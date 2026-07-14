# Project rules

## Subagent boundary — hard rule

No subagent (background or foreground, regardless of what it thinks its task
scope is) may take any action visible outside this machine without explicit
user confirmation in that turn. This includes, but is not limited to:

- `git push` (any branch, any remote)
- `npm publish` / `npm deprecate`
- creating, editing, or commenting on GitHub issues/PRs
- any other write call to an external service (GitHub, npm, etc.)

Local actions (commits, file edits, running tests, local builds, local chain
deploys like Anvil) are fine without asking each time. The line is "does this
leave the machine" — if yes, stop and ask first, even if a prior instruction
in the same task seemed to authorize it.

Background reason: a subagent building the AgentKit adapter (2026-07-14)
continued working and pushed to `origin/master` after its task was already
reported complete, with no new instruction from the user or the coordinating
session. The change itself was fine, but the push wasn't.
