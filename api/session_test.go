package api

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/cookie"
	"github.com/gin-gonic/gin"
)

func loginCookieHeader(t *testing.T, useTLS bool) string {
	t.Helper()
	gin.SetMode(gin.TestMode)

	router := gin.New()
	store := cookie.NewStore([]byte("0123456789abcdef0123456789abcdef"))
	router.Use(sessions.Sessions("s-ui", store))
	router.GET("/login-test", func(c *gin.Context) {
		if err := SetLoginUser(c, "test-user", 0); err != nil {
			t.Fatalf("SetLoginUser() error = %v", err)
		}
		c.Status(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/login-test", nil)
	if useTLS {
		req.TLS = &tls.ConnectionState{}
	}
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	return recorder.Header().Get("Set-Cookie")
}

func TestLoginCookieSupportsDirectHTTPPanel(t *testing.T) {
	header := loginCookieHeader(t, false)
	for _, expected := range []string{"s-ui=", "Path=/", "HttpOnly", "SameSite=Lax"} {
		if !strings.Contains(header, expected) {
			t.Fatalf("Set-Cookie = %q, want %q", header, expected)
		}
	}
	if strings.Contains(header, "Secure") {
		t.Fatalf("HTTP Set-Cookie must not contain Secure: %q", header)
	}
}

func TestLoginCookieUsesSecureOnHTTPS(t *testing.T) {
	header := loginCookieHeader(t, true)
	for _, expected := range []string{"HttpOnly", "Secure", "SameSite=Lax"} {
		if !strings.Contains(header, expected) {
			t.Fatalf("Set-Cookie = %q, want %q", header, expected)
		}
	}
}
