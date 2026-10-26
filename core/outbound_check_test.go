package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	N "github.com/sagernet/sing/common/network"
)

func TestDownloadThroughOutboundLimitsBytes(t *testing.T) {
	const limit int64 = 32 * 1024
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(strings.Repeat("a", int(limit*2))))
	}))
	defer server.Close()

	read, duration, err := downloadThroughOutbound(context.Background(), server.URL, N.SystemDialer, limit)
	if err != nil {
		t.Fatalf("测速下载失败: %v", err)
	}
	if read != limit {
		t.Fatalf("测速流量限制失效: got %d want %d", read, limit)
	}
	if duration <= 0 {
		t.Fatal("测速耗时必须大于 0")
	}
}

func TestDownloadThroughOutboundRejectsUnsupportedScheme(t *testing.T) {
	_, _, err := downloadThroughOutbound(context.Background(), "file:///etc/passwd", N.SystemDialer, 1024)
	if err == nil {
		t.Fatal("非 HTTP(S) 测速地址应被拒绝")
	}
}
