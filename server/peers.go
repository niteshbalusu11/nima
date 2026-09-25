package main

import (
	"database/sql"
	"errors"
	"net/http"
	"time"
)

// A full active-approval snapshot stays bounded and can replace a client's cache.
const maxPeerApprovals = 64

type peerApproval struct {
	ID            string `json:"id"`
	Sender        device `json:"sender"`
	Recipient     device `json:"recipient"`
	CreatedAt     int64  `json:"created_at"`
	SenderName    string `json:"sender_name"`
	RecipientName string `json:"recipient_name"`
}

const approvalSelect = `SELECT p.id,s.id,s.account_id,s.signing_public_key,s.tls_public_key,
 d.id,d.account_id,d.signing_public_key,d.tls_public_key,p.created_at,sa.name,da.name
 FROM peer_approvals p JOIN devices s ON s.id=p.sender_device_id JOIN devices d ON d.id=p.recipient_device_id
 JOIN accounts sa ON sa.id=s.account_id JOIN accounts da ON da.id=d.account_id
 WHERE p.revoked_at IS NULL AND s.revoked_at IS NULL AND d.revoked_at IS NULL AND sa.active=1 AND da.active=1`

func scanApproval(row interface{ Scan(...any) error }) (peerApproval, error) {
	var p peerApproval
	err := row.Scan(&p.ID, &p.Sender.ID, &p.Sender.AccountID, &p.Sender.SigningPublicKey, &p.Sender.TLSPublicKey,
		&p.Recipient.ID, &p.Recipient.AccountID, &p.Recipient.SigningPublicKey, &p.Recipient.TLSPublicKey, &p.CreatedAt, &p.SenderName, &p.RecipientName)
	return p, err
}

func (a *api) createPeerInvitation(w http.ResponseWriter, r *http.Request) {
	var input struct {
		RecipientAccountID string `json:"recipient_account_id"`
		RecipientDeviceID  string `json:"recipient_device_id"`
	}
	if !decode(w, r, &input) {
		return
	}
	if !a.limiter.allow("peer-invite:" + account(r)) {
		failure(w, 429, "Try again shortly")
		return
	}
	tx, sender, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	var target, name string
	err := tx.QueryRowContext(r.Context(), `SELECT d.id,a.name FROM devices d JOIN accounts a ON a.id=d.account_id
 WHERE d.id=? AND d.account_id=? AND d.id!=? AND d.revoked_at IS NULL AND a.active=1`, input.RecipientDeviceID, input.RecipientAccountID, sender.ID).Scan(&target, &name)
	if errors.Is(err, sql.ErrNoRows) {
		failure(w, 404, "Recipient unavailable")
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	var count int
	err = tx.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM peer_approvals WHERE sender_device_id=? AND recipient_device_id=? AND revoked_at IS NULL", sender.ID, target).Scan(&count)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if count != 0 {
		failure(w, 409, "Recipient already approved")
		return
	}
	// Replace outstanding tokens for this direction; accepted tokens retain their result.
	_, err = tx.ExecContext(r.Context(), `DELETE FROM peer_invitations WHERE expires_at<=? OR
 (sender_device_id=? AND recipient_device_id=? AND approval_id IS NULL)`, time.Now().Unix(), sender.ID, target)
	invite := invitation{Token: secret(), ExpiresAt: time.Now().Add(24 * time.Hour).Unix()}
	if err == nil {
		_, err = tx.ExecContext(r.Context(), "INSERT INTO peer_invitations(hash,sender_device_id,recipient_device_id,expires_at) VALUES(?,?,?,?)",
			digest(invite.Token), sender.ID, target, invite.ExpiresAt)
	}
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 201, struct {
		invitation
		RecipientName string `json:"recipient_name"`
	}{invite, name})
}

func (a *api) previewPeerInvitation(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Token string `json:"token"`
	}
	if !decode(w, r, &input) {
		return
	}
	if _, ok := decodeURLBytes(input.Token, 32); !ok {
		failure(w, 400, "Invalid peer invitation")
		return
	}
	tx, recipient, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	var preview struct {
		Sender     device `json:"sender"`
		SenderName string `json:"sender_name"`
		ExpiresAt  int64  `json:"expires_at"`
	}
	var accepted sql.NullString
	err := tx.QueryRowContext(r.Context(), `SELECT d.id,d.account_id,d.signing_public_key,d.tls_public_key,a.name,i.expires_at,i.approval_id
 FROM peer_invitations i JOIN devices d ON d.id=i.sender_device_id JOIN accounts a ON a.id=d.account_id
 WHERE i.hash=? AND i.recipient_device_id=? AND d.revoked_at IS NULL AND a.active=1`, digest(input.Token), recipient.ID).
		Scan(&preview.Sender.ID, &preview.Sender.AccountID, &preview.Sender.SigningPublicKey, &preview.Sender.TLSPublicKey, &preview.SenderName, &preview.ExpiresAt, &accepted)
	if errors.Is(err, sql.ErrNoRows) {
		failure(w, 404, "Peer invitation unavailable")
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if preview.ExpiresAt <= time.Now().Unix() {
		failure(w, 410, "Peer invitation expired")
		return
	}
	if accepted.Valid {
		_, err = scanApproval(tx.QueryRowContext(r.Context(), approvalSelect+" AND p.id=?", accepted.String))
		if errors.Is(err, sql.ErrNoRows) {
			failure(w, 410, "Peer approval revoked")
			return
		}
		if err != nil {
			failure(w, 503, "Unavailable")
			return
		}
	}
	jsonResponse(w, 200, preview)
}

func (a *api) acceptPeerInvitation(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Token string `json:"token"`
	}
	if !decode(w, r, &input) {
		return
	}
	if _, ok := decodeURLBytes(input.Token, 32); !ok {
		failure(w, 400, "Invalid peer invitation")
		return
	}
	tx, recipient, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	var sender string
	var expires int64
	var accepted sql.NullString
	err := tx.QueryRowContext(r.Context(), `SELECT i.sender_device_id,i.expires_at,i.approval_id FROM peer_invitations i
 JOIN devices d ON d.id=i.sender_device_id JOIN accounts a ON a.id=d.account_id
 WHERE i.hash=? AND i.recipient_device_id=? AND d.revoked_at IS NULL AND a.active=1`, digest(input.Token), recipient.ID).Scan(&sender, &expires, &accepted)
	if errors.Is(err, sql.ErrNoRows) {
		failure(w, 404, "Peer invitation unavailable")
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	status, id := 200, accepted.String
	if !accepted.Valid {
		if expires <= time.Now().Unix() {
			failure(w, 410, "Peer invitation expired")
			return
		}
		for _, d := range []string{sender, recipient.ID} {
			var count int
			err = tx.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM peer_approvals WHERE (sender_device_id=? OR recipient_device_id=?) AND revoked_at IS NULL", d, d).Scan(&count)
			if err != nil {
				failure(w, 503, "Unavailable")
				return
			}
			if count >= maxPeerApprovals {
				failure(w, 409, "Device has too many approved peers")
				return
			}
		}
		id, status = newID(), 201
		_, err = tx.ExecContext(r.Context(), "INSERT INTO peer_approvals(id,sender_device_id,recipient_device_id,created_at) VALUES(?,?,?,?)", id, sender, recipient.ID, time.Now().Unix())
		if err == nil {
			_, err = tx.ExecContext(r.Context(), "UPDATE peer_invitations SET approval_id=? WHERE hash=?", id, digest(input.Token))
		}
		if err != nil {
			failure(w, 503, "Unavailable")
			return
		}
	}
	p, err := scanApproval(tx.QueryRowContext(r.Context(), approvalSelect+" AND p.id=?", id))
	if errors.Is(err, sql.ErrNoRows) {
		failure(w, 410, "Peer approval revoked")
		return
	}
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, status, p)
}

func (a *api) listPeerApprovals(w http.ResponseWriter, r *http.Request) {
	tx, current, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(r.Context(), approvalSelect+" AND (s.id=? OR d.id=?) ORDER BY p.created_at,p.id", current.ID, current.ID)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer rows.Close()
	approvals := []peerApproval{}
	for rows.Next() {
		p, err := scanApproval(rows)
		if err != nil {
			failure(w, 503, "Unavailable")
			return
		}
		approvals = append(approvals, p)
	}
	if rows.Err() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]any{"approvals": approvals})
}

func (a *api) revokePeerApproval(w http.ResponseWriter, r *http.Request) {
	tx, current, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	var id string
	err := tx.QueryRowContext(r.Context(), `UPDATE peer_approvals SET revoked_at=COALESCE(revoked_at,?)
 WHERE id=? AND (sender_device_id=? OR recipient_device_id=?) RETURNING id`, time.Now().Unix(), r.PathValue("id"), current.ID, current.ID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		failure(w, 404, "Not found")
		return
	}
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}
