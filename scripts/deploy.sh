#!/usr/bin/env bash
# deploy.sh — Full DragonRx lab deployment in a single script.
# Equivalent to 'make up' but self-contained, with richer output and timing.
#
# Usage: bash scripts/deploy.sh [--destroy] [--skip-vms] [--skip-ansible] [--no-test]
#
# Options:
#   --destroy       Tear down all existing state before deploying (vagrant destroy + docker down -v)
#   --skip-vms      Skip vagrant up (reuse already-running Windows VMs)
#   --skip-ansible  Skip Ansible provisioning (reuse already-provisioned VMs)
#   --no-test       Skip final validation suite
#
# Requirements (checked automatically):
#   docker, docker compose, vagrant, ansible, VBoxManage, pywinrm,
#   vagrant plugins: vagrant-reload, vagrant-hostmanager

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$LAB_DIR"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[1;34m'; CYN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${GRN}[*]${NC} $*"; }
step()  { echo -e "\n${BLU}${BOLD}══ $* ══${NC}"; }
warn()  { echo -e "${YEL}[!]${NC} $*"; }
error() { echo -e "${RED}[X]${NC} $*" >&2; exit 1; }
timer() { echo -e "${CYN}[t]${NC} elapsed: $(( SECONDS / 60 ))m$(( SECONDS % 60 ))s"; }

DESTROY=0; SKIP_VMS=0; SKIP_ANSIBLE=0; RUN_TEST=1
for arg in "$@"; do
  case $arg in
    --destroy)      DESTROY=1 ;;
    --skip-vms)     SKIP_VMS=1 ;;
    --skip-ansible) SKIP_ANSIBLE=1 ;;
    --no-test)      RUN_TEST=0 ;;
    -h|--help)
      sed -n '2,/^[^#]/{ /^#/p }' "$0" | sed 's/^# \?//' | head -20
      exit 0 ;;
  esac
done

START_SECONDS=$SECONDS

# ── banner ────────────────────────────────────────────────────────────────────
echo -e "
${BLU}${BOLD}╔═══════════════════════════════════════════════════════╗
║    Operation DragonRx — APT41 Attack Simulation Lab   ║
║              Full Deployment Script v1.0              ║
╚═══════════════════════════════════════════════════════╝${NC}
Lab directory: ${LAB_DIR}
"

# ── Teardown (--destroy) ──────────────────────────────────────────────────────
if [[ $DESTROY -eq 1 ]]; then
  step "Teardown: destroying existing lab state"
  if vagrant status 2>/dev/null | grep -qE "running|saved|poweroff"; then
    info "Destroying Vagrant VMs..."
    vagrant destroy -f
  else
    info "No running VMs to destroy"
  fi
  info "Stopping Docker services and removing volumes..."
  docker compose down -v
  info "Teardown complete"
fi

# ── Step 0: Prerequisites ─────────────────────────────────────────────────────
step "Step 0: Checking prerequisites"

check_cmd() { command -v "$1" &>/dev/null || error "Missing: $1  (install it first)"; }
check_cmd docker
check_cmd vagrant
check_cmd ansible
check_cmd VBoxManage
info "Core binaries present"

# docker compose v2
docker compose version &>/dev/null || error "docker compose v2 not found (need Docker >= 24)"

# pywinrm
python3 -c "import winrm" 2>/dev/null || \
  error "pywinrm not installed — run: pip3 install pywinrm"

# Vagrant plugins — capture first to avoid grep-q SIGPIPE under pipefail
PLUGIN_LIST=$(vagrant plugin list 2>/dev/null || true)
for plugin in vagrant-reload vagrant-hostmanager; do
  echo "$PLUGIN_LIST" | grep -q "$plugin" || \
    error "Vagrant plugin missing: $plugin — run: vagrant plugin install $plugin"
done
info "All prerequisites satisfied"

# ── Step 1: VBoxDRV ───────────────────────────────────────────────────────────
step "Step 1: VirtualBox kernel modules"

# Read /proc/modules directly — no pipe, no SIGPIPE under pipefail
if ! grep -qw 'vboxdrv' /proc/modules; then
  warn "vboxdrv not loaded — attempting to fix..."
  if [[ -x "$SCRIPT_DIR/fix_vboxdrv.sh" ]]; then
    sudo bash "$SCRIPT_DIR/fix_vboxdrv.sh" || error "Could not load vboxdrv"
  else
    sudo modprobe vboxdrv && sudo modprobe vboxnetflt && sudo modprobe vboxnetadp || \
      error "modprobe failed — run: sudo bash scripts/fix_vboxdrv.sh"
  fi
fi
grep -E 'vboxdrv|vboxnetflt|vboxnetadp' /proc/modules | awk '{print $1, "loaded"}'
info "VirtualBox modules loaded"

# ── Step 2: Vagrant boxes ─────────────────────────────────────────────────────
step "Step 2: Vagrant box availability"

BOX_LIST=$(vagrant box list 2>/dev/null || true)
BOXES_NEEDED=("StefanScherer/windows_2019" "StefanScherer/windows_10")
for box in "${BOXES_NEEDED[@]}"; do
  if ! echo "$BOX_LIST" | grep -q "${box##*/}"; then
    info "Downloading Vagrant box: $box (~8 GB)..."
    vagrant box add "$box" --provider virtualbox
  else
    info "Box already cached: $box"
  fi
done

# ── Step 3: Build attack containers ──────────────────────────────────────────
step "Step 3: Building attack containers (rxphage implant + Kali toolset)"

info "Building rxphage implant (Linux ELF, Windows PE, DLL sideload, ransomware demo)..."
docker compose build rxphage_builder

info "Building Kali container (impacket, john, crackmapexec, hashcat, pypykatz, sliver-client)..."
docker compose build kali

info "Attack containers built"

# ── Step 4: Docker services ───────────────────────────────────────────────────
step "Step 4: Starting Docker services"

docker compose up -d
info "Waiting for Wazuh analysisd to initialise (may take ~30 s)..."
until docker exec dragonrx_wazuh pgrep wazuh-analysisd >/dev/null 2>&1; do sleep 5; done
docker cp siem/wazuh/rules/dragonrx_rules.xml dragonrx_wazuh:/var/ossec/etc/rules/ 2>/dev/null || true
docker exec dragonrx_wazuh /var/ossec/bin/wazuh-control restart >/dev/null 2>&1 || true
info "Custom Wazuh detection rules installed."
docker compose ps
timer

# ── Step 4b: Kali tool staging ────────────────────────────────────────────────
info "Verifying Kali attack tools..."
MISSING=()
for tool in impacket-secretsdump impacket-GetUserSPNs impacket-smbclient \
            impacket-smbexec crackmapexec john hashcat pypykatz; do
  if ! docker exec dragonrx_kali which "$tool" &>/dev/null && \
     ! docker exec dragonrx_kali python3 -c "import $(echo $tool | tr '-' '_')" &>/dev/null 2>&1; then
    MISSING+=("$tool")
  fi
done
[[ ${#MISSING[@]} -gt 0 ]] && warn "Tools not found in Kali: ${MISSING[*]}" || info "All attack tools verified"

info "Starting HTTP staging server in Kali (port 8900 → /opt/tools)..."
docker exec -d dragonrx_kali bash -c \
  "pkill -f 'http.server 8900' 2>/dev/null; python3 -m http.server 8900 --directory /opt/tools/" || true
info "Staging server ready: http://192.168.10.5:8900/"
info "  Available: $(docker exec dragonrx_kali ls /opt/tools/ 2>/dev/null | tr '\n' ' ')"

# ── Step 5: Windows VMs ───────────────────────────────────────────────────────
if [[ $SKIP_VMS -eq 0 ]]; then
  step "Step 5: Starting Windows VMs (DC01, FS01, WS01)"
  info "This takes 5-10 minutes while VMs first-boot..."
  vagrant up --provider virtualbox
  timer
else
  step "Step 5: Skipped (--skip-vms)"
fi

# ── Step 6: Disable Windows Defender on WS01 (offline VMDK edit) ─────────────
step "Step 6: Disabling Windows Defender on WS01 (offline VMDK edit)"
info "Tamper Protection blocks all in-OS methods — editing hive while VM is powered off..."
# Needs root for modprobe/qemu-nbd/mount; VBoxManage runs as $SUDO_USER inside the script.
if [[ $EUID -ne 0 ]]; then
  sudo -v
  sudo bash "$SCRIPT_DIR/disable_defender_offline.sh"
else
  bash "$SCRIPT_DIR/disable_defender_offline.sh"
fi
info "Restarting WS01 with Defender disabled..."
vagrant up WS01 --provider virtualbox
timer

# ── Step 7: Host networking ───────────────────────────────────────────────────
step "Step 7: Configuring host routing (Docker ↔ VirtualBox bridge)"

bash "$SCRIPT_DIR/setup_routing.sh"

# ── Step 8: Ansible provisioning ─────────────────────────────────────────────
if [[ $SKIP_ANSIBLE -eq 0 ]]; then
  step "Step 8: Ansible provisioning"
  info "Phase 8a: Installing Galaxy collections..."
  cd ansible
  ansible-galaxy collection install -r requirements.yml

  info "Phase 8b: Running deploy playbook..."
  ansible-playbook playbooks/deploy.yml -v
  cd "$LAB_DIR"
  timer
else
  step "Step 8: Skipped (--skip-ansible)"
fi

# ── Step 9: Validation ────────────────────────────────────────────────────────
if [[ $RUN_TEST -eq 1 ]]; then
  step "Step 9: Running validation suite"
  cd ansible
  ansible-playbook playbooks/test.yml -v
  cd "$LAB_DIR"
  timer
else
  step "Step 9: Skipped (--no-test)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
ELAPSED=$(( SECONDS - START_SECONDS ))
echo -e "
${GRN}${BOLD}╔═══════════════════════════════════════════════════════╗
║                   Lab Deployed ✓                      ║
╚═══════════════════════════════════════════════════════╝${NC}

  Total time : $((ELAPSED / 60))m$((ELAPSED % 60))s

  ${BOLD}Access points:${NC}
  Kibana SIEM    : ${CYN}http://localhost:5601${NC}
  Kali shell     : ${CYN}docker exec -it dragonrx_kali /bin/bash${NC}
  Sliver C2      : ${CYN}docker exec -it dragonrx_c2 sliver${NC}
  Tool staging   : ${CYN}http://192.168.10.5:8900/${NC}  (served from Kali /opt/tools)

  ${BOLD}Target network:${NC}
  WEB01  192.168.10.100  Tomcat + Log4j 2.14.1  :8080
  DC01   192.168.10.10   Windows Server 2019 AD
  FS01   192.168.10.20   Research + Manufacturing shares
  WS01   192.168.10.50   Windows 10 (jsmith)

  ${BOLD}Teardown:${NC}
  Stop:  ${CYN}make down${NC}
  Reset: ${CYN}make reset${NC}  (destroys all state)
"
