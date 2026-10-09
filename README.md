# Platform MVP — инфраструктурная платформа на базе Kubernetes

Учебный проект: развёртывание self-managed Kubernetes-кластера с полной
инфраструктурной обвязкой (мониторинг, логирование, трейсинг, CI/CD,
реестр артефактов, хранилище секретов) и демонстрационным приложением
Online Boutique.

Платформа разворачивается на ноутбуке под Windows 11 Home через
VMware Workstation Pro. Управление сервисами и приложением —
через GitOps (ArgoCD).

---

## Содержание

- [Ключевые решения](#ключевые-решения)
- [Архитектура](#архитектура)
- [Технологический стек](#технологический-стек)
- [Структура репозитория](#структура-репозитория)
- [Требования к железу и ПО](#требования-к-железу-и-по)
- [Процесс 1: Развёртывание платформы](#процесс-1-развёртывание-платформы)
- [Процесс 2: Сервисы и приложение через GitOps](#процесс-2-сервисы-и-приложение-через-gitops)
- [Публичный доступ (ingress)](#публичный-доступ-ingress)
- [Мониторинг и алерты](#мониторинг-и-алерты)
- [Логирование](#логирование)
- [Трейсинг](#трейсинг)
- [CI/CD](#cicd)
- [Хранилище артефактов](#хранилище-артефактов)
- [Хранилище секретов](#хранилище-секретов)
- [Проверка работоспособности](#проверка-работоспособности)
- [Changelog](#changelog)
- [Лицензия](#лицензия)

---

## Ключевые решения

Проект построен на нескольких осознанных компромиссах. Каждое
решение обосновано — это часть инженерной работы.

### 1. Гипервизор: VMware Workstation Pro (а не Hyper-V, не KVM)

**Проблема:** хост — ноутбук с Windows 11 Home. На Home нет
официальной поддержки Hyper-V (компонент отсутствует в образе,
`Enable-WindowsOptionalFeature` не находит `Microsoft-Hyper-V-All`).
WSL2 работает, но вложенная виртуализация (WSL2 → KVM → VM) даёт
нестабильность и потери производительности. Community-провайдеры
Terraform для VMware Workstation заброшены.

**Решение:** VMware Workstation Pro с ручным созданием VM через GUI.
VMware стабильно работает на Windows 11 Home, даёт снапшоты,
клонирование, гибкие сети (NAT/Bridged/Host-only).

**Обоснование:** ручное создание 6 VM — одноразовая операция
(30–60 минут с клонированием). Это подготовка окружения, а не часть
платформы. Автоматизация начинается с уровня ОС и выше — там, где
она даёт реальную ценность.

### 2. Terraform не используется

**Проблема:** Terraform — стандарт для IaC в облаках. Но здесь нет
облака. VM создаются локально в VMware, для которого нет живого
Terraform-провайдера. Пытаться использовать Terraform ради галочки —
значит писать костыли.

**Решение:** Terraform полностью исключён из проекта. Вся
автоматизация — на Ansible (для ОС и bootstrap) и ArgoCD
(для сервисов и приложения).

**Обоснование:** требование презентации — «Автоматизация создания и
настройки кластера в виде кода». Ansible — это тоже код. Terraform
не единственный инструмент IaC.

### 3. Установка Kubernetes: Kubespray (гибридный подход)

**Проблема:** написать свой Ansible для kubeadm init/join с HA
control plane и kube-vip — это +2 недели работы и высокая
вероятность застрять на отладке. При этом Kubespray — официальный
инструмент Kubernetes SIGs, стандарт де-факто для self-managed
кластеров.

**Решение:** гибридный подход.

| Слой | Инструмент | Кто пишет |
|---|---|---|
| Подготовка ОС | Ansible | Я |
| Установка Kubernetes | **Kubespray** | SIGs |
| Конфигурация Kubespray | YAML group_vars | Я |
| Bootstrap ArgoCD | Ansible | Я |
| Платформенные сервисы | ArgoCD (GitOps) | Я |
| CI/CD, приложение | GitLab CI + ArgoCD | Я |

**Обоснование:** в реальной практике k8s не пишут с нуля — используют
проверенные инструменты. Ценность создаётся вокруг кластера:
GitOps-обвязка, CI/CD, observability, безопасность, приложение. Это
и есть 90% проекта.

### 4. GitOps как единый механизм доставки

**Решение:** после bootstrap ArgoCD **все** сервисы и приложение
раскатываются через ArgoCD из git. Ansible после bootstrap больше
не используется.

**Обоснование:**
- Единый механизм для платформы и приложения
- Декларативность, drift detection, автоматическая синхронизация
- CI не имеет доступа к кластеру — только к git (best practice)
- Полная история изменений в git

### 5. Публичный доступ: Cloudflare Tunnel

**Проблема:** ноутбук не имеет белого IP. Требование — публично
доступный ingress.

**Решение:** Cloudflare Tunnel. На хосте запускается `cloudflared`,
создаёт исходящий туннель до Cloudflare, домен `*.your-domain`
резолвится в Cloudflare, трафик идёт в `ingress-nginx` внутри
кластера.

**Обоснование:** бесплатно, HTTPS из коробки, не требует белого IP,
не требует VPS. Индустриальный стандарт для такой задачи.

---

## Архитектура

### Высокоуровневая схема
```
┌──────────────────────────────────────────────────────────────────┐
│ Ноутбук (Windows 11 Home)                                        │
│                                                                  │
│ ┌──────────────────────────────────────────────────────────┐     │
│ │ VMware Workstation Pro                                   │     │
│ │                                                          │     │
│ │ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐          │     │
│ │ │ cp-1        │ │ cp-2        │ │ cp-3        │          │     │
│ │ │ 2 vCPU/4GB  │ │ 2 vCPU/4GB  │ │ 2 vCPU/4GB  │          │     │
│ │ └──────┬──────┘ └──────┬──────┘ └──────┬──────┘          │     │
│ │        │               │               │                 │     │
│ │        └───────────────┼───────────────┘                 │     │
│ │         kube-vip (VIP) │                                 │     │
│ │                        │                                 │     │
│ │ ┌─────────────┐ ┌──────┴──────┐ ┌─────────────┐          │     │
│ │ │ worker-1    │ │ worker-2    │ │ worker-3    │          │     │
│ │ │ 4 vCPU/8GB  │ │ 4 vCPU/8GB  │ │ 4 vCPU/8GB  │          │     │
│ │ └─────────────┘ └─────────────┘ └─────────────┘          │     │
│ │                                                          │     │
│ │ Kubernetes (kubeadm через Kubespray)                     │     │
│ │ CNI: Cilium + kube-proxy replacement                     │     │
│ │ Storage: Longhorn                                        │     │
│ └──────────────────────────────────────────────────────────┘     │
│                                                                  │
│ ┌──────────────────────────────────────────────────────────┐     │
│ │ Платформенные сервисы                                    │     │
│ │ ingress-nginx · cert-manager · external-dns              │     │ 
│ │ kube-prometheus-stack (Prometheus/Grafana/Alertmanager)  │     │
│ │ Loki + Promtail · Tempo + OTel Collector                 │     │
│ │ Harbor · Vault + External Secrets · GitLab CE + Runner   │     │
│ │ ArgoCD (GitOps)                                          │     │
│ └──────────────────────────────────────────────────────────┘     │
│                                                                  │
│ ┌──────────────────────────────────────────────────────────┐     │
│ │ Приложение: Online Boutique                              │     │
│ │ 11 микросервисов (frontend, cartservice, ...)            │     │
│ └──────────────────────────────────────────────────────────┘     │
│                                                                  │
│ Cloudflare Tunnel → ingress-nginx → сервисы                      │
└──────────────────────────────────────────────────────────────────┘
```



### Разделение на два процесса

| Процесс | Что делает | Инструменты | Результат |
|---|---|---|---|
| **1. Платформа** | Готовит ОС, ставит k8s, bootstrap ArgoCD | Ansible + Kubespray | «Голый» кластер + ArgoCD |
| **2. Сервисы и приложение** | Раскатывает обвязку и приложение | ArgoCD (GitOps) | Работающая платформа + приложение |

Разделение позволяет:
- Пересоздавать кластер, не трогая описания сервисов
- Обновлять сервисы через git push
- Использовать один механизм (GitOps) для платформы и приложения

### Границы автоматизации

| Слой | Автоматизация | Почему |
|---|---|---|
| Создание VM в VMware | Ручное (GUI) | Одноразовая операция, нет живого Terraform-провайдера |
| Подготовка ОС | Ansible роль `common` | Идемпотентно, воспроизводимо |
| Установка Kubernetes | Kubespray | Индустриальный стандарт SIGs |
| Bootstrap ArgoCD | Ansible роль `argocd` | Единственный сервис, который ставится вне GitOps |
| Всё остальное | ArgoCD (GitOps) | Декларативно, версионируется, drift detection |

---

## Технологический стек

Принцип выбора: **самое простое из работающих**, без overkill.

| Слой | Технология | Почему |
|---|---|---|
| Хост | Windows 11 Home | Основная ОС, менять не хотим |
| Гипервизор | VMware Workstation Pro | Работает на Home, стабилен, снапшоты |
| Управление | Ansible из WSL2 | Идемпотентно, без агентов |
| Kubernetes | kubeadm через **Kubespray** | Стандарт SIGs, HA из коробки |
| HA API | kube-vip (через Kubespray) | Один манифест, без keepalived |
| CNI | Cilium (через Kubespray) | eBPF, Hubble UI, kube-proxy replacement |
| Storage | Longhorn | Репликация, UI, простой install |
| Ingress | ingress-nginx | Стандарт де-факто |
| TLS | cert-manager + Let's Encrypt (DNS-01 CF) | Автоматические сертификаты |
| DNS | external-dns | Автоматические DNS-записи |
| GitOps | ArgoCD | App of Apps, drift detection |
| Метрики | kube-prometheus-stack | Prometheus + Grafana + Alertmanager |
| Логи | Loki + Promtail | Лёгкий, нативно в Grafana |
| Трейсы | Tempo + OpenTelemetry Collector | Нативно в Grafana |
| Алерты | Alertmanager → Telegram | Просто и наглядно |
| CI/CD | GitLab CE + GitLab Runner (k8s executor) | Всё в одном, индустриально |
| Registry | Harbor | Образы + Helm charts + Trivy |
| Secrets | Vault + External Secrets Operator | Стандарт, dynamic secrets |
| Публичный доступ | Cloudflare Tunnel | Нет белого IP — не проблема |
| Приложение | Online Boutique (Google) | 11 микросервисов, Apache 2.0, HTTP |

---

## Структура репозитория

```
platform-mvp/
├── README.md
├── CHANGELOG.md
├── Makefile # make prepare / k8s / argocd / all / destroy
├── .gitignore
├── .editorconfig
│
├── docs/
│ ├── architecture.md # детальная архитектура
│ ├── deployment.md # пошаговое развёртывание
│ ├── monitoring.md # метрики, дашборды, алерты
│ ├── logging.md # Loki, Promtail, LogQL
│ ├── tracing.md # Tempo, OTel, примеры трейсов
│ ├── ci-cd.md # пайплайн, переменные
│ ├── security.md # Vault, ESO, RBAC
│ └── troubleshooting.md # частые проблемы
│
├── ansible/ # ПРОЦЕСС 1: свой Ansible
│ ├── ansible.cfg
│ ├── requirements.yml
│ ├── inventory/
│ │ ├── prod.yml # inventory для своих playbook
│ │ └── kubespray.yml # inventory для Kubespray
│ ├── group_vars/
│ │ └── all.yml # версии, VIP, pod_cidr
│ ├── roles/
│ │ ├── common/ # подготовка ОС
│ │ │ ├── tasks/main.yml
│ │ │ ├── handlers/main.yml
│ │ │ └── defaults/main.yml
│ │ └── argocd/ # bootstrap ArgoCD
│ │ ├── tasks/main.yml
│ │ ├── handlers/main.yml
│ │ └── files/argocd-values.yaml
│ └── playbooks/
│ ├── site.yml # всё вместе
│ ├── 01-prepare.yml # подготовка ОС
│ ├── 02-kubespray.yml # обёртка над Kubespray
│ ├── 03-post-kubespray.yml # kubeconfig + метки нод
│ └── 04-argocd.yml # ArgoCD
│
├── kubespray-config/ # ПРОЦЕСС 1: конфигурация Kubespray
│ └── group_vars/
│ └── k8s_cluster/
│ ├── k8s-cluster.yml # версия, CNI, kube-proxy
│ └── addons.yml # аддоны (metrics-server и т.д.)
│
├── kubespray/ # git submodule (чужой код)
│
├── k8s/ # ПРОЦЕСС 2: GitOps
│ ├── bootstrap/
│ │ └── root-app.yaml # App of Apps
│ ├── apps/ # ArgoCD Applications
│ │ ├── 00-namespaces.yaml
│ │ ├── 10-ingress-nginx.yaml
│ │ ├── 11-cert-manager.yaml
│ │ ├── 12-external-dns.yaml
│ │ ├── 20-kube-prometheus-stack.yaml
│ │ ├── 21-loki.yaml
│ │ ├── 22-tempo.yaml
│ │ ├── 23-otel-collector.yaml
│ │ ├── 24-longhorn.yaml
│ │ ├── 30-harbor.yaml
│ │ ├── 31-vault.yaml
│ │ ├── 32-external-secrets.yaml
│ │ ├── 40-gitlab.yaml
│ │ ├── 41-gitlab-runner.yaml
│ │ └── 50-online-boutique.yaml
│ └── values/ # Helm values
│ ├── ingress-nginx.yaml
│ ├── cert-manager.yaml
│ ├── external-dns.yaml
│ ├── kube-prometheus-stack.yaml
│ ├── loki.yaml
│ ├── tempo.yaml
│ ├── otel-collector.yaml
│ ├── longhorn.yaml
│ ├── harbor.yaml
│ ├── vault.yaml
│ ├── external-secrets.yaml
│ ├── gitlab.yaml
│ ├── gitlab-runner.yaml
│ └── online-boutique.yaml
│
├── apps/ # приложение
│ └── online-boutique/
│ └── .gitlab-ci.yml
│
└── scripts/
├── bootstrap.sh # one-shot развёртывание
├── destroy.sh # снести кластер
├── smoke-test.sh # end-to-end проверка
└── get-argocd-password.sh
```


---

## Требования к железу и ПО

### Железо (хост)

| Ресурс | Значение |
|---|---|
| CPU | Intel i9 |
| RAM | 96 GB |
| Диск | 2 TB SSD |

### Распределение ресурсов VM

| VM | vCPU | RAM | Disk | Роль |
|---|---|---|---|---|
| cp-1 | 2 | 4 GB | 40 GB | control-plane 1 |
| cp-2 | 2 | 4 GB | 40 GB | control-plane 2 |
| cp-3 | 2 | 4 GB | 40 GB | control-plane 3 |
| worker-1 | 4 | 8 GB | 100 GB | monitoring, logging, tracing |
| worker-2 | 4 | 8 GB | 100 GB | приложения, ingress |
| worker-3 | 4 | 8 GB | 100 GB | Harbor, Vault, GitLab |
| **Итого** | **20** | **36 GB** | **420 GB** | |

RAM VM = 36 GB. Остаётся 60 GB на Windows + браузеры + WSL2.
Диск VM = 420 GB. Остаётся ~1.5 TB на хосте.

### Сеть

**VMware NAT** (VMnet8). VM не видны из домашней сети, но имеют
интернет и доступны с хоста.

| VM | IP |
|---|---|
| cp-1 | 192.168.75.10 |
| cp-2 | 192.168.75.11 |
| cp-3 | 192.168.75.12 |
| worker-1 | 192.168.75.21 |
| worker-2 | 192.168.75.22 |
| worker-3 | 192.168.75.23 |
| **kube-vip** | **192.168.75.100** |

### ПО на хосте

- Windows 11 Home
- VMware Workstation Pro 17.x
- WSL2 с Ubuntu 22.04
- В WSL: `ansible`, `python3`, `sshpass`, `kubectl`, `helm`, `git`, `make`
- Cloudflare аккаунт + домен
- Telegram-бот + chat_id

### ПО на VM (после подготовки)

- Ubuntu 22.04 Server
- OpenSSH server
- qemu-guest-agent (для VMware — open-vm-tools)
- Пользователь `ansible` с sudo без пароля
- SSH-ключ с хоста

