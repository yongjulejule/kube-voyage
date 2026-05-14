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
  local subnet=${assigned_ip#*/}

  # setup bridge network on host machine
  if ! ip link show ${bridge_name} >/dev/null 2>&1; then
    ip link add ${bridge_name} type bridge
  fi
  ip link set ${bridge_name} up
  ip link set mtu ${mtu} dev ${bridge_name}
  if ! ip addr show ${bridge_name} | grep -q "${gw_ip}/${subnet}"; then
    ip addr add ${gw_ip}/${subnet} dev ${bridge_name}
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

function del {
  echo "DEL command received, no action taken" >&2
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
