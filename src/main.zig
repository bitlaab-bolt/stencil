const std = @import("std");
const Allocator = std.mem.Allocator;

const stencil = @import("stencil");
const Stencil = stencil.Stencil;


pub fn main() !void {
    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    const path = try getUri(heap, "page");
    defer heap.free(path);

    var template = try Stencil.init(heap, path, 128);
    defer template.deinit();

    try testRun(heap, &template);
    try testRun(heap, &template);
    try testRun(heap, &template);
}

/// **Remarks:** Return value must be freed by the caller.
fn getUri(heap: Allocator, child: []const u8) ![]const u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(heap);
    defer heap.free(exe_dir);

    if (std.mem.count(u8, exe_dir, ".zig-cache") == 1) {
        const fmt_str = "{s}/../../../{s}";
        return try std.fmt.allocPrint(heap, fmt_str, .{exe_dir, child});
    } else if (std.mem.count(u8, exe_dir, "zig-out") == 1) {
        const fmt_str = "{s}/../../{s}";
        return try std.fmt.allocPrint(heap, fmt_str, .{exe_dir, child});
    } else {
        unreachable;
    }
}

fn testRun(heap: Allocator, template: *Stencil) !void {
    const id = try heap.alloc(u8, 4);
    defer heap.free(id);
    std.mem.copyForwards(u8, id, "test");

    var ctx = try template.new(id);
    try ctx.load("app.html");
    defer ctx.free();

    const res = try ctx.status();
    std.debug.print("{any}\n", .{res});

    try ctx.replace("../asset", "../../asset");

    try ctx.expand();

    std.debug.print("{?s}\n\n\n", .{try ctx.read()});

    const tokens = try ctx.extract();
    defer ctx.destruct(tokens);

    try ctx.inject(ctx.get(tokens, 0).?, 2, null);
    try ctx.inject(ctx.get(tokens, 1).?, 0, "{d: 23}");

    std.debug.print("{?s}\n\n\n", .{ctx.readFromCache()});
    std.debug.print("{?s}\n\n\n", .{try ctx.read()});
    std.debug.print("{?s}\n\n\n", .{ctx.readFromCache()});
}
