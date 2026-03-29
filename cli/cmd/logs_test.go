package cmd

import "testing"

func TestChooseLogsBackend(t *testing.T) {
	tests := []struct {
		name            string
		forceNative     bool
		forceDocker     bool
		nativeAvailable bool
		composeExists   bool
		want            logsBackend
		wantErr         bool
	}{
		{
			name:            "auto picks native when available",
			nativeAvailable: true,
			composeExists:   true,
			want:            logsBackendNative,
		},
		{
			name:          "auto falls back to docker",
			composeExists: true,
			want:          logsBackendDocker,
		},
		{
			name:            "forced native works",
			forceNative:     true,
			nativeAvailable: true,
			want:            logsBackendNative,
		},
		{
			name:          "forced docker works",
			forceDocker:   true,
			composeExists: true,
			want:          logsBackendDocker,
		},
		{
			name:        "forced native fails without session",
			forceNative: true,
			wantErr:     true,
		},
		{
			name:        "forced docker fails without compose",
			forceDocker: true,
			wantErr:     true,
		},
		{
			name:        "invalid when both forced",
			forceNative: true,
			forceDocker: true,
			wantErr:     true,
		},
		{
			name:    "auto fails when none available",
			wantErr: true,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got, err := chooseLogsBackend(tc.forceNative, tc.forceDocker, tc.nativeAvailable, tc.composeExists)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got backend=%q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("backend mismatch: want=%q got=%q", tc.want, got)
			}
		})
	}
}
