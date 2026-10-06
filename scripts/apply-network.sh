#!/usr/bin/env bash
# Run as a detached systemd job: netplan can replace the DHCP address carrying SSH.
set -euo pipefail
address="${1:?IPv4 required}"
mac="${2:?MAC required}"
state="${3:?state directory required}"
[[ "$state" =~ ^/run/multipass-k8s-network/[a-f0-9]{32}$ ]] || exit 2
umask 022
mkdir -p "$state"
exec >"$state/apply.log" 2>&1
finish() {
    result=$?
    printf '%s\n' "$result" > "$state/exit-code.tmp"
    mv "$state/exit-code.tmp" "$state/exit-code"
}
trap finish EXIT
timeout 90s netplan apply
python3 - "$address" "$mac" <<'PY'
import json, subprocess, sys, time
address, mac = sys.argv[1:]
links = json.loads(subprocess.check_output(['ip', '-j', 'address']))
lan = next((link for link in links if link.get('address', '').lower() == mac.lower()), None)
if not lan or not any(a.get('local') == address and a.get('prefixlen') == 24 for a in lan['addr_info']):
    raise SystemExit('Requested static IPv4 /24 was not applied to the expected MAC.')
for attempt in range(30):
    routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'default']))
    if any(route.get('dev') != lan['ifname'] for route in routes):
        break
    time.sleep(1)
if not any(route.get('dev') != lan['ifname'] for route in routes):
    raise SystemExit('Multipass management default route is missing.')
print(f"Static IP {address}/24 verified on {lan['ifname']}; management default route present.")
PY
