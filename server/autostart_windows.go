//go:build windows

package main

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
)

const (
	regKeyPath   = `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`
	regValueName = "LanRemoteServer"
)

func isAutoStartEnabled() bool {
	out, err := exec.Command("reg", "query", regKeyPath, "/v", regValueName).Output()
	return err == nil && strings.Contains(string(out), regValueName)
}

func setAutoStart(enabled bool) error {
	var cmd *exec.Cmd
	if enabled {
		exePath, err := os.Executable()
		if err != nil {
			return err
		}
		cmd = exec.Command("reg", "add", regKeyPath, "/v", regValueName, "/t", "REG_SZ", "/d", exePath, "/f")
	} else {
		cmd = exec.Command("reg", "delete", regKeyPath, "/v", regValueName, "/f")
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return cmd.Run()
}
