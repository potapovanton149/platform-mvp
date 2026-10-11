# Monitoring stack

## Что развёрнуто

- **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)
- Namespace: `monitoring`
- Sync-wave: "2" (после Longhorn)

## URLs

| Сервис       | URL                                              |
|--------------|--------------------------------------------------|
| Grafana      | https://grafana.platform-mvp-potapov.ru          |
| Alertmanager | https://alertmanager.platform-mvp-potapov.ru     |
| Prometheus   | внутренний (порт-форвард)                        |

## Grafana

- Login: `admin` / `AdminPass123!`
- Datasources: Prometheus (default), Loki, Tempo
- Persistence: Longhorn, 5Gi

Port-forward если ingress недоступен:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80