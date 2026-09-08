# Warp UI: source study and interaction specification

Date: 2026-09-08. Scope: desktop terminal and integrated-agent interactions relevant to Pocket DSH / Native Harness.

**Checkpoint refresh:** block selection/search/copy/attachments, Tab completion, history navigation, history suggestions and rich eza/ANSI output are now implemented. The gap table below records the earlier source-study baseline. [The current roadmap](ROADMAP.md) supersedes its implementation statuses and prioritizes context reliability, native controls, terminal focus/monitoring and review. AI suggestions remain optional backlog work.

This extends the [55-area feature inventory](WARP-FEATURE-AUDIT.md). It adds current public source evidence, more visual references, and a comparison with the **integrated** Pocket DSH path. It is a research deliverable, not an implemented redesign or a claim of full Warp runtime coverage.

## Evidence and limits

- **S — source:** inspected selected declarations and implementation sections from 21 public Warp files at commit [`1f0cf55afb29c71d94f2980b384aa11cb3cdb85a`](https://github.com/warpdotdev/warp/tree/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a), committed 2026-09-08 10:29:58 UTC. This does not mean all 21 files were read line by line or executed. Source availability does not establish which feature flags are enabled in a released build.
- **V — visual:** inspected the official block-menu video at its opening and paused at approximately 4.15 seconds, plus six official UI images listed below. These are reference media, not actions performed in the installed app. Their exact Warp build versions are unknown.
- **D — documented:** official pages linked below; the previous source catalog remains the broad inventory.
- **P — Pocket source:** examined the currently used `DesktopHomeView → DesktopPaneView → NativeShellPane` path, its transcript, wire types and terminal tools. No new Pocket runtime tests were run for this documentation task.

Computer Use again rejected access to `dev.warp.Warp-Stable` for safety reasons. No alternate control path or Linux VM was used to bypass that restriction. Installed-app scenarios in the earlier audit remain unexecuted. Existing macOS Warp and OrbStack were found; no VM image, Linux Warp package, build dependencies or full repository clone was downloaded.

The ignored research folder `output/warp-audit/source-2026-09-08/` holds the complete GitHub tree metadata, pinned revision and SHA-256 manifest for the selected source files. The 21 source files total 1,778,264 bytes. Six focused documentation pages are in `output/warp-audit/focused-docs/`. No Warp implementation code was added to our application.

## What makes the interface work

### 1. The transcript is a structured list, not one growing terminal grid

`BlockList` stores command blocks, stable ID lookup, selection, and an indexed tree of item heights. The height model also includes rich content. Agent UI and terminal output can therefore occupy one ordered surface without pretending that prose is terminal escape sequences. Dirty rich-content heights are tracked explicitly. [S: blocks.rs](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/model/blocks.rs#L268).

The renderer tracks visible items and blocks; completed `BlockGrid` objects cache measurements that would otherwise require inspecting cells repeatedly. This is concrete evidence of mechanisms relevant to efficient rendering, not a benchmark or a guarantee that Warp is always fast. [S: block_list_element.rs](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/block_list_element.rs#L668), [S: blockgrid.rs](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/crates/warp_terminal/src/model/blockgrid.rs#L30).

**Our adaptation:** keep the shared presentation journal and stable row identity. Add selection/navigation and reusable layout measurements around that model. Profile the current `VStack + ForEach(store.rows)` before choosing virtualization; do not create another transcript store or another PTY per historical block.

### 2. Following output and reading history are different states

Warp represents following the newest block, a fixed scroll position, and an anchor within a long-running block separately. The latter accounts for old output being evicted. Updates distinguish typing, terminal input, resize, filtering, and rich-content insertion. Rich-content growth can preserve the reading position depending on the autoscroll policy. [S: viewport states](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/block_list_viewport.rs#L137), [S: updates](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/block_list_viewport.rs#L752).

**Our adaptation:** preserve current follow/browse behavior, then replace fragile absolute offsets with a block ID and offset within that block where needed. Returning to latest output resumes follow. Text selection, permission dialogs and a TUI retain their own focus; reaching the bottom must not steal it. A selected historical block remains selected while the agent streams.

### 3. Interactive programs have their own screen and input ownership

Warp has an explicit `AltScreen` with its own grid handler and selection. Separately, a block's interaction model tracks human/agent origin, whether the agent has written, and who currently controls a long-running command. Taking over checks the current state before changing ownership. These are distinct concerns. [S: AltScreen](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/model/alt_screen.rs#L45), [S: interaction state](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/model/block/interaction_mode.rs#L343).

The official SQLite image keeps the terminal visible next to the agent's explanation and proposed input, with Allow, Refine and Take over controls. A second image shows shortcut labels directly on the takeover and stop controls. [V/D: Full Terminal Use](https://docs.warp.dev/agents/capabilities/full-terminal-use/).

**Our adaptation:** expand an active TUI to the available pane, retain the transcript behind it, and return to the same scroll anchor when it exits. Keep `Stop agent`, `Interrupt command` and `Take control` semantically separate. The current model tools only read terminal excerpts; a control button must not imply agent keyboard capability before host-side ownership and write authorization exist.

### 4. The editor is a first-class part of the terminal

Warp's source distinguishes fuzzy history, prefix history, completions, slash discovery, model selection and context selection. Its GUI input policy also contains mode autodetection and attachment-driven changes. These are independent modes, not interchangeable meanings for the same keystroke. [S: suggestions](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/input.rs#L580), [S: input policy](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/ai/blocklist/agent_view/gui_input_mode_policy.rs).

**Our adaptation:** retain the user's explicit routing: Shell Enter executes/sends PTY input, Cmd+Enter asks the agent in place, Shift+Enter inserts a newline. Chat remains another presentation of the same session. Add history/completion without silently classifying natural language or switching to Chat. Suggestions insert into the draft; selecting a suggestion does not execute it.

### 5. Queue controls belong beside the draft

The queue panel reads conversation-owned state and keeps hover, drag and editing state local to the view. It offers send-now, edit, delete and reorder actions. Official images place it immediately above the editor rather than elsewhere in a sidebar. [S: queued_prompts_panel.rs](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/view/queued_prompts_panel.rs#L1), [V/D: queue](https://docs.warp.dev/agents/local-agents/interacting-with-agents/prompt-queueing/).

**Our adaptation:** expose the native engine's existing delivery modes through the host and client. Label “after this response” versus “send now”; retain drafts on errors and pause queued delivery on failure. Do not copy Warp's empty-Enter-send-next behavior into our Shell: Enter may belong to a running program. Provide an explicit action instead.

### 6. Focus is centralized, even when content differs

`PaneGroupFocusState` separates the focused pane from the active terminal session and keeps split/maximize state in one model. This matters when a code pane has keyboard focus but a terminal is still the relevant session. [S: focus_state.rs](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/pane_group/focus_state.rs#L5).

**Our adaptation:** extend the integrated `AgentWorkspace`, preserving its existing split tree and saved state. The separate experimental `NativeWorkspace` already contains some navigation/maximize ideas, but its presence is not evidence those features are available in the current Pocket window.

## Interaction shortlist and current gaps

The “next behavior” column is our proposed product behavior. It is deliberately not a claim that Warp behaves identically on every platform.

| Area | Warp evidence | Current Pocket path | Next behavior / acceptance example |
| --- | --- | --- | --- |
| Unified feed | S: typed blocks and rich content | Present: Shell uses `PocketStore.rows`, including tools and reasoning | Preserve all messages and command order across Chat/Shell switches |
| Block selection | V: block outline and right-edge actions; D: block basics | Per-command copy and ask exist; no block selection/navigation state found in `NativeShellPane` | Select command plus output as one unit; move previous/next without editing the draft |
| Block action menu | V: command/output/both copy, metadata, find and bookmark | Limited inline actions | Same actions from context menu, keyboard and iPad long press; no mandatory hover |
| Output search | D: [find](https://docs.warp.dev/terminal/blocks/find/) | No native Shell find UI found | Search one block or the session; next/previous result; Escape restores reading position |
| Output filter | D: [filter](https://docs.warp.dev/terminal/blocks/block-filtering/); S: viewport filter anchoring | Missing in native Shell | Filter presentation without changing retained output; clear restores original lines |
| Sticky command identity | D: [sticky header](https://docs.warp.dev/terminal/blocks/sticky-command-header/) | Command header scrolls with output | While reading a long block, retain command, cwd and exit/running status compactly |
| Bookmarks | V/D: block actions | No native block bookmark UI found | Local bookmark with jump and preview; decide persistence explicitly rather than copying transient Warp bookmarks |
| Command history | S: prefix/fuzzy modes; D: editor/history | Native Shell composer is a text editor; no history chooser found | Ctrl+R opens local fuzzy history; selection inserts; Escape restores untouched draft |
| Completion | S: distinct completion mode | No Shell completion backend found | Local paths/commands first; menu retains caret position and supports keyboard/touch |
| Explicit agent context | D: [blocks as context](https://docs.warp.dev/agents/local-agents/agent-context/blocks-as-context/) | “Ask agent about this” and bounded terminal context exist | Show attached command IDs/previews, remove individually, disclose truncation; changing UI selection must not rewrite sent context |
| Output follow | S: viewport states | Present: follow flag, bottom observer and jump button | Test long streaming output, resize, selection and return-to-bottom; add stable anchors where current behavior fails |
| Full-pane TUI | S: alternate screen; D: full-screen apps | Interactive SwiftTerm currently occupies an adaptive 300–560 point block | Expand `htop`/Vim within the active pane, preserve neighboring panes and shell; q/Ctrl+C return to transcript |
| Agent observation/control | S/V/D: interaction ownership | Observation exists; tools explicitly have no keyboard control | Honest “Observing” status now; gated “Agent controls terminal” only after host support; takeover leaves process alive |
| Queue and steer | S/V/D: queue | Engine supports delivery modes; integrated UI/host management not complete | Queue, edit, remove and send-now visible in both views; failure retains pending work |
| Pane navigation | S: centralized focus; D: splits | Integrated UI has split/resize/close/restoration | Add directional focus and maximize/restore to this path; last-pane Cmd+W remains harmless |
| Diff beside work | V: side review and hunk attachment; D: [review](https://docs.warp.dev/code/code-review/) | Existing DSH diff UI is not proof of native workspace-wide review | Read-only native diff side pane; show base/worktree; attach hunk to current agent without changing session |
| Permissions | V: approval next to live terminal | Current native shell shows one interaction below feed | Compact proposed action with keyboard options; approval cannot hit another pane or a stale request |
| Appearance/density | D: [appearance](https://docs.warp.dev/terminal/appearance/) | Rich Pocket themes already exist | Apply current themes to block selection, context chips and new controls; preserve Dracula and touch target sizes |

## Visual notebook

Only the observations below were made during this pass. Links are to the original media; no downloaded or repackaged media assets were added to the repo.

| Reference | Observed detail | Design implication |
| --- | --- | --- |
| [Block-menu video](https://www.loom.com/embed/3dec25e548d4484aa3dd6437869e2bbf), opening and paused ≈4.15s | Thin separators, one outlined selected block; context menu groups copying, metadata, find/bookmark and pane actions | The command is the unit of interaction; keep actions unobtrusive until selection |
| [Queue panel](https://docs.warp.dev/_astro/prompt-queueing-panel.DUP6ueju_RXpCl.webp) | Pending prompts occupy a narrow stack above the bottom editor while the response remains visible | Pending work should stay next to the draft |
| [Queue row controls](https://docs.warp.dev/_astro/prompt-queueing-row-controls.BigLRXiO_5NnLp.webp) | Actions grouped at the right edge of a compact row | On iPad expose equivalent actions on selection, not hover alone |
| [Takeover controls](https://docs.warp.dev/_astro/full-terminal-use-takeover.CXmq55EP_ZbcbAV.webp) | Take-over and stop controls have distinct symbols and visible shortcut labels | Explain ownership and interruption at the point of use |
| [SQLite approval](https://docs.warp.dev/_astro/allow-refine-takeover.DQirdZqB_Z2ci4In.webp) | Live terminal left; agent explanation, proposed input and approval controls right | Keep relevant output visible while deciding what the agent may do |
| [Diff hunk attachment](https://docs.warp.dev/_astro/attach-diff-hunk-as-context.Dqq-xqrq_Z28tmyE.webp) | Attachment action appears beside a specific code hunk | Attach a bounded, identified piece of code rather than the entire repository |
| [Review beside terminal/agent](https://docs.warp.dev/_astro/code-review-panel-update.OokO3LEH_1Maom3.webp) | Conversation and code changes coexist in neighboring panes | Diff is a companion surface; opening it should retain the current task |

## Proposed next increments

These are recommendations, not approved implementation or a new development cycle.

1. **Make the existing transcript easy to navigate.** Selected-block state, previous/next block, command/output/both copy, find within a block, and visible selected-context chips. Preserve the current theme and Shell/Chat journal. Acceptance: a failed build can be located, copied and attached to an in-place agent question entirely with the keyboard; the same actions work with touch.
2. **Make interactive terminal focus predictable.** Full-pane TUI presentation, explicit return to transcript, centralized focus ownership, directional pane focus and maximize/restore. Acceptance: `htop → q`, `vim → exit`, Ctrl+C, resize and switching panes preserve the same shell and draft. During an agent turn, terminal input still goes to its visible owner.
3. **Expose agent state and pending work.** Queue/steer UI, permission focus, bounded context preview and read-only monitoring status. Wire engine semantics before presenting controls. Agent PTY writing and takeover form a separate host capability, with stale-write rejection and tests; do not disguise that as a UI-only change.
4. **Add review and reuse.** Native read-only diff side pane, hunk context, local searchable command history, then shell completions and saved commands. Reuse existing Pocket components when their native-host data contract is real.

For each increment, preserve one session across Chat/Shell, the user's Enter/Cmd+Enter rules, active-pane Cmd+W, existing themes and remote Home Rig inference. Avoid importing Warp's full product scope, mode autodetection defaults or cloud coupling.

## User-prioritized follow-up: command reuse

Basic Tab command/path completion and session Up/Down history have been implemented ahead of the original sequence; see `NATIVE-CHAT-INTEGRATION.md` for the actual contract and validation.

Fish-style inline history suggestions are now implemented as well: exact prefix matching in the retained session history, preference for the current directory, explicit full/word acceptance, Escape, and a persistent toggle. This is local history reuse; it makes no inference request.

Still in the backlog, not implemented in this increment:

- Optional AI suggestions through the configured local provider. Design latency/cancellation, context bounds and privacy first; show the suggestion's origin and never execute it automatically. Basic completion and history must remain immediate and usable when inference is busy or unavailable.

## Performance and debug hooks to carry forward

These are proposed diagnostics for our implementation, inspired by the source mechanisms above, not new measurements:

- Count retained/visible blocks, rendered rows, changed-row invalidations and layout time while streaming. Measure large histories before and after any virtualization work.
- Log a compact focus transition: active pane, input owner, reason, and whether a pending action was discarded. Never log typed secrets.
- Track scroll mode and block anchor; record why a follow transition occurred, especially after resize, search and TUI exit.
- Keep command lifecycle separate from PTY lifetime. Warp's explicit lifecycle vocabulary covers prompt-ready, submitted, executing, unknown and terminated states plus duplicate/colliding IDs. Our diagnostics should expose equivalent uncertainty instead of guessing completion from silence. [S: lifecycle policy](https://github.com/warpdotdev/warp/blob/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a/app/src/terminal/model/lifecycle/transition.rs#L10).
- Measure input-to-first-feedback and first-output latency separately from generation speed. Native language choice alone does not establish responsiveness.

## Local models: current Warp distinction

Warp now documents custom OpenAI-compatible inference endpoints. However, its documented flow runs the harness on Warp's backend and requires a publicly reachable endpoint; private/local network addresses are rejected. This is still different from our direct private-network Home Rig connection. This pass did not configure a Warp account or expose Home Rig publicly. [D: custom inference endpoint, updated September 3](https://docs.warp.dev/agents/inference/custom-inference-endpoint/).

The public repository identifies its UI framework crates as MIT and the remainder as AGPLv3. This study records behavior and architecture references; it is not a source import or a license-change proposal. [Repository licensing statement](https://github.com/warpdotdev/warp/tree/1f0cf55afb29c71d94f2980b384aa11cb3cdb85a#licensing).
