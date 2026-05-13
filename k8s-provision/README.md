# Ansible Cluster Provisioning

Lima VM 들에 kubeadm 으로 Kubernetes 클러스터 부트스트랩.
**CNI 는 의도적으로 설치 안 함** — 자작 CNI 학습이 목적이라.

## Prerequisites

- Lima VM 들이 이미 실행 중 (`k8s-master`, `k8s-worker-1`, `k8s-worker-2`)
- 각 VM 에 `lima0` 인터페이스 존재 (= shared network 설정됨)
- Master Lima YAML 에 6443 portForward 있음:
  ```yaml
  portForwards:
    - guestIP: "0.0.0.0"
      guestPort: 6443
      hostIP: "127.0.0.1"
      hostPort: 6443
  ```
- Host 에 `ansible`, `jq`, `limactl` 설치됨

## Usage

```bash
# 1. Lima VM 정보로부터 inventory 생성
./scripts/generate-inventory.sh

# 2. Playbook 실행
cd ansible
ansible-playbook site.yml

# 3. kubeconfig 확인 (자동으로 ansible/.kube/config 에 저장됨)
export KUBECONFIG=$(pwd)/.kube/config
kubectl get nodes
# NAME            STATUS     ROLES           AGE   VERSION
# k8s-master      NotReady   control-plane   2m    v1.31.x
# k8s-worker-1    NotReady   <none>          1m    v1.31.x
# k8s-worker-2    NotReady   <none>          1m    v1.31.x
```

NotReady 가 **정상 결과**임. CNI 가 없어서 그럼.
`kubectl describe node k8s-master` 보면 `KubeletNotReady` 와
`network plugin is not ready: cni plugin not initialized` 메시지 볼 수 있음.

## Reset (CNI 실험 후 초기화)

VM 은 그대로 두고 클러스터 상태만 초기화:
```bash
cd ansible
ansible-playbook reset.yml
ansible-playbook site.yml  # 다시 init
```

VM 부터 다 갈아엎고 싶으면:
```bash
limactl delete --force k8s-master k8s-worker-1 k8s-worker-2
# Lima YAML 로 다시 start, generate-inventory.sh, site.yml
```

## 디자인 결정 사항

- **Pod CIDR**: `10.244.0.0/16` (Flannel default).
  Lima shared 의 `192.168.105.0/24` 와 안 겹치게 일부러 10.x 대역 선택.
- **kubelet `--node-ip`**: lima0 인터페이스 IP 로 강제.
  안 그러면 kubelet 이 SLIRP eth0 (`192.168.5.x`) 를 advertise 해서 worker join 실패.
- **`--apiserver-advertise-address`**: 동일하게 lima0 IP.
- **kube-proxy 는 유지**: CNI 와 kube-proxy 는 다른 layer.
  CNI 학습에 집중하기 위해 kube-proxy 는 정상 작동하는 상태로 둠.
  나중에 본인 CNI 가 kube-proxy 까지 대체하고 싶으면 그때 `--skip-phases=addon/kube-proxy` 추가.

## 다음 단계 (CNI 학습)

1. `kubectl get pods -n kube-system` → CoreDNS 가 Pending (CNI 없어서 IP 못 받음)
2. `kubectl describe pod -n kube-system coredns-...` → "network plugin not ready" 확인
3. `/etc/cni/net.d/` 비어있음 확인 (`ls` 또는 `find`)
4. 직접 만든 CNI conflist 를 `/etc/cni/net.d/10-mycni.conflist` 로 배포
5. 직접 만든 CNI 바이너리를 `/opt/cni/bin/mycni` 로 배포
6. kubelet 이 CNI 인지하면 노드 Ready 됨
