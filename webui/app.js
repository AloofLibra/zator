const state = {
  locks: [],
  status: null,
  strategyChecks: {},
  tlsBlobSettings: null,
  wgBlobSettings: null,
  wgStateSettings: null,
  fallbackSettings: null,
  udpGamesSettings: null,
  modeSettings: {},
  ports: null,
  provider: null,
  backups: null,
  domains: { netrogat: null, custom_rkn: null, substring: null, netrogat_substring: null },
  activeSubview: 'netrogat',
};

const views = {
  status: document.getElementById('view-status'),
  strategies: document.getElementById('view-strategies'),
  domains: document.getElementById('view-domains'),
  settings: document.getElementById('view-settings'),
};

const toastRegion = document.getElementById('toast-region');
let activeToast = null;
let activeToastTimer = 0;

function dismissToast() {
  if (!activeToast) return;
  window.clearTimeout(activeToastTimer);
  const node = activeToast;
  activeToast = null;
  node.classList.remove('is-visible');
  const removeNode = () => node.remove();
  node.addEventListener('transitionend', removeNode, { once: true });
  window.setTimeout(removeNode, 300);
}

function showToast(message, type = 'success') {
  if (!toastRegion) return;
  if (activeToast) {
    activeToast.remove();
    activeToast = null;
  }
  window.clearTimeout(activeToastTimer);

  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  if (type === 'error') {
    toast.setAttribute('role', 'alert');
  }

  const msg = document.createElement('div');
  msg.className = 'toast-message';
  msg.textContent = message;
  toast.appendChild(msg);

  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'toast-close';
  close.setAttribute('aria-label', 'Закрыть уведомление');
  close.textContent = '×';
  close.addEventListener('click', dismissToast);
  toast.appendChild(close);

  toastRegion.appendChild(toast);
  activeToast = toast;

  requestAnimationFrame(() => toast.classList.add('is-visible'));

  // ошибки 8 секунд, обычное уведомление три с половиной
  const duration = type === 'error' ? 8000 : 3500;
  activeToastTimer = window.setTimeout(dismissToast, duration);
}

// Переиспользуемое модальное окно подтверждения — замена window.confirm.
// Возвращает Promise<boolean>: true — подтверждено, false — отменено.
// Поддерживает Escape (отмена), Enter (подтверждение) и клик по фону (отмена).
function confirmDialog({
  title,
  message = '',
  confirmText = 'Подтвердить',
  cancelText = 'Отмена',
  danger = false,
} = {}) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');

    const card = document.createElement('div');
    card.className = 'modal-card';

    const headingId = 'modal-title-' + Math.random().toString(36).slice(2, 9);
    const heading = document.createElement('h3');
    heading.className = 'modal-title';
    heading.id = headingId;
    heading.textContent = title;
    overlay.setAttribute('aria-labelledby', headingId);
    card.appendChild(heading);

    if (message) {
      const parts = (Array.isArray(message) ? message : [message]).filter(Boolean);
      parts.forEach((part) => {
        const msg = document.createElement('p');
        msg.className = 'modal-message';
        msg.textContent = part;
        card.appendChild(msg);
      });
    }

    const actions = document.createElement('div');
    actions.className = 'modal-actions';

    const cancelBtn = document.createElement('button');
    cancelBtn.type = 'button';
    cancelBtn.className = 'ghost modal-cancel';
    cancelBtn.textContent = cancelText;

    const confirmBtn = document.createElement('button');
    confirmBtn.type = 'button';
    confirmBtn.className = danger ? 'danger modal-confirm' : 'primary modal-confirm';
    confirmBtn.textContent = confirmText;

    actions.appendChild(cancelBtn);
    actions.appendChild(confirmBtn);
    card.appendChild(actions);
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      overlay.classList.remove('is-visible');
      const cleanup = () => overlay.remove();
      overlay.addEventListener('transitionend', cleanup, { once: true });
      window.setTimeout(cleanup, 240);
      document.removeEventListener('keydown', onKeydown, true);
      resolve(result);
    };

    const onKeydown = (event) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        finish(false);
      } else if (event.key === 'Enter') {
        event.preventDefault();
        finish(true);
      }
    };

    cancelBtn.addEventListener('click', () => finish(false));
    confirmBtn.addEventListener('click', () => finish(true));
    overlay.addEventListener('click', (event) => {
      if (event.target === overlay) finish(false);
    });
    document.addEventListener('keydown', onKeydown, true);

    requestAnimationFrame(() => overlay.classList.add('is-visible'));
    confirmBtn.focus();
  });
}

let activeOperation = false;

const ACTION_SELECTORS = [
  '#toggle-service',
  '#restart-service',
  '#refresh-status',
  '#run-check',
  '#refresh-locks',
  '#refresh-settings',
  '#refresh-domains',
  '#strategy-cards .lock-form button[type="submit"]',
  '#strategy-cards .lock-form .clear-lock',
  '#tls-blob-form button[type="submit"]',
  '#wg-blob-form button[type="submit"]',
  '#fallback-state-form button[type="submit"]',
  '#udp-games-form button[type="submit"]',
  '#auto-mode-form button[type="submit"]',
  '#hostlist-form button[type="submit"]',
  '#rst-guard-form button[type="submit"]',
  '#reasm-form button[type="submit"]',
  '#quic443-form button[type="submit"]',
  '#ports-tcp-form button[type="submit"]',
  '#ports-udp-form button[type="submit"]',
  '.port-remove',
  '#provider-form button[type="submit"]',
  '#provider-redetect-btn',
  '#backup-create-btn',
  '#backup-import-btn',
  '#backup-items .remove-btn',
  '#backup-items .backups-toggle',
  '.tab',
  '.subtab',
  '#open-strategies',
  '#domain-add-form button[type="submit"]',
  '#domain-import-btn',
  '#domain-copy-btn',
  '#domain-clear-btn',
  '#domain-items .remove-btn',
  '#domain-items .trial-btn',
  '#domain-items .trial-save',
  '#domain-items .trial-next',
  '#domain-items .trial-cancel',
  '#domain-items .trial-step',
];

function getActionControls() {
  return document.querySelectorAll(ACTION_SELECTORS.join(','));
}

function lockAllControls() {
  getActionControls().forEach((control) => {
    control.disabled = true;
  });
}

function unlockAllControls() {
  getActionControls().forEach((control) => {
    control.disabled = false;
  });
  renderServiceControls();
  document.querySelectorAll('#strategy-cards .lock-form').forEach(updateStrategyFormState);
  updateTlsBlobSubmit();
  updateWgSubmit();
  updateFallbackSubmit();
  updateUdpGamesSubmit();
  MODE_TOGGLES.forEach(updateModeSubmit);
  document.querySelectorAll('.ports-add-form').forEach(updatePortsSubmit);
  updateDomainsAddState();
  updateProviderSubmit();
}

function normalizeStrategyValue(raw) {
  const s = String(raw ?? '').trim();
  if (!/^[0-9]+$/.test(s)) return null;
  return s;
}

function updateStrategyFormState(form) {
  if (!form) return;
  const input = form.querySelector('input');
  const submit = form.querySelector('button[type="submit"]');
  const clear = form.querySelector('.clear-lock');
  if (!input || !submit) return;
  const saved = input.dataset.saved || '0';
  const current = normalizeStrategyValue(input.value);
  submit.disabled = current === null || current === saved;
  if (clear) {
    clear.disabled = saved === 'auto';
  }
}

function updateTlsBlobSubmit() {
  const select = document.getElementById('tls-blob-select');
  const form = document.getElementById('tls-blob-form');
  if (!select || !form) return;
  const submit = form.querySelector('button[type="submit"]');
  if (!submit) return;
  const saved = select.dataset.saved || '';
  submit.disabled = !select.value || select.value === saved;
}

function updateWgFieldsState() {
  const checkbox = document.getElementById('wg-state-toggle');
  if (!checkbox) return;
  const enabled = checkbox.checked;
  const select = document.getElementById('wg-blob-select');
  const repeatsInput = document.getElementById('wg-repeats-input');
  if (select) select.disabled = !enabled;
  if (repeatsInput) repeatsInput.disabled = !enabled;
  document.querySelectorAll('.step-wg-repeats').forEach((b) => { b.disabled = !enabled; });
}

function updateWgSubmit() {
  const select = document.getElementById('wg-blob-select');
  const repeatsInput = document.getElementById('wg-repeats-input');
  const checkbox = document.getElementById('wg-state-toggle');
  const form = document.getElementById('wg-blob-form');
  if (!select || !repeatsInput || !form) return;
  const submit = form.querySelector('button[type="submit"]');
  if (!submit) return;
  const enabled = checkbox ? checkbox.checked : true;
  const stateChanged = checkbox && (checkbox.dataset.saved || '0') !== (enabled ? '1' : '0');
  const savedBlob = select.dataset.saved || '';
  const savedRepeats = repeatsInput.dataset.saved || '';
  const blobChanged = select.value !== savedBlob;
  const repeatsChanged = String(repeatsInput.value).trim() !== savedRepeats;
  submit.disabled = !(stateChanged || (enabled && (blobChanged || repeatsChanged)));
}

function updateFallbackSubmit() {
  const stateForm = document.getElementById('fallback-state-form');
  if (stateForm) {
    const submit = stateForm.querySelector('button[type="submit"]');
    const checkbox = stateForm.querySelector('input[type="checkbox"]');
    if (submit && checkbox) {
      const saved = checkbox.dataset.saved || '0';
      const current = checkbox.checked ? '1' : '0';
      submit.disabled = current === saved;
    }
  }
}

function updateUdpGamesSubmit() {
  const form = document.getElementById('udp-games-form');
  if (!form) return;
  const submit = form.querySelector('button[type="submit"]');
  const checkbox = form.querySelector('input[type="checkbox"]');
  if (!submit || !checkbox) return;
  const saved = checkbox.dataset.saved || '0';
  const current = checkbox.checked ? '1' : '0';
  submit.disabled = current === saved;
}

function setBusy(element, busy) {
  if (!element) return;
  element.classList.toggle('is-busy', busy);
  element.disabled = busy;
  if (busy) {
    element.setAttribute('aria-busy', 'true');
  } else {
    element.removeAttribute('aria-busy');
  }
}

async function withBusy(element, task) {
  activeOperation = true;
  lockAllControls();
  setBusy(element, true);
  try {
    return await task();
  } finally {
    setBusy(element, false);
    activeOperation = false;
    unlockAllControls();
  }
}

async function api(path, options = {}) {
  const response = await fetch(path, options);
  let data = {};
  try {
    data = await response.json();
  } catch (_) {
    data = {};
  }
  if (!response.ok) {
    throw new Error(data.error || `HTTP ${response.status}`);
  }
  return data;
}

function applyTheme(theme) {
  const normalized = ['auto', 'light', 'dark'].includes(theme) ? theme : 'auto';
  document.documentElement.dataset.theme = normalized;
  const select = document.getElementById('theme-mode');
  if (select) {
    select.value = normalized;
  }
}

function initTheme() {
  let savedTheme = 'auto';
  try {
    savedTheme = localStorage.getItem('z2r-theme') || 'auto';
  } catch (_) {
    savedTheme = 'auto';
  }
  const select = document.getElementById('theme-mode');
  applyTheme(savedTheme);
  if (select) {
    select.addEventListener('change', () => {
      try {
        localStorage.setItem('z2r-theme', select.value);
      } catch (_) {
        // Theme still applies for the current session when storage is unavailable.
      }
      applyTheme(select.value);
    });
  }
}

function switchView(view) {
  if (activeOperation) return;
  Object.entries(views).forEach(([name, element]) => {
    element.classList.toggle('is-active', name === view);
  });
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.classList.toggle('is-active', tab.dataset.view === view);
  });
  if (view === 'domains') {
    document.querySelectorAll('.subtab').forEach((tab) => {
      tab.classList.toggle('is-active', tab.dataset.subview === state.activeSubview);
    });
    refreshDomains().catch((e) => showToast(e.message, 'error'));
  }
}

function renderServiceControls() {
  const toggleButton = document.getElementById('toggle-service');
  const restartButton = document.getElementById('restart-service');
  if (!toggleButton || !restartButton || !state.status) return;

  const running = Boolean(state.status.zapret2_running);
  toggleButton.dataset.action = running ? 'stop' : 'start';
  toggleButton.textContent = running ? 'Остановить zapret2' : 'Включить zapret2';
  toggleButton.classList.toggle('is-stop', running);
  toggleButton.classList.toggle('is-start', !running);

  restartButton.disabled = !running;
  restartButton.title = running ? 'Перезапустить zapret2' : 'zapret2 остановлен';
  restartButton.setAttribute('aria-label', restartButton.title);

  const serviceControl = toggleButton.closest('.service-control');
  if (serviceControl) {
    serviceControl.classList.toggle('is-running', running);
  }
}

function renderStatus() {
  if (!state.status) return;
  renderServiceControls();

  const statusCards = document.getElementById('status-cards');
  const statusProfiles = document.getElementById('status-profiles');
  const statTemplate = document.getElementById('status-card-template');
  const profileTemplate = document.getElementById('status-profile-template');

  statusCards.innerHTML = '';
  statusProfiles.innerHTML = '';

  const providerRaw = String(state.status.provider ?? '');
  const providerCut = providerRaw.indexOf(' - ');
  const providerName = providerCut > 0 ? providerRaw.slice(0, providerCut) : providerRaw;
  const providerCity = providerCut > 0 ? providerRaw.slice(providerCut + 3) : '';

  const cards = [
    ['zapret2', state.status.zapret2_running ? 'Запущен' : 'Остановлен', state.status.zapret2_running ? 'ok' : 'bad'],
    ['Локи стратегий', state.status.strategy_locks_status],
    ['Авторотация', state.status.auto_mode, state.status.auto_mode === 'включен' ? 'ok' : ''],
    ['Фильтр', state.status.hostlist_mode],
    ['FW', state.status.fwtype],
    ['Offload', state.status.flowoffload],
    ['TLS blob', state.status.tls_blob_mode],
    ['WireGuard', state.status.wireguard, state.status.wireguard === 'включено' ? 'ok' : ''],
    ['RST guard', state.status.rst_guard, state.status.rst_guard === 'включен' ? 'ok' : ''],
    ['Провайдер', providerName, '', providerCity],
  ];

  cards.forEach(([label, value, stateClass, subText]) => {
    const node = statTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector('.label').textContent = label;
    const valueEl = node.querySelector('.value');
    valueEl.textContent = value ?? '—';
    if (stateClass) valueEl.classList.add(stateClass);
    if (String(valueEl.textContent).length > 18) valueEl.classList.add('is-long');
    if (subText) {
      const subEl = node.querySelector('.value-sub');
      subEl.textContent = subText;
      subEl.hidden = false;
    }
    statusCards.appendChild(node);
  });

  const profiles = Array.isArray(state.status.profiles) ? state.status.profiles : [];
  profiles.forEach((profile) => {
    const node = profileTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector('h3').textContent = profile.label;
    node.querySelector('.desc').textContent = profile.description;
    renderCurrentLock(node.querySelector('.current-lock'), profile.current_lock);
    statusProfiles.appendChild(node);
  });
}

function renderCurrentLock(el, value) {
  if (!el) return;
  const lock = String(value ?? '0');
  el.classList.remove('bad');
  if (lock === '0') {
    el.textContent = '0 (выключено)';
    el.classList.add('bad');
  } else {
    el.textContent = lock === 'auto' ? 'def' : lock;
  }
}

const FALLBACK_CHECK_HINT = 'Безразборный режим: быстрая проверка неприменима (применяется ко всем доменам).';
const UDP_GAMES_CHECK_HINT = 'Игровой UDP: быстрая проверка неприменима (широкий диапазон портов).';
const AUTO_MODE_GATED_PROFILES = [1, 2, 3, 4];

function isAutoModeGated(profile) {
  return AUTO_MODE_GATED_PROFILES.includes(Number(profile.profile)) &&
    state.status?.auto_mode === 'включен';
}

function isProfileGated(profile) {
  if (isAutoModeGated(profile)) return true;
  if (profile.is_fallback && !profile.fallback_enabled) return true;
  if (profile.is_udp_games && !profile.udp_games_enabled) return true;
  return false;
}

function gatedReason(profile) {
  if (isAutoModeGated(profile)) {
    return 'Пока включена авторотация, стратегии профилей 1–4 подбираются автоматически. Выключите авторотацию в настройках, чтобы управлять ими вручную.';
  }
  if (profile.is_fallback && !profile.fallback_enabled) {
    return 'Сначала включите безразборный режим в настройках.';
  }
  if (profile.is_udp_games && !profile.udp_games_enabled) {
    return 'Сначала включите игровой UDP в настройках.';
  }
  return '';
}

function renderStrategies() {
  const container = document.getElementById('strategy-cards');
  const template = document.getElementById('strategy-card-template');
  container.innerHTML = '';

  state.locks.forEach((profile) => {
    const node = template.content.firstElementChild.cloneNode(true);
    node.querySelector('h3').textContent = profile.label;
    node.querySelector('.desc').textContent = profile.description;
    node.querySelector('.chip').textContent = `Профиль ${profile.profile}`;
    renderCurrentLock(node.querySelector('.current-lock'), profile.current_lock);
    node.querySelector('.max-lock').textContent = String(profile.max_strategy);

    const input = node.querySelector('input');
    const form = node.querySelector('.lock-form');
    const submitButton = form.querySelector('button[type="submit"]');
    const clearButton = node.querySelector('.clear-lock');
    const inlineCheck = node.querySelector('.inline-check');
    const stepButtons = node.querySelectorAll('.step-strategy');

    input.min = '0';
    input.max = String(profile.max_strategy);
    if (/^[0-9]+$/.test(String(profile.current_lock || ''))) {
      input.value = profile.current_lock;
    }
    input.dataset.saved = String(profile.current_lock || '0');
    updateStrategyFormState(form);
    input.addEventListener('input', () => updateStrategyFormState(form));
    if (profile.is_fallback) {
      renderCheckResults(inlineCheck, state.strategyChecks[profile.profile] || { results: [] }, FALLBACK_CHECK_HINT, false);
    } else if (profile.is_udp_games) {
      renderCheckResults(inlineCheck, state.strategyChecks[profile.profile] || { results: [] }, UDP_GAMES_CHECK_HINT, false);
    } else if (state.strategyChecks[profile.profile]) {
      renderCheckResults(inlineCheck, state.strategyChecks[profile.profile], 'Нет результатов быстрой проверки.', false);
    }

    stepButtons.forEach((button) => {
      button.addEventListener('click', () => {
        const step = Number(button.dataset.step || 0);
        const min = Number(input.min || 1);
        const max = Number(input.max || profile.max_strategy || min);
        const parsed = Number(input.value || profile.current_lock);
        const current = Number.isFinite(parsed) ? parsed : min;
        const next = Math.min(max, Math.max(min, current + step));
        input.value = String(next);
        input.dispatchEvent(new Event('input', { bubbles: true }));
      });
    });

    if (isProfileGated(profile)) {
      node.classList.add('is-disabled');
      input.disabled = true;
      submitButton.disabled = true;
      clearButton.disabled = true;
      stepButtons.forEach((b) => { b.disabled = true; });
      inlineCheck.classList.remove('empty');
      inlineCheck.innerHTML = `<p class="fallback-hint">${gatedReason(profile)}</p>`;
    }

    form.addEventListener('submit', async (event) => {
      if (isProfileGated(profile)) {
        showToast(gatedReason(profile), 'error');
        return;
      }
      event.preventDefault();
      const rawValue = input.value.trim();
      const value = Number(rawValue);
      if (!/^[0-9]+$/.test(rawValue) || value > Number(input.max || profile.max_strategy || 0)) {
        showToast('Введите номер стратегии.', 'error');
        return;
      }
      try {
        let payload = null;
        await withBusy(submitButton, async () => {
          payload = await api('/cgi-bin/set-lock.cgi', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ profile: profile.profile, strategy: value }),
          });
          state.strategyChecks[profile.profile] = payload?.check;
          await refreshAll();
        });
        showToast(value === 0 ? `Профиль ${profile.label} выключен.` : `Стратегия ${value} сохранена для ${profile.label}.`);
      } catch (error) {
        showToast(error.message, 'error');
      }
    });

    clearButton.addEventListener('click', async () => {
      if (isProfileGated(profile)) {
        showToast(gatedReason(profile), 'error');
        return;
      }
      try {
        await withBusy(clearButton, async () => {
          await api('/cgi-bin/clear-lock.cgi', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ profile: profile.profile }),
          });
          delete state.strategyChecks[profile.profile];
          await refreshAll();
        });
        showToast(`Lock снят для ${profile.label}.`);
      } catch (error) {
        showToast(error.message, 'error');
      }
    });

    container.appendChild(node);
  });
}

function appendText(parent, tag, text, className) {
  const element = document.createElement(tag);
  if (className) {
    element.className = className;
  }
  element.textContent = text;
  parent.appendChild(element);
  return element;
}

function checkVerdictClass(verdict) {
  if (verdict === 'ok') return 'ok';
  if (verdict === 'warn') return 'warn';
  return 'bad';
}

function checkLineClass(state) {
  return state === 'ok' || state === 'http' ? 'ok' : 'warn';
}

function renderCheckResults(container, payload, emptyMessage, emptyIsHidden = true) {
  if (!container) return;
  container.innerHTML = '';

  const results = Array.isArray(payload?.results) ? payload.results : [];
  if (!results.length) {
    container.classList.toggle('empty', emptyIsHidden && !payload?.message);
    container.textContent = payload?.message || emptyMessage;
    return;
  }

  container.classList.remove('empty');
  results.forEach((item) => {
    const article = document.createElement('article');
    article.className = 'check-item';

    const title = document.createElement('div');
    title.className = 'check-title';
    appendText(title, 'strong', item.label || 'Цель');
    appendText(title, 'span', item.target || '');

    const pair = document.createElement('div');
    pair.className = 'check-pair';
    if (item.verdict) {
      appendText(pair, 'span', item.text || item.verdict, checkVerdictClass(item.verdict));
      if (item.tls12_detail) {
        appendText(pair, 'span', item.tls12_detail.text || 'TLS 1.2', checkLineClass(item.tls12_detail.state));
      }
      if (item.tls13_detail) {
        appendText(pair, 'span', item.tls13_detail.text || 'TLS 1.3', checkLineClass(item.tls13_detail.state));
      }
      if (item.download) {
        appendText(pair, 'span', item.download.text || 'Данные', item.download.state === 'ok' ? 'ok' : 'warn');
      }
    } else {
      appendText(pair, 'span', `TLS 1.2: ${item.tls12 ? 'OK' : 'FAIL'}`, item.tls12 ? 'ok' : 'bad');
      appendText(pair, 'span', `TLS 1.3: ${item.tls13 ? 'OK' : 'FAIL'}`, item.tls13 ? 'ok' : 'bad');
    }

    article.append(title, pair);
    container.appendChild(article);
  });
}

async function refreshAll() {
  const status = await api('/cgi-bin/status.cgi');
  state.status = status;
  state.locks = status.profiles || [];
  renderStatus();
  renderStrategies();
  document.getElementById('view-status').classList.remove('is-loading');
  if (activeOperation) lockAllControls();
}

function renderSettings() {
  const select = document.getElementById('tls-blob-select');
  const statusChip = document.getElementById('tls-blob-status');
  const currentFile = document.getElementById('current-blob-file');

  if (!state.tlsBlobSettings) return;

  const settings = state.tlsBlobSettings;

  const mode = settings.current_mode || '';
  const isBuiltin = mode === 'fake_default_tls';

  const maxruFile = settings.current_blob || '';


  let statusText;
  if (mode === 'fake_default_tls') {
    statusText = 'default';
  } else {
    statusText = mode || 'не определён';
  }
  statusChip.textContent = statusText;
  statusChip.className = 'chip';
  if (mode === 'maxru') {
    statusChip.classList.add('is-ok');
  }

  currentFile.textContent = isBuiltin ? 'fake_default_tls (встроенный)' : (maxruFile || '—');

  const listedBlobs = Array.isArray(settings.available_blobs) ? settings.available_blobs : [];
  const blobs = (maxruFile && !listedBlobs.includes(maxruFile))
    ? [maxruFile, ...listedBlobs]
    : listedBlobs;

  select.innerHTML = '';

  const placeholder = document.createElement('option');
  placeholder.value = '';
  if (!isBuiltin && maxruFile) {
    placeholder.textContent = maxruFile + ' (текущий) — выберите файл';
  } else {
    placeholder.textContent = 'Выберите блоб';
  }
  placeholder.disabled = true;
  placeholder.selected = true;
  select.appendChild(placeholder);

  const builtin = document.createElement('option');
  builtin.value = 'fake_default_tls';
  builtin.textContent = 'fake_default_tls (встроенный)';
  if (isBuiltin) {
    builtin.textContent += ' (текущий)';
    builtin.disabled = true;
  }
  select.appendChild(builtin);

  blobs.forEach(blob => {
    const option = document.createElement('option');
    option.value = blob;
    if (!isBuiltin && blob === maxruFile) {
      option.textContent = blob + ' (текущий)';
      option.disabled = true;
    } else {
      option.textContent = blob;
    }
    select.appendChild(option);
  });

  select.dataset.saved = isBuiltin ? 'fake_default_tls' : maxruFile;
  updateTlsBlobSubmit();
  if (select.dataset.bound !== '1') {
    select.addEventListener('change', updateTlsBlobSubmit);
    select.dataset.bound = '1';
  }
}

async function refreshTlsBlobSettings() {
  try {
    const data = await api('/cgi-bin/settings.cgi');
    state.tlsBlobSettings = data;
    renderSettings();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function applyTlsBlob(blob) {
  if (!blob) {
    showToast('Выберите блоб.', 'error');
    return;
  }
  try {
    const payload = await api('/cgi-bin/settings.cgi', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ setting: 'tls_blob', value: blob }),
    });

    if (payload.reboot_required) {
      showToast('TLS-блоб изменён. Перезапустите zapret2 для применения.', 'warning');
    } else {
      showToast('TLS-блоб успешно изменён.');
    }

    await refreshTlsBlobSettings();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

document.getElementById('refresh-settings').addEventListener('click', (event) => {
  withBusy(event.currentTarget, async () => {
    await Promise.all([
      refreshTlsBlobSettings(),
      refreshWgBlobSettings(),
      refreshWgStateSettings(),
      refreshUdpGamesSettings(),
      refreshFallbackSettings(),
      ...MODE_TOGGLES.map(refreshModeSetting),
      refreshPorts(),
      refreshProvider(),
      refreshBackups(),
    ]);
  }).catch((e) => showToast(e.message, 'error'));
});

document.getElementById('tls-blob-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const select = document.getElementById('tls-blob-select');
  const submitButton = event.currentTarget.querySelector('button[type="submit"]');

  await withBusy(submitButton, async () => {
    await applyTlsBlob(select.value);
  });
});

async function refreshUdpGamesSettings() {
  try {
    const data = await api('/cgi-bin/settings.cgi?setting=udp-games');
    state.udpGamesSettings = data;
    renderUdpGamesSettings();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

function renderUdpGamesSettings() {
  const stateForm = document.getElementById('udp-games-form');
  if (!state.udpGamesSettings || !stateForm) return;

  const settings = state.udpGamesSettings;
  const isEnabled = settings.enabled === true;

  const checkbox = stateForm.querySelector('input[type="checkbox"]');
  if (checkbox) {
    checkbox.checked = isEnabled;
    checkbox.dataset.saved = isEnabled ? '1' : '0';
  }

  const stateChip = document.getElementById('udp-games-state-chip');
  if (stateChip) {
    stateChip.textContent = isEnabled ? 'включен' : 'выключен';
    stateChip.className = 'chip';
    if (isEnabled) {
      stateChip.classList.add('is-ok');
    }
  }

  const portsChip = document.getElementById('udp-games-ports-chip');
  if (portsChip) {
    portsChip.textContent = settings.ports || '—';
  }

  updateUdpGamesSubmit();
}

async function applyUdpGames(enabled) {
  return api('/cgi-bin/settings.cgi', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ setting: 'udp_games_state', value: enabled ? '1' : '0' }),
  });
}

document.getElementById('udp-games-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const checkbox = event.currentTarget.querySelector('input[type="checkbox"]');
  const submitButton = event.currentTarget.querySelector('button[type="submit"]');
  if (!checkbox || !submitButton) return;

  await withBusy(submitButton, async () => {
    try {
      await applyUdpGames(checkbox.checked);
      showToast(checkbox.checked ? 'Игровой UDP включён.' : 'Игровой UDP выключен.');
      await refreshUdpGamesSettings();
      await refreshAll();
    } catch (error) {
      showToast(error.message, 'error');
    }
  });
});

function renderWgSettings() {
  const select = document.getElementById('wg-blob-select');
  const repeatsInput = document.getElementById('wg-repeats-input');
  const currentFile = document.getElementById('current-wg-blob-file');

  if (!state.wgBlobSettings || !select) return;

  const settings = state.wgBlobSettings;

  currentFile.textContent = settings.current_blob || '—';

  select.innerHTML = '';
  if (Array.isArray(settings.available_blobs) && settings.available_blobs.length > 0) {
    settings.available_blobs.forEach((blob) => {
      const option = document.createElement('option');
      option.value = blob;
      option.textContent = blob;
      if (blob === settings.current_blob) {
        option.selected = true;
      }
      select.appendChild(option);
    });
    if (settings.current_blob) {
      select.value = settings.current_blob;
    }
  } else {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = 'WireGuard не найден в конфиге';
    select.appendChild(option);
  }

  if (settings.current_repeats) {
    repeatsInput.value = settings.current_repeats;
  }

  select.dataset.saved = settings.current_blob || '';
  repeatsInput.dataset.saved = String(settings.current_repeats || '');
  updateWgFieldsState();
  updateWgSubmit();
  if (select.dataset.bound !== '1') {
    select.addEventListener('change', updateWgSubmit);
    select.dataset.bound = '1';
  }
  if (repeatsInput.dataset.bound !== '1') {
    repeatsInput.addEventListener('input', updateWgSubmit);
    repeatsInput.dataset.bound = '1';
  }
}

async function refreshWgBlobSettings() {
  try {
    const data = await api('/cgi-bin/settings.cgi?setting=wg_blob');
    state.wgBlobSettings = data;
    renderWgSettings();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function applyWgBlob(blob) {
  return api('/cgi-bin/settings.cgi', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ setting: 'wg_blob', value: blob }),
  });
}

async function applyWgRepeats(repeats) {
  return api('/cgi-bin/settings.cgi', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ setting: 'wg_repeats', value: String(repeats) }),
  });
}

function renderWgStateSettings() {
  const checkbox = document.getElementById('wg-state-toggle');
  if (!state.wgStateSettings || !checkbox) return;

  const settings = state.wgStateSettings;
  const isEnabled = settings.enabled === true;

  checkbox.checked = isEnabled;
  checkbox.dataset.saved = isEnabled ? '1' : '0';

  const stateChip = document.getElementById('wg-state-chip');
  if (stateChip) {
    stateChip.textContent = isEnabled ? 'включено' : 'выключено';
    stateChip.className = 'chip';
    if (isEnabled) {
      stateChip.classList.add('is-ok');
    }
  }

  updateWgFieldsState();
  updateWgSubmit();
}

async function refreshWgStateSettings() {
  try {
    const data = await api('/cgi-bin/settings.cgi?setting=wg_state');
    state.wgStateSettings = data;
    renderWgStateSettings();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function applyWgState(enabled) {
  return api('/cgi-bin/settings.cgi', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ setting: 'wg_state', value: enabled ? '1' : '0' }),
  });
}

function renderFallbackSettings() {
  const stateForm = document.getElementById('fallback-state-form');
  if (!state.fallbackSettings || !stateForm) return;

  const settings = state.fallbackSettings;
  const unavailable = settings.state === 'недоступен';
  const isEnabled = settings.state === 'включен';

  const checkbox = stateForm.querySelector('input[type="checkbox"]');
  if (checkbox) {
    checkbox.checked = isEnabled;
    checkbox.disabled = unavailable;
    checkbox.dataset.saved = isEnabled ? '1' : '0';
  }

  const stateChip = document.getElementById('fallback-state-chip');
  if (stateChip) {
    stateChip.textContent = unavailable ? 'недоступен' : (isEnabled ? 'включен' : 'выключен');
    stateChip.className = 'chip';
    if (isEnabled) {
      stateChip.classList.add('is-ok');
    }
  }

  const alertEl = document.getElementById('fallback-state-alert');
  if (alertEl) {
    alertEl.hidden = !unavailable;
    alertEl.textContent = unavailable
      ? 'Авторотация включена. Выключите её, чтобы управлять безразборным режимом.'
      : '';
  }

  updateFallbackSubmit();

  const autoToggle = MODE_TOGGLES.find((t) => t.setting === 'auto_mode');
  if (autoToggle && state.modeSettings.auto_mode) {
    renderModeSetting(autoToggle);
  }
}

async function refreshFallbackSettings() {
  try {
    const data = await api('/cgi-bin/settings.cgi?setting=fallback');
    state.fallbackSettings = data;
    renderFallbackSettings();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function applyFallbackState(enabled) {
  return api('/cgi-bin/settings.cgi', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ setting: 'fallback_state', value: enabled ? '1' : '0' }),
  });
}

document.querySelectorAll('.step-wg-repeats').forEach((button) => {
  button.addEventListener('click', () => {
    const input = document.getElementById('wg-repeats-input');
    const step = Number(button.dataset.step || 0);
    const min = Number(input.min || 2);
    const max = Number(input.max || 99);
    const parsed = Number(input.value || min);
    const current = Number.isFinite(parsed) ? parsed : min;
    const next = Math.min(max, Math.max(min, current + step));
    input.value = String(next);
    input.dispatchEvent(new Event('input', { bubbles: true }));
  });
});

document.getElementById('wg-blob-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const checkbox = document.getElementById('wg-state-toggle');
  const select = document.getElementById('wg-blob-select');
  const repeatsInput = document.getElementById('wg-repeats-input');
  const submitButton = event.currentTarget.querySelector('button[type="submit"]');

  const enabled = checkbox ? checkbox.checked : false;
  const stateChanged = checkbox && (checkbox.dataset.saved || '0') !== (enabled ? '1' : '0');

  const blob = select.value;
  const repeatsRaw = repeatsInput.value.trim();
  const repeats = Number(repeatsRaw);

  // Валидация blob/repeats — только когда стратегия включена
  if (enabled) {
    if (!blob) {
      showToast('Выберите файл blob для WireGuard.', 'error');
      return;
    }
    if (!/^[0-9]+$/.test(repeatsRaw) || repeats < 2 || repeats > 99) {
      showToast('Повторы должны быть целым числом от 2 до 99.', 'error');
      return;
    }
  }

  await withBusy(submitButton, async () => {
    try {
      await applyWgState(enabled);
      if (enabled) {
        await applyWgBlob(blob);
        await applyWgRepeats(repeats);
      }
      let msg;
      if (stateChanged) {
        msg = enabled ? 'Стратегия WireGuard включена.' : 'Стратегия WireGuard выключена.';
      } else {
        msg = 'Настройки WireGuard сохранены.';
      }
      showToast(msg + ' Перезапустите zapret2 для применения.', 'warning');
      await refreshWgBlobSettings();
      await refreshWgStateSettings();
      await refreshAll();
    } catch (error) {
      showToast(error.message, 'error');
    }
  });
});

const fallbackToggle = document.getElementById('fallback-state-toggle');
if (fallbackToggle) {
  fallbackToggle.addEventListener('change', () => {
    updateFallbackSubmit();
  });
}

const udpGamesToggle = document.getElementById('udp-games-toggle');
if (udpGamesToggle) {
  udpGamesToggle.addEventListener('change', () => {
    updateUdpGamesSubmit();
  });
}

const wgStateToggle = document.getElementById('wg-state-toggle');
if (wgStateToggle) {
  wgStateToggle.addEventListener('change', () => {
    updateWgFieldsState();
    updateWgSubmit();
  });
}

const fallbackStateForm = document.getElementById('fallback-state-form');
if (fallbackStateForm) {
  fallbackStateForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const checkbox = event.currentTarget.querySelector('input[type="checkbox"]');
    const submitButton = event.currentTarget.querySelector('button[type="submit"]');
    if (!checkbox || !submitButton) return;

    const enable = checkbox.checked;
    const confirmed = await confirmDialog({
      title: enable ? 'Включить безразборный режим?' : 'Выключить безразборный режим?',
      message: enable
        ? [
            'Обход будет применяться ко всему трафику на выбранных портах, а не только к доменам из списков.',
            'После включения выберите стратегии для TLS (профиль 8) и HTTP (профиль 9) во вкладке «Стратегии».',
            'Изменение применяется после перезапуска zapret2.',
          ]
        : [
            'Обход снова будет применяться только к доменам из списков и выбранным стратегиям.',
            'Изменение применяется после перезапуска zapret2.',
          ],
      confirmText: enable ? 'Включить' : 'Выключить',
      cancelText: 'Отмена',
    });
    if (!confirmed) {
      checkbox.checked = !enable;
      updateFallbackSubmit();
      return;
    }

    await withBusy(submitButton, async () => {
      try {
        await applyFallbackState(enable);
        showToast(enable
          ? 'Безразборный режим включён. Перезапустите zapret2 для применения.'
          : 'Безразборный режим выключен. Перезапустите zapret2 для применения.', 'warning');
        await refreshFallbackSettings();
        await refreshAll();
      } catch (error) {
        showToast(error.message, 'error');
      }
    });
  });
}

const MODE_TOGGLES = [
  {
    setting: 'auto_mode',
    postKey: 'auto_mode_state',
    formId: 'auto-mode-form',
    chipId: 'auto-mode-chip',
    enabledField: 'enabled',
    onChip: 'включена',
    offChip: 'выключена',
    onToast: 'Авторотация включена.',
    offToast: 'Авторотация выключена.',
    needsRestart: false,
    askConfirm: true,
    confirm: {
      titleOn: 'Включить авторотацию?',
      messageOn: [
        'zapret2 будет сам подбирать и менять стратегии TCP/HTTP.',
        'Ручные фиксации профилей 1–4 и безразборный режим применяться не будут.',
        'Сервис перезапустится сразу.',
      ],
      titleOff: 'Выключить авторотацию?',
      messageOff: [
        'Стратегии перестанут меняться автоматически — управление вернётся к ручным фиксациям.',
        'Сервис перезапустится сразу.',
      ],
    },
  },
  {
    setting: 'hostlist',
    postKey: 'hostlist_state',
    formId: 'hostlist-form',
    chipId: 'hostlist-chip',
    enabledField: 'auto',
    onChip: 'автосбор',
    offChip: 'по листам',
    onToast: 'Автосбор списков включён. Перезапустите zapret2 для применения.',
    offToast: 'Фильтрация только по спискам. Перезапустите zapret2 для применения.',
    needsRestart: true,
    askConfirm: true,
    confirm: {
      titleOn: 'Включить автосбор списков?',
      messageOn: [
        'zapret2 начнёт сам определять заблокированные домены и пополнять список — обход будет работать шире.',
        'Пока автосбор включён, добавление доменов в RKN-списки (TCP_Custom и подстроки RKN) отключено. Списки исключений не затрагиваются.',
        'Изменение применяется после перезапуска zapret2.',
      ],
      titleOff: 'Выключить автосбор списков?',
      messageOff: [
        'Обход снова будет применяться только к доменам из ваших списков.',
        'Ручное добавление доменов в RKN-списки вернётся.',
        'Изменение применяется после перезапуска zapret2.',
      ],
    },
  },
  {
    setting: 'rst_guard',
    postKey: 'rst_guard_state',
    formId: 'rst-guard-form',
    chipId: 'rst-guard-chip',
    enabledField: 'enabled',
    onChip: 'включена',
    offChip: 'выключена',
    onToast: 'Защита от RST-инъекций включена. Перезапустите zapret2 для применения.',
    offToast: 'Защита от RST-инъекций выключена. Перезапустите zapret2 для применения.',
    needsRestart: true,
  },
  {
    setting: 'reasm',
    postKey: 'reasm_state',
    formId: 'reasm-form',
    chipId: 'reasm-chip',
    enabledField: 'enabled',
    onChip: 'включен',
    offChip: 'выключен',
    onToast: 'Параметр --reasm-disable включён. Перезапустите zapret2 для применения.',
    offToast: 'Параметр --reasm-disable выключен. Перезапустите zapret2 для применения.',
    needsRestart: true,
  },
  {
    setting: 'quic443',
    postKey: 'quic443_state',
    formId: 'quic443-form',
    chipId: 'quic443-chip',
    enabledField: 'enabled',
    onChip: 'включены',
    offChip: 'выключены',
    onToast: 'Фейки QUIC на порту 443 включены. Перезапустите zapret2 для применения.',
    offToast: 'Фейки QUIC на порту 443 выключены. Перезапустите zapret2 для применения.',
    needsRestart: true,
  },
];

async function refreshModeSetting(toggle) {
  const data = await api(`/cgi-bin/settings.cgi?setting=${toggle.setting}`);
  state.modeSettings[toggle.setting] = data;
  renderModeSetting(toggle);
}

function renderModeSetting(toggle) {
  const data = state.modeSettings[toggle.setting];
  const form = document.getElementById(toggle.formId);
  if (!data || !form) return;

  const enabled = data[toggle.enabledField] === true;
  const checkbox = form.querySelector('input[type="checkbox"]');
  if (checkbox) {
    checkbox.checked = enabled;
    checkbox.dataset.saved = enabled ? '1' : '0';
  }

  if (toggle.chipId) {
    const chip = document.getElementById(toggle.chipId);
    if (chip) {
      chip.textContent = enabled ? toggle.onChip : toggle.offChip;
      chip.className = 'chip';
      if (enabled) chip.classList.add('is-ok');
    }
  }

  if (toggle.setting === 'rst_guard') {
    const hint = document.getElementById('rst-guard-hint');
    const luaMissing = data.lua_available === false;
    if (hint) hint.hidden = !luaMissing;
    if (checkbox) checkbox.disabled = luaMissing && !enabled;
  }

  if (toggle.setting === 'auto_mode') {
    const alertEl = document.getElementById('auto-mode-alert');
    const submit = form.querySelector('button[type="submit"]');
    const fallbackOn = state.fallbackSettings?.state === 'включен';
    if (checkbox) checkbox.disabled = fallbackOn;
    if (alertEl) {
      alertEl.hidden = !fallbackOn;
      alertEl.textContent = fallbackOn
        ? 'Безразборный режим включён. Выключите его, чтобы включить авторотацию.'
        : '';
    }
    if (submit && fallbackOn) {
      submit.disabled = true;
      submit.title = 'Выключите безразборный режим, чтобы включить авторотацию';
    } else if (submit) {
      submit.title = '';
    }
  }

  updateModeSubmit(toggle);
}

function updateModeSubmit(toggle) {
  const form = document.getElementById(toggle.formId);
  if (!form) return;
  const submit = form.querySelector('button[type="submit"]');
  const checkbox = form.querySelector('input[type="checkbox"]');
  if (!submit || !checkbox) return;
  if (checkbox.disabled) {
    submit.disabled = true;
    return;
  }
  const saved = checkbox.dataset.saved || '0';
  submit.disabled = (checkbox.checked ? '1' : '0') === saved;
}

function bindModeToggle(toggle) {
  const form = document.getElementById(toggle.formId);
  if (!form) return;
  const checkbox = form.querySelector('input[type="checkbox"]');
  const submitButton = form.querySelector('button[type="submit"]');
  if (!checkbox || !submitButton) return;

  checkbox.addEventListener('change', () => updateModeSubmit(toggle));

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const enable = checkbox.checked;

    if (checkbox.disabled) {
      checkbox.checked = checkbox.dataset.saved === '1';
      updateModeSubmit(toggle);
      return;
    }

    if (toggle.setting === 'rst_guard' && enable &&
        state.modeSettings.rst_guard && state.modeSettings.rst_guard.lua_available === false) {
      showToast('На устройстве нет файла rst-guard.lua. Включите защиту через CLI (пункт 18 меню).', 'error');
      checkbox.checked = false;
      updateModeSubmit(toggle);
      return;
    }

    if (toggle.setting === 'auto_mode' && enable &&
        state.fallbackSettings?.state === 'включен') {
      showToast('Авторотация недоступна при включённом безразборном режиме. Сначала выключите безразборный режим.', 'error');
      checkbox.checked = false;
      updateModeSubmit(toggle);
      return;
    }

    if (toggle.askConfirm && toggle.confirm) {
      const confirmed = await confirmDialog({
        title: enable ? toggle.confirm.titleOn : toggle.confirm.titleOff,
        message: enable ? toggle.confirm.messageOn : toggle.confirm.messageOff,
        confirmText: enable ? 'Включить' : 'Выключить',
        cancelText: 'Отмена',
      });
      if (!confirmed) {
        checkbox.checked = !enable;
        updateModeSubmit(toggle);
        return;
      }
    }

    try {
      await withBusy(submitButton, async () => {
        const payload = await api('/cgi-bin/settings.cgi', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ setting: toggle.postKey, value: enable ? '1' : '0' }),
        });
        let message = enable ? toggle.onToast : toggle.offToast;
        if (toggle.setting === 'auto_mode') {
          message += payload.restarted ? ' zapret2 перезапущен.' : ' Применится при следующем запуске zapret2.';
        }
        showToast(message, toggle.needsRestart ? 'warning' : 'success');
        await refreshModeSetting(toggle);
        if (toggle.setting === 'auto_mode') {
          await refreshFallbackSettings();
        }
        await refreshAll();
      });
    } catch (error) {
      showToast(error.message, 'error');
      await refreshModeSetting(toggle);
    }
  });
}

MODE_TOGGLES.forEach(bindModeToggle);

function updatePortsSubmit(form) {
  const input = form.querySelector('input[type="text"]');
  const submit = form.querySelector('button[type="submit"]');
  if (input && submit) {
    submit.disabled = input.value.trim() === '';
  }
}

async function refreshPorts() {
  const data = await api('/cgi-bin/settings.cgi?setting=ports');
  state.ports = data;
  renderPorts();
}

function renderPorts() {
  if (!state.ports) return;
  renderPortsProto('tcp', state.ports.tcp);
  renderPortsProto('udp', state.ports.udp);
  const tcpCount = Array.isArray(state.ports.tcp?.user) ? state.ports.tcp.user.length : 0;
  const udpCount = Array.isArray(state.ports.udp?.user) ? state.ports.udp.user.length : 0;
  const chip = document.getElementById('ports-count-chip');
  if (chip) {
    const total = tcpCount + udpCount;
    chip.textContent = total > 0 ? `добавлено: ${total}` : 'не добавлены';
    chip.className = 'chip';
    if (total > 0) chip.classList.add('is-ok');
  }
}

function renderPortsProto(proto, info) {
  const chips = document.getElementById(`ports-${proto}-chips`);
  const base = document.getElementById(`ports-${proto}-base`);
  const empty = document.getElementById(`ports-${proto}-empty`);
  if (!chips) return;

  const users = Array.isArray(info?.user) ? info.user : [];
  chips.innerHTML = '';
  if (base) base.textContent = info?.base || '—';
  if (empty) empty.hidden = users.length > 0;

  users.forEach((token) => {
    const chip = document.createElement('span');
    chip.className = 'port-chip';
    const label = document.createElement('span');
    label.textContent = token;
    chip.appendChild(label);

    if (proto === 'udp' && token === '1026-65531') {
      chip.classList.add('is-managed');
      chip.title = 'Управляется переключателем «Игровой UDP» выше';
    } else {
      const removeBtn = document.createElement('button');
      removeBtn.type = 'button';
      removeBtn.className = 'port-remove';
      removeBtn.textContent = '×';
      removeBtn.setAttribute('aria-label', `Удалить порт ${token}`);
      removeBtn.addEventListener('click', () => removePort(proto, token, removeBtn));
      chip.appendChild(removeBtn);
    }
    chips.appendChild(chip);
  });
}

function validatePortList(raw) {
  const value = String(raw || '').replace(/\s+/g, '');
  if (!value) return null;
  const tokens = value.split(',');
  for (const token of tokens) {
    const match = token.match(/^(\d{1,5})(?:-(\d{1,5}))?$/);
    if (!match) return null;
    const start = Number(match[1]);
    const end = match[2] ? Number(match[2]) : start;
    if (start < 1 || end > 65535 || start > end) return null;
  }
  return value;
}

async function addPorts(proto) {
  const input = document.getElementById(`ports-${proto}-input`);
  const submitButton = document.getElementById(`ports-${proto}-form`).querySelector('button[type="submit"]');
  const value = validatePortList(input.value);
  if (!value) {
    showToast('Формат: порт (8080) или диапазон (9000-9100), через запятую. Значения от 1 до 65535.', 'error');
    return;
  }
  try {
    await withBusy(submitButton, async () => {
      const payload = await api('/cgi-bin/settings.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ setting: 'ports_add', proto, value }),
      });
      const skipped = payload.skipped ? ` Пропущено: ${payload.skipped}.` : '';
      showToast(`Добавлено: ${payload.added}.${skipped} Перезапустите zapret2 для применения.`, 'warning');
      input.value = '';
      updatePortsSubmit(submitButton.form);
      await refreshPorts();
      await refreshAll();
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function removePort(proto, token, button) {
  try {
    await withBusy(button, async () => {
      await api('/cgi-bin/settings.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ setting: 'ports_remove', proto, value: token }),
      });
      showToast(`Порт ${token} удалён. Перезапустите zapret2 для применения.`, 'warning');
      await refreshPorts();
      await refreshAll();
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

document.getElementById('ports-tcp-form').addEventListener('submit', (event) => {
  event.preventDefault();
  addPorts('tcp');
});

document.getElementById('ports-udp-form').addEventListener('submit', (event) => {
  event.preventDefault();
  addPorts('udp');
});

document.querySelectorAll('.ports-add-form').forEach((form) => {
  const input = form.querySelector('input[type="text"]');
  if (!input) return;
  input.addEventListener('input', () => updatePortsSubmit(form));
  updatePortsSubmit(form);
});

async function refreshProvider() {
  const data = await api('/cgi-bin/settings.cgi?setting=provider');
  state.provider = data;
  renderProvider();
}

function renderProvider() {
  if (!state.provider) return;
  const current = document.getElementById('provider-current');
  if (current) current.textContent = state.provider.provider || 'Не определён';
  const nameInput = document.getElementById('provider-name-input');
  const cityInput = document.getElementById('provider-city-input');
  if (nameInput && document.activeElement !== nameInput) {
    nameInput.value = state.provider.provider === 'Не определён' ? '' : String(state.provider.provider || '').split(' - ')[0];
  }
  if (cityInput && document.activeElement !== cityInput) {
    const parts = String(state.provider.provider || '').split(' - ');
    cityInput.value = parts.length > 1 ? parts.slice(1).join(' - ') : '';
  }
  updateProviderSubmit();
}

function updateProviderSubmit() {
  const form = document.getElementById('provider-form');
  if (!form) return;
  const submit = form.querySelector('button[type="submit"]');
  const nameInput = document.getElementById('provider-name-input');
  if (!submit || !nameInput) return;
  submit.disabled = !nameInput.value.trim();
}

document.getElementById('provider-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const submitButton = event.currentTarget.querySelector('button[type="submit"]');
  const name = document.getElementById('provider-name-input').value.trim();
  const city = document.getElementById('provider-city-input').value.trim();
  if (!name) {
    showToast('Укажите название провайдера.', 'error');
    return;
  }
  try {
    await withBusy(submitButton, async () => {
      await api('/cgi-bin/settings.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ setting: 'provider_set', name, city }),
      });
      showToast('Провайдер сохранён.');
      await refreshProvider();
      await refreshAll();
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
});

document.getElementById('provider-redetect-btn').addEventListener('click', async (event) => {
  try {
    await withBusy(event.currentTarget, async () => {
      const payload = await api('/cgi-bin/settings.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ setting: 'provider_redetect' }),
      });
      if (payload.provider && payload.provider !== 'Не удалось определить') {
        showToast(`Провайдер определён: ${payload.provider}`);
      } else {
        showToast('Не удалось определить провайдера автоматически. Задайте вручную.', 'warning');
      }
      await refreshProvider();
      await refreshAll();
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
});

async function refreshBackups() {
  const data = await api('/cgi-bin/backups.cgi');
  state.backups = data;
  renderBackups();
}

function formatSize(bytes) {
  const value = Number(bytes) || 0;
  if (value >= 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + ' МБ';
  if (value >= 1024) return (value / 1024).toFixed(1) + ' КБ';
  return value + ' Б';
}

const BACKUPS_PREVIEW_COUNT = 4;
let backupsListExpanded = false;

function renderBackups() {
  if (!state.backups) return;
  const items = Array.isArray(state.backups.items) ? state.backups.items : [];
  const list = document.getElementById('backup-items');
  const empty = document.getElementById('backups-empty');
  const chip = document.getElementById('backups-count-chip');
  if (!list) return;

  list.innerHTML = '';
  if (empty) empty.hidden = items.length > 0;
  if (chip) {
    chip.textContent = items.length > 0 ? `всего: ${items.length}` : 'нет';
    chip.className = 'chip';
    if (items.length > 0) chip.classList.add('is-ok');
  }

  const collapsed = items.length > BACKUPS_PREVIEW_COUNT && !backupsListExpanded;
  const visible = collapsed ? items.slice(0, BACKUPS_PREVIEW_COUNT) : items;

  visible.forEach((item) => {
    const row = document.createElement('li');
    row.className = 'backup-item';
    const name = document.createElement('span');
    name.className = 'backup-name';
    name.textContent = item.name;
    const meta = document.createElement('span');
    meta.className = 'backup-meta';
    const size = item.size !== undefined ? formatSize(item.size) : '';
    meta.textContent = [item.date, size].filter(Boolean).join(' · ');
    const actions = document.createElement('span');
    actions.className = 'backup-actions';
    const download = document.createElement('a');
    download.className = 'download-btn';
    download.href = '/cgi-bin/backups.cgi?action=download&name=' + encodeURIComponent(item.name);
    download.setAttribute('aria-label', 'Скачать');
    download.setAttribute('title', 'Скачать');
    download.textContent = '↓';
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'ghost danger remove-btn';
    remove.setAttribute('aria-label', 'Удалить');
    remove.setAttribute('title', 'Удалить');
    remove.textContent = '×';
    remove.addEventListener('click', async () => {
      const confirmed = await confirmDialog({
        title: `Удалить бэкап «${item.name}»?`,
        message: 'Действие необратимо.',
        confirmText: 'Удалить',
        cancelText: 'Отмена',
        danger: true,
      });
      if (!confirmed) return;
      try {
        await withBusy(remove, async () => {
          await api('/cgi-bin/backups.cgi', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ action: 'delete', name: item.name }),
          });
          showToast(`Бэкап удалён: ${item.name}`);
          await refreshBackups();
        });
      } catch (error) {
        showToast(error.message, 'error');
      }
    });
    actions.append(download, remove);
    row.append(name, meta, actions);
    list.appendChild(row);
  });

  if (items.length > BACKUPS_PREVIEW_COUNT) {
    const row = document.createElement('li');
    row.className = 'backup-toggle-row';
    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'ghost backups-toggle';
    toggle.textContent = collapsed ? `Показать все (${items.length})` : 'Свернуть';
    toggle.addEventListener('click', () => {
      backupsListExpanded = !backupsListExpanded;
      renderBackups();
    });
    row.appendChild(toggle);
    list.appendChild(row);
  }
}

document.getElementById('backup-create-btn').addEventListener('click', async (event) => {
  try {
    await withBusy(event.currentTarget, async () => {
      const payload = await api('/cgi-bin/backups.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ action: 'create' }),
      });
      showToast(`Бэкап создан: ${payload.name}`);
      await refreshBackups();
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
});

document.getElementById('backup-import-btn').addEventListener('click', () => {
  document.getElementById('backup-import-file').click();
});

document.getElementById('backup-import-file').addEventListener('change', async (event) => {
  const file = event.target.files[0];
  const importBtn = document.getElementById('backup-import-btn');
  event.target.value = '';
  if (!file) return;
  try {
    await withBusy(importBtn, async () => {
      const payload = await api('/cgi-bin/backups.cgi?action=upload&name=' + encodeURIComponent(file.name), {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-tar' },
        body: file,
      });
      showToast(`Бэкап импортирован: ${payload.name}`);
      await refreshBackups();
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
});

const AUTO_RKN_LISTS = ['custom_rkn', 'substring'];

function updateDomainsAddState() {
  const autoBlocked = AUTO_RKN_LISTS.includes(state.activeSubview) &&
    state.status?.hostlist_mode === 'авто';
  const alertEl = document.getElementById('domains-auto-alert');
  if (alertEl) {
    alertEl.hidden = !autoBlocked;
    alertEl.textContent = autoBlocked
      ? 'Автосбор списков включён: домены RKN zapret2 определяет автоматически, ручное добавление отключено. Выключите автосбор в настройках («Фильтрация по спискам»), чтобы пополнять список вручную. Удаление доступно.'
      : '';
  }
  const addInput = document.getElementById('domain-add-input');
  if (addInput) addInput.disabled = autoBlocked;
  const addSubmit = document.getElementById('domain-add-submit');
  if (addSubmit) addSubmit.disabled = autoBlocked;
  const importBtn = document.getElementById('domain-import-btn');
  if (importBtn) importBtn.disabled = autoBlocked;
  const importInput = document.getElementById('domain-import-input');
  if (importInput) importInput.disabled = autoBlocked;
}

const DOMAIN_META = {
  netrogat: {
    kind: 'domain',
    addLabel: 'Домен',
    placeholder: 'example.com',
    itemName: 'Домен',
  },
  custom_rkn: {
    kind: 'domain',
    addLabel: 'Домен',
    placeholder: 'example.com',
    itemName: 'Домен',
  },
  substring: {
    kind: 'substring',
    addLabel: 'Подстрока',
    placeholder: 'cdn, media, static, …',
    itemName: 'Подстрока',
  },
  netrogat_substring: {
    kind: 'substring',
    addLabel: 'Подстрока',
    placeholder: 'bank, shop, gov, …',
    itemName: 'Подстрока',
  },
};

function domainsApi(params, options = {}) {
  const search = new URLSearchParams(params);
  return api(`/cgi-bin/domains.cgi?${search.toString()}`, options);
}

function domainsPost(body) {
  return api('/cgi-bin/domains.cgi', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body),
  });
}

async function refreshDomains() {
  await Promise.all([
    refreshDomainList('netrogat'),
    refreshDomainList('custom_rkn'),
    refreshDomainList('substring'),
    refreshDomainList('netrogat_substring'),
  ]);
}

async function refreshDomainList(name) {
  try {
    const data = await domainsApi({ list: name });
    state.domains[name] = data;
    if (state.activeSubview === name) {
      renderDomainList(name);
    }
  } catch (error) {
    showToast(error.message, 'error');
  }
}

function renderDomainList(name) {
  const data = state.domains[name];
  if (!data) return;
  const meta = DOMAIN_META[name];

  document.getElementById('domains-title').textContent = data.title || name;
  document.getElementById('domains-desc').textContent = data.description || '';
  const countEl = document.getElementById('domains-count');
  if (countEl) {
    const n = Array.isArray(data.items) ? data.items.length : 0;
    countEl.textContent = String(n);
    countEl.className = 'chip';
    if (n > 0) countEl.classList.add('is-ok');
  }

  document.getElementById('domain-add-label').textContent = meta.addLabel;
  const addInput = document.getElementById('domain-add-input');
  addInput.placeholder = meta.placeholder;
  addInput.value = '';

  updateDomainsAddState();
  const listEl = document.getElementById('domain-items');
  listEl.innerHTML = '';
  const items = Array.isArray(data.items) ? data.items : [];
  document.getElementById('domains-empty').hidden = items.length > 0;

  const template = document.getElementById('domain-row-template');
  const isCustomRkn = data.is_custom_rkn === true;
  items.forEach((item) => {
    const row = template.content.cloneNode(true);
    row.querySelector('.domain-value').textContent = item.value;

    const stratChip = row.querySelector('.domain-strategy');
    const trialBtn = row.querySelector('.trial-btn');
    const checkBtn = row.querySelector('.domain-check-btn');
    if (isCustomRkn) {
      const strat = Number.isFinite(item.strategy) ? item.strategy : 0;
      if (strat > 0) {
        stratChip.textContent = `страт: ${strat}`;
        stratChip.classList.add('is-ok');
      } else {
        stratChip.textContent = 'РКН стр.';
      }
      if (trialBtn) trialBtn.hidden = false;
      if (checkBtn) checkBtn.hidden = false;
    } else {
      stratChip.hidden = true;
      if (trialBtn) trialBtn.hidden = true;
      if (checkBtn) checkBtn.hidden = true;
    }

    const rowEl = row.querySelector('.domain-row');
    rowEl.dataset.value = item.value;
    listEl.appendChild(rowEl);
  });
}

function switchSubview(name) {
  if (activeOperation) return;
  if (!DOMAIN_META[name]) return;
  state.activeSubview = name;
  document.querySelectorAll('.subtab').forEach((tab) => {
    tab.classList.toggle('is-active', tab.dataset.subview === name);
  });
  renderDomainList(name);
}

function findDomainRow(value) {
  return document.querySelector(`#domain-items .domain-row[data-value="${CSS.escape(value)}"]`);
}

function renderDomainCheck(container, check) {
  if (!container) return;
  if (check && Array.isArray(check.results) && check.results.length) {
    container.hidden = false;
    renderCheckResults(container, check, 'Нет результатов проверки.', false);
  } else {
    container.hidden = true;
    container.innerHTML = '';
  }
}

async function checkDomain(value) {
  const rowEl = findDomainRow(value);
  const btn = rowEl ? rowEl.querySelector('.domain-check-btn') : null;
  try {
    await withBusy(btn, async () => {
      const payload = await domainsPost({ list: 'custom_rkn', action: 'check', domain: value });
      if (rowEl) renderDomainCheck(rowEl.querySelector('.domain-check'), payload && payload.check);
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function addDomainFromForm() {
  const name = state.activeSubview;
  const input = document.getElementById('domain-add-input');
  const submitButton = document.getElementById('domain-add-submit');
  const value = input.value.trim();
  if (!value) return;
  try {
    await withBusy(submitButton, async () => {
      const payload = await domainsPost({ list: name, action: 'add', domain: value });
      if (payload && payload.duplicate) {
        showToast('Уже есть в списке.');
      } else {
        showToast('Добавлено.');
      }
      await refreshDomainList(name);
      const label = payload && payload.check && Array.isArray(payload.check.results) && payload.check.results[0]
        ? payload.check.results[0].label
        : '';
      if (label) {
        const rowEl = findDomainRow(label);
        if (rowEl) renderDomainCheck(rowEl.querySelector('.domain-check'), payload.check);
      }
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function removeDomain(value) {
  const name = state.activeSubview;
  const rowEl = findDomainRow(value);
  const btn = rowEl ? rowEl.querySelector('.remove-btn') : null;
  const itemName = (DOMAIN_META[name] || {}).itemName || 'домен';
  const confirmed = await confirmDialog({
    title: `Удалить ${itemName} «${value}»?`,
    message: name === 'custom_rkn'
      ? 'Подобранная стратегия также будет сброшена.'
      : 'Действие необратимо.',
    confirmText: 'Удалить',
    cancelText: 'Отмена',
    danger: true,
  });
  if (!confirmed) return;
  try {
    await withBusy(btn, async () => {
      await domainsPost({ list: name, action: 'remove', domain: value });
      showToast('Удалено.');
      await refreshDomainList(name);
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function importDomains() {
  const name = state.activeSubview;
  const textarea = document.getElementById('domain-import-input');
  const btn = document.getElementById('domain-import-btn');
  const text = textarea.value;
  if (!text.trim()) {
    showToast('Список для импорта пуст.', 'warning');
    return;
  }
  try {
    await withBusy(btn, async () => {
      const payload = await domainsPost({ list: name, action: 'import', domain: text });
      const added = payload ? payload.added : 0;
      const duplicates = payload ? payload.duplicates : 0;
      const skipped = payload ? payload.skipped : 0;
      showToast(`Импорт: добавлено ${added}, дубли ${duplicates}, пропущено ${skipped}.`);
      textarea.value = '';
      await refreshDomainList(name);
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function clearDomains() {
  const name = state.activeSubview;
  const btn = document.getElementById('domain-clear-btn');
  const confirmed = await confirmDialog({
    title: 'Очистить весь список?',
    message: 'Все записи будут удалены безвозвратно.',
    confirmText: 'Очистить',
    cancelText: 'Отмена',
    danger: true,
  });
  if (!confirmed) return;
  try {
    await withBusy(btn, async () => {
      await domainsPost({ list: name, action: 'clear' });
      showToast('Список очищен.');
      await refreshDomainList(name);
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function copyDomains() {
  const name = state.activeSubview;
  const data = state.domains[name];
  const btn = document.getElementById('domain-copy-btn');
  const items = data && Array.isArray(data.items) ? data.items.map((i) => i.value) : [];
  if (items.length === 0) {
    showToast('Список пуст, нечего копировать.', 'warning');
    return;
  }
  const text = items.join('\n');
  try {
    await withBusy(btn, async () => {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text);
        showToast(`Скопировано ${items.length} ${items.length === 1 ? 'запись' : 'записей'}.`);
      } else {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        ta.remove();
        showToast(`Скопировано ${items.length} ${items.length === 1 ? 'запись' : 'записей'}.`);
      }
    });
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function trialApplyStrategy(rowEl, strategyNum) {
  const domain = rowEl.dataset.value;
  const payload = await domainsPost({ list: 'custom_rkn', action: 'set_strategy', domain, strategy: String(strategyNum) });
  renderDomainCheck(rowEl.querySelector('.domain-check'), payload && payload.check);
  return payload;
}

function trialReadNum(rowEl) {
  const input = rowEl.querySelector('.trial-input');
  const n = Number(input.value, 10);
  return Number.isFinite(n) ? n : 1;
}

function trialWriteNum(rowEl, n) {
  const input = rowEl.querySelector('.trial-input');
  input.value = String(n);
}

function trialMax() {
  const data = state.domains.custom_rkn;
  const m = data ? data.max_strategy : 0;
  return Number.isFinite(m) && m > 0 ? m : 19;
}

async function openTrial(rowEl) {
  if (rowEl.classList.contains('is-expanded')) {
    closeTrial(rowEl, false);
    return;
  }

  document.querySelectorAll('#domain-items .domain-row.is-expanded').forEach((r) => {
    if (r !== rowEl) closeTrial(r, false);
  });

  const panel = rowEl.querySelector('.trial-panel');
  const max = trialMax();
  rowEl.querySelector('.trial-max').textContent = `из ${max}`;

  const data = state.domains.custom_rkn;
  const item = data && Array.isArray(data.items)
    ? data.items.find((it) => it.value === rowEl.dataset.value)
    : null;
  const startNum = item && Number.isFinite(item.strategy) && item.strategy > 0 ? item.strategy : 1;
  trialWriteNum(rowEl, startNum);
  panel.hidden = false;
  rowEl.classList.add('is-expanded');

  try {
    await trialApplyStrategy(rowEl, startNum);
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function closeTrial(rowEl, restore) {
  const panel = rowEl.querySelector('.trial-panel');
  panel.hidden = true;
  rowEl.classList.remove('is-expanded');
  if (restore) {
    const domain = rowEl.dataset.value;
    try {
      await domainsPost({ list: 'custom_rkn', action: 'clear_strategy', domain });
    } catch (error) {
      showToast(error.message, 'error');
    }
    await refreshDomainList('custom_rkn');
  }
}

async function trialNext(rowEl) {
  const max = trialMax();
  let n = trialReadNum(rowEl);
  if (n + 1 > max) {
    showToast('Достигнута максимальная стратегия.', 'warning');
    return;
  }
  n = n + 1;
  trialWriteNum(rowEl, n);
  try {
    await withBusy(rowEl.querySelector('.trial-next'), async () => {
      await trialApplyStrategy(rowEl, n);
    });
    showToast(`Применена стратегия ${n}. Проверьте доступ.`);
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function trialStep(rowEl, step) {
  const max = trialMax();
  let n = trialReadNum(rowEl) + step;
  if (n < 1) n = 1;
  if (n > max) n = max;
  trialWriteNum(rowEl, n);
  try {
    await trialApplyStrategy(rowEl, n);
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function trialSave(rowEl) {
  const n = trialReadNum(rowEl);
  try {
    await withBusy(rowEl.querySelector('.trial-save'), async () => {
      await trialApplyStrategy(rowEl, n);
    });
    showToast(`Стратегия ${n} сохранена для ${rowEl.dataset.value}.`);
    const panel = rowEl.querySelector('.trial-panel');
    panel.hidden = true;
    rowEl.classList.remove('is-expanded');
    await refreshDomainList('custom_rkn');
  } catch (error) {
    showToast(error.message, 'error');
  }
}

document.getElementById('domain-items').addEventListener('click', async (event) => {
  const rowEl = event.target.closest('.domain-row');
  if (!rowEl) return;
  const value = rowEl.dataset.value;
  if (event.target.classList.contains('remove-btn')) {
    await removeDomain(value);
  } else if (event.target.classList.contains('domain-check-btn')) {
    await checkDomain(value);
  } else if (event.target.classList.contains('trial-btn')) {
    await withBusy(event.target, () => openTrial(rowEl));
  } else if (event.target.classList.contains('trial-save')) {
    await trialSave(rowEl);
  } else if (event.target.classList.contains('trial-next')) {
    await trialNext(rowEl);
  } else if (event.target.classList.contains('trial-cancel')) {
    await closeTrial(rowEl, true);
  } else if (event.target.classList.contains('trial-step')) {
    const step = Number(event.target.dataset.step, 10);
    await trialStep(rowEl, Number.isFinite(step) ? step : 0);
  }
});

document.getElementById('domain-add-form').addEventListener('submit', (event) => {
  event.preventDefault();
  addDomainFromForm();
});

document.getElementById('domain-import-btn').addEventListener('click', () => {
  importDomains();
});

document.getElementById('domain-copy-btn').addEventListener('click', () => {
  copyDomains();
});

document.getElementById('domain-clear-btn').addEventListener('click', () => {
  clearDomains();
});

document.getElementById('refresh-domains').addEventListener('click', (event) => {
  withBusy(event.currentTarget, refreshDomains).catch((e) => showToast(e.message, 'error'));
});

document.querySelectorAll('.subtab').forEach((tab) => {
  tab.addEventListener('click', () => switchSubview(tab.dataset.subview));
});

initTheme();

Promise.all([
  refreshAll()
    .catch((error) => {
      showToast(error.message, 'error');
    })
    .finally(() => {
      document.getElementById('view-status').classList.remove('is-loading');
    }),
  refreshTlsBlobSettings().catch((error) => {
    showToast(error.message, 'error');
  }),
  refreshWgBlobSettings().catch((error) => {
    showToast(error.message, 'error');
  }),
  refreshWgStateSettings().catch((error) => {
    console.error('WG state settings error:', error);
  }),
  refreshUdpGamesSettings().catch((error) => {
    console.error('UDP games settings error:', error);
  }),
  refreshFallbackSettings().catch((error) => {
    console.error('Fallback settings error:', error);
  }),
  ...MODE_TOGGLES.map((toggle) => refreshModeSetting(toggle).catch((error) => {
    console.error(`Mode setting "${toggle.setting}" error:`, error);
  })),
  refreshPorts().catch((error) => {
    console.error('Ports settings error:', error);
  }),
  refreshProvider().catch((error) => {
    console.error('Provider settings error:', error);
  }),
  refreshBackups().catch((error) => {
    console.error('Backups error:', error);
  }),
]);

document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => switchView(tab.dataset.view));
});

const brandLink = document.getElementById('brand-link');
if (brandLink) {
  const goStatus = () => switchView('status');
  brandLink.addEventListener('click', goStatus);
  brandLink.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      goStatus();
    }
  });
}

document.getElementById('open-strategies').addEventListener('click', () => switchView('strategies'));
document.getElementById('refresh-status').addEventListener('click', (event) => {
  withBusy(event.currentTarget, refreshAll).catch((e) => showToast(e.message, 'error'));
});
document.getElementById('refresh-locks').addEventListener('click', (event) => {
  withBusy(event.currentTarget, refreshAll).catch((e) => showToast(e.message, 'error'));
});

async function runServiceAction(button, action) {
  const successMessages = {
    start: 'zapret2 включен.',
    stop: 'zapret2 выключен.',
    restart: 'zapret2 перезапущен.',
  };
  const successMessage = successMessages[action] || 'Команда выполнена.';
  try {
    await withBusy(button, async () => {
      await api('/cgi-bin/service.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ action }),
      });
      await refreshAll();
    });
    showToast(successMessage);
  } catch (error) {
    showToast(error.message, 'error');
  }
}

document.getElementById('toggle-service').addEventListener('click', (event) => {
  const action = event.currentTarget.dataset.action || (state.status?.zapret2_running ? 'stop' : 'start');
  runServiceAction(event.currentTarget, action);
});

document.getElementById('restart-service').addEventListener('click', (event) => {
  runServiceAction(event.currentTarget, 'restart');
});

document.getElementById('run-check').addEventListener('click', async (event) => {
  try {
    const payload = await withBusy(event.currentTarget, () => api('/cgi-bin/check.cgi', { method: 'POST' }));
    renderCheckResults(document.getElementById('check-results'), payload, 'Нет результатов проверки.');
    showToast('Проверка завершена.');
  } catch (error) {
    showToast(error.message, 'error');
  }
});
