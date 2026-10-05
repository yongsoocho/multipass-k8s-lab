#!/usr/bin/env bash
set -euo pipefail

INDEX="${1:?master index required}"
SELF_IP="${2:?node IP required}"
VIP="${3:?virtual IP required}"
IFACE="${4:?interface required}"

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy keepalived
cat <<'EOF' | sudo tee /etc/haproxy/haproxy.cfg >/dev/null
global
    log /dev/log local0
    daemon
defaults
    mode tcp
    timeout connect 5s
    timeout client  60s
    timeout server  60s
frontend kubernetes-api
    bind *:16443
    default_backend kube-apiservers
backend kube-apiservers
    option tcp-check
    balance roundrobin
    server master1 192.168.35.200:6443 check
    server master2 192.168.35.201:6443 check
    server master3 192.168.35.202:6443 check
EOF

case "$INDEX" in
  1) PEERS='192.168.35.201 192.168.35.202' ;;
  2) PEERS='192.168.35.200 192.168.35.202' ;;
  3) PEERS='192.168.35.200 192.168.35.201' ;;
  *) echo 'Invalid master index' >&2; exit 1 ;;
esac
sudo tee /etc/keepalived/keepalived.conf >/dev/null <<EOF
global_defs {
    router_id k8s_master_${INDEX}
}
vrrp_script chk_haproxy {
    script "/usr/bin/pgrep haproxy"
    interval 2
    fall 2
    rise 2
}
vrrp_instance K8S_API {
    state BACKUP
    interface ${IFACE}
    virtual_router_id 35
    priority $((110 - INDEX))
    advert_int 1
    unicast_src_ip ${SELF_IP}
    unicast_peer {
$(printf '        %s\n' $PEERS)
    }
    authentication {
        auth_type PASS
        auth_pass k8slab35
    }
    virtual_ipaddress {
        ${VIP}/24 dev ${IFACE}
    }
    track_script {
        chk_haproxy
    }
}
EOF
sudo systemctl enable --now haproxy keepalived
sudo systemctl restart haproxy keepalived
