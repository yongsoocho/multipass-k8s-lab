# Multipass Kubernetes practice cluster

Windows PowerShell에서 Multipass와 Hyper-V로 Ubuntu 24.04 기반 `kubeadm` 클러스터를 만듭니다. 기본 구성은 컨트롤 플레인 1대와 워커 2대이며, 확장 구성은 컨트롤 플레인 3대와 워커 6대입니다. 모든 노드는 자동으로 클러스터에 조인합니다.

## 준비

- Windows에서 Hyper-V와 Hyper-V PowerShell 모듈을 켜고 [Multipass](https://canonical.com/multipass/install)를 설치합니다. **관리자 권한** PowerShell에서 실행합니다.
- 호스트의 유선 LAN에 `192.168.35.0/24` 주소가 있어야 합니다. 스크립트는 그 어댑터에 `MultipassK8s` 외부 Hyper-V 스위치를 만듭니다. 스위치 생성 중 호스트 네트워크가 잠시 끊길 수 있습니다.
- `192.168.35.200`~`.209` 주소를 DHCP 예약 범위에서 제외하고 다른 장치가 사용하지 않도록 합니다. 실행 전 핑 충돌 검사를 하지만 핑을 차단한 장치는 발견하지 못합니다.
- 3노드 구성은 VM RAM 6GB와 디스크 50GB, 9노드 구성은 VM RAM 18GB와 디스크 150GB가 필요합니다. 호스트 운영체제와 이미지 다운로드 공간은 별도입니다.
- VM에서 `pkgs.k8s.io`, `registry.k8s.io`, GitHub 및 Ubuntu 저장소에 접속할 수 있어야 합니다. LAN에서 VRRP, TCP 22/6443/16443, VXLAN UDP 8472의 통신이 허용되어야 합니다.

## 실행

```powershell
.\init.ps1              # 1 master + 2 workers
.\init.ps1 -e           # 3 masters + 6 workers
.\init.ps1 --extend     # 위와 동일
```

| 구성 | 주소 | 최소 VM 사양 |
| --- | --- | --- |
| 기본 마스터 | `192.168.35.200` | 2 vCPU, RAM 2GB, 디스크 20GB |
| 기본 워커 | `.201`~`.202` | 각 1 vCPU, RAM 2GB, 디스크 15GB |
| 확장 마스터 | `.200`~`.202` | 각 2 vCPU, RAM 2GB, 디스크 20GB |
| 확장 워커 | `.203`~`.208` | 각 1 vCPU, RAM 2GB, 디스크 15GB |
| 확장 API 가상 IP | `.209:16443` | HAProxy + Keepalived |

Multipass의 기본 NAT NIC는 패키지 다운로드에 사용하고, 두 번째 NIC에는 표의 고정 LAN IP를 부여합니다. 확장 구성의 API 가상 IP는 세 마스터 사이에서 이동합니다. 이 구성은 학습용이며, 세 VM이 같은 PC에 있으므로 호스트 장애에는 대응하지 못합니다.

```powershell
multipass exec k8s-master-1 -- kubectl get nodes -o wide
ssh ubuntu@192.168.35.200
```

Ubuntu SSH 계정 암호는 요청한 대로 **`test`**입니다. 공개된 연습용 암호이므로 인터넷에 22번 포트를 열지 말고 신뢰하는 LAN에서만 사용하세요. LAN 밖에서 접속하려면 VPN이나 라우터 경로 및 방화벽을 별도로 구성해야 합니다.

## 제거

```powershell
.\destroy.ps1
```

이 명령은 Windows Multipass의 현재 드라이버와 `hyperv`·`hcs` 드라이버에서 보이는 **모든 VM**과 그 디스크·스냅샷을 영구 삭제하고, 삭제 대기 중인 VM을 purge하며, 이 프로젝트의 `MultipassK8s` Hyper-V 스위치를 제거합니다. 실행 후 원래 드라이버를 복원합니다. 설치된 Multipass 버전에서 지원하지 않는 드라이버는 경고와 함께 건너뜁니다. 다른 Hyper-V 스위치와 Docker 볼륨/네트워크는 건드리지 않습니다.

## 구현과 제한

- Kubernetes 패키지는 `v1.37` 저장소를 사용합니다. `scripts/setup-node.sh`는 containerd와 systemd cgroup, kubelet 노드 IP를 설정합니다.
- Flannel CNI는 `10.244.0.0/16` Pod 대역을 사용하고, 노드 간 통신에는 `192.168.35.0/24` NIC를 선택합니다.
- `init.ps1`는 기존 `k8s-*` VM을 발견하면 중단합니다. 중간 실패 뒤에는 원인을 확인하고 `destroy.ps1`로 정리한 다음 다시 실행합니다.
- Multipass 1.17부터 기존 `hyperv` 드라이버는 사용 중단 예정입니다. 이 프로젝트는 요청대로 해당 드라이버를 명시적으로 선택합니다.

참고: [Multipass static IP](https://canonical.com/multipass/docs/latest/how-to-guides/manage-instances/configure-static-ips/), [Kubernetes kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/), [kubeadm HA](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/), [Flannel](https://github.com/flannel-io/flannel).

## License

MIT — see [LICENSE](LICENSE).

