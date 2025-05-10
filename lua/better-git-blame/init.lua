-- ~/.config/nvim/lua/better-git-blame/init.lua

local M = {}

local selection_utils = require("better-git-blame.selection")
local git_utils = require("better-git-blame.git")
local telescope_integration = require("better-git-blame.telescope")

telescope_integration.setup_dependencies(git_utils)

local current_state = {
    last_selection = nil,
    last_repo_root = nil,
    last_commit_list = nil,

    last_search_term = nil,
    last_search_type = nil,
}

-- function called from BlameInvestigate
-- line based search
function M.investigate_selection(args)
    -- get lines of visual selection
    local selection = selection_utils.get_visual_selection(args.line1, args.line2)
    if not selection then return end -- handled in get_visual_selection

    local repo_root = git_utils.find_git_repo_root(selection.file)
    if not repo_root then return end -- handled in find_git_repo_root

    -- update cached values for use in :BlameShowLast
    current_state.last_selection = selection
    current_state.last_repo_root = repo_root
    current_state.last_search_type = "line"


    git_utils.get_blame_commits(selection, repo_root, function(commit_list, err)
        if err then
            return
        end

        -- update cached commit list
        current_state.last_commits = commit_list
        local title = string.format("Git History (Lines %d - %d)", selection.start_line, selection.end_line)
        telescope_integration.launch_telescope_picker(commit_list, repo_root, selection, title)
    end)
end

function M.investigate_content(args)
    local selection, lines = selection_utils.get_visual_selection_content(args.line1, args.line2)


    local repo_root = git_utils.find_git_repo_root(selection.file)
    if not repo_root then return end -- handled in find_git_repo_root

    --local search_term, search_type = selection_utils.derive_regex_from_lines(lines)
    local search_term, search_type = selection_utils.derive_pickaxe_from_lines(lines)
    if not search_term or not search_type then
        return
    end

    print(search_type .. ": " .. search_term)

    -- update cached values for use in :BlameShowLast
    current_state.last_selection = selection
    current_state.last_repo_root = repo_root
    current_state.last_search_term = search_term
    current_state.last_search_type = search_type

    git_utils.get_commits_by_search_term(selection, repo_root, search_term, search_type, function(commit_list, err)
        if err then return end
        current_state.last_commit_list = commit_list

        local title = "Git History (Content Search)"
        telescope_integration.launch_telescope_picker(commit_list, repo_root, selection, title)
    end)
end

function M.show_last_investigation()
    if not current_state.last_selection or
        not current_state.last_repo_root or
        not current_state.last_commits then
        vim.notify("Not previous investigation stored.", vim.log.levels.WARN, { title="BetterGitBlame:BlameShowLast" })
        return
    end

    local title = ""

    if current_state.last_search_type == "line" then
        title = string.format("Git History (%d - %d)", selection.start_line, selection.end_line)
    end


    telescope_integration.launch_telescope_picker(current_state.last_commits, current_state.last_repo_root, current_state.last_selection, title)
end

function M.setup()
    --config = vim.tbl_deep_extend("force", config, user_config or {})

    vim.api.nvim_create_user_command("BlameInvestigate", M.investigate_selection, {
        range = true,
        desc = "Investigate Git history of selected code block (line-based)",
    })

    vim.api.nvim_create_user_command("BlameShowLast", M.show_last_investigation, {
        desc = "Show telescope picker of last investigation from BlameInvestigate",
    })

    vim.api.nvim_create_user_command("BlameInvestigateContent", M.investigate_content, {
        range = true,
        desc = "Investigate Git history for content similar to selection",
    })
end

return M
