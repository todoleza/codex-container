#!/usr/bin/env python3
"""Generate retained profile Containerfiles and build Codex images."""
from __future__ import annotations

import argparse, json, os, re, subprocess, sys, tarfile, tempfile, uuid
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE_PROFILE = "default"
PROFILE_RELATIONSHIPS = (("python", "media"), ("python", "full"), ("media", "full"), ("infra", "full"))
KINDS = {"apk": ("container-deps/apk", {".apk"}), "dnf": ("container-deps/dnf", {".dnf"}), "copr": ("container-deps/copr", {".copr"}),
         "repos": ("container-deps/repos", {".repo"}), "collections": ("container-deps/collections", {".yml", ".yaml"}),
         "containerfiles": ("container-deps/containerfiles", {".containerfile"})}
COPR_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\s+[A-Za-z0-9_.:+-]+)?$")
PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.:*?-]*$")
MEMBER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PROFILE_RE = MEMBER_RE
DNF_INSTALL_OPTIONS = "--setopt=install_weak_deps=False --setopt=keepcache=True"

def fedora_settings(environment: dict[str, str], root: Path = ROOT) -> tuple[str, Path]:
    version = environment.get("FEDORA_VERSION", "latest")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", version):
        fail(f"invalid FEDORA_VERSION image tag: {version!r}")
    cache = Path(environment.get("DNF_CACHE_DIR", root / f".build-cache/dnf-fedora-{version}")).resolve()
    return version, cache

def alpine_settings(environment: dict[str, str], root: Path = ROOT) -> tuple[str, Path]:
    version = environment.get("ALPINE_VERSION") or "latest"
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", version):
        fail(f"invalid ALPINE_VERSION image tag: {version!r}")
    cache = Path(environment.get("APK_CACHE_DIR") or root / f".build-cache/apk-alpine-{version}").resolve()
    return version, cache

class BuildError(RuntimeError): pass

@dataclass(frozen=True)
class Profile:
    name: str
    members: dict[str, tuple[Path, ...]]
    distro: str = "fedora"
    base_profile: str = "default"

def fail(message: str): raise BuildError(message)
def content_lines(path: Path) -> list[str]:
    return [v for raw in path.read_text().splitlines() if (v := raw.split("#", 1)[0].strip())]
def parse_dnf(path: Path) -> list[str]:
    values = content_lines(path)
    if not values: fail(f"{path} lists no packages")
    if any(not PACKAGE_RE.fullmatch(v) for v in values): fail(f"invalid package declaration in {path}")
    return values
def parse_copr(path: Path) -> tuple[str, str | None]:
    lines = content_lines(path)
    if len(lines) != 1 or not COPR_RE.fullmatch(lines[0]): fail(f"invalid COPR declaration in {path}; expected OWNER/PROJECT [CHROOT]")
    parts = lines[0].split(); return parts[0], parts[1] if len(parts) == 2 else None

def discover_profiles(root: Path = ROOT) -> tuple[str, ...]:
    base = root / "container-profiles"
    found = {p.name for p in base.iterdir() if p.is_dir()} if base.is_dir() else set()
    if invalid := {name for name in found if not PROFILE_RE.fullmatch(name)}:
        fail(f"invalid profile directory names: {', '.join(sorted(invalid))}")
    if BASE_PROFILE not in found:
        fail(f"missing base profile: {BASE_PROFILE}")
    return (BASE_PROFILE, *sorted(found - {BASE_PROFILE}))

def read_profile(name: str, root: Path = ROOT) -> Profile:
    metadata_file = root / "container-profiles" / name / "profile.json"
    metadata = {}
    if metadata_file.exists():
        try: metadata = json.loads(metadata_file.read_text())
        except (ValueError, OSError) as exc: fail(f"invalid profile metadata for {name}: {exc}")
        if not isinstance(metadata, dict) or set(metadata) - {"distro", "base_profile"}:
            fail(f"unsupported profile metadata for {name}")
    distro = metadata.get("distro", "fedora")
    parent = metadata.get("base_profile", "default")
    if not isinstance(distro, str) or distro not in {"fedora", "alpine"}: fail(f"unsupported profile distro: {distro}")
    if not isinstance(parent, str) or not PROFILE_RE.fullmatch(parent): fail(f"invalid base profile: {parent}")
    members, package_owner = {}, {}
    for kind, (catalog_name, extensions) in KINDS.items():
        catalog = (root / catalog_name).resolve(); directory = root / "container-profiles" / name / kind; selected = []
        if directory.exists():
            if not directory.is_dir(): fail(f"{directory.relative_to(root)} is not a directory")
            for link in sorted(directory.iterdir()):
                rel = link.relative_to(root)
                if not link.is_symlink(): fail(f"profile member must be a symlink: {rel}")
                if not MEMBER_RE.fullmatch(link.name): fail(f"invalid profile member name: {rel}")
                if Path(os.readlink(link)).is_absolute(): fail(f"profile symlink must be relative: {rel}")
                if link.suffix not in extensions: fail(f"invalid {kind} profile extension: {rel}")
                target = link.resolve(strict=False)
                try: target.relative_to(catalog)
                except ValueError: fail(f"profile symlink escapes {catalog_name}: {rel}")
                if not target.is_file(): fail(f"dangling or non-file profile symlink: {rel}")
                if target.suffix not in extensions: fail(f"profile target has invalid extension: {rel}")
                selected.append(target)
        if len(selected) != len(set(selected)): fail(f"profile {name} contains duplicate {kind} membership")
        if kind in {"dnf", "apk"}:
            for source in selected:
                for package in parse_dnf(source):
                    if package in package_owner: fail(f"profile {name} declares package {package} in both {package_owner[package].relative_to(root)} and {source.relative_to(root)}")
                    package_owner[package] = source
        members[kind] = tuple(selected)
    packages = "apk" if distro == "alpine" else "dnf"
    if not members[packages]: fail(f"profile {name} selects no {packages.upper()} components")
    forbidden = ("dnf", "copr", "repos") if distro == "alpine" else ("apk",)
    if any(members[kind] for kind in forbidden): fail(f"profile {name} contains components incompatible with {distro}")
    return Profile(name, members, distro, parent)

def requirements(profile: Profile, root: Path) -> str | None:
    if not profile.members["collections"]: return None
    output = ["collections:"]
    for source in profile.members["collections"]:
        lines = [x for x in source.read_text().splitlines() if x.strip() and not x.lstrip().startswith("#")]
        if not lines: fail(f"{source.relative_to(root)} lists no collections")
        output += [f"  # {source.relative_to(root)}"] + [f"  {x}" for x in lines]
    return "\n".join(output) + "\n"

def validate_profile_relationships(profiles: dict[str, Profile]) -> None:
    def require_subset(parent: str, child: str) -> None:
        for kind in KINDS:
            missing = set(profiles[parent].members[kind]) - set(profiles[child].members[kind])
            if missing:
                names = ", ".join(sorted(path.name for path in missing))
                fail(f"profile {child} must include {parent} {kind} membership: {names}")

    if BASE_PROFILE not in profiles:
        fail(f"missing base profile: {BASE_PROFILE}")
    for name, profile in profiles.items():
        parent = profile.base_profile
        if parent not in profiles: fail(f"profile {name} has missing base profile {parent}")
        if profiles[parent].distro != profile.distro: fail(f"profile {name} cannot inherit across distros")
        if profiles[parent].base_profile != parent: fail(f"base profile {parent} must be self-based")
        if name != parent:
            require_subset(parent, name)
    for parent, child in PROFILE_RELATIONSHIPS:
        if parent in profiles and child in profiles:
            if profiles[parent].distro == profiles[child].distro:
                require_subset(parent, child)

def dependency_steps(members: dict[str, tuple[Path, ...]], root: Path) -> list[str]:
    steps: list[str] = []
    for source in members["repos"]:
        rel = source.relative_to(root)
        steps += [f"# {rel}", f"COPY {rel} /etc/yum.repos.d/{source.name}", ""]
    if members["copr"]:
        steps += ["RUN printf 'Installing Fedora COPR support\\n' \\", f"  && dnf -y install {DNF_INSTALL_OPTIONS} dnf5-plugins", ""]
        for source in members["copr"]:
            project, chroot = parse_copr(source)
            rel = source.relative_to(root)
            steps += [f"# {rel}", f"RUN dnf -y copr enable {project}" + (f" {chroot}" if chroot else ""), ""]
    for source in members["dnf"]:
        rel = source.relative_to(root)
        steps += [f"# {rel}", f"RUN printf 'Installing DNF component: {rel}\\n' \\", f"  && dnf -y install {DNF_INSTALL_OPTIONS} \\"]
        steps += [f"    {package} \\" for package in parse_dnf(source)] + ["  && true", ""]
    for source in members["apk"]:
        rel = source.relative_to(root)
        steps += [f"# {rel}", "RUN apk --cache-dir /var/cache/apk add --update-cache \\"]
        steps += [f"    {package} \\" for package in parse_dnf(source)] + ["  && true", ""]
    for source in members["containerfiles"]:
        rel = source.relative_to(root)
        steps += [f"# {rel}", source.read_text().rstrip(), ""]
    return steps

def render(profile: Profile, template: str, root: Path = ROOT, common: Profile | None = None) -> tuple[str, str | None]:
    for marker in ("# DISTRO_BASE", "# DISTRO_INITIALIZE", "@CREATE_RUNTIME_USER@", "# COMMON_DEPENDENCY_DROPINS", "# PROFILE_DEPENDENCY_DROPINS", "# ANSIBLE_COLLECTION_DROPINS"):
        if template.count(marker) != 1: fail(f"Dockerfile.in must contain exactly one {marker} marker")
    common = common or read_profile(profile.base_profile, root)
    if common.name != profile.base_profile or common.distro != profile.distro:
        fail(f"wrong common profile for {profile.name}")
    common_sources = {kind: set(common.members[kind]) for kind in KINDS}
    head = ["# Generated file; retained as build evidence.", f"# Profile: {profile.name}"]
    for kind in KINDS:
        for source in profile.members[kind]:
            role = "Common membership" if source in common_sources[kind] else "Profile membership"
            head.append(f"# {role}: {source.relative_to(root)}")

    shared_members = {kind: common.members[kind] if kind != "collections" else () for kind in KINDS}
    profile_members = {
        kind: tuple(source for source in profile.members[kind] if source not in common_sources[kind])
        if kind != "collections" else ()
        for kind in KINDS
    }
    shared_steps = dependency_steps(shared_members, root)
    profile_steps = dependency_steps(profile_members, root)
    req = requirements(profile, root)
    collection = ""
    if req: collection = "\n".join([f"COPY .build-cache/profiles/{profile.name}/ansible-collections.yml /tmp/codex-ansible-collections.yml",
        "RUN ansible-galaxy collection install --force -p /usr/share/ansible/collections -r /tmp/codex-ansible-collections.yml \\", "  && rm -f /tmp/codex-ansible-collections.yml"])
    if profile.distro == "alpine":
        base = "ARG ALPINE_VERSION=latest\nFROM alpine:${ALPINE_VERSION} AS codex-common"
        initialize = "RUN mkdir -p /var/cache/apk && ln -s /var/cache/apk /etc/apk/cache"
        user_command = 'adduser -D -s /bin/bash "${USERNAME}"'
    else:
        base = "ARG FEDORA_VERSION=latest\nFROM fedora:${FEDORA_VERSION} AS codex-common"
        initialize = "RUN dnf -y --refresh makecache"
        user_command = 'useradd --create-home "${USERNAME}"'
    template = template.replace("# DISTRO_BASE", base).replace("# DISTRO_INITIALIZE", initialize)
    template = template.replace("@CREATE_RUNTIME_USER@", user_command)
    body = template.replace("# COMMON_DEPENDENCY_DROPINS", "\n".join(shared_steps).rstrip())
    body = body.replace("# PROFILE_DEPENDENCY_DROPINS", "\n".join(profile_steps).rstrip())
    body = body.replace("# ANSIBLE_COLLECTION_DROPINS", collection)
    return "\n".join(head) + "\n\n" + body, req

def atomic_write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True); fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream: stream.write(content); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        try: os.unlink(temporary)
        except FileNotFoundError: pass
        raise
def generate(profile: Profile, root: Path = ROOT, common: Profile | None = None) -> Path:
    containerfile, req = render(profile, (root / "Dockerfile.in").read_text(), root, common); out = root / ".build-cache/profiles" / profile.name
    if req: atomic_write(out / "ansible-collections.yml", req)
    elif (out / "ansible-collections.yml").exists(): (out / "ansible-collections.yml").unlink()
    atomic_write(out / "Containerfile", containerfile); return out / "Containerfile"

def selection(argv: list[str], profiles: tuple[str, ...]):
    p = argparse.ArgumentParser(description="Build profile-aware Codex images")
    p.add_argument("--profile", action="append", default=[], metavar="NAME[,NAME...]"); p.add_argument("--all", "--all-profiles", action="store_true", dest="all_profiles")
    p.add_argument("--no-profile", action="append", default=[], metavar="NAME[,NAME...]"); p.add_argument("--batch", "--non-interactive", action="store_true", dest="batch")
    args = p.parse_args(argv); flatten = lambda xs: [x.strip() for item in xs for x in item.split(",") if x.strip()]
    wanted, excluded = flatten(args.profile), flatten(args.no_profile)
    for label, values in (("profile", wanted), ("excluded profile", excluded)):
        if unknown := set(values) - set(profiles): p.error(f"unknown {label}: {', '.join(sorted(unknown))}")
        if len(values) != len(set(values)): p.error(f"duplicate {label} selection")
    if args.all_profiles and wanted: p.error("--profile conflicts with all-profile selection")
    if excluded and not args.all_profiles: p.error("--no-profile requires all-profile selection")
    chosen = [x for x in profiles if x not in excluded] if args.all_profiles else (wanted or [BASE_PROFILE])
    if not chosen: p.error("profile selection is empty")
    return args, tuple(chosen)

def artifact(root: Path) -> tuple[str, str]:
    archive = root / "dist/codex.tgz"
    if not archive.is_file(): fail("dist/codex.tgz is missing; run ./codex-artifact.sh prepare first")
    try:
        with tarfile.open(archive) as tar: version = json.load(tar.extractfile("package/package.json"))["version"]
    except Exception as exc: fail(f"failed to extract Codex package version: {exc}")
    meta = {}
    if (mf := root / "dist/codex-artifact.env").exists():
        for line in mf.read_text().splitlines():
            if "=" in line and not line.startswith("#"): key, value = line.split("=", 1); meta[key] = value
    if meta.get("CODEX_ARTIFACT_VERSION") and meta["CODEX_ARTIFACT_VERSION"] != version: fail(f"dist/codex.tgz is version {version}, but metadata records {meta['CODEX_ARTIFACT_VERSION']}")
    return version, os.environ.get("CODEX_ARTIFACT_TYPE", meta.get("CODEX_ARTIFACT_TYPE", "release"))

def freshness(version: str, kind: str, batch: bool, root: Path) -> str:
    if kind not in {"release", "alpha"}: fail(f"unsupported CODEX_ARTIFACT_TYPE: {kind}")
    command = ["bash", "-c", 'source "$1"; CODEX_CURL_MAX_TIME="$2" latest_version_for_type "$3"', "_",
               str(root/"scripts/codex-artifact-common.sh"), os.environ.get("CODEX_ARTIFACT_BUILD_TIMEOUT", "1"), kind]
    try:
        latest = subprocess.run(command, text=True, capture_output=True, check=True, env=os.environ).stdout.strip()
    except Exception: print(f"Warning: could not check latest Codex {kind} version.", file=sys.stderr); return version
    if not latest or latest == version: return version
    print(f"Warning: staged Codex {kind} artifact is {version}; latest is {latest}.", file=sys.stderr); choice = os.environ.get("CODEX_ARTIFACT_STALE_POLICY", "")
    if not choice: choice = "fail" if batch or os.environ.get("CODEX_CONTAINER_BATCH") == "1" else (input("Stale Codex artifact. refresh, continue, or abort? [r/c/a] ").strip() or "abort")
    choice = {"r":"refresh", "c":"continue", "a":"abort"}.get(choice, choice)
    if choice == "refresh": subprocess.run([str(root/"codex-artifact.sh"), "prepare", "type", kind], check=True); return artifact(root)[0]
    if choice == "continue": return version
    if choice in {"fail", "abort"}: fail("refusing to build stale Codex artifact")
    fail(f"invalid CODEX_ARTIFACT_STALE_POLICY: {choice}")
def image_exists(cli: str, image: str) -> bool:
    cmd = [cli, "image", "exists", image] if cli == "podman" else [cli, "inspect", "--type", "image", image]
    return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
def detect_host_timezone(environment: dict[str, str] | None = None, localtime: Path = Path("/etc/localtime")) -> str:
    environment = os.environ if environment is None else environment
    if timezone := environment.get("TZ", "").strip(): return timezone
    if localtime.is_symlink():
        target = os.readlink(localtime)
        for prefix in ("/usr/share/zoneinfo/", "../usr/share/zoneinfo/"):
            if target.startswith(prefix): return target.removeprefix(prefix)
    try:
        result = subprocess.run(["timedatectl", "show", "--property=Timezone", "--value"], text=True, capture_output=True, timeout=2)
        if result.returncode == 0 and (timezone := result.stdout.strip()): return timezone
    except (OSError, subprocess.TimeoutExpired):
        pass
    return "UTC"
def promote(cli: str, candidate: str, profile: str):
    current, previous = f"codex:{profile}", f"codex:prev-{profile}"
    if image_exists(cli, current): subprocess.run([cli, "tag", current, previous], check=True)
    subprocess.run([cli, "tag", candidate, current], check=True)
    if profile == "default": subprocess.run([cli, "tag", current, "codex:latest"], check=True)
    subprocess.run([cli, "rmi", candidate], check=True)

def build(argv: list[str]) -> int:
    discovered = discover_profiles()
    args, selected = selection(argv, discovered)
    profiles = {name: read_profile(name) for name in discovered}
    validate_profile_relationships(profiles)
    cli = os.environ.get("CONTAINER_CLI", "buildah")
    if cli not in {"buildah", "podman"}: fail(f"unsupported CONTAINER_CLI={cli}")
    dns = os.environ.get("CODEX_FIREWALL_DNS_TOOL", "dig")
    if dns not in {"dig", "kdig", "drill"}: fail(f"unsupported CODEX_FIREWALL_DNS_TOOL={dns}")
    timezone = detect_host_timezone()
    settings = {name: (alpine_settings(os.environ) if profiles[name].distro == "alpine"
                       else fedora_settings(os.environ)) for name in selected}
    version, kind = artifact(ROOT); version = freshness(version, kind, args.batch, ROOT)
    base = [cli, "build" if cli == "podman" else "bud"]
    subprocess.run(base + ["--layers", "-t", "codex-firewall", "-f", "./Dockerfile.firewall", "--build-arg", f"CODEX_FIREWALL_DNS_TOOL={dns}", "--label", "org.opencontainers.image.title=codex-container-firewall",
      "--label", "org.opencontainers.image.ref.name=codex-firewall", "--label", f"codex.firewall.dns.tool={dns}", "--label", "app.kubernetes.io/part-of=codex-container", "--label", "app.kubernetes.io/component=firewall", "."], cwd=ROOT, check=True)
    for name in selected:
        profile = profiles[name]
        base_version, cache = settings[name]
        if profile.distro == "alpine":
            cache.mkdir(parents=True, exist_ok=True)
            cache_args = ["--volume", f"{cache}:/var/cache/apk:Z,rw"]
            base_arg = f"ALPINE_VERSION={base_version}"
        else:
            (cache/"dnf").mkdir(parents=True, exist_ok=True)
            (cache/"libdnf5").mkdir(parents=True, exist_ok=True)
            cache_args = ["--volume", f"{cache}/dnf:/var/cache/dnf:Z,rw", "--volume", f"{cache}/libdnf5:/var/cache/libdnf5:Z,rw"]
            base_arg = f"FEDORA_VERSION={base_version}"
        file = generate(profile, common=profiles[profile.base_profile]); candidate = f"codex:candidate-{name}-{uuid.uuid4().hex[:12]}"
        cmd = base + ["--layers", "--target", "codex-profile", "-t", candidate, "-f", str(file), "--pull=always", "--build-arg", base_arg, "--build-arg", f"TZ={timezone}", "--build-arg", f"SOPS_VERSION={os.environ.get('SOPS_VERSION','latest')}", "--build-arg", f"CODEX_PACKAGE_VERSION={version}",
          "--label", "org.opencontainers.image.title=codex-container-runtime", "--label", f"codex.cli.version={version}", "--label", f"codex.container.profile={name}", "--label", f"codex.container.distro={profile.distro}", "--label", f"codex.container.base={profile.distro}:{base_version}", "--label", f"org.opencontainers.image.ref.name=codex:{name}",
          "--label", f"org.opencontainers.image.version={version}", "--label", "app.kubernetes.io/name=codex", "--label", "app.kubernetes.io/part-of=codex-container", "--label", "app.kubernetes.io/component=app",
          "--label", f"app.kubernetes.io/version={version}", *cache_args, "--volume", f"{ROOT}/dist/codex.tgz:/tmp/codex.tgz:ro"]
        if "ANDROID_ACCEPT_LICENSES" in os.environ:
            cmd += ["--build-arg", f"ANDROID_ACCEPT_LICENSES={os.environ['ANDROID_ACCEPT_LICENSES']}"]
        cmd.append(".")
        subprocess.run(cmd, cwd=ROOT, check=True); promote(cli, candidate, name)
    return 0
if __name__ == "__main__":
    try: raise SystemExit(build(sys.argv[1:]))
    except BuildError as exc: print(f"Error: {exc}", file=sys.stderr); raise SystemExit(1)
    except subprocess.CalledProcessError as exc:
        print(f"Error: command failed with exit status {exc.returncode}: {' '.join(exc.cmd)}", file=sys.stderr)
        raise SystemExit(exc.returncode)
