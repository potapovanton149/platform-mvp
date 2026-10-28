# Online Boutique — приложение платформы

## Что это
Google Online Boutique (microservices-demo) — 11 микросервисов + Redis:
frontend, cartservice (C#), productcatalogservice, currencyservice,
paymentservice (Node.js), shippingservice, emailservice (Python),
checkoutservice, recommendationservice (Python), adservice (Java),
loadgenerator (Python).

## Образы
`harbor.platform-mvp-potapov.ru/online-boutique/<svc>:v1.0.0`
Собираются Kaniko из форка `potapovanton149/online-boutique`.

## Деплой через ArgoCD
Application `online-boutique` (sync-wave 5):
- source: `k8s/apps/online-boutique` (Kustomize)
- destination: ns `online-boutique`
- prune + selfHeal включены

## Ingress + TLS
`shop.platform-mvp-potapov.ru` → frontend:80, TLS через
`letsencrypt-staging` (staging — для учебного окружения).

Доступ из WSL: `ssh -L 8080:192.168.190.153:30080 devops@192.168.190.153`
и открыть `https://shop.platform-mvp-potapov.ru` через hosts/hostAlias
или `curl -k -H "Host: shop..." https://localhost:8080/`.

## Метрики
- OTel env: `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.tracing.svc:4317`
  → Tempo (трейсы), Prometheus (метрики)
- Prometheus annotations: `prometheus.io/scrape` на каждом сервисе
- ServiceMonitor `online-boutique` (ns monitoring)

## SLO-дашборд
ConfigMap `grafana-dashboard-online-boutique-slo` (ns monitoring,
label `grafana_dashboard=1`) → подхват sidecar'ом.
Панели: RPS, p95, error rate, availability SLO 99%, totals, pods running.

## Алерты
PrometheusRule `online-boutique` (ns monitoring):
- OBHighErrorRate (>5% 5m)
- OBHighLatency (p95 > 500ms 5m)
- OBServiceDown (up==0 2m)
- OBPodCrashLooping (>3 restarts / 10m)

## Обновление версии
1. CI собрал образы с `TAG=<sha>` → в Harbor.
2. В `k8s/apps/online-boutique/*.yaml` заменить `:v1.0.0` на `:<sha>` (sed/commit).
3. ArgoCD видит diff → auto-sync.