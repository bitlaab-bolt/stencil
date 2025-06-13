//! # File Templating Engine
//! TODO: Add multi-threading support

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const crypto = std.crypto;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.StringHashMap;

const utils = @import("./utils.zig");
const parser = @import("./parser.zig");


const Error = error { AlreadyLoaded };
const Cache = struct { content: []const u8, hash: [32]u8 };

heap: Allocator,
max_len: usize,
page_dir: []const u8,
cache: HashMap(Cache),
templates: ArrayList(*Template),

const Self = @This();

/// # Initialize the Template Engine
/// - `dir` - Absolute path of the page directory
/// - `limit` - Maximum file size in KB for a page
pub fn init(heap: Allocator, dir: []const u8, limit: usize) !Self {
    return .{
        .heap = heap,
        .max_len = limit,
        .page_dir = dir,
        .cache = HashMap(Cache).init(heap),
        .templates = ArrayList(*Template).init(heap)
    };
}

/// # Destroys the Template Engine
pub fn deinit(self: *Self) void {
    self.templates.deinit();

    var iter = self.cache.iterator();
    while (iter.next()) |entry| {
        const id = entry.key_ptr;
        self.heap.free(id.*);

        const cache: *Cache = entry.value_ptr;
        self.heap.free(cache.content);
    }
    self.cache.deinit();
}

/// # Creates New Template Context
/// - `name` - Template cache storage identifier
pub fn new(self: *Self, name: []const u8) !*Template {
    const title = try self.heap.alloc(u8, name.len);
    mem.copyForwards(u8, title, name);

    const template = try self.heap.create(Template);
    template.* = Template { .parent = self, .name = title };
    try self.templates.append(template);
    return template;
}

/// # Checks Template Data on the Cache
fn has(self: *Self, name: []const u8) bool {
    return self.cache.contains(name);
}

/// # Saves Evaluated Template Data on the Cache
fn put(self: *Self, name: []const u8, data: []const u8) !void {
    const id = try self.heap.alloc(u8, name.len);
    mem.copyForwards(u8, id, name);

    const digest = hash(data);
    const content = try self.heap.alloc(u8, data.len);
    mem.copyForwards(u8, content, data);

    try self.cache.put(id, Cache {.content = content, .hash = digest});
}

/// # Updates Stale Cache Content
fn update(self: *Self, name: []const u8, data: []const u8) !void {
    const cache: *Cache = self.cache.getPtr(name).?;
    self.heap.free(cache.content);

    const digest = hash(data);
    const content = try self.heap.alloc(u8, data.len);
    mem.copyForwards(u8, content, data);

    cache.content = content;
    cache.hash = digest;
}

/// # Checks if Cached Data is Outdated
fn stale(self: *Self, name: []const u8, data: []const u8) bool {
    const digest = hash(data);
    const cache = self.get(name).?;
    return if (!mem.eql(u8, &cache.hash, &digest)) true else false;
}

/// # Extracts Saved Template Data from the Storage
fn get(self: *Self, name: []const u8) ?Cache {
    return self.cache.get(name);
}

/// # Generates SHA-256 Digest of a Given Content
fn hash(content: []const u8) [32]u8 {
    var sha256 = crypto.hash.sha2.Sha256.init(.{});
    sha256.update(content);

    var digest: [32]u8 = undefined;
    sha256.final(&digest);
    return digest;
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
    /// **Remakes:** Make sure to call `Template.free()` when done.
    pub fn load(self: *Template, page: []const u8) !void {
        if (self.data != null) return Error.AlreadyLoaded;

        const p = self.parent;
        const data = try self.content(page, p.max_len);
        self.overwrite(data);
    }

    /// # Releases Template Resources
    pub fn free(self: *Template) void {
        const p = self.parent;
        if (self.data) |data| p.heap.free(data);

        const templates = p.templates.items;
        for (templates, 0..templates.len) |template, i| {
            if (template == self) {
                const item = p.templates.orderedRemove(i);
                p.heap.free(item.name);
                p.heap.destroy(item);
            }
        }
    }

    /// # Reads the Evaluated Page Content
    /// **Remarks:** Also responsible for generating and updating cache data
    /// - For reading page data from the cache use `readFromCache()`
    /// - If your page content is generated or modified at runtime
    ///     - You should always use `read()` for most up to date content data
    ///     - Or you can periodically call `read()` along with `readFromCache()`
    pub fn read(self: *Template) !?[]const u8 {
        const p = self.parent;

        if (self.data) |data| {
            if (!p.has(self.name)) try p.put(self.name, data)
            else {
                // Updates the outdated cache
                if (p.stale(self.name, data)) try p.update(self.name, data);
            }

            return data;
        }

        return null;
    }

    /// # Reads Cached Page Content from Storage
    pub fn readFromCache(self: *Template) ?[]const u8 {
        const p = self.parent;
        if (p.get(self.name)) |cache| return cache.content
        else return null;
    }

    /// # Returns Template Type of a Given Page
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

    /// # Replaces Targeted Token with Given Value
    pub fn replace(self: *Template, target: []const u8, val: []const u8) !void {
        const p = self.parent;
        const out = try mem.replaceOwned(u8, p.heap, self.data.?, target, val);
        self.overwrite(out);
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
                            const tmp = try self.content(v.name, p.max_len);
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
    /// **Remakes:** Make sure to call `Template.destruct()` when done.
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
                        var names = ArrayList([]const u8).init(p.heap);
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

    /// # Destroys Dynamic Template Tokens
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
        const tok_sz = @as(isize, @intCast(raw_token.len));

        if (mem.eql(u8, token.names[option], "void")) {
            self.offset -= tok_sz;

            const size = self.data.?.len - raw_token.len;
            const out = try p.heap.alloc(u8, size);

            mem.copyForwards(u8, out, self.data.?[0..begin]);
            mem.copyForwards(u8, out[begin..], self.data.?[end..]);
            self.overwrite(out);
        } else {
            const tmp = if (payload) |bytes| bytes
            else try self.content(token.names[option], p.max_len);
            defer { if (payload == null) p.heap.free(tmp); }

            const tmp_sz = @as(isize, @intCast(tmp.len));
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
    /// - `page` - Absolute page file path
    /// - `size` - Maximum page size in KB
    fn content(self: *Template, page: []const u8, size: usize) ![]const u8 {
        const p = self.parent;
        return try utils.loadFile(p.heap, p.page_dir, page, 1024 * size);
    }

    /// # Overwrites the Existing Data
    fn overwrite(self: *Template, data: []const u8) void {
        const p = self.parent;
        if (self.data) |page_data| p.heap.free(page_data);
        self.data = @constCast(data);
    }

    /// # Removes Duplicate Static Template Tokens
    /// - For one-shot expansion, since static tokens have a fixed data mapping
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
