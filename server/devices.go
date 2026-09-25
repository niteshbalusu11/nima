package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"
)

type device struct {
	ID               string `json:"id"`
	AccountID        string `json:"account_id"`
	SigningPublicKey string `json:"signing_public_key"`
	TLSPublicKey     string `json:"tls_public_key"`
}
type deviceKeys struct {
	SigningPublicKey string `json:"signing_public_key"`
	TLSPublicKey     string `json:"tls_public_key"`
}
type registrationChallenge struct {
	Nonce     string `json:"nonce"`
	ExpiresAt int64  `json:"expires_at"`
}
type registrationProof struct {
	Nonce            string `json:"nonce"`
	SigningSignature string `json:"signing_signature"`
	TLSSignature     string `json:"tls_signature"`
}

func sessionHash(r *http.Request) string {
	return digest(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
}

// Recheck session/account/device state inside the same transaction as every change.
// Legacy sessions remain valid for owner routes; only peer routes require a device.
func (a *api) deviceTransaction(w http.ResponseWriter, r *http.Request, required bool) (*sql.Tx, device, bool) {
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		failure(w, 503, "Unavailable")
		return nil, device{}, false
	}
	var binding sql.NullString
	err = tx.QueryRowContext(r.Context(), `SELECT s.device_id FROM sessions s JOIN accounts a ON a.id=s.account_id
 WHERE s.hash=? AND s.account_id=? AND s.revoked=0 AND a.active=1`, sessionHash(r), account(r)).Scan(&binding)
	d := device{AccountID: account(r)}
	status, message := 503, "Unavailable"
	if errors.Is(err, sql.ErrNoRows) {
		status, message = 401, "Scan a new invite"
	}
	if err == nil && binding.Valid {
		err = tx.QueryRowContext(r.Context(), `SELECT id,signing_public_key,tls_public_key FROM devices
 WHERE id=? AND account_id=? AND revoked_at IS NULL`, binding.String, account(r)).Scan(&d.ID, &d.SigningPublicKey, &d.TLSPublicKey)
		if errors.Is(err, sql.ErrNoRows) {
			status, message = 403, "Device sharing access revoked"
		}
	}
	if err != nil {
		tx.Rollback()
		failure(w, status, message)
		return nil, device{}, false
	}
	if required && d.ID == "" {
		tx.Rollback()
		failure(w, 409, "Set up this device first")
		return nil, device{}, false
	}
	return tx, d, true
}

func decodeURLBytes(value string, size int) ([]byte, bool) {
	b, err := base64.RawURLEncoding.Strict().DecodeString(value)
	return b, err == nil && len(b) == size && base64.RawURLEncoding.EncodeToString(b) == value
}
func registrationKey(value string) (*ecdsa.PublicKey, bool) {
	b, ok := decodeURLBytes(value, 65)
	if !ok {
		return nil, false
	}
	k, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), b)
	return k, err == nil
}

// Exact bytes signed by both keys, independently of JSON serialization.
func registrationPayload(challenge registrationChallenge, session, owner string, keys deviceKeys) []byte {
	data := []byte("uploadvideo.device-registration.v1\x00")
	nonce, _ := base64.RawURLEncoding.DecodeString(challenge.Nonce)
	hash, _ := hex.DecodeString(session)
	signing, _ := base64.RawURLEncoding.DecodeString(keys.SigningPublicKey)
	tls, _ := base64.RawURLEncoding.DecodeString(keys.TLSPublicKey)
	data = append(data, nonce...)
	data = append(data, hash...)
	data = binary.BigEndian.AppendUint16(data, uint16(len(owner)))
	data = append(data, owner...)
	data = append(data, signing...)
	data = append(data, tls...)
	return binary.BigEndian.AppendUint64(data, uint64(challenge.ExpiresAt))
}
func verifyRegistration(key, signature string, payload []byte) bool {
	k, ok := registrationKey(key)
	if !ok || len(signature) > 100 {
		return false
	}
	sig, err := base64.RawURLEncoding.Strict().DecodeString(signature)
	if err != nil || base64.RawURLEncoding.EncodeToString(sig) != signature {
		return false
	}
	h := sha256.Sum256(payload)
	return ecdsa.VerifyASN1(k, h[:], sig)
}

func (a *api) deviceChallenge(w http.ResponseWriter, r *http.Request) {
	var keys deviceKeys
	if !decode(w, r, &keys) {
		return
	}
	_, signingOK := registrationKey(keys.SigningPublicKey)
	_, tlsOK := registrationKey(keys.TLSPublicKey)
	if !signingOK || !tlsOK || keys.SigningPublicKey == keys.TLSPublicKey {
		failure(w, 400, "Two distinct P-256 keys are required")
		return
	}
	if !a.limiter.allow("device:" + account(r)) {
		failure(w, 429, "Try again shortly")
		return
	}
	tx, current, ok := a.deviceTransaction(w, r, false)
	if !ok {
		return
	}
	defer tx.Rollback()
	if current.ID != "" && (current.SigningPublicKey != keys.SigningPublicKey || current.TLSPublicKey != keys.TLSPublicKey) {
		failure(w, 409, "Session already belongs to another device identity")
		return
	}
	challenge := registrationChallenge{Nonce: secret(), ExpiresAt: time.Now().Add(5 * time.Minute).Unix()}
	if _, err := tx.ExecContext(r.Context(), "DELETE FROM device_challenges WHERE expires_at<=?", time.Now().Unix()); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	_, err := tx.ExecContext(r.Context(), `INSERT INTO device_challenges(session_hash,nonce,signing_public_key,tls_public_key,expires_at)
 VALUES(?,?,?,?,?) ON CONFLICT(session_hash) DO UPDATE SET nonce=excluded.nonce,signing_public_key=excluded.signing_public_key,
 tls_public_key=excluded.tls_public_key,expires_at=excluded.expires_at`, sessionHash(r), challenge.Nonce, keys.SigningPublicKey, keys.TLSPublicKey, challenge.ExpiresAt)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, challenge)
}

func (a *api) registerDevice(w http.ResponseWriter, r *http.Request) {
	var proof registrationProof
	if !decode(w, r, &proof) {
		return
	}
	if _, ok := decodeURLBytes(proof.Nonce, 32); !ok {
		failure(w, 400, "Invalid challenge")
		return
	}
	tx, current, ok := a.deviceTransaction(w, r, false)
	if !ok {
		return
	}
	defer tx.Rollback()
	challenge := registrationChallenge{Nonce: proof.Nonce}
	var keys deviceKeys
	err := tx.QueryRowContext(r.Context(), `SELECT signing_public_key,tls_public_key,expires_at FROM device_challenges
 WHERE session_hash=? AND nonce=?`, sessionHash(r), proof.Nonce).Scan(&keys.SigningPublicKey, &keys.TLSPublicKey, &challenge.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && challenge.ExpiresAt <= time.Now().Unix()) {
		failure(w, 410, "Request a new device challenge")
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	payload := registrationPayload(challenge, sessionHash(r), account(r), keys)
	if !verifyRegistration(keys.SigningPublicKey, proof.SigningSignature, payload) || !verifyRegistration(keys.TLSPublicKey, proof.TLSSignature, payload) {
		failure(w, 403, "Device proof failed")
		return
	}
	var found device
	var revoked sql.NullInt64
	err = tx.QueryRowContext(r.Context(), `SELECT id,account_id,signing_public_key,tls_public_key,revoked_at FROM devices
 WHERE signing_public_key IN (?,?) OR tls_public_key IN (?,?)`, keys.SigningPublicKey, keys.TLSPublicKey, keys.SigningPublicKey, keys.TLSPublicKey).
		Scan(&found.ID, &found.AccountID, &found.SigningPublicKey, &found.TLSPublicKey, &revoked)
	status := 200
	if errors.Is(err, sql.ErrNoRows) {
		if current.ID != "" {
			failure(w, 409, "Session already has a device")
			return
		}
		found = device{newID(), account(r), keys.SigningPublicKey, keys.TLSPublicKey}
		_, err = tx.ExecContext(r.Context(), "INSERT INTO devices(id,account_id,signing_public_key,tls_public_key,created_at) VALUES(?,?,?,?,?)",
			found.ID, found.AccountID, found.SigningPublicKey, found.TLSPublicKey, time.Now().Unix())
		status = 201
	} else if err == nil && (revoked.Valid || found.AccountID != account(r) || found.SigningPublicKey != keys.SigningPublicKey || found.TLSPublicKey != keys.TLSPublicKey || (current.ID != "" && current.ID != found.ID)) {
		failure(w, 409, "Device identity is unavailable")
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if _, err = tx.ExecContext(r.Context(), "UPDATE sessions SET device_id=? WHERE hash=?", found.ID, sessionHash(r)); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	// Keep the bounded challenge until expiry so a lost response can retry both proofs.
	if tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, status, found)
}

func (a *api) currentDevice(w http.ResponseWriter, r *http.Request) {
	tx, d, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	jsonResponse(w, 200, d)
}

func (a *api) revokeDevice(w http.ResponseWriter, r *http.Request) {
	tx, _, ok := a.deviceTransaction(w, r, false)
	if !ok {
		return
	}
	defer tx.Rollback()
	id, now := r.PathValue("id"), time.Now().Unix()
	var found string
	err := tx.QueryRowContext(r.Context(), `UPDATE devices SET revoked_at=COALESCE(revoked_at,?)
 WHERE id=? AND account_id=? RETURNING id`, now, id, account(r)).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		failure(w, 404, "Not found")
		return
	}
	if err == nil {
		_, err = tx.ExecContext(r.Context(), "UPDATE peer_approvals SET revoked_at=COALESCE(revoked_at,?) WHERE sender_device_id=? OR recipient_device_id=?", now, id, id)
	}
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}
