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

--- Normalize a solution folder name by stripping surrounding slashes.
--- e.g. "/src/" -> "src", "/Tests/" -> "Tests"
---@param raw string
---@return string
local function normalize_folder_name(raw)
  return (raw:match("^/?(.-)/?$")) or raw
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

--- Recursively convert an XML element and its children into a solution node.
---@param elem table XML element
---@return table node  { folders, projects, files }
local function elem_to_node(elem)
  local node = { folders = {}, projects = {}, files = {} }

  for _, child in ipairs(elem.children or {}) do
    if child.name == "Folder" then
      local raw_name = child.attrs.Name or ""
      local name = normalize_folder_name(raw_name)
      local sub = elem_to_node(child)
      node.folders[#node.folders + 1] = {
        name = name,
        raw_name = raw_name,
        folders = sub.folders,
        projects = sub.projects,
        files = sub.files,
      }
    elseif child.name == "Project" then
      local path = child.attrs.Path or ""
      node.projects[#node.projects + 1] = {
        path = path,
        dir = project_dir(path),
        name = project_name(path),
        startup = child.attrs.DefaultStartup == "true",
      }
    elseif child.name == "File" then
      local path = child.attrs.Path or ""
      node.files[#node.files + 1] = {
        path = path,
        name = path:match("([^/]+)$") or path,
      }
    end
  end

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
