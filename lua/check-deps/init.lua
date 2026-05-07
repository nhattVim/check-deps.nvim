local uv = vim.uv or vim.loop

local M = {}

local NS = vim.api.nvim_create_namespace("DepsCheck")
local AUGROUP = vim.api.nvim_create_augroup("DepsCheck", { clear = true })

local DEFAULT_CONFIG = {
    list = {},
    auto_check = false,
}

local config = {}

local state = {
    left_win = nil,
    right_win = nil,
    left_buf = nil,
    right_buf = nil,
    expanded_deps = {},
    rendered_items = {},
    results = {},
}

local OS = (function()
    local uname = uv.os_uname().sysname:lower()

    if uname:match("darwin") then
        return "mac"
    elseif uname:match("linux") then
        return "linux"
    elseif uname:match("windows") or uname:match("mingw") or uname:match("cygwin") then
        return "windows"
    end

    return uname
end)()

local ICONS = {
    ok = "✓",
    error = "✗",
    warn = "⚠",
    cmd = "+",
    expanded = "▾",
    collapsed = "▸",
}

local HIGHLIGHTS = {
    installed = {
        icon = "DiagnosticOk",
        text = "String",
    },
    missing = {
        icon = "ErrorMsg",
        text = "WarningMsg",
    },
}

---@param cmd string
---@return boolean
local function is_executable(cmd)
    return vim.fn.executable(cmd) == 1
end

---@param win integer?
local function close_win(win)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
end

local function cleanup_windows()
    close_win(state.left_win)
    close_win(state.right_win)

    state.left_win = nil
    state.right_win = nil
    state.left_buf = nil
    state.right_buf = nil
end

local function toggle_focus()
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win == state.left_win and state.right_win and vim.api.nvim_win_is_valid(state.right_win) then
        vim.api.nvim_set_current_win(state.right_win)
    elseif cur_win == state.right_win and state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
        vim.api.nvim_set_current_win(state.left_win)
    end
end

---@param buf integer
---@param title string
---@param width integer
---@param height integer
---@param row integer?
---@param col integer?
---@param focusable boolean?
---@return integer
local function create_float(buf, title, width, height, row, col, focusable)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title = (" %s "):format(title),
        title_pos = "center",
        width = width,
        height = height,
        row = row or math.floor((vim.o.lines - height) / 2),
        col = col or math.floor((vim.o.columns - width) / 2),
        focusable = focusable == nil and true or focusable,
    })

    vim.wo[win].cursorline = true

    return win
end

---@class DepsCheckResult
---@field dep table
---@field status "installed"|"missing"
---@field msg string?

---@param dep table
---@return "installed"|"missing", string?
local function check_dep(dep)
    if type(dep.check) == "function" then
        local ok, result = pcall(dep.check)

        if ok and result then
            return "installed"
        end
    end

    local executable = dep.cmd or dep.name

    if not executable or not is_executable(executable) then
        return "missing"
    end

    return "installed"
end

---@param buf integer
---@param mode string
---@param lhs string
---@param rhs function|string
local function map(buf, mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, {
        buffer = buf,
        silent = true,
        nowait = true,
    })
end

---@param cmd string
local function open_install_terminal(cmd)
    if not state.right_win or not vim.api.nvim_win_is_valid(state.right_win) then
        return
    end

    vim.api.nvim_set_current_win(state.right_win)

    local term_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.right_win, term_buf)
    state.right_buf = term_buf

    ---@diagnostic disable-next-line: deprecated
    vim.fn.termopen(cmd, {
        on_exit = function(_, code)
            vim.schedule(function()
                if vim.api.nvim_get_mode().mode == "t" then
                    vim.cmd.stopinsert()
                end
            end)

            if code == 0 then
                vim.notify("Successfully installed dependency!", vim.log.levels.INFO)
            else
                vim.notify(("Installation failed with exit code: %d"):format(code), vim.log.levels.ERROR)
            end

            vim.schedule(function()
                M.check(true, true)
            end)
        end,
    })

    if state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
        vim.api.nvim_set_current_win(state.left_win)
    end

    local function close_ui()
        cleanup_windows()
    end

    map(term_buf, "t", "<Esc>", [[<C-\><C-n>]])
    map(term_buf, "n", "q", close_ui)
    map(term_buf, "n", "<Esc>", close_ui)
    map(term_buf, "n", "<Tab>", toggle_focus)
end

local function render_left_panel()
    if not state.left_buf or not vim.api.nvim_buf_is_valid(state.left_buf) then
        return
    end

    local lines = {
        "  Deps-Check: Status Overview",
        "",
    }
    local highlights = {
        { 0, "Title", 0, -1 },
    }

    state.rendered_items = {}

    for _, result in ipairs(state.results) do
        local dep = result.dep
        local status = result.status
        local hl = HIGHLIGHTS[status]

        local is_expanded = state.expanded_deps[dep.name]
        local toggle_icon = is_expanded and ICONS.expanded or ICONS.collapsed
        local status_icon = ICONS[status == "installed" and "ok" or status == "missing" and "error" or "warn"]

        local text = ("  %s %s %s"):format(toggle_icon, status_icon, dep.name)
        if result.msg then
            text = ("%s (%s)"):format(text, result.msg)
        end

        local line = #lines
        lines[#lines + 1] = text
        state.rendered_items[line] = { type = "dep", dep = dep }

        highlights[#highlights + 1] = { line, "Special", 2, 5 }
        highlights[#highlights + 1] = { line, hl.icon, 5, 8 }
        highlights[#highlights + 1] = { line, hl.text, 8, -1 }

        if is_expanded then
            local cmds = dep.install and dep.install[OS] or {}
            if type(cmds) == "string" then
                cmds = { cmds }
            end

            if #cmds > 0 then
                for _, cmd in ipairs(cmds) do
                    local cmd_line = #lines
                    lines[#lines + 1] = ("      %s %s"):format(ICONS.cmd, cmd)
                    state.rendered_items[cmd_line] = { type = "cmd", dep = dep, cmd = cmd }

                    highlights[#highlights + 1] = { cmd_line, "Special", 6, 9 }
                    highlights[#highlights + 1] = { cmd_line, "Directory", 9, -1 }
                end
            else
                lines[#lines + 1] = ("      No install command for OS: %s"):format(OS)
                highlights[#highlights + 1] = { #lines - 1, "Comment", 0, -1 }
            end
        end
    end

    lines[#lines + 1] = ""

    local footer_lines = {
        "  [<CR>: Toggle/Install] [<Tab>: Switch Panel]",
        "  [<Esc>/q: Close]",
    }

    for _, line in ipairs(footer_lines) do
        lines[#lines + 1] = line
        highlights[#highlights + 1] = { #lines - 1, "Comment", 0, -1 }
    end

    vim.bo[state.left_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.left_buf, 0, -1, false, lines)
    vim.bo[state.left_buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(state.left_buf, NS, 0, -1)
    for _, hl in ipairs(highlights) do
        local line = lines[hl[1] + 1]
        vim.api.nvim_buf_set_extmark(state.left_buf, NS, hl[1], hl[3], {
            end_col = hl[4] == -1 and #line or hl[4],
            hl_group = hl[2],
        })
    end
end

local function show_results()
    cleanup_windows()

    local total_width = math.floor(vim.o.columns * 0.8)
    local total_height = math.floor(vim.o.lines * 0.8)

    local left_width = math.floor(total_width * 0.4)
    local right_width = total_width - left_width - 2

    local row = math.floor((vim.o.lines - total_height) / 2)
    local col = math.floor((vim.o.columns - total_width) / 2)

    state.left_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.left_buf].buftype = "nofile"
    vim.bo[state.left_buf].bufhidden = "wipe"
    vim.bo[state.left_buf].swapfile = false

    state.left_win = create_float(state.left_buf, "Dependencies", left_width, total_height, row, col)

    state.right_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.right_buf].buftype = "nofile"
    vim.bo[state.right_buf].bufhidden = "wipe"
    vim.bo[state.right_buf].swapfile = false

    local placeholder = {
        "",
        "  Select an install command to run it here.",
    }
    vim.api.nvim_buf_set_lines(state.right_buf, 0, -1, false, placeholder)
    vim.bo[state.right_buf].modifiable = false

    state.right_win =
        create_float(state.right_buf, "Terminal", right_width, total_height, row, col + left_width + 2, true)
    vim.api.nvim_set_current_win(state.left_win)

    local function close_ui()
        cleanup_windows()
    end

    map(state.left_buf, "n", "q", close_ui)
    map(state.left_buf, "n", "<Esc>", close_ui)
    map(state.left_buf, "n", "<Tab>", toggle_focus)
    map(state.left_buf, "n", "<CR>", function()
        local cursor_row = vim.api.nvim_win_get_cursor(state.left_win)[1] - 1
        local item = state.rendered_items[cursor_row]

        if not item then
            return
        end

        if item.type == "dep" then
            state.expanded_deps[item.dep.name] = not state.expanded_deps[item.dep.name]
            render_left_panel()
        elseif item.type == "cmd" then
            open_install_terminal(item.cmd)
        end
    end)

    map(state.right_buf, "n", "q", close_ui)
    map(state.right_buf, "n", "<Esc>", close_ui)
    map(state.right_buf, "n", "<Tab>", toggle_focus)

    render_left_panel()
end

---@param silent_if_ok boolean?
---@param is_refresh boolean?
function M.check(silent_if_ok, is_refresh)
    local results = {}
    local has_issues = false

    for _, dep in ipairs(config.list) do
        local status, msg = check_dep(dep)

        results[#results + 1] = {
            dep = dep,
            status = status,
            msg = msg,
        }

        if status ~= "installed" then
            local cmds = dep.install and dep.install[OS]
            if cmds and (type(cmds) == "string" or (type(cmds) == "table" and #cmds > 0)) then
                has_issues = true
            end
        end
    end

    state.results = results

    if is_refresh and state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
        render_left_panel()
        return
    end

    if not silent_if_ok then
        show_results()
    elseif has_issues then
        vim.notify("Missing dependencies found. Run :DepsCheck", vim.log.levels.WARN)
    end
end

---@param opts? table
function M.setup(opts)
    config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})

    vim.api.nvim_create_user_command("DepsCheck", function()
        M.check(false)
    end, {})

    vim.api.nvim_create_autocmd("WinClosed", {
        group = AUGROUP,
        callback = function(args)
            local win = tonumber(args.match)

            if win == state.left_win then
                state.left_win = nil
                vim.defer_fn(cleanup_windows, 10)
            elseif win == state.right_win then
                state.right_win = nil
                vim.defer_fn(cleanup_windows, 10)
            end
        end,
    })

    if config.auto_check then
        vim.defer_fn(function()
            M.check(true)
        end, 500)
    end
end

return M
