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
