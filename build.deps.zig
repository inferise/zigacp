//! Dependency resolution with a local-checkout override.
//!
//! Drop-in helper: copy this file next to `build.zig` and import it.
//!
//!     const deps = @import("build.deps.zig");
//!     const foo = deps.resolveModule(b, "foo", target, optimize) orelse return;
//!
//! Import it as `deps`, not `dep` — `dep` collides with the usual
//! `if (...) |dep|` capture around an optional dependency, and Zig rejects
//! shadowing. `resolveModule` is the whole public surface; if you ever need
//! the dependency itself (artifacts, include paths), make `resolveDependency` pub.
//!
//! `dep_name` is comptime, so every derived string is built at compile time.
//!
//! ## Convention
//!
//! `build.zig.zon` declares two keys per resolvable dependency:
//!
//!     .foo       = .{ .url = "git+https://...#commit", .hash = "...", .lazy = true },
//!     .foo_local = .{ .path = "../foo", .lazy = true },
//!
//! The bare name is the pinned remote — what CI and anyone fetching this
//! package gets. `<name>_local` is the developer override, selected
//! automatically when `../<name>` is checked out beside this repo. Everything
//! else is derived from the name passed in: the sibling path
//! `../<name>` and the build option `-D<name>-source`.
//!
//! ## Why the directory is probed first
//!
//! Zig opens a path dependency the moment `lazyDependency` requests that key,
//! and a missing directory ends the build — `.lazy = true` does not soften
//! that. Merely *declaring* an absent path dependency is harmless, which is
//! what makes this pattern work: both keys are always declared, and only the
//! one that can resolve is ever requested.
//!
//! ## When copying to a new project
//!
//! Add `"build.deps.zig"` to `.paths` in `build.zig.zon`, or a fetched copy of
//! the package will import a file that isn't there. Also make sure your format
//! and lint steps cover it — it sits outside `src/`.
//!
//! Note that building against a sibling makes Zig write cache artifacts into
//! that directory. Pass `-D<name>-source=remote` to leave it untouched.

const std = @import("std");

/// Where a dependency's source comes from.
const Source = enum {
    /// Sibling checkout when present, pinned remote otherwise.
    auto,
    /// Require the sibling checkout; error if it is missing.
    local,
    /// Always use the pinned remote, even with a sibling present.
    remote,
};

/// Resolve `dep_name` from either its sibling working copy or its pinned
/// remote, honouring `-D<dep_name>-source`.
///
/// Returns null when the chosen dependency is lazy and not yet fetched; Zig
/// fetches it and re-runs the build script, exactly as `lazyDependency` does.
fn resolveDependency(b: *std.Build, comptime dep_name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Dependency {
    const sibling = "../" ++ dep_name;

    const source = b.option(
        Source,
        dep_name ++ "-source",
        "Where to get " ++ dep_name ++ ": auto (sibling checkout at " ++ sibling ++ " if present, else pinned remote), local, remote",
    ) orelse .auto;

    const use_sibling = switch (source) {
        .local => true,
        .remote => false,
        .auto => hasSiblingPackage(b, sibling),
    };

    const key = if (use_sibling) dep_name ++ "_local" else dep_name;
    return b.lazyDependency(key, .{ .target = target, .optimize = optimize });
}

/// Resolve `dep_name` and return the module to import from it.
///
/// Module lookup follows the same name-is-the-convention rule as `resolveDependency`:
/// a package is expected to export a module named after itself. When it does
/// not, a package exporting exactly one module is taken to mean that module —
/// which keeps a build working across a dependency renaming its export, or a
/// sibling checkout and a pinned commit disagreeing about the name.
///
/// Panics if neither rule applies, naming what the package does export.
/// Returns null only when the dependency is lazy and not yet fetched.
pub fn resolveModule(b: *std.Build, comptime dep_name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    const dep = resolveDependency(b, dep_name, target, optimize) orelse return null;
    const modules = &dep.builder.modules;

    if (modules.get(dep_name)) |mod| return mod;

    if (modules.count() == 1) {
        var it = modules.iterator();
        return it.next().?.value_ptr.*;
    }

    std.debug.panic("dependency '{s}' exports no module named '{s}' and exports {d} modules ({s}) — pass one explicitly", .{ dep_name, dep_name, modules.count(), exportedNames(b, modules) });
}

/// Comma-separated list of the modules a dependency exports, for diagnostics.
fn exportedNames(b: *std.Build, modules: *const std.array_hash_map.String(*std.Build.Module)) []const u8 {
    const names = b.allocator.alloc([]const u8, modules.count()) catch @panic("OOM");
    var it = modules.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) names[i] = entry.key_ptr.*;
    return std.mem.join(b.allocator, ", ", names) catch @panic("OOM");
}

/// Whether `path`, relative to the build root, holds a Zig package.
///
/// Tests for the manifest rather than just the directory: an empty or
/// half-cloned sibling would otherwise be selected and then fail, because
/// committing to a path dependency is irreversible — there is no second
/// chance to fall back to the remote once the key has been requested.
fn hasSiblingPackage(b: *std.Build, path: []const u8) bool {
    var dir = b.build_root.handle.openDir(b.graph.io, path, .{}) catch return false;
    defer dir.close(b.graph.io);
    dir.access(b.graph.io, "build.zig.zon", .{}) catch return false;
    return true;
}
