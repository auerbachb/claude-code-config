#!/usr/bin/env python3
"""Bind a read-only browser bridge to its own freshly created usage tab."""
import json
from pathlib import Path
import re
import sys

PREFIX = 'mcp__claude-in-chrome__'
URL = 'https://cursor.com/dashboard?tab=usage'


def tab_id(value):
    """Accept positive integer tab IDs without coercing untrusted values."""
    return value if type(value) is int and value > 0 else None


def tool_failed(response):
    """Reject explicit native/MCP errors even beside apparently valid context."""
    if isinstance(response, dict):
        if response.get('isError') or response.get('is_error') or 'error' in response or response.get('success') is False or response.get('status') in ('error', 'failed', 'failure'):
            return True
        return any(tool_failed(response[key]) for key in
                   ('content', 'text', 'result', 'structuredContent', 'output', 'tabContext') if key in response)
    if isinstance(response, list):
        return any(tool_failed(item) for item in response)
    if isinstance(response, str):
        try:
            decoded = json.loads(response)
        except (ValueError, TypeError):
            return bool(re.search(r'^(?:Error\b|Failed\b|No MCP tab groups found\.)', response.strip(), re.I | re.M))
        return tool_failed(decoded)
    return False


def created_tab(response):
    """Require successful creation proof; execution context only confirms its ID."""
    if tool_failed(response):
        return None
    proved = set()
    context_ids = set()

    def collect(value, context_only=False):
        """Read known creation fields/text and separate native consistency metadata."""
        if isinstance(value, dict):
            for key, item in value.items():
                if not context_only and key in ('tabId', 'tab_id') and tab_id(item):
                    proved.add(item)
                elif key == 'executedOnTabId' and tab_id(item):
                    context_ids.add(item)
                elif key in ('content', 'text', 'result', 'structuredContent', 'output', 'tabContext'):
                    collect(item, context_only or key == 'tabContext')
        elif isinstance(value, list):
            for item in value:
                collect(item, context_only)
        elif isinstance(value, str):
            try:
                collect(json.loads(value), context_only)
            except (ValueError, TypeError):
                if context_only:
                    return
                native = re.findall(r'^Created new tab\. Tab ID: ([1-9][0-9]*)$', value, re.M)
                for match in native or re.findall(r'\btabId\s*[:=]\s*(\d+)\b', value):
                    if tab_id(int(match)):
                        proved.add(int(match))
    collect(response)
    return next(iter(proved)) if len(proved) == 1 and (not context_ids or context_ids == proved) else None


def navigation_acknowledged(response):
    """Recognize navigation acknowledgments without treating them as final URL proof."""
    if tool_failed(response):
        return False
    destinations = set()
    failed = False

    def collect(value):
        """Inspect known structured envelopes and literal navigation acknowledgments."""
        nonlocal failed
        if isinstance(value, dict):
            if value.get('isError') or value.get('error') or value.get('success') is False or value.get('status') == 'error':
                failed = True
            for key, item in value.items():
                if key in ('url', 'finalUrl', 'final_url') and isinstance(item, str):
                    destinations.add(item)
                elif key in ('content', 'text', 'result', 'structuredContent', 'output'):
                    collect(item)
        elif isinstance(value, list):
            for item in value:
                collect(item)
        elif isinstance(value, str):
            try:
                decoded = json.loads(value)
            except (ValueError, TypeError):
                if value.strip().lower().startswith('error'):
                    failed = True
                match = re.fullmatch(r'Navigated to (https?://\S+)\s*', value.strip())
                if match:
                    destinations.add(match.group(1))
            else:
                collect(decoded)
    collect(response)
    return not failed and destinations == {URL}


def context_destination(response, owned_tab):
    """Verify the dedicated tab URL from actual native tab-query metadata only."""
    if tool_failed(response):
        return False
    destinations = set()
    failed = False

    def collect(value):
        """Decode known MCP/native envelopes, never page content or acknowledgments."""
        nonlocal failed
        if isinstance(value, dict):
            if value.get('isError') or value.get('error') or value.get('success') is False:
                failed = True
            if 'availableTabs' in value:
                tabs = value['availableTabs']
                if not isinstance(tabs, list):
                    failed = True
                else:
                    for tab in tabs:
                        if not isinstance(tab, dict):
                            continue
                        identity = tab_id(tab.get('tabId', tab.get('id')))
                        if identity == owned_tab:
                            destinations.add(tab.get('url') if isinstance(tab.get('url'), str) else None)
                            if tab.get('pendingUrl') and tab['pendingUrl'] != URL:
                                failed = True
            for key in ('content', 'text', 'result', 'structuredContent', 'output', 'tabContext'):
                if key in value:
                    collect(value[key])
        elif isinstance(value, list):
            for item in value:
                collect(item)
        elif isinstance(value, str):
            try:
                decoded = json.loads(value)
            except (ValueError, TypeError):
                return
            collect(decoded)
    collect(response)
    return not failed and destinations == {URL}


def decide(event, state):
    """Allow only creating a dedicated tab, its fixed navigation and later reads."""
    name = event.get('tool_name', '')
    params = event.get('tool_input') or {}
    requested = tab_id(params.get('tabId', params.get('tab_id')))
    phase = event.get('hook_event_name')
    if phase == 'PostToolUse':
        response = event.get('tool_response')
        failed = tool_failed(response)
        if not failed and name == PREFIX + 'tabs_create_mcp':
            state.clear()
            state['tab'] = created_tab(response)
        elif name == PREFIX + 'navigate':
            state['navigated'] = False
            state['navigation_ack'] = bool(not failed and requested == state.get('tab') and params.get('url') == URL and navigation_acknowledged(response))
        elif name == PREFIX + 'tabs_context_mcp':
            state['navigated'] = bool(not failed and state.get('tab') and state.get('navigation_ack') and context_destination(response, state['tab']))
        return True
    if name == 'ToolSearch':
        return True
    if name == PREFIX + 'tabs_context_mcp':
        state['navigated'] = False
        return set(params) <= {'createIfEmpty'} and all(type(v) is bool for v in params.values())
    if name == PREFIX + 'tabs_create_mcp':
        state['navigated'] = False
        return not params
    if name == PREFIX + 'navigate':
        state['navigated'] = False
        state['navigation_ack'] = False
    if not requested or requested != state.get('tab'):
        return False
    if name == PREFIX + 'navigate':
        return params.get('url') == URL
    allowed = name in (PREFIX + 'read_page', PREFIX + 'get_page_text') and state.get('navigated') is True
    if allowed:
        state['navigated'] = False  # Require fresh native URL metadata before every read.
    return allowed


def main():
    """Persist only private tab metadata and return a fixed permission decision."""
    try:
        event = json.load(sys.stdin)
        path = Path(sys.argv[1])
        state = json.loads(path.read_text()) if path.exists() else {}
        allowed = decide(event, state)
        path.write_text(json.dumps(state))
        path.chmod(0o600)
    except (OSError, ValueError, TypeError, AttributeError, IndexError, RecursionError):
        allowed = False
        event = {}
    if event.get('hook_event_name') == 'PostToolUse':
        print('{}')
    else:
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                         'permissionDecision': 'allow' if allowed else 'deny',
                         'permissionDecisionReason': 'Quota bridge permits its own usage-tab reads only.'}}))


if __name__ == '__main__':
    main()
