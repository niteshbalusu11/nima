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
	_, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;`)
	if err == nil {
		err = migrate(db, migrations)
	}
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

type invitation struct {
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expires_at"`
}

func issueInvite(db *sql.DB, account string, ttl time.Duration, admin bool, createdBy string) (invitation, error) {
	if admin && (account != "" || createdBy != "") {
		return invitation{}, fmt.Errorf("--admin creates a new admin account through the CLI only")
	}
	role := "member"
	if admin {
		role = "admin"
	}
	var target any
	if account != "" {
		var active int
		if err := db.QueryRow("SELECT active,role FROM accounts WHERE id=?", account).Scan(&active, &role); err != nil || active != 1 {
			return invitation{}, fmt.Errorf("account is missing or revoked")
		}
		target = account
	}
	var issuer any
	if createdBy != "" {
		issuer = createdBy
	}
	invite := invitation{Token: secret(), ExpiresAt: time.Now().Add(ttl).Unix()}
	_, err := db.Exec("INSERT INTO invites(hash,account_id,expires_at,role,created_by) VALUES(?,?,?,?,?)", digest(invite.Token), target, invite.ExpiresAt, role, issuer)
	return invite, err
}

func issueSuperAdminInvite(db *sql.DB, ttl time.Duration) (invitation, error) {
	invite := invitation{Token: secret(), ExpiresAt: time.Now().Add(ttl).Unix()}
	_, err := db.Exec("INSERT INTO invites(hash,expires_at,role,super_admin) VALUES(?,?,'admin',1)", digest(invite.Token), invite.ExpiresAt)
	return invite, err
}
