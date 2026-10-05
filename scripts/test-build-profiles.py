#!/usr/bin/env python3
import importlib.util, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_images", ROOT / "build-images.py")
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)

class ProfilesTest(unittest.TestCase):
    def test_real_membership(self):
        self.assertEqual(m.discover_profiles(), m.PROFILE_ORDER)
        default, full = m.read_profile("default"), m.read_profile("full")
        dp = sum((m.parse_dnf(p) for p in default.members["dnf"]), [])
        self.assertEqual(dp.count("bind-utils"), 1)
        self.assertEqual(sum(m.parse_dnf(p).count("python3-dateutil") for p in full.members["dnf"]), 1)
        self.assertNotIn("41-scad.dnf.nope", {p.name for p in full.members["dnf"]})
    def test_selectors(self):
        self.assertEqual(m.selection([], m.PROFILE_ORDER)[1], ("default",))
        self.assertEqual(m.selection(["--profile", "media,infra"], m.PROFILE_ORDER)[1], ("media", "infra"))
        self.assertEqual(m.selection(["--all", "--no-profile", "full,media"], m.PROFILE_ORDER)[1], ("default", "infra", "python"))
        for args in (["--profile","bogus"],["--profile","infra,infra"],["--no-profile","infra"],["--all","--profile","infra"]):
            with self.assertRaises(SystemExit): m.selection(args, m.PROFILE_ORDER)
    def fixture(self):
        temp = tempfile.TemporaryDirectory(); root = Path(temp.name)
        for d in ("container-deps","container-repos","container-collections","container-profiles/default/dnf"): (root/d).mkdir(parents=True, exist_ok=True)
        (root/"container-deps/a.dnf").write_text("one\n"); (root/"container-profiles/default/dnf/a.dnf").symlink_to("../../../container-deps/a.dnf")
        return temp, root
    def test_symlink_guards_and_bak_exclusion(self):
        temp, root = self.fixture()
        with temp:
            (root/"container-deps.bak").mkdir(); (root/"container-deps.bak/evil.dnf").write_text("evil\n")
            self.assertEqual(m.read_profile("default", root).members["dnf"][0].name, "a.dnf")
            (root/"container-profiles/default/dnf/a.dnf").unlink(); (root/"container-profiles/default/dnf/a.dnf").symlink_to("../../../container-deps.bak/evil.dnf")
            with self.assertRaises(m.BuildError): m.read_profile("default", root)
    def test_bad_members_and_copr(self):
        for mode in ("regular","dangling","duplicate"):
            temp, root = self.fixture()
            with temp:
                d = root/"container-profiles/default/dnf"
                if mode == "regular": (d/"bad.dnf").write_text("two\n")
                elif mode == "dangling": (d/"bad.dnf").symlink_to("../../../container-deps/missing.dnf")
                else: (d/"copy.dnf").symlink_to("../../../container-deps/a.dnf")
                with self.assertRaises(m.BuildError): m.read_profile("default", root)
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td)/"bad.copr"; bad.write_text("dnf install shell\n")
            with self.assertRaises(m.BuildError): m.parse_copr(bad)
    def test_render_and_atomic_overwrite(self):
        text, _ = m.render(m.read_profile("default"), (ROOT/"Dockerfile.in").read_text())
        self.assertLess(text.index("10-agent-core.dnf"), text.index("20-agent-extended.dnf"))
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/"Containerfile"; m.atomic_write(path,"one\n"); m.atomic_write(path,"two\n"); self.assertEqual(path.read_text(),"two\n")
if __name__ == "__main__": unittest.main()
