#!/usr/bin/env python3
"""Launcher contract tests with stateful Podman mocks; no containers are touched."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
LAUNCHER = REPO / 'run-in-container.sh'
PODMAN = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a') as f:
    f.write(json.dumps(args) + '\n')
p = Path(os.environ['MOCK_STATE'])
s = json.loads(p.read_text())
cmd = args[0]
if cmd == 'container' and args[1] == 'exists':
    sys.exit(0 if args[2] in s['containers'] else 1)
if cmd == 'inspect':
    print('true' if 'Running' in args[2] else '0.1.0')
if cmd == 'image':
    if args[1] == 'inspect':
        query = args[3]
        image = args[-1]
        if 'container.profile' in query:
            print(image.split(':')[-1])
        elif 'container.distro' in query:
            print(os.environ.get('MOCK_IMAGE_DISTRO', 'alpine' if image == 'codex:alpine' else 'fedora'))
        elif 'container.base' in query:
            print(os.environ.get('MOCK_IMAGE_BASE', 'alpine:3.24'))
        elif 'Architecture' in query:
            print(os.environ.get('MOCK_IMAGE_ARCH', 'amd64'))
        else:
            print('0.1.0')
if cmd == 'pod':
    action = args[1]
    if action == 'exists':
        sys.exit(0 if args[2] in s['pods'] else 1)
    if action == 'create':
        s['pods'].append(args[args.index('--name') + 1])
    if action == 'rm':
        name = args[-1]
        if name == os.environ.get('MOCK_FAIL_REMOVE'):
            sys.exit(1)
        s['pods'] = [x for x in s['pods'] if x != name]
if cmd == 'rm':
    s['containers'] = [x for x in s['containers'] if x != args[-1]]
if cmd == 'run':
    s['containers'].append(args[args.index('--name') + 1])
p.write_text(json.dumps(s))
'''


class LauncherCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.work = self.base / 'work'
        self.work.mkdir()
        self.runtime = self.base / 'runtime'
        self.runtime.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        (self.bin / 'podman').write_text(PODMAN)
        (self.bin / 'podman').chmod(0o755)
        self.codex = self.bin / 'codex'
        self.codex.symlink_to(LAUNCHER)
        self.log = self.base / 'podman.log'
        self.state = self.base / 'state.json'
        self.state.write_text(json.dumps({'pods': [], 'containers': []}))
        self.registry = self.runtime / 'codex-container/workspaces'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        HOME=str(self.base), XDG_RUNTIME_DIR=str(self.runtime),
                        MOCK_LOG=str(self.log), MOCK_STATE=str(self.state),
                        CODEX_RELEASE_CHECK_ON_SPAWN='0', STARTUP_SUMMARY_HOLD_SECONDS='0',
                        CODEX_CONTAINER_GLOBAL_ENV_FILE=str(self.base / 'absent.env'),
                        CODEX_CONTAINER_ENV_FILES='', CODEX_CONTAINER_PROFILE='default',
                        PROXY_ENABLE='0', SIDECARS='', REPO_CACHE=str(self.base / 'package-cache'))
        for name in ('CODEX_CONTAINER_WORKSPACE_ENV_FILE', 'CODEX_CONTAINER_LAUNCHER_SNAPSHOT',
                     'CODEX_CONTAINER_LAUNCHER_SNAPSHOT_PATH', 'CONTAINER_EXEC_COMMAND',
                     'WORKSPACE_ROOT_DIR', 'CONTAINER_IMAGE', 'CODEX_PACKAGE_CACHE_ENABLE'):
            self.env.pop(name, None)

    def run_cli(self, *args, ok=True, env=None):
        result = subprocess.run([str(self.codex), *args], cwd=self.work,
                                env=self.env | (env or {}), text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def register(self, number, path=None, profile='default'):
        path = path or self.work
        path.mkdir(parents=True, exist_ok=True)
        # A marker makes workspace inference stable when called from a subdirectory.
        (path / '.codex-container.env').touch()
        entry = self.registry / 'state' / f'record-{number}'
        entry.mkdir(parents=True)
        values = dict(seq=str(number), path=str(path), profile=profile, alias=f'alias-{number}',
                      pod=f'saved-{number}', app=f'saved-{number}-app', fw=f'saved-{number}-fw',
                      proxy=f'saved-{number}-proxy', sidecars='api', sidecar_api=f'saved-{number}-special-api')
        for key, value in values.items():
            (entry / key).write_text(value + '\n')
        by_seq = self.registry / 'by-seq'
        by_seq.mkdir(exist_ok=True)
        (by_seq / str(number)).symlink_to(entry)
        by_hash = self.registry / 'by-path-hash'
        by_hash.mkdir(exist_ok=True)
        digest = hashlib.sha256(f'{path}:{profile}'.encode()).hexdigest()[:8]
        if not (by_hash / digest).exists():
            (by_hash / digest).symlink_to(entry)
        state = json.loads(self.state.read_text())
        state['pods'].append(values['pod'])
        state['containers'] += [values[k] for k in ('app', 'fw', 'proxy', 'sidecar_api')]
        self.state.write_text(json.dumps(state))

    def test_help_and_invalid_cli(self):
        for arg in ('help', '--help', '-h'):
            self.assertIn('Use -- --help', self.run_cli(arg).stdout)
        for args in [('--model', 'x'), ('respan',), ('-i',), ('-d',), ('-p',),
                     ('rm', 'all'), ('rm', 'all', '--workspace', '--tree'),
                     ('rm', 'all', '--everywhere', '-d', str(self.work)),
                     ('rm', 'all', '--workspace', '-i', '1'), ('spawn', '-i', '1,2'),
                     ('status', '--no-package-cache'), ('help', 'unknown'), ('list', 'extra'), ('replace', '--model', 'x'), ('shell',)]:
            self.run_cli(*args, ok=False)
        self.assertEqual(self.calls(), [])

    def test_exact_codex_and_shell_payload(self):
        self.register(1)
        payload = ['--help', '--profile', 'native', '', 'two words', '--', '-i', '8']
        self.run_cli('-i', '1', '--', *payload)
        self.assertEqual([c for c in self.calls() if c[0] == 'exec'][-1][-len(payload)-1:], ['codex', *payload])
        self.run_cli('shell', '-i', '1', 'bash', '-i', '-c', 'printf "hello world"')
        self.assertEqual([c for c in self.calls() if c[0] == 'exec'][-1][-4:], ['bash', '-i', '-c', 'printf "hello world"'])
        self.run_cli('replace', '-i', '1', '--', 'resume', '--', '')
        self.assertEqual([c for c in self.calls() if c[0] == 'exec'][-1][-4:], ['codex', 'resume', '--', ''])

    def test_copy_payload_and_multi_status_kill(self):
        self.register(1)
        self.register(2, self.work / 'second')
        self.run_cli('copy', '-i', '1', '--', 'local file', 'container file')
        copy = [c for c in self.calls() if c[0] == 'cp'][-1]
        self.assertEqual(copy[-2:], [str(self.work / 'local file'),
                                    f'saved-1-app:{self.work}/container file'])
        output = self.run_cli('status', '-i', '2,1').stdout
        self.assertIn('== id 1: status ==', output)
        self.assertIn('== id 2: status ==', output)
        self.run_cli('kill', '-i', '1-2')
        removals = [c for c in self.calls() if c[0] == 'rm']
        self.assertTrue(all('--time=0' in c for c in removals))

    def test_short_options_after_command(self):
        (self.work / '.codex-container.env').write_text('CODEX_ENV_SCOPE=local\n')
        self.run_cli('spawn', '-d', str(self.work), '-p', 'infra')
        runs = [c for c in self.calls() if c[0] == 'run']
        self.assertTrue(any('codex:infra' in c and 'SCOPE' in c for c in runs))
        self.register(4, profile='infra')
        self.assertIn('saved-4-app', self.run_cli('name', '-i', '4').stdout)
        self.run_cli('respawn', '-i', '4')

    def test_multi_id_preflight_and_order(self):
        for n in (3, 4, 5, 6, 9):
            self.register(n)
        output = self.run_cli('name', '-i', '9,3-6,4').stdout
        self.assertEqual([line for line in output.splitlines() if line.startswith('saved-')],
                         [f'saved-{n}-app' for n in (3, 4, 5, 6, 9)])
        self.run_cli('rm', '-i', '3,99', ok=False)
        self.assertFalse(any(c[0] == 'rm' for c in self.calls()))
        for selector in ('6-3', '3,,4', '3-', ',3', '3,', '3,nope'):
            self.run_cli('rm', '-i', selector, ok=False)
        self.run_cli('rm', '-i', '3-6,9,4')
        removed = [c[-1] for c in self.calls() if c[:2] == ['pod', 'rm']]
        self.assertEqual(removed, [f'saved-{n}' for n in (3, 4, 5, 6, 9)])
        self.assertTrue(any(c[-1] == 'saved-3-special-api' for c in self.calls() if c[0] == 'rm'))
        self.assertTrue((self.registry / 'by-seq/3').exists())

    def setup_tree(self):
        self.register(1, self.base, 'infra')
        self.register(2, self.work, 'default')
        self.register(3, self.work, 'infra')
        self.register(4, self.work / 'nested', 'infra')
        self.register(5, self.base / 'work-other', 'infra')

    def removed(self):
        return [c[-1] for c in self.calls() if c[:2] == ['pod', 'rm']]

    def test_workspace_scope_and_warning(self):
        self.setup_tree()
        output = self.run_cli('rm', 'all', '--workspace', '-d', str(self.work / 'subdir'))
        self.assertEqual(self.removed(), ['saved-2', 'saved-3'])
        self.assertIn('Use rm all --tree', output.stderr)

    def test_tree_and_profile_filter(self):
        self.setup_tree()
        self.run_cli('rm', 'all', '--tree', '-p', 'infra')
        self.assertEqual(self.removed(), ['saved-3', 'saved-4'])

    def test_ancestors(self):
        self.setup_tree()
        self.run_cli('rm', 'all', '--ancestors')
        self.assertEqual(self.removed(), ['saved-1', 'saved-2', 'saved-3'])

    def test_everywhere_ignores_default_profile(self):
        self.setup_tree()
        self.run_cli('rm', 'all', '--everywhere')
        self.assertEqual(self.removed(), [f'saved-{n}' for n in range(1, 6)])

    def test_everywhere_profile_filter(self):
        self.setup_tree()
        self.run_cli('rm', 'all', '--everywhere', '-p', 'default')
        self.assertEqual(self.removed(), ['saved-2'])

    def test_empty_and_partial_failure(self):
        self.assertIn('No registered instances', self.run_cli('rm', 'all', '--workspace').stdout)
        self.register(1)
        self.register(2)
        output = self.run_cli('rm', '-i', '1,2', ok=False, env={'MOCK_FAIL_REMOVE': 'saved-1'})
        self.assertIn('failed for id 1', output.stderr)
        self.assertEqual(self.removed(), ['saved-1', 'saved-2'])
        self.assertEqual(json.loads(self.state.read_text())['pods'], ['saved-1'])

    def test_multi_respawn(self):
        self.register(1)
        self.register(2, self.work / 'second', 'infra')
        (self.work / '.codex-container.env').write_text('CODEX_ENV_FIRST=one\n')
        (self.work / 'second/.codex-container.env').write_text('CODEX_ENV_SECOND=two\n')
        self.run_cli('respawn', '-i', '2,1')
        apps = [c for c in self.calls() if c[0] == 'run' and c[c.index('--name') + 1].endswith('-app')]
        self.assertEqual(len(apps), 2)
        self.assertIn('FIRST', apps[0])
        self.assertIn('SECOND', apps[1])
        self.assertNotIn('FIRST', apps[1])
        self.assertIn('codex:infra', apps[1])

    def app_runs(self):
        return [c for c in self.calls() if c[0] == 'run' and c[c.index('--name') + 1].endswith('-app')]

    def test_package_cache_default_empty_and_retention(self):
        for value in (None, ''):
            env = {} if value is None else {'CODEX_PACKAGE_CACHE_ENABLE': value}
            self.run_cli('replace', '-p', 'alpine', env=env)
            self.assertTrue(any(':/var/cache/apk:z' in arg for arg in self.app_runs()[-1]))
        cache = self.base / 'package-cache/alpine/3.24/amd64/apk'
        self.assertTrue(cache.is_dir())
        (cache / 'saved.apk').touch()
        self.run_cli('rm', '-p', 'alpine')
        self.assertTrue((cache / 'saved.apk').exists())

    def test_cache_disabled_and_invalid_settings(self):
        self.run_cli('spawn', '-p', 'alpine', env={'CODEX_PACKAGE_CACHE_ENABLE':'0'})
        self.assertFalse(any('/var/cache/apk' in arg for arg in self.app_runs()[-1]))
        self.assertFalse((self.base / 'package-cache').exists())
        self.run_cli('replace', '-p', 'alpine', env={'CODEX_PACKAGE_CACHE_ENABLE':'invalid'}, ok=False)
        self.run_cli('replace', '-p', 'alpine', '--no-package-cache', env={'CODEX_PACKAGE_CACHE_ENABLE':'invalid'})
        self.assertFalse(any('/var/cache/apk' in arg for arg in self.app_runs()[-1]))

    def test_cache_env_file_and_cli_precedence(self):
        (self.work / '.codex-container.env').write_text('CODEX_PACKAGE_CACHE_ENABLE=0\n')
        self.run_cli('replace', '-p', 'alpine')
        self.assertFalse(any('/var/cache/apk' in arg for arg in self.app_runs()[-1]))
        self.run_cli('replace', '-p', 'alpine', env={'CODEX_PACKAGE_CACHE_ENABLE':'1'})
        self.assertTrue(any('/var/cache/apk' in arg for arg in self.app_runs()[-1]))
        self.run_cli('replace', '-p', 'alpine', '--no-package-cache', env={'CODEX_PACKAGE_CACHE_ENABLE':'1'})
        self.assertFalse(any('/var/cache/apk' in arg for arg in self.app_runs()[-1]))

    def test_cache_metadata_and_isolation(self):
        self.run_cli('replace', '-p', 'alpine', env={'MOCK_IMAGE_ARCH':'arm64'})
        self.assertTrue((self.base / 'package-cache/alpine/3.24/arm64/apk').is_dir())
        self.run_cli('replace', env={'CONTAINER_IMAGE':'custom:image', 'MOCK_IMAGE_DISTRO':'alpine', 'MOCK_IMAGE_BASE':'alpine:3.23'})
        self.assertTrue((self.base / 'package-cache/alpine/3.23/amd64/apk').is_dir())
        self.run_cli('replace', env={'CONTAINER_IMAGE':'custom:unlabelled', 'MOCK_IMAGE_DISTRO':''})
        self.assertFalse(any('/var/cache/apk' in arg for arg in self.app_runs()[-1]))
        self.run_cli('replace', env={'CONTAINER_IMAGE':'custom:bad-tag', 'MOCK_IMAGE_DISTRO':'alpine', 'MOCK_IMAGE_BASE':'alpine:../escape'})
        self.assertFalse(any('/var/cache/apk' in arg for arg in self.app_runs()[-1]))

    def test_cache_batch_opt_out_and_existing_mount_notice(self):
        self.register(1, profile='alpine')
        self.register(2, self.work / 'second', 'alpine')
        output = self.run_cli('spawn', '-i', '1', '--no-package-cache')
        self.assertIn('existing mounts are unchanged', output.stderr)
        self.assertEqual(self.app_runs(), [])
        self.run_cli('respawn', '-i', '1-2', '--no-package-cache')
        self.assertEqual(len(self.app_runs()), 2)
        self.assertTrue(all(not any('/var/cache/apk' in arg for arg in c) for c in self.app_runs()))
        self.assertFalse((self.base / 'package-cache').exists())

    def test_environment_help_static_and_complete(self):
        import re
        bad = self.base / 'bad.env'
        bad.write_text('invalid env\n')
        output = self.run_cli('help', 'env', env={'CODEX_CONTAINER_ENV_FILES':str(bad),
                                               'OPENAI_API_KEY':'secret-test-value'}).stdout
        self.assertEqual(output, (REPO/'docs/environment.md').read_text())
        self.assertNotIn('secret-test-value', output)
        self.assertEqual(self.calls(), [])
        source = LAUNCHER.read_text()
        names = set(re.findall(r'^\s*: "\$\{([A-Z][A-Z0-9_]*):=', source, re.M))
        for name in names:
            self.assertIn('`'+name+'`', output)
        for name, default in re.findall(r'^\s*: "\$\{([A-Z][A-Z0-9_]*):=(.*)\}"$', source, re.M):
            escaped = (default or '(empty)').replace('|', '\\|')
            self.assertIn('| `'+name+'` | `'+escaped+'` |', output)
        firewall = (REPO/'firewall/firewall-common').read_text()
        for name in set(re.findall(r'\$\{(CODEX_FIREWALL_[A-Z_]+)', firewall)):
            self.assertIn('`'+name+'`', output)
        for internal in ('CODEX_CONTAINER_LAUNCHER_SNAPSHOT', 'CODEX_CONTAINER_BATCH_VERIFY_REMOVAL'):
            self.assertNotIn(internal, output)

    def test_completion_generation_and_bash(self):
        bad = self.base / 'bad.env'
        bad.write_text('invalid env\n')
        script = self.run_cli('completion', 'bash', env={'CODEX_CONTAINER_ENV_FILES': str(bad)}).stdout
        self.assertIn('complete -F _codex_container_launcher codex', script)
        self.assertNotIn('\n_codex()', script)
        completion = self.base / 'completion.bash'
        completion.write_text(script)
        subprocess.run(['bash', '-n', str(completion)], check=True)
        checks = r'''
source "$1"
check() {
  local expected="$1"; shift
  COMP_WORDS=(codex "$@")
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  _codex_container_launcher
  [[ " ${COMPREPLY[*]} " == *" $expected "* ]] || exit 1
}
check respawn re
check -i respawn -
check --tree rm all --t
check zsh completion z
check --profile respawn -i 4 --p
check --id copy --i
check --no-package-cache spawn --no-package
check env help e
check 'with space' -d 'with'
COMP_WORDS=(codex copy source --i); COMP_CWORD=3; _codex_container_launcher
[[ ${#COMPREPLY[@]} = 0 ]] || exit 1
COMP_WORDS=(codex -- --h); COMP_CWORD=2; _codex_container_launcher
[[ ${#COMPREPLY[@]} = 0 ]] || exit 1
COMP_WORDS=(codex shell -i 4 bash --h); COMP_CWORD=5; _codex_container_launcher
[[ ${#COMPREPLY[@]} = 0 ]] || exit 1
'''
        (self.work / 'with space').mkdir()
        subprocess.run(['bash', '-c', checks, 'bash', str(completion)], check=True, cwd=self.work)
        self.assertEqual(self.calls(), [])
        self.run_cli('completion', 'fish', ok=False)

    def test_zsh_completion(self):
        completion = self.base / 'completion.zsh'
        completion.write_text(self.run_cli('completion', 'zsh').stdout)
        subprocess.run(['zsh', '-n', str(completion)], check=True)
        checks = r'''
autoload -Uz compinit; compinit -D
source "$1"
[[ "${_comps[codex]}" = _codex_container_launcher ]] || exit 1
# Stub the shell's completion builtins to check candidate dispatch without a TTY.
compadd() { candidates=("${@:2}"); }
_path_files() { kind=directory; }
_files() { kind=files; }
words=(codex respawn -); CURRENT=3
_codex_container_launcher
[[ " ${candidates[*]} " = *' -i '* ]] || exit 1
words=(codex rm all --t); CURRENT=4
_codex_container_launcher
[[ " ${candidates[*]} " = *' --tree '* ]] || exit 1
words=(codex -d ''); CURRENT=3
_codex_container_launcher
[[ "$kind" = directory ]] || exit 1
candidates=()
words=(codex -- --h); CURRENT=3
_codex_container_launcher
[[ ${#candidates} = 0 ]] || exit 1
words=(codex ''); CURRENT=2
_codex_container_launcher
[[ " ${candidates[*]} " = *' respawn '* ]] || exit 1
'''
        subprocess.run(['zsh', '-f', '-c', checks, 'zsh', str(completion)], check=True, env=self.env)


if __name__ == '__main__':
    unittest.main()
