# Alpine default-tool mapping

The `alpine` profile selects these `.apk` components through relative symlinks.
Lists use the same comment/blank-line rules as `.dnf` lists. Declared package
errors fail the build; no skip-unavailable option is enabled.

| Fedora dependency | Alpine dependency |
| --- | --- |
| nodejs24, nodejs24-npm | nodejs, npm |
| gh | github-cli |
| bind-utils | bind-tools |
| gnupg2 | gnupg |
| iproute | iproute2 |
| procps-ng | procps |
| ShellCheck | shellcheck |
| python3-requests, python3-setuptools, python3-dateutil, python-pip | py3-requests, py3-setuptools, py3-dateutil, py3-pip |
| strings | binutils |
| man | mandoc |
| exiftool | exiftool (subpackage of perl-image-exiftool) |
| aggregate | Not included: no verified stable Alpine package mapping |

Other default tools retain their package names. Bash, coreutils, findutils,
and tzdata explicitly support the shared runtime scripts and timezone behavior.
Codex uses the common installation path. SOPS and age are omitted from Alpine;
they are selected only by the Fedora infra/full profiles. Alpine uses the selected base
image's stable main/community repositories; do not add edge to fill gaps.
Package sources were inspected for Alpine 3.24, including
[ExifTool](https://github.com/alpinelinux/aports/blob/3.24-stable/community/perl-image-exiftool/APKBUILD).
A complete real package install and image/runtime verification remain host
validation gates; catalog tests alone do not establish runtime compatibility.

APK's `/etc/apk/cache` points to `/var/cache/apk`. Builds bind the separate
`APK_CACHE_DIR` there. Runtime cache mounts use the launcher's `REPO_CACHE`
and may be disabled with `--no-package-cache` or
`CODEX_PACKAGE_CACHE_ENABLE=0`; neither affects build caches.
