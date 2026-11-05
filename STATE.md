# STATE (newest first)

## 2026-11-04 (night): remote mode
- Built `--remote` (scripts/inspect-remote.sh): scan in a throwaway GitHub codespace, report back, codespace deleted and checked gone. Ticket EST-262.
- First pass: tests/remote-offline.sh 10/10 with a stand-in gh; tests/remote-live.sh 6/6 on real codespaces (no network, read-only, no root hold inside; zip + GitHub link read high; none left).
- Live runs found 3 bugs the stand-in missed: scp path quoting, file permissions for user nobody, gh ssh turning exit 4 into 1. All fixed; exit-code bug has an offline regression check (red run failed).
- Codex review found 7 more holes. All fixed with checks; red run on the old code: 8 FAILED. The worst was in LOCAL mode too: a git hook inside a top-level folder (the usual zip shape) read as low. Now caught at any depth (tests/run.sh: wrapped.zip).
- Final: tests/run.sh 16/16, tests/remote-offline.sh 18/18, tests/remote-live.sh 6/6.
- Local commit only, NOT pushed. Needs Dan's "push it".

## 2026-11-04 (late)
- Public: https://github.com/Dandiggas/recruiter-due-diligence. Blog, LinkedIn and X posts live (links in dandiggas-site STATE.md).
- Considering: run mode in a test lab (sandbox) on a throwaway cloud machine.

## 2026-11-04
- Built: SKILL.md (safety screen + worth-it), scripts/inspect-takehome.sh (unpack + read in locked Docker, runs nothing), tests/run.sh (15 e2e checks).
- Codex review found 6 holes (SSRF via redirect, archive bomb, GitHub ref ignored, silent skips, suffix-only text read, nested archives). All fixed; each has a regression test; red run vs pre-fix code: 9 FAILED.
- Local only. NOT pushed, repo NOT created on GitHub (Dandiggas/recruiter-due-diligence is free). Needs Dan's "push it".
- Post drafts: ~/Desktop/Inbox/recruiter-dd-posts-2026-11-04.md (X + LinkedIn), not posted.
- Next: create public repo + push on Dan's go; terminal screenshot for X; post.
