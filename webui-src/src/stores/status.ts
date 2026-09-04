import { reactive, ref } from 'vue'
import { fetchScopes, fetchStatus } from '../api/endpoints'
import type { CheckPayload, ProfileInfo, ScopesPayload, StatusPayload } from '../api/types'

export const status = ref<StatusPayload | null>(null)
export const locks = ref<ProfileInfo[]>([])
export const scopes = ref<ScopesPayload>({ enabled: false, warning: '', scopes: ['default'] })
export const scope = ref('default')
export const statusLoaded = ref(false)
export const strategyChecks = reactive<Record<string, CheckPayload>>({})
export const statusCheck = ref<CheckPayload | null>(null)
export const statusCheckRan = ref(false)

export async function refreshAll() {
  const payload = await fetchStatus(scope.value)
  status.value = payload
  locks.value = payload.profiles || []
  try {
    scopes.value = await fetchScopes()
  } catch {
    // определение scope необязательно для старых роутеров
  }
}
