//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// webPortFilePath 返回 worker 写入 web 配置端口的文件路径（可执行文件同目录）
func webPortFilePath() string {
	exePath, _ := os.Executable()
	return filepath.Join(filepath.Dir(exePath), "webport")
}

// writeWebPort 将 web 配置端口写入文件，供管理进程读取
func writeWebPort(port int) {
	_ = os.WriteFile(webPortFilePath(), []byte(strconv.Itoa(port)), 0644)
}

// readWebPort 从文件读取 worker 的 web 配置端口
func readWebPort() (int, error) {
	data, err := os.ReadFile(webPortFilePath())
	if err != nil {
		return 0, err
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0, fmt.Errorf("webport 文件格式错误: %w", err)
	}
	if port <= 0 || port > 65535 {
		return 0, fmt.Errorf("webport 无效: %d", port)
	}
	return port, nil
}

// removeWebPortFile 删除端口文件（worker 退出时调用）
func removeWebPortFile() {
	_ = os.Remove(webPortFilePath())
}
