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

# VirtualBox VMs are registered per-user. When called via 'sudo', run VBoxManage
# as the real user ($SUDO_USER) so it can see the VM registry.
REAL_USER=${SUDO_USER:-$USER}
vboxmanage() { sudo -u "$REAL_USER" VBoxManage "$@"; }

# ── Locate the VMDK ──────────────────────────────────────────────────────────
VMDK=$(vboxmanage showvminfo "$VM_NAME" --machinereadable 2>/dev/null \
       | grep '"SATA Controller-0-0"\|"IDE Controller-0-0"\|"NVMe Controller-0-0"' \
       | head -1 | cut -d'"' -f4 || true)
[[ -z "$VMDK" ]] && error "VMDK not found for $VM_NAME (looked as user $REAL_USER) — has 'vagrant up' created the VM yet?"
info "WS01 VMDK: $VMDK"

# ── Ensure VM is powered off ─────────────────────────────────────────────────
STATE=$(vboxmanage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | grep '^VMState=' | cut -d'"' -f2 || true)
if [[ "$STATE" != "poweroff" && "$STATE" != "aborted" && "$STATE" != "saved" ]]; then
    info "Powering off $VM_NAME (state: $STATE)..."
    vboxmanage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    info "Waiting for VirtualBox to release VMDK lock..."
    sleep 8
fi

# ── Connect VMDK via qemu-nbd ─────────────────────────────────────────────────
info "Connecting VMDK via qemu-nbd..."
modprobe nbd max_part=16 2>/dev/null || true
# Disconnect any stale nbd0 connection first
qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
sleep 1
qemu-nbd --connect=/dev/nbd0 "$VMDK"
sleep 2

# Wait for partition devices to appear
for i in $(seq 1 10); do
    ls /dev/nbd0p* >/dev/null 2>&1 && break
    sleep 1
done
info "Partitions found: $(ls /dev/nbd0p* 2>/dev/null | tr '\n' ' ')"

cleanup() {
    umount "$MOUNT" 2>/dev/null || true
    qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    rm -rf "$MOUNT"
}
trap cleanup EXIT

# ── Find and mount the Windows C: partition ───────────────────────────────────
# Windows 10 disk layout (MBR or GPT) puts C: on partition 2, 3, or 4.
# Detect by looking for the partition that contains Windows/System32.
mkdir -p "$MOUNT"
WINDOWS_PART=""
for PART in /dev/nbd0p2 /dev/nbd0p3 /dev/nbd0p4 /dev/nbd0p1; do
    [[ -b "$PART" ]] || continue
    ntfsfix -d "$PART" >/dev/null 2>&1 || true
    if mount -t ntfs-3g "$PART" "$MOUNT" -o rw,nofail 2>/dev/null; then
        if [[ -d "$MOUNT/Windows/System32" ]]; then
            WINDOWS_PART="$PART"
            info "C: drive found on $PART, mounted read-write at $MOUNT"
            break
        fi
        umount "$MOUNT" 2>/dev/null || true
    fi
done
[[ -z "$WINDOWS_PART" ]] && error "Could not find Windows C: partition on any nbd0pN — check VMDK connection with: lsblk /dev/nbd0"

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
if [[ "$RESULT" == *"00000001"* ]]; then
    info "Verified: DisableAntiVirus=1 in hive"
else
    warn "Verification uncertain — check manually after boot"
fi

info "Offline Defender disable complete. WS01 is powered off — 'vagrant up WS01' will start it."
