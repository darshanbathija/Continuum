# Create a pull request

Follow this workflow to open a PR for the current branch.

## Before you start

1. Run `git status`, `git diff`, and `git log` to understand all changes on this branch (not just the latest commit).
2. Confirm the branch is pushed and up to date with the remote.
3. Use `origin/main` as the base branch unless the workspace specifies otherwise.

## Create the PR

1. Stage and commit any remaining work with a clear message focused on **why** the change exists.
2. Push the branch: `git push -u origin HEAD`
3. Open the PR with GitHub CLI:

```bash
gh pr create --base main --title "..." --body "$(cat <<'EOF'
## Summary
- ...

## Test plan
- [ ] ...

EOF
)"
```

4. Return the PR URL and number when done.

## PR body guidelines

- Summarize the nature of the changes (feature, fix, refactor, test, docs).
- Focus on **why**, not just **what**.
- Include a concrete test plan checklist.
- Do not commit secrets (.env, credentials.json, etc.).
