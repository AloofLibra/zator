export interface ModeConfirmTexts {
  titleOn: string
  messageOn: string[]
  titleOff: string
  messageOff: string[]
}

export interface ModeToggleConfig {
  setting: string
  panelId: string
  title: string
  beta?: boolean
  descriptions: string[]
  postKey: string
  formId: string
  chipId: string
  enabledField: 'enabled' | 'auto'
  toggleLabel: string
  onChip: string
  offChip: string
  onToast: string
  offToast: string
  askConfirm?: ModeConfirmTexts
}

export const MODE_TOGGLES: ModeToggleConfig[] = [
  {
    setting: 'auto_mode',
    panelId: 'auto-mode',
    title: 'Авторотация TCP/HTTP',
    descriptions: [
      'Автоматический подбор стратегий: zapret2 сам тестирует стратегии TCP/HTTP и переключает их при сбоях. Сервис перезапускается автоматически.',
      'Пока авторотация включена, ручная фиксация стратегий профилей 1–4 и безразборный режим недоступны — они противоречат авторотации. Выключите её, если хотите полностью управлять стратегиями вручную.',
    ],
    postKey: 'auto_mode_state',
    formId: 'auto-mode-form',
    chipId: 'auto-mode-chip',
    enabledField: 'enabled',
    toggleLabel: 'Автоматически подбирать и менять стратегии',
    onChip: 'включена',
    offChip: 'выключена',
    onToast: 'Авторотация включена.',
    offToast: 'Авторотация выключена.',
    askConfirm: {
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
    panelId: 'hostlist',
    title: 'Фильтрация по спискам',
    descriptions: [
      'Определяет, какие соединения попадают под обход. В режиме «по листам» обход применяется только к доменам из ваших списков.',
      'В режиме «автосбор» zapret2 дополнительно сам определяет заблокированные домены и пополняет список — обход работает шире, но список растёт. Пока автосбор включён, ручное добавление доменов в RKN-списки (TCP_Custom и подстроки RKN) отключено: их пополняет zapret2. Списки исключений работают как обычно.',
      'При изменении zapret2 перезапускается автоматически.',
    ],
    postKey: 'hostlist_state',
    formId: 'hostlist-form',
    chipId: 'hostlist-chip',
    enabledField: 'auto',
    toggleLabel: 'Автоматически пополнять списки (autohostlist)',
    onChip: 'автосбор',
    offChip: 'по листам',
    onToast: 'Автосбор списков включён.',
    offToast: 'Фильтрация только по спискам.',
    askConfirm: {
      titleOn: 'Включить автосбор списков?',
      messageOn: [
        'zapret2 начнёт сам определять заблокированные домены и пополнять список — обход будет работать шире.',
        'Пока автосбор включён, добавление доменов в RKN-списки (TCP_Custom и подстроки RKN) отключено. Списки исключений не затрагиваются.',
        'zapret2 перезапустится сразу.',
      ],
      titleOff: 'Выключить автосбор списков?',
      messageOff: [
        'Обход снова будет применяться только к доменам из ваших списков.',
        'Ручное добавление доменов в RKN-списки вернётся.',
        'zapret2 перезапустится сразу.',
      ],
    },
  },
  {
    setting: 'rst_guard',
    panelId: 'rst-guard',
    title: 'Защита от RST-инъекций',
    beta: true,
    descriptions: [
      'ТСПУ может принудительно разрывать соединения поддельными RST-пакетами. Защита переключает стратегии на устойчивый к этому режим работы.',
      'Функция экспериментальная: если соединения станут менее стабильными, выключите её. При изменении zapret2 перезапускается автоматически.',
    ],
    postKey: 'rst_guard_state',
    formId: 'rst-guard-form',
    chipId: 'rst-guard-chip',
    enabledField: 'enabled',
    toggleLabel: 'Включить защиту от RST-инъекций',
    onChip: 'включена',
    offChip: 'выключена',
    onToast: 'Защита от RST-инъекций включена.',
    offToast: 'Защита от RST-инъекций выключена.',
  },
  {
    setting: 'reasm',
    panelId: 'reasm',
    title: 'Склейка фрагментов (--reasm-disable)',
    descriptions: [
      'Отключает склейку больших пакетов из фрагментов при анализе средствами NFQWS2.',
      'Параметр нужен, только если на роутере не удаётся или не хочется отключать аппаратное ускорение: NFQWS2 задерживает первый фрагмент, роутер отправляет второй напрямую в сеть, и соединение ломается.',
      'Проблема чаще актуальна на Keenetic и Netcraze.',
      'OpenWRT по умолчанию работает с отключённым ускорением.',
      'Быстрая проверка: откройте в новом инкогнито-окне картинку-тест — если она открывается, параметр обычно не нужен. При изменении zapret2 перезапускается автоматически.',
    ],
    postKey: 'reasm_state',
    formId: 'reasm-form',
    chipId: 'reasm-chip',
    enabledField: 'enabled',
    toggleLabel: 'Включить параметр --reasm-disable',
    onChip: 'включен',
    offChip: 'выключен',
    onToast: 'Параметр --reasm-disable включён.',
    offToast: 'Параметр --reasm-disable выключен.',
  },
  {
    setting: 'quic443',
    panelId: 'quic443',
    title: 'Фейки QUIC (UDP 443)',
    descriptions: [
      'Отправляет фейковые QUIC-пакеты инициализации для всего UDP-трафика на порту 443, не только для YouTube.',
      'Выключите, если видео или приложения на QUIC начали работать хуже. При изменении zapret2 перезапускается автоматически.',
    ],
    postKey: 'quic443_state',
    formId: 'quic443-form',
    chipId: 'quic443-chip',
    enabledField: 'enabled',
    toggleLabel: 'Включить фейки для всех QUIC-соединений на порту 443',
    onChip: 'включены',
    offChip: 'выключены',
    onToast: 'Фейки QUIC на порту 443 включены.',
    offToast: 'Фейки QUIC на порту 443 выключены.',
  },
  {
    setting: 'dns_desync',
    panelId: 'dns-desync',
    title: 'Антиспуф DNS (профиль 10)',
    descriptions: [
      'Защита от подмены DNS-ответов провайдером на UDP:53 — клон запроса с малым TTL и дроп поддельного ответа.',
      'Включите режим, затем выберите стратегию для профиля 10 во вкладке «Стратегии»: после сохранения резолв проверяется автоматически. При изменении zapret2 перезапускается автоматически.',
    ],
    postKey: 'dns_desync_state',
    formId: 'dns-desync-form',
    chipId: 'dns-desync-chip',
    enabledField: 'enabled',
    toggleLabel: 'Включить антиспуф DNS',
    onChip: 'включен',
    offChip: 'выключен',
    onToast: 'Антиспуф DNS включён.',
    offToast: 'Антиспуф DNS выключен.',
  },
]
