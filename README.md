# snacks-slnx

A Neovim plugin that integrates Visual Studio `.slnx` solution files with [snacks.nvim](https://github.com/folke/snacks.nvim)'s file explorer. When you open a directory containing a `.slnx` file, the explorer shows the logical solution hierarchy — solution folders, projects, and solution items — instead of the raw filesystem layout.

```
 solution root/
 ├──  Solution Items/        ← virtual solution folder (collapsed by default)
 │   ├──  .editorconfig
 │   └──  Directory.Build.props
 ├──  src/
 │   ├──  Application/       ← real project directory
 │   └──  Domain/
 └──  docker-compose.dcproj
```

**Virtual solution folders** exist only in the `.slnx` file. They start collapsed; press `<CR>` to expand or collapse them.

**Project directories** are real filesystem paths and behave like normal explorer directories — press `<CR>` to expand, with git status and diagnostic annotations rendered by snacks as usual.

**Projects whose directory name differs from the project name** (e.g. `Foo/Bar.csproj`) are shown by their project name rather than the directory basename.

When a search query is active the plugin delegates to snacks' normal `fd`-based fuzzy finder, so search works across the whole project as usual. In directories without a `.slnx` file the plugin is a no-op.

## Requirements

- Neovim 0.10+
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) with the `picker` / `explorer` modules enabled

## Installation

### lazy.nvim — auto-patch (recommended)

Add the plugin and call `setup()`. The plugin patches snacks automatically after `VimEnter`.

```lua
{ "danspam/snacks-slnx" },

{
  "folke/snacks.nvim",
  dependencies = { "danspam/snacks-slnx" },
  config = function(_, opts)
    require("snacks-slnx").setup()
    require("snacks").setup(opts)
  end,
},
```

### lazy.nvim — manual wiring

Use `opts` as a **function** so that `require` is evaluated after lazy.nvim has set up the runtimepath:

```lua
{ "danspam/snacks-slnx" },

{
  "folke/snacks.nvim",
  dependencies = { "danspam/snacks-slnx" },
  opts = function(_, opts)
    opts.picker = opts.picker or {}
    opts.picker.sources = opts.picker.sources or {}
    opts.picker.sources.explorer = vim.tbl_extend(
      "force",
      opts.picker.sources.explorer or {},
      { finder = require("snacks-slnx.finder").slnx_finder }
    )
    return opts
  end,
},
```

> **Note:** `opts = { finder = require(...) }` (a plain table) will fail because it is evaluated before lazy.nvim adds plugin paths to `runtimepath`. Always use the function form.

## Configuration

```lua
require("snacks-slnx").setup({
  -- Automatically patch snacks.explorer on startup (default: true).
  -- Set to false to wire the finder manually as shown above.
  auto_detect = true,

  -- Show <File Path="..."> solution items as leaf nodes (default: true).
  show_solution_files = true,
})
```

## Running the tests

```sh
nvim --headless -u tests/minimal_init.lua -c "lua require('tests.runner')"
```

The suite has no dependencies beyond Neovim itself and covers 60 cases across parser and finder spec files.
