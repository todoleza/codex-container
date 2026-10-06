#!/usr/bin/env python3
import importlib.util, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_images", ROOT / "build-images.py")
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)

class ProfilesTest(unittest.TestCase):
    def test_catalog_layout(self):
        self.assertEqual({catalog for catalog, _ in m.KINDS.values()}, {
            "container-deps/dnf", "container-deps/copr",
            "container-deps/repos", "container-deps/collections",
        })
        self.assertFalse((ROOT/"container-repos").exists())
        self.assertFalse((ROOT/"container-collections").exists())

    def test_real_membership(self):
        self.assertEqual(m.discover_profiles(), m.PROFILE_ORDER)
        profiles = {name: m.read_profile(name) for name in m.PROFILE_ORDER}
        m.validate_profile_relationships(profiles)
        default, full = profiles["default"], profiles["full"]
        dp = sum((m.parse_dnf(p) for p in default.members["dnf"]), [])
        self.assertEqual(dp.count("bind-utils"), 1)
        self.assertEqual(sum(m.parse_dnf(p).count("python3-dateutil") for p in full.members["dnf"]), 1)
        self.assertNotIn("90-scad.dnf.nope", {p.name for p in full.members["dnf"]})

    def test_shared_stage_and_canonical_order(self):
        template = (ROOT/"Dockerfile.in").read_text()
        profiles = {name: m.read_profile(name) for name in m.PROFILE_ORDER}
        common_stages = []
        for profile in profiles.values():
            text, _ = m.render(profile, template, common=profiles["default"])
            common_stages.append(text[text.index("FROM fedora:44 AS codex-common"):text.index("FROM codex-common AS codex-profile")])
            final = text[text.index("FROM codex-common AS codex-profile"):]
            self.assertNotIn("CODEX_PACKAGE_VERSION", common_stages[-1])
            self.assertIn("CODEX_PACKAGE_VERSION", final)
        self.assertTrue(all(stage == common_stages[0] for stage in common_stages[1:]))

        full, _ = m.render(profiles["full"], template, common=profiles["default"])
        ordered = ["40-ansible.dnf", "41-podman.dnf", "42-hcloud.dnf", "50-python.dnf", "60-yt-dlp.dnf"]
        positions = [full.index(name, full.index("FROM codex-common AS codex-profile")) for name in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertLess(positions[-1], full.index("ansible-galaxy collection install"))

    def test_profile_relationship_validation(self):
        profiles = {name: m.read_profile(name) for name in m.PROFILE_ORDER}
        media_members = dict(profiles["media"].members)
        media_members["dnf"] = tuple(path for path in media_members["dnf"] if path.name != "50-python.dnf")
        profiles["media"] = m.Profile("media", media_members)
        with self.assertRaises(m.BuildError):
            m.validate_profile_relationships(profiles)
    def test_selectors(self):
        self.assertEqual(m.selection([], m.PROFILE_ORDER)[1], ("default",))
        self.assertEqual(m.selection(["--profile", "media,infra"], m.PROFILE_ORDER)[1], ("media", "infra"))
        self.assertEqual(m.selection(["--all", "--no-profile", "full,media"], m.PROFILE_ORDER)[1], ("default", "infra", "python"))
        for args in (["--profile","bogus"],["--profile","infra,infra"],["--no-profile","infra"],["--all","--profile","infra"]):
            with self.assertRaises(SystemExit): m.selection(args, m.PROFILE_ORDER)
    def fixture(self):
        temp = tempfile.TemporaryDirectory(); root = Path(temp.name)
        for d in ("container-deps/dnf","container-deps/copr","container-deps/repos","container-deps/collections","container-profiles/default/dnf"): (root/d).mkdir(parents=True, exist_ok=True)
        (root/"container-deps/dnf/a.dnf").write_text("one\n"); (root/"container-profiles/default/dnf/a.dnf").symlink_to("../../../container-deps/dnf/a.dnf")
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
                elif mode == "dangling": (d/"bad.dnf").symlink_to("../../../container-deps/dnf/missing.dnf")
                else: (d/"copy.dnf").symlink_to("../../../container-deps/dnf/a.dnf")
                with self.assertRaises(m.BuildError): m.read_profile("default", root)
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td)/"bad.copr"; bad.write_text("dnf install shell\n")
            with self.assertRaises(m.BuildError): m.parse_copr(bad)
    def test_render_and_atomic_overwrite(self):
        text, _ = m.render(m.read_profile("default"), (ROOT/"Dockerfile.in").read_text())
        self.assertIn("# Common membership: container-deps/dnf/10-agent-core.dnf", text)
        self.assertLess(text.index("10-agent-core.dnf"), text.index("20-agent-extended.dnf"))
        install_lines = [line for line in text.splitlines() if "dnf -y install" in line]
        self.assertTrue(install_lines)
        self.assertTrue(all(m.DNF_INSTALL_OPTIONS in line for line in install_lines))
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            copr = root/"example.copr"; copr.write_text("owner/project\n")
            members = {kind: () for kind in m.KINDS}; members["copr"] = (copr,)
            copr_steps = "\n".join(m.dependency_steps(members, root))
            self.assertIn(f"dnf -y install {m.DNF_INSTALL_OPTIONS} dnf5-plugins", copr_steps)
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/"Containerfile"; m.atomic_write(path,"one\n"); m.atomic_write(path,"two\n"); self.assertEqual(path.read_text(),"two\n")
if __name__ == "__main__": unittest.main()
