#!/usr/bin/env bash
# Enable IP forwarding and iptables rules so the attacker network
# (10.0.0.0/24) can reach the target network (192.168.10.0/24).
#
# VMs bridge directly onto the Docker target_net bridge (see Vagrantfile),
# so no host-only adapter or vboxnet0 configuration is needed here.
#
# Run once: after 'docker compose up -d', before 'vagrant up'.

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GRN}[*]${NC} $*"; }
error() { echo -e "${RED}[!]${NC} $*" >&2; exit 1; }

# ── VirtualBox network policy (6.1.28+) ──────────────────────────────────────
# Allow 192.168.10.0/24 so VBox doesn't reject bridge/host-only config calls.
if ! grep -qsE '^\*|192\.168\.10' /etc/vbox/networks.conf 2>/dev/null; then
    info "Whitelisting 192.168.10.0/24 in VirtualBox network policy..."
    sudo mkdir -p /etc/vbox
    echo "* 192.168.10.0/24 ::/0" | sudo tee /etc/vbox/networks.conf >/dev/null
fi

# ── IP forwarding ─────────────────────────────────────────────────────────────
info "Enabling IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-dragonrx.conf >/dev/null

# ── Locate Docker bridges ─────────────────────────────────────────────────────
info "Locating Docker network bridges..."

ATK_NET_ID=$(docker network ls --filter name=attacker_net --format "{{.ID}}" | head -1)
[[ -z "$ATK_NET_ID" ]] && error "attacker_net bridge not found — run 'docker compose up -d' first"
ATK_BRIDGE="br-${ATK_NET_ID:0:12}"

TGT_NET_ID=$(docker network ls --filter name=target_net --format "{{.ID}}" | head -1)
[[ -z "$TGT_NET_ID" ]] && error "target_net bridge not found — run 'docker compose up -d' first"
TGT_BRIDGE="br-${TGT_NET_ID:0:12}"

info "Attacker bridge : $ATK_BRIDGE  (10.0.0.0/24)"
info "Target bridge   : $TGT_BRIDGE  (192.168.10.0/24)"

# ── iptables forwarding between the two bridges ───────────────────────────────
info "Adding iptables FORWARD rules (attacker ↔ target)..."
sudo iptables -I FORWARD -i "$ATK_BRIDGE" -o "$TGT_BRIDGE" -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD -i "$TGT_BRIDGE" -o "$ATK_BRIDGE" -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 10.0.0.0/24     -d 192.168.10.0/24 -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.10.0/24 -d 10.0.0.0/24     -j MASQUERADE 2>/dev/null || true

info "Setting promiscuous mode on bridges..."
sudo ip link set "$ATK_BRIDGE" promisc on
sudo ip link set "$TGT_BRIDGE" promisc on

# ── TCP checksum offloading fix (Docker ↔ VirtualBox bridged VMs) ────────────
#
# Root cause: virtual NICs on both sides defer TCP checksum computation to
# "hardware" that doesn't exist in a virtual bridge stack.
#
#   Docker containers (Linux veth): the kernel marks outgoing TCP packets with
#   a partial pseudo-header checksum and expects the NIC to fill in the rest.
#   Through a virtual bridge no hardware ever completes it — Windows receives
#   the SYN with checksum 0x0000 and silently drops it (no RST).
#
#   VirtualBox Windows NICs: same problem in reverse — DC01/FS01/WS01 defer
#   their TX checksums to the virtual 82540EM; Linux receives SYN-ACKs with
#   invalid checksums and drops them silently.
#
#   ICMP ping works because the kernel always computes ICMP checksums in
#   software (raw socket path), never deferring to hardware.
#
# Fix: force software checksum computation on every interface in the path.
#   - bridge interface tx off        (locally-originated bridge traffic)
#   - host-side veths tx off         (forwarded traffic from containers)
#   - container-side eth1 tx off     (source of TCP segments — most critical)
#   - Windows NIC offloading disabled via Ansible provisioning (see roles/)
#
info "Disabling TX checksum offloading (Docker ↔ Windows VM TCP fix)..."
sudo ethtool -K "$TGT_BRIDGE" tx off 2>/dev/null || true

for veth in $(bridge link show "$TGT_BRIDGE" 2>/dev/null | grep -oP 'dev \K\S+'); do
    sudo ethtool -K "$veth" tx off 2>/dev/null || true
done

# Use nsenter so we don't rely on ethtool being installed inside each container
for ctr in dragonrx_web01 dragonrx_kali; do
    pid=$(docker inspect -f '{{.State.Pid}}' "$ctr" 2>/dev/null)
    [[ -n "$pid" && "$pid" != "0" ]] && \
        sudo nsenter -t "$pid" -n ethtool -K eth1 tx off 2>/dev/null || true
done

# ── Remove stale vboxnet0 route (conflicts with Docker bridge route) ──────────
# vboxnet0 may persist after prior host-only deployments; its kernel route for
# 192.168.10.0/24 shadows the Docker bridge route, breaking host→container reach.
if ip route show dev vboxnet0 2>/dev/null | grep -q '192.168.10'; then
    info "Removing stale vboxnet0 route for 192.168.10.0/24..."
    sudo ip route del 192.168.10.0/24 dev vboxnet0 2>/dev/null || true
fi

echo ""
info "Routing configured."
echo "    Attacker ($ATK_BRIDGE 10.0.0.0/24) ↔ Target ($TGT_BRIDGE 192.168.10.0/24)"
echo "    Windows VMs bridge directly onto $TGT_BRIDGE via Vagrantfile."
