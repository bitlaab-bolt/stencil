const std = @import("std");
const Allocator = std.mem.Allocator;

const stencil = @import("./core/stencil.zig");


pub fn main() !void {
    var gpa_mem = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    var template = try stencil.init(heap, "page", 128);
    defer template.deinit();

    try testRun(heap, &template);
    try testRun(heap, &template);
    try testRun(heap, &template);
}

fn testRun(heap: Allocator, template: *stencil) !void {
    const id = try heap.alloc(u8, 4);
    std.mem.copyForwards(u8, id, "test");

    var ctx = try template.new(id);
    try ctx.load("app.html");
    defer ctx.free();

    heap.free(id);

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
