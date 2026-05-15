# my-cni BGP 셋업

- my-cni 는 서로 다른 노드에 있는 파드간 통신을 위해 BGP 를 활용
- 각 노드에서 직접 커멘드 실행함 - ansible 로 자동화 or daemonset cni 생성 시 반영 가능할듯?

## 셋업 

```bash
# 1. FRR 설치
sudo apt-get update && sudo apt-get install -y frr

# 2. BGP 데몬 켜기 (bgpd=no 를 yes 로 변경)
sudo sed -i 's/bgpd=no/bgpd=yes/g' /etc/frr/daemons

# 3. FRR 서비스 재시작 (적용)
sudo systemctl restart frr
sudo systemctl enable frr
```

설치 후 vtysh 콘솔 접속 
`sudo vtysh`

```
# 설정 모드 진입
configure terminal

# BGP 프로세스 시작 (65000은 사설 AS 번호, 양쪽 동일하게 맞춤 - iBGP)
router bgp 65000

# 내 ip 설정
bgp router-id 192.168.105.3

# 옆집 ip 등록
neighbor 192.168.105.4 remote-as 65000

# 내 네트워크 넴스페이스 대역 advertise
address-family ipv4 unicast
  network 10.0.16.0/28
exit-address-family

exit
exit
write memory

```

## 확인

`sudo vtysh -c "show ip bgp summary"`

`ip route`
