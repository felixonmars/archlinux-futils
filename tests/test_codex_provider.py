"""Tests for codex-provider."""

import copy
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import urlparse

try:
    import tomlkit
except ImportError:  # pragma: no cover - dependency check
    tomlkit = None

try:
    from textual.widgets import DataTable, Input, Select, Static, Switch
except ImportError:  # pragma: no cover - optional TUI dependency
    DataTable = Input = Select = Static = Switch = None
    HAVE_TEXTUAL = False
else:
    HAVE_TEXTUAL = True

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "codex-provider"
CODEX = shutil.which("codex")

BETA = ["beta-1", "beta-2"]
REQUESTS = []


class Fixture:
    codex_url = ""
    openai_url = ""
    none_url = ""
    alpha = ()
    server = None


def catalog_entry(template, slug):
    entry = copy.deepcopy(template)
    entry["slug"] = slug
    entry["display_name"] = slug.title()
    return entry


class CatalogHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        REQUESTS.append((self.path, self.headers.get("Authorization")))
        path = urlparse(self.path).path
        if path == "/codex/models":
            body = json.dumps({"models": Fixture.alpha}).encode()
            status = 200
        elif path == "/openai/models":
            body = json.dumps(
                {"data": [{"id": slug} for slug in BETA]}).encode()
            status = 200
        else:
            body = b'{"error": "no catalog"}'
            status = 403 if path.startswith("/none") else 404
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def setUpModule():
    if tomlkit is None:
        raise unittest.SkipTest("python-tomlkit is required")
    if CODEX is None:
        raise unittest.SkipTest("the codex CLI is required")
    with tempfile.TemporaryDirectory() as scratch:
        env = dict(os.environ, CODEX_HOME=scratch)
        result = subprocess.run(
            [CODEX, "debug", "models", "--bundled"], check=True,
            env=env, capture_output=True, text=True)
    template = next(
        entry for entry in json.loads(result.stdout)["models"]
        if entry["slug"] == "gpt-5.5")
    Fixture.alpha = [catalog_entry(template, slug)
                     for slug in ("alpha-1", "alpha-2")]
    Fixture.server = ThreadingHTTPServer(("127.0.0.1", 0), CatalogHandler)
    port = Fixture.server.server_address[1]
    Fixture.codex_url = f"http://127.0.0.1:{port}/codex"
    Fixture.openai_url = f"http://127.0.0.1:{port}/openai"
    Fixture.none_url = f"http://127.0.0.1:{port}/none"
    threading.Thread(target=Fixture.server.serve_forever,
                     daemon=True).start()


def tearDownModule():
    if Fixture.server is not None:
        Fixture.server.shutdown()
        Fixture.server.server_close()


def load_script():
    loader = importlib.machinery.SourceFileLoader(
        "codex_provider_test", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


def rendered(widget):
    content = widget.content
    return content.plain if hasattr(content, "plain") else str(content)


def app_rows(app):
    table = app.query_one("#providers", DataTable)
    return [[cell.plain if hasattr(cell, "plain") else str(cell)
             for cell in table.get_row_at(index)]
            for index in range(table.row_count)]


def app_labels(app):
    return [row[1] for row in app_rows(app)]


def app_message(app):
    return rendered(app.query_one("#message", Static))


class ProviderFixture:
    def setUpFixture(self):
        REQUESTS.clear()
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.root = Path(self._temp.name)

    def config_text(self):
        return f'''model_provider = "OpenAI"
model = "gpt-6-astra"

[model_providers.OpenAI]
name = "OpenAI-RelayA"
base_url = "{Fixture.codex_url}"
wire_api = "responses"
requires_openai_auth = true

[model_providers.OpenAI2]
name = "OpenAI-RelayB"
base_url = "{Fixture.openai_url}"
wire_api = "responses"
requires_openai_auth = true

[model_providers.OpenAIOfficial]
name = "OpenAI-Official"
wire_api = "responses"
requires_openai_auth = true
'''

    def make_home(self, name="home"):
        home = self.root / name / ".codex"
        home.mkdir(parents=True)
        (home / "config.toml").write_text(self.config_text())
        (home / "auth.json").write_text(
            '{"OPENAI_API_KEY": "sk-test-relay-a-000000000000"}')
        (home / "auth.official.json").write_text(
            '{"auth_mode": "chatgpt", '
            '"tokens": {"refresh_token": "rt-official"}}')
        (home / "auth.OpenAI-RelayA.json").write_text(
            '{"auth_mode": "apikey", '
            '"OPENAI_API_KEY": "sk-test-relay-a-000000000000"}')
        (home / "auth.OpenAI-RelayB.json").write_text(
            '{"auth_mode": "apikey", '
            '"OPENAI_API_KEY": "sk-test-relay-b-000000000000"}')
        return home

    def run_cli(self, home, *args):
        env = dict(os.environ, HOME=str(home.parent))
        return subprocess.run(
            [str(SCRIPT), *args], check=False, env=env,
            capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def config_of(self, home):
        return tomlkit.parse((home / "config.toml").read_text())

    def entry_named(self, home, name):
        for entry in self.config_of(home)["model_providers"].values():
            if str(entry.get("name")) == name:
                return entry
        return None

    def auth_of(self, home):
        return json.loads((home / "auth.json").read_text())

    def codex_models(self, home):
        env = dict(os.environ, HOME=str(home.parent))
        env.pop("CODEX_HOME", None)
        result = subprocess.run(
            [CODEX, "debug", "models"], check=False, env=env,
            capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr[-300:])
        return [entry["slug"] for entry in
                json.loads(result.stdout).get("models", [])]

    def write_auth_file(self, home, name="import.json"):
        path = home.parent / name
        path.write_text('{"auth_mode": "chatgpt", '
                        '"tokens": {"refresh_token": "rt-imported"}}')
        return path


class CliTest(ProviderFixture, unittest.TestCase):
    def setUp(self):
        self.setUpFixture()

    def test_list_and_models(self):
        home = self.make_home()
        result = self.run_cli(home, "list")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertTrue(any(line.startswith("RelayA") and "(active)" in line
                            for line in lines))
        self.assertTrue(any("RelayB" in line and "sk-test-re..." in line
                            for line in lines))
        self.assertTrue(any("Official" in line and "ChatGPT login" in line
                            for line in lines))

        result = self.run_cli(home, "models", "RelayA")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 models (Codex catalog)", result.stdout)
        self.assertIn("alpha-1", result.stdout)
        self.assertIn("alpha-2", result.stdout)
        self.assertTrue(any(auth and auth.startswith("Bearer sk-test-")
                            for _, auth in REQUESTS))

        result = self.run_cli(home, "models", "RelayB")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 models (OpenAI-style list)", result.stdout)
        self.assertIn("beta-1", result.stdout)
        self.assertIn("beta-2", result.stdout)

    def test_switch_formats_and_models(self):
        home = self.make_home()
        result = self.run_cli(home, "use", "RelayB")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Using RelayB as OpenAI", result.stdout)
        self.assertIn("web_search disabled", result.stdout)
        names = {slot: str(entry.get("name")) for slot, entry in
                 self.config_of(home)["model_providers"].items()}
        self.assertEqual(names["OpenAI"], "OpenAI-RelayB")
        self.assertEqual(names["OpenAI2"], "OpenAI-RelayA")
        self.assertEqual(self.auth_of(home)["OPENAI_API_KEY"],
                         "sk-test-relay-b-000000000000")

        catalog_file = home / "model-catalog.OpenAI-RelayB.json"
        self.assertTrue(catalog_file.exists())
        catalog = json.loads(catalog_file.read_text())
        self.assertEqual([entry["slug"] for entry in catalog["models"]], BETA)
        self.assertEqual(catalog["_codex_provider"]["web_search"], None)
        config = self.config_of(home)
        self.assertEqual(str(config.get("model_catalog_json")),
                         "~/.codex/model-catalog.OpenAI-RelayB.json")
        self.assertEqual(str(config.get("web_search")), "disabled")

        result = self.run_cli(home, "use", "RelayA")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Using RelayA as OpenAI", result.stdout)
        relay_a = self.entry_named(home, "OpenAI-RelayA")
        self.assertEqual(str(relay_a.get("model_catalog_url")),
                         Fixture.codex_url + "/models")
        config = self.config_of(home)
        self.assertNotIn("model_catalog_json", config)
        self.assertNotIn("web_search", config)

        result = self.run_cli(home, "use", "RelayB", "--model", BETA[1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Model set to {BETA[1]}", result.stdout)
        self.assertEqual(str(self.config_of(home).get("model")), BETA[1])
        result = self.run_cli(home, "use", "RelayB", "--model", BETA[0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Model set to {BETA[0]}", result.stdout)
        self.assertEqual(str(self.config_of(home).get("model")), BETA[0])

    def test_add_remove_and_validation(self):
        home = self.make_home()
        before_catalog = self.config_of(home).get("model_catalog_json")
        result = self.run_cli(home, "add", "Gamma", "--base-url",
                              Fixture.openai_url, "--api-key", "sk-gamma")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Added Gamma", result.stdout)
        self.assertIn("2 models", result.stdout)
        self.assertEqual(self.config_of(home).get("model_catalog_json"),
                         before_catalog)
        self.assertTrue((home / "model-catalog.OpenAI-Gamma.json").exists())

        self.assertEqual(self.run_cli(
            home, "add", "Gamma", "--base-url",
            Fixture.openai_url).returncode, 1)
        self.assertEqual(self.run_cli(
            home, "add", "official", "--base-url",
            Fixture.openai_url).returncode, 1)
        self.assertEqual(self.run_cli(
            home, "add", "2", "--base-url",
            Fixture.openai_url).returncode, 1)
        self.assertEqual(self.run_cli(
            home, "add", "bad label", "--base-url",
            Fixture.openai_url).returncode, 1)
        self.assertEqual(self.run_cli(
            home, "add", "BadURL", "--base-url",
            "ftp://x.example.com").returncode, 1)
        self.assertEqual(self.run_cli(home, "add", "Nope").returncode, 2)
        self.assertEqual(self.run_cli(
            home, "add", "Nope", "--base-url", Fixture.openai_url,
            "--model", "x").returncode, 2)
        self.assertEqual(self.run_cli(home, "no-such-provider").returncode, 1)

        result = self.run_cli(home, "add", "Delta", "--base-url",
                              Fixture.openai_url, "--api-key", "sk-delta",
                              "--switch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Using Delta as OpenAI", result.stdout)
        self.assertEqual(str(self.config_of(home).get("model_catalog_json")),
                         "~/.codex/model-catalog.OpenAI-Delta.json")

        result = self.run_cli(home, "use", "Delta", "--api-key", "sk-delta-2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Updated auth for Delta", result.stdout)
        self.assertEqual(self.auth_of(home)["OPENAI_API_KEY"], "sk-delta-2")
        snapshot = json.loads((home / "auth.OpenAI-Delta.json").read_text())
        self.assertEqual(snapshot["OPENAI_API_KEY"], "sk-delta-2")

        import_file = self.write_auth_file(home)
        result = self.run_cli(home, "use", "RelayB", "--auth",
                              str(import_file))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Using RelayB", result.stdout)
        self.assertEqual(
            self.auth_of(home)["tokens"]["refresh_token"], "rt-imported")

        result = self.run_cli(home, "remove", "Gamma")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Removed Gamma", result.stdout)
        self.assertTrue((home / "auth.OpenAI-Gamma.json").exists())
        self.assertTrue((home / "model-catalog.OpenAI-Gamma.json").exists())
        names = [str(entry.get("name")) for entry in
                 self.config_of(home)["model_providers"].values()]
        self.assertNotIn("OpenAI-Gamma", names)
        self.assertEqual(self.run_cli(home, "remove", "RelayB").returncode, 1)
        self.assertEqual(self.run_cli(home, "remove", "official").returncode, 1)

    def test_web_search_restore(self):
        home = self.make_home("web-search")
        text = self.config_text().replace(
            'model = "gpt-6-astra"',
            'web_search = "live"\nmodel = "gpt-6-astra"')
        (home / "config.toml").write_text(text)

        result = self.run_cli(home, "use", "RelayB")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(str(self.config_of(home).get("web_search")),
                         "disabled")
        metadata = json.loads(
            (home / "model-catalog.OpenAI-RelayB.json").read_text())
        self.assertEqual(metadata["_codex_provider"]["web_search"], "live")

        result = self.run_cli(home, "add", "Gamma", "--base-url",
                              Fixture.openai_url, "--api-key", "sk-gamma",
                              "--switch")
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads(
            (home / "model-catalog.OpenAI-Gamma.json").read_text())
        self.assertEqual(metadata["_codex_provider"]["web_search"], "live")

        result = self.run_cli(home, "use", "RelayA")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("web_search restored to live", result.stdout)
        self.assertEqual(str(self.config_of(home).get("web_search")), "live")

    def test_unreachable_and_invalid(self):
        home = self.make_home()
        result = self.run_cli(home, "add", "Dead", "--base-url",
                              Fixture.none_url, "--api-key", "sk-dead")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Model catalog unavailable", result.stdout)
        dead = self.entry_named(home, "OpenAI-Dead")
        self.assertIsNotNone(dead)
        self.assertNotIn("model_catalog_url", dead)
        self.assertEqual(self.run_cli(home, "models", "Dead").returncode, 1)

        missing = self.make_home("missing-official")
        text = self.config_text().split(
            "[model_providers.OpenAIOfficial]")[0]
        (missing / "config.toml").write_text(text)
        result = self.run_cli(missing, "list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Official", result.stdout)
        (missing / "config.toml").write_text(text)
        result = self.run_cli(missing, "add", "Solo", "--base-url",
                              Fixture.openai_url, "--api-key", "sk-solo")
        self.assertEqual(result.returncode, 0, result.stderr)
        names = [str(entry.get("name")) for entry in
                 self.config_of(missing)["model_providers"].values()]
        self.assertIn("OpenAI-Official", names)

        invalid = self.make_home("invalid")
        (invalid / "config.toml").write_text(
            'model_provider = "OpenAI"\n')
        result = self.run_cli(invalid, "list")
        self.assertEqual(result.returncode, 1)
        self.assertIn("model_providers", result.stderr)
        (invalid / "config.toml").write_text("this is [not toml")
        result = self.run_cli(invalid, "list")
        self.assertEqual(result.returncode, 1)
        self.assertIn("codex-provider:", result.stderr)

    def test_codex_sees_catalogs(self):
        home = self.make_home()
        self.run_cli(home, "use", "RelayB")
        self.assertEqual(self.codex_models(home), BETA)
        self.run_cli(home, "use", "RelayA")
        self.assertEqual(self.codex_models(home),
                         [entry["slug"] for entry in Fixture.alpha])

    def test_transactions(self):
        module = load_script()
        home = self.make_home("transactions")
        store = module.Store(home)
        state = store.read()
        self.assertEqual([provider.label for provider in state.providers][:2],
                         ["RelayA", "RelayB"])

        text = (home / "config.toml").read_text().replace(
            'model = "gpt-6-astra"', 'model = "gpt-6-external"')
        text += f'''
[model_providers.OpenAIExt]
name = "OpenAI-Ext"
base_url = "{Fixture.codex_url}"
wire_api = "responses"
requires_openai_auth = true
'''
        (home / "config.toml").write_text(text)
        message = store.switch("Official")
        config = self.config_of(home)
        self.assertEqual(str(config.get("model")), "gpt-6-external")
        self.assertIsNotNone(config["model_providers"].get("OpenAIExt"))
        self.assertEqual(
            str(config["model_providers"]["OpenAI"]["name"]),
            "OpenAI-Official")
        self.assertIn("Using Official", message)

        retry_home = self.make_home("retry")
        retry_store = module.Store(retry_home)
        original = retry_store._changed_since
        calls = {"count": 0}

        def racing(texts):
            if calls["count"] == 0:
                calls["count"] += 1
                text = (retry_home / "config.toml").read_text().replace(
                    'model = "gpt-6-astra"', 'model = "gpt-6-racy"')
                (retry_home / "config.toml").write_text(text)
            return original(texts)

        retry_store._changed_since = racing
        retry_store.switch("RelayB")
        config = self.config_of(retry_home)
        self.assertEqual(calls["count"], 1)
        self.assertEqual(str(config.get("model")), "gpt-6-racy")
        self.assertEqual(
            str(config["model_providers"]["OpenAI"]["name"]),
            "OpenAI-RelayB")

        conflict_home = self.make_home("conflict")
        conflict_store = module.Store(conflict_home)
        before_auth = (conflict_home / "auth.json").read_text()
        before_config = (conflict_home / "config.toml").read_text()
        conflict_store._changed_since = lambda texts: True
        with self.assertRaises(module.Conflict):
            conflict_store.switch("RelayB")
        self.assertEqual((conflict_home / "auth.json").read_text(),
                         before_auth)
        self.assertEqual((conflict_home / "config.toml").read_text(),
                         before_config)


@unittest.skipUnless(HAVE_TEXTUAL, "python-textual is required")
class TuiTest(ProviderFixture, unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.setUpFixture()
        self.home = self.make_home()
        environment = mock.patch.dict(
            os.environ, {"HOME": str(self.home.parent)})
        environment.start()
        self.addCleanup(environment.stop)
        self.module = load_script()
        self.app = self.module.CodexProviderApp(self.module.Store(self.home))

    async def select(self, pilot, label):
        names = [provider.label for provider in self.app.state.providers]
        self.app.query_one("#providers", DataTable).move_cursor(
            row=names.index(label))
        await pilot.pause()

    def atomic_write(self, path, text):
        temporary = path.with_name(path.name + ".tmp-test")
        temporary.write_text(text)
        os.replace(temporary, path)

    async def test_flows(self):
        app = self.app
        async with app.run_test(size=(120, 40)) as pilot:
            await pilot.pause()
            self.assertEqual(app_labels(app),
                             ["RelayA", "RelayB", "Official"])
            self.assertEqual(app_rows(app)[0][0], "*")
            self.assertEqual(app_rows(app)[0][1], "RelayA")
            self.assertIn("sk-test-re...", app_rows(app)[0][2])
            details = rendered(app.query_one("#details", Static))
            self.assertIn("slot OpenAI", details)
            self.assertIn("catalog not configured", details)

            await pilot.press("j")
            await pilot.pause()
            self.assertEqual(app.query_one(DataTable).cursor_row, 1)
            await pilot.press("k")
            await pilot.pause()
            self.assertEqual(app.query_one(DataTable).cursor_row, 0)

            await pilot.press("question_mark")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__, "HelpScreen")
            self.assertIn("re-reads config.toml",
                          rendered(app.screen.query_one("#help", Static)))
            await pilot.press("escape")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__, "Screen")

            await pilot.press("a")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__,
                             "AddProviderScreen")
            form = app.screen
            form.query_one("#label", Input).value = "Ming"
            form.query_one("#base-url", Input).value = Fixture.openai_url
            form.query_one("#api-key", Input).value = \
                "sk-tui-test-000000000000"
            await pilot.pause()
            await pilot.click("#add")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__, "ModelsScreen")
            note = rendered(app.screen.query_one("#catalog-note", Static))
            self.assertIn("does not offer gpt-6-astra", note)
            await pilot.press("enter")
            await pilot.pause()

            config = self.config_of(self.home)
            self.assertEqual(
                str(config["model_providers"]["OpenAI"]["name"]),
                "OpenAI-Ming")
            self.assertEqual(str(config.get("model")), BETA[0])
            self.assertEqual(str(config.get("model_catalog_json")),
                             "~/.codex/model-catalog.OpenAI-Ming.json")
            self.assertEqual(str(config.get("web_search")), "disabled")
            self.assertTrue(
                (self.home / "model-catalog.OpenAI-Ming.json").exists())
            metadata = json.loads(
                (self.home / "model-catalog.OpenAI-Ming.json").read_text())
            self.assertEqual(metadata["_codex_provider"]["web_search"], None)
            self.assertEqual(
                self.auth_of(self.home)["OPENAI_API_KEY"],
                "sk-tui-test-000000000000")
            self.assertIn("Using Ming", app_message(app))
            self.assertEqual(app_rows(app)[0][1], "Ming")
            self.assertEqual(
                app.state.providers[
                    app.query_one(DataTable).cursor_row].label, "Ming")

            await pilot.press("m")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__, "ModelsScreen")
            model_table = app.screen.query_one("#model-table", DataTable)
            self.assertEqual(model_table.row_count, len(BETA))
            model_table.move_cursor(row=1)
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            self.assertEqual(str(self.config_of(self.home).get("model")),
                             BETA[1])
            self.assertIn(f"Model set to {BETA[1]}", app_message(app))

            await self.select(pilot, "RelayA")
            await pilot.press("u")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__, "ModelsScreen")
            await pilot.press("escape")
            await pilot.pause()
            self.assertIn("Switch cancelled", app_message(app))
            self.assertEqual(app_labels(app)[0], "Ming")

            await pilot.press("u")
            await pilot.pause()
            await pilot.press("j")
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            config = self.config_of(self.home)
            self.assertEqual(
                str(config["model_providers"]["OpenAI"]["name"]),
                "OpenAI-RelayA")
            self.assertEqual(str(config.get("model")), "alpha-2")
            self.assertIn("Model set to alpha-2", app_message(app))
            self.assertNotIn("model_catalog_json", config)
            self.assertNotIn("web_search", config)
            self.assertEqual(
                str(config["model_providers"]["OpenAI"].get(
                    "model_catalog_url")), Fixture.codex_url + "/models")

            await self.select(pilot, "RelayB")
            await pilot.press("i")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__,
                             "ImportAuthScreen")
            app.screen.query_one("#api-key", Input).value = \
                "sk-imported-000000000000"
            await pilot.pause()
            await pilot.click("#save")
            await pilot.pause()
            snapshot = json.loads(
                (self.home / "auth.OpenAI-RelayB.json").read_text())
            self.assertEqual(snapshot["OPENAI_API_KEY"],
                             "sk-imported-000000000000")

            await self.select(pilot, "RelayB")
            await pilot.press("e")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__,
                             "EditEndpointScreen")
            app.screen.query_one("#url", Input).value = \
                "ftp://bad.example.com"
            await pilot.pause()
            await pilot.click("#save")
            await pilot.pause()
            self.assertIn(
                "http://",
                rendered(app.screen.query_one("#error", Static)))
            await pilot.press("escape")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__, "Screen")
            await pilot.press("e")
            await pilot.pause()
            app.screen.query_one("#url", Input).value = Fixture.codex_url
            await pilot.pause()
            await pilot.click("#save")
            await pilot.pause()
            relay_b = self.entry_named(self.home, "OpenAI-RelayB")
            self.assertEqual(str(relay_b.get("base_url")),
                             Fixture.codex_url)
            self.assertEqual(str(relay_b.get("model_catalog_url")),
                             Fixture.codex_url + "/models")

            await self.select(pilot, "RelayB")
            await pilot.press("d")
            await pilot.pause()
            self.assertEqual(type(app.screen).__name__, "ConfirmScreen")
            await pilot.click("#yes")
            await pilot.pause()
            names = [str(entry.get("name")) for entry in
                     self.config_of(self.home)["model_providers"].values()]
            self.assertNotIn("OpenAI-RelayB", names)
            self.assertTrue(
                (self.home / "auth.OpenAI-RelayB.json").exists())

            await self.select(pilot, "RelayA")
            await pilot.press("d")
            await pilot.pause()
            self.assertIn("active", app_message(app))
            self.assertEqual(len(app.screen.query(DataTable)), 1)

            await pilot.press("a")
            await pilot.pause()
            form = app.screen
            form.query_one("#label", Input).value = "Solo"
            form.query_one("#base-url", Input).value = Fixture.openai_url
            form.query_one("#method", Select).value = "none"
            await pilot.pause()
            self.assertFalse(form.query_one("#switch", Switch).value)
            await pilot.click("#add")
            await pilot.pause()
            self.assertIn("Solo", app_labels(app))
            self.assertIn("No auth saved yet", app_message(app))
            self.assertFalse(
                (self.home / "auth.OpenAI-Solo.json").exists())
            self.assertFalse(
                (self.home / "model-catalog.OpenAI-Solo.json").exists())
            self.assertEqual(
                str(self.config_of(self.home)
                    ["model_providers"]["OpenAI"]["name"]),
                "OpenAI-RelayA")

            await self.select(pilot, "Solo")
            await pilot.press("d")
            await pilot.pause()
            await pilot.press("y")
            await pilot.pause()
            names = [str(entry.get("name")) for entry in
                     self.config_of(self.home)["model_providers"].values()]
            self.assertNotIn("OpenAI-Solo", names)
            self.assertNotIn("Solo", app_labels(app))

            (self.home / "auth.OpenAI-Ext.json").write_text(
                '{"auth_mode": "apikey", '
                '"OPENAI_API_KEY": "sk-ext-000000000000"}')
            text = (self.home / "config.toml").read_text() + f'''
[model_providers.OpenAIExt]
name = "OpenAI-Ext"
base_url = "{Fixture.codex_url}"
wire_api = "responses"
requires_openai_auth = true
'''
            self.atomic_write(self.home / "config.toml", text)
            app.poll_files()
            await pilot.pause()
            self.assertIn("Ext", app_labels(app))
            self.assertIn("Reloaded", app_message(app))

            saved = (self.home / "config.toml").read_text()
            self.atomic_write(self.home / "config.toml",
                              "this is [not toml\n")
            app.poll_files()
            await pilot.pause()
            self.assertIn("Cannot load provider files", app_message(app))
            self.assertIsNone(app.state)
            self.assertEqual(app.query_one(DataTable).row_count, 0)
            self.atomic_write(self.home / "config.toml", saved)
            app.poll_files()
            await pilot.pause()
            self.assertGreater(len(app_labels(app)), 0)
            self.assertIn("* RelayA",
                          [row[0] + " " + row[1] for row in app_rows(app)])

            await pilot.press("q")


if __name__ == "__main__":
    unittest.main()
