//! Content Templating Engine

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const ascii = std.ascii;
const ArrayList = std.ArrayList;
const HashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;

const utils = @import("./utils.zig");
const parser = @import("./parser.zig");


const Error = error { AlreadyLoaded };

heap: Allocator,
root: []const u8,
limit: usize,
templates: ArrayList(*Template),
storage: HashMap([]const u8),

const Self = @This();

/// - `dir` - Base directory relative to your project
/// - `limit` - Maximum file size limit in KB
pub fn init(heap: Allocator, dir: []const u8, limit: usize) !Self {
    const cwd = try std.fs.cwd().realpathAlloc(heap, ".");
    defer heap.free(cwd);

    const abs_path = try fmt.allocPrint(heap, "{s}/{s}", .{cwd, dir});
    return .{
        .heap = heap,
        .root = abs_path,
        .limit = limit,
        .templates = ArrayList(*Template).init(heap),
        .storage = HashMap([]const u8).init(heap)
    };
}

pub fn deinit(self: *Self) void {
    self.heap.free(self.root);
    for (self.templates.items) |template| self.heap.destroy(template);
    self.templates.deinit();
    self.storage.deinit();
}

/// # Creates New Template Context
pub fn new(self: *Self, name: []const u8) !*Template {
    const template = try self.heap.create(Template);
    template.* = Template { .parent = self, .name = name };
    try self.templates.append(template);
    return template;
}

/// # Checks Template Data on Storage
fn has(self: *Self, name: []const u8) bool {
    return self.storage.contains(name);
}

/// # Saves Evaluated Template Data to the Storage
fn put(self: *Self, name: []const u8, data: []const u8) !void {
    try self.storage.put(name, data);
}

/// # Extracts Saved Template Data from the Storage
fn get(self: *Self, name: []const u8) ?[]const u8 {
    return self.storage.get(name);
}

const Template = struct {
    parent: *Self,
    name: []const u8,
    data: ?[]u8 = null,
    offset: isize = 0,

    const TemplateType = enum { None, Static, Dynamic, Mixed };

    const Static = struct { name: []const u8, raw_token: []const u8 };
    const Dynamic = struct { names: [][]const u8, begin: usize, end: usize };
    const Token = union(enum) { static: Static, dynamic: Dynamic };

    /// # Loads Page for Incremental Evaluation
    /// **Remakes:** Make sure to call `free()` when done
    pub fn load(self: *Template, page: []const u8) !void {
        if (self.data != null) return Error.AlreadyLoaded;

        const p = self.parent;
        const data = try self.content(page, p.limit);
        self.overwrite(data);
    }

    /// # Release Template Resources
    pub fn free(self: *Template) void {
        const p = self.parent;
        if (self.data) |data| p.heap.free(data);

        const templates = p.templates.items;
        for (templates, 0..templates.len) |template, i| {
            if (template == self) {
                const item = p.templates.orderedRemove(i);
                p.heap.destroy(item);
            }
        }
    }

    /// # Reads the Evaluated Page Content
    pub fn read(self: *Template) !?[]const u8 {
        const p = self.parent;
        if (self.data) |data| {
            if (!p.has(self.name)) try p.put(self.name, data);
            return data;
        }

        return null;
    }

    /// # Reads Cached Page Content from Storage
    pub fn readFromCache(self: *Template) ?[]const u8 {
        const p = self.parent;
        return p.get(self.name);
    }

    /// # Embedded Template of a Given Page
    pub fn status(self: *Template) !TemplateType {
        if (try self.templateTokens(self.data.?)) |tokens| {
            defer self.destroy(tokens);

            var c: usize = 0;
            for (tokens) |token| {
                switch (token) {.static => c += 1, .dynamic => {} }
            }

            return if (c == tokens.len) .Static
            else if (c == 0) .Dynamic
            else .Mixed;
        }

        return .None;
    }

    /// # Expands Only Static Templates
    pub fn expand(self: *Template) !void {
        const p = self.parent;
        while (true) {
            if (try self.templateTokens(self.data.?)) |tokens| {
                defer self.destroy(tokens);

                var retry: bool = false;
                for (tokens) |token| {
                    switch(token) {
                        .static => |v| {
                            const tmp = try self.content(v.name, p.limit);
                            defer p.heap.free(tmp);

                            const out = try mem.replaceOwned(
                                u8, p.heap, self.data.?, v.raw_token, tmp
                            );
                            self.overwrite(out);
                            retry = true;
                            break;
                        },
                        .dynamic => {}
                    }
                }

                if (!retry) return; // Incase of no static token
            } else {
                break; // Incase of no embedded template
            }
        }
    }

    /// # Extracts Dynamic Template Tokens
    /// **Remakes:** Make sure to call `destruct()` when done
    pub fn extract(self: *Template) !?[]*Dynamic {
        const p = self.parent;
        var dyn_tokens = ArrayList(*Dynamic).init(p.heap);

        if (try self.templateTokens(self.data.?)) |tokens| {
            defer self.destroy(tokens);

            for (tokens) |token| {
                switch(token) {
                    .static => {},
                    .dynamic => |v| {
                        const dyn = try p.heap.create(Dynamic);
                        dyn.*.begin = v.begin;
                        dyn.*.end = v.end;

                        // Clones dynamic token data
                        var names = ArrayList([]u8).init(p.heap);
                        for (v.names) |name| {
                            const new_name = try p.heap.alloc(u8, name.len);
                            mem.copyForwards(u8, new_name, name);
                            try names.append(new_name);
                        }

                        dyn.names = try names.toOwnedSlice();
                        try dyn_tokens.append(dyn);
                    }
                }
            }

            if (dyn_tokens.items.len > 0) return try dyn_tokens.toOwnedSlice();
        }

        dyn_tokens.deinit();
        return null;
    }

    /// # Deallocate Dynamic Token Names
    pub fn destruct(self: *Template, dyn: ?[]*Dynamic) void {
        const p = self.parent;

        if (dyn) |tokens| {
            for (tokens) |token| {
                for (token.names) |name| p.heap.free(name);
                p.heap.free(token.names);
                p.heap.destroy(token);
            }
            p.heap.free(tokens);
        }
    }

    /// # Extracts Dynamic Token at Given Position
    pub fn get(self: *Template, dyn: ?[]*Dynamic, at: usize) ?*Dynamic {
        _ = self; // Makes this a member function
        return if (dyn != null and dyn.?.len > at) dyn.?[at]
        else null;
    }

    /// # Injects Dynamic Template Page
    /// **Remarks:** Your must always inject from top to bottom order!
    /// - `option` - Page index position of the dynamic template
    /// - `payload` - For runtime generated content otherwise **null**
    pub fn inject(
        self: *Template,
        token: *Dynamic,
        option: usize,
        payload: ?[]const u8
    ) !void {
        const p = self.parent;
        const data = self.data.?;

        const off_begin = @as(isize, @intCast(token.begin)) + self.offset;
        const off_end = @as(isize, @intCast(token.end)) + self.offset;
        const begin: usize = @intCast(off_begin);
        const end: usize = @intCast(off_end);

        const raw_token = data[begin..end];

        if (mem.eql(u8, token.names[option], "void")) {
            const out = try mem.replaceOwned(
                u8, p.heap, self.data.?, raw_token, ""
            );
            self.overwrite(out);
        } else {
            const tmp = if (payload) |bytes| bytes
            else try self.content(token.names[option], p.limit);
            defer { if (payload == null) p.heap.free(tmp); }

            const tmp_sz = @as(isize, @intCast(tmp.len));
            const tok_sz = @as(isize, @intCast(raw_token.len));
            self.offset += (tmp_sz - tok_sz);

            const size = (self.data.?.len + tmp.len) - raw_token.len;
            const out = try p.heap.alloc(u8, size);

            mem.copyForwards(u8, out, self.data.?[0..begin]);
            mem.copyForwards(u8, out[begin..], tmp);
            mem.copyForwards(u8, out[begin + tmp.len..], self.data.?[end..]);
            self.overwrite(out);
        }
    }

    /// # Extracts Template Tokens
    /// - `src` - Slice of the page content
    fn templateTokens(self: *Template, src: []const u8) !?[]Token {
        const parent = self.parent;
        var tokens = ArrayList(Token).init(parent.heap);

        var p = parser.init(src);
        var begin: ?usize = null;
        var end: ?usize = null;

        while(p.peek() != null) {
            try skipComment(&p);

            if (p.eatStr("{{")) begin = p.cursor() - 2;
            if (p.eatStr("}}")) end = p.cursor();

            // Extracts token string
            if (begin != null and end != null) {
                const raw_token = try p.peekStr(begin.? + 2, end.? - 2);
                const new_token = mem.trim(u8, raw_token, &ascii.whitespace);

                var iter = mem.tokenizeAny(u8, new_token, "||");
                if (mem.eql(u8, iter.peek().?, new_token)) {
                    // Static token
                    if (!hasStatic(tokens.items, new_token)) {
                        const token = Static {
                            .name = new_token,
                            .raw_token = try p.peekStr(begin.? - 2, end.?)
                        };
                        try tokens.append(Token {.static = token});
                    }
                } else {
                    var dyn_tokens = ArrayList([]const u8).init(parent.heap);

                    while (iter.peek() != null) {
                        try dyn_tokens.append(
                            mem.trim(u8, iter.next().?, &ascii.whitespace)
                        );
                    }

                    // Dynamic token
                    const items = try dyn_tokens.toOwnedSlice();
                    const token = Dynamic {
                        .names = items,
                        .begin = begin.? - 2,
                        .end = end.?
                    };
                    try tokens.append(Token {.dynamic = token});
                }

                begin = null; // Resets begin offset
                end = null;   // Resets end offset
            }

            try skipComment(&p);
            _ = try p.next();
        }

        if (tokens.items.len > 0) return try tokens.toOwnedSlice()
        else { tokens.deinit(); return null; }
    }

    /// # Deallocate Template Tokens
    fn destroy(self: *Template, tokens: []Token) void {
        const p = self.parent;

        for (tokens) |token| {
            switch (token) {.dynamic => |v| p.heap.free(v.names), else => {}}
        }

        p.heap.free(tokens);
    }

    /// # Loads Page Content
    /// - `size` - Maximum page size in KB
    fn content(self: *Template, page: []const u8, size: usize) ![]const u8 {
        const p = self.parent;
        const path = try fmt.allocPrint(p.heap, "{s}/{s}", .{p.root, page});
        defer p.heap.free(path);

        return try utils.loadFile(p.heap, path, 1024 * size);
    }

    /// # Overwrites the Existing Data
    fn overwrite(self: *Template, data: []const u8) void {
        const p = self.parent;
        if (self.data) |page_data| p.heap.free(page_data);
        self.data = @constCast(data);
    }

    /// # Removes Duplicate Static Template Tokens
    /// - For one-shot expansion, since static tokens has a fixed data mapping
    fn hasStatic(tokens: []Token, name: []const u8) bool {
        for (tokens) |item| {
            switch (item) {
                .static => |v| if (mem.eql(u8, v.name, name)) return true,
                .dynamic => {}
            }
        }

        return false;
    }

    /// # Skips HTML Comment
    fn skipComment(p: *parser) !void {
        if (!p.eatStr("<!--")) return;
        while (p.peek() != null and !p.eatStr("-->")) { _ = try p.next(); }
    }
};
