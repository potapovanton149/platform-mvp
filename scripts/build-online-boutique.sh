#!/usr/bin/env bash
set -euo pipefail

# ===== НАСТРОЙКИ =====
HARBOR="${HARBOR:-harbor.platform-mvp-potapov.ru/online-boutique}"
TAG="${TAG:-v1.0.0}"
REPO_URL="${REPO_URL:-https://github.com/potapovanton149/online-boutique.git}"
BRANCH="${BRANCH:-master}"
NS="${NS:-ci}"
KANIKO_IMAGE="${KANIKO_IMAGE:-gcr.io/kaniko-project/executor:v1.23.2-debug}"
LOG="${LOG:-/tmp/ob-build-$(date +%Y%m%d-%H%M%S).log}"

# 11 сервисов + пути в репо (относительно корня репо)
declare -A SVC=(
  [frontend]="src/frontend"
  [cartservice]="src/cartservice/src"
  [productcatalogservice]="src/productcatalogservice"
  [currencyservice]="src/currencyservice"
  [paymentservice]="src/paymentservice"
  [shippingservice]="src/shippingservice"
  [emailservice]="src/emailservice"
  [checkoutservice]="src/checkoutservice"
  [recommendationservice]="src/recommendationservice"
  [adservice]="src/adservice"
  [loadgenerator]="src/loadgenerator"
)

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ===== Preflight =====
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v git    >/dev/null || { echo "git not found";    exit 1; }
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

if ! kubectl -n "$NS" get secret harbor-creds >/dev/null 2>&1; then
  cat <<EOF
!!! Секрет $NS/harbor-creds не найден. Создай:
    kubectl -n $NS create secret docker-registry harbor-creds \\
      --docker-server=harbor.platform-mvp-potapov.ru \\
      --docker-username=admin \\
      --docker-password='Harbor12345'
EOF
  exit 1
fi

log ">>> [1/3] PVC ob-src (Longhorn, RWO, 2Gi)"
kubectl -n "$NS" delete pod ob-clone --ignore-not-found >/dev/null 2>&1 || true
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ob-src
  namespace: ci
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
EOF

log ">>> [2/3] Клон репозитория в PVC (pod ob-clone)"
kubectl -n "$NS" delete pod ob-clone --ignore-not-found >/dev/null 2>&1 || true
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ob-clone
  namespace: ci
spec:
  restartPolicy: Never
  containers:
  - name: clone
    image: alpine/git:2.45.2
    env:
    - {name: BRANCH,   value: "master"}
    - {name: REPO_URL, value: "https://github.com/potapovanton149/online-boutique.git"}
    command:
    - /bin/sh
    - -c
    - |
      set -e
      rm -rf /src/repo
      git clone --depth 1 -b "$BRANCH" "$REPO_URL" /src/repo
      echo "cloned: $(ls /src/repo | head)"
    volumeMounts:
    - {name: src, mountPath: /src}
  volumes:
  - name: src
    persistentVolumeClaim:
      claimName: ob-src
EOF

log "    Ждём завершения клона (Succeeded)..."
if ! kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/ob-clone --timeout=600s 2>/dev/null; then
  kubectl -n "$NS" logs ob-clone || true
  kubectl -n "$NS" describe pod ob-clone | tail -30
  log "!!! Клон не удался. Прерываю."
  exit 1
fi
kubectl -n "$NS" delete pod ob-clone --ignore-not-found >/dev/null

log ">>> [3/3] Kaniko: последовательная сборка 11 сервисов"
FAILED=()
for svc in frontend cartservice productcatalogservice currencyservice \
           paymentservice shippingservice emailservice checkoutservice \
           recommendationservice adservice loadgenerator; do
  ctx="${SVC[$svc]}"
  pod="kaniko-${svc}"
  log "  → kaniko-$svc (ctx=$ctx)"
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
  - name: kaniko
    image: ${KANIKO_IMAGE}
    args:
    - "--context=dir:///src/repo/${ctx}"
    - "--dockerfile=/src/repo/${ctx}/Dockerfile"
    - "--destination=${HARBOR}/${svc}:${TAG}"
    - "--cache=false"
    volumeMounts:
    - {name: src, mountPath: /src}
    - {name: docker-config, mountPath: /kaniko/.docker}
    resources:
      requests: {cpu: "500m", memory: "1Gi"}
      limits:   {cpu: "2",    memory: "4Gi"}
  volumes:
  - name: src
    persistentVolumeClaim:
      claimName: ob-src
  - name: docker-config
    secret:
      secretName: harbor-creds
      items:
      - {key: .dockerconfigjson, path: config.json}
EOF

  if kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$pod" --timeout=1800s 2>/dev/null; then
    log "    ✓ $svc"
  else
    log "    ✗ $svc — см. лог пода"
    kubectl -n "$NS" logs "$pod" 2>&1 | tail -40 | tee -a "$LOG" || true
    FAILED+=("$svc")
  fi
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
done

log ">>> Итог"
log "  Успешно: $(( ${#SVC[@]} - ${#FAILED[@]} ))/11"
if [ ${#FAILED[@]} -gt 0 ]; then
  log "  Провалились: ${FAILED[*]}"
  exit 2
fi
log "  Все образы: ${HARBOR}/<svc>:${TAG}"
log "  Лог: $LOG"