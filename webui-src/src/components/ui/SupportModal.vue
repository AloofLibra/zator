<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue'

const open = ref(false)
const visible = ref(false)
const closeButton = ref<HTMLButtonElement | null>(null)
const selectedJokes = ref<string[]>([])

const jokes = [
  '💸 Кнопка «задонатить» сломалась ещё до релиза.',
  '🧙 Лучший донат — когда интернет снова работает, а авторы гадают почему.',
  '☕ Ваше «спасибо» греет сильнее кофе и не требует настраивать платёжный шлюз.',
  '🛠️ Каждый найденный баг уже считается материальной поддержкой проекта.',
  '📡 Мы принимаем только сигналы, логи и рассказы о том, что опять заблокировали.',
  '🎰 Ваш роутер сегодня особенно стабилен? Считайте, вы уже сделали большой вклад.',
  '🦆 Денежные переводы не проходят проверку стратегий. А добрые слова — проходят.',
  '🚀 Одна звезда на GitHub — и где-то один разработчик начинает верить в светлое будущее.',
  '🧪 Мы тестировали приём денег, но тест внезапно стал бесконечным.',
  '🧘 Поддержать проект можно мысленно. Но ещё лучше — написать «спасибо» в Telegram.',
  '🧹 Расскажите друзьям — это бесплатный способ добавить проекту пропускной способности.',
  '🐛 Если обход заработал, просто улыбнитесь. Для авторов это уже отличный гонорар.',
  '💸 Переводы денег блокируются надёжнее, чем YouTube. Мы даже немного завидуем.',
  '🧩 Донат-форма не прошла проверку стратегий: слишком много нулей в нужных местах.',
  '🐢 Деньги до нас шли бы дольше, чем TLS-хендшейк через плохой маршрут.',
  '🛰️ Ваша стратегия держится третью неделю подряд? Считайте это нашим совместным достижением.',
  '📮 Напишите в Telegram, что у вас всё грузится. Такие сообщения мы храним бережнее бэкапов.',
  '🎁 Лучший подарок — pull request с фиксом. Второй по ценности — issue с логом внутри.',
  '🔊 Поставьте гимн на репит: каждый прослушанный байт уже считается вкладом.',
  '🌍 Расскажите провайдеру, что у вас всё открывается. Ему будет очень интересно.',
  '🚦 Локи бесплатно, RST-защита бесплатно, чувство контролируемого интернета — бесценно.',
  '🧠 Разобрались, что такое безразборный режим? Поздравляем, вы теперь часть команды.',
]

function pickJokes() {
  selectedJokes.value = [...jokes]
    .sort(() => Math.random() - 0.5)
    .slice(0, 3)
}

// Гимн Zator: стримится прямо в браузере, на роутер ничего не скачивается.
// Зеркала перебираются по порядку, пока одно не ответит.
const anthemMirrors = [
  'https://darkmaz-site.ru/Zator.mp3',
]
const anthemVisible = ref(false)
const anthemFailed = ref(false)
const anthemIndex = ref(0)
const anthemAudio = ref<HTMLAudioElement | null>(null)

function anthemStart() {
  const el = anthemAudio.value
  if (!el) return
  if (anthemIndex.value >= anthemMirrors.length) {
    anthemFailed.value = true
    el.removeAttribute('src')
    el.load()
    return
  }
  el.src = anthemMirrors[anthemIndex.value]
  el.load()
  void el.play().catch(() => { /* автозапуск не разрешён — есть кнопка play */ })
}

function onAnthemError() {
  if (anthemFailed.value) return
  anthemIndex.value += 1
  anthemStart()
}

function toggleAnthem() {
  anthemVisible.value = !anthemVisible.value
  if (anthemVisible.value) {
    anthemFailed.value = false
    anthemIndex.value = 0
    nextTick(anthemStart)
  } else {
    anthemAudio.value?.pause()
  }
}

function openModal() {
  pickJokes()
  open.value = true
  requestAnimationFrame(() => {
    visible.value = true
    nextTick(() => closeButton.value?.focus())
  })
}

function closeModal() {
  anthemAudio.value?.pause()
  visible.value = false
  window.setTimeout(() => { open.value = false }, 180)
}

function onKeydown(event: KeyboardEvent) {
  if (open.value && event.key === 'Escape') {
    event.preventDefault()
    closeModal()
  }
}

onMounted(() => document.addEventListener('keydown', onKeydown, true))
onBeforeUnmount(() => document.removeEventListener('keydown', onKeydown, true))
</script>

<template>
  <button id="support-project-btn" type="button" class="support-button" @click="openModal">
    ❤️ Поддержать проект
  </button>

  <div v-if="open" :class="['modal-overlay', { 'is-visible': visible }]" role="dialog" aria-modal="true"
    aria-labelledby="support-modal-title" @click.self="closeModal">
    <div class="modal-card support-modal-card">
      <div class="support-modal-heading">
        <span class="support-emoji" aria-hidden="true">🫡</span>
        <div>
          <h2 id="support-modal-title" class="modal-title">Поддержать проект</h2>
          <p class="modal-message">Денежку авторы не принимают: у нас и так достаточно богатства в виде логов, багов и внезапных идей.</p>
        </div>
      </div>

      <div class="support-jokes" aria-label="Почему денежку не принимают">
        <p v-for="joke in selectedJokes" :key="joke">{{ joke }}</p>
      </div>

      <p class="modal-message">Если проект пригодился, загляните в нашу Telegram-группу и скажите спасибо. А ещё можно поставить звёздочку на GitHub — это главный ритуал призыва новых контрибьюторов.</p>

      <div class="support-links">
        <a class="support-link telegram-link" href="https://t.me/zee4r" target="_blank" rel="noopener noreferrer">
          <span aria-hidden="true">✈️</span> Зайти в Telegram
        </a>
        <a class="support-link github-link" href="https://github.com/AloofLibra/zator" target="_blank" rel="noopener noreferrer">
          <span aria-hidden="true">⭐</span> Поставить звезду на GitHub
        </a>
      </div>

      <div class="support-anthem">
        <button type="button" class="support-link anthem-link" @click="toggleAnthem">
          <span aria-hidden="true">🎵</span> {{ anthemVisible ? 'Остановить гимн' : "Гимн Zator'a" }}
        </button>
        <template v-if="anthemVisible">
          <p class="anthem-hint">Играет прямо в браузере — на роутер ничего не скачивается. Если зеркало недоступно, попробуется следующее. Скачать — через меню плеера (⋮ три вертикальные точки).</p>
          <audio v-if="!anthemFailed" ref="anthemAudio" controls preload="none" class="anthem-audio" @error="onAnthemError"></audio>
          <p v-else class="anthem-failed">Все зеркала гимна недоступны — попробуйте позже.</p>
        </template>
      </div>

      <div class="modal-actions">
        <button ref="closeButton" type="button" class="ghost modal-cancel" @click="closeModal">Закрыть</button>
      </div>
    </div>
  </div>
</template>
