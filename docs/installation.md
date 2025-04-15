# How to Install

Navigate to your project directory. e.g., `cd my_awesome_project`

### Install the Nightly Version

Fetch **stencil** as external package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-bolt/stencil/archive/refs/heads/main.zip
```

### Install a Release Version

Fetch **stencil** as external package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-bolt/stencil/archive/refs/tags/v0.0.0.zip
```

Make sure to edit `v0.0.0` with the latest release version.

## Import Module

Now, import **stencil** as external package module to your project by coping following code:

```zig title="build.zig"
const stencil = b.dependency("stencil", .{});
exe.root_module.addImport("stencil", stencil.module("stencil"));
lib.root_module.addImport("stencil", stencil.module("stencil"));
```
