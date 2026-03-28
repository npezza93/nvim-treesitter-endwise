local M = {}
local indent_regex = vim.regex('\\v^\\s*\\zs\\S')
local tracking = {}
-- compatibility shim for breaking change on nightly/0.11
local opts = vim.fn.has("nvim-0.10") == 1 and { force = true, all = false } or true

local function tabstr()
    if vim.bo.expandtab then
        return string.rep(" ", vim.fn.shiftwidth())
    else
        return "	"
    end
end

local function text_for_range(range)
    local srow, scol, erow, ecol = unpack(range)
    if srow == erow then
        return string.sub(vim.fn.getline(srow + 1), scol + 1, ecol)
    else
        return string.sub(vim.fn.getline(srow + 1), scol + 1, -1) .. string.sub(vim.fn.getline(erow + 1), 1, ecol)
    end
end

local function point_in_range(row, col, range)
    return not (row < range[1] or row == range[1] and col < range[2]
        or row > range[3] or row == range[3] and col >= range[4])
end

local function strip_leading_whitespace(line)
    local indent_end = indent_regex:match_str(line)
    if indent_end then
        local indentation = string.sub(line, 0, indent_end)
        local text = string.sub(line, indent_end + 1)
        return indentation, text
    else
        return line, ''
    end
end

local function find_child(node, wanted_type)
    for child in node:iter_children() do
        if child:type() == wanted_type then
            return child
        end
    end
end

local function find_smallest_matching_node(node, row, col, wanted)
    local node_range = { node:range() }
    if not point_in_range(row, col, node_range) then
        return nil
    end

    for child in node:iter_children() do
        local match = find_smallest_matching_node(child, row, col, wanted)
        if match then
            return match
        end
    end

    if wanted[node:type()] then
        return node
    end
end

local function unpack_match(match, query)
    local indent_node, cursor_node, endable_node
    for id, node in pairs(match) do
        if type(node) == 'table' then
            node = node[#node]
        end

        if query.captures[id] == 'indent' then
            indent_node = node
        elseif query.captures[id] == 'cursor' then
            cursor_node = node
        elseif query.captures[id] == 'endable' then
            endable_node = node
        end
    end

    return indent_node, cursor_node, endable_node
end

local function build_end_text(metadata, source)
    local end_text = metadata.endwise_end_text
    if metadata.endwise_end_suffix then
        local suffix = vim.treesitter.get_node_text(metadata.endwise_end_suffix, source)
        local s, e = vim.regex(metadata.endwise_end_suffix_pattern):match_str(suffix)
        if s then
            suffix = string.sub(suffix, s + 1, e)
        end
        end_text = end_text .. suffix
    end

    return end_text
end

local function last_non_whitespace_pos(text)
    local lines = vim.split(text, '\n', { plain = true })
    for row = #lines, 1, -1 do
        local stripped = lines[row]:match('^(.*%S)')
        if stripped then
            return row - 1, #stripped - 1
        end
    end

    return 0, 0
end

local function string_lacks_end(node, end_text)
    local end_node = node:child(node:child_count() - 1)
    if end_node == nil then
        return true
    end
    if end_node:type() ~= end_text then
        return false
    end

    return end_node:missing()
end

local function lua_pesc(text)
    return (text:gsub('([^%w])', '%%%1'))
end

local function erb_end_text(directive, end_text, bufnr)
    local first = directive:child(0)
    local last = directive:child(directive:child_count() - 1)
    local open_text = first and vim.treesitter.get_node_text(first, bufnr) or '<%'
    local close_text = last and vim.treesitter.get_node_text(last, bufnr) or '%>'
    open_text = open_text:gsub('=', '')
    return open_text .. ' ' .. end_text .. ' ' .. close_text
end

local function erb_has_closing_directive_after(directive, end_text, bufnr)
    local directive_range = { directive:range() }
    local start_row = directive_range[1] + 1
    local indentation = strip_leading_whitespace(vim.fn.getline(start_row))
    local pattern = '^%s*<%%[-_]?%s*' .. lua_pesc(end_text) .. '%s*[-_]?%%>%s*$'
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for lnum = start_row + 1, line_count do
        local line = vim.fn.getline(lnum)
        if not line:match('^%s*$') then
            local current_indent = strip_leading_whitespace(line)
            if #current_indent < #indentation then
                return false
            end
            if current_indent == indentation and line:match(pattern) then
                return true
            end
            if current_indent == indentation then
                return false
            end
        end
    end

    return false
end

local function lacks_end(node, end_text)
    local end_node = node:child(node:child_count() - 1)
    if end_node == nil then
        return true
    end
    if end_node:type() ~= end_text then
        return false
    end
    if end_node:missing() then
        return true
    end

    local node_range = { node:range() }
    local indentation = strip_leading_whitespace(vim.fn.getline(node_range[1] + 1))
    local end_node_range = { end_node:range() }
    local end_node_indentation = strip_leading_whitespace(vim.fn.getline(end_node_range[1] + 1))
    local crow = unpack(vim.api.nvim_win_get_cursor(0))
    if indentation == end_node_indentation or end_node_range[3] == crow - 1 then
        return false
    end

    local parent = node:parent()
    while parent ~= nil do
        if parent:has_error() then
            return true
        end
        parent = parent:parent()
    end
    return false
end

local function add_end_node(indent_node_range, endable_node_range, end_text, shiftcount)
    local crow = unpack(vim.api.nvim_win_get_cursor(0))
    local indentation = strip_leading_whitespace(vim.fn.getline(indent_node_range[1] + 1))

    local line = vim.fn.getline(crow)
    local trailing_cursor_text, trailing_end_text
    if endable_node_range == nil or crow - 1 < endable_node_range[3] then
        local _, trailing_text = strip_leading_whitespace(line)
        if string.match(trailing_text, "^[%a%d]") then
            trailing_cursor_text = trailing_text
            trailing_end_text = ""
        else
            trailing_end_text = trailing_text
            trailing_cursor_text = ""
        end
    elseif crow - 1 == endable_node_range[3] then
        _, trailing_cursor_text = strip_leading_whitespace(string.sub(line, 1, endable_node_range[4]))
        _, trailing_end_text = strip_leading_whitespace(string.sub(line, endable_node_range[4] + 1, -1))
    else
        trailing_cursor_text = ""
        _, trailing_end_text = strip_leading_whitespace(line)
    end

    local cursor_indentation = indentation .. string.rep(tabstr(), shiftcount)

    vim.fn.setline(crow, cursor_indentation .. trailing_cursor_text)
    vim.fn.append(crow, indentation .. end_text .. trailing_end_text)
    vim.fn.cursor(crow, #cursor_indentation + 1)
end

local function endwise_embedded_template(bufnr, row, col)
    local parser = vim.treesitter.get_parser(bufnr, 'embedded_template', { error = false })
    if not parser then
        return false
    end

    local tree = parser:parse()[1]
    if not tree then
        return false
    end

    local root = tree:root()
    if not root then
        return false
    end

    local directive = find_smallest_matching_node(root, row, col, {
        directive = true,
        output_directive = true,
    })
    if not directive then
        return false
    end

    local code_node = find_child(directive, 'code')
    if not code_node then
        return false
    end

    local code = vim.trim(vim.treesitter.get_node_text(code_node, bufnr))
    if code == '' then
        return false
    end

    local ruby_query = vim.treesitter.query.get('ruby', 'endwise')
    if not ruby_query then
        return false
    end

    local ruby_parser = vim.treesitter.get_string_parser(code, 'ruby')
    local ruby_root = ruby_parser:parse()[1]:root()
    local ruby_row, ruby_col = last_non_whitespace_pos(code)

    for _, match, metadata in ruby_query:iter_matches(ruby_root, code, 0, -1, { all = true }) do
        local _, cursor_node, endable_node = unpack_match(match, ruby_query)
        if cursor_node and point_in_range(ruby_row, ruby_col, { cursor_node:range() }) then
            local end_node_type = metadata.endwise_end_node_type or metadata.endwise_end_text
            if (not endable_node or string_lacks_end(endable_node, end_node_type)) then
                local inner_end_text = build_end_text(metadata, code)
                if erb_has_closing_directive_after(directive, inner_end_text, bufnr) then
                    return false
                end
                add_end_node({ directive:range() }, nil, erb_end_text(directive, inner_end_text, bufnr), metadata.endwise_shiftcount)
                return true
            end
        end
    end

    return false
end

local function endwise(bufnr)
    local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype or '')
    if lang == 'eruby' or lang == 'erb' then
        lang = 'embedded_template'
    end
    if not lang then
        return
    end

    local parser, _ = vim.treesitter.get_parser(bufnr, lang, { error = false })
    if not parser then
        return
    end

    -- Search up the first the closest non-whitespace text before the cursor
    local row, col = unpack(vim.fn.searchpos('\\S', 'nbW'))
    row = row - 1
    col = col - 1

    if lang == 'embedded_template' and endwise_embedded_template(bufnr, row, col) then
        return
    end

    local lang_tree = parser:language_for_range({ row, col, row, col })
    lang = lang_tree:lang()
    if not lang then
        return
    end


    local node = vim.treesitter.get_node({
        bufnr = bufnr,
        lang = lang,
        pos = { row, col },
        ignore_injections = true,
    })
    if not node then
        return
    end

    local root = node:tree():root()
    if not root then
        return
    end

    local query = vim.treesitter.query.get(lang, 'endwise')
    if not query then
        return
    end

    local range = { root:range() }

    for _, match, metadata in query:iter_matches(root, bufnr, range[1], range[3] + 1, { all = true }) do
        local indent_node, cursor_node, endable_node = unpack_match(match, query)

        local indent_node_range = { indent_node:range() }
        local cursor_node_range = { cursor_node:range() }
        if point_in_range(row, col, cursor_node_range) then
            local end_node_type = metadata.endwise_end_node_type or metadata.endwise_end_text
            if not endable_node or lacks_end(endable_node, end_node_type) then
                local end_text = build_end_text(metadata, bufnr)
                local endable_node_range = endable_node and { endable_node:range() } or nil
                add_end_node(indent_node_range, endable_node_range, end_text, metadata.endwise_shiftcount)
                return
            end
        end
    end
end

-- #endwise! tree-sitter directive
-- @param endwise_end_text string end text to add
-- @param endwise_end_suffix node|nil captured node that contains text to add
--  as a suffix to the end text. E.g. In vimscript, `func` will be ended with
--  `endfunc` and `function` will be ended with `endfunction` even though they
--  are parsed the same. nil to always use endwise_end_text.
-- @param endwise_end_node_type string|nil node type to check against the last
--  child of the @endable captured node. This is required because the
--  endwise_end_text won't match the nodetype if it's dynamic for langauges like
--  vimscript. nil to use endwise_end_text as the node type.
-- @param endwise_shiftcount number a non-negative number of shifts to indent with,
--  defaults to 1
-- @param endwise_end_suffix_pattern string regex pattern to apply onto
--  endwise_end_suffix, defaults to matching the whole string
vim.treesitter.query.add_directive('endwise!', function(match, _, _, predicate, metadata)
    metadata.endwise_end_text = predicate[2]
    metadata.endwise_end_suffix = match[predicate[3]]
    metadata.endwise_end_node_type = predicate[4]
    metadata.endwise_shiftcount = predicate[5] or 1
    metadata.endwise_end_suffix_pattern = predicate[6] or '^.*$'
end, opts)

vim.on_key(function(key)
    if key ~= "\r" then return end
    if vim.api.nvim_get_mode().mode ~= 'i' then return end
    if vim.fn.reg_executing() ~= '' or vim.fn.reg_recording() ~= '' then
        return
    end
    vim.schedule_wrap(function()
        local bufnr = vim.fn.bufnr()
        if not tracking[bufnr] then return end
        vim.cmd('doautocmd User PreNvimTreesitterEndwiseCR')  -- Not currently used
        endwise(bufnr)
        vim.cmd('doautocmd User PostNvimTreesitterEndwiseCR') -- Used in tests to know when to exit Neovim
    end)()
end, nil)

function M.attach(bufnr)
    tracking[bufnr] = true
end

function M.detach(bufnr)
    tracking[bufnr] = false
end

return M
