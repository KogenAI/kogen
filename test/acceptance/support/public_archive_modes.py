"""Maintain INS-2 by reusing the real offline packaging regression."""
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

# Import without leaving bytecode in the source checkout.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'features/steps'))
import release_archive_public_modes as regression


def fixture_npm(args):
    # Delegate the actual offline install, then vary only the executable bit's
    # class in its disposable output. The shared observer snapshots these modes
    # before package.sh normalizes them, so owner-bit-only logic cannot pass.
    result = subprocess.run([os.environ['KOGEN_PUBLIC_MODE_REAL_NPM'], *args])
    if result.returncode:
        return result.returncode
    tools = sorted(p for p in Path('node_modules').rglob('*')
                   if stat.S_ISREG(p.lstat().st_mode) and p.stat().st_mode & 0o111)
    assert len(tools) >= 2, 'expected real npm executable fixtures'
    for tool, mode in zip(tools, (0o610, 0o601)):
        tool.chmod(mode)
    return 0


def exercise():
    root = Path(tempfile.mkdtemp(prefix='kogen-public-bit-classes-')).resolve()
    original_env = os.environ.copy()
    try:
        npm = shutil.which('npm')
        assert npm, 'npm required'
        wrapper = ('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' +
                   shlex.quote(str(Path(__file__).resolve())) + ' fixture-npm "$@"\n')
        regression.write(root / 'npm', wrapper.encode(), 0o755)
        os.environ.update(KOGEN_PUBLIC_MODE_REAL_NPM=npm,
                          PATH=str(root) + os.pathsep + os.environ['PATH'])
        rows = [dict(umask=mask, file_mode='0644', executable_mode='0755', directory_mode='0755')
                for mask in ('077', '022')]
        return regression.exercise(rows)
    finally:
        os.environ.clear()
        os.environ.update(original_env)
        regression.cleanup(root)


if __name__ == '__main__':
    sys.exit(fixture_npm(sys.argv[2:]) if sys.argv[1:] and sys.argv[1] == 'fixture-npm' else exercise())
