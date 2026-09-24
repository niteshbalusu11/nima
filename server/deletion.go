package main

import (
	"context"
	"log"
	"net/http"
	"time"
)

// A PUT signed before deletion may still arrive. Keep its key until the URL
// expires, with time for the phone's 30-second upload request to finish.
const deletionGrace = uploadURLLifetime + 3*time.Minute

func (a *api) deleteCapture(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !captureID.MatchString(id) {
		failure(w, 400, "Invalid capture")
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer tx.Rollback()
	now := time.Now().Unix()
	// Also tombstone captures whose first upload has not reached this server.
	_, err = tx.Exec("INSERT INTO captures(id,account_id,kind,created_at,deleted_at) VALUES(?,?,'photo',?,?) ON CONFLICT(id) DO NOTHING", id, account(r), now, now)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	var owner string
	if err = tx.QueryRow("SELECT account_id FROM captures WHERE id=?", id).Scan(&owner); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if owner != account(r) {
		failure(w, 404, "Not found")
		return
	}
	if _, err = tx.Exec("UPDATE captures SET deleted_at=COALESCE(deleted_at,?) WHERE id=?", now, id); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if err = tx.Commit(); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	// Durable intent is already committed. Storage failures are retried at startup
	// and periodically; they must not cause the phone to resume this capture.
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err = a.cleanCapture(ctx, id, time.Now()); err != nil {
		log.Printf("capture cleanup will retry: %v", err)
	}
	jsonResponse(w, 202, map[string]bool{"ok": true})
}

func (a *api) cleanCapture(ctx context.Context, id string, now time.Time) error {
	rows, err := a.db.QueryContext(ctx, "SELECT o.object_key,c.deleted_at FROM objects o JOIN captures c ON c.id=o.capture_id WHERE c.id=? AND c.deleted_at IS NOT NULL", id)
	if err != nil {
		return err
	}
	var keys []string
	var deleted int64
	for rows.Next() {
		var key string
		if err = rows.Scan(&key, &deleted); err != nil {
			rows.Close()
			return err
		}
		keys = append(keys, key)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	final := !now.Before(time.Unix(deleted, 0).Add(deletionGrace))
	for _, key := range keys {
		if err = a.store.remove(ctx, key); err != nil {
			return err
		}
		// Commit progress per object so even a long recording or a short cleanup
		// deadline can finish across retries. Keep the capture tombstone forever.
		if final {
			if _, err = a.db.ExecContext(ctx, "DELETE FROM objects WHERE object_key=?", key); err != nil {
				return err
			}
		}
	}
	return nil
}

func (a *api) cleanDeleted(ctx context.Context, now time.Time) error {
	rows, err := a.db.QueryContext(ctx, "SELECT id FROM captures WHERE deleted_at IS NOT NULL AND EXISTS(SELECT 1 FROM objects WHERE capture_id=captures.id)")
	if err != nil {
		return err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	var lastErr error
	for _, id := range ids {
		deadline, cancel := context.WithTimeout(ctx, 10*time.Second)
		if err = a.cleanCapture(deadline, id, now); err != nil {
			lastErr = err
		}
		cancel()
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	return lastErr
}

func (a *api) cleanDeletedCaptures(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		if err := a.cleanDeleted(ctx, time.Now()); err != nil && ctx.Err() == nil {
			log.Printf("capture cleanup will retry: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
