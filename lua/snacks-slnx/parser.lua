--- .slnx XML parser
--- Parses Visual Studio XML solution files into a structured Lua table.
local M = {}

--- Tokenize XML content into a flat list of tokens.
--- Handles: XML declarations, comments, self-closing tags, open/close tags.
---@param content string
---@return table tokens
local function tokenize(content)
  local tokens = {}
  local pos = 1
  local len = #content

  while pos <= len do
    -- Skip whitespace
    local _, ws_end = content:find("^%s+", pos)
    if ws_end then
      pos = ws_end + 1
    end
    if pos > len then
      break
    end

    if content:sub(pos, pos) ~= "<" then
      -- Text node: skip to next tag
      local next_lt = content:find("<", pos)
      pos = next_lt or (len + 1)
    elseif content:sub(pos, pos + 4) == "<?xml" then
      -- XML processing instruction
      local e = content:find("?>", pos)
      pos = (e or pos) + 2
    elseif content:sub(pos, pos + 3) == "<!--" then
      -- XML comment
      local e = content:find("-->", pos)
      pos = (e or pos) + 3
    elseif content:sub(pos, pos + 1) == "</" then
      -- Closing tag: </TagName>
      local e = content:find(">", pos)
      if not e then
        break
      end
      local name = content:sub(pos + 2, e - 1):match("^%s*([%w_%-]+)")
      tokens[#tokens + 1] = { type = "close", name = name }
      pos = e + 1
    else
      -- Opening or self-closing tag: <TagName attr="val" /> or <TagName attr="val">
      local e = content:find(">", pos)
      if not e then
        break
      end
      local body = content:sub(pos + 1, e - 1)
      local self_close = body:sub(-1) == "/"
      if self_close then
        body = body:sub(1, -2)
      end

      local name = body:match("^([%w_%-]+)")
      if not name then
        pos = e + 1
      else
        local attrs = {}
        -- Parse key="value" attributes (handles both single and double quotes)
        for k, v in body:gmatch('%s+([%w_%-]+)%s*=%s*"([^"]*)"') do
          attrs[k] = v
        end
        for k, v in body:gmatch("%s+([%w_%-]+)%s*=%s*'([^']*)'") do
          if not attrs[k] then
            attrs[k] = v
          end
        end

        tokens[#tokens + 1] = {
          type = self_close and "self_close" or "open",
          name = name,
          attrs = attrs,
        }
        pos = e + 1
      end
    end
  end

  return tokens
end

--- Parse a list of tokens starting at index idx as an element.
--- Returns the element table and the next index to process.
---@param tokens table
---@param idx integer
---@return table|nil element, integer next_idx
local function parse_element(tokens, idx)
  local tok = tokens[idx]
  if not tok then
    return nil, idx + 1
  end

  local elem = { name = tok.name, attrs = tok.attrs or {}, children = {} }

  if tok.type == "self_close" then
    return elem, idx + 1
  end

  -- tok.type == "open": consume children until matching close tag
  idx = idx + 1
  while idx <= #tokens do
    local t = tokens[idx]
    if t.type == "close" then
      return elem, idx + 1
    elseif t.type == "self_close" or t.type == "open" then
      local child, next_idx = parse_element(tokens, idx)
      if child then
        elem.children[#elem.children + 1] = child
      end
      idx = next_idx
    else
      idx = idx + 1
    end
  end

  return elem, idx
end

--- Find the root <Solution> element in the token stream and parse it.
---@param tokens table
---@return table|nil element, string|nil err
local function find_and_parse_solution(tokens)
  for i, tok in ipairs(tokens) do
    if tok.name == "Solution" and (tok.type == "open" or tok.type == "self_close") then
      return parse_element(tokens, i)
    end
  end
  return nil, "No <Solution> element found"
end

--- Derive the directory containing a project file path.
--- e.g. "src/App/App.csproj" -> "src/App"
---     "App.csproj"           -> "."
---@param project_path string
---@return string
local function project_dir(project_path)
  local dir = project_path:match("^(.+)/[^/]+$")
  return dir or "."
end

--- Derive a display name from a project file path.
--- e.g. "src/App/App.csproj" -> "App"
---     "App.csproj"           -> "App"
---@param project_path string
---@return string
local function project_name(project_path)
  local filename = project_path:match("([^/]+)$") or project_path
  return filename:match("^(.+)%.[^.]+$") or filename
end

--- Turn a raw folder Name attribute into a canonical path with leading and
--- trailing slashes: "/src/app/" → "/src/app/"  "Tests" → "/Tests/"
---@param raw string
---@return string
local function canonical_path(raw)
  local p = raw
  if p:sub(1, 1) ~= "/" then p = "/" .. p end
  if p:sub(-1) ~= "/" then p = p .. "/" end
  return p
end

--- Return the last path segment of a canonical folder path (the display name).
--- "/src/app/" → "app",  "/solution files/" → "solution files"
---@param path string canonical path
---@return string
local function last_segment(path)
  -- strip trailing slash, then take everything after the last remaining slash
  local inner = path:sub(1, -2) -- drop trailing "/"
  return inner:match("([^/]+)$") or inner
end

--- Return the parent canonical path, or nil if already at root depth.
--- "/src/app/" → "/src/"
--- "/src/"     → nil
---@param path string canonical path
---@return string|nil
local function parent_path(path)
  -- drop trailing slash, find the last slash
  local inner = path:sub(1, -2)
  local parent = inner:match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    return nil
  end
  return parent .. "/"
end

--- Build a project entry from an XML element's attrs.
---@param xml_elem table
---@return table
local function make_project(xml_elem)
  local path = xml_elem.attrs.Path or ""
  return {
    path = path,
    dir = project_dir(path),
    name = project_name(path),
    startup = xml_elem.attrs.DefaultStartup == "true",
  }
end

--- Build a file entry from an XML element's attrs.
---@param xml_elem table
---@return table
local function make_file(xml_elem)
  local path = xml_elem.attrs.Path or ""
  return { path = path, name = path:match("([^/]+)$") or path }
end

--- Build a tree of folder nodes from a flat list of <Folder> XML elements.
---
--- Real .slnx files use *flat-path siblings* to express nesting:
---   <Folder Name="/src/" />
---   <Folder Name="/src/app/">...</Folder>    ← sibling, not XML child
--- The hierarchy is reconstructed here by treating folder Name values as paths.
---
--- Our test fixtures use *XML nesting*:
---   <Folder Name="/Infrastructure/">
---     <Folder Name="/Data/">...</Folder>     ← actual XML child
---   </Folder>
--- Those XML-child folders are detected in the third pass below and appended
--- to their parent's .folders list, so both encodings work correctly.
---
---@param folder_elems table  list of XML Folder element nodes (siblings)
---@return table root_folders
local function build_folder_tree(folder_elems)
  local ordered = {} ---@type table[]  preserves XML declaration order
  local by_path = {} ---@type table<string, table>

  -- ── Pass 1: create an entry for every folder element ─────────────────────
  for _, xml in ipairs(folder_elems) do
    local raw = xml.attrs.Name or ""
    local cpath = canonical_path(raw)
    local entry = {
      name     = last_segment(cpath),
      raw_name = raw,
      _path    = cpath,
      _xml     = xml,
      folders  = {},
      projects = {},
      files    = {},
    }
    ordered[#ordered + 1] = entry
    -- Later entries with the same path silently overwrite (shouldn't happen in
    -- valid files, but avoids a crash if it does).
    by_path[cpath] = entry
  end

  -- ── Pass 2: attach entries to their path-implied parent ───────────────────
  local root_folders = {}
  for _, entry in ipairs(ordered) do
    local pp = parent_path(entry._path)
    local parent = pp and by_path[pp]
    if parent then
      parent.folders[#parent.folders + 1] = entry
    else
      root_folders[#root_folders + 1] = entry
    end
  end

  -- ── Pass 3: populate projects / files from each XML element's children ────
  -- Also handle XML-nested <Folder> elements (the alternative encoding style).
  for _, entry in ipairs(ordered) do
    for _, child in ipairs(entry._xml.children or {}) do
      if child.name == "Project" then
        entry.projects[#entry.projects + 1] = make_project(child)
      elseif child.name == "File" then
        entry.files[#entry.files + 1] = make_file(child)
      elseif child.name == "Folder" then
        -- XML-nested folder (not seen in flat-path files, but supported).
        -- Recursively build its subtree and attach it.
        local sub = build_folder_tree({ child })
        for _, s in ipairs(sub) do
          entry.folders[#entry.folders + 1] = s
        end
      end
    end
  end

  return root_folders
end

--- Convert the parsed <Solution> XML element into the solution table.
---@param elem table XML element
---@return table  { folders, projects, files }
local function elem_to_node(elem)
  local node = { folders = {}, projects = {}, files = {} }
  local folder_elems = {}

  for _, child in ipairs(elem.children or {}) do
    if child.name == "Folder" then
      folder_elems[#folder_elems + 1] = child
    elseif child.name == "Project" then
      node.projects[#node.projects + 1] = make_project(child)
    elseif child.name == "File" then
      node.files[#node.files + 1] = make_file(child)
    end
    -- Ignore <Configurations>, <Properties>, <BuildType>, and other elements.
  end

  node.folders = build_folder_tree(folder_elems)
  return node
end

--- Parse a .slnx file from disk.
---@param filepath string Absolute path to the .slnx file
---@return table|nil solution, string|nil err
function M.parse(filepath)
  local f = io.open(filepath, "r")
  if not f then
    return nil, "Cannot open file: " .. filepath
  end
  local content = f:read("*all")
  f:close()
  return M.parse_string(content)
end

--- Parse a .slnx XML string.
--- Returns a solution table:
---   {
---     folders  = { { name, folders, projects, files }, ... },
---     projects = { { path, dir, name, startup }, ... },
---     files    = { { path, name }, ... },
---   }
---@param content string Raw XML content
---@return table|nil solution, string|nil err
function M.parse_string(content)
  if type(content) ~= "string" or content == "" then
    return nil, "Empty or invalid content"
  end

  local tokens = tokenize(content)
  local solution_elem, err = find_and_parse_solution(tokens)
  if not solution_elem then
    return nil, err or "Parse error"
  end

  return elem_to_node(solution_elem)
end

return M
