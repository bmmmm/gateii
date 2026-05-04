// git.js: per-repo git-tracking config UI.
// Loads /internal/admin/git-tracking, lets user CRUD repos, PUTs back the
// full config. Validation happens server-side; this UI just collects fields.

const PLATFORM_LABELS = {
  forgejo: 'Forgejo',
  github: 'GitHub',
  gitlab: 'GitLab',
  gitea: 'Gitea',
  codeberg: 'Codeberg',
  bitbucket: 'Bitbucket',
  local: 'Local',
  other: 'Other',
};

let _config = { default_author: '', interval: 300, platform_authors: {}, repos: [] };
const PLATFORM_KEYS = ['forgejo', 'github', 'gitlab', 'codeberg', 'gitea', 'bitbucket'];

function platformBadge(platform) {
  if (!platform) return '';
  const label = PLATFORM_LABELS[platform] || platform;
  return `<span class="comp-vendor" title="platform">${esc(label)}</span>`;
}

function renderRepos() {
  const list = $('repos-list');
  $('repos-count').textContent = _config.repos.length;
  if (_config.repos.length === 0) {
    list.innerHTML = '<div class="empty">no repos tracked yet — add one below</div>';
    return;
  }
  list.innerHTML = _config.repos.map((r, i) => {
    const alias = r.alias || r.path.split('/').pop();
    const authorSub = r.author ? `author: ${esc(r.author)}` : '<span style="opacity:.6">default author</span>';
    return `<div class="user-row">
      <div class="user-info">
        <span class="user-name">${esc(alias)} ${platformBadge(r.platform)}</span>
        <span class="user-meta">${esc(r.path)} &middot; ${authorSub}</span>
      </div>
      <div class="user-actions">
        <button class="btn btn-danger" data-idx="${i}">Remove</button>
      </div>
    </div>`;
  }).join('');
}

async function loadConfig() {
  const data = await fetch('/internal/admin/git-tracking').then(r => r.json()).catch(() => null);
  if (!data) {
    toast('Failed to load git-tracking config', true);
    return;
  }
  _config = {
    default_author: data.default_author || '',
    interval: data.interval || 300,
    platform_authors: data.platform_authors && typeof data.platform_authors === 'object' ? data.platform_authors : {},
    repos: Array.isArray(data.repos) ? data.repos : [],
  };
  $('default-author').value = _config.default_author;
  $('interval').value = _config.interval;
  for (const k of PLATFORM_KEYS) {
    const el = $('pa-' + k);
    if (el) el.value = _config.platform_authors[k] || '';
  }
  renderRepos();
}

async function saveConfig() {
  const r = await fetch('/internal/admin/git-tracking', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(_config),
  });
  if (!r.ok) {
    const err = await r.json().catch(() => ({}));
    throw new Error(err.error || 'HTTP ' + r.status);
  }
}

async function saveSettings(ev) {
  _config.default_author = $('default-author').value.trim();
  const intv = parseInt($('interval').value, 10);
  if (isNaN(intv) || intv < 30) return toast('Interval must be ≥ 30 seconds', true);
  _config.interval = intv;
  // Collect platform_authors from the per-platform inputs; drop empty entries
  // so the JSON stays compact and the schema's "key must match pattern" check
  // doesn't fire on intentionally-blank ones.
  const pa = {};
  for (const k of PLATFORM_KEYS) {
    const v = ($('pa-' + k)?.value || '').trim();
    if (v) pa[k] = v;
  }
  _config.platform_authors = pa;
  await withBusy(ev?.currentTarget, async () => {
    try {
      await saveConfig();
      // Re-read so the form reflects whatever the server normalized
      // (trimmed whitespace, dropped duplicates, etc.) instead of the
      // input we just sent.
      await loadConfig();
      toast('Settings saved');
    } catch (e) { toast('Save failed: ' + e.message, true); }
  });
}

async function addRepo(ev) {
  const path = $('new-path').value.trim();
  const alias = $('new-alias').value.trim();
  const author = $('new-author').value.trim();
  const platform = $('new-platform').value;
  if (!path) return toast('Path required', true);
  if (!path.startsWith('/')) return toast('Path must be absolute', true);
  if (path.includes('..')) return toast('Path must not contain ".."', true);
  if (_config.repos.some(r => r.path === path)) return toast('Path already tracked', true);
  const entry = { path };
  if (alias) entry.alias = alias;
  if (author) entry.author = author;
  if (platform) entry.platform = platform;
  _config.repos.push(entry);
  await withBusy(ev?.currentTarget, async () => {
    try {
      await saveConfig();
      // Pull canonicalized state (server may default alias from path,
      // strip trailing slashes, etc.) so the rendered list matches storage.
      await loadConfig();
      toast('Added ' + (alias || path));
      $('new-path').value = ''; $('new-alias').value = ''; $('new-author').value = '';
      $('new-platform').value = '';
    } catch (e) {
      _config.repos.pop();
      toast('Add failed: ' + e.message, true);
      renderRepos();
    }
  });
}

async function removeRepo(btn, idx) {
  const removed = _config.repos[idx];
  _config.repos.splice(idx, 1);
  await withBusy(btn, async () => {
    try {
      await saveConfig();
      await loadConfig();   // re-sync to canonical server state
      toast('Removed ' + (removed.alias || removed.path));
    } catch (e) {
      _config.repos.splice(idx, 0, removed);
      toast('Remove failed: ' + e.message, true);
      renderRepos();
    }
  });
}

async function refresh() {
  await refreshHeader();
  try {
    await loadConfig();
    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (e) {
    toast('refresh failed: ' + e.message, true);
  }
}

async function initGit() {
  await window._initialAuth;
  $('btn-save-settings').addEventListener('click', saveSettings);
  $('btn-add-repo').addEventListener('click', addRepo);
  $('repos-list').addEventListener('click', e => {
    const btn = e.target.closest('button[data-idx]');
    if (!btn) return;
    removeRepo(btn, parseInt(btn.dataset.idx, 10));
  });
  refresh();
  pausableInterval(refresh, 30000);
}
