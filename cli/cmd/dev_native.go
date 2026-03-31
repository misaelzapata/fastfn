package cmd

import (
	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/misaelzapata/fastfn/cli/internal/workloads"
)

var runNativeRunner = process.RunNative

func runNative(projectDir, userFnDir string, imageWorkloads workloads.Config) error {
	return runNativeRunner(process.RunConfig{
		ProjectDir: projectDir,
		FnDir:      userFnDir,
		HotReload:  true,
		VerifyTLS:  false,
		Watch:      true,
		Workloads:  imageWorkloads,
	})
}
