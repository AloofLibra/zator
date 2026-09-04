export async function api<T = Record<string, unknown>>(path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(path, options)
  let data: Record<string, unknown> = {}
  try {
    data = await response.json() as Record<string, unknown>
  } catch {
    data = {}
  }
  if (!response.ok) {
    throw new Error(String(data.error || `HTTP ${response.status}`))
  }
  return data as T
}

export function formBody(params: Record<string, string | number>) {
  return {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params as Record<string, string>),
  }
}
