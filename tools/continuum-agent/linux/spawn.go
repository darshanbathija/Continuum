package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func prepareWorkspace(dataDir, repoKey string, useWorktree, isHandoff bool) (string, error) {
	safe := strings.NewReplacer("/", "_", "\\", "_", " ", "_").Replace(repoKey)
	base := filepath.Join(dataDir, "workspaces", safe)
	if err := os.MkdirAll(base, 0o755); err != nil {
		return "", err
	}
	if isHandoff {
		// Handoff path: workspace already synced via git push; ensure dir exists.
		return base, nil
	}
	if _, err := os.Stat(filepath.Join(base, ".git")); err == nil {
		return base, nil
	}
	// Clone if git available and repoKey looks like a remote URL or path with .git
	if strings.Contains(repoKey, "://") || strings.HasSuffix(repoKey, ".git") {
		if _, err := exec.LookPath("git"); err == nil {
			cmd := exec.Command("git", "clone", "--depth", "1", repoKey, base)
			cmd.Env = os.Environ()
			if out, err := cmd.CombinedOutput(); err != nil {
				return "", fmt.Errorf("git clone: %s", strings.TrimSpace(string(out)))
			}
			return base, nil
		}
	}
	// Local path or handoff resume: use directory as-is.
	if info, err := os.Stat(repoKey); err == nil && info.IsDir() {
		return repoKey, nil
	}
	return base, nil
}

// startAgentProcess launches a detached background runner so work continues
// when the SSH session or Mac client disconnects (R1: Mac sleep / VPS keeps going).
func startAgentProcess(workDir, agent, sessionID string) error {
	runner := filepath.Join(workDir, ".continuum-runner-"+sessionID[:8]+".sh")
	script := fmt.Sprintf(`#!/bin/sh
cd %q
# Stub agent runner — keeps session alive until stopped.
# Replace with claude/codex/opencode when installed on the host.
while true; do sleep 3600; done
`, workDir)
	if err := os.WriteFile(runner, []byte(script), 0o755); err != nil {
		return err
	}
	logPath := filepath.Join(workDir, ".continuum-agent-"+sessionID[:8]+".log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	cmd := exec.Command("nohup", "sh", runner)
	cmd.Dir = workDir
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.Env = append(os.Environ(), "CONTINUUM_AGENT="+agent, "CONTINUUM_SESSION="+sessionID)
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	_ = logFile.Close()
	_ = cmd.Process.Release()
	return nil
}
