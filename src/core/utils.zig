//! # Utility Module

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const Allocator = std.mem.Allocator;
const SrcLoc = std.builtin.SourceLocation;


const Str = []const u8;

//// # Loads File Content
/// **WARNING:** Return value must be freed by the caller
/// - `dir` - The absolute parent directory path
/// - `path` - A sub file path relative to the given directory path
/// - `max_size` - Maximum file size in bytes for the IO buffered reader
pub fn loadFile(heap: Allocator, dir: Str, path: Str, max_size: usize) !Str {
    return loadFileZ(heap, dir, path, max_size) catch |err| {
        if (mem.eql(u8, @errorName(err), "StreamTooLong")) {
            const fmt_str = "{s} exceeds the max size of {d}KB";
            log(.err, fmt_str, .{path, max_size / 1024}, @src());
        } else {
            const fmt_str = "File system error on: {s}";
            log(.err, fmt_str, .{path}, @src());
        }

        return err;
    };
}

fn loadFileZ(heap: Allocator, dir: Str, path: Str, max_size: usize) !Str {
    var abs_dir = try fs.openDirAbsolute(dir, .{});
    defer abs_dir.close();

    const file = try abs_dir.openFile(path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var input_stream = buf_reader.reader();

    return try input_stream.readAllAlloc(heap, max_size);
}

const Log = enum { info, warn, err };

/// # Synchronous Terminal Logger
/// A wrapper around `std.log` with additional source information
pub fn log(kind: Log, comptime format: Str, args: anytype, src: SrcLoc) void {
    switch (kind) {
        .info => std.log.info(format, args),
        .warn => std.log.warn(format, args),
        .err => std.log.err(format, args)
    }
    const fmt_str = "source: {s} at {d}:{d}\n";
    debug.print(fmt_str, .{src.file, src.line, src.column});
}
