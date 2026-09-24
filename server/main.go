package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/skip2/go-qrcode"
)

func env(key, fallback string) string {
	if s := os.Getenv(key); s != "" {
		return s
	}
	return fallback
}
func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func run() error {
	syscall.Umask(0077)
	command := "serve"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	if command == "init-bucket" {
		if os.Getenv("APP_ENV") != "development" {
			return fmt.Errorf("init-bucket is local-development only")
		}
		store, err := newS3()
		if err != nil {
			return err
		}
		if _, err = store.client.HeadBucket(context.Background(), &s3.HeadBucketInput{Bucket: aws.String(store.bucket)}); err == nil {
			return nil
		}
		_, err = store.client.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(store.bucket)})
		return err
	}
	db, err := openDB(env("DATABASE_PATH", "data/app.sqlite"))
	if err != nil {
		return err
	}
	defer db.Close()
	switch command {
	case "invite":
		flags := flag.NewFlagSet("invite", flag.ExitOnError)
		account := flags.String("account", "", "existing account for a replacement device")
		admin := flags.Bool("admin", false, "invite a new admin; cannot be combined with --account")
		out := flags.String("out", "invite.png", "private QR image path")
		textOut := flags.String("text-out", "", "optional private file containing QR text, for local testing")
		ttl := flags.Duration("ttl", 24*time.Hour, "invite lifetime")
		_ = flags.Parse(os.Args[2:])
		if *ttl <= 0 {
			return fmt.Errorf("ttl must be positive")
		}
		invite, err := issueInvite(db, *account, *ttl, *admin, "")
		if err != nil {
			return err
		}
		if err = qrcode.WriteFile("uploadvideo:invite:"+invite.Token, qrcode.Medium, 512, *out); err != nil {
			return err
		}
		if *textOut != "" {
			f, e := os.OpenFile(*textOut, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if e != nil {
				return e
			}
			_, e = f.WriteString("uploadvideo:invite:" + invite.Token)
			closeErr := f.Close()
			if e != nil {
				return e
			}
			if closeErr != nil {
				return closeErr
			}
		}
		fmt.Printf("Invite QR written to %s (expires in %s)\n", *out, *ttl)
		return nil
	case "accounts":
		rows, e := db.Query("SELECT id,name,active,role FROM accounts ORDER BY created_at DESC")
		if e != nil {
			return e
		}
		defer rows.Close()
		for rows.Next() {
			var id, name, role string
			var active bool
			if e = rows.Scan(&id, &name, &active, &role); e != nil {
				return e
			}
			fmt.Printf("%s  role=%s  active=%t  %s\n", id, role, active, name)
		}
		return rows.Err()
	case "revoke":
		flags := flag.NewFlagSet("revoke", flag.ExitOnError)
		account := flags.String("account", "", "account ID")
		session := flags.String("session-hash", "", "session hash")
		_ = flags.Parse(os.Args[2:])
		if (*account == "") == (*session == "") {
			return fmt.Errorf("specify exactly one of --account or --session-hash")
		}
		if *account != "" {
			_, err = db.Exec("UPDATE accounts SET active=0 WHERE id=?", *account)
		} else {
			_, err = db.Exec("UPDATE sessions SET revoked=1 WHERE hash=?", *session)
		}
		return err
	case "backup":
		flags := flag.NewFlagSet("backup", flag.ExitOnError)
		out := flags.String("out", "backup.sqlite", "new backup file path")
		_ = flags.Parse(os.Args[2:])
		_, err = db.Exec("VACUUM INTO ?", *out)
		return err
	case "serve":
		store, err := newS3()
		if err != nil {
			return err
		}
		app := &api{db: db, store: store}
		srv := &http.Server{Addr: env("LISTEN_ADDR", "127.0.0.1:8080"), Handler: app.handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		go app.cleanDeletedCaptures(ctx)
		go func() {
			<-ctx.Done()
			deadline, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = srv.Shutdown(deadline)
		}()
		log.Printf("API listening on %s", srv.Addr)
		if err = srv.ListenAndServe(); err != http.ErrServerClosed {
			return err
		}
		return nil
	default:
		return fmt.Errorf("commands: serve, invite, accounts, revoke, backup, init-bucket")
	}
}
