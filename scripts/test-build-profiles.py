#!/usr/bin/env python3
import importlib.util, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_images", ROOT / "build-images.py")
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)

class ProfilesTest(unittest.TestCase):
    def test_catalog_layout(self):
        self.assertEqual({catalog for catalog, _ in m.KINDS.values()}, {
            "container-deps/dnf", "container-deps/apk", "container-deps/copr",
            "container-deps/repos", "container-deps/collections", "container-deps/containerfiles",
        })
        self.assertFalse((ROOT/"container-repos").exists())
        self.assertFalse((ROOT/"container-collections").exists())

    def test_real_membership(self):
        expected = ("default", *sorted(path.name for path in (ROOT/"container-profiles").iterdir() if path.is_dir() and path.name != "default"))
        self.assertEqual(m.discover_profiles(), expected)
        profiles = {name: m.read_profile(name) for name in expected}
        m.validate_profile_relationships(profiles)
        default, full = profiles["default"], profiles["full"]
        dp = sum((m.parse_dnf(p) for p in default.members["dnf"]), [])
        self.assertEqual(dp.count("bind-utils"), 1)
        self.assertEqual(sum(m.parse_dnf(p).count("python3-dateutil") for p in full.members["dnf"]), 1)
        self.assertNotIn("90-scad.dnf.nope", {p.name for p in full.members["dnf"]})

    def test_shared_stage_and_canonical_order(self):
        template = (ROOT/"Dockerfile.in").read_text()
        profiles = {name: m.read_profile(name) for name in m.discover_profiles()}
        common_stages = []
        for profile in profiles.values():
            if profile.distro != "fedora":
                continue
            text, _ = m.render(profile, template, common=profiles[profile.base_profile])
            common_stages.append(text[text.index("ARG FEDORA_VERSION="):text.index("FROM codex-common AS codex-profile")])
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
        profiles = {name: m.read_profile(name) for name in m.discover_profiles()}
        media_members = dict(profiles["media"].members)
        media_members["dnf"] = tuple(path for path in media_members["dnf"] if path.name != "50-python.dnf")
        profiles["media"] = m.Profile("media", media_members)
        with self.assertRaises(m.BuildError):
            m.validate_profile_relationships(profiles)

    def test_fdroid_is_optional_and_uses_shared_fragments(self):
        template = (ROOT/"Dockerfile.in").read_text()
        fdroid = m.read_profile("fdroid")
        text, _ = m.render(fdroid, template)
        final = text[text.index("FROM codex-common AS codex-profile"):]
        self.assertLess(final.index("80-fdroid.dnf"), final.index("ARG ANDROID_CMDLINE_TOOLS="))
        self.assertLess(final.index("ARG ANDROID_CMDLINE_TOOLS="), final.index("ARG FDROIDSERVER_VERSION="))
        self.assertLess(final.index("ARG FDROIDSERVER_VERSION="), final.index('USER "${USERNAME}"'))
        self.assertIn('test "${ANDROID_ACCEPT_LICENSES}" = 1', final)
        self.assertIn('sha256sum -c -', final)
        self.assertIn('"fdroidserver==${FDROIDSERVER_VERSION}"', final)
        self.assertIn('/opt/project-venv/bin:${PATH}:/opt/fdroid-venv/bin', final)
        for name in ("default", "full", "python"):
            other, _ = m.render(m.read_profile(name), template)
            self.assertNotIn("/opt/android-sdk", other)
            self.assertNotIn("/opt/fdroid-venv", other)

    def test_fragment_catalog_guards_and_shared_membership(self):
        temp, root = self.fixture()
        with temp:
            catalog = root/"container-deps/containerfiles"
            catalog.mkdir()
            (catalog/"sdk.containerfile").write_text("ENV SDK_HOME=/opt/sdk\n")
            directory = root/"container-profiles/default/containerfiles"
            directory.mkdir()
            member = directory/"sdk.containerfile"
            member.symlink_to("../../../container-deps/containerfiles/sdk.containerfile")
            common = m.read_profile("default", root)
            template = (ROOT/"Dockerfile.in").read_text()
            text, _ = m.render(common, template, root, common)
            self.assertEqual(text.count("ENV SDK_HOME=/opt/sdk"), 1)
            self.assertLess(text.index("ENV SDK_HOME=/opt/sdk"), text.index("FROM codex-common"))
            child = m.Profile("child", {**common.members, "containerfiles": ()})
            with self.assertRaises(m.BuildError):
                m.validate_profile_relationships({"default": common, "child": child})
            member.unlink()
            member.symlink_to("../../../Dockerfile.in")
            with self.assertRaises(m.BuildError):
                m.read_profile("default", root)
    def test_selectors(self):
        profiles = ("default", "full", "infra", "media", "python", "typesetting")
        self.assertEqual(m.selection([], profiles)[1], ("default",))
        self.assertEqual(m.selection(["--profile", "media,infra"], profiles)[1], ("media", "infra"))
        self.assertEqual(m.selection(["--all", "--no-profile", "full,media,typesetting"], profiles)[1], ("default", "infra", "python"))
        for args in (["--profile","bogus"],["--profile","infra,infra"],["--no-profile","infra"],["--all","--profile","infra"]):
            with self.assertRaises(SystemExit): m.selection(args, profiles)
    def test_profile_discovery_is_directory_driven(self):
        temp, root = self.fixture()
        with temp:
            custom = root/"container-profiles/typesetting/dnf"
            custom.mkdir(parents=True)
            (custom/"a.dnf").symlink_to("../../../container-deps/dnf/a.dnf")
            self.assertEqual(m.discover_profiles(root), ("default", "typesetting"))
            profiles = {name: m.read_profile(name, root) for name in m.discover_profiles(root)}
            m.validate_profile_relationships(profiles)
    def test_host_timezone_detection(self):
        self.assertEqual(m.detect_host_timezone({"TZ": "Europe/Prague"}), "Europe/Prague")
        with tempfile.TemporaryDirectory() as td:
            localtime = Path(td)/"localtime"
            localtime.symlink_to("../usr/share/zoneinfo/America/New_York")
            self.assertEqual(m.detect_host_timezone({}, localtime), "America/New_York")

    def test_fedora_version_and_cache_selection(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self.assertEqual(m.fedora_settings({}, root),
                             ("latest", root/".build-cache/dnf-fedora-latest"))
            self.assertEqual(m.fedora_settings({"FEDORA_VERSION": "99"}, root),
                             ("99", root/".build-cache/dnf-fedora-99"))
            self.assertEqual(m.fedora_settings({"FEDORA_VERSION": "rawhide", "DNF_CACHE_DIR": str(root/"custom")}, root),
                             ("rawhide", root/"custom"))
            for invalid in ("", "../45", "45/../../tmp", "45\nRUN false", "fedora:45"):
                with self.subTest(version=invalid), self.assertRaises(m.BuildError):
                    m.fedora_settings({"FEDORA_VERSION": invalid}, root)
    def test_alpine_build_and_parity(self):
        profile = m.read_profile("alpine")
        self.assertEqual((profile.distro, profile.base_profile), ("alpine", "alpine"))
        text, req = m.render(profile, (ROOT/"Dockerfile.in").read_text())
        self.assertIn("FROM alpine:${ALPINE_VERSION}", text)
        self.assertNotIn("dnf ", text)
        self.assertNotIn("fedora:", text)
        self.assertIn("apk --cache-dir /var/cache/apk add --update-cache", text)
        self.assertNotIn("--no-cache", text)
        self.assertIn('adduser -D -s /bin/bash "${USERNAME}"', text)
        self.assertIn('&& codex --version', text)
        self.assertIsNone(req)
        packages = [pkg for source in profile.members["apk"] for pkg in m.parse_dnf(source)]
        for package in ("bash", "coreutils", "nodejs", "npm", "github-cli", "git", "py3-pip", "age"):
            self.assertIn(package, packages)
        self.assertNotIn("aggregate", packages)  # Explicitly documented parity gap.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(m.alpine_settings({}, root), ("latest", root/".build-cache/apk-alpine-latest"))
            self.assertEqual(m.alpine_settings({"ALPINE_VERSION":"3.24", "APK_CACHE_DIR":directory}, root), ("3.24", root))
            with self.assertRaises(m.BuildError): m.alpine_settings({"ALPINE_VERSION":"../oops"}, root)

    def test_distro_metadata_and_relationship_guards(self):
        temp, root = self.fixture()
        with temp:
            directory = root/"container-profiles/default"
            metadata = directory/"profile.json"
            metadata.write_text('{"distro":"alpine", "base_profile":"default"}')
            with self.assertRaises(m.BuildError): m.read_profile("default", root)
            (root/"container-deps/apk").mkdir()
            (root/"container-deps/apk/base.apk").write_text("bash\n")
            (directory/"apk").mkdir()
            (directory/"apk/base.apk").symlink_to("../../../container-deps/apk/base.apk")
            with self.assertRaisesRegex(m.BuildError, "incompatible"):
                m.read_profile("default", root)
            metadata.write_text('{"distro":"unknown"}')
            with self.assertRaises(m.BuildError): m.read_profile("default", root)
            metadata.write_text('{"unexpected":true}')
            with self.assertRaises(m.BuildError): m.read_profile("default", root)
        default, alpine = m.read_profile("default"), m.read_profile("alpine")
        with self.assertRaises(m.BuildError):
            m.validate_profile_relationships({"default":default, "alpine":m.Profile("alpine", alpine.members, "alpine", "default")})
        with self.assertRaises(m.BuildError):
            m.render(alpine, (ROOT/"Dockerfile.in").read_text(), common=default)

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
