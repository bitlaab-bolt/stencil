const std = @import("std");

const stencil = @import("./core/stencil.zig");


pub fn main() !void {
    var gpa_mem = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

    var template = try stencil.init(heap, "page", 128);
    defer template.deinit();

    var ctx = try template.new("app");
    try ctx.load("app.html");
    defer ctx.free();

    const res = try ctx.status();
    std.debug.print("{any}\n", .{res});

    try ctx.replace("../asset", "../../asset");

    try ctx.expand();

    const tokens = try ctx.extract();
    defer ctx.destruct(tokens);

    // try ctx.inject(ctx.get(tokens, 0).?, 1, null);
    try ctx.inject(ctx.get(tokens, 0).?, 2, null);
    try ctx.inject(ctx.get(tokens, 1).?, 0, "{d: 23}");

    std.debug.print("{?s}\n\n\n", .{ctx.readFromCache()});
    std.debug.print("{?s}\n\n\n", .{try ctx.read()});
    std.debug.print("{?s}\n\n\n", .{ctx.readFromCache()});
}
