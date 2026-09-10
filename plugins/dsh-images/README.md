# Agent image output

Client-only plugin for Harness 0.1.3-alpha.2. Registers a `dsh-image-gallery` conversation projection and a `conversation.chat.node` renderer. Completed turns with a closing assistant show durable tool-result images immediately after the answer, before its action footer. The gallery stays visible when the process disclosure is collapsed, and leaves the built-in tool image viewer and produced-file footer intact.

Images use the Chat node's session-authorized `loadImage` callback. The plugin does not resolve filesystem paths or Markdown URLs, expose a file server, or change stored messages. Replacement surface events and failed tool results are excluded; attachment IDs are deduplicated within each turn. The gallery requires a closing assistant in the loaded history; tool images remain available in the built-in tool view otherwise.

The web profile depends on this package. Its node_modules link may point to a staged copy under `~/.dsh/local-plugins/`, so inspect the actual symlink before deploying. Update both the source package and that installed copy, restart the authorized idle web host, and reload the browser. Keep a copy of the old client and manifest for rollback.

## Verification

Run `node plugins/dsh-images/client.test.cjs` from the repository root for attachment validation, deduplication, errors, nested results, replacement exclusion, incomplete history, and placement before the footer.

On 2026-09-10 the installed plugin was verified after a web-host restart in an existing session: the camera image rendered with `5 tool calls` collapsed, the image dialog opened at full size and closed, and the Branch action remained enabled. The change is web-only; no native client rebuild is required.
