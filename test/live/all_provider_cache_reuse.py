"""One exact-archive native journey, with inherited Git and login custody."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--preflight-only', action='store_true',
                        help='Check the installed archive, baseline and inherited Git guards without inference')
    args = parser.parse_args()
    archive = args.archive.resolve(strict=True)
    output = args.output.absolute()
    # Exclusive creation precedes installation, commands and any possible inference.
    output.mkdir(mode=0o700)
    os.umask(0o077)
    source = Path(__file__).resolve().parents[2]
    repo = output / 'project'
    receipt = dict(status='stopped-not-qualified', archive_sha256=None,
                   source_candidate_tree=None, approved_contract_sha256=None,
                   commands=[], roles={'shape': ['chatgpt', 'gpt-6.1-sol', 'high'],
                                       'build': ['chatgpt', 'gpt-6.1-sol', 'medium'],
                                       'review': ['anthropic', 'claude-sonnet-5-5', 'medium']},
                   native_usage=None)

    def save():
        temporary = output / 'receipt.tmp'
        temporary.write_text(json.dumps(receipt, indent=2) + '\n')
        temporary.chmod(0o600)
        temporary.replace(output / 'receipt.json')

    def run(name, command, cwd=repo, expected=0, env=None):
        with (output / (name + '.log')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, check=False)
        receipt['commands'].append({'name': name, 'exit': result.returncode})
        save()
        text = (output / (name + '.log')).read_text(errors='replace')
        if result.returncode != expected:
            raise RuntimeError(name + ' stopped; inspect private command evidence')
        return text

    def interrupted(signum, _frame):
        raise RuntimeError('interrupted by signal ' + str(signum))

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    save()
    try:
        receipt['archive_sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
        # Temporary index captures current candidate without touching the real index.
        env = dict(os.environ, GIT_INDEX_FILE=str(output / 'source.index'))
        run('source-read-tree', ['git', 'read-tree', 'HEAD'], source, env=env)
        run('source-add', ['git', 'add', '-A', '--', '.'], source, env=env)
        receipt['source_candidate_tree'] = run('source-tree', ['git', 'write-tree'], source, env=env).strip()
        run('node-prerequisite', ['node', '--version'], source)
        run('git-identity', ['git', 'var', 'GIT_AUTHOR_IDENT'], source)
        run('git-committer', ['git', 'var', 'GIT_COMMITTER_IDENT'], source)
        extract = output / 'archive'
        extract.mkdir(mode=0o700)
        run('extract', ['tar', '-xzf', str(archive), '-C', str(extract)], source)
        releases = [p for p in extract.iterdir() if (p / 'install.sh').is_file()]
        if len(releases) != 1:
            raise RuntimeError('archive must contain one installer')
        prefix = output / 'prefix'
        run('install', ['sh', str(releases[0] / 'install.sh'), '--prefix', str(prefix)], source)
        binary = str(prefix / 'bin/kogen')
        receipt['installed_version'] = run('version', [binary, 'version'], source).strip()
        logins = run('logins', [binary, 'provider', 'list'], source)
        if not re.search(r'^chatgpt: signed in(?:\s|$)', logins, re.MULTILINE):
            raise RuntimeError('ChatGPT saved login is required before inference')
        if not re.search(r'^anthropic: key saved \(not verified\)$', logins, re.MULTILINE):
            raise RuntimeError('Anthropic saved key is required before inference')
        repo.mkdir(mode=0o700)
        (repo / '.kogen').mkdir(mode=0o700)
        (repo / 'app.txt').write_text('baseline\n')
        (repo / 'check.js').write_text("const fs=require('node:fs'); const assert=require('node:assert/strict');\nassert.ok(['baseline\\n','candidate\\n'].includes(fs.readFileSync('app.txt','utf8')));\n")
        (repo / 'README.md').write_text('# Cache journey\n\nA tiny exact text change. Run node check.js. The configured check accepts baseline and candidate; Intent acceptance must require exactly candidate.\n')
        (repo / '.gitignore').write_text('.kogen/local/\n')
        runner = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
        (repo / '.kogen/project.yaml').write_text('version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - {name: check, run: "node check.js"}\n  acceptance:\n    run: \'' + runner + '\'\n    steps_dir: features/steps\nprotect: []\nmodels:\n  shape: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\n  build: {provider: chatgpt, model: gpt-6.1-sol, effort: medium}\n  review: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}\nshape_workers:\n  enabled: false\n')
        run('git-init', ['git', 'init', '-q', '--initial-branch=main'])
        run('baseline-check', ['node', 'check.js'])
        run('initial-add', ['git', 'add', '.'])
        run('initial-commit', ['git', 'commit', '-qm', 'Add cache journey baseline'])
        receipt['initial_commit'] = run('initial-head', ['git', 'rev-parse', 'HEAD']).strip()
        if args.preflight_only:
            receipt['status'] = 'preflight-passed'
            receipt['provider_requests'] = 0
            save()
            print('preflight-passed; no inference; private receipt: ' + str(output / 'receipt.json'))
            return 0
        request = output / 'request.md'
        request.write_text('Change app.txt from exactly baseline\\n to exactly candidate\\n. Slug cache-journey. Keep check.js unchanged: it deliberately accepts both baseline and candidate. Create executable Intent acceptance requiring exactly candidate\\n, legitimately red on baseline. Use a Then step parameterized as the cache journey text is {string}. Inspect README.md through read_file before submitting. No model is necessary for this exact text replacement.\n')
        receipt['inference_started_at'] = datetime.now(timezone.utc).isoformat()
        save()
        run('shape', [binary, 'intent', 'shape', 'cache-journey', str(request)])
        card = run('card', [binary, 'intent', 'approve', 'cache-journey'], expected=5)
        match = re.search(r'SHA-256: ([a-f0-9]{64})', card)
        if not match:
            raise RuntimeError('card has no full contract hash')
        receipt['approved_contract_sha256'] = match[1]
        save()
        run('approve', [binary, 'intent', 'approve', 'cache-journey', match[1]])
        try:
            run('build', [binary, 'intent', 'build', 'cache-journey'])
        finally:
            usage = run('usage', [binary, 'intent', 'usage', '--json'])
            receipt['native_usage'] = json.loads(usage)
            save()
        run('final-check', ['node', 'check.js'])
        text = run('final-text', ['git', 'show', 'HEAD:app.txt'])
        count = run('commit-count', ['git', 'rev-list', '--count', receipt['initial_commit'] + '..HEAD']).strip()
        if text != 'candidate\n' or count != '1':
            raise RuntimeError('expected exact candidate and one native commit')
        receipt['landed_commit'] = run('final-head', ['git', 'rev-parse', 'HEAD']).strip()
        receipt['status'] = 'qualified'
        save()
        print('qualified; private receipt: ' + str(output / 'receipt.json'))
        return 0
    except Exception as error:
        receipt['stop'] = str(error)
        save()
        print('stopped-not-qualified; private receipt: ' + str(output / 'receipt.json'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
