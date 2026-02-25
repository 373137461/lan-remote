//go:build darwin

package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"text/template"
)

const plistLabel = "com.lanremote.server"

var plistTmpl = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{{.Label}}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{{.ExePath}}</string>
		<string>-config</string>
		<string>{{.ConfigPath}}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
`

func plistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", plistLabel+".plist")
}

func isAutoStartEnabled() bool {
	_, err := os.Stat(plistPath())
	return err == nil
}

func setAutoStart(enabled bool) error {
	path := plistPath()
	if !enabled {
		exec.Command("launchctl", "unload", path).Run() //nolint:errcheck
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

	t, err := template.New("plist").Parse(plistTmpl)
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, map[string]string{
		"Label":      plistLabel,
		"ExePath":    exePath,
		"ConfigPath": configPath,
	}); err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	if err := os.WriteFile(path, buf.Bytes(), 0644); err != nil {
		return err
	}
	return exec.Command("launchctl", "load", path).Run()
}
