import json,os,subprocess,tempfile,threading,http.server,hashlib
from pathlib import Path
out=Path(__file__).resolve().parent
exe=Path.home()/'Library/Application Support/Kogen/codex/runtimes/0.154.0-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex'
receipts=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_POST(self):
  d=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  receipts.append({'model':d.get('model'),'tools':d.get('tools',[]),'tool_names':[t.get('name',t.get('type')) for t in d.get('tools',[])]})
  self.send_response(400);self.end_headers();self.wfile.write(b'{"error":{"message":"intentional offline schema capture"}}')
server=http.server.HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(dir=out,prefix='owned-') as temp:
 p=Path(temp);home=p/'home';home.mkdir();(home/'codex').mkdir();cwd=p/'fixture';cwd.mkdir()
 env={'HOME':str(home),'CODEX_HOME':str(home/'codex'),'PATH':os.environ['PATH'],'TMPDIR':str(p),'TERM':'dumb','OPENAI_BASE_URL':f'http://127.0.0.1:{server.server_port}/v1','OPENAI_API_KEY':'synthetic-not-a-credential'}
 cmd=[str(exe),'-c','model_provider="capture"','-c',f'model_providers.capture={{name="capture",base_url="http://127.0.0.1:{server.server_port}/v1",wire_api="responses",requires_openai_auth=false,request_max_retries=0}}','--disable','apps','--disable','plugins','exec','--skip-git-repo-check','--json','-m','gpt-5.6-sol','-c','model_reasoning_effort="low"','Report available tools. Do not invoke tools.']
 try:
  r=subprocess.run(cmd,cwd=cwd,env=env,input='',capture_output=True,text=True,timeout=35);status=r.returncode;error=r.stderr[-1500:]
 except subprocess.TimeoutExpired:status='timeout';error='bounded process timeout'
server.shutdown()
result={'binary_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'exit':status,'local_requests':receipts,'stderr_tail':error,'limitations':'Local HTTP capture with synthetic empty home; no external provider or actual child execution. Expected request rejection after schema capture.'}
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
