# Agent image output

Client-only Harness plugin registering the supported `tool.call.toolview` slot for `read_image`. Images load through `uiConversation.imageUrl(sessionId, attachment)`, preserving host authentication, session authorization and durable attachment caching. No new file server or public image URLs.

An image-capable model can call `read_image` on a real PNG/JPEG/WebP/GIF file. Pocket DSH renders image blocks from tool results directly in the transcript; the web plugin displays a thumbnail and native dialog. Harness may collapse completed tool calls under its process disclosure. Global agent usage guidance is in `~/.dsh/AGENTS.md`.

Installed through the web profile's dependency, bundle and symlink, matching dsh-voice. After client source changes, restart the web host while idle and reload the browser.

## Verification

Protocol checks cover tool images, multiple results, truncated history, malformed references, and assistant image blocks. The opt-in `testAgentImageOutput` UI test needs a server session containing an image result. Native authenticated attachment loading and fullscreen viewing have been exercised on simulator and device builds.
