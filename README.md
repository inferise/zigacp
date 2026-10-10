# Agent Client Protocol — Zig

[![Zig 0.17.0](https://img.shields.io/badge/zig-0.17.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

The **Agent Client Protocol** (ACP) standardises communication between *code editors* — interactive programs for viewing and editing source code — and *coding agents* — programs that use generative AI to autonomously modify code.

This repository is a native **Zig** implementation. It gives you allocator-aware wire types, a transport-agnostic synchronous SDK, proxy orchestration, a reference agent binary, and a comptime-reflective schema generator.

> **Status:** working core, public API stabilising toward `v0.1.0`. Wire format matches the canonical protocol; the public surface is unstable until tagged.

---

## Packages

**Core SDK**

- [`acp-schema`](./src/acp-schema/) — Wire-format types: methods, requests, responses, notifications, content variants, tool calls, errors. Forward-compatible `unknown` buckets on every public union so newer peers don't crash older clients.
- [`acp`](./src/acp/) — Synchronous `Connection` (results own their memory), vtable-based `Transport`, comptime-typed `Dispatcher` (or `registerRequestFn` for a plain function), `RawPeer` / `RawMessage` (whole parsed frames, for proxies), `ScriptedPeer` (a scripted test transport), `Session` state machine, capability negotiation, fixed-capacity trace ring buffer.
- [`acp-async`](./src/acp-async/) — Newline-delimited framer (16 MiB frame cap), `BufferPair` deterministic test transport, `FileTransport` over `std.Io.File` (EOF is `TransportClosed`), `StdioTransport` (pollable, for a process serving ACP on its own stdio) with its runtime `Config`, `LocalSeam(Agent)` (an agent served on one end of an in-process `FrameTransport` pair, torn down in order), subprocess `Child` spawn.
- [`acp-mcp`](./src/acp-mcp/) — MCP logic above the protocol, starting with `McpServer`, a view over one server from `session/new`. The MCP wire types themselves (`McpServerConfig` and its stdio / HTTP / SSE shapes) are part of ACP and stay in `acp-schema`.
- [`zigacp`](./src/module.zig) — The barrel harnesses import: every consumed symbol under one namespace (`RawPeer`, `ScriptedPeer`, `FileTransport`, `LocalSeam`, `Conductor`, …), plus shared implementations above the protocol — `Client.Fs` (`fs/*`), `Client.Terminal` (`terminal/*` over plain pipes, bounded output, process-group kill), `Client.PtyTerminal` (`terminal/*` on a pseudoterminal), `Pty` (`Session`, `Pair`, `VtDecoder`, `VtScreen`: a pseudoterminal and the screen it draws; `Login`: a CLI's own sign-in run on one, its output kept as plain text), `Meta` (`read` / `of` for `_meta`, and the key names cross-harness `_meta` fields use) and `Inferise` (the `_inferise/*` extension).

**Proxy orchestration**

- [`acp-conductor`](./src/acp-conductor/) — Compose N typed interceptors between client and agent ends with pass / short-circuit / drop semantics; reply interceptors see each reply with the method it answers, and `Pairing(T)` matches each reply to its request, one table per direction. The barrel re-exports it as `acp.Conductor`.

**Examples and testing**

- [`acp-cookbook`](./src/acp-cookbook/) — Minimal runnable client and agent.
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

Request it with target and optimize only. zigacp depends on one sibling checkout, `../zigstorage` (disk access for the barrel and `gen-schema`), which must exist beside this one.

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

---

## Build and test

```sh
zig version                                # must report 0.17.0
zig build                                  # build all libraries + binaries
zig build test --summary all               # 245 pass + 7 gated skips, zero leaks
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
    -Dunstable_elicitation=true \
    -Dunstable_nes=true \
    -Dunstable_auth_methods=true \
    -Dunstable_llm_providers=true
```

What ACP has stabilized is always built, with no flag: `session/close`, `session/resume`, `session/delete`, `logout`, `usage_update`, `$/cancel_request`, `additionalDirectories`, message ids and boolean config options. `elicitation` stays flagged because ACP stabilized a different shape (form and URL modes) than the draft modelled here; `session_model` gates `session/set_model`, which ACP dropped in favour of a `model` config option; `auth_methods` and `llm_providers` gate nothing yet. A consumer requests zigacp with no flags, and every repo that links several zigacp consumers must request it identically.

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
├── acp-schema/              # wire types + JSON codec
├── acp/                     # core SDK
│   ├── raw_peer.zig         # RawPeer / RawMessage
│   └── scripted_peer.zig    # ScriptedPeer
├── acp-async/               # framing + real-IO transports
│   └── local_seam.zig       # LocalSeam(Agent)
├── acp-conductor/           # proxy chain
│   └── pairing.zig          # Pairing(T)
├── acp-mcp/                 # MCP logic (wire types stay in acp-schema)
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
