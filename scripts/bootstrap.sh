#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}/ansible"

if [[ ! -f inventory/prod.yml ]]; then
  echo "ERROR: ansible/inventory/prod.yml not found"
  exit 1
fi

echo "==> [1/5] Installing Ansible collections"
ansible-galaxy collection install -r requirements.yml

echo "==> [2/5] Preparing OS on all nodes"
ansible-playbook playbooks/01-prepare.yml

echo "==> [3/5] Running Kubespray"
"${ROOT_DIR}/scripts/02-run-kubespray.sh"

echo "==> [4/5] Post-Kubespray (kubeconfig + labels)"
ansible-playbook playbooks/03-post-kubespray.yml

echo "==> [5/5] Bootstrapping ArgoCD"
ansible-playbook playbooks/04-argocd.yml

echo ""
echo "============================================================"
echo " PLATFORM READY"
echo "============================================================"
echo " ArgoCD:"
echo "   kubectl -n argocd port-forward svc/argo-cd-server 8080:80"
echo "   open http://localhost:8080"
echo "   user: admin"
echo "   pass: $(bash ${ROOT_DIR}/scripts/get-argocd-password.sh)"
echo ""
echo " Next: commit your k8s/apps/* to Git, ArgoCD will pick them up."
echo "============================================================"