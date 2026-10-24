import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import unittest
from unittest import mock
from urllib.error import HTTPError


SCRIPT = Path(__file__).resolve().parents[1] / "todoready"
loader = importlib.machinery.SourceFileLoader("todoready", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
todoready = importlib.util.module_from_spec(spec)
loader.exec_module(todoready)


def package(name, **fields):
    return dict(pkgname=name, pkgbase=name, depends=[], makedepends=[], checkdepends=[],
                provides=[], status_str="Incomplete") | fields


def repository(packages):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for pkg in packages:
            fields = dict(NAME=[pkg["pkgname"]], BASE=[pkg["pkgbase"]])
            for field in (*todoready.DEPENDENCIES, "provides"):
                if pkg[field]:
                    fields[field.upper()] = pkg[field]
            text = "".join(f"%{key}%\n" + "\n".join(value) + "\n\n"
                           for key, value in fields.items())
            content = text.encode()
            member = tarfile.TarInfo(f'{pkg["pkgname"]}-1-1/desc')
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    return stream.getvalue()


class TodoReadyTest(unittest.TestCase):
    def test_all_dependency_types_wait_for_completion(self):
        for field in todoready.DEPENDENCIES:
            with self.subTest(field=field):
                dependency = package("dependency")
                consumer = package("consumer", **{field: ["dependency>=1"]})
                rows = [consumer, dependency]
                self.assertEqual(todoready.ready_pkgbases(rows, rows), ["dependency"])
                dependency["status_str"] = "Complete"
                self.assertEqual(todoready.ready_pkgbases(rows, rows), ["consumer"])

    def test_external_and_optional_dependencies_do_not_block(self):
        rows = [package("consumer", depends=["external"], makedepends=["external-make"],
                        checkdepends=["external-check"], optdepends=["unfinished"]),
                package("unfinished")]
        self.assertEqual(todoready.ready_pkgbases(rows, rows), ["consumer", "unfinished"])

    def test_only_runtime_dependencies_are_followed_beyond_first_level(self):
        for field in todoready.DEPENDENCIES:
            for indirect_field in todoready.DEPENDENCIES:
                with self.subTest(field=field, indirect_field=indirect_field):
                    rows = [package("consumer", **{field: ["external"]}), package("unfinished")]
                    external = package("external", **{indirect_field: ["unfinished>=1"]})
                    expected = ["unfinished"] if indirect_field == "depends" else ["consumer", "unfinished"]
                    self.assertEqual(todoready.ready_pkgbases(rows, rows + [external]), expected)
                    rows[1]["status_str"] = "Complete"
                    self.assertEqual(todoready.ready_pkgbases(rows, rows + [external]), ["consumer"])

    def test_completed_todo_dependencies_are_traversed(self):
        for field in todoready.DEPENDENCIES:
            with self.subTest(field=field):
                rows = [package("consumer", depends=["completed"]),
                        package("completed", status_str="Complete", **{field: ["unfinished"]}),
                        package("unfinished")]
                expected = ["unfinished"] if field == "depends" else ["consumer", "unfinished"]
                self.assertEqual(todoready.ready_pkgbases(rows, rows), expected)

    def test_make_and_check_dependencies_stay_excluded_at_deeper_levels(self):
        for field in ("makedepends", "checkdepends"):
            with self.subTest(field=field):
                rows = [package("consumer", checkdepends=["first"]), package("unfinished")]
                first = package("first", depends=["second"])
                second = package("second", **{field: ["unfinished"]})
                packages = rows + [first, second]
                self.assertEqual(todoready.ready_pkgbases(rows, packages), ["consumer", "unfinished"])
                second["depends"] = ["unfinished"]
                self.assertEqual(todoready.ready_pkgbases(rows, packages), ["unfinished"])

    def test_indirect_in_progress_dependency_blocks(self):
        rows = [package("consumer", depends=["external"]), package("busy", status_str="In-progress")]
        external = package("external", depends=["busy"])
        self.assertEqual(todoready.ready_pkgbases(rows, rows + [external]), [])

    def test_cycles_outside_todo_are_ready_unless_they_reach_an_unfinished_package(self):
        rows = [package("consumer", depends=["first"]), package("unfinished")]
        first = package("first", depends=["second"])
        second = package("second", depends=["first"])
        packages = rows + [first, second]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["consumer", "unfinished"])
        second["checkdepends"] = ["unfinished"]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["consumer", "unfinished"])
        second["makedepends"] = ["unfinished"]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["consumer", "unfinished"])
        second["depends"].append("unfinished")
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["unfinished"])

    def test_cycle_through_non_todo_package_back_to_candidate_blocks(self):
        rows = [package("consumer", depends=["external"])]
        external = package("external", depends=["consumer"])
        self.assertEqual(todoready.ready_pkgbases(rows, rows + [external]), [])

    def test_deep_dependency_chain(self):
        rows = [package("consumer", depends=["external-0"]), package("unfinished")]
        packages = rows + [package(f"external-{i}", depends=[f"external-{i + 1}"])
                           for i in range(1200)]
        packages.append(package("external-1200", depends=["unfinished"]))
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["unfinished"])

    def test_indirect_split_dependency_blocks(self):
        rows = [package("consumer", depends=["external"]), package("tool", pkgbase="source")]
        packages = rows + [package("external", depends=["library"]),
                           package("library", pkgbase="source")]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["source"])

    def test_unused_split_sibling_does_not_add_dependencies(self):
        library = package("library", pkgbase="source", status_str="Complete")
        for listed in (False, True):
            with self.subTest(listed=listed):
                rows = [package("consumer", depends=["library"]), package("unfinished")]
                if listed:
                    rows.append(library)
                packages = rows + [library, package("bindings", pkgbase="source", depends=["unfinished"])]
                self.assertEqual(todoready.ready_pkgbases(rows, packages), ["consumer", "unfinished"])

    def test_needed_split_sibling_dependencies_are_followed(self):
        rows = [package("consumer", depends=["library"]), package("unfinished")]
        packages = rows + [package("library", pkgbase="source", depends=["helper"]),
                           package("helper", pkgbase="source", depends=["unfinished"])]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["unfinished"])

    def test_default_virtual_provider_must_have_ready_dependency_tree(self):
        rows = [package("consumer", depends=["virtual"]), package("unfinished")]
        first = package("first", provides=["virtual"], depends=["external"])
        second = package("second", provides=["virtual"], depends=["unfinished"])
        external = package("external", depends=["unfinished"])
        packages = rows + [first, second, external]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["unfinished"])
        second["depends"] = []
        second["makedepends"] = ["unfinished"]
        second["checkdepends"] = ["unfinished"]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["unfinished"])
        first["depends"] = []
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["consumer", "unfinished"])

    def test_in_progress_is_neither_ready_nor_complete(self):
        rows = [package("busy", status_str="In-progress"),
                package("consumer", depends=["busy"]), package("ready")]
        self.assertEqual(todoready.ready_pkgbases(rows, rows), ["ready"])

    def test_cycles_remain_blocked(self):
        rows = [package("first", checkdepends=["second"]),
                package("second", depends=["first"])]
        self.assertEqual(todoready.ready_pkgbases(rows, rows), [])

    def test_split_siblings_missing_from_todo_still_block_consumers(self):
        rows = [package("tool", pkgbase="source"),
                package("consumer", depends=["library=1"])]
        packages = rows + [package("library", pkgbase="source")]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["source"])
        rows[0]["status_str"] = "Complete"
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["consumer"])

    def test_all_split_sibling_dependencies_are_checked(self):
        rows = [package("tool", pkgbase="source"), package("dependency")]
        sibling = package("library", pkgbase="source", checkdepends=["dependency"])
        self.assertEqual(todoready.ready_pkgbases(rows, rows + [sibling]), ["dependency"])

    def test_split_output_is_unique_and_internal_dependencies_do_not_block(self):
        rows = [package("tool", pkgbase="source", depends=["library=1"]),
                package("library", pkgbase="source", checkdepends=["tool"])]
        self.assertEqual(todoready.ready_pkgbases(rows, rows), ["source"])

    def test_partially_complete_split_build_still_blocks_consumers(self):
        rows = [package("tool", pkgbase="source", status_str="Complete"),
                package("library", pkgbase="source"), package("consumer", depends=["tool"])]
        self.assertEqual(todoready.ready_pkgbases(rows, rows), ["source"])
        rows[0]["status_str"] = "In-progress"
        self.assertEqual(todoready.ready_pkgbases(rows, rows), [])

    def test_versioned_provides_from_an_unlisted_split_sibling(self):
        rows = [package("tool", pkgbase="source"),
                package("consumer", depends=["libexample.so=1-64"])]
        sibling = package("library", pkgbase="source", provides=["libexample.so=1-64"])
        self.assertEqual(todoready.ready_pkgbases(rows, rows + [sibling]), ["source"])

    def test_ready_nondefault_virtual_provider_does_not_unblock_dependency(self):
        rows = [package("a-provider", provides=["virtual=1"]),
                package("consumer", depends=["virtual>=1"])]
        self.assertEqual(todoready.ready_pkgbases(rows, rows), ["a-provider"])
        completed = package("z-completed", provides=["virtual=1"], status_str="Complete")
        self.assertEqual(todoready.ready_pkgbases(rows + [completed], rows + [completed]),
                         ["a-provider"])
        external = package("z-external", provides=["virtual=1"])
        self.assertEqual(todoready.ready_pkgbases(rows, rows + [external]),
                         ["a-provider"])

    def test_arti_waits_for_rust_despite_rustup_providing_cargo(self):
        rows = [package("arti", makedepends=["cargo"]),
                package("openssl", status_str="Complete", provides=["libssl.so=4-64"]),
                package("rust", provides=["cargo"], depends=["openssl", "libssl.so=3-64"])]
        packages = rows + [package("rustup", provides=["cargo"])]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["rust"])
        rows[2]["status_str"] = "Complete"
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["arti"])

    def test_repository_priority_precedes_provider_name(self):
        first = package("z-provider", provides=["virtual"])
        second = package("a-provider", provides=["virtual"])
        consumer = package("consumer", depends=["virtual"])
        rows = [consumer, first]
        self.assertEqual(todoready.ready_pkgbases(rows, [first, second, consumer]), ["z-provider"])
        self.assertEqual(todoready.ready_pkgbases(rows, [second, consumer, first]),
                         ["consumer", "z-provider"])

    def test_archive_order_does_not_change_default_provider(self):
        first = package("a-provider", provides=["virtual"])
        second = package("z-provider", provides=["virtual"])
        consumer = package("consumer", depends=["virtual"])
        packages = todoready.read_repository(io.BytesIO(repository([second, consumer, first])))
        self.assertEqual(todoready.ready_pkgbases([consumer, first], packages), ["a-provider"])

    def test_first_repository_wins_for_duplicate_packages(self):
        rows = [package("consumer", depends=["external"]), package("unfinished")]
        packages = rows + [package("external", depends=["unfinished"]), package("external")]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["unfinished"])

    def test_explicit_package_takes_priority_over_virtual_providers(self):
        rows = [package("dependency"), package("consumer", depends=["dependency"])]
        external = package("external", provides=["dependency"])
        self.assertEqual(todoready.ready_pkgbases(rows, [external] + rows), ["dependency"])

    def test_todo_metadata_overrides_older_mirror_metadata(self):
        rows = [package("consumer", depends=["dependency"]), package("dependency")]
        packages = [package("consumer"), package("dependency")]
        self.assertEqual(todoready.ready_pkgbases(rows, packages), ["dependency"])

    def test_removed_packages_and_empty_todos(self):
        row = package("ready")
        self.assertEqual(todoready.ready_pkgbases([None, row], [row]), ["ready"])
        self.assertEqual(todoready.ready_pkgbases([], []), [])

    def test_missing_metadata_and_unknown_status_are_errors(self):
        with self.assertRaisesRegex(ValueError, "missing from repository metadata.*missing"):
            todoready.ready_pkgbases([package("missing")], [])
        unknown = package("unknown", status_str="Surprise")
        with self.assertRaisesRegex(ValueError, "unknown todo status"):
            todoready.ready_pkgbases([unknown], [unknown])

    def test_page_and_json_urls_use_current_api_without_filters(self):
        for path in ("/todo/example", "/todo/example/", "/todo/example/json",
                     "/todo/example/json/", "/api/v1/todo/example/"):
            with self.subTest(path=path):
                self.assertEqual(todoready.todo_api_url("https://archlinux.org" + path + "?incomplete=1#list"),
                                 "https://archlinux.org/api/v1/todo/example/")
        with self.assertRaisesRegex(ValueError, "expected an Arch todo URL"):
            todoready.todo_api_url("file:///todo/example/")

    def test_repository_archive_preserves_dependencies_and_provides(self):
        pkg = package("split", pkgbase="source", depends=["runtime>=2"],
                      makedepends=["compiler"], checkdepends=["tester"], provides=["virtual=1"])
        actual = todoready.read_repository(io.BytesIO(repository([pkg])))
        self.assertEqual(actual, [{key: value for key, value in pkg.items() if key != "status_str"}])

    def test_command_fetches_todo_and_repositories_and_prints_only_ready_bases(self):
        rows = [package("consumer", depends=["external"]), package("tool", pkgbase="source")]
        payloads = {"https://archlinux.org/api/v1/todo/example/": json.dumps({"packages": rows}).encode()}
        for repo, packages in zip(todoready.REPOSITORIES,
                                  ([package("external", depends=["library"])],
                                   rows + [package("library", pkgbase="source")],
                                   [package("lib32-external")])):
            payloads[f"{todoready.MIRROR}/{repo}/os/x86_64/{repo}.db"] = repository(packages)

        def fetch(url, timeout):
            self.assertEqual(timeout, 30)
            return io.BytesIO(payloads[url])

        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(todoready, "urlopen", side_effect=fetch) as request:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                status = todoready.main(["https://archlinux.org/todo/example/"])
        self.assertEqual(status, 0, errors.getvalue())
        self.assertEqual(output.getvalue(), "source\n")
        self.assertEqual(errors.getvalue(), "")
        self.assertCountEqual([call.args[0] for call in request.call_args_list], payloads)

    def test_failed_fetch_does_not_produce_a_partial_ready_list(self):
        error = HTTPError("https://archlinux.org/", 503, "Service unavailable", {}, None)
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(todoready, "urlopen", side_effect=error):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                status = todoready.main(["https://archlinux.org/todo/example/"])
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("503", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
