# Platform MVP — инфраструктурная платформа на базе Kubernetes

Учебный production-like проект: self-managed Kubernetes-кластер на 6 виртуальных
машинах с полной платформенной обвязкой — GitOps-доставка (ArgoCD), ingress и
автоматический TLS, блочное хранилище, метрики/логи/трейсы, приватный реестр
образов, хранилище секретов и собственный CI/CD. Всё, что находится выше
уровня ОС, описано как код и раскатывается из git.

Демонстрационное приложение — Google Online Boutique (11 микросервисов + Redis),
собранное из форка в собственные образы, лежащие в Harbor, и развёрнутое через
ArgoCD. Кластер разворачивается на ноутбуке под Windows 11 Home в VMware
Workstation Pro, управление — из WSL2.

> **Статус:** кластер работает, 20 ArgoCD Applications в состоянии
> `Synced + Healthy`, 13/13 подов Online Boutique в `Running`, сертификаты
> `READY`. Часть функций ограничена сетевыми блокировками РФ — см.
> [Известные ограничения](#известные-ограничения) и
> [docs/known-limitations.md](docs/known-limitations.md).

---

## Содержание

- [Архитектура](#архитектура)
- [Технологический стек](#технологический-стек)
- [Структура репозитория](#структура-репозитория)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Что развёрнуто](#что-развёрнуто)
- [Доступы](#доступы)
- [Известные ограничения](#известные-ограничения)
- [Документация](#документация)
- [Лицензия](#лицензия)

---

## Архитектура

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Хост: Windows 11 Home + VMware Workstation Pro 17                          │
│ WSL2 (Ubuntu 22.04): ansible, kubectl, helm, make                          │
│                                                                            │
│  VMware NAT VMnet8 — 192.168.190.0/24                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  cp-1 .101      cp-2 .151      cp-3 .150      (2 vCPU / 4 GB / 40 GB)│  │
│  │      └──────────────┴──────┬───────┴──────────────┘                  │  │
│  │                     kube-vip VIP 192.168.190.100:6443 (ARP)          │  │
│  │                                                                      │  │
│  │  worker-1 .153   worker-2 .146   worker-3 .145 (4 vCPU / 8 GB / 100GB)│ │
│  │                                                                      │  │
│  │  Kubernetes v1.30.4 (Kubespray v2.26.0)                              │  │
│  │  CNI: Cilium v1.16.1 (eBPF, Hubble) · kube-proxy: IPVS               │  │
│  │  Storage: Longhorn (default StorageClass)                            │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Платформа (ArgoCD App of Apps, 20 Applications)                      │  │
│  │  ingress-nginx 4.11.3 (NodePort 30080/30443)                         │  │
│  │  cert-manager v1.16.2 + Let's Encrypt staging (DNS-01 Cloudflare)    │  │
│  │  external-dns 1.15.0 (replicas=0, known limitation)                  │  │
│  │  Longhorn · kube-prometheus-stack 65.5.0                             │  │
│  │  Loki 6.21.0 + Promtail 6.16.6 · Tempo 1.18.2 + OTel Collector 0.108 │  │
│  │  Vault (dev) + External Secrets Operator 0.10.4                      │  │
│  │  Harbor 1.15.1 · GitLab CE 17.11.7 + GitLab Runner 19.5.1            │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Приложение: Online Boutique (11 сервисов + redis-cart)               │  │
│  │  shop.platform-mvp-potapov.ru → frontend:80 (TLS, Certificate READY) │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

Детальная схема, потоки трафика и обоснования решений —
[docs/architecture.md](docs/architecture.md).

---

## Технологический стек

| Слой | Технология | Версия | Назначение |
|---|---|---|---|
| Гипервизор | VMware Workstation Pro | 17.x | 6 VM, NAT-сеть, снапшоты |
| Управление | Ansible (из WSL2) | 2.16+ | Подготовка ОС, bootstrap ArgoCD |
| Kubernetes | Kubespray (kubeadm) | v2.26.0 | Установка кластера, HA control plane |
| Kubernetes | Kubernetes | v1.30.4 | Оркестратор |
| HA API | kube-vip (ARP) | из Kubespray | VIP `192.168.190.100` |
| CNI | Cilium | v1.16.1 | eBPF, Hubble UI, NetworkPolicy |
| kube-proxy | IPVS | — | `kube_proxy_mode: ipvs` |
| Storage | Longhorn | chart vendored (values 1.7.1) | Реплицируемые PVC, default SC |
| Ingress | ingress-nginx | 4.11.3 | DaemonSet, NodePort 30080/30443 |
| TLS | cert-manager | v1.16.2 | Let's Encrypt staging, DNS-01 Cloudflare |
| DNS | external-dns | 1.15.0 | Cloudflare provider (отключён, см. ограничения) |
| GitOps | ArgoCD | chart 7.6.12 | App of Apps, sync-waves, selfHeal |
| Метрики | kube-prometheus-stack | 65.5.0 | Prometheus, Grafana, Alertmanager |
| Логи | Loki + Promtail | 6.21.0 / 6.16.6 | Сбор логов подов, LogQL |
| Трейсы | Tempo + OTel Collector | 1.18.2 / 0.108.0 | OTLP → Tempo, Grafana |
| Secrets | Vault + ESO | chart vendored / 0.10.4 | Vault dev + ExternalSecret |
| Registry | Harbor | 1.15.1 | Образы, Trivy-сканирование |
| CI/CD | GitLab CE + Runner | 17.11.7 / 19.5.1 | Kaniko-сборка, k8s executor |
| Приложение | Online Boutique | v1.0.0 / v1.0.4 | 11 микросервисов + Redis |

---

## Структура репозитория

```
platform-mvp/
├── README.md
├── CHANGELOG.md
├── Makefile                      # prepare / k8s / post-k8s / argocd / all / destroy
├── .gitmodules                   # kubespray (submodule)
│
├── ansible/                      # ПРОЦЕСС 1: подготовка ОС + bootstrap ArgoCD
│   ├── ansible.cfg
│   ├── requirements.yml
│   ├── inventory/
│   │   ├── prod.yml              # inventory для своих playbook
│   │   ├── kubespray.yml         # inventory для Kubespray
│   │   └── group_vars/all.yml    # версии, VIP, CIDR, метки нод
│   ├── roles/
│   │   ├── common/               # swap off, sysctl, пакеты, chrony, open-vm-tools
│   │   └── argocd/               # helm install ArgoCD + root-app
│   └── playbooks/
│       ├── site.yml
│       ├── 01-prepare.yml
│       ├── 02-kubespray.yml
│       ├── 03-post-kubespray.yml # kubeconfig + метки нод
│       └── 04-argocd.yml
│
├── kubespray/                    # git submodule (kubernetes-sigs/kubespray v2.26.0)
├── kubespray-config/
│   └── group_vars/k8s_cluster/
│       ├── k8s-cluster.yml       # версия, CNI, kube-vip, cilium
│       └── addons.yml            # аддоны Kubespray отключены (всё через ArgoCD)
│
├── scripts/
│   ├── bootstrap.sh              # one-shot: prepare → kubespray → post → argocd
│   ├── 02-run-kubespray.sh       # запуск Kubespray + патч cilium-config
│   ├── build-online-boutique.sh  # сборка 11 образов Kaniko в ns ci
│   ├── destroy.sh                # kubespray reset.yml
│   └── get-argocd-password.sh
│
├── k8s/                          # ПРОЦЕСС 2: GitOps
│   ├── bootstrap/root-app.yaml   # App of Apps (path: k8s/apps, recurse: false)
│   ├── apps/                     # 20 ArgoCD Applications
│   │   ├── 00-namespaces.yaml            wave -1
│   │   ├── 10-ingress-nginx.yaml         wave 0
│   │   ├── 11-cert-manager.yaml          wave 0
│   │   ├── 11a-clusterissuers.yaml       wave 0
│   │   ├── 12-external-dns.yaml          wave 0
│   │   ├── 13-certs.yaml                 wave 2
│   │   ├── 20-longhorn.yaml              wave 1
│   │   ├── 21-kube-prometheus-stack.yaml wave 2
│   │   ├── 22-loki.yaml                  wave 2
│   │   ├── 22a-promtail.yaml             wave 2
│   │   ├── 23-tempo.yaml                 wave 2
│   │   ├── 24-otel-collector.yaml        wave 2
│   │   ├── 30-external-secrets.yaml      wave 2
│   │   ├── 31-vault.yaml                 wave 2
│   │   ├── 40-harbor.yaml                wave 3
│   │   ├── 50-gitlab.yaml                wave 4
│   │   ├── 51-gitlab-runner.yaml         wave 4
│   │   ├── 52-gitlab-external-secrets.yaml wave 5
│   │   ├── 60-online-boutique.yaml       (default wave)
│   │   ├── 61-platform-alerts.yaml       wave 5
│   │   └── online-boutique/              # Kustomize-манифесты приложения
│   ├── values/                   # Helm values для каждого компонента
│   ├── manifests/
│   │   ├── namespaces.yaml
│   │   ├── clusterissuer-letsencrypt-{staging,prod}.yaml
│   │   ├── vault-cluster-secret-store.yaml
│   │   ├── certs/                # Certificate для каждого хоста
│   │   ├── external-secrets/     # 5 ExternalSecret
│   │   ├── alerts/               # PrometheusRule Online Boutique
│   │   ├── dashboards/           # Grafana SLO-дашборд (ConfigMap)
│   │   └── minio/                # MinIO для GitLab object storage
│   └── charts/                   # vendored: longhorn, vault
│
└── docs/
    ├── architecture.md
    ├── deployment.md
    ├── troubleshooting.md
    ├── monitoring.md
    ├── security.md
    ├── ci-cd.md
    ├── application.md
    ├── registry.md
    └── known-limitations.md
```

---

## Требования

### Железо (хост)

| Ресурс | Минимум | Использовано в проекте |
|---|---|---|
| CPU | 12 ядер | Intel i9 |
| RAM | 40 GB | 96 GB (36 GB отдано VM) |
| Диск | 500 GB SSD | 2 TB SSD (420 GB отдано VM) |

### Распределение VM

| VM | vCPU | RAM | Disk | IP | Роль |
|---|---|---|---|---|---|
| cp-1 | 2 | 4 GB | 40 GB | 192.168.190.101 | control-plane + etcd |
| cp-2 | 2 | 4 GB | 40 GB | 192.168.190.151 | control-plane + etcd |
| cp-3 | 2 | 4 GB | 40 GB | 192.168.190.150 | control-plane + etcd |
| worker-1 | 4 | 8 GB | 100 GB | 192.168.190.153 | monitoring, logging, tracing |
| worker-2 | 4 | 8 GB | 100 GB | 192.168.190.146 | приложения, ingress |
| worker-3 | 4 | 8 GB | 100 GB | 192.168.190.145 | Harbor, Vault, GitLab |
| **kube-vip** | — | — | — | **192.168.190.100** | VIP API-сервера |
| **Итого** | **20** | **36 GB** | **420 GB** | | |

### ПО

**Хост:** Windows 11 Home, VMware Workstation Pro 17.x, WSL2 (Ubuntu 22.04).

**WSL2:** `ansible`, `ansible-galaxy`, `python3`, `sshpass`, `kubectl`, `helm`,
`git`, `make`, `jq`, `curl`.

**VM:** Ubuntu 22.04 Server, OpenSSH, `open-vm-tools`, пользователь `devops`
с passwordless sudo, SSH-ключ `~/.ssh/id_ed25519` с хоста.

**Внешние сервисы:** аккаунт Cloudflare + домен `platform-mvp-potapov.ru`,
Telegram-бот + `chat_id` (для алертов).

**Kubespray venv:** `~/.venv/kubespray` (создаётся вручную, см.
[docs/deployment.md](docs/deployment.md)).

---

## Быстрый старт

Предполагается, что 6 VM уже созданы в VMware, у них настроены IP из таблицы
выше, и с хоста работает `ssh devops@192.168.190.101`.

```bash
# 0. Клонировать репозиторий и инициализировать submodule
git clone https://github.com/potapovanton149/platform-mvp.git && cd platform-mvp
git submodule update --init --recursive

# 1. Подготовить ОС на всех 6 нодах (swap off, sysctl, пакеты, chrony)
make prepare

# 2. Установить Kubernetes (Kubespray v2.26.0) + патч cilium-config
make k8s

# 3. Забрать kubeconfig, дождаться 6 Ready, навесить метки нод
make post-k8s

# 4. Установить ArgoCD и применить root App-of-Apps
make argocd

# 5. Дальше — только git: ArgoCD сам подхватит k8s/apps/*
git push origin master
```

Полный one-shot вариант: `make all` (запускает
[`scripts/bootstrap.sh`](scripts/bootstrap.sh)).

После шага 4:

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443
# https://localhost:8080  — admin / make password
```

ArgoCD последовательно (sync-waves −1 → 5) раскатает 20 Applications.
Полная раскатка платформы занимает 40–60 минут (GitLab — самый долгий).

Пошаговая инструкция с проверками после каждого шага —
[docs/deployment.md](docs/deployment.md).

---

## Что развёрнуто

| Компонент | Namespace | Версия | Sync-wave | Статус |
|---|---|---|---|---|
| namespaces | — | — | −1 | Synced |
| ingress-nginx | `ingress-nginx` | 4.11.3 | 0 | Synced + Healthy |
| cert-manager | `cert-manager` | v1.16.2 | 0 | Synced + Healthy |
| clusterissuers | `cert-manager` | — | 0 | Synced + Healthy |
| external-dns | `external-dns` | 1.15.0 | 0 | Synced, replicas=0 ⚠ |
| longhorn | `longhorn-system` | vendored | 1 | Synced + Healthy |
| kube-prometheus-stack | `monitoring` | 65.5.0 | 2 | Synced + Healthy |
| loki | `logging` | 6.21.0 | 2 | Synced + Healthy |
| promtail | `logging` | 6.16.6 | 2 | Synced + Healthy |
| tempo | `tracing` | 1.18.2 | 2 | Synced + Healthy |
| otel-collector | `tracing` | 0.108.0 | 2 | Synced + Healthy |
| external-secrets | `external-secrets` | 0.10.4 | 2 | Synced + Healthy |
| vault | `vault` | vendored (dev) | 2 | Synced + Healthy |
| platform-certs | `default` | — | 2 | Synced + Healthy |
| harbor | `harbor` | 1.15.1 | 3 | Synced + Healthy |
| gitlab | `gitlab` | 8.11.8 (CE 17.11.7) | 4 | Synced + Healthy |
| gitlab-runner | `gitlab` | 0.94.1 (19.5.1) | 4 | Synced + Healthy |
| gitlab-external-secrets | `gitlab` | — | 5 | Synced + Healthy |
| platform-alerts | `monitoring` | — | 5 | Synced + Healthy |
| online-boutique | `online-boutique` | v1.0.0 / v1.0.4 | default | Synced + Healthy |

**Итого:** 20 Applications, 13 namespaces, 13/13 подов Online Boutique в
`Running`, 11 образов в Harbor, 4 алерта Online Boutique (все `inactive`).

---

## Доступы

Пароли в репозитории не хранятся. Источники: Kubernetes Secret (указан в
таблице) или Vault (`kv/platform/*`).

| Сервис | URL | Логин | Пароль |
|---|---|---|---|
| ArgoCD | `kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443` → `https://localhost:8080` | `admin` | `make password` (Secret `argocd-initial-admin-secret`) |
| Grafana | https://grafana.platform-mvp-potapov.ru | `admin` | Secret `kube-prometheus-stack-grafana` |
| Prometheus | https://prometheus.platform-mvp-potapov.ru | — | — |
| Alertmanager | https://alertmanager.platform-mvp-potapov.ru | — | — |
| Longhorn UI | https://longhorn.platform-mvp-potapov.ru | — | — |
| Vault UI | https://vault.platform-mvp-potapov.ru | `token` | dev root token — Secret `vault` / `kv/platform/vault` |
| Harbor | https://harbor.platform-mvp-potapov.ru | `admin` | `kv/platform/harbor` → `admin-password` |
| GitLab | https://gitlab.platform-mvp-potapov.ru | `root` | `kv/platform/gitlab` → `root-password` |
| Online Boutique | https://shop.platform-mvp-potapov.ru | — | — |

Все хосты используют Let's Encrypt **staging** — браузер покажет предупреждение
о недоверенном сертификате. Это осознанно, см.
[docs/known-limitations.md](docs/known-limitations.md).

Доступ к GitLab/Harbor из WSL2 — только через SSH-туннель:

```bash
ssh -L 8443:192.168.190.153:30443 devops@192.168.190.153
# затем https://localhost:8443 с Host-заголовком или записью в /etc/hosts
```

---

## Известные ограничения

Проект честно фиксирует то, что не работает, и почему. Полный разбор —
[docs/known-limitations.md](docs/known-limitations.md).

| # | Ограничение | Причина | Обход |
|---|---|---|---|
| 1 | Внешний доступ из интернета не работает | DPI/РФ-ограничения: Cloudflare Tunnel (TCP 443 alert 40, QUIC 7844 timeout), ngrok (домен блокируется), Tailscale Funnel (control plane блокируется), VK Tunnel (техработы) | Демонстрация через screen share / запись видео |
| 2 | Telegram-алерты не доставляются | `api.telegram.org` блокируется из РФ | Конфиг готов, проверяется локально; скриншот алерта в Alertmanager |
| 3 | external-dns в `CrashLoopBackOff` | TLS handshake к `api.cloudflare.com` обрывается DPI | `replicas: 0`, DNS-записи создаются вручную в Cloudflare |
| 4 | Vault в dev-режиме | Данные в памяти, root token `root`, нет unseal | Для prod: persistent storage + Shamir/auto-unseal |
| 5 | GitLab ingress на self-signed CA | `gitlab-wildcard-tls`, не LE staging | Runner собран с этим CA в образе |
| 6 | MinIO из `bitnamilegacy` | Bitnami убрал free-образы | Временное решение, ждём возврата |
| 7 | Longhorn: 1 orphan volume | Остаток от каскадного удаления | Не критично, чистится вручную |
| 8 | GitLab/Harbor недоступны из WSL напрямую | NodePort + NAT + TLS SNI | Только через `ssh -L` |
| 9 | TLS — Let's Encrypt staging | Rate limits prod при отладке | Переключить ClusterIssuer на `letsencrypt-prod` |

---

## Документация

| Документ | Содержание |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Уровни платформы, сеть, потоки трафика, GitOps/CI-CD/Secrets/Observability, обоснования решений |
| [docs/deployment.md](docs/deployment.md) | Пошаговое развёртывание с нуля: VM → ОС → k8s → ArgoCD → секреты → GitLab → приложение |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Все грабли проекта: симптом → причина → фикс, готовый к copy-paste |
| [docs/monitoring.md](docs/monitoring.md) | Prometheus, Grafana, Alertmanager, Loki/Promtail, Tempo/OTel, 4 алерта Online Boutique |
| [docs/security.md](docs/security.md) | Vault, External Secrets Operator, 5 ExternalSecret, RBAC, путь секрета до пода |
| [docs/ci-cd.md](docs/ci-cd.md) | GitLab CE, Runner (k8s executor), Kaniko-пайплайн, bump тега, ArgoCD sync |
| [docs/application.md](docs/application.md) | Online Boutique: сервисы, сборка образов, Dockerfile-фиксы, ingress, SLO |
| [docs/registry.md](docs/registry.md) | Harbor: проекты, логин, push, Trivy, TLS-особенности |
| [docs/known-limitations.md](docs/known-limitations.md) | Честный список ограничений и планов по их устранению |
| [CHANGELOG.md](CHANGELOG.md) | История по 7 этапам разработки |

---

## Лицензия

Учебный проект. Код инфраструктуры (`ansible/`, `k8s/`, `scripts/`) —
MIT. Приложение Online Boutique — Apache License 2.0
([GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo)).
Kubespray — Apache License 2.0. Helm-чарты сохраняют лицензии апстрима.
