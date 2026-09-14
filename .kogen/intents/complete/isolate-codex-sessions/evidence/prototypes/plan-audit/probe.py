"""Source-bound offline controls; no native provider or production writes."""
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
root=Path.cwd(); out=Path(__file__).resolve().parent
receipt=root/'.kogen/runtime/live-evidence/native-helper-21046-818-1789326000782227708/native-receipt.json'
protocol=receipt.parent/'protocol.json'
consumer=root/'test/support/shaping_evaluation/managed_resume.py'
result={'provider_calls':0,'production_writes':0,'source_sha256':{str(consumer.relative_to(root)):hashlib.sha256(consumer.read_bytes()).hexdigest()},'limitations':'Focused retained-receipt validation and resume consumer controls only; not a full public lifecycle or a repaired native run.'}
with tempfile.TemporaryDirectory(prefix='owned-',dir=out) as work:
 work=Path(work)
 baseline=subprocess.run(['git','show','HEAD:test/support/native_helper_fixture.ex'],capture_output=True,text=True,check=True).stdout
 (work/'validator.ex').write_text(baseline)
 result['baseline_validator_sha256']=hashlib.sha256(baseline.encode()).hexdigest()
 code='''Code.compile_file(System.argv() |> Enum.at(0))
r = File.read!(Enum.at(System.argv(),1)) |> Jason.decode!()
p = File.read!(Enum.at(System.argv(),2)) |> Jason.decode!()
actual=Kogen.NativeHelperFixture.validate_receipt(r,p)
controls=Map.update!(r,"children",fn children -> Enum.map(children,fn child -> task=Enum.find(p["children"], &(&1["name"]==child["name"])); Map.put(child,"requested_kind",task["kind"]) end) end)
control=Kogen.NativeHelperFixture.validate_receipt(controls,p)
IO.puts(Jason.encode!(%{actual_rejected: actual != :ok, synthetic_kind_control_accepted: control == :ok}))
'''
 cmd=['elixir']
 for ebin in sorted((root/'_build/test/lib').glob('*/ebin')):cmd+=['-pa',str(ebin)]
 cmd+=['-e',code,str(work/'validator.ex'),str(receipt),str(protocol)]
 run=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
 if run.returncode: raise RuntimeError(run.stderr[-1500:])
 result['native_helper_receipt_control']=json.loads(run.stdout.splitlines()[-1])
 assert all(result['native_helper_receipt_control'].values())
 fake=work/'executor'; fake.write_text('#!'+sys.executable+'\nimport json,os\nprint(json.dumps({"role":os.getenv("KOGEN_ROLE"),"unset":os.getenv("AUDIT_UNSET"),"empty":os.getenv("AUDIT_EMPTY")}))\n');fake.chmod(0o700)
 context=work/'context.json'
 for label,pairs in [('stale_role',[['KOGEN_ROLE','developer']]),('correct_role',[['KOGEN_ROLE','shaper']])]:
  context.write_text(json.dumps({'executable':str(fake),'args':[],'env':pairs+[['AUDIT_UNSET',None],['AUDIT_EMPTY','']]}))
  env={**os.environ,'KOGEN_ROLE':'shaper','AUDIT_UNSET':'previous'}
  run=subprocess.run([sys.executable,'-B',str(consumer),str(context),'resume'],env=env,capture_output=True,text=True,timeout=5,check=True)
  result[label]=json.loads(run.stdout)
 assert result['stale_role']['role']=='developer' and result['correct_role']['role']=='shaper'
 assert result['correct_role']['unset'] is None and result['correct_role']['empty']==''
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
