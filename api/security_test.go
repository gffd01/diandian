package api

import "testing"

func resetLoginAttempts() {
	loginAttempts.Lock()
	loginAttempts.byIP = make(map[string]loginAttempt)
	loginAttempts.Unlock()
}

func TestLoginRateLimit(t *testing.T) {
	resetLoginAttempts()
	ip := "192.0.2.10"
	for i := 0; i < loginFailureLimit; i++ {
		if !loginAllowed(ip) {
			t.Fatalf("attempt %d was blocked too early", i+1)
		}
		recordLoginResult(ip, false)
	}
	if loginAllowed(ip) {
		t.Fatal("IP should be blocked after the failure limit")
	}
}

func TestSuccessfulLoginClearsFailures(t *testing.T) {
	resetLoginAttempts()
	ip := "192.0.2.20"
	recordLoginResult(ip, false)
	recordLoginResult(ip, true)
	if !loginAllowed(ip) {
		t.Fatal("successful login should clear prior failures")
	}
}
