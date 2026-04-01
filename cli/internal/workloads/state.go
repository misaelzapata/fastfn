package workloads

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type State struct {
	Apps     map[string]AppState     `json:"apps,omitempty"`
	Services map[string]ServiceState `json:"services,omitempty"`
}

type WorkloadDebugSSH struct {
	Host    string `json:"host,omitempty"`
	Port    int    `json:"port,omitempty"`
	User    string `json:"user,omitempty"`
	KeyPath string `json:"key_path,omitempty"`
}

type WorkloadHealth struct {
	Up     bool   `json:"up"`
	Reason string `json:"reason,omitempty"`
}

type AppState struct {
	Name           string            `json:"name"`
	Image          string            `json:"image"`
	ImageDigest    string            `json:"image_digest,omitempty"`
	Host           string            `json:"host"`
	Port           int               `json:"port"`
	BrokerHost     string            `json:"broker_host,omitempty"`
	BrokerPort     int               `json:"broker_port,omitempty"`
	InternalHost   string            `json:"internal_host,omitempty"`
	InternalPort   int               `json:"internal_port"`
	InternalURL    string            `json:"internal_url,omitempty"`
	Routes         []string          `json:"routes,omitempty"`
	ContainerID    string            `json:"container_id,omitempty"`
	Health         WorkloadHealth    `json:"health"`
	Lifecycle      LifecycleSpec     `json:"lifecycle,omitempty"`
	LifecycleState string            `json:"lifecycle_state,omitempty"`
	Paused         bool              `json:"paused,omitempty"`
	ResumeCount    int               `json:"resume_count,omitempty"`
	LastResumeMS   int64             `json:"last_resume_ms,omitempty"`
	FirecrackerPID int               `json:"firecracker_pid,omitempty"`
	Volume         *VolumeSpec       `json:"volume,omitempty"`
	DebugSSH       *WorkloadDebugSSH `json:"debug_ssh,omitempty"`
	Env            map[string]string `json:"env,omitempty"`
}

type ServiceState struct {
	Name           string            `json:"name"`
	Image          string            `json:"image"`
	ImageDigest    string            `json:"image_digest,omitempty"`
	Host           string            `json:"host"`
	Port           int               `json:"port"`
	BrokerHost     string            `json:"broker_host,omitempty"`
	BrokerPort     int               `json:"broker_port,omitempty"`
	InternalHost   string            `json:"internal_host"`
	InternalPort   int               `json:"internal_port"`
	URL            string            `json:"url"`
	InternalURL    string            `json:"internal_url"`
	ContainerID    string            `json:"container_id,omitempty"`
	Health         WorkloadHealth    `json:"health"`
	Lifecycle      LifecycleSpec     `json:"lifecycle,omitempty"`
	LifecycleState string            `json:"lifecycle_state,omitempty"`
	Paused         bool              `json:"paused,omitempty"`
	ResumeCount    int               `json:"resume_count,omitempty"`
	LastResumeMS   int64             `json:"last_resume_ms,omitempty"`
	FirecrackerPID int               `json:"firecracker_pid,omitempty"`
	Volume         *VolumeSpec       `json:"volume,omitempty"`
	DebugSSH       *WorkloadDebugSSH `json:"debug_ssh,omitempty"`
	BaseEnv        map[string]string `json:"-"`
	FunctionEnv    map[string]string `json:"function_env,omitempty"`
}

func WriteState(path string, state State) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create workload state dir: %w", err)
	}
	payload, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal workload state: %w", err)
	}
	if err := os.WriteFile(path, append(payload, '\n'), 0o644); err != nil {
		return fmt.Errorf("write workload state: %w", err)
	}
	return nil
}

func BuildFunctionServiceEnv(serviceName string, service ServiceState, baseEnv map[string]string) map[string]string {
	out := map[string]string{}
	appendScopedServiceEnv(out, serviceName, baseEnv)

	upper := serviceEnvToken(serviceName)
	out["SERVICE_"+upper+"_HOST"] = service.Host
	out["SERVICE_"+upper+"_PORT"] = fmt.Sprintf("%d", service.Port)
	out["SERVICE_"+upper+"_URL"] = service.URL
	out["SERVICE_"+upper+"_INTERNAL_HOST"] = service.InternalHost
	out["SERVICE_"+upper+"_INTERNAL_PORT"] = fmt.Sprintf("%d", service.InternalPort)
	if strings.TrimSpace(service.InternalURL) != "" {
		out["SERVICE_"+upper+"_INTERNAL_URL"] = service.InternalURL
	}
	appendDirectServiceAlias(out, serviceName, service.Host, service.Port, service.URL)

	return out
}

func BuildAppServiceEnv(serviceName string, service ServiceState, baseEnv map[string]string) map[string]string {
	out := cloneEnvMap(baseEnv)
	appendScopedServiceEnv(out, serviceName, service.BaseEnv)

	upper := serviceEnvToken(serviceName)
	internalURL := strings.TrimSpace(service.InternalURL)
	if internalURL == "" {
		internalURL = internalServiceURL(serviceName, service)
	}

	out["SERVICE_"+upper+"_HOST"] = service.InternalHost
	out["SERVICE_"+upper+"_PORT"] = fmt.Sprintf("%d", service.InternalPort)
	out["SERVICE_"+upper+"_URL"] = internalURL
	appendDirectServiceAlias(out, serviceName, service.InternalHost, service.InternalPort, internalURL)

	return out
}

func BuildServiceURL(name string, host string, port int, env map[string]string) string {
	host = strings.TrimSpace(host)
	if host == "" || port < 1 {
		return ""
	}

	scheme, user, pass, db := inferServiceURLParts(env)
	switch scheme {
	case "mysql", "postgres":
		return buildCredentialURL(scheme, host, port, user, pass, db)
	case "redis":
		return fmt.Sprintf("redis://%s:%d/0", host, port)
	}
	return fmt.Sprintf("tcp://%s:%d", host, port)
}

func internalServiceURL(name string, service ServiceState) string {
	return BuildServiceURL(name, service.InternalHost, service.InternalPort, nil)
}

func BuildAppURL(host string, port int, protocol string) string {
	host = strings.TrimSpace(host)
	if host == "" || port < 1 {
		return ""
	}
	scheme := strings.ToLower(strings.TrimSpace(protocol))
	switch scheme {
	case "", "tcp":
		scheme = "http"
	case "http", "https":
	default:
		scheme = "http"
	}
	return fmt.Sprintf("%s://%s:%d", scheme, host, port)
}

func buildCredentialURL(scheme, host string, port int, user, pass, db string) string {
	creds := ""
	if user != "" {
		creds = user
		creds += "@"
	}
	_ = pass
	path := ""
	if db != "" {
		path = "/" + db
	}
	return fmt.Sprintf("%s://%s%s:%d%s", scheme, creds, host, port, path)
}

func appendDirectServiceAlias(out map[string]string, serviceName, host string, port int, url string) {
	token := serviceEnvToken(serviceName)
	if token == "" {
		return
	}
	out[token+"_HOST"] = host
	out[token+"_PORT"] = fmt.Sprintf("%d", port)
	if strings.TrimSpace(url) != "" {
		out[token+"_URL"] = url
	}
}

func inferServiceURLParts(env map[string]string) (scheme string, user string, pass string, db string) {
	if mysqlUser, mysqlPass, mysqlDB, ok := firstCredentialSet(env,
		[][3]string{
			{"MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_DATABASE"},
			{"MARIADB_USER", "MARIADB_PASSWORD", "MARIADB_DATABASE"},
		},
	); ok {
		return "mysql", mysqlUser, mysqlPass, mysqlDB
	}
	if postgresUser, postgresPass, postgresDB, ok := firstCredentialSet(env,
		[][3]string{
			{"POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"},
		},
	); ok {
		return "postgres", postgresUser, postgresPass, postgresDB
	}
	if hasAnyEnv(env, "REDIS_PASSWORD", "REDIS_URL") {
		return "redis", "", "", ""
	}
	return "", "", "", ""
}

func firstCredentialSet(env map[string]string, keysets [][3]string) (user string, pass string, db string, ok bool) {
	for _, keyset := range keysets {
		user = strings.TrimSpace(env[keyset[0]])
		pass = strings.TrimSpace(env[keyset[1]])
		db = strings.TrimSpace(env[keyset[2]])
		if user != "" || pass != "" || db != "" {
			return user, pass, db, true
		}
	}
	return "", "", "", false
}

func hasAnyEnv(env map[string]string, keys ...string) bool {
	for _, key := range keys {
		if strings.TrimSpace(env[key]) != "" {
			return true
		}
	}
	return false
}

func cloneEnvMap(source map[string]string) map[string]string {
	out := map[string]string{}
	for key, value := range source {
		out[key] = value
	}
	return out
}

func appendScopedServiceEnv(out map[string]string, serviceName string, source map[string]string) {
	prefix := "SERVICE_" + serviceEnvToken(serviceName) + "_"
	for key, value := range source {
		scopedKey := normalizeEnvKey(key)
		if scopedKey == "" {
			continue
		}
		out[prefix+scopedKey] = value
	}
}

func serviceEnvToken(raw string) string {
	token := normalizeEnvKey(strings.ReplaceAll(raw, "-", "_"))
	if token == "" {
		return "SERVICE"
	}
	return token
}

func normalizeEnvKey(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	var out strings.Builder
	for _, ch := range raw {
		switch {
		case ch >= 'a' && ch <= 'z':
			out.WriteRune(ch - ('a' - 'A'))
		case ch >= 'A' && ch <= 'Z':
			out.WriteRune(ch)
		case ch >= '0' && ch <= '9':
			out.WriteRune(ch)
		default:
			out.WriteByte('_')
		}
	}
	return strings.Trim(out.String(), "_")
}
