package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"net"
	"net/http"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var webConfigPort int

var configPageTmpl = template.Must(template.New("cfg").Funcs(template.FuncMap{
	"inc": func(i int) int { return i + 1 },
}).Parse(`<!DOCTYPE html>
<html lang="zh"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>局域网键鼠遥控器 · 配置</title>
<style>
*{box-sizing:border-box}
body{font-family:system-ui,-apple-system,sans-serif;max-width:620px;margin:40px auto;padding:0 20px;background:#f2f2f7;color:#1c1c1e}
h1{font-size:17px;font-weight:600;margin:0 0 20px}
h2{font-size:14px;font-weight:600;margin:0 0 14px;color:#3a3a3c}
.card{background:#fff;border-radius:12px;padding:20px 20px 14px;margin-bottom:12px}
.field{margin-bottom:16px}
label{display:block;font-size:13px;color:#6e6e73;margin-bottom:5px;font-weight:500}
input[type=text],input[type=password],input[type=number]{width:100%;padding:9px 12px;border:1px solid #ddd;border-radius:8px;font-size:14px;outline:none;background:#fafafa}
input:focus{border-color:#007aff;box-shadow:0 0 0 3px rgba(0,122,255,.12);background:#fff}
.hint{font-size:12px;color:#8e8e93;margin:5px 0 0}
button{width:100%;padding:12px;background:#007aff;color:#fff;border:none;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer;margin-top:4px}
button:hover{background:#0066d6}
.msg{margin-top:14px;padding:12px 16px;border-radius:10px;font-size:13px;text-align:center}
.ok  {background:#d1f5d3;color:#1a7a2e}
.err {background:#ffd7d7;color:#b00020}
.warn{background:#fff3cc;color:#7d5a00}
.sc-table{width:100%;border-collapse:collapse;font-size:12px;margin-bottom:4px}
.sc-table th{text-align:left;color:#8e8e93;font-weight:500;padding:0 4px 8px;white-space:nowrap}
.sc-table td{padding:4px 2px;vertical-align:middle}
.sc-table input{padding:6px 8px;font-size:12px;border-radius:6px}
.sc-num{width:24px;text-align:center;color:#8e8e93;font-size:11px;padding:0 4px}
.dev-table{width:100%;border-collapse:collapse;font-size:13px}
.dev-table th{text-align:left;color:#8e8e93;font-weight:500;padding:0 8px 8px;border-bottom:1px solid #eee}
.dev-table td{padding:8px;border-bottom:1px solid #f5f5f5}
.dev-empty{text-align:center;color:#8e8e93;padding:20px;font-size:13px}
</style>
</head><body>
<h1>局域网键鼠遥控器 · 配置</h1>
<form method="POST" action="/save">
<div class="card">
<h2>基本配置</h2>
  <div class="field">
    <label>连接密码</label>
    <input type="password" name="password" value="{{.Password}}" placeholder="留空则无需密码" autocomplete="off">
    <p class="hint">留空免密码直连；填写后主控端需输入相同密码</p>
  </div>
  <div class="field">
    <label>UDP 端口</label>
    <input type="number" name="port" value="{{.Port}}" min="1" max="65535">
    <p class="hint">默认 8888，更改后立即生效（当前连接将自动重建）</p>
  </div>
  <div class="field">
    <label>超时阈值（毫秒）</label>
    <input type="number" name="timeout" value="{{.Timeout}}" min="1">
    <p class="hint">默认 50 ms，超过此值的陈旧数据包将被丢弃</p>
  </div>
</div>
<div class="card">
<h2>自定义快捷键</h2>
<p class="hint" style="margin-bottom:12px">App 登录后自动同步，名称不为空则在 App 中显示。快捷键格式：<code>command+shift+a</code>（不区分大小写；command 在 Windows 上自动替换为 ctrl）</p>
<table class="sc-table">
<thead><tr>
  <th class="sc-num">#</th>
  <th>名称（可含 emoji）</th>
  <th>说明（可选）</th>
  <th>快捷键</th>
</tr></thead>
<tbody>
{{range $i, $sc := .CustomShortcuts}}<tr>
  <td class="sc-num">{{inc $i}}</td>
  <td><input type="text" name="custom_{{inc $i}}_name" value="{{$sc.Name}}" placeholder="如：📺 全屏"></td>
  <td><input type="text" name="custom_{{inc $i}}_desc" value="{{$sc.Desc}}" placeholder="简短说明（可留空）"></td>
  <td><input type="text" name="custom_{{inc $i}}_keys" value="{{$sc.Keys}}" placeholder="如：command+f"></td>
</tr>
{{end}}
</tbody>
</table>
</div>
  <button type="submit">保存所有配置</button>
  {{if .Msg}}<div class="msg {{.MsgClass}}">{{.Msg}}</div>{{end}}
</form>

<div class="card" style="margin-top:12px">
<h2>已连接设备 <span id="dev-count" style="font-size:11px;font-weight:400;color:#8e8e93"></span></h2>
<div id="dev-list"><p class="dev-empty">加载中…</p></div>
</div>

<script>
function loadDevices(){
  fetch('/api/devices').then(r=>r.json()).then(data=>{
    var el=document.getElementById('dev-list');
    var cnt=document.getElementById('dev-count');
    if(!data||data.length===0){
      el.innerHTML='<p class="dev-empty">当前无连接设备</p>';
      cnt.textContent='';
      return;
    }
    cnt.textContent='('+data.length+')';
    var html='<table class="dev-table"><thead><tr><th>IP</th><th>首次连接</th><th>最近活跃</th><th>延迟</th><th>数据包</th></tr></thead><tbody>';
    data.forEach(function(d){
      html+='<tr><td>'+d.ip+'</td><td>'+d.first_seen+'</td><td>'+d.last_seen+'</td><td>'+d.latency+'</td><td>'+d.packets+'</td></tr>';
    });
    html+='</tbody></table>';
    el.innerHTML=html;
  }).catch(function(){
    document.getElementById('dev-list').innerHTML='<p class="dev-empty">获取失败</p>';
  });
}
loadDevices();
setInterval(loadDevices,5000);
</script>
</body></html>`))

// customShortcutData 用于模板渲染（Go template 只能访问导出字段）
type customShortcutData struct {
	Name string
	Desc string
	Keys string
}

type configPageData struct {
	Password        string
	Port            int
	Timeout         int64
	Msg             string
	MsgClass        string
	CustomShortcuts [10]customShortcutData
}

// startWebConfig 在随机 localhost 端口启动 HTTP 配置服务，非阻塞。
func startWebConfig() {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Printf("网页配置服务启动失败: %v\n", err)
		return
	}
	webConfigPort = l.Addr().(*net.TCPAddr).Port
	fmt.Printf("网页配置地址: http://127.0.0.1:%d\n", webConfigPort)

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleConfigPage)
	mux.HandleFunc("/save", handleConfigSave)
	mux.HandleFunc("/api/devices", handleDevicesAPI)
	go http.Serve(l, mux) //nolint:errcheck
}

// openBrowserConfig 用系统默认浏览器打开配置页。
func openBrowserConfig() {
	if webConfigPort == 0 {
		return
	}
	url := fmt.Sprintf("http://127.0.0.1:%d", webConfigPort)
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("cmd", "/c", "start", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	cmd.Start() //nolint:errcheck
}

func handleConfigPage(w http.ResponseWriter, r *http.Request) {
	renderPage(w, getCfg(), "", "")
}

func handleConfigSave(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", http.StatusBadRequest)
		return
	}

	newCfg := getCfg()
	newCfg.password = strings.TrimSpace(r.FormValue("password"))

	port, err := strconv.Atoi(r.FormValue("port"))
	if err != nil || port < 1 || port > 65535 {
		renderPage(w, newCfg, "端口无效，请输入 1–65535 之间的数字", "err")
		return
	}
	timeout, err := strconv.ParseInt(r.FormValue("timeout"), 10, 64)
	if err != nil || timeout <= 0 {
		renderPage(w, newCfg, "超时值无效，请输入大于 0 的整数（单位 ms）", "err")
		return
	}

	portChanged := port != newCfg.port
	newCfg.port = port
	newCfg.timeout = timeout

	// 解析自定义快捷键
	for i := 0; i < 10; i++ {
		n := strconv.Itoa(i + 1)
		newCfg.customShortcuts[i].name = strings.TrimSpace(r.FormValue("custom_" + n + "_name"))
		newCfg.customShortcuts[i].desc = strings.TrimSpace(r.FormValue("custom_" + n + "_desc"))
		newCfg.customShortcuts[i].keys = strings.TrimSpace(r.FormValue("custom_" + n + "_keys"))
	}

	if err := saveConfig(gConfPath, newCfg); err != nil {
		renderPage(w, newCfg, "保存失败: "+err.Error(), "err")
		return
	}
	updateCfg(newCfg)

	if portChanged {
		go restartUDPServer()
		renderPage(w, newCfg, "✓ 已保存，端口已切换（重新连接主控端即可）", "ok")
	} else {
		renderPage(w, newCfg, "✓ 已保存并生效", "ok")
	}
}

// handleDevicesAPI 返回当前已连接设备的 JSON 列表。
func handleDevicesAPI(w http.ResponseWriter, r *http.Request) {
	clientMu.RLock()
	defer clientMu.RUnlock()

	type deviceJSON struct {
		IP        string `json:"ip"`
		FirstSeen string `json:"first_seen"`
		LastSeen  string `json:"last_seen"`
		Latency   string `json:"latency"`
		Packets   int64  `json:"packets"`
	}

	now := time.Now()
	result := make([]deviceJSON, 0, len(clients))
	for _, c := range clients {
		latencyStr := "—"
		if c.latencyMs > 0 {
			latencyStr = fmt.Sprintf("%dms", c.latencyMs)
		}
		result = append(result, deviceJSON{
			IP:        c.ip,
			FirstSeen: fmtAgo(now.Sub(c.firstSeen)),
			LastSeen:  fmtAgo(now.Sub(c.lastSeen)),
			Latency:   latencyStr,
			Packets:   c.packets,
		})
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(result) //nolint:errcheck
}

func renderPage(w http.ResponseWriter, cfg serverConfig, msg, class string) {
	var customs [10]customShortcutData
	for i, sc := range cfg.customShortcuts {
		customs[i] = customShortcutData{Name: sc.name, Desc: sc.desc, Keys: sc.keys}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	configPageTmpl.Execute(w, configPageData{ //nolint:errcheck
		Password:        cfg.password,
		Port:            cfg.port,
		Timeout:         cfg.timeout,
		Msg:             msg,
		MsgClass:        class,
		CustomShortcuts: customs,
	})
}
