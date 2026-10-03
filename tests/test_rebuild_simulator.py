import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


class RebuildSimulatorTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.dbpath = Path(self.directory.name)
        (self.dbpath / "sync").mkdir()
        self.packages = []

    def add_package(self, name, **metadata):
        self.packages.append(dict(name=name, base=name, version="1-1", arch="x86_64") | metadata)

    def write_database(self):
        with tarfile.open(self.dbpath / "sync" / "extra.db", "w:gz") as database:
            for package in self.packages:
                description = ""
                for field, values in package.items():
                    if isinstance(values, str):
                        values = [values]
                    description += f"%{field.upper()}%\n" + "\n".join(values) + "\n\n"
                content = description.encode()
                entry = tarfile.TarInfo(f'{package["name"]}-1-1/desc')
                entry.size = len(content)
                database.addfile(entry, io.BytesIO(content))

    def run_simulator(self, *args, expected_status=0):
        self.write_database()
        harness = """
import pyalpm
import runpy
import sys
from unittest.mock import patch

handle = pyalpm.Handle('.', sys.argv.pop(1))
script = sys.argv.pop(1)
sys.argv[0] = script
with patch('pyalpm.Handle', return_value=handle):
    runpy.run_path(script, run_name='__main__')
"""
        result = subprocess.run(
            [sys.executable, "-c", harness, str(self.dbpath), str(REPOSITORY / "rebuild-simulator"), *args],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, expected_status, result.stderr)
        return result.stderr

    def test_ghc_rebuild_marks_ghc_libs_dependents_broken(self):
        self.add_package("ghc", depends=["ghc-libs"])
        self.add_package("ghc-libs", base="ghc")
        self.add_package("alex", depends=["ghc-libs"])
        self.add_package("haskell-base-orphans", depends=["ghc-libs"])
        output = self.run_simulator("-1", "ghc", "alex", "haskell-base-orphans")
        for dependent in ("alex", "haskell-base-orphans"):
            warning = f"Package {dependent} is broken after rebuilding ghc"
            self.assertIn(warning, output)
            self.assertLess(output.index(warning), output.index("Rebuilding alex"))
        self.assertIn("Rebuild finished successfully.", output)
        self.assertNotIn("Package ghc is broken", output)

    def test_split_package_and_pkgbase_inputs_share_broken_state(self):
        self.add_package("source-lib", base="source")
        self.add_package("source-tools", base="source", depends=["source-lib=1"])
        self.add_package("client-lib", base="client", depends=["source-tools>=1"])
        for root in ("source", "source-lib", "source-tools"):
            for dependent in ("client", "client-lib"):
                with self.subTest(root=root, dependent=dependent):
                    output = self.run_simulator("-1", root, dependent)
                    self.assertIn("Package client is broken after rebuilding source", output)
                    self.assertIn("Rebuild finished successfully.", output)
                    self.assertNotIn("Package source is broken", output)

    def test_transitive_split_dependents_are_broken_immediately(self):
        self.add_package("root-lib", base="root")
        self.add_package("middle-lib", base="middle", depends=["root-lib"])
        self.add_package("leaf-lib", base="leaf", depends=["middle-lib"])
        output = self.run_simulator("-1", "root", "leaf", "middle", expected_status=1)
        self.assertIn("Package middle is broken after rebuilding root", output)
        self.assertIn("Package leaf is broken after rebuilding root", output)
        self.assertIn("Package middle is broken, cannot rebuild leaf!", output)
        self.assertNotIn("Rebuilding middle", output)

    def test_all_split_dependency_fields_are_checked(self):
        self.add_package("root")
        self.add_package("library-lib", base="library", depends=["root"])
        self.add_package("target-lib", base="target")
        for field in ("depends", "makedepends", "checkdepends"):
            with self.subTest(field=field):
                self.add_package("target-tools", base="target", **{field: ["library-lib>=1"]})
                output = self.run_simulator("-1", "root", "target", "library", expected_status=1)
                self.assertIn("Package library is broken, cannot rebuild target!", output)
                self.packages.pop()

    def test_rebuilding_one_split_member_repairs_all_siblings(self):
        self.add_package("root")
        self.add_package("library-lib", base="library", depends=["root"])
        self.add_package("library-tools", base="library", depends=["library-lib"])
        self.add_package("client", depends=["library-tools"])
        output = self.run_simulator("-1", "root", "library-lib", "client")
        self.assertIn("Package library is broken after rebuilding root", output)
        self.assertIn("Package client is broken after rebuilding root", output)
        self.assertNotIn("CRITICAL", output)
        self.assertIn("Rebuild finished successfully.", output)

    def test_nocheck_ignores_split_check_dependencies(self):
        self.add_package("root")
        self.add_package("library-lib", base="library", depends=["root"])
        self.add_package("target-lib", base="target", checkdepends=["library-lib=1"])
        output = self.run_simulator("-1", "root", "target-lib:nocheck", "library", "target")
        self.assertNotIn("CRITICAL", output)
        self.assertIn("Rebuild finished successfully.", output)

    def test_nocheck_only_packages_are_tracked(self):
        self.add_package("root-lib", base="root")
        self.add_package("client-lib", base="client", depends=["root-lib"])
        output = self.run_simulator("-1", "root:nocheck", "client-lib:nocheck")
        self.assertIn("Package client is broken after rebuilding root", output)
        self.assertIn("Rebuild finished successfully.", output)

    def test_make_dependencies_only_skipped_with_make_as_check_option(self):
        self.add_package("root")
        self.add_package("library-lib", base="library", depends=["root"])
        self.add_package("target-lib", base="target", makedepends=["library-lib"])
        order = ("root", "target-lib:nocheck", "library", "target")
        output = self.run_simulator("-1", *order, expected_status=1)
        self.assertIn("Package library is broken, cannot rebuild target!", output)
        output = self.run_simulator("-1", "-M", *order)
        self.assertNotIn("CRITICAL", output)
        self.assertIn("Rebuild finished successfully.", output)

    def test_unrepaired_split_package_is_reported_at_end(self):
        self.add_package("root-lib", base="root")
        self.add_package("client-lib", base="client", depends=["root-lib"])
        output = self.run_simulator("client", "root")
        self.assertIn("Package client is still broken after rebuild finished!", output)
        self.assertNotIn("Rebuild finished successfully.", output)

    def test_genrebuild_split_cycle_order_can_be_simulated(self):
        self.add_package("first-lib", base="first-source", checkdepends=["second-lib"])
        self.add_package("first-tools", base="first-source", depends=["first-lib"])
        self.add_package("second-lib", base="second-source", depends=["first-tools"])
        self.write_database()
        generated = subprocess.run(
            [sys.executable, str(REPOSITORY / "genrebuild"), "--dbpath", str(self.dbpath), "--db", "extra",
             "-e", "-c", "first-lib"],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)
        output = self.run_simulator("-1", *generated.stdout.split())
        self.assertIn("Rebuilding first-source:nocheck", output)
        self.assertNotIn("CRITICAL", output)
        self.assertIn("Rebuild finished successfully.", output)


if __name__ == "__main__":
    unittest.main()
