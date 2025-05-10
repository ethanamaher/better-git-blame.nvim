-- lua/better-git-blame/selection.lua
--
local M = {}

local Path = require("plenary.path")


local function escape_posix_ere(text)
    if not text then return "" end

    text = text:gsub("\\", "\\\\")
    text = text:gsub("%^", "\\^")
    text = text:gsub("%$", "\\$")
    text = text:gsub("%.", "\\.")
    text = text:gsub("%[", "\\[")
    text = text:gsub("%]", "\\]")
    text = text:gsub("%(", "\\(")
    text = text:gsub("%)", "\\)")
    text = text:gsub("%*", "\\*")
    text = text:gsub("%+", "\\+")
    text = text:gsub("%?", "\\?")
    text = text:gsub("{", "\\{")
    text = text:gsub("}", "\\}")
    text = text:gsub("|", "\\|")

    return text
end

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

function M.get_visual_selection_content(start_line, end_line)
    local vis_selection = M.get_visual_selection(start_line, end_line)

    local lines = vim.api.nvim_buf_get_lines(0, start_line-1, end_line, false)
    if not lines then
        return nil, nil
    end

    return vis_selection, lines
end

-- pick longest line from selection and use escape_posix_ere to create regex for it
-- a little more fuzzy than searching directly for string
function M.derive_regex_from_lines(lines)
    -- fallback to pickaxe
    if not lines then return nil end
    local longest_line = ""
    if lines then
        for _, line in ipairs(lines) do
            local trimmed_line = vim.trim(line)
            if trimmed_line ~= "" and #trimmed_line > #longest_line then
                longest_line = trimmed_line
            end
        end
    end

    if longest_line == "" then
        return nil
    end

    local longest_line_escaped = escape_posix_ere(longest_line)

    local final_regex = longest_line_escaped

    if final_regex == "" or not final_regex then
        --fallback to pickaxe
        return nil
    end

    return final_regex
end

return M
