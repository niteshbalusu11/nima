import { useEffect, useRef, useState, type FormEvent } from 'react'
import { api } from './api'

type Recognition = { state: 'possible_match' | 'unknown' | 'ambiguous' | 'unavailable'; display_name?: string }
type Face = { id: string; first_seen_ms: number; sightings: number; recognition?: Recognition; reference_name?: string; enrollable: boolean }
type Research = { status: 'disabled' | 'enabled'; opt_in_allowed: boolean; enrollment_allowed: boolean; matching_enabled: boolean }
type Person = { id: string; display_name: string; capture_id: string; eligible: boolean }

function resultLabel(face: Face) {
  if (face.reference_name) return `Reference: ${face.reference_name}`
  switch (face.recognition?.state) {
    case 'possible_match': return `Possible match: ${face.recognition.display_name}`
    case 'unknown': return 'Unknown'
    case 'ambiguous': return 'Ambiguous'
    case 'unavailable': return 'Comparison unavailable'
    default: return ''
  }
}

export default function FaceGallery({ captureId, token, video, onSelectCapture }: {
  captureId: string; token: string; video: boolean; onSelectCapture: (id: string) => void
}) {
  const [faces, setFaces] = useState<Face[]>([])
  const [images, setImages] = useState<Record<string, string>>({})
  const [research, setResearch] = useState<Research | null>(null)
  const [people, setPeople] = useState<Person[]>([])
  const [optInConsent, setOptInConsent] = useState(false)
  const [enrollFace, setEnrollFace] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [enrollConsent, setEnrollConsent] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [epoch, setEpoch] = useState(0)
  const revision = useRef(0)
  const mutationPending = useRef(false)

  useEffect(() => {
    let active = true
    let timer: number
    const urls = new Map<string, string>()
    setImages({})
    const refresh = async () => {
      if (mutationPending.current) return
      const current = revision.current
      try {
        const [result, enrolled] = await Promise.all([
          api<{ faces: Face[]; research: Research }>('GET', `/super-admin/captures/${captureId}/faces`, token),
          api<{ people: Person[] }>('GET', '/super-admin/face-people', token),
        ])
        if (!active || current !== revision.current || mutationPending.current) return
        setFaces(result.faces)
        setResearch(result.research)
        setPeople(enrolled.people)
        setError(null)
        for (const face of result.faces) {
          if (urls.has(face.id)) continue
          const response = await fetch(`/super-admin/captures/${captureId}/faces/${face.id}`, {
            headers: { Authorization: `Bearer ${token}` }, cache: 'no-store',
          })
          if (!response.ok || !active || current !== revision.current || mutationPending.current) continue
          const url = URL.createObjectURL(await response.blob())
          if (!active || current !== revision.current || mutationPending.current) { URL.revokeObjectURL(url); return }
          urls.set(face.id, url)
          setImages(Object.fromEntries(urls))
        }
      } catch {
        if (active && current === revision.current && !mutationPending.current) {
          setFaces([])
          setResearch(null)
          setPeople([])
          setError('Research status unavailable. Retrying…')
        }
      }
      if (active) timer = window.setTimeout(refresh, 5000)
    }
    void refresh()
    return () => {
      active = false
      window.clearTimeout(timer)
      for (const url of urls.values()) URL.revokeObjectURL(url)
    }
  }, [captureId, token, epoch])

  async function mutate(action: () => Promise<unknown>): Promise<boolean> {
    revision.current++
    mutationPending.current = true
    setFaces([])
    setResearch(null)
    setPeople([])
    setError(null)
    setBusy(true)
    try { await action(); return true }
    catch (reason) { setError(reason instanceof Error ? reason.message : 'Could not update research settings'); return false }
    finally {
      mutationPending.current = false
      setBusy(false)
      setEpoch(value => value + 1)
    }
  }

  async function enroll(event: FormEvent) {
    event.preventDefault()
    if (!enrollFace || !enrollConsent || !name.trim()) return
    const succeeded = await mutate(() => api('POST', '/super-admin/face-people', token, {
      capture_id: captureId, face_group_id: enrollFace, display_name: name.trim(), consent_confirmed: true,
    }))
    if (succeeded) { setEnrollFace(null); setName(''); setEnrollConsent(false) }
  }

  return <section className="dash-faces" aria-label="Detected faces">
    <div className="dash-faces-head"><span className="dash-eyebrow">LIKELY PEOPLE</span><span>{faces.length}</span></div>
    {error && <p className="dash-research-error" role="status">{error}</p>}
    {(research?.opt_in_allowed || research?.status === 'enabled') && <div className="dash-research">
      <strong>Research demo</strong>
      {research.status === 'disabled' && research.opt_in_allowed && <>
        <label><input type="checkbox" checked={optInConsent} onChange={event => setOptInConsent(event.target.checked)} />
          Every visible participant agreed to cloud upload and face comparison with other consented captures, including those owned by other accounts.</label>
        <button disabled={busy || !optInConsent} onClick={() => {
          void mutate(() => api('PUT', `/super-admin/captures/${captureId}/face-research`, token, { consent_confirmed: true }))
            .then(succeeded => { if (succeeded) setOptInConsent(false) })
        }}>
          Use for research comparison
        </button>
      </>}
      {research.status === 'enabled' && <>
        <span>{research.matching_enabled ? 'Possible matches enabled' : 'Matching paused for calibration'}</span>
        <button disabled={busy} onClick={() => {
          if (window.confirm('Opt out this capture? Its enrollments will be removed; the recording and anonymous face crops remain.'))
            void mutate(() => api<void>('DELETE', `/super-admin/captures/${captureId}/face-research`, token))
              .then(succeeded => { if (succeeded) setOptInConsent(false) })
        }}>Opt out</button>
      </>}
    </div>}
    <div className="dash-faces-list">
      {faces.map((face, index) => <div className="dash-face" key={face.id}>
        {images[face.id] ? <img src={images[face.id]} alt={`Face group ${index + 1}`} /> : <span className="dash-face-placeholder" />}
        <span>Person {index + 1}</span>
        {resultLabel(face) && <strong className="dash-face-result">{resultLabel(face)}</strong>}
        <small>{face.sightings} sighting{face.sightings === 1 ? '' : 's'}{video ? ` · ${Math.round(face.first_seen_ms / 1000)}s` : ''}</small>
        {research?.enrollment_allowed && face.enrollable && <button disabled={busy} onClick={() => { setEnrollFace(face.id); setName(''); setEnrollConsent(false) }}>
          Enroll participant
        </button>}
      </div>)}
      {!faces.length && <p>Face crops will appear here after processing.</p>}
    </div>
    {enrollFace && <form className="dash-enroll" onSubmit={enroll}>
      <strong>Enroll participant</strong>
      <p>Use a research label only for someone who agreed to named enrollment and comparison with other consented captures, including those owned by other accounts.</p>
      <input aria-label="Participant name" maxLength={80} value={name} onChange={event => setName(event.target.value)} autoFocus />
      <label><input type="checkbox" checked={enrollConsent} onChange={event => setEnrollConsent(event.target.checked)} /> I confirmed this participant's enrollment consent.</label>
      <button disabled={busy || !enrollConsent || !name.trim()}>Enroll</button>
      <button type="button" onClick={() => setEnrollFace(null)}>Cancel</button>
    </form>}
    {people.length > 0 && <details className="dash-people"><summary>Enrolled participants ({people.length})</summary>
      {people.map(person => <div key={person.id}>
        <span>{person.display_name}{!person.eligible ? ' · comparison inactive' : ''}</span>
        <button onClick={() => onSelectCapture(person.capture_id)}>Source {person.capture_id.slice(0, 8)}</button>
        <button disabled={busy} onClick={() => {
          if (window.confirm('Remove this enrollment? The recording and anonymous face crops remain.'))
            void mutate(() => api<void>('DELETE', `/super-admin/face-people/${person.id}`, token))
        }}>Remove enrollment</button>
      </div>)}
    </details>}
  </section>
}
