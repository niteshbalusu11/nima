import { useEffect, useState } from 'react'
import { api } from './api'

type Face = { id: string; first_seen_ms: number; sightings: number }

export default function FaceGallery({ captureId, token, video }: { captureId: string; token: string; video: boolean }) {
  const [faces, setFaces] = useState<Face[]>([])
  const [images, setImages] = useState<Record<string, string>>({})

  useEffect(() => {
    let active = true
    let timer: number
    const urls = new Map<string, string>()
    const refresh = async () => {
      try {
        const result = await api<{ faces: Face[] }>('GET', `/super-admin/captures/${captureId}/faces`, token)
        if (!active) return
        setFaces(result.faces)
        for (const face of result.faces) {
          if (urls.has(face.id)) continue
          const response = await fetch(`/super-admin/captures/${captureId}/faces/${face.id}`, {
            headers: { Authorization: `Bearer ${token}` }, cache: 'no-store',
          })
          if (!response.ok || !active) continue
          const url = URL.createObjectURL(await response.blob())
          if (!active) { URL.revokeObjectURL(url); return }
          urls.set(face.id, url)
          setImages(Object.fromEntries(urls))
        }
      } catch { /* The next poll retries. */ }
      if (active) timer = window.setTimeout(refresh, 5000)
    }
    void refresh()
    return () => {
      active = false
      window.clearTimeout(timer)
      for (const url of urls.values()) URL.revokeObjectURL(url)
    }
  }, [captureId, token])

  return <section className="dash-faces" aria-label="Detected faces">
    <div className="dash-faces-head"><span className="dash-eyebrow">LIKELY PEOPLE</span><span>{faces.length}</span></div>
    <div className="dash-faces-list">
      {faces.map((face, index) => <div className="dash-face" key={face.id}>
        {images[face.id] ? <img src={images[face.id]} alt={`Face group ${index + 1}`} /> : <span className="dash-face-placeholder" />}
        <span>Person {index + 1}</span>
        <small>{face.sightings} sighting{face.sightings === 1 ? '' : 's'}{video ? ` · ${Math.round(face.first_seen_ms / 1000)}s` : ''}</small>
      </div>)}
      {!faces.length && <p>Face crops will appear here after processing.</p>}
    </div>
  </section>
}
