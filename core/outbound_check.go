package core

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/sagernet/sing-box/adapter"
	urltest "github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/ntp"
)

const checkTimeout = 15 * time.Second
const speedCheckTimeout = 30 * time.Second
const defaultSpeedTestURL = "https://speed.cloudflare.com/__down?bytes=10485760"
const defaultSpeedTestBytes int64 = 5 * 1024 * 1024
const minSpeedTestBytes int64 = 1 * 1024 * 1024
const maxSpeedTestBytes int64 = 10 * 1024 * 1024

type CheckOutboundResult struct {
	OK           bool
	Delay        uint16
	DownloadMbps float64
	Bytes        int64
	DurationMs   int64
	Error        string
}

func CheckOutbound(ctx context.Context, tag string, link string) (result CheckOutboundResult) {
	if outbound_manager == nil {
		result.Error = "core not running"
		return result
	}
	ob, ok := outbound_manager.Outbound(tag)
	if !ok {
		result.Error = "outbound not found"
		return result
	}

	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()

	delay, err := urltest.URLTest(ctx, link, ob)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.OK = true
	result.Delay = delay
	return result
}

// CheckOutboundSpeed 通过指定出站下载少量数据，测量真实吞吐量。
// 测试量被严格限制，避免控制面板的一次点击消耗大量服务器流量。
func CheckOutboundSpeed(ctx context.Context, tag string, link string, maxBytes int64) (result CheckOutboundResult) {
	if outbound_manager == nil {
		result.Error = "core not running"
		return result
	}
	ob, ok := outbound_manager.Outbound(tag)
	if !ok {
		result.Error = "outbound not found"
		return result
	}
	if link == "" {
		link = defaultSpeedTestURL
	}
	if maxBytes < minSpeedTestBytes {
		maxBytes = defaultSpeedTestBytes
	}
	if maxBytes > maxSpeedTestBytes {
		maxBytes = maxSpeedTestBytes
	}

	ctx, cancel := context.WithTimeout(ctx, speedCheckTimeout)
	defer cancel()

	delay, err := urltest.URLTest(ctx, "", ob)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.Delay = delay

	bytesRead, duration, err := downloadThroughOutbound(ctx, link, ob, maxBytes)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.OK = true
	result.Bytes = bytesRead
	result.DurationMs = duration.Milliseconds()
	if duration > 0 {
		result.DownloadMbps = float64(bytesRead*8) / duration.Seconds() / 1_000_000
	}
	return result
}

func downloadThroughOutbound(ctx context.Context, link string, dialer N.Dialer, maxBytes int64) (int64, time.Duration, error) {
	linkURL, err := url.Parse(link)
	if err != nil {
		return 0, 0, err
	}
	if linkURL.Scheme != "http" && linkURL.Scheme != "https" {
		return 0, 0, fmt.Errorf("speed test URL must use http or https")
	}

	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp", M.ParseSocksaddr(addr))
		},
		TLSClientConfig: &tls.Config{
			Time:    ntp.TimeFuncFromContext(ctx),
			RootCAs: adapter.RootPoolFromContext(ctx),
		},
		DisableCompression: true,
	}
	client := &http.Client{Transport: transport, Timeout: C.TCPTimeout}
	defer client.CloseIdleConnections()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, link, nil)
	if err != nil {
		return 0, 0, err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", maxBytes-1))
	resp, err := client.Do(req)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		return 0, 0, fmt.Errorf("speed test returned HTTP %d", resp.StatusCode)
	}

	start := time.Now()
	bytesRead, err := io.Copy(io.Discard, io.LimitReader(resp.Body, maxBytes))
	duration := time.Since(start)
	if err != nil {
		return bytesRead, duration, err
	}
	if bytesRead == 0 {
		return 0, duration, fmt.Errorf("speed test returned no data")
	}
	return bytesRead, duration, nil
}
