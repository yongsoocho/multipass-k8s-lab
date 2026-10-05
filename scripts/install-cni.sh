#!/usr/bin/env bash
set -euo pipefail

MODE="${1:?check or install required}"
PROVIDER="${2:?calico or flannel required}"
TIMEOUT="${3:-600}"
case "$MODE" in check|install) ;; *) echo 'Invalid mode.' >&2; exit 1 ;; esac
case "$PROVIDER" in calico|flannel) ;; *) echo 'Invalid CNI provider.' >&2; exit 1 ;; esac
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo 'Invalid timeout.' >&2; exit 1; }

if [[ "$MODE" == check ]]; then
    # Filenames alone are insufficient: inspect the actual plugin types on each VM.
    sudo python3 - "$PROVIDER" <<'PY'
import glob
import ipaddress
import json
import subprocess
import sys

provider = sys.argv[1]
lan = ipaddress.ip_network('192.168.35.0/24')
addresses = json.loads(subprocess.check_output(['ip', '-j', '-4', 'address', 'show']))
if not any(ipaddress.ip_address(a['local']) in lan for i in addresses for a in i['addr_info']):
    sys.exit('No 192.168.35.0/24 interface found on this node.')
for path in sorted(glob.glob('/etc/cni/net.d/*')):
    if not path.endswith(('.conf', '.conflist', '.json')):
        continue
    try:
        with open(path, encoding='utf-8') as stream:
            config = json.load(stream)
    except (OSError, ValueError) as error:
        sys.exit(f'Cannot safely inspect CNI file {path}: {error}')
    plugins = config.get('plugins', [config])
    types = {p.get('type') for p in plugins}
    if provider not in types or not types <= {provider, 'portmap', 'bandwidth', 'tuning'}:
        sys.exit(f'Conflicting CNI file {path}: {types}. Rebuild the lab before changing CNI.')
PY
    exit 0
fi

work="$(mktemp -d /tmp/multipass-k8s-cni.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
diagnostics() {
    local status=$?
    trap - ERR
    echo "CNI installation failed. Check LAN connectivity, image downloads and UDP ports (Calico 4789 / Flannel 8472)." >&2
    kubectl get nodes -o wide || true
    kubectl get pods -A -o wide || true
    kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -n 30 || true
    exit "$status"
}
trap diagnostics ERR

kubectl get daemonsets,deployments -A -o json > "$work/controllers.json"
kubectl -n kube-system get configmap kubeadm-config -o json > "$work/kubeadm.json"
python3 - "$PROVIDER" "$work" <<'PY'
import json
import pathlib
import re
import sys

provider, directory = sys.argv[1], pathlib.Path(sys.argv[2])
config = json.loads((directory / 'kubeadm.json').read_text())['data']['ClusterConfiguration']
if not re.search(r'(?m)^\s*podSubnet:\s*[\"\x27]?10\.244\.0\.0/16[\"\x27]?\s*$', config):
    sys.exit('This installer requires kubeadm podSubnet 10.244.0.0/16.')
known = {
    'calico': r'calico|tigera',
    'flannel': r'flannel',
    'other': r'cilium|weave-net|weaveworks/weave|kube-router|antrea|kube-ovn|canal',
}
for item in json.loads((directory / 'controllers.json').read_text())['items']:
    meta = item['metadata']
    name = meta['name']
    namespace = meta['namespace']
    images = ' '.join(c['image'] for c in item['spec']['template']['spec']['containers'])
    identity = f'{namespace}/{name} {images}'
    detected = {kind for kind, pattern in known.items() if re.search(pattern, identity, re.I)}
    if detected - {provider}:
        sys.exit(f'Conflicting CNI workload: {namespace}/{name}. Rebuild before switching CNI.')
    if provider == 'calico' and detected and (namespace != 'kube-system' or 'tigera' in identity):
        sys.exit('Operator-managed Calico exists. Manage it with its operator instead of this manifest installer.')
PY

if [[ "$PROVIDER" == calico ]]; then
    # A previously created IP pool cannot be changed just by updating DaemonSet env.
    if kubectl get crd ippools.crd.projectcalico.org --ignore-not-found -o name | grep -q .; then
        kubectl get ippools.crd.projectcalico.org -o json > "$work/pools.json"
        python3 - "$work/pools.json" <<'PY'
import json
import sys
for pool in json.load(open(sys.argv[1], encoding='utf-8'))['items']:
    spec = pool['spec']
    if spec.get('cidr') != '10.244.0.0/16' or spec.get('ipipMode', 'Never') != 'Never' or spec.get('vxlanMode') != 'Always':
        sys.exit('Existing Calico pool differs from this lab (10.244.0.0/16, VXLAN Always). Rebuild before changing its network.')
PY
    fi
    curl -fSL --retry 3 --connect-timeout 20 --max-time 300 \
        https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/calico.yaml \
        -o "$work/upstream.yaml"
    cat > "$work/patch.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: calico-config
  namespace: kube-system
data:
  calico_backend: vxlan
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: calico-node
  namespace: kube-system
spec:
  template:
    spec:
      containers:
        - name: calico-node
          env:
            - name: CLUSTER_TYPE
              value: k8s
            - name: IP_AUTODETECTION_METHOD
              value: cidr=192.168.35.0/24
            - name: CALICO_IPV4POOL_CIDR
              value: 10.244.0.0/16
            - name: CALICO_IPV4POOL_IPIP
              value: Never
            - name: CALICO_IPV4POOL_VXLAN
              value: Always
          livenessProbe:
            exec:
              command: [calico, component, node, health, --felix-live]
          readinessProbe:
            exec:
              command: [calico, component, node, health, --felix-ready]
YAML
    namespace=kube-system
    daemonset=calico-node
else
    curl -fSL --retry 3 --connect-timeout 20 --max-time 300 \
        https://github.com/flannel-io/flannel/releases/download/v0.28.9/kube-flannel.yml \
        -o "$work/upstream.yaml"
    cat > "$work/patch.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
data:
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "Backend": { "Type": "vxlan" }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
spec:
  template:
    spec:
      containers:
        - name: kube-flannel
          env:
            - name: FLANNELD_IFACE_REGEX
              value: ^192[.]168[.]35[.]
YAML
    namespace=kube-flannel
    daemonset=kube-flannel-ds
fi

cat > "$work/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - upstream.yaml
patches:
  - path: patch.yaml
YAML

# Render the full patched manifest before any resource is created. Reapplying this
# result is idempotent and never briefly starts pods with a wrong NIC or Pod CIDR.
kubectl kustomize "$work" > "$work/rendered.yaml"
kubectl apply --server-side --field-manager=multipass-k8s-lab -f "$work/rendered.yaml"
kubectl -n "$namespace" rollout status "daemonset/$daemonset" --timeout="${TIMEOUT}s"
if [[ "$PROVIDER" == calico ]]; then
    kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout="${TIMEOUT}s"
fi
kubectl wait --for=condition=Ready nodes --all --timeout="${TIMEOUT}s"
kubectl -n kube-system rollout status deployment/coredns --timeout="${TIMEOUT}s"
kubectl get nodes -o wide
echo "$PROVIDER installed. All nodes and CoreDNS are ready."
