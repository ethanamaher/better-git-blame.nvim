-- ~/.config/nvim/lua/better-git-blame/init.lua

local M = {}

local selection_utils = require("better-git-blame.selection")
local git_utils = require("better-git-blame.git")
local telescope_integration = require("better-git-blame.telescope")

telescope_integration.setup_dependencies(git_utils)

-- used to store state of last commit_list and the information used to get it
local current_state = {
    last_selection = nil,
    last_repo_root = nil,
    last_commit_list = nil,
    last_search_term = nil,
}

-- function for :BlameInvestigateLines
function M.investigate_lines(args)
    -- get lines of visual selection
    local selection = selection_utils.get_visual_selection(args.line1, args.line2)
    if not selection then return end -- handled in get_visual_selection

    local repo_root = git_utils.find_git_repo_root(selection.file)
    if not repo_root then return end -- handled in find_git_repo_root

    -- update cached values for use in :BlameShowLast
    current_state.last_selection = selection
    current_state.last_repo_root = repo_root
    current_state.last_search_term = nil

    git_utils.get_commits_by_line(selection, repo_root, function(commit_list, err)
        if err then
            return
        end

        -- update cached commit list
        current_state.last_commits = commit_list
        local title = string.format("Git History (Lines %d - %d)", selection.start_line, selection.end_line)
        telescope_integration.launch_telescope_picker(commit_list, repo_root, selection, title)
    end)
end

-- function for :BlameInvestigateContent
function M.investigate_content(args)
    local selection, lines = selection_utils.get_visual_selection_content(args.line1, args.line2)
    if not selection then return end

    local repo_root = git_utils.find_git_repo_root(selection.file)
    if not repo_root then return end -- handled in find_git_repo_root

    local search_term = selection_utils.derive_regex_from_lines(lines)

    -- update cached values for use in :BlameShowLast
    current_state.last_selection = selection
    current_state.last_repo_root = repo_root
    current_state.last_search_term = search_term

    git_utils.get_commits_by_search_term(selection, repo_root, search_term, function(commit_list, err)
        if err then return end
        current_state.last_commit_list = commit_list

        local title = "Git History (Content Search)"
        telescope_integration.launch_telescope_picker(commit_list, repo_root, selection, title)
    end)
end

-- function for :BlameShowLast
function M.show_last_investigation()
    if not current_state.last_selection or
        not current_state.last_repo_root or
        not current_state.last_commits then
        vim.notify("Not previous investigation stored.", vim.log.levels.WARN, { title="BetterGitBlame:BlameShowLast" })
        return
    end
    local title = string.format("Git History (%d - %d)", current_state.last_selection.start_line, current_state.last_selection.end_line)

    telescope_integration.launch_telescope_picker(current_state.last_commits, current_state.last_repo_root, current_state.last_selection, title)
end

-- function for :BlameInvestigateFunction
function M.investigate_function_names(args)
    local selection, func_names = selection_utils.get_function_names_from_selection(args.line1, args.line2)
    if not selection then return end

    local repo_root = git_utils.find_git_repo_root(selection.file)
    if not repo_root then return end -- handled in find_git_repo_root

    current_state.last_selection = selection
    current_state.last_repo_root = repo_root
    current_state.last_search_term = nil

    git_utils.get_commits_by_func_name(selection, repo_root, func_names, function(commit_list, err)
        if err then return end
        current_state.last_commit_list = commit_list

        local title = string.format("Git History (function search)")
        telescope_integration.launch_telescope_picker(commit_list, repo_root, selection, title)
    end)
end

-- setup all commands for BetterGitBlame
function M.setup()
    --config = vim.tbl_deep_extend("force", config, user_config or {})

    vim.api.nvim_create_user_command("BlameInvestigatLines", M.investigate_lines, {
        range = true,
        desc = "Investigate Git history of selected code block by visually selecting lines. git log -L<start_line>:<end_line>",
    })

    vim.api.nvim_create_user_command("BlameShowLast", M.show_last_investigation, {
        desc = "Show telescope picker of last investigation from BlameInvestigate",
    })

    vim.api.nvim_create_user_command("BlameInvestigateContent", M.investigate_content, {
        range = true,
        desc = "Investigate Git history for content similar to selection. git log -G<regex_string>",
    })

    vim.api.nvim_create_user_command("BlameInvestigateFunction", M.investigate_function_names, {
        range = true,
        desc = "Investigate git history by identifying function names in selected code block. git log -L:<func_name>:<file_name>",
    })
end

return M
