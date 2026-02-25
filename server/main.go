package main

import (
	_ "embed"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/go-vgo/robotgo"
)

//go:embed assets/app_icon.png
var iconData []byte

const (
	defaultPort = 8888
	bufferSize  = 65535

	// 指令码
	cmdTimeSync        = 0x00
	cmdMouseMove       = 0x01
	cmdMouseClick      = 0x02
	cmdMouseScroll     = 0x03
	cmdKeyTap          = 0x04
	cmdTextInput       = 0x05
	cmdMouseDown       = 0x06 // 按下不松开（拖拽用）
	cmdMouseUp         = 0x07 // 松开鼠标键
	cmdDblClick        = 0x08 // 双击
	cmdTextInputDirect = 0x09 // 逐字输入（TypeStr，不经剪贴板）
	cmdSysAction       = 0x0A // 系统操作
	cmdPing            = 0x10 // 心跳

	// 系统操作码
	sysLock      = byte(0x01)
	sysSleep     = byte(0x02)
	sysShutdown  = byte(0x03)
	sysRestart   = byte(0x04)
	sysSwitchApp = byte(0x05) // 切换应用窗口
	sysScreenshot = byte(0x06) // 截图
	// 编辑快捷键
	sysSelectAll = byte(0x07) // 全选
	sysCopy      = byte(0x08) // 复制
	sysCut       = byte(0x09) // 剪切
	sysUndo      = byte(0x0A) // 撤销
	sysRedo      = byte(0x0B) // 重做
	sysSave      = byte(0x0C) // 保存
	// 窗口管理
	sysTaskView    = byte(0x0D) // 任务视图（Win+Tab / Mission Control）
	sysShowDesktop = byte(0x0E) // 显示桌面（Win+D / Ctrl+F3）

	// 鼠标按键
	btnLeft   = 0x00
	btnRight  = 0x01
	btnMiddle = 0x02

	// 时间同步响应中的 OS 标识
	osWindows = byte(0x00)
	osMacOS   = byte(0x01)
	osLinux   = byte(0x02)

	// 时间同步响应中的认证结果
	authOK   = byte(0x00)
	authFail = byte(0x01)
)

// serverConfig 从配置文件读取的运行参数
type serverConfig struct {
	password string
	timeout  int64
	port     int
	logFile  string
}

// ── 全局可变配置（支持设置窗口实时修改密码/超时） ──
var (
	cfgMu    sync.RWMutex
	gCfg     serverConfig
	gConfPath string
)

func getCfg() serverConfig {
	cfgMu.RLock()
	defer cfgMu.RUnlock()
	return gCfg
}

func updateCfg(c serverConfig) {
	cfgMu.Lock()
	gCfg = c
	cfgMu.Unlock()
}

// loadConfig 读取 key=value 格式配置文件，解析失败时使用默认值
func loadConfig(path string) serverConfig {
	cfg := serverConfig{timeout: 50, port: defaultPort}
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		k := strings.TrimSpace(parts[0])
		v := strings.TrimSpace(parts[1])
		switch k {
		case "password":
			cfg.password = v
		case "timeout":
			var n int64
			if _, err := fmt.Sscan(v, &n); err == nil && n > 0 {
				cfg.timeout = n
			}
		case "port":
			var n int
			if _, err := fmt.Sscan(v, &n); err == nil && n > 0 {
				cfg.port = n
			}
		case "log_file":
			cfg.logFile = v
		}
	}
	return cfg
}

// saveConfig 将配置写回文件
func saveConfig(path string, cfg serverConfig) error {
	lines := []string{
		"# 局域网键鼠遥控器 - 被控端配置文件",
		"# 留空则免密码直连，填写后主控端需输入正确密码才能连接",
		"password=" + cfg.password,
		"",
		"# UDP 监听端口",
		fmt.Sprintf("port=%d", cfg.port),
		"",
		"# 丢包超时阈值（毫秒）：超过此时间的陈旧数据包将被丢弃",
		fmt.Sprintf("timeout=%d", cfg.timeout),
	}
	if cfg.logFile != "" {
		lines = append(lines, "", "# 操作日志文件路径", "log_file="+cfg.logFile)
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0644)
}

func getOSByte() byte {
	switch runtime.GOOS {
	case "windows":
		return osWindows
	case "darwin":
		return osMacOS
	default:
		return osLinux
	}
}

func buttonName(b byte) string {
	switch b {
	case btnRight:
		return "right"
	case btnMiddle:
		return "center"
	default:
		return "left"
	}
}

var keyMap = map[byte]string{
	13: "enter", 8: "backspace", 27: "escape", 9: "tab", 32: "space",
	37: "left", 38: "up", 39: "right", 40: "down",
	46: "delete", 36: "home", 35: "end", 33: "pageup", 34: "pagedown",
	112: "f1", 113: "f2", 114: "f3", 115: "f4", 116: "f5", 117: "f6",
	118: "f7", 119: "f8", 120: "f9", 121: "f10", 122: "f11", 123: "f12",
	200: "audio_vol_up", 201: "audio_vol_down", 202: "audio_mute",
	203: "audio_play", 204: "audio_next", 205: "audio_prev",
}

// ── 操作日志函数变量：生产环境写文件，开发环境输出控制台 ──
var opLog func(format string, args ...any)

// ── 已连接客户端注册表 ──

type clientInfo struct {
	ip        string
	firstSeen time.Time
	lastSeen  time.Time
	packets   int64
	latencyMs int64 // 服务端估算单向延迟（来自 Ping 时间戳，需时钟同步）
}

var (
	clientMu sync.RWMutex
	clients  = map[string]*clientInfo{}
)

func upsertClient(ip string) {
	clientMu.Lock()
	defer clientMu.Unlock()
	if _, ok := clients[ip]; !ok {
		clients[ip] = &clientInfo{ip: ip, firstSeen: time.Now(), lastSeen: time.Now()}
	} else {
		clients[ip].lastSeen = time.Now()
	}
}

func updateClientActivity(ip string) {
	clientMu.Lock()
	defer clientMu.Unlock()
	if c, ok := clients[ip]; ok {
		c.lastSeen = time.Now()
		c.packets++
	}
}

func updateClientLatency(ip string, latencyMs int64) {
	clientMu.Lock()
	defer clientMu.Unlock()
	if c, ok := clients[ip]; ok {
		c.lastSeen = time.Now()
		c.latencyMs = latencyMs
	}
}

func printClients() {
	clientMu.RLock()
	defer clientMu.RUnlock()
	if len(clients) == 0 {
		return
	}
	now := time.Now()
	fmt.Printf("\n===== 已连接客户端 (%d) =====\n", len(clients))
	fmt.Printf("%-18s %-12s %-12s %-8s %s\n", "IP", "首次连接", "最近活跃", "延迟", "数据包")
	for _, c := range clients {
		latencyStr := "—"
		if c.latencyMs > 0 {
			latencyStr = fmt.Sprintf("%dms", c.latencyMs)
		}
		fmt.Printf("%-18s %-12s %-12s %-8s %d\n",
			c.ip,
			fmtAgo(now.Sub(c.firstSeen)),
			fmtAgo(now.Sub(c.lastSeen)),
			latencyStr,
			c.packets,
		)
	}
	fmt.Println("=============================")
}

func fmtAgo(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds前", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm前", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh前", int(d.Hours()))
	}
}

func main() {
	configPath := flag.String("config", "server.conf", "配置文件路径")
	portFlag := flag.Int("port", 0, "UDP 端口（覆盖配置文件）")
	timeoutFlag := flag.Int("timeout", 0, "超时阈值 ms（覆盖配置文件）")
	logFlag := flag.String("log", "", "操作日志文件路径（覆盖配置文件）")
	noGUI := flag.Bool("nogui", false, "无界面模式（仅命令行，不显示托盘和设置窗口）")
	flag.Parse()

	gConfPath = *configPath
	gCfg = loadConfig(gConfPath)
	if *portFlag > 0 {
		gCfg.port = *portFlag
	}
	if *timeoutFlag > 0 {
		gCfg.timeout = int64(*timeoutFlag)
	}
	if *logFlag != "" {
		gCfg.logFile = *logFlag
	}

	// 配置操作日志输出
	if gCfg.logFile != "" {
		f, err := os.OpenFile(gCfg.logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			log.Fatalf("无法打开日志文件 %s: %v", gCfg.logFile, err)
		}
		defer f.Close()
		log.SetOutput(io.MultiWriter(f))
		log.SetFlags(log.LstdFlags)
		opLog = log.Printf
	} else {
		opLog = func(format string, args ...any) {
			fmt.Printf(format+"\n", args...)
		}
	}

	cfg := getCfg()
	authMode := "无密码（免认证）"
	if cfg.password != "" {
		authMode = "已启用密码保护"
	}
	logMode := "控制台"
	if cfg.logFile != "" {
		logMode = cfg.logFile
	}
	fmt.Printf("===== 局域网键鼠遥控器 - 被控端 =====\n")
	fmt.Printf("系统: %s/%s\n", runtime.GOOS, runtime.GOARCH)
	fmt.Printf("监听端口: %d  超时: %dms  认证: %s\n", cfg.port, cfg.timeout, authMode)
	fmt.Printf("操作日志: %s\n", logMode)
	fmt.Printf("======================================\n\n")

	if *noGUI {
		// 纯命令行模式：UDP 服务器在主 goroutine 阻塞运行
		runUDPServer()
		return
	}

	// GUI 模式：UDP 服务器在后台 goroutine 运行，主线程运行系统托盘
	go runUDPServer()
	startWebConfig()
	runTray()
}

// runUDPServer 启动 UDP 监听循环（阻塞）
func runUDPServer() {
	cfg := getCfg()
	addr := fmt.Sprintf(":%d", cfg.port)
	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		log.Fatalf("解析地址失败: %v", err)
	}
	conn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		log.Fatalf("监听 UDP 失败: %v", err)
	}
	defer conn.Close()

	// 定期打印连接用户表
	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			printClients()
		}
	}()

	buf := make([]byte, bufferSize)
	for {
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil || n < 1 {
			continue
		}
		data := make([]byte, n)
		copy(data, buf[:n])
		go handlePacket(conn, remoteAddr, data)
	}
}

func handlePacket(conn *net.UDPConn, addr *net.UDPAddr, data []byte) {
	cfg := getCfg()
	cmd := data[0]
	now := time.Now().UnixMilli()
	ip := addr.IP.String()

	// ── 时间同步握手 (0x00) ──
	// 请求: [0x00] + [pwd_len 1B] + [password UTF-8]
	// 响应: [0x00] + [timestamp 8B] + [os 1B] + [auth 1B]
	if cmd == cmdTimeSync {
		providedPwd := ""
		if len(data) >= 2 {
			pwdLen := int(data[1])
			if len(data) >= 2+pwdLen {
				providedPwd = string(data[2 : 2+pwdLen])
			}
		}

		authResult := authOK
		if cfg.password != "" && providedPwd != cfg.password {
			authResult = authFail
			opLog("[%s] 认证失败（密码错误）", ip)
		} else {
			upsertClient(ip)
			if cfg.password != "" {
				opLog("[%s] 认证成功", ip)
			} else {
				opLog("[%s] 已连接", ip)
			}
			printClients()
		}

		reply := make([]byte, 11)
		reply[0] = cmdTimeSync
		binary.BigEndian.PutUint64(reply[1:9], uint64(now))
		reply[9] = getOSByte()
		reply[10] = authResult
		conn.WriteToUDP(reply, addr) //nolint:errcheck
		return
	}

	// ── 心跳 Ping ──
	// 旧格式：[0x10]（1字节），新格式：[0x10][timestamp 8B]（9字节）
	if cmd == cmdPing {
		if len(data) >= 9 {
			// 新格式：echo 时间戳，客户端可计算 RTT
			pong := make([]byte, 9)
			pong[0] = cmdPing
			copy(pong[1:], data[1:9])
			conn.WriteToUDP(pong, addr) //nolint:errcheck
			// 估算单向延迟（需时钟经过握手同步）
			clientTs := int64(binary.BigEndian.Uint64(data[1:9]))
			oneWay := now - clientTs
			if oneWay >= 0 && oneWay < 5000 {
				updateClientLatency(ip, oneWay)
			}
		} else {
			conn.WriteToUDP([]byte{cmdPing}, addr) //nolint:errcheck
			upsertClient(ip)
		}
		return
	}

	// 其他指令：最短 9 字节（cmd 1B + timestamp 8B）
	if len(data) < 9 {
		return
	}
	packetTime := int64(binary.BigEndian.Uint64(data[1:9]))
	if now > packetTime && (now-packetTime) > cfg.timeout {
		return // 超时丢包，防止堆积指令导致鼠标乱飞
	}

	updateClientActivity(ip)

	switch cmd {
	case cmdMouseMove:
		if len(data) >= 13 {
			dx := int(int16(binary.BigEndian.Uint16(data[9:11])))
			dy := int(int16(binary.BigEndian.Uint16(data[11:13])))
			robotgo.MoveRelative(dx, dy)
		}

	case cmdMouseClick:
		if len(data) >= 10 {
			robotgo.Click(buttonName(data[9]))
		}

	case cmdDblClick:
		if len(data) >= 10 {
			robotgo.Click(buttonName(data[9]), true)
		}

	case cmdMouseDown:
		if len(data) >= 10 {
			robotgo.MouseDown(buttonName(data[9]))
		}

	case cmdMouseUp:
		if len(data) >= 10 {
			robotgo.MouseUp(buttonName(data[9]))
		}

	case cmdMouseScroll:
		if len(data) >= 11 {
			scrollY := int(int16(binary.BigEndian.Uint16(data[9:11])))
			robotgo.Scroll(0, scrollY)
		}

	case cmdKeyTap:
		if len(data) >= 10 {
			if keyName, ok := keyMap[data[9]]; ok {
				robotgo.KeyTap(keyName)
			}
		}

	case cmdTextInput:
		if len(data) >= 11 {
			textLen := int(binary.BigEndian.Uint16(data[9:11]))
			if len(data) >= 11+textLen && textLen > 0 {
				text := strings.TrimSpace(string(data[11 : 11+textLen]))
				if text != "" {
					pasteText(text)
				}
			}
		}

	case cmdTextInputDirect:
		if len(data) >= 11 {
			textLen := int(binary.BigEndian.Uint16(data[9:11]))
			if len(data) >= 11+textLen && textLen > 0 {
				text := string(data[11 : 11+textLen])
				if text != "" {
					robotgo.TypeStr(text)
					opLog("文本输入(逐字): %q", text)
				}
			}
		}

	case cmdSysAction:
		if len(data) >= 10 {
			sysAction(data[9])
		}
	}
}

// pasteText 写入剪贴板并触发粘贴，写入失败时降级为逐字输入
// 使用显式 KeyDown + KeyTap + KeyUp 序列，比 KeyTap("v","command") 更可靠
func pasteText(text string) {
	if err := robotgo.WriteAll(text); err != nil {
		log.Printf("剪贴板写入失败（%v），改用逐字输入", err)
		robotgo.TypeStr(text)
		return
	}
	// 等待剪贴板内容生效，避免粘贴到上次内容
	time.Sleep(120 * time.Millisecond)
	if runtime.GOOS == "darwin" {
		robotgo.KeyDown("command")
		time.Sleep(30 * time.Millisecond)
		robotgo.KeyTap("v")
		time.Sleep(30 * time.Millisecond)
		robotgo.KeyUp("command")
	} else {
		robotgo.KeyDown("ctrl")
		time.Sleep(30 * time.Millisecond)
		robotgo.KeyTap("v")
		time.Sleep(30 * time.Millisecond)
		robotgo.KeyUp("ctrl")
	}
	opLog("文本输入(剪贴板): %q", text)
}

// modKey 返回当前平台的修饰键名
func modKey() string {
	if runtime.GOOS == "darwin" {
		return "command"
	}
	return "ctrl"
}

// keyCombo 按下修饰键 + 敲击目标键 + 松开修饰键
func keyCombo(mod, key string) {
	robotgo.KeyDown(mod)
	time.Sleep(20 * time.Millisecond)
	robotgo.KeyTap(key)
	time.Sleep(20 * time.Millisecond)
	robotgo.KeyUp(mod)
}

// sysAction 执行平台相关的系统操作
func sysAction(action byte) {
	// ── 跨平台编辑快捷键 ──
	mod := modKey()
	switch action {
	case sysSelectAll:
		keyCombo(mod, "a")
		return
	case sysCopy:
		keyCombo(mod, "c")
		return
	case sysCut:
		keyCombo(mod, "x")
		return
	case sysUndo:
		keyCombo(mod, "z")
		return
	case sysRedo:
		if runtime.GOOS == "darwin" {
			robotgo.KeyDown("command")
			robotgo.KeyDown("shift")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("z")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("shift")
			robotgo.KeyUp("command")
		} else {
			keyCombo("ctrl", "y")
		}
		return
	case sysSave:
		keyCombo(mod, "s")
		return
	}

	// ── 平台相关操作 ──
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		switch action {
		case sysLock:
			cmd = exec.Command("osascript", "-e",
				`tell application "System Events" to keystroke "q" using {control down, command down}`)
		case sysSleep:
			cmd = exec.Command("pmset", "sleepnow")
		case sysShutdown:
			cmd = exec.Command("osascript", "-e",
				`tell application "System Events" to shut down`)
		case sysRestart:
			cmd = exec.Command("osascript", "-e",
				`tell application "System Events" to restart`)
		case sysSwitchApp:
			robotgo.KeyDown("command")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("tab")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("command")
		case sysScreenshot:
			robotgo.KeyDown("command")
			robotgo.KeyDown("shift")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("3")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("shift")
			robotgo.KeyUp("command")
		case sysTaskView: // Mission Control
			robotgo.KeyDown("ctrl")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("up")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("ctrl")
		case sysShowDesktop:
			robotgo.KeyDown("ctrl")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("f3")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("ctrl")
		}
	case "windows":
		switch action {
		case sysLock:
			cmd = exec.Command("rundll32.exe", "user32.dll,LockWorkStation")
		case sysSleep:
			cmd = exec.Command("rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0")
		case sysShutdown:
			cmd = exec.Command("shutdown", "/s", "/t", "0")
		case sysRestart:
			cmd = exec.Command("shutdown", "/r", "/t", "0")
		case sysSwitchApp:
			robotgo.KeyDown("alt")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("tab")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("alt")
		case sysScreenshot:
			robotgo.KeyTap("snapshot") // PrintScreen
		case sysTaskView: // Win+Tab
			robotgo.KeyDown("lwin")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("tab")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("lwin")
		case sysShowDesktop: // Win+D
			robotgo.KeyDown("lwin")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyTap("d")
			time.Sleep(20 * time.Millisecond)
			robotgo.KeyUp("lwin")
		}
	}
	if cmd != nil {
		if err := cmd.Start(); err != nil {
			log.Printf("系统操作失败: %v", err)
		}
	}
}
