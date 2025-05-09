-- ~/.config/nvim/lua/better-git-blame/init.lua

local M = {}

local Job = require("plenary.job")
local Path = require("plenary.path")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
-- local conf  = require("telescope.config").values
local sorters = require("telescope.sorters")
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local current_state = {
    last_selection = nil,
    last_repo_root = nil,
    last_commit_list = nil,
}

-- get the file, start_line, and end_line of visual selection
local function get_visual_selection(start_line, end_line)
    local file_path = vim.fn.expand("%:p")
    if not file_path or file_path == "" then
        vim.notify("No file name associated with buffer", vim.log.levels.WARN, { title="BetterGitBlame"})
        return nil
    end

    -- handle backward selection
    if start_line > end_line then
        start_line, end_line= end_line, start_line
    end

    return { file = file_path, start_line = start_line, end_line = end_line }
end

local function find_git_repo_root(current_path)
    local parent_dir = Path:new(current_path):parent():absolute()
    if not parent_dir then
        vim.notify("Could not get parent directory for: " .. tostring(current_path), vim.log.levels.ERROR, { title="BetterGitBlame" })
        return
    end

    local repo_root_cmd = { "git", "-C", vim.fn.fnameescape(parent_dir), "rev-parse", "--show-toplevel" }
    local repo_root_list = vim.fn.systemlist(repo_root_cmd)
    local repo_root = repo_root_list and repo_root_list[1]

    if vim.vshell_error ~= nil then
        if repo_root == "" then repo_root = nil end -- handle empty output
        vim.notify("ERROR HERE", vim.log.levels.ERROR, { title="BetterGitBlame" })
    end

    if not repo_root then
        vim.notify("Could not determine Git repository root. " .. tostring(parent_dir) .. " from " .. tostring(current_path), vim.log.levels.ERROR, { title="BetterGitBlame"})
    end
    return repo_root
end

-- parse output of git log
local function parse_git_log(output_lines)
    local commits = {}

    -- <hash> <date> <author> <subject>
    local pattern = "^([0-9a-f]+)%s+([%d-]+)%s+(.-)%s+(.*)$"

    for _, line in ipairs(output_lines) do
        local hash, date, author, subject = line:match(pattern)
        if hash and date and author and subject then
            table.insert(commits, {
                hash = hash,
                date = date,
                author = author,
                subject = subject,
            })
        end
    end
    return commits
end

local function get_blame_commits(selection, repo_root, callback)
    local current_path = Path:new(selection.file)
    local rel_file_path = current_path:make_relative(repo_root)
    if not rel_file_path then
        vim.notify("could not find relative file path", vim.log.levels.ERROR, { title="BetterGitBlame" })
        return
    end

    local log_range = string.format("%d,%d", selection.start_line, selection.end_line)
    local format_arg = "--format=%H %ad %an %s"
    local date_arg = "--date=short"
    local range_arg = "-L" .. log_range .. ":" .. rel_file_path

    -- git log -C <repo_root> -L "<start>,<end>:<relative_path>" --format="%H %ad %an %s" --date=short
    local git_args = { "-C", repo_root, "log", range_arg, format_arg, date_arg }
    vim.notify("Searching Git history for selection...", vim.log.levels.INFO, { title="BetterGitBlame" })

    Job:new({
        command = "git",
        args = git_args,
        cwd = repo_root,
        on_exit = vim.schedule_wrap(function(j, return_val)
            -- return val other than 0, consider error
            if return_val ~= 0 then
                local stderr = table.concat(j:stderr_result(), "\n")
                vim.notify("git log failed".. stderr , vim.log.levels.ERROR, { title="BetterGitBlame"})
                callback(nil, stderr)
                return
            end

            local commit_list = parse_git_log(j:result())
            -- no commit list
            if #commit_list == 0 then
                vim.notify("No commits", vim.log.levels.WARN, { title="BetterGitBlame" })
                -- callback with empty list
            end
            callback(commit_list, nil)
        end),
    }):start()
end

local function get_commit_details(repo_root, commit_hash, callback)
    local diff_args = { "show", commit_hash }

    local diff_output = {}
    local error_output = {}
    local exit_code = -1

    Job:new({
        command = "git",
        args = diff_args,
        cwd = repo_root,

        on_stdout = function(_, data) if data then table.insert(diff_output, data) end end,
        on_stderr = function(_, data) if data then table.insert(error_output, data) end end,

        on_exit = vim.schedule_wrap(function(j, return_val)
            exit_code = return_val
            if return_val ~= 0 then
                vim.notify("git show failed for diff: " .. commit_hash, vim.log.levels.WARN, { title="BetterGitBlame"})
            end
            callback(diff_output, error_output, exit_code)
        end),
    }):start()
end

local function get_git_remote_url(repo_root)
    local args = { "git", "-C", repo_root,  "remote", "get-url", "origin" }
    local result = vim.fn.systemlist(args)
    if result then
        return vim.trim(result[1])
    end

    return nil
end

local function parse_git_url(url)
    -- try ssh format
    local ssh_host, ssh_path = url:match("^git@([^:]+):(.+)$")
    if ssh_host and ssh_path then
        -- if optional .git at end of path, remove
        if ssh_path:find(".git$") then
            ssh_path = ssh_path:sub(1, -5)
        end
        return { host = ssh_host, path = ssh_path }
    end

    -- try http/https format
    -- should work but not tested other than in regex matcher. seems fine
    local https_host, https_path = url:match("^http[s]?://([^/]+)(/.+)$")
    if https_host and https_path then
        -- remove leading '/' in https path
        https_path = https_path:sub(2)
        return { host = https_host, path = https_path }
    end
    return nil
end

local function open_commit_in_browser(repo_root, commit_hash)
    local remote_url = get_git_remote_url(repo_root)
    if not remote_url then
        vim.notify("Could not determine remote URL: ", vim.log.levels.WARN, { title="BetterGitBlame:OpenCommitInBrowser" })
        return
    end

    local parsed_url = parse_git_url(remote_url)
    if not parsed_url then
        vim.notify("Could not parse remote URL: " .. parsed_url, vim.log.levels.WARN, { title="BetterGitBlame:OpenCommitInBrowser" })
        return
    end

    local commit_url = nil
    local host = parsed_url.host:lower()
    local path = parsed_url.path

    -- TODO
    -- support other hosts
    if host:find("github.com") then
        commit_url = string.format("https://%s/%s/commit/%s", host, path, commit_hash)
    else
        vim.notify("Unsupported git host: " .. parsed_url.host, vim.log.levels.WARN, { title="BetterGitBlame:OpenCommitInBrowser" })
        return
    end

    Job:new({
        -- TODO support for non linux xdg-open
        command = "xdg-open",
        args = { commit_url },

        on_exit = function(_, code)
            if code ~= 0 then
                vim.notify("Failed to open URL.", vim.log.levels.ERROR, { title="BetterGitBlame:OpenCommitInBrowser" })
            end
        end
    }):start()
end

-- defining preview window
local function create_previewer(repo_root)
    return previewers.new_buffer_previewer({
        define_preview = function(self, entry, status)
            if not vim.api.nvim_buf_is_valid(self.state.bufnr) then
                return
            end

            local bufnr = self.state.bufnr

            -- set buffer modifiable and clear it
            vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
            vim.api.nvim_buf_set_option(bufnr, "readonly", false)

            -- filetype git
            vim.api.nvim_buf_set_option(bufnr, "filetype", "git")

            -- clear buffer
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            if not entry or not entry.value or not entry.value.hash then
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Error: Invalid entry", vim.inspect(entry)})
                vim.api.nvim_buf_set_option(bufnr, "readonly", true)
                vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
                return
            end

            local commit_hash = entry.value.hash

            get_commit_details(repo_root, commit_hash, function(diff_lines, error_lines, exit_code)
                if not vim.api.nvim_buf_is_valid(bufnr) then return end

                local final_content
                if exit_code ~= 0 then
                    final_content = error_lines
                else
                    final_content = diff_lines
                end

                vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
                vim.api.nvim_buf_set_option(bufnr, "readonly", false)

                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_content)

                vim.api.nvim_buf_set_option(bufnr, "readonly", true)
                vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

                vim.api.nvim_win_set_cursor(self.state.winid, {1, 0})
            end)
        end,
    })
end

local function launch_telescope_picker(commit_list, repo_root, selection)
    pickers.new({}, {
        prompt_title = "Code Block History",
        finder = finders.new_table({
            results = commit_list,
            entry_maker = function(entry)

                -- trim hash to first 6 characters
                local trimmed_hash = string.sub(entry.hash, 1, 7)

                return {
                    value = entry,
                    display = string.format("%s (%s) | %s | %s", trimmed_hash, entry.date, entry.author, entry.subject),
                    ordinal = entry.date .. " " .. entry.hash,
                }
            end
        }),
        sorter = sorters.get_generic_fuzzy_sorter({}),
        previewer = create_previewer(repo_root),
        layout_strategy = 'horizontal',
        layout_config = {
            horizontal = {
                preview_width = 0.5,
            }
        },
        -- mappings
        -- map can be used for later keybind functionality
        attach_mappings = function(prompt_bufnr, map)
            -- local current_picker = action_state.get_current_picker(prompt_bufnr)

            actions.select_default:replace(function()
                local sel = action_state.get_selected_entry()
                actions.close(prompt_bufnr)

                if sel and sel.value and sel.value.hash then
                    local hash = sel.value.hash
                    local file = sel.filename

                    -- where optional dependencies come in handy

                    if vim.fn.exists(":Gvdiffsplit") == 2 then -- fugitive
                        vim.cmd("Gvdiffsplit " .. hash)
                    elseif vim.fn.exists(":DiffviewOpen") == 2 then --diffview
                        vim.cmd("DiffviewOpen " .. hash .. ".." .. hash .. " -- " .. file)
                    else
                        if vim.fn.exists(":Git") == 2 then
                            vim.cmd("tab Git show " .. hash)
                        else
                            vim.cmd("tabnew | term git -C " .. vim.fn.shellescape(repo_root) .. " show " .. hash)
                        end
                    end
                end
            end)
            -- Ctrl+b in telescope picker to open commit in browser
            map({"i", "n"}, "<C-b>", function()
                local sel = action_state.get_selected_entry()
                if sel and sel.value and sel.value.hash then
                    open_commit_in_browser(repo_root, sel.value.hash)
                else
                    vim.notify("No valid commit selected to open", vim.log.levels.WARN, { title="BetterGitBlame:OpenCommitInBrowser" })
                end
            end)
            return true
        end
    }):find()
end

-- function called from BlameInvestigate
function M.investigate_selection(args)
    -- get lines of visual selection
    local selection = get_visual_selection(args.line1, args.line2)
    if not selection then return end -- handled in get_visual_selection

    local repo_root = find_git_repo_root(selection.file)
    if not repo_root then return end -- handled in find_git_repo_root

    -- update cached values for use in :BlameShowLast
    current_state.last_selection = selection
    current_state.last_repo_root = repo_root

    get_blame_commits(selection, repo_root, function(commit_list, err)
        if err then
            return
        end

        -- update cached commit list
        current_state.last_commits = commit_list
        launch_telescope_picker(commit_list, repo_root, selection)
    end)
end

function M.show_last_investigation()
    if not current_state.last_selection or not current_state.last_repo_root then
        vim.notify("Not previous investigation stored.", vim.log.levels.WARN, { title="BetterGitBlame:BlameShowLast" })
        return
    end

    if current_state.last_commits then
        launch_telescope_picker(current_state.last_commits, current_state.last_repo_root, current_state.last_selection)
        return
    end
end

function M.setup()
    --config = vim.tbl_deep_extend("force", config, user_config or {})

    vim.api.nvim_create_user_command("BlameInvestigate", M.investigate_selection, {
        range = true,
        desc = "Investigate Git history of selected code block",
    })

    vim.api.nvim_create_user_command("BlameShowLast", M.show_last_investigation, {
        desc = "Show telescope picker of last investigation from BlameInvestigate",
    })
end

return M
