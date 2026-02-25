package main

import (
	"fmt"
	"html/template"
	"net"
	"net/http"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

var webConfigPort int

var configPageTmpl = template.Must(template.New("cfg").Parse(`<!DOCTYPE html>
<html lang="zh"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>局域网键鼠遥控器 · 配置</title>
<style>
*{box-sizing:border-box}
body{font-family:system-ui,-apple-system,sans-serif;max-width:440px;margin:56px auto;padding:0 20px;background:#f2f2f7;color:#1c1c1e}
h1{font-size:17px;font-weight:600;margin:0 0 20px}
.card{background:#fff;border-radius:12px;padding:20px 20px 6px;margin-bottom:12px}
.field{margin-bottom:16px}
label{display:block;font-size:13px;color:#6e6e73;margin-bottom:5px;font-weight:500}
input{width:100%;padding:9px 12px;border:1px solid #ddd;border-radius:8px;font-size:14px;outline:none;background:#fafafa}
input:focus{border-color:#007aff;box-shadow:0 0 0 3px rgba(0,122,255,.12);background:#fff}
.hint{font-size:12px;color:#8e8e93;margin:5px 0 0}
button{width:100%;padding:12px;background:#007aff;color:#fff;border:none;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer;margin-top:4px}
button:hover{background:#0066d6}
.msg{margin-top:14px;padding:12px 16px;border-radius:10px;font-size:13px;text-align:center}
.ok  {background:#d1f5d3;color:#1a7a2e}
.err {background:#ffd7d7;color:#b00020}
.warn{background:#fff3cc;color:#7d5a00}
</style>
</head><body>
<h1>局域网键鼠遥控器 · 配置</h1>
<div class="card">
<form method="POST" action="/save">
  <div class="field">
    <label>连接密码</label>
    <input type="password" name="password" value="{{.Password}}" placeholder="留空则无需密码" autocomplete="off">
    <p class="hint">留空免密码直连；填写后主控端需输入相同密码</p>
  </div>
  <div class="field">
    <label>UDP 端口</label>
    <input type="number" name="port" value="{{.Port}}" min="1" max="65535">
    <p class="hint">默认 8888，更改后需重启服务端生效</p>
  </div>
  <div class="field">
    <label>超时阈值（毫秒）</label>
    <input type="number" name="timeout" value="{{.Timeout}}" min="1">
    <p class="hint">默认 50 ms，超过此值的陈旧数据包将被丢弃</p>
  </div>
  <button type="submit">保存</button>
</form>
{{if .Msg}}<div class="msg {{.MsgClass}}">{{.Msg}}</div>{{end}}
</div>
</body></html>`))

type configPageData struct {
	Password string
	Port     int
	Timeout  int64
	Msg      string
	MsgClass string
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

	if err := saveConfig(gConfPath, newCfg); err != nil {
		renderPage(w, newCfg, "保存失败: "+err.Error(), "err")
		return
	}
	updateCfg(newCfg)

	if portChanged {
		renderPage(w, newCfg, "✓ 已保存。端口更改将在重启后生效。", "warn")
	} else {
		renderPage(w, newCfg, "✓ 已保存并生效", "ok")
	}
}

func renderPage(w http.ResponseWriter, cfg serverConfig, msg, class string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	configPageTmpl.Execute(w, configPageData{ //nolint:errcheck
		Password: cfg.password,
		Port:     cfg.port,
		Timeout:  cfg.timeout,
		Msg:      msg,
		MsgClass: class,
	})
}
