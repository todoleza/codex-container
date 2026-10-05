#!/usr/bin/env python3
"""Generate retained profile Containerfiles and build Codex images."""
from __future__ import annotations

import argparse, json, os, re, subprocess, sys, tarfile, tempfile, uuid
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROFILE_ORDER = ("default", "infra", "python", "media", "full")
KINDS = {"dnf": ("container-deps/dnf", {".dnf"}), "copr": ("container-deps/copr", {".copr"}),
         "repos": ("container-deps/repos", {".repo"}), "collections": ("container-deps/collections", {".yml", ".yaml"})}
COPR_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\s+[A-Za-z0-9_.:+-]+)?$")
PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.:*?-]*$")
MEMBER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

class BuildError(RuntimeError): pass

@dataclass(frozen=True)
class Profile:
    name: str
    members: dict[str, tuple[Path, ...]]

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
    base = root / "container-profiles"; found = {p.name for p in base.iterdir() if p.is_dir()} if base.is_dir() else set()
    if extra := found - set(PROFILE_ORDER): fail(f"unknown profile directories: {', '.join(sorted(extra))}")
    if missing := set(PROFILE_ORDER) - found: fail(f"missing profiles: {', '.join(sorted(missing))}")
    return tuple(p for p in PROFILE_ORDER if p in found)

def read_profile(name: str, root: Path = ROOT) -> Profile:
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
        if kind == "dnf":
            for source in selected:
                for package in parse_dnf(source):
                    if package in package_owner: fail(f"profile {name} declares package {package} in both {package_owner[package].relative_to(root)} and {source.relative_to(root)}")
                    package_owner[package] = source
        members[kind] = tuple(selected)
    if not members["dnf"]: fail(f"profile {name} selects no DNF components")
    return Profile(name, members)

def requirements(profile: Profile, root: Path) -> str | None:
    if not profile.members["collections"]: return None
    output = ["collections:"]
    for source in profile.members["collections"]:
        lines = [x for x in source.read_text().splitlines() if x.strip() and not x.lstrip().startswith("#")]
        if not lines: fail(f"{source.relative_to(root)} lists no collections")
        output += [f"  # {source.relative_to(root)}"] + [f"  {x}" for x in lines]
    return "\n".join(output) + "\n"

def render(profile: Profile, template: str, root: Path = ROOT) -> tuple[str, str | None]:
    for marker in ("# DNF_DROPINS", "# ANSIBLE_COLLECTION_DROPINS"):
        if template.count(marker) != 1: fail(f"Dockerfile.in must contain exactly one {marker} marker")
    sources = [p.relative_to(root) for kind in KINDS for p in profile.members[kind]]
    head = ["# Generated file; retained as build evidence.", f"# Profile: {profile.name}"] + [f"# Selected: {p}" for p in sources]; steps = []
    for source in profile.members["repos"]:
        rel = source.relative_to(root); steps += [f"# {rel}", f"COPY {rel} /etc/yum.repos.d/{source.name}", ""]
    if profile.members["copr"]:
        steps += ["RUN printf 'Installing Fedora COPR support\\n' \\", "  && dnf -y install --setopt=install_weak_deps=False dnf5-plugins", ""]
        for source in profile.members["copr"]:
            project, chroot = parse_copr(source); rel = source.relative_to(root)
            steps += [f"# {rel}", f"RUN dnf -y copr enable {project}" + (f" {chroot}" if chroot else ""), ""]
    for source in profile.members["dnf"]:
        rel = source.relative_to(root); steps += [f"# {rel}", f"RUN printf 'Installing DNF component: {rel}\\n' \\", "  && dnf -y install --setopt=install_weak_deps=False \\"]
        steps += [f"    {p} \\" for p in parse_dnf(source)] + ["  && true", ""]
    req = requirements(profile, root); collection = ""
    if req: collection = "\n".join([f"COPY .build-cache/profiles/{profile.name}/ansible-collections.yml /tmp/codex-ansible-collections.yml",
        "RUN ansible-galaxy collection install --force -p /usr/share/ansible/collections -r /tmp/codex-ansible-collections.yml \\", "  && rm -f /tmp/codex-ansible-collections.yml"])
    body = template.replace("# DNF_DROPINS", "\n".join(steps).rstrip()).replace("# ANSIBLE_COLLECTION_DROPINS", collection)
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
def generate(profile: Profile, root: Path = ROOT) -> Path:
    containerfile, req = render(profile, (root / "Dockerfile.in").read_text(), root); out = root / ".build-cache/profiles" / profile.name
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
    chosen = [x for x in profiles if x not in excluded] if args.all_profiles else (wanted or ["default"])
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
def promote(cli: str, candidate: str, profile: str):
    current, previous = f"codex:{profile}", f"codex:prev-{profile}"
    if image_exists(cli, current): subprocess.run([cli, "tag", current, previous], check=True)
    subprocess.run([cli, "tag", candidate, current], check=True)
    if profile == "default": subprocess.run([cli, "tag", current, "codex:latest"], check=True)
    subprocess.run([cli, "rmi", candidate], check=True)

def build(argv: list[str]) -> int:
    args, selected = selection(argv, discover_profiles()); cli = os.environ.get("CONTAINER_CLI", "buildah")
    if cli not in {"buildah", "podman"}: fail(f"unsupported CONTAINER_CLI={cli}")
    dns = os.environ.get("CODEX_FIREWALL_DNS_TOOL", "dig")
    if dns not in {"dig", "kdig", "drill"}: fail(f"unsupported CODEX_FIREWALL_DNS_TOOL={dns}")
    version, kind = artifact(ROOT); version = freshness(version, kind, args.batch, ROOT); cache = Path(os.environ.get("DNF_CACHE_DIR", ROOT/".build-cache/dnf-fedora-44")).resolve()
    (cache/"dnf").mkdir(parents=True, exist_ok=True); (cache/"libdnf5").mkdir(parents=True, exist_ok=True); base = [cli, "build" if cli == "podman" else "bud"]
    for name in selected:
        file = generate(read_profile(name)); candidate = f"codex:candidate-{name}-{uuid.uuid4().hex[:12]}"
        cmd = base + ["--layers", "-t", candidate, "-f", str(file), "--build-arg", f"SOPS_VERSION={os.environ.get('SOPS_VERSION','latest')}", "--build-arg", f"CODEX_PACKAGE_VERSION={version}",
          "--label", "org.opencontainers.image.title=codex-container-runtime", "--label", f"codex.cli.version={version}", "--label", f"codex.container.profile={name}", "--label", f"org.opencontainers.image.ref.name=codex:{name}",
          "--label", f"org.opencontainers.image.version={version}", "--label", "app.kubernetes.io/name=codex", "--label", "app.kubernetes.io/part-of=codex-container", "--label", "app.kubernetes.io/component=app",
          "--label", f"app.kubernetes.io/version={version}", "--volume", f"{cache}/dnf:/var/cache/dnf:Z,rw", "--volume", f"{cache}/libdnf5:/var/cache/libdnf5:Z,rw", "--volume", f"{ROOT}/dist/codex.tgz:/tmp/codex.tgz:ro", "."]
        subprocess.run(cmd, cwd=ROOT, check=True); promote(cli, candidate, name)
    subprocess.run(base + ["--layers", "-t", "codex-firewall", "-f", "./Dockerfile.firewall", "--build-arg", f"CODEX_FIREWALL_DNS_TOOL={dns}", "--label", "org.opencontainers.image.title=codex-container-firewall",
      "--label", "org.opencontainers.image.ref.name=codex-firewall", "--label", f"codex.firewall.dns.tool={dns}", "--label", "app.kubernetes.io/part-of=codex-container", "--label", "app.kubernetes.io/component=firewall", "."], cwd=ROOT, check=True)
    return 0
if __name__ == "__main__":
    try: raise SystemExit(build(sys.argv[1:]))
    except BuildError as exc: print(f"Error: {exc}", file=sys.stderr); raise SystemExit(1)
    except subprocess.CalledProcessError as exc:
        print(f"Error: command failed with exit status {exc.returncode}: {' '.join(exc.cmd)}", file=sys.stderr)
        raise SystemExit(exc.returncode)
