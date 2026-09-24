package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type memoryStore struct {
	sync.Mutex
	data map[string][]byte
}

func (s *memoryStore) upload(_ context.Context, o object) (signedUpload, error) {
	return signedUpload{URL: "https://example.invalid/" + o.Key}, nil
}
func (s *memoryStore) verify(_ context.Context, o object) (bool, error) {
	s.Lock()
	defer s.Unlock()
	b, ok := s.data[o.Key]
	if !ok {
		return false, nil
	}
	h := sha256.Sum256(b)
	return int64(len(b)) == o.Size && hex.EncodeToString(h[:]) == o.SHA256, nil
}
func (s *memoryStore) download(_ context.Context, key string) (string, error) {
	return "https://example.invalid/" + key, nil
}

type testAPI struct {
	db     *sql.DB
	server *httptest.Server
	store  *memoryStore
}

func setup(t *testing.T) *testAPI {
	t.Helper()
	db, err := openDB(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	store := &memoryStore{data: map[string][]byte{}}
	server := httptest.NewServer((&api{db: db, store: store}).handler())
	t.Cleanup(func() { server.Close(); db.Close() })
	return &testAPI{db, server, store}
}
func request(t *testing.T, base, method, path, token string, body any) (int, []byte) {
	t.Helper()
	var data []byte
	var err error
	if body != nil {
		data, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, base+path, bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, b
}
func mustStatus(t *testing.T, want, got int, body []byte) {
	t.Helper()
	if want != got {
		t.Fatalf("want status %d, got %d: %s", want, got, body)
	}
}
func enrollTest(t *testing.T, h *testAPI) (string, string) {
	t.Helper()
	invite, err := issueInvite(h.db, "", time.Hour, false, "")
	if err != nil {
		t.Fatal(err)
	}
	status, body := request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": invite.Token})
	mustStatus(t, 201, status, body)
	var result struct {
		Token     string
		AccountID string          `json:"account_id"`
		ExpiresAt json.RawMessage `json:"expires_at"`
	}
	if err = json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.ExpiresAt) != 0 {
		t.Fatal("enrollment response must not include a session expiry")
	}
	return result.Token, result.AccountID
}
func makeObject(data []byte, kind string, seq int) object {
	sha := sha256.Sum256(data)
	md := md5.Sum(data)
	return object{Kind: kind, Sequence: seq, Size: int64(len(data)), SHA256: hex.EncodeToString(sha[:]), MD5: base64.StdEncoding.EncodeToString(md[:])}
}
func TestInviteSingleUseConcurrentAndExpiry(t *testing.T) {
	h := setup(t)
	invite, err := issueInvite(h.db, "", time.Hour, false, "")
	if err != nil {
		t.Fatal(err)
	}
	statuses := make(chan int, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Go(func() {
			s, _ := request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": invite.Token})
			statuses <- s
		})
	}
	wg.Wait()
	close(statuses)
	counts := map[int]int{}
	for s := range statuses {
		counts[s]++
	}
	if counts[201] != 1 || counts[401] != 1 {
		t.Fatalf("concurrent redemption: %v", counts)
	}
	expired, _ := issueInvite(h.db, "", -time.Hour, false, "")
	s, b := request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": expired.Token})
	mustStatus(t, 401, s, b)
	var count int
	h.db.QueryRow("SELECT COUNT(*) FROM accounts").Scan(&count)
	if count != 1 {
		t.Fatal("failed enrollment created an account")
	}
}
func TestOwnershipProfilesRevocationAndRecovery(t *testing.T) {
	h := setup(t)
	token, owner := enrollTest(t, h)
	other, _ := enrollTest(t, h)
	p := map[string]string{"name": "Camera One", "email": "one@example.test", "signal_username": "one.01"}
	s, b := request(t, h.server.URL, "PATCH", "/me", token, p)
	mustStatus(t, 200, s, b)
	s, b = request(t, h.server.URL, "GET", "/me", other, nil)
	mustStatus(t, 200, s, b)
	if bytes.Contains(b, []byte("Camera One")) {
		t.Fatal("profile leaked")
	}
	id := "11111111-1111-1111-1111-111111111111"
	s, b = request(t, h.server.URL, "PUT", "/captures/"+id, token, map[string]string{"kind": "video"})
	mustStatus(t, 200, s, b)
	data := []byte("fragment bytes")
	o := makeObject(data, "init", 0)
	s, b = request(t, h.server.URL, "POST", "/captures/"+id+"/objects/reserve", token, o)
	mustStatus(t, 200, s, b)
	s, b = request(t, h.server.URL, "POST", "/captures/"+id+"/objects/reserve", token, o)
	mustStatus(t, 200, s, b)
	changed := o
	changed.SHA256 = fmt.Sprintf("%064x", 1)
	s, b = request(t, h.server.URL, "POST", "/captures/"+id+"/objects/reserve", token, changed)
	mustStatus(t, 409, s, b)
	for _, path := range []string{"/captures/" + id, "/captures/" + id + "/objects/reserve", "/captures/" + id + "/objects/ack", "/captures/" + id + "/finish"} {
		method := "POST"
		if path == "/captures/"+id {
			method = "GET"
		}
		s, b = request(t, h.server.URL, method, path, other, o)
		mustStatus(t, 404, s, b)
	}
	s, b = request(t, h.server.URL, "POST", "/captures/"+id+"/objects/ack", token, map[string]int{"sequence": 0})
	mustStatus(t, 409, s, b)
	var key string
	if err := h.db.QueryRow("SELECT object_key FROM objects").Scan(&key); err != nil {
		t.Fatal(err)
	}
	h.store.Lock()
	h.store.data[key] = data
	h.store.Unlock()
	// Neither an acknowledgment nor /finish was sent by the phone.
	s, b = request(t, h.server.URL, "GET", "/captures/"+id, token, nil)
	mustStatus(t, 200, s, b)
	var result struct{ Objects []object }
	json.Unmarshal(b, &result)
	if len(result.Objects) != 1 || !result.Objects[0].Acknowledged || result.Objects[0].URL == "" {
		t.Fatal("lost acknowledgment was not recovered")
	}
	if _, err := h.db.Exec("UPDATE sessions SET revoked=1 WHERE hash=?", digest(token)); err != nil {
		t.Fatal(err)
	}
	s, b = request(t, h.server.URL, "GET", "/me", token, nil)
	mustStatus(t, 401, s, b)
	replacement, _ := issueInvite(h.db, owner, time.Hour, false, "")
	s, b = request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": replacement.Token})
	mustStatus(t, 201, s, b)
	var session struct{ Token string }
	json.Unmarshal(b, &session)
	s, b = request(t, h.server.URL, "GET", "/me", session.Token, nil)
	mustStatus(t, 200, s, b)
	if !bytes.Contains(b, []byte("Camera One")) {
		t.Fatal("replacement lost account")
	}
	h.db.Exec("UPDATE accounts SET active=0 WHERE id=?", owner)
	s, b = request(t, h.server.URL, "GET", "/captures/"+id, session.Token, nil)
	mustStatus(t, 401, s, b)
}
func TestBackupRestore(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	request(t, h.server.URL, "PATCH", "/me", token, map[string]string{"name": "Persistent"})
	backup := filepath.Join(t.TempDir(), "backup.sqlite")
	if _, err := h.db.Exec("VACUUM INTO ?", backup); err != nil {
		t.Fatal(err)
	}
	restored, err := openDB(backup)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	server := httptest.NewServer((&api{db: restored, store: h.store}).handler())
	defer server.Close()
	s, b := request(t, server.URL, "GET", "/me", token, nil)
	mustStatus(t, 200, s, b)
	if !bytes.Contains(b, []byte("Persistent")) {
		t.Fatal("backup did not restore profile and session")
	}
}
func TestLimitsAndValidation(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	id := "22222222-2222-2222-2222-222222222222"
	request(t, h.server.URL, "PUT", "/captures/"+id, token, map[string]string{"kind": "photo"})
	invalid := makeObject([]byte("image"), "media", 1)
	s, b := request(t, h.server.URL, "POST", "/captures/"+id+"/objects/reserve", token, invalid)
	mustStatus(t, 400, s, b)
	invalid.Kind = "photo"
	invalid.Sequence = 0
	invalid.Size = maxObjectSize + 1
	s, b = request(t, h.server.URL, "POST", "/captures/"+id+"/objects/reserve", token, invalid)
	mustStatus(t, 400, s, b)
	s, b = request(t, h.server.URL, "PATCH", "/me", token, map[string]string{"account_id": "someone-else"})
	mustStatus(t, 400, s, b)
	for range 12 {
		s, _ = request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": "invalid"})
	}
	if s != 429 {
		t.Fatal("enrollment not rate limited")
	}
}

// Run with TEST_S3=1 and the local .env exported. Uses a real private RustFS bucket.
func TestS3ConditionalUploadAndRecovery(t *testing.T) {
	if os.Getenv("TEST_S3") != "1" {
		t.Skip("requires local S3")
	}
	store, err := newS3()
	if err != nil {
		t.Fatal(err)
	}
	h := setup(t)
	h.server.Close()
	h.server = httptest.NewServer((&api{db: h.db, store: store}).handler())
	token, _ := enrollTest(t, h)
	id := newID()
	s, b := request(t, h.server.URL, "PUT", "/captures/"+id, token, map[string]string{"kind": "photo"})
	mustStatus(t, 200, s, b)
	data := []byte("private test photo")
	o := makeObject(data, "photo", 0)
	s, b = request(t, h.server.URL, "POST", "/captures/"+id+"/objects/reserve", token, o)
	mustStatus(t, 200, s, b)
	var signed signedUpload
	if err = json.Unmarshal(b, &signed); err != nil {
		t.Fatal(err)
	}
	put := func() int {
		req, _ := http.NewRequest("PUT", signed.URL, bytes.NewReader(data))
		for k, v := range signed.Headers {
			req.Header.Set(k, v)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		io.Copy(io.Discard, resp.Body)
		return resp.StatusCode
	}
	if s = put(); s != 200 {
		t.Fatalf("PUT: %d", s)
	}
	if s = put(); s != 412 {
		t.Fatalf("conditional retry must be 412, got %d", s)
	}
	s, b = request(t, h.server.URL, "GET", "/captures/"+id, token, nil)
	mustStatus(t, 200, s, b)
	var result struct{ Objects []object }
	json.Unmarshal(b, &result)
	if len(result.Objects) != 1 || !result.Objects[0].Acknowledged {
		t.Fatal("not reconciled")
	}
	resp, err := http.Get(result.Objects[0].URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	got, _ := io.ReadAll(resp.Body)
	if !bytes.Equal(data, got) {
		t.Fatal("retrieved different bytes")
	}
	// An unsigned request to the same bucket must remain private.
	u := result.Objects[0].URL
	for i, c := range u {
		if c == '?' {
			u = u[:i]
			break
		}
	}
	private, err := http.Get(u)
	if err != nil {
		t.Fatal(err)
	}
	private.Body.Close()
	if private.StatusCode < 400 {
		t.Fatal("bucket publicly readable")
	}
}

func TestLiveMediaBeforeStop(t *testing.T) {
	if os.Getenv("TEST_S3") != "1" || os.Getenv("MEDIA_PROBE") == "" {
		t.Skip("requires local S3 and compiled media probe")
	}
	store, err := newS3()
	if err != nil {
		t.Fatal(err)
	}
	h := setup(t)
	h.server.Close()
	h.server = httptest.NewServer((&api{db: h.db, store: store}).handler())
	token, account := enrollTest(t, h)
	folder := t.TempDir()
	sessionPath := filepath.Join(folder, "session.json")
	data, _ := json.Marshal(map[string]any{"token": token, "account_id": account, "role": "member"})
	if err = os.WriteFile(sessionPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Getenv("MEDIA_PROBE"), h.server.URL, sessionPath, filepath.Join(folder, "queue"))
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("media probe failed: %v\n%s", err, output)
	}
	t.Log(string(output))
	var captures map[string]string
	captureData, e := os.ReadFile(filepath.Join(folder, "captures.json"))
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(captureData, &captures); e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"video_id", "photo_id"} {
		output, err = exec.Command("python3", "../tools/retrieve.py", "--api", h.server.URL, "--session", sessionPath, "--capture", captures[key], "--out", filepath.Join(folder, key)).CombinedOutput()
		if err != nil {
			t.Fatalf("retrieval helper: %v %s", err, output)
		}
	}
	live := filepath.Join(folder, "live-before-stop.mp4")
	output, err = exec.Command("ffprobe", "-v", "error", "-show_entries", "stream=codec_name,width,height:format=start_time,duration", "-of", "json", live).CombinedOutput()
	if err != nil {
		t.Fatalf("ffprobe: %v %s", err, output)
	}
	if !bytes.Contains(output, []byte(`"h264"`)) || !bytes.Contains(output, []byte(`"aac"`)) || !bytes.Contains(output, []byte(`"width": 720`)) {
		t.Fatalf("wrong streams: %s", output)
	}
	var timing struct {
		Format struct {
			Start    float64 `json:"start_time,string"`
			Duration float64 `json:"duration,string"`
		}
	}
	if err = json.Unmarshal(output, &timing); err != nil || timing.Format.Start < -0.05 || timing.Format.Start > 0.05 || timing.Format.Duration <= 0 || timing.Format.Duration > 7 {
		t.Fatalf("live video timeline must start at zero: %v %s", err, output)
	}
	output, err = exec.Command("ffmpeg", "-v", "error", "-i", live, "-f", "null", "-").CombinedOutput()
	if err != nil || len(bytes.TrimSpace(output)) != 0 {
		t.Fatalf("live file does not decode cleanly: %v %s", err, output)
	}
	output, err = exec.Command("ffmpeg", "-v", "error", "-i", filepath.Join(folder, "video.mp4"), "-f", "null", "-").CombinedOutput()
	if err != nil || len(bytes.TrimSpace(output)) != 0 {
		t.Fatalf("Photos export does not decode cleanly: %v %s", err, output)
	}
}

func TestSessionsHaveNoAutomaticExpiry(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	var expiryColumns int
	if err := h.db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name='expires_at'").Scan(&expiryColumns); err != nil {
		t.Fatal(err)
	}
	if expiryColumns != 0 {
		t.Fatal("session schema must not include an expiry")
	}
	status, body := request(t, h.server.URL, "GET", "/me", token, nil)
	mustStatus(t, 200, status, body)
	status, body = request(t, h.server.URL, "GET", "/me", secret(), nil)
	mustStatus(t, 401, status, body)
}
