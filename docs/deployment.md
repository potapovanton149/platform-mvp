# Развёртывание платформы с нуля

Пошаговая инструкция: от пустого VMware до работающей платформы с приложением.
Каждый шаг заканчивается проверкой — не переходите к следующему, пока проверка
не прошла.

- [0. Предварительные требования](#0-предварительные-требования)
- [Шаг 1. Создание 6 VM](#шаг-1-создание-6-vm)
- [Шаг 2. Подготовка ОС (Ansible)](#шаг-2-подготовка-ос-ansible)
- [Шаг 3. Установка Kubernetes (Kubespray)](#шаг-3-установка-kubernetes-kubespray)
- [Шаг 4. Post-Kubespray](#шаг-4-post-kubespray)
- [Шаг 5. Bootstrap ArgoCD](#шаг-5-bootstrap-argocd)
- [Шаг 6. ArgoCD раскатывает платформу](#шаг-6-argocd-раскатывает-платформу)
- [Шаг 7. Секреты](#шаг-7-секреты)
- [Шаг 8. GitLab и Runner](#шаг-8-gitlab-и-runner)
- [Шаг 9. Online Boutique](#шаг-9-online-boutique)
- [Шаг 10. Финальная проверка](#шаг-10-финальная-проверка)
- [Полный сброс](#полный-сброс)

---

## 0. Предварительные требования

### 0.1. Хост

| Ресурс | Требование |
|---|---|
| ОС | Windows 11 Home (Pro не обязателен) |
| CPU | ≥ 12 ядер (20 vCPU отдаётся VM) |
| RAM | ≥ 40 GB (36 GB отдаётся VM) |
| Диск | ≥ 500 GB SSD (420 GB отдаётся VM) |
| Виртуализация | VT-x/AMD-V включена в BIOS |

### 0.2. ПО на хосте

1. **VMware Workstation Pro 17.x** — установить, проверить, что виртуальные
   сети VMnet8 (NAT) созданы.
2. **WSL2 + Ubuntu 22.04**:

```bash
wsl --install -d Ubuntu-22.04
wsl --set-default-version 2
```

3. **Инструменты в WSL2**:

```bash
sudo apt update && sudo apt install -y \
  python3 python3-pip python3-venv sshpass git make jq curl unzip

pip3 install --user ansible ansible-lint
ansible-galaxy collection install kubernetes.core community.general

# kubectl
curl -LO "https://dl.k8s.io/release/v1.30.4/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

4. **SSH-ключ** (если ещё нет):

```bash
ssh-keygen -t ed25519 -C "platform-mvp" -f ~/.ssh/id_ed25519 -N ""
```

### 0.3. Внешние сервисы

| Сервис | Что нужно | Где используется |
|---|---|---|
| Cloudflare | Домен `platform-mvp-potapov.ru` в зоне, API Token с правами `Zone:DNS:Edit` + `Zone:Zone:Read` | cert-manager (DNS-01), external-dns |
| Telegram | Бот (`@BotFather`) + `chat_id` | Alertmanager |
| GitHub | Репозиторий `potapovanton149/platform-mvp`, ветка `master` | ArgoCD source |

### 0.4. Клонирование репозитория

```bash
git clone https://github.com/potapovanton149/platform-mvp.git
cd platform-mvp
git submodule update --init --recursive
```

Проверка:

```bash
ls kubespray/ | head -5
# CONTRIBUTING.md  LICENSE  README.md  ansible  cluster.yml ...
```

### 0.5. Kubespray venv

Kubespray требует собственный набор Python-зависимостей, который конфликтует с
системным Ansible. Создаём отдельное окружение:

```bash
python3 -m venv ~/.venv/kubespray
source ~/.venv/kubespray/bin/activate
pip install -U pip
pip install -r kubespray/requirements.txt
deactivate
```

Проверка:

```bash
~/.venv/kubespray/bin/ansible --version | head -1
# ansible [core 2.16.x]
```

> Путь `~/.venv/kubespray` захардкожен в
> [`scripts/02-run-kubespray.sh`](../scripts/02-run-kubespray.sh) как значение по
> умолчанию. Переопределяется переменной `KUBESPRAY_VENV`.

---

## Шаг 1. Создание 6 VM

### 1.1. Базовая VM

Создать в VMware Workstation Pro одну VM-шаблон:

| Параметр | Значение |
|---|---|
| ISO | `ubuntu-22.04.5-live-server-amd64.iso` |
| vCPU | 2 |
| RAM | 4 GB |
| Disk | 40 GB (SCSI, single file) |
| Network | Custom: VMnet8 (NAT) |
| Firmware | BIOS |

При установке Ubuntu:

- Hostname: `cp-1`
- Пользователь: `devops` (пароль запомнить)
- **Установить OpenSSH server** (обязательно)
- Дополнительных snap-пакетов не выбирать

### 1.2. Настройка сети внутри VM

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.190.101/24]
      routes:
        - to: default
          via: 192.168.190.2
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

```bash
sudo netplan apply
ip -4 addr show ens33
```

> Шлюз `192.168.190.2` — это VMware NAT gateway. Проверить в
> `Edit → Virtual Network Editor → VMnet8 → NAT Settings`.

### 1.3. SSH-доступ

С хоста (WSL2):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub devops@192.168.190.101
ssh devops@192.168.190.101 'echo OK'
```

### 1.4. Клонирование остальных 5 VM

В VMware: правый клик на `cp-1` → **Manage → Clone → Full Clone**.

Для каждого клона изменить hostname и IP:

| Клон | Hostname | IP | vCPU | RAM | Disk |
|---|---|---|---|---|---|
| cp-2 | cp-2 | 192.168.190.151 | 2 | 4 GB | 40 GB |
| cp-3 | cp-3 | 192.168.190.150 | 2 | 4 GB | 40 GB |
| worker-1 | worker-1 | 192.168.190.153 | 4 | 8 GB | 100 GB |
| worker-2 | worker-2 | 192.168.190.146 | 4 | 8 GB | 100 GB |
| worker-3 | worker-3 | 192.168.190.145 | 4 | 8 GB | 100 GB |

В каждой VM:

```bash
sudo hostnamectl set-hostname <hostname>
sudo nano /etc/netplan/00-installer-config.yaml   # поменять addresses
sudo netplan apply
sudo reboot
```

> **Важно:** после клонирования в `/etc/machine-id` остаётся одинаковый ID.
> Пересоздать:
> ```bash
> sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
> sudo systemd-machine-id-setup
> sudo reboot
> ```

### 1.5. Проверка

```bash
for ip in 101 151 150 153 146 145; do
  printf "192.168.190.%s: " "$ip"
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      devops@192.168.190.$ip 'hostname' || echo FAIL
done
```

Ожидается 6 строк с корректными hostname.

---

## Шаг 2. Подготовка ОС (Ansible)

### 2.1. Проверить inventory

[`ansible/inventory/prod.yml`](../ansible/inventory/prod.yml) должен содержать
актуальные IP. Если IP отличаются — поправить здесь и в
[`ansible/inventory/kubespray.yml`](../ansible/inventory/kubespray.yml)
(файлы должны быть идентичны).

### 2.2. Запуск

```bash
make prepare
```

Что делает роль `common`
([`ansible/roles/common/tasks/main.yml`](../ansible/roles/common/tasks/main.yml)):

| Задача | Детали |
|---|---|
| Timezone | `UTC` |
| Swap off | `swapoff -a` + комментарий в `/etc/fstab` |
| Модули ядра | `br_netfilter`, `overlay` → `/etc/modules-load.d/k8s.conf` |
| sysctl | `bridge-nf-call-iptables`, `ip_forward`, `inotify.max_user_watches=524288` |
| unattended-upgrades | Отключён (иначе ломает установку пакетов) |
| Ожидание dpkg-lock | До 120 с |
| Пакеты | `curl jq apt-transport-https ca-certificates gnupg lsb-release htop vim net-tools python3-pip chrony open-vm-tools python3-kubernetes` |
| chrony | Включён (критично для etcd и TLS) |
| ufw | Отключён |
| open-vm-tools | Включён |

### 2.3. Проверка

```bash
ansible -i ansible/inventory/prod.yml k8s_cluster -m shell \
  -a 'swapon --show; sysctl net.ipv4.ip_forward; systemctl is-active chrony' -b
```

Ожидается: пустой вывод `swapon`, `net.ipv4.ip_forward = 1`, `active` × 6.

---

## Шаг 3. Установка Kubernetes (Kubespray)

### 3.1. Проверить конфигурацию

[`kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml`](../kubespray-config/group_vars/k8s_cluster/k8s-cluster.yml):

```yaml
kube_version: v1.30.4
kube_network_plugin: cilium
kube_proxy_mode: ipvs
kube_proxy_remove: false
kube_vip_enabled: true
kube_vip_address: 192.168.190.100
kube_vip_interface: ens33
cilium_kube_proxy_replacement: false   # ← критично, см. troubleshooting
cilium_version: "v1.16.1"
```

[`kubespray-config/group_vars/k8s_cluster/addons.yml`](../kubespray-config/group_vars/k8s_cluster/addons.yml) —
все аддоны, которые ставит ArgoCD, отключены:

```yaml
metrics_server_enabled: false
ingress_nginx_enabled: false
cert_manager_enabled: false
helm_enabled: false
coredns_enabled: true
local_path_provisioner_enabled: false
```

### 3.2. Запуск

```bash
make k8s
```

Скрипт [`scripts/02-run-kubespray.sh`](../scripts/02-run-kubespray.sh) выполняет:

1. Копирует `ansible/inventory/kubespray.yml` → `kubespray/inventory/mycluster/hosts.yml`.
2. Копирует `kubespray-config/group_vars/k8s_cluster/*.yml` в inventory.
3. Запускает `cluster.yml` с `ANSIBLE_FORKS=2` и увеличенными SSH-таймаутами.
4. Забирает `admin.conf` с cp-1 в `~/.kube/config`, заменяет server на VIP.
5. **Патчит `cilium-config`** (workaround для Kubespray v2.26.0):

```bash
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"kube-proxy-replacement":"false",
               "k8s-service-host":"192.168.190.100",
               "k8s-service-port":"6443"}}'
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout restart deploy/cilium-operator
```

6. Ждёт готовности DaemonSet cilium (до 3 минут).

Время выполнения: **15–30 минут**.

### 3.3. Проверка

```bash
kubectl get nodes -o wide
```

Ожидается 6 нод в статусе `Ready`, версия `v1.30.4`.

```bash
kubectl -n kube-system get pods | grep -E 'cilium|kube-proxy|coredns'
```

Все поды `Running`, `cilium` — 6/6.

```bash
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement}'
# false
```

```bash
kubectl get --raw='/readyz?verbose' | tail -3
# readyz check passed
```

Проверка VIP:

```bash
curl -k https://192.168.190.100:6443/healthz
# ok
```

---

## Шаг 4. Post-Kubespray

### 4.1. Запуск

```bash
make post-k8s
```

Playbook [`ansible/playbooks/03-post-kubespray.yml`](../ansible/playbooks/03-post-kubespray.yml):

1. Забирает `admin.conf` с cp-1.
2. Заменяет `server:` на `https://192.168.190.100:6443`.
3. Ждёт, пока все 6 нод станут `Ready`.
4. Навешивает метки из `node_labels`:

| Нода | Метки |
|---|---|
| worker-1 | `monitoring=true`, `logging=true` |
| worker-2 | `storage=true` |
| worker-3 | `ingress=true` |

### 4.2. Проверка

```bash
kubectl get nodes --show-labels | grep -E 'monitoring|storage|ingress'
```

```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion
```

---

## Шаг 5. Bootstrap ArgoCD

### 5.1. Запуск

```bash
make argocd
```

Роль [`ansible/roles/argocd`](../ansible/roles/argocd/tasks/main.yml):

1. Ставит Helm (если нет).
2. Добавляет репозиторий `https://argoproj.github.io/argo-helm`.
3. Создаёт namespace `argocd`.
4. Устанавливает чарт `argo-cd` версии **7.6.12** с values из
   [`ansible/roles/argocd/files/argocd-values.yaml`](../ansible/roles/argocd/files/argocd-values.yaml):

```yaml
configs:
  params:
    server.insecure: true     # TLS терминируется на ingress
server:
  ingress:
    enabled: false            # ArgoCD доступен только через port-forward
dex:
  enabled: false
notifications:
  enabled: false
```

5. Ждёт готовности `argo-cd-argocd-server`.
6. Применяет [`k8s/bootstrap/root-app.yaml`](../k8s/bootstrap/root-app.yaml).
7. Выводит пароль admin.

### 5.2. Проверка

```bash
kubectl -n argocd get pods
# argo-cd-argocd-application-controller-0   1/1 Running
# argo-cd-argocd-repo-server-xxx            1/1 Running
# argo-cd-argocd-server-xxx                 1/1 Running
# argo-cd-redis-xxx                         1/1 Running

kubectl -n argocd get application root
# NAME   SYNC STATUS   HEALTH STATUS
# root   Synced        Healthy
```

Доступ к UI:

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443
# https://localhost:8080
# user: admin
# pass: make password
```

---

## Шаг 6. ArgoCD раскатывает платформу

После применения `root-app` ArgoCD читает `k8s/apps/` из GitHub и создаёт
20 Applications. Ничего делать не нужно — только наблюдать.

### 6.1. Мониторинг прогресса

```bash
watch -n 10 'kubectl -n argocd get applications -o wide'
```

Порядок по sync-waves:

| Wave | Applications | Ожидаемое время |
|---|---|---|
| −1 | namespaces | секунды |
| 0 | ingress-nginx, cert-manager, clusterissuers, external-dns | 2–3 мин |
| 1 | longhorn | 3–5 мин |
| 2 | kube-prometheus-stack, loki, promtail, tempo, otel-collector, external-secrets, vault, platform-certs | 5–10 мин |
| 3 | harbor | 5–8 мин |
| 4 | gitlab, gitlab-runner | 10–20 мин |
| 5 | gitlab-external-secrets, platform-alerts | 1–2 мин |
| default | online-boutique | 2–3 мин (образы уже в Harbor) |

**Итого: 40–60 минут.**

### 6.2. Проверка по волнам

**Wave −1:**

```bash
kubectl get ns
# argocd cert-manager external-dns external-secrets gitlab gitlab-runner
# harbor ingress-nginx logging longhorn-system monitoring online-boutique
# tracing vault
```

**Wave 0:**

```bash
kubectl -n ingress-nginx get ds,svc
# ds/ingress-nginx-controller   6/6
# svc/ingress-nginx-controller  NodePort  80:30080/TCP,443:30443/TCP

kubectl -n cert-manager get pods
kubectl get clusterissuer
# letsencrypt-prod      True
# letsencrypt-staging   True

kubectl get ingressclass
# nginx   k8s.io/ingress-nginx   true
```

**Wave 1:**

```bash
kubectl -n longhorn-system get pods | head
kubectl get sc
# longhorn (default)   driver.longhorn.io   Delete  Immediate  ...
```

**Wave 2:**

```bash
kubectl -n monitoring get pods
kubectl -n logging get pods
kubectl -n tracing get pods
kubectl -n external-secrets get pods
kubectl -n vault get pods
kubectl get certificate -A
```

**Wave 3:**

```bash
kubectl -n harbor get pods
curl -k -I https://harbor.platform-mvp-potapov.ru
```

**Wave 4:**

```bash
kubectl -n gitlab get pods
# Ожидается ~10 подов Running (webservice, sidekiq, gitaly, registry,
# postgresql, redis, toolbox, migrations, gitlab-exporter, shared-secrets)
```

### 6.3. Известные проблемы на этом шаге

| Симптом | Причина | Решение |
|---|---|---|
| `external-dns` в `CrashLoopBackOff` | DPI блокирует `api.cloudflare.com` | Ожидаемо. `kubectl -n external-dns scale deploy external-dns --replicas=0` |
| `Certificate` в `Pending` | Secret `cloudflare-api-token` не создан | См. [Шаг 7](#шаг-7-секреты) |
| `longhorn` OutOfSync | Version mismatch manager/instance-manager | См. [troubleshooting.md](troubleshooting.md#longhorn) |
| `harbor` Multi-Attach | RWO PVC + rollout | См. [troubleshooting.md](troubleshooting.md#harbor) |
| `vault` 403 на kv | kv engine не включён | См. [troubleshooting.md](troubleshooting.md#vault) |

---

## Шаг 7. Секреты

### 7.1. Проблема «курицы и яйца»

cert-manager нужен Cloudflare API Token, чтобы выпустить сертификаты. Токен
хранится в Vault. Vault разворачивается ArgoCD. ESO читает Vault и создаёт
Secret для cert-manager. Но чтобы залить токен в Vault, Vault должен быть уже
запущен.

Порядок:

1. Дождаться, пока Vault станет `Running` (wave 2).
2. Включить kv engine и залить секреты.
3. ESO подхватит их в течение `refreshInterval: 1h` (или принудительно).

### 7.2. Инициализация Vault

```bash
kubectl -n vault port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
# dev-режим: root-токен задан в k8s/values/vault.yaml (server.dev.devRootToken)
export VAULT_TOKEN="$(kubectl -n vault get secret vault -o jsonpath='{.data.root-token}' | base64 -d)"

vault status
# Sealed: false
```

> Значение root-токена — см. Secret `vault` (ключ `root-token`) в namespace `vault` либо Vault `kv/platform/vault`.

Включить KV v2 (chart 0.28.1 не делает этого автоматически):

```bash
vault secrets enable -path=kv -version=2 kv
```

### 7.3. Залить секреты

```bash
# Cloudflare API Token (Zone:DNS:Edit + Zone:Zone:Read)
vault kv put kv/platform/cloudflare api-token="<CF_API_TOKEN>"

# Telegram
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

Проверка:

```bash
vault kv list kv/platform
# cloudflare
# gitlab
# harbor
# telegram

vault kv get kv/platform/cloudflare
```

### 7.4. Токен для ESO

ESO аутентифицируется в Vault по статическому токену из Secret
`external-secrets/vault-token`:

```bash
kubectl -n external-secrets create secret generic vault-token \
  --from-literal=token=root
```

> В production здесь должен быть Kubernetes auth method + ServiceAccount, а не
> root-токен. См. [security.md](security.md).

### 7.5. Принудительная синхронизация ExternalSecret

```bash
kubectl -n cert-manager annotate externalsecret cloudflare-api-token \
  force-sync=$(date +%s) --overwrite
kubectl -n external-dns annotate externalsecret cloudflare-api-token \
  force-sync=$(date +%s) --overwrite
kubectl -n monitoring annotate externalsecret telegram-alertmanager \
  force-sync=$(date +%s) --overwrite
kubectl -n gitlab annotate externalsecret gitlab-root-password \
  force-sync=$(date +%s) --overwrite
kubectl -n gitlab annotate externalsecret harbor-credentials \
  force-sync=$(date +%s) --overwrite
```

### 7.6. Проверка

```bash
kubectl get externalsecret -A
# Все в SecretSynced=True

kubectl -n cert-manager get secret cloudflare-api-token
kubectl -n monitoring get secret alertmanager-telegram
kubectl -n gitlab get secret harbor-credentials
```

Сертификаты:

```bash
kubectl get certificate -A
# Все READY=True
```

Если `Pending` — смотреть:

```bash
kubectl -n cert-manager describe certificaterequest -A | tail -30
kubectl -n cert-manager logs deploy/cert-manager --tail=50
```

Типичная ошибка: ключ в Secret называется `api-token`, а чарт external-dns ждёт
`cloudflare_api_token`. См. [troubleshooting.md](troubleshooting.md#cert-manager).

### 7.7. DNS-записи вручную

external-dns отключён (DPI). Создать A-записи в Cloudflare вручную:

| Имя | Тип | Значение | Proxy |
|---|---|---|---|
| `vault` | A | 192.168.190.153 | DNS only |
| `harbor` | A | 192.168.190.153 | DNS only |
| `longhorn` | A | 192.168.190.153 | DNS only |
| `grafana` | A | 192.168.190.153 | DNS only |
| `prometheus` | A | 192.168.190.153 | DNS only |
| `alertmanager` | A | 192.168.190.153 | DNS only |
| `gitlab` | A | 192.168.190.153 | DNS only |
| `shop` | A | 192.168.190.153 | DNS only |

> `192.168.190.153` — worker-1, где работает ingress-nginx (DaemonSet, поэтому
> подходит любая нода). Proxy **выключен**: Cloudflare не может проксировать
> приватные адреса.

---

## Шаг 8. GitLab и Runner

### 8.1. Получить root-пароль

```bash
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Если Secret создан ESO из Vault — пароль совпадает с
`kv/platform/gitlab → root-password`.

### 8.2. Логин

```bash
# Из WSL2 — только через туннель
ssh -L 8443:192.168.190.153:30443 devops@192.168.190.153
```

В браузере: `https://gitlab.platform-mvp-potapov.ru` (при наличии записи в
`/etc/hosts` → `127.0.0.1`) или `https://localhost:8443` с
`--resolve`/hostAlias.

```bash
curl -k --resolve gitlab.platform-mvp-potapov.ru:8443:127.0.0.1 \
  https://gitlab.platform-mvp-potapov.ru:8443/users/sign_in
```

Логин: `root` / пароль из шага 8.1.

### 8.3. Регистрация Runner

Токен генерируется GitLab после старта — автоматизировать нельзя.

1. **Admin Area → CI/CD → Runners → New instance runner**.
2. Tags: `kubernetes,kubernetes-platform`. Run untagged: **off**.
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

### 8.4. Кастомный образ Runner с CA

GitLab использует self-signed CA (`gitlab-wildcard-tls`), поэтому стандартный
образ Runner не доверяет ему. Образ собран заранее и лежит в Harbor:
`harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5`.

Если нужно пересобрать:

```bash
# Извлечь CA
kubectl -n gitlab get secret gitlab-wildcard-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > gitlab-ca.crt

# Dockerfile
cat > Dockerfile <<'EOF'
FROM gitlab/gitlab-runner:v19.5.1
COPY gitlab-ca.crt /usr/local/share/ca-certificates/gitlab-ca.crt
USER root
RUN update-ca-certificates
USER gitlab-runner
EOF

docker build -t harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5 .
docker push harbor.platform-mvp-potapov.ru/online-boutique/gitlab-runner-ca:v19.5.1-fixed5
```

### 8.5. Проверка

```bash
kubectl -n gitlab get pods | grep runner
# gitlab-runner-xxx   1/1 Running

kubectl -n gitlab logs deploy/gitlab-runner --tail=30 | grep -i 'registered\|runner'
```

В UI: **Admin Area → CI/CD → Runners** — раннер онлайн, зелёный.

---

## Шаг 9. Online Boutique

### 9.1. Создать Secret для pull образов

```bash
kubectl -n online-boutique create secret docker-registry harbor-creds \
  --docker-server=harbor.platform-mvp-potapov.ru \
  --docker-username=admin \
  --docker-password='<HARBOR_ADMIN_PASSWORD>'
```

### 9.2. Собрать 11 образов

**Вариант A — через скрипт (Kaniko в кластере):**

```bash
./scripts/build-online-boutique.sh
```

Скрипт:

1. Создаёт PVC `ob-src` (Longhorn, RWO, 2 Gi) в namespace `ci`.
2. Клонирует `potapovanton149/online-boutique` в PVC подом `ob-clone`.
3. Последовательно запускает 11 Kaniko-подов, каждый собирает свой сервис.
4. Логи: `/tmp/ob-build-<timestamp>.log`.

**Вариант B — через GitLab CI:**

```bash
# В GitLab: New project → Import → potapovanton149/online-boutique
# CI/CD → Variables: HARBOR_USER, HARBOR_PASSWORD
# Push в master → pipeline запустится автоматически
```

### 9.3. Проверка образов

```bash
curl -k -u admin:<PASS> \
  https://harbor.platform-mvp-potapov.ru/api/v2.0/projects/online-boutique/repositories
```

Ожидается 11 репозиториев + `cache` (если включён Kaniko cache).

### 9.4. Дождаться синхронизации ArgoCD

```bash
kubectl -n argocd get application online-boutique
# Synced  Healthy

kubectl -n online-boutique get pods
# 13 подов Running (11 сервисов + redis-cart + loadgenerator)
```

### 9.5. Проверка ingress и TLS

```bash
kubectl -n online-boutique get ingress
kubectl -n online-boutique get certificate
# shop-tls   READY=True

curl -k -H 'Host: shop.platform-mvp-potapov.ru' \
  https://192.168.190.153:30443/ | head -20
```

### 9.6. Проверка UI

```bash
kubectl -n online-boutique port-forward svc/frontend 8080:80
# http://localhost:8080
```

---

## Шаг 10. Финальная проверка

```bash
# 1. Все Applications
kubectl -n argocd get applications
# 20 строк, все Synced + Healthy (кроме external-dns — Synced, но replicas=0)

# 2. Все поды
kubectl get pods -A | grep -v -E 'Running|Completed' | grep -v NAME
# пусто

# 3. Ноды
kubectl get nodes
# 6 × Ready

# 4. Сертификаты
kubectl get certificate -A
# все READY=True

# 5. ExternalSecrets
kubectl get externalsecret -A
# все SecretSynced=True

# 6. Storage
kubectl -n longhorn-system get volumes.longhorn.io
# 14/15 healthy (1 orphan — известное ограничение)

# 7. Приложение
kubectl -n online-boutique get pods | grep -c Running
# 13

# 8. Алерты
kubectl -n monitoring get prometheusrule
# online-boutique, platform-alerts, kube-prometheus-stack-*
```

---

## Полный сброс

Удалить кластер, сохранив VM:

```bash
make destroy
```

Скрипт [`scripts/destroy.sh`](../scripts/destroy.sh) запускает
`kubespray/reset.yml` — удаляет kubelet, etcd, CNI, контейнеры, конфиги.

После сброса можно повторить с [Шага 2](#шаг-2-подготовка-ос-ansible).

> **Внимание:** `reset.yml` не удаляет данные на дисках VM. Если нужно чистое
> состояние — удалить `/var/lib/longhorn`, `/var/lib/containerd`,
> `/var/lib/etcd` вручную на каждой ноде.

---

## Связанные документы

- [architecture.md](architecture.md) — как всё устроено
- [troubleshooting.md](troubleshooting.md) — если что-то пошло не так
- [security.md](security.md) — детали Vault/ESO
- [ci-cd.md](ci-cd.md) — пайплайн
- [application.md](application.md) — приложение
