 

## Этап 6: GitLab CE + Runner

### Bitnami убрал free-образы → используем bitnamilegacy

**Симптом:** postgres/redis из GitLab Helm chart не поднимаются.

**Решение:** bitnamilegacy/* (временное, пока Bitnami не вернёт).

### Runner x509 — не доверяет self-signed GitLab

**Симптом:** Runner не регистрируется, x509 certificate error.

**Решение:** собрать кастомный образ Runner с CA GitLab в /usr/local/share/ca-certificates/ + update-ca-certificates.

### Kaniko Invalid auth configuration file

**Симптом:** `before_script` через `printf | base64` даёт битый JSON.

**Решение:** прямой `cat > config.json <<EOF` с username/password (Kaniko сам base64).

### external_url с портом ломает Ruby URI

**Симптом:** `URI::InvalidComponentError`.

**Решение:** external_url без порта.
