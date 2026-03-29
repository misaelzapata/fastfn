package cmd

import (
	"github.com/misaelzapata/fastfn/cli/internal/process"
)

var runNativeRunner = process.RunNative

func runNative(userFnDir string) error {
	return runNativeRunner(process.RunConfig{
		FnDir:     userFnDir,
		HotReload: true,
		VerifyTLS: false,
		Watch:     true,
	})
}
