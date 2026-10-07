const std = @import("std");
const Allocator = std.mem.Allocator;

const Stencil = @import("stencil").Stencil;

pub fn main(init: std.process.Init) !void {
    std.debug.print("Code coverage example\n", .{});

    // Let's start from here...

    const heap = init.gpa;

    const path = try getUri(init.io, heap, "page");
    defer heap.free(path);

    var template = try Stencil.init(init.io, heap, path);
    // Also releases any context that missed an explicit `free()`
    defer template.deinit();

    // Static templates, including nested ones
    try staticExpansion(&template);

    // Static + dynamic evaluation on a single page
    try dynamicInjection(&template);

    // Callback hook and identifier based cache reads
    try cachedRead(&template);

    // Runtime rendering without the file system or cache
    try serverSideRendering(&template);

    // Shared cache across multiple contexts
    try sharedCache(&template);
}

/// # Evaluates Nested Static Templates
/// - `nested.html` expands `template/nest.html`, which itself embeds
///   `template/one.html` - `expand()` resolves the chain in one call
fn staticExpansion(template: *Stencil) !void {
    var ctx = try template.new("nested");
    try ctx.load("nested.html");
    defer ctx.free();

    const status = try ctx.status();
    std.debug.print("Nested Status: {any}\n", .{status});

    try ctx.expand();
    std.debug.print("Nested Content: {?s}\n", .{try ctx.read()});
}

/// # Evaluates Static and Dynamic Templates on One Page
/// - `app.html` mixes static, dynamic, and runtime tokens
fn dynamicInjection(template: *Stencil) !void {
    var ctx = try template.new("app");
    try ctx.load("app.html");
    defer ctx.free();

    const status = try ctx.status();
    std.debug.print("Template Status: {any}\n", .{status});

    // Resolves every static token at once
    try ctx.expand();

    // Extracts dynamic tokens for incremental evaluation
    const tokens = (try ctx.extract()) orelse return;
    defer ctx.destruct(tokens);

    // Injects `template/four.html` content
    if (ctx.get(tokens, 0)) |token| try ctx.inject(token, 1, null);
    // Injects nothing since the token `void`
    if (ctx.get(tokens, 1)) |token| try ctx.inject(token, 1, null);
    // Injects runtime generated content
    if (ctx.get(tokens, 2)) |token| try ctx.inject(token, 0, "{d: 23}");

    std.debug.print("Updated Content: {?s}\n", .{try ctx.read()});

    // Replaces any remaining string on the evaluated page
    try ctx.replace("demo.js", "script.js");
    std.debug.print("Final Content: {?s}\n", .{try ctx.read()});

    // Loading a context twice raises `error.AlreadyLoaded`
    ctx.load("app.html") catch |err| switch (err) {
        error.AlreadyLoaded => std.debug.print("Already loaded - skipping\n", .{}),
        else => return err,
    };
}

/// # Reads from the Cache with a Debug Callback
/// **Remarks:** The callback receives a freshly loaded page regardless of the
/// cache state, so changes made inside it can be persisted with `read()`
fn cachedRead(template: *Stencil) !void {
    const content = try template.read("app", debugInspect);
    std.debug.print("Cached Content: {?s}\n", .{content});
}

fn debugInspect(ctx: *Stencil.Template) void {
    const data = ctx.readSSR() orelse return;
    std.debug.print("Callback page `{s}`: {d} bytes\n", .{ ctx.name, data.len });
}

/// # Renders Runtime Content Without Files or Cache
/// - `loadSSR()` accepts raw content instead of a page path
fn serverSideRendering(template: *Stencil) !void {
    var ctx = try template.newSSR();
    defer ctx.freeSSR();

    try ctx.loadSSR("<!DOCTYPE html><html><body>{{ header || }}</body></html>");

    const tokens = (try ctx.extract()) orelse return;
    defer ctx.destruct(tokens);

    if (ctx.get(tokens, 0)) |token| {
        try ctx.inject(token, 0, "<h1>Rendered at runtime</h1>");
    }

    std.debug.print("SSR Content: {?s}\n", .{ctx.readSSR()});
}

/// # Shares the Cache Across Contexts
/// **WARNING:** Contexts with a duplicate identifier overwrite the previous
/// cache entry - always use a unique identifier per page
fn sharedCache(template: *Stencil) !void {
    var first = try template.new("shared");
    try first.load("template/one.html");
    defer first.free();

    // Populates the cache under the "shared" identifier
    _ = try first.read();

    // Another context with the same identifier reuses the same cache entry
    var second = try template.new("shared");
    try second.load("template/one.html");
    defer second.free();

    std.debug.print("Shared Cache: {?s}\n", .{first.readFromCache()});
    std.debug.print("Shared Read: {?s}\n", .{try second.read()});
}

/// **WARNING:** Return value must be freed by the caller.
fn getUri(io: std.Io, heap: Allocator, child: []const u8) ![]const u8 {
    const exe_dir = try std.process.executableDirPathAlloc(io, heap);
    defer heap.free(exe_dir);

    if (std.mem.count(u8, exe_dir, "zig-out/bin") == 1) {
        const fmt_str = "{s}/../../{s}";
        return try std.fmt.allocPrint(heap, fmt_str, .{exe_dir, child});
    }

    unreachable;
}
