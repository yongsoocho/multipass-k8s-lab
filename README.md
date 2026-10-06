# Multipass Kubernetes practice cluster

Windows의 PowerShell 7.2 이상에서 Multipass와 Hyper-V로 Ubuntu 24.04 기반 `kubeadm` 클러스터를 만듭니다. 기본 구성은 컨트롤 플레인 1대와 워커 2대이며, 확장 구성은 컨트롤 플레인 3대와 워커 6대입니다. 모든 노드는 자동으로 조인하고 **CNI는 설치하지 않습니다**.

## 준비

- Windows에서 Hyper-V와 Hyper-V PowerShell 모듈을 켜고 [Multipass](https://canonical.com/multipass/install), PowerShell 7.2 이상, Windows OpenSSH Client (`ssh`, `sftp`, `ssh-keygen`)를 설치합니다. **관리자 권한 `pwsh`**에서 실행합니다. Windows 기본 PowerShell 5.1은 지원하지 않습니다.
- 호스트의 유선 LAN에 `192.168.35.0/24` 주소가 있어야 합니다. 스크립트는 그 어댑터에 `MultipassK8s` 외부 Hyper-V 스위치를 만듭니다. 스위치 생성 중 호스트 네트워크가 잠시 끊길 수 있습니다.
- `192.168.35.200`~`.209` 주소를 DHCP 예약 범위에서 제외하고 다른 장치가 사용하지 않도록 합니다. 실행 전 핑 충돌 검사를 하지만 핑을 차단한 장치는 발견하지 못합니다.
- 3노드 구성은 VM RAM 6GB와 디스크 50GB, 9노드 구성은 VM RAM 18GB와 디스크 150GB가 필요합니다. 호스트 운영체제와 이미지 다운로드 공간은 별도입니다.
- VM에서 `pkgs.k8s.io`, `registry.k8s.io`, `get.helm.sh`, GitHub, Helm 저장소 및 Ubuntu 저장소에 접속할 수 있어야 합니다. 노드 사이 Kubernetes 통신과 LAN에서 TCP 22(SSH/SFTP), 6443/16443(API), 확장 구성의 VRRP가 허용되어야 합니다. CNI 설치 시 Calico VXLAN은 UDP 4789, Flannel VXLAN은 UDP 8472를 사용합니다.

### PowerShell 5.1에서 PowerShell 7로 전환

**Windows 기본 Windows PowerShell 5.1에서는 이 스크립트를 실행할 수 없습니다.** 스크립트의 `#requires -Version 7.2` 조건에 따라 PowerShell 7.2 이상이 필요합니다. `Set-ExecutionPolicy`는 실행 정책만 변경하므로 버전 불일치 오류를 해결하지 못합니다.

현재 터미널에서 다음 명령으로 PowerShell 7을 설치하세요.

```powershell
winget install --id Microsoft.PowerShell --source winget
```

PowerShell 7은 기존 Windows PowerShell 5.1과 별도로 설치됩니다. 설치 후 기존 터미널을 닫고 **시작 메뉴 → PowerShell 7 → 관리자 권한으로 실행**을 선택하세요. 새 창에서 버전이 7.2 이상인지 확인하고 저장소 디렉터리로 이동합니다.

```powershell
$PSVersionTable.PSVersion
Set-Location 'C:\path\to\multipass'  # 실제 저장소 경로로 바꾸세요.
```

실행 정책으로 차단되면 PowerShell 7 창에서 다음 명령을 실행한 뒤 다시 시도하세요.

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

이미 관리자 권한 터미널을 열었다면 `pwsh -NoProfile -File .\init.ps1`로 PowerShell 7을 명시하여 실행할 수도 있습니다. `#requires`를 삭제하지 마세요.

## 실행

```powershell
.\init.ps1              # 1 master + 2 workers
.\init.ps1 -e           # 3 masters + 6 workers
.\init.ps1 --extend     # 위와 동일
```

설치 완료 시 모든 노드가 등록됐는지와 API 상태를 확인합니다. CNI가 없으므로 **노드 NotReady, CoreDNS Pending은 정상적인 초기 상태**입니다. CNI를 직접 설치하거나 아래 스크립트 중 하나를 실행하세요.

```powershell
.\install-calico.ps1    # Calico 3.33.0, VXLAN
# 또는
.\install-flannel.ps1   # Flannel 0.28.9, VXLAN
```

두 스크립트 모두 `10.244.0.0/16` Pod CIDR와 `192.168.35.0/24` LAN 인터페이스를 사용합니다. 모든 VM의 기존 CNI 설정을 확인한 뒤 설치하고, CNI·노드·CoreDNS 준비까지 기다립니다. 다운로드가 느리면 `-TimeoutSeconds 1200`으로 준비 대기를 늘릴 수 있습니다. 같은 스크립트는 다시 실행할 수 있지만 다른 CNI가 있으면 중단합니다. CNI를 바꾸려면 클러스터를 다시 만드세요.

| 구성 | 주소 | 최소 VM 사양 |
| --- | --- | --- |
| 기본 마스터 | `192.168.35.200` | 2 vCPU, RAM 2GB, 디스크 20GB |
| 기본 워커 | `.201`~`.202` | 각 1 vCPU, RAM 2GB, 디스크 15GB |
| 확장 마스터 | `.200`~`.202` | 각 2 vCPU, RAM 2GB, 디스크 20GB |
| 확장 워커 | `.203`~`.208` | 각 1 vCPU, RAM 2GB, 디스크 15GB |
| 확장 API 가상 IP | `.209:16443` | HAProxy + Keepalived |

Multipass의 기본 NAT NIC는 패키지 다운로드에 사용하고, 두 번째 NIC에는 표의 고정 LAN IP를 부여합니다. 확장 구성의 API 가상 IP는 세 마스터 사이에서 이동합니다. 이 구성은 학습용이며, 세 VM이 같은 PC에 있으므로 호스트 장애에는 대응하지 못합니다.

## 명령어와 Helm 저장소

모든 VM에 전역 Bash alias `k=kubectl`, `h=helm`을 설정합니다. 같은 이름의 실행 링크도 설치하므로 비대화형 `ssh k8s-master-1 k get nodes`에서도 사용할 수 있습니다. 모든 마스터의 `ubuntu`와 `root`에 kubeconfig를 설정합니다. 워커에는 관리자 kubeconfig를 복사하지 않습니다.

```bash
k get nodes -o wide
h repo list
sudo crictl ps -a
etcdctl version
etcdutl version
etcdctl-k8s endpoint health   # 마스터의 로컬 etcd에 TLS 인증으로 접속
```

Helm 4.3.0은 공식 SHA256을 확인해 설치하며, `ubuntu`와 `root` 양쪽에 다음 저장소를 등록합니다. 차트는 자동 배포하지 않습니다.

| 저장소 | URL |
| --- | --- |
| metrics-server | `https://kubernetes-sigs.github.io/metrics-server/` |
| prometheus-community | `https://prometheus-community.github.io/helm-charts` |
| jetstack | `https://charts.jetstack.io` |

`cri-tools`의 `crictl`은 containerd 소켓으로 연결하도록 설정합니다. `etcd`, `etcdctl`, `etcdutl`은 kubeadm이 사용하는 etcd 이미지와 같은 버전으로 설치하고 체크섬을 검사합니다. 별도 etcd 서비스는 시작하지 않습니다.

## SSH와 SFTP

`init.ps1`을 실행한 Windows 사용자와 VM의 `ubuntu` 계정에서는 호스트 이름만 입력하면 됩니다.

```powershell
ssh k8s-master-1
ssh k8s-worker-1
sftp k8s-worker-1
ssh k8s-master-1 k get nodes -o wide
```

호스트는 `%USERPROFILE%\.ssh\config`의 표시된 블록으로 이름을 IP에 연결하고 사용자 `ubuntu`와 전용 키를 선택합니다. VM에는 전체 노드의 `/etc/hosts` 항목과 SSH 키 접속을 설정하므로 VM 안에서도 `ssh k8s-worker-1`을 사용할 수 있습니다. 각 VM의 개인 키는 해당 VM에 남고 공개 키만 교환합니다. 호스트의 전용 키·known_hosts는 `%USERPROFILE%\.ssh\multipass-k8s-lab`에 저장하며 저장소에 넣지 않습니다. 최초 호스트 키는 기록하고, 이후 키가 바뀌면 SSH가 접속을 거부합니다.

`init.ps1`은 각 VM의 SSH와 SFTP, VM에서 첫 마스터로의 SSH를 실제로 검사합니다. SFTP는 OpenSSH의 `internal-sftp`를 쓰며 별도 포트 없이 TCP 22번을 사용합니다. 기존 개인 SSH 설정과 Multipass의 인증 키는 유지합니다.

다른 LAN 컴퓨터에서는 `ssh ubuntu@192.168.35.200` 또는 `sftp ubuntu@192.168.35.200`으로 접속할 수 있습니다. 그 컴퓨터에서도 이름만 쓰려면 DNS/hosts 또는 아래와 같은 SSH 설정을 추가해야 합니다.

```sshconfig
Host k8s-master-1
    HostName 192.168.35.200
    User ubuntu
```

Ubuntu SSH 계정 암호는 **`test`**입니다. 공개된 연습용 암호이므로 신뢰하는 LAN에서 사용하세요. LAN 밖에서 접속하려면 VPN이나 라우터 경로 및 방화벽을 별도로 구성해야 합니다.

## nginx 연습 파일

[examples/nginx.yaml](examples/nginx.yaml)에 nginx Deployment(2 replicas)와 NodePort Service(30080)를 준비했습니다. **어떤 설치 스크립트도 이 파일을 적용하지 않습니다.** CNI 설치 후 직접 연습하려면 마스터로 복사한 뒤 적용합니다.

```powershell
multipass transfer .\examples\nginx.yaml k8s-master-1:/home/ubuntu/nginx.yaml
ssh k8s-master-1 k apply -f /home/ubuntu/nginx.yaml
ssh k8s-master-1 k get deploy,pods,svc
```

Pod가 준비되면 `http://192.168.35.201:30080`으로 확인할 수 있습니다. 이 예제는 기본 namespace를 사용하고 nginx `stable-alpine` 태그를 받습니다.

## 제거

```powershell
.\destroy.ps1
```

**초기화와 같은 Windows 계정의 관리자 PowerShell 7**에서 실행합니다. 이 명령은 현재 드라이버와 사용 가능한 Windows Multipass 드라이버에서 보이는 **모든 VM**과 그 디스크·스냅샷을 영구 삭제하고, 삭제 대기 중인 VM을 purge하며, 이 프로젝트의 `MultipassK8s` Hyper-V 스위치를 제거합니다. Multipass 1.16에서는 `hcs`를 시도하지 않고, 설치되지 않은 VirtualBox도 전환하지 않습니다. 건너뛴 드라이버와 이유를 출력합니다. 현재 활성 드라이버는 항상 검사 대상입니다.

드라이버 전환 후에는 접속과 인벤토리를 재확인하며 일시적인 TLS/socket 오류를 재시도합니다. JSON과 stderr 진단 메시지는 분리해서 처리합니다. 각 드라이버의 빈 VM 목록과 원래 드라이버 복원까지 검증합니다. 일부 단계가 실패하면 나머지 가능한 정리를 수행한 뒤 미완료 항목을 오류로 보고합니다. 같은 명령을 다시 실행해도 됩니다. VM이 남아 연결된 스위치는 제거하지 않으며, Hyper-V 삭제를 확인하지 못한 경우 SSH 접속 설정도 보존합니다.

다른 Hyper-V 스위치와 Docker 볼륨/네트워크, Multipass 인증서 및 공유 이미지 다운로드 캐시는 유지합니다. VM에 속한 디스크와 스냅샷은 Multipass의 `delete --all --purge`와 `purge`로 정리합니다. [Multipass 삭제 명령 문서](https://canonical.com/multipass/docs/latest/reference/command-line-interface/delete/)

현재 Windows 사용자의 SSH 설정에서 프로젝트 블록과 표식이 있는 전용 키·known_hosts 디렉터리도 제거합니다. 기존 개인 SSH 키와 다른 설정은 유지합니다. 초기화와 같은 Windows 계정으로 실행하세요.

## 구현과 제한

- Kubernetes 패키지는 `v1.37` 저장소를 사용합니다. 설치된 kubeadm 버전으로 제어면 이미지 버전을 고정합니다. `scripts/setup-node.sh`는 containerd와 systemd cgroup, kubelet 노드 IP를 설정합니다.
- 초기 구축에는 CNI를 배포하지 않습니다. Calico/Flannel 선택 설치는 별도 스크립트가 담당합니다.
- `init.ps1`는 기존 `k8s-*` VM을 발견하면 중단합니다. **kubeadm init/join 이전** 네트워크·패키지 설치 단계에서 실패했다면 VM을 보존한 채 `./init.ps1 -Resume`으로 재개하세요. 확장 구성은 `./init.ps1 -e -Resume`입니다. VM 이름·LAN MAC과 Kubernetes 초기화 여부를 확인하며, 이미 초기화된 노드는 재개를 거부합니다.
- `netplan apply` 중 기본 NIC의 DHCP 주소가 바뀌면 Multipass 연결이 잠시 끊길 수 있습니다. 네트워크 적용은 VM 내부의 독립된 systemd 작업으로 실행하고, 최대 240초 동안 재접속과 작업 결과를 확인합니다. 고정 IP와 관리용 기본 경로까지 확인해야 다음 단계로 진행합니다. 실패 시 출력되는 VM 내부 `apply.log` 경로를 확인하세요.
- Windows용 Multipass가 한글 로컬 경로를 잘못 읽는 문제를 피하기 위해 파일과 cloud-init 설정은 표준입력으로 전달합니다. VM에 전송한 파일은 SHA256까지 확인합니다. 저장소를 영문 경로로 옮길 필요가 없습니다.
- Multipass 1.17부터 기존 `hyperv` 드라이버는 사용 중단 예정입니다. 이 프로젝트는 요청대로 해당 드라이버를 명시적으로 선택합니다.

`pwsh -NoProfile -File .\tests\verify.ps1`은 PowerShell 구문과 격리된 테스트 디렉터리에서 SSH 설정/키 생성·정리를 검사합니다. 실제 클러스터 통합 테스트에는 Hyper-V와 Multipass가 필요합니다.

`pwsh -NoProfile -File .\tests\destroy.ps1`은 VM을 변경하지 않고 드라이버 선택, TLS 재시도, 일부 드라이버 실패, 원래 드라이버 복원, 남은 VM 검출, 반복 정리를 검사합니다.

`pwsh -NoProfile -File .\tests\network.ps1`은 연결 끊김·재접속·타임아웃 처리를 검사합니다. 실행 중인 VM이 있으면 `pwsh -NoProfile -File .\tests\transfer-live.ps1 -Node k8s-master-1`로 한글·공백·괄호 경로, 바이너리·빈 파일, 모든 셸 스크립트의 실제 전송과 SHA256을 검사할 수 있습니다. 이 검사는 VM의 임시 디렉터리만 사용하고 정리합니다.

구축 후에는 `pwsh -NoProfile -File .\tests\cluster-live.ps1`로 노드 등록과 API 상태를 다시 확인합니다. 확장 구성은 `-Extended`를 붙입니다. 이 검사는 CNI를 설치하지 않습니다.

참고: [Multipass static IP](https://canonical.com/multipass/docs/latest/how-to-guides/manage-instances/configure-static-ips/), [Kubernetes kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/), [kubeadm HA](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/), [Calico 요구사항](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements), [Flannel](https://github.com/flannel-io/flannel), [Helm 설치](https://helm.sh/docs/intro/install/), [crictl](https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/).

## License

MIT — see [LICENSE](LICENSE).

