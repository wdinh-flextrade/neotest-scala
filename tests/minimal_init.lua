-- Dependency locations default to a lazy.nvim install; override with env vars.
local lazy = vim.fn.stdpath("data") .. "/lazy"
local deps = {
    os.getenv("PLENARY_DIR") or (lazy .. "/plenary.nvim"),
    os.getenv("NIO_DIR") or (lazy .. "/nvim-nio"),
    os.getenv("NEOTEST_DIR") or (lazy .. "/neotest"),
    -- Location of the compiled scala treesitter parser (parser/scala.so).
    os.getenv("TS_PARSER_DIR") or (vim.fn.stdpath("data") .. "/site"),
}

vim.opt.rtp:append(".")
for _, dep in ipairs(deps) do
    vim.opt.rtp:append(dep)
end

vim.cmd("runtime plugin/plenary.vim")
