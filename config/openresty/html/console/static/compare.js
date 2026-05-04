// compare.js: monthly-cost-vs-competitors comparison page.
// Pulls the active provider config + live OpenRouter / llm-prices data, then
// computes what 7d-projected monthly token usage would cost at each
// competitor's prices.

let providersData = null;
let orModelsData = null;
let llmPricesData = null;
let monthlyTokensByPattern = null;

async function loadProviders() {
  try {
    const r = await fetch('/internal/admin/providers');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    providersData = await r.json();
  } catch (e) {
    providersData = null;
    toast('providers config unavailable: ' + e.message, true);
  }
}

async function loadOpenRouterModels() {
  try {
    const r = await fetch('/internal/admin/openrouter-models');
    if (!r.ok) return;
    orModelsData = await r.json();
    if (orModelsData?.models && providersData?.comparison_models) {
      const orMap = {};
      for (const m of orModelsData.models) orMap[m.id] = m;
      for (const cm of providersData.comparison_models) {
        if (!cm.openrouter_id) continue;
        const live = orMap[cm.openrouter_id];
        if (live) {
          cm.input = live.input;
          cm.output = live.output;
          cm._live = true;
          cm._or_live = true;
        }
      }
    }
  } catch (e) { orModelsData = null; }
}

async function loadLlmPrices() {
  try {
    const r = await fetch('/internal/admin/llm-prices');
    if (!r.ok) return;
    llmPricesData = await r.json();
    if (llmPricesData?.prices && providersData?.comparison_models) {
      const priceMap = {};
      for (const p of llmPricesData.prices) priceMap[p.id] = p;
      for (const cm of providersData.comparison_models) {
        if (cm._or_live) continue;
        const live = priceMap[cm.id];
        if (live) {
          cm.input = live.input;
          cm.output = live.output;
          if (live.input_cached !== null && live.input_cached !== undefined) cm.input_cached = live.input_cached;
          cm._live = true;
        }
      }
    }
  } catch (e) { /* fall back to static prices in providers.json */ }
}

async function fetchMonthlyProjection() {
  const vec = await promVector('sum by (model, type) (increase(gateii_tokens_total[7d])) / 7 * 30');
  if (!vec) return null;
  const byPattern = {};
  const active = providersData?.providers?.find(p => p.id === (providersData?.active_provider || 'anthropic'));
  const models = active?.models || [];
  for (const entry of vec) {
    const fullModel = entry.labels.model || '';
    const type = entry.labels.type || '';
    const lower = fullModel.toLowerCase();
    let pattern = fullModel;
    for (const pm of models) {
      if (lower.includes(pm.pattern)) { pattern = pm.pattern; break; }
    }
    if (!byPattern[pattern]) byPattern[pattern] = { input: 0, output: 0, cache_creation: 0, cache_read: 0 };
    byPattern[pattern][type] = (byPattern[pattern][type] || 0) + entry.value;
  }
  return byPattern;
}

function calcProviderCost(provider, tokensByPattern) {
  let total = 0;
  for (const pm of (provider.models || [])) {
    const usage = tokensByPattern[pm.pattern];
    if (!usage) continue;
    const cwm = provider.cache_write_multiplier || 1.25;
    const crm = provider.cache_read_multiplier || 0.1;
    total += (usage.input || 0) * pm.input / 1e6;
    total += (usage.output || 0) * pm.output / 1e6;
    total += (usage.cache_creation || 0) * (pm.input * cwm) / 1e6;
    total += (usage.cache_read || 0) * (pm.input * crm) / 1e6;
  }
  return total;
}

function calcModelCost(model, totalIn, totalOut, totalCacheW, totalCacheR, activeCwm, activeCrm) {
  const cwm = model.cache_write_multiplier ?? activeCwm ?? 1.25;
  const crm = model.cache_read_multiplier ?? activeCrm ?? 0.1;
  const cacheReadPrice = model.input_cached !== undefined ? model.input_cached : model.input * crm;
  return totalIn * model.input / 1e6
    + totalOut * model.output / 1e6
    + totalCacheW * (model.input * cwm) / 1e6
    + totalCacheR * cacheReadPrice / 1e6;
}

function renderComparison() {
  const compPanel = $('comparison-panel');
  const compBody = $('comparison-body');
  const compSource = $('comp-source');
  if (!providersData || !providersData.providers) {
    compBody.innerHTML = '<div class="empty">providers config unavailable</div>';
    return;
  }
  const provider = providersData.providers.find(p => p.id === (providersData.active_provider || 'anthropic'));
  if (!provider) {
    compBody.innerHTML = '<div class="empty">active provider not found in providers.json</div>';
    return;
  }
  const compModels = providersData.comparison_models || [];
  const monthlyTok = monthlyTokensByPattern || {};

  let totalIn = 0, totalOut = 0, totalCacheW = 0, totalCacheR = 0;
  for (const u of Object.values(monthlyTok)) {
    totalIn += u.input || 0;
    totalOut += u.output || 0;
    totalCacheW += u.cache_creation || 0;
    totalCacheR += u.cache_read || 0;
  }
  const totalTokens = totalIn + totalOut + totalCacheW + totalCacheR;

  if (totalTokens === 0 || compModels.length === 0) {
    compBody.innerHTML = '<div class="empty">no token volume yet — comparison needs at least 1d of usage</div>';
    $('comp-tokens').textContent = '';
    return;
  }
  $('comp-tokens').textContent = `${fmt(totalTokens)} tokens/month (7d avg)`;

  const orLink = `<a href="https://openrouter.ai/models?categories=programming&fmt=cards&order=top-weekly" target="_blank">openrouter.ai</a>`;
  const llmLink = `<a href="https://github.com/simonw/llm-prices" target="_blank">simonw/llm-prices</a>`;
  const hasOrLive = compModels.some(cm => cm._or_live);
  const parts = [`Rankings: ${orLink} · top weekly programming` + (hasOrLive ? ' · prices live' : '')];
  parts.push(`Pricing data: ${llmLink}`);
  compSource.style.display = '';
  compSource.innerHTML = parts.join(' &nbsp;·&nbsp; ');

  const entries = compModels.map(cm => ({
    ...cm,
    total: calcModelCost(cm, totalIn, totalOut, totalCacheW, totalCacheR,
      provider.cache_write_multiplier, provider.cache_read_multiplier),
  }));
  entries.push({
    name: 'Your current mix',
    vendor: provider.name,
    total: calcProviderCost(provider, monthlyTok),
    _current: true,
  });

  entries.sort((a, b) => a.total - b.total);
  const maxCost = Math.max(...entries.map(e => e.total), 0.001);
  const minCost = Math.min(...entries.filter(e => e.total > 0).map(e => e.total), maxCost);

  compBody.innerHTML = entries.map(e => {
    const pct = Math.max(3, Math.round(e.total / maxCost * 100));
    const isCheapest = e.total === minCost && !e._current;
    const barClass = e._current ? 'mid' : isCheapest ? 'cheapest' : e.total >= maxCost * 0.8 ? 'expensive' : 'mid';
    const costClass = e._current ? '' : isCheapest ? 'comp-cheapest' : 'comp-expensive';
    const vendorBadge = e._current
      ? `<span class="comp-vendor comp-current">CURRENT</span>`
      : `<span class="comp-vendor">${esc(e.vendor)}</span>`;
    const liveIndicator = e._live ? ' *' : '';
    const rankBadge = (!e._current && e.or_rank != null)
      ? `<span class="comp-rank" title="OpenRouter coding rank">#${e.or_rank}</span>` : '';
    return `<div class="comp-row">
      <div class="comp-provider"><span>${esc(e.name)}${liveIndicator}</span>${vendorBadge}${rankBadge}</div>
      <div class="comp-bar-wrap"><div class="comp-bar ${barClass}" style="width:${pct}%"></div></div>
      <div class="comp-cost ${costClass}">${fmtUSD(e.total)}/mo</div>
    </div>`;
  }).join('');
}

async function refreshCompare() {
  await refreshHeader();
  try {
    if (!providersData) await loadProviders();
    await Promise.allSettled([loadOpenRouterModels(), loadLlmPrices()]);
    monthlyTokensByPattern = await fetchMonthlyProjection();
    renderComparison();
    $('last-refresh').textContent = new Date().toLocaleTimeString();
  } catch (e) {
    toast('refresh failed: ' + e.message, true);
  }
}

async function initCompare() {
  await window._initialAuth;
  $('btn-refresh').addEventListener('click', e => withBusy(e.currentTarget, refreshCompare));
  refreshCompare();
  pausableInterval(refreshCompare, 60000);
}
