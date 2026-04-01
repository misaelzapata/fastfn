package workloads

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

func effectiveHealthcheck(spec HealthcheckSpec) HealthcheckSpec {
	out := spec
	if out.Type == "" {
		out.Type = "tcp"
	}
	if out.IntervalMS <= 0 {
		out.IntervalMS = 1000
	}
	if out.TimeoutMS <= 0 {
		out.TimeoutMS = 1000
	}
	return out
}

func waitForEndpoint(host string, port int, check HealthcheckSpec, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		var err error
		switch strings.ToLower(strings.TrimSpace(check.Type)) {
		case "http":
			err = checkHTTP(host, port, check)
		default:
			err = checkTCP(host, port, check)
		}
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return err
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func checkTCP(host string, port int, check HealthcheckSpec) error {
	timeout := time.Duration(check.TimeoutMS) * time.Millisecond
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", host, port), timeout)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := conn.SetReadDeadline(time.Now().Add(minDuration(timeout, 250*time.Millisecond))); err != nil {
		return err
	}
	var probe [1]byte
	_, err = conn.Read(probe[:])
	switch {
	case err == nil:
		return nil
	case err == io.EOF:
		return fmt.Errorf("connection closed immediately")
	case isTimeoutError(err):
		return nil
	default:
		return err
	}
}

func checkHTTP(host string, port int, check HealthcheckSpec) error {
	timeout := time.Duration(check.TimeoutMS) * time.Millisecond
	path := check.Path
	if path == "" {
		path = "/"
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(fmt.Sprintf("http://%s:%d%s", host, port, path))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 500 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func isTimeoutError(err error) bool {
	netErr, ok := err.(net.Error)
	return ok && netErr.Timeout()
}

func minDuration(a, b time.Duration) time.Duration {
	if a <= 0 {
		return b
	}
	if a < b {
		return a
	}
	return b
}

func sanitizeName(raw string) string {
	value := strings.ToLower(strings.TrimSpace(raw))
	if value == "" {
		return "workload"
	}
	var out strings.Builder
	for _, ch := range value {
		if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' {
			out.WriteRune(ch)
			continue
		}
		out.WriteByte('-')
	}
	return strings.Trim(out.String(), "-")
}
