const std = @import("std");

const stencil = @import("./core/stencil.zig");


pub fn main() !void {
    var gpa_mem = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    var template = try stencil.init(heap, "page", 128);
    defer template.deinit();

    var ctx = try template.new();
    try ctx.load("app.html");
    defer ctx.free();

    const res = try ctx.status();
    std.debug.print("{any}\n", .{res});

    try ctx.expand();

    const tokens = try ctx.extract();
    defer ctx.destruct(tokens);

    try ctx.inject(ctx.get(tokens, 0).?, 1, null);
    try ctx.inject(ctx.get(tokens, 1).?, 1, "Hello!!!");

    std.debug.print("{?s}\n", .{ctx.read()});
}
