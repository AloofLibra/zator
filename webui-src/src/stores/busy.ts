import { ref } from 'vue'

export const busyActive = ref(false)
// ключ кнопки, запустившей операцию — для спиннера button.is-busy
export const busyButton = ref<string | null>(null)

export async function withBusy<T>(button: string | null, task: () => Promise<T>): Promise<T> {
  busyActive.value = true
  busyButton.value = button
  try {
    return await task()
  } finally {
    busyActive.value = false
    busyButton.value = null
  }
}
