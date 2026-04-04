# Feature Backlog

## Alertmanager-basiertes Blocking (Webhook)

Prometheus Alertmanager kann bei Schwellwert-Ueberschreitung einen Webhook
an gateii senden, der User automatisch blockt.

**Ablauf:**
1. Prometheus erkennt `sum(increase(gateii_tokens_total{user="X"}[24h])) > threshold`
2. Alertmanager routet den Alert an einen gateii-Webhook (`POST /internal/admin/block`)
3. Admin API setzt Block-Flag in shared dict mit TTL

**Vorteil:** Komplexere Regeln (z.B. "Kosten > $10/Tag" statt nur Token-Count),
zentralisierte Alert-Konfiguration, Integration mit bestehenden Notification-Channels.

**Nachteil:** 15-60s Delay bis Block greift. Fuer harte Limits weiterhin die
synchrone Pruefung in auth.lua nutzen.

## Monthly Token Budgets

`limits` hat bereits `tokens_per_day` und `requests_per_day`.
Erweiterung um `tokens_per_month`: Analog zu daily counters in tracking.lua
monatliche Counters mit 32d TTL fuehren.

## Per-Model Limits

Limits aktuell nur global pro User. Erweiterung:
Separate Limit-Keys pro User+Model in der blocking shared dict.
auth.lua muesste nach User-Aufloesung das Modell aus dem Request-Body lesen
(erfordert Body-Read in access_by_lua, bevor handler.lua laeuft).

**Tradeoff:** Body-Parsing in auth.lua erhoeht Latenz und Komplexitaet.
Alternative: Limits nur pro User, Modell-Granularitaet ueber Grafana-Alerts.

## OpenAI + OpenRouter Provider (Completion)

Stubs existieren in `providers/openai.lua` und `providers/openrouter.lua`.
Fehlend: SSE-Token-Parsing (OpenAI-Format: `usage` im letzten `data: [DONE]`-Event),
Env-Vars in docker-compose + nginx.conf, End-to-end-Tests.

## Cost-Based Limits

Statt Token-Count direkt Dollar-Limits setzen. Pricing-Tabelle ist bereits
in metrics.lua vorhanden — kann als shared Module von auth.lua importiert werden.

## Multi-Key per User

Aktuell 1:1 Mapping Key->User in keys.json. Fuer Teams: mehrere Keys pro User
mit unterschiedlichen Berechtigungen (z.B. "read-only"-Key der nur Haiku darf).
