# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native Zig implementation of the **Agent Client Protocol** (ACP) — JSON-RPC 2.0 over a newline-delimited transport, spoken between code editors and coding agents. Ships wire types, a synchronous SDK, the client session, relay and analytics machinery, proxy orchestration, a single-agent terminal screen (`acp-tui`), a reference agent, and a schema generator. See `README.md` for the public API surface.

Zig **0.17.0** exactly (`.minimum_zig_version` in `build.zig.zon`); CI pins it on ubuntu + macOS. The codebase uses 0.17-era APIs (`std.Io`, `b.addTest(.{ .root_module = ... })`, `@typeInfo(T).@"struct".field_names`) — read `styleguide/ZIGMIGRATE.md` before porting anything that looks pre-0.17.

**Never run git commands unless explicitly asked.** No commits, branches, tags, pushes, or `make tag`.

## Build / Test

`make` is the entry point; `make validate` (clean → format → lint → build → test) is the pre-commit gate.

```sh
make build                                 # zig build
make test                                  # zig build test --summary all
make validate                              # full gate before handing work back
zig fmt --check src/ tools/           # exactly what CI enforces
zig build yopo                             # reference agent contract suite
zig build demo                             # cookbook client + agent examples
zig build gen-schema -- /tmp/schema.json   # schema catalog (omit arg for stdout)
```

Run one test file directly: `zig test src/acp/connection.zig` won't resolve imports — use `zig build test --summary all` and read the per-module breakdown, or temporarily narrow the `test` block.

`make lint` runs `zlintpre` then `zlint -c styleguide` (config: `styleguide/zlint.json`), each scoped to `build.zig src/ tools/`. Both tools are installed org-wide under `/usr/local/inferise/`, not vendored here.

## Module layout

Strictly layered; each package is `src/<name>/` with a `module.zig` barrel.

`acp-schema` (no deps) ← `acp` ← {`acp-mcp`, `acp-async`, `acp-conductor`, `acp-test`} ← the `zigacp` barrel ← `acp-tui` (with `zigtui`) ← binaries.

- `src/acp-schema/` — wire types (every request, response and notification carries `_meta`), JSON codec, the still-unstable surfaces. Receives `build_options`.
- `src/acp/` — `Connection` (writes with `wire_options`: unset optionals omitted; `request` results own their memory), vtable `Transport`, `Dispatcher` (typed handler structs, or `registerRequestFn(method, context, f)`), `RawPeer`/`RawMessage` (a peer that hands back whole parsed frames, for proxies), `ScriptedPeer` (a scripted test transport), `Session`, `TraceBuffer`, and the single `AcpError` set.
- `src/acp-async/` — newline framer (16 MiB frame cap), `BufferPair`, `FileTransport` (EOF is `TransportClosed`; frames past the cap dropped), `StdioTransport` (a reader task queues frames so a blocked handler can poll mid-turn) and the `Config` it borrows, `LocalSeam(Agent)` (an agent served on one end of an in-process pair, torn down in order), subprocess `Child`.
- `src/acp-mcp/` — all MCP logic: `McpServer`, `McpHttpServer` (Streamable HTTP on loopback; the host passes its tool table and `ServerInfo`), `RelayTools` (`report_progress`, `ask_user`). Only MCP types that are part of the ACP spec (`McpServerConfig` and its shapes) live in `acp-schema`.
- `src/acp-conductor/` — interceptor chain (pass / short-circuit / drop; reply interceptors see a reply with the method it answers) and `Pairing(T)`, which matches each reply to its request, one table per direction.
- `src/module.zig` — the `zigacp` barrel, plus what sits above the protocol: `acp.Meta` (`read`/`of` for `_meta`, shared keys), `acp.Inferise` (the `_inferise/*` extension), `acp.Client.Fs`, `acp.Client.Terminal` (pipes), `acp.Client.PtyTerminal` and `acp.Pty` (`pty_session.zig`, `vt_decoder.zig`, `vt_screen.zig`: a pseudoterminal and the screen it draws; `pty_login.zig`: `Pty.Login`, a CLI's sign-in on a pseudoterminal for a harness to relay over `_inferise/sign_in`). `acp.Inferise` includes the tool identity (`Tool`), the account list (`_inferise/accounts`) and sign-in (`_inferise/sign_in`, `sign_in_finish` polled, `sign_in_cancel`). The barrel's code names no harness; docs and fixtures may.
- The barrel's moved machinery, flat in `src/` and named by namespace: `client_session.zig` (`acp.Client.Session`), `client_settings.zig`, `client_history.zig` (`Client.History`, where finished turns go), `client_sign_in.zig` (`Client.SignIn`), `client_seam.zig` (`Client.Seam(Agent)`); `analytics_*.zig` (`acp.Analytics.*`: `Observer`, `TapTransport`, `EventDecoder`, `Recorder`, sinks, `ContentRedactor`, `AgentIdentity`); `relay_*.zig` (`acp.Relay.*`: `Proxy`, `Downstream(Agent)`, `Router` and its `RouterRoute`/`RouterWaiter`/`RouterHooks` — a multiplexing proxy's id and session rewriting, its owner's hook sees each frame a route sends, `SessionLog`, `UsageNormalizer`); `mcp_offer.zig` (`acp.McpOffer`); `test_echo_agent.zig` (`acp.Test.EchoAgent`, a scripted agent for client tests and demos).
- `src/tui/` — the `acp-tui` module: `Conversation`, `ConversationView`, `ChatPane` (one conversation folded, scrolled and drawn; a multi-agent screen keeps one per agent), `AgentChat` (the single-agent screen, around a `ChatPane`), `AgentMain(Agent)` and `Launch` (what every harness executable does: the screen, or ACP on stdio). It imports the `zigacp` barrel and `zigtui`; nothing else in zigacp imports `zigtui`.
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
- Protocol surface ACP has not stabilized is compile-gated behind its own `-Dunstable_*` flag (5 of them in `build.zig`'s `UnstableFlags`), default off, read via `@import("build_options")`. Gated tests self-skip with `return error.SkipZigTest`. Adding an unstable method means adding a flag, not exposing it unconditionally; once ACP stabilizes it (check `schema/v1/schema.json` in agent-client-protocol), the flag goes and it is always built. The exception: where ACP's unstable surface replaces an `acp.Inferise` item, zigacp uses it with no flag and that surface's flag goes (see "Decided against the ACP schema"). Consumers request zigacp with no flags.
- `@styleguide/ZIGSTYLE.md` is the authoritative Zig style guide — read it before writing Zig. Highlights: no namespace shorteners (`const mem = std.mem;` is banned, `const Self = @This();` is the only alias), enum variants are camelCase, every file declares a scoped logger, tests live at the file bottom after a `// ---` divider, prefer `std.Io` over `std.posix`.

## The ACP seam

zigacp owns all of the seam: the wire, `acp.Inferise`, and the client, relay, analytics and terminal-chat machinery (moved here from `../zigagent`; only the meta-agent's routing is still there). Every other repo is a consumer: a harness is an agent whose executable is also a chat with it (`acp-tui`), and zigagent is a client and an agent (a proxy). `README.md` holds the contract — the architecture, each role's obligations and the `_inferise` vocabulary table; keep it current when the wire changes. When writing seam code:

- **Branch on what the agent advertised or sent, never on which agent it is.** No harness name, `AgentKind` or `_meta.<harness>` key in `src/`. A per-agent difference becomes a capability, an `acp.Inferise` field, or a parameter the consumer passes. "Harness or native" is decided the same way: an agent that advertised `agentCapabilities._meta.inferise` takes `_meta.instructions`; usage is read from `_meta.inferise.usage` when the frame carries it, else from `usage_update`.
- **Advertise, then call — both ways.** A client calls an `_inferise/*` method only when the agent advertised it, and draws a part of its screen only when the agent advertised or sent it. A relay sends a host `elicitation/create` or a `notice` only when the host's `initialize` advertised `clientCapabilities.elicitation.form` or `session.notices`; the meta-agent passes exactly those two host capabilities to each subagent's relay.
- **Standard ACP first.** Reach for `acp.Inferise` only when ACP has no field: a boolean config option beats a `_meta` flag, `usage_update` beats a private usage key, `ToolCall.name` beats `_meta.inferise.tool.name`, `elicitation/create` beats a private question, a `notice` beats a private progress report.
- **An account is a name the agent resolves.** A client sends `_meta.inferise.account.name` and knows no agent's homes; each harness maps the name onto its own and refuses one it does not have with `InvalidParams`.
- **Adding to `acp.Inferise`** means four things: the member name constant, a type routed through `WireCase` (camelCase on the wire), a `read*` helper if it rides in `_meta`, and a round-trip test. A new `_inferise/*` request also gets a `Capabilities` flag. Optional fields stay optional: absent means "not reported", never zero. Then add its row to `README.md`'s vocabulary table.
- **Observers and taps never block, steer or fail the protocol path.** Copy the frame, then queue it. A full queue drops and counts. Errors become `log.warn`.
- **A relay forwards what it cannot parse** and pairs replies per direction (`Conductor.Pairing`). Requests run both ways.
- **Long-lived tasks (pumps, readers, decode loops) start with `io.concurrent`**, and a failure to get a task is a failed start. `io.async` runs inline once the pool's slots are taken, so a pump started that way never returns to answer its request (it hung zigcodex's `session/new`).
- **The protocol takes no UI.** Only `acp-tui` (`src/tui/`) imports `zigtui`; the `zigacp` module never does, and `zigtui` must never depend on zigacp (it would be a cycle). A harness links `acp-tui` into its executable, never its library.
- **The launch rule is `acp-tui`'s `Launch`, for every harness and `zagent`:** `app acp` (or `--acp`) serves ACP; a bare `app` serves ACP when stdin and stdout are both pipes, opens the chat on a terminal, refuses half a terminal. Never add a `tui` argument. Accepted edge case: Windows mintty and Cygwin terminals look like pipes, so a bare `app` there serves ACP; run it from Windows Terminal or under `winpty`.
- **Moving code in from zigagent** (the meta-agent's routing is what remains): rename its logger to `.acp_<file>`; replace inferred error sets and `anyerror` at the boundary with `AcpError`; turn zigagent types (`Transcript`, `AgentBackend`, `InferiseTools`) into parameters, vtables or callbacks; disk access through `zigstorage`; bring its tests along — a test that needs a real harness stays in zigagent, since zigacp cannot link one. zigagent keeps an alias under the old name in its `src/module.zig`.
- **Tests never start a real sign-in.** Grok and Copilot open a browser on the operator's screen whatever `PATH` says. Drive `Pty.Login` against `/bin/sh` instead. Tests drive a client against `acp.Test.EchoAgent`, never a real agent.
- **Fixtures compare parsed values, not bytes**: agents may order `_meta` members differently.

### Decided against the ACP schema (v1 1.25.0, 2026-10-09)

Re-check `schema/v1/schema.json` and `schema.unstable.json` in agent-client-protocol when ACP moves. Where ACP has an equivalent of an `acp.Inferise` item, stable or unstable, zigacp uses it with no flag.

- **Swapped:** `_meta.inferise.tool.name` → `ToolCall.name` / `ToolCallUpdate.name` (readers fall back to `_meta` for older agents; `server` and `agent` stay in `_meta.inferise.tool`). `_inferise/ask_user` → `elicitation/create` form mode (one field, `answer`; options as its `enum`). `_inferise/progress` → a `notice` update (percent and confidence in its `description`).
- **Not swapped, needs a decision:** tokens in `PromptResponse.usage` (unstable) — the response says "this turn", every `Usage` field says "across all turns". Accounts and sign-in — a sign-in could be `authenticate` raising a request-scoped URL elicitation, but ACP has nothing for a list of named accounts.
- **Kept:** `_meta.inferise.subagent` (ACP's unstable `SubagentUpdate` models a child session the host sees; the meta-agent hides them behind the group's). `TurnMeta.failure` (ACP's `ErrorStopReason` is a child session's state). `TurnMeta.denied` (a turn's result, not a live notice a host may drop). Status, extensions, `logDir`, `trustedMcpServers`, `turn`, account, interject, run ended, background tasks (no ACP field).

### Lessons

Each of these cost a debugging session.

- **ACP's `authenticate` alone cannot carry a sign-in**: one request, one answer, while agy waits a minute for a pasted code and Copilot and Codex show device codes. Hence the `_inferise/sign_in` trio, polled every ~2 s so a client can cancel or send a code between polls.
- **Grok's device URL carries the code** (`…/oauth2/device?user_code=<code>`), unlike its documentation: parse what the CLI prints.
- **Tool names collide across servers.** Grok has a built-in `spawn_subagent` and used it instead of the `inferise` server's; tool descriptions and prompts name the server.
- **A headless agent refuses silently.** agy with always-approve off refuses `run_command` and ends with an empty answer; the refusal is only in `TurnMeta.denied`, which a client turns into a note.
- **AFM reopens only with a store.** Started without one it advertises no `loadSession`.
- **A replay is history.** Updates during a client's own `session/load` are gathered, not drawn as a live turn.
- **Identical dependency options everywhere.** One repo passing other options to `zigacp`, `zigtui`, `zigwui` or `zigstorage` mints a second copy (`file exists in modules 'acp' and 'acp0'`).
- **vaxis quits by asking the terminal.** Its input thread is woken with `ESC[5n`; a test pseudoterminal that never answers it never exits. A pty harness answers `ESC[5n` and `ESC[6n` as a terminal does.
- **A test that fails while an agent waits on a permission hangs**: the handler waits uncancelably. Answer first, then check.
- **A screen's draw path is not in its tests.** zigagent's `zig build test` passed while `zig build` of its executable failed on an error set; build the executables too.

## Project-state heads-ups

- **Older files still diverge from `ZIGSTYLE.md`; new and touched code must not.** Barrels are now `module.zig` everywhere (B.1.a). Many older files still import siblings directly and alias them (`const Plan = @import("plan.zig").Plan;`, against B.4.a/B.4.b), and some hold several primary types (`src/acp-schema/agent.zig`, `client.zig`, against B.2.a). Code you add or a type you change goes through `const mod = @import("module.zig");`, one primary struct per file named for it.
- **Wire field names vs C.2.** ZIGSTYLE wants snake_case fields; ACP's JSON is camelCase. New and changed wire structs use snake_case fields and route their `jsonStringify`/`jsonParse`/`jsonParseFromValue` through `acp-schema`'s `WireCase`, which maps `config_id` ↔ `configId`. Older structs still use camelCase field names directly. `SessionUpdate` variants are camelCase in Zig (`.agentMessageChunk`) and keep their snake_case wire tags.
- **`make lint` is clean (0 findings) — keep it that way.** It runs two tools with different output formats, so read both: `zlint` prints boxed diagnostics, `zlintpre` prints bare `file:line:col:` lines. Left to themselves both walk the whole working directory and pull in ~276 findings from the vendored `zig-pkg/` cache, so the target feeds each an explicit file list instead. Never lint or edit `zig-pkg/` — it is a regenerable dependency cache and any edit is lost on the next fetch. Neither tool exits non-zero on warnings, so `make validate` passing is not by itself proof lint is clean; read the counts.
- `zlintpre`'s one check is "trailing comma in fn params": a trailing comma makes `zig fmt` keep a parameter list split across lines, and the tool wants it collapsed onto one line. Signatures here therefore run long (up to ~162 chars) — that is intended, and `line-length` is disabled in `styleguide/zlint.json` to match. Don't re-wrap them.
- **Two path dependencies: `../zigstorage`, and `../zigtui` (lazy).** `build.zig` uses `b.dependency(...)` on zigstorage and `b.lazyDependency(...)` on zigtui — no pinned remote, no fallback. Both sibling checkouts must exist (locally and in CI), or the build fails; zigtui brings `../zigvaxis`. zigtui is lazy and ungated: fetched with the package, compiled only by a consumer of `acp-tui`. Stock Zig ignores the `.clone` fields in `build.zig.zon`; `zigbuildx.Deps.cloneMissing` reads them, clones a missing sibling, and exits asking for a re-run.
- **One build-only dependency: `zigbuildx`**, pinned by `.url` + `.hash`, never `.path` — it holds the code that clones missing siblings, so it cannot itself be one. Imported from `build.zig` only, never from `src/`. Moving it to a newer version is `zig fetch --save` and nothing else.
- `zigstorage` is requested with target and optimize only — the options every other consumer passes, or a harness linking both mints a second copy. The `zigacp` barrel imports it (`src/client_fs.zig`), as does `gen-schema`.
- `README.md`'s install snippet points at `MagnovaAI/acp-zig` while `origin` is `inferise/zigacp`. Both appear in history — confirm which is intended before editing either.
- `build.zig.zon`'s `.version` is the release source of truth; `make tag` scrapes it with `sed`.
- CI runs the suite twice: once default, once with all 5 `unstable_*` flags on. A change that only compiles with flags off will pass locally and fail in CI.
- `acp.Pty.Session` and `acp.Pty.Pair` call libc's `openpty`: a consumer that uses them links libc. So does a consumer of `acp.Client.Session`, which serves `terminal/*` on a pseudoterminal outside Windows.

## Not yet implemented

- **The cookbook and `yopo` still run in-process** (`PipePair`, and `session-client` over `Client.Seam`). The process-to-process path is `StdioTransport`, exercised by its own tests against a real `/bin/cat`, by `Relay.Downstream`'s tests, by every harness executable (`AgentMain`), and by `../zigagent`'s meta-agent (`zagent acp`).
- **Token usage is not yet ACP's `PromptResponse.usage`, and accounts and sign-in are not yet ACP's `authenticate`** (see "Decided against the ACP schema").
- No web console — `make demo` runs the cookbook binaries, not a server.
- No `.claude/rules/`, skills, or hooks configured.
- Public API is unstable until tagged; wire format is already canonical.
