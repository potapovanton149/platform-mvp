# Online Boutique — приложение платформы

Документ описывает демонстрационное приложение: состав сервисов, сборку образов, особенности Dockerfile, развёртывание через ArgoCD, ingress и TLS, SLO-дашборд и алерты.

- [1. Что это](#1-что-это)
- [2. Состав сервисов](#2-состав-сервисов)
- [3. Исходный код и форк](#3-исходный-код-и-форк)
- [4. Сборка образов](#4-сборка-образов)
- [5. Исправления Dockerfile](#5-исправления-dockerfile)
- [6. Развёртывание через ArgoCD](#6-развёртывание-через-argocd)
- [7. Ingress и TLS](#7-ingress-и-tls)
- [8. Наблюдаемость](#8-наблюдаемость)
- [9. Проверка](#9-проверка)
- [10. Обновление версии](#10-обновление-версии)
- [11. Известные ограничения](#11-известные-ограничения)

---

## 1. Что это

**Online Boutique** (Google `microservices-demo`) — эталонное микросервисное приложение интернет-магазина. Используется как нагрузочный пример для демонстрации платформы: 11 сервисов на 6 языках, gRPC-взаимодействие, Redis как хранилище корзины, генератор нагрузки.

Приложение не является частью платформы — это **рабочая нагрузка**, которая проверяет, что платформа умеет: собирать образы (CI), хранить их (Harbor), доставлять (ArgoCD), маршрутизировать трафик (ingress), выпускать сертификаты (cert-manager), собирать метрики/логи/трейсы (observability) и алертить.

---

## 2. Состав сервисов

| Сервис | Язык | Порт (container) | Порт (service) | Реплики | Образ (тег) |
|---|---|---|---|---|---|
| `frontend` | Go | `8080` | `80` → `8080` | **2** | `frontend:v1.0.0` |
| `cartservice` | C# (.NET) | `7070` | `7070` | 1 | `cartservice:v1.0.0` |
| `productcatalogservice` | Go | `3550` | `3550` | 1 | `productcatalogservice:v1.0.0` |
| `currencyservice` | Node.js | `7000` | `7000` | 1 | `currencyservice:v1.0.0` |
| `paymentservice` | Node.js | `50051` | `50051` | 1 | `paymentservice:v1.0.0` |
| `shippingservice` | Go | `50051` | `50051` | 1 | `shippingservice:v1.0.4` |
| `emailservice` | Python | `8080` | `5000` → `8080` | 1 | `emailservice:v1.0.0` |
| `checkoutservice` | Go | `5050` | `5050` | 1 | `checkoutservice:v1.0.4` |
| `recommendationservice` | Python | `8080` | `8080` | 1 | `recommendationservice:v1.0.0` |
| `adservice` | Java | `9555` | `9555` | 1 | `adservice:v1.0.0` |
| `loadgenerator` | Python (Locust) | — | — | 1 | `loadgenerator:v1.0.0` |
| `redis-cart` | Redis 7.2 | `6379` | `6379` | 1 | `redis:7.2-alpine` (публичный) |

Итого: **13 подов** (11 сервисов + `redis-cart` + `loadgenerator`), из них `frontend` — 2 реплики, поэтому 12 Deployment/StatefulSet-объектов.

> Обратите внимание: `shippingservice` и `checkoutservice` используют тег `v1.0.4`, остальные — `v1.0.0`. Это следствие итеративной отладки Dockerfile (см. §5).

### 2.1. Топология вызовов

```
                        ┌──────────────┐
        браузер ───────►│   frontend   │ (2 реплики)
                        └──────┬───────┘
             ┌─────────────────┼──────────────────┬───────────────┐
             ▼                 ▼                  ▼               ▼
   ┌──────────────────┐ ┌─────────────┐ ┌────────────────┐ ┌───────────┐
   │productcatalog    │ │ currency    │ │ recommendation │ │ adservice │
   │service :3550     │ │ service:7000│ │ service :8080  │ │  :9555    │
   └──────────────────┘ └─────────────┘ └────────────────┘ └───────────┘
             │                 │                  │
             ▼                 ▼                  ▼
   ┌──────────────────┐ ┌─────────────┐ ┌────────────────┐
   │  cartservice     │ │  checkout   │ │  shipping      │
   │  :7070 ──► redis │ │  service    │ │  service:50051 │
   └──────────────────┘ │  :5050      │ └────────────────┘
                        └──────┬──────┘
                     ┌─────────┼──────────┐
                     ▼         ▼          ▼
              ┌──────────┐ ┌────────┐ ┌────────────┐
              │ payment  │ │ email  │ │ currency   │
              │ :50051   │ │ :5000  │ │ :7000      │
              └──────────┘ └────────┘ └────────────┘
```

### 2.2. Переменные окружения frontend

```yaml
env:
  - {name: PORT, value: "8080"}
  - {name: PRODUCT_CATALOG_SERVICE_ADDR, value: "productcatalogservice:3550"}
  - {name: CURRENCY_SERVICE_ADDR, value: "currencyservice:7000"}
  - {name: CART_SERVICE_ADDR, value: "cartservice:7070"}
  - {name: RECOMMENDATION_SERVICE_ADDR, value: "recommendationservice:8080"}
  - {name: SHIPPING_SERVICE_ADDR, value: "shippingservice:50051"}
  - {name: CHECKOUT_SERVICE_ADDR, value: "checkoutservice:5050"}
  - {name: AD_SERVICE_ADDR, value: "adservice:9555"}
  - {name: SHOPPING_ASSISTANT_SERVICE_ADDR, value: "disabled"}
  - {name: ENABLE_PROFILER, value: "0"}
  - {name: OTEL_SERVICE_NAME, value: "frontend"}
  - {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector.tracing.svc:4317"}
```

| Переменная | Значение | Комментарий |
|---|---|---|
| `SHOPPING_ASSISTANT_SERVICE_ADDR` | `disabled` | В оригинале сервис `shoppingassistantservice` требует Gemini API; отключён, чтобы не было ошибок в логах |
| `ENABLE_PROFILER` | `0` | Профайлер отключён (экономия ресурсов) |
| `OTEL_SERVICE_NAME` | имя сервиса | Метка `service_name` в трейсах и метриках |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.tracing.svc:4317` | OTLP gRPC в Collector |

Остальные сервисы используют `DISABLE_PROFILER: "1"` (Python/Go-сервисы) вместо `ENABLE_PROFILER: "0"`.

### 2.3. Пробы

| Сервис | Readiness | Liveness |
|---|---|---|
| `frontend` | `GET /_healthz:8080`, `initialDelay 10s`, `period 10s` | `GET /_healthz:8080`, `initialDelay 20s` |
| `redis-cart` | `exec redis-cli ping`, `initialDelay 5s`, `period 10s` | `exec redis-cli ping`, `initialDelay 15s`, `period 20s` |
| Остальные | gRPC health probe (встроенный в образ) | — |

### 2.4. Ресурсы

| Сервис | Requests | Limits |
|---|---|---|
| `frontend` | `100m` / `128Mi` | `500m` / `512Mi` |
| `loadgenerator` | `100m` / `128Mi` | `500m` / `512Mi` |
| `redis-cart` | `50m` / `64Mi` | `200m` / `256Mi` |
| Остальные | `100m` / `128Mi` (типовые) | `200m`–`500m` / `256Mi`–`512Mi` |

### 2.5. Хранилище

`redis-cart` — единственный компонент с PVC:

```yaml
volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn
      resources: {requests: {storage: 1Gi}}
```

`securityContext: {fsGroup: 1000}` — чтобы Redis мог писать в том Longhorn.

---

## 3. Исходный код и форк

| Параметр | Значение |
|---|---|
| Upstream | `https://github.com/GoogleCloudPlatform/microservices-demo` |
| Форк | `https://github.com/potapovanton149/online-boutique` |
| Ветка | `master` |
| Причина форка | Исправления Dockerfile (§5) и адаптация под OTLP |

Форк нужен, потому что upstream-образы собираются с ошибками в текущих версиях базовых образов, а также потому что требуется добавить `OTEL_*`-переменные и убрать зависимость от `shoppingassistantservice`.

---

## 4. Сборка образов

Образы собираются **двумя способами** (подробно — [ci-cd.md](ci-cd.md)):

| Способ | Инструмент | Тег | Параллельность |
|---|---|---|---|
| A. GitLab CI | Kaniko в job-поде | `$CI_COMMIT_SHORT_SHA` | до 4 одновременно (`concurrent: 4`) |
| B. Скрипт | Kaniko в поде namespace `ci` | `v1.0.0` (по умолчанию) | последовательно |

### 4.1. Результат

```
harbor.platform-mvp-potapov.ru/online-boutique/
├── frontend:v1.0.0
├── cartservice:v1.0.0
├── productcatalogservice:v1.0.0
├── currencyservice:v1.0.0
├── paymentservice:v1.0.0
├── shippingservice:v1.0.4
├── emailservice:v1.0.0
├── checkoutservice:v1.0.4
├── recommendationservice:v1.0.0
├── adservice:v1.0.0
├── loadgenerator:v1.0.0
└── cache/            ← кеш слоёв Kaniko (только при сборке через CI)
```

### 4.2. Контексты сборки

| Сервис | Контекст | Особенность |
|---|---|---|
| `frontend` | `src/frontend` | — |
| `cartservice` | `src/cartservice/src` | **на уровень глубже**: `Dockerfile` рядом с `.csproj` |
| `productcatalogservice` | `src/productcatalogservice` | — |
| `currencyservice` | `src/currencyservice` | — |
| `paymentservice` | `src/paymentservice` | — |
| `shippingservice` | `src/shippingservice` | — |
| `emailservice` | `src/emailservice` | — |
| `checkoutservice` | `src/checkoutservice` | — |
| `recommendationservice` | `src/recommendationservice` | — |
| `adservice` | `src/adservice` | — |
| `loadgenerator` | `src/loadgenerator` | — |

### 4.3. Аутентификация в Harbor

Приложение использует Secret `harbor-creds` для pull:

```yaml
spec:
  template:
    spec:
      imagePullSecrets: [{name: harbor-creds}]
```

Создаётся вручную (см. [deployment.md](deployment.md), Шаг 9):

```bash
kubectl -n online-boutique create secret docker-registry harbor-creds \
  --docker-server=harbor.platform-mvp-potapov.ru \
  --docker-username=admin \
  --docker-password='<HARBOR_ADMIN_PASSWORD>'
```

> `redis-cart` использует публичный образ `redis:7.2-alpine` и `imagePullSecrets` не требует.

---

## 5. Исправления Dockerfile

### 5.1. `checkoutservice` и `shippingservice`: `is a directory`

**Симптом:**

```
exec: "/src/server": is a directory
```

Под падает в `CrashLoopBackOff` сразу после старта.

**Причина.** В финальном stage Dockerfile было:

```dockerfile
WORKDIR /src/checkoutservice
COPY --from=builder /src/checkoutservice/server /src/server
ENTRYPOINT ["/src/server"]
```

`WORKDIR /src/checkoutservice` создаёт каталог. Далее `COPY ... /src/server` — если путь `/src/server` уже существует как каталог (из-за предыдущего слоя или `COPY . .`), Docker копирует **бинарник внутрь** каталога, и `/src/server` остаётся каталогом. `ENTRYPOINT ["/src/server"]` пытается исполнить каталог.

**Исправление** (в форке):

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /src
COPY --from=builder /src/checkoutservice/server /src/server
ENTRYPOINT ["/src/server"]
```

Ключевое: `WORKDIR /src` (не `/src/<svc>`), бинарник копируется в `/src/server`.

**Проверка:**

```bash
kubectl -n online-boutique get pods -l app=checkoutservice
# Running, 0 restarts

kubectl -n online-boutique exec deploy/checkoutservice -- ls -la /src
# -rwxr-xr-x  server     ← файл, не каталог
```

### 5.2. `cartservice`: контекст сборки

`cartservice` — единственный сервис, у которого `Dockerfile` лежит в `src/cartservice/src`, а не в корне каталога сервиса. Если указать контекст `src/cartservice`, сборка упадёт с `Dockerfile not found`.

**Правильно:**

```yaml
cartservice: {<<: *build, variables: {SVC: cartservice, CTX: src/cartservice/src}}
```

### 5.3. `frontend`: отключение shoppingassistant

В upstream `frontend` при отсутствии `SHOPPING_ASSISTANT_SERVICE_ADDR` пытается подключиться к `shoppingassistantservice:8080` и пишет ошибки в лог. Установка `disabled` отключает эту ветку кода.

### 5.4. OTLP-переменные

Во все 11 сервисов добавлены:

```yaml
- {name: OTEL_SERVICE_NAME, value: "<svc>"}
- {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector.tracing.svc:4317"}
```

Без них трейсы не отправляются, и Tempo остаётся пустым.

---

## 6. Развёртывание через ArgoCD

### 6.1. Application

Манифест: [`k8s/apps/60-online-boutique.yaml`](../k8s/apps/60-online-boutique.yaml).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: online-boutique
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/potapovanton149/platform-mvp.git
    targetRevision: master
    path: k8s/apps/online-boutique
  destination:
    server: https://kubernetes.default.svc
    namespace: online-boutique
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
  ignoreDifferences:
    - group: apps
      kind: StatefulSet
      jsonPointers:
        - /spec/volumeClaimTemplates
```

| Параметр | Значение | Комментарий |
|---|---|---|
| `sync-wave` | **не задана** (по умолчанию `0`) | Application не имеет аннотации `argocd.argoproj.io/sync-wave` |
| `path` | `k8s/apps/online-boutique` | Каталог с Kustomize |
| `CreateNamespace` | `false` | Namespace создаётся Application `namespaces` (wave `-1`) |
| `ignoreDifferences` | `/spec/volumeClaimTemplates` у StatefulSet | Иначе `redis-cart` вечно `OutOfSync`: контроллер дописывает поля в `volumeClaimTemplates` |
| `prune` / `selfHeal` | `true` | Полный GitOps |

> **Важно.** В старых версиях документации указывалась sync-wave `5`. Фактически аннотация отсутствует, и Application синхронизируется в волне по умолчанию (`0`) — то есть **раньше** GitLab (wave `4`) и алертов (wave `5`). Это работает, потому что образы уже лежат в Harbor, а `harbor-creds` создаётся вручную до первого sync.

### 6.2. Kustomize

[`k8s/apps/online-boutique/kustomization.yaml`](../k8s/apps/online-boutique/kustomization.yaml):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: online-boutique
resources:
  - redis.yaml
  - frontend.yaml
  - cartservice.yaml
  - productcatalogservice.yaml
  - currencyservice.yaml
  - paymentservice.yaml
  - shippingservice.yaml
  - emailservice.yaml
  - checkoutservice.yaml
  - recommendationservice.yaml
  - adservice.yaml
  - loadgenerator.yaml
  - ingress.yaml
```

`namespace: online-boutique` проставляется всем ресурсам автоматически — в самих манифестах `metadata.namespace` не указан.

> **Известная проблема.** Если файл `kustomization.yaml` сохранён с CRLF (Windows), Kustomize падает с ошибкой парсинга. См. [troubleshooting.md](troubleshooting.md).

### 6.3. Порядок синхронизации

| Волна | Application | Что создаёт |
|---|---|---|
| `-1` | `namespaces` | Namespace `online-boutique` |
| `0` | `online-boutique` | 12 Deployment/StatefulSet + 12 Service + Ingress |
| `2` | `platform-certs` | Certificate для `shop-tls` (через ingress-аннотацию) |
| `5` | `platform-alerts` | PrometheusRule `online-boutique` |

---

## 7. Ingress и TLS

[`k8s/apps/online-boutique/ingress.yaml`](../k8s/apps/online-boutique/ingress.yaml):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: online-boutique
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [shop.platform-mvp-potapov.ru]
      secretName: shop-tls
  rules:
    - host: shop.platform-mvp-potapov.ru
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

| Параметр | Значение |
|---|---|
| Host | `shop.platform-mvp-potapov.ru` |
| IngressClass | `nginx` |
| TLS Secret | `shop-tls` |
| ClusterIssuer | `letsencrypt-staging` |
| Backend | `frontend:80` → `8080` |
| `proxy-body-size` | `8m` |
| `pathType` | `Prefix` |

### 7.1. Цепочка TLS

```
Ingress (annotation cert-manager.io/cluster-issuer)
   → cert-manager создаёт Certificate shop-tls
   → CertificateRequest → ACME DNS-01 (Cloudflare)
   → Secret shop-tls (tls.crt, tls.key)
   → ingress-nginx читает Secret
```

Проверка:

```bash
kubectl -n online-boutique get certificate
# NAME       READY   SECRET     AGE
# shop-tls   True    shop-tls   10m

kubectl -n online-boutique get secret shop-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates
```

> Сертификат от **staging**-окружения Let's Encrypt — браузер покажет предупреждение. См. [known-limitations.md](known-limitations.md).

### 7.2. Доступ

| Способ | Команда / адрес |
|---|---|
| Через ingress (при наличии DNS) | `https://shop.platform-mvp-potapov.ru` |
| Напрямую по IP ноды | `curl -k -H 'Host: shop.platform-mvp-potapov.ru' https://192.168.190.153:30443/` |
| Через SSH-туннель из WSL2 | `ssh -L 8080:192.168.190.153:30080 devops@192.168.190.153` → `http://localhost:8080` |
| Port-forward | `kubectl -n online-boutique port-forward svc/frontend 8080:80` → `http://localhost:8080` |

---

## 8. Наблюдаемость

### 8.1. Метрики

Каждый сервис (кроме `loadgenerator` и `redis-cart`) имеет аннотации:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "<port>"
  prometheus.io/path: "/metrics"   # только frontend
```

| Сервис | `prometheus.io/port` |
|---|---|
| `frontend` | `8080` |
| `cartservice` | `7070` |
| `productcatalogservice` | `3550` |
| `currencyservice` | `7000` |
| `paymentservice` | `9464` |
| `shippingservice` | `50051` |
| `emailservice` | `8080` |
| `checkoutservice` | `5050` |
| `recommendationservice` | `8080` |
| `adservice` | `9555` |

> **Важно.** Prometheus Operator **не обрабатывает** аннотации `prometheus.io/*` — он работает только с `ServiceMonitor`/`PodMonitor`. Отдельного `ServiceMonitor` для Online Boutique в репозитории **нет**. Метрики приложения попадают в Prometheus только через OTel Collector (exporter `prometheus` на `:8889`, `resource_to_telemetry_conversion: true`). См. [monitoring.md](monitoring.md).

### 8.2. Трейсы

Все 11 сервисов отправляют OTLP в `otel-collector.tracing.svc:4317` → Tempo. В Grafana: **Explore → Tempo → Search → Service Name**.

### 8.3. Логи

Promtail собирает stdout всех подов. В Grafana: **Explore → Loki**:

```logql
{namespace="online-boutique"}
{namespace="online-boutique", pod=~"frontend-.*"} |= "error"
```

### 8.4. SLO-дашборд

ConfigMap [`k8s/manifests/dashboards/online-boutique-slo.yaml`](../k8s/manifests/dashboards/online-boutique-slo.yaml):

| Свойство | Значение |
|---|---|
| Имя | `grafana-dashboard-online-boutique-slo` |
| Namespace | `monitoring` |
| Метка | `grafana_dashboard: "1"` |
| UID | `ob-slo` |
| Заголовок | `Online Boutique SLO` |

Панели: RPS by service, Latency p95 by service, Error rate, SLO availability (target 99%), Requests total (1h), p95 (1h), Pods Running.

> Дашборд **не управляется ArgoCD** — каталог `k8s/manifests/dashboards/` не подключён ни к одному Application. Применять вручную:
>
> ```bash
> kubectl apply -f k8s/manifests/dashboards/online-boutique-slo.yaml
> ```

### 8.5. Алерты

PrometheusRule [`k8s/manifests/alerts/online-boutique.yaml`](../k8s/manifests/alerts/online-boutique.yaml), namespace `monitoring`, метка `release: kube-prometheus-stack`, группа `online-boutique.rules`, `interval: 30s`.

| Алерт | Условие | `for` | Severity |
|---|---|---|---|
| `OBHighErrorRate` | доля 5xx на ingress > `0.05` | `5m` | warning |
| `OBHighLatency` | p95 времени ответа ingress > `1` с | `5m` | warning |
| `OBServiceDown` | `kube_deployment_status_replicas_available == 0` | `2m` | critical |
| `OBPodCrashLooping` | `increase(kube_pod_container_status_restarts_total[10m]) > 3` | `5m` | warning |

Все четыре имеют метку `app: online-boutique`.

> `OBHighErrorRate` и `OBHighLatency` построены на метриках `nginx_ingress_controller_*`, но в [`k8s/values/ingress-nginx.yaml`](../k8s/values/ingress-nginx.yaml) `controller.metrics.serviceMonitor.enabled: false`. Без включения ServiceMonitor эти два алерта не могут сработать. См. [monitoring.md](monitoring.md#9-известные-ограничения).

---

## 9. Проверка

### 9.1. Состояние приложения

```bash
# Application синхронизирован
kubectl -n argocd get application online-boutique
# NAME              SYNC STATUS   HEALTH STATUS
# online-boutique   Synced        Healthy

# Все поды Running
kubectl -n online-boutique get pods
# 13 подов: 12 сервисов (frontend ×2) + redis-cart + loadgenerator

# Нет рестартов
kubectl -n online-boutique get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

# Образы
kubectl -n online-boutique get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

### 9.2. Функциональная проверка

```bash
# Главная страница
curl -k -H 'Host: shop.platform-mvp-potapov.ru' \
  https://192.168.190.153:30443/ -o /dev/null -w '%{http_code}\n'
# 200

# Список товаров (gRPC через frontend)
curl -k -H 'Host: shop.platform-mvp-potapov.ru' \
  https://192.168.190.153:30443/product/0PUK6V6EV0 | grep -o '<title>[^<]*</title>'

# Корзина (проверяет cartservice → redis)
curl -k -H 'Host: shop.platform-mvp-potapov.ru' \
  https://192.168.190.153:30443/cart -o /dev/null -w '%{http_code}\n'
```

### 9.3. Проверка сценария покупки

1. Открыть `https://shop.platform-mvp-potapov.ru` (или через туннель).
2. Выбрать товар → **Add to Cart**.
3. **View Cart** → **Checkout**.
4. Заполнить форму (любые данные) → **Place Order**.
5. Ожидается страница подтверждения с номером заказа.

Этот путь задействует `frontend → cartservice → redis`, `checkoutservice → payment/email/shipping/currency/productcatalog` — то есть все 11 сервисов.

### 9.4. Проверка нагрузки

`loadgenerator` (Locust, `USERS: 10`) постоянно генерирует трафик. Проверить:

```bash
kubectl -n online-boutique logs deploy/loadgenerator --tail=20
# ... Aggregated ... RPS ... Failures ...

# Метрики в Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090/graph
# sum(rate(nginx_ingress_controller_requests{namespace="online-boutique"}[5m]))
```

### 9.5. Диагностика

| Симптом | Причина | Решение |
|---|---|---|
| `ImagePullBackOff` + `x509` | Harbor с staging-сертификатом | `kubectl -n online-boutique get secret harbor-creds`; см. [registry.md](registry.md) |
| `ImagePullBackOff` + `unauthorized` | Неверный пароль в `harbor-creds` | Пересоздать Secret |
| `CrashLoopBackOff` + `is a directory` | Dockerfile (§5.1) | Пересобрать образ |
| `redis-cart` вечно `OutOfSync` | `volumeClaimTemplates` | Уже в `ignoreDifferences`; проверить, что Application обновлён |
| `Pending` у `redis-cart` | Нет PVC / Longhorn недоступен | `kubectl -n online-boutique get pvc` |
| 502/503 от ingress | `frontend` не готов | `kubectl -n online-boutique get endpoints frontend` |
| Пустые трейсы | Нет `OTEL_*` | Проверить env в поде |
| Пустой SLO-дашборд | Метрики `grpc_server_*` не собираются | См. [monitoring.md](monitoring.md#9-известные-ограничения) |

Полный список — [troubleshooting.md](troubleshooting.md).

---

## 10. Обновление версии

### 10.1. Через CI (рекомендуется)

```bash
# 1. Изменить код в форке
cd online-boutique
git commit -am "feat: ..." && git push origin master

# 2. Дождаться pipeline
# UI: https://gitlab.platform-mvp-potapov.ru → проект → CI/CD → Pipelines

# 3. Узнать SHA
git rev-parse --short HEAD
# a1b2c3d

# 4. Обновить тег в манифестах платформы
cd platform-mvp/k8s/apps/online-boutique
sed -i 's|frontend:v1.0.0|frontend:a1b2c3d|' frontend.yaml
git commit -am "bump frontend to a1b2c3d" && git push

# 5. ArgoCD синхронизирует автоматически
kubectl -n argocd get application online-boutique -w
```

### 10.2. Массовое обновление всех сервисов

```bash
cd k8s/apps/online-boutique
NEW_TAG=a1b2c3d
sed -i -E "s|(online-boutique/[a-z]+):v[0-9.]+|\1:${NEW_TAG}|g" *.yaml
git diff --stat
git commit -am "bump all services to ${NEW_TAG}" && git push
```

### 10.3. Откат

```bash
# Через ArgoCD (к предыдущей ревизии)
kubectl -n argocd get application online-boutique -o jsonpath='{.status.history[*].revision}'
argocd app rollback online-boutique <ID>

# Через Git (предпочтительно)
git revert <commit-with-bump>
git push
```

### 10.4. Проверка после обновления

```bash
kubectl -n online-boutique rollout status deploy/frontend --timeout=180s
kubectl -n online-boutique get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
curl -k -H 'Host: shop.platform-mvp-potapov.ru' https://192.168.190.153:30443/ -o /dev/null -w '%{http_code}\n'
```

---

## 11. Известные ограничения

| Ограничение | Причина | Следствие |
|---|---|---|
| Разные теги (`v1.0.0` / `v1.0.4`) | Итеративная отладка Dockerfile | Нет единой версии приложения |
| `frontend` — 2 реплики, остальные — 1 | Ресурсы стенда | Нет HA для 10 из 11 сервисов |
| Нет `ServiceMonitor` | Не создан | Метрики только через OTel Collector |
| `prometheus.io/*`-аннотации не работают | Prometheus Operator их игнорирует | Аннотации носят декоративный характер |
| `OBHighErrorRate` / `OBHighLatency` не сработают | `ingress-nginx` ServiceMonitor отключён | Два из четырёх алертов нерабочие |
| SLO-дашборд не в GitOps | Каталог не подключён к Application | Ручное применение |
| Панели дашборда могут быть пустыми | Запросы под `grpc_server_*`, а метрики — OTel `rpc_server_*` | Требуется переписать запросы |
| `SHOPPING_ASSISTANT_SERVICE_ADDR: disabled` | Требует Gemini API | Функция AI-ассистента недоступна |
| `loadgenerator` без проб | Не предусмотрены в манифесте | Под может быть `Running` при нерабочем приложении |
| `redis-cart` без `imagePullSecrets` | Публичный образ | Зависимость от Docker Hub |
| TLS staging | Let's Encrypt staging | Предупреждение браузера |
| Bump тега вручную | Нет автоматизации | См. [ci-cd.md](ci-cd.md#8-известные-ограничения) |

---

## Связанные документы

- [architecture.md](architecture.md) — место приложения в архитектуре платформы
- [deployment.md](deployment.md) — Шаг 9: сборка и развёртывание Online Boutique
- [ci-cd.md](ci-cd.md) — pipeline сборки 11 образов
- [registry.md](registry.md) — Harbor: проект `online-boutique`
- [monitoring.md](monitoring.md) — метрики, трейсы, SLO-дашборд, алерты
- [troubleshooting.md](troubleshooting.md) — диагностика приложения
- [known-limitations.md](known-limitations.md) — полный список ограничений
