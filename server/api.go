package main

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxObjectSize int64 = 12 << 20
const accountQuota int64 = 10 << 30

var captureID = regexp.MustCompile(`^[a-fA-F0-9-]{32,36}$`)

type api struct {
	db      *sql.DB
	store   objectStore
	limiter inviteLimiter
}
type profile struct {
	ID             string `json:"id"`
	Role           string `json:"role"`
	Name           string `json:"name"`
	Email          string `json:"email"`
	SignalUsername string `json:"signal_username"`
}
type object struct {
	CaptureID    string  `json:"-"`
	Sequence     int     `json:"sequence"`
	Kind         string  `json:"kind"`
	Key          string  `json:"-"`
	SHA256       string  `json:"sha256"`
	MD5          string  `json:"md5"`
	Size         int64   `json:"size"`
	Duration     float64 `json:"duration"`
	StartTime    float64 `json:"start_time"`
	Acknowledged bool    `json:"acknowledged"`
	URL          string  `json:"url,omitempty"`
}

type captureLocation struct {
	Latitude            *float64 `json:"latitude"`
	Longitude           *float64 `json:"longitude"`
	HorizontalAccuracyM *float64 `json:"horizontal_accuracy_m"`
	Timestamp           *int64   `json:"timestamp"`
}

func (l captureLocation) valid() bool {
	if l.Latitude == nil || l.Longitude == nil || l.HorizontalAccuracyM == nil || l.Timestamp == nil {
		return false
	}
	return !math.IsNaN(*l.Latitude) && !math.IsInf(*l.Latitude, 0) && *l.Latitude >= -90 && *l.Latitude <= 90 &&
		!math.IsNaN(*l.Longitude) && !math.IsInf(*l.Longitude, 0) && *l.Longitude >= -180 && *l.Longitude <= 180 &&
		!math.IsNaN(*l.HorizontalAccuracyM) && !math.IsInf(*l.HorizontalAccuracyM, 0) &&
		*l.HorizontalAccuracyM >= 0 && *l.HorizontalAccuracyM <= 1_000_000 &&
		*l.Timestamp > 0 && *l.Timestamp <= time.Now().Unix()+300
}

func locationFromDB(lat, lon, accuracy sql.NullFloat64, timestamp sql.NullInt64) *captureLocation {
	if !lat.Valid || !lon.Valid || !accuracy.Valid || !timestamp.Valid {
		return nil
	}
	return &captureLocation{&lat.Float64, &lon.Float64, &accuracy.Float64, &timestamp.Int64}
}

func (o object) contentType() string {
	if o.Kind == "photo" {
		return "image/jpeg"
	}
	return "video/mp4"
}

type accountContext struct{}

func account(r *http.Request) string { return r.Context().Value(accountContext{}).(string) }
func jsonResponse(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func failure(w http.ResponseWriter, status int, message string) {
	jsonResponse(w, status, map[string]string{"error": message})
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		failure(w, 400, "Invalid request")
		return false
	}
	if d.Decode(new(any)) != io.EOF {
		failure(w, 400, "Invalid request")
		return false
	}
	return true
}
func (a *api) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		if a.db.PingContext(r.Context()) != nil {
			failure(w, 503, "Unavailable")
			return
		}
		jsonResponse(w, 200, map[string]bool{"ok": true})
	})
	mux.HandleFunc("POST /enroll", a.enroll)
	protected := http.NewServeMux()
	protected.HandleFunc("GET /me", a.me)
	protected.HandleFunc("PATCH /me", a.updateMe)
	protected.HandleFunc("POST /invites", a.createInvite)
	protected.HandleFunc("PUT /captures/{id}", a.createCapture)
	protected.HandleFunc("POST /captures/{id}/objects/reserve", a.reserve)
	protected.HandleFunc("POST /captures/{id}/objects/ack", a.ack)
	protected.HandleFunc("POST /captures/{id}/finish", a.finish)
	protected.HandleFunc("GET /captures", a.listCaptures)
	protected.HandleFunc("GET /captures/{id}", a.getCapture)
	protected.HandleFunc("DELETE /captures/{id}", a.deleteCapture)
	mux.Handle("/", a.auth(protected))
	return mux
}
func (a *api) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") || len(header) > 256 {
			failure(w, 401, "Scan a new invite")
			return
		}
		var id string
		err := a.db.QueryRowContext(r.Context(), `SELECT s.account_id FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.hash=? AND s.revoked=0 AND a.active=1`, digest(strings.TrimPrefix(header, "Bearer "))).Scan(&id)
		if err != nil {
			failure(w, 401, "Scan a new invite")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), accountContext{}, id)))
	})
}

type attempt struct {
	start time.Time
	count int
}
type inviteLimiter struct {
	sync.Mutex
	entries map[string]attempt
}

func (l *inviteLimiter) allow(key string) bool {
	l.Lock()
	defer l.Unlock()
	if l.entries == nil {
		l.entries = map[string]attempt{}
	}
	now := time.Now()
	for k, v := range l.entries {
		if now.Sub(v.start) > time.Minute {
			delete(l.entries, k)
		}
	}
	if len(l.entries) > 4096 {
		return false
	}
	v := l.entries[key]
	if v.start.IsZero() {
		v.start = now
	}
	v.count++
	l.entries[key] = v
	return v.count <= 10
}
func (a *api) enroll(w http.ResponseWriter, r *http.Request) {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if !a.limiter.allow("enroll:" + host) {
		failure(w, 429, "Try again shortly")
		return
	}
	var input struct {
		Token string `json:"token"`
	}
	if !decode(w, r, &input) {
		return
	}
	if len(input.Token) != 43 {
		failure(w, 401, "Invalid invite")
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer tx.Rollback()
	var existing sql.NullString
	var role string
	err = tx.QueryRow(`UPDATE invites SET consumed_at=? WHERE hash=? AND consumed_at IS NULL AND expires_at>? RETURNING account_id,role`, time.Now().Unix(), digest(input.Token), time.Now().Unix()).Scan(&existing, &role)
	if err != nil {
		failure(w, 401, "Invalid invite")
		return
	}
	id := existing.String
	if !existing.Valid {
		id = newID()
		_, err = tx.Exec("INSERT INTO accounts(id,created_at,role) VALUES(?,?,?)", id, time.Now().Unix(), role)
	} else {
		var active int
		err = tx.QueryRow("SELECT active,role FROM accounts WHERE id=?", id).Scan(&active, &role)
		if active != 1 {
			failure(w, 401, "Invalid invite")
			return
		}
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	token := secret()
	if _, err = tx.Exec("INSERT INTO sessions(hash,account_id) VALUES(?,?)", digest(token), id); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if err = tx.Commit(); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 201, map[string]any{"token": token, "account_id": id, "role": role})
}
func (a *api) createInvite(w http.ResponseWriter, r *http.Request) {
	var role string
	if err := a.db.QueryRowContext(r.Context(), "SELECT role FROM accounts WHERE id=?", account(r)).Scan(&role); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if role != "admin" {
		failure(w, 403, "Admins only")
		return
	}
	var input struct{}
	if !decode(w, r, &input) {
		return
	}
	if !a.limiter.allow("issue:" + account(r)) {
		failure(w, 429, "Try again shortly")
		return
	}
	invite, err := issueInvite(a.db, "", 24*time.Hour, false, account(r))
	if err != nil {
		failure(w, 503, "Could not create invite")
		return
	}
	jsonResponse(w, 201, invite)
}
func (a *api) me(w http.ResponseWriter, r *http.Request) {
	var p profile
	if err := a.db.QueryRowContext(r.Context(), "SELECT id,role,name,email,signal_username FROM accounts WHERE id=?", account(r)).Scan(&p.ID, &p.Role, &p.Name, &p.Email, &p.SignalUsername); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, p)
}
func (a *api) updateMe(w http.ResponseWriter, r *http.Request) {
	var p struct {
		Name           string `json:"name"`
		Email          string `json:"email"`
		SignalUsername string `json:"signal_username"`
	}
	if !decode(w, r, &p) {
		return
	}
	p.Name = strings.TrimSpace(p.Name)
	p.Email = strings.TrimSpace(p.Email)
	p.SignalUsername = strings.TrimSpace(p.SignalUsername)
	if len(p.Name) > 120 || len(p.Email) > 254 || len(p.SignalUsername) > 120 {
		failure(w, 400, "Profile is too long")
		return
	}
	if _, err := a.db.ExecContext(r.Context(), "UPDATE accounts SET name=?,email=?,signal_username=? WHERE id=?", p.Name, p.Email, p.SignalUsername, account(r)); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	a.me(w, r)
}
func (a *api) owned(w http.ResponseWriter, r *http.Request) (string, bool) {
	var kind string
	var deleted sql.NullInt64
	err := a.db.QueryRowContext(r.Context(), "SELECT kind,deleted_at FROM captures WHERE id=? AND account_id=?", r.PathValue("id"), account(r)).Scan(&kind, &deleted)
	if err != nil {
		failure(w, 404, "Not found")
		return "", false
	}
	if deleted.Valid {
		failure(w, 410, "Capture deleted")
		return "", false
	}
	return kind, true
}
func (a *api) createCapture(w http.ResponseWriter, r *http.Request) {
	var p struct {
		Kind     string           `json:"kind"`
		Location *captureLocation `json:"location"`
	}
	if !decode(w, r, &p) {
		return
	}
	id := r.PathValue("id")
	if !captureID.MatchString(id) || (p.Kind != "video" && p.Kind != "photo") || (p.Location != nil && !p.Location.valid()) {
		failure(w, 400, "Invalid capture")
		return
	}
	var latitude, longitude, accuracy, timestamp any
	if p.Location != nil {
		latitude, longitude = *p.Location.Latitude, *p.Location.Longitude
		accuracy, timestamp = *p.Location.HorizontalAccuracyM, *p.Location.Timestamp
	}
	_, err := a.db.ExecContext(r.Context(), `INSERT INTO captures(id,account_id,kind,created_at,latitude,longitude,horizontal_accuracy_m,location_timestamp)
		VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING`, id, account(r), p.Kind, time.Now().Unix(), latitude, longitude, accuracy, timestamp)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	kind, ok := a.owned(w, r)
	if !ok {
		return
	}
	if kind != p.Kind {
		failure(w, 409, "Capture conflict")
		return
	}
	if p.Location != nil {
		var lat, lon, acc sql.NullFloat64
		var ts sql.NullInt64
		if err = a.db.QueryRowContext(r.Context(), "SELECT latitude,longitude,horizontal_accuracy_m,location_timestamp FROM captures WHERE id=?", id).Scan(&lat, &lon, &acc, &ts); err != nil {
			failure(w, 503, "Unavailable")
			return
		}
		stored := locationFromDB(lat, lon, acc, ts)
		if stored == nil || *stored.Latitude != *p.Location.Latitude || *stored.Longitude != *p.Location.Longitude ||
			*stored.HorizontalAccuracyM != *p.Location.HorizontalAccuracyM || *stored.Timestamp != *p.Location.Timestamp {
			failure(w, 409, "Capture conflict")
			return
		}
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}

const objectColumns = "capture_id,sequence,kind,object_key,sha256,md5,size,duration,start_time,acknowledged"

func scanObject(row interface{ Scan(...any) error }) (object, error) {
	var o object
	err := row.Scan(&o.CaptureID, &o.Sequence, &o.Kind, &o.Key, &o.SHA256, &o.MD5, &o.Size, &o.Duration, &o.StartTime, &o.Acknowledged)
	return o, err
}
func (a *api) reserve(w http.ResponseWriter, r *http.Request) {
	kind, ok := a.owned(w, r)
	if !ok {
		return
	}
	var o object
	if !decode(w, r, &o) {
		return
	}
	o.CaptureID = r.PathValue("id")
	sha, err := hex.DecodeString(o.SHA256)
	md5, e2 := base64.StdEncoding.DecodeString(o.MD5)
	validKind := (kind == "photo" && o.Kind == "photo" && o.Sequence == 0) || (kind == "video" && ((o.Sequence == 0 && o.Kind == "init") || (o.Sequence > 0 && o.Kind == "media")))
	if !validKind || o.Sequence < 0 || o.Sequence > 100000 || o.Size <= 0 || o.Size > maxObjectSize || err != nil || len(sha) != 32 || e2 != nil || len(md5) != 16 || o.Duration < 0 || o.Duration > 60 || o.StartTime < 0 || math.IsNaN(o.Duration) || math.IsNaN(o.StartTime) {
		failure(w, 400, "Invalid object")
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer tx.Rollback()
	// Serialize reservations with deletion, including signing the last upload URL.
	var deleted sql.NullInt64
	if err = tx.QueryRow("SELECT deleted_at FROM captures WHERE id=?", o.CaptureID).Scan(&deleted); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if deleted.Valid {
		failure(w, 410, "Capture deleted")
		return
	}
	old, err := scanObject(tx.QueryRow("SELECT "+objectColumns+" FROM objects WHERE capture_id=? AND sequence=?", o.CaptureID, o.Sequence))
	if err == nil {
		if old.SHA256 != o.SHA256 || old.MD5 != o.MD5 || old.Size != o.Size || old.Kind != o.Kind || old.Duration != o.Duration || old.StartTime != o.StartTime {
			failure(w, 409, "Object conflict")
			return
		}
		o = old
	} else if errors.Is(err, sql.ErrNoRows) {
		var used int64
		if err = tx.QueryRow("SELECT COALESCE(SUM(o.size),0) FROM objects o JOIN captures c ON c.id=o.capture_id WHERE c.account_id=? AND c.deleted_at IS NULL", account(r)).Scan(&used); err != nil {
			failure(w, 503, "Unavailable")
			return
		}
		if used+o.Size > accountQuota {
			failure(w, 413, "Storage full")
			return
		}
		o.Key = newID() + "/" + newID()
		o.Acknowledged = false
		_, err = tx.Exec("INSERT INTO objects("+objectColumns+") VALUES(?,?,?,?,?,?,?,?,?,0)", o.CaptureID, o.Sequence, o.Kind, o.Key, o.SHA256, o.MD5, o.Size, o.Duration, o.StartTime)
		if err != nil {
			failure(w, 503, "Unavailable")
			return
		}
	} else {
		failure(w, 503, "Unavailable")
		return
	}
	var signed signedUpload
	if !o.Acknowledged {
		signed, err = a.store.upload(r.Context(), o)
		if err != nil {
			failure(w, 503, "Storage unavailable")
			return
		}
	}
	if err = tx.Commit(); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if o.Acknowledged {
		jsonResponse(w, 200, map[string]any{"acknowledged": true})
		return
	}
	jsonResponse(w, 200, map[string]any{"acknowledged": false, "url": signed.URL, "headers": signed.Headers})
}
func (a *api) acknowledge(ctx context.Context, o object) (bool, error) {
	if o.Acknowledged {
		return true, nil
	}
	ok, err := a.store.verify(ctx, o)
	if err != nil || !ok {
		return ok, err
	}
	_, err = a.db.ExecContext(ctx, "UPDATE objects SET acknowledged=1 WHERE capture_id=? AND sequence=?", o.CaptureID, o.Sequence)
	return err == nil, err
}
func (a *api) ack(w http.ResponseWriter, r *http.Request) {
	if _, ok := a.owned(w, r); !ok {
		return
	}
	var p struct {
		Sequence int `json:"sequence"`
	}
	if !decode(w, r, &p) {
		return
	}
	o, err := scanObject(a.db.QueryRowContext(r.Context(), "SELECT "+objectColumns+" FROM objects WHERE capture_id=? AND sequence=?", r.PathValue("id"), p.Sequence))
	if err != nil {
		failure(w, 404, "Not found")
		return
	}
	ok, err := a.acknowledge(r.Context(), o)
	if err != nil {
		failure(w, 503, "Could not verify upload")
		return
	}
	if !ok {
		failure(w, 409, "Upload missing")
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}
func (a *api) finish(w http.ResponseWriter, r *http.Request) {
	if _, ok := a.owned(w, r); !ok {
		return
	}
	if _, err := a.db.ExecContext(r.Context(), "UPDATE captures SET finished=1 WHERE id=?", r.PathValue("id")); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}
func (a *api) listCaptures(w http.ResponseWriter, r *http.Request) {
	after := r.URL.Query().Get("after")
	rows, err := a.db.QueryContext(r.Context(), `SELECT id,kind,created_at,finished,latitude,longitude,horizontal_accuracy_m,location_timestamp
		FROM captures WHERE account_id=? AND deleted_at IS NULL AND id>? ORDER BY id LIMIT 100`, account(r), after)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer rows.Close()
	type capture struct {
		ID       string           `json:"id"`
		Kind     string           `json:"kind"`
		Created  int64            `json:"created_at"`
		Finished bool             `json:"finished"`
		Location *captureLocation `json:"location,omitempty"`
	}
	list := []capture{}
	for rows.Next() {
		var c capture
		var lat, lon, accuracy sql.NullFloat64
		var timestamp sql.NullInt64
		if rows.Scan(&c.ID, &c.Kind, &c.Created, &c.Finished, &lat, &lon, &accuracy, &timestamp) != nil {
			failure(w, 503, "Unavailable")
			return
		}
		c.Location = locationFromDB(lat, lon, accuracy, timestamp)
		list = append(list, c)
	}
	if rows.Err() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]any{"captures": list})
}
func (a *api) getCapture(w http.ResponseWriter, r *http.Request) {
	kind, ok := a.owned(w, r)
	if !ok {
		return
	}
	var lat, lon, accuracy sql.NullFloat64
	var timestamp sql.NullInt64
	if err := a.db.QueryRowContext(r.Context(), "SELECT latitude,longitude,horizontal_accuracy_m,location_timestamp FROM captures WHERE id=?", r.PathValue("id")).Scan(&lat, &lon, &accuracy, &timestamp); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	location := locationFromDB(lat, lon, accuracy, timestamp)
	after := -1
	if s := r.URL.Query().Get("after"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < -1 {
			failure(w, 400, "Invalid cursor")
			return
		}
		after = n
	}
	rows, err := a.db.QueryContext(r.Context(), "SELECT "+objectColumns+" FROM objects WHERE capture_id=? AND sequence>? ORDER BY sequence LIMIT 50", r.PathValue("id"), after)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	list := []object{}
	for rows.Next() {
		o, e := scanObject(rows)
		if e != nil {
			rows.Close()
			failure(w, 503, "Unavailable")
			return
		}
		list = append(list, o)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	// Reconcile reservations even if the phone never delivered /ack or /finish.
	for i := range list {
		verified, e := a.acknowledge(r.Context(), list[i])
		if e != nil {
			failure(w, 503, "Storage unavailable")
			return
		}
		list[i].Acknowledged = verified
		if verified {
			list[i].URL, e = a.store.download(r.Context(), list[i].Key)
			if e != nil {
				failure(w, 503, "Storage unavailable")
				return
			}
		}
	}
	jsonResponse(w, 200, map[string]any{"id": r.PathValue("id"), "kind": kind, "location": location, "objects": list})
}
