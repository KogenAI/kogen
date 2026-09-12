from pathlib import Path
import hashlib,json,sys
repo=Path(sys.argv[1]).resolve(); policy=Path(sys.argv[2]).resolve()
config="""harness: codex
shaping:   {model: gpt-6-astra, effort: low}
developer: {model: gpt-5.6-sol, effort: low}
reviewer:  {model: gpt-5.6-terra, effort: medium}
helpers:
  scout:  {model: gpt-5.6-luna, effort: low}
  worker: {model: gpt-5.6-luna, effort: medium}
  expert: {model: gpt-5.6-sol, effort: medium}
outer_resumptions: 2
"""
assert (repo/'.git').is_dir()
(repo/'.kogen/config.yaml').write_text(config)
text=policy.read_text(); text='Optimize the complete correct task'+text.split('Optimize the complete correct task',1)[1]; text=text.split('This slice does not change task-file transport',1)[0].rstrip()+'\n'
for role in ['shaping','developer','reviewer']:
 p=repo/'priv/kogen/prompts'/f'{role}.md'
 assert 'EXPERIMENTAL_SHARED_POLICY' not in p.read_text()
 p.write_text(p.read_text()+'\n## EXPERIMENTAL_SHARED_POLICY\n\n'+text)
# Existing fake lifecycle assumes all baseline roots use Astra-low. Preserve its
# exact four-call order and strengthen the assertion to role-specific profiles.
p=repo/'test/kogen/lifecycle_test.exs';t=p.read_text()
old='    assert Enum.all?(log_lines, fn line ->\n             line =~ "--model gpt-6-astra" and line =~ "model_reasoning_effort=\\"low\\""\n           end)'
new='    expected_profiles = [\n      {"gpt-5.6-sol", "low"},\n      {"gpt-5.6-terra", "medium"},\n      {"gpt-5.6-sol", "low"},\n      {"gpt-5.6-terra", "medium"}\n    ]\n\n    assert length(log_lines) == length(expected_profiles)\n\n    Enum.zip(log_lines, expected_profiles)\n    |> Enum.each(fn {line, {model, effort}} ->\n      assert line =~ "--model #{model}"\n      assert line =~ ~s(model_reasoning_effort="#{effort}")\n    end)'
assert old in t
p.write_text(t.replace(old,new).replace('gpt-5.6-terra` at `medium','gpt-5.6-luna` at `medium').replace('gpt-6-astra` at `medium','gpt-5.6-sol` at `medium'))
