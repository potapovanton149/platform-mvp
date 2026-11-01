# Troubleshooting — грабли проекта и их решения

Каждая запись: **симптом → причина → фикс**. Все команды готовы к copy-paste.
Записи сгруппированы по компонентам в порядке появления при развёртывании.

- [Cilium](#cilium)
- [Longhorn](#longhorn)
- [ArgoCD](#argocd)
- [cert-manager](#cert-manager)
- [Prometheus / kube-prometheus-stack](#prometheus--kube-prometheus-stack)
- [Vault](#vault)
- [Harbor](#harbor)
- [GitLab / Runner](#gitlab--runner)
- [Online Boutique](#online-boutique)
- [Прочее](#прочее)

---

## Cilium

### Cilium в CrashLoopBackOff: `Invalid value for --kube-proxy-replacement: False`

**Симптом**

```bash
kubectl -n kube-system get pods -l k8s-app=cilium
# cilium-xxxxx   0/1   CrashLoopBackOff
```

```bash
kubectl -n kube-system logs ds/cilium --tail=20
# level=fatal msg="Invalid value for --kube-proxy-replacement: False"
```

**Причина**

Kubespray v2.26.0 рендерит в ConfigMap `cilium-config` значение
`kube-proxy-replacement: "False"` (Python-строка с заглавной буквы). Cilium
v1.16.1 парсит это поле как Go-строку и принимает только `"true"` / `"false"`
в нижнем регистре. `"False"` → fatal.

**Фикс**

```bash
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"kube-proxy-replacement":"false"}}'

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout restart deploy/cilium-operator

kubectl -n kube-system rollout status ds/cilium --timeout=180s
```

Этот патч уже автоматизирован в
[`scripts/02-run-kubespray.sh`](../scripts/02-run-kubespray.sh) (шаг «Kubespray
v2.26.0 workarounds»). Дополнительно там выставляются `k8s-service-host` и
`k8s-service-port` — без них Cilium не может достучаться до API-сервера через
VIP.

**Профилактика**

В [`kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml`](../kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml)
явно задано:

```yaml
kube_proxy_remove: false
cilium_kube_proxy_replacement: false
```

То есть kube-proxy (IPVS) остаётся основным, Cilium не пытается его заменить.

---

### Cilium не видит API-сервер после смены VIP

**Симптом**

Поды cilium в `Running`, но `kubectl get nodes` возвращает
`Unable to connect to the server`.

**Причина**

В `cilium-config` остался старый `k8s-service-host` (например, IP конкретной
ноды вместо VIP).

**Фикс**

```bash
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"k8s-service-host":"192.168.190.100","k8s-service-port":"6443"}}'
kubectl -n kube-system rollout restart ds/cilium
```

---

## Longhorn

### Каскадное удаление всех томов через ArgoCD

**Симптом**

После `kubectl -n argocd delete application longhorn` (или неудачного sync с
`prune: true`) пропали все PVC, данные потеряны.

**Причина**

Application `longhorn` имеет `finalizers: resources-finalizer.argocd.argoproj.io`
и `syncPolicy.automated.prune: true`. При удалении Application ArgoCD удаляет
все ресурсы, которыми управляет, включая `PersistentVolume` и
`PersistentVolumeClaim`. Longhorn, увидев удаление PV, удаляет и бэкенд-реплики.

**Фикс (восстановление)**

```bash
# 1. Немедленно остановить ArgoCD, чтобы он не удалил остатки
kubectl -n argocd scale deploy argo-cd-argocd-applicationset-controller --replicas=0
kubectl -n argocd scale sts argo-cd-argocd-application-controller --replicas=0

# 2. Проверить, что осталось
kubectl -n longhorn-system get volumes.longhorn.io
kubectl get pv

# 3. Если PV остались в Released — вернуть в Bound
kubectl patch pv <pv-name> -p '{"spec":{"claimRef":null}}'

# 4. Пересоздать PVC из манифестов (ArgoCD)
kubectl -n argocd scale sts argo-cd-argocd-application-controller --replicas=1
```

**Профилактика**

Для stateful-компонентов (Longhorn, Prometheus, Loki, Tempo, Harbor, GitLab)
**не удалять Application**, а отключать auto-sync:

```bash
kubectl -n argocd patch application longhorn --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Или использовать `Prune=false` на конкретных ресурсах:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

---

### Version mismatch: `longhorn-manager v1.6.2` / `instance-manager v1.7.2`

**Симптом**

```bash
kubectl -n longhorn-system get pods
# instance-manager-xxx   0/1   CrashLoopBackOff
```

```bash
kubectl -n longhorn-system logs instance-manager-xxx --tail=20
# failed to get engine: version mismatch
```

Longhorn UI показывает `Degraded` на томах.

**Причина**

При обновлении чарта Longhorn старые `instance-manager`-поды (v1.6.2) не были
пересозданы, а `longhorn-manager` уже v1.7.2. Instance-manager запускается как
процесс внутри `longhorn-manager`-пода, но кэшируется в отдельном поде.

**Фикс**

```bash
# 1. Удалить все instance-manager поды — они пересоздадутся
kubectl -n longhorn-system delete pods -l longhorn.io/component=instance-manager

# 2. Если не помогло — перезапустить longhorn-manager
kubectl -n longhorn-system rollout restart ds longhorn-manager

# 3. Дождаться
kubectl -n longhorn-system rollout status ds longhorn-manager --timeout=300s

# 4. Проверить версии
kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

**Профилактика**

В [`k8s/values/longhorn.yaml`](../k8s/values/longhorn.yaml) отключены
pre-upgrade проверки, которые сами по себе могут блокировать обновление:

```yaml
preUpgradeChecker:
  jobEnabled: false
  upgradeVersionCheck: false
```

---

### 1 orphan volume

**Симптом**

```bash
kubectl -n longhorn-system get volumes.longhorn.io
# 14 healthy, 1 detached/faulted
```

**Причина**

Остаток от каскадного удаления (см. выше): PV удалён, а CRD `Volume` остался.

**Фикс**

```bash
# Найти orphan
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness

# Удалить (только если точно не используется!)
kubectl -n longhorn-system delete volumes.longhorn.io <volume-name>
```

**Статус:** не критично, зафиксировано в
[known-limitations.md](known-limitations.md).

---

### PVC в `Pending`: `no nodes available`

**Симптом**

```bash
kubectl -n monitoring get pvc
# storage-longhorn-xxx   Pending
```

```bash
kubectl -n longhorn-system logs ds/longhorn-manager | grep -i 'no node'
```

**Причина**

Нет нод с меткой `storage=true` или на нодах закончилось место
(`storageMinimalAvailablePercentage: 10`).

**Фикс**

```bash
# Проверить метки
kubectl get nodes -L storage

# Навесить метку
kubectl label node worker-2 storage=true --overwrite

# Проверить место
kubectl -n longhorn-system get nodes.longhorn.io
```

---

## ArgoCD

### Root App с `recurse: true` применяет манифесты приложения в namespace `argocd`

**Симптом**

```bash
kubectl -n argocd get pods
# frontend-xxx, cartservice-xxx, redis-cart-xxx — в namespace argocd!
```

Приложение Online Boutique разворачивается не туда.

**Причина**

В [`k8s/bootstrap/root-app.yaml`](../k8s/bootstrap/root-app.yaml) стояло
`directory.recurse: true`. ArgoCD обходил `k8s/apps/` рекурсивно, находил
`k8s/apps/online-boutique/*.yaml` и применял их в namespace назначения root-app
(`argocd`).

**Фикс**

```yaml
spec:
  source:
    path: k8s/apps
    directory:
      recurse: false      # ← обязательно
```

Применить:

```bash
kubectl apply -f k8s/bootstrap/root-app.yaml
kubectl -n argocd delete pods -l app=frontend
kubectl -n argocd delete pods -l app=cartservice
# и остальные, попавшие не туда
```

---

### `SharedResourceWarning` на Namespace

**Симптом**

```bash
kubectl -n argocd get application monitoring -o yaml | grep -A3 conditions
# SharedResourceWarning: Namespace/monitoring is already managed by another Application
```

Application в статусе `Healthy`, но с warning.

**Причина**

Два Application владеют одним Namespace: `namespaces` (создаёт) и, например,
`kube-prometheus-stack` (с `CreateNamespace=true`).

**Фикс**

Убрать `CreateNamespace=true` у всех Application, кроме `namespaces`:

```yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=false
```

Уже сделано для `online-boutique`, `platform-certs`, `platform-alerts`. Для
остальных `CreateNamespace=true` оставлен осознанно — он идемпотентен и не
ломает работу, warning косметический.

Альтернатива — добавить аннотацию владельца:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

---

### `repo-server` падает с `i/o timeout` при обращении к GitHub

**Симптом**

```bash
kubectl -n argocd logs deploy/argo-cd-argocd-repo-server --tail=30
# failed to list refs: ... dial tcp ...: i/o timeout
```

Application в статусе `Unknown` / `ComparisonError`.

**Причина**

Медленное или нестабильное соединение с GitHub (типично для РФ). Дефолтный
таймаут ArgoCD — 15 секунд.

**Фикс**

```bash
kubectl -n argocd patch cm argocd-cm --type merge -p '{
  "data": {
    "timeout.reconciliation": "180s",
    "timeout.reconciliation.jitter": "60s"
  }
}'

kubectl -n argocd set env deploy/argo-cd-argocd-repo-server \
  ARGOCD_GIT_REQUEST_TIMEOUT=120s

kubectl -n argocd rollout restart deploy/argo-cd-argocd-repo-server
```

Если проблема постоянная — перейти на SSH-доступ к GitHub с deploy key вместо
HTTPS.

---

### Application вечно `OutOfSync` из-за `volumeClaimTemplates`

**Симптом**

```bash
kubectl -n argocd get application kube-prometheus-stack
# OutOfSync   Healthy
```

Diff показывает изменения в `spec.volumeClaimTemplates`.

**Причина**

Kubernetes не позволяет изменять `volumeClaimTemplates` у существующего
StatefulSet. Helm-чарт рендерит одно, API хранит другое (добавляет
`apiVersion`, `kind`, `status`). ArgoCD видит расхождение и пытается его
устранить — бесконечно.

**Фикс**

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: StatefulSet
      jqPathExpressions:
        - .spec.persistentVolumeClaimRetentionPolicy
        - .spec.volumeClaimTemplates
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
```

Уже применено в `21-kube-prometheus-stack.yaml`, `22-loki.yaml`,
`23-tempo.yaml`, `60-online-boutique.yaml`.

---

### `ServerSideApply` нужен, но не включён: `metadata.annotations: Too long`

**Симптом**

```bash
kubectl -n argocd get application cert-manager
# SyncError: CustomResourceDefinition ... metadata.annotations: Too long:
# must be less than 262144 bytes
```

**Причина**

CRD cert-manager/Longhorn/Prometheus-Operator больше лимита client-side apply
(262144 байта на аннотацию `kubectl.kubernetes.io/last-applied-configuration`).

**Фикс**

```yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true
```

Уже включено для ingress-nginx, cert-manager, longhorn, monitoring, loki, tempo,
otel-collector, vault.

---

## cert-manager

### Certificate в `Pending`: `secret "cloudflare-api-token" not found`

**Симптом**

```bash
kubectl get certificate -A
# grafana-tls   False   Pending
```

```bash
kubectl -n cert-manager describe certificaterequest -A | tail -20
# Error: secret "cloudflare-api-token" not found
```

**Причина**

Две возможные причины:

1. ExternalSecret ещё не синхронизировался (Vault пуст или ESO не запущен).
2. **Несовпадение имени ключа**: ClusterIssuer ссылается на ключ `api-token`,
   а ExternalSecret создаёт `cloudflare_api_token` (или наоборот).

**Фикс**

Проверить, какой ключ ждёт ClusterIssuer:

```bash
kubectl get clusterissuer letsencrypt-staging -o yaml | grep -A5 cloudflare
# apiTokenSecretRef:
#   name: cloudflare-api-token
#   key: api-token          ← вот это
```

Проверить, что реально в Secret:

```bash
kubectl -n cert-manager get secret cloudflare-api-token -o jsonpath='{.data}' | jq 'keys'
```

Привести в соответствие. В проекте намеренно два разных ExternalSecret:

| Namespace | Secret | Ключ | Кто потребляет |
|---|---|---|---|
| `cert-manager` | `cloudflare-api-token` | `api-token` | ClusterIssuer |
| `external-dns` | `cloudflare-api-token` | `cloudflare_api_token` | external-dns chart |

Файлы:
[`k8s/manifests/external-secrets/cloudflare-api-token-certmanager.yaml`](../k8s/manifests/external-secrets/cloudflare-api-token-certmanager.yaml),
[`k8s/manifests/external-secrets/cloudflare-api-token-externaldns.yaml`](../k8s/manifests/external-secrets/cloudflare-api-token-externaldns.yaml).

Принудительная синхронизация:

```bash
kubectl -n cert-manager annotate externalsecret cloudflare-api-token \
  force-sync=$(date +%s) --overwrite
kubectl -n cert-manager delete certificaterequest --all
```

---

### DNS-01 challenge зависает в `pending`

**Симптом**

```bash
kubectl -n cert-manager get challenge
# xxx   pending
```

```bash
kubectl -n cert-manager describe challenge xxx | tail -20
# Waiting for DNS-01 challenge propagation: DNS record not yet propagated
```

**Причина**

cert-manager использует локальный CoreDNS для проверки TXT-записи, а CoreDNS
кэширует отрицательный ответ.

**Фикс**

В [`k8s/values/cert-manager.yaml`](../k8s/values/cert-manager.yaml) уже задано:

```yaml
extraArgs:
  - --dns01-recursive-nameservers-only
  - --dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53
```

Если всё равно висит:

```bash
# Проверить TXT-запись вручную
dig +short TXT _acme-challenge.grafana.platform-mvp-potapov.ru @1.1.1.1

# Удалить challenge и дать пересоздать
kubectl -n cert-manager delete challenge --all
kubectl -n cert-manager delete certificaterequest --all
```

---

### Let's Encrypt rate limit

**Симптом**

```bash
kubectl -n cert-manager describe certificaterequest xxx | tail
# too many failed authorizations recently
```

**Причина**

Production CA блокирует на 1 неделю после 5 неудачных валидаций в час.

**Фикс**

Проект использует `letsencrypt-staging` — лимитов нет. Если всё же попали:

```bash
# Переключить все ingress на staging
kubectl get ingress -A -o json | jq -r '
  .items[] | select(.metadata.annotations["cert-manager.io/cluster-issuer"]=="letsencrypt-prod")
  | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
  kubectl -n "$ns" annotate ingress "$name" \
    cert-manager.io/cluster-issuer=letsencrypt-staging --overwrite
done
```

---

## Prometheus / kube-prometheus-stack

### Опечатка `ReadWrilivenessProbeteOnce` вместо `ReadWriteOnce`

**Симптом**

```bash
kubectl -n monitoring get pvc
# prometheus-kube-prometheus-stack-prometheus-db-...   Pending
```

```bash
kubectl -n monitoring describe pvc prometheus-... | tail
# spec.accessModes: Unsupported value: "ReadWrilivenessProbeteOnce"
```

**Причина**

Опечатка при ручном редактировании values: `ReadWrilivenessProbeteOnce` —
склейка `ReadWriteOnce` и `livenessProbe`.

**Фикс**

```yaml
# k8s/values/kube-prometheus-stack.yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          accessModes: ["ReadWriteOnce"]     # ← правильно
          resources:
            requests:
              storage: 10Gi
```

```bash
kubectl -n monitoring delete pvc prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
kubectl -n argocd annotate application kube-prometheus-stack \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

### `kubeProxy: false` — нет метрик kube-proxy

**Симптом**

```bash
# В Prometheus targets
# kube-proxy   down
```

```bash
kubectl -n kube-system get pods -l k8s-app=kube-proxy
# Running, но :10249 не слушается
```

**Причина**

kube-proxy в режиме IPVS не поднимает HTTP-эндпоинт метрик на `:10249` по
умолчанию (в отличие от iptables-режима). Плюс в проекте
`cilium_kube_proxy_replacement: false`, но kube-proxy всё равно не отдаёт
метрики.

**Фикс**

Правило kube-proxy отключено в values:

```yaml
# k8s/values/kube-prometheus-stack.yaml
defaultRules:
  rules:
    kubeProxy: false
```

Это осознанно: алерт `KubeProxyDown` был бы вечным `firing`. Метрики
kube-proxy не критичны — сеть мониторится через Cilium и node-exporter.

Если метрики нужны — включить в kube-proxy:

```bash
kubectl -n kube-system get cm kube-proxy -o yaml | grep metricsBindAddress
# metricsBindAddress: ""
kubectl -n kube-system patch cm kube-proxy --type merge \
  -p '{"data":{"config.conf":"...metricsBindAddress: 0.0.0.0:10249..."}}'
kubectl -n kube-system rollout restart ds kube-proxy
```

---

### ServiceMonitor не скрейпит gRPC-порты

**Симптом**

В Prometheus targets поды Online Boutique `down` с ошибкой
`Get "http://...:5050/metrics": EOF`.

**Причина**

ServiceMonitor создан на порт `grpc` (5050), но gRPC-порт не отдаёт
HTTP `/metrics`. Метрики сервисов отдаются либо на отдельном HTTP-порту, либо
через OTel Collector.

**Фикс**

Не создавать ServiceMonitor на gRPC-порты. В проекте метрики Online Boutique
идут двумя путями:

1. Pod-аннотации `prometheus.io/scrape: "true"` + `prometheus.io/port` — но
   только для сервисов, реально отдающих `/metrics` (frontend :8080).
2. OTel Collector: приложение отправляет OTLP-метрики на
   `otel-collector.tracing.svc:4317`, коллектор экспортирует их на `:8889`,
   откуда их скрейпит Prometheus через ServiceMonitor `otel-collector`.

Проверка:

```bash
kubectl -n tracing get servicemonitor otel-collector -o yaml | grep -A5 endpoints
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets → otel-collector
```

---

### Prometheus OOMKilled

**Симптом**

```bash
kubectl -n monitoring get pods | grep prometheus
# prometheus-...   0/1   OOMKilled
```

**Причина**

Лимит памяти 2 Gi, retention 5d/4GB, но при большом количестве series
(все ServiceMonitor'ы + pod annotations) память уходит.

**Фикс**

```yaml
prometheus:
  prometheusSpec:
    resources:
      limits:
        memory: 3Gi        # было 2Gi
    retention: 3d          # было 5d
    retentionSize: 3GB
```

```bash
kubectl -n argocd annotate application kube-prometheus-stack \
  argocd.argoproj.io/refresh=hard --overwrite
```

Диагностика:

```bash
kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'
```

---

## Vault

### Ingress paths: chart 0.28.1 не поддерживает map

**Симптом**

```bash
helm template vault ./k8s/charts/vault -f k8s/values/vault.yaml
# Error: unable to build kubernetes objects ... cannot unmarshal object into Go struct field Ingress.spec.rules.http.paths of type []v1.HTTPIngressPath
```

**Причина**

В старых версиях чарта Vault `server.ingress.paths` был map (`{"/": {}}`), в
0.28.1 — список. При копировании values из старой документации получаем
несовместимый тип.

**Фикс**

Использовать список:

```yaml
server:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-staging
      nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    hosts:
      - host: vault.platform-mvp-potapov.ru
    tls:
      - secretName: vault-tls
        hosts:
          - vault.platform-mvp-potapov.ru
```

Либо вообще не указывать `paths` — чарт подставит `pathType: Prefix, path: /`.

---

### 403 при записи в kv: `no handler for route "kv/data/..."`

**Симптом**

```bash
vault kv put kv/platform/cloudflare api-token="xxx"
# Error making API request.
# Code: 403. Errors:
# * 1 error occurred:
#   * no handler for route "kv/data/platform/cloudflare"
```

**Причина**

KV v2 engine не включён. В dev-режиме Vault стартует с `secret/` (KV v1), а
ClusterSecretStore настроен на `path: kv, version: v2`.

**Фикс**

```bash
kubectl -n vault port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
# root-токен dev-режима — см. Secret vault (ключ root-token)
export VAULT_TOKEN="$(kubectl -n vault get secret vault -o jsonpath='{.data.root-token}' | base64 -d)"

vault secrets enable -path=kv -version=2 kv

vault secrets list
# kv/    kv    kv_xxx    ...
```

Проверка:

```bash
vault kv put kv/platform/test foo=bar
vault kv get kv/platform/test
vault kv delete kv/platform/test
```

---

### Vault теряет данные после рестарта пода

**Симптом**

После `kubectl -n vault delete pod vault-0` все секреты пропали, ESO начал
сыпать ошибками.

**Причина**

Vault в dev-режиме (`server.dev.enabled: true`) хранит данные **в памяти**.
Рестарт = полная потеря.

**Фикс (немедленный)**

Повторно залить секреты (см. [deployment.md, Шаг 7](deployment.md#шаг-7-секреты)).

**Фикс (правильный)**

Перейти на standalone/HA с persistent storage:

```yaml
server:
  dev:
    enabled: false
  standalone:
    enabled: true
    config: |
      ui = true
      listener "tcp" {
        address     = "0.0.0.0:8200"
        tls_disable = 1
      }
      storage "file" {
        path = "/vault/data"
      }
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: longhorn
```

После этого Vault нужно распечатать (unseal) — 3 из 5 ключей Shamir. Детали —
[security.md](security.md).

---

## Harbor

### Multi-Attach error при rollout

**Симптом**

```bash
kubectl -n harbor get pods
# harbor-registry-xxx   0/1   ContainerCreating
```

```bash
kubectl -n harbor describe pod harbor-registry-xxx | tail
# Multi-Attach error for volume "pvc-xxx"
# Volume is already exclusively attached to one node and can't be attached to another
```

**Причина**

PVC Harbor использует `ReadWriteOnce` (Longhorn RWO = один узел). При rollout
новый под стартует на другой ноде, пока старый ещё держит том.

**Фикс**

```bash
# 1. Дождаться, пока старый под умрёт
kubectl -n harbor get pods -w

# 2. Если застряло — удалить старый под принудительно
kubectl -n harbor delete pod harbor-registry-<old> --grace-period=0 --force

# 3. Если и это не помогло — проверить, что том отвязан
kubectl -n longhorn-system get volumes.longhorn.io | grep <pvc-uid>
```

**Профилактика**

В [`k8s/apps/40-harbor.yaml`](../k8s/apps/40-harbor.yaml) добавлен
`ignoreDifferences` на `/spec/strategy` — Harbor сам переключает стратегию
rollout на `Recreate` при RWO, и ArgoCD не должен это откатывать:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: harbor-registry
    jsonPointers:
      - /spec/strategy
syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true
```

---

### `ImagePullBackOff` при pull из Harbor

**Симптом**

```bash
kubectl -n online-boutique describe pod frontend-xxx | tail
# Failed to pull image "harbor.platform-mvp-potapov.ru/...": x509: certificate signed by unknown authority
```

**Причина**

Harbor использует Let's Encrypt **staging** — сертификат не входит в
trust store нод.

**Фикс**

Вариант 1 — добавить CA в containerd на всех нодах:

```bash
# Получить CA
kubectl -n harbor get secret harbor-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > harbor-ca.crt

# На каждой ноде
sudo mkdir -p /usr/local/share/ca-certificates/
sudo cp harbor-ca.crt /usr/local/share/ca-certificates/harbor-ca.crt
sudo update-ca-certificates
sudo systemctl restart containerd
```

Вариант 2 — добавить в `registries.yaml`:

```yaml
# /etc/containerd/certs.d/harbor.platform-mvp-potapov.ru/hosts.toml
server = "https://harbor.platform-mvp-potapov.ru"

[host."https://harbor.platform-mvp-potapov.ru"]
  skip_verify = true
```

```bash
sudo systemctl restart containerd
```

Вариант 3 (используется в проекте) — Secret `harbor-creds` в namespace
приложения + `imagePullSecrets` в поде. Работает, если CA уже в trust store
нод (после варианта 1).

---

### Trivy не сканирует образы

**Симптом**

В Harbor UI у образа нет результата сканирования, статус `Not Scanned`.

**Причина**

Trivy в Harbor обновляет базу уязвимостей из интернета. При блокировках или
`skipUpdate: true` база пустая.

**Фикс**

```yaml
# k8s/values/harbor.yaml
trivy:
  enabled: true
  skipUpdate: false        # разрешить обновление базы
```

```bash
kubectl -n harbor rollout restart deploy harbor-trivy
kubectl -n harbor logs deploy/harbor-trivy --tail=30
```

Ручной запуск сканирования:

```bash
curl -k -u admin:<PASS> -X POST \
  "https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories/frontend/artifacts/v1.0.0/scan"
```

---

## GitLab / Runner

### Bitnami убрал free-образы → `ImagePullBackOff` на postgres/redis

**Симптом**

```bash
kubectl -n gitlab get pods
# gitlab-postgresql-0   0/1   ImagePullBackOff
```

```bash
kubectl -n gitlab describe pod gitlab-postgresql-0 | tail
# Failed to pull image "docker.io/bitnami/postgresql:14.8.0": not found
```

**Причина**

Bitnami в 2025 перевёл бесплатные образы в `bitnamilegacy` и ограничил
публичный доступ к `bitnami/*`.

**Фикс**

```yaml
# k8s/values/gitlab.yaml
postgresql:
  image:
    registry: docker.io
    repository: bitnamilegacy/postgresql
    tag: 14.8.0
  metrics:
    image:
      registry: docker.io
      repository: bitnamilegacy/postgres-exporter
      tag: 0.14.0-debian-11-r2

redis:
  image:
    registry: docker.io
    repository: bitnamilegacy/redis
    tag: 7.2.4-debian-12-r9
  metrics:
    image:
      registry: docker.io
      repository: bitnamilegacy/redis-exporter
      tag: 1.58.0-debian-12-r4
```

```bash
kubectl -n argocd annotate application gitlab argocd.argoproj.io/refresh=hard --overwrite
```

**Статус:** временное решение, зафиксировано в
[known-limitations.md](known-limitations.md).

---

### Runner не регистрируется: `x509: certificate signed by unknown authority`

**Симптом**

```bash
kubectl -n gitlab logs deploy/gitlab-runner --tail=30
# ERROR: Registering runner... failed
# x509: certificate signed by unknown authority
```

**Причина**

GitLab ingress использует self-signed CA (`gitlab-wildcard-tls`), а не Let's
Encrypt. Стандартный образ Runner не доверяет этому CA.

**Фикс**

Собрать кастомный образ Runner с CA внутри:

```bash
kubectl -n gitlab get secret gitlab-wildcard-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > gitlab-ca.crt

cat > Dockerfile <<'EOF'
FROM gitlab/gitlab-runner:v19.5.1
USER root
COPY gitlab-ca.crt /usr/local/share/ca-certificates/gitlab-ca.crt
RUN update-ca-certificates
USER gitlab-runner
EOF

docker build -t harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5 .
docker push harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5
```

Values уже указывают на этот образ:

```yaml
# k8s/values/gitlab-runner.yaml
image:
  registry: harbor.platform-mvp-potapov.ru
  image: online-boutique/gitlab-runner-ca
  tag: v19.5.1-fixed5
certsSecretName: gitlab-runner-ca
envVars:
  - name: GITLAB_RUNNER_INSECURE
    value: "true"
```

---

### Kaniko: `Invalid auth configuration file`

**Симптом**

```bash
# В логе job
error checking push permissions: getting credentials:
Invalid auth configuration file
```

**Причина**

В `.gitlab-ci.yml` конфиг собирался так:

```yaml
before_script:
  - mkdir -p /kaniko/.docker
  - echo "{\"auths\":{\"$HARBOR\":{\"auth\":\"$(printf '%s:%s' "$USER" "$PASS" | base64)\"}}}" > /kaniko/.docker/config.json
```

`printf` внутри `$(...)` внутри JSON-строки ломается на кавычках и переносах —
получается невалидный JSON.

**Фикс**

Писать конфиг через heredoc, а креды передавать как `username`/`password`
(без ручного base64):

```yaml
script:
  - mkdir -p /kaniko/.docker
  - |
    cat > /kaniko/.docker/config.json <<EOF
    {"auths":{"harbor.platform-mvp-potapov.ru":{"username":"${HARBOR_USER}","password":"${HARBOR_PASSWORD}"}}}
    EOF
  - /kaniko/executor
    --context "$CI_PROJECT_DIR/$CTX"
    --dockerfile "$CI_PROJECT_DIR/$CTX/Dockerfile"
    --destination "$HARBOR/$SVC:$TAG"
```

Проверка валидности:

```bash
jq . /kaniko/.docker/config.json
```

---

### GitLab `external_url` с портом → `URI::InvalidComponentError`

**Симптом**

```bash
kubectl -n gitlab logs deploy/gitlab-webservice-default --tail=30
# URI::InvalidComponentError: bad component(expected host component): ...
```

GitLab не стартует.

**Причина**

В `global.hosts` или `external_url` указан порт (`gitlab.example.com:8443`).
Ruby `URI` не принимает порт в host-компоненте при HTTPS.

**Фикс**

```yaml
# k8s/values/gitlab.yaml
global:
  hosts:
    domain: platform-mvp-potapov.ru
    https: true
    gitlab:
      name: gitlab.platform-mvp-potapov.ru     # без порта
    registry:
      name: registry.gitlab.platform-mvp-potapov.ru
```

Порт задаётся только в ingress/NodePort, не в `external_url`.

---

### GitLab недоступен из WSL2

**Симптом**

```bash
curl -k https://gitlab.platform-mvp-potapov.ru
# curl: (7) Failed to connect
```

**Причина**

DNS-запись указывает на `192.168.190.153`, но WSL2 находится в другой
подсети (VMware NAT виден только хосту, а WSL2 — отдельная виртуальная сеть
Hyper-V). Плюс TLS SNI требует правильного Host-заголовка.

**Фикс**

SSH-туннель через хост:

```bash
ssh -L 8443:192.168.190.153:30443 devops@192.168.190.153
```

Затем:

```bash
# Вариант 1: /etc/hosts
echo "127.0.0.1 gitlab.platform-mvp-potapov.ru" | sudo tee -a /etc/hosts
curl -k https://gitlab.platform-mvp-potapov.ru:8443/users/sign_in

# Вариант 2: --resolve
curl -k --resolve gitlab.platform-mvp-potapov.ru:8443:127.0.0.1 \
  https://gitlab.platform-mvp-potapov.ru:8443/users/sign_in
```

То же для Harbor (`:8443` → `harbor.platform-mvp-potapov.ru`).

---

## Online Boutique

### `checkoutservice` / `shippingservice`: `is a directory`

**Симптом**

```bash
kubectl -n online-boutique logs checkoutservice-xxx
# exec: "/src/server": is a directory
```

Под в `CrashLoopBackOff`.

**Причина**

В Dockerfile финальный stage содержал:

```dockerfile
WORKDIR /src/checkoutservice
COPY --from=builder /src/checkoutservice/server /src/server
```

`WORKDIR /src/checkoutservice` создаёт каталог. Затем `COPY ... /src/server`
копирует **бинарник** в путь, который уже существует как каталог (из-за
предыдущего `WORKDIR` в другом слое или из-за `COPY . .`). В результате
`/src/server` — каталог, а `ENTRYPOINT ["/src/server"]` пытается его
выполнить.

**Фикс**

В форке `potapovanton149/online-boutique` Dockerfile исправлен:

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /src
COPY --from=builder /src/checkoutservice/server /src/server
USER nonroot
EXPOSE 5050
ENTRYPOINT ["/src/server"]
```

Ключевое: `WORKDIR /src` (не `/src/<svc>`), бинарник копируется в `/src/server`.

Пересобрать:

```bash
TAG=v1.0.4 ./scripts/build-online-boutique.sh
```

В манифестах эти два сервиса используют `:v1.0.4`, остальные — `:v1.0.0`.

---

### `frontend` падает: `SHOPPING_ASSISTANT_SERVICE_ADDR` not set

**Симптом**

```bash
kubectl -n online-boutique logs frontend-xxx
# panic: environment variable SHOPPING_ASSISTANT_SERVICE_ADDR not set
```

**Причина**

В коде frontend используется `mustMapEnv`, который паникует на пустой
переменной. В оригинальном `microservices-demo` эта переменная опциональна, но
в форке — обязательна.

**Фикс**

```yaml
# k8s/apps/online-boutique/frontend.yaml
env:
  - {name: SHOPPING_ASSISTANT_SERVICE_ADDR, value: "disabled"}
```

Значение `disabled` — валидный «выключенный» адрес: frontend проверяет его и
не пытается подключиться.

---

### `ImagePullBackOff` на образах Online Boutique

**Симптом**

```bash
kubectl -n online-boutique get pods
# frontend-xxx   0/1   ImagePullBackOff
```

**Причина**

1. Secret `harbor-creds` отсутствует в namespace `online-boutique`.
2. CA Harbor не в trust store нод (см. [Harbor](#harbor)).
3. Образ не собран.

**Фикс**

```bash
# 1. Secret
kubectl -n online-boutique create secret docker-registry harbor-creds \
  --docker-server=harbor.platform-mvp-potapov.ru \
  --docker-username=admin \
  --docker-password='<PASS>'

# 2. Проверить, что образ есть
curl -k -u admin:<PASS> \
  "https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories/frontend/artifacts"

# 3. Перезапустить
kubectl -n online-boutique rollout restart deploy frontend
```

---

### `redis-cart` StatefulSet вечно OutOfSync

**Симптом**

```bash
kubectl -n argocd get application online-boutique
# OutOfSync   Healthy
```

**Причина**

`redis-cart` — StatefulSet с `volumeClaimTemplates`. K8s добавляет в шаблон
служебные поля, ArgoCD видит diff.

**Фикс**

Уже применено в [`k8s/apps/60-online-boutique.yaml`](../k8s/apps/60-online-boutique.yaml):

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /spec/volumeClaimTemplates
```

---

### CRLF в `kustomization.yaml`

**Симптом**

```bash
kubectl -n argocd get application online-boutique
# ComparisonError: kustomize build failed:
# accumulating resources: ... yaml: line 1: did not find expected key
```

**Причина**

Файл сохранён в Windows с CRLF. Kustomize (как и любой YAML-парсер) не
принимает `\r` в конце строк.

**Фикс**

```bash
# Проверить
file k8s/apps/online-boutique/kustomization.yaml
# ... with CRLF line terminators

# Исправить
sed -i 's/\r$//' k8s/apps/online-boutique/kustomization.yaml

# Или через dos2unix
dos2unix k8s/apps/online-boutique/*.yaml
```

**Профилактика**

`.gitattributes`:

```
*.yaml text eol=lf
*.yml  text eol=lf
*.sh   text eol=lf
```

---

## Прочее

### `kubectl` не подключается к VIP

**Симптом**

```bash
kubectl get nodes
# Unable to connect to the server: x509: certificate is valid for
# 192.168.190.101, 10.233.0.1, ... not 192.168.190.100
```

**Причина**

VIP не добавлен в SAN сертификата API-сервера.

**Фикс**

```yaml
# kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml
supplementary_addresses_in_ssl_keys:
  - 192.168.190.100
```

Перегенерировать сертификаты:

```bash
cd kubespray
~/.venv/kubespray/bin/ansible-playbook -i inventory/mycluster/hosts.yml \
  cluster.yml -b --tags=kubeadm
```

---

### `ansible-playbook` падает на `dpkg lock`

**Симптом**

```bash
TASK [common : Install base packages]
fatal: [cp-1]: FAILED! => {"msg": "Failed to lock apt for exclusive operation"}
```

**Причина**

`unattended-upgrades` или предыдущий `apt` держит lock.

**Фикс**

Роль `common` уже ждёт до 120 секунд и отключает `unattended-upgrades`. Если
всё равно падает:

```bash
ansible -i ansible/inventory/prod.yml k8s_cluster -b -m shell \
  -a 'systemctl stop unattended-upgrades; pkill -9 apt; pkill -9 dpkg; rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock'
```

---

### `kubespray submodule not initialized`

**Симптом**

```bash
make k8s
# ERROR: kubespray submodule not initialized
```

**Фикс**

```bash
git submodule update --init --recursive
ls kubespray/cluster.yml
```

---

### `Kubespray venv not found`

**Симптом**

```bash
make k8s
# ERROR: Kubespray venv not found at /home/user/.venv/kubespray
```

**Фикс**

```bash
python3 -m venv ~/.venv/kubespray
source ~/.venv/kubespray/bin/activate
pip install -U pip
pip install -r kubespray/requirements.txt
deactivate
```

Или указать свой путь:

```bash
KUBESPRAY_VENV=/path/to/venv make k8s
```

---

### `external-dns` в CrashLoopBackOff

**Симптом**

```bash
kubectl -n external-dns logs deploy/external-dns --tail=20
# failed to sync: Get "https://api.cloudflare.com/client/v4/zones": 
# net/http: TLS handshake timeout
```

**Причина**

DPI блокирует TLS-хендшейк к `api.cloudflare.com` из РФ.

**Фикс**

Отключить (DNS-записи создаются вручную):

```bash
kubectl -n external-dns scale deploy external-dns --replicas=0
```

Чтобы ArgoCD не вернул реплику:

```yaml
# k8s/values/external-dns.yaml
replicaCount: 0
```

**Статус:** известное ограничение, см.
[known-limitations.md](known-limitations.md).

---

### Telegram-алерты не приходят

**Симптом**

Alertmanager показывает `firing`, но сообщений в Telegram нет.

```bash
kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 --tail=30
# notify retry canceled due to unrecoverable error after 1 attempts:
# Post "https://api.telegram.org/bot.../sendMessage": dial tcp: i/o timeout
```

**Причина**

`api.telegram.org` блокируется из РФ.

**Фикс**

Вариант 1 — прокси:

```yaml
# k8s/values/kube-prometheus-stack.yaml
alertmanager:
  config:
    receivers:
      - name: 'telegram'
        telegram_configs:
          - bot_token_file: /etc/alertmanager/secrets/alertmanager-telegram/bot-token
            chat_id: <CHAT_ID>
            parse_mode: 'HTML'
            send_resolved: true
            http_config:
              proxy_url: http://<PROXY>:3128
```

Вариант 2 — webhook на доступный сервис (например, собственный relay).

**Статус:** известное ограничение, конфиг готов и корректен — проверяется
локально через `amtool`:

```bash
kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- amtool alert query --alertmanager.url=http://localhost:9093
```

---

## Связанные документы

- [deployment.md](deployment.md) — пошаговое развёртывание
- [architecture.md](architecture.md) — как всё устроено
- [known-limitations.md](known-limitations.md) — что не работает и почему
- [monitoring.md](monitoring.md) — observability
- [security.md](security.md) — Vault/ESO
