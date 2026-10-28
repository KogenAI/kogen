package build

import (
 "encoding/json"
 "fmt"
 "net/http"
 "os"
 "path/filepath"
 "strconv"
 "strings"
 "syscall"
 "testing"
 "time"

 "kogen-loop/sys"
 "kogen/agent"
 "kogen/project"
)

// Mounted as a test-only overlay. The existing Build fixture supplies local Git,
// fake credentials, fake streaming provider and verification reports; no live service.
func TestKShellboundObservation(t *testing.T) {
 mode, setting, command := os.Getenv("KSHELL_MODE"), os.Getenv("KSHELL_SETTING"), os.Getenv("KSHELL_COMMAND")
 d := map[string]any{"mode":mode, "setting":setting}
 save := func(){ b,e:=json.Marshal(d); if e!=nil {t.Fatal(e)}; if e=os.WriteFile(os.Getenv("KSHELL_OUTPUT"),b,0600);e!=nil{t.Fatal(e)} }
 e:=newEnv(t)
 config:=e.read(".kogen/project.yaml")
 if mode=="configured" {
  cfg,er:=project.LoadConfig(e.root);if er!=nil{t.Fatal(er)}
  cfg.Setup=[]string{"sleep 3; echo setup > '"+filepath.Join(e.aux,"setup")+"'"}
  cfg.Fix=[]string{"sleep 3; echo fix > '"+filepath.Join(e.aux,"fix")+"'"}
  cfg.Checks=[]project.Check{{Name:"slow",Run:"sleep 3; echo check > '"+filepath.Join(e.aux,"check")+"'"}}
  config=project.RenderConfig(cfg)
 }
 if setting!="absent" { config += "\ntool_shell_timeout_seconds: "+setting+"\n" }
 e.write(".kogen/project.yaml",config)
 _,err:=project.LoadConfig(e.root)
 if err!=nil {
  d["config_error"]=fmt.Sprint(err)
  if se,ok:=sys.AsError(err);ok {d["config_error"]=se.Render()}
  save(); return
 }
 d["config_error"]=""
 if mode=="load" {save();return}
 e.run("git","add",".kogen/project.yaml")
 e.run("git","commit","--allow-empty","-qm","shell configuration")
 e.approve()
 marker:=filepath.Join(e.aux,"group")
 if mode=="group" || mode=="interrupt" {
  command="echo $$ > '"+marker+"'; trap 'wait; exit 143' TERM; "+command+" & wait"
 }
 call:=e.prov.call("shell",map[string]any{"command":command})
 // Observe group absence when feedback has actually reached the next request,
 // before verification/end-of-Build cleanup could conceal a custody defect.
 after:=func(h handler) handler {return func(w http.ResponseWriter,r *http.Request){
  if mode=="group" {
   b,er:=os.ReadFile(marker); if er!=nil {t.Error(er)} else {
    pid,er:=strconv.Atoi(strings.TrimSpace(string(b))); if er!=nil || pid<=1 {t.Error("invalid owned group marker")} else {d["group_absent_at_request"]=syscall.Kill(-pid,0)==syscall.ESRCH}
   }
  }
  h(w,r)
 }}
 if mode=="review" {
  e.prov.then(landScript(e.prov)...)
  e.prov.then(sse(call),after(submit(e.prov,"approve")))
 } else {
  e.prov.then(sse(call),after(e.prov.calls("shell",map[string]any{"command":"printf continued"})))
  e.prov.then(landScript(e.prov)...)
 }
 var a *attempt
 if mode=="interrupt" {
  var done <-chan struct{}
  a,done=e.start()
  deadline:=time.Now().Add(10*time.Second)
  for {if _,er:=os.Stat(marker);er==nil{break};if time.Now().After(deadline){t.Fatal("shell did not start")};time.Sleep(5*time.Millisecond)}
  a.s.Interrupt("SIGINT")
  select {case <-done:case <-time.After(15*time.Second):t.Fatal("interrupt did not stop")}
 } else if mode=="review" {a=e.reviewed()} else {a=e.build()}
 d["exit"]=a.exit; d["error"]=a.shown()
 d["landed"]=strings.Contains(a.out.String(),"landed fixture ")
 d["result"]="";d["continued"]=false;d["description"]=""
 for _,req:=range e.prov.requests(){
  for _,v:=range requestInput(req){
   m,ok:=v.(map[string]any);if !ok{continue}
   if m["type"]=="function_call_output" {
    if m["call_id"]==call["call_id"] {d["result"]=m["output"]}
    if m["output"]=="exit status: 0\ncontinued" {d["continued"]=true}
   }
  }
  isReview:=requestInstructions(req)==agent.Prompt(agent.Reviewer)
  if (mode=="review")==isReview {
   defs,_:=req["tools"].([]any)
   for _,v:=range defs {m,_:=v.(map[string]any);if m["name"]=="shell" {d["description"]=m["description"]}}
  }
 }
 if mode=="review" {d["continued"]=d["landed"]}
 if mode=="configured" {
  all:=true
  for _,n:=range []string{"setup","fix","check"}{b,er:=os.ReadFile(filepath.Join(e.aux,n));all=all && er==nil && strings.TrimSpace(string(b))==n}
  d["configured_completed"]=all
 }
 save()
}
