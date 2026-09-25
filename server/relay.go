package main

import (
	"database/sql"
	"errors"
	"net/http"
	"time"
)

func (a *api) relayAvailable(w http.ResponseWriter) bool {
	if !a.relayEnabled {
		mediaFailure(w, mediaAPIError{503, "relay_disabled", "Nearby cloud recovery is not enabled"})
		return false
	}
	return true
}

func attachSharedCapture(tx *sql.Tx, capture verifiedMediaCapture) error {
	d := capture.Descriptor
	var owner, kind string
	var deleted sql.NullInt64
	if err := tx.QueryRow("SELECT account_id,kind,deleted_at FROM captures WHERE id=?", d.CaptureID).Scan(&owner, &kind, &deleted); err != nil {
		return err
	}
	if owner != d.AccountID {
		return mediaConflict("Capture belongs to another recorder")
	}
	if deleted.Valid {
		return mediaAPIError{410, "capture_deleted", "Capture deleted"}
	}
	if kind != d.Kind {
		return mediaConflict("Capture kind changed")
	}
	var payload string
	err := tx.QueryRow("SELECT descriptor_payload FROM shared_captures WHERE capture_id=?", d.CaptureID).Scan(&payload)
	if err == nil {
		if payload != capture.Envelope.Payload {
			return mediaConflict("Capture descriptor changed")
		}
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	_, err = tx.Exec("INSERT INTO shared_captures(capture_id,recorder_device_id,descriptor_payload,descriptor_signature) VALUES(?,?,?,?)", d.CaptureID, d.DeviceID, capture.Envelope.Payload, capture.Envelope.Signature)
	if err == nil {
		_, err = tx.Exec("UPDATE captures SET finished=0 WHERE id=?", d.CaptureID)
	}
	return err
}

func loadSharedCapture(tx *sql.Tx, id string) (verifiedMediaCapture, *signedMediaRecord, error) {
	var recorder device
	var descriptor signedMediaRecord
	var payload, signature sql.NullString
	err := tx.QueryRow(`SELECT d.id,d.account_id,d.signing_public_key,d.tls_public_key,s.descriptor_payload,s.descriptor_signature,s.completion_payload,s.completion_signature
 FROM shared_captures s JOIN devices d ON d.id=s.recorder_device_id WHERE s.capture_id=?`, id).Scan(
		&recorder.ID, &recorder.AccountID, &recorder.SigningPublicKey, &recorder.TLSPublicKey, &descriptor.Payload, &descriptor.Signature, &payload, &signature)
	if err != nil {
		return verifiedMediaCapture{}, nil, err
	}
	capture, err := verifyMediaCapture(descriptor, recorder)
	if err != nil {
		return verifiedMediaCapture{}, nil, err
	}
	if payload.Valid && signature.Valid {
		return capture, &signedMediaRecord{payload.String, signature.String}, nil
	}
	return capture, nil, nil
}

func (a *api) redeemRelay(w http.ResponseWriter, r *http.Request) {
	if !a.relayAvailable(w) {
		return
	}
	var input struct {
		ApprovalID string            `json:"approval_id"`
		Descriptor signedMediaRecord `json:"descriptor"`
		Grant      signedMediaRecord `json:"grant"`
	}
	if !decode(w, r, &input) {
		return
	}
	tx, caller, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	approval, err := scanApproval(tx.QueryRow(approvalSelect+" AND p.id=? AND d.id=?", input.ApprovalID, caller.ID))
	if errors.Is(err, sql.ErrNoRows) {
		mediaFailure(w, mediaAPIError{403, "approval_revoked", "Sharing approval is unavailable"})
		return
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	capture, err := verifyMediaCapture(input.Descriptor, approval.Sender)
	if err != nil || !capture.validAt(time.Now().Unix()) {
		mediaFailure(w, mediaAPIError{400, "invalid_signature", "Invalid signed capture"})
		return
	}
	grant, err := capture.grant(input.Grant, approval)
	if err != nil {
		mediaFailure(w, mediaAPIError{400, "invalid_signature", "Invalid sharing permission"})
		return
	}
	if !grant.activeAt(time.Now().Unix()) {
		mediaFailure(w, mediaAPIError{403, "grant_expired", "Sharing permission expired or is not yet valid"})
		return
	}
	var oldPayload string
	err = tx.QueryRow("SELECT payload FROM relay_grants WHERE id=?", grant.ID).Scan(&oldPayload)
	if err == nil && oldPayload != input.Grant.Payload {
		mediaFailure(w, mediaConflict("Sharing permission ID was reused"))
		return
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		mediaFailure(w, err)
		return
	}
	d := capture.Descriptor
	_, err = tx.Exec(`INSERT INTO captures(id,account_id,kind,created_at,owner_metadata_pending) VALUES(?,?,?,?,1) ON CONFLICT(id) DO NOTHING`, d.CaptureID, d.AccountID, d.Kind, d.CreatedAt)
	if err == nil {
		err = attachSharedCapture(tx, capture)
	}
	if err == nil {
		_, err = tx.Exec("INSERT INTO relay_grants(id,capture_id,approval_id,payload,signature) VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING", grant.ID, d.CaptureID, grant.ApprovalID, input.Grant.Payload, input.Grant.Signature)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	jsonResponse(w, 200, map[string]any{"id": grant.ID, "capture_id": d.CaptureID, "recorder_account_id": d.AccountID})
}

func loadRelay(tx *sql.Tx, caller device, id string) (verifiedMediaCapture, mediaGrant, error) {
	var captureID, approvalID string
	var signed signedMediaRecord
	err := tx.QueryRow("SELECT capture_id,approval_id,payload,signature FROM relay_grants WHERE id=?", id).Scan(&captureID, &approvalID, &signed.Payload, &signed.Signature)
	if errors.Is(err, sql.ErrNoRows) {
		return verifiedMediaCapture{}, mediaGrant{}, mediaAPIError{404, "not_found", "Sharing permission not found"}
	}
	if err != nil {
		return verifiedMediaCapture{}, mediaGrant{}, err
	}
	approval, err := scanApproval(tx.QueryRow(approvalSelect+" AND p.id=? AND d.id=?", approvalID, caller.ID))
	if errors.Is(err, sql.ErrNoRows) {
		return verifiedMediaCapture{}, mediaGrant{}, mediaAPIError{403, "approval_revoked", "Sharing approval is unavailable"}
	}
	if err != nil {
		return verifiedMediaCapture{}, mediaGrant{}, err
	}
	capture, _, err := loadSharedCapture(tx, captureID)
	if err != nil {
		return verifiedMediaCapture{}, mediaGrant{}, err
	}
	grant, err := capture.grant(signed, approval)
	if err != nil {
		return verifiedMediaCapture{}, mediaGrant{}, err
	}
	if !grant.activeAt(time.Now().Unix()) {
		return verifiedMediaCapture{}, mediaGrant{}, mediaAPIError{403, "grant_expired", "Sharing permission expired or is not yet valid"}
	}
	var deleted sql.NullInt64
	if err = tx.QueryRow("SELECT deleted_at FROM captures WHERE id=?", captureID).Scan(&deleted); err != nil {
		return verifiedMediaCapture{}, mediaGrant{}, err
	}
	if deleted.Valid {
		return verifiedMediaCapture{}, mediaGrant{}, mediaAPIError{410, "capture_deleted", "Capture deleted"}
	}
	return capture, grant, nil
}

func (a *api) reserveRelay(w http.ResponseWriter, r *http.Request) {
	if !a.relayAvailable(w) {
		return
	}
	var input struct {
		Manifest signedMediaRecord `json:"manifest"`
	}
	if !decode(w, r, &input) {
		return
	}
	tx, caller, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	capture, grant, err := loadRelay(tx, caller, r.PathValue("id"))
	if err != nil {
		mediaFailure(w, err)
		return
	}
	o, err := capture.manifest(input.Manifest)
	if err != nil {
		mediaFailure(w, mediaAPIError{400, "invalid_signature", "Invalid signed fragment"})
		return
	}
	o, err = reserveCanonical(tx, capture.Descriptor.AccountID, o)
	if err != nil {
		mediaFailure(w, err)
		return
	}
	var originalPayload string
	err = tx.QueryRow("SELECT payload FROM shared_object_records WHERE capture_id=? AND sequence=?", o.CaptureID, o.Sequence).Scan(&originalPayload)
	if err == nil && originalPayload != input.Manifest.Payload {
		mediaFailure(w, mediaConflict("Signed fragment changed"))
		return
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		mediaFailure(w, err)
		return
	}
	_, err = tx.Exec("INSERT INTO shared_object_records(capture_id,sequence,payload,signature) VALUES(?,?,?,?) ON CONFLICT(capture_id,sequence) DO NOTHING", o.CaptureID, o.Sequence, input.Manifest.Payload, input.Manifest.Signature)
	if err != nil {
		mediaFailure(w, err)
		return
	}
	_, err = tx.Exec("INSERT INTO relay_grant_objects(grant_id,capture_id,sequence) VALUES(?,?,?) ON CONFLICT(grant_id,sequence) DO NOTHING", grant.ID, o.CaptureID, o.Sequence)
	var used int64
	if err == nil {
		err = tx.QueryRow(`SELECT COALESCE(SUM(o.size),0) FROM relay_grant_objects g JOIN objects o ON o.capture_id=g.capture_id AND o.sequence=g.sequence WHERE g.grant_id=?`, grant.ID).Scan(&used)
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	if used > grant.ByteLimit {
		mediaFailure(w, mediaAPIError{413, "grant_quota", "Sharing permission allowance exceeded"})
		return
	}
	var signed signedUpload
	if !o.Acknowledged {
		store, supported := a.store.(relayObjectStore)
		if !supported {
			mediaFailure(w, mediaAPIError{503, "relay_disabled", "Verified relay storage is unavailable"})
			return
		}
		lifetime := min(uploadURLLifetime, time.Until(time.Unix(grant.ExpiresAt, 0)))
		// Local presigning only: no storage request while holding the transaction.
		signed, err = store.uploadRelay(r.Context(), o, lifetime)
		if err != nil {
			mediaFailure(w, err)
			return
		}
	}
	if err = tx.Commit(); err != nil {
		mediaFailure(w, err)
		return
	}
	if o.Acknowledged {
		jsonResponse(w, 200, map[string]any{"acknowledged": true})
		return
	}
	jsonResponse(w, 200, map[string]any{"acknowledged": false, "url": signed.URL, "headers": signed.Headers})
}

func (a *api) ackRelay(w http.ResponseWriter, r *http.Request) {
	if !a.relayAvailable(w) {
		return
	}
	var input struct {
		Sequence int `json:"sequence"`
	}
	if !decode(w, r, &input) {
		return
	}
	tx, caller, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	capture, _, err := loadRelay(tx, caller, r.PathValue("id"))
	if err != nil {
		mediaFailure(w, err)
		return
	}
	o, err := scanObject(tx.QueryRow("SELECT "+objectColumns+" FROM objects WHERE capture_id=? AND sequence=? AND EXISTS(SELECT 1 FROM relay_grant_objects g WHERE g.grant_id=? AND g.capture_id=objects.capture_id AND g.sequence=objects.sequence)", capture.Descriptor.CaptureID, input.Sequence, r.PathValue("id")))
	if errors.Is(err, sql.ErrNoRows) {
		mediaFailure(w, mediaAPIError{404, "not_found", "Fragment not reserved"})
		return
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	// Release SQLite while hashing storage bytes, then recheck authorization and deletion.
	if err = tx.Commit(); err != nil {
		mediaFailure(w, err)
		return
	}
	verified := o.Acknowledged
	if !verified {
		verified, err = a.store.verify(r.Context(), o)
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	if !verified {
		mediaFailure(w, mediaAPIError{409, "upload_missing", "Upload missing or invalid"})
		return
	}
	tx, caller, ok = a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	if _, _, err = loadRelay(tx, caller, r.PathValue("id")); err == nil {
		_, err = tx.Exec("UPDATE objects SET acknowledged=1 WHERE capture_id=? AND sequence=? AND object_key=?", o.CaptureID, o.Sequence, o.Key)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}

func checkSharedObject(tx *sql.Tx, o object) error {
	capture, signed, err := loadSharedCapture(tx, o.CaptureID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	validKind := (capture.Descriptor.Kind == "photo" && o.Kind == "photo" && o.Sequence == 0) ||
		(capture.Descriptor.Kind == "video" && ((o.Kind == "init" && o.Sequence == 0) || (o.Kind == "media" && o.Sequence > 0)))
	if !validKind || !mediaTime(o.Duration, 60) || !mediaTime(o.StartTime, 6000000) || (o.Kind != "media" && (o.Duration != 0 || o.StartTime != 0)) {
		return mediaAPIError{400, "invalid_metadata", "Invalid shared fragment metadata"}
	}
	var count int
	var total int64
	if err = tx.QueryRow("SELECT COUNT(*),COALESCE(SUM(size),0) FROM objects WHERE capture_id=? AND sequence!=?", o.CaptureID, o.Sequence).Scan(&count, &total); err != nil {
		return err
	}
	if total+o.Size > maxSharedCapture {
		return mediaAPIError{413, "capture_quota", "Shared recording storage is full"}
	}
	if signed == nil {
		return nil
	}
	completion, err := capture.completion(*signed)
	if err != nil {
		return err
	}
	if o.Sequence > completion.LastSequence || total+o.Size > completion.TotalBytes || (count+1 == completion.ObjectCount && total+o.Size != completion.TotalBytes) {
		return mediaConflict("Fragment conflicts with recording ending")
	}
	return nil
}

func saveSharedCompletion(tx *sql.Tx, capture verifiedMediaCapture, signed signedMediaRecord) error {
	ending, err := capture.completion(signed)
	if err != nil {
		return mediaAPIError{400, "invalid_signature", "Invalid signed recording ending"}
	}
	_, old, err := loadSharedCapture(tx, capture.Descriptor.CaptureID)
	if err != nil {
		return err
	}
	if old != nil {
		if old.Payload != signed.Payload {
			return mediaConflict("Recording ending changed")
		}
		return nil
	}
	var count, last int
	var total int64
	err = tx.QueryRow("SELECT COUNT(*),COALESCE(MAX(sequence),-1),COALESCE(SUM(size),0) FROM objects WHERE capture_id=?", capture.Descriptor.CaptureID).Scan(&count, &last, &total)
	if err != nil {
		return err
	}
	if last > ending.LastSequence || total > ending.TotalBytes || (count == ending.ObjectCount && total != ending.TotalBytes) {
		return mediaConflict("Recording ending conflicts with fragments")
	}
	_, err = tx.Exec("UPDATE shared_captures SET completion_payload=?,completion_signature=? WHERE capture_id=?", signed.Payload, signed.Signature, capture.Descriptor.CaptureID)
	return err
}

type sharedCaptureStatus struct {
	Ending   string `json:"recording_ending"`
	Complete bool   `json:"cloud_complete"`
}

func sharedStatus(tx *sql.Tx, id string) (*sharedCaptureStatus, error) {
	capture, signed, err := loadSharedCapture(tx, id)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	status := &sharedCaptureStatus{Ending: "unknown"}
	if signed == nil {
		return status, nil
	}
	ending, err := capture.completion(*signed)
	if err != nil {
		return nil, err
	}
	status.Ending = ending.Ending
	var count, first, last, pending int
	var total int64
	err = tx.QueryRow(`SELECT COUNT(*),COALESCE(MIN(sequence),-1),COALESCE(MAX(sequence),-1),COALESCE(SUM(size),0),COALESCE(SUM(1-acknowledged),0) FROM objects WHERE capture_id=?`, id).Scan(&count, &first, &last, &total, &pending)
	if err != nil {
		return nil, err
	}
	status.Complete = count == ending.ObjectCount && first == 0 && last == ending.LastSequence && total == ending.TotalBytes && pending == 0
	return status, nil
}

func (a *api) completeRelay(w http.ResponseWriter, r *http.Request) {
	if !a.relayAvailable(w) {
		return
	}
	var input struct {
		Completion signedMediaRecord `json:"completion"`
	}
	if !decode(w, r, &input) {
		return
	}
	tx, caller, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	capture, _, err := loadRelay(tx, caller, r.PathValue("id"))
	if err == nil {
		err = saveSharedCompletion(tx, capture, input.Completion)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}

func (a *api) completeOwner(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Completion signedMediaRecord `json:"completion"`
	}
	if !decode(w, r, &input) {
		return
	}
	tx, _, ok := a.deviceTransaction(w, r, true)
	if !ok {
		return
	}
	defer tx.Rollback()
	capture, _, err := loadSharedCapture(tx, r.PathValue("id"))
	if errors.Is(err, sql.ErrNoRows) || (err == nil && capture.Descriptor.AccountID != account(r)) {
		mediaFailure(w, mediaAPIError{404, "not_found", "Not found"})
		return
	}
	if err == nil {
		err = attachSharedCapture(tx, capture)
	} // Includes the permanent tombstone check.
	if err == nil {
		err = saveSharedCompletion(tx, capture, input.Completion)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		mediaFailure(w, err)
		return
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}
