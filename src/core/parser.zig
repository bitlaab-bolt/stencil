//! # A Generic Plain Text Parser
//! **Last Updated: 15 March 2025 - v1.0.0**
//! - Expects octets slice as input data
//! - Keeps tracks of `offset`, `column` and `line` numbers for easy debugging

const std = @import("std");
const mem = std.mem;
const testing = std.testing;


const Error = error { UnexpectedEOF, InvalidOffsetRange, UnexpectedCharacter };

const Info = struct { size: usize, offset: usize, column: usize, line: usize };

const Self = @This();

src: []const u8,
offset: usize,
column: usize,
line: usize,

/// # Initiates the Parser
/// **WARNING:** Source data lifetime must be greater then the instance lifetime
/// - `data` - Source content of plain text as the parser input
pub fn init(data: []const u8) Self {
    return .{.src = data, .offset = 0, .column = 0, .line = 1};
}

/// # Peeks a Character
/// The byte value at the current cursor position
pub fn peek(self: *const Self) ?u8 {
    if (self.offset < self.src.len) return self.src[self.offset]
    else return null;
}

/// # Peeks a Character
/// The byte value at the given cursor position
pub fn peekAt(self: *const Self, offset: usize) ?u8 {
    if (offset < self.src.len) return self.src[offset]
    else return null;
}

/// # Peeks Multiple Characters
/// The string value within the given offset range
pub fn peekStr(self: *const Self, begin: usize, end: usize) ![]const u8 {
    if (begin >= end) return Error.InvalidOffsetRange;
    if (end <= self.src.len) return self.src[begin..end]
    else return Error.UnexpectedEOF;
}

/// # Returns a Character
/// Consumes the byte value at the current offset position
pub fn next(self: *Self) !u8 {
    if (self.offset < self.src.len) return self.consume()
    else return Error.UnexpectedEOF;
}

/// # Consumes a Character
/// Updates the internal parser state and returns consumed value
fn consume(self: *Self) u8 {
    const char = self.src[self.offset];
    if (char == '\n') { self.line += 1; self.column = 0; }
    else self.column += 1;
    self.offset += 1;

    return char;
}

/// # Eats the Character
/// Eats the given character when matches the `peek()` character
pub fn eat(self: *Self, char: u8) bool {
    self.expect(char) catch return false;
    return true;
}

/// # Checks Equality
/// Expects `peek()` character to be equal to the `expected` character
fn expect(self: *Self, expected: u8) !void {
    if (self.peek()) |char| {
        if (char == expected) { _ = self.consume(); return; }
        else return Error.UnexpectedCharacter;
    }

    return Error.UnexpectedEOF;
}

/// # Eats the Characters
/// Eats the given characters when matches the `expectStr()` characters
pub fn eatStr(self: *Self, slice: []const u8) bool {
    self.expectStr(slice) catch return false;
    return true;
}

/// # Checks Equality
/// Expects leading offset characters to be equal to the `expected` characters
fn expectStr(self: *Self, expected: []const u8) !void {
    const offset = self.offset + expected.len;
    if (offset > self.src.len) return Error.UnexpectedEOF;

    const remaining = self.src[self.offset..];
    if (mem.startsWith(u8, remaining, expected)) {
        var i: usize = 0;
        while (i < expected.len) : (i += 1) _ = self.consume();
        return;
    }

    return Error.UnexpectedCharacter;
}

/// # Eats Whitespace
/// Eats until a non-whitespace character is found
pub fn eatSp(self: *Self) bool {
    var ws = false;
    while (self.peek()) |char| {
        switch (char) {
            // [0x0B] VT character, [0x0C] FF character
            ' ', '\t', '\n', '\r', 0x0B, 0x0C => {
                _ = self.consume();
                ws = true;
            },
            else => break
        }
    }

    return ws;
}

/// # Returns the Current Offset Position
pub fn cursor(self: *const Self) usize {
    return self.offset;
}

/// # Returns Internal State Information
pub fn info(self: *const Self) Info {
    return .{
        .size = self.src.len,
        .offset = self.offset,
        .column = self.column,
        .line = self.line,
    };
}

/// # Traces Error Info
/// **Remarks:** Useful for identifying and debugging src content errors!
/// - `limit` - Returns the error content up to the given offset boundary
pub fn trace(self: *const Self, limit: usize) []const u8 {
    const slice = self.src[0..self.offset];
    if (slice.len <= limit) return slice
    else return slice[(slice.len - limit)..];
}

test "SmokeTest" {
    const expectTest = testing.expect;
    const expectError = testing.expectError;
    const expectEqual = testing.expectEqual;

    const src = "Game of Thrones!";
    var p = init(src);

    try expectEqual(@as(?u8, 'G'), p.peek());
    try expectEqual('G', try p.next());
    try expectEqual(@as(?u8, 'a'), p.peek());
    try expectEqual(@as(?u8, 'm'), p.peekAt(2));
    try expectTest(mem.eql(u8, "Game", try p.peekStr(0, 4)));
    try expectError(Error.InvalidOffsetRange, p.peekStr(5, 4));
    try expectTest(p.eat('a'));
    try expectTest(p.eatStr("me"));
    try expectEqual(@as(?u8, ' '), p.peek());
    try expectTest(p.eatSp());
    try expectEqual(@as(?u8, 'o'), p.peek());
    try expectTest(!p.eatSp());
    try expectTest(p.eatStr("of"));
    try expectTest(p.eatSp());
    try expectTest(!p.eatStr("thrones!"));
    try expectTest(mem.eql(u8, "Thrones!", try p.peekStr(p.cursor(), src.len)));
    try expectTest(p.eatStr("Thrones!"));
    try expectError(Error.UnexpectedEOF, p.next());
}
