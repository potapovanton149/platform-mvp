# Observability

Документ описывает стек наблюдаемости платформы: метрики (Prometheus + Grafana + Alertmanager), логи (Loki + Promtail) и трейсы (Tempo + OpenTelemetry Collector). Все компоненты разворачиваются через ArgoCD (sync-wave `2`), исходные конфигурации — в [`k8s/values/`](../k8s/values) и [`k8s/manifests/`](../k8s/manifests).

- [1. Состав стека](#1-состав-стека)
- [2. Prometheus](#2-prometheus)
- [3. Grafana](#3-grafana)
- [4. Alertmanager](#4-alertmanager)
- [5. Алерты](#5-алерты)
- [6. Loki + Promtail](#6-loki--promtail)
- [7. Tempo + OpenTelemetry Collector](#7-tempo--opentelemetry-collector)
- [8. Проверка стека](#8-проверка-стека)
- [9. Известные ограничения](#9-известные-ограничения)

---

## 1. Состав стека

| Компонент | Namespace | Версия | ArgoCD Application | Sync-wave | Назначение |
|---|---|---|---|---|---|
| kube-prometheus-stack (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics, Prometheus Operator) | `monitoring` | chart `65.5.0` | [`21-kube-prometheus-stack.yaml`](../k8s/apps/21-kube-prometheus-stack.yaml) | 2 | Метрики, дашборды, алертинг |
| Loki | `logging` | chart `6.21.0` | [`22-loki.yaml`](../k8s/apps/22-loki.yaml) | 2 | Хранилище логов |
| Promtail | `logging` | chart `6.16.6` | [`22a-promtail.yaml`](../k8s/apps/22a-promtail.yaml) | 2 | Сбор логов с нод |
| Tempo | `tracing` | chart `1.18.2` | [`23-tempo.yaml`](../k8s/apps/23-tempo.yaml) | 2 | Хранилище трейсов |
| OpenTelemetry Collector | `tracing` | chart `0.108.0` | [`24-otel-collector.yaml`](../k8s/apps/24-otel-collector.yaml) | 2 | Приём OTLP, маршрутизация в Tempo |
| PrometheusRule `online-boutique` | `monitoring` | — | [`61-platform-alerts.yaml`](../k8s/apps/61-platform-alerts.yaml) | 5 | 4 алерта приложения |
| Дашборд `grafana-dashboard-online-boutique-slo` | `monitoring` | — | не управляется ArgoCD (см. §3.3) | — | SLO-дашборд приложения |

Схема потоков сигналов:

```
                     ┌──────────────────────────────────────────────┐
   node-exporter ────┤                                              │
   kube-state-metrics┤                                              │
   ServiceMonitor'ы ─┤──► Prometheus ──► Grafana ◄── Loki ◄── Promtail ◄── /var/log/pods
   OTel :8889 ───────┘         │                    ▲
                               │                    │ tracesToLogsV2
                               ▼                    │
                          Alertmanager ──► Telegram│
                                                    │
   Online Boutique ──OTLP:4317──► OTel Collector ──► Tempo
```

---

## 2. Prometheus

### 2.1. Параметры

Источник: [`k8s/values/kube-prometheus-stack.yaml`](../k8s/values/kube-prometheus-stack.yaml).

| Параметр | Значение | Комментарий |
|---|---|---|
| `prometheus.prometheusSpec.replicas` | `1` | Без HA — учебный проект |
| `retention` | `5d` | Хранение метрик по времени |
| `retentionSize` | `4GB` | Жёсткий лимит по объёму TSDB |
| `storageSpec.volumeClaimTemplate` | `longhorn`, `ReadWriteOnce`, `10Gi` | PVC на Longhorn |
| `resources` | requests `200m` / `1Gi`, limits `1000m` / `2Gi` | |
| `ruleSelectorNilUsesHelmValues` | `false` | Prometheus видит **все** PrometheusRule в кластере |
| `serviceMonitorSelectorNilUsesHelmValues` | `false` | Видит все ServiceMonitor |
| `podMonitorSelectorNilUsesHelmValues` | `false` | Видит все PodMonitor |
| `probeSelectorNilUsesHelmValues` | `false` | Видит все Probe |
| `scrapeConfigSelectorNilUsesHelmValues` | `false` | Видит все ScrapeConfig |

Значение `*SelectorNilUsesHelmValues: false` — ключевое: без него Prometheus скрейпил бы только объекты с меткой `release: kube-prometheus-stack`, и ServiceMonitor'ы сторонних чартов (Loki, Tempo, OTel, ESO) остались бы невидимыми.

### 2.2. Что скрейпится

| Job / источник | Откуда | Метрики |
|---|---|---|
| `node-exporter` | DaemonSet на всех 6 нодах | CPU, RAM, диск, сеть |
| `kube-state-metrics` | Deployment в `monitoring` | Состояние объектов k8s (Deployment, Pod, PVC) |
| `kubelet`, `coredns`, `kube-apiserver`, `kube-scheduler`, `kube-controller-manager` | ServiceMonitor'ы чарта | Служебные метрики control plane |
| `loki` | ServiceMonitor (`release: kube-prometheus-stack`) | Метрики Loki |
| `tempo` | ServiceMonitor | Метрики Tempo |
| `otel-collector` | ServiceMonitor, endpoint `metrics` (`:8889`, interval `30s`) | Метрики коллектора + метрики приложения, экспортированные из OTLP |
| `external-secrets`, `external-secrets-webhook`, `external-secrets-cert-controller` | ServiceMonitor'ы | Метрики ESO |
| `longhorn` | ServiceMonitor из vendored-чарта | Метрики хранилища |
| `cert-manager` | ServiceMonitor'ы чарта | Метрики сертификатов |

`defaultRules.rules.kubeProxy: false` — правила kube-proxy отключены, так как в кластере используется Cilium без замены kube-proxy, и метрик `kubeproxy_*` нет. `etcd: false` — etcd развёрнут как host-сервис, метрики не собираются.

### 2.3. Проверка

```bash
# Все targets и их состояние
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090/targets

# Быстрая проверка через API
kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | head -c 2000

# Количество активных targets
kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
  | tr ',' '\n' | grep -c '"scrapeUrl"'
```

Полезные запросы в UI (`http://localhost:9090`):

```promql
# Ноды, которые не скрейпятся
up{job="node-exporter"} == 0

# Доступные реплики приложения
kube_deployment_status_replicas_available{namespace="online-boutique"}

# Использование CPU по нодам, %
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Свободное место на диске, %
(1 - node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|fuse.lxcfs"}) * 100
```

Web-доступ: `https://prometheus.platform-mvp-potapov.ru` (ingress, ClusterIssuer `letsencrypt-staging`, Secret `prometheus-tls`).

---

## 3. Grafana

### 3.1. Доступ и параметры

| Параметр | Значение |
|---|---|
| URL | `https://grafana.platform-mvp-potapov.ru` |
| Логин | `admin` |
| Пароль | см. `grafana.adminPassword` в [`k8s/values/kube-prometheus-stack.yaml`](../k8s/values/kube-prometheus-stack.yaml) (в учебном проекте хранится в values — см. [known-limitations.md](known-limitations.md)) |
| `grafana.ini.server.root_url` | `https://grafana.platform-mvp-potapov.ru` |
| `security.allow_embedding` | `true` |
| Persistence | `longhorn`, `5Gi`, `ReadWriteOnce` |
| Resources | requests `100m` / `256Mi`, limits `500m` / `512Mi` |
| TLS | Secret `grafana-tls`, ClusterIssuer `letsencrypt-staging` |

### 3.2. Datasources

Дополнительные источники данных объявлены декларативно в `grafana.additionalDataSources`:

| Имя | Тип | URL | Особенности |
|---|---|---|---|
| `Prometheus` | prometheus | встроенный (default) | Основной источник метрик |
| `Loki` | loki | `http://loki.logging.svc.cluster.local:3100` | `maxLines: 1000`, `timeout: 60` |
| `Tempo` | tempo | `http://tempo.tracing.svc.cluster.local:3200` | Корреляция (см. ниже) |

Корреляция сигналов в datasource Tempo:

| Настройка | Значение | Что даёт |
|---|---|---|
| `tracesToLogsV2` | datasource `loki`, сдвиг `-5m` / `+5m`, `filterByTraceID: true` | Из спана → логи по `traceID` |
| `tracesToMetrics` | datasource `prometheus`, сдвиг `-5m` / `+5m` | Из спана → метрики за тот же интервал |
| `serviceMap` | datasource `prometheus` | Карта зависимостей сервисов |
| `nodeGraph` | `enabled: true` | Граф спанов |
| `lokiSearch` | datasource `loki` | Поиск логов из Tempo |

### 3.3. Дашборды

**Стандартные K8s-дашборды** поставляются чартом `kube-prometheus-stack` (Grafana Dashboards: `Kubernetes / Compute Resources / Cluster`, `/ Namespace (Pods)`, `/ Node`, `Node Exporter / Nodes`, `Kubernetes / Networking`, и др.). Они доступны сразу после синхронизации Application `kube-prometheus-stack`.

**SLO-дашборд Online Boutique** — ConfigMap [`k8s/manifests/dashboards/online-boutique-slo.yaml`](../k8s/manifests/dashboards/online-boutique-slo.yaml):

| Свойство | Значение |
|---|---|
| Имя ConfigMap | `grafana-dashboard-online-boutique-slo` |
| Namespace | `monitoring` |
| Метка для sidecar | `grafana_dashboard: "1"` |
| UID дашборда | `ob-slo` |
| Заголовок | `Online Boutique SLO` |
| Теги | `online-boutique`, `slo` |
| Интервал по умолчанию | `now-6h` … `now` |

Панели:

| Панель | Тип | Запрос (сокращённо) |
|---|---|---|
| RPS by service | timeseries | `sum by (service_name) (rate(grpc_server_handled_total{namespace="online-boutique"}[1m]))` |
| Latency p95 by service | timeseries | `histogram_quantile(0.95, sum by (le, service_name) (rate(grpc_server_handling_seconds_bucket{namespace="online-boutique"}[5m])))` |
| Error rate (5xx + gRPC non-OK) | timeseries | `sum by (service_name) (rate(grpc_server_handled_total{...,grpc_code!="OK"}[5m])) / sum by (service_name) (rate(grpc_server_handled_total{...}[5m]))` |
| SLO: availability — target 99% | timeseries | `1 - (sum(rate(grpc_server_handled_total{...,grpc_code!="OK"}[5m])) / sum(rate(grpc_server_handled_total{...}[5m])))` |
| Requests total (1h) | stat | `sum(increase(grpc_server_handled_total{namespace="online-boutique"}[1h]))` |
| p95 (1h) | stat | `histogram_quantile(0.95, sum by (le) (rate(grpc_server_handling_seconds_bucket{namespace="online-boutique"}[1h])))` |
| Pods Running | stat | `count(kube_pod_status_phase{namespace="online-boutique",phase="Running"} == 1)` |

> **Важно.** Каталог `k8s/manifests/dashboards/` **не подключён ни к одному ArgoCD Application** (Application `namespaces` берёт только `namespaces.yaml`, `platform-certs` — `k8s/manifests/certs`, `platform-alerts` — `k8s/manifests/alerts`). Дашборд нужно применять вручную:
>
> ```bash
> kubectl apply -f k8s/manifests/dashboards/online-boutique-slo.yaml
> ```
>
> После применения sidecar Grafana (`sidecar.dashboards.enabled: true`, `label: grafana_dashboard`, `searchNamespace: ALL`) подхватит ConfigMap в течение ~1 минуты.

### 3.4. Проверка

```bash
# Grafana UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# → http://localhost:3000

# Список загруженных дашбордов через API
kubectl -n monitoring exec -it deploy/kube-prometheus-stack-grafana -c grafana -- \
  wget -qO- --header="Authorization: Basic $(printf 'admin:%s' "$GRAFANA_PASS" | base64)" \
  http://localhost:3000/api/search?type=dash-db

# Проверить, что sidecar увидел ConfigMap
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard | tail -20
```

---

## 4. Alertmanager

### 4.1. Параметры

| Параметр | Значение |
|---|---|
| URL | `https://alertmanager.platform-mvp-potapov.ru` |
| Реплики | `1` |
| Persistence | `longhorn`, `5Gi`, `ReadWriteOnce` |
| Resources | requests `50m` / `128Mi`, limits `200m` / `256Mi` |
| Секреты | `alertmanager-telegram` (монтируется в `/etc/alertmanager/secrets/alertmanager-telegram/`) |
| TLS | Secret `alertmanager-tls`, ClusterIssuer `letsencrypt-staging` |

### 4.2. Маршрутизация

```yaml
global:
  resolve_timeout: 5m
route:
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 3h
  receiver: 'telegram'
  routes:
    - match:
        severity: critical
      receiver: 'telegram'
receivers:
  - name: 'telegram'
    telegram_configs:
      - bot_token_file: /etc/alertmanager/secrets/alertmanager-telegram/bot-token
        chat_id: 5476863930
        parse_mode: 'HTML'
        send_resolved: true
inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'namespace']
```

| Параметр | Значение | Смысл |
|---|---|---|
| `group_by` | `alertname`, `namespace` | Алерты одного типа в одном namespace группируются в одно сообщение |
| `group_wait` | `30s` | Ожидание «дозагрузки» алертов перед первой отправкой |
| `group_interval` | `5m` | Интервал между обновлениями группы |
| `repeat_interval` | `3h` | Повтор уведомления, если алерт не погас |
| `send_resolved` | `true` | Отправлять сообщение о восстановлении |
| `parse_mode` | `HTML` | Разметка сообщений |
| `inhibit_rules` | critical подавляет warning | При падении сервиса не приходит дублирующий warning |

### 4.3. Секрет `alertmanager-telegram`

Создаётся External Secrets Operator из Vault (см. [security.md](security.md)):

| Ключ Secret | Источник в Vault |
|---|---|
| `bot-token` | `kv/platform/telegram` → `bot-token` |
| `chat-id` | `kv/platform/telegram` → `chat-id` |

Манифест: [`k8s/manifests/external-secrets/telegram-alertmanager.yaml`](../k8s/manifests/external-secrets/telegram-alertmanager.yaml).

Проверка:

```bash
kubectl -n monitoring get secret alertmanager-telegram
kubectl -n monitoring get externalsecret telegram-alertmanager -o jsonpath='{.status.conditions}'
```

### 4.4. Проверка доставки

```bash
# UI Alertmanager
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# → http://localhost:9093

# Список активных алертов
kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  wget -qO- http://localhost:9093/api/v2/alerts

# Проверить конфиг на валидность
kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool check-config /etc/alertmanager/config/alertmanager.yaml

# Тестовое уведомление (обходит Prometheus)
kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add test_alert severity=warning --alertmanager.url=http://localhost:9093
```

> **Known limitation.** `api.telegram.org` недоступен из сети стенда (DPI/РКН). Alertmanager формирует уведомления, но доставка в Telegram не происходит — в логах видны ошибки `dial tcp ... i/o timeout`. Подробнее — [known-limitations.md](known-limitations.md). Для демонстрации используется скриншот успешной доставки, сделанный при доступном канале, либо проверка через UI Alertmanager.

---

## 5. Алерты

### 5.1. Платформенные алерты

Объявлены в `additionalPrometheusRulesMap.platform-alerts` ([`k8s/values/kube-prometheus-stack.yaml`](../k8s/values/kube-prometheus-stack.yaml)), группа `platform`.

| Алерт | Условие | `for` | Severity |
|---|---|---|---|
| `NodeDown` | `up{job="node-exporter"} == 0` | `2m` | critical |
| `PodCrashLooping` | `rate(kube_pod_container_status_restarts_total[5m]) > 0` | `10m` | warning |
| `HighCPUUsage` | `100 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100 > 80` | `10m` | warning |
| `HighMemoryUsage` | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 90` | `5m` | warning |
| `DiskSpaceLow` | `(1 - node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs"} / node_filesystem_size_bytes{...}) * 100 > 85` | `5m` | warning |
| `CertificateExpiringSoon` | `(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 7` | `1h` | warning |

### 5.2. Алерты Online Boutique

Объявлены в PrometheusRule `online-boutique` ([`k8s/manifests/alerts/online-boutique.yaml`](../k8s/manifests/alerts/online-boutique.yaml)), namespace `monitoring`, метка `release: kube-prometheus-stack`, группа `online-boutique.rules`, `interval: 30s`.

| Алерт | Условие | `for` | Severity | Смысл |
|---|---|---|---|---|
| `OBHighErrorRate` | `sum(rate(nginx_ingress_controller_requests{namespace="online-boutique",status=~"5.."}[5m])) / sum(rate(nginx_ingress_controller_requests{namespace="online-boutique"}[5m])) > 0.05` | `5m` | warning | Доля 5xx на ingress выше 5% |
| `OBHighLatency` | `histogram_quantile(0.95, sum by (le)(rate(nginx_ingress_controller_request_duration_seconds_bucket{namespace="online-boutique"}[5m]))) > 1` | `5m` | warning | p95 времени ответа ingress выше 1 с |
| `OBServiceDown` | `kube_deployment_status_replicas_available{namespace="online-boutique"} == 0` | `2m` | critical | У Deployment нет доступных реплик |
| `OBPodCrashLooping` | `increase(kube_pod_container_status_restarts_total{namespace="online-boutique"}[10m]) > 3` | `5m` | warning | Более 3 рестартов контейнера за 10 минут |

Все четыре алерта имеют метку `app: online-boutique`, что позволяет фильтровать их в Alertmanager и Grafana.

### 5.3. Проверка правил

```bash
# Правила загружены Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090/rules

# Через API
kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' | tr ',' '\n' | grep -E '"name"|"state"'

# PrometheusRule на месте
kubectl -n monitoring get prometheusrule
kubectl -n monitoring get prometheusrule online-boutique -o yaml | head -40
```

Проверить срабатывание `OBServiceDown` (безопасно, откатывается):

```bash
kubectl -n online-boutique scale deploy frontend --replicas=0
# через ~2 минуты алерт перейдёт в firing
kubectl -n online-boutique scale deploy frontend --replicas=2
```

---

## 6. Loki + Promtail

### 6.1. Loki

Источник: [`k8s/values/loki.yaml`](../k8s/values/loki.yaml).

| Параметр | Значение |
|---|---|
| `deploymentMode` | `SingleBinary` (все компоненты в одном поде) |
| `loki.auth_enabled` | `false` |
| `commonConfig.replication_factor` | `1` |
| `storage.type` | `filesystem` |
| `schemaConfig` | `tsdb`, schema `v13`, с `2024-01-01` |
| `limits_config.retention_period` | `168h` (7 суток) |
| `limits_config.ingestion_rate_mb` | `10` |
| `limits_config.ingestion_burst_size_mb` | `20` |
| `limits_config.max_query_series` | `5000` |
| `limits_config.max_query_parallelism` | `16` |
| `limits_config.reject_old_samples_max_age` | `168h` |
| `limits_config.allow_structured_metadata` | `true` |
| `compactor.retention_enabled` | `true`, `delete_request_store: filesystem`, `compaction_interval: 10m`, `retention_delete_delay: 2h` |
| `singleBinary.replicas` | `1` |
| Persistence | `longhorn`, `20Gi`, `ReadWriteOnce` |
| Resources | requests `100m` / `512Mi`, limits `1000m` / `1Gi` |
| `read` / `write` / `backend` | `replicas: 0` (не используются в SingleBinary) |
| `chunksCache` / `resultsCache` | `enabled: false` |
| `gateway` | `enabled: false` |
| `monitoring.serviceMonitor` | `enabled: true`, метка `release: kube-prometheus-stack` |

Адрес приёма логов: `http://loki.logging.svc.cluster.local:3100/loki/api/v1/push`.

### 6.2. Promtail

Источник: [`k8s/values/promtail.yaml`](../k8s/values/promtail.yaml).

| Параметр | Значение |
|---|---|
| Режим | DaemonSet (по поду на каждую ноду, включая control plane) |
| `config.clients[0].url` | `http://loki.logging.svc.cluster.local:3100/loki/api/v1/push` |
| `extraRelabelConfigs` | `__meta_kubernetes_pod_node_name` → метка `node` |
| Tolerations | `NoSchedule` / `Exists` (чтобы работал на control plane) |
| Resources | requests `50m` / `64Mi`, limits `300m` / `256Mi` |
| HostPath | `/var/log`, `/var/lib/docker/containers` (read-only) |
| `serviceMonitor` | `enabled: true` |

Метки, которые автоматически проставляет Promtail: `namespace`, `pod`, `container`, `app`, `node`, `job`.

### 6.3. Примеры LogQL

```logql
# Все логи приложения
{namespace="online-boutique"}

# Логи конкретного сервиса
{namespace="online-boutique", pod=~"frontend-.*"}

# Только строки с ошибками
{namespace="online-boutique"} |= "error"

# JSON-парсинг и фильтр по полю
{namespace="online-boutique"} | json | severity="error"

# Логи ingress с кодом 5xx
{namespace="ingress-nginx"} | json | status >= 500

# Частота ошибок по подам
sum by (pod) (rate({namespace="online-boutique"} |= "error" [5m]))

# Поиск по traceID (корреляция с Tempo)
{namespace="online-boutique"} |= "<trace_id>"

# Логи конкретной ноды
{node="worker-1"}

# Топ-10 сообщений по частоте
topk(10, sum by (line) (count_over_time({namespace="online-boutique"} [1h])))
```

### 6.4. Проверка

```bash
# Поды Loki и Promtail
kubectl -n logging get pods
kubectl -n logging get ds promtail

# Loki готов принимать запросы
kubectl -n logging port-forward svc/loki 3100:3100
curl -s http://localhost:3100/ready
curl -s http://localhost:3100/metrics | grep -E 'loki_ingester_streams|loki_distributor_lines_received_total'

# Проверить, что логи приходят (запрос за последние 5 минут)
curl -sG http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="online-boutique"}' \
  --data-urlencode "start=$(date -d '-5 min' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=5'

# Promtail видит файлы
kubectl -n logging logs ds/promtail --tail=30 | grep -i 'tail routine'
```

---

## 7. Tempo + OpenTelemetry Collector

### 7.1. Поток трейсов

```
Online Boutique (11 сервисов)
   │  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.tracing.svc:4317
   ▼
OTel Collector (deployment, ns tracing)
   │  processors: memory_limiter → batch
   │  exporters:  otlp → tempo.tracing.svc.cluster.local:4317
   ▼
Tempo (ns tracing, retention 48h, local storage)
   ▲
   │  datasource Tempo в Grafana (tracesToLogsV2 → Loki, tracesToMetrics → Prometheus)
```

### 7.2. Tempo

Источник: [`k8s/values/tempo.yaml`](../k8s/values/tempo.yaml).

| Параметр | Значение |
|---|---|
| `tempo.retention` | `48h` |
| `tempo.receivers.otlp` | gRPC `0.0.0.0:4317`, HTTP `0.0.0.0:4318` |
| `tempo.storage.trace.backend` | `local`, путь `/var/tempo/traces` |
| `tempo.storage.trace.wal` | `/var/tempo/wal` |
| `tempo.metricsGenerator.enabled` | `false` |
| Persistence | `longhorn`, `20Gi`, `ReadWriteOnce` |
| Resources | requests `100m` / `256Mi`, limits `1000m` / `1Gi` |
| `tempoQuery` | `enabled: false` (используется Grafana) |
| `service.type` | `ClusterIP` |
| `serviceMonitor` | `enabled: true` |

### 7.3. OpenTelemetry Collector

Источник: [`k8s/values/otel-collector.yaml`](../k8s/values/otel-collector.yaml).

| Параметр | Значение |
|---|---|
| `mode` | `deployment`, `replicaCount: 1` |
| `fullnameOverride` | `otel-collector` (Service `otel-collector`) |
| Образ | `otel/opentelemetry-collector-contrib` |
| Receivers | `otlp` gRPC `:4317`, HTTP `:4318` |
| Processors | `memory_limiter` (`check_interval: 1s`, `limit_percentage: 75`, `spike_limit_percentage: 20`), `batch` |
| Exporter traces | `otlp` → `tempo.tracing.svc.cluster.local:4317`, `tls.insecure: true` |
| Exporter metrics | `prometheus` на `0.0.0.0:8889`, `resource_to_telemetry_conversion: true` |
| Pipelines | `traces: [otlp] → [memory_limiter, batch] → [otlp]`; `metrics: [otlp] → [memory_limiter, batch] → [prometheus]` |
| Telemetry | логи `info`, метрики на `0.0.0.0:8888` |
| Resources | requests `100m` / `128Mi`, limits `500m` / `512Mi` |
| `serviceMonitor` | `enabled: true`, endpoint `metrics` (`:8889`, `30s`, `/metrics`) |

### 7.4. Интеграция с приложением

Каждый из 11 сервисов Online Boutique получает переменные окружения:

```yaml
env:
  - {name: OTEL_SERVICE_NAME, value: "frontend"}
  - {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector.tracing.svc:4317"}
```

`OTEL_SERVICE_NAME` задаёт имя сервиса в трейсах и в метриках (после `resource_to_telemetry_conversion` оно становится меткой `service_name`). Профайлеры отключены (`DISABLE_PROFILER: "1"` / `ENABLE_PROFILER: "0"`), чтобы не расходовать ресурсы.

### 7.5. Проверка

```bash
# Поды
kubectl -n tracing get pods

# OTel Collector принимает и отправляет
kubectl -n tracing logs deploy/otel-collector --tail=50
# ожидаем отсутствие ошибок экспорта; при проблемах — "failed to send to tempo"

# Tempo API: список сервисов, от которых есть трейсы
kubectl -n tracing port-forward svc/tempo 3200:3200
curl -s 'http://localhost:3200/api/search/tags' | head -c 500
curl -s 'http://localhost:3200/api/search?tags=service.name%3Dfrontend&limit=5'

# Метрики коллектора
kubectl -n tracing port-forward svc/otel-collector 8889:8889
curl -s http://localhost:8889/metrics | grep -E '^otelcol_(receiver|exporter)_' | head -20
```

В Grafana: **Explore → Tempo → Search** — выбрать `Service Name = frontend`, нажать **Run query**. Из найденного спана доступны кнопки перехода в Loki (по `traceID`) и в Prometheus (за тот же интервал).

---

## 8. Проверка стека

### 8.1. Сводная проверка

```bash
# Все Application observability-стека синхронизированы
kubectl -n argocd get applications | grep -E 'kube-prometheus-stack|loki|promtail|tempo|otel-collector|platform-alerts'

# Поды во всех трёх namespace
kubectl -n monitoring get pods
kubectl -n logging get pods
kubectl -n tracing get pods

# PVC созданы и привязаны
kubectl -n monitoring get pvc
kubectl -n logging get pvc
kubectl -n tracing get pvc

# Ingress'ы
kubectl -n monitoring get ingress
```

Ожидаемое состояние: все Application — `Synced` / `Healthy`; все поды — `Running`; PVC — `Bound`.

### 8.2. URLs

| Сервис | URL | Доступ |
|---|---|---|
| Grafana | `https://grafana.platform-mvp-potapov.ru` | `admin` + пароль из values |
| Prometheus | `https://prometheus.platform-mvp-potapov.ru` | без аутентификации |
| Alertmanager | `https://alertmanager.platform-mvp-potapov.ru` | без аутентификации |

> Сертификаты выпущены ClusterIssuer `letsencrypt-staging` — браузер покажет предупреждение о недоверенном CA. Это ожидаемо, см. [known-limitations.md](known-limitations.md).

### 8.3. Port-forward (если ingress недоступен)

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
kubectl -n logging    port-forward svc/loki 3100:3100
kubectl -n tracing    port-forward svc/tempo 3200:3200
kubectl -n tracing    port-forward svc/otel-collector 8889:8889
```

### 8.4. Диагностика

| Симптом | Где смотреть |
|---|---|
| Targets в состоянии `DOWN` | `http://localhost:9090/targets`, вкладка Errors |
| Нет метрик приложения | `curl :8889/metrics` на OTel Collector; проверить `OTEL_EXPORTER_OTLP_ENDPOINT` в поде |
| Нет логов в Grafana | `kubectl -n logging logs ds/promtail`; проверить `curl :3100/ready` |
| Нет трейсов | `kubectl -n tracing logs deploy/otel-collector`; `curl :3200/api/search` |
| Алерт не уходит в Telegram | `kubectl -n monitoring logs alertmanager-...`; см. §4.4 |
| Grafana не видит дашборд | `kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard` |

Полный список проблем и решений — [troubleshooting.md](troubleshooting.md).

---

## 9. Известные ограничения

| Ограничение | Причина | Следствие |
|---|---|---|
| Prometheus без HA, retention `5d` / `4GB` | Один реплейсет, ограниченные ресурсы стенда | При потере PVC история метрик теряется; данные старше 5 суток недоступны |
| Loki `SingleBinary`, `filesystem`, retention `168h` | Упрощение архитектуры | Нет горизонтального масштабирования; при потере PVC логи теряются |
| Tempo `local` backend, retention `48h` | Упрощение архитектуры | Трейсы старше 2 суток недоступны |
| Доставка в Telegram не работает | `api.telegram.org` заблокирован (DPI) | Алерты видны в UI Alertmanager, но не в мессенджере |
| Метрики ingress-nginx не скрейпятся | В [`k8s/values/ingress-nginx.yaml`](../k8s/values/ingress-nginx.yaml) `controller.metrics.serviceMonitor.enabled: false`, а `prometheus.io/*`-аннотации Prometheus Operator не обрабатывает | Алерты `OBHighErrorRate` и `OBHighLatency` (построены на `nginx_ingress_controller_*`) не могут сработать |
| Панели SLO-дашборда могут быть пустыми | Панели написаны под нативные Prometheus-метрики gRPC (`grpc_server_handled_total`), а приложение отдаёт OTLP, который Collector конвертирует в `rpc_server_*` | Требуется либо включить Prometheus-экспортёр в приложении, либо переписать запросы под имена OTel-метрик |
| Дашборд не управляется ArgoCD | Каталог `k8s/manifests/dashboards/` не подключён ни к одному Application | Применяется вручную (`kubectl apply -f`) |
| Grafana admin-пароль в values | Учебный проект | См. [known-limitations.md](known-limitations.md) |

### Как включить скрейпинг ingress-nginx

Если нужно, чтобы `OBHighErrorRate` и `OBHighLatency` работали:

```yaml
# k8s/values/ingress-nginx.yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: kube-prometheus-stack
```

После коммита ArgoCD синхронизирует Application `ingress-nginx`, и метрики `nginx_ingress_controller_*` появятся в Prometheus.

---

## Связанные документы

- [architecture.md](architecture.md) — место observability-стека в общей архитектуре
- [deployment.md](deployment.md) — порядок развёртывания и проверки после каждого шага
- [security.md](security.md) — как секреты (Telegram-токен) попадают в Alertmanager
- [application.md](application.md) — Online Boutique, SLO и алерты приложения
- [troubleshooting.md](troubleshooting.md) — диагностика проблем стека
- [known-limitations.md](known-limitations.md) — полный список ограничений
