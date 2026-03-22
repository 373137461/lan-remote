package main

import (
	"fmt"
	"os"
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

	cfg := getCfg()
	statusText := fmt.Sprintf("端口 %d", cfg.port)
	if cfg.password != "" {
		statusText += " · 已设密码"
	} else {
		statusText += " · 无密码"
	}
	// worker 模式（服务已安装）加上标识
	if workerMode {
		statusText += " · 服务模式"
	}
	mStatus := systray.AddMenuItem(statusText, "")
	mStatus.Disable()

	systray.AddSeparator()
	mSettings := systray.AddMenuItem("设置...", "打开网页配置")
	systray.AddSeparator()

	// worker 模式下开机自启动由服务管理，隐藏此项
	var mAutostart *systray.MenuItem
	if !workerMode {
		mAutostart = systray.AddMenuItemCheckbox("开机自启动", "", isAutoStartEnabled())
	}

	// Windows 专属：系统服务安装 / 卸载
	var mSvcInstall, mSvcUninstall *systray.MenuItem
	if runtime.GOOS == "windows" {
		systray.AddSeparator()
		mSvcInstall = systray.AddMenuItem("安装为系统服务", "开机自启，支持在登录界面控制鼠标键盘")
		mSvcUninstall = systray.AddMenuItem("卸载系统服务", "")
		if isServiceInstalled() {
			mSvcInstall.Disable()
		} else {
			mSvcUninstall.Disable()
		}
	}

	systray.AddSeparator()
	var mQuit *systray.MenuItem
	if workerMode {
		// worker 模式退出后服务会在 3 秒内自动重启，给出提示
		mQuit = systray.AddMenuItem("退出托盘（服务将自动重启）", "")
	} else {
		mQuit = systray.AddMenuItem("退出", "退出局域网键鼠遥控器")
	}

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

	// 开机自启动（仅非服务模式）
	if mAutostart != nil {
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
	}

	// Windows 服务安装/卸载菜单处理
	if runtime.GOOS == "windows" && mSvcInstall != nil {
		go func() {
			for {
				select {
				case <-mSvcInstall.ClickedCh:
					go func() {
						elevateAndRun("-install-service") //nolint:errcheck
						time.Sleep(2 * time.Second)
						if isServiceInstalled() {
							mSvcInstall.Disable()
							mSvcUninstall.Enable()
						}
					}()
				case <-mSvcUninstall.ClickedCh:
					go func() {
						elevateAndRun("-uninstall-service") //nolint:errcheck
						time.Sleep(2 * time.Second)
						if !isServiceInstalled() {
							mSvcUninstall.Disable()
							mSvcInstall.Enable()
						}
					}()
				}
			}
		}()
	}
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
