const std = @import("std");

const zon = @import("build.zig.zon");
const zigbuildx = @import("zigbuildx");

pub fn build(b: *std.Build) void {
    // Pre-flight: ensure any local dependencies are cloned
    zigbuildx.Deps.cloneMissing(b, zon);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags = collectUnstableFlags(b);
    const build_options = b.addOptions();
    inline for (@typeInfo(UnstableFlags).@"struct".field_names) |name| {
        build_options.addOption(bool, name, @field(flags, name));
    }

    const schema = b.addModule("acp-schema", .{
        .root_source_file = b.path("src/acp-schema/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    schema.addOptions("build_options", build_options);

    const acp = b.addModule("acp", .{
        .root_source_file = b.path("src/acp/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp.addImport("acp-schema", schema);

    const acp_test = b.addModule("acp-test", .{
        .root_source_file = b.path("src/acp-test/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_test.addImport("acp", acp);
    acp_test.addImport("acp-schema", schema);

    const acp_async = b.addModule("acp-async", .{
        .root_source_file = b.path("src/acp-async/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_async.addImport("acp", acp);

    const acp_conductor = b.addModule("acp-conductor", .{
        .root_source_file = b.path("src/acp-conductor/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_conductor.addImport("acp", acp);

    // MCP logic; the MCP wire types themselves stay in `acp-schema`.
    const acp_mcp = b.addModule("acp-mcp", .{
        .root_source_file = b.path("src/acp-mcp/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_mcp.addImport("acp-schema", schema);

    // Disk I/O goes through `zigstorage`. Requested with exactly the options
    // every other consumer passes — target and optimize, nothing else — or the
    // harnesses linking both would mint a second copy.
    const zigstorage_module = b.dependency("zigstorage", .{ .target = target, .optimize = optimize }).module("zigstorage");

    // The barrel: one flat namespace over the five modules the harnesses and
    // hosts consume. See `src/module.zig` for the naming convention.
    const zigacp = b.addModule("zigacp", .{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigacp.addImport("acp", acp);
    zigacp.addImport("acp-schema", schema);
    zigacp.addImport("acp-async", acp_async);
    zigacp.addImport("acp-mcp", acp_mcp);
    zigacp.addImport("acp-conductor", acp_conductor);
    zigacp.addImport("zigstorage", zigstorage_module);

    const test_step = b.step("test", "Run unit tests");

    const schema_tests = b.addTest(.{
        .name = "acp-schema-tests",
        .root_module = schema,
    });
    test_step.dependOn(&b.addRunArtifact(schema_tests).step);

    const acp_tests = b.addTest(.{
        .name = "acp-tests",
        .root_module = acp,
    });
    test_step.dependOn(&b.addRunArtifact(acp_tests).step);

    const acp_test_tests = b.addTest(.{
        .name = "acp-test-tests",
        .root_module = acp_test,
    });
    test_step.dependOn(&b.addRunArtifact(acp_test_tests).step);

    const acp_async_tests = b.addTest(.{
        .name = "acp-async-tests",
        .root_module = acp_async,
    });
    test_step.dependOn(&b.addRunArtifact(acp_async_tests).step);

    const acp_conductor_tests = b.addTest(.{
        .name = "acp-conductor-tests",
        .root_module = acp_conductor,
    });
    test_step.dependOn(&b.addRunArtifact(acp_conductor_tests).step);

    const acp_mcp_tests = b.addTest(.{
        .name = "acp-mcp-tests",
        .root_module = acp_mcp,
    });
    test_step.dependOn(&b.addRunArtifact(acp_mcp_tests).step);

    const zigacp_tests = b.addTest(.{
        .name = "zigacp-tests",
        .root_module = zigacp,
    });
    test_step.dependOn(&b.addRunArtifact(zigacp_tests).step);

    const cookbook_step = b.step("cookbook", "Build cookbook examples");

    const minimal_client_module = b.createModule(.{
        .root_source_file = b.path("src/acp-cookbook/minimal_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    minimal_client_module.addImport("acp", acp);
    minimal_client_module.addImport("acp-test", acp_test);
    minimal_client_module.addImport("acp-schema", schema);
    const minimal_client_exe = b.addExecutable(.{
        .name = "minimal-client",
        .root_module = minimal_client_module,
    });
    b.installArtifact(minimal_client_exe);
    cookbook_step.dependOn(&minimal_client_exe.step);

    const minimal_agent_module = b.createModule(.{
        .root_source_file = b.path("src/acp-cookbook/minimal_agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    minimal_agent_module.addImport("acp", acp);
    minimal_agent_module.addImport("acp-test", acp_test);
    minimal_agent_module.addImport("acp-schema", schema);
    const minimal_agent_exe = b.addExecutable(.{
        .name = "minimal-agent",
        .root_module = minimal_agent_module,
    });
    b.installArtifact(minimal_agent_exe);
    cookbook_step.dependOn(&minimal_agent_exe.step);

    const demo_client_run = b.addRunArtifact(minimal_client_exe);
    const demo_agent_run = b.addRunArtifact(minimal_agent_exe);
    demo_agent_run.step.dependOn(&demo_client_run.step);
    const demo_step = b.step("demo", "Run the cookbook client and agent examples");
    demo_step.dependOn(&demo_agent_run.step);

    const gen_schema_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_schema/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_schema_module.addImport("acp-schema", schema);
    gen_schema_module.addImport("zigstorage", zigstorage_module);

    const gen_schema_exe = b.addExecutable(.{
        .name = "gen-schema",
        .root_module = gen_schema_module,
    });
    b.installArtifact(gen_schema_exe);

    const gen_schema_run = b.addRunArtifact(gen_schema_exe);
    gen_schema_run.addPassthruArgs();
    const gen_schema_step = b.step("gen-schema", "Emit canonical schema catalog JSON (path arg or stdout)");
    gen_schema_step.dependOn(&gen_schema_run.step);

    const yopo_module = b.createModule(.{
        .root_source_file = b.path("src/yopo/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    yopo_module.addImport("acp", acp);
    yopo_module.addImport("acp-test", acp_test);
    yopo_module.addImport("acp-schema", schema);

    const yopo_exe = b.addExecutable(.{
        .name = "yopo",
        .root_module = yopo_module,
    });
    b.installArtifact(yopo_exe);

    const yopo_run = b.addRunArtifact(yopo_exe);
    const yopo_step = b.step("yopo", "Run the reference agent contract suite");
    yopo_step.dependOn(&yopo_run.step);

    const run_yopo = b.addRunArtifact(yopo_exe);
    run_yopo.addPassthruArgs();
    const run_step = b.step("run", "Run the reference agent (yopo)");
    run_step.dependOn(&run_yopo.step);

    const docs_obj = b.addObject(.{
        .name = "acp-docs",
        .root_module = acp,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Emit API documentation to zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}

/// Protocol surface ACP has not stabilized, each off unless asked for.
///
/// Stabilized surface carries no flag: `session/close`, `session/resume`,
/// `logout`, `usage_update`, `$/cancel_request`, `additionalDirectories`,
/// message ids and boolean config options are always built. `elicitation`
/// stays flagged because its stable shape (form and URL modes) differs from
/// the draft modelled here; `session_model` gates `session/set_model`, which
/// ACP dropped for a `model` config option. `auth_methods` and
/// `llm_providers` gate nothing yet.
const UnstableFlags = struct {
    unstable_elicitation: bool,
    unstable_nes: bool,
    unstable_auth_methods: bool,
    unstable_session_fork: bool,
    unstable_session_model: bool,
    unstable_llm_providers: bool,
};

fn collectUnstableFlags(b: *std.Build) UnstableFlags {
    var flags: UnstableFlags = undefined;
    inline for (@typeInfo(UnstableFlags).@"struct".field_names) |name| {
        @field(flags, name) = b.option(
            bool,
            name,
            "Expose unstable protocol surface: " ++ name,
        ) orelse false;
    }
    return flags;
}
