"""Read-only browser bridge contracts, without live browser or credential access."""
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('browser', Path(__file__).parents[1] / '.claude/scripts/lib/quotas-browser.py')
browser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(browser)


def observation():
    """Return a fresh account-matched fixture with one reported pool."""
    return dict(schema_version=1, provider='cursor', label='fixture', email='fixture@example.com', status='ok',
                observed_at_epoch=1000, rows=[dict(window='cursor-models', used_pct=37, resets_at_epoch=None)])


class Browser(unittest.TestCase):
    """Reject unsafe observations and constrain the explicit supported bridge."""
    def test_identity_freshness_and_null(self):
        """Require identity and freshness, without converting missing usage to zero."""
        doc = observation()
        self.assertEqual(browser.validate(doc, 'fixture', 'FIXTURE@example.com', 1000), doc)
        for email, now in [('other@example.com', 1000), ('fixture@example.com', 1400)]:
            with self.assertRaises(ValueError):
                browser.validate(doc, 'fixture', email, now)
        doc['rows'][0]['used_pct'] = None
        with self.assertRaises(ValueError):
            browser.validate(doc, 'fixture', '', 1000)

    def test_secret_fields_and_bad_numbers(self):
        """Reject unrecognized fields, boolean percentages and malformed pools."""
        for change in ['token', 'cookie', 'password']:
            doc = observation()
            doc[change] = 'synthetic-never-read'
            with self.assertRaises(ValueError):
                browser.validate(doc, 'fixture', 'fixture@example.com', 1000)
        self.assertEqual(browser.validate(observation(), 'fixture', 'fixture@example.com', 1000)['status'], 'ok')
        for value in [True, -1, float('nan'), '35']:
            doc = observation()
            doc['rows'][0]['used_pct'] = value
            with self.assertRaises(ValueError):
                browser.validate(doc, 'fixture', 'fixture@example.com', 1000)

    def test_private_results_file(self):
        """Accept private result files and refuse public or symlinked inputs."""
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'result'
            p.write_text(json.dumps(observation()))
            p.chmod(0o600)
            self.assertEqual(browser.read_observation(str(p), 'fixture', 'fixture@example.com', 1000, 'unused')['status'], 'ok')
            p.chmod(0o644)
            with self.assertRaises(ValueError):
                browser.read_observation(str(p), 'fixture', 'fixture@example.com', 1000, 'unused')
            link = Path(tmp) / 'link'
            link.symlink_to(p)
            with self.assertRaises(OSError):
                browser.read_observation(str(link), 'fixture', 'fixture@example.com', 1000, 'unused')

    def test_guard_enforces_navigation_and_tool_boundary(self):
        """Native tab metadata must verify the owned destination before every read."""
        guard = Path(browser.__file__).with_name('quotas-browser-guard.py')
        url = 'https://cursor.com/dashboard?tab=usage'
        with tempfile.TemporaryDirectory() as tmp:
            state = str(Path(tmp)/'state')

            def event(tool, params, phase='PreToolUse', response=None):
                """Call the real hook with synthetic native1.0.104 response envelopes."""
                result = subprocess.run([sys.executable, str(guard), state], input=json.dumps(
                    {'tool_name':'mcp__claude-in-chrome__'+tool, 'tool_input':params,
                     'hook_event_name':phase, 'tool_response':response}), text=True, capture_output=True, check=True)
                return json.loads(result.stdout).get('hookSpecificOutput', {}).get('permissionDecision')

            def context(tabs, error=False):
                """Return fresh native tab-query metadata through the MCP text envelope."""
                self.assertEqual(event('tabs_context_mcp', {}), 'allow')
                payload = {'isError':True} if error else {'content':[{'type':'text','text':json.dumps({'availableTabs':tabs})}]}
                event('tabs_context_mcp', {}, 'PostToolUse', payload)

            params = {'tabId':41,'url':url}
            ack = {'output':'Navigated to '+url}
            actual = [{'tabId':41,'url':url},{'tabId':99,'url':'https://unrelated.example/'}]
            self.assertEqual(event('read_page', {'tabId':41}), 'deny')
            self.assertEqual(event('tabs_context_mcp', {'createIfEmpty':True}), 'allow')
            event('tabs_context_mcp', {}, 'PostToolUse', {'output':json.dumps({'availableTabs':[]})})
            event('tabs_create_mcp', {}, 'PostToolUse', {
                'output':'Created new tab. Tab ID: 41',
                'tabContext':{'currentTabId':99,'executedOnTabId':41,
                              'availableTabs':[{'id':41,'url':'chrome://newtab'},{'id':99,'url':'https://unrelated.example/'}]}})
            self.assertEqual(event('read_page', {'tabId':41}), 'deny')
            self.assertEqual(event('navigate', {'tabId':41,'url':'https://cursor.com/settings'}), 'deny')
            self.assertEqual(event('navigate', params), 'allow')
            event('navigate', params, 'PostToolUse', ack)
            self.assertEqual(event('read_page', {'tabId':41}), 'deny')  # Request echo is not destination proof.
            context(actual)
            self.assertEqual(event('read_page', {'tabId':41}), 'allow')
            self.assertEqual(event('read_page', {'tabId':41}), 'deny')  # Metadata permission is single-use.
            for response in [None, {}, {'success':True,'url':'https://other.example/'}, {'isError':True}]:
                event('navigate', params)
                event('navigate', params, 'PostToolUse', ack)
                context(actual)  # Begin with a previously verified tab, then invalidate it.
                self.assertEqual(event('navigate', params), 'allow')
                self.assertEqual(event('read_page', {'tabId':41}), 'deny')
                event('navigate', params, 'PostToolUse', response)
                context(actual)
                self.assertEqual(event('read_page', {'tabId':41}), 'deny')
            event('navigate', params)
            event('navigate', params, 'PostToolUse', ack)
            for tabs in [[{'tabId':41,'url':'https://other.example/'}], [],
                         [{'tabId':99,'url':url}], [{'tabId':41,'url':url,'pendingUrl':'https://other.example/'}]]:
                context(tabs)
                self.assertEqual(event('get_page_text', {'tabId':41}), 'deny')
            context(actual, error=True)
            self.assertEqual(event('read_page', {'tabId':41}), 'deny')
            event('tabs_context_mcp', {}, 'PostToolUse', {'output':'Navigated to '+url})
            self.assertEqual(event('read_page', {'tabId':41}), 'deny')
            event('tabs_context_mcp', {}, 'PostToolUse', {'output':json.dumps({'availableTabs':actual})})
            self.assertEqual(event('get_page_text', {'tabId':99}), 'deny')
            self.assertEqual(event('get_page_text', {'tabId':41}), 'allow')
            self.assertEqual(event('tabs_create_mcp', {'url':'https://other.example/'}), 'deny')
            self.assertEqual(event('computer', {'tabId':41,'action':'left_click'}), 'deny')
            self.assertEqual(event('javascript_tool', {'tabId':41}), 'deny')
            event('tabs_create_mcp', {}, 'PostToolUse', {'unknown':'unverified native envelope'})
            self.assertEqual(event('read_page', {'tabId':41}), 'deny')

    def test_native_errors_cannot_be_overridden_by_execution_context(self):
        """Native failure output never proves tab ownership or a final destination."""
        path = Path(browser.__file__).with_name('quotas-browser-guard.py')
        spec = importlib.util.spec_from_file_location('native_guard_errors', path)
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        url = guard.URL
        for response in [
            {'tabContext':{'executedOnTabId':99}},
            {'tabContext':{'tabId':99}},
            {'tabContext':{'output':'Created new tab. Tab ID: 99'}},
            {'output':'Error: creation failed','tabContext':{'executedOnTabId':99}},
            {'output':'Created new tab. Tab ID: 41','tabContext':{'executedOnTabId':99}},
            {'output':{'status':'error','tabId':41}},
            {'content':[{'text':'Error: creation failed'}], 'tabId':41}]:
            self.assertIsNone(guard.created_tab(response))
        good = {'availableTabs':[{'tabId':41,'url':url}]}
        for response in [{'status':'error',**good}, {'error':{},**good}, {'output':'Error: context unavailable',**good},
                         {'output':'No MCP tab groups found.',**good},
                         {'output':json.dumps({'status':'error',**good})}]:
            self.assertFalse(guard.context_destination(response,41))
            state = {'tab':41,'navigation_ack':True,'navigated':True}
            guard.decide({'tool_name':guard.PREFIX+'tabs_context_mcp','hook_event_name':'PostToolUse',
                          'tool_input':{},'tool_response':response},state)
            self.assertFalse(state['navigated'])

    def test_identity_required_for_usage_but_not_signed_out(self):
        """Unknown identity never attributes usage; signed-out observations retain status."""
        with self.assertRaises(ValueError):
            browser.validate(observation(), 'fixture', '', 1000)
        doc = observation()
        doc.update(status='logged_out', email='', rows=[])
        self.assertEqual(browser.validate(doc, 'fixture', 'fixture@example.com', 1000)['status'], 'logged_out')

    def test_malformed_bridge_envelopes_and_huge_numbers(self):
        """Malformed CLI data and oversized numbers reject without leaking diagnostics."""
        self.assertFalse(browser.number(10**500))
        with mock.patch.object(browser.subprocess, 'run') as run:
            run.return_value.stdout = '[]'
            with self.assertRaises(ValueError):
                browser.read_observation('', 'fixture', 'fixture@example.com', 1000, '/fake/claude')

    def test_supported_cli_bridge_is_read_only(self):
        """The actual bridge enables Chrome and allows only navigation/page tools."""
        with mock.patch.object(browser.subprocess, 'run') as run:
            run.return_value.stdout = json.dumps({'structured_output': observation()})
            browser.read_observation('', 'fixture', 'fixture@example.com', 1000, '/fake/claude')
        args = run.call_args.args[0]
        self.assertIn('--chrome', args)
        allowed = args[args.index('--allowedTools') + 1]
        for forbidden in ['javascript', 'computer', 'Bash', 'cookie', 'form_input']:
            self.assertNotIn(forbidden, allowed)
        self.assertIn('mcp__claude-in-chrome__navigate', allowed)
        self.assertIn('mcp__claude-in-chrome__tabs_context_mcp', allowed)
        self.assertIn('Before EACH page read', args[-1])
        self.assertEqual(run.call_args.kwargs['timeout'], 90)
        self.assertEqual(run.call_args.kwargs['stdin'], subprocess.DEVNULL)


if __name__ == '__main__':
    unittest.main()
