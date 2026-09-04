# webui-src — исходники Web-панели (z2r Web UI)

Фронтенд Web-панели управления zapret2. Написан на **Vue 3 + TypeScript**,
собирается **Vite** в три обычных статических файла, которые сервер
(uhttpd / busybox httpd на роутере) отдаёт без каких-либо требований к
браузеру — даже старые Android WebView работают.

> Файлы `webui/app.js`, `webui/styles.css`, `webui/index.html` —
> **собранные артефакты**. Их не редактируют руками: правьте сорсы здесь,
> пересобирайте и коммитьте вместе. Устройства пользователей скачивают эти
> три файла поимённо с ветки `zator`, поэтому артефакты всегда обязаны
> лежать в репозитории и соответствовать исходникам.

## Требования

| Инструмент | Версия | Для чего |
| --- | --- | --- |
| Node.js | **>= 18** (рекомендуется LTS 20+) | сборка и dev-сервер |
| npm | идёт с Node | зависимости |
| Python 3 | любой | `webui/dev/fake_router_server.py` (локальные тесты без роутера) |

Установка зависимостей — один раз:

```bash
cd webui-src
npm install
```

## Команды

```bash
npm run dev     # dev-сервер Vite (http://127.0.0.1:5173) с hot-reload
npm run build   # сборка в ../webui + простановка ?v=<sha256>
npm run check   # проверка типов vue-tsc (без сборки)
```

## Разработка с фейк-сервером (без роутера)

Рядом лежит `webui/dev/fake_router_server.py` — полный мэк бэкенда на
чистом Python (без pip-зависимостей). Он воспроизводит все CGI-эндпоинты
(включая агрегирующий `state.cgi`), хранит состояние во временной папке и
умеет симулировать ошибки, задержки и разные состояния сервиса.

Два режима:

1. **Hot-reload (основной):** в одном терминале поднимите мэк, в другом — Vite:

   ```bash
   python webui/dev/fake_router_server.py          # бэкенд-моки на :8099
   cd webui-src && npm run dev                     # Vite на :5173
   ```

   Откройте http://127.0.0.1:5173/ — запросы `/cgi-bin/*` уже
   проксируются на фейк-сервер (настроено в `vite.config.ts`).

2. **Проверка собранного бандла (как на устройстве):**

   ```bash
   npm run build
   python webui/dev/fake_router_server.py          # отдаёт webui/ на :8099
   ```

   Откройте http://127.0.0.1:8099/ — это ровно те файлы, которые поедут
   на роутер.

Полезные флаги фейк-сервера: `--service-state=stopped`, `--lock-state="2=5,4=0"`,
`--check-result=ok|fail|mixed|random`, `--simulate-error=settings`,
`--delay=3`, `--status-delay=3`; переключать состояние на ходу —
`POST /__dev/state`. Полный контракт ответов — в
`webui/dev/API_CONTRACT.md` (источник правды для мэка и TypeScript-типов).

## Сборка и деплой

- Сборка выдаёт **ровно три файла** в `../webui/`: `app.js` (один
  классический IIFE-скрипт, es2018, без sourcemap и чанков), `styles.css`
  и `index.html`. Такой состав — контракт установки `z2r.sh`: файлы
  качаются поимённо и кладутся в `/opt/zator/webui/www/`.
- `scripts/stamp-assets.mjs` автоматически проставляет в `index.html`
  `?v=<первые 8 символов sha256>` для `app.js`/`styles.css`/`favicon.svg`
  — после каждого обновления браузеры пользователей забирают свежие
  файлы, ручные `?v=15` не нужны.
- Коммитьте исходники и пересобранные артефакты **одним коммитом**.
- Проверка консистентности артефактов — `bash tests/webui_build_smoke.sh`
  (состав файлов, порядок тегов, совпадение `?v=` с хэшем).

Проверка на живом роутере: скопируйте три собранных файла в
`/opt/zator/webui/www/` и обновите страницу — смена `?v=` сама сбросит кэш.

## Структура

```
webui-src/
├─ index.html            # вход vite (мета + <script type="module" src="/src/main.ts">)
├─ vite.config.ts        # outDir ../webui, IIFE, dev-proxy /cgi-bin → :8099
├─ scripts/stamp-assets.mjs
└─ src/
   ├─ main.ts            # createApp + router + импорт стилей
   ├─ App.vue            # шапка (табы, тема), <router-view>, тосты, модалки, «наверх»
   ├─ router/index.ts    # hash-роутер + запрет навигации при операциях/загрузке
   ├─ api/               # client (fetch-обёртка), types (по API_CONTRACT.md), endpoints
   ├─ stores/            # состояние на composables (без Pinia):
   │                     #   status, settings, domains, backups, busy, toast,
   │                     #   confirm, theme, state (агрегированная загрузка)
   ├─ composables/       # useApiAction
   ├─ components/
   │  ├─ ui/             # ToastHost, ConfirmDialog, StatCard, NumberStepper, CheckResults
   │  ├─ status/         # StatusCards (карточки→ссылки/CLI), ServiceControls, ProfileGrid
   │  ├─ strategies/     # StrategyCard (лок-форма, inline-проверка, гейтинг)
   │  ├─ domains/        # DomainRow (trial-подбор стратегии)
   │  └─ settings/       # ModeTogglePanel (конфиг-Driven тумблеры) + отдельные панели
   ├─ views/             # StatusView, StrategiesView, DomainsView, SettingsView
   └─ styles/            # base.css (перенесён 1:1 из старого styles.css) + links.css
```

## Роутинг

`createWebHashHistory` — прямые ссылки вида `http://роутер:17682/#/settings/rst-guard`.
История (history-mode) невозможна: uhttpd/busybox httpd не умеют SPA-rewrite.

Маршруты: `/`, `/strategies` (`?scope=`, `?focus=N` — скролл к карточке
профиля с подсветкой), `/domains/:list`, `/settings/:panel` (13 панелей,
диплинк скроллит к панели и подсвечивает кольцом 6с).

## Архитектурные договорённости

- **Состояние** — простые composables-модули (`ref`/`reactive`), без Pinia
  и vuex. Один агрегирующий запрос `GET /cgi-bin/state.cgi` на старте и по
  кнопкам «Обновить»; точечные `settings.cgi?setting=…` — только
  перепроверка после изменения одной настройки. Не возвращайтесь к
  «куче запросов на старте»: на слабых роутерах каждый CGI — новый процесс.
- **busy-lock**: любая мутация идёт через `withBusy(key, fn)` — блокируются
  все контролы и навигация; у кнопки-инициатора спиннер (`busyButton`).
- **Гейтинг** профилей — `src/gating.ts` (единое место: тексты причин,
  `gatedPanel()` для ссылки «перейти к настройке»).
- **Тумблеры настроек** описываются конфигом `components/settings/modeToggles.ts`
  (тексты, чипы, конфирмы) и рендерятся одним `ModeTogglePanel` — новый
  тумблер = новая запись в конфиге, без копипасты.
- **Данные на «Доменах»** ленивые (грузятся при входе на вкладку), с
  индикатором «Пожалуйста подождите…».

## Стили

- `src/styles/base.css` — перенесён из старой вёрстки практически 1:1;
  тема на CSS-переменных (`--accent`, `--surface`, …), тёмная — через
  `html[data-theme]`. Старайтесь не менять его без нужды.
- `src/styles/links.css` — всё новое: кликабельные карточки, кольцо
  подсветки `is-target`, кнопка «наверх», ссылка-кнопка `a.ghost`.
- Подсветка цели (`scrollIntoView` + класс `is-target`) — единый паттерн
  для панелей настроек, карточек стратегий и результатов проверки.
- Отступ диплинка — `scroll-margin-top: 18px` у `.panel`/`.profile-card`.

## Правила кода

- TypeScript strict; типы ответов — в `src/api/types.ts` строго по
  `webui/dev/API_CONTRACT.md`.
- Комментарии — минимальные, только неочевидные ограничения, по-русски.
- Все тексты интерфейса — русские, формулировки переносите дословно из
  старой панели (пользовательские привычки + их проверяют смоки).
- **Не переименовывайте id элементов** (`auto-mode-form`, `ports-tcp-form`,
  `backup-create-btn`, `domains-panel`, …) и классы `checks domain-check`,
  `check-pair`, `fallback-hint` — смок-тесты грепают их по исходникам
  `webui-src/src/**` (минифицированный бандл не проверяется).
- Изменение API CGI → синхронно правьте: `_lib.sh`, `fake_router_server.py`,
  `API_CONTRACT.md`, `src/api/types.ts`.
