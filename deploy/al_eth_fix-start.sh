#!/bin/sh
# Run as root at boot (DSM Task Scheduler, triggered task, Boot-up): move one port from
# the built-in al_eth to al_eth_fix.ko, keeping its IPv4 addresses and routes.
# Usage: al_eth_fix-start.sh <interface> [path to al_eth_fix.ko] [module options]
set -u
IF=${1:?usage: al_eth_fix-start.sh <interface> [ko] [options]}
KO=${2:-/volume1/al_eth_fix/al_eth_fix.ko}
if [ $# -ge 2 ]; then shift 2; else shift $#; fi
LOG=/var/log/al_eth_fix.log
exec >> "$LOG" 2>&1
echo "== $(date '+%F %T') $IF"

grep -q '^al_eth_fix ' /proc/modules && { echo "al_eth_fix already loaded"; exit 0; }
pci=$(basename "$(readlink "/sys/class/net/$IF/device")")
[ -n "$pci" ] || { echo "no PCI device for $IF"; exit 1; }

# DSM may still be configuring the port at boot; wait for it to be up with an address.
i=0
while [ "$i" -lt 120 ] && ! ip -4 -o addr show dev "$IF" | grep -q inet; do
	sleep 2
	i=$((i + 2))
done
addrs=$(ip -4 -o addr show dev "$IF" | awk '{print $4}')
routes=$(ip -4 route show dev "$IF" | grep -v ' scope link')
echo "pci $pci addrs: $addrs routes: $routes"

insmod "$KO" take="$pci" "$@" || { echo "insmod failed, port left on al_eth"; exit 1; }
sleep 2
new=
for n in "/sys/bus/pci/devices/$pci/net/"*; do
	[ -e "$n" ] && new=$(basename "$n")
	break
done
[ -n "$new" ] || { echo "al_eth_fix did not create a netdev"; exit 1; }
ip link set "$new" up
i=0
while [ "$i" -lt 30 ] && [ "$(cat "/sys/class/net/$new/carrier" 2>/dev/null)" != 1 ]; do
	sleep 1
	i=$((i + 1))
done
# Tolerated: an address or route DSM already restored on the new netdev.
# Consequence: none, it is already there; a real failure shows in the final line.
for a in $addrs; do
	ip addr add "$a" dev "$new" 2>/dev/null || true
done
echo "$routes" | while read -r r; do
	[ -n "$r" ] || continue
	# shellcheck disable=SC2086 # the route spec is several words
	ip route add $r dev "$new" 2>/dev/null || true
done
echo "now on $new: driver $(basename "$(readlink "/sys/bus/pci/devices/$pci/driver")"), carrier $(cat "/sys/class/net/$new/carrier"), $(ip -4 -o addr show dev "$new" | awk '{print $4}' | tr '\n' ' ')"
