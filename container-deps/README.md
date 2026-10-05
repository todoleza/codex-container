# Dependency catalogs

Profiles select shared dependency components through relative symlinks into
these catalogs:

- `dnf/` contains package-list components.
- `copr/` contains declarative Fedora COPR entries.
- `repos/` contains literal DNF repository files.
- `collections/` contains Ansible collection requirement fragments.

COPR entries use `OWNER/PROJECT` with an optional Fedora chroot. Shell
fragments are not supported.
