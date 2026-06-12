package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type workspaceSpec struct {
	RepoKey         string
	SourceRemoteURL string
	SourceBranch    string
	SourceCommit    string
	UseWorktree     bool
	IsHandoff       bool
}

type processStart struct {
	PID      int
	LogPath  string
	TmuxName string
}

func prepareWorkspace(dataDir string, spec workspaceSpec) (string, error) {
	repoKey := strings.TrimSpace(spec.RepoKey)
	remoteURL := strings.TrimSpace(spec.SourceRemoteURL)
	safeKey := repoKey
	if remoteURL != "" {
		safeKey = remoteURL
	}
	safe := safePathComponent(safeKey)
	base := filepath.Join(dataDir, "workspaces", safe)
	if err := os.MkdirAll(filepath.Dir(base), 0o755); err != nil {
		return "", err
	}
	if remoteURL != "" {
		return ensureGitWorkspace(base, remoteURL, spec.SourceBranch, spec.SourceCommit)
	}
	if _, err := os.Stat(filepath.Join(base, ".git")); err == nil {
		return base, nil
	}
	// Clone if git available and repoKey looks like a remote URL or path with .git
	if strings.Contains(repoKey, "://") || strings.HasSuffix(repoKey, ".git") {
		return ensureGitWorkspace(base, repoKey, spec.SourceBranch, spec.SourceCommit)
	}
	// Local path or handoff resume: use directory as-is.
	if info, err := os.Stat(repoKey); err == nil && info.IsDir() {
		return repoKey, nil
	}
	if spec.IsHandoff {
		return "", fmt.Errorf("handoff requires sourceRemoteURL or an existing local repo on this host")
	}
	return "", fmt.Errorf("repo %q is not present on this host; pass sourceRemoteURL for remote execution", repoKey)
}

func safePathComponent(value string) string {
	safe := strings.NewReplacer("/", "_", "\\", "_", " ", "_", ":", "_", "@", "_").Replace(value)
	safe = strings.Trim(safe, "._-")
	if safe == "" {
		return "repo"
	}
	if len(safe) > 120 {
		safe = safe[len(safe)-120:]
	}
	return safe
}

func ensureGitWorkspace(base, remoteURL, branch, commit string) (string, error) {
	git, err := exec.LookPath("git")
	if err != nil {
		return "", fmt.Errorf("git is required to prepare remote workspace: %w", err)
	}
	if _, err := os.Stat(filepath.Join(base, ".git")); err != nil {
		if err := os.MkdirAll(base, 0o755); err != nil {
			return "", err
		}
		args := []string{"clone"}
		if branch != "" {
			args = append(args, "--branch", branch)
		}
		args = append(args, remoteURL, base)
		if out, err := runGit(git, "", args...); err != nil {
			return "", fmt.Errorf("git clone: %s", strings.TrimSpace(string(out)))
		}
	} else {
		if out, err := runGit(git, base, "remote", "set-url", "origin", remoteURL); err != nil {
			return "", fmt.Errorf("git remote set-url: %s", strings.TrimSpace(string(out)))
		}
		fetchRef := branch
		if fetchRef == "" {
			fetchRef = "HEAD"
		}
		if out, err := runGit(git, base, "fetch", "--prune", "origin", fetchRef); err != nil {
			return "", fmt.Errorf("git fetch: %s", strings.TrimSpace(string(out)))
		}
	}
	if branch != "" {
		if out, err := runGit(git, base, "checkout", "-B", branch, "origin/"+branch); err != nil {
			if out2, err2 := runGit(git, base, "checkout", branch); err2 != nil {
				return "", fmt.Errorf("git checkout: %s %s", strings.TrimSpace(string(out)), strings.TrimSpace(string(out2)))
			}
		}
	}
	if commit != "" {
		if out, err := runGit(git, base, "reset", "--hard", commit); err != nil {
			return "", fmt.Errorf("git reset: %s", strings.TrimSpace(string(out)))
		}
	}
	return base, nil
}

func runGit(git, dir string, args ...string) ([]byte, error) {
	cmd := exec.Command(git, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = os.Environ()
	return cmd.CombinedOutput()
}

// startAgentProcess launches a real provider process detached from the HTTP
// request so work continues when the Mac client disconnects.
func startAgentProcess(workDir, agent, model string, planMode bool, goal string, sessionID string) (processStart, error) {
	binary, args, err := agentCommand(agent, model, planMode, goal)
	if err != nil {
		return processStart{}, err
	}
	runner := filepath.Join(workDir, ".continuum-runner-"+sessionID[:8]+".sh")
	logPath := filepath.Join(workDir, ".continuum-agent-"+sessionID[:8]+".log")
	goalPath := filepath.Join(workDir, ".continuum-goal-"+sessionID[:8]+".txt")
	if strings.TrimSpace(goal) != "" {
		if err := os.WriteFile(goalPath, []byte(goal+"\n"), 0o600); err != nil {
			return processStart{}, err
		}
	}
	script := fmt.Sprintf(`#!/bin/sh
set -eu
cd %q
exec >> %s 2>&1
echo "continuum-agent starting %s at $(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"
export CONTINUUM_AGENT=%q
export CONTINUUM_SESSION=%q
`, workDir, shellQuote(logPath), shellQuote(binary), agent, sessionID)
	commandLine := shellQuote(binary)
	for _, arg := range args {
		commandLine += " " + shellQuote(arg)
	}
	if strings.TrimSpace(goal) != "" {
		script += "exec " + commandLine + " < " + shellQuote(goalPath) + "\n"
	} else {
		script += "exec " + commandLine + "\n"
	}
	if err := os.WriteFile(runner, []byte(script), 0o755); err != nil {
		return processStart{}, err
	}

	if tmux, err := exec.LookPath("tmux"); err == nil {
		name := "continuum-" + sessionID[:8]
		cmd := exec.Command(tmux, "new-session", "-d", "-s", name, "-c", workDir, runner)
		cmd.Env = append(os.Environ(), "CONTINUUM_AGENT="+agent, "CONTINUUM_SESSION="+sessionID)
		if out, err := cmd.CombinedOutput(); err != nil {
			return processStart{}, fmt.Errorf("tmux start: %s", strings.TrimSpace(string(out)))
		}
		return processStart{PID: 0, LogPath: logPath, TmuxName: name}, nil
	}

	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return processStart{}, err
	}
	cmd := exec.Command("/bin/sh", runner)
	cmd.Dir = workDir
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.Env = append(os.Environ(), "CONTINUUM_AGENT="+agent, "CONTINUUM_SESSION="+sessionID)
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return processStart{}, err
	}
	_ = logFile.Close()
	pid := cmd.Process.Pid
	_ = cmd.Process.Release()
	return processStart{PID: pid, LogPath: logPath}, nil
}

func agentCommand(agent, model string, planMode bool, goal string) (string, []string, error) {
	name := strings.ToLower(strings.TrimSpace(agent))
	if name == "" {
		name = "claude"
	}
	binaryName := name
	if name == "opencode" {
		binaryName = "opencode"
	}
	binary, err := exec.LookPath(binaryName)
	if err != nil {
		return "", nil, fmt.Errorf("%s binary not found on PATH", binaryName)
	}
	args := []string{}
	switch name {
	case "claude":
		if strings.TrimSpace(goal) != "" {
			args = append(args, "-p")
		}
		if model != "" {
			args = append(args, "--model", model)
		}
		if planMode {
			args = append(args, "--permission-mode", "plan")
		}
	case "codex":
		if strings.TrimSpace(goal) != "" {
			args = append(args, "exec")
		}
		if model != "" {
			args = append(args, "--model", model)
		}
	case "opencode":
		if strings.TrimSpace(goal) != "" {
			args = append(args, "run")
		}
		if model != "" {
			args = append(args, "--model", model)
		}
		if trimmedGoal := strings.TrimSpace(goal); trimmedGoal != "" {
			args = append(args, trimmedGoal)
		}
	case "cursor", "gemini", "grok":
		return "", nil, fmt.Errorf("%s remote execution is not supported by continuum-agent yet", name)
	default:
		return "", nil, fmt.Errorf("unknown agent %q", agent)
	}
	return binary, args, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func stopAgentProcess(session agentSession) error {
	if session.TmuxWindowID != nil && strings.HasPrefix(*session.TmuxWindowID, "continuum-") {
		if tmux, err := exec.LookPath("tmux"); err == nil {
			if err := exec.Command(tmux, "kill-session", "-t", *session.TmuxWindowID).Run(); err == nil {
				return nil
			}
		}
	}
	if session.PID != nil && *session.PID > 0 {
		if proc, err := os.FindProcess(*session.PID); err == nil {
			return proc.Kill()
		}
	}
	return nil
}
