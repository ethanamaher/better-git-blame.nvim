-- lua/better-git-blame/selection.lua
--
local M = {}

local Path = require("plenary.path")
local ts_parsers = require("nvim-treesitter.parsers")
local ts_query = require("vim.treesitter.query")

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
    text = text:gsub(" ", "\\s+")

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
        start_line, end_line = end_line, start_line
    end

    return { file = file_path, start_line = start_line, end_line = end_line }
end

-- get the file, start_line, and end_line for the visual selection and the actual lines for that selection
function M.get_visual_selection_content(start_line, end_line)
    local vis_selection = M.get_visual_selection(start_line, end_line)
    -- check

    local lines = vim.api.nvim_buf_get_lines(0, start_line-1, end_line, false)
    if not lines then return nil, nil end

    return vis_selection, lines
end

-- pick longest line from selection and use escape__posix_ere to create regex for it
-- a little more fuzzy than searching directly for string
function M.derive_regex_from_lines(lines)
    if not lines then return nil end

    -- pick the longest line of the selection content
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

    local final_regex = escape_posix_ere(longest_line)

    if final_regex == "" or not final_regex then
        --fallback to pickaxe
        return nil
    end

    return final_regex
end

-- get the file, start_line, and end_line for the visual selection and a list of function names in the selection
-- TODO if no function names in selection, try and traverse up tree to find what function we are in.
--      if not in function then return empty list
function M.get_function_names_from_selection(start_line, end_line)
    local vis_selection = M.get_visual_selection(start_line, end_line)
    if not vis_selection then return nil, nil end

    local bufnr = vim.api.nvim_get_current_buf()
    local parser = ts_parsers.get_parser(bufnr, vim.bo.filetype)
    local tree = parser:parse()[1]
    local root = tree:root()

    -- to zero-based
    local target_start_line = vis_selection.start_line - 1
    local target_end_line = vis_selection.end_line - 1

    -- hacky but works if visual selection is only line of method declaration
    if target_start_line == target_end_line then
        target_end_line = target_end_line+1
    end

    -- TODO move this query string to config somewhere else and work with other languages than lua
    local query_str = [[
        (function_declaration name: (identifier) @func_name)
        (function_declaration name: (dot_index_expression) @func_name)
    ]]

    local query = ts_query.parse(vim.bo.filetype, query_str)

    local names = {}
    local name_set = {}

    for id, node, metadata in query:iter_captures(root, bufnr, target_start_line, target_end_line) do
        -- id and metadata unused for now, but they exist
        local name = vim.treesitter.get_node_text(node, 0)
        if not name_set[name] then
            table.insert(names, name)
            name_set[name] = true
        end
    end

    return vis_selection, names
end

return M
