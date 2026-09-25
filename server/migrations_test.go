package main

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func databaseVersion(t *testing.T, db *sql.DB) int {
	t.Helper()
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatal(err)
	}
	return version
}

func TestMigrationsFreshAndRepeatStartup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app.sqlite")
	db, err := openDB(path)
	if err != nil {
		t.Fatal(err)
	}
	if databaseVersion(t, db) != len(migrations) {
		t.Fatal("fresh schema not versioned")
	}
	var obsolete int
	if err := db.QueryRow("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('peer_invitations','peer_invitations_pair')").Scan(&obsolete); err != nil || obsolete != 0 {
		t.Fatalf("fresh schema includes removed peer-invitation storage: %d %v", obsolete, err)
	}
	if _, err = db.Exec("INSERT INTO accounts(id,created_at,role) VALUES('kept',0,'admin')"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = openDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var role string
	if err = db.QueryRow("SELECT role FROM accounts WHERE id='kept'").Scan(&role); err != nil || role != "admin" {
		t.Fatalf("repeat startup lost data: %q %v", role, err)
	}
}

func TestMigrationsAdoptCurrentUnversionedDatabase(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "current.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.Exec(migrations[0]); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO accounts(id,created_at) VALUES('existing',0)"); err != nil {
		t.Fatal(err)
	}
	if err = migrate(db, migrations); err != nil {
		t.Fatal(err)
	}
	if databaseVersion(t, db) != len(migrations) {
		t.Fatal("current schema not adopted")
	}
	var id string
	if err = db.QueryRow("SELECT id FROM accounts WHERE id='existing'").Scan(&id); err != nil {
		t.Fatal(err)
	}
}

func TestSuperAdminMigrationPreservesExistingAccountsAndInvites(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "prior.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := migrate(db, migrations[:3]); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO accounts(id,role,name,created_at) VALUES('admin','admin','Existing',1)"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO invites(hash,expires_at,role,created_by) VALUES('invite',9999999999,'member','admin')"); err != nil {
		t.Fatal(err)
	}
	if err := migrate(db, migrations); err != nil {
		t.Fatal(err)
	}
	var role, name string
	var superAdmin bool
	if err := db.QueryRow("SELECT role,name,super_admin FROM accounts WHERE id='admin'").Scan(&role, &name, &superAdmin); err != nil || role != "admin" || name != "Existing" || superAdmin {
		t.Fatalf("account changed during migration: %q %q %t %v", role, name, superAdmin, err)
	}
	if err := db.QueryRow("SELECT role,super_admin FROM invites WHERE hash='invite'").Scan(&role, &superAdmin); err != nil || role != "member" || superAdmin {
		t.Fatalf("invite changed during migration: %q %t %v", role, superAdmin, err)
	}
}

func TestFaceMigrationPreservesExistingCaptures(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "prior-faces.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := migrate(db, migrations[:4]); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO accounts(id,created_at) VALUES('owner',1)"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO captures(id,account_id,kind,created_at) VALUES('capture','owner','photo',1)"); err != nil {
		t.Fatal(err)
	}
	if err := migrate(db, migrations); err != nil {
		t.Fatal(err)
	}
	var kind string
	if err := db.QueryRow("SELECT kind FROM captures WHERE id='capture'").Scan(&kind); err != nil || kind != "photo" {
		t.Fatalf("existing capture changed: %q %v", kind, err)
	}
}

func TestResearchMigrationPreservesLegacyAnonymousFaces(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "prior-research.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := migrate(db, migrations[:5]); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO accounts(id,created_at) VALUES('owner',1)"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO captures(id,account_id,kind,created_at) VALUES('capture','owner','photo',1)"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO face_groups(id,capture_id,embedding,jpeg,first_seen_ms) VALUES('legacy','capture','[]',X'00',0)"); err != nil {
		t.Fatal(err)
	}
	if err := migrate(db, migrations); err != nil {
		t.Fatal(err)
	}
	var version sql.NullString
	if err := db.QueryRow("SELECT model_version FROM face_groups WHERE id='legacy'").Scan(&version); err != nil || version.Valid {
		t.Fatalf("legacy face was changed: %+v %v", version, err)
	}
	if err := migrate(db, migrations); err != nil {
		t.Fatalf("repeat migration: %v", err)
	}
}

func TestMigrationsUpgradeRollbackAndNewerVersion(t *testing.T) {
	db, err := openDB(filepath.Join(t.TempDir(), "upgrade.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.Exec("INSERT INTO accounts(id,created_at,role) VALUES('kept',0,'admin')"); err != nil {
		t.Fatal(err)
	}
	steps := append(append([]string{}, migrations...), "ALTER TABLE accounts ADD COLUMN test_note TEXT NOT NULL DEFAULT '';", "INVALID SQL;")
	if err = migrate(db, steps); err == nil || !strings.Contains(err.Error(), fmt.Sprintf("migration %d", len(migrations)+2)) {
		t.Fatalf("expected migration failure: %v", err)
	}
	if databaseVersion(t, db) != len(migrations) {
		t.Fatal("failed batch advanced schema version")
	}
	if _, err = db.Exec("SELECT test_note FROM accounts"); err == nil {
		t.Fatal("failed batch kept partial schema")
	}
	steps = steps[:len(migrations)+1]
	if err = migrate(db, steps); err != nil {
		t.Fatal(err)
	}
	if databaseVersion(t, db) != len(migrations)+1 {
		t.Fatal("upgrade not versioned")
	}
	var role, note string
	if err = db.QueryRow("SELECT role,test_note FROM accounts WHERE id='kept'").Scan(&role, &note); err != nil || role != "admin" || note != "" {
		t.Fatalf("upgrade did not preserve existing data: %q %q %v", role, note, err)
	}
	if err = migrate(db, steps); err != nil {
		t.Fatalf("upgrade ran twice: %v", err)
	}
	if err = migrate(db, migrations); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Fatalf("old binary accepted newer schema: %v", err)
	}
	if databaseVersion(t, db) != len(migrations)+1 {
		t.Fatal("old binary changed newer schema")
	}
}
