import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


GENREBUILD = Path(__file__).resolve().parents[1] / "genrebuild"


class GenrebuildTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.dbpath = Path(self.directory.name)
        (self.dbpath / "sync").mkdir()
        self.packages = []

    def add_package(self, name, **metadata):
        self.packages.append(dict(name=name, base=name, version="1-1", arch="x86_64") | metadata)

    def run_genrebuild(self, *args):
        with tarfile.open(self.dbpath / "sync" / "test.db", "w:gz") as database:
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
        result = subprocess.run(
            [sys.executable, str(GENREBUILD), "--dbpath", str(self.dbpath), "--db", "test", *args],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.split()

    def test_haskell_rebuild_from_compiler_includes_arch_any_library(self):
        self.add_package("ghc", depends=["ghc-libs"])
        self.add_package("ghc-libs", base="ghc", depends=["gmp"])
        self.add_package("ghc-static", base="ghc", depends=["ghc"])
        self.add_package("haskell-gi-overloading", arch="any", depends=["ghc-libs"], makedepends=["ghc"])
        self.add_package("haskell-client", depends=["ghc-libs", "haskell-gi-overloading"])
        self.add_package("non-haskell", depends=["haskell-gi-overloading"])
        self.assertEqual(self.run_genrebuild("-H", "ghc-libs"),
                         ["ghc", "haskell-gi-overloading", "haskell-client"])

    def test_arch_any_haskell_root_expands(self):
        self.add_package("haskell-gi-overloading", arch="any", depends=["ghc-libs"])
        self.add_package("haskell-client", depends=["ghc-libs", "haskell-gi-overloading"])
        self.assertEqual(self.run_genrebuild("-H", "haskell-gi-overloading"),
                         ["haskell-gi-overloading", "haskell-client"])

    def test_haskell_expansion_includes_arch_any_reverse_dependency(self):
        self.add_package("haskell-root", depends=["ghc-libs"])
        self.add_package("haskell-any", arch="any", depends=["ghc-libs", "haskell-root"])
        self.add_package("haskell-client", depends=["ghc-libs", "haskell-any"])
        self.add_package("non-haskell", arch="any", depends=["haskell-root"])
        self.assertEqual(self.run_genrebuild("-H", "haskell-root"),
                         ["haskell-root", "haskell-any", "haskell-client"])

    def test_split_packages_are_one_build_with_all_sibling_dependents(self):
        self.add_package("split-lib", base="split-source", depends=["ghc-libs"])
        self.add_package("split-tools", base="split-source", depends=["ghc-libs", "split-lib=1"])
        self.add_package("client", depends=["ghc-libs", "split-tools>=1"])
        for roots in (("split-lib",), ("split-tools",), ("split-source",), ("split-lib", "split-tools")):
            with self.subTest(roots=roots):
                self.assertEqual(self.run_genrebuild("-H", *roots), ["split-source", "client"])

    def test_pkgname_outputs_all_split_packages_once_per_build(self):
        self.add_package("split-tools", base="split-source", depends=["ghc-libs", "split-lib=1"])
        self.add_package("split-lib", base="split-source", depends=["ghc-libs"])
        self.add_package("client", depends=["ghc-libs", "split-tools>=1"])
        for option in ("-n", "--pkgname"):
            for roots in (("split-lib",), ("split-source",), ("split-lib", "split-tools")):
                with self.subTest(option=option, roots=roots):
                    self.assertEqual(self.run_genrebuild(option, "-H", *roots),
                                     ["split-lib", "split-tools", "client"])

    def test_pkgname_preserves_merged_dependency_order(self):
        self.add_package("root")
        self.add_package("split-lib", base="a-source", depends=["root"])
        self.add_package("split-tools", base="a-source", depends=["z-dependency"])
        self.add_package("z-dependency", depends=["root"])
        self.add_package("client", depends=["split-lib"])
        self.assertEqual(self.run_genrebuild("--pkgname", "-e", "root"),
                         ["root", "z-dependency", "split-lib", "split-tools", "client"])

    def test_pkgname_preserves_nocheck_and_repeated_builds(self):
        self.add_package("first-lib", base="first-source", checkdepends=["second-lib"])
        self.add_package("first-tools", base="first-source", depends=["first-lib"])
        self.add_package("second-lib", base="second-source", depends=["first-tools"])
        self.assertEqual(self.run_genrebuild("--pkgname", "-e", "-c", "first-lib"),
                         ["first-lib:nocheck", "first-tools:nocheck", "second-lib",
                          "first-lib", "first-tools", "second-lib"])

    def test_pkgname_excludes_ignored_split_packages(self):
        self.add_package("split-lib", base="split-source")
        self.add_package("split-tools", base="split-source")
        self.assertEqual(self.run_genrebuild("--pkgname", "--ignore", "split-tools", "split-lib"),
                         ["split-lib"])

    def test_pkgname_preserves_additional_dependencies_missing_from_database(self):
        self.add_package("split-lib", base="split-source")
        self.assertEqual(self.run_genrebuild("--pkgname", "--dep", "split-lib:external", "split-lib"),
                         ["external", "split-lib"])

    def test_pkgname_falls_back_to_name_when_base_is_missing(self):
        self.add_package("standalone", base="")
        self.assertEqual(self.run_genrebuild("--pkgname", "standalone"), ["standalone"])

    def test_split_package_dependencies_are_merged_before_ordering(self):
        self.add_package("root")
        self.add_package("split-lib", base="a-source", depends=["root"])
        self.add_package("split-tools", base="a-source", depends=["z-dependency"])
        self.add_package("z-dependency", depends=["root"])
        self.add_package("client", depends=["split-lib"])
        self.assertEqual(self.run_genrebuild("-e", "root"),
                         ["root", "z-dependency", "a-source", "client"])

    def test_split_package_virtual_provides_are_preserved(self):
        self.add_package("split-lib", base="split-source", provides=["virtual-lib=1"])
        self.add_package("split-tools", base="split-source")
        self.add_package("client", depends=["virtual-lib>=1"])
        self.assertEqual(self.run_genrebuild("-e", "split-tools"), ["split-source", "client"])

    def test_make_and_check_dependencies_use_bases(self):
        self.add_package("split-lib", base="split-source")
        self.add_package("make-user", base="make-source", makedepends=["split-lib>=1"])
        self.add_package("check-user", base="check-source", checkdepends=["split-lib=1"])
        self.add_package("indirect-user", base="indirect-source", makedepends=["make-user"])
        self.assertEqual(self.run_genrebuild("-m", "-c", "--only-explicit-make-and-check", "split-lib"),
                         ["split-source", "check-source", "make-source"])
        self.assertEqual(self.run_genrebuild("-m", "-c", "split-lib"),
                         ["split-source", "check-source", "make-source", "indirect-source"])

    def test_additional_dependencies_use_bases(self):
        self.add_package("first-lib", base="a-source")
        self.add_package("second-lib", base="z-source")
        self.assertEqual(self.run_genrebuild("--dep", "first-lib:second-lib", "first-lib", "second-lib"),
                         ["z-source", "a-source"])

    def test_split_package_cycles_preserve_nocheck_bootstrap(self):
        self.add_package("first-lib", base="first-source", checkdepends=["second-lib"])
        self.add_package("first-tools", base="first-source", depends=["first-lib"])
        self.add_package("second-lib", base="second-source", depends=["first-tools"])
        self.assertEqual(self.run_genrebuild("-e", "-c", "first-lib"),
                         ["first-source:nocheck", "second-source", "first-source", "second-source"])

    def test_ignored_split_package_is_not_merged(self):
        self.add_package("split-lib", base="split-source")
        self.add_package("split-tools", base="split-source")
        self.add_package("client", depends=["split-tools"])
        self.assertEqual(self.run_genrebuild("-e", "--ignore", "split-tools", "split-lib"), ["split-source"])

    def test_haskell_tool_with_library_sibling_still_expands(self):
        self.add_package("happy", base="happy-source", depends=["ghc-libs", "happy-lib"])
        self.add_package("happy-lib", base="happy-source", depends=["ghc-libs"])
        self.add_package("haskell-client", depends=["ghc-libs", "happy-lib"])
        self.assertEqual(self.run_genrebuild("-H", "happy"), ["happy-source", "haskell-client"])

    def test_standalone_haskell_tool_does_not_expand(self):
        self.add_package("happy", base="happy-source", depends=["ghc-libs"])
        self.add_package("haskell-client", depends=["ghc-libs"], makedepends=["happy"])
        self.assertEqual(self.run_genrebuild("-H", "happy"), ["happy-source"])

    def test_real_haskell_make_dependencies_remain_hard_after_merging(self):
        self.add_package("happy", base="happy-source", depends=["ghc-libs"], checkdepends=["haskell-client"])
        self.add_package("haskell-client", depends=["ghc-libs"], makedepends=["happy"])
        self.assertEqual(self.run_genrebuild("-H", "happy", "haskell-client"),
                         ["happy-source:nocheck", "haskell-client", "happy-source"])

    def test_unsplit_packages_keep_alphabetical_order(self):
        self.add_package("root")
        self.add_package("z-client", depends=["root"])
        self.add_package("a-client", depends=["root"])
        self.assertEqual(self.run_genrebuild("-e", "root"), ["root", "a-client", "z-client"])


if __name__ == "__main__":
    unittest.main()
