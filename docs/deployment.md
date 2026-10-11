## Этап 3 — GitOps wave -1 и wave 0 (базовые сервисы)

### Что разворачивается
- **wave -1**: Namespaces (все 13 штук)
- **wave 0**:
    - ingress-nginx 4.11.3 (DaemonSet, NodePort 30080/30443)
    - cert-manager v1.16.2 (с CRDs, DNS-01 Cloudflare)
    - external-dns 8.3.9 (Cloudflare provider, proxied=false)

### Проверка
```bash
kubectl -n argocd get applications
kubectl -n ingress-nginx get pods,svc
kubectl -n cert-manager get pods
kubectl get clusterissuer
kubectl -n external-dns get pods
kubectl get ingressclass