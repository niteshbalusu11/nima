import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import Dashboard from '../src/Dashboard'

vi.mock('../src/FaceGallery', () => ({
  default: ({ onSelectCapture }: { onSelectCapture: (id: string) => void }) => <div>
    <button onClick={() => onSelectCapture('older')}>Source older</button>
    <button onClick={() => onSelectCapture('second')}>Source second</button>
  </div>,
}))

const recent = { id: 'recent', account_id: 'account', account_name: 'Recent owner', kind: 'photo',
  created_at: 1, finished: true, acknowledged_objects: 1 }
const older = { ...recent, id: 'older', account_name: 'Older owner' }
const second = { ...recent, id: 'second', account_name: 'Second owner' }

let root: Root
let container: HTMLDivElement
let sourceAvailable: boolean
let summaryRequest: ((capture: typeof recent) => void) | null
let pendingSummaries: boolean
let requests: string[]

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true)
  sessionStorage.setItem('witness.dashboard.session', JSON.stringify({ token: 'token', account_id: 'account', role: 'admin', super_admin: true }))
  sourceAvailable = true
  pendingSummaries = false
  summaryRequest = null
  requests = []
  vi.stubGlobal('fetch', vi.fn(async (input: string) => {
    requests.push(input)
    if (input === '/me') return { ok: true, status: 200, json: async () => ({ super_admin: true }) }
    if (input === '/super-admin/captures') return { ok: true, status: 200, json: async () => ({ captures: [recent] }) }
    if (input.endsWith('/summary')) {
      if (pendingSummaries) return new Promise(resolve => {
        summaryRequest = capture => resolve({ ok: true, status: 200, json: async () => capture })
      })
      if (!sourceAvailable) return { ok: false, status: 404, json: async () => ({ error: 'Not found' }) }
      return { ok: true, status: 200, json: async () => input.includes('/second/') ? second : older }
    }
    if (['/super-admin/captures/recent', '/super-admin/captures/older', '/super-admin/captures/second'].includes(input)) {
      return { ok: true, status: 200, json: async () => ({ objects: [{ sequence: 0, acknowledged: true,
        url: `/${input.split('/').pop()}.jpg` }] }) }
    }
    throw new Error(`Unexpected request: ${input}`)
  }))
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
})

afterEach(async () => {
  await act(async () => root.unmount())
  container.remove()
  sessionStorage.clear()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

async function mount() {
  await act(async () => root.render(<Dashboard />))
}

async function click(label: string) {
  const button = [...container.querySelectorAll('button')].find(element => element.textContent === label)
  expect(button, `missing ${label} button`).toBeDefined()
  await act(async () => button!.click())
}

function selectedOwner() {
  return container.querySelector('.dash-stage-heading h1')?.textContent
}

test('loads a source photo outside the recent capture feed', async () => {
  await mount()
  await click('Source older')
  expect(selectedOwner()).toBe('Older owner')
  expect(requests).toContain('/super-admin/captures/older')
  expect(container.querySelector('.dash-photo')?.getAttribute('src')).toBe('/older.jpg')
})

test('drops a selected source when its owner deletes it', async () => {
  await mount()
  await click('Source older')
  expect(selectedOwner()).toBe('Older owner')
  sourceAvailable = false
  await act(async () => vi.advanceTimersByTimeAsync(1500))
  expect(selectedOwner()).toBe('Recent owner')
  expect(container.querySelector('.dash-photo')?.getAttribute('src')).toBe('/recent.jpg')
})

test('ignores a slower source response after a newer selection', async () => {
  await mount()
  pendingSummaries = true
  await click('Source older')
  const resolveOlder = summaryRequest!
  await click('Source second')
  const resolveSecond = summaryRequest!
  await act(async () => resolveSecond(second))
  expect(selectedOwner()).toBe('Second owner')
  await act(async () => resolveOlder(older))
  expect(selectedOwner()).toBe('Second owner')
})
