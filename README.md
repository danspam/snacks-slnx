# snacks-slnx

A Neovim plugin that integrates Visual Studio `.slnx` solution files with [snacks.nvim](https://github.com/folke/snacks.nvim)'s file explorer. When you open a directory containing a `.slnx` file, the explorer tree is reorganised to reflect the logical solution hierarchy — solution folders, projects, and solution items — rather than the raw filesystem layout.

## What it does

A `.slnx` file describes how a .NET solution is organised: projects are grouped into named solution folders, and arbitrary files (`.editorconfig`, `Directory.Build.props`, etc.) can be listed as solution items. On disk these are just files scattered across subdirectories; in Visual Studio they appear in a tidy logical tree.

This plugin brings that same logical view to snacks.explorer:

```
 solution root/
 ├──  Solution Items/        ← virtual solution folder
 │   ├──  .editorconfig
 │   └──  Directory.Build.props
 ├──  src/                   ← virtual solution folder
 │   ├──  Application/       ← real project directory (expandable)
 │   └──  Domain/            ← real project directory (expandable)
 └──  docker-compose.dcproj
```

**Virtual solution folders** (shown with a folder icon) exist only in the `.slnx` file — they have no counterpart on disk. They are always expanded and pressing `<CR>` on them is a no-op.

**Project directories** are real filesystem paths. They behave exactly like normal explorer directories: press `<CR>` to expand or collapse them, and their contents (source files, sub-directories) are rendered using snacks' standard tree logic including git status and diagnostic annotations.

When the user types a search query the plugin hands off to snacks' normal `fd`-based fuzzy finder so search works across the whole project as usual.

## Requirements

- Neovim 0.10+
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) with the `picker` / `explorer` modules enabled

## Installation

### lazy.nvim (recommended)

Declare snacks-slnx as its own plugin spec and list it as a dependency of snacks.nvim. Use `opts` as a **function** so that `require("snacks-slnx.finder")` is evaluated lazily — after lazy.nvim has added all plugin directories to the runtimepath — rather than at parse time:

```lua
-- 1. Declare the plugin
{
  dir = "path/to/snacks-slnx", -- or a GitHub spec once published
  name = "snacks-slnx",
},

-- 2. Wire it into snacks using an opts function
{
  "folke/snacks.nvim",
  dependencies = { "snacks-slnx" },
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

> **Why a function?** An `opts = { ... }` table is a plain Lua table literal that is evaluated immediately when the config file is parsed, before lazy.nvim has added any plugin paths to `runtimepath`. Wrapping `opts` as a function defers execution until lazy.nvim is ready to set up the plugin, at which point all dependencies are already on the path.

### Auto-patch via `setup()`

Alternatively, call `setup()` and the plugin will patch snacks automatically after `VimEnter`:

```lua
-- somewhere in your config, after snacks.nvim is declared
require("snacks-slnx").setup()
```

`setup()` is safe to call multiple times and is idempotent.

## Configuration

`setup()` accepts an optional options table:

```lua
require("snacks-slnx").setup({
  -- Automatically patch Snacks.picker.sources.explorer on startup.
  -- Set to false if you prefer to wire the finder manually (see above).
  auto_detect = true,

  -- Show non-project files listed under <File Path="..."> elements in the
  -- solution. These appear as leaf nodes under their solution folder.
  show_solution_files = true,
})
```

When using the direct-finder approach the `show_solution_files` option is read from the snacks source `config` function. Set it inside the `opts` function alongside the finder:

```lua
opts = function(_, opts)
  opts.picker = opts.picker or {}
  opts.picker.sources = opts.picker.sources or {}
  opts.picker.sources.explorer = vim.tbl_extend(
    "force",
    opts.picker.sources.explorer or {},
    {
      finder = require("snacks-slnx.finder").slnx_finder,
      config = function(source_opts)
        require("snacks.picker.source.explorer").setup(source_opts)
        source_opts.show_solution_files = false -- hide <File> entries
      end,
    }
  )
  return opts
end,
```

## How it works

### `.slnx` parsing

`lua/snacks-slnx/parser.lua` implements a tokenizer and recursive descent parser for the `.slnx` XML format. No external XML library is required. It handles:

- XML declarations and comments
- Self-closing and open/close element pairs
- Arbitrarily nested `<Folder>` elements
- `<Project Path="..." DefaultStartup="true" />` entries
- `<File Path="..." />` solution item entries

### Explorer integration

`lua/snacks-slnx/finder.lua` provides a snacks-compatible finder function. When the explorer opens in a directory that contains a `.slnx` file the finder:

1. Parses the solution file.
2. Emits a root item for the working directory.
3. Walks the parsed solution tree depth-first, emitting virtual `dir` items for solution folders and real `dir` items for project directories.
4. For any project directory that the user has expanded (tracked by snacks' internal `Tree` module), recursively emits its contents using `Tree:get()` so git status, diagnostics, and hidden-file filtering all work normally.
5. Maintains `item.parent`, `item.sort`, and `item.last` fields so snacks' tree formatter draws the correct branch characters (`├─`, `└─`, `│`).

When no `.slnx` file is present the function delegates to the standard `snacks.picker.source.explorer` finder unchanged, so the plugin has zero impact on non-.NET projects.

## Running the tests

The test suite uses a self-contained runner and has no dependencies beyond Neovim itself:

```sh
nvim --headless -u tests/minimal_init.lua -c "luafile tests/runner.lua"
```

If you have [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) installed you can also use its busted runner:

```sh
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/spec {minimal_init = 'tests/minimal_init.lua'}"
```

The suite covers 43 cases across two spec files:

| File | What is tested |
|---|---|
| `tests/spec/parser_spec.lua` | XML tokenisation, attribute parsing, folder nesting, error handling, all fixture files |
| `tests/spec/finder_spec.lua` | `.slnx` detection, item structure, parent chains, `last` tracking, sort ordering, Tree module integration, fixture-level item counts |

## Project layout

```
lua/
  snacks-slnx/
    init.lua      Entry point: setup(), auto-patch logic, confirm-action override
    parser.lua    .slnx XML parser
    finder.lua    snacks.picker finder + find_slnx helper
tests/
  fixtures/
    simple.slnx          Two solution folders, root-level project
    nested.slnx          Deeply nested folders
    root_projects.slnx   Projects with no containing folder
    empty.slnx           Empty solution
  spec/
    parser_spec.lua
    finder_spec.lua
  minimal_init.lua   Neovim init used by the test runner
  runner.lua         Standalone busted-compatible test runner
```
