-- lua/better-git-blame/telescope.lua
local M = {}
local Path = require("plenary.path")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
-- local conf  = require("telescope.config").values
local sorters = require("telescope.sorters")
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local git_utils

function M.setup_dependencies(utils)
    git_utils = utils
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

            git_utils.get_commit_details(repo_root, commit_hash, function(diff_lines, error_lines, exit_code)
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

function M.launch_telescope_picker(commit_list, repo_root, selection, title)
    pickers.new({}, {
        prompt_title = title or "BetterGitBlame",
        finder = finders.new_table({
            results = commit_list,
            entry_maker = function(entry)

                -- trim hash to first 6 characters
                local trimmed_hash = string.sub(entry.hash, 1, 7)

                return {
                    value = entry,
                    display = string.format("%s (%s %s) | %s | %s", trimmed_hash, entry.date, entry.time, entry.author, entry.message),
                    ordinal = entry.date .. " " .. entry.time,
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
            -- TODO commands to change diff view between HEAD, parent, working,
            -- Ctrl+b in telescope picker to open commit in browser
            map({"i", "n"}, "<C-b>", function()
                local sel = action_state.get_selected_entry()
                if sel and sel.value and sel.value.hash then
                    git_utils.open_commit_in_browser(repo_root, sel.value.hash)
                else
                    vim.notify("No valid commit selected to open", vim.log.levels.WARN, { title="BetterGitBlame:OpenCommitInBrowser" })
                end
            end)
            return true
        end
    }):find()
end


return M
