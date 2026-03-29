package cmd

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	"github.com/misaelzapata/fastfn/cli/internal/process"
	"github.com/spf13/cobra"
)

var logsNativeMode bool
var logsDockerMode bool
var logsLines int
var logsNoFollow bool
var logsFile string

type logsBackend string

const (
	logsBackendDocker logsBackend = "docker"
	logsBackendNative logsBackend = "native"
)

var (
	readNativeSessionFn = process.ReadNativeSession
	runNativeLogsFn     = runNativeLogs
	runDockerLogsFn     = runDockerLogs
	chooseLogsBackendFn = chooseLogsBackend
	logsFatal           = log.Fatal
	logsFatalf          = log.Fatalf
)

func chooseLogsBackend(forceNative, forceDocker, nativeAvailable, composeExists bool) (logsBackend, error) {
	if forceNative && forceDocker {
		return "", fmt.Errorf("use either --native or --docker, not both")
	}
	if forceNative {
		if !nativeAvailable {
			return "", fmt.Errorf("native mode selected but no active native session was found")
		}
		return logsBackendNative, nil
	}
	if forceDocker {
		if !composeExists {
			return "", fmt.Errorf("docker mode selected but docker-compose.yml was not found in current directory")
		}
		return logsBackendDocker, nil
	}
	if nativeAvailable {
		return logsBackendNative, nil
	}
	if composeExists {
		return logsBackendDocker, nil
	}
	return "", fmt.Errorf("no active native session and no docker-compose.yml found")
}

func runDockerLogs(composePath string) error {
	dockerCmd := exec.Command("docker", "compose", "-f", composePath, "logs", "-f")
	dockerCmd.Stdout = &logAliasWriter{out: os.Stdout}
	dockerCmd.Stderr = &logAliasWriter{out: os.Stderr}
	dockerCmd.Dir = filepath.Dir(composePath)
	return dockerCmd.Run()
}

func selectedNativeLogFiles(session *process.NativeSession) ([]string, error) {
	if session == nil {
		return nil, fmt.Errorf("native session is required")
	}
	var files []string
	switch logsFile {
	case "all":
		files = append(files, session.ErrorLogPath(), session.AccessLogPath(), session.RuntimeLogPath())
	case "error":
		files = append(files, session.ErrorLogPath())
	case "access":
		files = append(files, session.AccessLogPath())
	case "runtime":
		files = append(files, session.RuntimeLogPath())
	default:
		return nil, fmt.Errorf("invalid --file value %q (use error|access|runtime|all)", logsFile)
	}
	return files, nil
}

func runNativeLogs(session *process.NativeSession) error {
	files, err := selectedNativeLogFiles(session)
	if err != nil {
		return err
	}

	existing := make([]string, 0, len(files))
	for _, p := range files {
		if _, err := os.Stat(p); err == nil {
			existing = append(existing, p)
		}
	}
	if len(existing) == 0 {
		return fmt.Errorf("native log files not found under %s", session.LogsDir)
	}

	args := []string{"-n", strconv.Itoa(logsLines)}
	if !logsNoFollow {
		args = append(args, "-F")
	}
	args = append(args, existing...)

	fmt.Printf("📜 Streaming native logs (%s) from %s\n", logsFile, session.LogsDir)
	tailCmd := exec.Command("tail", args...)
	tailCmd.Stdout = os.Stdout
	tailCmd.Stderr = os.Stderr
	return tailCmd.Run()
}

var logsCmd = &cobra.Command{
	Use:   "logs",
	Short: "View logs from the running stack",
	Long: `Stream logs from a running FastFN stack.

Backend selection:
- Auto: prefers active native session, then Docker Compose.
- --native: force native logs backend.
- --docker: force Docker logs backend.

Native mode reads OpenResty access/error logs plus persisted runtime handler logs.
Docker mode uses 'docker compose logs'.`,
	Example: `  fastfn logs
  fastfn logs --lines 500
  fastfn logs --no-follow
  fastfn logs --native --file error
  fastfn logs --docker`,
	Run: func(cmd *cobra.Command, args []string) {
		composePath := "docker-compose.yml"
		composeExists := false
		if _, err := os.Stat(composePath); err == nil {
			composeExists = true
		} else {
			altComposePath := filepath.Join("..", "docker-compose.yml")
			if _, altErr := os.Stat(altComposePath); altErr == nil {
				composePath = altComposePath
				composeExists = true
			}
		}

		var nativeSession *process.NativeSession
		if s, err := readNativeSessionFn(); err == nil {
			nativeSession = s
		}
		nativeAvailable := nativeSession != nil && nativeSession.IsActive()

		backend, err := chooseLogsBackendFn(logsNativeMode, logsDockerMode, nativeAvailable, composeExists)
		if err != nil {
			logsFatal(err)
		}

		switch backend {
		case logsBackendNative:
			if err := runNativeLogsFn(nativeSession); err != nil {
				logsFatalf("Failed to stream native logs: %v", err)
			}
		case logsBackendDocker:
			if err := runDockerLogsFn(composePath); err != nil {
				logsFatalf("Failed to attach Docker logs: %v", err)
			}
		default:
			logsFatalf("Unknown logs backend: %s", backend)
		}
	},
}

func init() {
	rootCmd.AddCommand(logsCmd)
	logsCmd.Flags().BoolVar(&logsNativeMode, "native", false, "Force native logs backend")
	logsCmd.Flags().BoolVar(&logsDockerMode, "docker", false, "Force Docker logs backend")
	logsCmd.Flags().IntVar(&logsLines, "lines", 200, "Number of recent lines to show")
	logsCmd.Flags().BoolVar(&logsNoFollow, "no-follow", false, "Print current logs and exit (do not follow)")
	logsCmd.Flags().StringVar(&logsFile, "file", "all", "Native log file(s): error|access|runtime|all")
}
