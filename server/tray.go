package main

import (
	"fmt"
	"strconv"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/widget"
)

var settingsWin fyne.Window

func runFyneApp() {
	a := app.NewWithID("com.lanremote.server")
	iconRes := fyne.NewStaticResource("app_icon.png", iconData)
	a.SetIcon(iconRes)

	desk, ok := a.(desktop.App)
	if ok {
		desk.SetSystemTrayIcon(iconRes)
		refreshTray(a, desk)
	}

	a.Run()
}

func refreshTray(a fyne.App, desk desktop.App) {
	cfg := getCfg()
	statusText := fmt.Sprintf("端口 %d", cfg.port)
	if cfg.password != "" {
		statusText += " · 已设密码"
	} else {
		statusText += " · 无密码"
	}

	autostartItem := &fyne.MenuItem{
		Label:   "开机自启动",
		Checked: isAutoStartEnabled(),
		Action: func() {
			enabled := !isAutoStartEnabled()
			if err := setAutoStart(enabled); err != nil {
				fmt.Printf("自启动设置失败: %v\n", err)
			}
			refreshTray(a, desk)
		},
	}

	menu := fyne.NewMenu("局域网键鼠遥控器",
		&fyne.MenuItem{Label: statusText, Disabled: true},
		fyne.NewMenuItemSeparator(),
		fyne.NewMenuItem("设置...", func() { showSettingsWindow(a, desk) }),
		fyne.NewMenuItemSeparator(),
		autostartItem,
		fyne.NewMenuItemSeparator(),
		fyne.NewMenuItem("退出", func() { a.Quit() }),
	)
	desk.SetSystemTrayMenu(menu)
}

func showSettingsWindow(a fyne.App, desk desktop.App) {
	if settingsWin != nil {
		settingsWin.RequestFocus()
		return
	}

	cfg := getCfg()

	w := a.NewWindow("局域网键鼠遥控器 · 设置")
	w.Resize(fyne.NewSize(360, 260))
	w.SetFixedSize(true)
	settingsWin = w
	w.SetOnClosed(func() { settingsWin = nil })

	passwordEntry := widget.NewPasswordEntry()
	passwordEntry.SetText(cfg.password)
	passwordEntry.SetPlaceHolder("留空则无需密码")

	portEntry := widget.NewEntry()
	portEntry.SetText(strconv.Itoa(cfg.port))

	timeoutEntry := widget.NewEntry()
	timeoutEntry.SetText(strconv.FormatInt(cfg.timeout, 10))

	statusLabel := widget.NewLabel("")
	statusLabel.Wrapping = fyne.TextWrapWord

	form := widget.NewForm(
		widget.NewFormItem("密码", passwordEntry),
		widget.NewFormItem("UDP 端口", portEntry),
		widget.NewFormItem("超时 (ms)", timeoutEntry),
	)

	saveBtn := widget.NewButton("保存", func() {
		newCfg := getCfg()
		newCfg.password = passwordEntry.Text

		port, err := strconv.Atoi(portEntry.Text)
		if err != nil || port < 1 || port > 65535 {
			statusLabel.SetText("端口无效，请输入 1–65535 之间的数字")
			return
		}

		timeout, err := strconv.ParseInt(timeoutEntry.Text, 10, 64)
		if err != nil || timeout <= 0 {
			statusLabel.SetText("超时值无效，请输入大于 0 的整数（单位 ms）")
			return
		}

		portChanged := port != newCfg.port
		newCfg.port = port
		newCfg.timeout = timeout

		if err := saveConfig(gConfPath, newCfg); err != nil {
			statusLabel.SetText("保存失败: " + err.Error())
			return
		}
		updateCfg(newCfg)
		refreshTray(a, desk)

		if portChanged {
			statusLabel.SetText("✓ 已保存。端口更改将在重启后生效。")
		} else {
			statusLabel.SetText("✓ 已保存并生效。")
		}
	})
	saveBtn.Importance = widget.HighImportance

	cancelBtn := widget.NewButton("取消", func() { w.Close() })

	content := container.NewVBox(
		form,
		statusLabel,
		container.NewGridWithColumns(2, saveBtn, cancelBtn),
	)

	w.SetContent(container.NewPadded(content))
	w.Show()
	w.RequestFocus()
}
