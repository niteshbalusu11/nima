package main

import (
	"context"
	"database/sql"
	"fmt"
)

// Append migrations; never edit or reorder an applied migration.
// Version 1 adopts the current prerelease schema as well as creating fresh databases.
var migrations = []string{`
CREATE TABLE IF NOT EXISTS accounts (
 id TEXT PRIMARY KEY, active INTEGER NOT NULL DEFAULT 1,
 role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member','admin')),
 name TEXT NOT NULL DEFAULT '', email TEXT NOT NULL DEFAULT '', signal_username TEXT NOT NULL DEFAULT '',
 created_at INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS invites (
 hash TEXT PRIMARY KEY, account_id TEXT REFERENCES accounts(id), expires_at INTEGER NOT NULL,
 role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member','admin')),
 created_by TEXT REFERENCES accounts(id),
 consumed_at INTEGER);
 CREATE TABLE IF NOT EXISTS sessions (
 hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
 revoked INTEGER NOT NULL DEFAULT 0);
 CREATE TABLE IF NOT EXISTS captures (
 id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), kind TEXT NOT NULL,
 created_at INTEGER NOT NULL, finished INTEGER NOT NULL DEFAULT 0);
 CREATE INDEX IF NOT EXISTS captures_owner ON captures(account_id, created_at);
 CREATE TABLE IF NOT EXISTS objects (
 capture_id TEXT NOT NULL REFERENCES captures(id), sequence INTEGER NOT NULL, kind TEXT NOT NULL,
 object_key TEXT NOT NULL UNIQUE, sha256 TEXT NOT NULL, md5 TEXT NOT NULL, size INTEGER NOT NULL,
 duration REAL NOT NULL, start_time REAL NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY (capture_id, sequence));
`, `
ALTER TABLE captures ADD COLUMN deleted_at INTEGER;
CREATE INDEX captures_deleted ON captures(deleted_at) WHERE deleted_at IS NOT NULL;
`, `
ALTER TABLE captures ADD COLUMN latitude REAL;
ALTER TABLE captures ADD COLUMN longitude REAL;
ALTER TABLE captures ADD COLUMN horizontal_accuracy_m REAL;
ALTER TABLE captures ADD COLUMN location_timestamp INTEGER;
	`,
	`
ALTER TABLE accounts ADD COLUMN super_admin INTEGER NOT NULL DEFAULT 0 CHECK(super_admin IN (0,1));
ALTER TABLE invites ADD COLUMN super_admin INTEGER NOT NULL DEFAULT 0 CHECK(super_admin IN (0,1));
`,
	`
CREATE TABLE face_jobs (
 capture_id TEXT NOT NULL REFERENCES captures(id), sequence INTEGER NOT NULL,
 processed_at INTEGER NOT NULL, PRIMARY KEY(capture_id, sequence));
CREATE TABLE face_groups (
 id TEXT PRIMARY KEY, capture_id TEXT NOT NULL REFERENCES captures(id),
 embedding TEXT NOT NULL, jpeg BLOB NOT NULL, first_seen_ms INTEGER NOT NULL,
 sightings INTEGER NOT NULL DEFAULT 1);
CREATE INDEX face_groups_capture ON face_groups(capture_id, first_seen_ms);
`,
	`
CREATE TABLE devices (
 id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
 signing_public_key TEXT NOT NULL UNIQUE, tls_public_key TEXT NOT NULL UNIQUE,
 created_at INTEGER NOT NULL, revoked_at INTEGER);
CREATE INDEX devices_account ON devices(account_id);
ALTER TABLE sessions ADD COLUMN device_id TEXT REFERENCES devices(id);
CREATE TABLE device_challenges (
 session_hash TEXT PRIMARY KEY REFERENCES sessions(hash), nonce TEXT NOT NULL,
 signing_public_key TEXT NOT NULL, tls_public_key TEXT NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE peer_approvals (
 id TEXT PRIMARY KEY, sender_device_id TEXT NOT NULL REFERENCES devices(id),
 recipient_device_id TEXT NOT NULL REFERENCES devices(id), created_at INTEGER NOT NULL,
 revoked_at INTEGER, CHECK(sender_device_id != recipient_device_id));
CREATE UNIQUE INDEX peer_approvals_active ON peer_approvals(sender_device_id,recipient_device_id) WHERE revoked_at IS NULL;
CREATE INDEX peer_approvals_recipient ON peer_approvals(recipient_device_id);
`,
	`
ALTER TABLE captures ADD COLUMN owner_metadata_pending INTEGER NOT NULL DEFAULT 0 CHECK(owner_metadata_pending IN (0,1));
CREATE TABLE shared_captures (
 capture_id TEXT PRIMARY KEY REFERENCES captures(id), recorder_device_id TEXT NOT NULL REFERENCES devices(id),
 descriptor_payload TEXT NOT NULL, descriptor_signature TEXT NOT NULL,
 completion_payload TEXT, completion_signature TEXT);
CREATE TABLE relay_grants (
 id TEXT PRIMARY KEY, capture_id TEXT NOT NULL REFERENCES shared_captures(capture_id),
 approval_id TEXT NOT NULL REFERENCES peer_approvals(id),
 payload TEXT NOT NULL, signature TEXT NOT NULL);
CREATE INDEX relay_grants_capture ON relay_grants(capture_id);
CREATE TABLE shared_object_records (
 capture_id TEXT NOT NULL, sequence INTEGER NOT NULL, payload TEXT NOT NULL, signature TEXT NOT NULL,
 PRIMARY KEY(capture_id,sequence),
 FOREIGN KEY(capture_id,sequence) REFERENCES objects(capture_id,sequence) ON DELETE CASCADE);
CREATE TABLE relay_grant_objects (
 grant_id TEXT NOT NULL REFERENCES relay_grants(id), capture_id TEXT NOT NULL, sequence INTEGER NOT NULL,
 PRIMARY KEY(grant_id,sequence),
 FOREIGN KEY(capture_id,sequence) REFERENCES objects(capture_id,sequence) ON DELETE CASCADE);
`,
	`
CREATE TABLE nearby_authority (id INTEGER PRIMARY KEY CHECK(id=1), seed BLOB NOT NULL CHECK(length(seed)=32));
`,
	`
ALTER TABLE face_groups ADD COLUMN model_version TEXT;
CREATE TABLE face_research_captures (
 capture_id TEXT PRIMARY KEY REFERENCES captures(id),
 confirmed_by TEXT NOT NULL REFERENCES accounts(id), confirmed_at INTEGER NOT NULL);
CREATE TABLE face_people (
 id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
 reference_group_id TEXT NOT NULL UNIQUE REFERENCES face_groups(id),
 display_name TEXT NOT NULL, consent_confirmed_by TEXT NOT NULL REFERENCES accounts(id),
 consent_confirmed_at INTEGER NOT NULL);
CREATE INDEX face_people_account ON face_people(account_id);
`,
}

// Run before serving requests. The write lock also serializes startup with CLI commands.
// A failure rolls back the entire pending batch; the process must not serve an older schema.
func migrate(db *sql.DB, steps []string) error {
	ctx := context.Background()
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err = conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fmt.Errorf("begin migrations: %w", err)
	}
	defer conn.ExecContext(ctx, "ROLLBACK")
	var version int
	if err = conn.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version > len(steps) {
		return fmt.Errorf("database version %d is newer than supported version %d", version, len(steps))
	}
	for i := version; i < len(steps); i++ {
		if _, err = conn.ExecContext(ctx, steps[i]); err != nil {
			return fmt.Errorf("migration %d: %w", i+1, err)
		}
		if _, err = conn.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", i+1)); err != nil {
			return err
		}
	}
	_, err = conn.ExecContext(ctx, "COMMIT")
	return err
}
