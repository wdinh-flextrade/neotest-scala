local nio = require("nio")
local lib = require("neotest.lib")
local FanoutAccum = require("neotest.types").FanoutAccum
local utils = require("neotest-scala.utils")

-- Runs tests through Metals: `debug-adapter-start` opens a DAP session (run with `noDebug`) on the
-- build server, which reports a `testResult` event per test.
local M = {}

---Test suites Metals discovered, as kept by nvim-metals' Test Explorer integration.
---@return table<string, { uri: string, suites: table<string, table> }> build target name -> state
function M.explorer_state()
    local ok, test_explorer = pcall(require, "metals.test_explorer")
    return ok and test_explorer.state or {}
end

---@return table|nil suite, string|nil target_uri
local function find_suite(state, class_name)
    for _, target in pairs(state) do
        local suite = target.suites and target.suites[class_name]
        if suite then
            return suite, target.uri
        end
    end
end

---@param tree neotest.Tree
---@return neotest.Tree|nil
local function enclosing_namespace(tree)
    local node = tree
    while node and node:data().type ~= "namespace" do
        node = node:parent()
    end
    return node
end

---@param namespace neotest.Position
---@return string
local function class_name(namespace)
    return (utils.get_package_name(namespace.path) or "") .. namespace.name
end

---Metals names tests by their full path (e.g. `describe` + `it` text in a FunSpec), which the
---treesitter query does not capture, so tests are matched to Metals' test cases by line.
---@return string
local function test_name(suite, position)
    for _, case in ipairs((suite and suite.testCases) or {}) do
        if case.location and case.location.range.start.line == position.range[1] then
            return case.name
        end
    end
    return utils.get_position_name(position)
end

---Builds the `debug-adapter-start` arguments for the position at the root of `tree`.
---@param tree neotest.Tree
---@param state table see `explorer_state`
---@return table|nil request, string|nil error
function M.build_request(tree, state)
    local position = tree:data()
    if position.type == "file" then
        return { path = vim.uri_from_fname(position.path), runType = "testFile" }
    end
    local namespace = enclosing_namespace(tree)
    if not namespace then
        return nil, "No test class encloses " .. position.name
    end
    local name = class_name(namespace:data())
    local suite, target_uri = find_suite(state, name)
    if not suite then
        if position.type == "namespace" then
            return { testClass = name }
        end
        return nil, "Metals has not discovered test suite " .. name .. " yet"
    end
    return {
        target = { uri = target_uri },
        requestData = {
            suites = {
                {
                    className = name,
                    tests = position.type == "test" and { test_name(suite, position) } or {},
                },
            },
            jvmOptions = {},
            environmentVariables = {},
        },
    }
end

local statuses = { passed = "passed", failed = "failed", error = "failed" }

---Converts the `testResult` event data received from Metals into neotest results.
---@param tree neotest.Tree
---@param state table see `explorer_state`
---@param events table[] `testResult` event data: `{ suiteName, tests = { { kind, testName, error } } }`
---@return table<string, neotest.Result>
function M.to_results(tree, state, events)
    local positions = {} -- class name -> Metals test name -> position
    for _, node in tree:iter_nodes() do
        local position = node:data()
        local namespace = position.type == "test" and enclosing_namespace(node)
        if namespace then
            local name = class_name(namespace:data())
            positions[name] = positions[name] or {}
            positions[name][test_name(find_suite(state, name), position)] = position
        end
    end
    local results = {}
    for _, event in ipairs(events) do
        local suite = positions[event.suiteName] or {}
        for _, test in ipairs(event.tests or {}) do
            local name = test.testName or ""
            -- Some frameworks (e.g. JUnit) prefix test names with the class name.
            if vim.startswith(name, event.suiteName .. ".") then
                name = name:sub(#event.suiteName + 2)
            end
            local position = suite[name]
            if position then
                local result = { status = statuses[test.kind] or "skipped" }
                if test.error then
                    result.short = test.error
                    result.errors = { { message = test.error, line = position.range[1] } }
                end
                results[position.id] = result
            end
        end
    end
    return results
end

---@param path string
local function metals_client(path)
    local clients = vim.lsp.get_clients({ name = "metals" })
    for _, client in ipairs(clients) do
        local root = client.config.root_dir
        if root and vim.startswith(path, root) then
            return client
        end
    end
    return clients[1]
end

---neotest strategy that runs `spec.context.metals.request` through Metals. Received `testResult`
---event data is appended to `spec.context.metals.events`.
---@param spec neotest.RunSpec
---@param context neotest.StrategyContext
---@return neotest.Process
function M.strategy(spec, context)
    local ctx = spec.context.metals
    local output_path = nio.fn.tempname()
    local output_file = assert(io.open(output_path, "w"))
    local output = FanoutAccum(function(prev, new)
        return prev and prev .. new or new
    end, nil)
    local finished = nio.control.future()
    local tcp, seq, exit_code, code = nil, 0, nil, nil

    local function write(text)
        if code ~= nil then
            return
        end
        output_file:write(text)
        output_file:flush()
        nio.run(function()
            output:push(text)
        end)
    end

    local function finish(result_code)
        if code ~= nil then
            return
        end
        code = result_code
        output_file:close()
        if tcp and not tcp:is_closing() then
            -- shutdown flushes pending writes (e.g. disconnect) before closing.
            tcp:shutdown(function()
                if not tcp:is_closing() then
                    tcp:close()
                end
            end)
        end
        finished.set()
    end

    local function send(message)
        if not tcp or tcp:is_closing() then
            return
        end
        seq = seq + 1
        message.seq = seq
        local body = vim.json.encode(message)
        tcp:write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
    end

    local function request(command, arguments)
        send({ type = "request", command = command, arguments = arguments or vim.empty_dict() })
    end

    local function fail(message)
        write(message .. "\n")
        lib.notify(message, vim.log.levels.ERROR)
        finish(1)
    end

    local function handle(message)
        if message.type == "event" then
            local body = message.body or {}
            if message.event == "initialized" then
                request("configurationDone")
            elseif message.event == "output" and body.category ~= "telemetry" then
                write(body.output or "")
            elseif message.event == "testResult" then
                table.insert(ctx.events, body.data or body)
            elseif message.event == "exited" then
                exit_code = body.exitCode
            elseif message.event == "terminated" then
                request("disconnect")
            end
        elseif message.type == "response" then
            if message.command == "initialize" then
                request("launch", { noDebug = true, name = "neotest-scala", type = "scala", request = "launch" })
            elseif message.command == "disconnect" then
                finish(exit_code or 0)
            elseif not message.success then
                fail(("Metals %s request failed: %s"):format(message.command, message.message or ""))
            end
        elseif message.type == "request" then
            -- No reverse request (e.g. runInTerminal) is expected when running without debugging.
            send({ type = "response", request_seq = message.seq, command = message.command, success = false })
        end
    end

    local function connect(port)
        local buffer = ""
        tcp = vim.uv.new_tcp()
        tcp:connect("127.0.0.1", port, function(connect_err)
            if connect_err then
                return vim.schedule(function()
                    fail("Unable to connect to the Metals debug adapter: " .. connect_err)
                end)
            end
            tcp:read_start(function(read_err, data)
                if read_err or not data then
                    return vim.schedule(function()
                        finish(exit_code or (read_err and 1 or 0))
                    end)
                end
                buffer = buffer .. data
                while true do
                    local header_end = buffer:find("\r\n\r\n", 1, true)
                    if not header_end then
                        break
                    end
                    local length = tonumber(buffer:sub(1, header_end):match("Content%-Length: (%d+)"))
                    local body_end = header_end + 3 + length
                    if #buffer < body_end then
                        break
                    end
                    local body = buffer:sub(header_end + 4, body_end)
                    buffer = buffer:sub(body_end + 1)
                    vim.schedule(function()
                        handle(vim.json.decode(body))
                    end)
                end
            end)
            vim.schedule(function()
                request("initialize", {
                    clientID = "neotest-scala",
                    adapterID = "scala",
                    linesStartAt1 = true,
                    columnsStartAt1 = true,
                    pathFormat = "path",
                })
            end)
        end)
    end

    nio.run(function()
        if not ctx.request then
            return fail(ctx.error)
        end
        nio.scheduler()
        local client = metals_client(context.position.path)
        if not client then
            return fail("Metals is not running")
        end
        local started = nio.control.future()
        client:request("workspace/executeCommand", {
            command = "metals.debug-adapter-start",
            arguments = { ctx.request },
        }, function(err, result)
            started.set({ err = err, result = result })
        end)
        local response = started.wait()
        if code ~= nil then
            return -- stopped while Metals was preparing the run
        end
        local uri = response.result and response.result.uri
        local port = (uri or ""):match(":(%d+)$")
        if not port then
            local message = response.err and response.err.message or vim.inspect(response.result)
            return fail("Metals could not start the test run: " .. message)
        end
        nio.scheduler()
        connect(tonumber(port))
    end)

    return {
        is_complete = function()
            return code ~= nil
        end,
        output = function()
            return output_path
        end,
        output_stream = function()
            local queue = nio.control.queue()
            output:subscribe(queue.put)
            return function()
                return nio.first({ finished.wait, queue.get })
            end
        end,
        attach = function() end,
        stop = function()
            if tcp and not tcp:is_closing() then
                request("disconnect", { terminateDebuggee = true })
            end
            finish(1)
        end,
        result = function()
            finished.wait()
            return code
        end,
    }
end

return M
