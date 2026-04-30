#!/usr/bin/env bash
# Bridge Docker target_net and VirtualBox vboxnet0 so containers and VMs
# can communicate on the same 192.168.10.0/24 subnet.
# Run once: after 'docker compose up -d', before 'vagrant up'.

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GRN}[*]${NC} $*"; }
error() { echo -e "${RED}[!]${NC} $*" >&2; exit 1; }

info "Enabling IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-dragonrx.conf >/dev/null

info "Locating Docker target_net bridge..."
DOCKER_NET_ID=$(docker network ls --filter name=dragonrx --format "{{.ID}}" | head -1)
[[ -z "$DOCKER_NET_ID" ]] && error "Docker network not found — run 'docker compose up -d' first"
DOCKER_BRIDGE="br-${DOCKER_NET_ID:0:12}"
info "Docker bridge: $DOCKER_BRIDGE"

info "Ensuring vboxnet0 exists at 192.168.10.1..."
if ! ip link show vboxnet0 &>/dev/null; then
    VBoxManage hostonlyif create
    VBoxManage hostonlyif ipconfig vboxnet0 --ip 192.168.10.1 --netmask 255.255.255.0
fi

info "Adding iptables FORWARD rules..."
sudo iptables -I FORWARD -i "$DOCKER_BRIDGE" -o vboxnet0       -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD -i vboxnet0       -o "$DOCKER_BRIDGE" -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -I POSTROUTING -s 192.168.10.0/24 -j MASQUERADE 2>/dev/null || true

info "Setting promiscuous mode on $DOCKER_BRIDGE..."
sudo ip link set "$DOCKER_BRIDGE" promisc on

echo ""
info "Routing configured."
echo "    Docker target_net ($DOCKER_BRIDGE) ↔ VirtualBox vboxnet0: bridged"
echo "    Containers and VMs share 192.168.10.0/24 transparently."
