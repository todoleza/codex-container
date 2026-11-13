# Build environment reference

Run `./build-images.sh --help-env` to print these defaults. No artifact, network,
or container tool is required. Settings come from the process environment;
launcher env files and CODEX_ENV_* forwarding do not apply to builds.

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `TZ` | `host timezone, then UTC` | Builder: explicit TZ overrides host detection. |

## Image builder

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `CODEX_FIREWALL_DNS_TOOL` | `dig` | Firewall image build: dig, kdig, or drill; requires rebuilding the firewall image. |
| `CONTAINER_CLI` | `buildah` | Builder: buildah or podman. |
| `FEDORA_VERSION` | `latest` | Builder: Fedora base tag; applies only to Fedora profiles. |
| `DNF_CACHE_DIR` | `${REPO}/.build-cache/dnf-fedora-${FEDORA_VERSION}` | Builder: persistent Fedora build cache, separate from runtime caches. |
| `ALPINE_VERSION` | `latest` | Builder: Alpine base tag; stable repositories from that image are retained. |
| `APK_CACHE_DIR` | `${REPO}/.build-cache/apk-alpine-${ALPINE_VERSION}` | Builder: persistent Alpine build cache, separate from runtime caches. |
| `SOPS_VERSION` | `latest` | Builder/infra/full: stable SOPS release or an explicit version; ignored by other profiles. |
| `ANDROID_ACCEPT_LICENSES` | `fragment ARG default (currently 1)` | Builder/fdroid: forwarded only when explicitly set; review the Android license first. |

## Artifact freshness during builds

| Variable | Default / derivation | Purpose / context |
| --- | --- | --- |
| `CODEX_GITHUB_API_URL` | `https://api.github.com/repos/openai/codex` | Artifact tools: upstream release API root. |
| `CODEX_ARTIFACT_TYPE` | `metadata type, otherwise release` | Artifact tools/builder: release or alpha; artifact CLI selectors override during prepare. |
| `CODEX_ARTIFACT_STALE_POLICY` | `prompt interactively; fail in batch` | Artifact tools/builder: refresh, continue, fail/abort. |
| `CODEX_CONTAINER_BATCH` | `0` | Artifact tools/builder: 1 enables batch stale-artifact handling; --batch also supported. |
| `CODEX_CURL` | `curl` | Artifact tools: curl executable override. |
| `CODEX_ARTIFACT_RELEASE_PAGE_SIZE` | `10` | Artifact tools: release-list page size. |
| `CODEX_ARTIFACT_RELEASE_MAX_PAGES` | `10` | Artifact tools: maximum release-list pages. |
| `CODEX_ARTIFACT_BUILD_TIMEOUT` | `1` | Builder: freshness-check timeout, seconds. |

A stale-policy refresh invokes the artifact preparation command. Its additional
settings (paths, prompt controls, and download timeouts) are documented separately
in docs/environment.md; they do not change the builder’s own dist/ input path.
