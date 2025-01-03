# How to Install

## Installation

Navigate to your project directory. e.g., `cd my_awesome_project`

### Install the Nightly Version

Fetch jsonic as zig package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-bolt/jsonic/archive/refs/heads/main.zip
```

### Install a Release Version

Fetch jsonic as zig package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-bolt/jsonic/archive/refs/tags/"your-version".zip
```

Add jsonic as dependency to your project by coping following code on your project.

```zig title="build.zig"
const jsonic = b.dependency("jsonic", .{});
exe.root_module.addImport("jsonic", jsonic.module("jsonic"));
lib.root_module.addImport("jsonic", jsonic.module("jsonic"));
```
