package service

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/alireza0/s-ui/database"
	"github.com/alireza0/s-ui/database/model"
)

func TestGetOrCreateTokenIsScopedAndReusable(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "s-ui-test.db")
	if err := database.InitDB(dbPath); err != nil {
		t.Fatalf("initialize test database: %v", err)
	}

	users := UserService{}
	if err := users.UpdateFirstUser("alice", "alice-password"); err != nil {
		t.Fatalf("update first user: %v", err)
	}
	if err := database.GetDB().Create(&model.User{Username: "bob", Password: "unused"}).Error; err != nil {
		t.Fatalf("create second user: %v", err)
	}

	permanentInstall, err := users.AddToken("alice", 0, "install")
	if err != nil {
		t.Fatalf("create permanent alice token: %v", err)
	}
	aliceInstall, err := users.GetOrCreateToken("alice", "install", 30)
	if err != nil {
		t.Fatalf("create alice install token: %v", err)
	}
	if aliceInstall == permanentInstall {
		t.Fatal("a finite request must not reuse a permanent token")
	}
	aliceInstallAgain, err := users.GetOrCreateToken("alice", "install", 30)
	if err != nil {
		t.Fatalf("reuse alice install token: %v", err)
	}
	if aliceInstallAgain != aliceInstall {
		t.Fatal("same user and purpose should reuse the existing valid token")
	}

	aliceOther, err := users.GetOrCreateToken("alice", "other", 30)
	if err != nil {
		t.Fatalf("create alice token for another purpose: %v", err)
	}
	if aliceOther == aliceInstall {
		t.Fatal("different token purposes must not share a token")
	}

	bobInstall, err := users.GetOrCreateToken("bob", "install", 30)
	if err != nil {
		t.Fatalf("create bob install token: %v", err)
	}
	if bobInstall == aliceInstall {
		t.Fatal("different users must not share a token")
	}

	var stored model.Tokens
	if err := database.GetDB().Where("token = ?", aliceInstall).First(&stored).Error; err != nil {
		t.Fatalf("load stored token: %v", err)
	}
	if stored.Expiry <= time.Now().Unix() {
		t.Fatal("time-limited installer token should have a future expiry")
	}
}
