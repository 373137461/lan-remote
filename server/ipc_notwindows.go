//go:build !windows

package main

import "errors"

func writeWebPort(_ int)        {}
func readWebPort() (int, error) { return 0, errors.New("not supported") }
func removeWebPortFile()        {}
