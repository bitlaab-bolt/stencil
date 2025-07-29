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

### Dynamic Template Syntax

```html
<p>Some Content here...</p>
{{ template/user.html || template/admin.html || void }}
```

**Remarks:** `void` is a special token, indicates that the content will not be evaluated.

### Dynamic Template Syntax with Runtime Content

Usually only one token is used but you can add multiple tokens too. It's conventional to use only tag-name for runtime tokens rather then the relative path.

```html
<p>Some Content here...</p>
{{ user-json-info || }}
```

### Comments

```html
<!-- {{ global/user-info.html }} -->
<!-- {{ template/user.html || template/admin.html || void }} -->
```

## Setup Stencil Instance

Make sure to copy the **Page** directory from the repository and paste it to your project.

Copy and paste the following function into your `main.zig` file.

```zig
/// **Remarks:** Return value must be freed by the caller.
fn getUri(heap: Allocator, child: []const u8) ![]const u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(heap);
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

const path = try getUri(heap, "page");
defer heap.free(path);

var template = try Stencil.init(heap, path, 128);
defer template.deinit();
```

## Create a Template Context

Following example creates a context and loads page content for future evaluation. You can create multiple context with unique identifier.

```zig
var ctx = try template.new("app");
try ctx.load("app.html");
defer ctx.free();
```

## Check Embedded Template Status

Following example shows what kind of templating are being used.

```zig
const status = try ctx.status();
std.debug.print("{any}\n", .{status});
```

## Evaluate Static Templates

Following example evaluates all the static templates in a context at once, including any nested templates.

```zig
try ctx.expand();
```

## Evaluate Dynamic Templates

Following example shows how to conditionally evaluate a dynamic template token. You can also pass runtime generated content.

```zig
const tokens = try ctx.extract();
defer ctx.destruct(tokens);

try ctx.inject(ctx.get(tokens, 0).?, 1, null);
try ctx.inject(ctx.get(tokens, 1).?, 1, null);

try ctx.inject(ctx.get(tokens, 2).?, 0, "{d: 23}");
```

## Replacing Token String

```zig
try ctx.replace("Old value", "New Value");
```

## Extract Output

Following example shows how to extract evaluated template content both from context and storage. You can read from cache once you read the content at least once, and you should use common identifier for lazy evaluation when evaluating same page template across multiple functions or modules.

```zig
std.debug.print("{?s}\n\n\n", .{ctx.readFromCache()});
std.debug.print("{?s}\n\n\n", .{try ctx.read()});
std.debug.print("{?s}\n\n\n", .{ctx.readFromCache()});
```
