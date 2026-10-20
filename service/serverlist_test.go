package service

import "testing"

func TestNormalizeRemotePanelURLRequiresHTTPS(t *testing.T) {
	t.Setenv("SUI_ALLOW_INSECURE_REMOTE", "")
	if _, err := normalizeRemotePanelURL("http://panel.example/app/"); err == nil {
		t.Fatal("plain HTTP remote panel should be rejected")
	}
}

func TestNormalizeRemotePanelURLRejectsOtherSchemesAndCredentials(t *testing.T) {
	t.Setenv("SUI_ALLOW_INSECURE_REMOTE", "1")
	for _, rawURL := range []string{
		"ftp://panel.example/app/",
		"https://admin:secret@panel.example/app/",
	} {
		if _, err := normalizeRemotePanelURL(rawURL); err == nil {
			t.Fatalf("unsafe remote panel URL should be rejected: %s", rawURL)
		}
	}
}

func TestNormalizeRemotePanelURL(t *testing.T) {
	t.Setenv("SUI_ALLOW_INSECURE_REMOTE", "")
	got, err := normalizeRemotePanelURL(" https://panel.example/app ")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "https://panel.example/app/" {
		t.Fatalf("unexpected normalized URL: %q", got)
	}
}
