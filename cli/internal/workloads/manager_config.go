package workloads

type ManagerConfig struct {
	ProjectDir string
	StatePath  string
	Apps       []AppSpec
	Services   []ServiceSpec
}
