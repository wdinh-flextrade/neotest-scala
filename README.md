# neotest-scala

[Neotest](https://github.com/rcarriga/neotest) adapter for scala. Supports [utest](https://github.com/com-lihaoyi/utest), [munit](https://scalameta.org/munit/docs/getting-started.html) and [ScalaTest](https://www.scalatest.org/) test frameworks, by either running it with [bloop](https://scalacenter.github.io/bloop/) or sbt. Note that for ScalaTest the only supported style is FunSuite for now.

It also supports debugging tests with [nvim-dap](https://github.com/rcarriga/nvim-dap) (requires [nvim-metals](https://github.com/scalameta/nvim-metals)). You can debug individual test cases as well, but note that utest framework doesn't support this because it doesn't implement `sbt.testing.TestSelector`. To run tests with debugger pass `strategy = "dap"` when running neotest:

```lua
require('neotest').run.run({strategy = 'dap'})
```

Requires [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) and the parser for scala.

## Installation

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "nvim-neotest/neotest",
  requires = {
    ...,
    "stevanmilic/neotest-scala",
  }
  config = function()
    require("neotest").setup({
      ...,
      adapters = {
        require("neotest-scala"),
      }
    })
  end
})
```

## Configuration

You can set optional arguments to the setup function:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-scala")({
        -- Command line arguments for runner
        -- Can also be a function to return dynamic values
        args = {"--no-color"},
        -- Runner to use. Will use bloop by default.
        -- Can be a function to return dynamic value.
        -- For backwards compatibility, it also tries to read the vim-test scala config.
        -- Possibly values bloop|sbt.
        runner = "bloop",
        -- Test framework to use. Will use utest by default.
        -- Can be a function to return dynamic value.
        -- Possibly values utest|munit|scalatest.
        framework = "utest",
    })
  }
})
```

## Development

Run the unit tests with [plenary.nvim](https://github.com/nvim-lua/plenary.nvim):

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/unit { minimal_init = 'tests/minimal_init.lua', sequential = true }"
```

`tests/minimal_init.lua` looks for plenary.nvim, nvim-nio and neotest in the lazy.nvim data directory and for the
scala treesitter parser in `stdpath("data")/site`. Override these locations with `PLENARY_DIR`, `NIO_DIR`, `NEOTEST_DIR`
and `TS_PARSER_DIR`.

ScalaTest results are read from the reporter's `- <test name>` lines and matched against the test names discovered in
the file. Lines may carry the sbt 1.x `[info] ` prefix (dropped in sbt 2) and may be preceded by test stdout that was not
newline-terminated.

## Roadmap

To be implemented:

- Displaying errors in diagnostics
