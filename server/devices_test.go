package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type testDeviceKeys struct {
	public       deviceKeys
	signing, tls *ecdsa.PrivateKey
}

func newTestDeviceKeys(t *testing.T) testDeviceKeys {
	t.Helper()
	signing, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tls, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s, err := signing.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	b, err := tls.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	return testDeviceKeys{deviceKeys{base64.RawURLEncoding.EncodeToString(s), base64.RawURLEncoding.EncodeToString(b)}, signing, tls}
}
func challengeTest(t *testing.T, h *testAPI, token string, keys testDeviceKeys) registrationChallenge {
	t.Helper()
	s, b := request(t, h.server.URL, "POST", "/devices/challenge", token, keys.public)
	mustStatus(t, 200, s, b)
	var challenge registrationChallenge
	if err := json.Unmarshal(b, &challenge); err != nil {
		t.Fatal(err)
	}
	return challenge
}
func proofTest(t *testing.T, challenge registrationChallenge, token, owner string, keys testDeviceKeys) registrationProof {
	t.Helper()
	h := sha256.Sum256(registrationPayload(challenge, digest(token), owner, keys.public))
	s, err := ecdsa.SignASN1(rand.Reader, keys.signing, h[:])
	if err != nil {
		t.Fatal(err)
	}
	b, err := ecdsa.SignASN1(rand.Reader, keys.tls, h[:])
	if err != nil {
		t.Fatal(err)
	}
	return registrationProof{challenge.Nonce, base64.RawURLEncoding.EncodeToString(s), base64.RawURLEncoding.EncodeToString(b)}
}
func registerTest(t *testing.T, h *testAPI, token, owner string, keys testDeviceKeys) device {
	t.Helper()
	proof := proofTest(t, challengeTest(t, h, token, keys), token, owner, keys)
	s, b := request(t, h.server.URL, "POST", "/devices/register", token, proof)
	mustStatus(t, 201, s, b)
	var d device
	if err := json.Unmarshal(b, &d); err != nil {
		t.Fatal(err)
	}
	return d
}
func sessionTest(t *testing.T, h *testAPI, owner string) string {
	t.Helper()
	token := secret()
	if _, err := h.db.Exec("INSERT INTO sessions(hash,account_id) VALUES(?,?)", digest(token), owner); err != nil {
		t.Fatal(err)
	}
	return token
}
func execTest(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatal(err)
	}
}

func TestDeviceMigrationPreservesLegacySessions(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "legacy.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := migrate(db, migrations[:5]); err != nil {
		t.Fatal(err)
	}
	execTest(t, db, "INSERT INTO accounts(id,role,super_admin,created_at) VALUES('owner','admin',1,1)")
	execTest(t, db, "INSERT INTO sessions(hash,account_id) VALUES('legacy','owner')")
	execTest(t, db, "INSERT INTO captures(id,account_id,kind,created_at) VALUES('existing-photo','owner','photo',1)")
	execTest(t, db, "INSERT INTO face_jobs(capture_id,sequence,processed_at) VALUES('existing-photo',0,2)")
	execTest(t, db, "INSERT INTO face_groups(id,capture_id,embedding,jpeg,first_seen_ms,sightings) VALUES('face','existing-photo','[1]',?,3,4)", []byte("saved-preview"))
	if err := migrate(db, migrations); err != nil {
		t.Fatal(err)
	}
	var deviceID sql.NullString
	var revoked, super int
	var role string
	if err := db.QueryRow("SELECT s.device_id,s.revoked,a.role,a.super_admin FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.hash='legacy'").Scan(&deviceID, &revoked, &role, &super); err != nil {
		t.Fatal(err)
	}
	if deviceID.Valid || revoked != 0 || role != "admin" || super != 1 {
		t.Fatal("migration changed legacy authorization")
	}
	var preview []byte
	var sightings, processed int
	if err := db.QueryRow("SELECT jpeg,sightings,processed_at FROM face_groups g JOIN face_jobs j ON j.capture_id=g.capture_id WHERE g.id='face'").Scan(&preview, &sightings, &processed); err != nil || string(preview) != "saved-preview" || sightings != 4 || processed != 2 {
		t.Fatal("nearby migrations changed existing face gallery", err)
	}
}

func TestDeviceRegistrationProofsAndSessionIsolation(t *testing.T) {
	h := setup(t)
	token, owner := enrollTest(t, h)
	other, otherOwner := enrollTest(t, h)
	sameAccount := sessionTest(t, h, owner)
	keys := newTestDeviceKeys(t)
	s, b := request(t, h.server.URL, "GET", "/devices/current", token, nil)
	mustStatus(t, 409, s, b)
	s, b = request(t, h.server.URL, "PUT", "/captures/11111111-1111-1111-1111-111111111111", token, map[string]string{"kind": "video"})
	mustStatus(t, 200, s, b)
	challenge := challengeTest(t, h, token, keys)
	proof := proofTest(t, challenge, token, owner, keys)
	for _, change := range []string{"signing", "tls", "session", "account", "expiry", "keys"} {
		bad := proof
		switch change {
		case "signing":
			bad.SigningSignature = proof.TLSSignature
		case "tls":
			bad.TLSSignature = proof.SigningSignature
		case "session":
			bad = proofTest(t, challenge, sameAccount, owner, keys)
		case "account":
			bad = proofTest(t, challenge, token, otherOwner, keys)
		case "expiry":
			altered := challenge
			altered.ExpiresAt++
			bad = proofTest(t, altered, token, owner, keys)
		case "keys":
			bad = proofTest(t, challenge, token, owner, newTestDeviceKeys(t))
		}
		s, b = request(t, h.server.URL, "POST", "/devices/register", token, bad)
		mustStatus(t, 403, s, b)
	}
	s, b = request(t, h.server.URL, "POST", "/devices/register", sameAccount, proof)
	mustStatus(t, 410, s, b)
	type result struct {
		status int
		body   []byte
	}
	results := make(chan result, 2)
	var wait sync.WaitGroup
	for range 2 {
		wait.Go(func() {
			s, b := request(t, h.server.URL, "POST", "/devices/register", token, proof)
			results <- result{s, b}
		})
	}
	wait.Wait()
	close(results)
	counts := map[int]int{}
	ids := map[string]bool{}
	for r := range results {
		counts[r.status]++
		var d device
		if err := json.Unmarshal(r.body, &d); err != nil {
			t.Fatal(err)
		}
		ids[d.ID] = true
	}
	if counts[201] != 1 || counts[200] != 1 || len(ids) != 1 || ids[""] {
		t.Fatalf("registration race: %v %v", counts, ids)
	}
	var untouched sql.NullString
	if err := h.db.QueryRow("SELECT device_id FROM sessions WHERE hash=?", digest(sameAccount)).Scan(&untouched); err != nil || untouched.Valid {
		t.Fatal("bound another session", err)
	}
	// Idempotency never bypasses proof validation.
	proof.TLSSignature = proof.SigningSignature
	s, b = request(t, h.server.URL, "POST", "/devices/register", token, proof)
	mustStatus(t, 403, s, b)
	s, b = request(t, h.server.URL, "POST", "/devices/challenge", token, newTestDeviceKeys(t).public)
	mustStatus(t, 409, s, b)
	proof = proofTest(t, challengeTest(t, h, other, keys), other, otherOwner, keys)
	s, b = request(t, h.server.URL, "POST", "/devices/register", other, proof)
	mustStatus(t, 409, s, b)
	// Re-enrollment of this same physical identity may bind a new session for its account.
	proof = proofTest(t, challengeTest(t, h, sameAccount, keys), sameAccount, owner, keys)
	s, b = request(t, h.server.URL, "POST", "/devices/register", sameAccount, proof)
	mustStatus(t, 200, s, b)
	var d device
	if err := json.Unmarshal(b, &d); err != nil || !ids[d.ID] {
		t.Fatal("retry changed device", err)
	}
}

func TestDeviceChallengeValidationExpiryAndRevocation(t *testing.T) {
	h := setup(t)
	token, owner := enrollTest(t, h)
	keys := newTestDeviceKeys(t)
	for _, input := range []deviceKeys{{keys.public.SigningPublicKey, keys.public.SigningPublicKey}, {"invalid", keys.public.TLSPublicKey}, {keys.public.SigningPublicKey + "=", keys.public.TLSPublicKey}, {base64.RawURLEncoding.EncodeToString(make([]byte, 65)), keys.public.TLSPublicKey}} {
		s, b := request(t, h.server.URL, "POST", "/devices/challenge", token, input)
		mustStatus(t, 400, s, b)
	}
	old := proofTest(t, challengeTest(t, h, token, keys), token, owner, keys)
	fresh := proofTest(t, challengeTest(t, h, token, keys), token, owner, keys)
	s, b := request(t, h.server.URL, "POST", "/devices/register", token, old)
	mustStatus(t, 410, s, b)
	execTest(t, h.db, "UPDATE device_challenges SET expires_at=0")
	s, b = request(t, h.server.URL, "POST", "/devices/register", token, fresh)
	mustStatus(t, 410, s, b)
	challenge := challengeTest(t, h, token, keys)
	fresh = proofTest(t, challenge, token, owner, keys)
	execTest(t, h.db, "UPDATE sessions SET revoked=1 WHERE hash=?", digest(token))
	s, b = request(t, h.server.URL, "POST", "/devices/register", token, fresh)
	mustStatus(t, 401, s, b)
	execTest(t, h.db, "UPDATE sessions SET revoked=0 WHERE hash=?", digest(token))
	execTest(t, h.db, "UPDATE accounts SET active=0 WHERE id=?", owner)
	s, b = request(t, h.server.URL, "POST", "/devices/register", token, fresh)
	mustStatus(t, 401, s, b)
	execTest(t, h.db, "UPDATE accounts SET active=1 WHERE id=?", owner)
	d := registerTest(t, h, token, owner, keys)
	other, otherOwner := enrollTest(t, h)
	s, b = request(t, h.server.URL, "DELETE", "/devices/"+d.ID, other, nil)
	mustStatus(t, 404, s, b)
	s, b = request(t, h.server.URL, "DELETE", "/devices/"+d.ID, token, nil)
	mustStatus(t, 200, s, b)
	s, b = request(t, h.server.URL, "GET", "/devices/current", token, nil)
	mustStatus(t, 403, s, b)
	s, b = request(t, h.server.URL, "GET", "/me", token, nil)
	mustStatus(t, 200, s, b)
	// A new token cannot reactivate revoked keys, even with valid signatures.
	newSession := sessionTest(t, h, owner)
	proof := proofTest(t, challengeTest(t, h, newSession, keys), newSession, owner, keys)
	s, b = request(t, h.server.URL, "POST", "/devices/register", newSession, proof)
	mustStatus(t, 409, s, b)
	// Reusing a key in the other role is also forbidden.
	swapped := testDeviceKeys{deviceKeys{keys.public.TLSPublicKey, keys.public.SigningPublicKey}, keys.tls, keys.signing}
	proof = proofTest(t, challengeTest(t, h, other, swapped), other, otherOwner, swapped)
	s, b = request(t, h.server.URL, "POST", "/devices/register", other, proof)
	mustStatus(t, 409, s, b)
}

func TestDeviceChallengeRateLimit(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	keys := newTestDeviceKeys(t)
	for i := 0; i < 11; i++ {
		s, b := request(t, h.server.URL, "POST", "/devices/challenge", token, keys.public)
		want := 200
		if i == 10 {
			want = 429
		}
		mustStatus(t, want, s, b)
	}
	var count int
	if err := h.db.QueryRow("SELECT COUNT(*) FROM device_challenges").Scan(&count); err != nil || count != 1 {
		t.Fatal("unbounded challenges", count, err)
	}
}

func TestSwiftDeviceRegistration(t *testing.T) {
	probe := os.Getenv("IDENTITY_PROBE")
	if probe == "" {
		t.Skip("run tools/verify-identities.sh for the actual Swift client")
	}
	h := setup(t)
	token, owner := enrollTest(t, h)
	config, err := json.Marshal(map[string]any{"base_url": h.server.URL, "session": map[string]string{"token": token, "account_id": owner, "role": "member"}})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "session.json")
	if err = os.WriteFile(path, config, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, probe, path).CombinedOutput()
	if err != nil {
		t.Fatalf("Swift registration failed: %v %s", err, out)
	}
	if !bytes.Contains(out, []byte("PASS: Swift device registration")) {
		t.Fatalf("missing Swift result: %s", out)
	}
	var count int
	if err = h.db.QueryRow("SELECT COUNT(*) FROM devices WHERE account_id=?", owner).Scan(&count); err != nil || count != 1 {
		t.Fatal("Swift retry created duplicate devices", count, err)
	}
}
