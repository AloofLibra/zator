const state = {
  locks: [],
  status: null,
  strategyChecks: {},
};

const views = {
  status: document.getElementById('view-status'),
  strategies: document.getElementById('view-strategies'),
};

const busyLabels = new WeakMap();

function showBanner(message, type = 'success') {
  const banner = document.getElementById('banner');
  banner.textContent = message;
  banner.className = `banner ${type}`;
  banner.hidden = false;
  window.clearTimeout(showBanner._timer);
  showBanner._timer = window.setTimeout(() => {
    banner.hidden = true;
  }, 3500);
}

function setBusy(element, busy, label) {
  if (!element) return;
  if (busy) {
    if (!busyLabels.has(element)) {
      busyLabels.set(element, element.textContent);
    }
    element.disabled = true;
    element.setAttribute('aria-busy', 'true');
    if (label) {
      element.textContent = label;
    }
    return;
  }
  element.disabled = false;
  element.removeAttribute('aria-busy');
  if (busyLabels.has(element)) {
    element.textContent = busyLabels.get(element);
    busyLabels.delete(element);
  }
}

async function withBusy(element, label, task) {
  setBusy(element, true, label);
  try {
    return await task();
  } finally {
    setBusy(element, false);
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
  Object.entries(views).forEach(([name, element]) => {
    element.classList.toggle('is-active', name === view);
  });
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.classList.toggle('is-active', tab.dataset.view === view);
  });
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
    ['zapret2', state.status.zapret2_running ? 'Запущен' : 'Остановлен'],
    ['Локи стратегий', state.status.strategy_locks_status],
    ['Фильтр', state.status.hostlist_mode],
    ['FW', state.status.fwtype],
    ['Offload', state.status.flowoffload],
    ['TLS blob', state.status.tls_blob_mode],
  ];

  cards.forEach(([label, value]) => {
    const node = statTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector('.label').textContent = label;
    node.querySelector('.value').textContent = value ?? '—';
    statusCards.appendChild(node);
  });

  const profiles = Array.isArray(state.status.profiles) ? state.status.profiles : [];
  profiles.forEach((profile) => {
    const node = profileTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector('h3').textContent = profile.label;
    node.querySelector('.desc').textContent = profile.description;
    node.querySelector('.current-lock').textContent = profile.current_lock || '0';
    statusProfiles.appendChild(node);
  });
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
    node.querySelector('.current-lock').textContent = profile.current_lock || '0';
    node.querySelector('.max-lock').textContent = String(profile.max_strategy);

    const input = node.querySelector('input');
    const form = node.querySelector('.lock-form');
    const submitButton = form.querySelector('button[type="submit"]');
    const clearButton = node.querySelector('.clear-lock');
    const inlineCheck = node.querySelector('.inline-check');
    const stepButtons = node.querySelectorAll('.step-strategy');

    input.min = '1';
    input.max = String(profile.max_strategy);
    if (profile.current_lock && profile.current_lock !== '0') {
      input.value = profile.current_lock;
    }
    if (state.strategyChecks[profile.profile]) {
      renderCheckResults(inlineCheck, state.strategyChecks[profile.profile], 'Нет результатов быстрой проверки.', false);
    }

    stepButtons.forEach((button) => {
      button.addEventListener('click', () => {
        const step = Number(button.dataset.step || 0);
        const min = Number(input.min || 1);
        const max = Number(input.max || profile.max_strategy || min);
        const current = Number(input.value || profile.current_lock || min);
        const next = Math.min(max, Math.max(min, current + step));
        input.value = String(next);
        input.dispatchEvent(new Event('input', { bubbles: true }));
      });
    });

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const value = Number(input.value);
      if (!value) {
        showBanner('Введите номер стратегии.', 'error');
        return;
      }
      try {
        let payload = null;
        await withBusy(submitButton, 'Сохранение и проверка...', async () => {
          payload = await api('/cgi-bin/set-lock.cgi', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ profile: profile.profile, strategy: value }),
          });
          state.strategyChecks[profile.profile] = payload?.check;
          await refreshAll();
        });
        showBanner(`Стратегия ${value} сохранена для ${profile.label}.`);
      } catch (error) {
        showBanner(error.message, 'error');
      }
    });

    clearButton.addEventListener('click', async () => {
      try {
        await withBusy(clearButton, 'Сброс...', async () => {
          await api('/cgi-bin/clear-lock.cgi', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ profile: profile.profile }),
          });
          delete state.strategyChecks[profile.profile];
          await refreshAll();
        });
        showBanner(`Lock снят для ${profile.label}.`);
      } catch (error) {
        showBanner(error.message, 'error');
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
}

initTheme();

document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => switchView(tab.dataset.view));
});

document.getElementById('open-strategies').addEventListener('click', () => switchView('strategies'));
document.getElementById('refresh-status').addEventListener('click', (event) => {
  withBusy(event.currentTarget, 'Обновление...', refreshAll).catch((e) => showBanner(e.message, 'error'));
});
document.getElementById('refresh-locks').addEventListener('click', (event) => {
  withBusy(event.currentTarget, 'Обновление...', refreshAll).catch((e) => showBanner(e.message, 'error'));
});

async function runServiceAction(button, action) {
  const labels = {
    start: ['Включение...', 'zapret2 включен.'],
    stop: ['Выключение...', 'zapret2 выключен.'],
    restart: ['Перезапуск...', 'zapret2 перезапущен.'],
  };
  const [busyLabel, successMessage] = labels[action] || ['Выполнение...', 'Команда выполнена.'];
  try {
    setBusy(button, true, busyLabel);
    await api('/cgi-bin/service.cgi', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ action }),
    });
    setBusy(button, false);
    await refreshAll();
    showBanner(successMessage);
  } catch (error) {
    setBusy(button, false);
    showBanner(error.message, 'error');
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
    const payload = await withBusy(event.currentTarget, 'Проверка...', () => api('/cgi-bin/check.cgi', { method: 'POST' }));
    renderCheckResults(document.getElementById('check-results'), payload, 'Нет результатов проверки.');
    showBanner('Проверка завершена.');
  } catch (error) {
    showBanner(error.message, 'error');
  }
});

refreshAll().catch((error) => {
  showBanner(error.message, 'error');
});
