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

Strictly layered; each package is `src/<name>/` with a `root.zig` barrel.

`acp-schema` (no deps) ← `acp` ← {`acp-async`, `acp-conductor`, `acp-test`} ← binaries.

- `src/acp-schema/` — wire types, JSON codec, unstable surfaces. Receives `build_options`.
- `src/acp/` — `Connection`, vtable `Transport`, comptime `Dispatcher`, `Session`, `TraceBuffer`, and the single `AcpError` set.
- `src/acp-async/` — newline framer, `BufferPair`, `FileTransport`, subprocess `Child`.
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

- **This repo diverges from `ZIGSTYLE.md` on three structural rules, unresolved.** Barrels are named `root.zig` (B.1.a says `module.zig`); files import siblings directly, e.g. `@import("transport.zig")` in `src/acp/connection.zig` (B.4.b says go through the barrel); several files export more than one type, e.g. `src/acp-schema/agent.zig` (B.2.a says one primary struct per file). Match the surrounding code rather than "fixing" a file to the guide mid-task; raise the conflict instead.
- **`make lint` is clean (0 findings) — keep it that way.** It runs two tools with different output formats, so read both: `zlint` prints boxed diagnostics, `zlintpre` prints bare `file:line:col:` lines. Left to themselves both walk the whole working directory and pull in ~276 findings from the vendored `zig-pkg/` cache, so the target feeds each an explicit file list instead. Never lint or edit `zig-pkg/` — it is a regenerable dependency cache and any edit is lost on the next fetch. Neither tool exits non-zero on warnings, so `make validate` passing is not by itself proof lint is clean; read the counts.
- `zlintpre`'s one check is "trailing comma in fn params": a trailing comma makes `zig fmt` keep a parameter list split across lines, and the tool wants it collapsed onto one line. Signatures here therefore run long (up to ~162 chars) — that is intended, and `line-length` is disabled in `styleguide/zlint.json` to match. Don't re-wrap them.
- **`zigvaxis` resolves from two places and `build.deps.zig` picks one.** That file is a copy-into-new-projects helper: `deps.resolveModule(b, "<name>", target, optimize)` returns the module to import, `deps.resolve(...)` the dependency itself. `dep_name` is comptime, so every derived name is built at compile time from the manifest convention: `.{name}` = pinned remote (what CI and consumers get), `.{name}_local` = `.path = "../{name}"` (the dev override). `-D<name>-source` selects `auto` (default — sibling if the directory exists, else the pin), `local`, or `remote`.
- **Module lookup tolerates a renamed export.** `resolveModule` wants a module named after the package; failing that, a package exporting exactly one module is taken to mean that module. This is load-bearing right now — the sibling exports `zigvaxis` while the pinned commit still exports `vaxis`, so `local` and `remote` builds find the module by different rules.
- **Copying `build.deps.zig` to another project has two easy-to-miss steps:** add it to `.paths` in `build.zig.zon` (or a fetched copy of the package imports a file that isn't there), and make sure format/lint cover it — it lives outside `src/`, which is why the Makefile globs `build*.zig`.
- Building with the sibling active makes Zig write cache artifacts **into `../zigvaxis`**. Use `-Dzigvaxis-source=remote` when that directory must stay untouched.
- **Requesting a missing path dependency is fatal, so probe before asking.** `lazy = true` does not help — Zig opens a path dependency the moment `lazyDependency` requests that key, and a missing directory ends the build. Merely *declaring* an absent path dep is harmless. That is why `build.deps.zig` checks for `../<name>/build.zig.zon` before choosing a key; don't collapse it back into a direct `lazyDependency` call, and don't weaken the probe to a bare directory check — the choice is irreversible, so a sibling that exists but isn't a package has to read as absent.
- After changing the fork, re-pin with `zig fetch git+https://github.com/inferise/zigvaxis#<commit>` and paste the printed hash into `.zigvaxis_pinned`. Local builds keep working from the sibling regardless, so a stale pin only shows up in CI.
- `src/acp-trace-viewer/` is the only consumer of `zigvaxis`; it is built conditionally, so if the dependency fails to resolve the `trace-viewer` step silently disappears from `zig build --list-steps`.
- `README.md`'s install snippet points at `MagnovaAI/acp-zig` while `origin` is `inferise/zigacp`. Both appear in history — confirm which is intended before editing either.
- `build.zig.zon`'s `.version` is the release source of truth; `make tag` scrapes it with `sed`.
- CI runs the suite twice: once default, once with 8 `unstable_*` flags on. A change that only compiles with flags off will pass locally and fail in CI.

## Not yet implemented

- **No real stdio transport in the public API.** The cookbook examples and `yopo` all run over an in-memory `PipePair`; `src/acp-cookbook/minimal_client.zig` says as much. Don't assume a process-to-process path exists.
- No web console — `make demo` runs the cookbook binaries, not a server.
- No `.claude/rules/`, skills, or hooks configured.
- Public API is unstable until tagged; wire format is already canonical.
