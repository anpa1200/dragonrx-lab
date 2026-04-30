#!/usr/bin/env bash
# deploy.sh — Full DragonRx lab deployment in a single script.
# Equivalent to 'make up' but self-contained, with richer output and timing.
#
# Usage: bash scripts/deploy.sh [--skip-vms] [--skip-ansible] [--no-test]
#
# Options:
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

SKIP_VMS=0; SKIP_ANSIBLE=0; RUN_TEST=1
for arg in "$@"; do
  case $arg in
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

# ── Step 3: Docker services ───────────────────────────────────────────────────
step "Step 3: Starting Docker services"

docker compose up -d
info "Waiting for Wazuh analysisd to initialise (may take ~30 s)..."
until docker exec dragonrx_wazuh pgrep wazuh-analysisd >/dev/null 2>&1; do sleep 5; done
docker cp siem/wazuh/rules/dragonrx_rules.xml dragonrx_wazuh:/var/ossec/etc/rules/ 2>/dev/null || true
docker exec dragonrx_wazuh /var/ossec/bin/wazuh-control restart >/dev/null 2>&1 || true
info "Custom Wazuh detection rules installed."
docker compose ps
timer

# ── Step 4: Host networking ───────────────────────────────────────────────────
step "Step 4: Configuring host routing (Docker ↔ VirtualBox bridge)"

bash "$SCRIPT_DIR/setup_routing.sh"

# ── Step 5: Windows VMs ───────────────────────────────────────────────────────
if [[ $SKIP_VMS -eq 0 ]]; then
  step "Step 5: Starting Windows VMs (DC01, FS01, WS01)"
  info "This takes 5-10 minutes while VMs first-boot..."
  vagrant up --provider virtualbox
  timer
else
  step "Step 5: Skipped (--skip-vms)"
fi

# ── Step 6: Ansible provisioning ─────────────────────────────────────────────
if [[ $SKIP_ANSIBLE -eq 0 ]]; then
  step "Step 6: Ansible provisioning"
  info "Phase 6a: Installing Galaxy collections..."
  cd ansible
  ansible-galaxy collection install -r requirements.yml -q

  info "Phase 6b: Running deploy playbook..."
  ansible-playbook playbooks/deploy.yml -v
  cd "$LAB_DIR"
  timer
else
  step "Step 6: Skipped (--skip-ansible)"
fi

# ── Step 7: Validation ────────────────────────────────────────────────────────
if [[ $RUN_TEST -eq 1 ]]; then
  step "Step 7: Running validation suite"
  cd ansible
  ansible-playbook playbooks/test.yml -v
  cd "$LAB_DIR"
  timer
else
  step "Step 7: Skipped (--no-test)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
ELAPSED=$(( SECONDS - START_SECONDS ))
echo -e "
${GRN}${BOLD}╔═══════════════════════════════════════════════════════╗
║                   Lab Deployed ✓                      ║
╚═══════════════════════════════════════════════════════╝${NC}

  Total time : $((ELAPSED / 60))m$((ELAPSED % 60))s

  ${BOLD}Access points:${NC}
  Kibana SIEM : ${CYN}http://localhost:5601${NC}
  Kali shell  : ${CYN}make shell${NC}   (docker exec -it dragonrx_kali /bin/bash)
  Sliver C2   : ${CYN}docker exec -it dragonrx_c2 sliver${NC}
  Attack run  : ${CYN}make attack${NC}

  ${BOLD}Target network:${NC}
  WEB01  192.168.10.100  Tomcat + Log4j 2.14.1  :8443
  DC01   192.168.10.10   Windows Server 2019 AD
  FS01   192.168.10.20   Research + Manufacturing shares
  WS01   192.168.10.50   Windows 10 (jsmith)

  ${BOLD}Teardown:${NC}
  Stop:  ${CYN}make down${NC}
  Reset: ${CYN}make reset${NC}  (destroys all state)
"
