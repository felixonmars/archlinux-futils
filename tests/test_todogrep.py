import asyncio
import importlib.machinery
import importlib.util
import io
import json
import logging
import os
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
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.cache = Path(directory) / 'cache' / '%2Ftodo%2Factive%2F.json'
        self.patch = mock.patch.multiple(todogrep, ARCHWEB=str(self.server.make_url('')).rstrip('/'),
                                         MIRROR=str(self.server.make_url('/')),
                                         TODO_CACHE_DIR=str(self.cache.parent))
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
                         set(todogrep.REPOSITORIES))
        self.assertNotIn('/api/v1/todo/finished/', self.requests)
        self.assertEqual(len(self.requests), len(states) + len(todogrep.REPOSITORIES) + 1)

    async def test_todo_details_are_cached_for_one_day_but_index_and_databases_are_live(self):
        self.index({'active': 'incomplete'})
        todo = {'name': 'Active', 'kind': 'Rebuild',
                'packages': [None, {'pkgname': 'split', 'pkgbase': 'base'}]}
        self.responses['/api/v1/todo/active/'] = (200, 'application/json', json.dumps(todo))
        first = mock.AsyncMock()
        await todogrep.analyze_overlaps(first, mock.AsyncMock())
        cached_at = self.cache.stat().st_mtime - 23 * 60 * 60
        os.utime(self.cache, (cached_at, cached_at))
        modified = self.cache.stat().st_mtime_ns

        # Details are still reusable after 23 hours, without extending expiry.
        del self.responses['/api/v1/todo/active/']
        self.requests.clear()
        second = mock.AsyncMock()
        databases = mock.AsyncMock()
        await todogrep.analyze_overlaps(second, databases)
        self.assertEqual(second.await_args_list, first.await_args_list)
        self.assertEqual(second.await_args.args[0]['packages'], todo['packages'])
        self.assertEqual(databases.await_count, len(todogrep.REPOSITORIES))
        self.assertEqual(len(self.requests), len(todogrep.REPOSITORIES) + 1)
        self.assertIn('/todo/', self.requests)
        self.assertNotIn('/api/v1/todo/active/', self.requests)
        self.assertEqual(self.cache.stat().st_mtime_ns, modified)

        updated = todo | {'packages': []}
        self.responses['/api/v1/todo/active/'] = (200, 'application/json', json.dumps(updated))
        expired = cached_at - 60 * 60
        os.utime(self.cache, (expired, expired))
        self.requests.clear()
        third = mock.AsyncMock()
        await todogrep.analyze_overlaps(third, mock.AsyncMock())
        third.assert_awaited_once_with(updated | {'url': '/todo/active/'})
        self.assertIn('/todo/', self.requests)
        self.assertIn('/api/v1/todo/active/', self.requests)
        self.assertEqual(json.loads(self.cache.read_text()), updated | {'url': '/todo/active/'})

    async def test_live_index_detects_new_completed_and_removed_todos_with_fresh_caches(self):
        self.index({'active': 'incomplete', 'finished': 'incomplete', 'removed': 'incomplete'})
        for slug in ('active', 'finished', 'removed', 'new'):
            self.responses[f'/api/v1/todo/{slug}/'] = (
                200, 'application/json', json.dumps({'name': slug, 'packages': []}))
        await todogrep.analyze_overlaps(mock.AsyncMock(), mock.AsyncMock())
        modified = self.cache.stat().st_mtime_ns

        self.index({'active': 'incomplete', 'finished': 'complete', 'new': 'incomplete'})
        self.requests.clear()
        callback = mock.AsyncMock()
        await todogrep.analyze_overlaps(callback, mock.AsyncMock())
        self.assertEqual({call.args[0]['url'] for call in callback.await_args_list},
                         {'/todo/active/', '/todo/new/'})
        self.assertIn('/todo/', self.requests)
        self.assertIn('/api/v1/todo/new/', self.requests)
        self.assertNotIn('/api/v1/todo/active/', self.requests)
        self.assertNotIn('/api/v1/todo/finished/', self.requests)
        self.assertNotIn('/api/v1/todo/removed/', self.requests)
        self.assertEqual(self.cache.stat().st_mtime_ns, modified)

    async def test_empty_todo_list_is_fetched_live(self):
        self.index({'finished': 'complete'})
        await todogrep.analyze_overlaps(mock.AsyncMock(), mock.AsyncMock())
        self.requests.clear()
        callback = mock.AsyncMock()
        await todogrep.analyze_overlaps(callback, mock.AsyncMock())
        callback.assert_not_awaited()
        self.assertEqual(len(self.requests), len(todogrep.REPOSITORIES) + 1)
        self.assertIn('/todo/', self.requests)

    async def test_invalid_cache_is_refetched(self):
        self.index({'active': 'incomplete'})
        todo = {'name': 'Active', 'packages': []}
        self.responses['/api/v1/todo/active/'] = (200, 'application/json', json.dumps(todo))
        self.cache.parent.mkdir()
        for content in (b'{', b'[]', b'{}', b'\xff'):
            with self.subTest(content=content):
                self.cache.write_bytes(content)
                self.requests.clear()
                await todogrep.analyze_overlaps(mock.AsyncMock(), mock.AsyncMock())
                self.assertIn('/todo/', self.requests)
                self.assertIn('/api/v1/todo/active/', self.requests)
                self.assertEqual(json.loads(self.cache.read_text()), todo | {'url': '/todo/active/'})

    async def test_unavailable_cache_does_not_prevent_live_check(self):
        self.index({'active': 'incomplete'})
        todo = {'name': 'Active', 'packages': []}
        self.responses['/api/v1/todo/active/'] = (200, 'application/json', json.dumps(todo))
        self.cache.parent.write_text('not a directory')
        callback = mock.AsyncMock()
        databases = mock.AsyncMock()
        with self.assertLogs(todogrep.logger, level='WARNING') as captured:
            await todogrep.analyze_overlaps(callback, databases)
        self.assertIn('/todo/', self.requests)
        callback.assert_awaited_once_with(todo | {'url': '/todo/active/'})
        self.assertEqual(databases.await_count, len(todogrep.REPOSITORIES))
        self.assertTrue(any('Cannot save todo cache' in line for line in captured.output))

    async def test_failed_refresh_keeps_expired_file_and_other_todos_are_cached_independently(self):
        self.index({'active': 'incomplete'})
        self.responses['/api/v1/todo/active/'] = (
            200, 'application/json', json.dumps({'name': 'Active', 'packages': []}))
        await todogrep.analyze_overlaps(mock.AsyncMock(), mock.AsyncMock())
        original = self.cache.read_bytes()
        expired = self.cache.stat().st_mtime - todogrep.TODO_CACHE_TTL
        os.utime(self.cache, (expired, expired))
        modified = self.cache.stat().st_mtime_ns

        self.index({'new': 'incomplete', 'active': 'incomplete'})
        self.responses['/api/v1/todo/new/'] = (
            200, 'application/json', json.dumps({'name': 'New', 'packages': []}))
        self.responses['/api/v1/todo/active/'] = (200, 'text/html', '<h1>Challenge</h1>')
        with self.assertRaises(aiohttp.ContentTypeError):
            await todogrep.analyze_overlaps(mock.AsyncMock(), mock.AsyncMock())
        self.assertEqual(self.cache.read_bytes(), original)
        self.assertEqual(self.cache.stat().st_mtime_ns, modified)

        self.responses['/api/v1/todo/active/'] = (
            200, 'application/json', json.dumps({'name': 'Unblocked', 'packages': []}))
        self.requests.clear()
        callback = mock.AsyncMock()
        await todogrep.analyze_overlaps(callback, mock.AsyncMock())
        self.assertIn('/todo/', self.requests)
        self.assertIn('/api/v1/todo/active/', self.requests)
        self.assertNotIn('/api/v1/todo/new/', self.requests)
        self.assertEqual(callback.await_count, 2)
        self.assertEqual(json.loads(self.cache.read_text())['name'], 'Unblocked')

    async def test_http_block_is_reported_before_callbacks(self):
        self.index({'active': 'incomplete'})
        self.responses['/api/v1/todo/active/'] = (
            200, 'application/json', json.dumps({'name': 'Active', 'packages': []}))
        await todogrep.analyze_overlaps(mock.AsyncMock(), mock.AsyncMock())
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

    async def test_pkgbase_mode_matches_only_the_supplied_pkgbases(self):
        async def overlaps(todo_callback, db_callback):
            await todo_callback({'packages': [{'pkgname': 'split', 'pkgbase': 'base'}],
                                 'kind': 'Rebuild', 'url': '/todo/example/', 'name': 'Example'})

        with mock.patch.object(todogrep, 'analyze_overlaps', side_effect=overlaps):
            self.assertEqual(await todogrep.main(['--pkgbase', 'base', 'other']), 1)
            self.assertEqual(await todogrep.main(['--pkgbase', 'split']), 0)

    async def test_missing_arguments_read_a_pkgbase_list_from_stdin(self):
        async def overlaps(todo_callback, db_callback):
            await todo_callback({'packages': [{'pkgname': 'split', 'pkgbase': 'base'}],
                                 'kind': 'Rebuild', 'url': '/todo/example/', 'name': 'Example'})

        with mock.patch.object(todogrep, 'analyze_overlaps', side_effect=overlaps):
            with mock.patch.object(todogrep.sys, 'stdin', io.StringIO('base\n\nother\n')):
                self.assertEqual(await todogrep.main(['--pkgbase']), 1)


if __name__ == '__main__':
    unittest.main()
