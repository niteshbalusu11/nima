package main

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"sync"
	"testing"
	"time"
)

func nearbyCredentialTest(t *testing.T, h *testAPI, token string) (string, signedMediaRecord) {
	t.Helper()
	s, b := request(t, h.server.URL, "GET", "/devices/credential", token, nil)
	mustStatus(t, 200, s, b)
	var result struct {
		Authority   string            `json:"authority"`
		Certificate signedMediaRecord `json:"certificate"`
	}
	if err := json.Unmarshal(b, &result); err != nil {
		t.Fatal(err)
	}
	return result.Authority, result.Certificate
}
func signedPermissionTest(t *testing.T, authority string, a, b device, ka, kb testDeviceKeys) nearbyPermission {
	t.Helper()
	p := nearbyPermission{Approval: peerApproval{ID: newID(), Sender: a, Recipient: b, CreatedAt: time.Now().Unix()}, Authority: authority}
	data, ok := nearbyPermissionPayload(p)
	if !ok {
		t.Fatal("invalid fixture")
	}
	h := sha256.Sum256(data)
	sa, err := ecdsa.SignASN1(rand.Reader, ka.signing, h[:])
	if err != nil {
		t.Fatal(err)
	}
	sb, err := ecdsa.SignASN1(rand.Reader, kb.signing, h[:])
	if err != nil {
		t.Fatal(err)
	}
	p.SenderSignature = base64.RawURLEncoding.EncodeToString(sa)
	p.RecipientSignature = base64.RawURLEncoding.EncodeToString(sb)
	return p
}
func TestNearbyOfflinePermission(t *testing.T) {
	h := setup(t)
	ta, oa := enrollTest(t, h)
	tb, ob := enrollTest(t, h)
	tc, oc := enrollTest(t, h)
	ka, kb, kc := newTestDeviceKeys(t), newTestDeviceKeys(t), newTestDeviceKeys(t)
	a, b := registerTest(t, h, ta, oa, ka), registerTest(t, h, tb, ob, kb)
	registerTest(t, h, tc, oc, kc)
	authority, cert := nearbyCredentialTest(t, h, ta)
	public, _ := decodeURLBytes(authority, 32)
	raw, _ := base64.RawURLEncoding.DecodeString(cert.Payload)
	signature, _ := decodeURLBytes(cert.Signature, 64)
	if !ed25519.Verify(public, append([]byte(nearbyCredentialDomain), raw...), signature) {
		t.Fatal("invalid credential signature")
	}
	var claims nearbyCredential
	if err := json.Unmarshal(raw, &claims); err != nil || claims.Device != a || claims.ExpiresAt-claims.IssuedAt != int64(nearbyCredentialLifetime.Seconds()) {
		t.Fatal("invalid credential claims", err)
	}
	same, _ := nearbyCredentialTest(t, h, tb)
	if same != authority {
		t.Fatal("authority changed")
	}
	p := signedPermissionTest(t, authority, a, b, ka, kb)
	route := "/peer-approvals/" + p.Approval.ID
	input := map[string]any{"permission": p, "revoked": false}
	s, body := request(t, h.server.URL, "PUT", route, tc, input)
	mustStatus(t, 403, s, body)
	bad := p
	bad.RecipientSignature = bad.SenderSignature
	s, body = request(t, h.server.URL, "PUT", route, tb, map[string]any{"permission": bad})
	mustStatus(t, 400, s, body)
	bad = p
	bad.Approval.Recipient.SigningPublicKey = kc.public.SigningPublicKey
	s, body = request(t, h.server.URL, "PUT", route, tb, map[string]any{"permission": bad})
	mustStatus(t, 400, s, body)
	var wg sync.WaitGroup
	for _, token := range []string{ta, tb} {
		wg.Add(1)
		go func(token string) {
			defer wg.Done()
			s, b := request(t, h.server.URL, "PUT", route, token, input)
			mustStatus(t, 200, s, b)
		}(token)
	}
	wg.Wait()
	var count int
	if h.db.QueryRow("SELECT COUNT(*) FROM peer_approvals WHERE id=?", p.Approval.ID).Scan(&count) != nil || count != 1 {
		t.Fatal("permission duplicated")
	}
	s, body = request(t, h.server.URL, "DELETE", route, tb, nil)
	mustStatus(t, 200, s, body)
	s, body = request(t, h.server.URL, "PUT", route, ta, input)
	mustStatus(t, 410, s, body)
	// A permission revoked while both phones were offline arrives as a tombstone.
	p = signedPermissionTest(t, authority, a, b, ka, kb)
	route = "/peer-approvals/" + p.Approval.ID
	s, body = request(t, h.server.URL, "PUT", route, tb, map[string]any{"permission": p, "revoked": true})
	mustStatus(t, 200, s, body)
	s, body = request(t, h.server.URL, "PUT", route, ta, map[string]any{"permission": p})
	mustStatus(t, 410, s, body)
	p = signedPermissionTest(t, authority, a, b, ka, kb)
	route = "/peer-approvals/" + p.Approval.ID
	execTest(t, h.db, "UPDATE devices SET revoked_at=? WHERE id=?", time.Now().Unix(), b.ID)
	s, body = request(t, h.server.URL, "PUT", route, ta, map[string]any{"permission": p})
	mustStatus(t, 403, s, body)
	s, body = request(t, h.server.URL, "GET", "/devices/credential", tb, nil)
	mustStatus(t, 403, s, body)
}
