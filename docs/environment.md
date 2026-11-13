# Environment reference

Runtime-only help: `codex help env` ([reference](environment-runtime.md)).
Build-only help: `./build-images.sh --help-env` ([reference](environment-build.md)).
This complete reference additionally covers artifact preparation and direct
firewall-script invocation. All references show defaults, never current values.

## Precedence and execution contexts

Launcher CLI options override matching settings. Caller-exported variables beat
all env files. Files load global, workspace, then CODEX_CONTAINER_ENV_FILES in
order; later files override earlier files. Global/workspace file paths and the
extra-file list must be selected before those files are read. Files contain
literal NAME=value assignments, without shell evaluation or quote stripping.

`: "${NAME:=default}"` defaults only unset/empty values. An explicit `0` is
preserved. Where a setting uses `${NAME:-default}`, unset/empty similarly uses
the fallback without assignment. Python builder settings are read from the
process environment, not launcher env files. Explicit numeric flags and enum
values are validated by their owning command; values are case-sensitive.

Runtime mount, firewall, proxy, and image settings normally apply when creating
containers: use replace/respawn to apply changes to existing instances. App env
settings can also be forwarded to exec operations. CODEX_ENV_* is app-only;
firewall DNS settings are explicitly forwarded by the launcher, while other
firewall-script variables require direct sidecar configuration. There is no
implicit firewall forwarding prefix.

## Launcher defaults and forwarded settings

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `CODEX_CONTAINER_GLOBAL_ENV_FILE` | `${HOME}/.local/share/codex-container/env` | Launcher: global defaults file. |
| `CODEX_CONTAINER_WORKSPACE_ENV_FILE` | `${EARLY_WORK_DIR}/.codex-container.env` | Launcher: workspace defaults file, selected before loading settings. |
| `CODEX_ALLOWED_DOMAIN_CATEGORIES` | `openai source_control os_packages containers language_packages jvm_dotnet schema_docs` | Launcher/firewall: enabled named allowlist categories, whitespace separated. |
| `CODEX_ALLOWED_DOMAINS_OPENAI` | `api.openai.com auth.openai.com chatgpt.com` | Launcher/firewall: domains in the openai category; override replaces that category. |
| `CODEX_ALLOWED_DOMAINS_SOURCE_CONTROL` | `github.com githubusercontent.com raw.githubusercontent.com api.github.com gitlab.com bitbucket.org` | Launcher/firewall: domains in the source_control category; override replaces that category. |
| `CODEX_ALLOWED_DOMAINS_OS_PACKAGES` | `alpinelinux.org archlinux.org centos.org copr.fedorainfracloud.org download.copr.fedorainfracloud.org debian.org fedoraproject.org ppa.launchpad.net ubuntu.com packages.microsoft.com` | Launcher/firewall: domains in the os_packages category; override replaces that category. |
| `CODEX_ALLOWED_DOMAINS_CONTAINERS` | `docker.com docker.io ghcr.io gcr.io mcr.microsoft.com quay.io` | Launcher/firewall: domains in the containers category; override replaces that category. |
| `CODEX_ALLOWED_DOMAINS_LANGUAGE_PACKAGES` | `cpan.org crates.io golang.org goproxy.io haskell.org hex.pm metacpan.org nodejs.org npmjs.com npmjs.org packagist.org pkg.go.dev pub.dev pypa.io pypi.org pypi.python.org pythonhosted.org ruby-lang.org rubygems.org rubyonrails.org rustup.rs yarnpkg.com` | Launcher/firewall: domains in the language_packages category; override replaces that category. |
| `CODEX_ALLOWED_DOMAINS_JVM_DOTNET` | `apt.llvm.org dot.net dotnet.microsoft.com gradle.org maven.org nuget.org` | Launcher/firewall: domains in the jvm_dotnet category; override replaces that category. |
| `CODEX_ALLOWED_DOMAINS_SCHEMA_DOCS` | `json-schema.org json.schemastore.org` | Launcher/firewall: domains in the schema_docs category; override replaces that category. |
| `CODEX_ALLOWED_DOMAINS_VENDOR_OPT_IN` | `anaconda.com apache.org azure.com cocoapods.org eclipse.org google.com hashicorp.com java.com java.net k8s.io launchpad.net microsoft.com oracle.com packagecloud.io sourceforge.net spring.io swift.org visualstudio.com` | Launcher/firewall: domains in the vendor_opt_in category; override replaces that category. |
| `CODEX_OMITTED_DOMAINS` | `bower.io continuum.io jcenter.bintray.com rubyforge.org rvm.io` | Launcher/firewall: excluded preset domains, including category-derived entries. |
| `OPENAI_ALLOWED_DOMAINS` | `(empty)` | Launcher/firewall: full manual domain override; empty builds the list from categories. |
| `EXTRA_ALLOWED_DOMAINS` | `(empty)` | Launcher/firewall: additional whitespace-separated domains. |
| `EXTRA_ALLOWED_IPV4` | `(empty)` | Launcher/firewall: additional IPv4 addresses/CIDRs. |
| `EXTRA_ALLOWED_IPV6` | `(empty)` | Launcher/firewall: additional IPv6 addresses/CIDRs. |
| `CODEX_CONTAINER_PROFILE` | `default` | Launcher: selected profile; -p/--profile overrides it. |
| `FIREWALL_CONTAINER_IMAGE` | `codex-firewall` | Launcher: firewall-sidecar image. |
| `PROXY_CONTAINER_IMAGE` | `${FIREWALL_CONTAINER_IMAGE}` | Launcher: optional host-side proxy-relay image. |
| `PROXY_ENABLE` | `0` | Launcher: 0/1, enable the optional proxy relay. |
| `PROXY_RUNTIME_DIR` | `/run/codex-proxy` | Launcher/proxy: container-side proxy mount directory. |
| `PROXY_SOCKET_PATH` | `/run/codex-proxy/proxy.sock` | Launcher/proxy: container-side relay socket path. |
| `PROXY_LISTEN_HOST` | `localhost` | Launcher/proxy: pod-side relay bind hostname/address. |
| `PROXY_LISTEN_PORT` | `1080` | Launcher/proxy: pod-side relay port. |
| `PROXY_UPSTREAM_HOST` | `localhost` | Launcher/proxy: existing proxy host reachable by the host-side relay. |
| `PROXY_UPSTREAM_PORT` | `1080` | Launcher/proxy: existing proxy port. |
| `CODEX_FIREWALL_POLICY_DIR` | `/run/codex-firewall-policy` | Launcher/app: read-only policy mount in the app; also used by codex-firewall-policy. |
| `CODEX_FIREWALL_MODE` | `enforced` | Launcher: enforced or lifted for newly created resources; --no-firewall overrides it. |
| `CODEX_FIREWALL_DNS_TIMEOUT` | `0.75` | Launcher -> firewall: per-resolver timeout, seconds. |
| `CODEX_FIREWALL_DNS_TRIES` | `5` | Launcher -> firewall: maximum DNS resolution attempts. |
| `CODEX_FIREWALL_DNS_BATCH_SIZE` | `10` | Launcher -> firewall: names submitted per resolver invocation. |
| `CODEX_FIREWALL_DNS_PARALLELISM` | `32` | Launcher -> firewall: parallel resolver limit. |
| `CODEX_FIREWALL_DNS_CACHE_TTL` | `300` | Launcher -> firewall: cached DNS answer lifetime, seconds. |
| `CODEX_SANDBOX_MODE` | `danger-full-access` | Launcher -> app wrapper: read-only, workspace-write, or danger-full-access. |
| `CODEX_APPROVAL_POLICY` | `on-request` | Launcher -> app wrapper: untrusted, on-failure, on-request, or never. |
| `CODEX_DANGEROUS_BYPASS` | `0` | Launcher -> app wrapper: 0/1, bypass approvals and sandbox. |
| `CODEX_RELEASE_API_URL` | `https://api.github.com/repos/openai/codex/releases/latest` | Launcher: endpoint used for latest-version labels on new instances. |
| `CODEX_RELEASE_API_TIMEOUT_SECONDS` | `5` | Launcher: timeout for latest-release lookup, seconds. |
| `CODEX_RELEASE_CHECK_ON_SPAWN` | `1` | Launcher: 0/1, check latest release while creating instances. |
| `PODMAN_POD_CREATE_ARGS` | `(empty)` | Launcher: extra podman pod create arguments, whitespace split. |
| `PODMAN_FIREWALL_RUN_ARGS` | `(empty)` | Launcher: extra firewall podman run arguments, including explicit -e overrides. |
| `PODMAN_CODEX_RUN_ARGS` | `(empty)` | Launcher: extra app podman run arguments, whitespace split. |
| `PODMAN_EXEC_ARGS` | `(empty)` | Launcher: extra podman exec arguments, whitespace split. |
| `CONTAINER_EXEC_COMMAND` | `(empty)` | Launcher: replace the default Codex invocation with bash -lc COMMAND. |
| `SIDECARS` | `(empty)` | Launcher: colon-separated sidecar IDs. |
| `STARTUP_SUMMARY_HOLD_SECONDS` | `1.2` | Launcher: summary pause, nonnegative seconds; 0 disables. |
| `CODEX_PACKAGE_CACHE_ENABLE` | `1` | Launcher: 0/1, external runtime cache enable; --no-package-cache overrides to 0. |
| `REPO_CACHE` | `/var/tmp/container_repo_cache` | Launcher: external runtime package-cache root; tilde expanded; retained across removal. |

## Additional launcher inputs

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `WORKSPACE_ROOT_DIR` | `current working directory` | Launcher: initial workspace path; -d overrides; Git/env-file root inference follows. |
| `CONTAINER_IMAGE` | `codex:${CODEX_CONTAINER_PROFILE}` | Launcher: explicit runtime image override; inspect its metadata for cache support. |
| `CODEX_CONTAINER_ENV_FILES` | `(empty)` | Launcher: additional colon-separated env files, loaded in order. |
| `PROXY_RUNTIME_DIR_HOST` | `${XDG_RUNTIME_DIR:-/run/user/UID}/${POD_NAME}-proxy` | Launcher: host proxy state; only caller-environment override is honored. |
| `FIREWALL_POLICY_RUNTIME_DIR_HOST` | `${XDG_RUNTIME_DIR:-/run/user/UID}/${POD_NAME}-policy` | Launcher: host policy state; only caller-environment override is honored. |
| `OPENAI_API_KEY` | `(unset)` | Launcher -> app: optional API credential; values are never printed by this reference. |
| `CODEX_ENV_<NAME>` | `(unset)` | Launcher -> app: export as NAME, stripping CODEX_ENV_; does not target the firewall. |
| `SIDECAR_<id>_IMAGE` | `(required for each SIDECARS member)` | Launcher: sidecar image. |
| `SIDECAR_<id>_ENV_PREFIX` | `(empty)` | Launcher: prefix of settings exported only to that sidecar, with prefix stripped. |
| `SIDECAR_<id>_RUN_ARGS` | `(empty)` | Launcher: extra sidecar run arguments; volume sources support documented home/env expansion. |
| `SIDECAR_<id>_COMMAND` | `(empty)` | Launcher: explicit sidecar command executed with sh -lc. |
| `HOME` | `host environment` | Launcher/artifact tools: credentials, env-file and home-directory defaults. |
| `XDG_RUNTIME_DIR` | `/run/user/UID` | Launcher: workspace registry, policy/proxy state, and snapshots. |
| `TZ` | `host timezone, then UTC` | Builder/launcher: timezone; explicit TZ wins. |

## Runtime wrapper (inside the app container)

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `CODEX_REAL_BIN` | `/usr/local/share/npm-global/bin/codex` | App wrapper: native Codex executable path. |
| `CODEX_NO_DAEMON` | `1` | App wrapper: 0/1. Set CODEX_ENV_CODEX_NO_DAEMON on the host to forward it. |
| `CODEX_EXTRA_ADD_DIRS` | `launcher-derived Git metadata paths` | App wrapper: whitespace-separated default --add-dir paths; launcher computes this value. |
| `CODEX_NO_ALT_SCREEN` | `1` | App wrapper: 0/1. Set CODEX_ENV_CODEX_NO_ALT_SCREEN on the host to forward it; 0 disables automatic --no-alt-screen. |

## Direct firewall scripts and firewall image build (not launcher inputs)

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `CODEX_FIREWALL_DNS_TOOL` | `dig` | Image build: dig, kdig, or drill; selects the installed resolver. Host changes need an image rebuild. Direct scripts read the image setting. |
| `CODEX_FIREWALL_STATE_DIR` | `/etc/codex-firewall` | Direct firewall scripts only: writable state path. Launcher mounts policy at the default path; changing it requires matching mount configuration. |
| `CODEX_FIREWALL_DIG_TIMEOUT` | `0.75 fallback` | Legacy direct-script alias: used only when CODEX_FIREWALL_DNS_TIMEOUT is unset/empty. Launcher always forwards the canonical setting. |
| `CODEX_FIREWALL_DIG_TRIES` | `5 fallback` | Legacy direct-script alias: used only when CODEX_FIREWALL_DNS_TRIES is unset/empty. Launcher always forwards the canonical setting. |

## Image builder (not launcher inputs)

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `CONTAINER_CLI` | `buildah` | Builder: buildah or podman. |
| `FEDORA_VERSION` | `latest` | Builder: Fedora base tag; applies only to Fedora profiles. |
| `DNF_CACHE_DIR` | `${REPO}/.build-cache/dnf-fedora-${FEDORA_VERSION}` | Builder: persistent Fedora build cache, separate from runtime caches. |
| `ALPINE_VERSION` | `latest` | Builder: Alpine base tag; stable repositories from that image are retained. |
| `APK_CACHE_DIR` | `${REPO}/.build-cache/apk-alpine-${ALPINE_VERSION}` | Builder: persistent Alpine build cache, separate from runtime caches. |
| `SOPS_VERSION` | `latest` | Builder/infra/full: stable SOPS release or an explicit version; ignored by other profiles. |
| `ANDROID_ACCEPT_LICENSES` | `fragment ARG default (currently 1)` | Builder/fdroid: forwarded only when explicitly set; review the Android license first. |

## Artifact preparation and freshness (not launcher inputs)

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `CODEX_GITHUB_API_URL` | `https://api.github.com/repos/openai/codex` | Artifact tools: upstream release API root. |
| `CODEX_ARTIFACT_TYPE` | `metadata type, otherwise release` | Artifact tools/builder: release or alpha; artifact CLI selectors override during prepare. |
| `CODEX_ARTIFACT_STALE_POLICY` | `prompt interactively; fail in batch` | Artifact tools/builder: refresh, continue, fail/abort. |
| `CODEX_CONTAINER_BATCH` | `0` | Artifact tools/builder: 1 enables batch stale-artifact handling; --batch also supported. |
| `INTERACTIVE` | `1` | Artifact shell tools: 0 disables prompts; non-TTY stdin also disables prompts. Builder uses --batch/CODEX_CONTAINER_BATCH. |
| `CODEX_CURL` | `curl` | Artifact tools: curl executable override. |
| `CODEX_ARTIFACT_RELEASE_PAGE_SIZE` | `10` | Artifact tools: release-list page size. |
| `CODEX_ARTIFACT_RELEASE_MAX_PAGES` | `10` | Artifact tools: maximum release-list pages. |
| `CODEX_ARTIFACT_STATUS_TIMEOUT` | `2` | Artifact status: curl timeout, seconds. |
| `CODEX_ARTIFACT_BUILD_TIMEOUT` | `1` | Builder: freshness-check timeout, seconds. |
| `CODEX_CURL_MAX_TIME` | `command-specific timeout` | Artifact shell helpers: explicit curl timeout; builder sets it for freshness checks. |
| `REPO_ROOT` | `artifact script repository` | Artifact shell tools: repository-root override; Python builder always uses its own repository. |
| `UPSTREAM_CACHE_DIR` | `${REPO_ROOT}/.build-cache/upstream/codex` | Artifact tools: downloaded upstream archive cache. |
| `DIST_DIR` | `${REPO_ROOT}/dist` | Artifact tools: staged output directory; Python builder still consumes its repository dist/. |
| `STAGED_ARTIFACT` | `${DIST_DIR}/codex.tgz` | Artifact tools: staged tarball path; Python builder consumes repository dist/codex.tgz. |
| `ARTIFACT_METADATA` | `${DIST_DIR}/codex-artifact.env` | Artifact tools: metadata path; Python builder consumes repository dist/codex-artifact.env. |

## Internal and derived values

Snapshot markers, batch-dispatch controls, generated resource names, shell
arrays, and parsed artifact metadata are implementation state, not supported
configuration inputs. CODEX_FIREWALL_UPDATED_EPOCH is status output, not a
setting. Standard HOME/TZ/XDG_RUNTIME_DIR values are consumed as noted above;
this reference does not list every variable consumed by third-party tools.
