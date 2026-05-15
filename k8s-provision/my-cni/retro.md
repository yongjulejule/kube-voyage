# Bash 100줄로 K8s CNI 만들고 BGP로 멀티노드 통신까지 뚫어보기

> Lima VM 3대 위에 깡통 K8s 클러스터를 띄워놓고 CNI 만 일부러 빼놓은 다음, 순수 Bash 스크립트로 처음부터 끝까지 직접 깎아본 기록.

## 왜 이런 짓을?

쿠버네티스 쓰면서 Flannel, Calico, Cilium 같은 CNI 는 `kubectl apply -f` 한 줄로 깔고 끝낸다. 그 한 줄 뒤에서 일어나는 일을 한 번도 진짜로 본 적이 없었다.

그래서 결심했다. **CNI 를 빼고 클러스터를 띄운 다음, 직접 만들어서 꽂아보자.** 언어는 Bash. 이유는 가장 원시적이라서 어디서 무슨 일이 벌어지는지 한 줄 한 줄 다 보이기 때문.

목표:
1. 단일 노드에서 파드 띄우고 통신되게 만들기
2. 멀티 노드 간 파드 통신까지 뚫기 (BGP)

## 전체 그림

```
                    macOS Host
   ┌────────────────────────────────────────────────────────────┐
   │                                                            │
   │  ┌────────────┐    ┌─────────────┐    ┌─────────────┐      │
   │  │ Lima VM    │    │ Lima VM     │    │ Lima VM     │      │
   │  │ k8s-master │    │ worker-1    │    │ worker-2    │      │
   │  │            │    │             │    │             │      │
   │  │ kubeadm    │    │  Pod CIDR:  │    │  Pod CIDR:  │      │
   │  │  init      │    │ 10.0.0.0/28 │    │10.0.0.32/28 │      │
   │  │            │    │             │    │             │      │
   │  │ ❌ CNI 없음 │    │ ❌ CNI 없음 │    │ ❌ CNI 없음 │      │
   │  └─────┬──────┘    └──────┬──────┘    └──────┬──────┘      │
   │        │                  │                  │             │
   │        └──────────────────┼──────────────────┘             │
   │                   shared network (lima0)                   │
   │                    192.168.105.0/24                        │
   └────────────────────────────────────────────────────────────┘

           ↓ 오늘 할 일 ↓

   각 워커에 my-cni.sh (Bash) + FRR (BGP) 꽂아서 통신 뚫기
```

Ansible 로 kubeadm 부트스트랩까지만 하고 CNI 는 일부러 설치 안 함. `kubectl get nodes` 치면 전부 `NotReady`. CoreDNS 는 영원히 `ContainerCreating`. 정상이다.

```
kubelet 에러:
"network plugin is not ready: cni plugin not initialized"
```

이 메시지를 없애는 게 첫 번째 목표.

---

## CNI 동작 원리 — 누가 누구에게 뭘 던지는가

가장 헷갈리는 부분. 정리하면:

```
┌──────────┐
│ kubelet  │
└────┬─────┘
     │ "파드 만들어줘"
     ↓
┌──────────────┐
│ containerd   │   ① /etc/cni/net.d/*.conf 읽음
│   (CRI)      │   ② conf["type"] = "my-cni"
└────┬─────────┘   ③ /opt/cni/bin/my-cni 실행
     │
     │  stdin  : conf JSON 원본 그대로
     │  env    : CNI_COMMAND=ADD
     │           CNI_NETNS=/var/run/netns/cni-xxx
     │           CNI_IFNAME=eth0
     │           CNI_CONTAINERID=...
     ↓
┌──────────────┐
│ my-cni.sh    │      stdin: conf JSON      ┌─────────────────┐
│              │ ─────────────────────────→ │   host-local    │
│  (Bash)      │      stdout: 할당된 IP/GW  │   (IPAM 위임)   │
│              │ ←───────────────────────── └─────────────────┘
└────┬─────────┘
     │  stdout: 최종 결과 JSON
     │         {ips, interfaces, ...}
     ↓
[containerd → kubelet 회신]
```

핵심 사실 두 개:
- **Kubelet 이 IP 를 결정하는 게 아니다.** CNI 가 결정해서 stdout 으로 뱉으면 Kubelet 이 받아 적는다.
- **conf 파일은 동적이 아니다.** 내가 미리 써둔 정적 파일. containerd 는 그걸 그대로 stdin 으로 던질 뿐.

---

## Step 1: CNI 스크립트 골격

```bash
#!/usr/bin/env bash
set -euo pipefail

function add {
  local target_ns=${CNI_NETNS##*/}        # ① 절대경로에서 이름만 추출
  local pod_ifname=${CNI_IFNAME}
  local input_config=$(cat)               # ② stdin = conf JSON

  local bridge_name=$(jq -r '.bridge' <<<"$input_config")
  local mtu=$(jq -r '.mtu' <<<"$input_config")

  # ③ IPAM 은 직접 짜지 않고 공식 host-local 바이너리에 위임
  local ipam_result=$(echo "$input_config" | /opt/cni/bin/host-local)
  local assigned_ip=$(jq -r '.ips[0].address' <<<"$ipam_result")
  local gw_ip=$(jq -r '.ips[0].gateway'  <<<"$ipam_result")

  # ... 네트워크 공사 ...

  # ④ Kubelet 에게 결과 보고
  jq -n --arg mac "$mac" --arg ip "$assigned_ip" '{
    cniVersion: "0.3.1",
    interfaces: [{name: "eth0", mac: $mac}],
    ips: [{version: "4", address: $ip, interface: 0}]
  }'
}
```

### 함정 ①: `CNI_NETNS` 는 절대경로로 온다

CNI 스펙은 절대경로 (`/var/run/netns/cni-d991...`) 로 던지라고 한다. 그런데 `ip netns exec` 는 **이름만** 받는다. `${CNI_NETNS##*/}` 로 마지막 슬래시 뒤만 잘라야 함.

### 함정 ②: IPAM 은 절대 직접 짜지 마라

처음엔 Bash 로 IP 카운터를 직접 관리하려 했다. `/tmp/ip-counter.txt` 만들어서 `+1` 씩 증가. 미친 짓이다. CIDR 계산, 충돌 방지, 동시성 락 다 짜려면 수백 줄.

`host-local` 이라는 공식 IPAM 바이너리가 `/opt/cni/bin/` 에 이미 있다. conf 의 `ipam.type: host-local` 만 지정하면, 내 CNI 가 그걸 **하청업체로 호출** 해서 IP 받아오면 끝.

```jsonc
// /etc/cni/net.d/10-my-cni.conf  (worker-1)
{
  "cniVersion": "0.3.1",
  "name": "my-bash-network",
  "type": "my-cni",           // → /opt/cni/bin/my-cni 호출됨
  "bridge": "br0",
  "mtu": 1352,                // ← 나중에 설명
  "ipam": {
    "type": "host-local",     // → /opt/cni/bin/host-local 위임
    "subnet": "10.0.0.0/28",
    "routes": [{"dst": "0.0.0.0/0"}]
  }
}
```

worker-2 는 subnet 만 `10.0.0.32/28` 로 바꿔서 동일하게 배치.

### 함정 ③: 수동 테스트하려면 환경변수 직접 줘야 함

```bash
cat conf.json | /opt/cni/bin/host-local
# → 버전 정보만 뱉고 끝
```

`CNI_COMMAND` 환경변수가 없으면 host-local 도 "뭐 하라는 거임?" 하고 퇴근.

```bash
cat conf.json | \
  CNI_COMMAND=ADD CNI_CONTAINERID=test \
  CNI_NETNS=/var/run/netns/dummy CNI_IFNAME=eth0 \
  CNI_PATH=/opt/cni/bin /opt/cni/bin/host-local
# → 이제 IP JSON 뱉음
```

---

## Step 2: 실제 네트워크 공사

### 단일 노드에서의 패킷 경로

```
        ┌──────────────────────────────────────┐
        │   Pod netns (cni-xxx)                │
        │                                      │
        │   ┌─────────┐                        │
        │   │  eth0   │   10.0.0.2/28          │
        │   │         │   default via 10.0.0.1 │
        │   └────┬────┘                        │
        └────────┼─────────────────────────────┘
                 │
                 │  ← veth pair 가 이 경계를 가로지름
                 │
        ┌────────┼─────────────────────────────┐
        │   ┌────┴────┐                        │
        │   │ veth-2  │   (호스트 netns)       │
        │   └────┬────┘                        │
        │        │ master                      │
        │        ↓                             │
        │   ┌──────────┐                       │
        │   │   br0    │   10.0.0.1/28         │
        │   │  bridge  │   ← 게이트웨이         │
        │   └────┬─────┘                       │
        │        │                             │
        │        │  호스트 라우팅 테이블이      │
        │        │  10.0.0.0/28 → br0 으로 라우팅 │
        │        ↓                             │
        │       외부 (lima0)                   │
        └──────────────────────────────────────┘
```

코드:

```bash
# 브릿지 자가 치유 (멱등성 분리가 핵심)
if ! ip link show "$bridge_name" >/dev/null 2>&1; then
  ip link add "$bridge_name" type bridge
fi
ip link set "$bridge_name" up
ip link set mtu "$mtu" dev "$bridge_name"
if ! ip addr show "$bridge_name" | grep -q "$gw_ip/$prefix"; then
  ip addr add "$gw_ip/$prefix" dev "$bridge_name"
fi

# veth pair 생성 (한쪽은 host, 한쪽은 pod netns 로)
ip link add "$host_veth" type veth peer "$pod_ifname" netns "$target_ns"
ip link set "$host_veth" mtu "$mtu"
ip link set "$host_veth" master "$bridge_name"
ip link set "$host_veth" up

# pod netns 내부 세팅
ip netns exec "$target_ns" ip link set lo up
ip netns exec "$target_ns" ip link set "$pod_ifname" up      # ← 먼저 UP
ip netns exec "$target_ns" ip addr add "$assigned_ip" dev "$pod_ifname"
ip netns exec "$target_ns" ip link set "$pod_ifname" mtu "$mtu"
ip netns exec "$target_ns" ip route add default via "$gw_ip" dev "$pod_ifname"
```

### 함정 ④: 멱등성 (Idempotency) 강박증

```bash
# ❌ 이렇게 묶어두면 망함
if ! ip link show "$br" >/dev/null 2>&1; then
  ip link add "$br" type bridge
  ip link set "$br" up                  # 브릿지가 존재하지만 down 일 때 실행 안 됨
  ip addr add "$ip/$prefix" dev "$br"   # IP 가 빠져있어도 실행 안 됨
fi
```

리눅스에서 "이미 켜진 인터페이스에 `up` 한 번 더" 는 에러 없다. "이미 있는 IP 또 추가" 는 에러 난다. 그래서 **존재 여부 / UP 여부 / IP 부여 여부 각각을 따로 체크**해야 한다. K8s 의 "원하는 상태(desired state)" 철학을 스크립트에도 이식하는 거.

### 함정 ⑤: `ip addr` 와 `ip route` 의 정반대 마스크 문법

```
┌─────────────────────────────────────────────────────────────┐
│  ip addr add 10.0.0.41/28 dev eth0    ← 마스크 필수         │
│                          ↑                                  │
│              "내 방 크기" → 같은 서브넷 친구 인식           │
├─────────────────────────────────────────────────────────────┤
│  ip addr add 10.0.0.41    dev eth0    ← 마스크 빠지면       │
│                       ↑                                     │
│              커널이 /32 로 처리 → 독방, 이웃 없음           │
│  → ip route add default via 10.0.0.33                       │
│    ❌ "Nexthop has invalid gateway"                         │
├─────────────────────────────────────────────────────────────┤
│  ip route add default via 10.0.0.33   ← 마스크 금지         │
│                          ↑                                  │
│              목적지는 한 점만 지정해야 함                   │
├─────────────────────────────────────────────────────────────┤
│  ip route add default via 10.0.0.33/28                      │
│  ❌ "any valid address is expected rather than ..."         │
└─────────────────────────────────────────────────────────────┘
```

`host-local` 이 JSON 으로 `address: "10.0.0.41/28"` 과 `gateway: "10.0.0.33"` 을 **이미 분리해서** 준다. 변수 두 개를 헷갈리지 않고 정확히 쓰는 게 전부.

### 함정 ⑥: `up` 을 `route add` 보다 먼저

```bash
ip netns exec $ns ip route add default via $gw   # ❌ 인터페이스 down 상태
ip netns exec $ns ip link set eth0 up
```

라우팅 테이블은 인터페이스가 UP 일 때만 추가 가능. 순서 바꾸면 안 된다.

---

## Step 3: 첫 번째 큰 산 — MTU 블랙홀

CNI 가 동작하니 Nginx 는 잘 떴다. 그런데 `netshoot`, `busybox` 같은 다른 이미지 풀할 때 죽음:

```
Failed to pull image "ghcr.io/nicolaka/netshoot:v0.15":
  net/http: TLS handshake timeout
```

호스트에서 직접 `curl https://ghcr.io` 는 잘 됨. 환장.

### 진단: PMTUD 실패

```bash
# DF (Don't Fragment) 플래그로 강제 측정
ping -M do -s 1472 8.8.8.8   # payload 1472 + header 28 = 1500 bytes
# → 응답 없음. 차단됨.

ping -M do -s 1352 8.8.8.8   # payload 1352 + header 28 = 1380 bytes
# → 성공. 즉 경로의 실효 MTU = 1380
```

이상한 점: `ip link show` 로 보면 Lima VM 의 lima0, eth0, 호스트 macOS 인터페이스 **전부 MTU 1500**. 그런데 왜 깎이지?

### 답: 가상화 자체가 보이지 않는 오버레이

```
   Pod 가 1500 bytes 짜리 TLS 인증서 패킷을 던짐
   ┌─────────────────────────────────────────────┐
   │ IP 20 │ TCP 20 │ TLS 데이터 1460 bytes      │  1500 bytes
   └─────────────────────────────────────────────┘
                  │
                  ↓ (Pod 내부, br0, lima0 다 MTU 1500 → 통과)
                  │
   ┌──────────────────────────────────────────┐
   │  Lima VM ←→ 하이퍼바이저 / macOS NAT     │   여기서 ~120 bytes
   │  보이지 않는 헤더 / 캡슐화 추가          │   추가됨
   └──────────────────────────────────────────┘
                  │
                  ↓  1500 > 실효 파이프 1380
                  ✗  드롭 🗑️
                  ↓
          TLS handshake timeout

   왜 TLS 만 망가졌나:
   - TCP SYN/SYN-ACK = 60 bytes   ✓ 통과
   - HTTP GET 헤더   = 작음        ✓ 통과
   - TLS Server Hello (인증서)    = 풀 페이로드  ✗
```

Nginx 이미지가 받아진 건 운. CDN 라우팅이 달랐거나, 인증서 체인이 짧았거나.

### 해결

```bash
# 1. 호스트 lima0 의 MTU 도 깎기 (containerd 이미지 풀이 이 경로 씀)
sudo ip link set lima0 mtu 1352

# 2. CNI conf 에 mtu 추가 → 스크립트가 br0/host-veth/pod-eth0 셋 다 1352 로 설정
"mtu": 1352
```

**참고**: 실측된 경로 MTU 는 1380 인데 conf 에는 1352 로 설정. 헤더 분 28 bytes 만큼 보수적으로 잡은 거 (= 페이로드 사이즈 그대로 인터페이스 MTU 로 박음). 1380 으로 해도 됐지만 1352 면 마진이 있어서 더 안전. 일관성을 위해 세 인터페이스 다 깎아야 — 한 쪽이 1500 이면 MSS 협상이 꼬임.

---

## Step 4: 두 번째 큰 산 — 멀티노드 BGP

이제 단일 노드는 완벽. 다른 노드 파드로 핑 쏘는 차례.

### 라우팅 부재의 비극

```bash
# Worker-2 의 파드에서:
ping 10.0.0.2   # Worker-1 의 파드
# → Network is unreachable
```

타임아웃이 아니라 **Unreachable**. 즉 패킷이 출발조차 못함. 이유는 명확:
- 파드의 라우팅 테이블에는 자기 `/28` 대역만 있음
- `10.0.0.2` 가 어디인지 모름
- 디폴트 게이트웨이도 없음
- 커널: "어디로 던질지 모르겠다. 폐기." 🗑️

→ `ip route add default via $gw_ip` 추가 (Step 2 에 이미 반영)

### FRR 로 BGP 띄우기

```bash
# 양쪽 노드에서
sudo apt install -y frr
sudo sed -i 's/bgpd=no/bgpd=yes/g' /etc/frr/daemons
sudo sed -i 's/zebra=no/zebra=yes/g' /etc/frr/daemons
sudo systemctl restart frr
```

Worker-1 (`192.168.105.3`) 의 `vtysh`:
```
router bgp 65000
 bgp router-id 192.168.105.3
 neighbor 192.168.105.4 remote-as 65000     # ← Worker-2
 address-family ipv4 unicast
  network 10.0.0.0/28                       # "내 뒤에 이 대역 있어!"
 exit-address-family
```

Worker-2 도 대칭으로 (서로 neighbor 로 가리키고, `10.0.0.32/28` 광고).

설정 직후 양쪽 노드 커널 라우팅 테이블:
```
$ ip route | grep bgp
10.0.0.32/28 nhid 28 via 192.168.105.4 dev lima0 proto bgp metric 20
```

`proto bgp` 가 보이면 BGP 가 커널에 경로를 주입한 것.

### 멀티노드 패킷 흐름 (완성형)

```
┌────────────────────────────────┐         ┌────────────────────────────────┐
│  Worker-1   (192.168.105.3)    │         │  Worker-2   (192.168.105.4)    │
│                                │         │                                │
│   ┌──────┐                     │         │                     ┌──────┐  │
│   │ Pod  │  10.0.0.2/28        │         │       10.0.0.36/28  │ Pod  │  │
│   └──┬───┘  default 10.0.0.1   │         │   default 10.0.0.33 └──┬───┘  │
│      │ eth0                    │         │                    eth0│      │
│ ─ ─ ─│─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ │         │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─│
│      │ veth pair               │         │             veth pair  │      │
│   ┌──┴─────┐                   │         │                   ┌────┴──┐   │
│   │veth-2  │                   │         │                   │veth-36│   │
│   └──┬─────┘                   │         │                   └────┬──┘   │
│      │ master                  │         │                  master│      │
│      ↓                         │         │                        ↓      │
│   ┌──────────┐                 │         │                ┌──────────┐   │
│   │   br0    │ 10.0.0.1/28     │         │     10.0.0.33/28│   br0   │   │
│   └────┬─────┘                 │         │                └────┬─────┘   │
│        │                       │         │                     │         │
│        │ 호스트 라우팅 테이블:  │         │                     │         │
│        │  10.0.0.32/28 via     │   ┌─────┘  10.0.0.0/28 via    │         │
│        │  192.168.105.4        │   │        192.168.105.3      │         │
│        │  proto bgp ←──────────┼───┤  (proto bgp) ─────────────┤         │
│        ↓                       │   │                            ↓        │
│   ┌──────────┐                 │   │                     ┌──────────┐    │
│   │  lima0   │ .105.3          │   │              .105.4 │  lima0   │    │
│   └────┬─────┘                 │   │                     └────┬─────┘    │
└────────┼───────────────────────┘   │                          │          │
         │                           │                          │          │
         └───────────────────────────┼──────────────────────────┘          │
                  ┌──────────────────┴──────────────────┐                  │
                  │  BGP peering over TCP 179           │                  │
                  │  네트워크 광고 교환                 │                  │
                  └─────────────────────────────────────┘                  │

                  물리 네트워크: 192.168.105.0/24 (lima shared)
```

### 그래도 안 되는 핑 — `tcpdump` 가 답

핑이 안 옴. 이번엔 **Timeout**.

```bash
# Worker-1 의 lima0
$ sudo tcpdump -ni lima0 icmp
IP 10.0.0.36 > 10.0.0.2:  ICMP echo request   ← Worker-2 의 파드가 보낸 거
IP 10.0.0.2  > 10.0.0.36: ICMP echo reply     ← Worker-1 의 파드가 응답!

# Worker-2 의 lima0
IP 10.0.0.36 > 10.0.0.2:  ICMP echo request   출발
IP 10.0.0.2  > 10.0.0.36: ICMP echo reply     응답 무사 도착
```

**충격**: 패킷은 이미 양쪽 노드를 왕복하고 있었다. BGP / 라우팅 / 방화벽 다 통과. 그런데 파드에는 안 닿음. → 마지막 1mm (lima0 → br0 → veth → 파드 netns) 어딘가에서 죽는다.

### 진짜 범인 — 스스로 자기 발등 찍기

`ip route get` 으로 커널 모의주행:
```
$ ip route get 10.0.0.38
10.0.0.38 via 192.168.105.1 dev lima0 src 192.168.105.4
```

발견. `10.0.0.38` 은 분명 br0 대역(`10.0.0.32/28`) 안의 파드인데, 커널이 br0 가 아니라 **외부 게이트웨이(`lima0` 의 `.105.1`)** 로 던지고 있다.

추적해보니, 디버깅하다 빡쳐서 `ip route del 10.0.0.32/28` 갈긴 게 있었음. **호스트의 로컬 라우팅을 삭제** 한 거. 그러면 커널은 "내 안방 대역 모름" 상태가 되어 디폴트 게이트웨이로 던져버린다.

해결: br0 IP 다시 정확한 마스크로 박고 (`ip addr add 10.0.0.33/28 dev br0`), 꼬인 라우팅/ARP 캐시 다 리셋, 파드 다 지우고 새로 띄움. **Clean slate**.

이게 통하니까 핑이 무사히 왕복. 🎉

---

## 회고: 결국 뭘 배웠나

### CNI 의 본질
- CNI 는 stdin/stdout 으로 통신하는 **실행 가능한 파일**. 그 이상도 이하도 아니다.
- 핵심 작업 4단계: ① IP 할당 ② veth pair 생성 ③ pod netns 안에 IP/route 박기 ④ 결과 JSON 회신
- 복잡한 건 다 하청. IPAM 은 `host-local` 에게, 라우팅 전파는 BGP 데몬에게.

### 리눅스 네트워크
- **L2 (veth ↔ br0) 와 L3 (default route) 는 완전히 별개.** veth 꽂았다고 통신 되는 게 아니다.
- `ip addr add` 와 `ip route add via` 의 마스크 규칙이 정반대. 이거 모르면 하루 날린다.
- 멱등성을 스크립트에 강제하려면 **모든 상태 변경을 독립된 조건문**으로 쪼개야 한다.

### 가상화 환경의 함정
- Lima/QEMU/Docker Desktop 위에서 K8s 돌리면 **보이지 않는 오버레이가 이미 끼어있다.** 인터페이스 MTU 가 1500 으로 떠도 실제 경로 MTU 는 더 좁을 수 있음.
- TLS handshake timeout 은 90% MTU 문제. `ping -M do -s` 로 검증.
- TCP 작은 패킷은 사는데 TLS 큰 패킷만 죽는 게 PMTUD 실패의 전형적 증상.

### BGP / 멀티노드
- 노드 간 파드 통신은 결국 **물리 라우터에게 "이 대역은 나한테 보내" 를 어떻게 알리느냐**의 문제.
- 방법 셋: 라우터 수동 설정 / BGP / Overlay (VXLAN). BGP 는 성능 최강, Overlay 는 호환성 최강.
- FRR 의 `bgpd` 와 `zebra` 둘 다 켜져야 커널 라우팅 테이블에 실제 주입.

### 운영 철학
- 디버깅의 최후 무기는 `tcpdump`. "안 된다" 가 아니라 "패킷이 어디서 죽는지" 를 물어라.
- `ip route get <IP>` 는 패킷이 어디로 보내질지 커널이 미리 답해주는 모의주행 도구. 라우팅 디버깅의 단축키.
- 꼬이면 고치지 말고 밀고 다시 깔아라 (**Immutable Infrastructure**). 디버깅 시간 > 재설치 시간 인 경우가 대부분.
- 화나서 `ip route del` 같은 거 갈기지 마라. 자기 발등 찍는다.

### 노드별 CIDR 설계 (보너스)
오늘은 `/28` 씩 잘게 쪼개서 했지만, 현업에서는 `/24` 씩 옥텟 단위로 큼직하게 끊는 게 정석. 이유는 **Route Summarization**:
- `/28` × 1000 노드 → 상단 라우터 TCAM 에 1000 개 경로. 노드 하나 죽을 때마다 BGP update 폭풍.
- `/24` × 1000 노드를 `/16` 으로 묶으면 → 외부 라우터는 1개 경로만 알면 됨.

---

## 알려진 한계

- **DEL 함수가 stub**. 파드 삭제 시 IPAM 장부 (`/var/lib/cni/networks/<name>/`) 가 정리 안 됨. 노드 하나당 16 개 (`/28`) 만 쓸 수 있으니, 파드 생성/삭제 반복하면 금방 IP 고갈. 다음에 고칠 일순위.
- **호스트 라우팅 자동화 X**. FRR / iptables FORWARD 설정은 수동. Calico 처럼 K8s API 와 연동하는 컨트롤 플레인은 없음.
- **단일 인터페이스 가정**. 멀티 인터페이스 / IPv6 / Network Policy 다 안 함.

이것들을 다 자동화하면? 그게 바로 Calico 다. 다음 글에서는 직접 짠 이 100 줄과 Calico 소스를 비교해볼 예정.

---

*하루 동안 욕하면서 굴렀던 결과물. 욕한 만큼 남는 게 있긴 하다.*
