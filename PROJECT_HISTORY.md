# Project History

## 2026-11-11 - Make launcher arguments explicit and add completion and bulk selection

### Changed and decisions
- Kept the self-contained Bash launcher. Codex arguments now require `--`,
  including with `replace`; launcher `-h`/`--help` shows local help. Added
  `-i/--id`, `-d/--wd`, and `-p/--profile`, accepted after commands before
  shell/copy payloads. Early workspace/profile discovery uses the same parser.
- Added `completion bash|zsh`, inferring the command name from `$0`, including
  the user's `codex` symlink. Generation bypasses env files, Podman, snapshots,
  and network access. Native Codex completion remains separately documented;
  payload delegation and dynamic profile/ID suggestions are deferred.
- Added checked numeric ID lists/ranges for status, name, respawn, and removal.
  Spawn remains single-target. Requests resolve all IDs before dispatch,
  process targets in numeric order, and aggregate operational failures.
- Added explicit `rm all` scopes: `--workspace`, `--ancestors`, `--tree`, and
  `--everywhere`. Path scopes include the inferred root; explicit CLI profiles
  filter selection, environment/default profiles do not. Exact-root removal
  warns about descendants left outside its scope. Selection is restricted to
  this user's registry, retaining mounted workspace files and registry records.
- Per-target invocations start workspace inference at the saved target path and
  use saved resource/sidecar names. A new isolation test caught invocation-root
  env settings leaking into a second target; target-root initialization fixes
  that failure. Batch removals verify resources are gone and report failures.
- Updated README, usage notes, and the living plan for the breaking argument
  boundary and new selection/completion interfaces.

### Validation and follow-up
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-launcher-cli.py`: 14 tests
  passed, covering exact argument arrays, short options, shell/copy boundaries,
  list/range preflight, multi-target configuration isolation, every removal
  scope, profile filters, failure aggregation, and Bash/Zsh completion.
- All five existing `scripts/test-launcher-*.sh` regression scripts passed.
- Bash launcher/generated-completion syntax, Zsh generated-completion syntax,
  generated Bash completion ShellCheck, and `git diff --check` passed.
  Launcher ShellCheck retains the same pre-existing diagnostics as HEAD;
  no new diagnostic was introduced.
- Podman is unavailable in this session. Container lifecycle/removal validation
  used stateful mocks; live workstation Podman behavior remains unverified.

## 2026-11-09 - Allow GitHub raw content in the source-control category

### Changed and evidence
- Added `raw.githubusercontent.com` to `CODEX_ALLOWED_DOMAINS_SOURCE_CONTROL`
  in `run-in-container.sh` and updated the documented default. The user
  reported access failure; the existing `githubusercontent.com` entry does
  not automatically resolve its subdomains into the firewall address sets.
- Kept the change to the requested host in the existing default category.
  Explicit category/domain overrides retain their existing behavior.

### Validation
- Launcher firewall-mode and environment/snapshot tests, shell syntax, and
  `git diff --check` passed. Live policy was inspected and was already lifted
  in this session; no live firewall changes or enforced-network access test
  were performed. Existing pods need an operator policy update/reload or a
  subsequent startup using the new defaults.

## 2026-11-09 - Generalize Fedora selection and finalize temporary-directory permissions

### Changed and evidence
- Replaced release-specific base/cache settings with `FEDORA_VERSION`,
  defaulting to `latest`. The driver passes the selected tag to the template's
  `FROM fedora:${FEDORA_VERSION}` and derives `.build-cache/dnf-fedora-<tag>`
  unless `DNF_CACHE_DIR` is explicitly set. No release number remains in the
  build driver.
- Runtime builds use `--pull=always`, matching Buildah's documented pull policy,
  so the rolling default checks for a fresh base. DNF refreshes metadata when
  the base changes and its dependency layer runs again. Retained the common
  stage, profile composition, layer caching, and existing cache directories.
- The user reported the root F-Droid verifier passed but the subsequent
  `USER`-scoped `/tmp`/`/var/tmp` check failed. Moved permission normalization to
  after all dependency installers and copies. The image-user check now prints
  identity/modes and actually creates temporary files in both directories.
  The exact earlier operation affecting directory access remains unconfirmed.

### Validation and follow-up
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-build-profiles.py`: 13 tests
  passed, including default/pinned tag selection, cache override, and unsafe
  tag rejection.
- `PYTHONDONTWRITEBYTECODE=1 bash scripts/test-build-freshness.sh`: mocked
  builds passed for default `latest`, an arbitrary future release tag, all
  profiles, the cache override, and license overrides.
- Shell syntax, generated Containerfile inspection, and `git diff --check`
  passed. Real base pulls and the final non-root temporary-file check still
  require the host image builder; Buildah/Podman are unavailable here.

## 2026-11-09 - Prime project test tooling and ensure writable temporary directories

### Changed and evidence
- The user verified the running F-Droid toolchain (Python 3.15, Java 25,
  Android Build Tools 36.0.0, fdroidserver 2.4.5), including zipalign, using
  `TMPDIR=/var/tmp`; `/tmp` was reported unwritable. This confirms the toolchain
  is installed, while the earlier missing-tools report did not reflect it.
- Added `pytest>=8`, `setuptools>=75`, and wheel to `/opt/project-venv`.
  The mounted application still needs its own editable installation.
- Explicitly create `/tmp` and `/var/tmp` with mode `1777` in the common image
  and check writability as the image user. The precise cause of the reported
  runtime `/tmp` permissions was not established from the supplied output.
- Extended `codex-verify-fdroid-env` to check project dependencies and both
  temporary directories, so overriding TMPDIR cannot hide a broken `/tmp`.

### Validation and follow-up
- Profile-generation tests, mocked builds, shell syntax, ShellCheck, and
  `git diff --check` passed. A temporary Python 3.14 environment verified the
  baseline package installation and version checks.
- Rebuild and verify as the runtime user on the host; no local Buildah/Podman
  is available here. The existing container is not changed by these edits.

## 2026-11-09 - Preserve the selected Android license ARG default

### Changed and evidence
- The user explicitly changed `ARG ANDROID_ACCEPT_LICENSES=1` in the Android
  catalog fragment, but the builder still supplied `--build-arg
  ANDROID_ACCEPT_LICENSES=0` whenever the environment variable was absent.
- The driver now forwards a license build argument only when the build
  environment explicitly sets it, preserving the user's fragment default.
  Explicit environment values, including `0`, still override the fragment.

### Validation
- Mocked build tests cover an unset environment, explicit `1`, and explicit
  `0`; profile-generation tests and `git diff --check` passed.
- The fragment's user-selected default remains `1`. Full image/SDK execution
  still requires Buildah or Podman outside this session.

## 2026-11-09 - Upgrade runtime profiles to Fedora 45

### Changed and evidence
- Updated `Dockerfile.in` to `fedora:45` for every runtime profile, following
  the user's direction to use the released Fedora 45 base.
- Changed the default DNF cache to `.build-cache/dnf-fedora-45`, preserving the
  old Fedora 44 cache and the explicit `DNF_CACHE_DIR` override.
- Updated current usage/design notes and the common-stage generation check.
  Fedora's [package metadata](https://packages.fedoraproject.org/pkgs/java-25-openjdk/java-25-openjdk-devel/fedora-45.html)
  confirms `java-25-openjdk-devel` is available for Fedora 45.

### Validation and follow-up
- Profile-generation tests and mocked build orchestration passed. Generated
  Containerfiles use Fedora 45 and the F-Droid profile selects OpenJDK 25.
- `git diff --check` passed. Real Fedora 45 RPM transaction resolution and SDK
  execution still require a build on a host with Buildah/Podman.

## 2026-11-09 - Fix the F-Droid Java package for Fedora 44

### Changed and evidence
- Replaced `java-21-openjdk-devel` with `java-25-openjdk-devel` in
  `container-deps/dnf/80-fdroid.dnf` and aligned current usage/design notes.
- The reported Buildah transaction failed with `No match for argument:
  java-21-openjdk-devel`. Fedora retired OpenJDK 21 from Fedora 44; the
  [Fedora 44 package metadata](https://packages.fedoraproject.org/pkgs/java-25-openjdk/java-25-openjdk-devel/fedora-44.html)
  confirms the replacement package is available.

### Validation and follow-up
- Profile-generation tests and mocked build orchestration passed; inspected
  the generated F-Droid Containerfile for the replacement package.
- `git diff --check` passed. A real Fedora image build and SDK execution still
  require a host with Buildah/Podman. The reported command also supplied
  `ANDROID_ACCEPT_LICENSES=0`; SDK installation requires explicit opt-in as
  documented in the build instructions.

## 2026-11-09 - Add an optional F-Droid repository toolchain

### Changed
- Added the directory-discovered `fdroid` profile with default/Python components,
  Java 21, APK tooling, SQLite, archive utilities, and development packages.
- Extended the existing symlink catalog mechanism with trusted `.containerfile`
  fragments for reusable non-RPM installations, after DNF and before collections.
- Pinned the checksum-verified Android CLI to `15859902`, Build Tools to
  `36.0.0`, and fdroidserver to `2.4.5` in its own virtualenv. Project installs
  use a separate writable `/opt/project-venv`; Google's sdkmanager precedes the
  same-named Python dependency on `PATH`.
- Added `codex-verify-fdroid-env` as a build/runtime smoke check and documented
  build, launch, license opt-in, network sources, and dependency-locking limits.

### Why and evidence
- `fdroid-repo.md` requests a toolchain for existing APKs, with isolated Python
  environments and deferred manifest editor selection. Preserved Fedora 44 and
  the common-stage architecture in `Dockerfile.in` and `PLAN.md`; no SDK
  platforms, emulator, application code, signing keys, or repo are created.
- Confirmed the CLI checksum against Google's Android Studio download page and
  the fdroidserver release/dependencies against PyPI. SDK license acceptance
  requires an explicit `ANDROID_ACCEPT_LICENSES=1` build environment setting.

### Validation
- `python3 scripts/test-build-profiles.py`: 12 tests passed, including shared
  stage identity, optional toolchain isolation, and fragment symlink boundaries.
- `bash scripts/test-build-freshness.sh`: mocked builds passed, including
  all-profile discovery and license build-argument propagation.
- `bash scripts/test-launcher-profiles.sh`: passed.
- An isolated Python 3.14 virtualenv installed `fdroidserver==2.4.5` and passed
  `pip check`, `fdroid --version`, and `fdroid update --help`.
- Shell syntax, ShellCheck, generated Containerfile inspection, and
  `git diff --check` passed.

### Follow-up
- Build and run `codex:fdroid` on a Linux x86_64 host with Buildah or Podman;
  neither image builder is installed in this session. SDK binary execution and
  Fedora RPM resolution were not validated here. Platform Tools and transitive
  pip packages still resolve at build time.

## 2026-10-07 - Harden DNS batches and support lifted startup

### Changed
- Batched resolver invocations now have a 750 ms deadline, make at most five
  attempts, strictly filter addresses, and reject malformed cached results.
- Added `--no-firewall` and `CODEX_FIREWALL_MODE=lifted`; enforced startup stays
  fail-closed, while lifted startup tolerates a broken firewall container and
  records `mode: disabled`.

### Why
- A transient `dig` diagnostic containing a colon passed the loose AAAA filter,
  was cached as `;;`, and made the generated nftables transaction invalid.
- Operators need an explicit way to start without enforcement even when the
  firewall image or container is unavailable.

### Validation
- `bash scripts/test-firewall-policy.sh`
- `bash scripts/test-launcher-firewall-mode.sh`
- All scripts matching `scripts/test-*.sh`
- Shell syntax checks and `git diff --check`

## 2026-10-07 - Decouple build profiles and repair implicit workspace selection

### Changed
- Build profiles are now discovered from `container-profiles/`, with `default`
  retained as the required common base instead of a hardcoded profile list.
- An implicit launch can adopt the newest running profile record for the same
  or nearest ancestor path; explicit profile choices remain profile-scoped.

### Why
- Adding the `typesetting` profile required editing `build-images.py`, which
  contradicted the symlink-composed profile boundary.
- A missing default-profile record hid a newer running `typesetting` record for
  the same path and caused the default workspace to be spawned again.

### Validation
- `python3 scripts/test-build-profiles.py`
- `bash scripts/test-launcher-profiles.sh`
- All scripts matching `scripts/test-*.sh`
- `bash -n run-in-container.sh scripts/test-launcher-profiles.sh`
- `python3 -m py_compile build-images.py scripts/test-build-profiles.py`

## 2026-10-06 - Discover launcher profiles from local images

### Changed
- Added `profiles` and `--list-profiles`, which report canonical local Codex
  profile images and their version and image metadata.
- Replaced launcher profile-name hardcoding with label-backed local-image
  validation at pod creation boundaries.

### Why
- The launcher duplicated the build system's profile names, so adding or
  retaining a locally built profile also required editing launcher source.
- Image removal must not prevent operators from inspecting, entering, copying
  from, or cleaning up an existing workspace.

### Validation
- Launcher tests cover discovery filtering, stable table output, an unknown-to-
  source local profile, missing-image safety, lifecycle management, and the
  explicit image override.

## 2026-10-06 - Derive runtime image timezone from the build host

### Changed
- Runtime profile builds now receive an explicit `TZ` build argument detected
  from the build host, with a `UTC` fallback.

### Why
- Generated Containerfiles declared `ARG TZ`, but orchestration did not supply
  it, producing one missing-argument warning for every selected profile and an
  empty image timezone.

### Validation
- Unit coverage checks environment and `/etc/localtime` detection, and the
  mocked build verifies that the detected timezone reaches Buildah.

## 2026-10-06 - Build the firewall dependency first

### Changed
- Image orchestration now builds `codex-firewall` before every selected runtime
  profile and stops before runtime builds if the firewall build fails.

### Why
- The firewall sidecar is a hard runtime dependency, so producing runtime
  images before validating their required companion image inverted the actual
  startup dependency order.

### Validation
- Mocked default and all-profile builds assert that the firewall build is the
  first image build command.

## 2026-10-06 - Retain RPM payloads in the shared DNF cache

### Changed
- Generated DNF install commands now enable `keepcache`, including the
  conditional `dnf5-plugins` installation used for COPR profiles.

### Why
- The cache directories were already shared across every profile build, but
  DNF discarded successful transaction payloads. The first all-profile build
  consequently downloaded the same 13 MiB `uv` transaction for both `python`
  and `full`.

### Evidence and validation
- `build-images2.log` completed an unchanged all-profile rebuild in about 16
  seconds with every runtime instruction served from Buildah's layer cache.
- Profile-generation tests verify that every generated DNF install carries the
  shared keep-cache option.

## 2026-10-06 - Share the default build foundation

### Changed
- Generated profile Containerfiles now use an identical internal
  `codex-common` stage containing the default dependencies, SOPS, runtime files,
  and user setup.
- Profile-only dependencies and collections follow the shared stage, while the
  frequently changing Codex artifact is installed in the final layer.
- Dependency prefixes now express common, infrastructure, Python, media, and
  disabled groups so related profiles share useful instruction prefixes.

### Why
- The original per-profile `FROM fedora` files warmed some Buildah layers but
  did not use default as a real common foundation. Profile divergence caused
  repeated runtime setup and made the historical numeric ordering ineffective
  for cross-profile reuse.

### Validation
- Generated common stages are byte-identical across all profiles, Codex appears
  only in final stages, and profile relationship and canonical-order tests pass.

## 2026-10-06 - Consolidate dependency catalogs

### Changed
- Moved DNF, COPR, literal repository, and Ansible collection catalogs under
  `container-deps/{dnf,copr,repos,collections}` so the shared catalog mirrors
  each profile's membership structure.
- Repointed profile symlinks and updated generated evidence, tests, and
  operator documentation for the consolidated paths.

### Validation
- All profile links resolve within their matching catalog.
- Profile generation, repository tests, Python compilation, shell syntax, and
  whitespace checks pass with the consolidated layout.

## 2026-10-05 - Add profile-aware runtime builds

### Changed
- Added symlink-composed dependency profiles, declarative COPR and literal DNF
  repository support, and a Python build orchestrator behind `build-images.sh`.
- Retained generated Containerfiles per profile, preserved shared DNF/layer
  caches, and added candidate promotion with one rollback tag per profile.
- Added launcher profile selection and profile-aware workspace identity.

### Safety and validation
- Profile inputs reject non-symlinks, escaping or dangling targets, wrong
  extensions, duplicate packages, and malformed COPR declarations.
- Literal repository domains are not trusted automatically; only the Fedora
  COPR service domains were added to the `os_packages` firewall category.
- Python compilation, shell syntax, profile tests, launcher tests, and
  whitespace validation cover the implementation. A live Buildah build reached
  the Fedora 44 pull with the `vfs` fallback, then the running container's
  enforced firewall rejected the CDN IPv6 destination; larger-profile startup
  and rollback checks therefore remain operator validation steps.

## 2026-10-05 - Disable the Codex daemon by default

### Changed
- The image-side Codex wrapper now adds `--no-daemon` by default. Operators can
  opt back in with `CODEX_ENV_CODEX_NO_DAEMON=0`.

### Why
- Codex CLI 0.160.1 attempted to use
  `~/.codex/packages/standalone/current/codex`, which is not part of the npm CLI
  installed in the image. A shared daemon is also a poor fit for multiple
  ephemeral workspace containers sharing the host `~/.codex` mount.

### Evidence
- `codex features list` reported `daemon_auto_start` as enabled by default.
- The expected standalone executable and app-server control socket were absent.
- `codex --help` documents `--no-daemon` for this operating mode.

### Validation
- `scripts/test-codex-wrapper-add-dir.sh` covers the new default and explicit
  opt-out.

### Follow-up
- A daemon-enabled deployment needs a dedicated lifecycle and a container-local
  control/package directory rather than the shared host mount.
