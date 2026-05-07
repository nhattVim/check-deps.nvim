# check-deps.nvim

A lightweight Neovim plugin to check for external dependencies and help install them.

![screenshot](https://github.com/nhattVim/assets/blob/master/check-deps.nvim/1.png?raw=true)

## Features

- Define a list of required programs/tools.
- Custom check functions per dependency.
- Warn if dependencies are missing.
- Floating window display of missing dependencies.
- Suggested install commands for each dependency.

## Installation

```lua
-- lua with lazy.nvim
return {
  "nhattVim/check-deps.nvim",
  lazy = false,
  cmd = "DepsCheck",
  opts = {
    auto_check = true,
    list = {
      {
        name = "make",
        cmd = "make",
        install = {
          linux = { "sudo apt install build-essential", "sudo pacman -S make" },
          mac = { "brew install make" },
          windows = { "scoop install make", "choco install make" },
        },
      },
      {
        name = "python",
        cmd = { "python3", "python" },
        install = {
          linux = { "sudo apt install python3", "sudo pacman -S python" },
          mac = { "brew install python" },
          windows = { "scoop install python", "winget install Python.Python.3" },
        },
      },
      {
        name = "fd",
        cmd = { "fd", "fdfind" },
        install = {
          linux = { "sudo apt install fd-find", "sudo pacman -S fd" },
          mac = { "brew install fd" },
          windows = {
            "scoop install fd",
            "choco install fd",
            "winget install sharkdp.fd",
          },
        },
      },
      {
        name = "nodejs",
        cmd = "node",
        check = function()
          return vim.fn.executable("node") == 1 and vim.fn.system("node -v"):match("v16") ~= nil
        end,
        install = {
          linux = { "sudo apt install nodejs" },
          mac = { "brew install node" },
          windows = { "choco install nodejs" },
        },
      },
      {
        name = "lazygit",
        cmd = "lazygit",
        install = {
          linux = {
            "sudo add-apt-repository ppa:lazygit-team/release && sudo apt install lazygit",
            "sudo pacman -S lazygit",
          },
          mac = { "brew install lazygit" },
          windows = {
            "scoop install lazygit",
            "choco install lazygit",
            "winget install JesseDuffield.lazygit",
          },
        },
      },
      {
        name = "translate-shell",
        cmd = "trans",
        install = {
          linux = { "sudo apt install translate-shell", "sudo pacman -S translate-shell" },
          mac = { "brew install translate-shell" },
        },
      },
    },
  },
}

```

## Usage

- Run `:DepsCheck` to check dependencies.
- If missing dependencies are found:
    - A floating window will open.
    - Each missing dependency is listed with its install commands.
    - Move the cursor to an install command and press `<CR>` to run it.
    - Press `<Tab>` to switch panel, `<Esc>/q` to close the panel.

## Configuration

Options passed to `setup`:

```lua
opts = {
  auto_check = true, -- run automatically at startup
  list = { ... },    -- table of dependencies
}
```

### Dependency spec fields

- **name**: Display name.
- **cmd**: The executable name to check (optional if using `check`).
- **check**: A custom Lua function that takes no parameters and returns `true` if installed.
- **install**: A table of possible install commands by platform (keys: `linux`, `mac`, `windows`).

## Example

```lua
{
  name = "python3",
  cmd = "python3",
  install = {
    linux = { "sudo apt install python3" },
    mac = { "brew install python3" },
    windows = { "choco install python3" },
  }
}
```
