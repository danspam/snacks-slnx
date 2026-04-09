--- Custom snacks.picker finder for .slnx solution files.
--- Replaces the default filesystem-based explorer tree with the logical
--- hierarchy defined in the nearest .slnx solution file.
local M = {}

--- Per-session open/closed state for virtual solution folders.
--- Keys are virtual paths (see virtual_path()); values are booleans.
--- Absent key = default open (true).  Persists across re-finds within a session.
---@type table<string, boolean>
M.virtual_open = {}

--- Toggle the open/closed state of a virtual folder path and return the new state.
---@param vpath string
---@return boolean new_state
function M.toggle_virtual(vpath)
  -- Default is open, so a missing key means "was open, now close"
  local was_open = M.virtual_open[vpath]
  if was_open == nil then was_open = true end
  M.virtual_open[vpath] = not was_open
  return not was_open
end

--- Scan a directory for the first .slnx file (non-recursive).
---@param dir string Absolute directory path
---@return string|nil filepath
function M.find_slnx(dir)
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(dir)
  if not handle then
    return nil
  end
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if ftype == "file" and name:match("%.slnx$") then
      return dir .. "/" .. name
    end
  end
  return nil
end

--- Build a virtual filesystem path for a solution folder so that it is
--- unique but will never collide with a real directory.
---@param cwd string
---@param folder_name string Normalized folder name (no slashes)
---@param parent_virtual_path string|nil Parent's virtual path or nil for root
---@return string
local function virtual_path(cwd, folder_name, parent_virtual_path)
  local safe_name = folder_name:gsub("[^%w%-_.]", "_")
  if parent_virtual_path then
    return parent_virtual_path .. "/" .. safe_name
  end
  return cwd .. "/.slnx_virtual/" .. safe_name
end

--- Resolve the on-disk absolute path for a project relative to the solution root.
---@param cwd string
---@param project_dir string Relative dir ("." means the cwd itself)
---@return string
local function resolve_project_dir(cwd, project_dir)
  if project_dir == "." then
    return cwd
  end
  return cwd .. "/" .. project_dir
end

--- Build the finder function (the inner callback-based iterator).
--- This is the core that emits snacks.picker.explorer.Item records.
---@param solution table Parsed solution from parser.lua
---@param cwd string Absolute path to the solution root directory
---@param opts table snacks.picker.explorer.Config
---@return fun(cb: fun(item: table))
function M.make(solution, cwd, opts)
  local ok_tree, Tree = pcall(require, "snacks.explorer.tree")

  return function(cb)
    -- Track the most-recently-emitted child for each parent so we can
    -- update item.last = false when a sibling follows.
    local last_child = {} ---@type table<table, table>

    ---@param item table snacks.picker.explorer.Item
    local function emit(item)
      local parent = item.parent
      if parent then
        local prev = last_child[parent]
        if prev then
          prev.last = false
        end
        item.last = true
        last_child[parent] = item
      end
      cb(item)
    end

    -- Monotonic counter used to build sort keys that preserve insertion order.
    local seq = 0
    local function next_sort(parent_sort, is_dir)
      seq = seq + 1
      -- Directories sort before files at the same level (matching snacks convention).
      local sep = is_dir and "!" or "#"
      return parent_sort .. sep .. string.format("%08d", seq)
    end

    -- ── Root ────────────────────────────────────────────────────────────────
    local root = {
      file = cwd,
      dir = true,
      open = true,
      text = cwd,
      sort = "",
      internal = true,
    }
    emit(root)

    -- ── Helpers ─────────────────────────────────────────────────────────────

    --- Emit a single file item (non-directory).
    ---@param file_path string Absolute path
    ---@param parent table Parent item
    ---@param sort_key string
    local function emit_file_item(file_path, parent, sort_key)
      local basename = vim.fn.fnamemodify(file_path, ":t")
      local node = ok_tree and Tree:node(file_path) or nil
      emit({
        file = file_path,
        dir = false,
        text = file_path,
        parent = parent,
        sort = sort_key,
        hidden = basename:sub(1, 1) == ".",
        status = node and node.status or nil,
        severity = node and node.severity or nil,
        type = node and node.type or "file",
      })
    end

    --- Emit a directory item (real or virtual) and return it.
    ---@param dir_path string Absolute path (may be virtual/non-existent)
    ---@param parent table Parent item
    ---@param sort_key string
    ---@param is_virtual boolean True for solution folder nodes with no real path
    ---@return table item
    local function emit_dir_item(dir_path, parent, sort_key, is_virtual)
      local basename = vim.fn.fnamemodify(dir_path, ":t")
      local node = ok_tree and not is_virtual and Tree:node(dir_path) or nil
      local open_state
      if is_virtual then
        -- Consult session state; default open when first seen.
        local stored = M.virtual_open[dir_path]
        open_state = (stored == nil) and true or stored
      else
        open_state = node and node.open or false
      end
      local item = {
        file = dir_path,
        dir = true,
        open = open_state,
        text = dir_path,
        parent = parent,
        sort = sort_key,
        hidden = not is_virtual and basename:sub(1, 1) == "." or false,
        status = node and (not node.open or opts.git_status_open) and node.status or nil,
        severity = node and (not node.open or opts.diagnostics_open) and node.severity or nil,
        type = node and node.type or "directory",
        -- Custom flag so the confirm action can treat virtual folders specially.
        _slnx_virtual = is_virtual or nil,
      }
      emit(item)
      return item
    end

    --- Emit all visible descendants of an open project directory.
    --- Uses snacks' Tree module so it respects the user's open/close state
    --- and git/diagnostic annotations.
    ---@param proj_dir string Absolute path to the project directory
    ---@param proj_item table The already-emitted parent item for proj_dir
    local function emit_project_contents(proj_dir, proj_item)
      if not ok_tree then
        return
      end
      -- Map path -> emitted item so we can establish parent chains.
      local emitted = {} ---@type table<string, table>
      emitted[proj_dir] = proj_item

      Tree:get(proj_dir, function(node)
        -- Tree:get calls back for the root node too; skip it.
        if node.path == proj_dir then
          return
        end
        local node_parent_item = (node.parent and emitted[node.parent.path]) or proj_item
        local sk = next_sort(node_parent_item.sort, node.dir)

        local node_item = {
          file = node.path,
          dir = node.dir,
          open = node.open,
          text = node.path,
          parent = node_parent_item,
          sort = sk,
          hidden = node.hidden,
          ignored = node.ignored,
          status = (not node.dir or not node.open or opts.git_status_open) and node.status or nil,
          severity = (not node.dir or not node.open or opts.diagnostics_open) and node.severity or nil,
          type = node.type,
        }
        emit(node_item)
        if node.dir then
          emitted[node.path] = node_item
        end
      end, {
        hidden = opts.hidden,
        ignored = opts.ignored,
        exclude = opts.exclude,
        include = opts.include,
      })
    end

    -- ── Recursive folder emitter ─────────────────────────────────────────────

    ---@param folder table Parsed folder from parser.lua
    ---@param parent table Parent item
    ---@param parent_vpath string|nil Virtual path of the parent folder (nil = root)
    local function emit_folder(folder, parent, parent_vpath)
      local vpath = virtual_path(cwd, folder.name, parent_vpath)
      local sk = next_sort(parent.sort, true)
      local folder_item = emit_dir_item(vpath, parent, sk, true)

      -- Only emit children when the virtual folder is open.
      if not folder_item.open then
        return
      end

      -- Subfolders first (directories sort before files)
      for _, sub in ipairs(folder.folders or {}) do
        emit_folder(sub, folder_item, vpath)
      end

      -- Projects
      for _, project in ipairs(folder.projects or {}) do
        local proj_abs = resolve_project_dir(cwd, project.dir)
        local proj_sort = next_sort(folder_item.sort, true)
        local proj_item = emit_dir_item(proj_abs, folder_item, proj_sort, false)
        if proj_item.open then
          emit_project_contents(proj_abs, proj_item)
        end
      end

      -- Solution item files
      if opts.show_solution_files ~= false then
        for _, file in ipairs(folder.files or {}) do
          local file_abs = cwd .. "/" .. file.path
          local file_sort = next_sort(folder_item.sort, false)
          emit_file_item(file_abs, folder_item, file_sort)
        end
      end
    end

    -- ── Top-level emission ───────────────────────────────────────────────────

    -- Root-level solution folders
    for _, folder in ipairs(solution.folders or {}) do
      emit_folder(folder, root, nil)
    end

    -- Root-level projects (no containing folder)
    for _, project in ipairs(solution.projects or {}) do
      local proj_abs = resolve_project_dir(cwd, project.dir)
      local sk = next_sort(root.sort, true)
      local proj_item = emit_dir_item(proj_abs, root, sk, false)
      if proj_item.open then
        emit_project_contents(proj_abs, proj_item)
      end
    end

    -- Root-level solution files
    if opts.show_solution_files ~= false then
      for _, file in ipairs(solution.files or {}) do
        local file_abs = cwd .. "/" .. file.path
        local sk = next_sort(root.sort, false)
        emit_file_item(file_abs, root, sk)
      end
    end
  end
end

--- snacks.picker finder entry point.
--- Used as the `finder` field in a picker source configuration.
--- Falls back to the default explorer finder when no .slnx file is present,
--- and to the fd-based search finder when the user has typed a search query.
---@param opts table snacks.picker.explorer.Config
---@param ctx table snacks.picker.finder.ctx
---@return fun(cb: fun(item: table))
function M.slnx_finder(opts, ctx)
  local cwd = ctx.filter.cwd
  local slnx_path = M.find_slnx(cwd)

  -- ── No .slnx: delegate entirely to the default explorer ─────────────────
  if not slnx_path then
    return require("snacks.picker.source.explorer").explorer(opts, ctx)
  end

  -- ── Parse the solution file ───────────────────────────────────────────────
  local parser = require("snacks-slnx.parser")
  local solution, err = parser.parse(slnx_path)
  if not solution then
    vim.notify("[snacks-slnx] Failed to parse " .. slnx_path .. ": " .. (err or "unknown error"), vim.log.levels.WARN)
    return require("snacks.picker.source.explorer").explorer(opts, ctx)
  end

  -- ── Set up explorer state (watches, git status, diagnostics, follow_file) ─
  local explorer_mod = require("snacks.picker.source.explorer")
  local state = explorer_mod.get_state(ctx.picker)

  ctx.picker.matcher.opts.keep_parents = false

  -- When the user is actively searching (filter non-empty) use the normal
  -- fd-based search so fuzzy matching works across the whole tree.
  if state:setup(ctx) then
    ctx.picker.matcher.opts.keep_parents = true
    return explorer_mod.search(opts, ctx)
  end

  return M.make(solution, cwd, opts)
end

return M
