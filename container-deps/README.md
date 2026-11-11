# Dependency catalogs

Profiles select shared dependency components through relative symlinks into
these catalogs:

- `dnf/` contains Fedora package-list components.
- `apk/` contains Alpine package-list components and parity notes.
- `copr/` contains declarative Fedora COPR entries.
- `repos/` contains literal DNF repository files.
- `collections/` contains Ansible collection requirement fragments.
- `containerfiles/` contains trusted `.containerfile` instruction fragments for
  tools that need more than RPM installation, such as SDKs and virtualenvs.
  They are inserted in filename order after distro packages and before collections
  in the corresponding common or profile stage. Keep fragments within the
  current stage and leave user switching to `Dockerfile.in`.

COPR entries use `OWNER/PROJECT` with an optional Fedora chroot. Shell
fragments are not supported.

The `fdroid` profile selects `80-fdroid.dnf`, `80-android-sdk.containerfile`,
and `81-fdroid.containerfile` on top of the default and Python components.
Android CLI/checksum, Build Tools, and fdroidserver pins live in those fragments.
Platform Tools and transitive pip dependencies resolve at build time; this is
not a fully locked dependency tree.

Profiles without metadata retain `distro=fedora, base_profile=default`.
`container-profiles/alpine/profile.json` selects
`{"distro":"alpine","base_profile":"alpine"}`. A base must reference itself;
children must include its membership and share its distro. DNF/COPR/literal
Fedora repository components are rejected in Alpine profiles; APK components
are rejected in Fedora profiles. Common user/runtime/artifact steps are shared
in Dockerfile.in; only base initialization and account creation differ.
