-- lua/better-git-blame/git.lua

local M = {}

local Job = require("plenary.job")
local Path = require("plenary.path")

local format_arg = "--format=%H %ad %an %s"
local date_arg = "--date=format:%Y-%m-%d %H:%M:%S"

-- find git repo root
-- runs git rev-parse --show-toplevel from parent dir.
-- TODO check if current_path is file
-- if file do parent():absolute()
-- else for :absolute()
function M.find_git_repo_root(current_path)
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
-- put into table with each element.
-- must be used with hardcoded format and date arguments
--
-- --format=%H %ad %an %s
-- --date=format:%Y-%m-%d %H:%M:%S
function M.parse_git_log(output_lines)
    local commits = {}

    -- <hash> <date> <author> <subject>
    local pattern = "^([0-9a-f]+)%s+([%d-]+)%s+([%d:]+)%s+(.-)%s+(.*)$"

    for _, line in ipairs(output_lines) do
        local hash, date, time, author, message = line:match(pattern)
        if hash and date and time and author and message then
            table.insert(commits, {
                hash = hash,
                date = date,
                time = time,
                author = author,
                message = message, -- commit message (denoted subject from git log)
            })
        end
    end
    return commits
end

-- driver function for BlameInvestigateLines
-- git log -L<start>:<end>
-- output of git log is parsed into commit_list table and returned
function M.get_commits_by_line(selection, repo_root, callback)
    local current_path = Path:new(selection.file)
    local rel_file_path = current_path:make_relative(repo_root)
    if not rel_file_path then
        vim.notify("could not find relative file path", vim.log.levels.ERROR, { title="BetterGitBlame" })
        return
    end

    local log_range = string.format("%d,%d", selection.start_line, selection.end_line)
    local range_arg = "-L" .. log_range .. ":" .. rel_file_path

    -- git log -C <repo_root> -L "<start>,<end>:<relative_path>" --format="%H %ad %an %s" --date=short
    local git_args = { "-C", repo_root, "log", range_arg, format_arg, date_arg }

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

            local commit_list = M.parse_git_log(j:result())
            -- no commit list
            if #commit_list == 0 then
                vim.notify("No commits", vim.log.levels.WARN, { title="BetterGitBlame" })
                -- callback with empty list
            end
            callback(commit_list, nil)
        end),
    }):start()
end

-- driver function for BlameInvestigateContent
-- git log -G<regex>
-- output of git log is parsed into commit_list table and returned
function M.get_commits_by_search_term(selection, repo_root, search_term, callback)
    local current_path = Path:new(selection.file)
    local rel_file_path = current_path:make_relative(repo_root)
    if not rel_file_path then
        vim.notify("could not find relative file path", vim.log.levels.ERROR, { title="BetterGitBlame" })
        callback(nil, "Relative path error")
        return
    end

    local search_arg_option = "-G" .. search_term
    local search_description = "regex -G"

    local git_args = { "-C", repo_root, "log", search_arg_option, format_arg, date_arg, "--", rel_file_path }

    Job:new({
        command = "git",
        args = git_args,
        cwd = repo_root,
        on_exit = vim.schedule_wrap(function(j, return_val)
            local stderr_lines = j:stderr_result()
            local stderr = stderr_lines and table.concat(stderr_lines, "\n") or ""
            if return_val ~= 0 then
                vim.notify("git log %s failed: %s".. search_description, stderr, vim.log.levels.ERROR, { title="BetterGitBlame"})
                callback(nil, stderr)
                return
            end

            if stderr:match("fatal: ambiguous argument") or stderr:match("fatal: bad revision") or stderr:match("Invalid regular expression") then
                vim.notify("git log %s fatal error: %s".. search_description, stderr, vim.log.levels.ERROR, { title="BetterGitBlame"})
                callback(nil, stderr)
                return
            end

            local commit_list = M.parse_git_log(j:result())

            if #commit_list == 0 then
                vim.notify("No commits", vim.log.levels.WARN, { title="BetterGitBlame" })
                -- callback with empty list
            end
            callback(commit_list, nil)
        end),
    }):start()
end

-- driver function for BlameInvestigateFunction
-- git log -L:<func_name>:<filename>
-- output of git log is parsed into commit_list table and returned
function M.get_commits_by_func_name(selection, repo_root, function_names, callback)
    -- relative file path for git log arg
    local current_path = Path:new(selection.file)
    local rel_file_path = current_path:make_relative(repo_root)
    if not rel_file_path then
        vim.notify("could not find relative file path", vim.log.levels.ERROR, { title="BetterGitBlame" })
        return
    end

    local commit_list = {}
    local commit_list_set = {}

    for _, function_name in ipairs(function_names) do
        local range_arg = "-L:" .. function_name .. ":" .. rel_file_path

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

                local commit_list_function = M.parse_git_log(j:result()) -- should never be nil
                for _, commit in ipairs(commit_list_function) do
                    if not commit_list_set[commit.hash] then
                        table.insert(commit_list, commit)
                        commit_list_set[commit.hash] = true
                    else
                        vim.notify("Not insert hash: " .. commit.hash, vim.log.levels.INFO, { title="BetterGirBlame:BlameInvestigateFunction" })
                    end
                end

                -- no commit list
                if #commit_list_function == 0 then
                    vim.notify("No commits", vim.log.levels.WARN, { title="BetterGitBlame" })
                    -- callback with empty list
                end

                callback(commit_list, nil)
            end),
        }):start()
    end
end

-- used for getting diff output from commit hash
-- git show <hash>
function M.get_commit_details(repo_root, commit_hash, callback)
    local diff_args = { "show", commit_hash }

    local diff_output = {}
    local error_output = {}
    local exit_code = -1

    -- git show <hash>
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

-- parse a remote url from get_git_remote_url
-- should work for both ssh and https urls
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

function M.open_commit_in_browser(repo_root, commit_hash)
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

    -- TODO support other hosts
    if host:find("github.com") then
        commit_url = string.format("https://%s/%s/commit/%s", host, path, commit_hash)
    else
        vim.notify("Unsupported git host: " .. parsed_url.host, vim.log.levels.WARN, { title="BetterGitBlame:OpenCommitInBrowser" })
        return
    end

    -- use xdg-open to open the commit url in default browser
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

return M
