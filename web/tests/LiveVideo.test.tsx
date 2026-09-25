import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import LiveVideo from '../src/LiveVideo'

let root: Root
let container: HTMLDivElement
let available: number
let unavailable: number | undefined
let requests: string[]
let appended: number[]
let ranges: { start: number; end: number }[]
let paused: boolean
let readyState: number

// Exercise the component's real fetch, cursor, append and playback loop, with
// one-second fragments and only the browser's media APIs replaced.
class SourceBufferMock extends EventTarget {
  appendBuffer(bytes: ArrayBuffer) {
    if (bytes.byteLength === 4) {
      const sequence = new DataView(bytes).getInt32(0)
      appended.push(sequence)
      if (!ranges.length) ranges.push({ start: sequence - 1, end: sequence })
      else ranges[0].end = sequence
    }
    queueMicrotask(() => this.dispatchEvent(new Event('updateend')))
  }
  remove(_start: number, end: number) {
    ranges[0].start = end
    queueMicrotask(() => this.dispatchEvent(new Event('updateend')))
  }
}

class MediaSourceMock extends EventTarget {
  readyState = 'open'
  static isTypeSupported() { return true }
  addSourceBuffer() { return new SourceBufferMock() }
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true)
  vi.stubGlobal('MediaSource', MediaSourceMock)
  available = 28
  unavailable = undefined
  requests = []
  appended = []
  ranges = []
  paused = true
  readyState = HTMLMediaElement.HAVE_FUTURE_DATA
  vi.spyOn(URL, 'createObjectURL').mockImplementation(() => {
    ranges = []
    return 'blob:test-video'
  })
  vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {})
  vi.spyOn(HTMLMediaElement.prototype, 'buffered', 'get').mockImplementation(() => ({
    length: ranges.length,
    start: (index: number) => ranges[index].start,
    end: (index: number) => ranges[index].end,
  }))
  vi.spyOn(HTMLMediaElement.prototype, 'paused', 'get').mockImplementation(() => paused)
  vi.spyOn(HTMLMediaElement.prototype, 'readyState', 'get').mockImplementation(() => readyState)
  vi.spyOn(HTMLMediaElement.prototype, 'play').mockImplementation(async function () {
    paused = false
    this.dispatchEvent(new Event('play'))
  })
  vi.spyOn(HTMLMediaElement.prototype, 'pause').mockImplementation(function () {
    paused = true
    this.dispatchEvent(new Event('pause'))
  })
  vi.spyOn(HTMLMediaElement.prototype, 'load').mockImplementation(() => {})
  vi.stubGlobal('fetch', vi.fn(async (input: string) => {
    requests.push(input)
    if (input.startsWith('/super-admin/')) {
      const query = new URL(input, 'https://test.invalid').searchParams
      const after = Number(query.get('after') ?? -1)
      const sequences = Array.from({ length: available + 1 }, (_, sequence) => sequence)
        .filter(sequence => query.has('tail') ? sequence === 0 || sequence > available - 6 : sequence > after)
        .slice(0, 50)
      return { ok: true, json: async () => ({ finished: false, objects: sequences.map(sequence => ({
        sequence, kind: sequence === 0 ? 'init' : 'media',
        acknowledged: sequence !== unavailable, url: `/fragments/${sequence}`,
      })) }) }
    }
    const sequence = Number(input.split('/').pop())
    const bytes = sequence === 0
      ? new Uint8Array([97, 118, 99, 67, 1, 77, 0, 31]).buffer
      : new ArrayBuffer(4)
    if (sequence) new DataView(bytes).setInt32(0, sequence)
    return { ok: true, arrayBuffer: async () => bytes }
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
  await act(async () => root.render(<LiveVideo captureId="capture" token="test-token" />))
}

async function tick(ms = 1200) {
  await act(async () => vi.advanceTimersByTimeAsync(ms))
}

async function click(label: string) {
  const button = [...container.querySelectorAll('button')].find(button => button.textContent === label)
  expect(button, `missing ${label} button`).toBeDefined()
  await act(async () => button!.click())
}

test('replays every fragment of an existing recording from the beginning without skipping ahead', async () => {
  await mount()
  expect(appended).toEqual(Array.from({ length: 28 }, (_, index) => index + 1))
  expect(ranges).toEqual([{ start: 0, end: 28 }])
  expect(container.querySelector('video')!.currentTime).toBe(0)
  expect(container.textContent).toContain('28 fragments loaded')
})

test('continues appending new uploads without moving the replay position', async () => {
  await mount()
  const video = container.querySelector('video')!
  video.currentTime = 5
  available = 30
  await tick()
  expect(appended.slice(-2)).toEqual([29, 30])
  expect(video.currentTime).toBe(5)
})

test('waits at an unverified fragment and resumes in sequence when it arrives', async () => {
  unavailable = 5
  await mount()
  expect(appended).toEqual([1, 2, 3, 4])
  unavailable = undefined
  await tick()
  expect(appended).toEqual(Array.from({ length: 28 }, (_, index) => index + 1))
})

test('switches to the latest fragments explicitly and can replay from the start again', async () => {
  await mount()
  appended = []
  await click('Jump to latest')
  expect(requests).toContain('/super-admin/captures/capture?tail=1')
  expect(appended).toEqual([23, 24, 25, 26, 27, 28])
  expect(container.querySelector('video')!.currentTime).toBeGreaterThanOrEqual(22)
  appended = []
  await click('Play from start')
  expect(appended).toEqual(Array.from({ length: 28 }, (_, index) => index + 1))
  expect(container.querySelector('video')!.currentTime).toBe(0)
})

test('pages through a longer recording with bounded buffering and no skipped fragments', async () => {
  available = 75
  await mount()
  const video = container.querySelector('video')!
  expect(appended[0]).toBe(1)
  expect(appended.length).toBeLessThanOrEqual(32)
  for (const time of [20, 40, 60]) {
    video.currentTime = time
    await tick()
    expect(video.currentTime).toBe(time)
  }
  expect(appended).toEqual(Array.from({ length: 75 }, (_, index) => index + 1))
  expect(requests.some(request => Number(request.match(/[?&]after=(\d+)/)?.[1]) >= 50)).toBe(true)
})

test('keeps a native-controls pause when new uploads arrive at the end', async () => {
  available = 4
  await mount()
  const video = container.querySelector('video')!
  video.currentTime = 4
  await tick(4800)
  await act(async () => { void video.play(); video.pause() })
  available = 5
  await tick()
  expect(paused).toBe(true)
  expect(video.currentTime).toBe(4)
})

test('bounds buffering while live playback is paused and can rejoin the latest upload', async () => {
  await mount()
  await click('Jump to latest')
  const video = container.querySelector('video')!
  video.currentTime = 24
  await act(async () => video.pause())
  available = 100
  await tick()
  expect(video.currentTime).toBe(24)
  expect(paused).toBe(true)
  expect(ranges[0].end - video.currentTime).toBeLessThanOrEqual(32)
  appended = []
  await click('Jump to latest')
  expect(appended).toEqual([95, 96, 97, 98, 99, 100])
  expect(paused).toBe(false)
})

test('Play from start reloads portions that were trimmed during a long replay', async () => {
  available = 100
  await mount()
  const video = container.querySelector('video')!
  for (const time of [25, 50, 75]) {
    video.currentTime = time
    await tick()
  }
  expect(ranges[0].start).toBeGreaterThan(0)
  appended = []
  await click('Play from start')
  expect(appended[0]).toBe(1)
  expect(ranges[0].start).toBe(0)
  expect(video.currentTime).toBe(0)
})

test('retries an unsuccessful first request without skipping the beginning', async () => {
  vi.mocked(fetch).mockResolvedValueOnce({ ok: false, status: 503 } as Response)
  await mount()
  expect(appended).toEqual([])
  await tick()
  expect(appended).toEqual(Array.from({ length: 28 }, (_, index) => index + 1))
})

test('does not pause before the last frames have played', async () => {
  await mount()
  container.querySelector('video')!.currentTime = 27.8
  await tick(4800)
  expect(paused).toBe(false)
})

test('stops buffering at the end of an idle recording and resumes for new fragments', async () => {
  available = 3
  await mount()
  container.querySelector('video')!.currentTime = 2.95
  readyState = HTMLMediaElement.HAVE_CURRENT_DATA
  await tick(4800)
  expect(paused).toBe(true)
  expect(container.textContent).toContain('No new fragments')
  available = 4
  await tick()
  expect(paused).toBe(false)
  expect(appended).toEqual([1, 2, 3, 4])
})
