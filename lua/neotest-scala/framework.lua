local utils = require("neotest-scala.utils")

local M = {}

TEST_PASSED = "passed" -- the test passed
TEST_FAILED = "failed" -- the test failed
TEST_SKIPPED = "skipped" -- the test was ignored, canceled or pending

---@class neotest-scala.Framework
---@field build_command fun(runner: string, project: string, tree: neotest.Tree, name: string, extra_args: table|string): string[]
---@field get_test_results fun(output_lines: string[], tree: neotest.Tree): table<string, string> position id -> status

--- Strip ainsi characters from the string, leaving the rest of the string intact.
---@param s string
---@return string
local function strip_ainsi_chars(s)
    local v = s:gsub("\x1b%[%d+;%d+;%d+;%d+;%d+m", "")
        :gsub("\x1b%[%d+;%d+;%d+;%d+m", "")
        :gsub("\x1b%[%d+;%d+;%d+m", "")
        :gsub("\x1b%[%d+;%d+m", "")
        :gsub("\x1b%[%d+m", "")
    return v
end

---@param project string
---@param runner string
---@param test_path string|nil
---@param extra_args table|string
---@return string[]
local function build_command_with_test_path(project, runner, test_path, extra_args)
    if runner == "bloop" then
        local full_test_path
        if not test_path then
            full_test_path = {}
        else
            full_test_path = { "--", test_path }
        end
        return vim.tbl_flatten({ "bloop", "test", extra_args, project, full_test_path })
    end
    if not test_path then
        return vim.tbl_flatten({ "sbt", extra_args, project .. "/test" })
    end
    -- TODO: Run sbt with colors, but figuoure wich ainsi sequence need to be matched.
    return vim.tbl_flatten({
        "sbt",
        "--no-colors",
        extra_args,
        project .. "/testOnly -- " .. '"' .. test_path .. '"',
    })
end

---@return neotest-scala.Framework
local function utest_framework()
    -- Builds a test path from the current position in the tree.
    ---@param tree neotest.Tree
    ---@param name string
    ---@return string|nil
    local function build_test_path(tree, name)
        local parent_tree = tree:parent()
        local type = tree:data().type
        if parent_tree and parent_tree:data().type == "namespace" then
            local package = utils.get_package_name(parent_tree:data().path)
            local parent_name = parent_tree:data().name
            return package .. parent_name .. "." .. name
        end
        if parent_tree and parent_tree:data().type == "test" then
            local parent_pos = parent_tree:data()
            return build_test_path(parent_tree, utils.get_position_name(parent_pos)) .. "." .. name
        end
        if type == "namespace" then
            local package = utils.get_package_name(tree:data().path)
            if not package then
                return nil
            end
            return package .. name
        end
        if type == "file" then
            local test_suites = {}
            for _, child in tree:iter_nodes() do
                if child:data().type == "namespace" then
                    table.insert(test_suites, child:data().name)
                end
            end
            if test_suites then
                local package = utils.get_package_name(tree:data().path)
                return package .. "{" .. table.concat(test_suites, ",") .. "}"
            end
        end
        if type == "dir" then
            local packages = {}
            local visited = {}
            for _, child in tree:iter_nodes() do
                if child:data().type == "namespace" then
                    local package = utils.get_package_name(child:data().path)
                    if package and not visited[package] then
                        table.insert(packages, package:sub(1, -2))
                        visited[package] = true
                    end
                end
            end
            if packages then
                return "{" .. table.concat(packages, ",") .. "}"
            end
        end
        return nil
    end

    --- Builds a command for running tests for the framework.
    ---@param runner string
    ---@param project string
    ---@param tree neotest.Tree
    ---@param name string
    ---@param extra_args table|string
    ---@return string[]
    local function build_command(runner, project, tree, name, extra_args)
        local test_path = build_test_path(tree, name)
        return build_command_with_test_path(project, runner, test_path, extra_args)
    end

    ---Get test ID from the test line output.
    ---@param output string
    ---@return string
    local function get_test_id(output)
        local words = vim.split(output, " ", { trimempty = true })
        -- Strip the test success indicator prefix and time taken in ms suffix.
        table.remove(words, 1)
        table.remove(words)
        return table.concat(words, " ")
    end

    -- Get test results from the test output.
    ---@param output_lines string[]
    ---@return table<string, string>
    local function get_test_results(output_lines)
        local test_results = {}
        for _, line in ipairs(output_lines) do
            line = strip_ainsi_chars(line)
            if vim.startswith(line, "+") then
                local test_id = get_test_id(line)
                test_results[test_id] = TEST_PASSED
            elseif vim.startswith(line, "X") then
                local test_id = get_test_id(line)
                test_results[test_id] = TEST_FAILED
            end
        end
        return test_results
    end

    return {
        get_test_results = get_test_results,
        build_command = build_command,
    }
end

---@return neotest-scala.Framework
local function munit_framework()
    -- Builds a test path from the current position in the tree.
    ---@param tree neotest.Tree
    ---@param name string
    ---@return string|nil
    local function build_test_path(tree, name)
        local parent_tree = tree:parent()
        local type = tree:data().type
        if parent_tree and parent_tree:data().type == "namespace" then
            local package = utils.get_package_name(parent_tree:data().path)
            local parent_name = parent_tree:data().name
            return package .. parent_name .. "." .. name
        end
        if parent_tree and parent_tree:data().type == "test" then
            local parent_pos = parent_tree:data()
            return build_test_path(parent_tree, utils.get_position_name(parent_pos)) .. "." .. name
        end
        if type == "namespace" then
            local package = utils.get_package_name(tree:data().path)
            if not package then
                return nil
            end
            return package .. name .. ".*"
        end
        if type == "file" then
            local test_suites = {}
            for _, child in tree:iter_nodes() do
                if child:data().type == "namespace" then
                    table.insert(test_suites, child:data().name)
                end
            end
            if test_suites then
                local package = utils.get_package_name(tree:data().path)
                return package .. "*"
            end
        end
        if type == "dir" then
            return "*"
        end
        return nil
    end

    --- Builds a command for running tests for the framework.
    ---@param runner string
    ---@param project string
    ---@param tree neotest.Tree
    ---@param name string
    ---@param extra_args table|string
    ---@return string[]
    local function build_command(runner, project, tree, name, extra_args)
        local test_path = build_test_path(tree, name)
        return build_command_with_test_path(project, runner, test_path, extra_args)
    end

    ---Get test ID from the test line output.
    ---@param output string
    ---@return string
    local function get_test_name(output, prefix)
        return output:match("^" .. prefix .. " (.*) %d*%.?%d+s.*") or nil
    end

    ---Get test namespace from the test line output.
    ---@param output string
    ---@return string|nil
    local function get_test_namespace(output)
        return output:match("^([%w%.]+):") or nil
    end

    -- Get test results from the test output.
    ---@param output_lines string[]
    ---@return table<string, string>
    local function get_test_results(output_lines)
        local test_results = {}
        local test_namespace = nil
        for _, line in ipairs(output_lines) do
            line = vim.trim(strip_ainsi_chars(line))
            local current_namespace = get_test_namespace(line)
            if current_namespace and (not test_namespace or test_namespace ~= current_namespace) then
                test_namespace = current_namespace
            end
            if test_namespace and vim.startswith(line, "+") then
                local test_name = get_test_name(line, "+")
                if test_name then
                    local test_id = test_namespace .. "." .. vim.trim(test_name)
                    test_results[test_id] = TEST_PASSED
                end
            elseif test_namespace and vim.startswith(line, "==> X") then
                local test_name = get_test_name(line, "==> X")
                if test_name then
                    test_results[vim.trim(test_name)] = TEST_FAILED
                end
            end
        end
        return test_results
    end

    return {
        get_test_results = get_test_results,
        build_command = build_command,
    }
end

---@return neotest-scala.Framework
local function scalatest_framework()
    -- Builds a test path from the current position in the tree.
    ---@param tree neotest.Tree
    ---@return string|nil
    local function build_test_namespace(tree, name)
        local parent_tree = tree:parent()
        local type = tree:data().type
        if parent_tree and parent_tree:data().type == "namespace" then
            local package = utils.get_package_name(parent_tree:data().path)
            local parent_name = parent_tree:data().name
            return package .. parent_name
        end
        if parent_tree and parent_tree:data().type == "test" then
            return nil
        end
        if type == "namespace" then
            local package = utils.get_package_name(tree:data().path)
            if not package then
                return nil
            end
            return package .. name
        end
        if type == "file" then
            local test_suites = {}
            for _, child in tree:iter_nodes() do
                if child:data().type == "namespace" then
                    table.insert(test_suites, child:data().name)
                end
            end
            if test_suites then
                local package = utils.get_package_name(tree:data().path)
                return package .. "*"
            end
        end
        if type == "dir" then
            return "*"
        end
        return nil
    end

    --- Builds a command for running tests for the framework.
    ---@param runner string
    ---@param project string
    ---@param tree neotest.Tree
    ---@param name string
    ---@param extra_args table|string
    ---@return string[]
    local function build_command(runner, project, tree, name, extra_args)
        local test_namespace = build_test_namespace(tree, name)
        if runner == "bloop" then
            local full_test_path
            if not test_namespace then
                full_test_path = {}
            elseif tree:data().type ~= "test" then
                full_test_path = { "-o", test_namespace }
            else
                full_test_path = { "-o", test_namespace, "--", "-z", name }
            end
            return vim.tbl_flatten({ "bloop", "test", extra_args, project, full_test_path })
        end
        if not test_namespace then
            return vim.tbl_flatten({ "sbt", extra_args, project .. "/test" })
        end
        -- TODO: Run sbt with colors, but figuoure wich ainsi sequence need to be matched.
        local test_path = ""
        if tree:data().type == "test" then
            test_path = ' -- -z "' .. name .. '"'
        end
        return vim.tbl_flatten({
            "sbt",
            "--no-colors",
            extra_args,
            project .. "/testOnly " .. test_namespace .. test_path,
        })
    end

    -- Reporter line suffixes, checked in order. Lines without one are passed tests.
    local status_suffixes = {
        { " *** FAILED ***", TEST_FAILED },
        { " !!! IGNORED !!!", TEST_SKIPPED },
        { " !!! CANCELED !!!", TEST_SKIPPED },
        { " (pending)", TEST_SKIPPED },
    }
    local status_priority = { [TEST_SKIPPED] = 1, [TEST_PASSED] = 2, [TEST_FAILED] = 3 }

    ---@param line string
    ---@return string body, string status
    local function split_status(line)
        for _, suffix in ipairs(status_suffixes) do
            if vim.endswith(line, suffix[1]) then
                return line:sub(1, -#suffix[1] - 1), suffix[2]
            end
        end
        return line, TEST_PASSED
    end

    ---Finds the longest candidate for which `line` ends with `prefix .. candidate .. suffix`.
    ---@param line string
    ---@param candidates string[]
    ---@param prefix string
    ---@param suffix string
    ---@return string|nil
    local function longest_suffix_match(line, candidates, prefix, suffix)
        local best = nil
        for _, candidate in ipairs(candidates) do
            if vim.endswith(line, prefix .. candidate .. suffix) and (not best or #candidate > #best) then
                best = candidate
            end
        end
        return best
    end

    ---Groups the tests in the tree by the simple name of their enclosing suite.
    ---@param tree neotest.Tree
    ---@return table<string, table<string, string>> suite name -> test name -> position id
    local function collect_suites(tree)
        local suites = {}
        for _, node in tree:iter_nodes() do
            local position = node:data()
            if position.type == "test" then
                local parent = node:parent()
                while parent and parent:data().type ~= "namespace" do
                    parent = parent:parent()
                end
                if parent then
                    local suite = parent:data().name
                    suites[suite] = suites[suite] or {}
                    suites[suite][utils.get_position_name(position)] = position.id
                end
            end
        end
        return suites
    end

    -- Get test results from the test output.
    --
    -- Reporter lines are matched against the test names known from the tree rather than
    -- parsed on their own. Test stdout is not newline-terminated before the reporter line,
    -- so a line can look like `<stdout>[info] - name`. sbt 2 also drops the `[info]` prefix,
    -- which leaves nothing to separate the stdout from the name.
    ---@param output_lines string[]
    ---@param tree neotest.Tree
    ---@return table<string, string> position id -> status
    local function get_test_results(output_lines, tree)
        local suites = collect_suites(tree)
        local suite_names = vim.tbl_keys(suites)
        local test_results = {}
        local current_suite = #suite_names == 1 and suite_names[1] or nil
        for _, line in ipairs(output_lines) do
            line = strip_ainsi_chars(line):gsub("%s+$", "")
            local suite = longest_suffix_match(line, suite_names, "", ":")
            if suite then
                current_suite = suite
            elseif current_suite then
                local tests = suites[current_suite]
                local body, status = split_status(line)
                local clean = body:gsub("^%[info%]", ""):gsub("^%s+", "")
                local name
                if vim.startswith(clean, "- ") then
                    -- An uninterrupted reporter line must match a name exactly, so a filtered
                    -- run cannot credit `- x - name` to a test called `name`.
                    name = tests[clean:sub(3)] and clean:sub(3)
                else
                    name = longest_suffix_match(body, vim.tbl_keys(tests), "- ", "")
                end
                if name then
                    local id = tests[name]
                    local previous = test_results[id]
                    if not previous or status_priority[status] > status_priority[previous] then
                        test_results[id] = status
                    end
                end
            end
        end
        return test_results
    end

    return {
        get_test_results = get_test_results,
        build_command = build_command,
    }
end

---Returns a framework class.
---@param framework string
---@return neotest-scala.Framework|nil
function M.get_framework_class(framework)
    if framework == "utest" then
        return utest_framework()
    elseif framework == "munit" then
        return munit_framework()
    elseif framework == "scalatest" then
        return scalatest_framework()
    end
end

return M
