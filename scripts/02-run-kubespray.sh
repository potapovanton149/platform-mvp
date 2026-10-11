cat > ~/platform-mvp/scripts/02-run-kubespray.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBESPRAY_DIR="${ROOT_DIR}/kubespray"
INV_DIR="${KUBESPRAY_DIR}/inventory/mycluster"
ANSIBLE_DIR="${ROOT_DIR}/ansible"
CFG_DIR="${ROOT_DIR}/kubespray-config"
KUBESPRAY_VENV="${KUBESPRAY_VENV:-$HOME/.venv/kubespray}"

echo "==> Checking inventory..."
if [[ ! -f "${ANSIBLE_DIR}/inventory/prod.yml" ]]; then
  echo "ERROR: ansible/inventory/prod.yml not found"
  exit 1
fi

if [[ ! -d "${KUBESPRAY_DIR}" ]]; then
  echo "ERROR: kubespray submodule not initialized. Run:"
  echo "  git submodule update --init --recursive"
  exit 1
fi

if [[ ! -x "${KUBESPRAY_VENV}/bin/ansible-playbook" ]]; then
  echo "ERROR: Kubespray venv not found at ${KUBESPRAY_VENV}"
  exit 1
fi

KUBESPRAY_ANSIBLE="${KUBESPRAY_VENV}/bin/ansible-playbook"

echo "==> Using Ansible: $(${KUBESPRAY_VENV}/bin/ansible --version | head -1)"

echo "==> Preparing Kubespray inventory..."
mkdir -p "${INV_DIR}/group_vars/k8s_cluster"
cp -f "${ANSIBLE_DIR}/inventory/kubespray.yml" "${INV_DIR}/hosts.yml"
cp -f "${CFG_DIR}/group_vars/k8s_cluster/"*.yml "${INV_DIR}/group_vars/k8s_cluster/"

echo "==> Running Kubespray (this will take 15-30 minutes)..."
cd "${KUBESPRAY_DIR}"
ANSIBLE_FORKS=2 \
ANSIBLE_SSH_ARGS='-o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=10' \
"${KUBESPRAY_ANSIBLE}" -i "${INV_DIR}/hosts.yml" cluster.yml -b

echo "==> Fetching kubeconfig from cp-1..."
mkdir -p ~/.kube
ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no devops@192.168.190.147 \
  "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config
sed -i -E 's#https://(127\.0\.0\.1|192\.168\.190\.147|192\.168\.75\.100):6443#https://192.168.190.100:6443#' ~/.kube/config
chmod 600 ~/.kube/config

echo "==> kubeconfig server:"
grep server ~/.kube/config

# ============================================================
# Kubespray v2.26.0 workarounds
# ============================================================
echo "==> Patching cilium-config (kube-proxy-replacement + k8s-service-host)..."
export KUBECONFIG=$HOME/.kube/config
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"kube-proxy-replacement":"false","k8s-service-host":"192.168.190.100","k8s-service-port":"6443"}}' 2>/dev/null || true
kubectl -n kube-system rollout restart ds/cilium 2>/dev/null || true
kubectl -n kube-system rollout restart deploy/cilium-operator 2>/dev/null || true

echo "==> Waiting for cilium to become ready (up to 3 min)..."
for i in $(seq 1 36); do
  READY=$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  DESIRED=$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  if [[ "$READY" == "$DESIRED" && "$DESIRED" != "0" ]]; then
    echo "==> cilium ready: ${READY}/${DESIRED}"
    break
  fi
  sleep 5
done

echo "==> Done. kubeconfig at ~/.kube/config"
kubectl get nodes || true
EOF

chmod +x ~/platform-mvp/scripts/02-run-kubespray.sh