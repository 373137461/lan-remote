//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	svcName        = "LanRemoteServer"
	svcDisplayName = "局域网键鼠遥控器"
	svcDesc        = "局域网跨平台键鼠遥控器被控端，支持在系统登录界面控制鼠标和键盘"
)

// ── 状态查询 ──────────────────────────────────────────────────────────────

func isRunningAsService() bool {
	ok, err := svc.IsWindowsService()
	return err == nil && ok
}

func isServiceInstalled() bool {
	m, err := mgr.Connect()
	if err != nil {
		return false
	}
	defer m.Disconnect()
	s, err := m.OpenService(svcName)
	if err != nil {
		return false
	}
	s.Close()
	return true
}

// serviceStatus 查询服务状态，使用最低访问权限（SC_MANAGER_CONNECT + SERVICE_QUERY_STATUS），
// 普通用户进程也可调用，无需管理员权限。
func serviceStatus() string {
	// 绕过 mgr.Connect()（它使用 SC_MANAGER_ALL_ACCESS，非管理员会失败）
	// 直接用 WinAPI 以最小权限打开 SCM
	scmH, _, _ := procOpenSCManagerW.Call(0, 0, _SC_MANAGER_CONNECT)
	if scmH == 0 {
		return "unknown"
	}
	defer procCloseServiceHandle.Call(scmH)

	svcNamePtr, _ := syscall.UTF16PtrFromString(svcName)
	svcH, _, _ := procOpenServiceW.Call(scmH, uintptr(unsafe.Pointer(svcNamePtr)), _SERVICE_QUERY_STATUS)
	if svcH == 0 {
		return "not_installed"
	}
	defer procCloseServiceHandle.Call(svcH)

	var status _SERVICE_STATUS_PROCESS
	var needed uint32
	ret, _, _ := procQueryServiceStatusEx.Call(
		svcH,
		0, // SC_STATUS_PROCESS_INFO
		uintptr(unsafe.Pointer(&status)),
		uintptr(unsafe.Sizeof(status)),
		uintptr(unsafe.Pointer(&needed)),
	)
	if ret == 0 {
		return "unknown"
	}
	switch status.CurrentState {
	case _SVC_RUNNING:
		return "running"
	case _SVC_STOPPED:
		return "stopped"
	case _SVC_START_PENDING:
		return "starting"
	case _SVC_STOP_PENDING:
		return "stopping"
	default:
		return "unknown"
	}
}

// ── WinAPI 低权限查询所需常量与结构体 ─────────────────────────────────────

const (
	_SC_MANAGER_CONNECT   = 0x0001
	_SERVICE_QUERY_STATUS = 0x0004
	_SVC_STOPPED          = 1
	_SVC_START_PENDING    = 2
	_SVC_STOP_PENDING     = 3
	_SVC_RUNNING          = 4
)

type _SERVICE_STATUS_PROCESS struct {
	ServiceType             uint32
	CurrentState            uint32
	ControlsAccepted        uint32
	Win32ExitCode           uint32
	ServiceSpecificExitCode uint32
	CheckPoint              uint32
	WaitHint                uint32
	ProcessId               uint32
	ServiceFlags            uint32
}

var (
	modAdvapi32             = windows.NewLazySystemDLL("advapi32.dll")
	procOpenSCManagerW      = modAdvapi32.NewProc("OpenSCManagerW")
	procOpenServiceW        = modAdvapi32.NewProc("OpenServiceW")
	procQueryServiceStatusEx = modAdvapi32.NewProc("QueryServiceStatusEx")
	procCloseServiceHandle  = modAdvapi32.NewProc("CloseServiceHandle")
)

func isAdmin() bool {
	var t windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &t); err != nil {
		return false
	}
	defer t.Close()
	sid, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return false
	}
	ok, err := t.IsMember(sid)
	return err == nil && ok
}

// ── 安装 / 卸载 ───────────────────────────────────────────────────────────

func installService() error {
	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("获取可执行文件路径失败: %w", err)
	}
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("连接服务控制管理器失败（需管理员权限）: %w", err)
	}
	defer m.Disconnect()
	if s, err2 := m.OpenService(svcName); err2 == nil {
		s.Close()
		return fmt.Errorf("服务已存在，请先卸载")
	}
	s, err := m.CreateService(svcName, exePath, mgr.Config{
		StartType:        mgr.StartAutomatic,
		DisplayName:      svcDisplayName,
		Description:      svcDesc,
		ServiceStartName: "LocalSystem",
	}, "-service")
	if err != nil {
		return fmt.Errorf("创建服务失败: %w", err)
	}
	defer s.Close()
	if err := s.Start(); err != nil {
		return fmt.Errorf("服务已安装，启动失败: %w", err)
	}
	return nil
}

func uninstallService() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("连接服务控制管理器失败: %w", err)
	}
	defer m.Disconnect()
	s, err := m.OpenService(svcName)
	if err != nil {
		return fmt.Errorf("服务不存在: %w", err)
	}
	defer s.Close()
	s.Control(svc.Stop) //nolint:errcheck
	time.Sleep(time.Second)
	return s.Delete()
}

// elevateAndRun 用 ShellExecute runas 以管理员权限重新运行当前程序
func elevateAndRun(args string) error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	exePtr, _ := syscall.UTF16PtrFromString(exePath)
	argsPtr, _ := syscall.UTF16PtrFromString(args)
	verbPtr, _ := syscall.UTF16PtrFromString("runas")
	modShell32 := windows.NewLazyDLL("shell32.dll")
	shellExec := modShell32.NewProc("ShellExecuteW")
	r, _, _ := shellExec.Call(
		0,
		uintptr(unsafe.Pointer(verbPtr)),
		uintptr(unsafe.Pointer(exePtr)),
		uintptr(unsafe.Pointer(argsPtr)),
		0,
		1, // SW_SHOWNORMAL
	)
	if r <= 32 {
		return fmt.Errorf("ShellExecute 失败，返回值: %d", r)
	}
	return nil
}

// ── SCM 服务主入口 ────────────────────────────────────────────────────────

func runAsService() {
	svc.Run(svcName, &lanRemoteSvc{}) //nolint:errcheck
}

type lanRemoteSvc struct{}

var (
	workerProcMu sync.Mutex
	workerProc   *os.Process
)

func (s *lanRemoteSvc) Execute(_ []string, r <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	done := make(chan struct{})
	go s.manageWorker(done)
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for req := range r {
		if req.Cmd == svc.Stop || req.Cmd == svc.Shutdown {
			status <- svc.Status{State: svc.StopPending}
			close(done)
			s.killWorker()
			return false, 0
		}
	}
	return false, 0
}

func (s *lanRemoteSvc) manageWorker(done <-chan struct{}) {
	for {
		select {
		case <-done:
			return
		default:
		}
		sessionId := wtsGetActiveConsoleSessionId()
		if sessionId != 0xFFFFFFFF {
			proc, err := spawnWorkerInSession(sessionId)
			if err == nil {
				workerProcMu.Lock()
				workerProc = proc
				workerProcMu.Unlock()
				proc.Wait()
				workerProcMu.Lock()
				workerProc = nil
				workerProcMu.Unlock()
			}
		}
		select {
		case <-done:
			return
		case <-time.After(3 * time.Second):
		}
	}
}

func (s *lanRemoteSvc) killWorker() {
	workerProcMu.Lock()
	p := workerProc
	workerProcMu.Unlock()
	if p != nil {
		p.Kill() //nolint:errcheck
	}
}

// ── Session 工具函数 ───────────────────────────────────────────────────────

var (
	modKernel32                      = windows.NewLazySystemDLL("kernel32.dll")
	modWtsapi32                      = windows.NewLazyDLL("wtsapi32.dll")
	procWTSGetActiveConsoleSessionId = modKernel32.NewProc("WTSGetActiveConsoleSessionId")
	procWTSQueryUserToken            = modWtsapi32.NewProc("WTSQueryUserToken")
	procProcessIdToSessionId         = modKernel32.NewProc("ProcessIdToSessionId")
)

func wtsGetActiveConsoleSessionId() uint32 {
	r, _, _ := procWTSGetActiveConsoleSessionId.Call()
	return uint32(r)
}

func wtsQueryUserToken(sessionId uint32) (windows.Token, error) {
	var token windows.Token
	r, _, e := procWTSQueryUserToken.Call(uintptr(sessionId), uintptr(unsafe.Pointer(&token)))
	if r == 0 {
		return 0, e
	}
	return token, nil
}

// getWinlogonToken 获取目标 session 中 winlogon.exe 的 SYSTEM 令牌（登录界面时使用）
func getWinlogonToken(sessionId uint32) (windows.Token, error) {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return 0, err
	}
	defer windows.CloseHandle(snapshot)
	var pe windows.ProcessEntry32
	pe.Size = uint32(unsafe.Sizeof(pe))
	if err := windows.Process32First(snapshot, &pe); err != nil {
		return 0, err
	}
	for {
		name := windows.UTF16ToString(pe.ExeFile[:])
		if name == "winlogon.exe" {
			ph, err := windows.OpenProcess(windows.PROCESS_QUERY_INFORMATION, false, pe.ProcessID)
			if err == nil {
				var sid uint32
				r, _, _ := procProcessIdToSessionId.Call(uintptr(pe.ProcessID), uintptr(unsafe.Pointer(&sid)))
				if r != 0 && sid == sessionId {
					var token windows.Token
					if err3 := windows.OpenProcessToken(ph, windows.TOKEN_ALL_ACCESS, &token); err3 == nil {
						windows.CloseHandle(ph)
						return token, nil
					}
				}
				windows.CloseHandle(ph)
			}
		}
		if err := windows.Process32Next(snapshot, &pe); err != nil {
			break
		}
	}
	return 0, fmt.Errorf("winlogon.exe not found in session %d", sessionId)
}

// spawnWorkerInSession 在指定 session 启动自身的 -worker 模式（使用 SYSTEM 令牌）
func spawnWorkerInSession(sessionId uint32) (*os.Process, error) {
	// 优先使用 winlogon 的 SYSTEM 令牌，可访问 Winlogon 桌面
	token, err := getWinlogonToken(sessionId)
	if err != nil {
		// fallback：用已登录用户令牌
		token, err = wtsQueryUserToken(sessionId)
		if err != nil {
			return nil, fmt.Errorf("获取 session %d 令牌失败: %w", sessionId, err)
		}
	}
	defer token.Close()

	var primaryToken windows.Token
	if err := windows.DuplicateTokenEx(token, windows.TOKEN_ALL_ACCESS, nil,
		windows.SecurityImpersonation, windows.TokenPrimary, &primaryToken); err != nil {
		return nil, fmt.Errorf("复制令牌失败: %w", err)
	}
	defer primaryToken.Close()

	exePath, err := os.Executable()
	if err != nil {
		return nil, err
	}

	cmdLine := `"` + exePath + `" -worker`
	cmdLinePtr, err := syscall.UTF16PtrFromString(cmdLine)
	if err != nil {
		return nil, err
	}
	desktopPtr, _ := syscall.UTF16PtrFromString(`WinSta0\Default`)
	var si windows.StartupInfo
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Desktop = desktopPtr
	var pi windows.ProcessInformation
	if err := windows.CreateProcessAsUser(primaryToken, nil, cmdLinePtr,
		nil, nil, false,
		windows.CREATE_NO_WINDOW|windows.CREATE_UNICODE_ENVIRONMENT,
		nil, nil, &si, &pi); err != nil {
		return nil, fmt.Errorf("CreateProcessAsUser 失败: %w", err)
	}
	windows.CloseHandle(pi.Thread) //nolint:errcheck
	proc, err := os.FindProcess(int(pi.ProcessId))
	if err != nil {
		windows.TerminateProcess(pi.Process, 1) //nolint:errcheck
		windows.CloseHandle(pi.Process)
		return nil, err
	}
	windows.CloseHandle(pi.Process)
	return proc, nil
}

// ── Web 配置 API（Windows 服务管理） ─────────────────────────────────────

func registerServiceRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/service/status", handleServiceStatus)
	mux.HandleFunc("/api/service/install", handleServiceInstall)
	mux.HandleFunc("/api/service/uninstall", handleServiceUninstall)
}

func handleServiceStatus(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]string{"status": serviceStatus()}) //nolint:errcheck
}

func handleServiceInstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isAdmin() {
		http.Error(w, "需要管理员权限，请通过托盘图标操作，或以管理员身份运行后刷新", http.StatusForbidden)
		return
	}
	if err := installService(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Write([]byte("ok")) //nolint:errcheck
}

func handleServiceUninstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isAdmin() {
		http.Error(w, "需要管理员权限，请通过托盘图标操作，或以管理员身份运行后刷新", http.StatusForbidden)
		return
	}
	if err := uninstallService(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Write([]byte("ok")) //nolint:errcheck
}
