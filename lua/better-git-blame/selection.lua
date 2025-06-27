-- lua/better-git-blame/selection.lua
--
local M = {}

local Path = require("plenary.path")
local ts_parsers = require("nvim-treesitter.parsers")
local ts_query = require("vim.treesitter.query")

local function_node_types = {
	["function_declaration"] = true,
	["function_definition_statement"] = true,
}

---Checks if a Treesitter node represents a function declaration/definition
---for the current buffer's language
---@param node userdata Treesitter node to check
---@return boolean True if node is a function type for the language
local function is_function_declaration_node(node, lang)
	if not node then
		return false
	end
	return function_node_types[node:type()]
end

---Escapes text to be used as a POSIX Extended Regular Expression (ERE)
---Escapes characters with special meaning in EREs
---Also converts sequences of spaces '\s+' to match one or more whitespace characters
---@param text string the text to escape
---@return string the escaped string
local function escape_posix_ere(text)
	if not text then
		return ""
	end

	-- escape posix and regex sequences for parsing line into regex
	-- git grep can read
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
	text = text:gsub("%s+", "\\s+")

	return text
end

---Get the current buffer's filename and the start/end lines of a visual selection
---@param start_line number starting line number of selection (1-based)
---@param end_line number ending line number of selection (1-based)
---@return table|nil vis_selection table { filename = string, start_line = number, end_line = number} or nil on error
function M.get_visual_selection(start_line, end_line)
	local file_path = vim.fn.expand("%:p")
	if not file_path or file_path == "" then
		vim.notify("No file name associated with buffer", vim.log.levels.WARN, { title = "BetterGitBlame" })
		return nil
	end

	-- handle backward selection
	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end

	return { filename = file_path, start_line = start_line, end_line = end_line }
end

---Gets visual selection details as well as the actual content of the selection
---@param start_line number starting line number of selection (1-based)
---@param end_line number ending line number of selection (1-based)
---@return table|nil vis_selection table { filename, start_line, end_line }
---@return table|nil lines of strings with selection lines or nil
function M.get_visual_selection_content(start_line, end_line)
	--- TODO move this get_visual_selection to calling function
	local vis_selection = M.get_visual_selection(start_line, end_line)

	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	if not lines then
		return nil, nil
	end

	return vis_selection, lines
end

---Derives a POSIX ERE regex from the longest non-empty trimmed line in the viusal selection
---@param lines table a list of strings (lines of text from buffer)
---@return string|nil derived regex string or nil if no suitable line is found
function M.derive_regex_from_lines(lines)
	if not lines then
		return nil
	end

	-- pick the longest line of the selection content
	local longest_line = ""
	if lines then
		for _, line in ipairs(lines) do
			local trimmed_line = vim.trim(line)
			if #trimmed_line > #longest_line then
				longest_line = trimmed_line
			end
		end
	end

	if longest_line == "" then
		return nil
	end

	local final_regex = escape_posix_ere(longest_line)
	if final_regex == "" or not final_regex then -- should not happen
		--fallback to pickaxe
		return nil
	end

	return final_regex
end

---Extracts function names from the current visual selection using Treesitter
---Attempts to find function definition nodes that intersect with selection
---If selection does no contain and function definition nodes, it will attempt to identify the closing function
---@param start_line number starting line number of selection (1-based)
---@param end_line number ending line number of selection (1-based)
---@return table|nil vis_selection table { filename, start_line, end_line }
---@return table|nil function_names list of unique function names strings or nil on error
function M.get_function_names_from_selection(start_line, end_line)
	local vis_selection = M.get_visual_selection(start_line, end_line)
	if not vis_selection then
		return nil, nil
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local parser = ts_parsers.get_parser(bufnr, vim.bo[bufnr].filetype)
	local tree = parser:parse()[1]
	local root = tree:root()

	-- to zero-based
	local target_start_line = vis_selection.start_line - 1
	local target_end_line = vis_selection.end_line - 1

	-- hacky but works if visual selection is only line of method declaration
	if target_start_line == target_end_line then
		target_end_line = target_end_line + 1
	end

	-- TODO move this query string to config somewhere else and work with other languages than lua
	local query_str = [[
        (function_declaration name: (identifier) @func_name)
        (function_declaration name: (dot_index_expression) @func_name)
    ]]

	local query = ts_query.parse(vim.bo.filetype, query_str)

	local current_node =
		root:descendant_for_range(target_start_line, target_end_line, target_start_line, target_end_line)

	if not current_node then
		print("Could not find node at selection start.")
		return nil, nil
	end

	-- getting parent function_declaration from selection text
	while current_node do
		if is_function_declaration_node(current_node) then
			local body_start_line, _, body_end_line, _ = current_node:range()

			if body_start_line < target_start_line then
				target_start_line = body_start_line
			end
			-- dont really need to update end
			if body_end_line > target_end_line then
				target_end_line = body_end_line
			end
		end
		current_node = current_node:parent()
	end

	local names = {}
	local name_set = {}

	for id, node, metadata in query:iter_captures(root, bufnr, target_start_line, target_end_line) do
		-- id and metadata unused for now, but they are options for later maybe
		local name = vim.treesitter.get_node_text(node, 0)
		if not name_set[name] then
			table.insert(names, name)
			name_set[name] = true
		end
	end

	return vis_selection, names
end

return M
