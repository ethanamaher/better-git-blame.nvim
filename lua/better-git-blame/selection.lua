-- lua/better-git-blame/selection.lua
--
local M = {}

local Path = require("plenary.path")

-- get the file, start_line, and end_line of visual selection
function M.get_visual_selection(start_line, end_line)
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

return M
