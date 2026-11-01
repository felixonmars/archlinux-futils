import asyncio
import importlib.machinery
import importlib.util
import io
import json
import logging
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer


SCRIPT = Path(__file__).resolve().parents[1] / "todogrep"
loader = importlib.machinery.SourceFileLoader("todogrep", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
todogrep = importlib.util.module_from_spec(spec)
loader.exec_module(todogrep)


class TodoGrepTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.requests = []
        self.active = 0
        self.max_active = 0
        self.responses = {}
        app = web.Application()
        app.router.add_get('/{path:.*}', self.respond)
        self.server = TestServer(app)
        await self.server.start_server()
        self.addAsyncCleanup(self.server.close)
        self.patch = mock.patch.multiple(todogrep, ARCHWEB=str(self.server.make_url('')).rstrip('/'),
                                         MIRROR=str(self.server.make_url('/')))
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.addCleanup(todogrep.logger.setLevel, todogrep.logger.level)
        self.addCleanup(todogrep.handler.setLevel, todogrep.handler.level)

    async def respond(self, request):
        self.requests.append(request.path)
        self.active += 1
        self.max_active = max(self.active, self.max_active)
        try:
            # Keep requests overlapping so an unbounded client hits the limit.
            await asyncio.sleep(0.01)
            if self.active > 2:
                return web.Response(status=429)
            if request.path.endswith('.db'):
                return web.Response(body=b'repository data')
            status, content_type, body = self.responses[request.path]
            return web.Response(status=status, content_type=content_type, text=body)
        finally:
            self.active -= 1

    def index(self, states):
        body = '<table id="dev-todo-lists">'
        for slug, state in states.items():
            body += f'<tr><td><a href="/todo/{slug}/">{slug}</a></td>'
            body += f'<td><span class="{state}">{state}</span></td></tr>'
        self.responses['/todo/'] = (200, 'text/html', body + '</table>')

    async def test_active_todos_use_api_with_bounded_connections(self):
        states = {f'active-{i}': 'incomplete' for i in range(12)}
        self.index(states | {'finished': 'complete'})
        for slug in states:
            self.responses[f'/api/v1/todo/{slug}/'] = (
                200, 'application/json', json.dumps({'name': slug, 'packages': []}))
        todo_callback = mock.AsyncMock()
        db_callback = mock.AsyncMock()
        await todogrep.analyze_overlaps(todo_callback, db_callback)

        self.assertEqual(self.max_active, 2)
        self.assertEqual(todo_callback.await_count, len(states))
        self.assertEqual({call.args[0]['url'] for call in todo_callback.await_args_list},
                         {f'/todo/{slug}/' for slug in states})
        self.assertEqual({call.args[0] for call in db_callback.await_args_list},
                         {'core-staging', 'extra-staging', 'multilib-staging'})
        self.assertNotIn('/api/v1/todo/finished/', self.requests)
        self.assertEqual(len(self.requests), len(states) + 4)

    async def test_http_block_is_reported_before_callbacks(self):
        self.responses['/todo/'] = (403, 'text/html', '<h1>Forbidden</h1>')
        todo_callback = mock.AsyncMock()
        db_callback = mock.AsyncMock()
        with self.assertRaises(aiohttp.ClientResponseError) as raised:
            await todogrep.analyze_overlaps(todo_callback, db_callback)
        self.assertEqual(raised.exception.status, 403)
        todo_callback.assert_not_awaited()
        db_callback.assert_not_awaited()

    async def test_html_challenge_is_not_treated_as_no_todos(self):
        self.responses['/todo/'] = (200, 'text/html', '<h1>Verify you are human</h1>')
        with self.assertRaisesRegex(ValueError, 'expected a todo list'):
            await todogrep.analyze_overlaps(mock.AsyncMock(), mock.AsyncMock())

    async def test_blocked_detail_is_not_treated_as_no_overlap(self):
        self.index({'blocked': 'incomplete'})
        self.responses['/api/v1/todo/blocked/'] = (200, 'text/html', '<h1>Challenge</h1>')
        todo_callback = mock.AsyncMock()
        with self.assertRaises(aiohttp.ContentTypeError):
            await todogrep.analyze_overlaps(todo_callback, mock.AsyncMock())
        todo_callback.assert_not_awaited()

    async def test_file_logging_records_failure_and_returns_error_status(self):
        self.responses['/todo/'] = (503, 'text/html', '<h1>Unavailable</h1>')
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'todogrep.log'
            with self.assertLogs(todogrep.logger, level='ERROR') as captured:
                status = await todogrep.main(['--log-file', str(log), 'example'])
            text = log.read_text()
        self.assertEqual(status, 2)
        self.assertIn('503', '\n'.join(captured.output))
        self.assertRegex(text, r'\d{4}-\d{2}-\d{2} .*DEBUG: Checking packages: example')
        self.assertIn('Traceback (most recent call last)', text)
        self.assertIn('/todo/', text)
        self.assertIn('503', text)
        self.assertNotIn('\x1b[', text)

    async def test_exit_status_for_todo_and_repository_matches(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            content = b'%NAME%\nstaged-split\n\n%BASE%\nstaged-base\n\n%VERSION%\n1-1\n\n'
            entry = tarfile.TarInfo('staged-split-1-1/desc')
            entry.size = len(content)
            archive.addfile(entry, io.BytesIO(content))

        async def overlaps(todo_callback, db_callback):
            await todo_callback({'packages': [None, {'pkgname': 'split', 'pkgbase': 'base'}],
                                 'kind': kind, 'url': '/todo/example/', 'name': kind})
            await db_callback('extra-staging', stream.getvalue())

        cases = [(['absent'], 0), (['base'], 0), (['staged-base'], 0),
                 (['split'], 1), (['staged-split'], 1), (['--pkgbase', 'base'], 1),
                 (['--pkgbase', 'staged-base'], 1), (['absent', 'split'], 1)]
        with mock.patch.object(todogrep, 'analyze_overlaps', side_effect=overlaps):
            for kind in ('Rebuild', 'Cleanup'):
                for args, expected in cases:
                    with self.subTest(kind=kind, args=args):
                        self.assertEqual(await todogrep.main(args), expected)

    async def test_failure_after_match_takes_precedence(self):
        async def overlaps(todo_callback, db_callback):
            await todo_callback({'packages': [{'pkgname': 'example', 'pkgbase': 'example'}],
                                 'kind': 'Rebuild', 'url': '/todo/example/', 'name': 'Example'})
            raise KeyError('packages')

        with mock.patch.object(todogrep, 'analyze_overlaps', side_effect=overlaps):
            with self.assertLogs(todogrep.logger, level='ERROR') as captured:
                status = await todogrep.main(['example'])
        self.assertEqual(status, 2)
        self.assertTrue(any('example overlaps' in line for line in captured.output))
        self.assertTrue(any('Overlap check failed' in line for line in captured.output))

    async def test_debug_and_pkgbase_matching(self):
        async def overlaps(todo_callback, db_callback):
            for kind in ('Rebuild', 'Cleanup'):
                await todo_callback({'packages': [None, {'pkgname': 'split', 'pkgbase': 'base'}],
                                     'kind': kind, 'url': '/todo/example/', 'name': kind})

        with mock.patch.object(todogrep, 'analyze_overlaps', side_effect=overlaps):
            with self.assertLogs(todogrep.logger, level='DEBUG') as captured:
                status = await todogrep.main(['--debug', '--pkgbase', 'base'])
        self.assertEqual(status, 1)
        self.assertEqual(todogrep.handler.level, logging.DEBUG)
        self.assertTrue(any('ERROR:' in line and 'base overlaps' in line for line in captured.output))
        self.assertTrue(any('WARNING:' in line and 'base overlaps' in line for line in captured.output))


if __name__ == '__main__':
    unittest.main()
