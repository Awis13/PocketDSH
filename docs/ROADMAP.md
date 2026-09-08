# Pocket DSH / Native Harness — current state and next work

Updated 2026-09-08 after packaging the native workspace in [PR #1](https://github.com/Awis13/PocketDSH/pull/1). Code baseline for this assessment: `70b9a5f` (with core `a40a5c2` and vendor `10610a3`).

This is a source-based reconciliation of the earlier DSH and Warp research, not another live walkthrough of either product. It supersedes implementation-status claims in the older research notes. Recommended work below is a plan, not approved implementation. Do not infer a completion percentage from the number of broad feature rows.

## Product contract

One native workspace, one session journal, two parallel presentations: touch-friendly Chat and keyboard-first Shell. Shell Enter executes/sends terminal input; Command+Enter asks the integrated agent in place. Switching presentation keeps the session, draft, output and agent history. Output and agent steps stay visible in Shell. Themes, split panes, active-pane Command+W and local/private-network inference remain core requirements.

There are **two backends**. A feature in the existing DSH client is not automatically implemented in the Swift engine. iOS runs the client; the macOS host owns processes, tools and model requests. SwiftTerm and Nerd Fonts are bundled; eza is an optional native host executable. Node/Python are not native runtime requirements, but remain development or optional DSH-plugin tools.

## What is already implemented

| Area | Current implementation and evidence |
| --- | --- |
| Native execution | Swift 6 provider/SSE adapter, separate text/reasoning, indexed tool calls, bounded steps, cancellation, SQLite events, writer lock, durable request receipts; `NativeHarness/Sources/HarnessCore` |
| Tools and permissions | Workspace list/read/exact edit, finite shell command, one-use allow/reject, fail-closed behavior; read-only terminal inspect/read/wait. No agent PTY writing or OS sandbox |
| Native host and client | Authenticated loopback WebSocket host; one shared Shell/Chat presentation journal; live tool output and stop/approval status; `NativeHost.swift`, `NativeChatConnection.swift`, `PocketStore.swift` |
| Real terminal | Persistent zsh and POSIX PTY, command hooks, cwd/exit status, live SwiftTerm surface, Ctrl+C/focus routing; live Mac htop round trips recorded |
| Blocks and input | Open output, select/previous/next, Find, copy command/output/both, immutable context attachments; basic host Tab completion, Up/Down history, local fish-style suggestions |
| Rendering | Theme-aware ANSI palette/style retention, symbols in live/replayed output, optional eza helpers; exact retained Unicode width/copy fidelity still needs broader fixtures |
| Workspace and recovery | Existing splits and pane close, saved layout/ratios/session/drafts, replay after disconnect/restart. A dead process is not resurrected; unknown/interrupted outcomes are explicit |
| Existing DSH backend | Models, basic queue/current-draft steering, approvals/questions, images, voice relay, Markdown/diff sheet and themes remain available through DSH |

Verification refreshed for this checkpoint: 65 Swift core/host tests, offline protocol/Markdown/transcript/editor checks, 11 mocked voice tests, five real-process probe suites, and unsigned Mac Catalyst + generic iOS builds passed. XcodeGen reproduces the project and bundles font/notices. The observation probe was repaired to expect normalized model excerpts while still requiring a complete later output line. Earlier live Mac evidence is in [integration notes](NATIVE-CHAT-INTEGRATION.md). No fresh physical iPad test or installation was performed. GitHub CI status is reported separately on the PR.

## DeepSeek Harness mechanics: what remains

These are the ten boundaries from [the source research](NATIVE-HARNESS-RESEARCH.md), compared with the current Swift implementation.

| Mechanic | State | Remaining work |
| --- | --- | --- |
| One execution owner | Implemented foundation | Maintenance/compaction needs the same exclusivity and cancellation semantics as turns |
| Queue vs steering | Core implemented; client partial | Host prompts enqueue; CLI exposes queue/steer/remove/resume. The native wire/UI lacks delivery mode and queue item controls. Add pending-state projection and stable-ID edit/remove/steer operations |
| History vs model context | Partial | Engine and presentation journals are separate; bounded terminal attachments exist. Model context still grows from full history. Add token budgeting, context projection and request provenance |
| Provisional streaming | Implemented foundation | Keep partial versus completed identity; future retries need attempt reconciliation. UI currently discards some unfamiliar event kinds |
| Parallel tools | Missing | Engine executes sequentially. Add bounded concurrency, exclusive barriers and deterministic commits without hiding live per-tool progress |
| Permission policy | Partial | One-use approvals exist. General access profiles, scoped persistent grants, client policy selection and actual OS enforcement do not |
| Crash recovery | Implemented foundation | No automatic command replay; preserve unknown outcomes. Retention quotas, paging, disk-full/power-loss tests and large-history measurements remain |
| Balanced compaction | Missing | ANSI/base64 context inflation was fixed; that repair is not compaction. Preserve tool pairs, recent tail and original transcript, reject bad summaries, commit against a frozen context generation |
| Goals and children | Missing | No native goal/plan/subagent/workflow drivers. Define lineage, authority, concurrency and cancellation before adding their UI |
| Reconnect reconciliation | Implemented foundation | Ordered replay, acknowledged prompt IDs and saved drafts exist. Add version/capability negotiation, explicit unknown-event handling, paged replay and multi-client policy |

Provider-specific gaps: one configured compatible endpoint/model per host, fixed generation settings, no automatic provider retry policy, usage/token accounting or per-session model/effort selection. Diagnostics report observed milestones; they do not split provider queue time from prefill or establish cache hits. The [benchmark](HARNESS-BENCHMARK-2026-09-08.md) used unequal tool/context/cache conditions and is not a pure Swift-versus-TypeScript speed comparison.

## DSH client inventory reconciliation

All 46 original IDs are retained below. The original audit described the **DSH adapter**, not the later native host. Existing source was checked; new backend success paths were not exercised for this documentation pass.

| Original IDs | Current DSH client gap | Native-host implication |
| --- | --- | --- |
| G01, G21 | Only local /view, /model, /new; no server command/skill catalog | Need capability-backed command registry and skills, not arbitrary slash text sent as a prompt |
| G02, G03, G42, G43 | Effort/preset selection and provider/preset administration absent | Model catalog, per-session configuration and preset mechanism also absent in core/host; model selection UI is disabled |
| G04, G05 | Full access exists from an approval; no general/default access selector | Native allows one-use decisions only; policy changes need a host contract |
| G06, G07, G18 | Plans/goals and specialized activity states absent | No native drivers; generic running/approval status is not plan or goal support |
| G08, G09 | Basic queue and current-draft steering exist; no item editing/removal or busy-send preference | Basic prompt enqueue works, but no visible pending native queue or steer controls; preserve Shell Enter semantics |
| G10, G11, G12, G13, G14 | Rename/fork/turn-branch/archive and content search remain absent; search filters loaded titles | Native host lists/opens saved sessions but lacks these management operations |
| G15, G16 | Existing workspace choice/filter; no metadata management, grouping/manual order | Native session creation uses the host workspace; no workspace catalog/management |
| G17 | Subagents filtered out; no lineage navigation | Native child-agent execution and identity are also missing |
| G19, G20 | No remote @file/@folder/@session picker | Native terminal-block attachments are implemented; they do not cover file/session references |
| G22, G23, G24, G26 | No context meter, injection inspector, compaction UI or usage/performance readout | Missing token accounting/compaction; existing core diagnostic events need an honest client projection |
| G25, G27, G28 | No trajectory or persistent tool side inspector; Markdown/diff/tool rendering partial | Better terminal styles do not implement native file/diff contracts or request inspection |
| G29, G30 | No completed-turn grouping or durable turn navigator | Native block navigation is present, but does not navigate agent turns. Any process compaction must stay optional in Shell |
| G31 | Retry/token-limit/unknown-event coverage incomplete | Native context-limit error is now explicit; retries and general compatibility fallback remain missing |
| G32, G33 | Whole-message copy/feedback incomplete | Shell command/output copy is implemented; it is not a general chat feedback/copy surface |
| G34, G35, G36, G37 | Images only; generic files/artifacts, external open and session export absent | Native image/voice input is not wired; general artifacts and share/export need native transport |
| G38, G39, G40 | No jobs/schedules/workflow panels | No corresponding native persistent drivers/catalogs |
| G41 | Basic DSH questions exist; advanced navigation/plan-specific answers absent | Native tool catalog has approvals but no general ask-user/plan-review tool |
| G44, G45 | No plugin inventory/configuration or host configuration entry point | No native plugin lifecycle/config schema; administration is later scope |
| G46 | English-only interface is intentional for now | Localization is optional, not a release blocker |

## Warp interaction inventory reconciliation

All 55 research IDs are mapped. “Partial” means the useful core exists, not that all documented Warp behavior has been reproduced. Warp's installed-app walkthrough was not completed; original evidence consists of pinned source, official documentation and reference media.

| Original IDs | State in the integrated Pocket path | Remaining work / scope |
| --- | --- | --- |
| W01, W02, W03 | Partial: individual blocks, keyboard navigation, copy and Find implemented | Range selection, bookmarks, broader search and large-output limits |
| W04, W05, W06 | Missing dedicated UI | Output filters, sticky command headers, explicit unassigned/background-output blocks; never invent process provenance from mixed PTY bytes |
| W07 | Partial: local copy | Export later; public permalinks optional |
| W08, W49, W50 | Partial: themes, fonts, ANSI palette, theme JSON import/export and local settings | Independent density/cursor controls and complete settings portability; whole-window transparent Liquid Glass remains deferred |
| W09, W10 | Partial: interactive PTY surface and selection | Full-pane TUI presentation, explicit return anchor, rectangular/multi-block selection and keyboard-protocol coverage. Current inline TUI height is capped |
| W11 | Partial: native multiline editor and standard editing | Broader IME/Unicode/wrapped-line and physical iPad keyboard validation |
| W12, W13, W14, W17 | Missing | Editor Vim keymap, alias expansion preview, syntax/argument inspector and visible command correction are optional later features; executing Vim in PTY already works |
| W15, W16 | Partial: basic Tab, session history and history ghost implemented | Fuzzy/all-session history, command-specific flags/Git completions and optional model suggestions |
| W18 | Missing; optional | Explicit multi-target synchronized input, not default behavior |
| W19, W52 | Missing | Local parameterized saved commands/workflows/prompt library before any sharing service |
| W20, W29 | Partial: local slash commands | One action registry/palette; native fork, compaction and model commands need real host operations |
| W21, W22 | Implemented product contract | Explicit Shell/Chat views and in-place agent submission; no auto-detection requested |
| W23 | Implemented bounded slice | Immutable selected-block attachments with preview/remove; retain explicit size/retention limits |
| W24 | Partial: block context | File/session/URL and multimodal context need native schemas |
| W25, W26 | Read-only observation implemented; control missing | Model-visible screen/lifecycle state, input ownership, approved writes, revocation, stale-write rejection and handback |
| W27, W28 | Partial: one-use approvals and core inbox | Profiles/policy and queue UI; no implication that a button alone grants agent PTY writing |
| W30, W31 | Missing in native host | General user questions, structured plans/tasks and review lifecycle; DSH has basic questions |
| W32, W38 | Missing in native engine | Instructions/skills discovery, MCP and explicit memory policy; Seed stays backlog |
| W33 | Partial: direct private provider connection | Native model/effort/catalog selection and provider capabilities |
| W34, W35 | Missing in native backend | DSH voice/images already work separately; reliable notification delivery remains unresolved |
| W36, W37 | Missing dedicated integration | Foreign CLI agents, indexing, browser/computer use and search are separate capability projects; a raw shell can still run installed programs |
| W39, W40, W41 | Partial: sidebar, split tree, resize and active-pane close | Directional focus/maximize in the actual app path; tab reorder/reopen/pins/groups and drag/drop. Unused NativeWorkspace experiment is not shipped evidence |
| W42, W43 | Partial: saved current layout, sessions and drafts, replay/recovery | Named layout templates, paged history and multi-device policies; no dead-process resurrection |
| W44 | Missing; optional | Global summon shortcut and customizable toolbar |
| W45 | Partial: raw SSH can run inside PTY | Shell hooks/completion do not automatically install inside SSH or subshells; integrated remote-shell support needs a separate contract |
| W46, W47, W48 | Missing native workspace review/editor/worktree management | Start with read-only diff beside the current pane and hunk context; a full editor/LSP is later scope |
| W51 | Partial: cwd, Markdown and some native accessibility | Clickable file/link actions, bell policies, quit warnings and focused daily-use/accessibility checks |
| W53, W54, W55 | Deferred | Team collaboration, cloud orchestration and factories are outside the immediate local-first MVP |

## Recommended next milestones

The broader comparison changes the priority from adding another input feature to making long native sessions dependable. These are bounded proposals; nothing here starts a development cycle.

1. **NH-CONTEXT — visible context pressure.** Parse actual provider usage/capabilities, display context budget and request timing with unknown values explicit; preserve unknown relevant events. Acceptance: a long session shows evidence of pressure before a provider rejection, and users can inspect the failed request stage. Never fabricate cache hits or prefill percentages.
2. **NH-COMPACT — bounded model context.** Build a separate context projection with balanced tool pairs, retained recent turns, validated summary, generation check and atomic replacement. Acceptance: continue a deliberately over-budget conversation without losing the original UI history or replaying tool effects; failed/cancelled summaries leave the old projection intact. Follow with bounded provider retries and request-attempt reconciliation.
3. **NH-DAILY — control the native session.** Expose core queue/steering/pending cancellation first; then model/effort and explicit access mode, rename/archive/fork and content search. Split delivery controls from session management into separate changes. Acceptance: edit pending work while output streams, handle already-consumed IDs, and reopen the same session with truthful settings.
4. **NH-TERMINAL — complete focus and monitoring.** First full-pane TUI/return, directional pane focus/maximize and real iPad keyboard/touch validation; then model-visible command/screen state. Agent input/takeover is a separate guarded host milestone (NH-CONTROL), with human input revoking permission and stale writes rejected.
5. **NH-REVIEW — inspect changes beside work.** Read-only workspace/branch diff, changed-files list, hunk attachments and artifact open/share. Acceptance: inspect the correct file/base and ask about a selected hunk while preserving the current session, draft and scroll position.
6. **NH-EXTENSIONS — reusable agent capabilities.** Versioned instructions/Markdown skill discovery, typed tool/permission API, then MCP or Seed adapters. General questions/plans and child-session lifecycles remain distinct engine work; do not promise all DSH plugins by loading Markdown alone.

**Optional small slice: NH-AI-SUGGEST.** Explicit shortcut/button for a bounded local-model command suggestion, cancellation when the draft changes, visible origin and accept/edit/reject. Never auto-execute. Ordinary Tab/history stays immediate while inference is busy. Continuous background prediction is a separate opt-in decision after latency measurements, not the default next priority.

**Reliability alongside these stages:** journal retention/paged replay, large-history render measurements, foreground/background output attribution, Unicode width/copy fixtures, one-client-per-session policy, host service/tunnel packaging and physical iPad reconnect/focus checks. Track these as concrete limits; do not mark the 30-scenario research checklist passed because the current 65 unit tests pass.

**Deferred product scope:** full IDE/LSP, cloud/teams/factories, forced language localization, dependable Apple push delivery, transparent whole-window glass and Seed deployment. The user's Seed concept remains recorded in the private backlog and has no installed native adapter yet.

## Evidence boundaries

- This checkpoint reran offline tests and isolated process probes, and built both Apple targets. Earlier live Mac checks are explicitly dated in the integration notes; no new UI redesign was tested here.
- DSH UI inspection happened against 0.1.3-alpha.2. The Warp public-source snapshot is pinned in its study. No new upstream-version compatibility claim is made.
- Native generic iOS compilation does not establish physical-device interaction, background behavior or secure remote setup.
- Known constraints: host binds loopback; eight instantiated shells per launch; one attached client per session; native command rendering retains bounded previews; full journal replay/history currently grows without quotas/paging; the PTY is not a security sandbox.
- Builds pass with warnings. The Swift 5-mode client reports a main-actor conformance warning for `NativeTerminalDelegate`/`TerminalViewDelegate`; audit that boundary before enabling Swift 6 language mode. The vendored library also has upstream deprecation/style warnings. No new linter or independent code review was run for this checkpoint.
- The research inventories remain useful historical evidence. This document and the integration contract are the current implementation-status entry points.
