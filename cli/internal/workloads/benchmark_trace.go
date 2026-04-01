package workloads

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

type benchmarkTrace struct {
	enabled bool
	kind    string
	name    string
	started time.Time
}

func newBenchmarkTrace(kind, name string) benchmarkTrace {
	value := strings.ToLower(strings.TrimSpace(os.Getenv("FN_BENCHMARK_TIMINGS")))
	enabled := value == "1" || value == "true" || value == "yes" || value == "on"
	return benchmarkTrace{
		enabled: enabled,
		kind:    kind,
		name:    name,
		started: time.Now(),
	}
}

func (t benchmarkTrace) log(event string, fields map[string]any) {
	if !t.enabled {
		return
	}
	var builder strings.Builder
	builder.WriteString("fastfn benchmark ")
	builder.WriteString(strings.TrimSpace(event))
	builder.WriteString(" kind=")
	builder.WriteString(strings.TrimSpace(t.kind))
	builder.WriteString(" name=")
	builder.WriteString(strings.TrimSpace(t.name))
	builder.WriteString(" elapsed_ms=")
	builder.WriteString(fmt.Sprintf("%d", time.Since(t.started).Milliseconds()))
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		builder.WriteString(" ")
		builder.WriteString(strings.TrimSpace(key))
		builder.WriteString("=")
		builder.WriteString(strings.TrimSpace(fmt.Sprint(fields[key])))
	}
	fmt.Fprintln(os.Stdout, builder.String())
}
