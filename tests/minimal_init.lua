--- Minimal Neovim init for running the snacks-slnx test suite.
---
--- Usage (standalone runner, no plenary required):
---   nvim --headless -u tests/minimal_init.lua -c "luafile tests/runner.lua"
---
--- Usage (with plenary, if installed):
---   nvim --headless -u tests/minimal_init.lua \
---     -c "PlenaryBustedDirectory tests/spec {minimal_init = 'tests/minimal_init.lua'}"

local this_file = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(this_file, ":h:h")

-- Plugin's own lua/ directory
vim.opt.runtimepath:prepend(repo_root)

-- ── snacks.nvim ───────────────────────────────────────────────────────────────
-- Add snacks from the lazy data directory if installed; this lets the
-- integration path in finder.lua resolve, while unit-test stubs still win
-- for the specific modules we stub in package.loaded.
local snacks_path = vim.fn.stdpath("data") .. "/lazy/snacks.nvim"
if vim.fn.isdirectory(snacks_path) == 1 then
  vim.opt.runtimepath:prepend(snacks_path)
end

-- ── plenary.nvim (optional) ───────────────────────────────────────────────────
local plenary_paths = {
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim",
  repo_root .. "/../plenary.nvim",
}
for _, p in ipairs(plenary_paths) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
    break
  end
end

-- ── Stubs for snacks modules used by finder.lua ───────────────────────────────
-- These are registered in package.loaded BEFORE any spec file is loaded.
-- Individual spec files may replace them with more detailed stubs.

if not package.loaded["snacks.picker.source.explorer"] then
  package.loaded["snacks.picker.source.explorer"] = {
    explorer = function(_opts, _ctx)
      return function(_cb) end
    end,
    search = function(_opts, _ctx)
      return function(_cb) end
    end,
    setup = function(_opts) end,
    get_state = function(_picker)
      return {
        setup = function(_self, _ctx)
          return false -- not searching
        end,
        on_find = nil,
      }
    end,
  }
end

if not package.loaded["snacks.explorer.actions"] then
  package.loaded["snacks.explorer.actions"] = {
    actions = {
      confirm = function(_picker, _item) end,
    },
  }
end

-- snacks.explorer.tree is stubbed per-test in finder_spec.lua
-- so we only install a basic fallback here.
if not package.loaded["snacks.explorer.tree"] then
  package.loaded["snacks.explorer.tree"] = {
    node = function(_self, _path) return nil end,
    get = function(_self, _root, _cb, _opts) end,
  }
end
