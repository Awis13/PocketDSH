# Native harness acceptance scenarios

Date: 2026-09-08. Proposed checks; **none have been run against a new Swift engine**. See [research](NATIVE-HARNESS-RESEARCH.md).

Use deterministic fake providers/tools for fault injection, then repeat the meaningful end-to-end paths with a real provider, Mac host, and iPad. Record event traces, command IDs, durable checkpoints, and external tool effects. UI screenshots alone cannot establish these invariants.

| # | Trigger | Required observation |
| --- | --- | --- |
| 1 | Submit a normal prompt | One accepted receipt, one turn, streamed response, one final completion |
| 2 | Submit queue and steer while streaming | Steer appears at the next step boundary; queued prompt starts a later turn; neither rewrites the in-flight request |
| 3 | Stop while a new message arrives | Defined inbox-retention behavior; at most one driver; new prompt never disappears into the cancelled activity |
| 4 | Two read tools finish in reverse order | Concurrent execution, independently visible progress, deterministic final tool-result order |
| 5 | Exclusive write after parallel reads | Write begins after the required barrier; later calls cannot bypass it |
| 6 | Invalid JSON/schema or unknown tool | Structured model-visible failure; no tool side effect and no UI crash |
| 7 | Stop during shell execution | No new dispatch; process tree and output readers settle; escalation timeout is visible; no false successful completion |
| 8 | Approval displayed on two devices | First valid answer wins; duplicate answer has no additional effect; exact action and scope remain identifiable |
| 9 | Approval arrives after cancellation | Stale answer rejected; operation never starts because of that answer |
| 10 | Disconnect while approval is pending | Snapshot on reconnect restores pending state according to host policy; absence of a viewer never grants access |
| 11 | Kill host before tool dispatch | Recovery marks interrupted work; no fabricated result |
| 12 | Kill host after file write but before result commit | Unknown outcome exposed; file inspected before retry; no blind duplicate write |
| 13 | Disk full at command acceptance or tool-start commit | Command not falsely acknowledged durable; tool not dispatched without its required commit |
| 14 | Two host processes open the same store | One execution owner; second fails or attaches without a second driver |
| 15 | Reconnect and resend identical command ID | One admission and effect; same ID with changed payload rejected |
| 16 | Disconnect midway through assistant stream | Historical cursor plus current attempt baseline reconstruct one answer; no duplicated partial text |
| 17 | Drop/reorder stream frames | Gap or revision mismatch detected; replay/rebaseline restores authoritative state |
| 18 | Provider retries after partial output | Attempts distinguishable; partial attempt never merged into successful answer; retry budget and stop honored |
| 19 | Change model while a step runs | Existing request retains its snapshot; next request uses explicit selected route; no silent fallback |
| 20 | Provider rejects image or context size | Typed capability/error path; attachment remains recoverable; no endless retry |
| 21 | Compact near a tool pair boundary | Pair kept whole; source history retained; summary provenance and recent tail available |
| 22 | Cancel or change selected surface during summarization | Stale summary not installed; original context remains valid or a committed replacement is explicitly recoverable |
| 23 | Empty/truncated summary | No destructive context replacement; useful error/alternative path |
| 24 | Resume child after host restart | Parent/depth/model/scope preserved; child cannot enlarge its permissions |
| 25 | Pause goal and restart host | No unrequested continuation; goal state and active execution authority distinguished |
| 26 | Two panes edit the same file | Expected-content validation or resource arbitration exposes conflict; no silent lost update |
| 27 | Close every client window | Host follows explicit lifetime policy; reopening restores task and status |
| 28 | iPad backgrounds and returns | Host continues independently; client reconciles history, pending approvals, and active output |
| 29 | Stream very large tool output/history | Bounded memory, paged transcript/artifact preview, responsive input; UI cannot stall engine |
| 30 | Unknown protocol event/version | Payload retained or explicit unsupported state; no invisible approval or false idle state |

## First end-to-end demonstration

Give the agent a small repository task: inspect two files, propose and apply a bounded edit, run verification, then summarize. While reads are running, steer a requirement from iPad. Require approval for the chosen write policy. Disconnect the iPad, let the Mac finish, reconnect, and verify the actual diff, tool results, final status, and absence of duplicated commands.

Repeat with a forced host termination after the edit but before its result commit. The expected result is honest recovery of an ambiguous operation, not an automatic rerun marketed as seamless recovery.

## Performance evidence to collect

Measure release builds on a named Mac and iPad, with model/network settings recorded. Separate provider prefill and generation latency from engine admission, persistence, decoding, and rendering overhead. Compare equivalent request/context/tool behavior against DSH; changing prompt size is not a fair runtime comparison.

Collect idle memory/CPU, sustained streaming memory, disk growth per task, cold/warm first-token timing, reconnect recovery time, cancellation/process-settlement time, and UI input latency with several active panes. Set budgets after baseline measurement; current research contains no benchmark results.
