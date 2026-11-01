# Harbor — реестр образов

Документ описывает приватный реестр контейнерных образов платформы: зачем он
нужен, как развёрнут, как в него логиниться и пушить образы, как работает
сканирование уязвимостей и какие у решения есть ограничения.

- Версия чарта: **Harbor `1.15.1`** (Helm-репозиторий `https://helm.goharbor.io`)
- Namespace: `harbor`
- ArgoCD Application: [`k8s/apps/40-harbor.yaml`](../k8s/apps/40-harbor.yaml), sync-wave `3`
- Values: [`k8s/values/harbor.yaml`](../k8s/values/harbor.yaml)
- Внешний URL: `https://harbor.platform-mvp-potapov.ru`

---

## 1. Зачем Harbor в этом проекте

Кластер не имеет доступа к Docker Hub для приватных образов, а приложение
собирается из форка Online Boutique. Harbor решает три задачи:

| Задача | Как решается |
|---|---|
| Хранение собранных образов | 11 образов Online Boutique + образ Runner с CA |
| Аутентифицированный pull из кластера | Secret `harbor-creds` + `imagePullSecrets` в подах |
| Сканирование уязвимостей | Встроенный Trivy-адаптер, отчёт по каждому артефакту |

Дополнительно Harbor — единственная точка, откуда кластер тянет образы
приложения, поэтому он же является «шиной» между CI (GitLab Runner + Kaniko)
и CD (ArgoCD). Схема потока:

```
GitLab CI (Kaniko)  ──push──►  Harbor  ──pull──►  kubelet (ноды)
   ns: gitlab                 ns: harbor            ns: online-boutique
   Secret: harbor-credentials  PVC: registry 20Gi   Secret: harbor-creds
```

Подробнее о сборке — [ci-cd.md](ci-cd.md), о манифестах приложения —
[application.md](application.md).

---

## 2. Развёртывание

Harbor ставится ArgoCD как Helm-чарт из upstream-репозитория с
multi-source Application: чарт берётся из `helm.goharbor.io`, values — из
этого репозитория через `ref: values`.

```yaml
# k8s/apps/40-harbor.yaml (сокращённо)
metadata:
  name: harbor
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  sources:
    - repoURL: https://helm.goharbor.io
      chart: harbor
      targetRevision: 1.15.1
      helm:
        valueFiles:
          - $values/k8s/values/harbor.yaml
    - repoURL: https://github.com/potapovanton149/platform-mvp.git
      targetRevision: master
      ref: values
  destination:
    namespace: harbor
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions:
      - CreateNamespace=true
      - RespectIgnoreDifferences=true
```

### 2.1. `ignoreDifferences` на `/spec/strategy`

Для трёх Deployment'ов (`harbor-core`, `harbor-jobservice`, `harbor-registry`)
игнорируется `/spec/strategy`:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: harbor-registry
    jsonPointers: [/spec/strategy]
```

Причина: PVC Harbor создаются с `accessModes: ReadWriteOnce`. Harbor сам
переключает стратегию rollout на `Recreate`, иначе новый под не сможет
смонтировать том, пока старый его держит (`Multi-Attach error`). Без
`ignoreDifferences` ArgoCD считал бы это drift'ом и откатывал обратно на
`RollingUpdate`, ломая rollout. Разбор инцидента —
[troubleshooting.md → Harbor](troubleshooting.md#harbor).

### 2.2. Параметры values

| Параметр | Значение | Комментарий |
|---|---|---|
| `expose.type` | `ingress` | Не NodePort/LoadBalancer |
| `expose.ingress.className` | `nginx` | Класс ingress-nginx |
| `expose.ingress.hosts.core` | `harbor.platform-mvp-potapov.ru` | Единственный хост |
| `expose.tls.enabled` | `true` | TLS терминируется на ingress |
| `expose.tls.certSource` | `secret` | Сертификат из Secret, не генерируется чартом |
| `expose.tls.secret.secretName` | `harbor-tls` | Создаётся cert-manager |
| `externalURL` | `https://harbor.platform-mvp-potapov.ru` | Используется в UI и API |
| `persistence.enabled` | `true` | Longhorn |
| `persistence.resourcePolicy` | `keep` | PVC не удаляются при `helm uninstall` |
| `database.type` | `internal` | PostgreSQL внутри чарта |
| `trivy.enabled` | `true` | Сканер уязвимостей |
| `trivy.skipUpdate` | `true` | База CVE **не обновляется** (см. §10) |
| `metrics.enabled` | `true` | Метрики для Prometheus |
| `metrics.serviceMonitor.enabled` | `true` | ServiceMonitor с `release: kube-prometheus-stack` |

Аннотации ingress:

| Аннотация | Значение | Зачем |
|---|---|---|
| `cert-manager.io/cluster-issuer` | `letsencrypt-staging` | Выпуск сертификата |
| `nginx.ingress.kubernetes.io/proxy-body-size` | `"0"` | Без лимита — слои образов бывают крупными |
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | `"600"` | Долгие push/pull |
| `nginx.ingress.kubernetes.io/proxy-send-timeout` | `"600"` | Долгие push/pull |

### 2.3. Сертификат

```yaml
# k8s/manifests/certs/harbor-cert.yaml
kind: Certificate
metadata: {name: harbor-tls, namespace: harbor}
spec:
  secretName: harbor-tls
  duration: 2160h        # 90 дней
  renewBefore: 360h      # 15 дней
  issuerRef: {name: letsencrypt-staging, kind: ClusterIssuer}
  dnsNames: [harbor.platform-mvp-potapov.ru]
```

Используется **staging**-окружение Let's Encrypt. Это осознанное решение
(лимиты prod при отладке), но оно даёт недоверенный сертификат — см. §11.

---

## 3. Компоненты и ресурсы

Harbor состоит из нескольких подов; все они в namespace `harbor`.

| Компонент | Роль | Requests | Limits |
|---|---|---|---|
| `harbor-core` | API, аутентификация, бизнес-логика | `100m` / `256Mi` | `500m` / `1Gi` |
| `harbor-portal` | Web UI (nginx + статика) | `50m` / `128Mi` | `200m` / `256Mi` |
| `harbor-registry` | Registry v2 — приём и отдача слоёв | `100m` / `256Mi` | `500m` / `1Gi` |
| `harbor-jobservice` | Асинхронные задачи (GC, репликация, scan) | `50m` / `128Mi` | `200m` / `512Mi` |
| `harbor-database` | PostgreSQL (internal) | `100m` / `256Mi` | `500m` / `1Gi` |
| `harbor-redis` | Кэш и очередь задач | `50m` / `128Mi` | `200m` / `512Mi` |
| `harbor-trivy` | Сканер уязвимостей | `100m` / `256Mi` | `500m` / `1Gi` |
| `harbor-exporter` | Метрики Prometheus | `50m` / `64Mi` | `200m` / `128Mi` |

Суммарно по requests: ~`600m` CPU и ~`1.5Gi` RAM — самый «тяжёлый» после
GitLab компонент платформы.

---

## 4. Хранилище

Все PVC — на Longhorn (`storageClass: longhorn`), `resourcePolicy: keep`.

| PVC | Размер | Что хранит |
|---|---|---|
| `registry` | `20Gi` | Слои и манифесты образов |
| `database` | `5Gi` | PostgreSQL: проекты, пользователи, метаданные артефактов |
| `redis` | `2Gi` | Кэш, очередь jobservice |
| `trivy` | `5Gi` | База CVE и результаты сканирования |
| `jobservice.jobLog` | `1Gi` | Логи задач |

Итого `33Gi` на Longhorn. При `defaultReplicaCount: 1` каждый том — одна
реплика, то есть без отказоустойчивости на уровне хранилища.

Проверка:

```bash
kubectl -n harbor get pvc
# NAME                                   STATUS   VOLUME   CAPACITY   STORAGECLASS
# data-harbor-redis-0                    Bound    ...      2Gi        longhorn
# database-data-harbor-database-0        Bound    ...      5Gi        longhorn
# harbor-jobservice                     Bound    ...      1Gi        longhorn
# harbor-registry                       Bound    ...      20Gi       longhorn
# harbor-trivy                          Bound    ...      5Gi        longhorn
```

---

## 5. Доступ и учётные данные

### 5.1. URL и логин

| Параметр | Значение |
|---|---|
| URL | `https://harbor.platform-mvp-potapov.ru` |
| Логин | `admin` |
| Пароль | см. Vault `kv/platform/harbor` → `admin-password` |
| Альтернативный источник | Secret `gitlab/harbor-credentials` (ключ `HARBOR_PASSWORD`), создаётся ESO |

Пароль администратора задаётся в values:

```yaml
# k8s/values/harbor.yaml
harborAdminPassword: "<см. Vault kv/platform/harbor → admin-password>"
```

> **Ограничение.** В текущей версии репозитория значение записано в
> values-файл открытым текстом. Это учебное упрощение; для production
> значение должно приходить из Vault через ESO или из
> `existingSecretAdminPassword`. См. [security.md](security.md) и
> [known-limitations.md](known-limitations.md).

### 5.2. Как получить пароль

```bash
# Вариант 1 — из Vault (root-токен dev-режима — см. Secret vault, ключ root-token)
VAULT_TOKEN="$(kubectl -n vault get secret vault -o jsonpath='{.data.root-token}' | base64 -d)"
kubectl -n vault exec -i vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" vault kv get -field=admin-password kv/platform/harbor

# Вариант 2 — из Secret, созданного ESO
kubectl -n gitlab get secret harbor-credentials \
  -o jsonpath='{.data.HARBOR_PASSWORD}' | base64 -d; echo

# Вариант 3 — из Secret самого Harbor
kubectl -n harbor get secret harbor-core \
  -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d; echo
```

> Secret `gitlab/harbor-credentials` создаётся ExternalSecret
> [`harbor-credentials.yaml`](../k8s/manifests/external-secrets/harbor-credentials.yaml).
> В нём `remoteRef.key` указан как `kv/platform/harbor`, что даёт двойной
> префикс `kv/data/kv/platform/harbor` — известная ошибка, разобранная в
> [security.md §4](security.md) и [troubleshooting.md](troubleshooting.md).

---

## 6. Проекты Harbor

| Проект | Видимость | Назначение | Содержимое |
|---|---|---|---|
| `online-boutique` | **public** | Образы приложения и инфраструктурных образов | 11 сервисов + `gitlab-runner-ca` + `cache` |
| `platform` | **private** | Зарезервирован под образы платформы | Пусто (задел на будущее) |

Проект `online-boutique` публичный на чтение: это позволяет kubelet'у
тянуть образы без обязательной аутентификации, но `imagePullSecrets` всё
равно указан — на случай ужесточения политики.

> **Важно.** Проекты **не создаются автоматически**. В GitOps нет ресурса,
> который бы их описывал (Harbor не имеет CRD для проектов, а Terraform/
> Harbor-API-джобы в проекте отсутствуют). При развёртывании с нуля проекты
> создаются вручную в UI или через API:

```bash
# Создать проект через API (public)
curl -k -u admin:"$HARBOR_PASSWORD" -X POST \
  "https://harbor.platform-mvp-potapov.ru/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"online-boutique","public":true}'

# Приватный проект
curl -k -u admin:"$HARBOR_PASSWORD" -X POST \
  "https://harbor.platform-mvp-potapov.ru/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"platform","public":false}'
```

### 6.1. Структура репозиториев

```
harbor.platform-mvp-potapov.ru/
└── online-boutique/
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
    ├── gitlab-runner-ca:v19.5.1-fixed5
    └── cache/            # Kaniko layer cache (--cache-repo)
```

Полное соответствие «сервис → тег → порт» — в
[application.md §2](application.md).

---

## 7. Аутентификация клиентов

### 7.1. Из виртуальной машины (Linux, где развёрнут кластер)

DNS-имя `harbor.platform-mvp-potapov.ru` резолвится в `192.168.190.153`
(worker-нода), ingress слушает NodePort `30443`. Сертификат — staging, поэтому
нужно либо добавить CA в trust store, либо отключить проверку.

**Вариант A — добавить CA (рекомендуется):**

```bash
# Выгрузить CA из Secret
kubectl -n harbor get secret harbor-tls -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | sudo tee /usr/local/share/ca-certificates/harbor-ca.crt

sudo update-ca-certificates

# Docker: положить сертификат в каталог реестра
sudo mkdir -p /etc/docker/certs.d/harbor.platform-mvp-potapov.ru
sudo cp /usr/local/share/ca-certificates/harbor-ca.crt \
        /etc/docker/certs.d/harbor.platform-mvp-potapov.ru/ca.crt
sudo systemctl restart docker
```

**Вариант B — без проверки TLS:**

```bash
# Docker: добавить реестр в insecure-registries
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "insecure-registries": ["harbor.platform-mvp-potapov.ru"] }
EOF
sudo systemctl restart docker
```

**Логин:**

```bash
docker login harbor.platform-mvp-potapov.ru -u admin
# Password: <см. Vault kv/platform/harbor → admin-password>
# Login Succeeded
```

Для `podman`/`buildah` проверка отключается флагом на команду:

```bash
podman login --tls-verify=false harbor.platform-mvp-potapov.ru -u admin
```

### 7.2. Из WSL2 (рабочая машина разработчика)

WSL2 находится в отдельной виртуальной сети (Hyper-V), а `192.168.190.0/24`
виден только хосту через VMware NAT. Прямой доступ невозможен — нужен
SSH-туннель на хост:

```bash
ssh -L 8443:192.168.190.153:30443 devops@192.168.190.153
```

Далее в другом терминале WSL2:

```bash
# Подменить DNS локально
echo "127.0.0.1 harbor.platform-mvp-potapov.ru" | sudo tee -a /etc/hosts

# Проверить
curl -k https://harbor.platform-mvp-potapov.ru:8443/api/v2.0/systeminfo

# Логин (порт 8443)
docker login harbor.platform-mvp-potapov.ru:8443 -u admin
```

Альтернатива без правки `/etc/hosts`:

```bash
curl -k --resolve harbor.platform-mvp-potapov.ru:8443:127.0.0.1 \
  https://harbor.platform-mvp-potapov.ru:8443/api/v2.0/systeminfo
```

> При логине через туннель имя образа для push меняется на
> `harbor.platform-mvp-potapov.ru:8443/...`. Для кластера это неприменимо —
> там используется имя без порта. Поэтому push из WSL2 — только для
> отладки, штатная сборка идёт внутри кластера.

---

## 8. Push образов

### 8.1. Штатный путь — Kaniko в GitLab CI

Основной способ: пайплайн в GitLab собирает 11 образов Kaniko и пушит их в
Harbor. Аутентификация — `config.json` в `/kaniko/.docker`:

```yaml
# k8s/apps/online-boutique/.gitlab-ci.yml (фрагмент)
script:
  - mkdir -p /kaniko/.docker
  - |
    cat > /kaniko/.docker/config.json <<EOF
    {"auths":{"harbor.platform-mvp-potapov.ru":{"auth":"$(printf 'admin:<PASSWORD>' | base64)"}}}
    EOF
  - /kaniko/executor
    --context "$CI_PROJECT_DIR/$CTX"
    --dockerfile "$CI_PROJECT_DIR/$CTX/Dockerfile"
    --destination "$HARBOR/$SVC:$TAG"
    --destination "$HARBOR/$SVC:latest"
    --cache=true --cache-repo="$HARBOR/cache"
```

Полный разбор пайплайна — [ci-cd.md §4](ci-cd.md).

### 8.2. Про `--skip-tls-verify`

В текущих манифестах флаг **не используется**: доверие к staging-сертификату
обеспечивается установкой CA Harbor в trust store нод (см. §7.1, вариант A).
Если push или pull падает с ошибкой вида:

```
error checking push permissions ... x509: certificate signed by unknown authority
```

— добавьте флаг в аргументы Kaniko:

```yaml
- /kaniko/executor
  --skip-tls-verify              # не проверять TLS при push
  --skip-tls-verify-pull         # не проверять TLS при pull базового образа
  --context "$CI_PROJECT_DIR/$CTX"
  --dockerfile "$CI_PROJECT_DIR/$CTX/Dockerfile"
  --destination "$HARBOR/$SVC:$TAG"
```

Флаги действуют только на время job'а и не меняют состояние кластера — это
приемлемый компромисс для учебного стенда, но не для production.

### 8.3. Альтернативный путь — скрипт `build-online-boutique.sh`

[`scripts/build-online-boutique.sh`](../scripts/build-online-boutique.sh)
собирает те же 11 образов без GitLab: клонирует репозиторий в PVC `ob-src`
(namespace `ci`), затем последовательно запускает поды Kaniko. Аутентификация
— Secret `ci/harbor-creds`, монтируемый как `config.json`:

```yaml
volumes:
  - name: docker-config
    secret:
      secretName: harbor-creds
      items:
        - {key: .dockerconfigjson, path: config.json}
```

Запуск:

```bash
# Создать Secret (один раз)
kubectl -n ci create secret docker-registry harbor-creds \
  --docker-server=harbor.platform-mvp-potapov.ru \
  --docker-username=admin \
  --docker-password="<см. Vault kv/platform/harbor → admin-password>"

# Собрать
TAG=v1.0.0 ./scripts/build-online-boutique.sh
```

Скрипт использует `--cache=false` (в отличие от CI) и собирает сервисы
последовательно, чтобы не превысить лимиты нод.

### 8.4. Ручной push (для отладочных образов)

Так собирался образ Runner с CA:

```bash
cd /tmp/runner-ca
docker build -t harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5 .
docker push harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5
```

---

## 9. Pull образов в кластере

### 9.1. Secret `harbor-creds`

Создаётся вручную в namespace приложения (и в `ci` для скрипта):

```bash
kubectl -n online-boutique create secret docker-registry harbor-creds \
  --docker-server=harbor.platform-mvp-potapov.ru \
  --docker-username=admin \
  --docker-password="<см. Vault kv/platform/harbor → admin-password>"
```

### 9.2. Использование в подах

Все 12 манифестов приложения (11 сервисов + loadgenerator) содержат:

```yaml
spec:
  template:
    spec:
      imagePullSecrets: [{name: harbor-creds}]
      containers:
        - name: frontend
          image: harbor.platform-mvp-potapov.ru/online-boutique/frontend:v1.0.0
```

### 9.3. Доверие к сертификату на нодах

`imagePullSecrets` решает только аутентификацию. Проверка TLS выполняется
containerd, и staging-сертификат он не признаёт. Поэтому CA Harbor должен быть
в trust store **всех шести нод**:

```bash
# На каждой ноде
sudo mkdir -p /usr/local/share/ca-certificates/
sudo cp harbor-ca.crt /usr/local/share/ca-certificates/harbor-ca.crt
sudo update-ca-certificates
sudo systemctl restart containerd
```

Альтернатива — `skip_verify` в конфигурации containerd:

```toml
# /etc/containerd/certs.d/harbor.platform-mvp-potapov.ru/hosts.toml
server = "https://harbor.platform-mvp-potapov.ru"

[host."https://harbor.platform-mvp-potapov.ru"]
  skip_verify = true
```

Разбор ошибки `x509: certificate signed by unknown authority` —
[troubleshooting.md → ImagePullBackOff](troubleshooting.md).

---

## 10. Trivy: сканирование уязвимостей

Trivy встроен в Harbor как адаптер сканера. Включён в values:

```yaml
trivy:
  enabled: true
  skipUpdate: true
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {cpu: 500m, memory: 1Gi}
```

### 10.1. Что означает `skipUpdate: true`

Trivy при старте не скачивает обновления базы CVE. Причина — нестабильный
доступ к внешним репозиториям (DPI/блокировки). Следствия:

| Следствие | Проявление |
|---|---|
| База CVE может быть пустой или устаревшей | Артефакт в статусе `Not Scanned` |
| Сканирование «по требованию» может завершаться без результата | В UI нет вкладки Vulnerabilities |
| Отчёт не отражает актуальные CVE | Нельзя использовать как gate в CI |

### 10.2. Запуск сканирования вручную

```bash
# Через API: конкретный артефакт
curl -k -u admin:"$HARBOR_PASSWORD" -X POST \
  "https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories/frontend/artifacts/v1.0.0/scan"

# Через UI: Projects → online-boutique → frontend → v1.0.0 → Scan
```

### 10.3. Просмотр отчёта

```bash
curl -k -u admin:"$HARBOR_PASSWORD" \
  "https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories/frontend/artifacts/v1.0.0/additions/vulnerabilities" \
  | jq '.application_vulnerability_total'
```

### 10.4. Как включить обновление базы

```yaml
# k8s/values/harbor.yaml
trivy:
  enabled: true
  skipUpdate: false
```

```bash
kubectl -n harbor rollout restart deploy harbor-trivy
kubectl -n harbor logs deploy/harbor-trivy --tail=30
```

Требует сетевого доступа к `ghcr.io/aquasecurity/trivy-db` — в текущем
окружении может быть недоступен.

---

## 11. Метрики и мониторинг

Harbor отдаёт метрики через `harbor-exporter`, ServiceMonitor включён:

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    additionalLabels:
      release: kube-prometheus-stack
```

Метка `release: kube-prometheus-stack` обязательна: Prometheus Operator
выбирает ServiceMonitor по ней (в values Prometheus стоит
`serviceMonitorSelectorNilUsesHelmValues: false`, но метка всё равно
проставлена для единообразия).

Проверка в Prometheus:

```promql
# Все targets Harbor
up{job=~".*harbor.*"}

# Количество проектов и репозиториев
harbor_project_total
harbor_repo_total

# Использование хранилища
harbor_project_quota_usage_byte
```

Подробнее о стеке мониторинга — [monitoring.md](monitoring.md).

---

## 12. Проверка работоспособности

### 12.1. Базовая проверка

```bash
# 1. Поды
kubectl -n harbor get pods
# Ожидается 8 подов в Running (core, portal, registry, jobservice,
# database, redis, trivy, exporter)

# 2. Ingress и сертификат
kubectl -n harbor get ingress,certificate
kubectl -n harbor get certificate harbor-tls \
  -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status}'; echo
# Ready=True

# 3. API отвечает
curl -k https://harbor.platform-mvp-potapov.ru/api/v2.0/systeminfo | jq '.harbor_version'

# 4. ArgoCD
kubectl -n argocd get application harbor \
  -o jsonpath='{.status.sync.status} {.status.health.status}'; echo
# Synced Healthy
```

### 12.2. Проверка содержимого

```bash
# Список репозиториев проекта
curl -k -u admin:"$HARBOR_PASSWORD" \
  'https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories?page_size=50' \
  | jq -r '.[].name'

# Теги конкретного образа
curl -k -u admin:"$HARBOR_PASSWORD" \
  'https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories/frontend/artifacts?page_size=5' \
  | jq -r '.[].tags[].name'

# Ожидается 12 репозиториев (11 сервисов + gitlab-runner-ca) и cache
```

### 12.3. Проверка pull из кластера

```bash
# Тестовый под с образом из Harbor
kubectl -n online-boutique run harbor-test --rm -it --restart=Never \
  --image=harbor.platform-mvp-potapov.ru/online-boutique/frontend:v1.0.0 \
  --image-pull-policy=Always -- /bin/sh -c 'echo pull-ok'

# Если x509 — CA не в trust store нод (§9.3)
# Если unauthorized — неверный пароль в harbor-creds (§9.1)
```

### 12.4. Диагностика

| Симптом | Причина | Где смотреть |
|---|---|---|
| `Multi-Attach error` при rollout | RWO PVC + `RollingUpdate` | [troubleshooting.md → Harbor](troubleshooting.md#harbor) |
| `x509: certificate signed by unknown authority` | Staging-сертификат не в trust store | §9.3 |
| `unauthorized: authentication required` | Неверный/отсутствующий `harbor-creds` | §9.1 |
| `403` на push | Нет прав у пользователя в проекте | UI → Project → Members |
| `Not Scanned` | `trivy.skipUpdate: true` | §10.1 |
| `502` на UI | `harbor-core` не готов | `kubectl -n harbor logs deploy/harbor-core` |
| ArgoCD `OutOfSync` на `/spec/strategy` | Потерян `ignoreDifferences` | §2.1 |

---

## 13. Известные ограничения

| # | Ограничение | Причина | Обход / план |
|---|---|---|---|
| 1 | TLS — Let's Encrypt **staging** | Лимиты prod при отладке | Переключить `ClusterIssuer` на `letsencrypt-prod` в `harbor-cert.yaml` и в аннотации ingress |
| 2 | Пароль admin в values открытым текстом | Учебное упрощение | `existingSecretAdminPassword` + ESO |
| 3 | Проекты не создаются автоматически | Нет CRD/провайдера в GitOps | Создавать вручную или через API (§6) |
| 4 | Trivy не обновляет базу CVE | `skipUpdate: true`, блокировки | Включить `skipUpdate: false` при стабильной сети |
| 5 | Нет robot-аккаунтов | CI использует `admin` | Создать robot-аккаунт с правами push только в `online-boutique` |
| 6 | Нет политик retention | Не настроено | Настроить tag retention в UI (иначе `20Gi` переполнится) |
| 7 | Нет репликации в другой реестр | Один стенд | Настроить replication endpoint |
| 8 | `defaultReplicaCount: 1` в Longhorn | Экономия ресурсов | Увеличить до 2–3 для prod |
| 9 | Доступ из WSL2 только через `ssh -L` | Сетевая изоляция + SNI | Туннель (§7.2) |
| 10 | `harbor-credentials` ExternalSecret с двойным префиксом `kv/` | Ошибка в `remoteRef.key` | Убрать `kv/` из ключа |
| 11 | Нет подписи образов (cosign/Notary) | Не реализовано | Добавить cosign + admission policy |
| 12 | `latest` тег перезаписывается | `--destination ...:latest` в CI | Использовать только immutable-теги (`$CI_COMMIT_SHORT_SHA`) |

Полный перечень ограничений платформы — [known-limitations.md](known-limitations.md).

---

## См. также

- [ci-cd.md](ci-cd.md) — сборка образов Kaniko, пайплайн, bump тега
- [application.md](application.md) — манифесты Online Boutique, `imagePullSecrets`
- [security.md](security.md) — Vault, ESO, ExternalSecret `harbor-credentials`
- [troubleshooting.md](troubleshooting.md) — `Multi-Attach`, `x509`, Trivy
- [monitoring.md](monitoring.md) — метрики Harbor в Prometheus
- [known-limitations.md](known-limitations.md) — общий список ограничений
