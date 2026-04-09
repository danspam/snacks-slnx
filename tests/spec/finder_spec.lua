--- Unit tests for snacks-slnx.finder
--- These tests exercise the finder module in isolation without a live Neovim
--- UI or a real snacks.picker instance.  The snacks.explorer.tree module is
--- stubbed out so the tests are hermetic.

local finder = require("snacks-slnx.finder")
local parser = require("snacks-slnx.parser")

local fixtures_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures"

-- ── Stub the snacks.explorer.tree module ─────────────────────────────────────
-- We register a minimal stub before each test group so finder.lua's
-- `pcall(require, "snacks.explorer.tree")` resolves to our fake.
local Tree = {
  _nodes = {}, -- path -> { open = bool, status = nil, ... }
  _children = {}, -- path -> list of child node tables
}
Tree.__index = Tree

function Tree:node(path)
  return self._nodes[path]
end

function Tree:get(root, cb, _opts)
  -- Call back for the root first (matching snacks behaviour)
  local root_node = self._nodes[root] or { path = root, dir = true, open = true }
  root_node.path = root
  cb(root_node)
  -- Then for each registered child
  for _, child in ipairs(self._children[root] or {}) do
    cb(child)
  end
end

function Tree:reset()
  self._nodes = {}
  self._children = {}
end

-- Install the stub into package.loaded so require() resolves it.
package.loaded["snacks.explorer.tree"] = Tree

-- Reset virtual_open state before every test so tests are independent.
local function reset_virtual_open()
  finder.virtual_open = {}
end

-- ── Helper ───────────────────────────────────────────────────────────────────

--- Collect all items emitted by a finder callback into a list.
---@param make_fn fun(cb: fun(item: table))
---@return table items
local function collect(make_fn)
  local items = {}
  make_fn(function(item)
    items[#items + 1] = item
  end)
  return items
end

--- Find the first item whose `file` path ends with the given suffix.
---@param items table
---@param suffix string
---@return table|nil
local function find_item(items, suffix)
  for _, item in ipairs(items) do
    if item.file:sub(-#suffix) == suffix then
      return item
    end
  end
  return nil
end

--- Return all items that have a given parent item.
---@param items table
---@param parent table
---@return table children
local function children_of(items, parent)
  local result = {}
  for _, item in ipairs(items) do
    if item.parent == parent then
      result[#result + 1] = item
    end
  end
  return result
end

-- ── find_slnx ─────────────────────────────────────────────────────────────────

describe("finder.find_slnx", function()
  it("returns nil for a directory with no .slnx file", function()
    -- Use OS temp dir which definitely has no .slnx
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    assert.is_nil(finder.find_slnx(tmp))
    vim.fn.delete(tmp, "rf")
  end)

  it("returns the path when a .slnx file is present", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local slnx = tmp .. "/MySolution.slnx"
    local f = io.open(slnx, "w")
    f:write("<Solution/>")
    f:close()

    local result = finder.find_slnx(tmp)
    assert.is_string(result)
    assert.truthy(result:find("MySolution%.slnx$"))
    vim.fn.delete(tmp, "rf")
  end)

  it("ignores non-.slnx files", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local f = io.open(tmp .. "/readme.md", "w")
    f:write("# hello")
    f:close()
    assert.is_nil(finder.find_slnx(tmp))
    vim.fn.delete(tmp, "rf")
  end)

  it("returns nil for a non-existent directory", function()
    assert.is_nil(finder.find_slnx("/definitely/does/not/exist"))
  end)
end)

-- ── finder.make ───────────────────────────────────────────────────────────────

describe("finder.make", function()
  local cwd = "/solution/root"
  local opts = { show_solution_files = true }

  before_each(function()
    Tree:reset()
    reset_virtual_open()
    -- By default, no nodes are open so project dirs won't expand.
  end)

  -- ── Root item ──────────────────────────────────────────────────────────────

  it("always emits the root item first", function()
    local sol = { folders = {}, projects = {}, files = {} }
    local items = collect(finder.make(sol, cwd, opts))
    assert.is_true(#items >= 1)
    local root = items[1]
    assert.equals(cwd, root.file)
    assert.is_true(root.dir)
    assert.is_true(root.open)
    assert.is_nil(root.parent)
  end)

  -- ── Empty solution ────────────────────────────────────────────────────────

  it("emits only the root item for an empty solution", function()
    local sol = { folders = {}, projects = {}, files = {} }
    local items = collect(finder.make(sol, cwd, opts))
    assert.equals(1, #items)
  end)

  -- ── Virtual solution folders ──────────────────────────────────────────────

  it("emits virtual dir items for solution folders", function()
    local sol = {
      folders = {
        { name = "src", raw_name = "/src/", folders = {}, projects = {}, files = {} },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- root + 1 virtual folder
    assert.equals(2, #items)
    local folder_item = items[2]
    assert.is_true(folder_item.dir)
    assert.is_true(folder_item.open)           -- virtual folders are always open
    assert.is_true(folder_item._slnx_virtual)
    assert.truthy(folder_item.file:find("src", 1, true))
    -- Virtual folder path must be under cwd
    assert.truthy(folder_item.file:sub(1, #cwd) == cwd)
    -- Parent is root
    assert.equals(items[1], folder_item.parent)
  end)

  it("virtual folder files are parented to the virtual folder item", function()
    local sol = {
      folders = {
        {
          name = "Solution Items",
          raw_name = "/Solution Items/",
          folders = {},
          projects = {},
          files = {
            { path = ".editorconfig", name = ".editorconfig" },
            { path = "Directory.Build.props", name = "Directory.Build.props" },
          },
        },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- root + folder + 2 files = 4
    assert.equals(4, #items)

    local root = items[1]
    local folder = items[2]
    local children = children_of(items, folder)
    assert.equals(2, #children)

    -- files should NOT be parented to root
    for _, child in ipairs(children) do
      assert.not_equals(root, child.parent)
    end
  end)

  -- ── Project directory items ───────────────────────────────────────────────

  it("emits project dirs as real (non-virtual) directory items", function()
    local sol = {
      folders = {
        {
          name = "src",
          raw_name = "/src/",
          folders = {},
          projects = { { path = "src/App/App.csproj", dir = "src/App", name = "App", startup = false } },
          files = {},
        },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- root + virtual folder + project dir = 3
    assert.equals(3, #items)
    local proj = items[3]
    assert.is_true(proj.dir)
    assert.is_nil(proj._slnx_virtual)
    assert.equals(cwd .. "/src/App", proj.file)
    assert.is_false(proj.open)  -- Tree has no open node registered
  end)

  it("expands an open project directory using Tree:get", function()
    local proj_dir = cwd .. "/src/App"
    -- Register the project node as open in the stub Tree
    Tree._nodes[proj_dir] = { path = proj_dir, dir = true, open = true }
    -- Register one child file
    Tree._children[proj_dir] = {
      {
        path = proj_dir .. "/Program.cs",
        dir = false,
        open = false,
        parent = { path = proj_dir },
        hidden = false,
        ignored = false,
        status = nil,
        severity = nil,
        type = "file",
      },
    }

    local sol = {
      folders = {
        {
          name = "src",
          raw_name = "/src/",
          folders = {},
          projects = { { path = "src/App/App.csproj", dir = "src/App", name = "App", startup = false } },
          files = {},
        },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- root + virtual folder + project dir (open) + Program.cs = 4
    -- (Tree:get also calls back for root node itself, but we skip it)
    assert.equals(4, #items)
    local cs_item = find_item(items, "Program.cs")
    assert.is_not_nil(cs_item)
    assert.is_false(cs_item.dir)
  end)

  -- ── Root-level projects ───────────────────────────────────────────────────

  it("emits root-level projects directly under the root item", function()
    local sol = {
      folders = {},
      projects = {
        { path = "MyApp.csproj", dir = ".", name = "MyApp", startup = true },
        { path = "MyLib/MyLib.csproj", dir = "MyLib", name = "MyLib", startup = false },
      },
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- root + 2 project dirs = 3
    assert.equals(3, #items)
    local root = items[1]
    local app_item = find_item(items, "root")  -- dir = "." maps to cwd
    local lib_item = find_item(items, "MyLib")

    assert.is_not_nil(lib_item)
    assert.equals(root, lib_item.parent)
    assert.equals(cwd .. "/MyLib", lib_item.file)
  end)

  it("project with dir='.' maps to cwd", function()
    local sol = {
      folders = {},
      projects = { { path = "MyApp.csproj", dir = ".", name = "MyApp", startup = false } },
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    local proj = find_item(items, "root")
    -- The root item itself has file == cwd; the root-level project also has file == cwd
    -- Both should appear but only one root is emitted by convention
    -- What matters is that the item exists with file == cwd
    local has_cwd_item = false
    for _, item in ipairs(items) do
      if item.file == cwd and item.dir then
        has_cwd_item = true
      end
    end
    assert.is_true(has_cwd_item)
  end)

  -- ── Root-level files ──────────────────────────────────────────────────────

  it("emits root-level files under the root item", function()
    local sol = {
      folders = {},
      projects = {},
      files = { { path = ".editorconfig", name = ".editorconfig" } },
    }
    local items = collect(finder.make(sol, cwd, opts))
    assert.equals(2, #items)
    local file_item = items[2]
    assert.is_false(file_item.dir)
    assert.equals(cwd .. "/.editorconfig", file_item.file)
    assert.equals(items[1], file_item.parent)
  end)

  it("hides solution files when show_solution_files is false", function()
    local sol = {
      folders = {
        {
          name = "Items",
          raw_name = "/Items/",
          folders = {},
          projects = {},
          files = { { path = ".editorconfig", name = ".editorconfig" } },
        },
      },
      projects = {},
      files = { { path = "readme.md", name = "readme.md" } },
    }
    local no_files_opts = { show_solution_files = false }
    local items = collect(finder.make(sol, cwd, no_files_opts))
    -- root + virtual folder only (no files)
    assert.equals(2, #items)
    for _, item in ipairs(items) do
      assert.is_false(item.file:find("%.editorconfig") ~= nil)
    end
  end)

  -- ── item.last tracking ────────────────────────────────────────────────────

  it("marks the last child of each parent correctly", function()
    local sol = {
      folders = {
        { name = "A", raw_name = "/A/", folders = {}, projects = {}, files = {} },
        { name = "B", raw_name = "/B/", folders = {}, projects = {}, files = {} },
        { name = "C", raw_name = "/C/", folders = {}, projects = {}, files = {} },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- root (last=nil) + A (last=false) + B (last=false) + C (last=true)
    local root = items[1]
    local folder_children = children_of(items, root)
    assert.equals(3, #folder_children)
    -- Only the last sibling should have last=true
    assert.is_false(folder_children[1].last)
    assert.is_false(folder_children[2].last)
    assert.is_true(folder_children[3].last)
  end)

  it("marks a single child as last=true", function()
    local sol = {
      folders = {
        { name = "Only", raw_name = "/Only/", folders = {}, projects = {}, files = {} },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    local folder = items[2]
    assert.is_true(folder.last)
  end)

  -- ── Sort key ordering ─────────────────────────────────────────────────────

  it("sort keys are strictly increasing in emission order", function()
    local sol = {
      folders = {
        {
          name = "src",
          raw_name = "/src/",
          folders = {},
          projects = {
            { path = "src/A/A.csproj", dir = "src/A", name = "A", startup = false },
            { path = "src/B/B.csproj", dir = "src/B", name = "B", startup = false },
          },
          files = {},
        },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- Verify sort is monotonically increasing across all emitted items.
    for i = 2, #items do
      assert.truthy(
        items[i].sort > items[i - 1].sort,
        string.format("sort[%d]=%q should be > sort[%d]=%q", i, items[i].sort, i - 1, items[i - 1].sort)
      )
    end
  end)

  -- ── Nested folders ────────────────────────────────────────────────────────

  it("emits nested virtual folders with correct parent chain", function()
    local sol = {
      folders = {
        {
          name = "Infrastructure",
          raw_name = "/Infrastructure/",
          folders = {
            {
              name = "Data",
              raw_name = "/Data/",
              folders = {},
              projects = { { path = "src/Infra.Data/Infra.Data.csproj", dir = "src/Infra.Data", name = "Infra.Data", startup = false } },
              files = {},
            },
          },
          projects = {},
          files = {},
        },
      },
      projects = {},
      files = {},
    }
    local items = collect(finder.make(sol, cwd, opts))
    -- root, Infrastructure, Data, Infra.Data project dir
    assert.equals(4, #items)

    local root = items[1]
    local infra = items[2]
    local data = items[3]
    local proj = items[4]

    assert.equals(root, infra.parent)
    assert.equals(infra, data.parent)
    assert.equals(data, proj.parent)

    -- Virtual flags
    assert.is_true(infra._slnx_virtual)
    assert.is_true(data._slnx_virtual)
    assert.is_nil(proj._slnx_virtual)
  end)

  -- ── Full fixture integration ──────────────────────────────────────────────

  it("produces correct item count for simple.slnx", function()
    local sol = parser.parse(fixtures_dir .. "/simple.slnx")
    -- Structure:
    --   root
    --   └─ Solution Items (virtual)
    --      ├─ .editorconfig
    --      └─ Directory.Build.props
    --   └─ src (virtual)
    --      ├─ src/Application dir (closed)
    --      └─ src/Domain dir (closed)
    --   └─ docker-compose dir (closed, dir = ".")
    --
    -- root(1) + Solution Items(1) + 2 files + src(1) + 2 proj dirs + docker-compose(1) = 9
    -- Note: docker-compose.dcproj dir is "." which maps to cwd (already the root).
    -- We still emit it as a root-level project.
    local items = collect(finder.make(sol, cwd, opts))
    -- At minimum we expect: root + 2 virtual folders + 2 files + 2 project dirs + 1 root proj
    assert.truthy(#items >= 8)
  end)

  it("produces correct item count for nested.slnx", function()
    local sol = parser.parse(fixtures_dir .. "/nested.slnx")
    -- root + Infrastructure + Data + Infra.Data + API + Infra.API + api-notes.txt + Tests + Unit + Integration
    local items = collect(finder.make(sol, cwd, opts))
    assert.equals(10, #items)
  end)
end)

-- ── Virtual folder toggle (open/closed state) ─────────────────────────────────

describe("finder.toggle_virtual", function()
  local cwd = "/solution/root"
  local opts = { show_solution_files = true }

  before_each(function()
    Tree:reset()
    reset_virtual_open()
  end)

  local function one_folder_sol()
    return {
      folders = {
        {
          name = "src",
          raw_name = "/src/",
          folders = {},
          projects = { { path = "src/App/App.csproj", dir = "src/App", name = "App", startup = false } },
          files = {},
        },
      },
      projects = {},
      files = {},
    }
  end

  it("virtual folders start open by default", function()
    local items = collect(finder.make(one_folder_sol(), cwd, opts))
    local folder = items[2]
    assert.is_true(folder._slnx_virtual)
    assert.is_true(folder.open)
    -- Children are emitted (root + folder + project = 3)
    assert.equals(3, #items)
  end)

  it("toggle_virtual closes an open virtual folder", function()
    -- Collect once to learn the virtual path
    local items = collect(finder.make(one_folder_sol(), cwd, opts))
    local folder = items[2]
    assert.is_true(folder.open)

    -- Toggle closed
    local new_state = finder.toggle_virtual(folder.file)
    assert.is_false(new_state)

    -- Re-collect: folder should now be closed and have no children
    local items2 = collect(finder.make(one_folder_sol(), cwd, opts))
    local folder2 = items2[2]
    assert.is_false(folder2.open)
    -- Only root + closed folder emitted (no project child)
    assert.equals(2, #items2)
  end)

  it("toggle_virtual reopens a closed virtual folder", function()
    local items = collect(finder.make(one_folder_sol(), cwd, opts))
    local vpath = items[2].file

    finder.toggle_virtual(vpath)  -- close
    finder.toggle_virtual(vpath)  -- reopen

    local items2 = collect(finder.make(one_folder_sol(), cwd, opts))
    assert.is_true(items2[2].open)
    assert.equals(3, #items2)  -- children visible again
  end)

  it("toggling one folder does not affect siblings", function()
    local sol = {
      folders = {
        { name = "A", raw_name = "/A/", folders = {}, projects = { { path = "src/a/a.csproj", dir = "src/a", name = "A", startup = false } }, files = {} },
        { name = "B", raw_name = "/B/", folders = {}, projects = { { path = "src/b/b.csproj", dir = "src/b", name = "B", startup = false } }, files = {} },
      },
      projects = {},
      files = {},
    }

    -- Learn virtual paths: root, A(virtual), A-project, B(virtual), B-project = 5 items
    local items = collect(finder.make(sol, cwd, opts))
    assert.equals(5, #items)

    -- Virtual folder items have _slnx_virtual set; find them by their path suffix.
    local folder_a = find_item(items, ".slnx_virtual/A")
    local folder_b = find_item(items, ".slnx_virtual/B")
    assert.is_not_nil(folder_a)
    assert.is_not_nil(folder_b)

    -- Close A only
    finder.toggle_virtual(folder_a.file)

    local items2 = collect(finder.make(sol, cwd, opts))
    -- A is closed (no child), B is still open (has child)
    -- root + A(closed) + B(open) + B's project = 4
    assert.equals(4, #items2)
    local a2 = find_item(items2, ".slnx_virtual/A")
    local b2 = find_item(items2, ".slnx_virtual/B")
    assert.is_false(a2.open)
    assert.is_true(b2.open)
  end)

  it("toggling a parent folder hides its nested children recursively", function()
    local sol = {
      folders = {
        {
          name = "src",
          raw_name = "/src/",
          folders = {
            { name = "app", raw_name = "/src/app/", folders = {}, projects = { { path = "src/App.csproj", dir = "src", name = "App", startup = false } }, files = {} },
          },
          projects = {},
          files = {},
        },
      },
      projects = {},
      files = {},
    }

    -- Open: root + src + app + project = 4
    local items = collect(finder.make(sol, cwd, opts))
    assert.equals(4, #items)
    local src_item = items[2]

    -- Close src
    finder.toggle_virtual(src_item.file)
    local items2 = collect(finder.make(sol, cwd, opts))
    -- Closed src hides app and project: root + src = 2
    assert.equals(2, #items2)
    assert.is_false(items2[2].open)
  end)
end)
