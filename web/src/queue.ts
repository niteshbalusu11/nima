import SparkMD5 from 'spark-md5'
import { api, type Session } from './api'

type CaptureKind = 'photo' | 'video'
type ObjectKind = 'photo' | 'init' | 'media'
type Pending = {
  id: string
  accountId: string
  captureId: string
  captureKind: CaptureKind
  sequence: number
  kind: ObjectKind
  blob: Blob
  sha256: string
  md5: string
  size: number
  createdAt: number
}
type Reservation = { acknowledged: boolean; url?: string; headers?: Record<string, string> }

const maxObjectSize = 12 * 1024 * 1024
const maxPendingSize = 256 * 1024 * 1024
let database: Promise<IDBDatabase> | undefined

function openQueue(): Promise<IDBDatabase> {
  database ??= new Promise((resolve, reject) => {
    const request = indexedDB.open('witness-uploads', 1)
    request.onupgradeneeded = () => request.result.createObjectStore('pending', { keyPath: 'id' })
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
  return database
}

async function allPending(): Promise<Pending[]> {
  const db = await openQueue()
  return new Promise((resolve, reject) => {
    const request = db.transaction('pending').objectStore('pending').getAll()
    request.onsuccess = () => resolve(request.result as Pending[])
    request.onerror = () => reject(request.error)
  })
}

async function writePending(item: Pending): Promise<void> {
  const db = await openQueue()
  await new Promise<void>((resolve, reject) => {
    const transaction = db.transaction('pending', 'readwrite')
    transaction.objectStore('pending').put(item)
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(transaction.error)
  })
}

async function removePending(id: string): Promise<void> {
  const db = await openQueue()
  await new Promise<void>((resolve, reject) => {
    const transaction = db.transaction('pending', 'readwrite')
    transaction.objectStore('pending').delete(id)
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(transaction.error)
  })
}

async function makePending(session: Session, captureId: string, captureKind: CaptureKind,
  sequence: number, kind: ObjectKind, blob: Blob): Promise<Pending> {
  if (blob.size === 0 || blob.size > maxObjectSize) throw new Error('Capture is too large')
  const bytes = await blob.arrayBuffer()
  const sha = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  const sha256 = Array.from(sha, byte => byte.toString(16).padStart(2, '0')).join('')
  const md5 = btoa(SparkMD5.ArrayBuffer.hash(bytes, true))
  return {
    id: `${session.account_id}/${captureId}/${sequence}`,
    accountId: session.account_id, captureId, captureKind, sequence, kind,
    blob, sha256, md5, size: blob.size, createdAt: Date.now(),
  }
}

export class UploadQueue {
  private running = new Set<CaptureKind>()
  private timer?: number
  private error: string | null = null
  private online = () => this.kick()

  constructor(private session: Session, private onStatus: (pending: number, error: string | null) => void) {}

  start(): void {
    window.addEventListener('online', this.online)
    this.timer = window.setInterval(() => this.kick(), 5000)
    this.kick()
  }

  stop(): void {
    window.removeEventListener('online', this.online)
    window.clearInterval(this.timer)
  }

  async add(captureId: string, captureKind: CaptureKind, sequence: number,
    kind: ObjectKind, blob: Blob): Promise<void> {
    const item = await makePending(this.session, captureId, captureKind, sequence, kind, blob)
    const pending = await allPending()
    if (pending.reduce((total, current) => total + current.size, 0) + item.size > maxPendingSize) {
      throw new Error('Storage full')
    }
    await writePending(item)
    await this.report()
    this.kick()
  }

  private async report(): Promise<void> {
    const pending = (await allPending()).filter(item => item.accountId === this.session.account_id)
    this.onStatus(pending.length, this.error || (pending.length && !navigator.onLine ? 'Offline' : null))
  }

  private kick(): void {
    for (const kind of ['video', 'photo'] as const) {
      if (!this.running.has(kind)) void this.drain(kind)
    }
  }

  private async drain(kind: CaptureKind): Promise<void> {
    this.running.add(kind)
    try {
      while (navigator.onLine) {
        const pending = (await allPending())
          .filter(item => item.accountId === this.session.account_id && item.captureKind === kind)
          .sort((a, b) => a.createdAt - b.createdAt || a.sequence - b.sequence)
        const next = pending[0]
        if (!next) break
        await this.send(next)
        await removePending(next.id)
        this.error = null
        await this.report()
      }
    } catch {
      this.error = navigator.onLine ? 'Upload paused' : 'Offline'
    } finally {
      this.running.delete(kind)
      await this.report().catch(() => this.onStatus(0, 'Could not open saved media'))
    }
  }

  private async send(item: Pending): Promise<void> {
    const capturePath = `/captures/${item.captureId}`
    await api('PUT', capturePath, this.session.token, { kind: item.captureKind })
    const signed = await api<Reservation>('POST', `${capturePath}/objects/reserve`, this.session.token, {
      sequence: item.sequence, kind: item.kind, sha256: item.sha256, md5: item.md5,
      size: item.size, duration: 0, start_time: 0,
    })
    if (!signed.acknowledged) {
      if (!signed.url) throw new Error('Upload unavailable')
      if (location.protocol === 'https:' && new URL(signed.url).protocol !== 'https:') {
        throw new Error('Upload unavailable')
      }
      const headers = new Headers()
      for (const [name, value] of Object.entries(signed.headers || {})) {
        // The browser sets Content-Length from the Blob itself.
        if (name.toLowerCase() !== 'content-length') headers.set(name, value)
      }
      const response = await fetch(signed.url, { method: 'PUT', headers, body: item.blob })
      if (!response.ok && response.status !== 412) throw new Error('Upload failed')
      await api('POST', `${capturePath}/objects/ack`, this.session.token, { sequence: item.sequence })
    }
  }
}
