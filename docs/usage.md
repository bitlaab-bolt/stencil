# How to use

First, import Stencil on your zig file.

```zig
const Stencil = @import("stencil").Stencil;
```

## Template Syntax

All template tokens must be a relative path to the base directory of the stencil instance except the runtime content tokens.

### Static Template Syntax

```html
<p>Some Content here...</p>
{{ template/user-info.html }}
```

Static templates can be nested - an included page may itself contain static tokens, and `expand()` resolves the whole chain.

### Dynamic Template Syntax

Dynamic template should always contain `||`.

```html
<p>Some Content here...</p>
{{ template/user.html || template/admin.html || void }}
```

Each `||` separated name is an alternative - pick one at injection time by its position (see [Evaluate Dynamic Templates](#evaluate-dynamic-templates)).

**Remarks:** `void` is a special token, indicates that the content will not be evaluated.

### Dynamic Template Syntax with Runtime Content

Usually only one token is used but you can add multiple tokens too. It's conventional to use only tag-name for runtime tokens rather then the relative path.

```html
<p>Some Content here...</p>
{{ user-json-info || }}
```

### Comments

Tokens inside HTML comments are never evaluated - use them to keep alternates around without paying for evaluation.

```html
<!-- {{ global/user-info.html }} -->
<!-- {{ template/user.html || template/admin.html || void }} -->
```

## Setup Stencil Instance

Make sure to copy the **Page** directory from the repository and paste it to your project.

Copy and paste the following function into your `main.zig` file.

```zig
/// **WARNING:** Return value must be freed by the caller.
fn getUri(io: std.Io, heap: Allocator, child: []const u8) ![]const u8 {
    const exe_dir = try std.process.executableDirPathAlloc(io, heap);
    defer heap.free(exe_dir);

    if (std.mem.count(u8, exe_dir, "zig-out/bin") == 1) {
        const fmt_str = "{s}/../../{s}";
        return try std.fmt.allocPrint(heap, fmt_str, .{exe_dir, child});
    }

    unreachable;
}
```

Now, copy and paste the following code into your `main` function.

```zig
var gpa_mem = std.heap.DebugAllocator(.{}).init;
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();

const path = try getUri(init.io, heap, "page");
defer heap.free(path);

var template = try Stencil.init(init.io, heap, path);
// Also releases any context that missed an explicit `free()`
defer template.deinit();
```

## Create a Template Context

Following example creates a context and loads page content for future evaluation. You can create multiple context with unique identifier.

```zig
var ctx = try template.new("app");
try ctx.load("app.html");
defer ctx.free();
```

- Each call to `load()` must be matched by exactly one `free()`.
- Loading a context twice raises `error.AlreadyLoaded`.

**WARNING:** A duplicate identifier overwrites the previous cache entry - always use a unique identifier per page.

## Check Embedded Template Status

Following example shows what kind of templating are being used.

```zig
const status = try ctx.status();
std.debug.print("Template Status: {any}\n", .{status});
```

| Status | Meaning | Typical action |
| --- | --- | --- |
| `.None` | Page has no template tokens | Render as-is |
| `.Static` | Only static tokens | `expand()` alone is enough |
| `.Dynamic` | Only dynamic tokens | Use `extract()` / `inject()` |
| `.Mixed` | Both kinds | `expand()` first, then `extract()` / `inject()` |

You can branch on the result:

```zig
switch (try ctx.status()) {
    .None => {},
    .Static => try ctx.expand(),
    .Dynamic => {},
    .Mixed => {
        try ctx.expand();
        // then evaluate dynamic tokens, see below
    },
}
```

## Evaluate Static Templates

Following example evaluates all the static templates in a context at once, including any nested templates.

```zig
try ctx.expand();

std.debug.print("Cache: {?s}\n", .{ctx.readFromCache()});
std.debug.print("Content: {?s}\n", .{try ctx.read()});
std.debug.assert(ctx.readFromCache() != null);
```

**Remarks:** Cyclic includes (a page including itself, directly or indirectly) raise `error.CyclicTemplate` instead of looping forever:

```zig
ctx.expand() catch |err| switch (err) {
    error.CyclicTemplate => std.debug.print("Cyclic include rejected\n", .{}),
    else => return err,
};
```

## Evaluate Dynamic Templates

Following example shows how to conditionally evaluate a dynamic template token. You can also pass runtime generated content.

```zig
const tokens = (try ctx.extract()) orelse return; // null when no dynamic tokens
defer ctx.destruct(tokens);

// Injects `template/four.html` content (second name, index 1)
try ctx.inject(ctx.get(tokens, 0).?, 1, null);
// Injects nothing since the token `void`
try ctx.inject(ctx.get(tokens, 1).?, 1, null);
// Injects runtime content (the payload bypasses the file system)
try ctx.inject(ctx.get(tokens, 2).?, 0, "{d: 23}");

std.debug.print("Updated Content: {?s}\n", .{try ctx.read()});
```

**Remarks:**
- `ctx.get(tokens, i)` returns `null` when `i` is out of range - prefer `if (...) |token|` over `.?` in production code.
- `payload` wins over the token name when provided; passing `null` loads the selected name from the page directory instead.
- Inject in top-to-bottom token order.

## Replacing Token String

```zig
try ctx.replace("demo.js", "script.js");
std.debug.print("Final Content: {?s}\n", .{try ctx.read()});
```

`replace()` swaps every occurrence of the target string on the current page data.

## Extract Output

Following example shows how to extract evaluated template content both from context and storage. You can read from cache once you read the content at least once, and you should use common identifier for lazy evaluation when evaluating same page template across multiple functions or modules.

```zig
std.debug.print("{?s}\n", .{ctx.readFromCache()});
std.debug.print("{?s}\n", .{try ctx.read()});
std.debug.print("{?s}\n", .{ctx.readFromCache()});

// Only cached read without cache validation
const content = try template.read("app", null);
std.debug.print("Template Content: {?s}\n", .{content});
```

**Remarks:** `read()` and `readFromCache()` return engine-owned slices - do not free them, and do not keep them across `expand()`, `inject()`, or `replace()` calls, which may reallocate the buffer.

### Debug Callback

`Stencil.read()` accepts an optional callback that receives a freshly loaded page regardless of the cache state - useful for inspecting or patching the on-disk content before it is served. Only use callbacks in debug mode.

```zig
fn debugInspect(ctx: *Stencil.Template) void {
    const data = ctx.readSSR() orelse return;
    std.debug.print("Callback page `{s}` ({d} bytes)\n", .{ ctx.name, data.len });
}

// Somewhere in main:
const content = try template.read("app", debugInspect);
```

**Remarks:** Modifications made inside the callback only reach the cache if the callback calls `ctx.read()`.

## Server Side Rendering (SSR)

For content that is fully generated at runtime, use an SSR context: no page files, no cache - just content in and content out.

```zig
var ctx = try template.newSSR();
defer ctx.freeSSR();

// Raw content instead of a page path
try ctx.loadSSR("<!DOCTYPE html><html><body>{{ header || }}</body></html>");

const tokens = (try ctx.extract()) orelse return;
defer ctx.destruct(tokens);

// Injects runtime generated content into the token
if (ctx.get(tokens, 0)) |token| {
    try ctx.inject(token, 0, "<h1>Rendered at runtime</h1>");
}

std.debug.print("SSR Content: {?s}\n", .{ctx.readSSR()});
```

**Remarks:** Call `freeSSR()` (not `free()`) on SSR contexts, and read the result with `readSSR()` instead of `read()`.

## Sharing the Cache Across Contexts

Contexts created with the same identifier share one cache entry, so a page evaluated once can be re-read cheaply elsewhere.

```zig
var first = try template.new("shared");
try first.load("template/one.html");
defer first.free();

// Populates the cache under the "shared" identifier
_ = try first.read();

// Another context with the same identifier reuses the same cache entry
var second = try template.new("shared");
try second.load("template/one.html");
defer second.free();

std.debug.print("Shared Cache: {?s}\n", .{first.readFromCache()});
std.debug.print("Shared Read: {?s}\n", .{try second.read()});
```

**WARNING:** A duplicate identifier overwrites the previous cache entry - always use a unique identifier per page.

## Error Handling Quick Reference

| Error | Raised by | Meaning |
| --- | --- | --- |
| `error.AlreadyLoaded` | `load()`, `loadSSR()` | Context already holds content |
| `error.CyclicTemplate` | `expand()` | A static include cycle was detected |
| `error.InvalidTokenIndex` | `inject()` | `c_pos` is out of range of the token names |
| `error.InvalidTokenOffset` | `inject()` | Token offsets no longer match the page content |

```zig
ctx.expand() catch |err| switch (err) {
    error.CyclicTemplate => { /* skip or report */ },
    else => return err,
};
```

## Cleanup

- Every context from `new()` must be released with `free()`; every context from `newSSR()` with `freeSSR()`.
- `deinit()` also releases any context that missed an explicit `free()`, so leaks cannot outlive the engine instance.
- Stencil is single threaded; once all pages are evaluated, further operations are read-only and safe to share across threads.
