package workloads

import (
	"net"
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
