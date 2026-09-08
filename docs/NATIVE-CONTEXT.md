# Native model request accounting

C1 prepares and measures model requests in HarnessCore. C2 exposes those observations in the shared Shell/Chat indicator and request inspector, and preserves them in diagnostic and presentation journals. General history compaction remains C3–C5; the conversation is still retained and sent in full, with the existing bounded terminal excerpt transformation.

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
