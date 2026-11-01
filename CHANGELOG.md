# Changelog

Все значимые изменения инфраструктурной платформы. Формат основан на
[Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версионирование —
[Semantic Versioning](https://semver.org/lang/ru/).

Проект учебный, поэтому версии отражают не «релизы продукта», а этапы
построения платформы.

---

## [Unreleased]

### Планируется

- Vault: миграция с dev-режима на persistent + Shamir/auto-unseal
- Вынос всех паролей из values-файлов в Vault + ESO
- Автоматический bump image-тегов в пайплайне
- Включение ServiceMonitor для ingress-nginx и cert-manager
- NetworkPolicies (default-deny + явные разрешения)
- Longhorn `backupTarget` + RecurringJob + Velero
- Переключение на `letsencrypt-prod`
- Внешний доступ через VPS + WireGuard/cloudflared

Полный список с приоритетами — [docs/known-limitations.md](docs/known-limitations.md).

---

## [1.0.0] — 2025-11

Первая рабочая версия платформы: 20 ArgoCD Applications в состоянии
`Synced + Healthy`, 13/13 подов Online Boutique в `Running`, 11 образов в
Harbor, 4 алерта Online Boutique в состоянии `inactive`.

### Итоговое состояние

| Параметр | Значение |
|---|---|
| Kubernetes | v1.30.4 (Kubespray v2.26.0) |
| Ноды | 3 control-plane + 3 worker |
| CNI | Cilium v1.16.1 + Hubble |
| VIP | `192.168.190.100` (kube-vip, ARP) |
| ArgoCD | chart 7.6.12, App of Apps |
| Applications | 20 (`Synced + Healthy`) |
| Namespaces | 13 |
| Ingress | ingress-nginx 4.11.3, NodePort 30080/30443 |
| TLS | cert-manager v1.16.2, Let's Encrypt **staging**, DNS-01 Cloudflare |
| Storage | Longhorn, `defaultReplicaCount: 1`, 14/15 volumes healthy |
| Метрики | kube-prometheus-stack 65.5.0 |
| Логи | Loki 6.21.0 + Promtail 6.16.6 |
| Трейсы | Tempo 1.18.2 + OTel Collector 0.108.0 |
| Секреты | Vault 0.28.1 (dev) + ESO 0.10.4, 5 ExternalSecret |
| Registry | Harbor 1.15.1, проекты `online-boutique` (public), `platform` (private) |
| CI/CD | GitLab CE 17.11.7 (chart 8.11.8) + Runner 19.5.1 (chart 0.94.1) |
| Приложение | Online Boutique, 11 сервисов + redis-cart |

---

## Этап 1. Инфраструктура и виртуальные машины

**Цель:** подготовить вычислительную базу под кластер.

### Добавлено

- 6 виртуальных машин в VMware Workstation Pro (Windows 11 Home хост):
  - `cp-1` — `192.168.190.101`
  - `cp-2` — `192.168.190.151`
  - `cp-3` — `192.168.190.150`
  - `worker-1` — `192.168.190.153`
  - `worker-2` — `192.168.190.146`
  - `worker-3` — `192.168.190.145`
- NAT-сеть `192.168.190.0/24`
- Ubuntu 22.04 LTS на всех нодах, пользователь `devops`, SSH по ключу
  `~/.ssh/id_ed25519`
- Ansible-инвентарь [`ansible/inventory/prod.yml`](ansible/inventory/prod.yml)
  с группами `kube_control_plane`, `kube_node`, `etcd`
- Роль `common`: отключение swap, модули ядра (`br_netfilter`, `overlay`),
  sysctl (`net.bridge.bridge-nf-call-iptables`, `net.ipv4.ip_forward`),
  containerd, `kubelet`-зависимости
- [`Makefile`](Makefile) с целями `prepare`, `k8s`, `post-k8s`, `argocd`,
  `all`, `destroy`, `password`
- [`scripts/bootstrap.sh`](scripts/bootstrap.sh) — полный прогон 5 шагов
- [`scripts/destroy.sh`](scripts/destroy.sh) — снос кластера (VM остаются)

### Изменено

- `ansible/ansible.cfg`: отключён host key checking, указан inventory по
  умолчанию

### Известные проблемы

- Нет публичного IP: сеть за NAT провайдера (CGNAT) — см.
  [L-01](docs/known-limitations.md#l-01-внешний-доступ-из-интернета-не-работает)

---

## Этап 2. Kubernetes (Kubespray) и сеть

**Цель:** развернуть отказоустойчивый кластер с VIP и Cilium.

### Добавлено

- Kubespray **v2.26.0** как git-submodule ([`.gitmodules`](.gitmodules))
- [`kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml`](kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml):

```yaml
kube_version: v1.30.4
kube_network_plugin: cilium
kube_proxy_mode: ipvs
kube_proxy_strict_arp: true
kube_proxy_remove: false

kube_vip_enabled: true
kube_vip_controlplane_enabled: true
kube_vip_address: 192.168.190.100
kube_vip_interface: ens33
kube_vip_cidr: 32
kube_vip_arp_enabled: true
kube_vip_leader_election_enabled: true
kube_vip_lb_enable: false
supplementary_addresses_in_ssl_keys:
  - 192.168.190.100

container_manager: containerd
etcd_deployment_type: host
dns_mode: coredns
upstream_dns_servers:
  - 1.1.1.1
  - 8.8.8.8

cilium_enable_hubble: true
cilium_hubble_ui_enabled: true
cilium_kube_proxy_replacement: false
cilium_version: "v1.16.1"
```

- [`kubespray-config/group_vars/k8s_cluster/addons.yml`](kubespray-config/group_vars/k8s_cluster/addons.yml)
- [`scripts/02-run-kubespray.sh`](scripts/02-run-kubespray.sh) — обёртка над
  `cluster.yml` с патчем Cilium
- [`ansible/playbooks/03-post-kubespray.yml`](ansible/playbooks/03-post-kubespray.yml)
  — kubeconfig, labels нод
- kube-vip в ARP-режиме: VIP `192.168.190.100:6443` на интерфейсе `ens33`

### Исправлено

- **Cilium `CrashLoopBackOff`**: `Invalid value for --kube-proxy-replacement: False`.
  Kubespray 2.26 передаёт `False` (Python-нотация), Cilium 1.16 ожидает
  `false` (Go-нотация). Решение: `cilium_kube_proxy_replacement: false` в
  `k8s-cluster.yml` + патч DaemonSet.
- **kube-proxy IPVS не слушает `:10249`**: метрики kube-proxy недоступны,
  поэтому в kube-prometheus-stack отключено правило `kubeProxy`
  (`defaultRules.rules.kubeProxy: false`).

### Известные проблемы

- etcd на хостах (`etcd_deployment_type: host`) — нет отдельного
  мониторинга etcd (`defaultRules.rules.etcd: false`)

---

## Этап 3. Ingress, сертификаты, DNS

**Цель:** обеспечить входной трафик и TLS для всех хостов.

### Добавлено

- **ingress-nginx 4.11.3** ([`k8s/values/ingress-nginx.yaml`](k8s/values/ingress-nginx.yaml)):
  - DaemonSet на всех 6 нодах
  - NodePort `30080` (HTTP) / `30443` (HTTPS)
  - `ingressClass: nginx`, `isDefaultClass: true`
  - `use-forwarded-headers: true`, `compute-full-forwarded-for: true`,
    `enable-real-ip: true`, `proxy-real-ip-cidr: 0.0.0.0/0`
  - JSON `log-format-upstream`
  - `defaultBackend.enabled: false`
- **cert-manager v1.16.2** ([`k8s/values/cert-manager.yaml`](k8s/values/cert-manager.yaml)):
  - `installCRDs: true`
  - `extraArgs: --dns01-recursive-nameservers-only`,
    `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53`
- Два `ClusterIssuer`:
  - [`k8s/manifests/clusterissuer-letsencrypt-staging.yaml`](k8s/manifests/clusterissuer-letsencrypt-staging.yaml)
  - [`k8s/manifests/clusterissuer-letsencrypt-prod.yaml`](k8s/manifests/clusterissuer-letsencrypt-prod.yaml)
  - оба — DNS-01 через Cloudflare
- **external-dns 1.15.0** ([`k8s/values/external-dns.yaml`](k8s/values/external-dns.yaml)):
  - `provider: cloudflare`, `domainFilters: [platform-mvp-potapov.ru]`,
    `policy: sync`, `txtOwnerId: platform-mvp`, `txtPrefix: "_externaldns."`
- 7 `Certificate` в [`k8s/manifests/certs/`](k8s/manifests/certs/):
  `harbor`, `gitlab`, `grafana`, `prometheus`, `alertmanager`, `vault`,
  `longhorn`
- Application `platform-certs` (sync-wave `2`)

### Исправлено

- **`Certificate` в `Pending`**: Secret `cloudflare-api-token` не найден.
  Причина — рассинхрон имён ключей: cert-manager ждёт `api-token`,
  external-dns — `cloudflare_api_token`. Решение: два отдельных
  ExternalSecret с разными `property`.
- **external-dns `CrashLoopBackOff`**: TLS handshake к `api.cloudflare.com`
  обрывается DPI. Решение: `replicas: 0`, DNS-записи создаются вручную.

### Известные проблемы

- external-dns не работает — [L-03](docs/known-limitations.md#l-03-external-dns-в-crashloopbackoff)
- Все сертификаты — staging — [L-05](docs/known-limitations.md#l-05-tls--lets-encrypt-staging)
- `controller.metrics.serviceMonitor.enabled: false` — метрики ingress-nginx
  не собираются, из-за чего 2 алерта Online Boutique неработоспособны
  ([L-13](docs/known-limitations.md#l-13-два-алерта-online-boutique-не-могут-сработать))

---

## Этап 4. Хранилище и наблюдаемость

**Цель:** дать приложениям persistent storage и полный observability-стек.

### Добавлено

- **Longhorn** (vendored chart, [`k8s/charts/longhorn/`](k8s/charts/longhorn/),
  values — [`k8s/values/longhorn.yaml`](k8s/values/longhorn.yaml)):
  - `defaultReplicaCount: 1`, `defaultDataPath: /var/lib/longhorn`
  - `storageMinimalAvailablePercentage: 10`
  - StorageClass `longhorn` — **default**
  - `upgradeChecker: false`, `preUpgradeChecker.jobEnabled: false`
  - UI на `longhorn.platform-mvp-potapov.ru`
  - ServiceMonitor с `release: kube-prometheus-stack`
- **kube-prometheus-stack 65.5.0**
  ([`k8s/values/kube-prometheus-stack.yaml`](k8s/values/kube-prometheus-stack.yaml)):
  - Prometheus: `replicas: 1`, `retention: 5d`, `retentionSize: 4GB`,
    PVC `10Gi` Longhorn, `200m/1Gi` → `1000m/2Gi`
  - `ruleSelectorNilUsesHelmValues: false`,
    `serviceMonitorSelectorNilUsesHelmValues: false`,
    `podMonitorSelectorNilUsesHelmValues: false`,
    `probeSelectorNilUsesHelmValues: false`,
    `scrapeConfigSelectorNilUsesHelmValues: false`
  - Grafana: PVC `5Gi`, `sidecar.dashboards` (`label: grafana_dashboard`,
    `searchNamespace: ALL`), `allow_embedding: true`
  - Alertmanager: `replicas: 1`, PVC `5Gi`, `secrets: [alertmanager-telegram]`,
    маршрут `telegram`, `group_wait: 30s`, `group_interval: 5m`,
    `repeat_interval: 3h`, `send_resolved: true`, `parse_mode: HTML`
  - `defaultRules.rules`: `etcd: false`, `kubeProxy: false`
  - 6 платформенных алертов: `NodeDown`, `PodCrashLooping`, `HighCPUUsage`,
    `HighMemoryUsage`, `DiskSpaceLow`, `CertificateExpiringSoon`
- **Loki 6.21.0** ([`k8s/values/loki.yaml`](k8s/values/loki.yaml)):
  - `deploymentMode: SingleBinary`, `replicas: 1`
  - `auth_enabled: false`, `replication_factor: 1`
  - `storage.type: filesystem`, PVC `20Gi` Longhorn
  - schema `tsdb` / `v13` с `2024-01-01`
  - `retention_period: 168h`, compactor с `retention_enabled: true`
  - `ingestion_rate_mb: 10`, `ingestion_burst_size_mb: 20`
  - `max_query_series: 5000`, `max_query_parallelism: 16`
  - `allow_structured_metadata: true`
  - `gateway.enabled: false`, `chunksCache`/`resultsCache` отключены
- **Promtail 6.16.6** ([`k8s/values/promtail.yaml`](k8s/values/promtail.yaml)):
  - DaemonSet, tolerations `NoSchedule/Exists`
  - hostPath `/var/log` и `/var/lib/docker/containers`
  - `extraRelabelConfigs`: `__meta_kubernetes_pod_node_name` → `node`
- **Tempo 1.18.2** ([`k8s/values/tempo.yaml`](k8s/values/tempo.yaml)):
  - `retention: 48h`, PVC `20Gi` Longhorn
  - OTLP gRPC `0.0.0.0:4317`, HTTP `0.0.0.0:4318`
  - `storage.trace.backend: local`
  - `metricsGenerator.enabled: false`, `tempoQuery.enabled: false`
- **OTel Collector 0.108.0** ([`k8s/values/otel-collector.yaml`](k8s/values/otel-collector.yaml)):
  - `mode: deployment`, `replicaCount: 1`
  - processors: `memory_limiter` (`limit_percentage: 75`,
    `spike_limit_percentage: 20`) + `batch`
  - exporters: `otlp → tempo.tracing.svc:4317` (`tls.insecure: true`),
    `prometheus → 0.0.0.0:8889` (`resource_to_telemetry_conversion: true`)
  - pipelines: `traces`, `metrics`
- Grafana datasources: `Loki` (`http://loki.logging.svc:3100`),
  `Tempo` (`http://tempo.tracing.svc:3200`) с корреляцией
  `tracesToLogsV2`, `tracesToMetrics`, `serviceMap`, `nodeGraph`, `lokiSearch`

### Исправлено

- **Prometheus PVC**: опечатка `ReadWrilivenessProbeteOnce` вместо
  `ReadWriteOnce` — под висел в `Pending`
- **Longhorn version mismatch**: `longhorn-manager v1.6.2` /
  `instance-manager v1.7.2` — потребовался пересоздание instance-manager
  подов
- **Longhorn каскадное удаление через ArgoCD**: `prune: true` +
  `resources-finalizer.argocd.argoproj.io` удалили PVC вместе с Application.
  Решение: `ignoreDifferences` на `volumeClaimTemplates`, аккуратное удаление
  через `--cascade=orphan`
- **ServiceMonitor на gRPC-портах**: попытка скрапить `/metrics` с портов
  gRPC-сервисов давала `connection refused`. Решение: скрапить только
  реальные metrics-порты

### Известные проблемы

- 1 orphan volume в Longhorn — [L-18](docs/known-limitations.md#l-18-longhorn-1-orphan-volume)
- Нет бэкапов — [L-16](docs/known-limitations.md#l-16-нет-бэкапов)
- Короткое хранение (5d/7d/48h) — [L-26](docs/known-limitations.md#l-26-короткое-хранение-метрик-логов-трейсов)
- `CertificateExpiringSoon` не может сработать (нет ServiceMonitor у
  cert-manager) — [L-15](docs/known-limitations.md#l-15-алерт-certificateexpiringsoon-не-может-сработать)

---

## Этап 5. Секреты и реестр образов

**Цель:** централизованное хранение секретов и приватный registry.

### Добавлено

- **Vault** (vendored chart 0.28.1 / appVersion 1.17.2,
  [`k8s/charts/vault/`](k8s/charts/vault/),
  values — [`k8s/values/vault.yaml`](k8s/values/vault.yaml)):
  - `server.dev.enabled: true`, `devRootToken` — см. Vault `kv/platform/vault`
  - `global.tlsDisable: true`
  - `standalone.enabled: false`, `dataStorage.enabled: false`
  - `auditStorage.enabled: false`, `VAULT_AUDIT_LOG_DEVICE: stdout`
  - `csi.enabled: false`, `injector.enabled: false`
  - UI на `vault.platform-mvp-potapov.ru` (`backend-protocol: HTTP`)
  - KV v2 движок `kv`, префикс `kv/platform/`
- **External Secrets Operator 0.10.4**
  ([`k8s/values/external-secrets.yaml`](k8s/values/external-secrets.yaml)):
  - `installCRDs: true`, `replicaCount: 1`
  - ServiceMonitor для main/webhook/certController с
    `release: kube-prometheus-stack`
- `ClusterSecretStore` `vault-backend`
  ([`k8s/manifests/vault-cluster-secret-store.yaml`](k8s/manifests/vault-cluster-secret-store.yaml)):
  - `server: http://vault.vault.svc:8200`, `path: kv`, `version: v2`
  - `auth.tokenSecretRef: {name: vault-token, key: token, namespace: external-secrets}`
- 5 `ExternalSecret` в [`k8s/manifests/external-secrets/`](k8s/manifests/external-secrets/):

| # | Файл | Namespace | Target Secret | Ключи |
|---|---|---|---|---|
| 1 | `cloudflare-api-token-certmanager.yaml` | `cert-manager` | `cloudflare-api-token` | `api-token` |
| 2 | `cloudflare-api-token-externaldns.yaml` | `external-dns` | `cloudflare-api-token` | `cloudflare_api_token` |
| 3 | `telegram-alertmanager.yaml` | `monitoring` | `alertmanager-telegram` | `bot-token`, `chat-id` |
| 4 | `gitlab-root.yaml` | `gitlab` | `gitlab-gitlab-initial-root-password` | `password` |
| 5 | `harbor-credentials.yaml` | `gitlab` | `harbor-credentials` | `HARBOR_USER`, `HARBOR_PASSWORD` |

- **Harbor 1.15.1** ([`k8s/values/harbor.yaml`](k8s/values/harbor.yaml)):
  - ingress `harbor.platform-mvp-potapov.ru`, `letsencrypt-staging`
  - `proxy-body-size: "0"`, `proxy-read/send-timeout: "600"`
  - PVC: registry `20Gi`, database `5Gi`, redis `2Gi`, trivy `5Gi`,
    jobservice `1Gi` — все Longhorn, `resourcePolicy: keep`
  - `database.type: internal`
  - Trivy: `enabled: true`, `skipUpdate: true`
  - `metrics.serviceMonitor.enabled: true`
  - `ignoreDifferences` на `/spec/strategy` для `harbor-core`,
    `harbor-jobservice`, `harbor-registry`
- Проекты Harbor: `online-boutique` (public), `platform` (private)

### Исправлено

- **Vault ingress paths**: chart 0.28.1 не поддерживает `map`-синтаксис для
  `server.ingress.paths` — пришлось использовать список
- **Vault 403 на `kv/`**: KV v2 движок не был включён. Решение:
  `vault secrets enable -path=kv -version=2 kv`
- **Harbor `Multi-Attach error`**: RWO PVC + `RollingUpdate`. Решение:
  `ignoreDifferences` на `/spec/strategy` + `RespectIgnoreDifferences=true`

### Известные проблемы

- Vault dev-режим — [L-07](docs/known-limitations.md#l-07-vault-в-dev-режиме)
- Пароли в values — [L-08](docs/known-limitations.md#l-08-пароли-в-values-файлах-открытым-текстом)
- Двойной префикс `kv/` в ExternalSecret #4 и #5 —
  [L-09](docs/known-limitations.md#l-09-двойной-префикс-kv-в-externalsecret)
- `ClusterSecretStore` и 3 из 5 ExternalSecret вне GitOps —
  [L-10](docs/known-limitations.md#l-10-часть-манифестов-вне-gitops)

---

## Этап 6. GitLab CE, Runner и CI/CD

**Цель:** собственный Git-сервер и пайплайн сборки образов.

### Добавлено

- **GitLab CE 17.11.7** (chart 8.11.8,
  [`k8s/values/gitlab.yaml`](k8s/values/gitlab.yaml)):
  - `global.edition: ce`, `global.hosts.domain: platform-mvp-potapov.ru`
  - `gitlab.platform-mvp-potapov.ru`, `registry.gitlab.platform-mvp-potapov.ru`,
    `minio.gitlab.platform-mvp-potapov.ru`
  - `global.ingress.configureCertmanager: false` (self-signed
    `gitlab-wildcard-tls`)
  - `initialRootPassword.secret: gitlab-gitlab-initial-root-password`
  - `global.minio.enabled: false`, object storage через Secret
    `gitlab-object-storage`
  - `grafana.enabled: false`, `prometheus.enabled: false`,
    `upgradeCheck.enabled: false`
  - `certmanager.install: false`, `nginx-ingress.enabled: false`,
    `gitlab-runner.install: false`
  - Redis `bitnamilegacy/redis:7.2.4-debian-12-r9` (PVC `2Gi`)
  - PostgreSQL `bitnamilegacy/postgresql:14.8.0` (PVC `10Gi`)
  - Gitaly PVC `5Gi`
  - webservice `1` реплика `300m/1Gi` → `1500m/2Gi`
  - sidekiq `1` реплика `200m/1Gi` → `1000m/2Gi`
  - pages, mailroom, spamcheck отключены
- **GitLab Runner 19.5.1** (chart 0.94.1,
  [`k8s/values/gitlab-runner.yaml`](k8s/values/gitlab-runner.yaml)):
  - `gitlabUrl: https://gitlab.platform-mvp-potapov.ru`
  - кастомный образ
    `harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5`
  - `certsSecretName: gitlab-runner-ca`, `GITLAB_RUNNER_INSECURE: "true"`
  - `concurrent: 4`, `checkInterval: 10`
  - executor `kubernetes`, `namespace: gitlab`, `privileged: true`,
    `tls_verify: false`, `poll_timeout: 600`
  - `cpu_request: 200m`, `memory_request: 256Mi`,
    `cpu_limit: 1`, `memory_limit: 1Gi`
- Пайплайн [`k8s/apps/online-boutique/.gitlab-ci.yml`](k8s/apps/online-boutique/.gitlab-ci.yml):
  - одна стадия `build`
  - YAML-anchor `.build_template` + 11 job'ов
  - Kaniko `gcr.io/kaniko-project/executor:v1.23.2-debug`
  - `--cache=true --cache-repo="$HARBOR/cache"`
  - два тега на образ: `$CI_COMMIT_SHORT_SHA` и `latest`
  - `rules: [{if: $CI_COMMIT_BRANCH == "master"}]`
- Application `gitlab-external-secrets` (sync-wave `5`) с
  `directory.include: '{gitlab-root.yaml,harbor-credentials.yaml}'`

### Исправлено

- **Bitnami убрал free-образы**: `ImagePullBackOff` на postgres/redis.
  Решение: `bitnamilegacy/*` с фиксированными тегами
- **Runner `x509: certificate signed by unknown authority`**: GitLab отдаёт
  self-signed CA. Решение: собран образ Runner с CA внутри
- **Kaniko `Invalid auth configuration file`**: `printf | base64` давал битый
  JSON из-за переноса строки. Решение: `printf '%s:%s'` без `\n`
- **GitLab `external_url` с портом**: `Ruby URI::InvalidComponentError`.
  Решение: убрать порт из `external_url`, использовать стандартный 443
- **`SharedResourceWarning` на Namespace**: два Application владели одним
  namespace. Решение: `CreateNamespace=true` только у одного

### Известные проблемы

- Пароль Harbor в `.gitlab-ci.yml` — [L-11](docs/known-limitations.md#l-11-пароль-harbor-в-gitlab-ciyml)
- Bump тега не автоматизирован — [L-12](docs/known-limitations.md#l-12-bump-тега-не-автоматизирован)
- Нет тестов в пайплайне — [L-23](docs/known-limitations.md#l-23-нет-тестов-в-пайплайне)
- GitLab self-signed CA — [L-06](docs/known-limitations.md#l-06-gitlab-отдаёт-self-signed-сертификат)
- MinIO из `bitnamilegacy` — [L-19](docs/known-limitations.md#l-19-minio-из-bitnamilegacy)

---

## Этап 7. ArgoCD, Online Boutique и алерты

**Цель:** GitOps-доставка приложения и SLO-мониторинг.

### Добавлено

- **ArgoCD** chart 7.6.12
  ([`ansible/roles/argocd/files/argocd-values.yaml`](ansible/roles/argocd/files/argocd-values.yaml)):
  - `server.insecure: true`, ingress отключён (доступ через port-forward)
  - `dex.enabled: false`, `notifications.enabled: false`
  - по 1 реплике: server, controller, repoServer, applicationSet, redis
- **App of Apps**: [`k8s/bootstrap/root-app.yaml`](k8s/bootstrap/root-app.yaml)
  - `path: k8s/apps`, `directory.recurse: false`
  - `ignoreDifferences` на `/status`, `/metadata/annotations`,
    `/spec/source/directory`
- **20 Applications** в [`k8s/apps/`](k8s/apps/):

| Файл | Application | Sync-wave |
|---|---|---|
| `00-namespaces.yaml` | `namespaces` | `-1` |
| `10-ingress-nginx.yaml` | `ingress-nginx` | `0` |
| `11-cert-manager.yaml` | `cert-manager` | `0` |
| `11a-clusterissuers.yaml` | `clusterissuers` | `0` |
| `12-external-dns.yaml` | `external-dns` | `0` |
| `13-certs.yaml` | `platform-certs` | `2` |
| `20-longhorn.yaml` | `longhorn` | `1` |
| `21-kube-prometheus-stack.yaml` | `kube-prometheus-stack` | `2` |
| `22-loki.yaml` | `loki` | `2` |
| `22a-promtail.yaml` | `promtail` | `2` |
| `23-tempo.yaml` | `tempo` | `2` |
| `24-otel-collector.yaml` | `otel-collector` | `2` |
| `30-external-secrets.yaml` | `external-secrets` | `2` |
| `31-vault.yaml` | `vault` | `2` |
| `40-harbor.yaml` | `harbor` | `3` |
| `50-gitlab.yaml` | `gitlab` | `4` |
| `51-gitlab-runner.yaml` | `gitlab-runner` | `4` |
| `52-gitlab-external-secrets.yaml` | `gitlab-external-secrets` | `5` |
| `60-online-boutique.yaml` | `online-boutique` | — (по умолчанию `0`) |
| `61-platform-alerts.yaml` | `platform-alerts` | `5` |

- **Online Boutique** ([`k8s/apps/online-boutique/`](k8s/apps/online-boutique/)):
  - 11 микросервисов + `redis-cart` StatefulSet
  - `kustomization.yaml` с `namespace: online-boutique`
  - образы `harbor.platform-mvp-potapov.ru/online-boutique/<svc>:v1.0.0`
    (`checkoutservice` и `shippingservice` — `v1.0.4`)
  - `imagePullSecrets: [{name: harbor-creds}]` во всех манифестах
  - `OTEL_SERVICE_NAME` + `OTEL_EXPORTER_OTLP_ENDPOINT` во всех сервисах
  - `ignoreDifferences` на `StatefulSet /spec/volumeClaimTemplates`
- **Ingress** `shop.platform-mvp-potapov.ru`:
  - `cert-manager.io/cluster-issuer: letsencrypt-staging`
  - `proxy-body-size: "8m"`, TLS Secret `shop-tls`
  - backend `frontend:80`, `pathType: Prefix`
- **4 алерта Online Boutique**
  ([`k8s/manifests/alerts/online-boutique.yaml`](k8s/manifests/alerts/online-boutique.yaml)):
  - `OBHighErrorRate` — 5xx > 5% за 5m, `warning`
  - `OBHighLatency` — p95 > 1s за 5m, `warning`
  - `OBServiceDown` — `replicas_available == 0` за 2m, `critical`
  - `OBPodCrashLooping` — `increase(restarts[10m]) > 3` за 5m, `warning`
- **SLO-дашборд** `Online Boutique SLO`
  ([`k8s/manifests/dashboards/online-boutique-slo.yaml`](k8s/manifests/dashboards/online-boutique-slo.yaml)):
  RPS, p95 latency, error rate, SLO availability 99%, requests total, pods
  running
- **Скрипт сборки** [`scripts/build-online-boutique.sh`](scripts/build-online-boutique.sh):
  PVC `ob-src` → клон в поде `ob-clone` → 11 последовательных Kaniko-подов

### Исправлено

- **Root App `recurse: true`** применял манифесты в namespace `argocd`.
  Решение: `directory.recurse: false`
- **`checkoutservice`/`shippingservice`: `exec: "/src/server": is a directory`**.
  Причина: `WORKDIR /src/<svc>` в финальном stage создавал каталог, а
  `COPY --from=builder ... /src/server` копировал бинарник в него. Решение:
  `WORKDIR /src` + `COPY ... /src/server`
- **`frontend` падал на старте**: `SHOPPING_ASSISTANT_SERVICE_ADDR` не задан,
  `mustMapEnv` паникует на пустой строке. Решение:
  `SHOPPING_ASSISTANT_SERVICE_ADDR: "disabled"`
- **CRLF в `kustomization.yaml`**: файл сохранён с Windows-переносами,
  ArgoCD не смог его распарсить. Решение: `.gitattributes` + `dos2unix`
- **`cartservice` build context**: Dockerfile лежит в `src/cartservice/src`,
  а не в `src/cartservice`. Решение: отдельный `CTX` в пайплайне

### Известные проблемы

- `online-boutique` Application без sync-wave — синхронизируется в волне `0`,
  раньше GitLab (wave `4`). Работает, потому что образы уже в Harbor
- 2 из 4 алертов не могут сработать — [L-13](docs/known-limitations.md#l-13-два-алерта-online-boutique-не-могут-сработать)
- Панели SLO-дашборда могут быть пустыми — [L-14](docs/known-limitations.md#l-14-панели-slo-дашборда-могут-быть-пустыми)
- Дашборд вне GitOps — [L-10](docs/known-limitations.md#l-10-часть-манифестов-вне-gitops)

---

## Сводка по этапам

| Этап | Содержание | Ключевые версии | Проблемы |
|---|---|---|---|
| 1 | VM, ОС, Ansible | Ubuntu 22.04, Ansible | Нет публичного IP |
| 2 | Kubernetes, сеть | k8s v1.30.4, Kubespray v2.26.0, Cilium v1.16.1, kube-vip | Cilium `False`/`false`, kube-proxy `:10249` |
| 3 | Ingress, TLS, DNS | ingress-nginx 4.11.3, cert-manager v1.16.2, external-dns 1.15.0 | external-dns DPI, staging TLS |
| 4 | Storage, observability | Longhorn, kube-prometheus-stack 65.5.0, Loki 6.21.0, Promtail 6.16.6, Tempo 1.18.2, OTel 0.108.0 | PVC-опечатка, Longhorn mismatch, orphan volume |
| 5 | Secrets, registry | Vault 0.28.1, ESO 0.10.4, Harbor 1.15.1 | Vault dev, `kv/`-префикс, Multi-Attach |
| 6 | CI/CD | GitLab CE 17.11.7, Runner 19.5.1, Kaniko v1.23.2 | bitnamilegacy, Runner x509, Kaniko auth |
| 7 | GitOps, приложение | ArgoCD 7.6.12, Online Boutique v1.0.0/v1.0.4 | `is a directory`, `mustMapEnv`, CRLF |

---

## Ссылки

- [README.md](README.md) — обзор платформы
- [docs/architecture.md](docs/architecture.md) — архитектура
- [docs/deployment.md](docs/deployment.md) — развёртывание с нуля
- [docs/troubleshooting.md](docs/troubleshooting.md) — все грабли
- [docs/known-limitations.md](docs/known-limitations.md) — ограничения
