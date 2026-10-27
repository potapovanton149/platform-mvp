# CI/CD: GitLab CE + Runner

## Что это
- **GitLab CE** — self-hosted Git-сервер + CI/CD-движок.
- **GitLab Runner** — агент, который исполняет jobs. Использует Kubernetes executor: каждый job — отдельный pod.
- **Kaniko** — сборка Docker-образов без Docker daemon (не требует privileged).
- **Harbor** — приватный registry, куда пушим образы.

## Доступ
- UI: https://gitlab.platform-mvp-potapov.ru
- root / пароль из Vault (`kv/platform/gitlab` → `root-password`, в проекте — `GitLab12345!`)
- Пароль в k8s: `kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d`

## Развёртывание
1. Push в git → ArgoCD synс волны 4.
2. Через 10–15 минут GitLab поднимется: `kubectl -n gitlab get pods`.
3. Логин в UI root-паролем.
4. Сменить пароль (Profile → Password).

## Регистрация Runner (ручная)
Токен генерируется GitLab после старта — автоматизировать нельзя.
1. Admin Area → CI/CD → Runners → **New instance runner**.
2. Tags: `kubernetes,kubernetes-platform`. Run untagged: off. Privileged: on.
3. Скопировать registration token.
4. Создать Secret:
   ```bash
   kubectl -n gitlab create secret generic gitlab-runner-secret \
     --from-literal=runner-registration-token="<TOKEN>"