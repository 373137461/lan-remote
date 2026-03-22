//go:build windows

package main

import (
	"runtime"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ── Windows INPUT 结构体（amd64，40 字节） ─────────────────────────────────

const (
	_INPUT_MOUSE    = 0
	_INPUT_KEYBOARD = 1

	_MOUSEEVENTF_MOVE       = 0x0001
	_MOUSEEVENTF_LEFTDOWN   = 0x0002
	_MOUSEEVENTF_LEFTUP     = 0x0004
	_MOUSEEVENTF_RIGHTDOWN  = 0x0008
	_MOUSEEVENTF_RIGHTUP    = 0x0010
	_MOUSEEVENTF_MIDDLEDOWN = 0x0020
	_MOUSEEVENTF_MIDDLEUP   = 0x0040
	_MOUSEEVENTF_WHEEL      = 0x0800

	_KEYEVENTF_KEYDOWN     = 0x0000
	_KEYEVENTF_EXTENDEDKEY = 0x0001
	_KEYEVENTF_KEYUP       = 0x0002
	_KEYEVENTF_UNICODE     = 0x0004

	_GENERIC_ALL = 0x10000000

	_WHEEL_DELTA = 120

	// Virtual Key codes
	_VK_BACK     = 0x08
	_VK_TAB      = 0x09
	_VK_RETURN   = 0x0D
	_VK_SHIFT    = 0x10
	_VK_CONTROL  = 0x11
	_VK_MENU     = 0x12 // Alt
	_VK_LWIN     = 0x5B
	_VK_ESCAPE   = 0x1B
	_VK_SPACE    = 0x20
	_VK_PRIOR    = 0x21 // Page Up
	_VK_NEXT     = 0x22 // Page Down
	_VK_END      = 0x23
	_VK_HOME     = 0x24
	_VK_LEFT     = 0x25
	_VK_UP       = 0x26
	_VK_RIGHT    = 0x27
	_VK_DOWN     = 0x28
	_VK_SNAPSHOT = 0x2C // Print Screen
	_VK_DELETE   = 0x2E
	_VK_F1       = 0x70
	// F2-F12: 0x71-0x7B
)

// mouseINPUT matches Windows INPUT with type=INPUT_MOUSE (40 bytes on amd64)
// Layout: Type(4)+pad(4)+dx(4)+dy(4)+mouseData(4)+flags(4)+time(4)+pad(4)+extraInfo(8)
type mouseINPUT struct {
	typ       uint32
	_pad1     uint32
	dx        int32
	dy        int32
	mouseData uint32
	flags     uint32
	time      uint32
	_pad2     uint32
	extraInfo uintptr
}

// keybdINPUT matches Windows INPUT with type=INPUT_KEYBOARD (40 bytes on amd64)
// Layout: Type(4)+pad(4)+vk(2)+scan(2)+flags(4)+time(4)+pad(4)+pad(4)+extraInfo(8)
type keybdINPUT struct {
	typ       uint32
	_pad1     uint32
	vk        uint16
	scan      uint16
	flags     uint32
	time      uint32
	_pad2     uint32
	_pad3     uint32
	extraInfo uintptr
}

var _inputSize = unsafe.Sizeof(mouseINPUT{})

var (
	modUser32            = windows.NewLazySystemDLL("user32.dll")
	procSendInput        = modUser32.NewProc("SendInput")
	procOpenInputDesktop = modUser32.NewProc("OpenInputDesktop")
	procSetThreadDesktop = modUser32.NewProc("SetThreadDesktop")
	procGetThreadDesktop = modUser32.NewProc("GetThreadDesktop")
	procCloseDesktop     = modUser32.NewProc("CloseDesktop")
	procGetCurrentTid    = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetCurrentThreadId")
)

// withInputDesktop 锁定 OS 线程，切换到当前活动输入桌面（Default 或 Winlogon），
// 执行 fn 后恢复原桌面。
func withInputDesktop(fn func()) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	// 获取当前线程 ID 和原桌面
	tid, _, _ := procGetCurrentTid.Call()
	hOld, _, _ := procGetThreadDesktop.Call(tid)

	// 打开当前活动输入桌面（登录界面时为 Winlogon，否则为 Default）
	hDesk, _, _ := procOpenInputDesktop.Call(0, 0, uintptr(_GENERIC_ALL))
	if hDesk == 0 || hDesk == hOld {
		if hDesk != 0 {
			procCloseDesktop.Call(hDesk)
		}
		fn()
		return
	}

	procSetThreadDesktop.Call(hDesk)
	fn()
	procSetThreadDesktop.Call(hOld)
	procCloseDesktop.Call(hDesk)
}

func sendMouseINPUT(inp mouseINPUT) {
	procSendInput.Call(1, uintptr(unsafe.Pointer(&inp)), _inputSize) //nolint:errcheck
}

func sendKeybdINPUT(inp keybdINPUT) {
	procSendInput.Call(1, uintptr(unsafe.Pointer(&inp)), _inputSize) //nolint:errcheck
}

// ── 鼠标操作 ──────────────────────────────────────────────────────────────

func winMouseMove(dx, dy int) {
	withInputDesktop(func() {
		sendMouseINPUT(mouseINPUT{
			typ:   _INPUT_MOUSE,
			dx:    int32(dx),
			dy:    int32(dy),
			flags: _MOUSEEVENTF_MOVE,
		})
	})
}

func winMouseButtonEvent(btn string, down bool) {
	var flags uint32
	switch btn {
	case "right":
		if down {
			flags = _MOUSEEVENTF_RIGHTDOWN
		} else {
			flags = _MOUSEEVENTF_RIGHTUP
		}
	case "center":
		if down {
			flags = _MOUSEEVENTF_MIDDLEDOWN
		} else {
			flags = _MOUSEEVENTF_MIDDLEUP
		}
	default: // left
		if down {
			flags = _MOUSEEVENTF_LEFTDOWN
		} else {
			flags = _MOUSEEVENTF_LEFTUP
		}
	}
	withInputDesktop(func() {
		sendMouseINPUT(mouseINPUT{typ: _INPUT_MOUSE, flags: flags})
	})
}

func winMouseClick(btn string) {
	winMouseButtonEvent(btn, true)
	time.Sleep(20 * time.Millisecond)
	winMouseButtonEvent(btn, false)
}

func winMouseDblClick(btn string) {
	winMouseClick(btn)
	time.Sleep(50 * time.Millisecond)
	winMouseClick(btn)
}

func winMouseDown(btn string) { winMouseButtonEvent(btn, true) }
func winMouseUp(btn string)   { winMouseButtonEvent(btn, false) }

func winMouseScroll(scrollY int) {
	// robotgo Scroll 的 scrollY: 正=向上，负=向下
	// MOUSEEVENTF_WHEEL: 正 mouseData = 向上
	delta := int32(scrollY) * _WHEEL_DELTA
	withInputDesktop(func() {
		sendMouseINPUT(mouseINPUT{
			typ:       _INPUT_MOUSE,
			mouseData: uint32(delta),
			flags:     _MOUSEEVENTF_WHEEL,
		})
	})
}

// ── 键盘操作 ──────────────────────────────────────────────────────────────

// vkMap 将 main.go 中 keyMap 的 byte code 映射到 Windows VK 码
var vkMap = map[byte]uint16{
	13: _VK_RETURN,
	8:  _VK_BACK,
	27: _VK_ESCAPE,
	9:  _VK_TAB,
	32: _VK_SPACE,
	37: _VK_LEFT,
	38: _VK_UP,
	39: _VK_RIGHT,
	40: _VK_DOWN,
	46: _VK_DELETE,
	36: _VK_HOME,
	35: _VK_END,
	33: _VK_PRIOR,
	34: _VK_NEXT,
	112: _VK_F1, 113: _VK_F1 + 1, 114: _VK_F1 + 2,
	115: _VK_F1 + 3, 116: _VK_F1 + 4, 117: _VK_F1 + 5,
	118: _VK_F1 + 6, 119: _VK_F1 + 7, 120: _VK_F1 + 8,
	121: _VK_F1 + 9, 122: _VK_F1 + 10, 123: _VK_F1 + 11,
}

func sendVKDown(vk uint16) {
	flags := uint32(_KEYEVENTF_KEYDOWN)
	if vk > 0x7F {
		flags |= _KEYEVENTF_EXTENDEDKEY
	}
	sendKeybdINPUT(keybdINPUT{typ: _INPUT_KEYBOARD, vk: vk, flags: flags})
}

func sendVKUp(vk uint16) {
	flags := uint32(_KEYEVENTF_KEYUP)
	if vk > 0x7F {
		flags |= _KEYEVENTF_EXTENDEDKEY
	}
	sendKeybdINPUT(keybdINPUT{typ: _INPUT_KEYBOARD, vk: vk, flags: flags})
}

func winKeyVKTap(vk uint16) {
	withInputDesktop(func() {
		sendVKDown(vk)
		time.Sleep(10 * time.Millisecond)
		sendVKUp(vk)
	})
}

func winKeyVKDown(vk uint16) {
	withInputDesktop(func() { sendVKDown(vk) })
}

func winKeyVKUp(vk uint16) {
	withInputDesktop(func() { sendVKUp(vk) })
}

// winKeyTap 对应 main.go 的 cmdKeyTap，参数为协议中的 byte code
func winKeyTap(code byte) {
	if vk, ok := vkMap[code]; ok {
		winKeyVKTap(vk)
		return
	}
	// ASCII 可打印字符：直接用 Unicode 方式发送
	if code >= 32 && code <= 126 {
		withInputDesktop(func() {
			r := rune(code)
			sendKeybdINPUT(keybdINPUT{
				typ:   _INPUT_KEYBOARD,
				scan:  uint16(r),
				flags: _KEYEVENTF_UNICODE,
			})
			time.Sleep(5 * time.Millisecond)
			sendKeybdINPUT(keybdINPUT{
				typ:   _INPUT_KEYBOARD,
				scan:  uint16(r),
				flags: _KEYEVENTF_UNICODE | _KEYEVENTF_KEYUP,
			})
		})
	}
}

// winKeyNameToVK 将 robotgo 风格的键名转为 VK 码（供 winSysAction 使用）
func winKeyNameToVK(name string) uint16 {
	switch name {
	case "ctrl", "control":
		return _VK_CONTROL
	case "alt", "menu":
		return _VK_MENU
	case "shift":
		return _VK_SHIFT
	case "lwin", "win", "super":
		return _VK_LWIN
	case "tab":
		return _VK_TAB
	case "return", "enter":
		return _VK_RETURN
	case "d":
		return 'D'
	case "a":
		return 'A'
	case "c":
		return 'C'
	case "x":
		return 'X'
	case "z":
		return 'Z'
	case "y":
		return 'Y'
	case "s":
		return 'S'
	case "v":
		return 'V'
	case "snapshot", "printscreen":
		return _VK_SNAPSHOT
	default:
		if len(name) == 1 {
			return uint16([]rune(name)[0] & 0xFF)
		}
		return 0
	}
}

// winKeyCombo 对应 main.go 的 keyCombo，在 worker 模式下使用
func winKeyCombo(mod, key string) {
	modVK := winKeyNameToVK(mod)
	keyVK := winKeyNameToVK(key)
	if modVK == 0 || keyVK == 0 {
		return
	}
	withInputDesktop(func() {
		sendVKDown(modVK)
		time.Sleep(20 * time.Millisecond)
		sendVKDown(keyVK)
		time.Sleep(10 * time.Millisecond)
		sendVKUp(keyVK)
		time.Sleep(10 * time.Millisecond)
		sendVKUp(modVK)
	})
}

// winKeyCombo2 两个修饰键 + 一个字符键
func winKeyCombo2(mod1, mod2, key string) {
	v1, v2, vk := winKeyNameToVK(mod1), winKeyNameToVK(mod2), winKeyNameToVK(key)
	if v1 == 0 || v2 == 0 || vk == 0 {
		return
	}
	withInputDesktop(func() {
		sendVKDown(v1)
		sendVKDown(v2)
		time.Sleep(20 * time.Millisecond)
		sendVKDown(vk)
		time.Sleep(10 * time.Millisecond)
		sendVKUp(vk)
		sendVKUp(v2)
		sendVKUp(v1)
	})
}

// winTypeStr 逐字发送 Unicode 文本（使用 KEYEVENTF_UNICODE，支持中文）
func winTypeStr(text string) {
	withInputDesktop(func() {
		for _, r := range text {
			sendKeybdINPUT(keybdINPUT{
				typ:   _INPUT_KEYBOARD,
				scan:  uint16(r),
				flags: _KEYEVENTF_UNICODE,
			})
			time.Sleep(5 * time.Millisecond)
			sendKeybdINPUT(keybdINPUT{
				typ:   _INPUT_KEYBOARD,
				scan:  uint16(r),
				flags: _KEYEVENTF_UNICODE | _KEYEVENTF_KEYUP,
			})
		}
	})
}

// winSysActionWindows 处理 worker 模式下 Windows 平台的系统操作
// （替代 sysAction 中使用 robotgo 的部分）
func winSysActionWindows(action byte) bool {
	switch action {
	case sysSwitchApp: // Alt+Tab
		withInputDesktop(func() {
			sendVKDown(_VK_MENU)
			time.Sleep(20 * time.Millisecond)
			sendVKDown(_VK_TAB)
			time.Sleep(10 * time.Millisecond)
			sendVKUp(_VK_TAB)
			time.Sleep(10 * time.Millisecond)
			sendVKUp(_VK_MENU)
		})
		return true
	case sysScreenshot: // Print Screen
		winKeyVKTap(_VK_SNAPSHOT)
		return true
	case sysTaskView: // Win+Tab
		winKeyCombo("lwin", "tab")
		return true
	case sysShowDesktop: // Win+D
		winKeyCombo("lwin", "d")
		return true
	case sysSelectAll:
		winKeyCombo("ctrl", "a")
		return true
	case sysCopy:
		winKeyCombo("ctrl", "c")
		return true
	case sysCut:
		winKeyCombo("ctrl", "x")
		return true
	case sysUndo:
		winKeyCombo("ctrl", "z")
		return true
	case sysRedo:
		winKeyCombo("ctrl", "y")
		return true
	case sysSave:
		winKeyCombo("ctrl", "s")
		return true
	}
	return false
}

// winExecuteShortcutString 解析 "command+shift+a" 格式并在 worker 模式下执行
func winExecuteShortcutString(keys string) {
	parts := make([]string, 0)
	for _, p := range strings.Split(keys, "+") {
		p = strings.TrimSpace(strings.ToLower(p))
		if p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) == 0 {
		return
	}
	key := winKeyNameToVK(parts[len(parts)-1])
	if key == 0 {
		return
	}
	mods := make([]uint16, 0, len(parts)-1)
	for _, m := range parts[:len(parts)-1] {
		vk := winKeyNameToVK(mapModifier(m))
		if vk != 0 {
			mods = append(mods, vk)
		}
	}
	withInputDesktop(func() {
		for _, vk := range mods {
			sendVKDown(vk)
			time.Sleep(15 * time.Millisecond)
		}
		sendVKDown(key)
		time.Sleep(10 * time.Millisecond)
		sendVKUp(key)
		time.Sleep(10 * time.Millisecond)
		for i := len(mods) - 1; i >= 0; i-- {
			sendVKUp(mods[i])
			time.Sleep(15 * time.Millisecond)
		}
	})
}
