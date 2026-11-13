#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fake_codex="${tmpdir}/codex-real"
cat > "${fake_codex}" <<'FAKE_CODEX'
#!/bin/sh
printf '%s\n' "$*" > "${CODEX_WRAPPER_LOG}"
FAKE_CODEX
chmod 755 "${fake_codex}"

export CODEX_WRAPPER_LOG="${tmpdir}/codex.args"
CODEX_REAL_BIN="${fake_codex}" \
CODEX_SANDBOX_MODE=workspace-write \
CODEX_APPROVAL_POLICY=on-request \
CODEX_EXTRA_ADD_DIRS="/repo/.git /repo/vendor/.git" \
  bash "${repo_root}/container-runtime/codex" status

grep -Fq -- "--no-daemon --sandbox workspace-write --ask-for-approval on-request --add-dir /repo/.git --add-dir /repo/vendor/.git status" "${CODEX_WRAPPER_LOG}"

CODEX_REAL_BIN="${fake_codex}" \
CODEX_EXTRA_ADD_DIRS="/repo/.git" \
  bash "${repo_root}/container-runtime/codex" --add-dir /custom status

grep -Fq -- "--no-daemon --sandbox danger-full-access --ask-for-approval on-request --add-dir /custom status" "${CODEX_WRAPPER_LOG}"
if grep -Fq -- "/repo/.git" "${CODEX_WRAPPER_LOG}"; then
  echo "wrapper should not add default add-dir when caller supplies --add-dir" >&2
  exit 1
fi

CODEX_REAL_BIN="${fake_codex}" \
CODEX_NO_DAEMON=0 \
  bash "${repo_root}/container-runtime/codex" status

if grep -Fq -- "--no-daemon" "${CODEX_WRAPPER_LOG}"; then
  echo "wrapper should allow the daemon default to be restored explicitly" >&2
  exit 1
fi

# Capture individual arguments to check terminal defaults and payload boundaries.
python3 - "${repo_root}" "${tmpdir}" <<'PY'
import os, subprocess, sys
from pathlib import Path
root, temp = map(Path, sys.argv[1:])
fake = temp/'capture'
fake.write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$CODEX_WRAPPER_LOG"\n')
fake.chmod(0o755)
env = dict(os.environ, CODEX_REAL_BIN=str(fake), CODEX_NO_DAEMON='0')
for setting, payload, expected in [
    (None, ['status'], 1),
    ('1', ['--', 'prompt with spaces'], 1),
    ('', ['status'], 1),
    ('0', ['status'], 0),
    ('1', ['--no-alt-screen', 'status'], 1),
    ('0', ['--no-alt-screen', 'status'], 1),
]:
    run_env = env.copy()
    run_env.pop('CODEX_NO_ALT_SCREEN', None)
    if setting is not None:
        run_env['CODEX_NO_ALT_SCREEN'] = setting
    subprocess.run(['bash', str(root/'container-runtime/codex'), *payload], env=run_env, check=True)
    args = Path(env['CODEX_WRAPPER_LOG']).read_bytes().decode().split('\0')[:-1]
    assert args.count('--no-alt-screen') == expected, args
    assert args[-len(payload):] == payload, args
PY
