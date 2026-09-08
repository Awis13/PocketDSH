# Harness comparison — local mini-benchmark

| Scenario | Engine | Correct | First visible output, median s | First answer text, median s | Completion, median s | Tool calls |
|---|---|---:|---:|---:|---:|---:|
| short | native | 2/2 | 1.93 | 2.26 | 2.31 | 0.00 |
| short | dsh | 2/2 | 4.18 | 4.84 | 4.91 | 0.00 |
| inspect | native | 2/2 | 0.59 | 5.52 | 6.50 | 4.50 |
| inspect | dsh | 2/2 | 2.56 | 17.60 | 18.81 | 4.50 |
| fix | native | 2/2 | 0.47 | 9.44 | 10.53 | 5.00 |
| fix | dsh | 2/2 | 2.62 | 23.33 | 28.04 | 7.00 |
| long | native | 2/2 | 0.71 | 1.41 | 14.58 | 0.00 |
| long | dsh | 1/2 | 2.61 | 3.78 | 17.68 | 0.00 |

## Method and limits

- Two fresh sessions per scenario and engine, alternating order. One run at a time. Same Home Rig qwen3.8-27b endpoint. Setup and compilation excluded from turn timing.
- Separate copies of the same four-file Python fixture. Fix correctness checked by unchanged test files, four unit tests, and independent holdout boundary cases.
- Short-answer correctness requires exact BENCH_READY; investigation must identify 30 seconds, POCKET_CACHE_TTL, and is_fresh; long output requires exactly 100 specified lines.
- These are current product configurations: DSH has a larger system prompt, more tools/plugins and reasoningEffort=xhigh. Native uses its small tool set and temperature 0.1. This is not a language-only or equal-prompt comparison.
- DSH live assistant-stream was explicitly enabled. Its current protocol otherwise only sends the committed assistant message to this follow subscriber. The older Pocket DSH subscription lacks this option; that UI integration issue is separate from engine throughput.
- Cache was not flushed, model was not unloaded, and external server traffic was not locked out. Treat this as alternating warm/mixed-cache operation, not controlled cold-start evidence.
- First output means a received reasoning/text delta or tool call. First text excludes reasoning. Completion is the engine end marker. Approval decisions were immediate for these authorized fixture tasks.
- Wire stream timing is measured here; UI frame rate, scrolling responsiveness and physical iPad rendering are not measured. Two samples per scenario are preliminary, not a stable population estimate.
- Raw event logs, prompts, individual results and validation output accompany this report. Failed instrumentation attempts are stored separately and excluded.

## Additional findings

All code-reading and code-fixing runs passed. Native met all 8 exact-format/task checks. DSH met 7/8: its second long-output run produced all 100 correct numbered lines but omitted the final period on each line. This is a formatting failure, not evidence of inferior coding ability.

Cancellation was measured once per engine after receiving the first answer text. Native: 3.51 ms; DSH: 21.97 ms. These are cancel-request-to-engine-end-event times, not physical-device UI latency or direct GPU-stop telemetry.

DSH short requests carried 16,576 logical input tokens in both scored runs. Cache accounting: first run 14,958 cached + 1,618 uncached; second run 16,064 cached + 512 uncached. Large logical context does not mean it was all recomputed. DSH registered 39 tools; the native host exposes 7. Native per-request token usage is not exposed by the current wire and was not captured; missing is not zero.

An unscored DSH setup probe took 43.16 seconds with 16,390 reported input tokens and no cache-read entry. It used a different subscription and is excluded from paired timings; it is not a controlled model cold-start measurement.

Native generation settings in source: temperature 0.1 and max_tokens 4096, thinking not disabled. DSH request headers: homerig/qwen3.8-27b with reasoningEffort=xhigh. Different prompts, tools, inference settings, model verbosity and cache reuse can explain much of the measured difference. This experiment does not isolate Swift/Node runtime overhead.

The DSH stream compatibility finding is recorded, not fixed as part of this benchmark. The current `PocketStore.followSelected()` requests session/follow without assistantStream. The installed DSH 0.1.3-alpha.2 protocol requires assistantStream=true for process-local live frames; a client also needs to fold assistant-stream frames and reconcile their committed messages.

## Reproduction

Compile `tests/HarnessBenchmark.swift` with `PocketDSH/HarnessProtocol.swift`, `PocketDSH/HarnessAPI.swift`, and `Shared/NativeWire.swift`; run `scripts/benchmark-harness.py`. It creates isolated output fixtures and benchmark-only DSH sessions. No model installation, server cache flush, or production project edit is needed.

Scored raw evidence: `output/harness-benchmark/20260908-122746/`. Cancellation evidence: `output/harness-benchmark/20260908-123200/`. Aborted instrumentation trial: `output/harness-benchmark/20260908-122407/` (excluded). No new dependencies installed. Existing DSH and the user-facing Native host were not restarted; per-run benchmark Native hosts were stopped.
