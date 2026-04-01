package workloads

import (
	"fmt"
	"os"
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
	Device string `json:"device,omitempty"`
}

type HealthcheckSpec struct {
	Type       string `json:"type,omitempty"`
	Path       string `json:"path,omitempty"`
	IntervalMS int    `json:"interval_ms,omitempty"`
	TimeoutMS  int    `json:"timeout_ms,omitempty"`
}

type PortSpec struct {
	Name          string          `json:"name"`
	ContainerPort int             `json:"container_port"`
	Protocol      string          `json:"protocol,omitempty"`
	Public        bool            `json:"public,omitempty"`
	Routes        []string        `json:"routes,omitempty"`
	ListenPort    int             `json:"listen_port,omitempty"`
	Healthcheck   HealthcheckSpec `json:"healthcheck,omitempty"`
}

type ProcessGroupSpec struct {
	Name     string   `json:"name"`
	Command  []string `json:"command,omitempty"`
	Replicas int      `json:"replicas,omitempty"`
}

type HAHooksSpec struct {
	BootstrapPrimary []string `json:"bootstrap_primary,omitempty"`
	BootstrapReplica []string `json:"bootstrap_replica,omitempty"`
	PromoteReplica   []string `json:"promote_replica,omitempty"`
	RejoinReplica    []string `json:"rejoin_replica,omitempty"`
}

type HAConfig struct {
	PrimaryGroup string      `json:"primary_group,omitempty"`
	ReplicaGroup string      `json:"replica_group,omitempty"`
	Hooks        HAHooksSpec `json:"hooks,omitempty"`
}

type LifecycleSpec struct {
	IdleAction   string `json:"idle_action,omitempty"`
	PauseAfterMS int    `json:"pause_after_ms,omitempty"`
	Prewarm      bool   `json:"prewarm,omitempty"`
}

type AppSpec struct {
	Name          string             `json:"name"`
	ScopeDir      string             `json:"scope_dir,omitempty"`
	Image         string             `json:"image,omitempty"`
	ImageFile     string             `json:"image_file,omitempty"`
	Dockerfile    string             `json:"dockerfile,omitempty"`
	Context       string             `json:"context,omitempty"`
	Port          int                `json:"port"`
	Env           map[string]string  `json:"env,omitempty"`
	Command       []string           `json:"command,omitempty"`
	WorkingDir    string             `json:"working_dir,omitempty"`
	User          string             `json:"user,omitempty"`
	Volume        *VolumeSpec        `json:"volume,omitempty"`
	Volumes       []*VolumeSpec      `json:"volumes,omitempty"`
	Healthcheck   HealthcheckSpec    `json:"healthcheck,omitempty"`
	Routes        []string           `json:"routes,omitempty"`
	Replicas      int                `json:"replicas,omitempty"`
	Ports         []PortSpec         `json:"ports,omitempty"`
	ProcessGroups []ProcessGroupSpec `json:"process_groups,omitempty"`
	HA            *HAConfig          `json:"ha,omitempty"`
	Lifecycle     LifecycleSpec      `json:"lifecycle,omitempty"`
}

type ServiceSpec struct {
	Name          string             `json:"name"`
	ScopeDir      string             `json:"scope_dir,omitempty"`
	Image         string             `json:"image,omitempty"`
	ImageFile     string             `json:"image_file,omitempty"`
	Dockerfile    string             `json:"dockerfile,omitempty"`
	Context       string             `json:"context,omitempty"`
	Port          int                `json:"port"`
	Env           map[string]string  `json:"env,omitempty"`
	Command       []string           `json:"command,omitempty"`
	WorkingDir    string             `json:"working_dir,omitempty"`
	User          string             `json:"user,omitempty"`
	Volume        *VolumeSpec        `json:"volume,omitempty"`
	Volumes       []*VolumeSpec      `json:"volumes,omitempty"`
	Healthcheck   HealthcheckSpec    `json:"healthcheck,omitempty"`
	Routes        []string           `json:"routes,omitempty"`
	Ports         []PortSpec         `json:"ports,omitempty"`
	ProcessGroups []ProcessGroupSpec `json:"process_groups,omitempty"`
	HA            *HAConfig          `json:"ha,omitempty"`
	Lifecycle     LifecycleSpec      `json:"lifecycle,omitempty"`
}

func (c Config) HasWorkloads() bool {
	return len(c.Apps) > 0 || len(c.Services) > 0
}

func NormalizeAppSpecs(raw any) ([]AppSpec, bool, error) {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		return nil, false, nil
	}
	out, err := normalizeNamedApps("", "", source)
	if err != nil {
		return nil, false, err
	}
	return out, len(out) > 0, nil
}

func NormalizeServiceSpecs(raw any) ([]ServiceSpec, bool, error) {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		return nil, false, nil
	}
	out, err := normalizeNamedServices("", "", source)
	if err != nil {
		return nil, false, err
	}
	return out, len(out) > 0, nil
}

func NormalizeConfigMap(baseDir string, raw map[string]any) (Config, bool, error) {
	return normalizeConfigMap(baseDir, filepath.Base(filepath.Clean(baseDir)), raw)
}

func normalizeConfigMap(baseDir, impliedName string, raw map[string]any) (Config, bool, error) {
	var cfg Config
	if len(raw) == 0 {
		return cfg, false, nil
	}

	if appsRaw, ok := raw["apps"]; ok {
		apps, err := normalizeNamedApps(baseDir, "", appsRaw)
		if err != nil {
			return cfg, false, err
		}
		cfg.Apps = append(cfg.Apps, apps...)
	}
	if servicesRaw, ok := raw["services"]; ok {
		services, err := normalizeNamedServices(baseDir, "", servicesRaw)
		if err != nil {
			return cfg, false, err
		}
		cfg.Services = append(cfg.Services, services...)
	}
	if appRaw, ok := raw["app"]; ok {
		if strings.TrimSpace(impliedName) == "" {
			return cfg, false, fmt.Errorf("app requires an implied workload name")
		}
		app, err := normalizeAppSpec(baseDir, impliedName, appRaw)
		if err != nil {
			return cfg, false, fmt.Errorf("app: %w", err)
		}
		cfg.Apps = append(cfg.Apps, app)
	}
	if serviceRaw, ok := raw["service"]; ok {
		if strings.TrimSpace(impliedName) == "" {
			return cfg, false, fmt.Errorf("service requires an implied workload name")
		}
		service, err := normalizeServiceSpec(baseDir, impliedName, serviceRaw)
		if err != nil {
			return cfg, false, fmt.Errorf("service: %w", err)
		}
		cfg.Services = append(cfg.Services, service)
	}

	if err := validateDuplicateSpecs(cfg); err != nil {
		return cfg, false, err
	}
	return cfg, cfg.HasWorkloads(), nil
}

func validateDuplicateSpecs(cfg Config) error {
	seenApps := map[string]bool{}
	for _, spec := range cfg.Apps {
		name := strings.ToLower(strings.TrimSpace(spec.Name))
		if seenApps[name] {
			return fmt.Errorf("duplicate app %q", spec.Name)
		}
		seenApps[name] = true
	}
	seenServices := map[string]bool{}
	for _, spec := range cfg.Services {
		name := strings.ToLower(strings.TrimSpace(spec.Name))
		if seenServices[name] {
			return fmt.Errorf("duplicate service %q", spec.Name)
		}
		seenServices[name] = true
	}
	return nil
}

func normalizeNamedApps(baseDir, _ string, raw any) ([]AppSpec, error) {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		return nil, fmt.Errorf("apps must be an object")
	}
	order := make([]string, 0, len(source))
	for name := range source {
		order = append(order, name)
	}
	sort.Strings(order)

	out := make([]AppSpec, 0, len(order))
	for _, name := range order {
		spec, err := normalizeAppSpec(baseDir, name, source[name])
		if err != nil {
			return nil, fmt.Errorf("apps.%s: %w", name, err)
		}
		out = append(out, spec)
	}
	return out, nil
}

func normalizeNamedServices(baseDir, _ string, raw any) ([]ServiceSpec, error) {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		return nil, fmt.Errorf("services must be an object")
	}
	order := make([]string, 0, len(source))
	for name := range source {
		order = append(order, name)
	}
	sort.Strings(order)

	out := make([]ServiceSpec, 0, len(order))
	for _, name := range order {
		spec, err := normalizeServiceSpec(baseDir, name, source[name])
		if err != nil {
			return nil, fmt.Errorf("services.%s: %w", name, err)
		}
		out = append(out, spec)
	}
	return out, nil
}

func normalizeAppSpec(baseDir, name string, raw any) (AppSpec, error) {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return AppSpec{}, fmt.Errorf("must be an object")
	}

	spec := AppSpec{
		Name:        name,
		ScopeDir:    normalizeScopeDir(baseDir),
		Env:         normalizeEnvMap(cfg["env"]),
		Command:     normalizeCommand(cfg["command"]),
		WorkingDir:  strings.TrimSpace(toString(cfg["working_dir"])),
		User:        strings.TrimSpace(toString(cfg["user"])),
		Healthcheck: normalizeHealthcheck(cfg["healthcheck"]),
		Replicas:    1,
	}
	if err := populateSourceFields(baseDir, cfg, &spec.Image, &spec.ImageFile, &spec.Dockerfile, &spec.Context); err != nil {
		return AppSpec{}, err
	}
	volumes, err := normalizeVolumes(name, cfg["volumes"], cfg["volume"])
	if err != nil {
		return AppSpec{}, fmt.Errorf("volumes: %w", err)
	}
	spec.Volumes = volumes
	spec.Volume = firstVolume(volumes)

	spec.ProcessGroups = normalizeProcessGroups(cfg["process_groups"], spec.Command, normalizePositiveInt(cfg["replicas"]))
	spec.HA, err = normalizeHA(cfg["ha"])
	if err != nil {
		return AppSpec{}, fmt.Errorf("ha: %w", err)
	}
	spec.Lifecycle = normalizeLifecycle(cfg["lifecycle"], defaultAppLifecycle())

	ports, legacyPort, legacyRoutes, legacyHealth, err := normalizePorts(name, cfg, true)
	if err != nil {
		return AppSpec{}, err
	}
	spec.Ports = ports
	spec.Port = legacyPort
	spec.Routes = legacyRoutes
	if spec.Healthcheck == (HealthcheckSpec{}) {
		spec.Healthcheck = legacyHealth
	}
	spec.Replicas = replicasFromGroups(spec.ProcessGroups)

	if err := validateCommonSpec(name, spec.Image, spec.ImageFile, spec.Dockerfile, spec.Context, spec.Ports, spec.ProcessGroups, spec.HA, spec.Lifecycle); err != nil {
		return AppSpec{}, err
	}
	if spec.Port < 1 || len(spec.Routes) == 0 {
		return AppSpec{}, fmt.Errorf("must expose at least one public HTTP port with routes")
	}
	return spec, nil
}

func normalizeServiceSpec(baseDir, name string, raw any) (ServiceSpec, error) {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return ServiceSpec{}, fmt.Errorf("must be an object")
	}

	spec := ServiceSpec{
		Name:        name,
		ScopeDir:    normalizeScopeDir(baseDir),
		Env:         normalizeEnvMap(cfg["env"]),
		Command:     normalizeCommand(cfg["command"]),
		WorkingDir:  strings.TrimSpace(toString(cfg["working_dir"])),
		User:        strings.TrimSpace(toString(cfg["user"])),
		Healthcheck: normalizeHealthcheck(cfg["healthcheck"]),
	}
	if err := populateSourceFields(baseDir, cfg, &spec.Image, &spec.ImageFile, &spec.Dockerfile, &spec.Context); err != nil {
		return ServiceSpec{}, err
	}
	volumes, err := normalizeVolumes(name, cfg["volumes"], cfg["volume"])
	if err != nil {
		return ServiceSpec{}, fmt.Errorf("volumes: %w", err)
	}
	spec.Volumes = volumes
	spec.Volume = firstVolume(volumes)

	spec.ProcessGroups = normalizeProcessGroups(cfg["process_groups"], spec.Command, 1)
	spec.HA, err = normalizeHA(cfg["ha"])
	if err != nil {
		return ServiceSpec{}, fmt.Errorf("ha: %w", err)
	}
	spec.Lifecycle = normalizeLifecycle(cfg["lifecycle"], defaultServiceLifecycle())

	ports, legacyPort, legacyRoutes, legacyHealth, err := normalizePorts(name, cfg, false)
	if err != nil {
		return ServiceSpec{}, err
	}
	spec.Ports = ports
	spec.Port = legacyPort
	spec.Routes = legacyRoutes
	if spec.Healthcheck == (HealthcheckSpec{}) {
		spec.Healthcheck = legacyHealth
	}

	if err := validateCommonSpec(name, spec.Image, spec.ImageFile, spec.Dockerfile, spec.Context, spec.Ports, spec.ProcessGroups, spec.HA, spec.Lifecycle); err != nil {
		return ServiceSpec{}, err
	}
	if spec.Port < 1 {
		return ServiceSpec{}, fmt.Errorf("must define at least one port")
	}
	return spec, nil
}

func populateSourceFields(baseDir string, cfg map[string]any, image, imageFile, dockerfile, context *string) error {
	*image = normalizeLocalRef(baseDir, strings.TrimSpace(toString(cfg["image"])))
	*imageFile = normalizePathRef(baseDir, cfg["image_file"])
	*dockerfile = normalizePathRef(baseDir, cfg["dockerfile"])
	*context = normalizePathRef(baseDir, cfg["context"])
	if *dockerfile != "" && *context == "" {
		*context = filepath.Dir(*dockerfile)
	}
	return nil
}

func validateCommonSpec(name, image, imageFile, dockerfile, context string, ports []PortSpec, groups []ProcessGroupSpec, ha *HAConfig, lifecycle LifecycleSpec) error {
	if !isValidName(name) {
		return fmt.Errorf("invalid name %q", name)
	}
	sourceCount := 0
	for _, value := range []string{image, imageFile, dockerfile} {
		if strings.TrimSpace(value) != "" {
			sourceCount++
		}
	}
	if sourceCount != 1 {
		return fmt.Errorf("must set exactly one image source among image, image_file or dockerfile")
	}
	if strings.TrimSpace(context) != "" && strings.TrimSpace(dockerfile) == "" {
		return fmt.Errorf("context is only supported together with dockerfile")
	}
	if len(ports) == 0 {
		return fmt.Errorf("must define at least one port")
	}
	for _, port := range ports {
		if !isValidName(port.Name) {
			return fmt.Errorf("invalid port name %q", port.Name)
		}
		if port.ContainerPort < 1 || port.ContainerPort > 65535 {
			return fmt.Errorf("port %q must be between 1 and 65535", port.Name)
		}
		protocol := normalizedProtocol(port.Protocol)
		if protocol == "" {
			return fmt.Errorf("port %q has unsupported protocol %q", port.Name, port.Protocol)
		}
		if port.Public && protocol != "http" && (port.ListenPort < 1 || port.ListenPort > 65535) {
			return fmt.Errorf("port %q: public tcp exposure requires listen_port", port.Name)
		}
	}
	if len(groups) == 0 {
		return fmt.Errorf("must define at least one process group")
	}
	for _, group := range groups {
		if !isValidName(group.Name) {
			return fmt.Errorf("invalid process group %q", group.Name)
		}
		if group.Replicas < 1 {
			return fmt.Errorf("process group %q replicas must be >= 1", group.Name)
		}
	}
	if ha != nil {
		if ha.PrimaryGroup != "" && !isValidName(ha.PrimaryGroup) {
			return fmt.Errorf("ha.primary_group is invalid")
		}
		if ha.ReplicaGroup != "" && !isValidName(ha.ReplicaGroup) {
			return fmt.Errorf("ha.replica_group is invalid")
		}
	}
	switch lifecycle.IdleAction {
	case "", "run", "pause":
	default:
		return fmt.Errorf("lifecycle.idle_action must be run or pause")
	}
	if lifecycle.PauseAfterMS < 0 {
		return fmt.Errorf("lifecycle.pause_after_ms must be >= 0")
	}
	return nil
}

func normalizePorts(workloadName string, cfg map[string]any, isApp bool) ([]PortSpec, int, []string, HealthcheckSpec, error) {
	if rawPorts, ok := cfg["ports"]; ok && rawPorts != nil {
		ports, err := normalizeNamedPorts(rawPorts)
		if err != nil {
			return nil, 0, nil, HealthcheckSpec{}, fmt.Errorf("ports: %w", err)
		}
		legacyPort, routes, health, err := selectLegacyPortFields(ports, isApp)
		if err != nil {
			return nil, 0, nil, HealthcheckSpec{}, err
		}
		return ports, legacyPort, routes, health, nil
	}

	port := normalizePort(cfg["port"])
	if port < 1 {
		return nil, 0, nil, HealthcheckSpec{}, fmt.Errorf("port must be between 1 and 65535")
	}
	routes := normalizeRoutes(cfg["routes"])
	health := normalizeHealthcheck(cfg["healthcheck"])
	protocol := "tcp"
	public := false
	if len(routes) > 0 {
		protocol = "http"
		public = true
	} else if strings.EqualFold(health.Type, "http") {
		protocol = "http"
	}
	ports := []PortSpec{{
		Name:          "default",
		ContainerPort: port,
		Protocol:      protocol,
		Public:        public,
		Routes:        routes,
		Healthcheck:   health,
	}}
	if isApp && len(routes) == 0 {
		return nil, 0, nil, HealthcheckSpec{}, fmt.Errorf("must expose at least one public HTTP port with routes")
	}
	return ports, port, routes, health, nil
}

func normalizeNamedPorts(raw any) ([]PortSpec, error) {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		return nil, fmt.Errorf("must be an object")
	}
	order := make([]string, 0, len(source))
	for name := range source {
		order = append(order, name)
	}
	sort.Strings(order)

	out := make([]PortSpec, 0, len(order))
	for _, name := range order {
		cfg, ok := normalizeStringMap(source[name])
		if !ok {
			return nil, fmt.Errorf("%s must be an object", name)
		}
		spec := PortSpec{
			Name:          name,
			ContainerPort: normalizePositiveInt(cfg["container_port"]),
			Protocol:      normalizedProtocol(toString(cfg["protocol"])),
			Healthcheck:   normalizeHealthcheck(cfg["healthcheck"]),
		}
		exposeCfg, exposeSet := normalizeStringMap(cfg["expose"])
		if exposeSet {
			spec.Public = normalizeBool(exposeCfg["public"])
			spec.Routes = normalizeRoutes(exposeCfg["routes"])
			spec.ListenPort = normalizePositiveInt(exposeCfg["listen_port"])
		}
		if !exposeSet {
			spec.Public = normalizeBool(cfg["public"])
			spec.Routes = normalizeRoutes(cfg["routes"])
			spec.ListenPort = normalizePositiveInt(cfg["listen_port"])
		}
		if spec.Protocol == "" {
			if spec.Public && len(spec.Routes) > 0 {
				spec.Protocol = "http"
			} else if strings.EqualFold(spec.Healthcheck.Type, "http") {
				spec.Protocol = "http"
			} else {
				spec.Protocol = "tcp"
			}
		}
		out = append(out, spec)
	}
	return out, nil
}

func selectLegacyPortFields(ports []PortSpec, isApp bool) (int, []string, HealthcheckSpec, error) {
	if len(ports) == 0 {
		return 0, nil, HealthcheckSpec{}, fmt.Errorf("must define at least one port")
	}
	if !isApp {
		first := ports[0]
		return first.ContainerPort, first.Routes, first.Healthcheck, nil
	}

	for _, port := range ports {
		if port.Public && port.Protocol == "http" && len(port.Routes) > 0 {
			return port.ContainerPort, port.Routes, port.Healthcheck, nil
		}
	}
	return 0, nil, HealthcheckSpec{}, fmt.Errorf("must expose at least one public HTTP port with routes")
}

func normalizeProcessGroups(raw any, fallbackCommand []string, defaultReplicas int) []ProcessGroupSpec {
	source, ok := normalizeNamedMap(raw)
	if !ok {
		if defaultReplicas < 1 {
			defaultReplicas = 1
		}
		return []ProcessGroupSpec{{
			Name:     "default",
			Command:  append([]string{}, fallbackCommand...),
			Replicas: defaultReplicas,
		}}
	}

	order := make([]string, 0, len(source))
	for name := range source {
		order = append(order, name)
	}
	sort.Strings(order)

	out := make([]ProcessGroupSpec, 0, len(order))
	for _, name := range order {
		cfg, ok := normalizeStringMap(source[name])
		if !ok {
			continue
		}
		replicas := normalizePositiveInt(cfg["replicas"])
		if replicas < 1 {
			replicas = 1
		}
		command := normalizeCommand(cfg["command"])
		if len(command) == 0 {
			command = append([]string{}, fallbackCommand...)
		}
		out = append(out, ProcessGroupSpec{
			Name:     name,
			Command:  command,
			Replicas: replicas,
		})
	}
	if len(out) == 0 {
		return []ProcessGroupSpec{{
			Name:     "default",
			Command:  append([]string{}, fallbackCommand...),
			Replicas: maxInt(defaultReplicas, 1),
		}}
	}
	return out
}

func normalizeHA(raw any) (*HAConfig, error) {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return nil, nil
	}
	ha := &HAConfig{
		PrimaryGroup: strings.TrimSpace(toString(cfg["primary_group"])),
		ReplicaGroup: strings.TrimSpace(toString(cfg["replica_group"])),
	}
	if hooks, ok := normalizeStringMap(cfg["hooks"]); ok {
		ha.Hooks = HAHooksSpec{
			BootstrapPrimary: normalizeCommand(hooks["bootstrap_primary"]),
			BootstrapReplica: normalizeCommand(hooks["bootstrap_replica"]),
			PromoteReplica:   normalizeCommand(hooks["promote_replica"]),
			RejoinReplica:    normalizeCommand(hooks["rejoin_replica"]),
		}
	}
	return ha, nil
}

func defaultAppLifecycle() LifecycleSpec {
	return LifecycleSpec{
		IdleAction:   "run",
		PauseAfterMS: 15000,
		Prewarm:      true,
	}
}

func defaultServiceLifecycle() LifecycleSpec {
	return LifecycleSpec{
		IdleAction:   "run",
		PauseAfterMS: 0,
		Prewarm:      true,
	}
}

func normalizeLifecycle(raw any, defaults LifecycleSpec) LifecycleSpec {
	cfg, ok := normalizeStringMap(raw)
	if !ok {
		return defaults
	}
	out := defaults
	if idleAction := strings.ToLower(strings.TrimSpace(toString(cfg["idle_action"]))); idleAction != "" {
		out.IdleAction = idleAction
	}
	if pauseAfter := normalizePositiveInt(cfg["pause_after_ms"]); pauseAfter > 0 {
		out.PauseAfterMS = pauseAfter
	}
	if _, exists := cfg["prewarm"]; exists {
		out.Prewarm = normalizeBool(cfg["prewarm"])
	}
	return out
}

func normalizeVolumes(workloadName string, rawVolumes any, rawVolume any) ([]*VolumeSpec, error) {
	if rawVolumes != nil {
		source, ok := normalizeNamedMap(rawVolumes)
		if !ok {
			return nil, fmt.Errorf("must be an object")
		}
		order := make([]string, 0, len(source))
		for name := range source {
			order = append(order, name)
		}
		sort.Strings(order)

		out := make([]*VolumeSpec, 0, len(order))
		for _, name := range order {
			volume, err := normalizeVolume(workloadName, name, source[name])
			if err != nil {
				return nil, err
			}
			out = append(out, volume)
		}
		return out, nil
	}

	volume, err := normalizeLegacyVolume(workloadName, rawVolume)
	if err != nil {
		return nil, err
	}
	if volume == nil {
		return nil, nil
	}
	return []*VolumeSpec{volume}, nil
}

func normalizeVolume(workloadName, volumeKey string, raw any) (*VolumeSpec, error) {
	switch typed := raw.(type) {
	case string:
		target := strings.TrimSpace(typed)
		if target == "" {
			return nil, fmt.Errorf("volumes.%s target is required", volumeKey)
		}
		return &VolumeSpec{
			Name:   strings.TrimSpace(workloadName + "-" + volumeKey),
			Target: target,
		}, nil
	default:
		cfg, ok := normalizeStringMap(raw)
		if !ok {
			return nil, fmt.Errorf("volumes.%s must be a string or object", volumeKey)
		}
		spec := &VolumeSpec{
			Name:   strings.TrimSpace(toString(cfg["name"])),
			Target: strings.TrimSpace(toString(cfg["target"])),
		}
		if spec.Name == "" {
			spec.Name = strings.TrimSpace(workloadName + "-" + volumeKey)
		}
		if spec.Target == "" {
			return nil, fmt.Errorf("volumes.%s target is required", volumeKey)
		}
		return spec, nil
	}
}

func normalizeLegacyVolume(name string, raw any) (*VolumeSpec, error) {
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

func normalizePathRef(baseDir string, raw any) string {
	value := strings.TrimSpace(toString(raw))
	if value == "" {
		return ""
	}
	if filepath.IsAbs(value) {
		return filepath.Clean(value)
	}
	if baseDir == "" {
		return filepath.Clean(value)
	}
	return filepath.Clean(filepath.Join(baseDir, value))
}

func normalizeLocalRef(baseDir, raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if filepath.IsAbs(raw) {
		return filepath.Clean(raw)
	}
	if baseDir != "" {
		candidate := filepath.Join(baseDir, raw)
		if _, err := os.Stat(candidate); err == nil {
			return filepath.Clean(candidate)
		}
	}
	return raw
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

func normalizeBool(raw any) bool {
	switch typed := raw.(type) {
	case bool:
		return typed
	case string:
		value := strings.TrimSpace(strings.ToLower(typed))
		return value == "1" || value == "true" || value == "yes" || value == "on"
	default:
		return false
	}
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
		Type: normalizedProtocol(toString(cfg["type"])),
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

func normalizedProtocol(raw string) string {
	value := strings.ToLower(strings.TrimSpace(raw))
	switch value {
	case "", "tcp":
		return "tcp"
	case "http":
		return "http"
	default:
		return ""
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

func normalizeScopeDir(baseDir string) string {
	if strings.TrimSpace(baseDir) == "" {
		return ""
	}
	return filepath.Clean(baseDir)
}

func replicasFromGroups(groups []ProcessGroupSpec) int {
	total := 0
	for _, group := range groups {
		total += maxInt(group.Replicas, 1)
	}
	if total < 1 {
		return 1
	}
	return total
}

func firstVolume(volumes []*VolumeSpec) *VolumeSpec {
	if len(volumes) == 0 {
		return nil
	}
	return volumes[0]
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
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
