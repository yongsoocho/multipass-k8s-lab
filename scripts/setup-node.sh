#!/usr/bin/env bash
set -euo pipefail

K8S_MINOR="${1:?Kubernetes minor version required}"
NODE_IP="${2:?node IP required}"

sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay br_netfilter
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system >/dev/null

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg containerd openssh-server
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd ssh
sudo systemctl restart containerd

sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" |
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" |
  sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$NODE_IP" | sudo tee /etc/default/kubelet >/dev/null
sudo systemctl enable --now kubelet

