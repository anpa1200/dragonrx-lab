#!/bin/sh
set -e

# Parse /proc/net/route (no iproute2 required) to find the lab bridge interface.
# Destinations are stored as little-endian hex:
#   192.168.10.0/24  = 000AA8C0  (target network — priority: probe + Windows VMs)
#   10.0.0.0/24      = 0000000A  (attacker network — fallback)

IFACE=$(awk '$2 == "000AA8C0" {print $1; exit}' /proc/net/route)
[ -z "$IFACE" ] && IFACE=$(awk '$2 == "0000000A" {print $1; exit}' /proc/net/route)
[ -z "$IFACE" ] && IFACE="any"

echo "[zeek] Capturing on: $IFACE"
exec zeek -C -i "$IFACE" /usr/local/zeek/share/zeek/site/local.zeek
