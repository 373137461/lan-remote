package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"time"

	"fyne.io/systray"
)

func runTray() {
	systray.Run(onTrayReady, func() {})
}

func onTrayReady() {
	systray.SetIcon(prepareIcon(iconData))
	systray.SetTooltip("局域网键鼠遥控器")

	if managerMode {
		onTrayReadyManager()
		return
	}
	onTrayReadyNormal()
}

// restartSelf 重启当前进程（用于安装服务后切换到管理模式）。
func restartSelf() {
	exe, err := os.Executable()
	if err != nil {
		os.Exit(0)
		return
	}
	exec.Command(exe).Start() //nolint:errcheck
	os.Exit(0)
}

// ── 普通模式托盘 ──────────────────────────────────────────────────────────

func onTrayReadyNormal() {
	cfg := getCfg()
	statusText := fmt.Sprintf("端口 %d", cfg.port)
	if cfg.password != "" {
		statusText += " · 已设密码"
	} else {
		statusText += " · 无密码"
	}
	mStatus := systray.AddMenuItem(statusText, "")
	mStatus.Disable()

	systray.AddSeparator()
	mSettings := systray.AddMenuItem("设置...", "打开网页配置")
	systray.AddSeparator()

	mAutostart := systray.AddMenuItemCheckbox("开机启动", "", isAutoStartEnabled())

	// Windows 专属：服务管理
	var mSvcStatus *systray.MenuItem
	var mInstall *systray.MenuItem
	if runtime.GOOS == "windows" {
		systray.AddSeparator()
		mSvcStatus = systray.AddMenuItem("服务状态：未安装（低权限）", "")
		mSvcStatus.Disable()
		mInstall = systray.AddMenuItem("安装服务", "安装为 Windows 系统服务")
	}

	systray.AddSeparator()
	mQuit := systray.AddMenuItem("退出", "退出局域网键鼠遥控器")

	go func() {
		for {
			select {
			case <-mSettings.ClickedCh:
				openBrowserConfig()
			case <-mQuit.ClickedCh:
				systray.Quit()
				os.Exit(0)
			}
		}
	}()

	go func() {
		for range mAutostart.ClickedCh {
			enabled := !isAutoStartEnabled()
			if err := setAutoStart(enabled); err != nil {
				fmt.Printf("自启动设置失败: %v\n", err)
			}
			if isAutoStartEnabled() {
				mAutostart.Check()
			} else {
				mAutostart.Uncheck()
			}
		}
	}()

	if runtime.GOOS == "windows" && mInstall != nil {
		go func() {
			for range mInstall.ClickedCh {
				mInstall.Disable()
				go func() {
					defer mInstall.Enable()
					go elevateAndRun("-install-service") //nolint:errcheck

					// 轮询等待服务启动（最多 20 秒，每秒检测一次）
					deadline := time.Now().Add(20 * time.Second)
					for time.Now().Before(deadline) {
						time.Sleep(time.Second)
						st := serviceStatus()
						if st == "running" || st == "starting" {
							// 安装并启动成功，重启进程进入管理模式
							restartSelf()
							return
						}
					}
					// 超时仍未启动，自动卸载并报错
					go elevateAndRun("-uninstall-service") //nolint:errcheck
					showError("服务安装后未能成功启动，已自动卸载。\n请以管理员身份运行后重试。")
				}()
			}
		}()
	}
}

// ── 管理模式托盘 ──────────────────────────────────────────────────────────

func svcStatusLabel(st string) string {
	switch st {
	case "running", "starting":
		return "已安装-正在运行"
	case "stopped", "stopping":
		return "已安装-未运行"
	default:
		return "未安装（低权限）"
	}
}

func onTrayReadyManager() {
	// 1. 服务状态（动态更新）
	mSvcStatus := systray.AddMenuItem("服务状态：检测中…", "")
	mSvcStatus.Disable()

	systray.AddSeparator()
	mSettings := systray.AddMenuItem("设置...", "打开网页配置")
	systray.AddSeparator()

	// 2. 开机启动
	mAutostart := systray.AddMenuItemCheckbox("开机启动", "", isAutoStartEnabled())

	systray.AddSeparator()

	// 3. 服务管理操作
	mInstall := systray.AddMenuItem("安装服务", "安装为 Windows 系统服务")
	mUninstall := systray.AddMenuItem("卸载服务", "卸载系统服务")
	mStart := systray.AddMenuItem("启动服务", "启动系统服务")
	mStop := systray.AddMenuItem("停止服务", "停止系统服务")

	systray.AddSeparator()

	// 4. 完全退出
	mFullQuit := systray.AddMenuItem("完全退出", "停止服务并退出管理进程")
	// 5. 退出管理进程
	mQuit := systray.AddMenuItem("退出管理进程", "关闭托盘图标，服务继续运行")

	// 状态轮询：立即刷新，之后每 5 秒更新一次
	// 若检测到服务已不存在，自动重启进程切换回普通模式
	refreshStatus := func() {
		st := serviceStatus()
		mSvcStatus.SetTitle("服务状态：" + svcStatusLabel(st))
		switch st {
		case "running", "starting":
			mStart.Disable()
			mStop.Enable()
		case "stopped", "stopping":
			mStart.Enable()
			mStop.Disable()
		default:
			// 服务已卸载，重启进入普通模式
			restartSelf()
		}
	}
	refreshStatus()
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			refreshStatus()
		}
	}()

	// 开机启动
	go func() {
		for range mAutostart.ClickedCh {
			enabled := !isAutoStartEnabled()
			if err := setAutoStart(enabled); err != nil {
				fmt.Printf("自启动设置失败: %v\n", err)
			}
			if isAutoStartEnabled() {
				mAutostart.Check()
			} else {
				mAutostart.Uncheck()
			}
		}
	}()

	// 服务管理 + 退出
	go func() {
		for {
			select {
			case <-mSettings.ClickedCh:
				openBrowserConfig()
			case <-mInstall.ClickedCh:
				go elevateAndRun("-install-service") //nolint:errcheck
			case <-mUninstall.ClickedCh:
				go elevateAndRun("-uninstall-service") //nolint:errcheck
			case <-mStart.ClickedCh:
				go elevateAndRun("-start-service") //nolint:errcheck
			case <-mStop.ClickedCh:
				go elevateAndRun("-stop-service") //nolint:errcheck
			case <-mFullQuit.ClickedCh:
				// 停止服务，等待最多 8 秒后退出
				if isAdmin() {
					stopService() //nolint:errcheck
				} else {
					go elevateAndRun("-stop-service") //nolint:errcheck
				}
				deadline := time.Now().Add(8 * time.Second)
				for time.Now().Before(deadline) {
					time.Sleep(500 * time.Millisecond)
					st := serviceStatus()
					if st == "stopped" || st == "not_installed" || st == "unknown" {
						break
					}
				}
				systray.Quit()
				os.Exit(0)
			case <-mQuit.ClickedCh:
				systray.Quit()
				os.Exit(0)
			}
		}
	}()
}

// prepareIcon 在 Windows 上将 PNG 包装为最小 ICO 容器（Vista+ 原生支持），
// macOS / Linux 直接使用 PNG 字节。
func prepareIcon(png []byte) []byte {
	if runtime.GOOS != "windows" {
		return png
	}
	n := len(png)
	// ICONDIR (6B) + ICONDIRENTRY (16B) = 22B 头部，图像数据紧随其后
	ico := []byte{
		0, 0,      // idReserved
		1, 0,      // idType: 1 = ICO
		1, 0,      // idCount: 1 张图
		0,         // bWidth:  0 表示 256px
		0,         // bHeight: 0 表示 256px
		0,         // bColorCount
		0,         // bReserved
		1, 0,      // wPlanes
		32, 0,     // wBitCount: 32bpp
		byte(n), byte(n >> 8), byte(n >> 16), byte(n >> 24), // dwBytesInRes
		22, 0, 0, 0, // dwImageOffset = 6+16 = 22
	}
	return append(ico, png...)
}
