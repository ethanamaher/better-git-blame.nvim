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
local utils = require("telescope.utils")

-- get the file, start_line, and end_line of visual selection
local function get_visual_selection()
    local start_row, end_row
    -- check for in visual mode
    local is_visual_mode = vim.fn.mode():find("[vV]")


    -- if in visual mode get selection range
    -- if not in visual mode use current line
    if is_visual_mode then
        _, start_row, _, _ = unpack(vim.fn.getpos("'<"))
        _, end_row, _, _ = unpack(vim.fn.getpos("'>"))
    else
        start_row = vim.fn.line(".")
        end_row = start_row
    end

    local file_path = vim.fn.expand("%:p")
    if not file_path or file_path == "" then
        vim.notify("No file name associated with buffer", vim.log.levels.WARN, { title="BetterGitBlame"})
        return nil
    end

    if start_row == 0 or end_row == 0 then
        if not is_visual_mode then
            start_row = vim.fn.line(".")
            end_row = start_row
        else
            vim.notify("Could not determine selection range", vim.log.levels.WARN, { title="BetterGitBlame"})
        end
    end

    -- handle backward selection
    if start_row > end_row then
        start_row, end_row = end_row, start_row
    end

    return { file = file_path, start_line = start_row, end_line = end_row }
end

local function find_git_repo_root(path)
    local parent_dir = Path:new(path):parent():absolute()
    local repo_root_cmd = { "git", "-C", parent_dir, "rev-parse", "--show-toplevel" }
    local root = nil
    local job_result = vim.fn.systemlist(repo_root_cmd)

    if vim.vshell_error == 0 and job_result then
        root = vim.trim(job_result[1])
        if root == "" then root = nil end -- handle empty output
    end

    if not root then
        vim.notify("Could not determine Git repository root", vim.log.levels.ERROR, { title="BetterGitBlame"})
    end
    return root
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

-- function called from BlameInvestigate
function M.investigate_selection()
    -- get lines of visual selection
    local selection = get_visual_selection()
    if not selection then return end -- handled in get_visual_selection

    local repo_root = find_git_repo_root(selection.file)
    if not repo_root then return end -- handled in find_git_repo_root

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
                vim.notify("Failed Here".. stderr , vim.log.levels.ERROR, { title="BetterGitBlame"})
                return
            end

            local commit_list = parse_git_log(j:result())
            -- no commit list
            if #commit_list == 0 then
                vim.notify("No commits", vim.log.levels.WARN, { title="BetterGitBlame" })
                return
            end

            -- defining preview buffer
            -- should probably do in its own function

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

                    return true
                end
            }):find()
        end)
    }):start()
end


function M.setup()
    vim.api.nvim_create_user_command("BlameInvestigate", M.investigate_selection, {
        range = true,
        desc = "Investigate Git history of selected code block",
    })
end

return M
