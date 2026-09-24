package main

import (
	"database/sql"
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
	if databaseVersion(t, db) != 1 {
		t.Fatal("current schema not adopted")
	}
	var id string
	if err = db.QueryRow("SELECT id FROM accounts WHERE id='existing'").Scan(&id); err != nil {
		t.Fatal(err)
	}
}

func TestMigrationsUpgradeRollbackAndNewerVersion(t *testing.T) {
	db, err := openDB(filepath.Join(t.TempDir(), "upgrade.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	steps := append(append([]string{}, migrations...), "ALTER TABLE accounts ADD COLUMN test_note TEXT NOT NULL DEFAULT '';", "INVALID SQL;")
	if err = migrate(db, steps); err == nil || !strings.Contains(err.Error(), "migration 3") {
		t.Fatalf("expected migration failure: %v", err)
	}
	if databaseVersion(t, db) != 1 {
		t.Fatal("failed batch advanced schema version")
	}
	if _, err = db.Exec("SELECT test_note FROM accounts"); err == nil {
		t.Fatal("failed batch kept partial schema")
	}
	steps = steps[:2]
	if err = migrate(db, steps); err != nil {
		t.Fatal(err)
	}
	if databaseVersion(t, db) != 2 {
		t.Fatal("upgrade not versioned")
	}
	if err = migrate(db, steps); err != nil {
		t.Fatalf("upgrade ran twice: %v", err)
	}
	if err = migrate(db, migrations); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Fatalf("old binary accepted newer schema: %v", err)
	}
	if databaseVersion(t, db) != 2 {
		t.Fatal("old binary changed newer schema")
	}
}
