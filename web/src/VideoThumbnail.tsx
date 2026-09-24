import { useEffect, useRef, useState } from 'react'

type Part = { kind: string; acknowledged: boolean; url?: string }
type Detail = { objects: Part[] }

function waitForFrame(video: HTMLVideoElement, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const done = (error?: Error) => {
      video.removeEventListener('loadeddata', ready)
      video.removeEventListener('error', failed)
      signal.removeEventListener('abort', aborted)
      window.clearTimeout(timer)
      if (error) reject(error)
      else resolve()
    }
    const ready = () => done()
    const failed = () => done(new Error('Could not decode video preview'))
    const aborted = () => done(new DOMException('Cancelled', 'AbortError'))
    const timer = window.setTimeout(failed, 8000)
    video.addEventListener('loadeddata', ready, { once: true })
    video.addEventListener('error', failed, { once: true })
    signal.addEventListener('abort', aborted, { once: true })
    if (signal.aborted) aborted()
  })
}

async function makeThumbnail(captureId: string, token: string, signal: AbortSignal): Promise<string | null> {
  const response = await fetch(`/super-admin/captures/${captureId}?tail=1`, {
    headers: { Authorization: `Bearer ${token}` }, cache: 'no-store', signal,
  })
  if (!response.ok) throw new Error('Could not load video preview')
  const detail = await response.json() as Detail
  const init = detail.objects.find(part => part.kind === 'init' && part.acknowledged && part.url)
  const media = detail.objects.find(part => part.kind === 'media' && part.acknowledged && part.url)
  if (!init?.url || !media?.url) return null

  const [initResponse, mediaResponse] = await Promise.all([
    fetch(init.url, { cache: 'no-store', signal }),
    fetch(media.url, { cache: 'no-store', signal }),
  ])
  if (!initResponse.ok || !mediaResponse.ok) throw new Error('Could not load video fragment')
  const [initBytes, mediaBytes] = await Promise.all([initResponse.arrayBuffer(), mediaResponse.arrayBuffer()])
  const url = URL.createObjectURL(new Blob([initBytes, mediaBytes], { type: 'video/mp4' }))
  const video = document.createElement('video')
  video.muted = true
  video.playsInline = true
  video.preload = 'auto'
  try {
    const frame = waitForFrame(video, signal)
    video.src = url
    video.load()
    await frame
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 112
    const context = canvas.getContext('2d')
    if (!context || !video.videoWidth || !video.videoHeight) return null
    const size = Math.min(video.videoWidth, video.videoHeight)
    context.drawImage(video, (video.videoWidth - size) / 2, (video.videoHeight - size) / 2, size, size,
      0, 0, canvas.width, canvas.height)
    return canvas.toDataURL('image/jpeg', 0.72)
  } finally {
    video.removeAttribute('src')
    video.load()
    URL.revokeObjectURL(url)
  }
}

export default function VideoThumbnail({ captureId, token, available }: { captureId: string; token: string; available: boolean }) {
  const node = useRef<HTMLSpanElement>(null)
  const [image, setImage] = useState<string | null>(null)

  useEffect(() => {
    if (!available || image || !node.current) return
    const controller = new AbortController()
    let timer: number | undefined
    let attempts = 0
    const load = async () => {
      try {
        const thumbnail = await makeThumbnail(captureId, token, controller.signal)
        if (controller.signal.aborted) return
        if (thumbnail) { setImage(thumbnail); return }
      } catch { /* A later verified fragment may be ready on retry. */ }
      if (!controller.signal.aborted && ++attempts < 3) timer = window.setTimeout(load, 4000)
    }
    let observer: IntersectionObserver | undefined
    if ('IntersectionObserver' in window) {
      observer = new IntersectionObserver(entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          observer?.disconnect()
          void load()
        }
      }, { rootMargin: '100px' })
      observer.observe(node.current)
    } else { void load() }
    return () => { controller.abort(); observer?.disconnect(); window.clearTimeout(timer) }
  }, [available, captureId, image, token])

  return <span ref={node} className="dash-feed-thumb">{image
    ? <><img src={image} alt="" /><span className="dash-thumb-play" aria-hidden="true">▶</span></>
    : <span className="dash-play-glyph">▶</span>}</span>
}
