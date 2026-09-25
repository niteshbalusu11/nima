package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

const nearbyCredentialLifetime = 30 * 24 * time.Hour
const nearbyCredentialDomain = "uploadvideo.nearby-credential.v1\x00"
const nearbyPermissionDomain = "uploadvideo.nearby-permission.v1\x00"

type nearbyCredential struct {
	Device    device `json:"device"`
	Name      string `json:"name"`
	IssuedAt  int64  `json:"issued_at"`
	ExpiresAt int64  `json:"expires_at"`
}
type nearbyPermission struct {
	Approval           peerApproval `json:"approval"`
	Authority          string       `json:"authority"`
	SenderSignature    string       `json:"sender_signature"`
	RecipientSignature string       `json:"recipient_signature"`
}

// The authority is scoped to this persistent database. Only authenticated HTTPS
// delivers its public key to a phone; a peer may never replace that trust anchor.
func nearbyAuthority(tx *sql.Tx) (ed25519.PrivateKey, error) {
	var seed []byte
	err := tx.QueryRow("SELECT seed FROM nearby_authority WHERE id=1").Scan(&seed)
	if errors.Is(err, sql.ErrNoRows) {
		seed = make([]byte, ed25519.SeedSize)
		if _, err = rand.Read(seed); err == nil {
			_, err = tx.Exec("INSERT INTO nearby_authority(id,seed) VALUES(1,?)", seed)
		}
	}
	if err != nil {
		return nil, err
	}
	if len(seed) != ed25519.SeedSize {
		return nil, errors.New("invalid nearby authority")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func (a *api) nearbyCredential(w http.ResponseWriter, r *http.Request) {
	tx, d, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	key, err := nearbyAuthority(tx)
	var name string
	if err == nil {
		err = tx.QueryRow("SELECT name FROM accounts WHERE id=?", d.AccountID).Scan(&name)
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	now := time.Now()
	payload, err := json.Marshal(nearbyCredential{d, name, now.Unix(), now.Add(nearbyCredentialLifetime).Unix()})
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	signature := ed25519.Sign(key, append([]byte(nearbyCredentialDomain), payload...))
	jsonResponse(w, 200, map[string]any{"authority": base64.RawURLEncoding.EncodeToString(key.Public().(ed25519.PublicKey)), "certificate": signedMediaRecord{base64.RawURLEncoding.EncodeToString(payload), base64.RawURLEncoding.EncodeToString(signature)}})
}

// Fixed-width bytes, shared with NearbyPairing.swift; display names are not
// authority and are obtained from the database when the permission is synced.
func nearbyPermissionPayload(p nearbyPermission) ([]byte, bool) {
	authority, ok := decodeURLBytes(p.Authority, 32)
	if !ok {
		return nil, false
	}
	data := append([]byte(nearbyPermissionDomain), authority...)
	id, err := hex.DecodeString(p.Approval.ID)
	if err != nil || len(id) != 16 || hex.EncodeToString(id) != p.Approval.ID {
		return nil, false
	}
	data = append(data, id...)
	for _, d := range []device{p.Approval.Sender, p.Approval.Recipient} {
		for _, s := range []string{d.ID, d.AccountID} {
			b, e := hex.DecodeString(s)
			if e != nil || len(b) != 16 || hex.EncodeToString(b) != s {
				return nil, false
			}
			data = append(data, b...)
		}
		for _, s := range []string{d.SigningPublicKey, d.TLSPublicKey} {
			b, ok := decodeURLBytes(s, 65)
			if !ok {
				return nil, false
			}
			if _, ok = registrationKey(s); !ok {
				return nil, false
			}
			data = append(data, b...)
		}
		if d.SigningPublicKey == d.TLSPublicKey {
			return nil, false
		}
	}
	if p.Approval.CreatedAt <= 0 || p.Approval.Sender.ID == p.Approval.Recipient.ID {
		return nil, false
	}
	return binary.BigEndian.AppendUint64(data, uint64(p.Approval.CreatedAt)), true
}

func (a *api) syncNearbyPermission(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Permission nearbyPermission `json:"permission"`
		Revoked    bool             `json:"revoked"`
	}
	if !decode(w, r, &input) {
		return
	}
	p := input.Permission
	payload, valid := nearbyPermissionPayload(p)
	if !valid || p.Approval.ID != r.PathValue("id") || !verifyRegistration(p.Approval.Sender.SigningPublicKey, p.SenderSignature, payload) || !verifyRegistration(p.Approval.Recipient.SigningPublicKey, p.RecipientSignature, payload) {
		failure(w, 400, "Invalid nearby permission")
		return
	}
	tx, caller, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	if caller != p.Approval.Sender && caller != p.Approval.Recipient {
		failure(w, 403, "Permission belongs to other devices")
		return
	}
	key, err := nearbyAuthority(tx)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if p.Authority != base64.RawURLEncoding.EncodeToString(key.Public().(ed25519.PublicKey)) {
		failure(w, 403, "Permission belongs to another server")
		return
	}
	for _, d := range []device{p.Approval.Sender, p.Approval.Recipient} {
		var actual device
		err = tx.QueryRow(`SELECT d.id,d.account_id,d.signing_public_key,d.tls_public_key FROM devices d JOIN accounts a ON a.id=d.account_id WHERE d.id=? AND d.revoked_at IS NULL AND a.active=1`, d.ID).Scan(&actual.ID, &actual.AccountID, &actual.SigningPublicKey, &actual.TLSPublicKey)
		if errors.Is(err, sql.ErrNoRows) || err == nil && actual != d {
			failure(w, 403, "Device sharing access revoked")
			return
		}
		if err != nil {
			failure(w, 503, "Unavailable")
			return
		}
	}
	var sender, recipient string
	var created int64
	var revoked sql.NullInt64
	err = tx.QueryRow("SELECT sender_device_id,recipient_device_id,created_at,revoked_at FROM peer_approvals WHERE id=?", p.Approval.ID).Scan(&sender, &recipient, &created, &revoked)
	if err == nil {
		if sender != p.Approval.Sender.ID || recipient != p.Approval.Recipient.ID || created != p.Approval.CreatedAt {
			failure(w, 409, "Permission identity changed")
			return
		}
		if revoked.Valid && !input.Revoked {
			failure(w, 410, "Sharing permission removed")
			return
		}
	} else if errors.Is(err, sql.ErrNoRows) {
		now := time.Now().Unix()
		if p.Approval.CreatedAt > now+300 || p.Approval.CreatedAt < now-int64(nearbyCredentialLifetime.Seconds()) {
			failure(w, 410, "Pair again to renew sharing permission")
			return
		}
		// A revoked import is a tombstone, not an active peer. It must succeed even
		// when the devices already reached the active-peer limit.
		if !input.Revoked {
			for _, id := range []string{p.Approval.Sender.ID, p.Approval.Recipient.ID} {
				var count int
				if tx.QueryRow("SELECT COUNT(*) FROM peer_approvals WHERE (sender_device_id=? OR recipient_device_id=?) AND revoked_at IS NULL", id, id).Scan(&count) != nil {
					failure(w, 503, "Unavailable")
					return
				}
				if count >= maxPeerApprovals {
					failure(w, 409, "Device has too many approved peers")
					return
				}
			}
			var count int
			if tx.QueryRow("SELECT COUNT(*) FROM peer_approvals WHERE sender_device_id=? AND recipient_device_id=? AND revoked_at IS NULL", p.Approval.Sender.ID, p.Approval.Recipient.ID).Scan(&count) != nil {
				failure(w, 503, "Unavailable")
				return
			}
			if count > 0 {
				failure(w, 409, "Another permission already exists for these devices")
				return
			}
		}
		var removal any
		if input.Revoked {
			removal = now
		}
		_, err = tx.Exec("INSERT INTO peer_approvals(id,sender_device_id,recipient_device_id,created_at,revoked_at) VALUES(?,?,?,?,?)", p.Approval.ID, p.Approval.Sender.ID, p.Approval.Recipient.ID, p.Approval.CreatedAt, removal)
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if input.Revoked {
		_, err = tx.Exec("UPDATE peer_approvals SET revoked_at=COALESCE(revoked_at,?) WHERE id=?", time.Now().Unix(), p.Approval.ID)
	}
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}
