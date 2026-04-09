--- Unit tests for snacks-slnx.parser
--- Run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec {minimal_init = 'tests/minimal_init.lua'}"
--- or:        busted tests/spec/parser_spec.lua  (requires a luarocks-installed busted + neovim shim)

local parser = require("snacks-slnx.parser")
local fixtures_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures"

describe("parser.parse_string", function()
  -- ── Basic contract ─────────────────────────────────────────────────────────

  it("returns nil and error for empty input", function()
    local sol, err = parser.parse_string("")
    assert.is_nil(sol)
    assert.is_string(err)
  end)

  it("returns nil and error for non-XML input", function()
    local sol, err = parser.parse_string("this is not xml")
    assert.is_nil(sol)
    assert.is_string(err)
  end)

  it("returns nil and error when Solution element is missing", function()
    local sol, err = parser.parse_string("<Root><Child /></Root>")
    assert.is_nil(sol)
    assert.is_string(err)
  end)

  -- ── Empty solution ─────────────────────────────────────────────────────────

  it("parses an empty <Solution>", function()
    local sol, err = parser.parse_string("<Solution></Solution>")
    assert.is_nil(err)
    assert.is_table(sol)
    assert.same({}, sol.folders)
    assert.same({}, sol.projects)
    assert.same({}, sol.files)
  end)

  it("parses a self-closing <Solution />", function()
    local sol, err = parser.parse_string("<Solution />")
    assert.is_nil(err)
    assert.is_table(sol)
    assert.same({}, sol.folders)
  end)

  -- ── XML declaration and comments ──────────────────────────────────────────

  it("ignores XML declarations", function()
    local xml = '<?xml version="1.0" encoding="utf-8"?><Solution></Solution>'
    local sol, err = parser.parse_string(xml)
    assert.is_nil(err)
    assert.is_table(sol)
  end)

  it("ignores XML comments", function()
    local xml = [[
      <?xml version="1.0"?>
      <!-- This is a comment -->
      <Solution>
        <!-- Another comment -->
      </Solution>
    ]]
    local sol, err = parser.parse_string(xml)
    assert.is_nil(err)
    assert.is_table(sol)
    assert.same({}, sol.folders)
  end)

  -- ── Root-level projects ────────────────────────────────────────────────────

  it("parses a root-level self-closing Project element", function()
    local xml = [[
      <Solution>
        <Project Path="MyApp.csproj" />
      </Solution>
    ]]
    local sol, err = parser.parse_string(xml)
    assert.is_nil(err)
    assert.equals(1, #sol.projects)
    local p = sol.projects[1]
    assert.equals("MyApp.csproj", p.path)
    assert.equals(".", p.dir)
    assert.equals("MyApp", p.name)
    assert.is_false(p.startup)
  end)

  it("parses DefaultStartup attribute on Project", function()
    local xml = [[
      <Solution>
        <Project Path="src/App/App.csproj" DefaultStartup="true" />
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.is_true(sol.projects[1].startup)
  end)

  it("derives project dir from nested path", function()
    local xml = [[
      <Solution>
        <Project Path="src/Application/Application.csproj" />
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    local p = sol.projects[1]
    assert.equals("src/Application", p.dir)
    assert.equals("Application", p.name)
  end)

  it("parses multiple root-level projects", function()
    local xml = [[
      <Solution>
        <Project Path="A/A.csproj" />
        <Project Path="B/B.csproj" />
        <Project Path="C/C.csproj" />
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.equals(3, #sol.projects)
    assert.equals("A/A.csproj", sol.projects[1].path)
    assert.equals("B/B.csproj", sol.projects[2].path)
    assert.equals("C/C.csproj", sol.projects[3].path)
  end)

  -- ── Root-level files ───────────────────────────────────────────────────────

  it("parses root-level File elements", function()
    local xml = [[
      <Solution>
        <File Path=".editorconfig" />
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.equals(1, #sol.files)
    assert.equals(".editorconfig", sol.files[1].path)
    assert.equals(".editorconfig", sol.files[1].name)
  end)

  -- ── Solution folders ───────────────────────────────────────────────────────

  it("parses a single Folder with projects", function()
    local xml = [[
      <Solution>
        <Folder Name="/src/">
          <Project Path="src/App/App.csproj" />
        </Folder>
      </Solution>
    ]]
    local sol, err = parser.parse_string(xml)
    assert.is_nil(err)
    assert.equals(1, #sol.folders)
    local f = sol.folders[1]
    assert.equals("src", f.name)
    assert.equals("/src/", f.raw_name)
    assert.equals(1, #f.projects)
    assert.equals("src/App/App.csproj", f.projects[1].path)
  end)

  it("strips leading and trailing slashes from folder names", function()
    local cases = {
      { input = "/Tests/",    expected = "Tests" },
      { input = "Tests",      expected = "Tests" },
      { input = "/Tests",     expected = "Tests" },
      { input = "Tests/",     expected = "Tests" },
      { input = "/My Folder/", expected = "My Folder" },
    }
    for _, c in ipairs(cases) do
      local xml = string.format('<Solution><Folder Name="%s"><Project Path="P.csproj" /></Folder></Solution>', c.input)
      local sol = parser.parse_string(xml)
      assert.equals(c.expected, sol.folders[1].name, "Failed for input: " .. c.input)
    end
  end)

  it("parses Folder with File children", function()
    local xml = [[
      <Solution>
        <Folder Name="/Solution Items/">
          <File Path=".editorconfig" />
          <File Path="Directory.Build.props" />
        </Folder>
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    local f = sol.folders[1]
    assert.equals("Solution Items", f.name)
    assert.equals(2, #f.files)
    assert.equals(".editorconfig", f.files[1].path)
    assert.equals("Directory.Build.props", f.files[2].path)
  end)

  it("parses multiple sibling Folders", function()
    local xml = [[
      <Solution>
        <Folder Name="/A/"><Project Path="A.csproj" /></Folder>
        <Folder Name="/B/"><Project Path="B.csproj" /></Folder>
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.equals(2, #sol.folders)
    assert.equals("A", sol.folders[1].name)
    assert.equals("B", sol.folders[2].name)
  end)

  -- ── Nested folders: XML nesting style (test fixtures) ────────────────────

  it("parses XML-nested Folders (nested inside parent Folder element)", function()
    local xml = [[
      <Solution>
        <Folder Name="/Infrastructure/">
          <Folder Name="/Data/">
            <Project Path="src/Infra.Data/Infra.Data.csproj" />
          </Folder>
          <Folder Name="/API/">
            <Project Path="src/Infra.API/Infra.API.csproj" />
          </Folder>
        </Folder>
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.equals(1, #sol.folders)
    local infra = sol.folders[1]
    assert.equals("Infrastructure", infra.name)
    assert.equals(2, #infra.folders)
    assert.equals("Data", infra.folders[1].name)
    assert.equals("API", infra.folders[2].name)
    assert.equals(1, #infra.folders[1].projects)
    assert.equals("src/Infra.Data/Infra.Data.csproj", infra.folders[1].projects[1].path)
  end)

  -- ── Nested folders: flat-path sibling style (real .slnx files) ───────────

  it("reconstructs hierarchy from flat-path sibling Folder names", function()
    local xml = [[
      <Solution>
        <Folder Name="/src/" />
        <Folder Name="/src/app/">
          <Project Path="src/App/App.csproj" />
        </Folder>
        <Folder Name="/src/lib/">
          <Project Path="src/Lib/Lib.csproj" />
        </Folder>
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    -- /src/ is the only root-level folder; app and lib are its children
    assert.equals(1, #sol.folders)
    local src = sol.folders[1]
    assert.equals("src", src.name)
    assert.equals(2, #src.folders)
    assert.equals("app", src.folders[1].name)
    assert.equals("lib", src.folders[2].name)
    assert.equals(1, #src.folders[1].projects)
    assert.equals("src/App/App.csproj", src.folders[1].projects[1].path)
  end)

  it("handles flat-path folders with files at multiple nesting levels", function()
    local xml = [[
      <Solution>
        <Folder Name="/solution files/">
          <File Path=".editorconfig" />
        </Folder>
        <Folder Name="/solution files/.github/" />
        <Folder Name="/solution files/.github/instructions/">
          <File Path=".github/instructions/csharp.instructions.md" />
        </Folder>
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.equals(1, #sol.folders)
    local sf = sol.folders[1]
    assert.equals("solution files", sf.name)
    assert.equals(1, #sf.files)
    assert.equals(".editorconfig", sf.files[1].path)

    assert.equals(1, #sf.folders)
    local gh = sf.folders[1]
    assert.equals(".github", gh.name)
    assert.equals(0, #gh.files)  -- empty self-closing element

    assert.equals(1, #gh.folders)
    local instr = gh.folders[1]
    assert.equals("instructions", instr.name)
    assert.equals(1, #instr.files)
    assert.equals(".github/instructions/csharp.instructions.md", instr.files[1].path)
  end)

  it("ignores unknown top-level elements (Configurations, Properties, etc.)", function()
    local xml = [[
      <Solution>
        <Configurations>
          <BuildType Name="Debug" />
          <Platform Name="Any CPU" />
        </Configurations>
        <Folder Name="/src/">
          <Project Path="src/App.csproj" />
        </Folder>
        <Properties Name="JSLint">
          <Property Name="foo" Value="bar" />
        </Properties>
      </Solution>
    ]]
    local sol, err = parser.parse_string(xml)
    assert.is_nil(err)
    assert.equals(1, #sol.folders)
    assert.equals("src", sol.folders[1].name)
    assert.equals(0, #sol.projects)
  end)

  it("ignores BuildType children inside Project elements", function()
    local xml = [[
      <Solution>
        <Folder Name="/src/">
          <Project Path="src/App/App.csproj">
            <BuildType Solution="Debug|*" Project="Debug" />
            <BuildType Solution="Release|*" Project="Release" />
          </Project>
        </Folder>
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.equals(1, #sol.folders[1].projects)
    assert.equals("src/App/App.csproj", sol.folders[1].projects[1].path)
  end)

  it("preserves insertion order of folders, projects, and files", function()
    local xml = [[
      <Solution>
        <Folder Name="/Z/"><Project Path="z.csproj" /></Folder>
        <Folder Name="/A/"><Project Path="a.csproj" /></Folder>
        <Folder Name="/M/"><Project Path="m.csproj" /></Folder>
      </Solution>
    ]]
    local sol = parser.parse_string(xml)
    assert.equals("Z", sol.folders[1].name)
    assert.equals("A", sol.folders[2].name)
    assert.equals("M", sol.folders[3].name)
  end)

  -- ── Full fixture files ────────────────────────────────────────────────────

  it("parses simple.slnx fixture", function()
    local sol, err = parser.parse(fixtures_dir .. "/simple.slnx")
    assert.is_nil(err)
    assert.is_table(sol)

    -- Two folders: "Solution Items" and "src"
    assert.equals(2, #sol.folders)
    local items_folder = sol.folders[1]
    local src_folder = sol.folders[2]
    assert.equals("Solution Items", items_folder.name)
    assert.equals("src", src_folder.name)

    -- Solution Items contains two files
    assert.equals(2, #items_folder.files)

    -- src folder contains two projects
    assert.equals(2, #src_folder.projects)
    assert.is_true(src_folder.projects[1].startup)  -- Application has DefaultStartup="true"
    assert.is_false(src_folder.projects[2].startup)

    -- One root-level project (docker-compose)
    assert.equals(1, #sol.projects)
    assert.equals("docker-compose.dcproj", sol.projects[1].path)
  end)

  it("parses nested.slnx fixture", function()
    local sol, err = parser.parse(fixtures_dir .. "/nested.slnx")
    assert.is_nil(err)

    -- Infrastructure -> Data, API (nested)
    -- Tests -> two projects
    assert.equals(2, #sol.folders)
    local infra = sol.folders[1]
    assert.equals("Infrastructure", infra.name)
    assert.equals(2, #infra.folders)

    local data_folder = infra.folders[1]
    assert.equals("Data", data_folder.name)
    assert.equals(1, #data_folder.projects)

    local api_folder = infra.folders[2]
    assert.equals("API", api_folder.name)
    assert.equals(1, #api_folder.projects)
    assert.equals(1, #api_folder.files)
    assert.equals("api-notes.txt", api_folder.files[1].path)

    local tests = sol.folders[2]
    assert.equals("Tests", tests.name)
    assert.equals(2, #tests.projects)
  end)

  it("parses root_projects.slnx fixture", function()
    local sol, err = parser.parse(fixtures_dir .. "/root_projects.slnx")
    assert.is_nil(err)
    assert.equals(0, #sol.folders)
    assert.equals(2, #sol.projects)
    assert.equals("MyApp.csproj", sol.projects[1].path)
    assert.is_true(sol.projects[1].startup)
    assert.equals("MyLib", sol.projects[2].name)
    assert.equals("MyLib", sol.projects[2].dir)
  end)

  it("parses empty.slnx fixture", function()
    local sol, err = parser.parse(fixtures_dir .. "/empty.slnx")
    assert.is_nil(err)
    assert.same({}, sol.folders)
    assert.same({}, sol.projects)
    assert.same({}, sol.files)
  end)

  it("parses flat_path.slnx fixture (real-world flat-path encoding)", function()
    local sol, err = parser.parse(fixtures_dir .. "/flat_path.slnx")
    assert.is_nil(err)

    -- Root folders: solution files, src, tests (3 roots; .github etc. are children)
    assert.equals(3, #sol.folders)
    local sf = sol.folders[1]
    local src = sol.folders[2]
    local tests = sol.folders[3]

    assert.equals("solution files", sf.name)
    assert.equals("src", src.name)
    assert.equals("tests", tests.name)

    -- solution files → .github → instructions
    assert.equals(2, #sf.files)
    assert.equals(1, #sf.folders)
    local gh = sf.folders[1]
    assert.equals(".github", gh.name)
    assert.equals(1, #gh.folders)
    assert.equals("instructions", gh.folders[1].name)
    assert.equals(1, #gh.folders[1].files)

    -- src → app, lib
    assert.equals(2, #src.folders)
    assert.equals("app", src.folders[1].name)
    assert.equals("lib", src.folders[2].name)
    assert.is_true(src.folders[1].projects[1].startup)

    -- tests → 1 project
    assert.equals(1, #tests.projects)
  end)

  -- ── File I/O error handling ───────────────────────────────────────────────

  it("returns nil and error for a nonexistent file path", function()
    local sol, err = parser.parse("/does/not/exist.slnx")
    assert.is_nil(sol)
    assert.is_string(err)
    assert.truthy(err:find("Cannot open"))
  end)
end)
