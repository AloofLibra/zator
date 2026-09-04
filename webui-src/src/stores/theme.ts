import { ref, watch } from 'vue'

export type ThemeMode = 'auto' | 'light' | 'dark'

function loadTheme(): ThemeMode {
  const current = document.documentElement.dataset.theme
  if (current === 'light' || current === 'dark' || current === 'auto') return current
  return 'auto'
}

export const theme = ref<ThemeMode>(loadTheme())

watch(theme, (value) => {
  document.documentElement.dataset.theme = value
  try {
    localStorage.setItem('z2r-theme', value)
  } catch {
    // без хранилища тема действует до перезагрузки страницы
  }
})
