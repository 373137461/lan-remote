//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

const desktopFileName = "lan-remote-server.desktop"

func desktopFilePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "autostart", desktopFileName)
}

func isAutoStartEnabled() bool {
	_, err := os.Stat(desktopFilePath())
	return err == nil
}

func setAutoStart(enabled bool) error {
	path := desktopFilePath()
	if !enabled {
		return os.Remove(path)
	}

	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("获取程序路径失败: %w", err)
	}
	configPath, err := filepath.Abs(gConfPath)
	if err != nil {
		configPath = gConfPath
	}

	content := fmt.Sprintf(`[Desktop Entry]
Type=Application
Name=局域网键鼠遥控器
Exec="%s" -config "%s"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
`, exePath, configPath)

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0644)
}
