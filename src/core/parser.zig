//! # A Generic Plain Text Parser - v1.0.1
//! - Expects octet slice as input (source) data
//! - Keeps tracks of `offset`, `column`, and `line` numbers for easy debugging

const std = @import("std");
const mem = std.mem;
const testing = std.testing;


const Error = error { UnexpectedEOF, InvalidOffsetRange, UnexpectedCharacter };

const Info = struct { size: usize, offset: usize, column: usize, line: usize };

pub const SpecialChar = struct {
    /// # Space Character
    /// Also known as white space, used to separate tokens or fields.
    const SP = 0x20;

    /// # Line Feed
    /// `\n` - Also known as new line. used to separate tokens or fields.
    const LF = 0x0A;

    /// # Carriage Return
    /// `\r` - Moves terminal cursor to the beginning of the current line.
    const CR = 0x0D;

    /// # Horizontal Tab
    /// `\t` - Moves terminal cursor to the next tab stop, often every 4 SPs.
    const HT = 0x09;

    /// # Vertical Tab
    /// It's rarely used and often ignored or treated as whitespace.
    const VT = 0x0B;

    /// # Form Feed
    /// It's rarely used and often ignored or treated as whitespace.
    const FF = 0x0C;
};

const Self = @This();

src: []const u8,
offset: usize,
column: usize,
line: usize,

/// # Initiates the Parser
/// **WARNING:** Source data lifetime must be greater than the instance lifetime
/// - `data` - Source content of plain text as the parser input
pub fn init(data: []const u8) Self {
    return .{.src = data, .offset = 0, .column = 0, .line = 1};
}

/// # Peeks a Character
/// - The byte value at the current cursor position
pub fn peek(self: *const Self) ?u8 {
    if (self.offset < self.src.len) return self.src[self.offset]
    else return null;
}

/// # Peeks a Character
/// - The byte value at the given cursor position
pub fn peekAt(self: *const Self, offset: usize) ?u8 {
    if (offset < self.src.len) return self.src[offset]
    else return null;
}

/// # Peeks Multiple Characters
/// - The string value within the given offset range
pub fn peekStr(self: *const Self, begin: usize, end: usize) ![]const u8 {
    if (begin > end) return Error.InvalidOffsetRange;
    if (end <= self.src.len) return self.src[begin..end]
    else return Error.UnexpectedEOF;
}

/// # Returns a Character
/// - Consumes the byte value at the current offset position
pub fn next(self: *Self) !u8 {
    if (self.offset < self.src.len) return self.consume()
    else return Error.UnexpectedEOF;
}

/// # Consumes a Character
/// - Updates the internal parser state and returns consumed value
fn consume(self: *Self) u8 {
    const char = self.src[self.offset];
    if (char == SpecialChar.LF) { self.line += 1; self.column = 0; }
    else self.column += 1;
    self.offset += 1;

    return char;
}

/// # Eats the Character
/// - Eats the given character when it matches the `peek()` character
pub fn eat(self: *Self, char: u8) bool {
    self.expect(char) catch return false;
    return true;
}

/// # Checks Equality
/// - Expects `peek()` character to be equal to the `expected` character
fn expect(self: *Self, expected: u8) !void {
    if (self.peek()) |char| {
        if (char == expected) { _ = self.consume(); return; }
        else return Error.UnexpectedCharacter;
    }

    return Error.UnexpectedEOF;
}

/// # Eats the Characters
/// - Eats the given characters when match the `expectStr()` characters
/// - An empty `slice` always succeeds without consuming anything
pub fn eatStr(self: *Self, slice: []const u8) bool {
    self.expectStr(slice) catch return false;
    return true;
}

/// # Checks Equality
/// - Expects leading offset characters to be equal to the `expected` characters
fn expectStr(self: *Self, expected: []const u8) !void {
    const offset = self.offset +| expected.len;
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
            SpecialChar.SP,
            SpecialChar.HT,
            SpecialChar.LF,
            SpecialChar.CR,
            SpecialChar.VT,
            SpecialChar.FF => {
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
/// **Remarks:** Useful for identifying and debugging source content errors!
///
/// - `limit` - Maximum number of trailing bytes / full content when lesser.
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

test "LineAndColumnTracking" {
    const expectEqual = testing.expectEqual;

    var p = init("ab\ncd\r\nef\tx");
    _ = try p.next(); // 'a' -> column 1
    _ = try p.next(); // 'b' -> column 2
    _ = try p.next(); // '\n' -> line 2, column 0
    _ = try p.next(); // 'c' -> column 1
    _ = try p.next(); // 'd' -> column 2
    _ = try p.next(); // CR counted as an ordinary byte -> column 3
    _ = try p.next(); // '\n' -> line 3, column 0
    _ = try p.next(); // 'e' -> column 1
    _ = try p.next(); // 'f' -> column 2
    _ = try p.next(); // HT counted as an ordinary byte -> column 3

    const state = p.info();
    try expectEqual(@as(usize, 3), state.line);
    try expectEqual(@as(usize, 3), state.column);
}

test "EatWhitespaceAcrossLines" {
    const expectTest = testing.expect;
    const expectEqual = testing.expectEqual;

    var p = init(" \t\r\nx");
    try expectTest(p.eatSp());
    try expectEqual(@as(?u8, 'x'), p.peek());
    try expectEqual(@as(usize, 2), p.info().line);
    try expectTest(!p.eatSp());
}

test "EatStrNoPartialConsume" {
    const expectTest = testing.expect;
    const expectEqual = testing.expectEqual;

    var p = init("world");
    try expectTest(!p.eatStr("worx"));
    try expectEqual(@as(usize, 0), p.cursor());
    try expectEqual(@as(?u8, 'w'), p.peek());
}

test "EmptySliceEdgeCases" {
    const expectEqual = testing.expectEqual;
    const expectError = testing.expectError;
    const expectTest = testing.expect;

    var p = init("abcd");
    try expectTest(p.eatStr(""));
    try expectEqual(@as(usize, 0), p.cursor());
    try expectEqual(@as(usize, 0), (try p.peekStr(0, 0)).len);
    try expectEqual(@as(usize, 2), (try p.peekStr(1, 3)).len);
    try expectError(Error.InvalidOffsetRange, p.peekStr(2, 1));
}

test "TraceTrailingContent" {
    const expectTest = testing.expect;

    var p = init("0123456789");
    var i: usize = 0;
    while (i < 6) : (i += 1) _ = try p.next();

    try expectTest(mem.eql(u8, "012345", p.trace(10)));
    try expectTest(mem.eql(u8, "012345", p.trace(6)));
    try expectTest(mem.eql(u8, "12345", p.trace(5)));
    try expectTest(mem.eql(u8, "", p.trace(0)));
}
