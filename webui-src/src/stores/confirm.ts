import { ref } from 'vue'

export interface ConfirmOptions {
  title: string
  message?: string | string[]
  confirmText?: string
  cancelText?: string
  danger?: boolean
  info?: boolean
}

export const confirmState = ref<ConfirmOptions | null>(null)

let resolver: ((result: boolean) => void) | null = null

export function confirmDialog(options: ConfirmOptions): Promise<boolean> {
  return new Promise((resolve) => {
    resolver?.(false)
    confirmState.value = options
    resolver = resolve
  })
}

export function settleConfirm(result: boolean) {
  if (!resolver) return
  const resolve = resolver
  resolver = null
  confirmState.value = null
  resolve(result)
}
