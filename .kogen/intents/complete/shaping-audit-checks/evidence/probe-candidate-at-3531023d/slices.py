import sys,re,os
P=sys.argv[1]
def idx(c):
    return [l.rstrip('\n').split('\t') for l in open(f'{P}/split-{c}/INDEX')]
def res(c):
    return dict(zip([p for _,p in idx(c)],[l.split('\t')[0] for l in open(f'{P}/apply-{c}.tsv').read().splitlines()]))
qb='qbOzahf8-f4819c37-codex'; zj='ZujYgSGt-555d0af3'
S1=[r'^lib/kogen/build\.ex$',r'^lib/kogen/build/verification_plan\.ex$',r'^lib/kogen/verification_policy\.ex$',r'^lib/kogen/harness\.ex$',r'^lib/kogen/intent\.ex$',
    r'^lib/kogen/shaping_audit\.ex$',r'^lib/kogen/shaping_audit/(deterministic|finding|materialization|package|report)\.ex$',r'^lib/mix/tasks/kogen\.audit\.ex$',r'^README\.md$',
    r'^test/kogen/shaping_audit_(checks|task)_test\.exs$',r'^test/support/shaping_audit/fixture\.ex$',
    r'^test/support/shaping_audit/drafts/(proof-defects|ledger-flawed|ledger-unstated|controller-read|catalog-added|long-title|paid-unproven|paid-overbroad|paid-provider-only|live-owner|stale|stale-disputed|history|invalid|complete|non-regular)/',
    r'^test/kogen/intent_test\.exs$',r'^test/kogen/commit_provenance_test\.exs$']
S2=[r'^\.kogen/config\.yaml$',r'^README\.md$',r'^lib/kogen/intent\.ex$',r'^lib/kogen/harness\.ex$',r'^lib/kogen/harness/(claude|codex)\.ex$',r'^lib/kogen/(codex|claude_code|jev)\.ex$',r'^lib/kogen/codex/environment\.ex$',
    r'^lib/kogen/shaping_audit\.ex$',r'^lib/kogen/shaping_audit/(jev_layer|questions|auditor|report|finding)\.ex$',r'^lib/mix/tasks/kogen\.audit\.ex$',
    r'^priv/kogen/prompts/auditor\.md$',r'^priv/kogen/shaping_audit/(question-gate-v1|questions-v1|settled)\.json$',
    r'^test/kogen/shaping_audit_(jev|question_gate|auditor|flow|task)_test\.exs$',r'^test/kogen/(intent|configuration_support_contract|harness_role)_test\.exs$',
    r'^test/support/shaping_audit/(fake_jev_audit|fake_jev_audit\.ex|fake_security_audit|fake_auditor)$',r'^test/support/shaping_audit/fake_auditor_messages/',
    r'^test/support/shaping_audit/drafts/(jev-clauses|jev-large|questions|flow)/']
S3=[r'^README\.md$',r'^lib/kogen/harness\.ex$',r'^lib/kogen/harness/codex\.ex$',r'^lib/kogen/codex/environment\.ex$',r'^lib/kogen/shaping_audit\.ex$',r'^lib/kogen/shaping_audit/(stop_hook|jev_layer|report)\.ex$',
    r'^lib/mix/tasks/kogen\.(audit|shape)\.ex$',r'^priv/kogen/shaping_audit/stop_hook\.sh$',r'^priv/kogen/prompts/shaping(-continuation|-fresh)?\.md$',
    r'^test/kogen/shaping_audit_(hook|task)_test\.exs$',r'^test/kogen/(shape_task|harness_role|codex_environment|shaping_evaluation|live_shaping_evaluation)_test\.exs$',
    r'^test/support/shaping_audit/(fake_mix|fast_auditor\.ex)$',r'^test/support/shaping_audit/hook/',r'^test/support/shaping_evaluation/']
S4=[r'^README\.md$',r'^lib/kogen/harness/claude\.ex$',r'^priv/kogen/claude_code/shaping-settings\.json$',r'^test/kogen/(claude_code_harness|shape_task|live_shape_to_build|shaping_audit_hook)_test\.exs$',
    r'^test/support/shape_to_build_probe\.exp$',r'^test/support/shaping_audit/fast_auditor\.ex$']
slices={'shaping-audit-checks':S1,'shaping-audit-jev-and-auditor':S2,'shaping-stop-hook':S3,'claude-shaping-under-hook':S4}
out=sys.argv[2]
for slug,pats in slices.items():
    lines=[]
    for c in (qb,zj):
        r=res(c)
        for i,p in idx(c):
            if any(re.search(x,p) for x in pats):
                lines.append((c,i,p,r[p]))
    os.makedirs(f'{out}/{slug}/evidence',exist_ok=True)
    for c in (qb,zj):
        with open(f'{out}/{slug}/evidence/candidate-{c}-slice.diff','wb') as fh:
            for cc,i,p,st in lines:
                if cc==c: fh.write(open(f'{P}/split-{c}/{i}.diff','rb').read())
    with open(f'{P}/slice-{slug}.tsv','w') as fh:
        for cc,i,p,st in lines: fh.write(f'{cc}\t{p}\t{st}\n')
    print(slug, len([l for l in lines if l[0]==qb]), len([l for l in lines if l[0]==zj]))
