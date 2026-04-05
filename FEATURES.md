# Feature Backlog

## Alertmanager-Based Blocking (Webhook)

Prometheus Alertmanager can send a webhook to gateii when a threshold is exceeded,
automatically blocking the user.

**Flow:**
1. Prometheus detects `sum(increase(gateii_tokens_total{user="X"}[24h])) > threshold`
2. Alertmanager routes the alert to a gateii webhook (`POST /internal/admin/block`)
3. Admin API sets block flag in shared dict with TTL

**Advantage:** More complex rules (e.g., "costs > $10/day" instead of just token count),
centralized alert configuration, integration with existing notification channels.

**Disadvantage:** 15-60s delay until block takes effect. For hard limits, continue
using the synchronous check in auth.lua.

## Monthly Token Budgets

`limits` already has `tokens_per_day` and `requests_per_day`.
Extension to `tokens_per_month`: similar to daily counters in tracking.lua,
maintain monthly counters with 32d TTL.

## Per-Model Limits

Limits are currently global per user. Extension:
separate limit keys per user+model in the blocking shared dict.
auth.lua would need to read the model from the request body after user resolution
(requires body read in access_by_lua, before handler.lua runs).

**Tradeoff:** Body parsing in auth.lua increases latency and complexity.
Alternative: limits only per user, model granularity via Grafana alerts.

## OpenAI + OpenRouter Provider (Completion)

Stubs exist in `providers/openai.lua` and `providers/openrouter.lua`.
Missing: SSE token parsing (OpenAI format: `usage` in last `data: [DONE]` event),
env vars in docker-compose + nginx.conf, end-to-end tests.

## Cost-Based Limits

Set dollar limits directly instead of token counts. Pricing table is already
in metrics.lua — can be imported as a shared module from auth.lua.

## Multi-Key per User

Currently 1:1 mapping key->user in keys.json. For teams: multiple keys per user
with different permissions (e.g., "read-only" key that only allows Haiku).
