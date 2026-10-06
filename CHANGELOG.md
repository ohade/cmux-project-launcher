# Changelog

## 2026-10-05 — choose a project's agents

Merged at `1bedebc`. A launch can start any set of Claude Code, Codex, Grok,
Gemini and Codex on Cursor in one AMQ room, instead of the fixed Codex + Claude
pair. The README's **Agents** section describes the full behaviour.

### In the app

- The **Agents** button picks the agents for the selected project. Its popover
  stays open, so several agents can be ticked in one go. Each tick is saved at
  once.
- **Settings** sets the default agents for a new room: Claude Code + Grok unless
  changed. The last default agent stays ticked.
- With no choice of its own, a project with an AMQ room shows that room's agents,
  faded and labelled "Room". A project with no room shows the default, labelled
  "Default". The first tick starts from what the button shows, so a Claude Code
  + Codex room keeps Codex.
- **Clear Choice** drops the project's own choice again.

### In the launcher

- A project with no choice keeps its existing room's agents. A new room starts
  with the default.
- A chosen agent the room lacks is added to the room. When the workspace is
  already open, the launcher adds a pane for that agent and leaves the running
  agents alone. If the added agent's wake never attaches, its pane is closed and
  its wake retired.
- Grok, Gemini and Codex on Cursor start through `coopgrok`, `coopgemini` and
  `coopcursorcodex` exactly as typed. Their own bootstrap names them and
  attaches their wake.
- Up to three agents share a row of panes. Four agents are two over two, and
  five are three over two.
- Relaunching a workspace with a Gemini pane reattaches it. Gemini runs as
  `node …/gemini-cli/bundle/gemini.js`, which the liveness check now accepts.
- When a project's workspace is gone, every leftover wake in its room is
  retired, not only the chosen agents' wakes.
- A fallback `<project>-2` room gets the project room's agents.
- `cmux-project-launch --room-agents <project>` prints the room's agents
  without changing anything. The app's Agents button uses it.
- Panes survive an oh-my-zsh update prompt, and Codex 0.160.0's rename dialog
  is recognised.

### Verification

- Every bug fix started with a test that failed on the old code.
- The Swift tests, the launch suite with fake and real AMQ 0.77.3, the create
  suite, the Bash 3.2 suite and ShellCheck all pass at `1bedebc`.
- Live gates on production cmux passed:
  - a five-agent launch;
  - a relaunch with and without a choice, each reattaching every agent;
  - adding Grok to a live Claude workspace;
  - cleanup.

### Deferred

- Split `bin/cmux-project-launch` (about 1,600 lines) into modules, on its own
  branch.
- Replace the wall-clock limit in the two-slow-helpers test with a poll count.
- A corrupt stored choice silently reads as "no choice".
