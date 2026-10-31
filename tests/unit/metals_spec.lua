local nio = require("nio")
local adapter = require("neotest-scala")({ framework = "scalatest" })
local metals = require("neotest-scala.metals")

local SPEC_SOURCE = [[
package com.example

class FirstSpec extends AnyFunSpec {
  describe("Main.msg") {
    it("returns a greeting") {}
    it("is not empty") {}
  }
}

class SecondSpec extends AnyFunSpec {
  it("returns a greeting") {}
}
]]

local FIRST = "com.example.FirstSpec"
local SECOND = "com.example.SecondSpec"
local TARGET_URI = "file:/project/#root/Test"

local function test_case(name, line)
    return { name = name, location = { range = { start = { line = line, character = 4 } } } }
end

-- Test Explorer state as built by nvim-metals; Metals names FunSpec tests with their describe text.
local STATE = {
    ["root-test"] = {
        uri = TARGET_URI,
        suites = {
            [FIRST] = {
                testCases = {
                    test_case("Main.msg returns a greeting", 4),
                    test_case("Main.msg is not empty", 5),
                },
            },
            [SECOND] = { testCases = { test_case("returns a greeting", 10) } },
        },
    },
}

local function discover()
    local path = vim.fn.tempname() .. "Spec.scala"
    local file = assert(io.open(path, "w"))
    file:write(SPEC_SOURCE)
    file:close()
    return adapter.discover_positions(path)
end

describe("metals runner", function()
    nio.tests.it("requests a single test by the name Metals discovered on its line", function()
        local tree = discover()
        local request = metals.build_request(tree:get_key(FIRST .. ".is not empty"), STATE)
        assert.are.same({
            target = { uri = TARGET_URI },
            requestData = {
                suites = { { className = FIRST, tests = { "Main.msg is not empty" } } },
                jvmOptions = {},
                environmentVariables = {},
            },
        }, request)
    end)

    nio.tests.it("runs a file's suites on the JVM target of a cross-built project", function()
        local tree = discover()
        local suite = { testCases = {} }
        local state = {
            ["domainjs-test"] = { uri = "file:/p/#domainJS/Test", suites = { [FIRST] = suite, [SECOND] = suite } },
            ["domainjvm-test"] = { uri = "file:/p/#domainJVM/Test", suites = { [FIRST] = suite, [SECOND] = suite } },
        }
        local request = metals.build_request(tree, state)
        assert.are.same({ uri = "file:/p/#domainJVM/Test" }, request.target)
        assert.are.same(
            { { className = FIRST, tests = {} }, { className = SECOND, tests = {} } },
            request.requestData.suites
        )
    end)

    nio.tests.it("maps testResult events to positions of their suite", function()
        local tree = discover()
        local results = metals.to_results(tree, STATE, {
            {
                suiteName = FIRST,
                tests = {
                    { kind = "passed", testName = "Main.msg returns a greeting" },
                    { kind = "failed", testName = FIRST .. ".Main.msg is not empty", error = "was empty" },
                },
            },
            { suiteName = SECOND, tests = { { kind = "ignored", testName = "returns a greeting" } } },
        })
        assert.are.same("passed", results[FIRST .. ".returns a greeting"].status)
        assert.are.same("failed", results[FIRST .. ".is not empty"].status)
        assert.are.same({ { message = "was empty", line = 5 } }, results[FIRST .. ".is not empty"].errors)
        assert.are.same("skipped", results[SECOND .. ".returns a greeting"].status)
    end)
end)
