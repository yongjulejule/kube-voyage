#!/usr/bin/env bash

# Lima VM 정보로부터 Ansible inventory 생성
# 사용: ./scripts/generate-inventory.sh
set -euo pipefail
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT="${REPO_ROOT}/ansible/inventory.yml"
 
LIMA_USER_KEY="${HOME}/.lima/_config/user"
 
# Lima 가 만든 SSH key 가 존재하는지 확인
if [[ ! -f "${LIMA_USER_KEY}" ]]; then
  echo "ERROR: Lima SSH key not found at ${LIMA_USER_KEY}" >&2
  echo "Lima 가 처음 실행됐는지 확인하세요." >&2
  exit 1
fi
 
# VM 이름과 그룹 매핑 (필요시 수정)
MASTERS=(k8s-master)
WORKERS=(k8s-worker-1 k8s-worker-2)
 
# K8s 버전 (변경하려면 여기만 수정)
K8S_VERSION="${K8S_VERSION:-1.36}"
 
get_ssh_port() {
  local name="$1"
  limactl ls --json | jq -r "select(.name==\"${name}\") | .sshLocalPort"
}
 
check_running() {
  local name="$1"
  local status
  status=$(limactl ls --json | jq -r "select(.name==\"${name}\") | .status")
  if [[ "${status}" != "Running" ]]; then
    echo "ERROR: VM '${name}' is not running (status: ${status:-not found})" >&2
    exit 1
  fi
}
 
for vm in "${MASTERS[@]}" "${WORKERS[@]}"; do
  check_running "${vm}"
done
 
{
  cat <<EOF
all:
  vars:
    ansible_user: ${USER}
    ansible_ssh_private_key_file: ${LIMA_USER_KEY}
    ansible_python_interpreter: /usr/bin/python3
    kubernetes_version: "${K8S_VERSION}"
    pod_network_cidr: "10.244.0.0/16"
    service_cidr: "10.96.0.0/12"
  children:
    masters:
      hosts:
EOF
 
  for m in "${MASTERS[@]}"; do
    port=$(get_ssh_port "${m}")
    cat <<EOF
        ${m}:
          ansible_host: 127.0.0.1
          ansible_port: ${port}
EOF
  done
 
  cat <<EOF
    workers:
      hosts:
EOF
 
  for w in "${WORKERS[@]}"; do
    port=$(get_ssh_port "${w}")
    cat <<EOF
        ${w}:
          ansible_host: 127.0.0.1
          ansible_port: ${port}
EOF
  done
} > "${OUTPUT}"
 
echo "Generated ${OUTPUT} (k8s ${K8S_VERSION})"
