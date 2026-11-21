import { ref } from 'vue'
import { fetchCustomBlobs } from '../api/endpoints'
import type { CustomBlobsPayload, SniProfileInfo, SniSetInfo } from '../api/types'

// Единый на вкладку «Блобы и SNI» SNI-стейт: blobs.cgi отдаёт и список
// своих блобов, и sni-блок — раньше вкладка запрашивала его трижды
// (карта профилей, SniPanel, список блобов), и на слабых роутерах это
// стояло в фоне полминуты. Теперь один GET на загрузку/«Обновить»,
// все карточки читают этот стор.
export const sniProfiles = ref<SniProfileInfo[]>([])
export const sniSets = ref<SniSetInfo[]>([])
export const sniUnavailable = ref(false)
export const customBlobsPayload = ref<CustomBlobsPayload | null>(null)

export function applySniPayload(data: CustomBlobsPayload) {
  customBlobsPayload.value = data
  sniUnavailable.value = !data.sni
  sniProfiles.value = Array.isArray(data.sni?.profiles) ? (data.sni?.profiles || []) : []
  sniSets.value = Array.isArray(data.sni?.sets) ? (data.sni?.sets || []) : []
}

export async function refreshSniState(): Promise<CustomBlobsPayload> {
  const data = await fetchCustomBlobs()
  applySniPayload(data)
  return data
}
