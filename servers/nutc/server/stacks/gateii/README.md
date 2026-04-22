# gateii — NUTC production stack

In-repo staging for the NUTC deployment. Mirrors the 3-container local dev
stack (openresty + prometheus + grafana) with production-safe defaults.

## Deploy

```bash
bash scripts/deploy-nutc.sh
```

What the script does:

1. rsync `servers/nutc/server/stacks/gateii/docker-compose.yml` →
   `~/docker/gateii/docker-compose.yml` on the NUTC host
2. rsync `config/openresty/` (repo root) → `~/docker/gateii/config/openresty/`
3. rsync `prometheus.yml` + `config/prometheus/` → `~/docker/gateii/config/`
4. rsync `grafana/` → `~/docker/gateii/config/grafana/`
5. `docker compose up -d` on the NUTC host

The `.env` and `data/` directories on the NUTC host are preserved (excluded
from rsync). First deploy must ssh to the host and copy `.env.example → .env`
before running `deploy-nutc.sh`.

## Differences from local dev stack

| Setting | dev | NUTC prod |
|---|---|---|
| `PROXY_MODE` | `passthrough` | `apikey` |
| `CONSOLE_ENABLED` | `0` | `1` |
| `ADMIN_TOKEN` | optional | required |
| `HISTORY_RETENTION` | `0` (unlimited) | `90d` |
| Grafana anon | enabled | disabled (user+pw required) |
| Port bind | `0.0.0.0` | `127.0.0.1` (traefik fronts) |
| Prometheus port exposed | yes (9090) | no (internal only) |
| git-tracking plugin | optional | no |
