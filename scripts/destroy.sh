#!/usr/bin/env bash
# destroy.sh — Tear down the DragonRx lab (VMs + Docker).
# Equivalent to 'make reset' but with richer output.
#
# Usage: bash scripts/destroy.sh [--keep-volumes] [--docker-only]
#
# Options:
#   --keep-volumes  Stop containers without removing volumes (preserves Wazuh/Zeek data)
#   --docker-only   Skip Vagrant teardown (useful when VMs were never started)

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

KEEP_VOLUMES=0; DOCKER_ONLY=0
for arg in "$@"; do
  case $arg in
    --keep-volumes) KEEP_VOLUMES=1 ;;
    --docker-only)  DOCKER_ONLY=1 ;;
    -h|--help)
      sed -n '2,/^[^#]/{ /^#/p }' "$0" | sed 's/^# \?//' | head -10
      exit 0 ;;
    *) error "Unknown option: $arg" ;;
  esac
done

START_SECONDS=$SECONDS

# ── banner ────────────────────────────────────────────────────────────────────
echo -e "
${RED}${BOLD}╔═══════════════════════════════════════════════════════╗
║    Operation DragonRx — APT41 Attack Simulation Lab   ║
║                  Lab Teardown Script v1.0             ║
╚═══════════════════════════════════════════════════════╝${NC}
Lab directory: ${LAB_DIR}
"

# ── Step 1: Vagrant VMs ───────────────────────────────────────────────────────
if [[ $DOCKER_ONLY -eq 0 ]]; then
  step "Step 1: Destroying Vagrant VMs"
  if command -v vagrant &>/dev/null; then
    VM_STATUS=$(vagrant status 2>/dev/null || true)
    if echo "$VM_STATUS" | grep -qE "running|saved|poweroff"; then
      info "Destroying VMs (DC01, FS01, WS01)..."
      vagrant destroy -f
      info "VMs destroyed"
    else
      info "No active VMs found — skipping"
    fi
  else
    warn "vagrant not found — skipping VM teardown"
  fi
else
  step "Step 1: Skipped (--docker-only)"
fi

# ── Step 2: Docker services ───────────────────────────────────────────────────
step "Step 2: Stopping Docker services"

if [[ $KEEP_VOLUMES -eq 0 ]]; then
  info "Removing containers and volumes (Wazuh indices, Zeek logs)..."
  docker compose down -v
  info "All volumes removed"
else
  warn "--keep-volumes set: data volumes preserved"
  docker compose down
  info "Containers stopped; volumes intact"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
ELAPSED=$(( SECONDS - START_SECONDS ))
echo -e "
${GRN}${BOLD}╔═══════════════════════════════════════════════════════╗
║                   Lab Destroyed ✓                     ║
╚═══════════════════════════════════════════════════════╝${NC}

  Total time : $((ELAPSED / 60))m$((ELAPSED % 60))s

  ${BOLD}To redeploy:${NC}
  Docker only : ${CYN}docker compose up -d${NC}
  Full lab    : ${CYN}bash scripts/deploy.sh${NC}  or  ${CYN}make up${NC}
"
