# TODO

## CNI / 인프라
- [ ] **DEL 함수 구현** — 현재 stub. 파드 삭제 시 host-local 장부(`/var/lib/cni/networks/<name>/`) 정리 안 됨. `/28` 이라 16개만 쓸 수 있는데 누수 누적되면 금방 IP 고갈.
- [ ] **shell script 코드 정리** — `my-cni.sh` 변수명/함수 분리/주석 정돈
- [ ] **my-cni conf 생성 자동화** — 노드별 subnet 만 다른데 수동으로 두 개 만들고 있음
- [ ] **CNI 배포 방식 고민** 
  - 현재: VM 들어가서 `/opt/cni/bin/` 에 직접 복사, `/etc/cni/net.d/` 에 conf 직접 넣음. 수정할 때마다 양쪽 노드 직접 들어가서 갈아치워야 함.
  - DaemonSet 으로 배포 (Flannel/Calico 방식)

## Ansible / 클러스터 프로비저닝
- [ ] **ansible 정상화** — 현재 동작 상태 점검 (CNI 깎느라 ansible 쪽 안 건드림)
- [ ] **ansible README 정리** — LLM 이 써서 너무 장황함. 간결하게 다시 쓰기.

## 문서
- [ ] **루트 README 작성** — 프로젝트 전체 소개 (현재는 `k8s-provision/README.md` 만 있고 그건 ansible 한정)
- [ ] bash cni 문서 손보기 

