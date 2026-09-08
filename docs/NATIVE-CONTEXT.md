# Native model request accounting

The first context milestone (C1) prepares and measures model requests in HarnessCore. Client indicators, durable request metrics and general history compaction are later commits; the conversation is still retained and sent in full, with the existing bounded terminal excerpt transformation.

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

`SessionEngine.contextBudget()` and `providerUsage()` expose the current request's in-memory observations for the next client/diagnostic integration. They are reset before the next preparation; they are not yet wired into NativeWire or persisted. Existing request IDs are shared with diagnostics. Queue, cancellation and recovery continue to use the same execution owner; a local overflow preserves the admitted prompt and never dispatches tools.

## Verification

On 2026-09-08, `sh scripts/check.sh` passed: 84 Swift core/host tests, client protocol/Markdown/Shell/transcript checks and 11 mocked voice tests. New cases cover serialized system/tools/template inputs, terminal clipping, tool ordering, usage snapshots and numeric validation, known/unknown budgets, anchor invalidation, cancellation during measurement and the generation boundary.

Run the isolated real-HTTP checks with:

```sh
python3 scripts/probe-native-context.py
```

All seven scenarios passed: fit, overflow before generation, unsupported count, timeout, refused redirect, cancellation before generation and truncated final stream. The probe verifies identical count/generation bodies, retained original prompts and absence of incomplete assistant messages in the journal. Python is development tooling only; the native runtime adds no dependencies. No production model request, service restart, device installation or UI change was performed for C1.
