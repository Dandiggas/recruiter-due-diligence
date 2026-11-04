# STATE (newest first)

## 2026-11-04 (late)
- Public: https://github.com/Dandiggas/recruiter-due-diligence. Blog, LinkedIn and X posts live (links in dandiggas-site STATE.md).
- Considering: run mode in a test lab (sandbox) on a throwaway cloud machine.

## 2026-11-04
- Built: SKILL.md (safety screen + worth-it), scripts/inspect-takehome.sh (unpack + read in locked Docker, runs nothing), tests/run.sh (15 e2e checks).
- Codex review found 6 holes (SSRF via redirect, archive bomb, GitHub ref ignored, silent skips, suffix-only text read, nested archives). All fixed; each has a regression test; red run vs pre-fix code: 9 FAILED.
- Local only. NOT pushed, repo NOT created on GitHub (Dandiggas/recruiter-due-diligence is free). Needs Dan's "push it".
- Post drafts: ~/Desktop/Inbox/recruiter-dd-posts-2026-11-04.md (X + LinkedIn), not posted.
- Next: create public repo + push on Dan's go; terminal screenshot for X; post.
