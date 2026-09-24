import { useEffect, useRef, useState } from 'react'

type Part = { sequence: number; kind: string; acknowledged: boolean; url?: string }
type Detail = { finished: boolean; objects: Part[] }

function findAtom(bytes: Uint8Array, name: string): number {
  for (let offset = 0; offset <= bytes.length - name.length; offset++) {
    if ([...name].every((letter, index) => bytes[offset + index] === letter.charCodeAt(0))) return offset
  }
  return -1
}

function mediaType(init: ArrayBuffer): string {
  const bytes = new Uint8Array(init)
  const avcC = findAtom(bytes, 'avcC')
  if (avcC < 0 || avcC + 8 > bytes.length) throw new Error('This video format cannot be played here')
  const avc = Array.from(bytes.slice(avcC + 5, avcC + 8), byte => byte.toString(16).padStart(2, '0')).join('')
  const audio = findAtom(bytes, 'mp4a') >= 0 ? ', mp4a.40.2' : ''
  return `video/mp4; codecs="avc1.${avc}${audio}"`
}

function waitForOpen(source: MediaSource, signal: AbortSignal): Promise<void> {
  if (source.readyState === 'open') return Promise.resolve()
  return new Promise((resolve, reject) => {
    const done = () => {
      source.removeEventListener('sourceopen', opened)
      signal.removeEventListener('abort', aborted)
    }
    const opened = () => { done(); resolve() }
    const aborted = () => { done(); reject(new DOMException('Cancelled', 'AbortError')) }
    source.addEventListener('sourceopen', opened, { once: true })
    signal.addEventListener('abort', aborted, { once: true })
  })
}

function append(buffer: SourceBuffer, data: ArrayBuffer, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const done = () => {
      buffer.removeEventListener('updateend', updated)
      buffer.removeEventListener('error', failed)
      signal.removeEventListener('abort', aborted)
    }
    const updated = () => { done(); resolve() }
    const failed = () => { done(); reject(new Error('Video playback stopped')) }
    const aborted = () => { done(); reject(new DOMException('Cancelled', 'AbortError')) }
    buffer.addEventListener('updateend', updated, { once: true })
    buffer.addEventListener('error', failed, { once: true })
    signal.addEventListener('abort', aborted, { once: true })
    try { buffer.appendBuffer(data) } catch (error) { done(); reject(error) }
  })
}

function trim(buffer: SourceBuffer, before: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const done = () => {
      buffer.removeEventListener('updateend', updated)
      buffer.removeEventListener('error', failed)
      signal.removeEventListener('abort', aborted)
    }
    const updated = () => { done(); resolve() }
    const failed = () => { done(); reject(new Error('Video playback stopped')) }
    const aborted = () => { done(); reject(new DOMException('Cancelled', 'AbortError')) }
    buffer.addEventListener('updateend', updated, { once: true })
    buffer.addEventListener('error', failed, { once: true })
    signal.addEventListener('abort', aborted, { once: true })
    try { buffer.remove(0, before) } catch (error) { done(); reject(error) }
  })
}

function pause(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise(resolve => {
    const done = () => { signal.removeEventListener('abort', aborted); resolve() }
    const aborted = () => { window.clearTimeout(timer); done() }
    const timer = window.setTimeout(done, ms)
    signal.addEventListener('abort', aborted, { once: true })
  })
}

export default function LiveVideo({ captureId, token }: { captureId: string; token: string }) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const userPaused = useRef(false)
  const [parts, setParts] = useState(0)
  const [message, setMessage] = useState('Waiting for video…')

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.code !== 'Space' || event.repeat || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
      if (event.target instanceof Element && event.target.closest('input, textarea, select, [contenteditable], button:not(.dash-feed-row)')) return
      const video = videoRef.current
      if (!video) return
      event.preventDefault()
      if (video.paused) {
        userPaused.current = false
        if (video.buffered.length) void video.play().then(() => setMessage('Playing uploaded video')).catch(() => setMessage('Press play to watch'))
      } else {
        userPaused.current = true
        video.pause()
        setMessage('Paused')
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => {
    const video = videoRef.current
    if (!video) return
    const controller = new AbortController()
    let sourceURL: string | undefined

    async function run() {
      if (!video) return
      if (!window.MediaSource) { setMessage('This browser cannot play live video'); return }
      let buffer: SourceBuffer | undefined
      let lastSequence = -1
      let firstRequest = true
      let firstMedia = true
      let started = false
      let autoPaused = false
      let lastReceivedAt = 0
      let count = 0
      while (!controller.signal.aborted) {
        try {
          const query = firstRequest ? '?tail=1' : `?after=${lastSequence}`
          firstRequest = false
          const response = await fetch(`/super-admin/captures/${captureId}${query}`, {
            headers: { Authorization: `Bearer ${token}` }, cache: 'no-store', signal: controller.signal,
          })
          if (!response.ok) throw new Error(response.status === 403 || response.status === 401 ? 'Dashboard access ended' : 'Waiting for connection…')
          const detail = await response.json() as Detail
          for (const part of detail.objects) {
            if (controller.signal.aborted || !part.acknowledged) break
            if (part.sequence <= lastSequence) continue
            if (!part.url) break
            if (part.kind === 'media' && (!buffer || (!firstMedia && part.sequence !== lastSequence + 1))) break
            const media = await fetch(part.url, { cache: 'no-store', signal: controller.signal })
            if (!media.ok) throw new Error('Waiting for video fragment…')
            const bytes = await media.arrayBuffer()
            if (part.kind === 'init') {
              const type = mediaType(bytes)
              if (!MediaSource.isTypeSupported(type)) throw new Error('This browser cannot play this video codec')
              const source = new MediaSource()
              sourceURL = URL.createObjectURL(source)
              const opened = waitForOpen(source, controller.signal)
              video.src = sourceURL
              await opened
              buffer = source.addSourceBuffer(type)
              await append(buffer, bytes, controller.signal)
            } else if (buffer) {
              // The first request may start at a recent independent fragment.
              await append(buffer, bytes, controller.signal)
              firstMedia = false
              count++
              lastReceivedAt = Date.now()
              setParts(count)
              setMessage(userPaused.current ? 'Paused' : 'Playing uploaded video')
              if (video.buffered.length) {
                const end = video.buffered.end(video.buffered.length - 1)
                if (video.currentTime < video.buffered.start(0) || end - video.currentTime > 8) {
                  video.currentTime = Math.max(video.buffered.start(0), end - 2)
                }
                if (!userPaused.current && (!started || autoPaused)) {
                  started = true
                  autoPaused = false
                  void video.play().catch(() => setMessage('Press play to watch'))
                }
                if (video.currentTime - video.buffered.start(0) > 60) {
                  await trim(buffer, video.currentTime - 30, controller.signal)
                }
              }
            }
            lastSequence = part.sequence
          }
          if (!count) setMessage('Waiting for video…')
          if (count && Date.now() - lastReceivedAt > 3500) {
            setMessage(userPaused.current ? 'Paused' : detail.finished ? 'Recording finished' : 'Waiting for next fragment…')
            if (video.buffered.length && !video.paused &&
              video.currentTime >= video.buffered.end(video.buffered.length - 1) - 0.3) {
              autoPaused = true
              video.pause()
            }
          }
          if (detail.objects.length === 50 && lastSequence === detail.objects[49].sequence) continue
        } catch (error) {
          if (controller.signal.aborted) break
          const text = error instanceof Error ? error.message : 'Waiting for connection…'
          setMessage(text)
          if (text.startsWith('This browser') || text === 'Video playback stopped' || text === 'Dashboard access ended') break
        }
        await pause(1200, controller.signal)
      }
    }
    void run()
    return () => {
      controller.abort()
      video.pause()
      video.removeAttribute('src')
      video.load()
      if (sourceURL) URL.revokeObjectURL(sourceURL)
    }
  }, [captureId, token])

  function goLive() {
    const video = videoRef.current
    if (!video?.buffered.length) return
    userPaused.current = false
    const end = video.buffered.end(video.buffered.length - 1)
    video.currentTime = Math.max(video.buffered.start(video.buffered.length - 1), end - 2)
    void video.play()
  }

  return <div className="dash-video-wrap">
    <video ref={videoRef} className="dash-video" controls autoPlay muted playsInline aria-label="Live uploaded video" />
    <div className="dash-player-foot"><span role="status">{message}</span><span>{parts} fragments received</span><button onClick={goLive} disabled={!parts}>Jump to latest</button></div>
  </div>
}
