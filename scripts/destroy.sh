#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBESPRAY_DIR="${ROOT_DIR}/kubespray"
INV_DIR="${KUBESPRAY_DIR}/inventory/mycluster"

echo "WARNING: this will destroy the Kubernetes cluster on all 6 VMs."
echo "VM themselves will NOT be deleted."
read -r -p "Type 'yes' to continue: " confirm
[[ "${confirm}" == "yes" ]] || exit 1

cd "${KUBESPRAY_DIR}"
ansible-playbook -i "${INV_DIR}/hosts.yml" reset.yml -b

echo "Cluster destroyed. VMs still running."