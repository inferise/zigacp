# Agent Client Protocol — Zig

[![Zig 0.17.0](https://img.shields.io/badge/zig-0.17.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

The **Agent Client Protocol** (ACP) standardises communication between *code editors* — interactive programs for viewing and editing source code — and *coding agents* — programs that use generative AI to autonomously modify code.

This repository is a native **Zig** implementation. It gives you allocator-aware wire types, a transport-agnostic synchronous SDK, a client session, a relay and analytics for agents behind it, proxy orchestration, a terminal chat for any agent, a reference agent binary, and a comptime-reflective schema generator.

> **Status:** working core, public API stabilising toward `v0.1.0`. Wire format matches the canonical protocol; the public surface is unstable until tagged.

---

## Packages

**Core SDK**

- [`acp-schema`](./src/acp-schema/) — Wire-format types: methods, requests, responses, notifications, content variants, tool calls, errors. Forward-compatible `unknown` buckets on every public union so newer peers don't crash older clients.
- [`acp`](./src/acp/) — Synchronous `Connection` (results own their memory), vtable-based `Transport`, comptime-typed `Dispatcher` (or `registerRequestFn` for a plain function), `RawPeer` / `RawMessage` (whole parsed frames, for proxies), `ScriptedPeer` (a scripted test transport), `Session` state machine, capability negotiation, fixed-capacity trace ring buffer.
- [`acp-async`](./src/acp-async/) — Newline-delimited framer (16 MiB frame cap), `BufferPair` deterministic test transport, `FileTransport` over `std.Io.File` (EOF is `TransportClosed`), `StdioTransport` (pollable, for a process serving ACP on its own stdio) with its runtime `Config`, `LocalSeam(Agent)` (an agent served on one end of an in-process `FrameTransport` pair, torn down in order), subprocess `Child` spawn.
- [`acp-mcp`](./src/acp-mcp/) — MCP logic above the protocol: `McpServer`, a view over one server from `session/new`; `McpHttpServer`, a host's own MCP server over Streamable HTTP on loopback, answering a tool table the host passes in; `RelayTools`, the relay's `report_progress` and `ask_user`. The MCP wire types themselves (`McpServerConfig` and its stdio / HTTP / SSE shapes) are part of ACP and stay in `acp-schema`.
- [`zigacp`](./src/module.zig) — The barrel harnesses import: every consumed symbol under one namespace (`RawPeer`, `ScriptedPeer`, `FileTransport`, `LocalSeam`, `Conductor`, …), plus shared implementations above the protocol — `Client.Fs` (`fs/*`), `Client.Terminal` (`terminal/*` over plain pipes, bounded output, process-group kill), `Client.PtyTerminal` (`terminal/*` on a pseudoterminal), `Pty` (`Session`, `Pair`, `VtDecoder`, `VtScreen`: a pseudoterminal and the screen it draws; `Login`: a CLI's own sign-in run on one, its output kept as plain text), `Meta` (`read` / `of` for `_meta`, and the key names cross-harness `_meta` fields use) and `Inferise` (the `_inferise/*` extension).

**Client, relay and analytics** (on the barrel)

- `Client.Session` — one agent's ACP session as a front end drives it: handshake, new / load / close, prompts (with images), permissions, settings (`Client.Settings`), status, extensions, accounts, the conversation record; finished turns go to the caller's `Client.History`. `Client.SignIn` runs `_inferise/sign_in` on its own task, polled. `Client.Seam(Agent)` stands an agent up in-process with a connected session, torn down in order.
- `Relay.Proxy` — every frame between a host and an agent: the session record (`Relay.SessionLog`), turn numbers, one usage shape (`Relay.UsageNormalizer`), instructions, and the MCP way back to the host as ACP's own `notice` and `elicitation/create`. `Relay.Downstream(Agent)` is its agent end: linked in-process, or a child on stdio.
- `Analytics` — `TapTransport` reports every frame to an `Observer`; `Recorder` decodes them (`EventDecoder`) off the protocol path into JSON records for its sinks (`JsonlSink`, `MemorySink`), content cut and redacted (`ContentRedactor`); agents are named by `AgentIdentity`.
- `Test.EchoAgent` — a scripted in-process agent for a client's tests and demos.

**Terminal UI**

- [`acp-tui`](./src/tui/) — A separate module on `zigtui`, so the protocol module takes no UI: `Conversation` and `ConversationView` (an agent's `session/update`s as who said what), `AgentChat` (the single-agent screen: conversation, prompt, permissions, and a menu of what the agent advertised — models, modes, options, status, extensions, accounts, sign-in), and `AgentMain(Agent)` with its `Launch` rule, the `main` every harness executable shares: `app` in a terminal is the screen, `app acp` or a launch on pipes serves ACP on stdio.

**Proxy orchestration**

- [`acp-conductor`](./src/acp-conductor/) — Compose N typed interceptors between client and agent ends with pass / short-circuit / drop semantics; reply interceptors see each reply with the method it answers, and `Pairing(T)` matches each reply to its request, one table per direction. The barrel re-exports it as `acp.Conductor`.

**Examples and testing**

- [`acp-cookbook`](./src/acp-cookbook/) — Minimal runnable client and agent, and `session-client`: one turn through `Client.Seam` and `Client.Session`.
- [`acp-test`](./src/acp-test/) — In-memory `PipePair` transport and end-to-end contract tests.
- [`yopo`](./src/yopo/) — Reference agent binary that drives the full contract over an in-process pipe.

**Tooling**

- [`tools/gen_schema`](./tools/gen_schema/) — Comptime-reflective generator that emits a canonical JSON catalog of the public schema.

---

## Install

```sh
zig fetch --save git+https://github.com/MagnovaAI/acp-zig
```

In your `build.zig`:

```zig
const zigacp_dep = b.dependency("zigacp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigacp", zigacp_dep.module("zigacp"));
```

Request it with target and optimize only. zigacp depends on sibling checkouts that must exist beside this one: `../zigstorage` (disk access for the barrel and `gen-schema`), and `../zigtui` (lazy; compiled only by a consumer of `acp-tui`, the module a terminal chat needs: `zigacp_dep.module("acp-tui")`).

## Quick start

### Drive a connection

```zig
const std = @import("std");
const acp = @import("zigacp");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const transport: acp.Transport = my_transport;          // FileTransport, BufferPair, etc.
    var conn = acp.Connection.init(allocator, transport);

    const resp = try conn.request(
        acp.Agent.InitializeResponse,
        acp.Agent.method_initialize,
        .{ .protocolVersion = acp.ProtocolVersion.V1 },
    );
    defer resp.deinit();

    std.debug.print("peer speaks protocol v{d}\n", .{resp.value.protocolVersion.value});
}
```

### Implement an agent

```zig
const Agent = struct {
    pub const Params = acp.Agent.InitializeRequest;
    pub const Result = acp.Agent.InitializeResponse;
    pub fn handle(_: *@This(), _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        return .{ .protocolVersion = params.protocolVersion };
    }
};

var dispatcher = acp.Dispatcher.init(allocator);
defer dispatcher.deinit();

var agent: Agent = .{};
try dispatcher.registerRequest(acp.Agent.method_initialize, Agent, &agent);

var conn = acp.Connection.init(allocator, transport);
conn.setRequestHandler(dispatcher.requestHandler());
try conn.serve();
```

A full client+agent round-trip lives in [`src/acp-test/contract_handshake.zig`](./src/acp-test/contract_handshake.zig). The reference contract is in [`src/yopo/main.zig`](./src/yopo/main.zig).

### Chat with an agent in a terminal

A harness executable is a chat with its agent in a terminal and the agent on stdio for a host, from one `main`:

```zig
const acp_tui = @import("acp-tui");
const Main = acp_tui.AgentMain(mod.AcpAgent);

pub fn main(init: std.process.Init) !void {
    const all = try init.minimal.args.toSlice(init.arena.allocator());
    const spec: Main.Spec = .{ .title = "Claude", .label = "claude", .program = "zigclaude", .start = startAgent };
    if (!try Main.run(init, spec, all[1..])) return error.UnknownArgument;
}
```

The launch rule (`Launch.decide`) is the same for every harness: `app acp` (or `--acp`) always serves ACP on stdio; a bare `app` serves ACP when stdin and stdout are both pipes — how a host launches an agent — opens `AgentChat` on a terminal, and refuses half a terminal (`app | less`). There is no `tui` argument. Request `acp-tui` for the executable only; a library never takes a UI. Set `std_options.logFn` to `acp_tui.zigtui.LogRing.logFn` so records go to the screen's log while it is up and to stderr — never stdout — otherwise.

---

## How the pieces fit

zigacp owns the ACP seam: the wire, the `_inferise` extension below, and every piece of machinery that sits on the protocol whatever product is above it. Harnesses (`zigclaude`, `zigcodex`, `ziggrok`, `ziggemini`, `zigcopilot`, `zigafm`) are ACP agents; `zigagent` is a client and an agent — a proxy that runs many agents at once.

```
   terminal / browser                    any ACP host (Zed, …)
          │ in-process                          │ stdio (`zagent acp`)
          ▼                                     ▼
 ┌──────────────────────────── zigagent ───────────────────────────┐
 │  front ends ── Client.Session ──┐          MetaAgent            │
 │                                 │          routes host sessions │
 │                   Relay.Proxy per subagent ◄────────────────────┘
 │                   Analytics.TapTransport → Recorder              │
 └─────────────────────────────────┼────────────────────────────────┘
                                   │ Relay.Downstream: linked (LocalSeam) or a child's stdio
                                   ▼
        zigclaude · zigcodex · ziggrok · ziggemini · zigcopilot · zigafm · any ACP agent
        each also: `app` → acp-tui AgentChat over Client.Seam · `app acp` → ACP on stdio
```

### Every agent

- **`initialize`:** `agentInfo` (with the CLI's version where there is one); `loadSession` only if it can reopen a session; `mcpCapabilities.http` if it takes HTTP MCP servers; `promptCapabilities.image` if it takes images; `agentCapabilities._meta.inferise` (`Inferise.Capabilities`) for what it serves of the extension.
- **`session/new` / `session/load`:** read `_meta.inferise` with `Inferise.readSession` — the account by name, `logDir`, `trustedMcpServers`. Refuse an account that is not signed in. `session/load` replays the conversation as `session/update`s before it answers.
- **Turns:** standard stop reasons; every turn ends with `Inferise.TurnMeta` on the result's `_meta`; `usage_update` only when the agent knows its context window.
- **Tool calls** carry ACP's `name`, and `_meta.inferise.tool` with the agent's name (and the MCP server, for an MCP tool).
- **Always-approve** is the boolean config option `alwaysApprove`. **Sign-in** is driven off the agent's own CLI, on a pseudoterminal where it needs one (`Pty.Login`).

### Every client

- Decide everything from what the agent advertised: resuming from `loadSession`, MCP offers from `mcpCapabilities.http`, images from `promptCapabilities.image`, each `_inferise/*` call from its capability. Draw a part of the screen only when the agent advertised or sent it.
- Serve `fs/*` and `terminal/*` (`Client.Fs`, `Client.PtyTerminal`, `Client.Terminal` on Windows), with no path sandbox.
- Name the account on `session/new` and again on `session/load`; offer the MCP tools again under a fresh token.
- Treat updates that arrive during the client's own `session/load` as replayed history, not a live turn.
- Poll `sign_in_finish`; never block a connection on a sign-in for minutes. Decode leniently.

`Client.Session` does all of this.

### Every relay or proxy

- Pair replies per direction (`Conductor.Pairing`): requests run both ways.
- Keep the session record, number turns, and put one usage shape on each prompt result.
- Pass instructions as `_meta.instructions` to an agent that advertised the extension; prepend them to any other agent's first prompt.
- Offer the host's MCP server only to an agent that takes HTTP MCP. Its tools become ACP's own messages to the host — a `notice` for `report_progress`, an `elicitation/create` form for `ask_user` — and only when the host advertised `session.notices` or `elicitation.form`.
- A multiplexing proxy rewrites session ids and request ids both ways and tags every forwarded update `_meta.inferise.subagent`.
- Forward what does not parse, as it came.

`Relay.Proxy` does all of this but the multiplexing, which is `zigagent`'s `MetaAgent`.

## The `_inferise` extension

What ACP has no field for travels under `_inferise/*` methods and `_meta.inferise` (`acp.Inferise`), one vocabulary every agent and client here speaks, so a client never needs to know which agent it is talking to. Wire names are camelCase. A request is called only when the agent advertised it in `agentCapabilities._meta.inferise`.

| What | Wire | Direction | Advertised |
|---|---|---|---|
| Account | `_meta.inferise.account { home?, name? }` on `session/new` / `load` | client → agent | — |
| Log directory | `_meta.inferise.logDir` on `session/new` / `load` | client → agent | — |
| Trusted MCP servers | `_meta.inferise.trustedMcpServers` on `session/new` / `load` | client → agent | — |
| Instructions | `_meta.instructions` on `session/new` | client → agent | — |
| Turn meta | `_meta.inferise { usage, failure?, denied[] }` on the prompt result | agent → client | — |
| Turn number | `_meta.inferise.turn` on the prompt result | relay → host | — |
| Tool | `_meta.inferise.tool { server?, agent }` beside ACP's `name` | agent → client | — |
| Subagent | `_meta.inferise.subagent` on each forwarded update | proxy → host | — |
| Status | `_inferise/status { sessionId? }` → `{ cli?, account?, fields }` | client → agent | `status` |
| Extensions | `[{ method, label, scope, input? }]`, each called with `{ sessionId?, input? }` | client → agent | `extensions` |
| Accounts | `_inferise/accounts` → `{ accounts: [{ name, isDefault, signedIn }] }` | client → agent | `accounts` |
| Sign-in | `_inferise/sign_in`, `sign_in_finish` (polled about every 2 s), `sign_in_cancel` | client → agent | `signIn` |
| Interject, run ended, background tasks | `_inferise/interject`, `run_ended`, `background_tasks` | both | `interject`, `unpromptedTurns` |

Standard ACP is used wherever it has the field: a tool's name is `ToolCall.name`, always-approve is a boolean config option, a question for the person is `elicitation/create`, progress is a `notice`, context use is `usage_update`. Everything else follows ACP's extensibility rules: `_`-prefixed methods, `_meta` namespaced by implementation, custom capabilities under a capability object's `_meta`.

---

## Build and test

```sh
zig version                                # must report 0.17.0
zig build                                  # build all libraries + binaries
zig build test --summary all               # every package, acp-tui included; zero leaks
zig fmt --check src/ tools/           # formatting check

zig build yopo                             # run the reference contract suite
zig build gen-schema -- /tmp/schema.json   # emit canonical schema catalog
```

### Unstable feature flags

Protocol surface ACP has not stabilized is gated behind its own build flag, off by default:

```sh
zig build test \
    -Dunstable_session_fork=true \
    -Dunstable_session_model=true \
    -Dunstable_nes=true \
    -Dunstable_auth_methods=true \
    -Dunstable_llm_providers=true
```

What ACP has stabilized is always built, with no flag: `session/close`, `session/resume`, `session/delete`, `logout`, `usage_update`, `$/cancel_request`, `additionalDirectories`, message ids, boolean config options, a tool call's `name`, and elicitation (form and URL modes, `elicitation/create` and `elicitation/complete`). `session_model` gates `session/set_model`, which ACP dropped in favour of a `model` config option; `auth_methods` and `llm_providers` gate nothing yet. A consumer requests zigacp with no flags, and every repo that links several zigacp consumers must request it identically.

---

## Design notes

- **One error set across boundaries.** `AcpError` is the only error type returned across package boundaries — never `anyerror!T`. Failure modes are explicit.
- **Allocator-aware everywhere.** Every owning type takes an allocator and exposes a matching `deinit`. No global allocator, no hidden heap.
- **Forward-compatible unions.** Public tagged unions expose an `unknown: std.json.Value` variant so a peer running a newer revision never crashes an older client.
- **Comptime-typed dispatch.** `Dispatcher` registers handlers by method name with concrete `Params` / `Result` types. The thunk parses, invokes, and re-marshals through a per-call arena.
- **Per-frame tracing.** Attach a `TraceBuffer` to a `Connection` and every JSON-RPC frame is recorded with direction and a monotonic sequence number. Diagnostics never block the protocol path.

## Layout

```
src/
├── module.zig               # the zigacp barrel: Meta, Inferise, Conductor, Pty, Client.*
├── client_fs.zig            # Client.Fs: fs/*
├── client_terminal.zig      # Client.Terminal: terminal/* over pipes
├── client_pty_terminal.zig  # Client.PtyTerminal: terminal/* on a pseudoterminal
├── pty_session.zig          # Pty.Session, Pty.Pair
├── vt_decoder.zig           # Pty.VtDecoder
├── vt_screen.zig            # Pty.VtScreen
├── client_*.zig             # Client.Session, Settings, History, SignIn, Seam(Agent)
├── analytics_*.zig          # Analytics.Observer, TapTransport, EventDecoder, Recorder, sinks
├── relay_*.zig              # Relay.Proxy, Downstream(Agent), SessionLog, UsageNormalizer
├── mcp_offer.zig            # McpOffer
├── test_echo_agent.zig      # Test.EchoAgent
├── tui/                     # acp-tui: Conversation, ConversationView, AgentChat, AgentMain
├── acp-schema/              # wire types + JSON codec
├── acp/                     # core SDK
│   ├── raw_peer.zig         # RawPeer / RawMessage
│   └── scripted_peer.zig    # ScriptedPeer
├── acp-async/               # framing + real-IO transports
│   └── local_seam.zig       # LocalSeam(Agent)
├── acp-conductor/           # proxy chain
│   └── pairing.zig          # Pairing(T)
├── acp-mcp/                 # MCP logic: McpServer, McpHttpServer, RelayTools
├── acp-test/                # in-memory transport + contract tests
├── acp-cookbook/            # examples
└── yopo/                    # reference agent binary
tools/
└── gen_schema/        # canonical schema catalog generator
```

---

## Contributing

- **Bug reports:** open a [bug report issue](.github/ISSUE_TEMPLATE/bug_report.md). Include `zig version`, OS / arch, and a minimal failing snippet.
- **Pull requests:** the PR template lists the merge checklist. Each PR should keep `zig build test` green with zero leaks and `zig fmt --check src/ tools/` clean. Wire-format changes need an explicit note in the PR body.
- **Larger proposals:** open a discussion first so we can align on the wire-format impact before any code lands.

See [CHANGELOG.md](./CHANGELOG.md) for what's in each release.

## License

[MIT](./LICENSE).
