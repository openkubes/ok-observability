# Onboarding: Co-working on ok-observability with Claude (Cowork)

*For Christian — how the three of us (Arash, Christian, Claude) work on the
same source base for the OK-100 Harness pilot.*

## The model in one paragraph

There is no shared live AI session. **The Git repository is the shared
state.** Each of us runs our own Cowork session against our own local clone of
`openkubes/ok-observability`. Coordination happens exactly where it always
has: branches, PRs, and Jira. What makes this work well is the pilot itself —
`AGENTS.md` gives every Claude instance (yours or Arash's) the same context
and rules, and `make verify` / `make conformance` give every instance the same
deterministic checks. Same harness, independent hands.

## Setup (once, ~10 minutes)

1. Install the Claude desktop app and open **Cowork mode**.
2. Clone the repo locally: `git clone git@github.com:openkubes/ok-observability.git`
3. In Cowork, connect that folder when Claude asks (or ask Claude to work in
   it). Claude reads `AGENTS.md` from there — no further briefing needed.
4. Connect the **Atlassian connector** (Jira/Confluence) in the app settings —
   same Kubernauts workspace, project `OK`. Then Claude can read tickets
   (OK-100, OK-79) and draft evidence comments for you.

## Working agreement (mirrors AGENTS.md)

- Work on branches, never on `main`. Current pilot branch:
  `spike/ok-100-harness-pilot`.
- Before any PR: `make verify` must pass. `make conformance` fails by design
  until OK-79 delivers `tests/contract-test.sh` — that's expected, don't fix it.
- `make evidence` generates the Jira-comment evidence block; a human reviews
  and posts it.
- AI output is advisory. **Only humans approve and merge.** Claude will refuse
  to weaken tests or touch contract semantics — that's intentional.
- Commits: `feat/fix/docs/chore(scope): …` with `Relates: OK-nnn`.

## Division of labor for the pilot

- Arash: spike owner, OK-100 decisions, merges.
- Christian: review of the harness scaffold, timing check against OK-79,
  ideally drives one realistic change through the workflow.
- Claude (both instances): analysis, implementation proposals, running checks,
  drafting evidence — under the rules above.

Questions → comment on OK-100.
