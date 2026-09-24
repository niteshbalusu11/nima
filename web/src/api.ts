export type Session = { token: string; account_id: string; role: 'member' | 'admin' }
export type Profile = { id: string; role: 'member' | 'admin'; name: string; email: string; signal_username: string }

export class APIError extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

export async function api<T>(method: string, path: string, token?: string, body?: object): Promise<T> {
  const response = await fetch(path, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    cache: 'no-store',
  })
  if (!response.ok) {
    const error = await response.json().catch(() => null) as { error?: string } | null
    throw new APIError(response.status, error?.error || 'Try again')
  }
  return response.json() as Promise<T>
}

const sessionKey = 'witness.session'

export function loadSession(): Session | null {
  try {
    const value = localStorage.getItem(sessionKey)
    return value ? JSON.parse(value) as Session : null
  } catch {
    return null
  }
}

export function saveSession(session: Session): void {
  localStorage.setItem(sessionKey, JSON.stringify(session))
}

export function clearSession(): void {
  localStorage.removeItem(sessionKey)
}
