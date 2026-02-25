//go:build windows

package main

import "syscall"

// hideConsoleWindow 在 GUI 模式下调用 FreeConsole 隐藏命令行窗口。
func hideConsoleWindow() {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	kernel32.NewProc("FreeConsole").Call()
}
