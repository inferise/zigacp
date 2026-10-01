# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native Zig implementation of the **Agent Client Protocol** (ACP) — JSON-RPC 2.0 over a newline-delimited transport, spoken between code editors and coding agents. Ships wire types, a synchronous SDK, proxy orchestration, a reference agent, and a schema generator. See `README.md` for the public API surface.

Zig **0.16.0** exactly (`.minimum_zig_version` in `build.zig.zon`); CI pins it on ubuntu + macOS. The codebase uses 0.16-era APIs (`std.Io`, `b.addTest(.{ .root_module = ... })`, `@typeInfo(T).@"struct"`) — read `styleguide/ZIGMIGRATE.md` before porting anything that looks pre-0.16.

**Never run git commands unless explicitly asked.** No commits, branches, tags, pushes, or `make tag`.

## Build / Test

`make` is the entry point; `make validate` (clean → format → lint → build → test) is the pre-commit gate.

```sh
make build                                 # zig build
make test                                  # zig build test --summary all
make validate                              # full gate before handing work back
zig fmt --check build.zig src/ tools/      # exactly what CI enforces
zig build yopo                             # reference agent contract suite
zig build demo                             # cookbook client + agent examples
zig build gen-schema -- /tmp/schema.json   # schema catalog (omit arg for stdout)
```

Run one test file directly: `zig test src/acp/connection.zig` won't resolve imports — use `zig build test --summary all` and read the per-module breakdown, or temporarily narrow the `test` block.

`make lint` runs `zlintpre` then `zlint -c styleguide` (config: `styleguide/zlint.json`), each scoped to `build.zig src/ tools/`. Both tools are installed org-wide under `/usr/local/inferise/`, not vendored here.

## Module layout

Strictly layered; each package is `src/<name>/` with a `module.zig` barrel.

`acp-schema` (no deps) ← {`acp`, `acp-mcp`}; `acp` ← {`acp-async`, `acp-conductor`, `acp-test`} ← binaries.

- `src/acp-schema/` — wire types, JSON codec, unstable surfaces. Receives `build_options`.
- `src/acp/` — `Connection`, vtable `Transport`, comptime `Dispatcher`, `Session`, `TraceBuffer`, and the single `AcpError` set.
- `src/acp-async/` — newline framer, `BufferPair`, `FileTransport`, `StdioTransport` (a reader task queues frames so a blocked handler can poll mid-turn) and the `Config` it borrows, subprocess `Child`.
- `src/acp-mcp/` — all MCP logic. Only MCP types that are part of the ACP spec (`McpServerConfig` and its shapes) live in `acp-schema`; anything that *does* something with an MCP server goes here.
- `src/acp-conductor/` — interceptor chain (pass / short-circuit / drop).
- `src/acp-test/` — `PipePair` in-memory transport + `contract_handshake.zig`.
- `src/yopo/main.zig` — reference agent; the executable contract spec.
- `tools/gen_schema/` — comptime-reflective schema catalog emitter.

Do not hand-edit: `zig-pkg/`, `.zig-cache/`, `zig-out/` (all generated, all gitignored). `styleguide/` is a git submodule — change it in `inferise/styleguide`, never in place.

## Architecture conventions

- **`AcpError` is the only error type crossing a package boundary.** Never `anyerror!T` in a public signature.
- Every owning type takes an allocator and exposes a matching `deinit`. No globals, no hidden heap. Tests use `std.testing.allocator`; zero leaks is a merge requirement.
- Public tagged unions carry an `unknown: std.json.Value` variant so a newer peer never crashes an older one. Adding a variant means keeping that bucket intact.
- `Connection.init` **borrows** its transport — the caller closes it.
- Tracing never blocks the protocol path: trace failures become `log.warn`, not returned errors.
- Every unstable protocol method is compile-gated behind its own `-Dunstable_*` flag (14 of them in `build.zig`'s `UnstableFlags`), default off, read via `@import("build_options")`. Gated tests self-skip with `return error.SkipZigTest`. Adding an unstable method means adding a flag, not exposing it unconditionally.
- `@styleguide/ZIGSTYLE.md` is the authoritative Zig style guide — read it before writing Zig. Highlights: no namespace shorteners (`const mem = std.mem;` is banned, `const Self = @This();` is the only alias), enum variants are camelCase, every file declares a scoped logger, tests live at the file bottom after a `// ---` divider, prefer `std.Io` over `std.posix`.

## Project-state heads-ups

- **Older files still diverge from `ZIGSTYLE.md`; new and touched code must not.** Barrels are now `module.zig` everywhere (B.1.a). Many older files still import siblings directly and alias them (`const Plan = @import("plan.zig").Plan;`, against B.4.a/B.4.b), and some hold several primary types (`src/acp-schema/agent.zig`, `client.zig`, against B.2.a). Code you add or a type you change goes through `const mod = @import("module.zig");`, one primary struct per file named for it.
- **Wire field names vs C.2.** ZIGSTYLE wants snake_case fields; ACP's JSON is camelCase. New and changed wire structs use snake_case fields and route their `jsonStringify`/`jsonParse`/`jsonParseFromValue` through `acp-schema`'s `WireCase`, which maps `config_id` ↔ `configId`. Older structs still use camelCase field names directly. `SessionUpdate` variants are camelCase in Zig (`.agentMessageChunk`) and keep their snake_case wire tags.
- **`make lint` is clean (0 findings) — keep it that way.** It runs two tools with different output formats, so read both: `zlint` prints boxed diagnostics, `zlintpre` prints bare `file:line:col:` lines. Left to themselves both walk the whole working directory and pull in ~276 findings from the vendored `zig-pkg/` cache, so the target feeds each an explicit file list instead. Never lint or edit `zig-pkg/` — it is a regenerable dependency cache and any edit is lost on the next fetch. Neither tool exits non-zero on warnings, so `make validate` passing is not by itself proof lint is clean; read the counts.
- `zlintpre`'s one check is "trailing comma in fn params": a trailing comma makes `zig fmt` keep a parameter list split across lines, and the tool wants it collapsed onto one line. Signatures here therefore run long (up to ~162 chars) — that is intended, and `line-length` is disabled in `styleguide/zlint.json` to match. Don't re-wrap them.
- **`zigvaxis` is a single path dependency: `.zigvaxis = .{ .path = "../zigvaxis" }`.** `build.zig` uses `b.dependency("zigvaxis", ...).module("zigvaxis")` directly — no pinned remote, no fallback. The sibling checkout must exist at `../zigvaxis` (locally and in CI), or the build fails. Ignore the `.clone` field in `build.zig.zon`; stock Zig doesn't use it.
- Building makes Zig write cache artifacts **into `../zigvaxis`**.
- `src/acp-trace-viewer/` is the only consumer of `zigvaxis`.
- `README.md`'s install snippet points at `MagnovaAI/acp-zig` while `origin` is `inferise/zigacp`. Both appear in history — confirm which is intended before editing either.
- `build.zig.zon`'s `.version` is the release source of truth; `make tag` scrapes it with `sed`.
- CI runs the suite twice: once default, once with 9 `unstable_*` flags on. A change that only compiles with flags off will pass locally and fail in CI.

## Not yet implemented

- **The cookbook and `yopo` still run over an in-memory `PipePair`.** The process-to-process path is `StdioTransport`, exercised by its own tests against a real `/bin/cat` and by `../zigagent`'s `zagent --acp=<agent>`; nothing in this repo's binaries uses it yet.
- No web console — `make demo` runs the cookbook binaries, not a server.
- No `.claude/rules/`, skills, or hooks configured.
- Public API is unstable until tagged; wire format is already canonical.
