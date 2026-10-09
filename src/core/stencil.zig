//! # File Templating Engine
//!
//! **IMPORTANT:** Stencil is single threaded, but can be used with in
//! multi-threaded environment. Once all the pages are evaluated - page content
//! get cached, therefore multi-threaded operations are read-only.
//!
//! - Only use callback with `read()` in debug mode.
//! - Simultaneous or parallel page evaluation can produce undefined behavior.

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.StringHashMap;

const utils = @import("./utils.zig");
const parser = @import("./parser.zig");


const Str = []const u8;

const Callback = *const fn(*Template) void;

const Cache = struct { url: Str, content: Str };

io: std.Io,
heap: Allocator,
page_dir: Str,
cache: HashMap(Cache),
templates: ArrayList(*Template),

const Self = @This();

/// # Initialize the Template Engine
/// - `dir` - Absolute path of the page directory
pub fn init(io: std.Io, heap: Allocator, dir: Str) !Self {
    return .{
        .io = io,
        .heap = heap,
        .page_dir = dir,
        .templates = .empty,
        .cache = HashMap(Cache).init(heap)
    };
}

/// # Destroys the Template Engine
/// **Remarks:** Any `Template` created with `new()` that was never released
/// with `Template.free()` is cleaned up here as well.
pub fn deinit(self: *Self) void {
    for (self.templates.items) |template| {
        self.heap.free(template.name);
        if (template.url) |url| self.heap.free(url);
        if (template.data) |data| self.heap.free(data);
        self.heap.destroy(template);
    }

    self.templates.deinit(self.heap);

    var iter = self.cache.iterator();
    while (iter.next()) |entry| {
        const id = entry.key_ptr;
        self.heap.free(id.*);

        const cache: *Cache = entry.value_ptr;
        self.heap.free(cache.content);
        self.heap.free(cache.url);
    }
    self.cache.deinit();
}

/// # Creates New Template Context
/// **Remakes:** Make sure to call `Template.free()` when done.
/// - `name` - Template cache storage identifier
/// **WARNING:** Duplicate template (same ID) will overwrite the previous cache.
pub fn new(self: *Self, name: Str) !*Template {
    const title = try self.heap.alloc(u8, name.len);
    mem.copyForwards(u8, title, name);

    const template = try self.heap.create(Template);
    template.* = Template {.parent = self, .name = title};
    try self.templates.append(self.heap, template);
    return template;
}

/// # Creates New SSR (Server Side Rendering) Template Context
/// **Remakes:** Make sure to call `Template.freeSSR()` when done.
pub fn newSSR(self: *Self) !*Template {
    const template = try self.heap.create(Template);
    template.* = Template {.parent = self, .name = "SSR"};
    return template;
}

/// # Reads Cached Page Content from Storage
/// - `name` - Template cache storage identifier
/// - `cfn` - Callback function, Be cautious and only use in debug mode
pub fn read(self: *Self, name: Str, cfn: ?Callback) !?Str {
    const cached = self.cache.get(name) orelse return null;

    if (cfn) |cb| {
        var ctx = try self.new(name);
        errdefer ctx.free();

        try ctx.load(cached.url);
        defer ctx.free();

        cb(ctx); // Invokes user defined function

        // Re-reads in case the callback modified the cache
        return self.cache.get(name).?.content;
    }

    return cached.content;
}

/// # Checks Template Data on the Cache
fn has(self: *Self, name: Str) bool { return self.cache.contains(name); }

/// # Saves Evaluated Template Data on the Cache
fn put(self: *Self, name: Str, path: Str, data: Str) !void {
    const id = try self.heap.alloc(u8, name.len);
    mem.copyForwards(u8, id, name);
    errdefer self.heap.free(id);

    const url = try self.heap.alloc(u8, path.len);
    mem.copyForwards(u8, url, path);
    errdefer self.heap.free(url);

    const content = try self.heap.alloc(u8, data.len);
    mem.copyForwards(u8, content, data);
    errdefer self.heap.free(content);

    if (self.cache.getPtr(id)) |existing| {
        // # Duplicate Identifier
        // - overwrites the stale entry (keeps the original key)
        self.heap.free(existing.url);
        self.heap.free(existing.content);
        self.heap.free(id);

        existing.url = url;
        existing.content = content;
    } else {
        try self.cache.put(id, Cache {
            .url = url, .content = content
        });
    }
}

/// # Updates Stale Cache Content
fn update(self: *Self, name: Str, data: Str) !void {
    const cache: *Cache = self.cache.getPtr(name).?;

    const content = try self.heap.alloc(u8, data.len);
    mem.copyForwards(u8, content, data);

    // Frees only after the new content is secured
    self.heap.free(cache.content);
    cache.content = content;
}

/// # Checks if Cached Data is Outdated
fn stale(self: *Self, name: Str, data: Str) bool {
    const cache = self.get(name).?;
    return !mem.eql(u8, cache.content, data);
}

/// # Extracts Saved Template Data from the Storage
fn get(self: *Self, name: Str) ?Cache { return self.cache.get(name); }

pub const Template = struct {
    parent: *Self,
    name: Str,
    url: ?Str = null,
    data: ?[]u8 = null,
    offset: isize = 0,

    const TemplateType = enum { None, Static, Dynamic, Mixed };

    const Static = struct { name: Str, raw_token: Str };
    const Dynamic = struct { names: []Str, begin: usize, end: usize };
    const Token = union(enum) { static: Static, dynamic: Dynamic };

    /// Upper bound for `expand()` passes - guards against cyclic includes
    const max_expand_passes: usize = 256;

    /// # Loads Page for Incremental Evaluation
    /// - `page` - File path relative to the given page directory
    pub fn load(self: *Template, page: Str) !void {
        if (self.data != null) return error.AlreadyLoaded;

        // Sets path to the cache for future file reading
        const url = try self.parent.heap.alloc(u8, page.len);
        mem.copyForwards(u8, url, page);
        self.url = url;

        const data = try self.content(page);
        self.overwrite(data);
    }

    /// # Loads Static Cache Content for Incremental Dynamic Evaluation
    /// **Remakes:** Make sure to call `Template.free()` when done.
    ///
    /// - `src` - Base cache content for dynamic evaluation
    pub fn loadSSR(self: *Template, src: Str) !void {
        if (self.data != null) return error.AlreadyLoaded;

        // Sets path to the cache for future file reading
        const data = try self.parent.heap.alloc(u8, src.len);
        mem.copyForwards(u8, data, src);
        self.data = data;
    }

    /// # Releases Template Resources
    /// **Remarks:** Safe to call even when `load()` was never invoked.
    pub fn free(self: *Template) void {
        const p = self.parent;

        // Cache resources
        if (self.url) |url| p.heap.free(url);
        if (self.data) |data| p.heap.free(data);

        const templates = p.templates.items;
        for (templates, 0..templates.len) |template, i| {
            if (template == self) {
                const item = p.templates.orderedRemove(i);
                p.heap.free(item.name);
                p.heap.destroy(item);
                break;
            }
        }
    }

    /// # Releases SSR Template Resources
    pub fn freeSSR(self: *Template) void {
        const heap = self.parent.heap;
        if (self.data) |data| heap.free(data);
        heap.destroy(self);
    }

    /// # Reads the Evaluated Page Content
    /// **Remarks:** Also responsible for generating and updating cache data
    ///
    /// - For reading page data from the cache, use `readFromCache()`
    /// - If your page content is generated or modified at runtime
    ///     - You should always use `read()` for most up to date content data
    ///     - Or you can periodically call `read()` along with `readFromCache()`
    pub fn read(self: *Template) !?Str {
        const p = self.parent;

        if (self.data) |data| {
            if (!p.has(self.name)) try p.put(self.name, self.url.?, data)
            else {
                // Updates the outdated cache
                if (p.stale(self.name, data)) try p.update(self.name, data);
            }

            return data;
        }

        return null;
    }

    /// # Reads the Evaluated SSR Page Content
    pub fn readSSR(self: *Template) ?Str { return self.data; }

    /// # Reads Cached Page Content from Storage
    pub fn readFromCache(self: *Template) ?Str {
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
    pub fn replace(self: *Template, target: Str, val: Str) !void {
        const p = self.parent;
        const out = try mem.replaceOwned(u8, p.heap, self.data.?, target, val);
        self.overwrite(out);
    }

    /// # Expands Only Static Templates
    /// **Remarks:** Cyclic includes raise `error.CyclicTemplate`
    pub fn expand(self: *Template) !void {
        const p = self.parent;
        var passes: usize = 0;
        while (true) {
            passes += 1;
            if (passes > max_expand_passes) return error.CyclicTemplate;

            if (try self.templateTokens(self.data.?)) |tokens| {
                defer self.destroy(tokens);

                // Replaces every static token found in this pass - raw tokens
                // are searched patterns, so the source data must stay alive
                // until the last replacement is applied
                var current: Str = self.data.?;
                var changed = false;
                errdefer if (changed) p.heap.free(current);

                for (tokens) |token| {
                    switch(token) {
                        .static => |v| {
                            const tmp = try self.content(v.name);
                            defer p.heap.free(tmp);

                            const out = try mem.replaceOwned(
                                u8, p.heap, current, v.raw_token, tmp
                            );

                            // Frees the intermediate buffer - the original
                            // data is released only after the last pass
                            if (changed) p.heap.free(current);
                            current = out;
                            changed = true;
                        },
                        .dynamic => {}
                    }
                }

                if (!changed) return; // In case of no static token

                const old = self.data.?;
                self.data = @constCast(current);
                p.heap.free(old);
            } else {
                break; // In case of no embedded template
            }
        }
    }

    /// # Extracts Dynamic Template Tokens
    /// **Remakes:** Make sure to call `Template.destruct()` when done.
    pub fn extract(self: *Template) !?[]*Dynamic {
        const p = self.parent;
        var dyn_tokens: ArrayList(*Dynamic) = .empty;
        errdefer dyn_tokens.deinit(p.heap);

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
                        var names: ArrayList(Str) = .empty;
                        errdefer names.deinit(p.heap);

                        for (v.names) |name| {
                            const new_name = try p.heap.alloc(u8, name.len);
                            mem.copyForwards(u8, new_name, name);
                            try names.append(p.heap, new_name);
                        }

                        dyn.names = try names.toOwnedSlice(p.heap);
                        try dyn_tokens.append(p.heap, dyn);
                    }
                }
            }

            if (dyn_tokens.items.len > 0) {
                return try dyn_tokens.toOwnedSlice(p.heap);
            }
        }

        dyn_tokens.deinit(p.heap);
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
    /// **Remarks:** You must always inject from top to bottom order. Also 
    ///
    /// - `c_pos` - Current page index position of the dynamic template
    /// - `payload` - For runtime-generated content, otherwise **null**
    pub fn inject(
        self: *Template,
        token: *Dynamic,
        c_pos: usize,
        payload: ?Str
    ) !void {
        const p = self.parent;
        const data = self.data.?;

        if (c_pos >= token.names.len) return error.InvalidTokenIndex;

        const off_begin = @as(isize, @intCast(token.begin)) + self.offset;
        const off_end = @as(isize, @intCast(token.end)) + self.offset;

        // Guards against desynchronized offsets (e.g., content modified
        // between `extract()` and `inject()`)
        if (off_begin < 0 or off_end < 0 or off_begin > off_end
        or @as(usize, @intCast(off_end)) > data.len) {
            return error.InvalidTokenOffset;
        }

        const begin: usize = @intCast(off_begin);
        const end: usize = @intCast(off_end);

        const raw_token = data[begin..end];
        const tok_sz = @as(isize, @intCast(raw_token.len));

        if (mem.eql(u8, token.names[c_pos], "void")) {
            self.offset -= tok_sz;

            const size = self.data.?.len - raw_token.len;
            const out = try p.heap.alloc(u8, size);

            mem.copyForwards(u8, out, self.data.?[0..begin]);
            mem.copyForwards(u8, out[begin..], self.data.?[end..]);
            self.overwrite(out);
        } else {
            const tmp = if (payload) |bytes| bytes
            else try self.content(token.names[c_pos]);
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
    fn templateTokens(self: *Template, src: Str) !?[]Token {
        const parent = self.parent;
        const heap = parent.heap;

        var tokens: ArrayList(Token) = .empty;
        errdefer tokens.deinit(heap);

        // Deduplicates static tokens in O(1) per occurrence
        var seen = std.StringHashMap(void).init(heap);
        defer seen.deinit();

        var p = parser.init(src);
        var begin: ?usize = null;
        var end: ?usize = null;

        while(p.peek() != null) {
            try skipComment(&p);

            if (p.eatStr("{{")) begin = p.cursor() - 2;
            if (p.eatStr("}}")) end = p.cursor();

            // Extracts the token string
            if (begin != null and end != null) {
                const raw_token = try p.peekStr(begin.? + 2, end.? - 2);
                const new_token = mem.trim(u8, raw_token, &ascii.whitespace);

                var iter = mem.tokenizeAny(u8, new_token, "||");
                if (iter.peek()) |first| {
                    if (mem.eql(u8, first, new_token)) {
                        // Static token
                        if (!seen.contains(new_token)) {
                            try seen.put(new_token, {});

                            const token = Static {
                                .name = new_token,
                                .raw_token = try p.peekStr(begin.?, end.?)
                            };
                            try tokens.append(heap, Token {.static = token});
                        }
                    } else {
                        var dyn_tokens: ArrayList(Str) = .empty;
                        errdefer dyn_tokens.deinit(heap);

                        while (iter.peek() != null) {
                            try dyn_tokens.append(
                                heap, mem.trim(u8, iter.next().?, &ascii.whitespace)
                            );
                        }

                        // Dynamic token
                        const items = try dyn_tokens.toOwnedSlice(heap);
                        const token = Dynamic {
                            .names = items,
                            .begin = begin.?,
                            .end = end.?
                        };
                        try tokens.append(heap, Token {.dynamic = token});
                    }
                }

                begin = null; // Resets begin offset
                end = null;   // Resets end offset
                continue; // Re-checks from the current position (handles
                          // adjacent tokens and tokens ending at EOF)
            }

            try skipComment(&p);
            if (p.peek() == null) break;

            // Consumes one candidate byte, then skips ahead in bulk to the
            // next one - tokens only ever start at '{', '}' or '<'
            _ = try p.next();
            p.scanTo("{<}");
        }

        if (tokens.items.len > 0) return try tokens.toOwnedSlice(heap)
        else { tokens.deinit(heap); return null; }
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
    /// - `page` - File path relative to the given page directory
    fn content(self: *Template, page: Str) !Str {
        const p = self.parent;
        const io = p.io;

        return try utils.loadFile(io, p.heap, p.page_dir, page);
    }

    /// # Overwrites the Existing Data
    fn overwrite(self: *Template, data: Str) void {
        const p = self.parent;
        if (self.data) |page_data| p.heap.free(page_data);
        self.data = @constCast(data);
    }

    /// # Skips HTML Comment
    fn skipComment(p: *parser) !void {
        if (!p.eatStr("<!--")) return;
        while (p.peek() != null) {
            if (p.eatStr("-->")) return;
            _ = try p.next();
            p.scanTo("-");
        }
    }
};
