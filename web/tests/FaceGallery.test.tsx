import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import FaceGallery from '../src/FaceGallery'

let root: Root
let container: HTMLDivElement
let fail: boolean
let enabled: boolean

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true)
  fail = false
  enabled = true
  vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:face')
  vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {})
  vi.stubGlobal('fetch', vi.fn(async (input: string) => {
    if (input.endsWith('/faces')) {
      if (fail) return { ok: false, status: 503, json: async () => ({ error: 'Unavailable' }) }
      return { ok: true, status: 200, json: async () => ({
        faces: [{ id: 'face', first_seen_ms: 0, sightings: 1, enrollable: true,
          recognition: enabled ? { state: 'possible_match', display_name: '<XYZ>' } : undefined }],
        research: { status: enabled ? 'enabled' : 'disabled', opt_in_allowed: true,
          enrollment_allowed: enabled, matching_enabled: enabled },
      }) }
    }
    if (input.endsWith('/face-people')) return { ok: true, status: 200, json: async () => ({ people: [] }) }
    return { ok: true, status: 200, blob: async () => new Blob(['crop']) }
  }))
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
})

afterEach(async () => {
  await act(async () => root.unmount())
  container.remove()
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

async function mount() {
  await act(async () => root.render(<FaceGallery captureId="capture" token="token" video={false} onSelectCapture={() => {}} />))
}

test('renders candidate names as text and clears them when polling fails', async () => {
  await mount()
  expect(container.textContent).toContain('Possible match: <XYZ>')
  expect(container.querySelector('XYZ')).toBeNull()
  fail = true
  await act(async () => vi.advanceTimersByTimeAsync(5000))
  expect(container.textContent).not.toContain('<XYZ>')
  expect(container.textContent).toContain('Research status unavailable')
})

test('requires an explicit capture-consent check before opt-in', async () => {
  enabled = false
  await mount()
  const button = [...container.querySelectorAll('button')].find(element => element.textContent?.includes('Use for research comparison'))!
  expect(button.disabled).toBe(true)
  await act(async () => (container.querySelector('input[type=checkbox]') as HTMLInputElement).click())
  expect(button.disabled).toBe(false)
})
