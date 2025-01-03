# How to use

First import Jsonic on your zig file.

```zig
const jsonic = @import("jsonic");
```

## Static JSON

```zig
var gpa_mem = std.heap.GeneralPurposeAllocator(.{}){};
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();

const static_input = "{ \"name\": \"John Doe\", \"age\": 40 }";
const User = struct { name: []const u8, age: u8 };

const data = try jsonic.StaticJson.parse(User, heap, static_input);
std.debug.print(
    "Static Data [ name: {s}, age: {d} ]\n", .{data.name, data.age}
);
```

## Dynamic JSON

### Array

```zig
var gpa_mem = std.heap.GeneralPurposeAllocator(.{}){};
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();

const input = "[\"John Doe\", 40]";

var dyn_json = try jsonic.DynamicJson.init(heap, input, .{});
defer dyn_json.deinit();

const json_data = dyn_json.data().array;
const item = json_data.items[0].string;
std.debug.print("Array Item: {s}\n", .{item});
```

### Object

```zig
var gpa_mem = std.heap.GeneralPurposeAllocator(.{}){};
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();

const input =
\\ {
\\      "name": "Jane Doe",
\\      "age": 30,
\\      "hobby": ["reading", "fishing"],
\\      "score": {
\\          "fear": 75,
\\          "joy": 60
\\      }
\\ }
;

var dyn_json = try jsonic.DynamicJson.init(heap, input, .{});
defer dyn_json.deinit();

const json_data = dyn_json.data().object;
const joy = json_data.get("score").?.object.get("joy").?.integer;
std.debug.print("Joy: {d}\n", .{joy});

const hobby = json_data.get("hobby").?.array.items[1].string;
std.debug.print("Hobby: {s}\n", .{hobby});
```