//go:build !windows

package main

import (
	"fmt"
	"net/http"
)

func isRunningAsService() bool     { return false }
func isServiceInstalled() bool     { return false }
func serviceStatus() string        { return "not_available" }
func isAdmin() bool                { return false }
func installService() error        { return nil }
func uninstallService() error      { return nil }
func startService() error          { return nil }
func stopService() error           { return nil }
func elevateAndRun(_ string) error     { return nil }
func runAsService()                    {}
func showError(msg string)             { fmt.Println(msg) }
func acquireSingleInstanceMutex() bool { return true }
func registerServiceRoutes(_ *http.ServeMux) {}
