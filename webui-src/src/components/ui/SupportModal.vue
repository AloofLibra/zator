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
]

function pickJokes() {
  selectedJokes.value = [...jokes]
    .sort(() => Math.random() - 0.5)
    .slice(0, 3)
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

      <div class="modal-actions">
        <button ref="closeButton" type="button" class="ghost modal-cancel" @click="closeModal">Закрыть</button>
      </div>
    </div>
  </div>
</template>
