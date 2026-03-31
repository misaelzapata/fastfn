package workloads

import (
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type Config struct {
	Apps     []AppSpec     `json:"apps,omitempty"`
	Services []ServiceSpec `json:"services,omitempty"`
}

type VolumeSpec struct {
	Name   string `json:"name"`
	Target string `json:"target,omitempty"`
}

type HealthcheckSpec struct {
	Type       string `json:"type,omitempty"`
	Path       string `json:"path,omitempty"`
	IntervalMS int    `json:"interval_ms,omitempty"`
	TimeoutMS  int    `json:"timeout_ms,omitempty"`
}

type AppSpec struct {
	Name        string            `json:"name"`
	Image       string            `json:"image,omitempty"`
	Dockerfile  string            `json:"dockerfile,omitempty"`
	Port        int               `json:"port"`
	Env         map[string]string `json:"env,omitempty"`
	Command     []string          `json:"command,omitempty"`
	Volume      *VolumeSpec       `json:"volume,omitempty"`
	Healthcheck HealthcheckSpec   `json:"healthcheck,omitempty"`
	Routes      []string          `json:"routes,omitempty"`
	Replicas    int               `json:"replicas,omitempty"`
}

type ServiceSpec struct {
	Name        string            `json:"name"`
	Image       string            `json:"image,omitempty"`
	Dockerfile  string            `json:"dockerfile,omitempty"`
	Port        int               `json:"port"`
	Env         map[string]string `json:"env,omitempty"`
	Command     []string          `json:"command,omitempty"`
	Volume      *VolumeSpec       `json:"volume,omitempty"`
	Healthcheck HealthcheckSpec   `json:"healthcheck,omitempty"`
}

func (c Config) HasWorkloads() bool {
	return len(c.Apps) > 0 || len(c.Services) > 0
}

func NormalizeAppSpecs(raw any) ([]AppSpec, bool, error) {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		return nil, false, nil
	}

	order := make([]string, 0, len(source))
	for name := range source {
		order = append(order, name)
	}
	sort.Strings(order)

	out := make([]AppSpec, 0, len(order))
	for _, name := range order {
		spec, err := normalizeAppSpec(name, source[name])
		if err != nil {
			return nil, false, err
		}
		out = append(out, spec)
	}
	return out, len(out) > 0, nil
}

func NormalizeServiceSpecs(raw any) ([]ServiceSpec, bool, error) {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		return nil, false, nil
	}

	order := make([]string, 0, len(source))
	for name := range source {
		order = append(order, name)
	}
	sort.Strings(order)

	out := make([]ServiceSpec, 0, len(order))
	for _, name := range order {
		spec, err := normalizeServiceSpec(name, source[name])
		if err != nil {
			return nil, false, err
		}
		out = append(out, spec)
	}
	return out, len(out) > 0, nil
}

func normalizeAppSpec(name string, raw any) (AppSpec, error) {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return AppSpec{}, fmt.Errorf("apps.%s must be an object", name)
	}

	spec := AppSpec{
		Name:        name,
		Env:         normalizeEnvMap(cfg["env"]),
		Command:     normalizeCommand(cfg["command"]),
		Healthcheck: normalizeHealthcheck(cfg["healthcheck"]),
		Replicas:    1,
	}
	spec.Image = strings.TrimSpace(toString(cfg["image"]))
	spec.Dockerfile = normalizeOptionalPath(cfg["dockerfile"])
	spec.Port = normalizePort(cfg["port"])
	spec.Routes = normalizeRoutes(cfg["routes"])
	if replicas := normalizePositiveInt(cfg["replicas"]); replicas > 0 {
		spec.Replicas = replicas
	}

	volume, err := normalizeVolume(name, cfg["volume"])
	if err != nil {
		return AppSpec{}, fmt.Errorf("apps.%s volume: %w", name, err)
	}
	spec.Volume = volume

	if err := validateCommonSpec(name, spec.Image, spec.Dockerfile, spec.Port); err != nil {
		return AppSpec{}, fmt.Errorf("apps.%s: %w", name, err)
	}
	if len(spec.Routes) == 0 {
		return AppSpec{}, fmt.Errorf("apps.%s: routes must include at least one public route", name)
	}

	return spec, nil
}

func normalizeServiceSpec(name string, raw any) (ServiceSpec, error) {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return ServiceSpec{}, fmt.Errorf("services.%s must be an object", name)
	}

	spec := ServiceSpec{
		Name:        name,
		Env:         normalizeEnvMap(cfg["env"]),
		Command:     normalizeCommand(cfg["command"]),
		Healthcheck: normalizeHealthcheck(cfg["healthcheck"]),
	}
	spec.Image = strings.TrimSpace(toString(cfg["image"]))
	spec.Dockerfile = normalizeOptionalPath(cfg["dockerfile"])
	spec.Port = normalizePort(cfg["port"])

	volume, err := normalizeVolume(name, cfg["volume"])
	if err != nil {
		return ServiceSpec{}, fmt.Errorf("services.%s volume: %w", name, err)
	}
	spec.Volume = volume

	if err := validateCommonSpec(name, spec.Image, spec.Dockerfile, spec.Port); err != nil {
		return ServiceSpec{}, fmt.Errorf("services.%s: %w", name, err)
	}

	return spec, nil
}

func validateCommonSpec(name, image, dockerfile string, port int) error {
	if !isValidName(name) {
		return fmt.Errorf("invalid name %q", name)
	}
	if strings.TrimSpace(dockerfile) != "" {
		return fmt.Errorf("dockerfile is not supported for Firecracker workloads in this branch; set image to a local Firecracker bundle directory")
	}
	if strings.TrimSpace(image) == "" {
		return fmt.Errorf("must set image to a local Firecracker bundle directory")
	}
	if port < 1 || port > 65535 {
		return fmt.Errorf("port must be between 1 and 65535")
	}
	return nil
}

func isValidName(raw string) bool {
	value := strings.TrimSpace(strings.ToLower(raw))
	if value == "" {
		return false
	}
	for _, ch := range value {
		if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' {
			continue
		}
		return false
	}
	return true
}

func normalizeNamedMap(raw any) (map[string]any, bool) {
	switch typed := raw.(type) {
	case map[string]any:
		if len(typed) == 0 {
			return nil, false
		}
		return typed, true
	case map[any]any:
		out := map[string]any{}
		for key, value := range typed {
			name := strings.TrimSpace(fmt.Sprint(key))
			if name == "" {
				continue
			}
			out[name] = value
		}
		if len(out) == 0 {
			return nil, false
		}
		return out, true
	default:
		return nil, false
	}
}

func normalizeStringMap(raw any) (map[string]any, bool) {
	if raw == nil {
		return nil, false
	}
	switch typed := raw.(type) {
	case map[string]any:
		return typed, true
	case map[any]any:
		out := map[string]any{}
		for key, value := range typed {
			out[strings.TrimSpace(fmt.Sprint(key))] = value
		}
		return out, true
	default:
		return nil, false
	}
}

func normalizeEnvMap(raw any) map[string]string {
	typed, ok := normalizeStringMap(raw)
	if !ok {
		return nil
	}
	out := map[string]string{}
	for key, value := range typed {
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		out[key] = toString(value)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func normalizeOptionalPath(raw any) string {
	value := strings.TrimSpace(toString(raw))
	if value == "" {
		return ""
	}
	return filepath.Clean(value)
}

func normalizeCommand(raw any) []string {
	switch typed := raw.(type) {
	case string:
		fields := strings.Fields(strings.TrimSpace(typed))
		if len(fields) == 0 {
			return nil
		}
		return fields
	case []string:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			item = strings.TrimSpace(item)
			if item != "" {
				out = append(out, item)
			}
		}
		if len(out) == 0 {
			return nil
		}
		return out
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			value := strings.TrimSpace(toString(item))
			if value != "" {
				out = append(out, value)
			}
		}
		if len(out) == 0 {
			return nil
		}
		return out
	default:
		return nil
	}
}

func normalizePort(raw any) int {
	return normalizePositiveInt(raw)
}

func normalizePositiveInt(raw any) int {
	switch typed := raw.(type) {
	case int:
		return typed
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	case string:
		value, err := strconv.Atoi(strings.TrimSpace(typed))
		if err == nil {
			return value
		}
	}
	return 0
}

func normalizeRoutes(raw any) []string {
	var items []string
	switch typed := raw.(type) {
	case string:
		value := normalizeRoute(typed)
		if value != "" {
			items = append(items, value)
		}
	case []string:
		for _, item := range typed {
			value := normalizeRoute(item)
			if value != "" {
				items = append(items, value)
			}
		}
	case []any:
		for _, item := range typed {
			value := normalizeRoute(toString(item))
			if value != "" {
				items = append(items, value)
			}
		}
	}
	if len(items) == 0 {
		return nil
	}
	sort.Strings(items)
	return items
}

func normalizeRoute(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return ""
	}
	if !strings.HasPrefix(value, "/") {
		value = "/" + value
	}
	if value != "/" && strings.HasSuffix(value, "/") && !strings.HasSuffix(value, "/*") {
		value = strings.TrimRight(value, "/")
	}
	return value
}

func normalizeHealthcheck(raw any) HealthcheckSpec {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return HealthcheckSpec{}
	}
	out := HealthcheckSpec{
		Type: strings.ToLower(strings.TrimSpace(toString(cfg["type"]))),
		Path: normalizeRoute(toString(cfg["path"])),
	}
	if out.Type == "" {
		out.Type = "tcp"
	}
	if interval := normalizePositiveInt(cfg["interval_ms"]); interval > 0 {
		out.IntervalMS = interval
	}
	if timeout := normalizePositiveInt(cfg["timeout_ms"]); timeout > 0 {
		out.TimeoutMS = timeout
	}
	return out
}

func normalizeVolume(name string, raw any) (*VolumeSpec, error) {
	switch typed := raw.(type) {
	case nil:
		return nil, nil
	case string:
		volumeName := strings.TrimSpace(typed)
		if volumeName == "" {
			return nil, nil
		}
		target := inferVolumeTarget(name)
		if target == "" {
			return nil, fmt.Errorf("generic string volume requires a known target; use an object with name and target")
		}
		return &VolumeSpec{Name: volumeName, Target: target}, nil
	default:
		cfg, ok := normalizeStringMap(typed)
		if !ok {
			return nil, fmt.Errorf("must be a string or object")
		}
		spec := &VolumeSpec{
			Name:   strings.TrimSpace(toString(cfg["name"])),
			Target: strings.TrimSpace(toString(cfg["target"])),
		}
		if spec.Name == "" {
			return nil, fmt.Errorf("name is required")
		}
		if spec.Target == "" {
			spec.Target = inferVolumeTarget(name)
		}
		if spec.Target == "" {
			return nil, fmt.Errorf("target is required")
		}
		return spec, nil
	}
}

func inferVolumeTarget(name string) string {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "mysql", "mariadb":
		return "/var/lib/mysql"
	case "postgres", "postgresql":
		return "/var/lib/postgresql/data"
	case "redis", "minio":
		return "/data"
	case "rabbitmq":
		return "/var/lib/rabbitmq"
	default:
		return ""
	}
}

func toString(raw any) string {
	switch typed := raw.(type) {
	case string:
		return typed
	case fmt.Stringer:
		return typed.String()
	case nil:
		return ""
	default:
		return fmt.Sprint(raw)
	}
}
