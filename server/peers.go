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
