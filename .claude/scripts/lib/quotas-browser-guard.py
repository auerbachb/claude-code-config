#!/usr/bin/env python3
"""Bind a read-only browser bridge to its own freshly created usage tab."""
import json
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time

PREFIX = 'mcp__claude-in-chrome__'
URL = 'https://cursor.com/dashboard?tab=usage'
FAILURES = {'connection', 'denied', 'create', 'destination'}


def context_available(response):
    """Recognize native context metadata, without using it as URL authorization."""
    if tool_failed(response):
        return False
    if isinstance(response, dict):
        if isinstance(response.get('availableTabs'), list):
            return True
        return any(context_available(response[key]) for key in
                   ('content', 'text', 'result', 'structuredContent', 'output', 'tabContext') if key in response)
    if isinstance(response, list):
        return any(context_available(value) for value in response)
    if isinstance(response, str):
        try:
            value = json.loads(response)
        except (ValueError, TypeError):
            return False
        return context_available(value)
    return False


def read_evidence(path):
    """Read fixed observational facts only; they never authorize a tool."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_size > 1024):
                return None
            raw = stream.read(1025)
            if len(raw) > 1024:
                return None
            value = json.loads(raw)
        if (not isinstance(value, dict)
                or set(value) != {'last_failure', 'owned_tab', 'read_authorized'}
                or value['last_failure'] not in FAILURES | {None}
                or type(value['owned_tab']) is not bool
                or type(value['read_authorized']) is not bool):
            return None
        return value
    except (OSError, ValueError, TypeError, RecursionError):
        return None


def record_evidence(path, event, prior, allowed, failed=False):
    """Publish allowlisted stage facts after a decision, without changing it."""
    if not path:
        return
    temporary = None
    try:
        facts = read_evidence(path) or dict(last_failure=None, owned_tab=False, read_authorized=False)
        name, phase = event.get('tool_name'), event.get('hook_event_name')
        if phase != 'PostToolUse' and not allowed:
            facts['last_failure'] = 'denied'
        elif not failed and phase == 'PostToolUse':
            response = event.get('tool_response')
            if name == PREFIX + 'tabs_create_mcp':
                facts.update(owned_tab=created_tab(response) is not None, read_authorized=False)
                facts['last_failure'] = None if facts['owned_tab'] else 'create'
            elif name == PREFIX + 'tabs_context_mcp':
                if not prior.get('tab'):
                    if tool_failed(response):
                        facts['last_failure'] = 'connection'
                    elif context_available(response) and facts['last_failure'] == 'connection':
                        facts['last_failure'] = None
                elif prior.get('navigation_ack'):
                    facts['last_failure'] = None if context_destination(response, prior['tab']) else 'destination'
            elif name == PREFIX + 'navigate':
                params = event.get('tool_input') or {}
                if (isinstance(params, dict) and prior.get('tab')
                        and tab_id(params.get('tabId', params.get('tab_id'))) == prior['tab']
                        and params.get('url') == URL and not navigation_acknowledged(response)):
                    facts['last_failure'] = 'destination'
        elif phase == 'PreToolUse' and allowed and name in (PREFIX + 'read_page', PREFIX + 'get_page_text'):
            facts.update(last_failure=None, read_authorized=True)
        # Never serialize the event, prior authorization state, error text, URL
        # or tab identity. Diagnostics are expendable if publication fails.
        fd, temporary = tempfile.mkstemp(prefix='.stage-', dir=Path(path).parent)
        with os.fdopen(fd, 'w') as stream:
            json.dump(facts, stream)
        os.replace(temporary, path)
    except (OSError, ValueError, TypeError, AttributeError, RecursionError):
        pass
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


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


def private_write(path, value):
    """Publish bounded controller state before exposing its private pathname."""
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix='.quota-proof-', dir=path.parent)
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def state_lock(path):
    fd = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, 'a') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            raise ValueError('unsafe_lock')
        deadline = time.monotonic() + 4
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError('busy_lock')
                time.sleep(.02)
        yield


def private_state(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return {}
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > 16384:
            raise ValueError('unsafe_state')
        value = json.loads(stream.read(16385))
    if not isinstance(value, dict):
        raise ValueError('state_shape')
    return value


def fail_proof(path):
    """A denial/failure cannot race a later post event back into success."""
    try:
        fd = os.open(str(path) + '.failed', os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        return
    os.close(fd)


def read_key(event, state, attempt):
    identity = event.get('tool_use_id')
    params = event.get('tool_input')
    if not isinstance(identity, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,200}', identity) or not isinstance(params, dict):
        return None
    requested = tab_id(params.get('tabId', params.get('tab_id')))
    if requested is None or requested != state.get('tab'):
        return None
    # Persist no tool ID, input payload or tab identifier in the new proof.
    return hashlib.sha256((attempt + '\0' + identity + '\0' + event['tool_name'] + '\0' + str(requested)).encode()).hexdigest()


def supported_read(response):
    """Observed Claude2.1.312 native MCP PostToolUse content-block list only."""
    return (isinstance(response, list) and 0 < len(response) <= 64 and not tool_failed(response)
            and all(isinstance(block, dict) and block.get('type') == 'text' and isinstance(block.get('text'), str)
                    for block in response)
            and any(block['text'].strip() for block in response))


def bind_proof(path, attempt, event, prior, state, allowed, failed=False):
    phase, name = event.get('hook_event_name'), event.get('tool_name', '')
    reads = (PREFIX + 'read_page', PREFIX + 'get_page_text')
    state['proof_attempt'] = attempt
    used = prior.get('proof_used_ids', [])
    if isinstance(used, list) and len(used) <= 32 and all(isinstance(key, str) and re.fullmatch(r'[0-9a-f]{64}', key) for key in used):
        state['proof_used_ids'] = used
    else:
        allowed, failed = False, True
    if failed or phase == 'PostToolUseFailure' or (phase == 'PreToolUse' and not allowed):
        fail_proof(path)
        state.pop('proof_pending', None)
        private_write(path, dict(schema_version='1.0', attempt=attempt, completed_reads=0))
        return allowed
    if phase == 'PreToolUse' and name in reads:
        key = read_key(event, state, attempt)
        if not key or key in used or len(used) >= 32:
            fail_proof(path)
            allowed = False
            key = None
        else:
            state['proof_used_ids'] = used + [key]
        state['proof_pending'] = key
        private_write(path, dict(schema_version='1.0', attempt=attempt, completed_reads=0))
    elif phase == 'PostToolUse' and name in reads:
        key = read_key(event, state, attempt)
        complete = bool(key and key == prior.get('proof_pending') and supported_read(event.get('tool_response')))
        state.pop('proof_pending', None)
        if not complete:
            fail_proof(path)
        complete = complete and not os.path.lexists(str(path) + '.failed')
        private_write(path, dict(schema_version='1.0', attempt=attempt, completed_reads=int(complete)))
    elif name.startswith(PREFIX):
        state.pop('proof_pending', None)
        private_write(path, dict(schema_version='1.0', attempt=attempt, completed_reads=0))
    return allowed


def main():
    """Persist only private tab metadata and return a fixed permission decision."""
    observed, prior, failed, proof, attempt = {}, {}, False, None, None
    try:
        # Resolve the controller's fixed proof destination before parsing an event,
        # so malformed/oversized input also revokes any earlier completion.
        path = Path(sys.argv[1])
        if len(sys.argv) > 3:
            proof, attempt = Path(sys.argv[3]), sys.argv[4]
            if not re.fullmatch(r'[0-9a-f]{64}', attempt):
                raise ValueError('attempt')
        raw = sys.stdin.buffer.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024:
            raise ValueError('event_limit')
        event = json.loads(raw)
        observed = event if isinstance(event, dict) else {}
        if not observed or observed.get('hook_event_name') not in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
            raise ValueError('event_shape')
        with state_lock(path):
            state = private_state(path)
            prior = dict(state)
            if proof and prior.get('proof_attempt') != attempt:
                allowed, failed = False, True
                state.clear()
            elif observed['hook_event_name'] == 'PostToolUseFailure':
                allowed = False
                state['navigated'] = False
            else:
                allowed = decide(event, state)
            if proof:
                allowed = bind_proof(proof, attempt, event, prior, state, allowed, failed)
            private_write(path, state)
    except (OSError, ValueError, TypeError, AttributeError, IndexError, RecursionError):
        failed = True
        allowed = False
        if proof:
            with contextlib.suppress(OSError, ValueError):
                fail_proof(proof)
                private_write(proof, dict(schema_version='1.0', attempt=attempt, completed_reads=0))
    if observed.get('hook_event_name') != 'PostToolUseFailure':
        record_evidence(sys.argv[2] if len(sys.argv) > 2 else '', observed, prior, allowed, failed)
    if observed.get('hook_event_name') in ('PostToolUse', 'PostToolUseFailure'):
        print('{}')
    else:
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                         'permissionDecision': 'allow' if allowed else 'deny',
                         'permissionDecisionReason': 'Quota bridge permits its own usage-tab reads only.'}}))


if __name__ == '__main__':
    main()
