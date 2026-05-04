// agents.js: live view of local omlx-backed agent runs.
// Polls /internal/admin/agents every 2 s, renders active card + history table.

const POLL_MS = 2000;

function relTime(epoch) {
  if (!epoch) return '?';
  const dt = Math.max(0, Math.floor(Date.now() / 1000 - epoch));
  if (dt < 60)    return dt + 's ago';
  if (dt < 3600)  return Math.floor(dt / 60) + 'm ago';
  if (dt < 86400) return Math.floor(dt / 3600) + 'h ago';
  return Math.floor(dt / 86400) + 'd ago';
}

function shortModel(m) {
  if (!m) return '?';
  return m
    .replace(/-MLX-4bit$/, '')
    .replace(/-A3B-4bit$/, '-A3B')
    .replace(/-a4b-it-4bit$/, '');
}

function renderActive(active) {
  const area = $('active-area');
  const count = $('active-count');
  if (!active || !active.task) {
    area.innerHTML = '<div class="empty">no agent currently running</div>';
    count.textContent = '0';
    return;
  }
  count.textContent = '1';
  const elapsed = Math.max(0, Math.floor(Date.now() / 1000 - (active.started_epoch || 0)));
  const cwd = (active.parent && active.parent.cwd) || '?';
  const ppid = (active.parent && active.parent.ppid) || '?';
  const pcmd = (active.parent && active.parent.parent_cmd) || '';
  area.innerHTML = `
    <div class="agent-card">
      <div class="pulse"></div>
      <div style="flex:1;min-width:0">
        <div style="display:flex;align-items:baseline;gap:10px;margin-bottom:4px">
          <span style="font-weight:600;font-size:14px">${esc(active.task)}</span>
          <span style="color:var(--dim);font-family:ui-monospace,monospace;font-size:12px">${esc(shortModel(active.model))}</span>
          <span style="margin-left:auto;color:var(--dim);font-size:12px">${elapsed}s · pid ${esc(active.pid || '?')}</span>
        </div>
        <div class="agent-meta">
          <b>cwd</b>        <span>${esc(cwd)}</span>
          <b>parent pid</b> <span>${esc(ppid)}${pcmd ? ' &mdash; <span style="color:var(--dim)">' + esc(pcmd) + '</span>' : ''}</span>
        </div>
        ${active.prompt_preview ? `<div class="agent-preview">→ ${esc(active.prompt_preview)}</div>` : ''}
      </div>
    </div>`;
}

function renderHistory(recent) {
  const area = $('history-area');
  const count = $('recent-count');
  if (!recent || recent.length === 0) {
    area.innerHTML = '<div class="empty">no history yet — run <code>scripts/agent run &lt;task&gt;</code></div>';
    count.textContent = '0';
    return;
  }
  count.textContent = String(recent.length);
  // Newest first
  const rows = recent.slice().reverse().map(r => {
    const exitCls = (r.exit === 0) ? 'exit-ok' : 'exit-bad';
    const exitTxt = (r.exit === 0) ? '✓' : ('✗' + r.exit);
    const tokens = (r.tokens_in != null || r.tokens_out != null)
      ? `${r.tokens_in || 0}→${r.tokens_out || 0}` : '-';
    const lat = (r.latency_s != null) ? r.latency_s.toFixed(2) + 's' : '-';
    const out = r.output_preview || (r.error ? '⚠ ' + r.error : '');
    return `<tr>
      <td>${esc(r.started_at || '?')}</td>
      <td><b>${esc(r.task || '?')}</b></td>
      <td style="color:var(--dim);font-family:ui-monospace,monospace">${esc(shortModel(r.model))}</td>
      <td class="num">${lat}</td>
      <td class="num">${tokens}</td>
      <td class="num ${exitCls}">${exitTxt}</td>
      <td class="preview-cell" title="${esc(out)}">${esc(out)}</td>
    </tr>`;
  }).join('');
  area.innerHTML = `<table class="hist-table">
    <thead><tr>
      <th>Time</th><th>Task</th><th>Model</th><th>Latency</th><th>Tokens (in→out)</th><th>Exit</th><th>Output</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table>`;
}

function renderRouting(routing) {
  const area = $('routing-area');
  const meta = $('routing-meta');
  if (!routing || !routing.routes) {
    area.innerHTML = '<div class="empty">routing not yet generated — run <code>scripts/agent-bench</code></div>';
    meta.textContent = 'no routing.json yet';
    return;
  }
  meta.textContent = `generated ${routing.generated_at || '?'} · default ${shortModel(routing.default_model)}`;
  const tasks = Object.keys(routing.routes).sort();
  area.innerHTML = tasks.map(t => {
    const r = routing.routes[t];
    const passPct = Math.round((r.pass_rate || 0) * 100);
    const passCls = passPct === 100 ? '' : (passPct >= 50 ? 'partial' : 'fail');
    return `<div class="routing-row">
      <span class="task">${esc(t)}</span>
      <span class="model">${esc(shortModel(r.model))} <span style="opacity:.6">· max ${r.max_tokens || '?'}t · p50 ${(r.latency_p50 || 0).toFixed(2)}s</span></span>
      <span class="pass ${passCls}">${passPct}%</span>
    </div>`;
  }).join('');
}

let _lastOk = 0;
async function pollAgents() {
  try {
    const r = await fetch('/internal/admin/agents');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    renderActive(data.active);
    renderHistory(data.recent || []);
    renderRouting(data.routing);
    _lastOk = Date.now();
    const pill = $('status-pill'), txt = $('status-text');
    if (pill && txt) {
      pill.classList.remove('offline');
      pill.classList.add('online');
      txt.textContent = 'live';
    }
    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (err) {
    const pill = $('status-pill'), txt = $('status-text');
    if (pill && txt) {
      pill.classList.remove('online');
      pill.classList.add('offline');
      txt.textContent = 'reconnecting...';
    }
  }
}

function initAgents() {
  pollAgents();
  setInterval(pollAgents, POLL_MS);
}
