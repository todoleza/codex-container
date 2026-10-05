# Project History

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
