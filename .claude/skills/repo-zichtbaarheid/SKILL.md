---
name: repo-zichtbaarheid
description: Monthly visibility review of this repository - how people find it, what similar tools offer, and small README and metadata improvements. Use for the routine "NVIDIA repo zichtbaarheid" or when Dennis asks how to make the script easier to find.
---

# Repository visibility

Goal: admins who search for "NVIDIA driver Intune" or "update NVIDIA driver PowerShell silent" find this script, trust it, and find out who made it. Honest and useful beats loud.

## Input

- README.md, intune/README.md, the last release notes (if any).
- Repo metadata via REST: `gh api repos/{owner}/{repo}` (description, topics, homepage), `gh api repos/{owner}/{repo}/traffic/popular/referrers` and `traffic/popular/paths` (needs push access; skip if refused).
- Open issues and discussions.
- WebSearch (at most five searches) for similar tools and where admins ask this question. Known alternatives at the time of writing: lord-carlos/nvidia-update, ZenitH-AT/nvidia-update, the Chocolatey package `nvidia-display-driver`, NVCleanstall. Compare features, not popularity.

## Output

1. A short report as a comment in the monthly tracking issue labelled `visibility` (create it once if missing): referrers, top paths, what similar tools do better, what this repo does better.
2. At most one PR with small improvements, for example:
   - README first paragraph: say plainly what it does and for whom (Intune, unattended, signature check).
   - A comparison table "When to use this vs. alternatives" with verifiable facts only, no disparaging wording.
   - Missing docs that issues show people need (troubleshooting, exit codes, logs).
   - A suggested description, topics and homepage for the repo. These are repo settings, not files: list them in the PR body for Dennis to apply (`intune`, `nvidia`, `powershell`, `driver-updates`, `win32-app`, `endpoint-management`, `autopilot`).
3. Never: star or follow campaigns, posting in other projects' issues, link exchanges, inflated claims.

The blog on soulbit.nl is the place for a longer write-up. If one is missing or outdated, say so in the report; the marketing routines create the topic brief.
