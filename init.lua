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

local function get_visual_selection()
    local _, start_row, _, _ = unpack(vim.fn.getpos("'<"))
    local _, end_row, _, _ = unpack(vim.fn.getpos("'>"))
    local file_path = vim.fn.expand("%:p")

    if not file_path or file_path == "" then
        vim.notify("No file name associated with buffer", vim.log.levels.WARN, { title="BetterGitBlame" })
        return nil
    end

    if start_row == 0 or end_row == 0 then
        vim.notify("Could not find start or end row", vim.log.levels.WARN, { title="BetterGitBlame" })
        return nil
    end

    -- hand backward selection
    if start_row > end_row then
        start_row, end_row = end_row, start_row
    end

    return { file = file_path, start_line = start_row, end_line = end_row }
end

local function parse_commit_list(output_lines)
    print("Parsing commits")
    local commits = {}

    local pattern = "^([0-9a-f]+)%s+([%d-]+)%s+(.-)%s+(.*)$"

    for _, line in ipairs(output_lines) do
        local hash, date, author, subject = line:match(pattern)
        if hash then
            print(hash)
            table.insert(commits, {
                hash = hash,
                date = date,
                author = author,
                subject = subject,
                raw = line
            })
        end
    end
    return commits
end

function M.investigate_selection()
    local selection = get_visual_selection()
    if not selection then
        vim.notify("No selection", vim.log.levels.ERROR, { title="BetterGitBlame" })
        return
    end

    local current_path = Path:new(selection.file)
    local repo_root_cmd = string.format("git -C '%s' rev-parse --show-toplevel", vim.fn.fnameescape(current_path:parent():absolute()))

    local repo_root_list = vim.fn.systemlist(repo_root_cmd)
    local repo_root = repo_root_list and repo_root_list[1]
    repo_root = repo_root and vim.trim(repo_root)
    if vim.vshell_error ~= nil or not repo_root or repo_root == "" then
        vim.notify("Shell or repo root error: " .. repo_root , vim.log.levels.ERROR, { title="BetterGitBlame" })
        return
    end

    local rel_file_path = current_path:make_relative(repo_root)

    if not rel_file_path then
        vim.notify("could not find relative file path", vim.log.levels.ERROR, { title="BetterGitBlame" })
        return
    end

    local log_range = string.format("%d,%d", selection.start_line, selection.end_line)
    local format_arg = "--format=%H %ad %an %s"
    local date_arg = "--date=short"
    local range_arg = "-L" .. log_range .. ":" .. rel_file_path

    local git_args = { "-C", repo_root, "log", range_arg, format_arg, date_arg }

    vim.notify("Searching Git history for selection...", vim.log.levels.INFO, { title="BetterGitBlame" })

    local job = Job:new({
        command = "git",
        args = git_args,
        cwd = repo_root,
        on_exit = vim.schedule_wrap(function(j, return_val)
            if return_val ~= 0 then
                local stderr = table.concat(j:stderr_result(), "\n")
                vim.notify("Failed Here".. stderr , vim.log.levels.ERROR, { title="BetterGitBlame"})
                return
            end

            local commit_list = parse_commit_list(j:result())

            if #commit_list == 0 then
                vim.notify("No commits", vim.log.levels.WARN, { title="BetterGitBlame" })
                return
            end

            local git_previewer = previewers.new_buffer_previewer {
                define_preview = function(self, entry, status)
                    if not vim.api.nvim_buf_is_valid(self.state.bufnr) then
                        return
                    end

                    -- set buffer modifiable and clear it
                    vim.api.nvim_buf_set_option(self.state.bufnr, "modifiable", true)
                    vim.api.nvim_buf_set_option(self.state.bufnr, "readonly", false)

                    -- clear buffer
                    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {})

                    if not entry or not entry.value or not entry.value.hash then
                        local err_msg = "Error invalid entry"
                        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { err_msg, vim.inspect(entry)})
                        vim.api.nvim_buf_set_option(self.state.bufnr, "readonly", true)
                        vim.api.nvim_buf_set_option(self.state.bufnr, "modifiable", false)
                        return
                    end

                    local commit_hash = entry.value.hash
                    local show_cmd_args = {"show", commit_hash}

                    local output_lines = {}
                    local error_lines = {}
                    local job_exit_code = -1

                    Job:new({
                        command = "git",
                        args = show_cmd_args,
                        cwd = repo_root,

                        on_stdout = function(_, data)
                            if data then table.insert(output_lines, data) end
                        end,

                        on_stderr = function(_, data)
                            if data then table.insert(error_lines, data) end
                        end,

                        on_exit = vim.schedule_wrap(function(_, code)
                            job_exit_code = code

                            if not vim.api.nvim_buf_is_valid(self.state.bufnr) then return end

                            local final_content = {}

                            if job_exit_code ~= 0 then

                                final_content = error_lines
                                if #final_content == 0 then
                                    table.insert(final_content, "Failed")
                                end

                            else
                                final_content = output_lines
                                if #final_content == 0 then
                                    table.insert(final_content, "Failed")
                                end
                            end
                            vim.api.nvim_buf_set_option(self.state.bufnr, "modifiable", true)
                            vim.api.nvim_buf_set_option(self.state.bufnr, "readonly", false)

                            vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, final_content)
                            vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "git")


                            vim.api.nvim_buf_set_option(self.state.bufnr, "readonly", true)
                            vim.api.nvim_buf_set_option(self.state.bufnr, "modifiable", false)

                        end),
                    }):start()
                end,
            }

            pickers.new({}, {
                prompt_title = "Code Block History",
                finder = finders.new_table({
                    results = commit_list,
                    entry_maker = function(entry)
                        local trimmed_hash = string.sub(entry.hash, 1, 7)

                        return {
                            value = entry,
                            display = string.format("%s (%s) | %s | %s", trimmed_hash, entry.date, entry.author, entry.subject),
                            ordinal = entry.date .. " " .. entry.hash,
                        }
                    end
                }),
                sorter = sorters.get_generic_fuzzy_sorter({}),
                previewer = git_previewer,
                layout_strategy = 'horizontal',
                layout_config = {
                    horizontal = {
                        preview_width = 0.5,
                    }
                },
                attach_mappings = function(prompt_bufnr, map)
                    -- local current_picker = action_state.get_current_picker(prompt_bufnr)

                    actions.select_default:replace(function()
                        local sel = action_state.get_selected_entry()
                        actions.close(prompt_bufnr)

                        if sel and sel.value and sel.value.hash then
                            local hash = sel.value.hash
                            local file = sel.filename

                            if vim.fn.exists(":Gvdiffsplit") == 2 then
                                vim.cmd("Gvdiffsplit " .. hash)
                            elseif vim.fn.exists(":DiffviewOpen") == 2 then
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
    })
    if job then
        job:start()
    end
end


function M.setup()
    vim.api.nvim_create_user_command("BlameInvestigate", M.investigate_selection, {
        range = true,
        desc = "Investigate Git history of selected code block",
    })
end

return M
