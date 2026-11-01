# Известные ограничения

Документ фиксирует всё, что в платформе **не работает** или работает **не
так, как должно в production**. Ограничения не скрываются: каждое имеет
причину, способ обхода и план устранения.

- Версия платформы: **v1.0.0**
- Kubernetes: **v1.30.4** (Kubespray v2.26.0)
- Дата фиксации: ноябрь 2025

---

## 1. Как читать этот документ

Каждое ограничение имеет идентификатор `L-NN`, критичность и статус.

| Критичность | Значение |
|---|---|
| 🔴 **Высокая** | Блокирует заявленную функциональность; обход есть, но он ручной |
| 🟠 **Средняя** | Функциональность работает частично или небезопасно |
| 🟡 **Низкая** | Косметика, удобство, «долг» без влияния на демонстрацию |

| Статус | Значение |
|---|---|
| `Обход` | Есть рабочее решение, применяется в проекте |
| `Принято` | Осознанно оставлено как есть для учебного стенда |
| `TODO` | Не реализовано, план есть |

---

## 2. Сводная таблица

| ID | Ограничение | Критичность | Статус |
|---|---|---|---|
| [L-01](#l-01-внешний-доступ-из-интернета-не-работает) | Внешний доступ из интернета не работает (DPI) | 🔴 | Обход |
| [L-02](#l-02-telegram-алерты-не-доставляются) | Telegram-алерты не доставляются | 🟠 | Обход |
| [L-03](#l-03-external-dns-в-crashloopbackoff) | external-dns в `CrashLoopBackOff`, `replicas=0` | 🟠 | Обход |
| [L-04](#l-04-доступ-к-gitlabharbor-из-wsl2-только-через-ssh--l) | GitLab/Harbor из WSL2 — только через `ssh -L` | 🟠 | Обход |
| [L-05](#l-05-tls--lets-encrypt-staging) | TLS — Let's Encrypt **staging** | 🟠 | Принято |
| [L-06](#l-06-gitlab-отдаёт-self-signed-сертификат) | GitLab отдаёт self-signed сертификат | 🟠 | Обход |
| [L-07](#l-07-vault-в-dev-режиме) | Vault в dev-режиме, данные в памяти | 🔴 | Принято |
| [L-08](#l-08-пароли-в-values-файлах-открытым-текстом) | Пароли в values открытым текстом | 🔴 | Принято |
| [L-09](#l-09-двойной-префикс-kv-в-externalsecret) | Двойной префикс `kv/` в двух ExternalSecret | 🟠 | TODO |
| [L-10](#l-10-часть-манифестов-вне-gitops) | Часть манифестов вне GitOps | 🟠 | TODO |
| [L-11](#l-11-пароль-harbor-в-gitlab-ciyml) | Пароль Harbor в `.gitlab-ci.yml` | 🔴 | Принято |
| [L-12](#l-12-bump-тега-не-автоматизирован) | Bump тега не автоматизирован | 🟠 | TODO |
| [L-13](#l-13-два-алерта-online-boutique-не-могут-сработать) | 2 из 4 алертов OB не могут сработать | 🟠 | TODO |
| [L-14](#l-14-панели-slo-дашборда-могут-быть-пустыми) | Панели SLO-дашборда могут быть пустыми | 🟡 | TODO |
| [L-15](#l-15-алерт-certificateexpiringsoon-не-может-сработать) | `CertificateExpiringSoon` не может сработать | 🟡 | TODO |
| [L-16](#l-16-нет-бэкапов) | Нет резервного копирования | 🔴 | TODO |
| [L-17](#l-17-все-компоненты-в-одной-реплике) | Все компоненты в одной реплике | 🟠 | Принято |
| [L-18](#l-18-longhorn-1-orphan-volume) | Longhorn: 1 orphan volume | 🟡 | TODO |
| [L-19](#l-19-minio-из-bitnamilegacy) | MinIO из `bitnamilegacy` | 🟠 | Обход |
| [L-20](#l-20-нет-шифрования-secret-at-rest) | Нет шифрования Secret at-rest | 🟠 | TODO |
| [L-21](#l-21-нет-networkpolicies) | Нет NetworkPolicies | 🟠 | TODO |
| [L-22](#l-22-нет-подписи-образов) | Нет подписи образов | 🟡 | TODO |
| [L-23](#l-23-нет-тестов-в-пайплайне) | В пайплайне нет тестов | 🟠 | TODO |
| [L-24](#l-24-нет-аудита-vault) | Нет audit log Vault | 🟡 | TODO |
| [L-25](#l-25-нет-ресурсных-квот-и-hpa) | Нет ResourceQuota, LimitRange, HPA | 🟡 | TODO |
| [L-26](#l-26-короткое-хранение-метрик-логов-трейсов) | Короткое хранение метрик/логов/трейсов | 🟡 | Принято |
| [L-27](#l-27-нет-политик-retention-в-harbor) | Нет retention-политик в Harbor | 🟡 | TODO |
| [L-28](#l-28-нет-проверки-соответствия-манифестов-политикам) | Нет policy-as-code (Kyverno/OPA) | 🟡 | TODO |

---

## 3. Внешний доступ и сеть

### L-01. Внешний доступ из интернета не работает

**Критичность:** 🔴 высокая · **Статус:** обход

**Симптом**

Ни один сервис платформы недоступен из интернета. `https://shop.platform-mvp-potapov.ru`
открывается только из локальной сети `192.168.190.0/24`.

**Причина**

Кластер находится в NAT-сети VMware Workstation Pro за домашним роутером.
Публичного IP нет. Все попытки «пробить» туннель наружу упираются в
DPI-фильтрацию российских провайдеров:

| Решение | Что произошло |
|---|---|
| **Cloudflare Tunnel** (`cloudflared`) | TCP 443 → `alert 40` (TLS handshake reset), QUIC 7844 → timeout |
| **ngrok** | Домен `*.ngrok-free.app` блокируется на уровне DNS/SNI |
| **Tailscale Funnel** | Control plane `controlplane.tailscale.com` недоступен |
| **VK Tunnel** | Сервис в техработах на момент проверки |
| **Проброс портов на роутере** | Нет публичного IP (CGNAT провайдера) |

**Обход (применяется)**

Демонстрация через screen share (Zoom/Teams) или запись видео. Все проверки
выполняются изнутри сети

**План устранения**

1. Арендовать VPS с публичным IP, поднять там `cloudflared`/`frp`-сервер.
2. Использовать WireGuard-туннель между VPS и кластером.
3. Как вариант — перенести стенд в облако (Yandex Cloud / Selectel).

---

### L-02. Telegram-алерты не доставляются

**Критичность:** 🟠 средняя · **Статус:** обход

**Симптом**

Alertmanager формирует уведомления, но в Telegram они не приходят. В логах:

```bash
kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 --tail=20
# level=warn msg="Notify for alerts failed" receiver=telegram
# err="Post \"https://api.telegram.org/bot<TOKEN>/sendMessage\": dial tcp ...: i/o timeout"
```

**Причина**

`api.telegram.org` блокируется из РФ. Конфигурация при этом полностью
корректна: маршрут, receiver, `bot_token_file`, `chat_id`, `parse_mode: HTML`,
`send_resolved: true`.

**Обход (применяется)**

1. Проверка конфигурации без реальной доставки — через Alertmanager UI
   (`https://alertmanager.platform-mvp-potapov.ru`) и `amtool`:

```bash
kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-alertmanager-0 \
  -- amtool alert query --alertmanager.url=http://localhost:9093
```

2. Скриншот сработавшего алерта в UI — как доказательство работоспособности
   цепочки «Prometheus → Alertmanager».

**План устранения**

- Проксировать запросы Alertmanager через HTTP-прокси с доступом к Telegram
  (`http_config.proxy_url` в `receivers.telegram_configs`).
- Либо заменить receiver на `webhook` → собственный relay на VPS.

Детали конфигурации — [monitoring.md §4](monitoring.md).

---

### L-03. external-dns в `CrashLoopBackOff`

**Критичность:** 🟠 средняя · **Статус:** обход

**Симптом**

```bash
kubectl -n external-dns get pods
# NAME                          READY   STATUS             RESTARTS
# external-dns-7d9f8c6b4-x2vql  0/1     CrashLoopBackOff   47
```

**Причина**

external-dns обращается к `api.cloudflare.com` для управления DNS-записями.
TLS handshake обрывается DPI. Конфигурация в
[`k8s/values/external-dns.yaml`](../k8s/values/external-dns.yaml) корректна:

```yaml
provider: {name: cloudflare}
domainFilters: [platform-mvp-potapov.ru]
policy: sync
txtOwnerId: platform-mvp
txtPrefix: "_externaldns."
sources: [ingress, service]
```

**Обход (применяется)**

Deployment масштабирован в ноль, DNS-записи создаются вручную в панели
Cloudflare:

```bash
kubectl -n external-dns scale deploy external-dns --replicas=0
```

Записи, которые нужно создать вручную (все — `A` на `192.168.190.153`):

| Хост | Назначение |
|---|---|
| `vault.platform-mvp-potapov.ru` | Vault UI |
| `harbor.platform-mvp-potapov.ru` | Harbor |
| `longhorn.platform-mvp-potapov.ru` | Longhorn UI |
| `grafana.platform-mvp-potapov.ru` | Grafana |
| `prometheus.platform-mvp-potapov.ru` | Prometheus |
| `alertmanager.platform-mvp-potapov.ru` | Alertmanager |
| `gitlab.platform-mvp-potapov.ru` | GitLab |
| `registry.gitlab.platform-mvp-potapov.ru` | GitLab Registry |
| `minio.gitlab.platform-mvp-potapov.ru` | MinIO (object storage) |
| `shop.platform-mvp-potapov.ru` | Online Boutique |

**План устранения**

- Запустить external-dns на VPS с доступом к Cloudflare API и синхронизировать
  записи оттуда.
- Либо перейти на DNS-провайдера без блокировок.

---

### L-04. Доступ к GitLab/Harbor из WSL2 только через `ssh -L`

**Критичность:** 🟠 средняя · **Статус:** обход

**Симптом**

```bash
# Из WSL2
curl -k https://gitlab.platform-mvp-potapov.ru
# curl: (7) Failed to connect to gitlab.platform-mvp-potapov.ru port 443
```

**Причина**

WSL2 работает в отдельной виртуальной сети Hyper-V и не видит
`192.168.190.0/24` (эта сеть — VMware NAT, доступна только Windows-хосту).
Дополнительно ingress-nginx использует NodePort `30443`, а TLS SNI требует
правильного `Host`-заголовка.

**Обход (применяется)**

SSH-туннель на хост:

```bash
ssh -L 8443:192.168.190.153:30443 devops@192.168.190.153
```

Затем в WSL2:

```bash
# Вариант 1 — /etc/hosts
echo "127.0.0.1 gitlab.platform-mvp-potapov.ru" | sudo tee -a /etc/hosts
curl -k https://gitlab.platform-mvp-potapov.ru:8443/users/sign_in

# Вариант 2 — --resolve
curl -k --resolve gitlab.platform-mvp-potapov.ru:8443:127.0.0.1 \
  https://gitlab.platform-mvp-potapov.ru:8443/users/sign_in
```

То же для Harbor (`:8443` → `harbor.platform-mvp-potapov.ru`).

**План устранения**

- Перевести WSL2 в режим `mirrored` networking (Windows 11 22H2+):
  `networkingMode=mirrored` в `.wslconfig`.
- Либо добавить статический маршрут в WSL2 на `192.168.190.0/24`.

---

## 4. TLS и сертификаты

### L-05. TLS — Let's Encrypt staging

**Критичность:** 🟠 средняя · **Статус:** принято

**Симптом**

Браузер показывает `NET::ERR_CERT_AUTHORITY_INVALID` на всех хостах.
`curl` без `-k` падает с `SSL certificate problem: unable to get local issuer certificate`.

**Причина**

Все `Certificate` и аннотации ingress ссылаются на `ClusterIssuer`
`letsencrypt-staging`. Это осознанный выбор: staging не имеет жёстких rate
limits (prod — 5 дублей в неделю, 50 сертификатов на домен), что критично при
отладке DNS-01.

Затронутые ресурсы:

| Ресурс | Secret | Issuer |
|---|---|---|
| `harbor-tls` | `harbor-tls` | `letsencrypt-staging` |
| `gitlab-tls` | `gitlab-tls` | `letsencrypt-staging` |
| `grafana-tls` | `grafana-tls` | `letsencrypt-staging` |
| `prometheus-tls` | `prometheus-tls` | `letsencrypt-staging` |
| `alertmanager-tls` | `alertmanager-tls` | `letsencrypt-staging` |
| `vault-tls` | `vault-tls` | `letsencrypt-staging` |
| `longhorn-tls` | `longhorn-tls` | `letsencrypt-staging` |
| `shop-tls` | `shop-tls` | `letsencrypt-staging` |

**Обход (применяется)**

- В браузере — «Дополнительно → Перейти на сайт».
- В `curl` — флаг `-k`.
- В `docker`/`podman` — CA в trust store или `--tls-verify=false`.

**План устранения**

Заменить `letsencrypt-staging` → `letsencrypt-prod` в 7 файлах
`k8s/manifests/certs/*.yaml` и в аннотациях ingress в values-файлах:

```bash
grep -rl "letsencrypt-staging" k8s/ | tee /tmp/staging-files.txt
# затем заменить и дождаться перевыпуска
kubectl get certificate -A -w
```

`ClusterIssuer` `letsencrypt-prod` уже существует и находится в состоянии
`Ready=True` — переключение не требует установки дополнительных компонентов.

---

### L-06. GitLab отдаёт self-signed сертификат

**Критичность:** 🟠 средняя · **Статус:** обход

**Симптом**

```bash
kubectl -n gitlab logs deploy/gitlab-runner --tail=30
# ERROR: Registering runner... failed
# x509: certificate signed by unknown authority
```

**Причина**

В [`k8s/values/gitlab.yaml`](../k8s/values/gitlab.yaml) стоит
`global.ingress.configureCertmanager: false`, поэтому чарт GitLab генерирует
собственный self-signed сертификат `gitlab-wildcard-tls` и использует его
внутри кластера. При этом на ingress висит аннотация
`cert-manager.io/cluster-issuer: letsencrypt-staging` — снаружи отдаётся
staging-сертификат, а webservice внутри кластера — self-signed. Два разных
сертификата на одном хосте.

**Обход (применяется)**

Собран кастомный образ Runner с CA внутри:

```dockerfile
FROM gitlab/gitlab-runner:v19.5.1
USER root
COPY gitlab-ca.crt /usr/local/share/ca-certificates/gitlab-ca.crt
RUN update-ca-certificates
USER gitlab-runner
```

Образ лежит в Harbor:
`harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5`.
В values Runner указан `certsSecretName: gitlab-runner-ca` и
`tls_verify = false`.

**План устранения**

1. Выставить `global.ingress.configureCertmanager: true` и
   `certmanager.install: false` (cert-manager уже есть в кластере).
2. Убрать `tls_verify = false` из конфигурации Runner.
3. Вернуться на upstream-образ `gitlab/gitlab-runner`.

Детали — [ci-cd.md §3](ci-cd.md).

---

## 5. Секреты и безопасность

### L-07. Vault в dev-режиме

**Критичность:** 🔴 высокая · **Статус:** принято

**Симптом**

После рестарта пода `vault-0` все секреты в `kv/platform/*` исчезают.
ExternalSecret переходят в `SecretSyncedError`.

**Причина**

```yaml
# k8s/values/vault.yaml
server:
  dev:
    enabled: true
    devRootToken: "<см. Vault kv/platform/vault → root-token>"
standalone:
  enabled: false
dataStorage:
  enabled: false
auditStorage:
  enabled: false
```

Dev-режим Vault:

| Свойство | Следствие |
|---|---|
| Хранилище in-memory | Данные теряются при рестарте |
| Автоматический unseal | Нет процедуры распечатки |
| Root token задан заранее | Полный доступ у всех, кто знает токен |
| TLS отключён (`global.tlsDisable: true`) | Трафик ESO → Vault по HTTP |
| Audit log только в stdout | Нет истории доступа на диске |
| `injector.enabled: false`, `csi.enabled: false` | Нет sidecar-инъекции и CSI-провайдера |

**Обход (применяется)**

После каждого рестарта Vault секреты пересоздаются вручную:

```bash
kubectl -n vault exec -it vault-0 -- \
  env VAULT_TOKEN=<ROOT_TOKEN> vault kv put kv/platform/cloudflare api-token="<CF_TOKEN>"
# и так для telegram, gitlab, harbor
```

**План устранения**

Пошаговый план миграции на production-режим — в
[security.md §2.4](security.md): persistent storage, Shamir или auto-unseal,
TLS, Kubernetes auth, политика только на чтение `kv/data/platform/*`,
audit device на PVC.

---

### L-08. Пароли в values-файлах открытым текстом

**Критичность:** 🔴 высокая · **Статус:** принято

**Симптом**

В Git-репозитории присутствуют значения паролей в открытом виде.

**Причина**

Учебное упрощение: быстрее отладить, чем настраивать ESO для каждого
компонента. Затронутые места:

| Файл | Параметр | Правильный источник |
|---|---|---|
| [`k8s/values/harbor.yaml`](../k8s/values/harbor.yaml) | `harborAdminPassword` | `existingSecretAdminPassword` + ESO |
| [`k8s/values/kube-prometheus-stack.yaml`](../k8s/values/kube-prometheus-stack.yaml) | `grafana.adminPassword` | `grafana.admin.existingSecret` + ESO |
| [`k8s/values/vault.yaml`](../k8s/values/vault.yaml) | `server.dev.devRootToken` | Не хранить в Git вообще |
| [`k8s/values/gitlab.yaml`](../k8s/values/gitlab.yaml) | `global.minio` (пароль MinIO) | `global.minio.existingSecret` |
| [`k8s/apps/online-boutique/.gitlab-ci.yml`](../k8s/apps/online-boutique/.gitlab-ci.yml) | `admin:<PASSWORD>` в `config.json` | CI-переменные `HARBOR_USER`/`HARBOR_PASSWORD` |

**Обход (применяется)**

Документация не воспроизводит эти значения: везде указано
«см. Vault `kv/platform/<path>`» или «см. Secret `<name>`».

**План устранения**

1. Вынести все значения в Vault (`kv/platform/harbor`, `kv/platform/grafana`,
   `kv/platform/vault`, `kv/platform/minio`).
2. Создать ExternalSecret для каждого.
3. Переключить чарты на `existingSecret`.
4. Очистить историю Git (`git filter-repo`) — значения уже скомпрометированы.

---

### L-09. Двойной префикс `kv/` в ExternalSecret

**Критичность:** 🟠 средняя · **Статус:** TODO

**Симптом**

```bash
kubectl -n gitlab get externalsecret
# NAME                 STATUS              READY
# gitlab-root-password SecretSyncedError   False
# harbor-credentials   SecretSyncedError   False
```

В описании: `error processing spec.data[0] ... 404 Not Found`.

**Причина**

`ClusterSecretStore` уже содержит `path: kv`:

```yaml
spec:
  provider:
    vault:
      server: http://vault.vault.svc:8200
      path: kv          # ← имя KV-движка
      version: v2
```

ESO сам добавляет `kv/data/` к `remoteRef.key`. Но в двух файлах ключ указан
с префиксом:

| Файл | `remoteRef.key` | Итоговый путь | Корректно |
|---|---|---|---|
| [`gitlab-root.yaml`](../k8s/manifests/external-secrets/gitlab-root.yaml) | `kv/platform/gitlab` | `kv/data/kv/platform/gitlab` | ❌ |
| [`harbor-credentials.yaml`](../k8s/manifests/external-secrets/harbor-credentials.yaml) | `kv/platform/harbor` | `kv/data/kv/platform/harbor` | ❌ |

Остальные три ExternalSecret используют ключи без префикса
(`platform/cloudflare`, `platform/telegram`) и работают.

**Обход (применяется)**

Либо создаётся «вложенный» путь в Vault, либо Secret создаётся вручную.

**План устранения**

Убрать `kv/` из `remoteRef.key` в двух файлах:

```yaml
# было
remoteRef: {key: kv/platform/gitlab, property: root-password}
# стало
remoteRef: {key: platform/gitlab, property: root-password}
```

Затем:

```bash
kubectl -n gitlab delete externalsecret gitlab-root-password harbor-credentials
kubectl apply -f k8s/manifests/external-secrets/
kubectl -n gitlab get externalsecret
```

Детали — [security.md §4](security.md).

---

### L-20. Нет шифрования Secret at-rest

**Критичность:** 🟠 средняя · **Статус:** TODO

**Симптом**

```bash
kubectl -n online-boutique get secret harbor-creds -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
# {"auths":{"harbor.platform-mvp-potapov.ru":{"auth":"YWRtaW46..."}}}
```

Значение читается в открытом виде любым, у кого есть `get secret`.

**Причина**

В `kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml` не настроен
`EncryptionConfiguration` для etcd. base64 — это кодирование, не шифрование.

**План устранения**

1. Сгенерировать ключ шифрования (`head -c 32 /dev/urandom | base64`).
2. Добавить `EncryptionConfiguration` с провайдером `aescbc` или `secretbox`.
3. Прописать `--encryption-provider-config` в kube-apiserver через Kubespray.
4. Перешифровать существующие секреты:
   `kubectl get secrets -A -o json | kubectl replace -f -`.

---

### L-21. Нет NetworkPolicies

**Критичность:** 🟠 средняя · **Статус:** TODO

**Симптом**

Любой под в любом namespace может обратиться к любому другому поду и к
kube-apiserver. Плоская сеть.

**Причина**

NetworkPolicies не описаны. Cilium поддерживает их, но политики не созданы
(кроме тех, что генерируют сами чарты — например, Longhorn).

**План устранения**

1. Включить default-deny в каждом namespace:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: {name: default-deny, namespace: online-boutique}
   spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
   ```
2. Разрешить явные потоки: `ingress-nginx → frontend`, `frontend → *`,
   `* → otel-collector`, `promtail → loki`, `eso → vault`.
3. Использовать Cilium Network Policies для L7-правил (HTTP/gRPC).

---

### L-22. Нет подписи образов

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

Кластер запустит любой образ из Harbor, даже подменённый.

**Причина**

cosign/Notary не настроены, admission-контроллер проверки подписи
отсутствует.

**План устранения**

1. Подписывать образы в CI: `cosign sign --key ... $IMAGE`.
2. Установить Kyverno с политикой `verifyImages`.
3. Запретить pull неподписанных образов в namespace `online-boutique`.

---

### L-24. Нет аудита Vault

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

Нет истории «кто и когда читал секрет».

**Причина**

```yaml
# k8s/values/vault.yaml
auditStorage:
  enabled: false
server:
  extraEnvironmentVars:
    VAULT_AUDIT_LOG_DEVICE: stdout
```

Аудит пишется только в stdout пода и теряется при рестарте.

**План устранения**

Включить `auditStorage.enabled: true` (PVC на Longhorn) и
`server.auditConfig` с `file`-device на этот том.

---

## 6. GitOps и ArgoCD

### L-10. Часть манифестов вне GitOps

**Критичность:** 🟠 средняя · **Статус:** TODO

**Симптом**

Ресурсы существуют в кластере, но не управляются ArgoCD: при удалении
кластера они не восстановятся автоматически.

**Причина**

Не все каталоги `k8s/manifests/` подключены к Application:

| Путь | Управляется ArgoCD | Комментарий |
|---|---|---|
| `k8s/manifests/namespaces.yaml` | ✅ | Application `namespaces` |
| `k8s/manifests/clusterissuer-*.yaml` | ✅ | Application `clusterissuers` |
| `k8s/manifests/certs/` | ✅ | Application `platform-certs` |
| `k8s/manifests/alerts/` | ✅ | Application `platform-alerts` |
| `k8s/manifests/external-secrets/` (частично) | ⚠️ | Только `gitlab-root.yaml` и `harbor-credentials.yaml` через `include` |
| `k8s/manifests/external-secrets/cloudflare-*.yaml`, `telegram-alertmanager.yaml` | ❌ | Применяются вручную |
| `k8s/manifests/vault-cluster-secret-store.yaml` | ❌ | Применяется вручную |
| `k8s/manifests/dashboards/` | ❌ | Применяется вручную |
| `k8s/manifests/minio/minio.yaml` | ❌ | Применяется вручную |

**Обход (применяется)**

Ручное применение:

```bash
kubectl apply -f k8s/manifests/vault-cluster-secret-store.yaml
kubectl apply -f k8s/manifests/dashboards/
kubectl apply -f k8s/manifests/external-secrets/cloudflare-api-token-certmanager.yaml
kubectl apply -f k8s/manifests/external-secrets/cloudflare-api-token-externaldns.yaml
kubectl apply -f k8s/manifests/external-secrets/telegram-alertmanager.yaml
```

**План устранения**

1. Расширить `include` в Application `gitlab-external-secrets` или создать
   отдельный Application `platform-external-secrets` с `directory.recurse: true`.
2. Создать Application `platform-dashboards` (path `k8s/manifests/dashboards`).
3. Добавить `vault-cluster-secret-store.yaml` в Application `external-secrets`
   или в отдельный `platform-secrets-store`.

---

### L-13. Два алерта Online Boutique не могут сработать

**Критичность:** 🟠 средняя · **Статус:** TODO

**Симптом**

`OBHighErrorRate` и `OBHighLatency` всегда в состоянии `inactive`, даже при
генерации 5xx и росте latency.

**Причина**

Оба алерта построены на метриках ingress-nginx:

```promql
sum(rate(nginx_ingress_controller_requests{namespace="online-boutique",status=~"5.."}[5m]))
  / sum(rate(nginx_ingress_controller_requests{namespace="online-boutique"}[5m])) > 0.05
```

Но в [`k8s/values/ingress-nginx.yaml`](../k8s/values/ingress-nginx.yaml):

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false      # ← Prometheus не скрапит ingress-nginx
```

Prometheus Operator не видит ServiceMonitor, метрики
`nginx_ingress_controller_*` отсутствуют, выражения возвращают пустой вектор,
алерт не срабатывает.

При этом `OBServiceDown` и `OBPodCrashLooping` работают — они на
`kube_*`-метриках от kube-state-metrics.

**Обход (применяется)**

Фактический контроль доступности — через `OBServiceDown` и
`OBPodCrashLooping`, а также через панели Grafana.

**План устранения**

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

Затем:

```bash
kubectl -n ingress-nginx get servicemonitor
# Проверить в Prometheus: up{job="ingress-nginx-controller"}
```

Альтернатива — переписать алерты на OTel-метрики приложения
(`rpc_server_duration_milliseconds_bucket`), которые уже собираются через
OTel Collector.

---

### L-15. Алерт `CertificateExpiringSoon` не может сработать

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

Алерт `CertificateExpiringSoon` всегда `inactive`.

**Причина**

Выражение использует `certmanager_certificate_expiration_timestamp_seconds`,
но в [`k8s/values/cert-manager.yaml`](../k8s/values/cert-manager.yaml):

```yaml
prometheus:
  enabled: true
  servicemonitor:
    enabled: false     # ← метрики cert-manager не собираются
```

**План устранения**

```yaml
prometheus:
  enabled: true
  servicemonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
```

Проверка: `up{job="cert-manager"}` в Prometheus.

---

## 7. CI/CD

### L-11. Пароль Harbor в `.gitlab-ci.yml`

**Критичность:** 🔴 высокая · **Статус:** принято

**Симптом**

В файле [`k8s/apps/online-boutique/.gitlab-ci.yml`](../k8s/apps/online-boutique/.gitlab-ci.yml)
аутентификация Harbor выполняется строкой с логином и паролем в открытом виде:

```yaml
- |
  cat > /kaniko/.docker/config.json <<EOF
  {"auths":{"harbor.platform-mvp-potapov.ru":{"auth":"$(printf 'admin:<PASSWORD>' | base64)"}}}
  EOF
```

**Причина**

Историческая реализация: сначала пайплайн отлаживался с фиксированными
значениями, потом CI-переменные `HARBOR_USER`/`HARBOR_PASSWORD` были созданы,
но в скрипте так и не использованы.

**Обход (применяется)**

Ничего: пароль уже в истории Git. Документация его не воспроизводит.

**План устранения**

```yaml
- |
  cat > /kaniko/.docker/config.json <<EOF
  {"auths":{"harbor.platform-mvp-potapov.ru":{"auth":"$(printf '%s:%s' "$HARBOR_USER" "$HARBOR_PASSWORD" | base64)"}}}
  EOF
```

Плюс:

1. Создать в Harbor robot-аккаунт с правами push только в `online-boutique`.
2. Записать его креды в GitLab CI/CD Variables (masked, protected).
3. Ротировать пароль `admin` и очистить историю Git.

Детали — [ci-cd.md §5](ci-cd.md).

---

### L-12. Bump тега не автоматизирован

**Критичность:** 🟠 средняя · **Статус:** TODO

**Симптом**

После успешной сборки в Harbor лежат образы с тегом `$CI_COMMIT_SHORT_SHA`,
но кластер продолжает работать на `v1.0.0`/`v1.0.4`. Деплой не происходит.

**Причина**

Пайплайн состоит из одной стадии `build`. Job'а, которая обновляет `image:`
в манифестах и коммитит в репозиторий платформы, нет. Bump выполняется
вручную.

**Обход (применяется)**

```bash
# Обновить тег в манифесте
sed -i 's|frontend:v1.0.0|frontend:'"$NEW_TAG"'|' k8s/apps/online-boutique/frontend.yaml

# Закоммитить
git add k8s/apps/online-boutique/frontend.yaml
git commit -m "chore(ob): bump frontend to $NEW_TAG"
git push

# ArgoCD подхватит автоматически (selfHeal: true)
kubectl -n argocd get application online-boutique -o jsonpath='{.status.sync.status}'
```

**План устранения**

Добавить стадию `bump` с `kustomize edit set image` или `yq`, и push через
deploy key / project access token:

```yaml
stages: [build, bump]

bump:
  stage: bump
  image: alpine/git:2.45.2
  needs: [frontend, cartservice]   # и остальные
  script:
    - apk add --no-cache yq
    - |
      for svc in frontend cartservice productcatalogservice currencyservice \
                 paymentservice shippingservice emailservice checkoutservice \
                 recommendationservice adservice loadgenerator; do
        yq -i ".spec.template.spec.containers[0].image = \"$HARBOR/$svc:$TAG\"" \
          k8s/apps/online-boutique/$svc.yaml
      done
    - git config user.email "ci@platform-mvp"
    - git config user.name "GitLab CI"
    - git commit -am "chore(ob): bump images to $TAG"
    - git push "https://oauth2:${PLATFORM_REPO_TOKEN}@gitlab.platform-mvp-potapov.ru/root/platform-mvp.git" HEAD:master
  rules:
    - if: $CI_COMMIT_BRANCH == "master"
```

---

### L-23. В пайплайне нет тестов

**Критичность:** 🟠 средняя · **Статус:** TODO

**Симптом**

Пайплайн зелёный, даже если образ неработоспособен (например, `ENTRYPOINT`
указывает на каталог — как было с `checkoutservice`).

**Причина**

Единственная стадия — `build`. Нет `test`, `lint`, `scan`, `deploy`.

**План устранения**

1. Стадия `test`: `go test ./...`, `npm test`, `pytest` по языкам сервисов.
2. Стадия `scan`: `trivy image --exit-code 1 --severity HIGH,CRITICAL`.
3. Стадия `smoke`: `kubectl run` + `curl /_healthz` после деплоя.
4. `needs`-граф, чтобы тесты шли параллельно сборке.

---

## 8. Наблюдаемость

### L-14. Панели SLO-дашборда могут быть пустыми

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

На дашборде `Online Boutique SLO` часть панелей показывает `No data`.

**Причина**

Запросы в
[`k8s/manifests/dashboards/online-boutique-slo.yaml`](../k8s/manifests/dashboards/online-boutique-slo.yaml)
используют метрики gRPC-сервера в нотации Prometheus-клиента:

```promql
sum by (service_name) (rate(grpc_server_handled_total{namespace="online-boutique"}[1m]))
```

Но приложение инструментировано OpenTelemetry SDK и отдаёт метрики в нотации
OTel (`rpc_server_duration_milliseconds_bucket`,
`rpc_server_duration_milliseconds_count`), которые OTel Collector
экспортирует в Prometheus через `resource_to_telemetry_conversion: true`.
Метрик `grpc_server_*` в системе нет.

**Обход (применяется)**

Рабочие панели: `Pods Running`, `Requests total` (по ingress-метрикам — тоже
не работают, см. L-13). Фактически надёжны только панели на `kube_*`.

**План устранения**

Переписать запросы на OTel-метрики:

```promql
# RPS по сервисам
sum by (service_name) (rate(rpc_server_duration_milliseconds_count{namespace="online-boutique"}[1m]))

# p95 latency
histogram_quantile(0.95,
  sum by (le, service_name) (rate(rpc_server_duration_milliseconds_bucket{namespace="online-boutique"}[5m])))

# Error rate
sum by (service_name) (rate(rpc_server_duration_milliseconds_count{namespace="online-boutique",rpc_grpc_status_code!="0"}[5m]))
  / sum by (service_name) (rate(rpc_server_duration_milliseconds_count{namespace="online-boutique"}[5m]))
```

Проверить фактические имена метрик:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# затем в UI: {__name__=~"rpc_server.*"}
```

---

### L-26. Короткое хранение метрик, логов, трейсов

**Критичность:** 🟡 низкая · **Статус:** принято

**Симптом**

Данные старше нескольких дней недоступны.

**Причина**

Ограничения ресурсов учебного стенда:

| Компонент | Параметр | Значение |
|---|---|---|
| Prometheus | `retention` | `5d` |
| Prometheus | `retentionSize` | `4GB` |
| Prometheus | PVC | `10Gi` |
| Loki | `retention_period` | `168h` (7 дней) |
| Loki | PVC | `20Gi` |
| Tempo | `retention` | `48h` |
| Tempo | PVC | `20Gi` |

**План устранения**

- Prometheus: `retention: 30d`, `retentionSize: 50GB`, PVC `100Gi`.
- Loki: перейти с `filesystem` на object storage (MinIO/S3), retention `720h`.
- Tempo: object storage + retention `168h`.
- Обязательное условие — увеличить диски worker-нод.

---

## 9. Хранилище и отказоустойчивость

### L-16. Нет резервного копирования

**Критичность:** 🔴 высокая · **Статус:** TODO

**Симптом**

Потеря ноды или PVC означает безвозвратную потерю данных: GitLab-репозитории,
образы Harbor, метрики, секреты Vault.

**Причина**

```yaml
# k8s/values/longhorn.yaml
defaultSettings:
  backupTarget: ""                    # ← бэкапы не настроены
  backupTargetCredentialSecret: ""
```

Velero не установлен. Snapshot-класс Longhorn не создан.

**План устранения**

1. Настроить `backupTarget` на S3/MinIO:
   ```yaml
   defaultSettings:
     backupTarget: "s3://longhorn-backup@ru-central1/"
     backupTargetCredentialSecret: longhorn-backup-secret
   ```
2. Создать `RecurringJob` для ежедневных снапшотов критичных PVC
   (`harbor-registry`, `database-data-harbor-database-0`, `data-gitlab-gitaly-0`).
3. Установить Velero для бэкапа манифестов и PV.
4. Проверить восстановление на тестовом namespace.

---

### L-17. Все компоненты в одной реплике

**Критичность:** 🟠 средняя · **Статус:** принято

**Симптом**

Падение ноды с подом Prometheus/Alertmanager/Grafana/Vault/Harbor/GitLab
приводит к недоступности компонента до пересоздания пода.

**Причина**

Экономия ресурсов на 6 VM:

| Компонент | Реплики |
|---|---|
| Prometheus | 1 |
| Alertmanager | 1 |
| Grafana | 1 |
| Loki (SingleBinary) | 1 |
| Tempo | 1 |
| OTel Collector | 1 |
| Vault | 1 (dev) |
| Harbor core/registry/portal/jobservice | 1 |
| GitLab webservice | 1 |
| GitLab sidekiq | 1 |
| Gitaly | 1 |
| Online Boutique frontend | 2 |
| Остальные сервисы OB | 1 |

**План устранения**

- Prometheus/Alertmanager: `replicas: 2` + anti-affinity по нодам.
- Loki: перейти на `deploymentMode: SimpleScalable` (read/write/backend).
- GitLab: `webservice.replicas: 2`, `sidekiq.replicas: 2`.
- Добавить `PodDisruptionBudget` для критичных компонентов.

---

### L-18. Longhorn: 1 orphan volume

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

```bash
kubectl -n longhorn-system get volumes.longhorn.io
# NAME                                       STATE      ROBUSTNESS
# pvc-3f2a...                                detached   unknown
```

14 из 15 томов в `healthy`, один — `detached`/`unknown`.

**Причина**

Остаток от каскадного удаления Application через ArgoCD: `prune: true` +
`resources-finalizer.argocd.argoproj.io` удалили PVC, но Longhorn не успел
завершить cleanup, и том остался в `detached`.

**Обход (применяется)**

Не влияет на работу. Чистится вручную:

```bash
# Найти том
kubectl -n longhorn-system get volumes.longhorn.io | grep -v healthy

# Удалить
kubectl -n longhorn-system delete volumes.longhorn.io <volume-name>
```

**План устранения**

- Включить `orphan`-защиту: `defaultSettings.orphanResourceAutoDeletion: true`.
- Не удалять Application с `prune: true` без предварительного `--cascade=orphan`.

---

### L-19. MinIO из `bitnamilegacy`

**Критичность:** 🟠 средняя · **Статус:** обход

**Симптом**

```bash
kubectl -n gitlab get pods | grep -E "redis|postgresql"
# ImagePullBackOff
```

**Причина**

Bitnami в 2025 году убрал бесплатные образы из `docker.io/bitnami/*` и
перенёс их в `docker.io/bitnamilegacy/*` без гарантий поддержки. В
[`k8s/values/gitlab.yaml`](../k8s/values/gitlab.yaml) используются:

| Компонент | Образ |
|---|---|
| Redis | `bitnamilegacy/redis:7.2.4-debian-12-r9` |
| PostgreSQL | `bitnamilegacy/postgresql:14.8.0` |

**Обход (применяется)**

Образы зафиксированы на конкретных тегах из `bitnamilegacy`. Работает, но
обновлений безопасности не будет.

**План устранения**

1. Перейти на официальные образы: `redis:7.2-alpine`, `postgres:14-alpine`.
2. Либо использовать Bitnami Secure Images (платно).
3. Либо развернуть внешние managed-инстансы.

---

## 10. Приложение

### L-27. Нет retention-политик в Harbor

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

PVC `harbor-registry` (`20Gi`) постепенно заполняется. Каждый пайплайн
создаёт 11 новых тегов + перезаписывает `latest`.

**Причина**

Tag retention rules не настроены. `--destination ...:latest` в CI
перезаписывает тег, но старые SHA-теги остаются навсегда.

**План устранения**

1. В UI: Project `online-boutique` → Policy → Tag Retention:
   - keep the most recently pushed `10` artifacts;
   - keep artifacts pulled within the last `30` days.
2. Убрать `--destination "$HARBOR/$SVC:latest"` из пайплайна — immutable-теги
   надёжнее.
3. Настроить `harbor_project_quota_usage_byte` алерт в Prometheus.

---

## 11. Что сознательно не входит в scope

Эти пункты не являются «багами» — они вне учебного задания:

| Не реализовано | Почему |
|---|---|
| Service mesh (Istio/Linkerd) | Cilium + OTel покрывают наблюдаемость; mesh усложнил бы стенд |
| Multi-cluster / federation | Один кластер по заданию |
| HPA / VPA / Cluster Autoscaler | Нагрузка фиксированная (loadgenerator, 10 users) |
| GitOps для инфраструктуры (Terraform/Crossplane) | VM создаются вручную в VMware |
| Secrets Store CSI Driver | ESO достаточно; `csi.enabled: false` в Vault |
| Vault injector (sidecar) | Приложение читает env, не файлы |
| OPA Gatekeeper / Kyverno | См. L-28 |
| Chaos engineering | Вне задания |
| Multi-tenancy (vCluster, Capsule) | Один tenant |
| Disaster recovery runbook | См. L-16 |

### L-25. Нет ResourceQuota, LimitRange, HPA

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

Один namespace может занять все ресурсы кластера. Поды без `resources` не
ограничены.

**Причина**

`ResourceQuota` и `LimitRange` не созданы. HPA отсутствует — реплики
фиксированы в манифестах.

**План устранения**

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: {name: online-boutique-quota, namespace: online-boutique}
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "30"
```

Плюс `LimitRange` с `defaultRequest`/`defaultLimit` и HPA на `frontend` по
CPU 70%.

### L-28. Нет policy-as-code

**Критичность:** 🟡 низкая · **Статус:** TODO

**Симптом**

В кластер можно применить под с `privileged: true`, `hostPath`, `latest`-тегом
или без `resources`.

**Причина**

Kyverno/OPA Gatekeeper не установлены, Pod Security Standards не включены
(`pod-security.kubernetes.io/enforce` не выставлен на namespace).

**План устранения**

1. Включить PSS на namespace:
   ```bash
   kubectl label ns online-boutique \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/warn=restricted
   ```
2. Установить Kyverno с политиками: `disallow-latest-tag`,
   `require-resources`, `disallow-privileged`, `verify-images` (см. L-22).

---

## 12. План устранения по приоритетам

### Приоритет 1 — блокеры production (1–2 недели)

| ID | Задача | Трудоёмкость |
|---|---|---|
| L-07 | Vault: persistent + Shamir/auto-unseal + TLS | 2 дня |
| L-08 | Вынести все пароли в Vault + ESO | 2 дня |
| L-11 | Robot-аккаунт Harbor + CI-переменные | 4 часа |
| L-16 | Longhorn backupTarget + RecurringJob + Velero | 2 дня |
| L-01 | VPS + WireGuard/cloudflared для внешнего доступа | 1 день |

### Приоритет 2 — корректность (1 неделя)

| ID | Задача | Трудоёмкость |
|---|---|---|
| L-09 | Убрать `kv/` из двух ExternalSecret | 15 минут |
| L-10 | Все манифесты в GitOps | 4 часа |
| L-13 | Включить ServiceMonitor ingress-nginx | 30 минут |
| L-15 | Включить ServiceMonitor cert-manager | 30 минут |
| L-14 | Переписать SLO-запросы на OTel-метрики | 4 часа |
| L-12 | Автоматический bump тега | 1 день |
| L-23 | Стадии test/scan/smoke в пайплайне | 2 дня |

### Приоритет 3 — hardening (2–3 недели)

| ID | Задача | Трудоёмкость |
|---|---|---|
| L-20 | Шифрование Secret at-rest | 1 день |
| L-21 | NetworkPolicies (default-deny + allow) | 3 дня |
| L-22 | cosign + Kyverno verifyImages | 2 дня |
| L-28 | Kyverno-политики + PSS | 2 дня |
| L-17 | Реплики 2+ и PDB | 2 дня |
| L-25 | ResourceQuota, LimitRange, HPA | 1 день |
| L-24 | Vault audit на PVC | 4 часа |
| L-26 | Увеличить retention + object storage | 2 дня |
| L-27 | Harbor retention policy | 1 час |
| L-18 | Почистить orphan volume | 15 минут |
| L-19 | Заменить bitnamilegacy-образы | 1 день |
| L-05 | Переключить на `letsencrypt-prod` | 1 час |
| L-06 | GitLab: `configureCertmanager: true` | 4 часа |
| L-02 | Прокси для Telegram | 4 часа |
| L-03 | external-dns на VPS | 4 часа |
| L-04 | WSL2 mirrored networking | 30 минут |

---

## 13. Как проверить ограничения самостоятельно

```bash
# L-01: внешний доступ
curl -m 5 -k https://shop.platform-mvp-potapov.ru   # из внешней сети — timeout

# L-02: Telegram
kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 --tail=20 | grep -i telegram

# L-03: external-dns
kubectl -n external-dns get deploy external-dns -o jsonpath='{.spec.replicas}'; echo

# L-05: staging-сертификат
echo | openssl s_client -connect 192.168.190.153:30443 -servername shop.platform-mvp-potapov.ru 2>/dev/null \
  | openssl x509 -noout -issuer
# issuer=C=US, O=(STAGING) Let's Encrypt, CN=(STAGING) Pretend Pear X1

# L-07: Vault dev
kubectl -n vault get statefulset vault -o jsonpath='{.spec.template.spec.containers[0].args}'; echo

# L-09: ExternalSecret
kubectl -n gitlab get externalsecret

# L-10: что не в GitOps
kubectl get application -n argocd -o name | wc -l   # 20
ls k8s/manifests/dashboards/                        # не входит ни в один Application

# L-13: метрики ingress-nginx
kubectl -n ingress-nginx get servicemonitor 2>&1    # NotFound

# L-15: метрики cert-manager
kubectl -n cert-manager get servicemonitor 2>&1     # NotFound

# L-16: бэкапы
kubectl -n longhorn-system get setting backup-target -o jsonpath='{.value}'; echo   # пусто

# L-17: реплики
kubectl -n monitoring get deploy,statefulset -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas

# L-18: orphan volume
kubectl -n longhorn-system get volumes.longhorn.io | grep -v healthy

# L-19: bitnamilegacy
grep -rn "bitnamilegacy" k8s/values/

# L-20: Secret в base64
kubectl -n online-boutique get secret harbor-creds -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | head -c 60; echo

# L-21: NetworkPolicies
kubectl get networkpolicy -A

# L-26: retention
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.retention} {.spec.retentionSize}'; echo
```

---

## См. также

- [troubleshooting.md](troubleshooting.md) — симптом → причина → фикс по компонентам
- [security.md](security.md) — Vault, ESO, план миграции на production
- [monitoring.md](monitoring.md) — алерты, метрики, дашборды
- [ci-cd.md](ci-cd.md) — пайплайн, Runner, bump тега
- [registry.md](registry.md) — Harbor, Trivy, TLS
- [application.md](application.md) — Online Boutique, SLO
