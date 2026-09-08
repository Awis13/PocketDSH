# SwiftTerm library subset

Upstream: https://github.com/migueldeicaza/SwiftTerm

Version 1.5.1, commit `0b8d99bd19b694df44e1ccaa3891309719d34330`. The complete `Sources/SwiftTerm` directory and MIT license are retained. The package manifest exposes only the library used by Pocket DSH; upstream's CLI/fuzzer/test products and their ArgumentParser dependency are not included.

Local source changes:

- `TerminalView.pressesBegan(_:with:)` is `open override` instead of `public override`. Pocket DSH consumes app shortcuts before SwiftTerm turns them into PTY bytes.
- iOS/Catalyst `TerminalView.characterFont` optionally supplies an explicit font for individual characters while building attributed lines. Pocket uses it only for Nerd Font private-use symbols: CoreText's ordinary fallback can return LastResort for these code points. The symbol face is fitted to one native text column, preserving grid alignment. The hook changes glyph selection, not terminal text or escape parsing.
- `getAttributes` applies the existing ANSI dim flag to foreground opacity. Completed blocks apply the same treatment.

When updating, compare sources against the pinned upstream revision, retain the license and reapply these small patches. Validate ordinary terminal input, Ctrl+C, Command+Enter, block navigation, Nerd Font BMP/supplementary glyphs during a running command and after completion, dim output, and the exact next command seen by the host.
