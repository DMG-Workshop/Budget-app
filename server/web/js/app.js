// Coldwater's web UI. No framework, no build step — an appliance should be
// serveable from a directory of files and debuggable in view-source.

const $ = (id) => document.getElementById(id);

const PROVIDERS = [
  ['anthropic', 'Claude', 'Reads the PDF directly. Best on table-heavy statements.'],
  ['gemini', 'Gemini', 'Reads the PDF directly. Cheap and fast.'],
  ['openai', 'OpenAI', 'Text only — the statement is extracted here first.'],
  ['local', 'Ollama / LM Studio', 'Runs on your own machine. Nothing leaves your network.'],
];

const state = {
  config: null,
  outcome: null,
  dismissed: new Set(),
};

// --- helpers ---------------------------------------------------------

const money = (value, currency) => {
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency',
      currency: currency || 'USD',
    }).format(value);
  } catch {
    // A statement can name a currency Intl does not know. Printing the code
    // is honest; printing a dollar sign on a sterling statement is not.
    return `${currency} ${value.toFixed(2)}`;
  }
};

const signedMoney = (value, currency) =>
  (value > 0 ? '+' : '') + money(value, currency);

const percent = (fraction) => `${Math.round(fraction * 100)}%`;

const formatPeriod = (start, end) => {
  const from = new Date(start);
  const to = new Date(end);
  if (Number.isNaN(+from) || Number.isNaN(+to)) return `${start} – ${end}`;
  const day = { day: 'numeric', month: 'short' };
  const full = { day: 'numeric', month: 'short', year: 'numeric' };
  const sameYear = from.getFullYear() === to.getFullYear();
  return `${from.toLocaleDateString(undefined, sameYear ? day : full)} – ${to.toLocaleDateString(undefined, full)}`;
};

const show = (...ids) => {
  for (const id of ['upload', 'working', 'failure', 'results', 'history']) {
    $(id).hidden = !ids.includes(id);
  }
};

async function api(path, options = {}) {
  const response = await fetch(path, options);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(body.detail || `Request failed (${response.status})`);
    error.body = body;
    throw error;
  }
  return body;
}

// --- config ----------------------------------------------------------

async function loadConfig() {
  state.config = await api('/api/config');
  const { kind, model, has_api_key, needs_api_key } = state.config;
  const label = PROVIDERS.find(([k]) => k === kind)?.[1] ?? kind;

  $('provider-line').textContent =
    needs_api_key && !has_api_key
      ? `${label} is selected but has no API key. Open settings.`
      : `Auditing with ${label} · ${model}`;

  $('history-button').hidden = !state.config.keep_history;
}

function renderProviderChoices() {
  $('provider-choices').innerHTML = PROVIDERS.map(
    ([kind, label, blurb]) => `
      <label>
        <input type="radio" name="kind" value="${kind}">
        <span>
          <span class="choice-title">${label}</span>
          <span class="muted small">${blurb}</span>
        </span>
      </label>`,
  ).join('');

  for (const input of document.querySelectorAll('input[name=kind]')) {
    input.addEventListener('change', () => {
      $('local-fields').hidden = input.value !== 'local';
      $('cfg-key-label').hidden = input.value === 'local';
    });
  }
}

function fillSettings() {
  const c = state.config;
  const radio = document.querySelector(`input[name=kind][value="${c.kind}"]`);
  if (radio) radio.checked = true;
  $('cfg-model').value = c.model ?? '';
  $('cfg-key').value = '';
  $('cfg-key').placeholder = c.has_api_key ? 'unchanged' : 'not set';
  $('cfg-flavor').value = c.flavor ?? 'ollama';
  $('cfg-base-url').value = c.base_url ?? '';
  $('cfg-currency').value = c.currency_hint ?? '';
  $('cfg-context').value = c.user_context ?? '';
  $('cfg-history').checked = !!c.keep_history;
  $('local-fields').hidden = c.kind !== 'local';
  $('cfg-key-label').hidden = c.kind === 'local';
  $('test-result').hidden = true;
}

function settingsPayload() {
  const payload = {
    kind: document.querySelector('input[name=kind]:checked')?.value,
    model: $('cfg-model').value.trim(),
    flavor: $('cfg-flavor').value,
    base_url: $('cfg-base-url').value.trim(),
    currency_hint: $('cfg-currency').value.trim().toUpperCase(),
    user_context: $('cfg-context').value.trim(),
    keep_history: $('cfg-history').checked,
  };
  // An empty box means "leave the stored key alone", not "delete it".
  const key = $('cfg-key').value;
  if (key !== '') payload.api_key = key;
  return payload;
}

// --- the audit -------------------------------------------------------

async function runAudit(file) {
  show('working');
  $('working-step').textContent = `Reading ${file.name}…`;

  const body = new FormData();
  body.append('file', file);

  try {
    const label = PROVIDERS.find(([k]) => k === state.config?.kind)?.[1] ?? 'the model';
    $('working-step').textContent =
      state.config?.kind === 'local'
        ? 'Auditing on your own machine. A cold model can take a minute.'
        : `Auditing with ${label}…`;

    const outcome = await api('/api/audit', { method: 'POST', body });
    state.outcome = outcome;
    state.dismissed = new Set();
    renderResults();
    show('results');
    if (state.config?.keep_history) $('history-button').hidden = false;
  } catch (error) {
    renderFailure(error);
    show('failure');
  }
}

function renderFailure(error) {
  $('failure-title').textContent = error.message;
  const parts = [];
  if (error.body?.violations?.length) parts.push(error.body.violations.join('\n'));
  if (error.body?.provider_message) parts.push(error.body.provider_message);
  if (error.body?.extraction_failure) parts.push(error.body.extraction_failure);
  if (error.body?.last_response) parts.push(`The model replied:\n${error.body.last_response}`);

  const detail = parts.join('\n\n').trim();
  $('failure-details').hidden = detail === '';
  $('failure-detail').textContent = detail;
}

// --- rendering -------------------------------------------------------

function renderResults() {
  const { report, arithmetic, breakdown, route_reason } = state.outcome;
  const currency = report.currency;

  // Reality check
  const deficit = report.is_deficit;
  const chip = $('verdict-chip');
  chip.textContent = deficit ? 'Deficit' : 'Surplus';
  chip.className = `chip ${deficit ? 'deficit' : 'surplus'}`;
  $('period').textContent = formatPeriod(report.period_start, report.period_end);
  $('net-cashflow').textContent = signedMoney(report.net_cashflow, currency);
  $('net-cashflow').style.color = deficit ? 'var(--critical)' : 'var(--good)';
  $('in-out').textContent =
    `${money(report.total_net_income, currency)} in · ${money(report.total_expenses, currency)} out`;
  $('summary').textContent = report.harsh_audit_summary;

  const cut = report.wasteful_leaks
    .filter((leak) => state.dismissed.has(leak.label))
    .reduce((sum, leak) => sum + leak.annual_cost, 0);
  $('cut-so-far').hidden = cut <= 0;
  $('cut-so-far').textContent = `Cut so far: ${money(cut, currency)} a year.`;

  renderTrust(arithmetic);
  renderBreakdown(breakdown, currency);
  renderCutList(report, currency);

  $('action-plan').hidden = report.action_plan.length === 0;
  $('action-steps').innerHTML = report.action_plan
    .map((step) => `<li>${escapeHtml(step)}</li>`)
    .join('');

  $('route-reason').textContent = route_reason;
}

function renderTrust(arithmetic) {
  const problems = arithmetic.findings.filter((f) => f.severity !== 'info');
  const unverified = state.outcome.unverified_evidence ?? [];

  const messages = problems.map((f) => f.message);
  if (unverified.length) {
    messages.push(
      `These figures cite a transaction that could not be found in the statement: ${unverified.join(', ')}.`,
    );
  }

  const card = $('trust');
  card.hidden = messages.length === 0;
  if (card.hidden) return;

  card.classList.toggle('error', arithmetic.has_errors);
  $('trust-title').textContent = arithmetic.has_errors
    ? "The model's arithmetic does not add up"
    : 'Some of this audit could not be verified';
  $('trust-list').innerHTML = messages
    .map((m) => `<li>${escapeHtml(m)}</li>`)
    .join('');
}

const SEGMENTS = [
  ['needs', 'Needs', 'var(--needs)', false],
  ['wants', 'Wants', 'var(--wants)', false],
  ['leaks', 'Wasteful', 'var(--leaks)', true],
];

function renderBreakdown(breakdown, currency) {
  $('breakdown-total').textContent = money(breakdown.total, currency);

  const present = SEGMENTS
    .map(([key, label, color, isLeak]) => ({
      key, label, color, isLeak,
      amount: breakdown[key],
      share: breakdown.total > 0 ? breakdown[key] / breakdown.total : 0,
    }))
    .filter((s) => s.amount > 0);

  // The bar. A 2px gap in a 100-unit viewBox at ~660px wide is about 0.3
  // units; the gap is a real surface-coloured strip so adjacent fills never
  // blend, which is what makes the palette's CVD advisory acceptable.
  const GAP = 0.4;
  const usable = 100 - GAP * Math.max(0, present.length - 1);
  let x = 0;
  const parts = present.map((segment, i) => {
    const width = usable * segment.share;
    const first = i === 0;
    const last = i === present.length - 1;
    const rect = `<rect x="${x.toFixed(3)}" y="0" width="${Math.max(width, 0).toFixed(3)}"
        height="6" fill="${segment.color}"
        rx="${first || last ? 0.8 : 0}" ry="0.8">
        <title>${segment.label}: ${money(segment.amount, currency)} (${percent(segment.share)})</title>
      </rect>`;
    x += width + GAP;
    return rect;
  });
  $('bar').innerHTML = parts.join('');
  $('bar-desc').textContent =
    'Spending breakdown. ' +
    present.map((s) => `${s.label}: ${percent(s.share)}`).join(', ') + '.';

  // Direct labels. Not optional — see the note at the top of app.css.
  $('legend').innerHTML = present
    .map(
      (s) => `<li>
        <span class="swatch" style="background:${s.color}"></span>
        ${s.isLeak ? `<span class="leak-icon" style="color:${s.color}" aria-hidden="true">&#9888;</span>` : ''}
        <span class="legend-label">${s.label}</span>
        <span class="legend-share">${percent(s.share)}</span>
        <span class="legend-value">${money(s.amount, currency)}</span>
      </li>`,
    )
    .join('');

  $('breakdown-table').querySelector('tbody').innerHTML = present
    .map(
      (s) => `<tr><td>${s.label}</td><td>${percent(s.share)}</td>
        <td>${money(s.amount, currency)}</td></tr>`,
    )
    .join('');

  const orphaned = breakdown.unattributed_leaks;
  $('unattributed').hidden = !(orphaned > 0);
  $('unattributed').textContent =
    `${money(orphaned, currency)} of flagged waste matched no line item and is not shown in the bar.`;
}

function renderCutList(report, currency) {
  const unverified = new Set(state.outcome.unverified_evidence ?? []);
  const remaining = report.wasteful_leaks.filter((l) => !state.dismissed.has(l.label));
  const list = $('cut-list');

  if (remaining.length === 0) {
    list.innerHTML = `<article class="card"><p>${
      state.dismissed.size === 0
        ? 'No waste was flagged in this statement. That is rarer than you think.'
        : 'That is the whole list. Now actually cancel them.'
    }</p></article>`;
    return;
  }

  list.innerHTML = remaining
    .map(
      (leak) => `
      <article class="card leak">
        <div class="row">
          <h3>${escapeHtml(leak.label)}</h3>
          <span class="spacer"></span>
          <span class="severity ${leak.severity}">${leak.severity}</span>
        </div>
        <p class="costs money">${money(leak.amount, currency)} this period ·
          ${money(leak.annual_cost, currency)} a year</p>
        <p class="verdict">${escapeHtml(leak.verdict)}</p>
        ${unverified.has(leak.label)
          ? '<p class="unverified">Could not find this transaction in the statement.</p>'
          : ''}
        <button class="ghost cut" type="button" data-label="${escapeAttr(leak.label)}">
          I have cut this
        </button>
      </article>`,
    )
    .join('');

  for (const button of list.querySelectorAll('.cut')) {
    button.addEventListener('click', () => {
      state.dismissed.add(button.dataset.label);
      renderResults();
    });
  }
}

// --- history ---------------------------------------------------------

async function openHistory() {
  const { audits } = await api('/api/audits');
  $('history-list').innerHTML = audits.length
    ? audits
        .map(
          (a) => `<li>
            <div>
              <div>${escapeHtml(a.filename)}</div>
              <div class="when">${new Date(a.created_at).toLocaleString()} · ${a.provider}</div>
            </div>
            <span class="spacer"></span>
            <span class="money">${money(a.net_cashflow, a.currency)}</span>
            <button class="ghost" type="button" data-open="${a.id}">Open</button>
          </li>`,
        )
        .join('')
    : '<li class="muted">Nothing stored yet.</li>';

  for (const button of $('history-list').querySelectorAll('[data-open]')) {
    button.addEventListener('click', async () => {
      state.outcome = await api(`/api/audits/${button.dataset.open}`);
      state.dismissed = new Set();
      renderResults();
      show('results');
    });
  }
  show('history');
}

// --- escaping --------------------------------------------------------

// Every string rendered here came from a language model reading a document
// the user supplied. It is not trusted markup.
function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll('"', '&quot;').replaceAll("'", '&#39;');
}

// --- wiring ----------------------------------------------------------

function init() {
  renderProviderChoices();
  loadConfig().catch((e) => {
    $('provider-line').textContent = `Could not read settings: ${e.message}`;
  });

  const input = $('file-input');
  const zone = $('dropzone');

  zone.addEventListener('click', () => input.click());
  zone.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); input.click(); }
  });
  input.addEventListener('change', () => {
    if (input.files?.[0]) runAudit(input.files[0]);
  });

  for (const event of ['dragenter', 'dragover']) {
    zone.addEventListener(event, (e) => { e.preventDefault(); zone.classList.add('over'); });
  }
  for (const event of ['dragleave', 'drop']) {
    zone.addEventListener(event, () => zone.classList.remove('over'));
  }
  zone.addEventListener('drop', (e) => {
    e.preventDefault();
    const file = e.dataTransfer?.files?.[0];
    if (file) runAudit(file);
  });

  $('again').addEventListener('click', () => { show('upload'); input.value = ''; });
  $('failure-retry').addEventListener('click', () => { show('upload'); input.value = ''; });
  $('failure-settings').addEventListener('click', () => $('settings').showModal());

  $('settings-button').addEventListener('click', () => { fillSettings(); $('settings').showModal(); });
  $('history-button').addEventListener('click', () => openHistory().catch(() => {}));
  $('history-back').addEventListener('click', () => show('upload'));
  $('history-clear').addEventListener('click', async () => {
    if (!confirm('Delete every stored audit? This cannot be undone.')) return;
    await api('/api/audits', { method: 'DELETE' });
    openHistory();
  });

  $('settings-form').addEventListener('submit', async (e) => {
    if (e.submitter?.value !== 'save') return;
    try {
      state.config = await api('/api/config', {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(settingsPayload()),
      });
      await loadConfig();
    } catch (error) {
      alert(error.message);
    }
  });

  $('cfg-test').addEventListener('click', async () => {
    const box = $('test-result');
    box.hidden = false;
    box.className = 'test-result';
    box.textContent = 'Saving and testing…';
    try {
      await api('/api/config', {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(settingsPayload()),
      });
      const result = await api('/api/config/test', { method: 'POST' });
      box.className = `test-result ${result.ok ? 'ok' : 'bad'}`;
      box.textContent = [result.summary, result.detail].filter(Boolean).join(' — ');
      await loadConfig();
    } catch (error) {
      box.className = 'test-result bad';
      box.textContent = error.message;
    }
  });

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }
}

init();
