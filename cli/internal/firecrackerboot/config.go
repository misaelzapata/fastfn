package firecrackerboot

type Config struct {
	Version          int               `json:"version"`
	Kind             string            `json:"kind,omitempty"`
	Name             string            `json:"name,omitempty"`
	ProcessGroup     string            `json:"process_group,omitempty"`
	Replica          int               `json:"replica,omitempty"`
	Port             int               `json:"port,omitempty"`
	Command          []string          `json:"command,omitempty"`
	Env              map[string]string `json:"env,omitempty"`
	WorkingDir       string            `json:"working_dir,omitempty"`
	User             string            `json:"user,omitempty"`
	ControlGuestPort int               `json:"control_guest_port,omitempty"`
	InboundPorts     []InboundPort     `json:"inbound_ports,omitempty"`
	Services         []ServiceBinding  `json:"services,omitempty"`
	Volumes          []VolumeMount     `json:"volumes,omitempty"`
	HA               HAConfig          `json:"ha,omitempty"`
}

type InboundPort struct {
	Name          string `json:"name"`
	Protocol      string `json:"protocol,omitempty"`
	GuestPort     int    `json:"guest_port"`
	ContainerPort int    `json:"container_port"`
}

type ServiceBinding struct {
	Name      string `json:"name"`
	LocalHost string `json:"local_host,omitempty"`
	LocalIP   string `json:"local_ip,omitempty"`
	LocalPort int    `json:"local_port"`
	VsockPort int    `json:"vsock_port"`
	URL       string `json:"url,omitempty"`
}

type VolumeMount struct {
	Name   string `json:"name"`
	Target string `json:"target"`
	Device string `json:"device"`
}

type HAConfig struct {
	Mode string `json:"mode,omitempty"`
}
