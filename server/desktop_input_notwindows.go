//go:build !windows

package main

func winMouseMove(dx, dy int)             {}
func winMouseClick(btn string)            {}
func winMouseDblClick(btn string)         {}
func winMouseDown(btn string)             {}
func winMouseUp(btn string)               {}
func winMouseScroll(scrollY int)          {}
func winKeyTap(code byte)                 {}
func winKeyCombo(mod, key string)         {}
func winKeyCombo2(mod1, mod2, key string) {}
func winTypeStr(text string)              {}
func winSysActionWindows(_ byte) bool     { return false }
func winExecuteShortcutString(_ string)   {}
