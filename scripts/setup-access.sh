#!/usr/bin/env bash
set -euo pipefail

# Run as ubuntu. Only public keys travel between the host and VMs.
mode="${1:?prepare or authorize required}"
input="${2:?input file required}"
begin='# BEGIN MULTIPASS-K8S-LAB'
end='# END MULTIPASS-K8S-LAB'
install -d -m 700 "$HOME/.ssh"

replace_block() {
  python3 - "$1" "$2" "$begin" "$end" <<'PY'
import pathlib, re, sys
path, source = map(pathlib.Path, sys.argv[1:3])
begin, end = sys.argv[3:5]
old = path.read_text() if path.exists() else ''
pattern = rf'(?ms)^{re.escape(begin)}\n.*?^{re.escape(end)}(?:\n|$)'
if (begin in old or end in old) and not re.search(pattern, old):
    raise SystemExit(f'Incomplete managed block in {path}')
path.write_text(begin + '\n' + source.read_text().rstrip() + '\n' + end + '\n' + re.sub(pattern, '', old))
PY
}

case "$mode" in
  prepare)
    # Preserve Ubuntu's localhost and Multipass entries in /etc/hosts.
    hosts_copy=$(mktemp)
    config_copy=$(mktemp)
    trap 'rm -f "$hosts_copy" "$config_copy"' EXIT
    cat /etc/hosts > "$hosts_copy"
    replace_block "$hosts_copy" "$input"
    sudo install -m 644 "$hosts_copy" /etc/hosts
    if [[ ! -f "$HOME/.ssh/multipass-k8s-id_ed25519" ]]; then
      ssh-keygen -q -t ed25519 -N '' -C "$(hostname)-lab" -f "$HOME/.ssh/multipass-k8s-id_ed25519"
    fi
    cat > "$config_copy" <<'EOF'
Host k8s-master-* k8s-worker-*
    User ubuntu
    IdentityFile ~/.ssh/multipass-k8s-id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/multipass-k8s-known_hosts
    StrictHostKeyChecking accept-new
Host *
EOF
    replace_block "$HOME/.ssh/config" "$config_copy"
    chmod 600 "$HOME/.ssh/config"
    cat "$HOME/.ssh/multipass-k8s-id_ed25519.pub"
    ;;
  authorize)
    replace_block "$HOME/.ssh/authorized_keys" "$input"
    chmod 600 "$HOME/.ssh/authorized_keys"
    ;;
  *) echo 'Usage: setup-access.sh prepare hosts-file | authorize public-keys-file' >&2; exit 2 ;;
esac
