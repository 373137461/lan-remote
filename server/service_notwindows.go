//go:build !windows

package main

import "net/http"

func isRunningAsService() bool     { return false }
func isServiceInstalled() bool     { return false }
func serviceStatus() string        { return "not_available" }
func isAdmin() bool                { return false }
func installService() error        { return nil }
func uninstallService() error      { return nil }
func elevateAndRun(_ string) error { return nil }
func runAsService()                {}
func registerServiceRoutes(_ *http.ServeMux) {}
