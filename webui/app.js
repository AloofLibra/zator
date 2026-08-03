const state = {
  locks: [],
  status: null,
  strategyChecks: {},
  tlsBlobSettings: null,
  wgBlobSettings: null,
  wgStateSettings: null,
  fallbackSettings: null,
  udpGamesSettings: null,
  domains: { netrogat: null, custom_rkn: null, substring: null },
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
      const msg = document.createElement('p');
      msg.className = 'modal-message';
      msg.textContent = message;
      card.appendChild(msg);
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
  submit.disabled = select.value === saved;
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

  const cards = [
    ['zapret2', state.status.zapret2_running ? 'Запущен' : 'Остановлен', state.status.zapret2_running ? 'ok' : 'bad'],
    ['Локи стратегий', state.status.strategy_locks_status],
    ['Фильтр', state.status.hostlist_mode],
    ['FW', state.status.fwtype],
    ['Offload', state.status.flowoffload],
    ['TLS blob', state.status.tls_blob_mode],
    ['WireGuard', state.status.wireguard, state.status.wireguard === 'включено' ? 'ok' : ''],
  ];

  cards.forEach(([label, value, stateClass]) => {
    const node = statTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector('.label').textContent = label;
    const valueEl = node.querySelector('.value');
    valueEl.textContent = value ?? '—';
    if (stateClass) valueEl.classList.add(stateClass);
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
    el.textContent = lock;
  }
}

const FALLBACK_CHECK_HINT = 'Безразборный режим: быстрая проверка неприменима (применяется ко всем доменам).';
const UDP_GAMES_CHECK_HINT = 'Игровой UDP: быстрая проверка неприменима (широкий диапазон портов).';

function isProfileGated(profile) {
  if (profile.is_fallback && !profile.fallback_enabled) return true;
  if (profile.is_udp_games && !profile.udp_games_enabled) return true;
  return false;
}

function gatedReason(profile) {
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
    appendText(pair, 'span', `TLS 1.2: ${item.tls12 ? 'OK' : 'FAIL'}`, item.tls12 ? 'ok' : 'bad');
    appendText(pair, 'span', `TLS 1.3: ${item.tls13 ? 'OK' : 'FAIL'}`, item.tls13 ? 'ok' : 'bad');

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

  statusChip.textContent = settings.current_mode;
  statusChip.className = 'chip';
  if (settings.current_mode === 'maxru') {
    statusChip.classList.add('is-ok');
  }

  currentFile.textContent = settings.current_blob || '—';

  select.innerHTML = '<option value="fake_default_tls">fake_default_tls (встроенный)</option>';

  if (Array.isArray(settings.available_blobs)) {
    settings.available_blobs.forEach(blob => {
      const option = document.createElement('option');
      option.value = blob;
      option.textContent = blob;
      if (blob === settings.current_blob) {
        option.selected = true;
      }
      select.appendChild(option);
    });
  }

  if (settings.current_blob && settings.current_blob !== 'fake_default_tls') {
    select.value = settings.current_blob;
  }

  select.dataset.saved = settings.current_blob || 'fake_default_tls';
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
  const isEnabled = settings.state === 'включен';

  const checkbox = stateForm.querySelector('input[type="checkbox"]');
  if (checkbox) {
    checkbox.checked = isEnabled;
    checkbox.dataset.saved = isEnabled ? '1' : '0';
  }

  const stateChip = document.getElementById('fallback-state-chip');
  if (stateChip) {
    stateChip.textContent = isEnabled ? 'включен' : 'выключен';
    stateChip.className = 'chip';
    if (isEnabled) {
      stateChip.classList.add('is-ok');
    }
  }

  updateFallbackSubmit();
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

    await withBusy(submitButton, async () => {
      try {
        await applyFallbackState(checkbox.checked);
        showToast(checkbox.checked ? 'Безразборный режим включён.' : 'Безразборный режим выключен.');
        await refreshFallbackSettings();
        await refreshAll();
      } catch (error) {
        showToast(error.message, 'error');
      }
    });
  });
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
    countEl.textContent = n > 0 ? `${n}` : '';
    countEl.className = 'chip';
    if (n > 0) countEl.classList.add('is-ok');
  }

  document.getElementById('domain-add-label').textContent = meta.addLabel;
  const addInput = document.getElementById('domain-add-input');
  addInput.placeholder = meta.placeholder;
  addInput.value = '';

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
    if (isCustomRkn) {
      const strat = Number.isFinite(item.strategy) ? item.strategy : 0;
      if (strat > 0) {
        stratChip.textContent = `страт: ${strat}`;
        stratChip.classList.add('is-ok');
      } else {
        stratChip.textContent = 'РКН стр.';
      }
      if (trialBtn) trialBtn.hidden = false;
    } else {
      stratChip.hidden = true;
      if (trialBtn) trialBtn.hidden = true;
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
  await domainsPost({ list: 'custom_rkn', action: 'set_strategy', domain, strategy: String(strategyNum) });
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
