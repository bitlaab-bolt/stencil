# How to Install

## Installation

Navigate to your project directory. e.g., `cd my_awesome_project`

### Install the Nightly Version

Fetch stencil as zig package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-bolt/stencil/archive/refs/heads/main.zip
```

### Install a Release Version

Fetch stencil as zig package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-bolt/stencil/archive/refs/tags/"your-version".zip
```

Add stencil as dependency to your project by coping following code on your project.

```zig title="build.zig"
const stencil = b.dependency("stencil", .{});
exe.root_module.addImport("stencil", stencil.module("stencil"));
lib.root_module.addImport("stencil", stencil.module("stencil"));
```
