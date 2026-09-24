import { useEffect, useRef, useState, type FormEvent } from 'react'
import { api, APIError, clearSession, loadSession, saveSession, type Profile, type Session } from './api'
import { UploadQueue } from './queue'

const invitePrefix = 'uploadvideo:invite:'
const appIcon = '/app/app-icon.png'

function parseInvite(value: string): string | null {
  const token = value.trim().replace(invitePrefix, '')
  return /^[A-Za-z0-9_-]{43}$/.test(token) ? token : null
}

function CloudIcon() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M6.5 18.5a4.5 4.5 0 0 1-.4-9 6.2 6.2 0 0 1 11.8 1.4 3.8 3.8 0 0 1-.4 7.6H6.5Z" />
  </svg>
}

function ProfileIcon() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
    <circle cx="12" cy="8" r="3.2" /><path d="M5.8 19c.5-3.2 2.8-5 6.2-5s5.7 1.8 6.2 5" />
  </svg>
}

function formatTime(seconds: number): string {
  const minutes = Math.floor(seconds / 60).toString().padStart(2, '0')
  return `${minutes}:${(seconds % 60).toString().padStart(2, '0')}`
}

export default function App() {
  const [session, setSession] = useState<Session | null>(loadSession)
  const [invite, setInvite] = useState('')
  const [enrolling, setEnrolling] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [cameraState, setCameraState] = useState<'starting' | 'ready' | 'error'>('starting')
  const [mode, setMode] = useState<'photo' | 'video'>('photo')
  const [recording, setRecording] = useState(false)
  const [preparing, setPreparing] = useState(false)
  const [stopping, setStopping] = useState(false)
  const [seconds, setSeconds] = useState(0)
  const [flash, setFlash] = useState(false)
  const [pending, setPending] = useState(0)
  const [uploadError, setUploadError] = useState<string | null>(null)
  const [profileOpen, setProfileOpen] = useState(false)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [savingProfile, setSavingProfile] = useState(false)
  const videoRef = useRef<HTMLVideoElement>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const audioRef = useRef<MediaStream | null>(null)
  const recorderRef = useRef<MediaRecorder | null>(null)
  const uploaderRef = useRef<UploadQueue | null>(null)
  const enqueueRef = useRef<Promise<void>>(Promise.resolve())
  const startRef = useRef(0)

  useEffect(() => {
    if (!session) return
    const queue = new UploadQueue(session, (count, error) => {
      setPending(count)
      setUploadError(error)
    })
    uploaderRef.current = queue
    queue.start()
    return () => {
      queue.stop()
      uploaderRef.current = null
    }
  }, [session])

  useEffect(() => {
    if (!session) return
    let active = true
    api<Profile>('GET', '/me', session.token).then(value => {
      if (active) setProfile(value)
    }).catch(error => {
      if (active && error instanceof APIError && error.status === 401) {
        clearSession()
        setSession(null)
      }
    })
    return () => { active = false }
  }, [session])

  useEffect(() => {
    if (!session) return
    let active = true
    setCameraState('starting')
    if (!navigator.mediaDevices?.getUserMedia) {
      setCameraState('error')
      setMessage('Open the HTTPS site to use the camera')
      return
    }
    navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false })
      .then(async stream => {
        if (!active) { stream.getTracks().forEach(track => track.stop()); return }
        streamRef.current = stream
        stream.getVideoTracks()[0].onended = () => {
          if (active) { setCameraState('error'); setMessage('Camera disconnected') }
        }
        if (videoRef.current) {
          videoRef.current.srcObject = stream
          await videoRef.current.play()
        }
        if (active) setCameraState('ready')
      }).catch(() => {
        if (active) { setCameraState('error'); setMessage('Allow camera access to continue') }
      })
    return () => {
      active = false
      recorderRef.current?.stop()
      recorderRef.current = null
      streamRef.current?.getTracks().forEach(track => track.stop())
      streamRef.current = null
      audioRef.current?.getTracks().forEach(track => track.stop())
      audioRef.current = null
    }
  }, [session])

  useEffect(() => {
    if (!recording) return
    const timer = window.setInterval(() => setSeconds(Math.floor((Date.now() - startRef.current) / 1000)), 250)
    return () => window.clearInterval(timer)
  }, [recording])

  useEffect(() => {
    if (!recording) return
    const stopIfHidden = () => {
      if (document.visibilityState === 'hidden' && recorderRef.current?.state === 'recording') recorderRef.current.stop()
    }
    document.addEventListener('visibilitychange', stopIfHidden)
    return () => document.removeEventListener('visibilitychange', stopIfHidden)
  }, [recording])

  async function enroll(event: FormEvent) {
    event.preventDefault()
    const token = parseInvite(invite)
    if (!token) { setMessage('Invalid invite'); return }
    setEnrolling(true)
    setMessage(null)
    try {
      const next = await api<Session>('POST', '/enroll', undefined, { token })
      saveSession(next)
      setSession(next)
      setInvite('')
    } catch (error) {
      setMessage(error instanceof APIError ? error.message : 'Offline')
    } finally {
      setEnrolling(false)
    }
  }

  async function takePhoto() {
    const video = videoRef.current
    const uploader = uploaderRef.current
    if (!video || !uploader || !video.videoWidth) return
    setMessage(null)
    setFlash(true)
    window.setTimeout(() => setFlash(false), 160)
    try {
      const canvas = document.createElement('canvas')
      canvas.width = video.videoWidth
      canvas.height = video.videoHeight
      canvas.getContext('2d')!.drawImage(video, 0, 0)
      const blob = await new Promise<Blob>((resolve, reject) => {
        canvas.toBlob(value => value ? resolve(value) : reject(new Error('Photo failed')), 'image/jpeg', 0.9)
      })
      await uploader.add(crypto.randomUUID(), 'photo', 0, 'photo', blob)
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Photo failed')
    }
  }

  async function startVideo() {
    const stream = streamRef.current
    const uploader = uploaderRef.current
    if (!stream || !uploader || preparing) return
    if (!window.MediaRecorder || !MediaRecorder.isTypeSupported('video/mp4')) {
      setMessage('Video recording is unavailable in this browser')
      return
    }
    setMessage(null)
    setPreparing(true)
    try {
      let audio: MediaStream | null = null
      try { audio = await navigator.mediaDevices.getUserMedia({ audio: true }) } catch { /* Silent video is allowed. */ }
      audioRef.current = audio
      const tracks = [...stream.getVideoTracks(), ...(audio?.getAudioTracks() || [])]
      const recorder = new MediaRecorder(new MediaStream(tracks), {
        mimeType: 'video/mp4', videoBitsPerSecond: 1_500_000, audioBitsPerSecond: 64_000,
      })
      const captureId = crypto.randomUUID()
      let sequence = 0
      let queueFailed = false
      enqueueRef.current = Promise.resolve()
      recorder.ondataavailable = event => {
        if (!event.data.size || queueFailed) return
        const number = sequence++
        const kind = number === 0 ? 'init' : 'media'
        const blob = new Blob([event.data], { type: 'video/mp4' })
        enqueueRef.current = enqueueRef.current.then(() => uploader.add(captureId, 'video', number, kind, blob))
          .catch(error => {
            queueFailed = true
            setMessage(error instanceof Error ? error.message : 'Video could not be saved')
            if (recorder.state !== 'inactive') recorder.stop()
          })
      }
      recorder.onstop = () => {
        audio?.getTracks().forEach(track => track.stop())
        audioRef.current = null
        recorderRef.current = null
        setRecording(false)
        setStopping(false)
        void enqueueRef.current.then(() => api('POST', `/captures/${captureId}/finish`, session?.token)).catch(() => {})
      }
      recorder.onerror = () => setMessage('Recording interrupted')
      recorderRef.current = recorder
      recorder.start(1000)
      startRef.current = Date.now()
      setSeconds(0)
      setRecording(true)
    } catch {
      audioRef.current?.getTracks().forEach(track => track.stop())
      audioRef.current = null
      setMessage('Could not start recording')
    } finally {
      setPreparing(false)
    }
  }

  function stopVideo() {
    if (recorderRef.current?.state === 'recording') {
      setStopping(true)
      recorderRef.current.stop()
    }
  }

  async function saveProfile(event: FormEvent) {
    event.preventDefault()
    if (!session || !profile) return
    setSavingProfile(true)
    setMessage(null)
    try {
      const updated = await api<Profile>('PATCH', '/me', session.token, {
        name: profile.name, email: profile.email, signal_username: profile.signal_username,
      })
      setProfile(updated)
      setProfileOpen(false)
    } catch (error) {
      setMessage(error instanceof APIError ? error.message : 'Offline')
    } finally {
      setSavingProfile(false)
    }
  }

  if (!session) return <main className="invite-page">
    <div className="invite-content">
      <div className="brand invite-brand"><img src={appIcon} alt="" /><span className="wordmark">Nima</span></div>
      <div className="invite-bottom">
        <h1>Enter invite</h1>
        <form onSubmit={enroll}>
          <label className="sr-only" htmlFor="invite">Invite code</label>
          <input id="invite" type="text" autoComplete="off" autoCapitalize="none" spellCheck={false}
            placeholder="Invite code" value={invite} onChange={event => setInvite(event.target.value)} />
          <button className="primary-button" type="submit" disabled={enrolling || !invite.trim()}>
            {enrolling ? 'Joining…' : 'Continue'}
          </button>
        </form>
        {message && <p className="form-message" role="alert">{message}</p>}
      </div>
    </div>
  </main>

  return <main className="camera-page">
    <video className="camera-preview" ref={videoRef} autoPlay muted playsInline />
    <div className="camera-vignette" />
    <div className={`photo-flash ${flash ? 'visible' : ''}`} />
    <header className="camera-header">
      <span className="brand camera-brand"><img src={appIcon} alt="" /><span className="small-wordmark">Nima</span></span>
      <div className="header-actions">
        <div className={`cloud-status ${uploadError ? 'problem' : pending ? 'busy' : ''}`} role="status" aria-live="polite">
          <CloudIcon /><span>{uploadError || (pending ? 'Uploading' : 'Saved')}</span>
        </div>
        <button className="icon-button" aria-label="Profile" onClick={() => setProfileOpen(true)} disabled={recording || preparing}>
          <ProfileIcon />
        </button>
      </div>
    </header>
    {cameraState !== 'ready' && <div className="camera-prompt">
      <p>{cameraState === 'starting' ? 'Opening camera…' : message || 'Camera unavailable'}</p>
      {cameraState === 'error' && <button onClick={() => location.reload()}>Try again</button>}
    </div>}
    {recording && <div className="record-time"><span className="record-dot" />{formatTime(seconds)}</div>}
    {message && cameraState === 'ready' && <div className="camera-message" role="alert">{message}</div>}
    <div className="camera-controls">
      <div className="mode-picker" role="group" aria-label="Capture mode">
        <button className={mode === 'photo' ? 'selected' : ''} onClick={() => setMode('photo')} disabled={recording || preparing}>PHOTO</button>
        <button className={mode === 'video' ? 'selected' : ''} onClick={() => setMode('video')} disabled={recording || preparing}>VIDEO</button>
      </div>
      <button className={`shutter ${mode === 'video' ? 'video-mode' : ''} ${recording ? 'recording' : ''}`}
        aria-label={recording ? 'Stop recording' : mode === 'photo' ? 'Take photo' : 'Record video'}
        disabled={cameraState !== 'ready' || stopping || preparing}
        onClick={() => recording ? stopVideo() : mode === 'photo' ? void takePhoto() : void startVideo()}>
        <span />
      </button>
    </div>
    {profileOpen && <div className="sheet-backdrop" onClick={() => setProfileOpen(false)}>
      <section className="profile-sheet" aria-label="Profile" onClick={event => event.stopPropagation()}>
        <div className="sheet-header"><h2>Profile</h2><button onClick={() => setProfileOpen(false)} aria-label="Close profile">Done</button></div>
        <form onSubmit={saveProfile}>
          <label>Name<input type="text" autoComplete="name" value={profile?.name || ''}
            onChange={event => setProfile(value => value && { ...value, name: event.target.value })} /></label>
          <label>Email<input type="email" autoComplete="email" value={profile?.email || ''}
            onChange={event => setProfile(value => value && { ...value, email: event.target.value })} /></label>
          <label>Signal<input type="text" autoCapitalize="none" autoComplete="off" value={profile?.signal_username || ''}
            onChange={event => setProfile(value => value && { ...value, signal_username: event.target.value })} /></label>
          <button className="primary-button" type="submit" disabled={!profile || savingProfile}>{savingProfile ? 'Saving…' : 'Save'}</button>
          {message && <p className="form-message" role="alert">{message}</p>}
        </form>
      </section>
    </div>}
  </main>
}
