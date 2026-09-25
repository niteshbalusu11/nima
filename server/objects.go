package main

import (
	"database/sql"
	"errors"
	"net/http"
)

type mediaAPIError struct {
	status        int
	code, message string
}

func (e mediaAPIError) Error() string { return e.message }
func mediaFailure(w http.ResponseWriter, err error) {
	var e mediaAPIError
	if !errors.As(err, &e) {
		e = mediaAPIError{503, "unavailable", "Sharing temporarily unavailable"}
	}
	jsonResponse(w, e.status, map[string]string{"code": e.code, "error": e.message})
}
func mediaConflict(message string) error { return mediaAPIError{409, "metadata_conflict", message} }

// Both upload principals reserve the same immutable capture/sequence and charge
// the recorder's account once. The caller holds the deletion-serialization lock.
func reserveCanonical(tx *sql.Tx, owner string, o object) (object, error) {
	var storedOwner string
	var deleted sql.NullInt64
	if err := tx.QueryRow("SELECT account_id,deleted_at FROM captures WHERE id=?", o.CaptureID).Scan(&storedOwner, &deleted); err != nil {
		return object{}, err
	}
	if storedOwner != owner {
		return object{}, mediaAPIError{404, "not_found", "Not found"}
	}
	if deleted.Valid {
		return object{}, mediaAPIError{410, "capture_deleted", "Capture deleted"}
	}
	if err := checkSharedObject(tx, o); err != nil {
		return object{}, err
	}
	old, err := scanObject(tx.QueryRow("SELECT "+objectColumns+" FROM objects WHERE capture_id=? AND sequence=?", o.CaptureID, o.Sequence))
	if err == nil {
		if old.SHA256 != o.SHA256 || old.MD5 != o.MD5 || old.Size != o.Size || old.Kind != o.Kind || old.Duration != o.Duration || old.StartTime != o.StartTime {
			return object{}, mediaConflict("Object conflict")
		}
		return old, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return object{}, err
	}
	var used int64
	if err = tx.QueryRow("SELECT COALESCE(SUM(o.size),0) FROM objects o JOIN captures c ON c.id=o.capture_id WHERE c.account_id=? AND c.deleted_at IS NULL", owner).Scan(&used); err != nil {
		return object{}, err
	}
	if used+o.Size > accountQuota {
		return object{}, mediaAPIError{413, "account_quota", "Recorder storage is full"}
	}
	o.Key = newID() + "/" + newID()
	o.Acknowledged = false
	_, err = tx.Exec("INSERT INTO objects("+objectColumns+") VALUES(?,?,?,?,?,?,?,?,?,0)", o.CaptureID, o.Sequence, o.Kind, o.Key, o.SHA256, o.MD5, o.Size, o.Duration, o.StartTime)
	return o, err
}
