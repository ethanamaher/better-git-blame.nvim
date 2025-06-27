-- lua/better-git-blame/telescope.lua
local M = {}
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local sorters = require("telescope.sorters")
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local git_utils

---sets up dependencies for telescope integration
---@param utils table better-git-blame.utils module
function M.setup_dependencies(utils)
	git_utils = utils
end

---Create a Telescope previewer for displaying git commit diffs
---@param repo_root string absolute path to git repo root
---@return table Telescope previewer table instance
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
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

			-- filetype git
			vim.api.nvim_buf_set_option(bufnr, "filetype", "git")

			if not entry or not entry.value or not entry.value.hash then
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Error: Invalid entry", vim.inspect(entry) })
				vim.api.nvim_buf_set_option(bufnr, "readonly", true)
				vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
				return
			end

			local commit_hash = entry.value.hash
			git_utils.get_commit_details(repo_root, commit_hash, function(diff_lines, error_lines, exit_code)
				-- check buffer validity since async callback
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end

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

				vim.api.nvim_win_set_cursor(self.state.winid, { 1, 0 })
			end)
		end,
	})
end

---Launches telescope picker to display list of commits
---@param commit_list table list of commits (utils.parse_git_log)
---@param repo_root string absolute path to git repo root
---@param selection table visual selection object { filename, start_line, end_line }
---@param title string|nil title for telescope prompt
function M.launch_telescope_picker(commit_list, repo_root, selection, title)
	pickers
		.new({}, {
			prompt_title = title or "BetterGitBlame",
			finder = finders.new_table({
				results = commit_list,
				entry_maker = function(entry)
					-- trim hash to first 6 characters
					local trimmed_hash = string.sub(entry.hash, 1, 7)

					return {
						value = entry,
						display = string.format(
							"%s (%s %s) | %s | %s",
							trimmed_hash,
							entry.date,
							entry.time,
							entry.author,
							entry.message
						),
						ordinal = entry.date .. " " .. entry.time,
					}
				end,
			}),
			-- use generic_sorter with fuzzy matching
			sorter = sorters.get_generic_fuzzy_sorter({}),
			previewer = create_previewer(repo_root),
			layout_strategy = "horizontal",
			layout_config = {
				horizontal = {
					preview_width = 0.5,
				},
			},
			-- mappings
			attach_mappings = function(prompt_bufnr, map)
				-- local current_picker = action_state.get_current_picker(prompt_bufnr)

				-- default action: show diff of selected commit
				actions.select_default:replace(function()
					local current_sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					if current_sel and current_sel.value and current_sel.value.hash then
						local hash = current_sel.value.hash
						local file = current_sel.filename

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
				map({ "i", "n" }, "<C-b>", function()
					local current_sel = action_state.get_selected_entry()
					if current_sel and current_sel.value and current_sel.value.hash then
						git_utils.open_commit_in_browser(repo_root, current_sel.value.hash)
					else
						vim.notify(
							"No valid commit selected to open",
							vim.log.levels.WARN,
							{ title = "BetterGitBlame:OpenCommitInBrowser" }
						)
					end
				end)
				return true
			end,
		})
		:find()
end

return M
