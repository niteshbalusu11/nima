package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

func openDB(path string) (*sql.DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	// One connection serializes short metadata transactions, including invite redemption.
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
 CREATE TABLE IF NOT EXISTS accounts (
 id TEXT PRIMARY KEY, active INTEGER NOT NULL DEFAULT 1,
 name TEXT NOT NULL DEFAULT '', email TEXT NOT NULL DEFAULT '', signal_username TEXT NOT NULL DEFAULT '',
 created_at INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS invites (
 hash TEXT PRIMARY KEY, account_id TEXT REFERENCES accounts(id), expires_at INTEGER NOT NULL,
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
 PRIMARY KEY (capture_id, sequence));`)
	if err != nil {
		db.Close()
		return nil, err
	}
	if err = os.Chmod(path, 0600); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func secret() string { return base64.RawURLEncoding.EncodeToString(randomBytes(32)) }
func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
func digest(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
func newID() string          { return hex.EncodeToString(randomBytes(16)) }

func issueInvite(db *sql.DB, account string, ttl time.Duration) (string, error) {
	var target any
	if account != "" {
		var active int
		if err := db.QueryRow("SELECT active FROM accounts WHERE id=?", account).Scan(&active); err != nil || active != 1 {
			return "", fmt.Errorf("account is missing or revoked")
		}
		target = account
	}
	token := secret()
	_, err := db.Exec("INSERT INTO invites(hash,account_id,expires_at) VALUES(?,?,?)", digest(token), target, time.Now().Add(ttl).Unix())
	return token, err
}
