#!/usr/bin/env bash
set -euo pipefail

K8S_MINOR="${1:?Kubernetes minor version required}"
NODE_IP="${2:?node IP required}"
HELM_VERSION='v4.3.0'

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
sudo modprobe -a overlay br_netfilter
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system >/dev/null

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg containerd openssh-server openssh-client bash-completion python3
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
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl cri-tools
sudo apt-mark hold kubelet kubeadm kubectl cri-tools
printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$NODE_IP" | sudo tee /etc/default/kubelet >/dev/null
sudo systemctl enable --now kubelet

# Use the installed kubeadm version to select matching images/tools without
# contacting the Kubernetes stable-version endpoint or drifting to another minor.
kubernetes_version="$(kubeadm version -o short)"
cluster_images="$(kubeadm config images list --kubernetes-version="$kubernetes_version")"
pause_image="$(printf '%s\n' "$cluster_images" | awk '/\/pause:/ {print; exit}')"
if [[ -z "$pause_image" ]]; then
  echo 'Cannot determine the kubeadm pause image.' >&2
  exit 1
fi
sudo sed -i -E "s|^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*|\1\"$pause_image\"|" /etc/containerd/config.toml
sudo systemctl restart containerd
cat <<'EOF' | sudo tee /etc/crictl.yaml >/dev/null
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# These SHA256 values are published with the pinned official Helm release:
# https://github.com/helm/helm/releases/tag/v4.3.0
architecture="$(dpkg --print-architecture)"
case "$architecture" in
  amd64) helm_sha256='86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb' ;;
  arm64) helm_sha256='31c5794dd55c66a51e6b7d2e2ac7a114ae8b1de41ff1d9ba51748ac973b06a08' ;;
  *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
esac
helm_archive="helm-${HELM_VERSION}-linux-${architecture}.tar.gz"
curl --fail --silent --show-error --location --retry 3 \
  "https://get.helm.sh/$helm_archive" -o "$work_dir/$helm_archive"
printf '%s  %s\n' "$helm_sha256" "$work_dir/$helm_archive" | sha256sum --check --strict -
tar -xzf "$work_dir/$helm_archive" -C "$work_dir" "linux-${architecture}/helm"
sudo install -m 0755 "$work_dir/linux-${architecture}/helm" /usr/local/bin/helm

# Helm repositories are per-user. Configure both the normal SSH user and root
# so `helm`, `h`, and `sudo helm` see the same initial repository list.
for account in ubuntu root; do
  sudo -H -u "$account" /usr/local/bin/helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
  sudo -H -u "$account" /usr/local/bin/helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
  sudo -H -u "$account" /usr/local/bin/helm repo add jetstack https://charts.jetstack.io --force-update
  sudo -H -u "$account" /usr/local/bin/helm repo update
done

# Install the same etcd release as kubeadm's stacked-etcd image, including
# etcdutl for offline snapshot inspection/restore. No extra etcd service starts.
etcd_tag="$(printf '%s\n' "$cluster_images" | awk '/\/etcd:/ {sub(/^.*\/etcd:/, ""); print; exit}')"
etcd_version="${etcd_tag%%-*}"
if [[ ! "$etcd_version" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
  echo "Cannot determine etcd version from kubeadm images: $etcd_tag" >&2
  exit 1
fi
etcd_release="etcd-v${etcd_version}-linux-${architecture}"
etcd_url="https://github.com/etcd-io/etcd/releases/download/v${etcd_version}"
curl --fail --silent --show-error --location --retry 3 "$etcd_url/$etcd_release.tar.gz" -o "$work_dir/$etcd_release.tar.gz"
curl --fail --silent --show-error --location --retry 3 "$etcd_url/SHA256SUMS" -o "$work_dir/etcd-SHA256SUMS"
awk -v archive="$etcd_release.tar.gz" '$2 == archive {print}' "$work_dir/etcd-SHA256SUMS" > "$work_dir/etcd-checksum"
if [[ ! -s "$work_dir/etcd-checksum" ]]; then
  echo "No official checksum found for $etcd_release.tar.gz" >&2
  exit 1
fi
(cd "$work_dir" && sha256sum --check --strict etcd-checksum)
tar -xzf "$work_dir/$etcd_release.tar.gz" -C "$work_dir" \
  "$etcd_release/etcd" "$etcd_release/etcdctl" "$etcd_release/etcdutl"
sudo install -m 0755 "$work_dir/$etcd_release/etcd" "$work_dir/$etcd_release/etcdctl" "$work_dir/$etcd_release/etcdutl" /usr/local/bin/
cat <<'EOF' | sudo tee /usr/local/bin/etcdctl-k8s >/dev/null
#!/usr/bin/env bash
set -euo pipefail
if ! sudo test -f /etc/kubernetes/pki/etcd/ca.crt; then
  echo 'Run etcdctl-k8s on a control-plane VM after kubeadm init/join.' >&2
  exit 1
fi
exec sudo /usr/local/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key "$@"
EOF
sudo chmod 0755 /usr/local/bin/etcdctl-k8s

# Aliases cover login shells and interactive non-login Bash shells for all users.
# Executable links also make `ssh hostname k ...` and `sudo k ...` work.
cat <<'EOF' | sudo tee /etc/profile.d/k8s-lab.sh >/dev/null
alias k='kubectl'
alias h='helm'
EOF
profile_source='[ ! -r /etc/profile.d/k8s-lab.sh ] || . /etc/profile.d/k8s-lab.sh'
if ! grep -Fqx "$profile_source" /etc/bash.bashrc; then
  printf '\n%s\n' "$profile_source" | sudo tee -a /etc/bash.bashrc >/dev/null
fi
sudo ln -sfn /usr/bin/kubectl /usr/local/bin/k
sudo ln -sfn /usr/local/bin/helm /usr/local/bin/h
sudo mkdir -p /usr/share/bash-completion/completions
kubectl completion bash | sudo tee /usr/share/bash-completion/completions/kubectl >/dev/null
helm completion bash | sudo tee /usr/share/bash-completion/completions/helm >/dev/null

# OpenSSH provides both SSH and SFTP over TCP 22. The early drop-in overrides
# cloud-image password defaults; validate effective settings before restarting.
printf 'ubuntu:test\n' | sudo chpasswd
sudo mkdir -p /etc/ssh/sshd_config.d
sudo sed -i -E '/^[[:space:]]*Subsystem[[:space:]]+sftp[[:space:]]/d' /etc/ssh/sshd_config
cat <<'EOF' | sudo tee /etc/ssh/sshd_config.d/00-k8s-lab.conf >/dev/null
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
Subsystem sftp internal-sftp
EOF
sudo /usr/sbin/sshd -t
sshd_settings="$(sudo /usr/sbin/sshd -T -C user=ubuntu,host=localhost,addr=127.0.0.1)"
grep -qx 'passwordauthentication yes' <<< "$sshd_settings"
grep -qx 'pubkeyauthentication yes' <<< "$sshd_settings"
grep -qx 'subsystem sftp internal-sftp' <<< "$sshd_settings"
sudo systemctl enable --now ssh
sudo systemctl restart ssh

helm version --short
crictl --version
etcdctl version
etcdutl version
