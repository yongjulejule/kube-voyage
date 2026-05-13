#!/usr/bin/env bash

MACHINES=(
  "k8s-master"
  "k8s-worker-1"
  "k8s-worker-2"
)

# create vms


function create_vms() {
  for machine in "${MACHINES[@]}"; do
    echo "Creating VM: $machine"
    limactl create --name="$machine" --tty=false k8s-master.yml
  done
}

function start_vms() {
  for machine in "${MACHINES[@]}"; do
    echo "Starting VM: $machine"
    limactl start "$machine"
  done
}

function stop_vms() {
  for machine in "${MACHINES[@]}"; do
    echo "Stopping VM: $machine"
    limactl stop "$machine"
  done
}

function delete_vms() {
  for machine in "${MACHINES[@]}"; do
    echo "Deleting VM: $machine"
    limactl delete "$machine"
  done
}

function recreate_vms() {
  stop_vms
  delete_vms
  create_vms
  start_vms
}

function main() {
  case "$1" in
    create)
      create_vms
      ;;
    start)
      start_vms
      ;;
    stop)
      stop_vms
      ;;
    delete)
      delete_vms
      ;;
    recreate)
      recreate_vms
      ;;
    *)
      echo "Usage: $0 {create|start|stop|delete|recreate}"
      exit 1
      ;;
  esac
}

main $@
