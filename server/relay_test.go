package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"math"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func (s *memoryStore) uploadRelay(ctx context.Context, o object, lifetime time.Duration) (signedUpload, error) {
	return s.upload(ctx, o)
}

type relayFixture struct {
	h                       *testAPI
	a, b, c                 string
	owner, recipient, third device
	keys                    testDeviceKeys
	approval, approvalC     peerApproval
	id                      string
	descriptor              signedMediaRecord
	grant, grantC           signedMediaRecord
}

func setupRelay(t *testing.T) relayFixture {
	t.Helper()
	h := setup(t)
	server := httptest.NewServer((&api{db: h.db, store: h.store, relayEnabled: true}).handler())
	t.Cleanup(server.Close)
	h.server = server
	a, accountA := enrollTest(t, h)
	b, accountB := enrollTest(t, h)
	c, accountC := enrollTest(t, h)
	keys := newTestDeviceKeys(t)
	owner := registerTest(t, h, a, accountA, keys)
	recipient := registerTest(t, h, b, accountB, newTestDeviceKeys(t))
	third := registerTest(t, h, c, accountC, newTestDeviceKeys(t))
	approve := func(token string, d device) peerApproval {
		invitation := peerInvitationTest(t, h, a, d)
		status, body := request(t, h.server.URL, "POST", "/peer-invitations/accept", token, map[string]string{"token": invitation.Token})
		mustStatus(t, 201, status, body)
		var approval peerApproval
		if err := json.Unmarshal(body, &approval); err != nil {
			t.Fatal(err)
		}
		return approval
	}
	f := relayFixture{h: h, a: a, b: b, c: c, owner: owner, recipient: recipient, third: third, keys: keys,
		approval: approve(b, recipient), approvalC: approve(c, third), id: "00112233-4455-6677-8899-aabbccddeeff"}
	key, _ := base64.RawURLEncoding.DecodeString(owner.SigningPublicKey)
	hash := sha256.Sum256(key)
	p := mediaTestPayload("capture", mediaTestID(f.id), mediaTestID(accountA), mediaTestID(owner.ID), hash[:], []byte{1}, mediaTestU64(uint64(time.Now().Unix())))
	f.descriptor = f.sign(t, p)
	f.grant = f.permission(t, f.approval, newID(), maxSharedCapture, time.Now().Unix()+mediaGrantLifetime)
	f.grantC = f.permission(t, f.approvalC, newID(), maxSharedCapture, time.Now().Unix()+mediaGrantLifetime)
	return f
}
func mediaTestID(s string) []byte  { b, _ := hex.DecodeString(strings.ReplaceAll(s, "-", "")); return b }
func mediaTestU64(n uint64) []byte { b := make([]byte, 8); binary.BigEndian.PutUint64(b, n); return b }
func mediaTestU32(n int) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, uint32(n))
	return b
}
func mediaTestPayload(kind string, fields ...[]byte) []byte {
	b := []byte("uploadvideo.media." + kind + ".v1\x00")
	for _, field := range fields {
		b = append(b, field...)
	}
	return b
}
func (f relayFixture) sign(t *testing.T, payload []byte) signedMediaRecord {
	t.Helper()
	hash := sha256.Sum256(payload)
	signature, err := ecdsa.SignASN1(rand.Reader, f.keys.signing, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	return signedMediaRecord{base64.RawURLEncoding.EncodeToString(payload), base64.RawURLEncoding.EncodeToString(signature)}
}
func (f relayFixture) captureHash() []byte {
	b, _ := base64.RawURLEncoding.DecodeString(f.descriptor.Payload)
	h := sha256.Sum256(b)
	return h[:]
}
func (f relayFixture) permission(t *testing.T, approval peerApproval, id string, limit, expires int64) signedMediaRecord {
	return f.sign(t, mediaTestPayload("grant", mediaTestID(id), f.captureHash(), mediaTestID(f.owner.ID), mediaTestID(approval.Recipient.AccountID),
		mediaTestID(approval.Recipient.ID), mediaTestID(approval.ID), []byte{1, 1}, mediaTestU64(uint64(expires-mediaGrantLifetime)), mediaTestU64(uint64(expires)), mediaTestU64(uint64(limit))))
}
func (f relayFixture) manifest(t *testing.T, data []byte, seq int) (signedMediaRecord, object) {
	kind, raw := "media", byte(2)
	if seq == 0 {
		kind, raw = "init", 1
	}
	capture, err := verifyMediaCapture(f.descriptor, f.owner)
	if err != nil {
		t.Fatal(err)
	}
	if capture.Descriptor.Kind == "photo" {
		kind, raw = "photo", 3
	}
	o := makeObject(data, kind, seq)
	o.Duration, o.StartTime = 0, 0
	o.CaptureID = f.id
	sha, _ := hex.DecodeString(o.SHA256)
	md5, _ := base64.StdEncoding.DecodeString(o.MD5)
	return f.sign(t, mediaTestPayload("object", f.captureHash(), mediaTestU32(seq), []byte{raw}, mediaTestU64(uint64(o.Size)), sha, md5,
		mediaTestU64(math.Float64bits(o.Duration)), mediaTestU64(math.Float64bits(o.StartTime)))), o
}
func (f relayFixture) completion(t *testing.T, count int, size int64, interrupted bool) signedMediaRecord {
	ending := byte(1)
	if interrupted {
		ending = 2
	}
	return f.sign(t, mediaTestPayload("completion", f.captureHash(), []byte{ending}, mediaTestU32(count-1), mediaTestU32(count), mediaTestU64(uint64(size))))
}
func (f relayFixture) redeem(t *testing.T, token string, approval peerApproval, grant signedMediaRecord, expected int) string {
	t.Helper()
	status, body := request(t, f.h.server.URL, "POST", "/relay-grants/redeem", token, map[string]any{"approval_id": approval.ID, "descriptor": f.descriptor, "grant": grant})
	mustStatus(t, expected, status, body)
	var result struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(body, &result)
	return result.ID
}
func (f relayFixture) call(t *testing.T, token, grant, action string, input any, expected int) []byte {
	t.Helper()
	status, body := request(t, f.h.server.URL, "POST", "/relay-grants/"+grant+"/"+action, token, input)
	mustStatus(t, expected, status, body)
	return body
}
func (f relayFixture) store(t *testing.T, sequence int, data []byte) {
	t.Helper()
	var key string
	if err := f.h.db.QueryRow("SELECT object_key FROM objects WHERE capture_id=? AND sequence=?", f.id, sequence).Scan(&key); err != nil {
		t.Fatal(err)
	}
	f.h.store.Lock()
	f.h.store.data[key] = data
	f.h.store.Unlock()
}

func TestRelayConcurrentOwnerRecipientsAndRecovery(t *testing.T) {
	f := setupRelay(t)
	var bID, cID string
	var group sync.WaitGroup
	group.Go(func() { bID = f.redeem(t, f.b, f.approval, f.grant, 200) })
	group.Go(func() { cID = f.redeem(t, f.c, f.approvalC, f.grantC, 200) })
	group.Wait()
	var owner string
	if err := f.h.db.QueryRow("SELECT account_id FROM captures WHERE id=?", f.id).Scan(&owner); err != nil || owner != f.owner.AccountID {
		t.Fatal("relay changed recorder", err)
	}
	// A second valid signature must preserve the first grant envelope.
	payload, _ := base64.RawURLEncoding.DecodeString(f.grant.Payload)
	f.redeem(t, f.b, f.approval, f.sign(t, payload), 200)
	var signature string
	if err := f.h.db.QueryRow("SELECT signature FROM relay_grants WHERE id=?", bID).Scan(&signature); err != nil || signature != f.grant.Signature {
		t.Fatal("retry replaced original grant", err)
	}
	f.redeem(t, f.b, f.approval, f.permission(t, f.approval, bID, 1000, time.Now().Unix()+mediaGrantLifetime), 409)
	changedCapture := f
	changed, _ := base64.RawURLEncoding.DecodeString(f.descriptor.Payload)
	changed[len(changed)-1] ^= 1
	changedCapture.descriptor = f.sign(t, changed)
	changedCapture.redeem(t, f.b, f.approval, changedCapture.permission(t, f.approval, newID(), maxSharedCapture, time.Now().Unix()+mediaGrantLifetime), 409)
	status, legacyEnd := request(t, f.h.server.URL, "POST", "/captures/"+f.id+"/finish", f.a, nil)
	mustStatus(t, 409, status, legacyEnd)
	status, unknown := request(t, f.h.server.URL, "GET", "/captures/"+f.id, f.a, nil)
	mustStatus(t, 200, status, unknown)
	var unknownEnding struct {
		Ending   string `json:"recording_ending"`
		Complete bool   `json:"cloud_complete"`
		Finished bool
	}
	if err := json.Unmarshal(unknown, &unknownEnding); err != nil || unknownEnding.Ending != "unknown" || unknownEnding.Complete || unknownEnding.Finished {
		t.Fatal("legacy finish fabricated shared completion", err)
	}
	data := [][]byte{[]byte("init"), []byte("fragment one"), []byte("fragment two")}
	manifest, obj := f.manifest(t, data[0], 0)
	for _, attempt := range []struct{ token, id string }{{f.b, bID}, {f.c, cID}, {f.b, bID}} {
		group.Go(func() {
			f.call(t, attempt.token, attempt.id, "objects/reserve", map[string]any{"manifest": manifest}, 200)
		})
	}
	group.Go(func() {
		s, b := request(t, f.h.server.URL, "POST", "/captures/"+f.id+"/objects/reserve", f.a, obj)
		mustStatus(t, 200, s, b)
	})
	group.Wait()
	var count int
	var size int64
	if err := f.h.db.QueryRow("SELECT COUNT(*),SUM(size) FROM objects WHERE capture_id=?", f.id).Scan(&count, &size); err != nil || count != 1 || size != int64(len(data[0])) {
		t.Fatal("duplicate account quota charge", count, size, err)
	}
	if err := f.h.db.QueryRow("SELECT COUNT(*) FROM relay_grant_objects").Scan(&count); err != nil || count != 2 {
		t.Fatal("duplicate grant charge", count, err)
	}
	conflicting, _ := f.manifest(t, []byte("changed bytes"), 0)
	f.call(t, f.b, bID, "objects/reserve", map[string]any{"manifest": conflicting}, 409)
	manifestBytes, _ := base64.RawURLEncoding.DecodeString(manifest.Payload)
	f.call(t, f.b, bID, "objects/reserve", map[string]any{"manifest": f.sign(t, manifestBytes)}, 200)
	if err := f.h.db.QueryRow("SELECT signature FROM shared_object_records WHERE capture_id=? AND sequence=0", f.id).Scan(&signature); err != nil || signature != manifest.Signature {
		t.Fatal("retry replaced signed object proof", err)
	}
	f.store(t, 0, data[0])
	for _, attempt := range []struct{ token, id string }{{f.b, bID}, {f.c, cID}} {
		group.Go(func() { f.call(t, attempt.token, attempt.id, "objects/ack", map[string]int{"sequence": 0}, 200) })
	}
	group.Wait()
	body := f.call(t, f.b, bID, "objects/reserve", map[string]any{"manifest": manifest}, 200)
	var reservation struct {
		Acknowledged bool
		URL          string
	}
	_ = json.Unmarshal(body, &reservation)
	if !reservation.Acknowledged || reservation.URL != "" {
		t.Fatal("verified duplicate received another upload URL")
	}
	manifest1, _ := f.manifest(t, data[1], 1)
	f.call(t, f.b, bID, "objects/reserve", map[string]any{"manifest": manifest1}, 200)
	f.store(t, 1, data[1]) // Lost PUT/ack response.
	completion := f.completion(t, 3, int64(len(data[0])+len(data[1])+len(data[2])), false)
	f.call(t, f.b, bID, "completion", map[string]any{"completion": completion}, 200)
	assertStatus := func(complete bool) {
		s, b := request(t, f.h.server.URL, "GET", "/captures/"+f.id, f.a, nil)
		mustStatus(t, 200, s, b)
		var result struct {
			CloudComplete   bool   `json:"cloud_complete"`
			RecordingEnding string `json:"recording_ending"`
			Finished        bool
		}
		if err := json.Unmarshal(b, &result); err != nil {
			t.Fatal(err)
		}
		if result.CloudComplete != complete || result.Finished != complete || result.RecordingEnding != "stopped" {
			t.Fatal("false capture completeness", result)
		}
	}
	assertStatus(false)
	// Restart the API/database after the unacknowledged PUT and before C contributes.
	var file string
	var seq int
	var name string
	if err := f.h.db.QueryRow("PRAGMA database_list").Scan(&seq, &name, &file); err != nil {
		t.Fatal(err)
	}
	f.h.server.Close()
	f.h.db.Close()
	db, err := openDB(file)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	f.h.db = db
	server := httptest.NewServer((&api{db: db, store: f.h.store, relayEnabled: true}).handler())
	t.Cleanup(server.Close)
	f.h.server = server
	f.call(t, f.b, bID, "objects/ack", map[string]int{"sequence": 1}, 200)
	manifest2, _ := f.manifest(t, data[2], 2)
	f.call(t, f.c, cID, "objects/reserve", map[string]any{"manifest": manifest2}, 200)
	f.store(t, 2, data[2])
	f.call(t, f.c, cID, "objects/ack", map[string]int{"sequence": 2}, 200)
	assertStatus(true)
	bad, _ := f.manifest(t, []byte("unexpected"), 3)
	f.call(t, f.b, bID, "objects/reserve", map[string]any{"manifest": bad}, 409)
	_, ownerBad := f.manifest(t, []byte("unexpected"), 3)
	s, b := request(t, f.h.server.URL, "POST", "/captures/"+f.id+"/objects/reserve", f.a, ownerBad)
	mustStatus(t, 409, s, b)
	s, b = request(t, f.h.server.URL, "GET", "/captures/"+f.id, f.b, nil)
	mustStatus(t, 404, s, b)
}

func TestRelayAuthorizationExpiryQuotaAndDeletion(t *testing.T) {
	f := setupRelay(t)
	f.redeem(t, f.c, f.approval, f.grant, 403)
	legacy := sessionTest(t, f.h, f.recipient.AccountID)
	f.redeem(t, legacy, f.approval, f.grant, 409)
	other := sessionTest(t, f.h, f.recipient.AccountID)
	registerTest(t, f.h, other, f.recipient.AccountID, newTestDeviceKeys(t))
	f.redeem(t, other, f.approval, f.grant, 403)
	expired := f.permission(t, f.approval, newID(), 100, time.Now().Unix()-1)
	f.redeem(t, f.b, f.approval, expired, 403)
	invalid := f.grant
	invalid.Signature = f.descriptor.Signature
	f.redeem(t, f.b, f.approval, invalid, 400)
	limited := f.permission(t, f.approval, newID(), 4, time.Now().Unix()+mediaGrantLifetime)
	id := f.redeem(t, f.b, f.approval, limited, 200)
	manifest, _ := f.manifest(t, []byte("init"), 0)
	f.call(t, f.b, id, "objects/reserve", map[string]any{"manifest": manifest}, 200)
	f.call(t, f.b, id, "objects/ack", map[string]int{"sequence": 0}, 409)
	fragment, _ := f.manifest(t, []byte("fragment"), 1)
	body := f.call(t, f.b, id, "objects/reserve", map[string]any{"manifest": fragment}, 413)
	var result map[string]string
	_ = json.Unmarshal(body, &result)
	if result["code"] != "grant_quota" {
		t.Fatal("missing quota code")
	}
	var count int
	_ = f.h.db.QueryRow("SELECT COUNT(*) FROM objects").Scan(&count)
	if count != 1 {
		t.Fatal("quota rejection allocated storage")
	}
	f.call(t, f.c, id, "objects/reserve", map[string]any{"manifest": manifest}, 403)
	bad := fragment
	bad.Signature = manifest.Signature
	f.call(t, f.b, id, "objects/reserve", map[string]any{"manifest": bad}, 400)
	shortExpiry := time.Now().Unix() + 2
	shortID := f.redeem(t, f.b, f.approval, f.permission(t, f.approval, newID(), 100, shortExpiry), 200)
	time.Sleep(time.Until(time.Unix(shortExpiry, 0)))
	f.call(t, f.b, shortID, "objects/reserve", map[string]any{"manifest": manifest}, 403)
	f.call(t, f.b, shortID, "completion", map[string]any{"completion": f.completion(t, 1, 4, false)}, 403)
	s, b := request(t, f.h.server.URL, "DELETE", "/captures/"+f.id, f.a, nil)
	mustStatus(t, 202, s, b)
	f.redeem(t, f.b, f.approval, limited, 410)
	f.call(t, f.b, id, "objects/reserve", map[string]any{"manifest": manifest}, 410)
	f.call(t, f.b, id, "objects/ack", map[string]int{"sequence": 0}, 410)
	f.call(t, f.b, id, "completion", map[string]any{"completion": f.completion(t, 1, 4, false)}, 410)
	if err := (&api{db: f.h.db, store: f.h.store}).cleanDeleted(context.Background(), time.Now().Add(deletionGrace+time.Second)); err != nil {
		t.Fatal(err)
	}
	f.redeem(t, f.b, f.approval, limited, 410)
}

func TestRelayMetadataOrderingAndCompletionProof(t *testing.T) {
	for _, relayFirst := range []bool{false, true} {
		for _, location := range []bool{false, true} {
			t.Run(strings.Join([]string{map[bool]string{false: "owner", true: "relay"}[relayFirst], map[bool]string{false: "private", true: "location"}[location]}, "-"), func(t *testing.T) {
				f := setupRelay(t)
				input := map[string]any{"kind": "video", "descriptor": f.descriptor}
				if location {
					input["location"] = map[string]any{"latitude": 1.25, "longitude": 2.5, "horizontal_accuracy_m": 3, "timestamp": time.Now().Unix()}
				}
				ownerCreate := func() {
					s, b := request(t, f.h.server.URL, "PUT", "/captures/"+f.id, f.a, input)
					mustStatus(t, 200, s, b)
				}
				var id string
				if relayFirst {
					id = f.redeem(t, f.b, f.approval, f.grant, 200)
					ownerCreate()
				} else {
					ownerCreate()
					id = f.redeem(t, f.b, f.approval, f.grant, 200)
				}
				ownerCreate()
				var pending bool
				if err := f.h.db.QueryRow("SELECT owner_metadata_pending FROM captures WHERE id=?", f.id).Scan(&pending); err != nil || pending {
					t.Fatal("metadata not finalized", err)
				}
				input["location"] = map[string]any{"latitude": 9.0, "longitude": 2.5, "horizontal_accuracy_m": 3, "timestamp": time.Now().Unix()}
				s, b := request(t, f.h.server.URL, "PUT", "/captures/"+f.id, f.a, input)
				mustStatus(t, 409, s, b)
				bad := f.completion(t, 1, 4, false)
				bad.Signature = f.grant.Signature
				f.call(t, f.b, id, "completion", map[string]any{"completion": bad}, 400)
				good := f.completion(t, 1, 4, true)
				f.call(t, f.b, id, "completion", map[string]any{"completion": good}, 200)
				f.call(t, f.b, id, "completion", map[string]any{"completion": f.completion(t, 1, 4, false)}, 409)
				s, b = request(t, f.h.server.URL, "POST", "/captures/"+f.id+"/completion", f.a, map[string]any{"completion": good})
				mustStatus(t, 200, s, b)
			})
		}
	}
	f := setupRelay(t)
	s, b := request(t, f.h.server.URL, "DELETE", "/captures/"+f.id, f.a, nil)
	mustStatus(t, 202, s, b)
	f.redeem(t, f.b, f.approval, f.grant, 410)
}

type relayVerificationBarrier struct {
	*memoryStore
	started, resume chan struct{}
}

func (s *relayVerificationBarrier) verify(ctx context.Context, o object) (bool, error) {
	close(s.started)
	select {
	case <-s.resume:
		return true, nil
	case <-ctx.Done():
		return false, ctx.Err()
	}
}

func TestRelayRechecksRevocationAndDeletionAfterStorage(t *testing.T) {
	for _, mutation := range []string{"approval", "recipient_device", "recorder_device", "session", "recorder_account", "delete"} {
		t.Run(mutation, func(t *testing.T) {
			f := setupRelay(t)
			id := f.redeem(t, f.b, f.approval, f.grant, 200)
			manifest, _ := f.manifest(t, []byte("init"), 0)
			f.call(t, f.b, id, "objects/reserve", map[string]any{"manifest": manifest}, 200)
			barrier := &relayVerificationBarrier{f.h.store, make(chan struct{}), make(chan struct{})}
			resume := sync.OnceFunc(func() { close(barrier.resume) })
			defer resume()
			server := httptest.NewServer((&api{db: f.h.db, store: barrier, relayEnabled: true}).handler())
			t.Cleanup(server.Close)
			type response struct {
				status int
				body   []byte
			}
			result := make(chan response, 1)
			go func() {
				s, b := request(t, server.URL, "POST", "/relay-grants/"+id+"/objects/ack", f.b, map[string]int{"sequence": 0})
				result <- response{s, b}
			}()
			select {
			case <-barrier.started:
			case <-time.After(3 * time.Second):
				resume()
				t.Fatal("storage verification did not start")
			}
			expected := 403
			switch mutation {
			case "approval":
				s, b := request(t, f.h.server.URL, "DELETE", "/peer-approvals/"+f.approval.ID, f.b, nil)
				mustStatus(t, 200, s, b)
			case "recipient_device", "recorder_device":
				token, device := f.b, f.recipient
				if mutation == "recorder_device" {
					token, device = f.a, f.owner
				}
				s, b := request(t, f.h.server.URL, "DELETE", "/devices/"+device.ID, token, nil)
				mustStatus(t, 200, s, b)
			case "session":
				execTest(t, f.h.db, "UPDATE sessions SET revoked=1 WHERE hash=?", digest(f.b))
				expected = 401
			case "recorder_account":
				execTest(t, f.h.db, "UPDATE accounts SET active=0 WHERE id=?", f.owner.AccountID)
			case "delete":
				s, b := request(t, f.h.server.URL, "DELETE", "/captures/"+f.id, f.a, nil)
				mustStatus(t, 202, s, b)
				expected = 410
			}
			resume()
			select {
			case result := <-result:
				mustStatus(t, expected, result.status, result.body)
			case <-time.After(3 * time.Second):
				t.Fatal("acknowledgement stalled")
			}
			var acknowledged bool
			if err := f.h.db.QueryRow("SELECT acknowledged FROM objects WHERE capture_id=? AND sequence=0", f.id).Scan(&acknowledged); err != nil || acknowledged {
				t.Fatal("revoked/deleted upload acknowledged", err)
			}
		})
	}
}

func TestRelayPhotoQuotaIsolationAndDisabledAdmission(t *testing.T) {
	f := setupRelay(t)
	payload, _ := base64.RawURLEncoding.DecodeString(f.descriptor.Payload)
	payload[len(payload)-9] = 2
	f.descriptor = f.sign(t, payload)
	data := []byte("photo bytes")
	f.grant = f.permission(t, f.approval, newID(), int64(len(data)), time.Now().Unix()+mediaGrantLifetime)
	id := f.redeem(t, f.b, f.approval, f.grant, 200)
	manifest, _ := f.manifest(t, data, 0)
	// A full recipient account must not consume A's quota or reject A's upload.
	execTest(t, f.h.db, "INSERT INTO captures(id,account_id,kind,created_at) VALUES('recipient-full',?,'video',1)", f.recipient.AccountID)
	execTest(t, f.h.db, `INSERT INTO objects(capture_id,sequence,kind,object_key,sha256,md5,size,duration,start_time) VALUES('recipient-full',0,'init','recipient-key','sha','md5',?,0,0)`, accountQuota)
	f.call(t, f.b, id, "objects/reserve", map[string]any{"manifest": manifest}, 200)
	f.store(t, 0, data)
	f.call(t, f.b, id, "objects/ack", map[string]int{"sequence": 0}, 200)
	f.call(t, f.b, id, "completion", map[string]any{"completion": f.completion(t, 1, int64(len(data)), false)}, 200)
	s, b := request(t, f.h.server.URL, "GET", "/captures/"+f.id, f.a, nil)
	mustStatus(t, 200, s, b)
	var result struct {
		CloudComplete bool `json:"cloud_complete"`
		Kind          string
	}
	if err := json.Unmarshal(b, &result); err != nil || !result.CloudComplete || result.Kind != "photo" {
		t.Fatal("photo not recovered", err)
	}
	server := httptest.NewServer((&api{db: f.h.db, store: f.h.store}).handler())
	defer server.Close()
	s, b = request(t, server.URL, "POST", "/relay-grants/"+id+"/objects/reserve", f.b, map[string]any{"manifest": manifest})
	mustStatus(t, 503, s, b)
	var failure map[string]string
	_ = json.Unmarshal(b, &failure)
	if failure["code"] != "relay_disabled" {
		t.Fatal("missing admission switch")
	}
}

func TestRelayRecorderQuotaAndMigration(t *testing.T) {
	f := setupRelay(t)
	id := f.redeem(t, f.b, f.approval, f.grant, 200)
	execTest(t, f.h.db, "INSERT INTO captures(id,account_id,kind,created_at) VALUES('owner-full',?,'video',1)", f.owner.AccountID)
	execTest(t, f.h.db, `INSERT INTO objects(capture_id,sequence,kind,object_key,sha256,md5,size,duration,start_time) VALUES('owner-full',0,'init','owner-key','sha','md5',?,0,0)`, accountQuota)
	manifest, _ := f.manifest(t, []byte("init"), 0)
	body := f.call(t, f.b, id, "objects/reserve", map[string]any{"manifest": manifest}, 413)
	var result map[string]string
	_ = json.Unmarshal(body, &result)
	if result["code"] != "account_quota" {
		t.Fatal("wrong quota account")
	}
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "v5.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = migrate(db, migrations[:5]); err != nil {
		t.Fatal(err)
	}
	execTest(t, db, "INSERT INTO accounts(id,created_at) VALUES('owner',1)")
	execTest(t, db, "INSERT INTO captures(id,account_id,kind,created_at,deleted_at,latitude) VALUES('deleted','owner','video',1,2,3)")
	execTest(t, db, `INSERT INTO objects(capture_id,sequence,kind,object_key,sha256,md5,size,duration,start_time,acknowledged) VALUES('deleted',0,'init','kept-key','sha','md5',4,0,0,1)`)
	if err = migrate(db, migrations); err != nil {
		t.Fatal(err)
	}
	var deleted, size int64
	var pending, ack bool
	if err = db.QueryRow("SELECT c.deleted_at,c.owner_metadata_pending,o.size,o.acknowledged FROM captures c JOIN objects o ON o.capture_id=c.id WHERE c.id='deleted'").Scan(&deleted, &pending, &size, &ack); err != nil || deleted != 2 || pending || size != 4 || !ack {
		t.Fatal("migration changed legacy media", err)
	}
}

func TestRelayRealStorage(t *testing.T) {
	if os.Getenv("TEST_S3") != "1" {
		t.Skip("run tools/verify-local.sh against local RustFS")
	}
	f := setupRelay(t)
	store, err := newS3()
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer((&api{db: f.h.db, store: store, relayEnabled: true}).handler())
	t.Cleanup(server.Close)
	f.h.server = server
	bID := f.redeem(t, f.b, f.approval, f.grant, 200)
	cID := f.redeem(t, f.c, f.approvalC, f.grantC, 200)
	data := []byte(strings.Repeat("signed fragment bytes", 8192))
	manifest, obj := f.manifest(t, data, 0)
	var uploads []signedUpload
	for _, attempt := range []struct{ token, id string }{{f.b, bID}, {f.c, cID}} {
		body := f.call(t, attempt.token, attempt.id, "objects/reserve", map[string]any{"manifest": manifest}, 200)
		var upload signedUpload
		if err = json.Unmarshal(body, &upload); err != nil {
			t.Fatal(err)
		}
		uploads = append(uploads, upload)
	}
	s, body := request(t, server.URL, "POST", "/captures/"+f.id+"/objects/reserve", f.a, obj)
	mustStatus(t, 200, s, body)
	var upload signedUpload
	if err = json.Unmarshal(body, &upload); err != nil {
		t.Fatal(err)
	}
	uploads = append(uploads, upload)
	var key string
	if err = f.h.db.QueryRow("SELECT object_key FROM objects WHERE capture_id=? AND sequence=0", f.id).Scan(&key); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := store.remove(ctx, key); err != nil {
			t.Error("relay fixture cleanup failed")
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	changed := append([]byte(nil), data...)
	changed[0] ^= 1
	status, code, err := relayProbePUT(ctx, uploads[0], changed)
	if err != nil || status != 400 || code != "BadDigest" {
		t.Fatalf("corrupt relay occupied canonical key: status=%d code=%s error=%v", status, code, err)
	}
	statuses := make(chan int, 3)
	var group sync.WaitGroup
	for _, upload := range uploads {
		group.Go(func() {
			status, _, err := relayProbePUT(ctx, upload, data)
			if err != nil {
				t.Error(err)
			}
			statuses <- status
		})
	}
	group.Wait()
	close(statuses)
	winners := 0
	for status := range statuses {
		if status == 200 {
			winners++
		} else if status != 412 {
			t.Fatalf("unexpected concurrent upload status %d", status)
		}
	}
	if winners != 1 {
		t.Fatalf("expected one upload winner, got %d", winners)
	}
	f.call(t, f.b, bID, "objects/ack", map[string]int{"sequence": 0}, 200)
	f.call(t, f.c, cID, "objects/ack", map[string]int{"sequence": 0}, 200)
	f.call(t, f.b, bID, "completion", map[string]any{"completion": f.completion(t, 1, int64(len(data)), false)}, 200)
	body = f.call(t, f.c, cID, "objects/reserve", map[string]any{"manifest": manifest}, 200)
	var result struct {
		Acknowledged bool
		URL          string
	}
	if err = json.Unmarshal(body, &result); err != nil || !result.Acknowledged || result.URL != "" {
		t.Fatal("verified storage did not deduplicate", err)
	}
}
