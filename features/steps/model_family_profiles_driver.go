package main

import (
 "context"
 "encoding/json"
 "fmt"
 "io"
 "net/http"
 "net/http/httptest"
 "net/url"
 "os"
 "path/filepath"
 "strings"
 "time"
 "kogen-loop/provider"
 "kogen-loop/sys"
 "kogen-loop/tools"
 "kogen/project"
)

// This is an external acceptance driver, not production policy. Only fixture credentials
// exist in its HOME. Its injected HTTP transport redirects every request to its own server;
// the original logical URL is recorded before redirection. It cannot qualify a live model.
type selection struct { Provider, Model, Effort, Role, Mode, BaseURL string; Seam, Image bool }
type observer struct { Rows []map[string]any }
func (o *observer) Attempt(r map[string]any) { o.Rows=append(o.Rows,r) }
type redirect struct { Target string; URLs []string }
func (r *redirect) RoundTrip(q *http.Request) (*http.Response,error) {
 r.URLs=append(r.URLs,q.URL.String())
 v:=q.Clone(q.Context()); u:=*q.URL; target,_:=url.Parse(r.Target); u.Scheme=target.Scheme;u.Host=target.Host;v.URL=&u;v.Host=target.Host
 return http.DefaultTransport.RoundTrip(v)
}
func event(w http.ResponseWriter, v any) { b,_:=json.Marshal(v);fmt.Fprintf(w,"data: %s\n\n",b) }
func answer(w http.ResponseWriter, s selection, n int) {
 if s.Mode=="reject" {w.Header().Set("Content-Type","application/json");w.WriteHeader(400);io.WriteString(w,`{"error":{"type":"invalid_request_error","message":"model not found"}}`);return}
 call:=n==1 && s.Mode!="budget"
 if s.Provider=="anthropic" {
 w.Header().Set("Content-Type","text/event-stream")
 event(w,map[string]any{"type":"message_start","message":map[string]any{"id":"msg_fixture","model":s.Model,"usage":map[string]any{"input_tokens":10,"cache_read_input_tokens":2,"cache_creation_input_tokens":0}}})
 blocks:=[]any{map[string]any{"type":"text","text":"done"}}
 if call {blocks=[]any{map[string]any{"type":"thinking","thinking":"fixture thinking","signature":"fixture-signature"},map[string]any{"type":"tool_use","id":"tool_fixture","name":"read_file","input":map[string]any{"path":"app.txt"}}}}
 for i,b:=range blocks {event(w,map[string]any{"type":"content_block_start","index":i,"content_block":b});event(w,map[string]any{"type":"content_block_stop","index":i})}
 reason:="end_turn";if call {reason="tool_use"};event(w,map[string]any{"type":"message_delta","delta":map[string]any{"stop_reason":reason},"usage":map[string]any{"output_tokens":3}});event(w,map[string]any{"type":"message_stop"});return
 }
 if s.Provider=="opencode-go"||s.Provider=="openai-compatible" {
 w.Header().Set("Content-Type","application/json");m:=map[string]any{"role":"assistant","content":"done"};reason:="stop"
 if call {m=map[string]any{"role":"assistant","content":nil,"reasoning_content":"fixture reasoning","tool_calls":[]any{map[string]any{"id":"tool_fixture","type":"function","function":map[string]any{"name":"read_file","arguments":"{\"path\":\"app.txt\"}"}}}};reason="tool_calls"}
 json.NewEncoder(w).Encode(map[string]any{"id":"chat_fixture","model":s.Model,"choices":[]any{map[string]any{"index":0,"message":m,"finish_reason":reason}},"usage":map[string]any{"prompt_tokens":12,"completion_tokens":3,"prompt_tokens_details":map[string]any{"cached_tokens":2}}});return
 }
 w.Header().Set("Content-Type","text/event-stream")
 items:=[]any{map[string]any{"type":"message","id":"message_fixture","role":"assistant","content":[]any{map[string]any{"type":"output_text","text":"done"}}}}
 if call {items=[]any{map[string]any{"type":"reasoning","id":"reasoning_fixture","encrypted_content":"fixture-encrypted","summary":[]any{}},map[string]any{"type":"function_call","id":"function_fixture","call_id":"tool_fixture","name":"read_file","arguments":"{\"path\":\"app.txt\"}"}}}
 for i,b:=range items {event(w,map[string]any{"type":"response.output_item.done","output_index":i,"item":b})}
 event(w,map[string]any{"type":"response.completed","response":map[string]any{"id":"resp_fixture","model":s.Model,"usage":map[string]any{"input_tokens":12,"output_tokens":3,"input_tokens_details":map[string]any{"cached_tokens":2},"output_tokens_details":map[string]any{"reasoning_tokens":0}}}})
}
func fail(e error) (any,error) {
 if se,ok:=sys.AsError(e);ok {return map[string]any{"code":se.Class+"/"+se.Reason,"exit":se.Exit,"message":se.Render()},nil};return nil,e
}
func run(s selection) (map[string]any,error) {
 home,err:=os.MkdirTemp("","kogen-profile-driver-");if err!=nil{return nil,err};defer os.RemoveAll(home)
 if s.Role==""{s.Role="build"};if s.Mode==""{s.Mode="roundtrip"}
 if s.Provider=="openai-compatible"&&s.BaseURL==""{s.BaseURL="http://127.0.0.1:11434/v1"}
 roleLine:=fmt.Sprintf("  %s: {provider: %s, model: %s, effort: %s",s.Role,s.Provider,s.Model,s.Effort);if s.Provider=="openai-compatible"{roleLine+=", base_url: '"+s.BaseURL+"'"};roleLine+="}\n"
 text:="version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n";if s.Mode!="defaults" {text+="models:\n"+roleLine}
 cfg,err:=project.ParseConfig(text,".kogen/project.yaml");if err!=nil{return nil,err}
 cr:=cfg.Models[s.Role];r:=provider.Role{Provider:cr.Provider,Model:cr.Model,Effort:cr.Effort,BaseURL:cr.BaseURL}
 s.Provider=provider.Name(r);s.Model=r.Model;s.Effort=r.Effort
 dir:=filepath.Join(home,".kogen","credentials");if err:=os.MkdirAll(dir,0700);err!=nil{return nil,err}
 for _,p:=range []string{"chatgpt","supergrok","opencode-go","anthropic"} {
 cred:=map[string]any{"provider":p,"api_key":"fixture-key"}
 if p=="chatgpt"||p=="supergrok" {cred=map[string]any{"client_id":"oaiapp_fixture","access_token":"fixture-token","refresh_token":"fixture-refresh","expires_at":time.Now().Unix()+86400,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct","referrer":"kogen"}}
 b,_:=json.Marshal(cred);if err:=os.WriteFile(filepath.Join(dir,p+".json"),b,0600);err!=nil{return nil,err}
 }
 records:=[]map[string]any{}
 server:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,q *http.Request){var body map[string]any;if err:=json.NewDecoder(q.Body).Decode(&body);err!=nil {http.Error(w,err.Error(),500);return};records=append(records,map[string]any{"path":q.URL.Path,"headers":q.Header,"body":body});answer(w,s,len(records))}));defer server.Close()
 tr:=&redirect{Target:server.URL,URLs:[]string{}};client:=provider.NewClient("kogen profile-fixture");client.HTTP=&http.Client{Transport:tr,Timeout:5*time.Second}
 env:=[]string{"HOME="+home,"PATH="+os.Getenv("PATH")};if s.Seam {env=append(env,"KOGEN_PROVIDER_URL="+server.URL)}
 session:=sys.NewWith(env,home)
 obs:=&observer{Rows:[]map[string]any{}}
 req:=provider.Request{Role:r,Instructions:"profile fixture policy",Input:[]any{map[string]any{"role":"user","content":"profile fixture authority"}},Tools:[]any{map[string]any{"type":"function","name":"read_file","description":"Read a file","parameters":map[string]any{"type":"object","properties":map[string]any{"path":map[string]any{"type":"string"}},"required":[]any{"path"},"additionalProperties":false}}},CacheID:"profile-fixture-conversation",Context:map[string]any{"role":s.Role,"phase":s.Role},Single:true}
 // This typed marker tests pre-inference capability refusal, not pixel delivery or validity.
 if s.Image {req.Input=[]any{map[string]any{"role":"user","content":[]any{map[string]any{"type":"input_image","image_url":"data:image/png;base64,AAAA"}}}}}
 failures:=[]any{};sizes:=[]int{};calls:=[]int{}
 for n:=0;n<2;n++ {
 if s.Mode=="budget" {break}
 resp,e:=client.Respond(context.Background(),session,req,obs)
 if e!=nil {f,er:=fail(e);if er!=nil{return nil,er};failures=append(failures,f);break}
 calls=append(calls,len(tools.Calls(resp.Items)))
 if n==0 {req.Input=append(req.Input,tools.Replay(resp.Items)...);for _,call:=range tools.Calls(resp.Items) {req.Input=append(req.Input,call.Output("fixture tool result"))}}
 }
 if s.Mode=="budget" {for _,target:=range []int{524287,524288,524289} {req.Input=[]any{map[string]any{"role":"user","content":""}};b,_:=json.Marshal(client.Body(req));req.Input[0].(map[string]any)["content"]=strings.Repeat("x",target-len(b));b,_=json.Marshal(client.Body(req));sizes=append(sizes,len(b));_,e:=client.Respond(context.Background(),session,req,obs);if e!=nil {f,er:=fail(e);if er!=nil{return nil,er};failures=append(failures,f)}}}
 return map[string]any{"selection":s,"records":records,"urls":tr.URLs,"rows":obs.Rows,"errors":failures,"calls":calls,"sizes":sizes},nil
}
func main(){var s selection;if err:=json.NewDecoder(os.Stdin).Decode(&s);err!=nil{fmt.Fprintln(os.Stderr,err);os.Exit(2)};out,err:=run(s);if err!=nil{fmt.Fprintln(os.Stderr,err);os.Exit(2)};json.NewEncoder(os.Stdout).Encode(out)}
