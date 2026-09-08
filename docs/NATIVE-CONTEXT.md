# Native context and request accounting

C1 prepares and measures model requests in HarnessCore. C2 exposes those observations in the shared Shell/Chat indicator and request inspector, and preserves them in diagnostic and presentation journals. C3 adds a durable model-only context projection. C4 adds bounded summary generation, automatic pressure handling and a manual engine/driver API. User controls remain C5; `/compact` is not exposed in the app or CLI yet. The original conversation and terminal history remain intact.

## Configuration

Both CLI and host modes read the same optional environment settings:

| Variable | Default | Meaning |
| --- | --- | --- |
| `HARNESS_PROVIDER_PROFILE` | `compatible` | `llama-cpp` enables the specific count/props contract described below. Generic compatible mode makes no discovery/count requests. |
| `HARNESS_CONTEXT_TOKENS` | Unknown | Explicit positive context limit, labelled as configured rather than discovered. |
| `HARNESS_OUTPUT_TOKENS` | `4096` | Positive generation reserve; also the actual request's `max_tokens`. Must be smaller than an explicitly configured context limit. |
| `HARNESS_INCLUDE_USAGE` | `1` for llama-cpp, `0` for compatible | Whether to send `stream_options.include_usage`; override with `0` or `1` for the actual provider. Usage is parsed whenever received. |

These settings do not change a server's model, slot capacity or generation defaults. Existing host services are not reconfigured by this commit. Providers that reject streaming usage options should use `HARNESS_INCLUDE_USAGE=0`; there is no automatic generation retry.

## Request and budget contract

`ModelProvider` exposes `prepare`, `measure` and `complete`. Preparation freezes the request ID, system instruction, conversation, transformed terminal payloads, ordered tool schemas, model/template options and output reserve into a `PreparedModelRequest`. Count and generation receive the identical JSON bytes. Source messages and stored terminal output are not rewritten. Prepared bodies contain private data and are not Codable diagnostic records.

The optional llama.cpp profile sends the prepared body to `/v1/chat/completions/input_tokens`. With no configured limit, it also reads the model-scoped `/props?model=…&autoload=false` and uses `default_generation_settings.n_ctx`, not training context or slot count. Reverse-proxy path prefixes are preserved. Both reads run concurrently, have a three-second resource timeout and a one-MiB response limit, and refuse HTTP redirects. Capabilities are checked for each request rather than cached across server changes.

This implementation follows the pinned [llama.cpp count endpoint documentation](https://github.com/ggml-org/llama.cpp/blob/f3f1a8f2760f28325a5ec20c05b171e5b7c83a29/tools/server/README.md#post-v1chatcompletionsinput_tokens-token-counting) and [props contract](https://github.com/ggml-org/llama.cpp/blob/f3f1a8f2760f28325a5ec20c05b171e5b7c83a29/tools/server/README.md#get-props-get-server-global-properties). Count is a provider extension, not a universal compatible API. Support on the installed Home Rig build has not been verified or enabled by this increment.

- A valid count response is an exact observation of that prepared request at the count endpoint. It does not guarantee that the server configuration stays unchanged until generation.
- Otherwise, the budget uses a clearly labelled UTF-8 JSON bytes / 4 heuristic. This includes system/tools overhead but is neither a tokenizer nor a safe upper bound, especially across languages and templates.
- A previous successful prompt usage can calibrate that estimate only when the same provider envelope and complete message prefix match. Newly appended message bytes are estimated. Changing tools, model/template, editing history or replacing it with a summary invalidates the anchor. It is memory-only and does not survive engine recreation. It never becomes an exact current count.
- Missing capacity means no percentage, remaining count or fit verdict. A configured capacity keeps its configured provenance.
- The budget includes the output reserve. Only exact input count plus a known capacity can cause a local `CONTEXT_LIMIT` refusal. An over-budget estimate does not block generation.
- Unsupported count endpoints, timeout and malformed responses degrade to estimates with sanitized issue codes. Cancellation remains cancellation and never starts generation as a fallback.

`ReplyAssembly` consumes usage before examining choices, including final empty-choices frames after `finish_reason`. Repeated frames replace the usage snapshot instead of accumulating it. Prompt, completion and total counts remain optional; missing/null, negative, fractional, boolean, string or out-of-range values are not converted into token counts. Cached prompt and reasoning details are subsets of their parent counts. Contradictory totals/details become unknown. Usage does not bypass the required finish reason or `[DONE]` stream terminator.

`SessionEngine.contextBudget()` and `providerUsage()` expose the current request's in-memory observations, reset before the next preparation. C2 also attaches request metadata to diagnostic events and NativeWire stage events. Request and turn IDs match the engine journal. Queue, cancellation and recovery continue to use the same execution owner; a local overflow preserves the admitted prompt and never dispatches tools.

## Request inspector and retained diagnostics (C2)

The compact **Context** button above the conversation opens **Request details** in both Shell and Chat. Both views use the same session-bound request list. It includes:

- input tokens with exact/estimated/unknown provenance, capacity and its source, output reserve, and remaining space;
- provider-reported prompt/completion/total tokens and optional cached/reasoning subsets;
- request/turn IDs, purpose, preparation/measurement/response stages and sanitized result code;
- first headers/data/reasoning/text timings and final model-response time.

The bar includes input **plus the output reserve**. `≈` marks estimated input; missing capacity shows `?` and no percentage. Response timings start at host dispatch and include transport delays. They are not provider queue/prefill breakdowns or cache-hit measurements. Request elapsed time updates at observed milestones, not with a synthetic progress timer. Completed model timing is not inflated by subsequent tool execution or persistence. The inspector follows the latest request by default; a previous request can be selected explicitly.

Each stage carries an optional, self-contained request snapshot, written through the existing presentation journal before delivery. Final metadata survives reconnect and host restart; unfinished requests are marked interrupted without restarting inference. The UI shows the most recent 128 requests in that session. Older journal records remain stored, pending a separate retention/paging milestone. Older sessions and hosts without metadata show unavailable values rather than zero.

`DiagnosticTrace` and `DiagnosticArchive` each keep a separate bounded ledger of 128 request summaries and a dropped-request count. Overflow of the 256-event ring no longer loses a request's first milestones or final result. `harness --trace NEW_FILE` and `harness --inspect-trace FILE` retain the same request identity, budget, usage and timing semantics as the UI. Existing version-1 traces remain readable. New diagnostic stage strings survive decoding.

NativeWire preserves unknown envelope fields and the complete extensible request object during decode/encode/journal replay, including nested values and large integer values. Unknown significant operations/stages produce up to eight bounded protocol notes. Known PTY, session, approval and workspace control events are not reported as unsupported. Malformed/future request objects do not disconnect the client. Known numeric fields are validated before display or arithmetic.

**Share request diagnostics** exports an allowlist of scalar metadata. It excludes the raw extensible object, endpoint, headers, credentials, prompts, reasoning and tool output. The underlying conversation journal still contains private conversation and terminal data; it is not a diagnostic export.

## Durable context projection (C3)

The execution journal remains the source of truth for history, tool dispatch and recovery. `load(session:)` still returns original events. `loadSequenced(session:after:)` additionally exposes SQLite's global sequence numbers, filtered to one session; these are not array indexes or turn IDs.

The C3 migration takes an unversioned event database to schema version 1 in one transaction; C4 then adds operation receipts in schema version 2. It adds `context_state`, initializes each session's version from its existing model messages, and retains event bodies/sequences, workspace bindings and pending commands. It does not rewrite or delete source rows. Migration scans one event at a time. Reopening is idempotent; unsupported future database/projection versions fail explicitly. A failed migration rolls back its schema changes and version marker.

`loadContext(session:)` returns an immutable snapshot with the session ID, current version, optional projection and sequenced uncovered tail. Without a projection its messages equal the legacy history. A projection stores summary text, its covered source prefix and provenance (model, summary request IDs, creation time, source/applied versions). The model receives a labelled summary at user priority followed by uncovered messages. Summary text is neither a new system instruction nor a user-visible assistant answer; it contains no executable tool calls. The execution and presentation journals retain the complete original history.

`replaceContext(session:expectedVersion:through:summary:provenance:owner:)` atomically replaces the projection and appends a `context.compacted` audit carrying only range/version/provenance metadata. The audit has no `event.message`, so legacy transcript readers cannot add the summary on top of the full conversation. Source event rows are never changed. The SQLite transaction has no actor suspension point. It compares the current version and requires the active execution owner's token when a session is running; idle core callers may omit the token.

The version advances for every admitted model message (including inbox claims and recovery tool results), and once per successful projection replacement. Audit, raw PTY and pending inbox admission/removal do not advance it. Appending a message invalidates a *prepared replacement's version*, while the existing committed summary remains valid and the new message enters its uncovered tail. A replacement must extend a prefix of that same session, end at an actual model message and retain complete tool-call/result groups. Empty summaries, invalid provenance, stale versions and incomplete groups are rejected before mutation. Source versions and audit provenance roll back together if any write fails.

Recovery always reads the original execution log and closes unfinished tool pairs before the engine builds the projected history. `TOOL_OUTCOME_UNKNOWN` and `TOOL_NOT_STARTED` remain in the model's tail; historical tool calls are not dispatched again. The projection never writes to the Shell/Chat presentation journal, raw PTY output, drafts or pane state.

C3 supplies storage and consumption; C4 supplies the bounded compactor below. This is not journal retention: the original history continues to occupy disk space.

## Bounded compaction (C4)

`SessionEngine` automatically considers compaction at a model-step boundary when input plus output reserve reaches **90% of a known capacity**. It uses the same session execution owner as the conversation. It attempts at most one automatic operation per turn. Unknown capacity never invents a pressure threshold. If no older turns are eligible, the existing exact-overflow refusal / estimated-budget behavior remains. Failure of an attempted compaction stops that turn with a specific code and preserves its admitted messages.

`SessionDriver.compact(operationID:)` and `SessionEngine.compact(operationID:)` provide the manual core API. A new operation is accepted while idle; a competing conversation or maintenance operation receives `BUSY`. A previously admitted ID returns its persisted receipt instead of repeating summary generation, including after reconnect or process restart. Status reports compaction during both manual and automatic work. App/wire/CLI commands and buttons belong to C5.

Selection retains the **two most recent completed turns plus the current unfinished turn**. Legacy histories without turn markers are conservatively grouped at user messages. The older prefix is partitioned only at balanced message boundaries: an assistant's multiple tool calls and all their results stay together, and orphan/duplicate/incomplete groups are rejected. Recovery closes interrupted tool calls before manual selection. An automatic operation runs after the previous step's tool results have been stored.

The compactor merges a prior summary with bounded portions of historical records, with **no tool schemas enabled**. It measures candidate requests before dispatch, includes the actual output reserve and uses binary search to find fitting portions. Defaults allow at most **four summary generations** and **64 planning/dispatch measurements**, plus the initial baseline and final revalidation. `CompactionPolicy` can retain 1–16 recent turns, allow 1–8 generations and lower the measurement cap through the Swift API. These limits do not start unbounded retries. A protected tail or indivisible tool group that cannot fit produces a refusal, not hidden truncation.

Each summary must be a complete, nonempty assistant response with no tool calls or tool-result identity, and must reduce the serialized historical payload. The final **whole conversation request**, including normal tools/system/options and the retained tail, must fit and be smaller in both serialized bytes and comparable input counts. Counts keep their exact/estimated provenance. Estimated fit is still a heuristic, not a guarantee against provider rejection; the configured/server capacity remains explicit. Changing count provenance, capacity or prepared parameters during the operation causes rejection.

Before commit, preparation of the original and candidate requests is repeated and fingerprints/envelopes compared, then the candidate budget is measured again. The store checks the frozen source version, execution owner and admitted request fingerprint. Projection, provenance audit and completed operation receipt commit in one SQLite transaction. Queue/steer admission during summary awaits does not change model history; it stays pending and the normal driver consumes it after successful maintenance. Stop preserves unclaimed work for explicit resume.

Cancellation is checked after model responses, during final validation and immediately before the first projection write. That last check begins the indivisible commit section: if the transaction commits successfully, a later cancellation returns the saved success receipt. Cancellation before it rejects even a provider response that arrives late. Failed or cancelled summaries leave the previous projection untouched; a receipt-write failure also rolls back the projection/audit. On startup, schema-v2 operations left running become `interrupted` and never resume inference automatically.

Diagnostic request purposes distinguish `conversation`, `compaction` and `compactionValidation`. `superseded` marks preparation/counting that was not sent for generation, and `dispatched` identifies actual requests. Summary text and reasoning never enter the visible answer stream. A summary's lifecycle completion does not complete its enclosing agent turn. Operation receipts retain before/after budgets, source/applied versions, summary request count and sanitized failure codes.

Typical refusals are `CONTEXT_CAPACITY_UNKNOWN`, `CONTEXT_PROTECTED_TAIL_TOO_LARGE`, `CONTEXT_GROUP_TOO_LARGE`, `COMPACTION_REQUEST_LIMIT`, `COMPACTION_MEASUREMENT_LIMIT`, `COMPACTION_INVALID_SUMMARY`, `COMPACTION_NOT_SMALLER`, `CONTEXT_STILL_TOO_LARGE`, `CONTEXT_PARAMETERS_CHANGED` and `CONTEXT_STALE`. Storage and cancellation retain `STORAGE_FAILURE` / `CANCELLED`. This validates structural correctness and size; semantic summary quality still depends on the model.

## C4 verification

On 2026-09-08, `sh scripts/check.sh` passed with **121 Swift core/host tests**, all client protocol/Markdown/Shell checks and **11 mocked voice tests**. New tests cover bounded chunks, protected recent/open turns, multiple tool calls, oversized groups/tails, unknown and estimated counts, invalid/nonshrinking summaries, final-request overflow, generation/measurement limits, stale history/provider changes, two competing engines, queue/steer, cancellation before and after model output, cancellation after commit, transaction rollback and receipt recovery. Historical tool dispatch remains zero. Schema-v1 projections survive the v2 migration.

```sh
python3 scripts/probe-native-compaction.py
python3 scripts/probe-native-request-replay.py
```

The compaction probe runs the real CLI and compatible HTTP/SSE provider against an isolated deterministic server. It seeds an old unversioned database, forces four bounded summary requests, continues the conversation, restarts the process and checks reuse of the saved projection. All 24 original rows remain byte-identical. An incomplete summary is rejected without projection changes or tool execution. The fixture reports byte-based counts to exercise budgets; it is not a tokenizer benchmark or Home Rig evidence. The separate WebSocket/restart probe also passed for ordinary request metadata/replay.

Mac Catalyst and generic iOS Debug builds passed. No app installation, production migration/restart or Home Rig inference was performed. Manual `/compact` controls, full client interaction checks and physical iPad validation remain C5.

## C3 verification

On 2026-09-08, `sh scripts/check.sh` passed with **102 Swift core/host tests**, client protocol/Markdown/Shell/transcript checks and **11 mocked voice tests**. Added cases cover legacy migration/reopen with byte-identical source rows, retained workspace/inbox data, future schema rejection, migration rollback, global sequences/session boundaries, durable summary plus tail, version invalidation, atomic replacement/audit rollback through an injected SQLite trigger, failed message-batch rollback and complete multi-tool boundaries.

The engine test reopens a projected database with interrupted tools, repairs it, runs two new turns and verifies the exact model history and **zero historical tool dispatches**. The host recovery fixture separately checks retained Shell/Chat messages and byte-exact raw terminal output. The isolated WebSocket/host restart probe checks ordinary request metadata and replay through the migrated store; it does not exercise a compactor, which is not implemented yet.

No UI code changed in C3, so Mac/iOS builds and device checks were not repeated. Production databases/services and Home Rig were not touched.

## C2 verification

On 2026-09-08, `sh scripts/check.sh` passed with **89 Swift core/host tests**, client protocol/Markdown/Shell/transcript checks and **11 mocked voice tests**. The seven real-HTTP context probes also passed with assertions on final metadata, including preflight refusal, cancellation, timeout and truncated transport.

```sh
sh scripts/check-native.sh # also compiles the isolated WebSocket probe client
python3 scripts/probe-native-context.py
python3 scripts/probe-native-request-replay.py
```

The WebSocket probe starts its own loopback provider and Native Harness host in a temporary workspace/database. It verifies successful and HTTP-400 requests, exact count/capacity provenance, usage, first milestones, duplicate replay and host restart. Restart/replay must not generate another model request. `--hold` keeps only this test host alive for visual inspection until Enter is pressed. The temporary folder also contains `<session UUID>-events.json` replay files for the Debug UI mode below.

Mac Catalyst and generic iOS Debug builds passed. The actual Chat/Shell views and inspector were checked in a separate Mac test app using a recorded replay from the isolated host. This is fixture evidence, not a live Home Rig or physical iPad check. The production app/host and Home Rig configuration were not updated.

For repeatable offline UI diagnosis, a Debug build accepts `DSH_NATIVE_REPLAY=/absolute/path/events.json`: an array of NativeWire events beginning with `opened` and ending with `synced`, limited to 4 MiB. It renders the regular client views, creates no transport, and never runs shell commands. Use a separate test app identity to keep normal preferences isolated. Release builds do not include this mode.

## C1 verification

On 2026-09-08, `sh scripts/check.sh` passed: 84 Swift core/host tests, client protocol/Markdown/Shell/transcript checks and 11 mocked voice tests. New cases cover serialized system/tools/template inputs, terminal clipping, tool ordering, usage snapshots and numeric validation, known/unknown budgets, anchor invalidation, cancellation during measurement and the generation boundary.

Run the isolated real-HTTP checks with:

```sh
python3 scripts/probe-native-context.py
```

All seven scenarios passed: fit, overflow before generation, unsupported count, timeout, refused redirect, cancellation before generation and truncated final stream. The probe verifies identical count/generation bodies, retained original prompts and absence of incomplete assistant messages in the journal. Python is development tooling only; the native runtime adds no dependencies. No production model request, service restart, device installation or UI change was performed for C1.
