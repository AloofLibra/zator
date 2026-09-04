import { reactive, ref } from 'vue'
import { fetchDomainsList } from '../api/endpoints'
import type { CheckPayload, DomainsListPayload } from '../api/types'
import { showToast } from './toast'

export const DOMAIN_LISTS = ['netrogat', 'custom_rkn', 'substring', 'netrogat_substring'] as const
export type DomainListName = typeof DOMAIN_LISTS[number]

export const DOMAIN_META: Record<DomainListName, { kind: string; addLabel: string; placeholder: string; itemName: string }> = {
  netrogat: { kind: 'domain', addLabel: 'Домен', placeholder: 'example.com', itemName: 'Домен' },
  custom_rkn: { kind: 'domain', addLabel: 'Домен', placeholder: 'example.com', itemName: 'Домен' },
  substring: { kind: 'substring', addLabel: 'Подстрока', placeholder: 'cdn, media, static, …', itemName: 'Подстрока' },
  netrogat_substring: { kind: 'substring', addLabel: 'Подстрока', placeholder: 'bank, shop, gov, …', itemName: 'Подстрока' },
}

export const domainLists = reactive<Record<DomainListName, DomainsListPayload | null>>({
  netrogat: null,
  custom_rkn: null,
  substring: null,
  netrogat_substring: null,
})
export const domainChecks = reactive<Record<string, CheckPayload>>({})
export const expandedDomain = ref<string | null>(null)

export async function refreshDomainList(name: DomainListName) {
  try {
    domainLists[name] = await fetchDomainsList(name)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

export async function refreshDomains() {
  await Promise.all(DOMAIN_LISTS.map((name) => refreshDomainList(name)))
}
