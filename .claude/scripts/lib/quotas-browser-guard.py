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


def created_tab(response):
    """Extract one unambiguous native tab-create ID, otherwise fail closed."""
    found = set()

    def collect(value):
        """Read structured tool envelopes and JSON/text content blocks."""
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ('tabId', 'tab_id') and tab_id(item):
                    found.add(item)
                elif key in ('content', 'text', 'result', 'structuredContent'):
                    collect(item)
        elif isinstance(value, list):
            for item in value:
                collect(item)
        elif isinstance(value, str):
            try:
                collect(json.loads(value))
            except (ValueError, TypeError):
                for match in re.findall(r'\btabId\s*[:=]\s*(\d+)\b', value):
                    if tab_id(int(match)):
                        found.add(int(match))
    collect(response)
    return next(iter(found)) if len(found) == 1 else None


def verified_destination(response):
    """Require an explicit native destination proof, never a requested URL alone."""
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
                elif key in ('content', 'text', 'result', 'structuredContent'):
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


def decide(event, state):
    """Allow only creating a dedicated tab, its fixed navigation and later reads."""
    name = event.get('tool_name', '')
    params = event.get('tool_input') or {}
    requested = tab_id(params.get('tabId', params.get('tab_id')))
    phase = event.get('hook_event_name')
    if phase == 'PostToolUse':
        response = event.get('tool_response')
        failed = isinstance(response, dict) and (response.get('isError') or response.get('error'))
        failed = failed or (isinstance(response, str) and response.lstrip().lower().startswith('error'))
        if not failed and name == PREFIX + 'tabs_create_mcp':
            state.clear()
            state['tab'] = created_tab(response)
        elif name == PREFIX + 'navigate':
            state['navigated'] = bool(not failed and requested == state.get('tab') and params.get('url') == URL and verified_destination(response))
        return True
    if name == 'ToolSearch':
        return True
    if name == PREFIX + 'tabs_create_mcp':
        return not params
    if name == PREFIX + 'navigate':
        state['navigated'] = False
    if not requested or requested != state.get('tab'):
        return False
    if name == PREFIX + 'navigate':
        return params.get('url') == URL
    return name in (PREFIX + 'read_page', PREFIX + 'get_page_text') and state.get('navigated') is True


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
