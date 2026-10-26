"""Independent real-package observer; never install or write the caller's home."""
import base64
import copy
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(root):
    result = {}

    def visit(p, key):
        s = p.lstat()
        mode = stat.S_IMODE(s.st_mode)
        if p.is_symlink():
            row = dict(kind='link', target=os.readlink(p))
        elif p.is_dir():
            row = dict(kind='dir')
        elif p.is_file():
            row = dict(kind='file', sha256=digest(p.read_bytes()), executable=bool(mode & 0o111))
        else:
            raise AssertionError('unsupported fixture type: ' + str(p))
        result[key] = dict(row, mode=mode)
        if row['kind'] == 'dir':
            for child in sorted(p.iterdir()):
                if key == '' and child.name in ('.git', 'dist'):
                    continue
                visit(child, (key + '/' + child.name).lstrip('/'))
    visit(Path(root), '')
    return result


def semantic(row):
    return {k: v for k, v in row.items() if k != 'mode'}


def inspect_archive(archive, expected, modes):
    actual = {}
    roots = set()
    with tarfile.open(archive, 'r:gz') as tf:
        for member in tf:
            name = member.name.rstrip('/')
            assert not name.startswith('/') and '..' not in name.split('/'), 'unsafe payload path'
            if member.isfile() and Path(name).name.startswith('._'):
                if tf.extractfile(member).read(4) == b'\x00\x05\x16\x07':
                    continue  # AppleDouble metadata, not arbitrary hidden application files.
            parts = name.split('/', 1)
            roots.add(parts[0])
            key = parts[1] if len(parts) == 2 else ''
            assert key not in actual, 'duplicate payload path: ' + key
            if member.isdir():
                row = dict(kind='dir')
            elif member.issym():
                row = dict(kind='link', target=member.linkname)
            elif member.isfile():
                row = dict(kind='file', sha256=digest(tf.extractfile(member).read()), executable=bool(member.mode & 0o111))
            else:
                raise AssertionError('changed payload type: ' + key)
            actual[key] = dict(row, mode=member.mode)
    assert len(roots) == 1, 'archive must have one application root'
    assert set(actual) == set(expected), 'payload paths differ'
    for key in sorted(expected):
        want, got = expected[key], actual[key]
        assert semantic(got) == semantic(want), 'payload content/type/link/executable differs: ' + key
        if want['kind'] != 'link':
            field = 'directory_mode' if want['kind'] == 'dir' else ('executable_mode' if want['executable'] else 'file_mode')
            assert got['mode'] == int(modes[field], 8), 'public mode differs: ' + (key or '<root>') + ' = ' + oct(got['mode'])
    return len(actual)


def cleanup(root, remove=shutil.rmtree):
    remove(root)  # Deliberately no ignore_errors, force success, or swallowed exception.
    assert not Path(root).exists(), 'cleanup left test outputs'


def run(command, cwd, env):
    r = subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert r.returncode == 0, repr(command) + '\n' + r.stdout
    return r.stdout


def write(p, data, mode=0o644):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    p.chmod(mode)


def cache_snapshot(root):
    # Unlike a source snapshot, no cache entry is excluded as a build output.
    assert not any(p.name in ('.git', 'dist') for p in root.iterdir()), 'unexpected cache entry'
    return snapshot(root)


def lock_inputs(repo):
    locks, records = {}, {}
    for bundle in ('quint', 'cucumber'):
        name = 'packaging/' + bundle + '/package-lock.json'
        data = (repo / name).read_bytes()
        locks[name] = digest(data)
        for row in json.loads(data)['packages'].values():
            if 'integrity' not in row:
                continue
            assert row['resolved'].startswith('https://registry.npmjs.org/'), 'non-registry fixture input'
            algorithm, encoded = row['integrity'].split('-', 1)
            raw = base64.b64decode(encoded, validate=True)
            assert algorithm == 'sha512' and len(raw) == 64, 'fixture requires pinned SHA-512 content'
            h = raw.hex()
            rel = 'content-v2/sha512/' + h[:2] + '/' + h[2:4] + '/' + h[4:]
            records[rel] = h
    identity = digest(json.dumps(locks, sort_keys=True, separators=(',', ':')).encode())
    return identity, locks, records


def private_directory(p):
    p.mkdir(mode=0o700, exist_ok=True)
    s = p.lstat()
    assert stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid() and stat.S_IMODE(s.st_mode) == 0o700, 'unsafe prepared-input directory: ' + str(p)


def blob_bytes(p, h):
    try:
        before = p.lstat()
    except FileNotFoundError:
        raise AssertionError('offline npm prerequisite missing: lock-pinned blob ' + str(p)) from None
    assert stat.S_ISREG(before.st_mode), 'offline content is not a regular file: ' + str(p)
    with p.open('rb') as f:
        data = f.read()
    assert hashlib.sha512(data).hexdigest() == h, 'offline seed integrity mismatch: ' + str(p)
    after = p.lstat()
    fields = ('st_mode', 'st_uid', 'st_size', 'st_mtime_ns')
    signature = tuple(getattr(before, k) for k in fields)
    assert signature == tuple(getattr(after, k) for k in fields), 'donor changed during read'
    return data, signature


def validate_seed(seed, locks, records):
    rows = cache_snapshot(seed)
    wanted = {'', 'identity.json', '_cacache', '_cacache/tmp'}
    for rel, h in records.items():
        key = '_cacache/' + rel
        wanted.add(key)
        while '/' in key:
            key = key.rsplit('/', 1)[0]
            wanted.add(key)
        blob_bytes(seed / '_cacache' / rel, h)
    assert set(rows) == wanted, 'prepared-input paths differ'
    for key, row in rows.items():
        assert row['kind'] in ('dir', 'file') and (seed / key).lstat().st_uid == os.getuid(), 'unsafe prepared-input member'
    assert json.loads((seed / 'identity.json').read_text()) == locks, 'prepared-input lock identity differs'
    return rows


def warm_cache(repo, donor=None, store=None):
    identity, locks, records = lock_inputs(repo)
    donor = donor if donor is not None else Path.home() / '.npm/_cacache'
    # Stable across disposable scratch TMPDIRs; never a directory in an account home.
    store = store if store is not None else Path('/tmp') / ('kogen-public-npm-' + str(os.getuid()))
    private_directory(store)
    seed = store / identity
    fd = os.open(store / (identity + '.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'rb') as lock:
        s = os.fstat(lock.fileno())
        assert stat.S_ISREG(s.st_mode) and s.st_uid == os.getuid() and stat.S_IMODE(s.st_mode) == 0o600, 'unsafe preparation lock'
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        if seed.exists() or seed.is_symlink():
            private_directory(seed)
            validate_seed(seed, locks, records)
            return seed, False
        partial = Path(tempfile.mkdtemp(prefix='.preparing-', dir=store))
        try:
            (partial / '_cacache/tmp').mkdir(parents=True)
            index = donor / 'index-v5'
            index_before = index.stat().st_mtime_ns if index.exists() else None
            selected = {}
            for rel, h in records.items():
                data, signature = blob_bytes(donor / rel, h)
                selected[rel] = signature
                write(partial / '_cacache' / rel, data, 0o600)
            for rel, h in records.items():
                assert blob_bytes(donor / rel, h)[1] == selected[rel], 'preparation changed donor content/mode/mtime'
            assert (index.stat().st_mtime_ns if index.exists() else None) == index_before, 'preparation changed donor index mtime'
            write(partial / 'identity.json', json.dumps(locks, sort_keys=True).encode(), 0o600)
            validate_seed(partial, locks, records)
            partial.rename(seed)
        finally:
            if partial.exists():
                cleanup(partial)
        return seed, True


def npm_environment(env, home, cache, logs):
    for p in (home, logs):
        p.mkdir(mode=0o700, exist_ok=True)
    write(home / 'empty.npmrc', b'')
    write(home / 'empty-global.npmrc', b'')
    env.update(HOME=str(home), npm_config_cache=str(cache), npm_config_offline='true', npm_config_userconfig=str(home / 'empty.npmrc'), npm_config_globalconfig=str(home / 'empty-global.npmrc'), npm_config_logs_dir=str(logs), npm_config_logs_max='0', npm_config_update_notifier='false')


def offline_npm(args, cwd, env, mask=None):
    assert args and args[0] == 'ci', 'expected real npm ci'
    assert env['npm_config_offline'] == 'true', 'offline npm environment required'
    cache = Path(env['npm_config_cache'])
    before = cache_snapshot(cache)
    command = [env['PUBLIC_REAL_NPM'], *args, '--offline']
    if mask is not None:
        command = ['/bin/sh', '-c', 'umask "$1"; shift; exec "$@"', 'offline-control', mask, *command]
    try:
        return subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    finally:
        assert cache_snapshot(cache) == before, 'real npm changed prepared working cache'


def cache_controls(which):
    repo = Path(__file__).resolve().parents[2]
    root = Path(tempfile.mkdtemp(prefix='kogen-public-npm-control-')).resolve()
    seed = seed_before = None
    try:
        seed, _ = warm_cache(repo)
        seed_before = cache_snapshot(seed)
        identity, locks, records = lock_inputs(repo)
        reused, prepared = warm_cache(repo, donor=root / 'unavailable-donor')
        assert reused == seed and not prepared, 'seed reuse attempted preparation'
        cache = root / 'cache'
        shutil.copytree(seed / '_cacache', cache / '_cacache')
        env = {k: v for k, v in os.environ.items() if not k.lower().startswith('npm_config_')}
        env.update(PUBLIC_REAL_NPM=shutil.which('npm'), TMPDIR=str(root))
        assert env['PUBLIC_REAL_NPM'], 'npm required'
        npm_environment(env, root / 'home', cache, root / 'logs')
        for bundle in ('quint', 'cucumber'):
            work = root / bundle
            work.mkdir()
            for name in ('package.json', 'package-lock.json'):
                shutil.copyfile(repo / 'packaging' / bundle / name, work / name)
        if which == 'bad':
            lock = json.loads((root / 'quint/package-lock.json').read_text())
            row = next(r for r in lock['packages'].values() if r.get('resolved', '').endswith('/yargs-parser-21.1.1.tgz'))
            h = base64.b64decode(row['integrity'].split('-', 1)[1]).hex()
            (cache / '_cacache/content-v2/sha512' / h[:2] / h[2:4] / h[4:]).unlink()
            r = offline_npm(['ci', '--ignore-scripts', '--no-audit', '--no-fund', '--loglevel=error'], root / 'quint', env)
            assert r.returncode != 0 and 'ENOTCACHED' in r.stdout and row['resolved'] in r.stdout, 'missing content did not produce real offline rejection: ' + r.stdout
        else:
            cache_before = cache_snapshot(cache)
            for mask in ('077', '022'):
                for bundle in ('quint', 'cucumber'):
                    args = ['ci', '--ignore-scripts', '--no-audit', '--no-fund', '--silent']
                    if bundle == 'cucumber':
                        args.append('--omit=dev')
                    r = offline_npm(args, root / bundle, env, mask)
                    assert r.returncode == 0, r.stdout
            assert cache_snapshot(cache) == cache_before, 'offline reuse changed cache'
            broken = root / 'broken-seed'
            shutil.copytree(seed, broken)
            rel = next(iter(records))
            write(broken / '_cacache' / rel, b'corrupt prepared content', 0o600)
            try:
                validate_seed(broken, locks, records)
            except AssertionError as e:
                assert str(e).startswith('offline seed integrity mismatch:'), str(e)
            else:
                raise AssertionError('corrupt seed accepted')
            failed_store = root / 'failed-preparation'
            try:
                warm_cache(repo, donor=root / 'unavailable-donor', store=failed_store)
            except AssertionError as e:
                assert str(e).startswith('offline npm prerequisite missing:'), str(e)
            else:
                raise AssertionError('missing donor silently prepared')
            assert sorted(p.name for p in failed_store.iterdir()) == [identity + '.lock'], 'failed preparation left partial content'
    finally:
        try:
            if seed_before is not None:
                assert cache_snapshot(seed) == seed_before, 'controls changed prepared seed'
        finally:
            cleanup(root)
    assert not root.exists(), 'offline controls left test outputs'
    print('missing offline content rejected' if which == 'bad' else 'offline preparation controls accepted')
    return 1 if which == 'bad' else 0


def fixture_archive(p, rows):
    with tarfile.open(p, 'w:gz') as tf:
        for key, row in rows.items():
            m = tarfile.TarInfo('kogen-control' + ('/' + key if key else ''))
            m.mode = row['mode']
            if row['kind'] == 'dir':
                m.type = tarfile.DIRTYPE
                tf.addfile(m)
            elif row['kind'] == 'link':
                m.type = tarfile.SYMTYPE
                m.linkname = row['target']
                tf.addfile(m)
            else:
                data = row['data']
                m.size = len(data)
                tf.addfile(m, io.BytesIO(data))


def controls(which):
    root = Path(tempfile.mkdtemp(prefix='kogen-public-control-'))
    modes = dict(file_mode='0644', executable_mode='0755', directory_mode='0755')
    try:
        tree = root / 'tree'
        tree.mkdir(mode=0o755)
        tree.chmod(0o755)
        write(tree / 'data', b'public bytes\x00\xff', 0o644)
        write(tree / 'tool', b'#!/bin/sh\nexit 0\n', 0o755)
        (tree / 'link').symlink_to('data')
        expected = snapshot(tree)
        rows = copy.deepcopy(expected)
        for key, row in rows.items():
            if row['kind'] == 'file':
                row['data'] = (tree / key).read_bytes()
        archive = root / 'fixture.tar.gz'
        fixture_archive(archive, rows)
        inspect_archive(archive, expected, modes)
        if which == 'bad':
            rows['data']['mode'] = 0o600
            fixture_archive(archive, rows)
            try:
                inspect_archive(archive, expected, modes)
            except AssertionError as e:
                assert str(e).startswith('public mode differs: data'), str(e)
                print('owner-only archive rejected')
                return 1
            raise AssertionError('observer accepted owner-only entry')
        mutations = []
        for key, mode in [('', 0o700), ('data', 0o600), ('tool', 0o700), ('data', 0o755), ('tool', 0o644)]:
            bad = copy.deepcopy(rows)
            bad[key]['mode'] = mode
            mutations.append(bad)
        bad = copy.deepcopy(rows)
        bad['data']['data'] = b'changed bytes'
        mutations.append(bad)
        bad = copy.deepcopy(rows)
        bad['link']['target'] = 'tool'
        mutations.append(bad)
        bad = copy.deepcopy(rows)
        bad['data'] = dict(kind='link', target='tool', mode=0o777)
        mutations.append(bad)
        bad = copy.deepcopy(rows)
        bad['renamed'] = bad.pop('data')
        mutations.append(bad)
        bad = copy.deepcopy(rows)
        del bad['tool']
        mutations.append(bad)
        for bad in mutations:
            fixture_archive(archive, bad)
            try:
                inspect_archive(archive, expected, modes)
            except AssertionError:
                pass
            else:
                raise AssertionError('observer accepted corrupt control')
        owned = root / 'cleanup'
        owned.mkdir()

        def refuse(_):
            raise OSError('injected cleanup failure')
        try:
            cleanup(owned, refuse)
        except OSError as e:
            assert str(e) == 'injected cleanup failure' and owned.exists()
        else:
            raise AssertionError('cleanup failure swallowed')
        cleanup(owned)
    finally:
        cleanup(root)
    print('archive controls accepted')
    return 0


def expected_payload(src, trace, stage):
    expected = {}

    def merge(prefix, rows):
        for key, value in rows.items():
            expected[(prefix + ('/' + key if key else '')).strip('/')] = value
    for source, dest in [('packaging/install.sh', 'install.sh'), ('packaging/README.md', 'README.md'), ('LICENSE', 'LICENSE'), ('NOTICE', 'NOTICE'), ('packaging/licenses', 'licenses'), ('docs/testing-rules.md', 'docs/testing-rules.md'), ('docs/configuration.md', 'docs/configuration.md')]:
        merge(dest, snapshot(src / source))
    for bundle in ('quint', 'cucumber'):
        rows = json.loads((trace / (bundle + '.json')).read_text())
        merge('lib/' + bundle, rows)
    for key in ('bin/kogen', 'lib/VERSION', 'lib/VERSION.json', 'licenses/npm-packages.md', 'TARGET'):
        assert stage[key]['kind'] == 'file', 'missing generated regular file: ' + key
        expected[key] = dict(stage[key], executable=(key == 'bin/kogen'))
    for key in list(expected):
        parent = key
        while '/' in parent:
            parent = parent.rsplit('/', 1)[0]
            expected.setdefault(parent, dict(kind='dir', mode=0o755))
    expected[''] = dict(kind='dir', mode=0o755)
    return expected


def exercise(configs):
    repo = Path(__file__).resolve().parents[2]
    root = Path(tempfile.mkdtemp(prefix='kogen-public-package-')).resolve()
    receipt = dict(umasks=[], entries=[], verified=False, inputs_unchanged=False, private_unchanged=False, cleaned=False, offline_rows=[], cache_unchanged=False)
    failures = []
    seed = seed_before = cache_before = None
    try:
        src, home, cache, trace, wrappers = [root / n for n in ('source', 'home', 'cache', 'trace', 'wrappers')]
        for d in (src, home, cache, trace, wrappers, root / 'tmp'):
            d.mkdir(mode=0o700)
        for name in ('cli', 'packaging', 'docs'):
            shutil.copytree(repo / name, src / name, symlinks=True, ignore=shutil.ignore_patterns('node_modules', '.git', 'dist', '__pycache__'))
        for name in ('LICENSE', 'NOTICE'):
            shutil.copy2(repo / name, src / name)
        private = root / 'private'
        private.mkdir(mode=0o700)
        write(private / 'sentinel', b'private outside-stage data\n', 0o600)
        fixture = src / 'packaging/licenses/public-mode-fixture'
        write(fixture / 'data', b'copied non-executable\x00\xff\n', 0o600)
        write(fixture / 'tool', b'#!/bin/sh\nexit 0\n', 0o700)
        (fixture / 'external-link').symlink_to(private / 'sentinel')
        copied = ['LICENSE', 'NOTICE', 'packaging/install.sh', 'packaging/README.md', 'packaging/licenses', 'docs/testing-rules.md', 'docs/configuration.md', 'packaging/quint/package.json', 'packaging/quint/package-lock.json', 'packaging/cucumber/package.json', 'packaging/cucumber/package-lock.json']
        for name in copied:
            p = src / name
            for key, row in snapshot(p).items():
                q = p / key if key else p
                if row['kind'] != 'link':
                    q.chmod(0o700 if row['kind'] == 'dir' or row.get('executable') else 0o600)
        before, private_before = snapshot(src), snapshot(private)
        seed, _ = warm_cache(src)
        seed_before = cache_snapshot(seed)
        receipt['preparation_identity'] = seed.name
        shutil.copytree(seed / '_cacache', cache / 'npm/_cacache')
        cache_before = cache_snapshot(cache / 'npm')
        env = {k: v for k, v in os.environ.items() if not k.lower().startswith('npm_config_')}
        env.update(HOME=str(home), XDG_CACHE_HOME=str(cache), XDG_CONFIG_HOME=str(home / 'config'), TMPDIR=str(root / 'tmp'), GOCACHE=str(cache / 'go'), GOPATH=str(cache / 'gopath'), GOENV='off', GOTOOLCHAIN='local', GOPROXY='off', GOSUMDB='off', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Packaging Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='Packaging Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        npm_environment(env, home, cache / 'npm', root / 'npm-logs')
        for args in (['init', '-q'], ['add', '.'], ['-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Packaging fixture']):
            run(['git', *args], src, env)
        env.update(PUBLIC_REAL_NPM=shutil.which('npm'), PUBLIC_REAL_TAR=shutil.which('tar'), PUBLIC_TRACE=str(trace), PUBLIC_SOURCE=str(src))
        assert env['PUBLIC_REAL_NPM'] and env['PUBLIC_REAL_TAR'], 'npm and tar required'
        for tool in ('npm', 'tar'):
            text = '#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(Path(__file__).resolve())) + ' observe-' + tool + ' "$@"\n'
            write(wrappers / tool, text.encode(), 0o755)
        env['PATH'] = str(wrappers) + os.pathsep + env['PATH']
        for config in configs:
            mask = config['umask']
            assert mask in ('077', '022'), 'unexpected test umask'
            for f in trace.iterdir():
                f.unlink()
            output = run(['/bin/sh', '-c', 'umask "$1"; exec sh packaging/package.sh', 'public-package', mask], src, env)
            assert cache_snapshot(cache / 'npm') == cache_before, 'packaging changed npm cache'
            assert cache_snapshot(seed) == seed_before, 'packaging changed prepared seed'
            offline = [json.loads((trace / (b + '-offline.json')).read_text()) for b in ('quint', 'cucumber')]
            assert offline == [dict(bundle=b, command='ci', offline=True) for b in ('quint', 'cucumber')], 'missing real offline npm observation'
            receipt['offline_rows'].append([r['bundle'] for r in offline])
            archive = Path(output.strip().splitlines()[-1])
            assert archive.is_file() and archive.parent == src / 'dist', output
            stage = json.loads((trace / 'stage.json').read_text())
            expected = expected_payload(src, trace, stage)
            receipt['umasks'].append(mask)
            try:
                receipt['entries'].append(inspect_archive(archive, expected, config))
            except AssertionError as e:
                failures.append('umask ' + mask + ': ' + str(e))
        assert snapshot(src) == before, 'packaging changed source bytes/types/modes'
        assert snapshot(private) == private_before, 'packaging followed a symlink into private data'
        receipt.update(inputs_unchanged=True, private_unchanged=True, cache_unchanged=True)
        assert not failures, '\n'.join(failures)
        receipt['verified'] = True
    finally:
        try:
            if cache_before is not None:
                assert cache_snapshot(root / 'cache/npm') == cache_before, 'working npm cache changed on exit'
            if seed_before is not None:
                assert cache_snapshot(seed) == seed_before, 'prepared seed changed on exit'
        finally:
            cleanup(root)
    receipt['cleaned'] = not root.exists()
    print(json.dumps(receipt))
    return 0


def main():
    mode = sys.argv[1]
    if mode in ('control', 'cache-control'):
        assert sys.argv[2] in ('good', 'bad')
        return controls(sys.argv[2]) if mode == 'control' else cache_controls(sys.argv[2])
    if mode == 'exercise':
        return exercise(json.loads(sys.argv[2]))
    trace = Path(os.environ['PUBLIC_TRACE'])
    if mode == 'observe-npm':
        r = offline_npm(sys.argv[2:], Path.cwd(), os.environ)
        sys.stdout.write(r.stdout)
        if r.returncode:
            return r.returncode
        bundle = Path.cwd().name
        (trace / (bundle + '.json')).write_text(json.dumps(snapshot(Path.cwd())))
        (trace / (bundle + '-offline.json')).write_text(json.dumps(dict(bundle=bundle, command='ci', offline=True)))
        return 0
    if mode == 'observe-tar':
        work = [p for p in (Path(os.environ['PUBLIC_SOURCE']) / 'dist').iterdir() if p.is_dir()]
        assert len(work) == 1, 'expected one staging payload'
        (trace / 'stage.json').write_text(json.dumps(snapshot(work[0])))
        os.execv(os.environ['PUBLIC_REAL_TAR'], [os.environ['PUBLIC_REAL_TAR'], *sys.argv[2:]])
    raise AssertionError('unknown driver mode: ' + mode)


if __name__ == '__main__':
    sys.exit(main())
