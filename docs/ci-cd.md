# CI/CD: GitLab CE + Runner + Kaniko

Документ описывает конвейер непрерывной интеграции и доставки: self-hosted GitLab CE, GitLab Runner с Kubernetes executor, сборку образов через Kaniko без Docker daemon, публикацию в Harbor и передачу тега в ArgoCD.

- [1. Общая схема](#1-общая-схема)
- [2. GitLab CE](#2-gitlab-ce)
- [3. GitLab Runner](#3-gitlab-runner)
- [4. Pipeline](#4-pipeline)
- [5. Секреты в CI](#5-секреты-в-ci)
- [6. Альтернатива: сборка скриптом](#6-альтернатива-сборка-скриптом)
- [7. Проверка end-to-end](#7-проверка-end-to-end)
- [8. Известные ограничения](#8-известные-ограничения)

---

## 1. Общая схема

```
┌──────────────┐   git push    ┌──────────────┐   job    ┌──────────────────┐
│  Разработчик │──────────────►│   GitLab CE  │─────────►│  GitLab Runner   │
└──────────────┘               │  ns: gitlab  │          │  ns: gitlab      │
                               └──────────────┘          │  k8s executor    │
                                                          └────────┬─────────┘
                                                                   │ запускает Pod
                                                                   ▼
                                                          ┌──────────────────┐
                                                          │ Kaniko (Pod)     │
                                                          │ без Docker daemon│
                                                          └────────┬─────────┘
                                                                   │ push
                                                                   ▼
                                                          ┌──────────────────┐
                                                          │  Harbor          │
                                                          │  ns: harbor      │
                                                          └────────┬─────────┘
                                                                   │ pull
                                                                   ▼
┌──────────────┐   git pull    ┌──────────────┐   sync   ┌──────────────────┐
│   ArgoCD     │◄──────────────│  Git-репо    │─────────►│  Kubernetes      │
│  ns: argocd  │               │  (манифесты) │          │  ns: online-     │
└──────────────┘               └──────────────┘          │      boutique    │
                                                          └──────────────────┘
```

Два независимых контура:

| Контур | Триггер | Что делает | Инструмент |
|---|---|---|---|
| **CI** | `git push` в `master` | Собирает 11 образов, пушит в Harbor | GitLab CI + Runner + Kaniko |
| **CD** | изменение манифестов в Git | Приводит кластер к состоянию из Git | ArgoCD |

Связка между контурами — **тег образа в манифесте**. CI обновляет тег (bump), CD подхватывает изменение.

---

## 2. GitLab CE

### 2.1. Параметры

| Параметр | Значение |
|---|---|
| Chart | `gitlab` `8.11.8` из `https://charts.gitlab.io` |
| ArgoCD Application | [`50-gitlab.yaml`](../k8s/apps/50-gitlab.yaml), sync-wave `4` |
| Namespace | `gitlab` |
| Edition | `ce` (`global.edition: ce`) |
| URL | `https://gitlab.platform-mvp-potapov.ru` |
| Registry | `registry.gitlab.platform-mvp-potapov.ru` (включён, но не используется — образы идут в Harbor) |
| Ingress class | `nginx` |
| `configureCertmanager` | `false` (используется внешний cert-manager) |
| ClusterIssuer | `letsencrypt-staging` |
| `proxy-body-size` | `0` (без ограничения — для git push больших репозиториев) |
| Root-пароль | Secret `gitlab-gitlab-initial-root-password`, ключ `password` |
| MinIO | `global.minio.enabled: false`, `minio.install: false` |
| Object storage | `global.appConfig.object_store.enabled: true`, Secret `gitlab-object-storage` |
| Встроенные Prometheus / Grafana | отключены |
| Встроенный nginx-ingress | отключён |
| Встроенный cert-manager | отключён |
| Встроенный gitlab-runner | отключён (`gitlab-runner.install: false`) |
| `upgradeCheck` | отключён |

### 2.2. Компоненты и ресурсы

| Компонент | Реплики | Requests | Limits | Persistence |
|---|---|---|---|---|
| `webservice` | 1 | `300m` / `1Gi` | `1500m` / `2Gi` | — |
| `sidekiq` | 1 | `200m` / `1Gi` | `1000m` / `2Gi` | — |
| `gitaly` | 1 | `200m` / `512Mi` | `1000m` / `1Gi` | Longhorn `5Gi` |
| `gitlab-shell` | 1 | `100m` / `128Mi` | `500m` / `512Mi` | — |
| `toolbox` | — | `200m` / `512Mi` | `1` / `2Gi` | — |
| `migrations` | — | `200m` / `512Mi` | `1` / `1Gi` | — |
| `gitlab-exporter` | 1 | `50m` / `64Mi` | `200m` / `256Mi` | — |
| `registry` | 1 | `100m` / `256Mi` | `500m` / `512Mi` | — |
| `postgresql` | 1 | `200m` / `512Mi` | `1` / `1Gi` | Longhorn `10Gi` |
| `redis` | 1 | `100m` / `256Mi` | `500m` / `512Mi` | Longhorn `2Gi` |

Отключены: `pages`, `mailroom`, `spamcheck`.

### 2.3. Образы БД и кеша

Из-за удаления старых тегов из Docker Hub используются образы из namespace `bitnamilegacy`:

| Компонент | Образ |
|---|---|
| PostgreSQL | `docker.io/bitnamilegacy/postgresql:14.8.0` |
| PostgreSQL exporter | `docker.io/bitnamilegacy/postgres-exporter:0.14.0-debian-11-r2` |
| Redis | `docker.io/bitnamilegacy/redis:7.2.4-debian-12-r9` |
| Redis exporter | `docker.io/bitnamilegacy/redis-exporter:1.58.0-debian-12-r4` |

### 2.4. Первый вход

```bash
# Root-пароль
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Если Secret создан ESO из Vault — значение совпадает с `kv/platform/gitlab` → `root-password` (см. [security.md](security.md)).

Логин: `root` + пароль выше. Сразу после первого входа пароль рекомендуется сменить (**Profile → Password**).

### 2.5. Проверка

```bash
kubectl -n gitlab get pods
# webservice, sidekiq, gitaly, gitlab-shell, toolbox, migrations,
# registry, postgresql, redis, gitlab-exporter — Running/Completed

kubectl -n gitlab get ingress
kubectl -n gitlab get certificate

# Готовность приложения
kubectl -n gitlab exec deploy/gitlab-webservice-default -c webservice -- \
  curl -sf http://localhost:8080/-/health | head -5
```

Первый старт занимает **10–15 минут** (миграции БД, инициализация Gitaly).

---

## 3. GitLab Runner

### 3.1. Параметры

| Параметр | Значение |
|---|---|
| Chart | `gitlab-runner` `0.94.1` из `https://charts.gitlab.io` |
| ArgoCD Application | [`51-gitlab-runner.yaml`](../k8s/apps/51-gitlab-runner.yaml), sync-wave `4` |
| Namespace | `gitlab` |
| `gitlabUrl` | `https://gitlab.platform-mvp-potapov.ru` |
| Образ | `harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5` |
| `certsSecretName` | `gitlab-runner-ca` |
| `GITLAB_RUNNER_INSECURE` | `"true"` |
| `concurrent` | `4` |
| `checkInterval` | `10` |
| Secret регистрации | `gitlab-runner-secret` |
| `rbac.create` | `true` |
| Resources | requests `100m` / `128Mi`, limits `500m` / `512Mi` |

### 3.2. Конфигурация executor

```toml
[[runners]]
  name = "k8s-runner"
  executor = "kubernetes"
  tls-ca-file = "/etc/ssl/certs/gitlab-ca.crt"
  [runners.kubernetes]
    namespace = "gitlab"
    image = "alpine:latest"
    privileged = true
    tls_verify = false
    poll_timeout = 600
    cpu_request = "200m"
    memory_request = "256Mi"
    cpu_limit = "1"
    memory_limit = "1Gi"
```

| Параметр | Значение | Зачем |
|---|---|---|
| `executor` | `kubernetes` | Каждый job — отдельный Pod, нет постоянных агентов |
| `namespace` | `gitlab` | Job-поды создаются в namespace GitLab |
| `image` | `alpine:latest` | Образ по умолчанию, переопределяется в job |
| `privileged` | `true` | Требуется для некоторых сборщиков; Kaniko формально не требует, но оставлено для совместимости |
| `tls_verify` | `false` | GitLab использует self-signed CA |
| `tls-ca-file` | `/etc/ssl/certs/gitlab-ca.crt` | CA, добавленный в кастомный образ |
| `poll_timeout` | `600` | Таймаут ожидания пода |
| `cpu_request` / `memory_request` | `200m` / `256Mi` | Ресурсы job-пода по умолчанию |
| `cpu_limit` / `memory_limit` | `1` / `1Gi` | Лимиты job-пода по умолчанию |

### 3.3. Кастомный образ Runner с CA

GitLab выпускает сертификат через ClusterIssuer `letsencrypt-staging`, но внутри кластера webservice отдаёт сертификат от self-signed CA (`gitlab-wildcard-tls`). Стандартный образ Runner не доверяет этому CA, поэтому собран образ с добавленным сертификатом.

```bash
# 1. Извлечь CA
kubectl -n gitlab get secret gitlab-wildcard-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > gitlab-ca.crt

# 2. Dockerfile
cat > Dockerfile <<'EOF'
FROM gitlab/gitlab-runner:v19.5.1
USER root
COPY gitlab-ca.crt /usr/local/share/ca-certificates/gitlab-ca.crt
RUN update-ca-certificates
USER gitlab-runner
EOF

# 3. Собрать и запушить
docker build -t harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5 .
docker login harbor.platform-mvp-potapov.ru -u admin
docker push harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5
```

Дополнительно CA монтируется в под через `certsSecretName: gitlab-runner-ca`:

```bash
kubectl -n gitlab create secret generic gitlab-runner-ca \
  --from-file=gitlab-ca.crt=gitlab-ca.crt
```

### 3.4. Регистрация Runner

Токен генерируется GitLab после первого старта — автоматизировать нельзя.

1. **Admin Area → CI/CD → Runners → New instance runner**.
2. Tags: `kubernetes,kubernetes-platform`. **Run untagged: off**.
3. Скопировать registration token.
4. Создать Secret:

```bash
kubectl -n gitlab create secret generic gitlab-runner-secret \
  --from-literal=runner-registration-token="<TOKEN>" \
  --from-literal=runner-token=""
```

5. Перезапустить Runner:

```bash
kubectl -n gitlab rollout restart deploy gitlab-runner
```

### 3.5. Проверка

```bash
kubectl -n gitlab get pods | grep runner
# gitlab-runner-xxxxx   1/1   Running

kubectl -n gitlab logs deploy/gitlab-runner --tail=50 | grep -iE 'registered|configuration loaded|runner'
```

В UI: **Admin Area → CI/CD → Runners** — раннер в статусе online (зелёная точка).

---

## 4. Pipeline

### 4.1. Файл `.gitlab-ci.yml`

Расположение: [`k8s/apps/online-boutique/.gitlab-ci.yml`](../k8s/apps/online-boutique/.gitlab-ci.yml). Файл лежит в репозитории платформы как **эталон**; в репозитории `potapovanton149/online-boutique` он должен находиться в корне.

```yaml
stages: [build]

variables:
  HARBOR: harbor.platform-mvp-potapov.ru/online-boutique
  TAG: $CI_COMMIT_SHORT_SHA
  KANIKO_IMAGE: gcr.io/kaniko-project/executor:v1.23.2-debug

.build_template: &build
  stage: build
  image:
    name: $KANIKO_IMAGE
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - |
      cat > /kaniko/.docker/config.json <<EOF
      {"auths":{"harbor.platform-mvp-potapov.ru":{"auth":"$(printf 'admin:<HARBOR_ADMIN_PASSWORD>' | base64)"}}}
      EOF
    - /kaniko/executor
      --context "$CI_PROJECT_DIR/$CTX"
      --dockerfile "$CI_PROJECT_DIR/$CTX/Dockerfile"
      --destination "$HARBOR/$SVC:$TAG"
      --destination "$HARBOR/$SVC:latest"
      --cache=true --cache-repo="$HARBOR/cache"
  rules:
    - if: $CI_COMMIT_BRANCH == "master"

frontend:              {<<: *build, variables: {SVC: frontend, CTX: src/frontend}}
cartservice:           {<<: *build, variables: {SVC: cartservice, CTX: src/cartservice/src}}
productcatalogservice: {<<: *build, variables: {SVC: productcatalogservice, CTX: src/productcatalogservice}}
currencyservice:       {<<: *build, variables: {SVC: currencyservice, CTX: src/currencyservice}}
paymentservice:        {<<: *build, variables: {SVC: paymentservice, CTX: src/paymentservice}}
shippingservice:       {<<: *build, variables: {SVC: shippingservice, CTX: src/shippingservice}}
emailservice:          {<<: *build, variables: {SVC: emailservice, CTX: src/emailservice}}
checkoutservice:       {<<: *build, variables: {SVC: checkoutservice, CTX: src/checkoutservice}}
recommendationservice: {<<: *build, variables: {SVC: recommendationservice, CTX: src/recommendationservice}}
adservice:             {<<: *build, variables: {SVC: adservice, CTX: src/adservice}}
loadgenerator:         {<<: *build, variables: {SVC: loadgenerator, CTX: src/loadgenerator}}
```

### 4.2. Разбор

| Элемент | Значение | Комментарий |
|---|---|---|
| `stages` | `[build]` | Одна стадия — только сборка |
| `HARBOR` | `harbor.platform-mvp-potapov.ru/online-boutique` | Проект `online-boutique` в Harbor |
| `TAG` | `$CI_COMMIT_SHORT_SHA` | Короткий SHA коммита — уникальный тег |
| `KANIKO_IMAGE` | `gcr.io/kaniko-project/executor:v1.23.2-debug` | `-debug` содержит shell, нужен для `cat > config.json` |
| `entrypoint: [""]` | пустой | Обязательно: иначе Kaniko-образ запустит свой entrypoint и проигнорирует `script` |
| `--context` | `$CI_PROJECT_DIR/$CTX` | Контекст сборки — каталог сервиса |
| `--dockerfile` | `$CI_PROJECT_DIR/$CTX/Dockerfile` | Dockerfile внутри контекста |
| `--destination` ×2 | `:$TAG` и `:latest` | Уникальный тег + плавающий `latest` |
| `--cache=true` | — | Кеш слоёв в Harbor |
| `--cache-repo` | `$HARBOR/cache` | Отдельный репозиторий для кеша |
| `rules` | `$CI_COMMIT_BRANCH == "master"` | Pipeline только для `master` |

### 4.3. YAML-якоря вместо `parallel:matrix`

В проекте используется **YAML-якорь** `&build` + `<<: *build`, а не `parallel:matrix`. Это даёт тот же результат (11 параллельных job'ов), но проще читается и не требует вычисления `CTX` из матрицы.

Эквивалент через `parallel:matrix` (если нужен):

```yaml
build:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug
    entrypoint: [""]
  parallel:
    matrix:
      - SVC: [frontend, cartservice, productcatalogservice, currencyservice,
              paymentservice, shippingservice, emailservice, checkoutservice,
              recommendationservice, adservice, loadgenerator]
        CTX: [src/frontend, src/cartservice/src, src/productcatalogservice,
              src/currencyservice, src/paymentservice, src/shippingservice,
              src/emailservice, src/checkoutservice, src/recommendationservice,
              src/adservice, src/loadgenerator]
  script:
    - /kaniko/executor --context "$CI_PROJECT_DIR/$CTX" ...
```

> `parallel:matrix` создаёт декартово произведение (11 × 11 = 121 job), если `SVC` и `CTX` заданы отдельными списками. Правильный вариант — список словарей:
>
> ```yaml
> parallel:
>   matrix:
>     - SVC: frontend
>       CTX: src/frontend
>     - SVC: cartservice
>       CTX: src/cartservice/src
>     # ...
> ```
>
> Именно поэтому в проекте выбран вариант с якорями.

### 4.4. Соответствие сервисов и контекстов

| Сервис | `CTX` | Язык |
|---|---|---|
| `frontend` | `src/frontend` | Go |
| `cartservice` | `src/cartservice/src` | C# (.NET) |
| `productcatalogservice` | `src/productcatalogservice` | Go |
| `currencyservice` | `src/currencyservice` | Node.js |
| `paymentservice` | `src/paymentservice` | Node.js |
| `shippingservice` | `src/shippingservice` | Go |
| `emailservice` | `src/emailservice` | Python |
| `checkoutservice` | `src/checkoutservice` | Go |
| `recommendationservice` | `src/recommendationservice` | Python |
| `adservice` | `src/adservice` | Java |
| `loadgenerator` | `src/loadgenerator` | Python (Locust) |

> `cartservice` — единственный сервис, у которого контекст сборки на уровень глубже (`src/cartservice/src`), потому что `Dockerfile` лежит рядом с `.csproj`, а не в корне каталога сервиса.

### 4.5. Полный цикл: build → push → bump → sync

| Шаг | Что происходит | Где видно |
|---|---|---|
| 1. `git push` в `master` | GitLab создаёт pipeline | **CI/CD → Pipelines** |
| 2. Runner забирает job | Создаётся Pod `runner-xxxxx-project-1-concurrent-0-...` | `kubectl -n gitlab get pods` |
| 3. Kaniko собирает образ | Слои кешируются в `online-boutique/cache` | Лог job'а |
| 4. Push в Harbor | Образ `online-boutique/<svc>:<sha>` и `:latest` | Harbor UI → проект `online-boutique` |
| 5. **Bump тега** | Обновление `image:` в манифестах `k8s/apps/online-boutique/*.yaml` | Коммит в репозитории платформы |
| 6. ArgoCD sync | Application `online-boutique` подхватывает новый тег | ArgoCD UI → `online-boutique` |
| 7. Rolling update | Deployment'ы обновляют поды | `kubectl -n online-boutique rollout status` |

> **Важно.** Шаг 5 (bump) в текущей реализации **не автоматизирован**: pipeline только собирает и пушит образы. Обновление тега в манифестах выполняется вручную:
>
> ```bash
> cd k8s/apps/online-boutique
> sed -i 's|frontend:v1.0.0|frontend:<NEW_SHA>|' frontend.yaml
> git commit -am "bump frontend to <NEW_SHA>" && git push
> ```
>
> Автоматизация требует отдельной job'ы с правом записи в репозиторий платформы (deploy key / project access token). См. §8.

---

## 5. Секреты в CI

### 5.1. Переменные

| Переменная | Источник | Где используется |
|---|---|---|
| `HARBOR_USER` | Secret `gitlab/harbor-credentials`, ключ `HARBOR_USER` | Логин в Harbor |
| `HARBOR_PASSWORD` | Secret `gitlab/harbor-credentials`, ключ `HARBOR_PASSWORD` | Пароль в Harbor |

Secret создаётся External Secrets Operator из Vault (см. [security.md](security.md)):

```bash
kubectl -n gitlab get secret harbor-credentials -o jsonpath='{.data}' | jq 'keys'
# ["HARBOR_PASSWORD", "HARBOR_USER"]
```

### 5.2. Регистрация в GitLab

**Settings → CI/CD → Variables → Add variable**:

| Key | Value | Type | Protected | Masked |
|---|---|---|---|---|
| `HARBOR_USER` | `admin` | Variable | нет | нет |
| `HARBOR_PASSWORD` | `<HARBOR_ADMIN_PASSWORD>` | **Variable** | нет | **да** |

> Тип должен быть **Variable**, а не **File**: Kaniko читает их как обычные строки.

### 5.3. Использование в `.gitlab-ci.yml`

Текущий файл **не использует** `HARBOR_USER` / `HARBOR_PASSWORD` — учётные данные захардкожены в `config.json`:

```yaml
- |
  cat > /kaniko/.docker/config.json <<EOF
  {"auths":{"harbor.platform-mvp-potapov.ru":{"auth":"$(printf 'admin:<HARBOR_ADMIN_PASSWORD>' | base64)"}}}
  EOF
```

> `<HARBOR_ADMIN_PASSWORD>` — см. Secret `harbor-core` в namespace `harbor` (ключ `HARBOR_ADMIN_PASSWORD`) либо Vault `kv/platform/harbor`.

Правильный вариант с переменными:

```yaml
- |
  cat > /kaniko/.docker/config.json <<EOF
  {"auths":{"harbor.platform-mvp-potapov.ru":{"auth":"$(printf '%s:%s' "$HARBOR_USER" "$HARBOR_PASSWORD" | base64)"}}}
  EOF
```

Это устраняет пароль из репозитория. Зафиксировано в [known-limitations.md](known-limitations.md).

### 5.4. Проверка переменных

```bash
# В UI: Settings → CI/CD → Variables — обе переменные присутствуют
# В логе job'а (при debug) — значения маскируются как [MASKED]
```

---

## 6. Альтернатива: сборка скриптом

Если GitLab/Runner недоступны или нужна сборка «здесь и сейчас», используется [`scripts/build-online-boutique.sh`](../scripts/build-online-boutique.sh).

### 6.1. Параметры

| Переменная | Значение по умолчанию | Назначение |
|---|---|---|
| `HARBOR` | `harbor.platform-mvp-potapov.ru/online-boutique` | Проект Harbor |
| `TAG` | `v1.0.0` | Тег образов |
| `REPO_URL` | `https://github.com/potapovanton149/online-boutique.git` | Репозиторий с исходниками |
| `BRANCH` | `master` | Ветка |
| `NS` | `ci` | Namespace для сборки |
| `KANIKO_IMAGE` | `gcr.io/kaniko-project/executor:v1.23.2-debug` | Образ Kaniko |
| `LOG` | `/tmp/ob-build-<timestamp>.log` | Файл лога |

### 6.2. Алгоритм

| Шаг | Действие |
|---|---|
| Preflight | Проверка `kubectl`, `git`; создание namespace `ci`; проверка Secret `ci/harbor-creds` |
| 1/3 | Создание PVC `ob-src` (Longhorn, RWO, `2Gi`) |
| 2/3 | Клон репозитория подом `ob-clone` (`alpine/git:2.45.2`) в PVC, ожидание `Succeeded` (таймаут 600 с) |
| 3/3 | Последовательный запуск 11 Kaniko-подов, ожидание `Succeeded` (таймаут 1800 с каждый) |

### 6.3. Отличия от GitLab CI

| Параметр | GitLab CI | Скрипт |
|---|---|---|
| Параллельность | 11 job'ов параллельно (до `concurrent: 4`) | Последовательно, 1 под за раз |
| Кеш | `--cache=true --cache-repo=$HARBOR/cache` | `--cache=false` |
| Тег | `$CI_COMMIT_SHORT_SHA` | `v1.0.0` (по умолчанию) |
| Контекст | `$CI_PROJECT_DIR/$CTX` | `dir:///src/repo/$CTX` |
| Ресурсы Kaniko | лимиты Runner (`1` / `1Gi`) | requests `500m` / `1Gi`, limits `2` / `4Gi` |
| Аутентификация | `config.json` в job'е | Secret `ci/harbor-creds` (`items: .dockerconfigjson → config.json`) |

### 6.4. Запуск

```bash
# Создать Secret для pull/push
kubectl -n ci create secret docker-registry harbor-creds \
  --docker-server=harbor.platform-mvp-potapov.ru \
  --docker-username=admin \
  --docker-password='<HARBOR_ADMIN_PASSWORD>'

# Запустить сборку
./scripts/build-online-boutique.sh

# С другим тегом
TAG=v1.0.1 ./scripts/build-online-boutique.sh
```

Ожидаемый вывод:

```
[12:00:01] >>> [1/3] PVC ob-src (Longhorn, RWO, 2Gi)
[12:00:02] >>> [2/3] Клон репозитория в PVC (pod ob-clone)
[12:00:35] >>> [3/3] Kaniko: последовательная сборка 11 сервисов
[12:00:35]   → kaniko-frontend (ctx=src/frontend)
[12:03:10]     ✓ frontend
...
[12:35:00] >>> Итог
[12:35:00]   Успешно: 11/11
[12:35:00]   Все образы: harbor.platform-mvp-potapov.ru/online-boutique/<svc>:v1.0.0
```

---

## 7. Проверка end-to-end

### 7.1. Полный сценарий

```bash
# 1. Runner онлайн
kubectl -n gitlab get pods | grep runner
# gitlab-runner-xxxxx   1/1   Running

# 2. Pipeline запущен
# UI: https://gitlab.platform-mvp-potapov.ru → проект → CI/CD → Pipelines

# 3. Job-поды создаются
kubectl -n gitlab get pods -w | grep -E 'runner-.*-concurrent'

# 4. Образы в Harbor
curl -k -u admin:<PASS> \
  'https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories?page_size=50' \
  | jq -r '.[].name'

# 5. Тег в Harbor совпадает с SHA коммита
curl -k -u admin:<PASS> \
  'https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories/frontend/artifacts?page_size=5' \
  | jq -r '.[].tags[].name'

# 6. ArgoCD синхронизирован
kubectl -n argocd get application online-boutique
# NAME              SYNC STATUS   HEALTH STATUS
# online-boutique   Synced        Healthy

# 7. Поды используют новый образ
kubectl -n online-boutique get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# 8. Приложение отвечает
curl -k -H 'Host: shop.platform-mvp-potapov.ru' https://192.168.190.153:30443/ -o /dev/null -w '%{http_code}\n'
# 200
```

### 7.2. Диагностика

| Симптом | Причина | Решение |
|---|---|---|
| Pipeline в статусе `pending` | Нет доступного Runner'а | Проверить `kubectl -n gitlab get pods \| grep runner`; теги job'а vs теги Runner'а |
| `ERROR: Job failed (system failure): ... x509` | Runner не доверяет CA GitLab | Проверить `certsSecretName` и кастомный образ (§3.3) |
| `error checking push permissions` | Неверные учётные данные Harbor | Проверить `config.json` / `HARBOR_USER`+`HARBOR_PASSWORD` |
| `Invalid auth config` | `config.json` не создан или пустой | Убедиться, что `entrypoint: [""]` и `mkdir -p /kaniko/.docker` |
| `is a directory` при сборке | Неверный `WORKDIR`/`COPY` в Dockerfile | См. [application.md](application.md) |
| Job висит на `Preparing the docker executor` | `privileged: true` не разрешён | Проверить PodSecurity в namespace `gitlab` |
| Образ собран, но под не стартует | Тег в манифесте не обновлён | Выполнить bump (§4.5) |

Полный список — [troubleshooting.md](troubleshooting.md).

---

## 8. Известные ограничения

| Ограничение | Причина | Следствие |
|---|---|---|
| Bump тега не автоматизирован | Нет job'ы с правом записи в репозиторий платформы | После сборки нужно вручную обновить `image:` в манифестах |
| Пароль Harbor в `.gitlab-ci.yml` | Учебный проект | Учётные данные администратора Harbor захардкожены в открытом виде в репозитории (см. Secret `harbor-core`) |
| `HARBOR_USER`/`HARBOR_PASSWORD` не используются | Историческая реализация | Переменные созданы, но pipeline их игнорирует |
| GitLab недоступен из WSL2 | DPI/маршрутизация | Только через `ssh -L` (см. ниже) |
| Self-signed CA | `configureCertmanager: false` + staging-сертификат | Требуется кастомный образ Runner и `tls_verify = false` |
| `privileged: true` | Совместимость сборщиков | Расширенные права job-подов |
| `concurrent: 4` | Ресурсы стенда | Не более 4 job'ов одновременно; 11 сервисов собираются в 3 волны |
| Образы из `bitnamilegacy` | Удаление тегов из Docker Hub | Нет обновлений безопасности для PostgreSQL/Redis |
| Registry GitLab включён, но не используется | Образы идут в Harbor | Лишний под `registry` потребляет ресурсы |
| Нет стадий test/lint/security-scan | Учебный проект | Pipeline только собирает; Trivy-сканирование выполняется в Harbor |
| Нет `needs`/`dependencies` | Одна стадия | Все 11 job'ов независимы и стартуют сразу |

### 8.1. Доступ к GitLab из WSL2

Из WSL2 `https://gitlab.platform-mvp-potapov.ru` не резолвится и/или блокируется. Рабочий способ — SSH-туннель:

```bash
ssh -L 8443:192.168.190.153:30443 devops@192.168.190.153
```

Затем в браузере Windows: `https://localhost:8443`. Чтобы GitLab корректно строил ссылки, добавьте в `C:\Windows\System32\drivers\etc\hosts`:

```
127.0.0.1 gitlab.platform-mvp-potapov.ru
```

И открывайте `https://gitlab.platform-mvp-potapov.ru:8443`.

Проверка через `curl`:

```bash
curl -k --resolve gitlab.platform-mvp-potapov.ru:8443:127.0.0.1 \
  https://gitlab.platform-mvp-potapov.ru:8443/users/sign_in -o /dev/null -w '%{http_code}\n'
# 200
```

### 8.2. Как автоматизировать bump

Направление развития (не реализовано):

```yaml
# .gitlab-ci.yml — дополнительная стадия
stages: [build, bump]

bump-manifests:
  stage: bump
  image: alpine/git:2.45.2
  needs: [frontend, cartservice, productcatalogservice, currencyservice,
          paymentservice, shippingservice, emailservice, checkoutservice,
          recommendationservice, adservice, loadgenerator]
  script:
    - git clone https://oauth2:$PLATFORM_TOKEN@github.com/potapovanton149/platform-mvp.git
    - cd platform-mvp/k8s/apps/online-boutique
    - sed -i "s|:v1.0.0|:$CI_COMMIT_SHORT_SHA|g" *.yaml
    - git -c user.email=ci@platform -c user.name=ci commit -am "bump to $CI_COMMIT_SHORT_SHA"
    - git push
  rules:
    - if: $CI_COMMIT_BRANCH == "master"
```

Требуется `PLATFORM_TOKEN` — project access token с правом `write_repository`.

---

## Связанные документы

- [architecture.md](architecture.md) — место CI/CD в общей архитектуре
- [deployment.md](deployment.md) — Шаг 8: развёртывание GitLab и регистрация Runner
- [security.md](security.md) — Secret `harbor-credentials` и Vault
- [registry.md](registry.md) — Harbor: проекты, логин, push, Trivy
- [application.md](application.md) — Online Boutique и Dockerfile-фиксы
- [troubleshooting.md](troubleshooting.md) — диагностика GitLab и Runner
- [known-limitations.md](known-limitations.md) — полный список ограничений
