#!/usr/bin/env bash
# Disable Windows Defender on WS01 by editing its VMDK registry offline.
#
# Why offline: Windows 10 22H2 Tamper Protection blocks ALL in-OS disable methods —
# Set-MpPreference, registry writes via WinRM, and even safe-mode WinRM (NTLM stack
# not loaded in safe mode). Editing the hive while the VM is powered off bypasses it.
#
# Called by: make up (step 3, after vagrant up, before Ansible)
# Idempotent: safe to re-run; writes are no-ops if keys already set.

set -euo pipefail
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[*]${NC} $*"; }
warn()  { echo -e "${YEL}[!]${NC} $*"; }
error() { echo -e "${RED}[!]${NC} $*" >&2; exit 1; }

VM_NAME="dragonrx_ws01"
MOUNT=/mnt/ws01_offline

# ── Locate the VMDK ──────────────────────────────────────────────────────────
VMDK=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null \
       | grep '"IDE Controller-0-0"' | cut -d'"' -f4)
[[ -z "$VMDK" ]] && error "VMDK not found for $VM_NAME — has 'vagrant up' created the VM yet?"
info "WS01 VMDK: $VMDK"

# ── Ensure VM is powered off ─────────────────────────────────────────────────
STATE=$(VBoxManage showvminfo "$VM_NAME" --machinereadable | grep '^VMState=' | cut -d'"' -f2)
if [[ "$STATE" != "poweroff" && "$STATE" != "aborted" && "$STATE" != "saved" ]]; then
    info "Powering off $VM_NAME (state: $STATE)..."
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    sleep 3
fi

# ── Connect VMDK via qemu-nbd ─────────────────────────────────────────────────
info "Connecting VMDK via qemu-nbd..."
modprobe nbd max_part=8 2>/dev/null || true
qemu-nbd --connect=/dev/nbd0 "$VMDK"
sleep 2

cleanup() {
    umount "$MOUNT" 2>/dev/null || true
    qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    rm -rf "$MOUNT"
}
trap cleanup EXIT

# ── Mount NTFS partition ──────────────────────────────────────────────────────
mkdir -p "$MOUNT"
ntfsfix -d /dev/nbd0p1 >/dev/null 2>&1 || true
mount -t ntfs-3g /dev/nbd0p1 "$MOUNT" -o rw 2>/dev/null || \
    mount -t ntfs-3g /dev/nbd0p1 "$MOUNT" -o ro && \
    error "Cannot mount NTFS read-write — VM may not have shut down cleanly"
info "NTFS partition mounted at $MOUNT"

# ── Edit SOFTWARE hive ────────────────────────────────────────────────────────
SOFTWARE="$MOUNT/Windows/System32/config/SOFTWARE"
[[ -f "$SOFTWARE" ]] || error "SOFTWARE hive not found at $SOFTWARE"

REG_FILE=$(mktemp /tmp/defender_disable_XXXXXX.reg)
cat > "$REG_FILE" << 'REGEOF'
Windows Registry Editor Version 5.00

[\Microsoft\Windows Defender]
"DisableAntiVirus"=dword:00000001
"DisableAntiSpyware"=dword:00000001

[\Microsoft\Windows Defender\Features]
"TamperProtection"=dword:00000000

[\Microsoft\Windows Defender\Real-Time Protection]
"DisableRealtimeMonitoring"=dword:00000001
"DisableIOAVProtection"=dword:00000001
"DisableBehaviorMonitoring"=dword:00000001

[\Policies\Microsoft\Windows Defender]
"DisableAntiSpyware"=dword:00000001

[\Policies\Microsoft\Windows Defender\Real-Time Protection]
"DisableRealtimeMonitoring"=dword:00000001
REGEOF

hivexregedit --merge "$SOFTWARE" "$REG_FILE"
rm -f "$REG_FILE"
info "Windows Defender disabled in SOFTWARE hive"

# ── Verify ────────────────────────────────────────────────────────────────────
RESULT=$(hivexregedit --export "$SOFTWARE" '\' 2>/dev/null \
         | grep '"DisableAntiVirus"' | head -1)
[[ "$RESULT" == *"00000001"* ]] && info "Verified: DisableAntiVirus=1 in hive" \
    || warn "Verification uncertain — check manually after boot"

info "Offline Defender disable complete."
