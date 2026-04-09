--- Minimal busted-compatible test runner for environments without plenary.nvim.
--- Provides: describe, it, before_each, after_each, assert extensions.
--- Usage:
---   nvim --headless -u tests/minimal_init.lua -c "luafile tests/runner.lua" -c "qa!"

local M = {}

-- ── State ────────────────────────────────────────────────────────────────────

local results = { passed = 0, failed = 0, errors = 0 }
local current_before_each = nil
local indent = 0

local function log(msg)
  io.write(msg .. "\n")
  io.flush()
end

local function pass(name)
  results.passed = results.passed + 1
  log(string.rep("  ", indent) .. "  \27[32m✓\27[0m " .. name)
end

local function fail(name, err)
  results.failed = results.failed + 1
  log(string.rep("  ", indent) .. "  \27[31m✗\27[0m " .. name)
  log(string.rep("  ", indent) .. "    " .. tostring(err):gsub("\n", "\n" .. string.rep("  ", indent) .. "    "))
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.describe(name, fn)
  log(string.rep("  ", indent) .. name)
  local prev_before = current_before_each
  current_before_each = nil
  indent = indent + 1
  fn()
  indent = indent - 1
  current_before_each = prev_before
end

function M.it(name, fn)
  local ok, err = pcall(function()
    if current_before_each then
      current_before_each()
    end
    fn()
  end)
  if ok then
    pass(name)
  else
    fail(name, err)
  end
end

function M.before_each(fn)
  current_before_each = fn
end

function M.after_each(_fn)
  -- not implemented (no cleanup needed for these tests)
end

-- ── assert extensions ─────────────────────────────────────────────────────────

local function assertion_error(msg)
  error(msg, 3)
end

-- Augment the global assert with busted-compatible methods.
local assert_mt = {}
assert_mt.__index = assert_mt

function assert_mt.is_true(v, msg)
  if v ~= true then
    assertion_error((msg or "Expected true, got: ") .. tostring(v))
  end
end

function assert_mt.is_false(v, msg)
  if v ~= false then
    assertion_error((msg or "Expected false, got: ") .. tostring(v))
  end
end

function assert_mt.is_nil(v, msg)
  if v ~= nil then
    assertion_error((msg or "Expected nil, got: ") .. tostring(v))
  end
end

function assert_mt.is_not_nil(v, msg)
  if v == nil then
    assertion_error(msg or "Expected non-nil value")
  end
end

function assert_mt.is_string(v, msg)
  if type(v) ~= "string" then
    assertion_error((msg or "Expected string, got: ") .. type(v))
  end
end

function assert_mt.is_table(v, msg)
  if type(v) ~= "table" then
    assertion_error((msg or "Expected table, got: ") .. type(v))
  end
end

function assert_mt.equals(expected, actual, msg)
  if expected ~= actual then
    assertion_error(
      (msg or "") .. string.format("\nExpected: %s\nActual:   %s", vim.inspect(expected), vim.inspect(actual))
    )
  end
end

function assert_mt.not_equals(unexpected, actual, msg)
  if unexpected == actual then
    assertion_error((msg or "") .. string.format("\nDid not expect: %s", vim.inspect(unexpected)))
  end
end

function assert_mt.same(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    assertion_error(
      (msg or "") .. string.format("\nExpected: %s\nActual:   %s", vim.inspect(expected), vim.inspect(actual))
    )
  end
end

function assert_mt.truthy(v, msg)
  if not v then
    assertion_error((msg or "Expected truthy value, got: ") .. tostring(v))
  end
end

function assert_mt.falsy(v, msg)
  if v then
    assertion_error((msg or "Expected falsy value, got: ") .. tostring(v))
  end
end

-- Install as globals, mimicking busted's API.
_G.describe = M.describe
_G.it = M.it
_G.before_each = M.before_each
_G.after_each = M.after_each

-- Replace global assert with our extended version.
local original_assert = assert
_G.assert = setmetatable({}, {
  __index = assert_mt,
  __call = function(_, v, msg)
    return original_assert(v, msg)
  end,
})

-- ── Run all spec files ────────────────────────────────────────────────────────

local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/spec"
local spec_files = vim.fn.glob(spec_dir .. "/**/*_spec.lua", false, true)
table.sort(spec_files)

log("\n\27[1mRunning tests...\27[0m\n")

for _, spec_file in ipairs(spec_files) do
  log("\27[2m--- " .. vim.fn.fnamemodify(spec_file, ":~:.") .. " ---\27[0m")
  local ok, err = pcall(dofile, spec_file)
  if not ok then
    results.errors = results.errors + 1
    log("\27[31mError loading spec: " .. tostring(err) .. "\27[0m")
  end
  log("")
end

-- ── Summary ──────────────────────────────────────────────────────────────────

log(string.format(
  "\27[1mResults: \27[32m%d passed\27[0m, \27[31m%d failed\27[0m, \27[33m%d errors\27[0m",
  results.passed,
  results.failed,
  results.errors
))

-- Exit with a non-zero code if anything failed.
if results.failed > 0 or results.errors > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end

return M
