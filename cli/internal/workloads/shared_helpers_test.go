package workloads

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestCheckTCP_RejectsImmediateClose(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer ln.Close()

	go func() {
		conn, err := ln.Accept()
		if err == nil {
			_ = conn.Close()
		}
	}()

	addr := ln.Addr().(*net.TCPAddr)
	err = checkTCP("127.0.0.1", addr.Port, HealthcheckSpec{TimeoutMS: 500})
	if err == nil {
		t.Fatalf("checkTCP() error = nil, want immediate close failure")
	}
}

func TestCheckTCP_AllowsIdleOpenConnection(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer ln.Close()

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		time.Sleep(400 * time.Millisecond)
	}()

	addr := ln.Addr().(*net.TCPAddr)
	if err := checkTCP("127.0.0.1", addr.Port, HealthcheckSpec{TimeoutMS: 100}); err != nil {
		t.Fatalf("checkTCP() error = %v", err)
	}
}

func TestWaitForEndpointStable_RequiresContinuousHealthyWindow(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch hits.Add(1) {
		case 1:
			w.WriteHeader(http.StatusOK)
		case 2:
			http.Error(w, "warming", http.StatusServiceUnavailable)
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer server.Close()

	hostPort := strings.TrimPrefix(server.URL, "http://")
	host, portRaw, err := net.SplitHostPort(hostPort)
	if err != nil {
		t.Fatalf("SplitHostPort() error = %v", err)
	}
	port, err := strconv.Atoi(portRaw)
	if err != nil {
		t.Fatalf("Atoi() error = %v", err)
	}

	err = waitForEndpointStable(host, port, HealthcheckSpec{
		Type:      "http",
		Path:      "/",
		TimeoutMS: 100,
	}, 2*time.Second, 350*time.Millisecond)
	if err != nil {
		t.Fatalf("waitForEndpointStable() error = %v", err)
	}
	if hits.Load() < 5 {
		t.Fatalf("hits = %d, want >= 5 to prove the stability window reset after failure", hits.Load())
	}
}
