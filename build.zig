const std = @import("std");

const zon = @import("build.zig.zon");

const Git = struct {
    const Self = @This();

    /// Clones every missing cloneable dependency and exits 1; returns when none are missing.
    ///
    /// Parameters:
    /// - `b`: the build graph.
    ///
    /// Return: nothing when all are present; otherwise never.
    pub fn cloneDeps(b: *std.Build) if (Self.hasAllDeps()) void else noreturn {
        if (comptime Self.hasAllDeps()) return;
        const io = b.graph.io;
        var missing: usize = 0;
        var cloned: usize = 0;
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".fields) |field| {
            if (comptime Self.isCloneable(field.name) and !Self.isCloned(field.name)) {
                const dep = @field(zon.dependencies, field.name);
                const dest = b.pathFromRoot(dep.path);
                missing += 1;
                if (std.Io.Dir.cwd().access(io, dest, .{})) |_| {
                    std.debug.print("{s} exists but is not a Zig package\n", .{dep.path});
                } else |err| switch (err) {
                    error.FileNotFound => if (Self.clone(io, dep.clone, dest)) {
                        cloned += 1;
                    } else |clone_err| {
                        std.debug.print("git clone {s} {s} failed [{any}]\n", .{ dep.clone, dep.path, clone_err });
                    },
                    else => std.debug.print("cannot check {s} [{any}]\n", .{ dep.path, err }),
                }
            }
        }
        if (cloned > 0) std.debug.print("cloned {d} of {d} missing dependencies; re-run zig build\n", .{ cloned, missing });
        std.process.exit(1);
    }

    /// Reports whether every cloneable dependency is present.
    ///
    /// Return: `true` when none is missing.
    fn hasAllDeps() bool {
        inline for (@typeInfo(@TypeOf(zon.dependencies)).@"struct".fields) |field| {
            if (Self.isCloneable(field.name) and !Self.isCloned(field.name)) return false;
        }
        return true;
    }

    /// Reports whether dependency `name` was present when the build runner was compiled.
    ///
    /// Parameters:
    /// - `name`: the dependency's field name in `build.zig.zon`.
    ///
    /// Return: `true` when present, or when this package is not the root.
    fn isCloned(comptime name: []const u8) bool {
        const deps = @import("root").dependencies;
        for (deps.root_deps) |dep| {
            if (std.mem.eql(u8, dep[0], name)) return @hasDecl(@field(deps.packages, dep[1]), "build_zig");
        }
        return true;
    }

    /// Reports whether dependency `name` declares both a `.path` and a `.clone`.
    ///
    /// Parameters:
    /// - `name`: the dependency's field name in `build.zig.zon`.
    ///
    /// Return: `true` when both fields are present.
    fn isCloneable(comptime name: []const u8) bool {
        const Dep = @TypeOf(@field(zon.dependencies, name));
        return @hasField(Dep, "path") and @hasField(Dep, "clone");
    }

    /// Clones the repository at `url` into `dest`.
    ///
    /// Parameters:
    /// - `io`: IO the `git` child is spawned on.
    /// - `url`: the repository to clone.
    /// - `dest`: the directory to clone into.
    ///
    /// Return: nothing on success; `error.GitCloneFailed` when `git` fails.
    fn clone(io: std.Io, url: []const u8, dest: []const u8) !void {
        var child = try std.process.spawn(io, .{ .argv = &.{ "git", "clone", url, dest } });
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) return error.GitCloneFailed,
            else => return error.GitCloneFailed,
        }
    }
};

pub fn build(b: *std.Build) void {
    // Pre-flight: ensure any local dependencies are cloned
    Git.cloneDeps(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags = collectUnstableFlags(b);
    const build_options = b.addOptions();
    inline for (@typeInfo(UnstableFlags).@"struct".fields) |field| {
        build_options.addOption(bool, field.name, @field(flags, field.name));
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

    // The barrel: one flat namespace over the four modules the harnesses
    // consume. See `src/module.zig` for the naming convention.
    const zigacp = b.addModule("zigacp", .{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigacp.addImport("acp", acp);
    zigacp.addImport("acp-schema", schema);
    zigacp.addImport("acp-async", acp_async);
    zigacp.addImport("acp-mcp", acp_mcp);
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
    if (b.args) |args| gen_schema_run.addArgs(args);
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
    if (b.args) |args| run_yopo.addArgs(args);
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

    const vaxis_module = b.dependency("zigvaxis", .{ .target = target, .optimize = optimize }).module("zigvaxis");
    const trace_viewer_module = b.createModule(.{
        .root_source_file = b.path("src/acp-trace-viewer/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    trace_viewer_module.addImport("vaxis", vaxis_module);
    trace_viewer_module.addImport("zigstorage", zigstorage_module);

    const trace_viewer_exe = b.addExecutable(.{
        .name = "acp-trace-viewer",
        .root_module = trace_viewer_module,
    });
    b.installArtifact(trace_viewer_exe);

    const viewer_step = b.step("trace-viewer", "Build the interactive trace viewer");
    viewer_step.dependOn(&trace_viewer_exe.step);
}

const UnstableFlags = struct {
    unstable_elicitation: bool,
    unstable_nes: bool,
    unstable_cancel_request: bool,
    unstable_auth_methods: bool,
    unstable_logout: bool,
    unstable_session_fork: bool,
    unstable_session_resume: bool,
    unstable_session_close: bool,
    unstable_session_model: bool,
    unstable_session_usage: bool,
    unstable_session_additional_directories: bool,
    unstable_llm_providers: bool,
    unstable_message_id: bool,
    unstable_boolean_config: bool,
};

fn collectUnstableFlags(b: *std.Build) UnstableFlags {
    var flags: UnstableFlags = undefined;
    inline for (@typeInfo(UnstableFlags).@"struct".fields) |field| {
        @field(flags, field.name) = b.option(
            bool,
            field.name,
            "Expose unstable protocol surface: " ++ field.name,
        ) orelse false;
    }
    return flags;
}
