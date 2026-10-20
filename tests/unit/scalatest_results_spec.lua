local nio = require("nio")
local adapter = require("neotest-scala")({ framework = "scalatest" })

local SPEC_SOURCE = [[
package com.example

class FirstSpec extends AnyFunSpec {
  describe("Default scheme") {
    it("default deliverable") {}
    it("default deliverable swap: EUR/USD-20240920-20240921 (NDS)") {}
  }
  describe("Configuration validation") {
    it("falls back to defaults when a forward template is missing a required token") {}
    it("parses a swap symbol whose date format contains the template separator '-'") {}
    it("uses 100%") {}
    it("is ignored") {}
  }
}

class SecondSpec extends AnyFunSpec {
  it("default deliverable") {}
}
]]

local FIRST = "com.example.FirstSpec."
local SECOND = "com.example.SecondSpec."

local function write_temp(content, suffix)
    local path = vim.fn.tempname() .. suffix
    local file = assert(io.open(path, "w"))
    file:write(content)
    file:close()
    return path
end

---@param output_lines string[]
---@return table<string, string> position id -> status
local function run_results(output_lines)
    local spec_path = write_temp(SPEC_SOURCE, "Spec.scala")
    local output_path = write_temp(table.concat(output_lines, "\n"), ".log")
    local tree = adapter.discover_positions(spec_path)
    local results = adapter.results(nil, { output = output_path, code = 1 }, tree)
    local statuses = {}
    for id, result in pairs(results) do
        statuses[id] = result.status
    end
    return statuses
end

describe("scalatest results", function()
    nio.tests.it("ignores test stdout interleaved before an sbt 1.x reporter line", function()
        local statuses = run_results({
            "[info] FirstSpec:",
            "[info] Configuration validation",
            "java.lang.IllegalArgumentException: FX f[info] - falls back to defaults when a forward template is missing a required token",
            "[info] - parses a swap symbol whose date format contains the template separator '-' *** FAILED ***",
            "[info]   Left(...) was not equal to Right(...) (FirstSpec.scala:10)",
        })
        assert.are.same("passed", statuses[FIRST .. "falls back to defaults when a forward template is missing a required token"])
        assert.are.same("failed", statuses[FIRST .. "parses a swap symbol whose date format contains the template separator '-'"])
    end)

    nio.tests.it("parses sbt 2.x output without the [info] prefix", function()
        local statuses = run_results({
            "FirstSpec:",
            "Configuration validation",
            "\tat org.scalatest.to- falls back to defaults when a forward template is missing a required token",
            "- parses a swap symbol whose date format contains the template separator '-' *** FAILED ***",
        })
        assert.are.same("passed", statuses[FIRST .. "falls back to defaults when a forward template is missing a required token"])
        assert.are.same("failed", statuses[FIRST .. "parses a swap symbol whose date format contains the template separator '-'"])
    end)

    nio.tests.it("matches names exactly when they contain Lua pattern characters or share a prefix", function()
        local statuses = run_results({
            "[info] FirstSpec:",
            "[info] - default deliverable",
            "[info] - default deliverable swap: EUR/USD-20240920-20240921 (NDS) *** FAILED ***",
            "[info] - uses 100%",
        })
        assert.are.same("passed", statuses[FIRST .. "default deliverable"])
        assert.are.same("failed", statuses[FIRST .. "default deliverable swap: EUR/USD-20240920-20240921 (NDS)"])
        assert.are.same("passed", statuses[FIRST .. "uses 100%"])
    end)

    nio.tests.it("attributes same-named tests to the suite whose header precedes them", function()
        local statuses = run_results({
            "[info] FirstSpec:",
            "[info] - default deliverable *** FAILED ***",
            "[info] SecondSpec:",
            "[info] - default deliverable",
        })
        assert.are.same("failed", statuses[FIRST .. "default deliverable"])
        assert.are.same("passed", statuses[SECOND .. "default deliverable"])
    end)

    nio.tests.it("reports ignored tests as skipped", function()
        local statuses = run_results({
            "[info] FirstSpec:",
            "[info] - is ignored !!! IGNORED !!!",
        })
        assert.are.same("skipped", statuses[FIRST .. "is ignored"])
    end)

    nio.tests.it("leaves tests absent from the output without a result", function()
        local statuses = run_results({
            "[info] FirstSpec:",
            "[info] - default deliverable",
        })
        assert.is_nil(statuses[FIRST .. "is ignored"])
    end)
end)
