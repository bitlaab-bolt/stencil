const std = @import("std");
const Allocator = std.mem.Allocator;

const Stencil = @import("stencil").Stencil;

pub fn main() !void {
    std.debug.print("Code coverage example\n", .{});

    // Let's start from here...

    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    const path = try getUri(heap, "page");
    defer heap.free(path);

    var template = try Stencil.init(heap, path);
    defer template.deinit();

    var ctx = try template.new("app");
    try ctx.load("app.html");
    defer ctx.free();

    const status = try ctx.status();
    std.debug.print("Template Status: {any}\n", .{status});

    try ctx.expand();

    std.debug.print("Cache: {?s}\n", .{ctx.readFromCache()});
    std.debug.print("Content: {?s}\n", .{try ctx.read()});
    std.debug.assert(ctx.readFromCache() != null);

    const tokens = try ctx.extract();
    defer ctx.destruct(tokens);

    // Injects `template/four.html` content
    try ctx.inject(ctx.get(tokens, 0).?, 1, null);
    // Injects nothing since the token `void`
    try ctx.inject(ctx.get(tokens, 1).?, 1, null);
    // Injects runtime content
    try ctx.inject(ctx.get(tokens, 2).?, 0, "{d: 23}");

    std.debug.print("Updated Content: {?s}\n", .{try ctx.read()});

    try ctx.replace("demo.js", "script.js");
    std.debug.print("Final Content: {?s}\n", .{try ctx.read()});

    std.debug.print("Template Content: {?s}\n", .{template.read("app")});
}

fn getUri(heap: Allocator, child: []const u8) ![]const u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(heap);
    defer heap.free(exe_dir);

    if (std.mem.count(u8, exe_dir, "zig-out/bin") == 1) {
        const fmt_str = "{s}/../../{s}";
        return try std.fmt.allocPrint(heap, fmt_str, .{exe_dir, child});
    }

    unreachable;
}