# Dependency catalogs

Profiles select shared dependency components through relative symlinks into
these catalogs:

- `dnf/` contains package-list components.
- `copr/` contains declarative Fedora COPR entries.
- `repos/` contains literal DNF repository files.
- `collections/` contains Ansible collection requirement fragments.
- `containerfiles/` contains trusted `.containerfile` instruction fragments for
  tools that need more than RPM installation, such as SDKs and virtualenvs.
  They are inserted in filename order after DNF packages and before collections
  in the corresponding common or profile stage. Keep fragments within the
  current stage and leave user switching to `Dockerfile.in`.

COPR entries use `OWNER/PROJECT` with an optional Fedora chroot. Shell
fragments are not supported.

The `fdroid` profile selects `80-fdroid.dnf`, `80-android-sdk.containerfile`,
and `81-fdroid.containerfile` on top of the default and Python components.
Android CLI/checksum, Build Tools, and fdroidserver pins live in those fragments.
Platform Tools and transitive pip dependencies resolve at build time; this is
not a fully locked dependency tree.
