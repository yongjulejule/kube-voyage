#!/usr/bin/env bash
# cni plugin written in bash
# copy to /opt/cni/bin/my-cni (should match filename with conf file)

set -euo pipefail
CNI_COMMAND=${CNI_COMMAND:-}
INPUT_TMP_FILE=$(mktemp)

function validation {
  if [[ -z ${CNI_COMMAND} ]]; then
    echo "CNI_COMMAND is not set"
    exit 1
  fi
}

# TODO
function validate_input_json {
  local input=$1
  # mtu, bridge, ips[0], ips[0].address, ips[0].gateway required
}

function print_to_stderr {
  echo $@ >&2
}

# spec ref: https://www.cni.dev/docs/spec/#add-success
function add {
  local target_ns_path=${CNI_NETNS}
  local target_ns=${CNI_NETNS##*/}
  local pod_ifname=${CNI_IFNAME}
  local input_config=$(cat)
  print_to_stderr $input_config
  local bridge_name=$(jq -r '.bridge' <<<${input_config})
  local mtu=$(jq -r '.mtu'<<<${input_config})
  local ipam_result=$(echo $input_config | /opt/cni/bin/host-local)
  print_to_stderr "IPAM Result: ${ipam_result}"
  local assigned_ip=$(jq -r '.ips[0].address' <<<${ipam_result})
  local gw_ip=$(jq -r '.ips[0].gateway' <<<${ipam_result})
  local prefix=${assigned_ip#*/}

  # setup bridge network on host machine
  if ! ip link show ${bridge_name} >/dev/null 2>&1; then
    ip link add ${bridge_name} type bridge
  fi
  ip link set ${bridge_name} up
  ip link set mtu ${mtu} dev ${bridge_name}
  if ! ip addr show ${bridge_name} | grep -q "${gw_ip}/${prefix}"; then
    ip addr add ${gw_ip}/${prefix} dev ${bridge_name}
  fi

  local raw_ip=${assigned_ip%/*}
  local host_veth_ifname=veth-${raw_ip##*.} # 랜덤보다 낫지 않을가?


  # network 연결 - 렌선만들어서 브릿지에 꼽기
  ip link add ${host_veth_ifname} type veth peer ${pod_ifname} netns ${target_ns}
  ip link set ${host_veth_ifname} mtu ${mtu} # lima 가상화 과정에 발생한 mtu 크기로 인한 tls timeout 이슈 해결 
  ip link set ${host_veth_ifname} master ${bridge_name}
  ip link set ${host_veth_ifname} up

  ip netns exec ${target_ns} ip link set lo up
  ip netns exec ${target_ns} ip link set ${pod_ifname} up
  ip netns exec ${target_ns} ip addr add ${assigned_ip} dev ${pod_ifname}
  ip netns exec ${target_ns} ip link set ${pod_ifname} mtu ${mtu} # lima 가상화 과정에 발생한 mtu 크기로 인한 tls timeout 이슈 해결 
  ip netns exec ${target_ns} ip route add default via ${gw_ip} dev ${pod_ifname} # pod netns 에 게이트웨이로 가는 길 알려주는 라우팅 테이블 추가(up 을 먼저 하고 해야함)


  local assigned_mac=$(ip netns exec ${target_ns} ip addr show dev ${pod_ifname} | grep link/ether | awk '{ print $2 }')

  jq -n --arg mac "$assigned_mac" --arg ip "$assigned_ip" '{
    cniVersion: "0.3.1",
    interfaces: [
        { "name": "eth0", "mac": $mac }
    ],
    ips: [
        {
            "version": "4",
            "address": $ip,
            "interface": 0
        }
    ]
  }'
}

# ref: https://www.cni.dev/docs/spec/#del-remove-container-from-network-or-un-apply-modifications
# CNI_NETNS 에 있는 CNI_IFNAME 인터페이스를 날려야함 + ADD 에서 한 모든 변경사항을 undo 해야함 . lifo 로..
function del {
  local target_ns_path=${CNI_NETNS}
  local target_ns=${CNI_NETNS##*/}
  local pod_ifname=${CNI_IFNAME}

  # 네트워크 네임스페이스, veth 삭제
  if [ -n "${target_ns_path}" ] && [ -f "${target_ns_path}" ]; then
    ip netns exec ${target_ns} ip link del ${pod_ifname} 2>/dev/null || true

    # -----------------------------------------------------------------------
    # 이후 커널이 해주는것:
    # 1. 파드 IP 삭제: ip netns exec ${target_ns} ip addr del <pod-ip> dev eth0
    # 2. 라우팅 테이블 삭제: ip netns exec ${target_ns} ip route del default via <gw>
    # 3. 호스트 veth 반대편 삭제: ip link del veth-XXX
    # 4. 브릿지 포트 뽑음: ip link set veth-XXX nomaster
    # 5. 브릿지 FDB(MAC 주소록) 갱신: bridge fdb del <파드_MAC> dev veth-XXX master br0
    # -----------------------------------------------------------------------
  fi

  # IPAM 자원 반납 
  export CNI_COMMAND=DEL
  cat | /opt/cni/bin/host-local >/dev/null 2>&1

  echo "{}"
  exit 0
}

function version { 
  echo "CNI version v1.0.0-mola" >&2
}

function main {
  validation
  case "$CNI_COMMAND" in
    "ADD")
      add
      ;;
    "DEL")
      del
      ;;
    "VERSION")
      version
      ;;
    *)
      echo "Unsupported CNI_COMMAND: $CNI_COMMAND"
      exit 1
      ;;
  esac
  exit 0
}

main
