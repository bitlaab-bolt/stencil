const std = @import("std");
const Allocator = std.mem.Allocator;

const stencil = @import("stencil");
const Stencil = stencil.Stencil;


pub fn main() !void {
    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    const dir = try std.fs.selfExeDirPathAlloc(heap);
    defer heap.free(dir);

    // When you are on Windows or are running: ./zig-out/bin/stencil.exe
    // Make sure to change this path to `{s}/../../page`
    const path = try std.fmt.allocPrint(heap, "{s}/../../../page", .{dir});
    defer heap.free(path);

    var template = try Stencil.init(heap, path, 128);
    defer template.deinit();

    try testRun(heap, &template);
    try testRun(heap, &template);
    try testRun(heap, &template);
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
