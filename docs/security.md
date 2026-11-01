# Секреты и доступы

Документ описывает, как в платформе хранятся и доставляются секреты: HashiCorp Vault как источник истины, External Secrets Operator (ESO) как механизм синхронизации, Kubernetes Secret как точка потребления подом. Также приведён обзор RBAC и честный список ограничений.

- [1. Схема работы](#1-схема-работы)
- [2. Vault](#2-vault)
- [3. External Secrets Operator](#3-external-secrets-operator)
- [4. Пять ExternalSecret](#4-пять-externalsecret)
- [5. Как залить секрет в Vault](#5-как-залить-секрет-в-vault)
- [6. Как создать новый ExternalSecret](#6-как-создать-новый-externalsecret)
- [7. RBAC](#7-rbac)
- [8. Проверка](#8-проверка)
- [9. Известные ограничения](#9-известные-ограничения)

---

## 1. Схема работы

```
┌──────────────┐   token (Secret vault-token)   ┌──────────────────────────┐
│    Vault     │◄───────────────────────────────│ External Secrets Operator │
│  ns: vault   │                                │  ns: external-secrets     │
│  kv/ (v2)    │──── kv/platform/* ────────────►│  ClusterSecretStore       │
└──────────────┘                                │  vault-backend            │
                                                └────────────┬─────────────┘
                                                             │ создаёт/обновляет
                                                             ▼
                                              ┌──────────────────────────────┐
                                              │ Kubernetes Secret            │
                                              │ (cert-manager, external-dns, │
                                              │  monitoring, gitlab)         │
                                              └────────────┬─────────────────┘
                                                           │ envFrom / volume
                                                           ▼
                                              ┌──────────────────────────────┐
                                              │ Pod                          │
                                              └──────────────────────────────┘
```

Ключевые свойства:

| Свойство | Значение |
|---|---|
| Источник истины | Vault, KV v2, префикс `kv/platform/` |
| Механизм доставки | ESO, `refreshInterval: 1h` |
| Аутентификация ESO в Vault | статический токен из Secret `external-secrets/vault-token` |
| Хранение в кластере | обычные Kubernetes Secret (base64, не шифруются at-rest) |
| Ротация | автоматическая раз в час + принудительная через аннотацию `force-sync` |

---

## 2. Vault

### 2.1. Параметры развёртывания

| Параметр | Значение |
|---|---|
| Chart | vendored [`k8s/charts/vault`](../k8s/charts/vault) — `vault` `0.28.1`, appVersion `1.17.2` |
| ArgoCD Application | [`31-vault.yaml`](../k8s/apps/31-vault.yaml), sync-wave `2` |
| Namespace | `vault` |
| URL | `https://vault.platform-mvp-potapov.ru` |
| Режим | **dev** (`server.dev.enabled: true`) |
| Root token | `server.dev.devRootToken` в [`k8s/values/vault.yaml`](../k8s/values/vault.yaml) |
| TLS | `global.tlsDisable: true` (внутри кластера — HTTP), снаружи — TLS от ingress |
| Ingress backend protocol | `HTTP` |
| UI | `enabled: true`, `serviceType: ClusterIP` |
| Persistence | `server.dataStorage.enabled: false` — **данные не сохраняются** |
| Audit log | `server.auditStorage.enabled: false`, `VAULT_AUDIT_LOG_DEVICE: stdout` |
| CSI provider | `csi.enabled: false` |
| Agent injector | `injector.enabled: false` |
| Metrics | `server.metrics.enabled: true`, ServiceMonitor с меткой `release: kube-prometheus-stack` |
| Resources | requests `100m` / `256Mi`, limits `500m` / `512Mi` |

### 2.2. Почему dev-режим

| Причина | Пояснение |
|---|---|
| Не требуется инициализация | В prod-режиме нужны `vault operator init` (5 unseal-ключей) и `vault operator unseal` после каждого рестарта — это ручные операции, несовместимые с полностью автоматическим GitOps-развёртыванием |
| Не требуется auto-unseal | Auto-unseal требует внешнего KMS (AWS KMS, GCP KMS, Transit) — недоступно в изолированном стенде |
| Учебная цель | Демонстрация паттерна «Vault → ESO → Secret → Pod», а не эксплуатация Vault в production |
| Простота воспроизведения | Стенд разворачивается и сносится многократно; dev-режим стартует «из коробки» |

### 2.3. Последствия dev-режима

| Последствие | Детали |
|---|---|
| Данные в памяти | `dataStorage.enabled: false` — при рестарте пода Vault все секреты теряются |
| Root token фиксирован | `devRootToken` задан в values и известен всем, у кого есть доступ к репозиторию |
| Нет TLS внутри кластера | `tlsDisable: true` — трафик ESO → Vault идёт по HTTP внутри пода-сети |
| Нет HA | Один под, без реплик |
| KV v2 не включён по умолчанию | Требуется ручной `vault secrets enable -path=kv -version=2 kv` |

### 2.4. Как перейти в production

Пошаговый план миграции (не реализован в проекте, приведён как направление развития):

1. **Отключить dev-режим.**
   ```yaml
   # k8s/values/vault.yaml
   server:
     dev:
       enabled: false
     standalone:
       enabled: true
     dataStorage:
       enabled: true
       size: 10Gi
       storageClass: longhorn
     auditStorage:
       enabled: true
       size: 5Gi
   ```

2. **Включить TLS.**
   ```yaml
   global:
     tlsDisable: false
   server:
     ingress:
       annotations:
         nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
   ```
   Сертификат — через cert-manager (ClusterIssuer `letsencrypt-staging`), Secret `vault-tls`.

3. **Инициализировать и распечатать Vault.**
   ```bash
   kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=5 -key-threshold=3
   # сохранить 5 unseal-ключей и initial root token ВНЕ кластера
   kubectl -n vault exec -it vault-0 -- vault operator unseal   # ×3
   ```

4. **Настроить auto-unseal** через внешний KMS (или Transit в отдельном Vault) — иначе после каждого рестарта пода потребуется ручной unseal.

5. **Заменить статический токен ESO на Kubernetes auth.**
   ```bash
   # В Vault
   vault auth enable kubernetes
   vault write auth/kubernetes/config \
     kubernetes_host="https://kubernetes.default.svc:443"

   vault policy write eso-policy - <<'EOF'
   path "kv/data/platform/*" { capabilities = ["read"] }
   path "kv/metadata/platform/*" { capabilities = ["read", "list"] }
   EOF

   vault write auth/kubernetes/role/eso \
     bound_service_account_names=external-secrets \
     bound_service_account_namespaces=external-secrets \
     policies=eso-policy \
     ttl=1h
   ```
   ```yaml
   # ClusterSecretStore
   spec:
     provider:
       vault:
         server: https://vault.vault.svc:8200
         path: kv
         version: v2
         caProvider:
           type: Secret
           name: vault-tls
           key: ca.crt
           namespace: vault
         auth:
           kubernetes:
             mountPath: kubernetes
             role: eso
             serviceAccountRef:
               name: external-secrets
               namespace: external-secrets
   ```

6. **Включить audit log** в файл на PVC (а не в stdout) и настроить ротацию.

7. **Включить CSI-провайдер или Agent Injector**, если нужна доставка секретов без промежуточного Kubernetes Secret.

---

## 3. External Secrets Operator

### 3.1. Параметры

| Параметр | Значение |
|---|---|
| Chart | `external-secrets` `0.10.4` из `https://charts.external-secrets.io` |
| ArgoCD Application | [`30-external-secrets.yaml`](../k8s/apps/30-external-secrets.yaml), sync-wave `2` |
| Namespace | `external-secrets` |
| `installCRDs` | `true` |
| Компоненты | `external-secrets` (replicaCount 1), `webhook` (1), `certController` (1) |
| Metrics | включены для всех трёх, ServiceMonitor с меткой `release: kube-prometheus-stack` |
| Resources (основной) | requests `50m` / `128Mi`, limits `200m` / `256Mi` |

### 3.2. ClusterSecretStore `vault-backend`

Манифест: [`k8s/manifests/vault-cluster-secret-store.yaml`](../k8s/manifests/vault-cluster-secret-store.yaml).

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: http://vault.vault.svc:8200
      path: kv
      version: v2
      auth:
        tokenSecretRef:
          name: vault-token
          key: token
          namespace: external-secrets
```

| Поле | Значение | Комментарий |
|---|---|---|
| `server` | `http://vault.vault.svc:8200` | ClusterIP-сервис Vault, HTTP (TLS отключён) |
| `path` | `kv` | Имя KV-движка, включённого вручную |
| `version` | `v2` | KV версии 2 — путь в Vault получается `kv/data/<key>` |
| `auth.tokenSecretRef` | Secret `vault-token`, ключ `token`, ns `external-secrets` | Статический токен |

> **Важно.** `ClusterSecretStore` **не управляется ArgoCD** — каталог `k8s/manifests/` подключён к Application `namespaces` только с `include: "namespaces.yaml"`. Применять вручную:
>
> ```bash
> kubectl apply -f k8s/manifests/vault-cluster-secret-store.yaml
> ```

### 3.3. Secret `vault-token`

```bash
kubectl -n external-secrets create secret generic vault-token \
  --from-literal=token=root
```

В dev-режиме значение совпадает с `server.dev.devRootToken`. В production этот Secret заменяется на Kubernetes auth (см. §2.4, п. 5).

### 3.4. Как ESO разрешает путь

Для `ExternalSecret` с `remoteRef.key: platform/cloudflare` и `property: api-token` ESO выполняет:

```
GET http://vault.vault.svc:8200/v1/kv/data/platform/cloudflare
→ { "data": { "data": { "api-token": "..." } } }
→ берёт .data.data["api-token"]
```

Отсюда два следствия:

1. В `remoteRef.key` **не** указывается префикс `kv/` — он уже задан в `ClusterSecretStore.path`.
2. В `remoteRef.key` **не** указывается `data/` — ESO добавляет его сам для KV v2.

Именно из-за этого в манифестах встречаются оба варианта записи ключа:

| Файл | `remoteRef.key` | Итоговый путь в Vault | Корректно |
|---|---|---|---|
| `cloudflare-api-token-certmanager.yaml` | `platform/cloudflare` | `kv/data/platform/cloudflare` | да |
| `cloudflare-api-token-externaldns.yaml` | `platform/cloudflare` | `kv/data/platform/cloudflare` | да |
| `telegram-alertmanager.yaml` | `platform/telegram` | `kv/data/platform/telegram` | да |
| `gitlab-root.yaml` | `kv/platform/gitlab` | `kv/data/kv/platform/gitlab` | **нет** |
| `harbor-credentials.yaml` | `kv/platform/harbor` | `kv/data/kv/platform/harbor` | **нет** |

В двух последних файлах префикс `kv/` указан ошибочно: ESO добавляет имя движка из `ClusterSecretStore.path` самостоятельно, поэтому получается двойной префикс. Такие ExternalSecret переходят в состояние `SecretSyncedError` с кодом 404, если в Vault не создан «вложенный» путь `kv/kv/platform/...`. Расхождение зафиксировано в [troubleshooting.md](troubleshooting.md) и [known-limitations.md](known-limitations.md); при развёртывании с нуля используйте ключи **без** префикса `kv/`.

---

## 4. Пять ExternalSecret

| # | Файл | Имя ExternalSecret | Namespace | Целевой Secret | Ключи | Источник в Vault |
|---|---|---|---|---|---|---|
| 1 | [`cloudflare-api-token-certmanager.yaml`](../k8s/manifests/external-secrets/cloudflare-api-token-certmanager.yaml) | `cloudflare-api-token` | `cert-manager` | `cloudflare-api-token` | `api-token` | `platform/cloudflare` → `api-token` |
| 2 | [`cloudflare-api-token-externaldns.yaml`](../k8s/manifests/external-secrets/cloudflare-api-token-externaldns.yaml) | `cloudflare-api-token` | `external-dns` | `cloudflare-api-token` | `cloudflare_api_token` | `platform/cloudflare` → `api-token` |
| 3 | [`telegram-alertmanager.yaml`](../k8s/manifests/external-secrets/telegram-alertmanager.yaml) | `telegram-alertmanager` | `monitoring` | `alertmanager-telegram` | `bot-token`, `chat-id` | `platform/telegram` → `bot-token`, `chat-id` |
| 4 | [`gitlab-root.yaml`](../k8s/manifests/external-secrets/gitlab-root.yaml) | `gitlab-root-password` | `gitlab` | `gitlab-gitlab-initial-root-password` | `password` | `kv/platform/gitlab` → `root-password` |
| 5 | [`harbor-credentials.yaml`](../k8s/manifests/external-secrets/harbor-credentials.yaml) | `harbor-credentials` | `gitlab` | `harbor-credentials` | `HARBOR_USER`, `HARBOR_PASSWORD` | `kv/platform/harbor` → `admin-user`, `admin-password` |

Общие параметры всех пяти: `refreshInterval: 1h`, `secretStoreRef: {name: vault-backend, kind: ClusterSecretStore}`.

### 4.1. Особенности

**#1 и #2 — один и тот же секрет, разные имена ключей.** Это не опечатка, а требование чартов:

| Потребитель | Ожидаемое имя ключа | Почему |
|---|---|---|
| cert-manager | `api-token` | ClusterIssuer ссылается на `apiTokenSecretRef: {name: cloudflare-api-token, key: api-token}` |
| external-dns | `cloudflare_api_token` | Чарт `external-dns` монтирует Secret и читает переменную `CF_API_TOKEN` из ключа `cloudflare_api_token` |

Именно рассинхронизация этих имён — типичная причина ошибки `secret "cloudflare-api-token" not found` в cert-manager. См. [troubleshooting.md](troubleshooting.md#cert-manager).

**#4 — `creationPolicy: Owner` и `deletionPolicy: Retain`.**

```yaml
target:
  name: gitlab-gitlab-initial-root-password
  creationPolicy: Owner
  deletionPolicy: Retain
```

| Политика | Значение | Зачем |
|---|---|---|
| `creationPolicy: Owner` | ESO создаёт Secret и владеет им | Без этого чарт GitLab создаёт Secret сам, и ESO не может его перезаписать (`Merge` конфликтует с Helm) |
| `deletionPolicy: Retain` | При удалении ExternalSecret Secret остаётся | Защита от потери пароля root при случайном удалении Application |

**#5 — потребляется GitLab CI.** Ключи `HARBOR_USER` / `HARBOR_PASSWORD` имеют имена в верхнем регистре, потому что используются как CI/CD-переменные (см. [ci-cd.md](ci-cd.md)).

### 4.2. Кто создаёт ExternalSecret

| ExternalSecret | Создаётся через | Sync-wave |
|---|---|---|
| #1, #2, #3 | вручную (`kubectl apply -f k8s/manifests/external-secrets/`) | — |
| #4, #5 | ArgoCD Application `gitlab-external-secrets` ([`52-gitlab-external-secrets.yaml`](../k8s/apps/52-gitlab-external-secrets.yaml)), `include: '{gitlab-root.yaml,harbor-credentials.yaml}'` | 5 |

Application `gitlab-external-secrets` имеет wave `5`, потому что целевой Secret `gitlab-gitlab-initial-root-password` должен существовать **до** первого старта пода GitLab (wave `4`). На практике wave `5` срабатывает после `4`, поэтому Secret создаётся уже после запуска GitLab — и чарт успевает сгенерировать свой пароль. Это известное ограничение, см. [known-limitations.md](known-limitations.md).

---

## 5. Как залить секрет в Vault

### 5.1. Подключение

```bash
kubectl -n vault port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
# dev-режим: root-токен — см. Secret vault (ключ root-token)
export VAULT_TOKEN="$(kubectl -n vault get secret vault -o jsonpath='{.data.root-token}' | base64 -d)"

vault status
# Sealed: false
```

### 5.2. Включение KV v2 (один раз)

```bash
vault secrets enable -path=kv -version=2 kv
```

Проверка:

```bash
vault secrets list
# kv/    kv    kv_...
```

### 5.3. Запись секретов

```bash
# Cloudflare API Token (права: Zone:DNS:Edit, Zone:Zone:Read)
vault kv put kv/platform/cloudflare api-token="<CF_API_TOKEN>"

# Telegram bot
vault kv put kv/platform/telegram \
  bot-token="<BOT_TOKEN>" \
  chat-id="<CHAT_ID>"

# GitLab root password
vault kv put kv/platform/gitlab root-password="<GITLAB_ROOT_PASSWORD>"

# Harbor admin
vault kv put kv/platform/harbor \
  admin-user="admin" \
  admin-password="<HARBOR_ADMIN_PASSWORD>"
```

### 5.4. Проверка

```bash
vault kv list kv/platform
# cloudflare
# gitlab
# harbor
# telegram

vault kv get kv/platform/cloudflare
vault kv get -field=api-token kv/platform/cloudflare
```

### 5.5. Обновление секрета

```bash
vault kv put kv/platform/cloudflare api-token="<NEW_TOKEN>"

# Принудительно синхронизировать, не дожидаясь refreshInterval
kubectl -n cert-manager annotate externalsecret cloudflare-api-token \
  force-sync=$(date +%s) --overwrite
kubectl -n external-dns annotate externalsecret cloudflare-api-token \
  force-sync=$(date +%s) --overwrite
```

> `vault kv put` **перезаписывает** весь набор полей. Чтобы добавить поле, не потеряв остальные, используйте `vault kv patch`:
>
> ```bash
> vault kv patch kv/platform/telegram new-field="value"
> ```

---

## 6. Как создать новый ExternalSecret

### 6.1. Шаг 1 — залить секрет в Vault

```bash
vault kv put kv/platform/myapp \
  username="app-user" \
  password="<PASSWORD>"
```

### 6.2. Шаг 2 — создать манифест

```yaml
# k8s/manifests/external-secrets/myapp-credentials.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-credentials
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: platform/myapp        # БЕЗ префикса kv/
        property: username
    - secretKey: password
      remoteRef:
        key: platform/myapp
        property: password
```

### 6.3. Шаг 3 — применить и проверить

```bash
kubectl apply -f k8s/manifests/external-secrets/myapp-credentials.yaml

kubectl -n myapp get externalsecret myapp-credentials
# STATUS: SecretSynced, READY: True

kubectl -n myapp get secret myapp-credentials
kubectl -n myapp get secret myapp-credentials -o jsonpath='{.data.username}' | base64 -d
```

### 6.4. Шаг 4 — подключить к поду

```yaml
spec:
  containers:
    - name: myapp
      envFrom:
        - secretRef:
            name: myapp-credentials
      # либо точечно:
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: myapp-credentials
              key: password
```

### 6.5. Шаг 5 — добавить в ArgoCD (опционально)

Если ExternalSecret должен управляться GitOps, добавьте файл в `include` существующего Application или создайте новый:

```yaml
# k8s/apps/53-myapp-external-secrets.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-external-secrets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  project: default
  source:
    repoURL: https://github.com/potapovanton149/platform-mvp
    targetRevision: master
    path: k8s/manifests/external-secrets
    directory:
      recurse: false
      include: '{myapp-credentials.yaml}'
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true]
```

### 6.6. Использование `dataFrom` (все ключи сразу)

Если нужно забрать все поля секрета без перечисления:

```yaml
spec:
  dataFrom:
    - extract:
        key: platform/myapp
```

Тогда имена ключей в Kubernetes Secret совпадут с именами полей в Vault.

---

## 7. RBAC

Детальная настройка RBAC в проекте не выполнялась — используются роли, поставляемые чартами. Обзорная картина:

| Компонент | ServiceAccount | Права | Источник |
|---|---|---|---|
| ArgoCD application-controller | `argocd-application-controller` | `cluster-admin` (через `ClusterRoleBinding`) | чарт ArgoCD |
| ArgoCD repo-server | `argocd-repo-server` | чтение репозиториев, работа с секретами репозиториев | чарт ArgoCD |
| External Secrets Operator | `external-secrets` | чтение/запись Secret во всех namespace, чтение ClusterSecretStore | чарт ESO |
| ESO webhook | `external-secrets-webhook` | валидация/мутация ExternalSecret | чарт ESO |
| ESO cert-controller | `external-secrets-cert-controller` | управление webhook-сертификатами | чарт ESO |
| Vault server | `vault` | `system:auth-delegator` (TokenReview), discovery-роль в своём ns | чарт Vault |
| Longhorn | `longhorn-service-account` | `longhorn-role` (ClusterRole), `cluster-admin` для support-bundle | чарт Longhorn |
| Prometheus | `kube-prometheus-stack-prometheus` | чтение ServiceMonitor/PodMonitor/PrometheusRule во всех ns | чарт kube-prometheus-stack |
| GitLab Runner | `gitlab-runner` | создание Pod/Secret/ConfigMap в `gitlab-runner` | чарт gitlab-runner |
| Приложения | `default` | стандартный ServiceAccount namespace | — |

Проверка:

```bash
# Кто имеет cluster-admin
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .subjects[]? | "\(.kind)/\(.namespace // "-")/\(.name)"'

# Права ServiceAccount ESO
kubectl auth can-i --list --as=system:serviceaccount:external-secrets:external-secrets -A | head -20

# Права ServiceAccount приложения
kubectl auth can-i --list --as=system:serviceaccount:online-boutique:default -n online-boutique
```

### 7.1. Что стоит ужесточить

| Область | Текущее состояние | Рекомендация |
|---|---|---|
| ArgoCD | `cluster-admin` | Ограничить `ClusterRole` списком необходимых API-групп |
| ESO | чтение/запись Secret во всех namespace | Ограничить `Role` в конкретных namespace |
| Vault | root-токен | Kubernetes auth + политики (см. §2.4) |
| Приложения | `default` ServiceAccount | Отдельный SA с `automountServiceAccountToken: false` |
| NetworkPolicy | не настроены | Ограничить трафик между namespace (Cilium поддерживает) |

---

## 8. Проверка

### 8.1. Полная проверка цепочки

```bash
# 1. Vault работает
kubectl -n vault get pods
kubectl -n vault port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$(kubectl -n vault get secret vault -o jsonpath='{.data.root-token}' | base64 -d)"
vault status

# 2. Секреты на месте
vault kv list kv/platform

# 3. ClusterSecretStore валиден
kubectl get clustersecretstore vault-backend
kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions}'

# 4. Все ExternalSecret синхронизированы
kubectl get externalsecret -A
# Ожидается: STATUS=SecretSynced, READY=True для всех пяти

# 5. Целевые Secret созданы
kubectl -n cert-manager get secret cloudflare-api-token
kubectl -n external-dns get secret cloudflare-api-token
kubectl -n monitoring get secret alertmanager-telegram
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password
kubectl -n gitlab get secret harbor-credentials
```

### 8.2. Диагностика

```bash
# Детали конкретного ExternalSecret
kubectl -n cert-manager describe externalsecret cloudflare-api-token

# События ESO
kubectl -n external-secrets logs deploy/external-secrets --tail=100

# Проверить, что ключ реально есть в Vault
vault kv get kv/platform/cloudflare

# Проверить содержимое созданного Secret
kubectl -n monitoring get secret alertmanager-telegram -o jsonpath='{.data}' | jq 'keys'
```

| Симптом | Причина | Решение |
|---|---|---|
| `SecretSyncedError: ... 403` | KV v2 не включён или неверный токен | `vault secrets enable -path=kv -version=2 kv`; проверить `vault-token` |
| `SecretSyncedError: ... 404` | Неверный `remoteRef.key` (лишний префикс `kv/`) | Убрать `kv/` из `key` |
| `SecretSyncedError: ... property not found` | Неверное имя поля в Vault | `vault kv get` и сверить `property` |
| `READY: False`, `SecretNotFound` | Целевой namespace не существует | Создать namespace или `CreateNamespace=true` |
| Secret создан, но под не видит | Под запущен до создания Secret | `kubectl rollout restart deploy/<name>` |

Полный список — [troubleshooting.md](troubleshooting.md).

---

## 9. Известные ограничения

| Ограничение | Причина | Риск | Как исправить |
|---|---|---|---|
| Vault в dev-режиме | Автоматизация развёртывания | Секреты теряются при рестарте пода | §2.4 |
| Root-токен в values | Учебный проект | Полный доступ к Vault у всех с доступом к репозиторию | Kubernetes auth |
| `vault-token` = root | Упрощение | ESO имеет полные права в Vault | Политика только на чтение `kv/data/platform/*` |
| TLS отключён внутри кластера | Упрощение | Трафик ESO → Vault по HTTP | Включить TLS (§2.4, п. 2) |
| Нет audit log на диске | `auditStorage.enabled: false` | Нет истории доступа к секретам | Включить `auditStorage` |
| Пароли в values-файлах | Учебный проект | Пароли Harbor, Grafana, MinIO и root-токен Vault лежат в Git в открытом виде (см. Secret `harbor-core`, `kube-prometheus-stack-grafana`, `gitlab-object-storage`, `vault`) | Вынести в Vault + ESO |
| Kubernetes Secret не шифруются at-rest | Не настроен `EncryptionConfiguration` | base64 ≠ шифрование; доступ к etcd = доступ к секретам | Включить encryption provider |
| `ClusterSecretStore` вне GitOps | Не подключён к Application | Ручное применение, дрейф конфигурации | Добавить в `include` |
| ExternalSecret #1–#3 вне GitOps | Не подключены к Application | Ручное применение | Добавить в `include` |
| Префикс `kv/` в `remoteRef.key` (#4, #5) | Историческая ошибка | Путь `kv/data/kv/platform/...` | Убрать префикс |
| Wave `5` для `gitlab-external-secrets` | Порядок волн | Secret создаётся после старта GitLab | Перенести на wave `3` |
| RBAC не ужесточён | Учебный проект | Избыточные права | §7.1 |

---

## Связанные документы

- [architecture.md](architecture.md) — поток секретов в общей архитектуре
- [deployment.md](deployment.md) — Шаг 7: инициализация Vault и заливка секретов
- [monitoring.md](monitoring.md) — использование Secret `alertmanager-telegram`
- [ci-cd.md](ci-cd.md) — использование `HARBOR_USER` / `HARBOR_PASSWORD`
- [troubleshooting.md](troubleshooting.md) — диагностика Vault и ESO
- [known-limitations.md](known-limitations.md) — полный список ограничений
