# Feature Backlog

## Alertmanager-basiertes Blocking (Webhook)

Prometheus Alertmanager kann bei Schwellwert-Ueberschreitung einen Webhook
an gateii senden, der `blocked:<user>` automatisch setzt.

**Ablauf:**
1. Prometheus erkennt `sum(increase(gateii_tokens_total{user="X"}[24h])) > threshold`
2. Alertmanager routet den Alert an einen gateii-Webhook (`POST /admin/block`)
3. Webhook setzt `blocked:<user>` in Redis mit TTL

**Prometheus scrape_interval**: Pro Job konfigurierbar in prometheus.yml.
Fuer gateii koennte man auf 5s reduzieren -- aber Alert `for:` Bedingung +
Alertmanager-Routing-Delay bleibt. Fuer sofortiges Blocking weiterhin
auth.lua Direktpruefung bevorzugen.

**Vorteil:** Komplexere Regeln (z.B. "Kosten > $10/Tag" statt nur Token-Count),
zentralisierte Alert-Konfiguration, Integration mit bestehenden Notification-Channels.

**Nachteil:** 15-60s Delay bis Block greift. Fuer harte Limits weiterhin die
synchrone Pruefung in auth.lua nutzen.

## Monthly Token Budgets

`limits:<user>` hat bereits `tokens_per_month` als erlaubtes Feld.
Tracking fehlt noch: `usage_month:<user>:<YYYY-MM>` Redis-Hash mit 32d TTL.

Implementierung analog zu `usage_day`: In tracking.lua im Pipeline
`usage_month:*` inkrementieren, in auth.lua pruefen.

## Per-Model Limits

Limits aktuell nur global pro User. Erweiterung:
`limits:<user>:<model>` als separater Hash mit denselben Feldern.
auth.lua muesste nach User-Aufloesung das Modell aus dem Request-Body lesen
(erfordert Body-Read in access_by_lua, bevor handler.lua laeuft).

**Tradeoff:** Body-Parsing in auth.lua erhoeht Latenz und Komplexitaet.
Alternative: Limits nur pro User, Modell-Granularitaet ueber Grafana-Alerts.

## OpenAI + OpenRouter Provider (Completion)

Stubs existieren in `providers/openai.lua` und `providers/openrouter.lua`.
Fehlend: SSE-Token-Parsing (OpenAI-Format: `usage` im letzten `data: [DONE]`-Event),
Env-Vars in docker-compose + nginx.conf, End-to-end-Tests.

## Admin API (HTTP statt CLI)

Aktuell: `admin.sh` ueber `docker exec redis-cli`. Fuer Remote-Management:
REST-Endpunkt in OpenResty (separater `server`-Block auf internem Port),
geschuetzt durch IP-Allowlist oder separaten Admin-Key.

Basis fuer Alertmanager-Webhook (siehe oben).

## Cost-Based Limits

Statt Token-Count direkt Dollar-Limits setzen. Erfordert Modell-Pricing
in Lua (aktuell nur im Python-Exporter). Pricing-Tabelle als shared Lua-Module,
von auth.lua und tracking.lua importiert.

## Multi-Key per User

Aktuell 1:1 Mapping Key->User. Fuer Teams: mehrere Keys pro User mit
unterschiedlichen Berechtigungen (z.B. "read-only"-Key der nur Haiku darf).
