--- snacks-slnx: Visual Studio .slnx solution file integration for snacks.explorer
---
--- Usage (in your snacks.nvim opts):
---
---   require("snacks-slnx").setup()
---
--- Or, for explicit control over snacks picker configuration:
---
---   {
---     "folke/snacks.nvim",
---     opts = {
---       picker = {
---         sources = {
---           explorer = {
---             finder = require("snacks-slnx.finder").slnx_finder,
---           },
---         },
---       },
---     },
---   }
local M = {}

---@class snacks_slnx.Config
---@field auto_detect boolean Patch snacks.explorer automatically on startup (default: true)
---@field show_solution_files boolean Show non-project files listed in .slnx (default: true)

---@type snacks_slnx.Config
local defaults = {
  auto_detect = true,
  show_solution_files = true,
}

--- Patch Snacks.picker.sources.explorer to use the slnx-aware finder.
--- Safe to call multiple times (idempotent).
local function patch_snacks()
  -- Guard: snacks must be loadable.
  local ok_snacks = pcall(require, "snacks.picker")
  if not ok_snacks then
    return false
  end

  -- The global `Snacks` table is created by snacks when it loads.
  ---@diagnostic disable-next-line: undefined-global
  if not (Snacks and Snacks.picker and Snacks.picker.sources) then
    return false
  end

  local finder = require("snacks-slnx.finder")

  ---@diagnostic disable-next-line: undefined-global
  local sources = Snacks.picker.sources
  local existing = sources.explorer or {}

  -- Only patch if not already patched.
  if existing.finder == finder.slnx_finder then
    return true
  end

  sources.explorer = vim.tbl_extend("force", existing, {
    finder = finder.slnx_finder,
    -- Keep the standard explorer config function so that confirm actions,
    -- filter transforms and formatters are still configured correctly.
    config = function(opts)
      local ok, explorer_mod = pcall(require, "snacks.picker.source.explorer")
      if ok then
        explorer_mod.setup(opts)
      end
      -- Pass our show_solution_files option into opts so the finder can read it.
      opts.show_solution_files = (M._config or defaults).show_solution_files
    end,
    -- Override confirm so pressing <CR> on a virtual solution folder is a no-op
    -- rather than trying to call Tree:toggle() on a non-existent path.
    actions = {
      confirm = function(picker, item)
        if item and item._slnx_virtual then
          -- Virtual solution folder: nothing to open.
          return
        end
        -- Fall through to the standard explorer confirm action.
        local ok, actions = pcall(require, "snacks.explorer.actions")
        if ok then
          actions.actions.confirm(picker, item)
        end
      end,
    },
  })

  return true
end

--- Set up the plugin.
---@param opts? snacks_slnx.Config
function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", defaults, opts or {})

  if not M._config.auto_detect then
    return
  end

  -- If snacks is already loaded, patch immediately.
  if patch_snacks() then
    return
  end

  -- Otherwise defer until after all plugins are loaded.
  local group = vim.api.nvim_create_augroup("SnacksSlnx", { clear = true })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    callback = function()
      vim.schedule(patch_snacks)
    end,
  })

  -- Re-check whenever the working directory changes (e.g. opening a new project).
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      vim.schedule(patch_snacks)
    end,
  })
end

--- Expose sub-modules for direct use in snacks configuration.
M.finder = require("snacks-slnx.finder")
M.parser = require("snacks-slnx.parser")

return M
