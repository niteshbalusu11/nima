import { useEffect, useRef, useState, type FormEvent } from 'react'
import { api, APIError, type Profile, type Session } from './api'
import LiveVideo from './LiveVideo'
import VideoThumbnail from './VideoThumbnail'

type Capture = {
  id: string
  account_id: string
  account_name: string
  kind: 'photo' | 'video'
  created_at: number
  finished: boolean
  acknowledged_objects: number
}
type Feed = { captures: Capture[] }
type Detail = { objects: { sequence: number; acknowledged: boolean; url?: string }[] }

const storageKey = 'witness.dashboard.session'
const invitePrefix = 'uploadvideo:invite:'

function savedSession(): Session | null {
  try {
    const value = sessionStorage.getItem(storageKey)
    return value ? JSON.parse(value) as Session : null
  } catch { return null }
}

function inviteToken(value: string): string | null {
  const token = value.trim().replace(invitePrefix, '')
  return /^[A-Za-z0-9_-]{43}$/.test(token) ? token : null
}

function timeLabel(value: number): string {
  return new Date(value * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
}

export default function Dashboard() {
  const [session, setSession] = useState<Session | null>(savedSession)
  const [authorized, setAuthorized] = useState(false)
  const [invite, setInvite] = useState('')
  const [joining, setJoining] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [captures, setCaptures] = useState<Capture[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [photos, setPhotos] = useState<Record<string, string>>({})
  const [now, setNow] = useState(Date.now())
  const activity = useRef(new Map<string, { count: number; changed: number }>())
  const loadingPhotos = useRef(new Set<string>())
  const selectedRow = useRef<HTMLButtonElement>(null)
  const keyboardNavigation = useRef(false)
  const currentToken = useRef<string | null>(session?.token ?? null)
  currentToken.current = session?.token ?? null

  useEffect(() => {
    if (!session) return
    let active = true
    api<Profile>('GET', '/me', session.token).then(profile => {
      if (!active) return
      if (!profile.super_admin) {
        sessionStorage.removeItem(storageKey)
        setSession(null)
        setError('This account does not have dashboard access')
      } else { setAuthorized(true) }
    }).catch(() => {
      if (!active) return
      sessionStorage.removeItem(storageKey)
      setSession(null)
      setError('Sign in again to open the dashboard')
    })
    return () => { active = false }
  }, [session])

  useEffect(() => {
    if (!authorized || !session) return
    let active = true
    let timer: number
    const refresh = async () => {
      try {
        const feed = await api<Feed>('GET', '/super-admin/captures', session.token)
        if (!active) return
        const current = Date.now()
        for (const capture of feed.captures) {
          const previous = activity.current.get(capture.id)
          if (!previous || previous.count !== capture.acknowledged_objects) {
            activity.current.set(capture.id, {
              count: capture.acknowledged_objects,
              changed: previous ? current : capture.created_at * 1000,
            })
          }
        }
        setNow(current)
        setCaptures(feed.captures)
        setSelectedId(previous => previous && feed.captures.some(capture => capture.id === previous)
          ? previous : feed.captures[0]?.id ?? null)
        setError(null)
      } catch (reason) {
        if (!active) return
        if (reason instanceof APIError && [401, 403].includes(reason.status)) {
          sessionStorage.removeItem(storageKey)
          setSession(null)
          setAuthorized(false)
          setError('Dashboard access ended')
          return
        }
        setError('Connection lost. Retrying…')
      }
      if (active) timer = window.setTimeout(refresh, 1500)
    }
    void refresh()
    return () => { active = false; window.clearTimeout(timer) }
  }, [authorized, session])

  useEffect(() => {
    if (!authorized || !session) return
    const visible = captures.filter(capture => capture.kind === 'photo' && capture.acknowledged_objects > 0).slice(0, 12)
    for (const capture of visible) {
      if (photos[capture.id] || loadingPhotos.current.has(capture.id)) continue
      loadingPhotos.current.add(capture.id)
      void api<Detail>('GET', `/super-admin/captures/${capture.id}`, session.token).then(detail => {
        const url = detail.objects.find(object => object.acknowledged && object.url)?.url
        if (url && currentToken.current === session.token) setPhotos(previous => ({ ...previous, [capture.id]: url }))
      }).catch(() => {}).finally(() => loadingPhotos.current.delete(capture.id))
    }
  }, [authorized, captures, photos, session])

  useEffect(() => {
    if (!authorized) return
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return
      if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || event.repeat) return
      if (event.target instanceof Element && event.target.closest('input, textarea, select, [contenteditable]')) return
      if (!captures.length) return
      event.preventDefault()
      setSelectedId(current => {
        const direction = event.key === 'ArrowUp' ? -1 : 1
        let index = captures.findIndex(capture => capture.id === current)
        if (index < 0) index = direction < 0 ? 0 : captures.length - 1
        const next = captures[(index + direction + captures.length) % captures.length]
        keyboardNavigation.current = next.id !== current
        return next.id
      })
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [authorized, captures])

  useEffect(() => {
    if (!keyboardNavigation.current) return
    keyboardNavigation.current = false
    selectedRow.current?.scrollIntoView({ block: 'nearest' })
  }, [selectedId])

  async function enroll(event: FormEvent) {
    event.preventDefault()
    const token = inviteToken(invite)
    if (!token) { setError('Enter a valid invite'); return }
    setJoining(true)
    setError(null)
    try {
      const next = await api<Session>('POST', '/enroll', undefined, { token })
      if (!next.super_admin) throw new Error('This invite does not grant dashboard access')
      sessionStorage.setItem(storageKey, JSON.stringify(next))
      setSession(next)
      setInvite('')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not sign in')
    } finally { setJoining(false) }
  }

  function signOut() {
    sessionStorage.removeItem(storageKey)
    currentToken.current = null
    setAuthorized(false)
    setSession(null)
    setCaptures([])
    setPhotos({})
    activity.current.clear()
  }

  if (!session) return <main className="dash-login">
    <div className="dash-login-mark"><img src="/app/app-icon.png" alt="" /><span>Nima</span></div>
    <form onSubmit={enroll} className="dash-login-form">
      <span className="dash-eyebrow">PRIVATE DASHBOARD</span>
      <h1>Enter super-admin invite</h1>
      <label htmlFor="dashboard-invite">Invite code</label>
      <input id="dashboard-invite" value={invite} onChange={event => setInvite(event.target.value)}
        autoComplete="off" autoCapitalize="none" spellCheck={false} autoFocus />
      <button disabled={joining || !invite.trim()}>{joining ? 'Joining…' : 'Open dashboard'}</button>
      {error && <p role="alert">{error}</p>}
    </form>
  </main>

  const selected = captures.find(capture => capture.id === selectedId)
  const selectedActivity = selected && activity.current.get(selected.id)
  const receiving = Boolean(selected && selected.kind === 'video' && !selected.finished &&
    selected.acknowledged_objects > 0 && selectedActivity && now - selectedActivity.changed < 8000)

  return <main className="dash-page">
    <header className="dash-header">
      <div className="dash-brand"><img src="/app/app-icon.png" alt="" /><strong>Nima</strong><span>Live dashboard</span></div>
      <div className="dash-header-right"><span className="dash-private">PRIVATE VIEW</span><button onClick={signOut}>Sign out</button></div>
    </header>
    <div className="dash-workspace">
      <section className="dash-stage" aria-label="Selected capture">
        <div className="dash-stage-heading">
          <div><span className="dash-eyebrow">SELECTED CAPTURE</span><h1>{selected ? selected.account_name : 'Waiting for captures'}</h1>
            <p>{selected ? `${selected.kind === 'video' ? 'Video' : 'Photo'} · ${timeLabel(selected.created_at)}` : 'New uploads will appear here.'}</p></div>
          {selected && <div className={`dash-stage-status ${receiving ? 'receiving' : ''}`}><i />
            {selected.kind === 'photo' ? selected.acknowledged_objects ? 'Uploaded' : 'Uploading' :
              selected.finished ? 'Finished' : receiving ? 'Receiving fragments' : 'No recent uploads'}
          </div>}
        </div>
        <div className="dash-media">
          {!selected && <div className="dash-empty"><span className="dash-empty-ring" /><p>Waiting for the first upload</p></div>}
          {selected?.kind === 'video' && <LiveVideo key={selected.id} captureId={selected.id} token={session.token} />}
          {selected?.kind === 'photo' && (photos[selected.id]
            ? <img className="dash-photo" src={photos[selected.id]} alt={`Uploaded by ${selected.account_name}`} referrerPolicy="no-referrer"
                onError={() => setPhotos(previous => { const next = { ...previous }; delete next[selected.id]; return next })} />
            : <div className="dash-empty"><span className="dash-empty-ring" /><p>Waiting for photo upload</p></div>)}
        </div>
        {selected && <div className="dash-stage-meta"><span>CAPTURE ID&nbsp; {selected.id.slice(0, 8)}</span><span>{selected.kind === 'video' ? `${Math.max(0, selected.acknowledged_objects - 1)} video fragments uploaded` : 'Photo'}</span><span className="dash-shortcuts">↑ ↓ captures{selected.kind === 'video' ? ' · Space play/pause' : ''}</span></div>}
      </section>
      <aside className="dash-feed" aria-label="Recent captures">
        <div className="dash-feed-head"><div><span className="dash-eyebrow">ACTIVITY</span><h2>Recent captures</h2></div><span>{captures.length}</span></div>
        {error && <p className="dash-feed-error" role="status">{error}</p>}
        <div className="dash-feed-list">
          {captures.map(capture => {
            const changed = activity.current.get(capture.id)?.changed ?? 0
            const active = capture.kind === 'video' && !capture.finished && capture.acknowledged_objects > 0 && now - changed < 8000
            return <button className={`dash-feed-row ${capture.id === selectedId ? 'selected' : ''}`} key={capture.id}
              ref={capture.id === selectedId ? selectedRow : null}
              onClick={() => setSelectedId(capture.id)} aria-pressed={capture.id === selectedId}>
              {capture.kind === 'video'
                ? <VideoThumbnail captureId={capture.id} token={session.token} available={capture.acknowledged_objects > 1} />
                : <span className="dash-feed-thumb">{photos[capture.id]
                  ? <img src={photos[capture.id]} alt="" referrerPolicy="no-referrer" />
                  : <span className="dash-photo-glyph">▧</span>}</span>}
              <span className="dash-feed-info"><strong>{capture.account_name}</strong><small>{capture.kind === 'video' ? 'Video' : 'Photo'} · {timeLabel(capture.created_at)}</small></span>
              <span className={`dash-feed-state ${active ? 'active' : ''}`}>{capture.kind === 'photo'
                ? capture.acknowledged_objects ? 'READY' : 'WAIT'
                : capture.finished ? 'DONE' : active ? 'LIVE' : capture.acknowledged_objects ? 'IDLE' : 'WAIT'}</span>
            </button>
          })}
          {!captures.length && <p className="dash-feed-none">No captures yet</p>}
        </div>
      </aside>
    </div>
  </main>
}
