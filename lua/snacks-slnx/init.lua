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
    -- config() is called by snacks and its RETURN VALUE replaces opts.
    -- We must: (1) call the standard explorer setup to get filter/formatters/confirm,
    -- (2) wrap confirm so virtual folders toggle instead of erroring,
    -- (3) return the fully merged opts table.
    config = function(opts)
      -- Run standard explorer setup. It returns a new merged table; capture it.
      local ok_exp, explorer_mod = pcall(require, "snacks.picker.source.explorer")
      local merged = opts
      if ok_exp then
        merged = explorer_mod.setup(opts) or opts
      end

      -- Wrap the confirm action that setup() installed.
      merged.actions = merged.actions or {}
      local base_confirm = merged.actions.confirm
      merged.actions.confirm = function(picker, item, action)
        -- Identify virtual solution folders by custom flag OR path sentinel.
        -- Display-override project items also have _slnx_virtual=true but carry
        -- _slnx_real_dir pointing to the actual directory on disk.
        local is_virtual = item
          and (item._slnx_virtual
            or (item.dir and item.file and item.file:find("/.slnx_virtual/", 1, true) ~= nil))

        if is_virtual then
          if item._slnx_real_dir then
            -- Display-override project item: toggle the real directory via Tree.
            local ok_tree, Tree = pcall(require, "snacks.explorer.tree")
            if ok_tree then
              Tree:toggle(item._slnx_real_dir)
            end
          else
            -- Pure virtual solution folder: flip our own toggle state.
            require("snacks-slnx.finder").toggle_virtual(item.file)
          end
          local ok_act, actions = pcall(require, "snacks.explorer.actions")
          if ok_act and actions.update then
            actions.update(picker)
          else
            picker:find()
          end
          return
        end

        if base_confirm then
          base_confirm(picker, item, action)
        end
      end

      -- Expose our option so the finder can read it from opts.
      merged.show_solution_files = (M._config or defaults).show_solution_files

      return merged
    end,
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
