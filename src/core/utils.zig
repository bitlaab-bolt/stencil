//! # Generic Utility Functions

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

/// # Loads File Content
/// **WARNING:** Return value must be deallocated!
/// - `max_size` - Maximum file size in bytes
pub fn loadFile(heap: Allocator, path: []const u8, max_size: usize) ![]u8 {
    const file = try fs.Dir.openFile(fs.cwd(), path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var input_stream = buf_reader.reader();

    return try input_stream.readAllAlloc(heap, max_size);
}
