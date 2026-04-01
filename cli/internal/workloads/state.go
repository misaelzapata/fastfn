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

type WorkloadHealth struct {
	Up     bool   `json:"up"`
	Reason string `json:"reason,omitempty"`
}

type AppState struct {
	Name         string            `json:"name"`
	Image        string            `json:"image"`
	ImageDigest  string            `json:"image_digest,omitempty"`
	Host         string            `json:"host"`
	Port         int               `json:"port"`
	InternalHost string            `json:"internal_host,omitempty"`
	InternalPort int               `json:"internal_port"`
	InternalURL  string            `json:"internal_url,omitempty"`
	Routes       []string          `json:"routes,omitempty"`
	ContainerID  string            `json:"container_id,omitempty"`
	Health       WorkloadHealth    `json:"health"`
	Volume       *VolumeSpec       `json:"volume,omitempty"`
	Env          map[string]string `json:"env,omitempty"`
}

type ServiceState struct {
	Name         string            `json:"name"`
	Image        string            `json:"image"`
	ImageDigest  string            `json:"image_digest,omitempty"`
	Host         string            `json:"host"`
	Port         int               `json:"port"`
	InternalHost string            `json:"internal_host"`
	InternalPort int               `json:"internal_port"`
	URL          string            `json:"url"`
	InternalURL  string            `json:"internal_url"`
	ContainerID  string            `json:"container_id,omitempty"`
	Health       WorkloadHealth    `json:"health"`
	Volume       *VolumeSpec       `json:"volume,omitempty"`
	BaseEnv      map[string]string `json:"-"`
	FunctionEnv  map[string]string `json:"function_env,omitempty"`
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
	out := cloneEnvMap(baseEnv)
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

	switch strings.ToLower(serviceName) {
	case "mysql":
		out["MYSQL_HOST"] = service.Host
		out["MYSQL_PORT"] = fmt.Sprintf("%d", service.Port)
		out["MYSQL_URL"] = service.URL
	case "postgres", "postgresql":
		out["POSTGRES_HOST"] = service.Host
		out["POSTGRES_PORT"] = fmt.Sprintf("%d", service.Port)
		out["POSTGRES_URL"] = service.URL
	case "redis":
		out["REDIS_HOST"] = service.Host
		out["REDIS_PORT"] = fmt.Sprintf("%d", service.Port)
		out["REDIS_URL"] = service.URL
	}

	return out
}

func BuildAppServiceEnv(serviceName string, service ServiceState, baseEnv map[string]string) map[string]string {
	out := cloneEnvMap(baseEnv)
	for key, value := range service.BaseEnv {
		out[key] = value
	}
	appendScopedServiceEnv(out, serviceName, service.BaseEnv)

	upper := serviceEnvToken(serviceName)
	internalURL := strings.TrimSpace(service.InternalURL)
	if internalURL == "" {
		internalURL = internalServiceURL(serviceName, service)
	}

	out["SERVICE_"+upper+"_HOST"] = service.InternalHost
	out["SERVICE_"+upper+"_PORT"] = fmt.Sprintf("%d", service.InternalPort)
	out["SERVICE_"+upper+"_URL"] = internalURL

	switch strings.ToLower(serviceName) {
	case "mysql":
		out["MYSQL_HOST"] = service.InternalHost
		out["MYSQL_PORT"] = fmt.Sprintf("%d", service.InternalPort)
		out["MYSQL_URL"] = internalURL
	case "postgres", "postgresql":
		out["POSTGRES_HOST"] = service.InternalHost
		out["POSTGRES_PORT"] = fmt.Sprintf("%d", service.InternalPort)
		out["POSTGRES_URL"] = internalURL
	case "redis":
		out["REDIS_HOST"] = service.InternalHost
		out["REDIS_PORT"] = fmt.Sprintf("%d", service.InternalPort)
		out["REDIS_URL"] = internalURL
	}

	return out
}

func BuildServiceURL(name string, host string, port int, env map[string]string) string {
	host = strings.TrimSpace(host)
	if host == "" || port < 1 {
		return ""
	}

	switch strings.ToLower(strings.TrimSpace(name)) {
	case "mysql":
		user := strings.TrimSpace(env["MYSQL_USER"])
		pass := strings.TrimSpace(env["MYSQL_PASSWORD"])
		db := strings.TrimSpace(env["MYSQL_DATABASE"])
		return buildCredentialURL("mysql", host, port, user, pass, db)
	case "postgres", "postgresql":
		user := strings.TrimSpace(env["POSTGRES_USER"])
		pass := strings.TrimSpace(env["POSTGRES_PASSWORD"])
		db := strings.TrimSpace(env["POSTGRES_DB"])
		return buildCredentialURL("postgres", host, port, user, pass, db)
	case "redis":
		return fmt.Sprintf("redis://%s:%d/0", host, port)
	default:
		return fmt.Sprintf("tcp://%s:%d", host, port)
	}
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
