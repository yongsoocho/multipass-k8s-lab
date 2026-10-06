#!/usr/bin/env bash
set -euo pipefail
name="${1:?name required}"
mac="${2:?MAC required}"
[[ "$(hostname)" == "$name" ]] || { echo 'Unexpected VM hostname.' >&2; exit 1; }
grep -qiFx "$mac" /sys/class/net/*/address || { echo 'VM LAN MAC differs from requested topology.' >&2; exit 1; }
if sudo test -e /etc/kubernetes/kubelet.conf || sudo test -e /etc/kubernetes/admin.conf ||
   sudo test -d /var/lib/etcd/member || sudo find /etc/kubernetes/manifests -name '*.yaml' -print 2>/dev/null | grep -q .; then
    echo 'Kubernetes bootstrap already started on this VM. Resume only supports provisioning failures before kubeadm init/join.' >&2
    exit 1
fi
echo 'Pre-bootstrap VM identity verified; provisioning can resume.'
