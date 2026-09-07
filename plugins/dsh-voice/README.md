# Pocket DSH voice input

Local Cordis plugin for DSH 0.1.2-rc.1. Adds a microphone to the conversation input slot and an authenticated audio relay used by Pocket DSH for iOS.

Hold the microphone to record up to two minutes. The waveform displays actual microphone amplitude. Release to transcribe and automatically send the recognized text to the current agent. Slide at least 65 points/pixels left and release to discard without uploading. Very short taps are discarded. Existing typed drafts and image attachments are preserved and are not included in the voice message. Cancel stops microphone capture or the HTTP request. A failed transcription keeps the recording available for Retry while the composer stays open. Switching task, closing the composer or backgrounding the iOS app cancels and discards the recording. Audio is not stored as a conversation attachment; only the automatically submitted transcript enters history. A failed send can be retried explicitly with the same request ID, without retranscribing or duplicating an acknowledged request.

Set `POCKET_DSH_ASR_URL` in the Harness process environment to your Whisper-compatible `/asr` endpoint. The default is `http://127.0.0.1:9000/asr`. The relay expects a multipart audio upload and a JSON response containing `text` and optional `language`. Whisper medium with faster-whisper has been used successfully; model hosting is separate from this plugin.

`POST /pocket-voice/transcribe`: audio bytes, supported audio Content-Type, normal DSH browser Cookie and Origin. Returns `{text, language}` or `{error}`. The host checks DSH authentication before reading the body, accepts at most 8 MiB and one in-flight request, and limits processing to 180 seconds. No arbitrary upstream URL is accepted from clients. The two-minute duration limit is enforced by the recording clients; the relay additionally enforces a byte limit.

The browser module uses the native `conversation.input.right` slot and authenticated `session/prompt` with a stable request ID. Pointer capture handles release outside the button, OS gesture cancellation and permission dialogs safely. Keyboard and screen-reader users can activate the microphone to start and activate it again to finish. iOS binds each recording to its starting endpoint/session and cancels on navigation.

## Local installation

Link this directory as `~/.dsh/profiles/web/node_modules/dsh-voice`, add its `link:` dependency and `dsh-voice` to the profile's `dsh.profile.bundles`, then restart DSH when no tasks are running. Existing profile settings are preserved. The package has no npm dependencies; its browser module consumes DSH's existing React runtime.

## Verification

- `node --test plugins/dsh-voice/voice.test.mjs`: authentication, multipart relay, invalid and oversized recordings, no-speech handling, failure/retry, busy/timeout handling voice-only request identity, release-to-send, swipe cancellation, OS cancellation and release before microphone permission.
- `node scripts/check-voice-live.mjs`: opt-in test against the local DSH relay using `/tmp/pocket-dsh-voice-check.aiff`; uses the current local launch URL without logging credentials.
- `Tests/LiveVoiceCheck.swift`: opt-in native URLSession/M4A integration check with `DSH_LIVE_LOG` and `DSH_VOICE_AUDIO`.
- `PocketDSHUITests.testVoiceRecordingCanBeCancelled`: native hold-and-swipe cancellation without uploading or submitting a message.
