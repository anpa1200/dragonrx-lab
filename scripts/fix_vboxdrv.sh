#!/usr/bin/env bash
# Fix VBoxDRV kernel module for kernel $(uname -r)
# Run once as: sudo bash scripts/fix_vboxdrv.sh

set -euo pipefail
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[*]${NC} $*"; }
warn()  { echo -e "${YEL}[!]${NC} $*"; }
error() { echo -e "${RED}[X]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"

KERNEL=$(uname -r)
info "Kernel: $KERNEL"

# 1. Kernel headers
info "Installing kernel headers..."
apt-get install -y linux-headers-"$KERNEL" 2>/dev/null || \
    apt-get install -y linux-headers-generic

# 2. virtualbox-dkms — builds vboxdrv/vboxnetflt/vboxnetadp against current kernel
info "Installing virtualbox-dkms..."
apt-get install -y virtualbox-dkms

# 3. Rebuild DKMS modules explicitly if the install didn't trigger it
info "Rebuilding DKMS modules for $KERNEL..."
dkms autoinstall -k "$KERNEL" || true

# 4. Load the modules
info "Loading kernel modules..."
modprobe vboxdrv
modprobe vboxnetflt
modprobe vboxnetadp

# 5. Fix device permissions
if [ -e /dev/vboxdrv ]; then
    chmod 0660 /dev/vboxdrv
    chown root:vboxusers /dev/vboxdrv 2>/dev/null || true
fi

# 6. Add current user to vboxusers group (needs re-login to take effect)
SUDO_USER_NAME="${SUDO_USER:-$USER}"
if id "$SUDO_USER_NAME" &>/dev/null; then
    usermod -aG vboxusers "$SUDO_USER_NAME"
    warn "User '$SUDO_USER_NAME' added to vboxusers — log out and back in for group to take effect"
fi

# 7. Verify
info "Verifying..."
lsmod | grep -E "vbox" && echo "" || warn "vbox modules still not showing in lsmod"
VBoxManage --version && info "VBoxManage OK" || warn "VBoxManage error"

echo ""
info "VBoxDRV fix complete. Run 'make up' from dragonrx-lab/ to deploy the lab."
