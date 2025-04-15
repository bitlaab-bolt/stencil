# Developer Guide

If you are using previous release of Stencil for some reason, you can generate documentation for that release by following these steps:

- Install [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/getting-started/) on your platform.

- Download and extract `Source code (zip)` for your target release at [**Stencil Repo**](https://github.com/bitlaab-bolt/stencil)

- Now, `cd` into your release directory and run: `mkdocs serve`

## Generate Code Documentation

To generate Zig's API documentation, navigate to your project directory and run:

```sh
zig build-lib -femit-docs=docs/zig-docs src/root.zig
```

Now, clean up any unwanted generated file and make sure to link `zig-docs/index.html` to your `reference.md` file.

**Remarks:** Make sure all source code file end with an `\n`. Otherwise doc generator will silently pass but the final webpage will throw an ambagious syntax error on console.