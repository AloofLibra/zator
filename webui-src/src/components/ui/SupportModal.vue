<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue'

const open = ref(false)
const visible = ref(false)
const closeButton = ref<HTMLButtonElement | null>(null)
const catMood = ref(0)
const catMoods = [
  { face: '(=－ω－=)', text: 'Спит на тёплом роутере. Видит сны про свободный интернет.' },
  { face: '(=＾ω＾=)', text: 'Мур-р-р. Ваш пакет принят на мягкую обработку.' },
  { face: '(=⊙ω⊙=)', text: 'Увидел огурец в таблице маршрутизации.' },
  { face: '(=ↀωↀ=)', text: 'Смотрит в пустоту. Пустота прислала SYN-ACK.' },
  { face: '(=￣ω￣=)', text: 'Сбросил пакет со стола. Так и было задумано.' },
]

// Гимн Zator: стримится прямо в браузере, на роутер ничего не скачивается.
// Зеркала перебираются по порядку, пока одно не ответит:
// основное — сервер автора, резервное — зеркало контрибьютора.
const anthemMirrors = [
  'https://alooflibra.fun/Zator.mp3',
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
  catMood.value = 0
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
          <p class="modal-message">Проект живёт благодаря людям. Спасибо всем, кто помогает ему становиться лучше!</p>
        </div>
      </div>

      <div class="support-community">
        <section class="support-credits" aria-labelledby="support-credits-title">
          <h3 id="support-credits-title">Спасибо за поддержку</h3>
          <h4>Помогли в разработке</h4>
          <ul class="support-names">
            <li>DarkMaz</li><li>Bank</li><li>a1ligat0r</li>
          </ul>
          <h4>Поддержали денежкой</h4>
          <ul class="support-names">
            <li>Wusspoppin</li><li>Швейк</li><li>BestFridayxD</li>
            <li>a1ligat0r</li><li>Данил</li><li>DarkMaz</li>
          </ul>
        </section>

        <section class="support-cat" aria-labelledby="support-cat-title">
          <h3 id="support-cat-title">Кот в роутере</h3>
          <div class="support-cat-mood" aria-live="polite" aria-atomic="true">
            <span class="support-cat-face" aria-hidden="true">{{ catMoods[catMood].face }}</span>
            <p>{{ catMoods[catMood].text }}</p>
          </div>
          <button type="button" class="ghost" @click="catMood = (catMood + 1) % catMoods.length">Погладить кота</button>
          <small>Ни пользы. Ни смысла. Только мур.</small>
        </section>
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
