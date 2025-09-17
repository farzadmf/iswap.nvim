local util = require('iswap.util')
local err = util.err

local ft_to_lang = require('nvim-treesitter.parsers').ft_to_lang

local M = {}

-- Helper function to get named children of a node
local function get_named_children(node)
  local children = {}
  for child in node:iter_children() do
    if child:named() then
      table.insert(children, child)
    end
  end
  return children
end

-- Helper function to get node at cursor position
local function get_node_at_cursor(winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row, col = cursor[1] - 1, cursor[2]
  local ft = vim.bo[bufnr].filetype
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local root = vim.treesitter.get_parser(bufnr, lang):parse()[1]:root()
  return root:descendant_for_range(row, col, row, col)
end

-- Helper function to swap two nodes or ranges in the buffer
local function swap_nodes(node_or_range1, node_or_range2, bufnr)
  local start_row1, start_col1, end_row1, end_col1
  local start_row2, start_col2, end_row2, end_col2

  -- Handle both nodes and ranges
  if type(node_or_range1) == "table" and #node_or_range1 == 4 then
    -- It's a range
    start_row1, start_col1, end_row1, end_col1 = unpack(node_or_range1)
  else
    -- It's a node
    start_row1, start_col1, end_row1, end_col1 = node_or_range1:range()
  end

  if type(node_or_range2) == "table" and #node_or_range2 == 4 then
    -- It's a range
    start_row2, start_col2, end_row2, end_col2 = unpack(node_or_range2)
  else
    -- It's a node
    start_row2, start_col2, end_row2, end_col2 = node_or_range2:range()
  end

  local text1 = vim.api.nvim_buf_get_text(bufnr, start_row1, start_col1, end_row1, end_col1, {})
  local text2 = vim.api.nvim_buf_get_text(bufnr, start_row2, start_col2, end_row2, end_col2, {})

  -- Replace the second node first (to avoid offset issues)
  if start_row1 < start_row2 or (start_row1 == start_row2 and start_col1 < start_col2) then
    vim.api.nvim_buf_set_text(bufnr, start_row2, start_col2, end_row2, end_col2, text1)
    vim.api.nvim_buf_set_text(bufnr, start_row1, start_col1, end_row1, end_col1, text2)
  else
    vim.api.nvim_buf_set_text(bufnr, start_row1, start_col1, end_row1, end_col1, text2)
    vim.api.nvim_buf_set_text(bufnr, start_row2, start_col2, end_row2, end_col2, text1)
  end
end

-- certain lines of code below are taken from nvim-treesitter where i
-- had to modify the function body of an existing function in ts_utils

--
function M.find(winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local cursor_range = { cursor[1] - 1, cursor[2] }
  local row = cursor_range[1]
  -- NOTE: this root is freshly parsed, but this may not be the best way of getting a fresh parse
  --       see :h Query:iter_captures()
  local ft = vim.bo[bufnr].filetype
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local root = vim.treesitter.get_parser(bufnr, lang):parse()[1]:root()
  local q = vim.treesitter.query.get(lang, 'iswap-list')
  -- TODO: initialize correctly so that :ISwap is not callable on unsupported
  -- languages, if that's possible.
  if not q then
    err('Cannot query this filetype', true)
    return
  end
  return q:iter_captures(root, bufnr, row, row + 1)
end

-- Get the closest parent that can be used as a list wherein elements can be
-- swapped.
-- needs_cursor_node is a boolean indicating whether we require that the cursor
-- be on a named child of the list node
-- this also returns the cursor node index
function M.get_list_node_at_cursor(winid, config, needs_cursor_node)
  local ret = nil
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local cursor_range = { cursor[1] - 1, cursor[2] }
  local iswap_list_captures = M.find(winid)
  if not iswap_list_captures then
    -- query not supported
    return
  end
  for id, node, metadata in iswap_list_captures do
    err('found node', config.debug)
    local start_row, start_col, end_row, end_col = node:range()
    local start = { start_row, start_col }
    local end_ = { end_row, end_col }
    if util.within(start, cursor_range, end_) and node:named_child_count() > 1 then
      local children = get_named_children(node)
      if needs_cursor_node then
        local cur_nodes = util.nodes_containing_cursor(children, winid)
        if #cur_nodes >= 1 then
          if #cur_nodes > 1 then
            err("multiple found, using first", config.debug)
          end
          ret = { node, children, cur_nodes[1] }
        end
      else
        ret = { node, children }
      end
    end
  end
  err('completed', config.debug)
  if ret then
    return unpack(ret)
  end
end

local function node_or_range_get_text(node_or_range, bufnr)
  local bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not node_or_range then return {} end

  -- We have to remember that end_col is end-exclusive
  local start_row, start_col, end_row, end_col = vim.treesitter.get_node_range(node_or_range)

  if end_col == 0 then
    if start_row == end_row then
      start_col = -1
      start_row = start_row - 1
    end
    end_col = -1
    end_row = end_row - 1
  end
  return vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
end

-- node 'a' is the one the cursor is on
function M.swap_nodes_and_return_new_ranges(a, b, bufnr, should_move_cursor)
  return M.swap_ranges_and_return_new_ranges({ a:range() }, { b:range() }, bufnr, should_move_cursor)
end
function M.swap_ranges_and_return_new_ranges(a, b, bufnr, should_move_cursor)
  local winid = vim.api.nvim_get_current_win()

  local a_sr, a_sc = unpack(a)
  local b_sr, b_sc = unpack(b)
  local c_r, c_c

  -- #64: note cursor position before swapping
  local cursor_delta
  if should_move_cursor then
    local cursor = vim.api.nvim_win_get_cursor(winid)
    c_r, c_c = unpack { cursor[1] - 1, cursor[2] }
    cursor_delta = { c_r - a_sr, c_c - a_sc }
  end

  -- [1] first appearing node should be `a`, so swap for convenience
  local HAS_SWAPPED = false
  if not util.compare_position({ a_sr, a_sc }, { b_sr, b_sc }) then
    a, b = b, a
    HAS_SWAPPED = true
  end

  local a_sr, a_sc, a_er, a_ec = unpack(a)
  local b_sr, b_sc, b_er, b_ec = unpack(b)

  local text1 = node_or_range_get_text(a, bufnr)
  local text2 = node_or_range_get_text(b, bufnr)

  swap_nodes(a, b, bufnr)

  local char_delta = 0
  local line_delta = 0
  if a_er < b_sr or (a_er == b_sr and a_ec <= b_sc) then line_delta = #text2 - #text1 end

  if a_er == b_sr and a_ec <= b_sc then
    if line_delta ~= 0 then
      --- why?
      --correction_after_line_change =  -b_sc
      --text_now_before_range2 = #(text2[#text2])
      --space_between_ranges = b_sc - a_ec
      --char_delta = correction_after_line_change + text_now_before_range2 + space_between_ranges
      --- Equivalent to:
      char_delta = #text2[#text2] - a_ec

      -- add a_sc if last line of range1 (now text2) does not start at 0
      if a_sr == b_sr + line_delta then char_delta = char_delta + a_sc end
    else
      char_delta = #text2[#text2] - #text1[#text1]
    end
  end

  -- now let a = first one (text2), b = second one (text1)
  -- (opposite of what it used to be)

  local _a_sr = a_sr
  local _a_sc = a_sc
  local _a_er = a_sr + #text2 - 1
  local _a_ec = (#text2 > 1) and #text2[#text2] or a_sc + #text2[#text2]
  local _b_sr = b_sr + line_delta
  local _b_sc = b_sc + char_delta
  local _b_er = b_sr + #text1 - 1
  local _b_ec = (#text1 > 1) and #text1[#text1] or b_sc + #text1[#text1]

  local a_data = { _a_sr, _a_sc, _a_er, _a_ec }
  local b_data = { _b_sr, _b_sc, _b_er, _b_ec }

  -- undo [1]'s swapping
  if HAS_SWAPPED then
    a_data, b_data = b_data, a_data
  end

  if should_move_cursor then
    -- cursor offset depends on whether it is affected by the node start position
    local c_to_c = (#text2 > 1 and cursor_delta[1] ~= 0) and c_c or b_data[2] + cursor_delta[2]
    vim.api.nvim_win_set_cursor(winid, { b_data[1] + 1 + cursor_delta[1], c_to_c })
  end

  return { a_data, b_data }
end

function M.move_node_to_index(children, cur_node_idx, a_idx, config)
  local bufnr = vim.api.nvim_get_current_buf()
  if a_idx == cur_node_idx + 1 or a_idx == cur_node_idx - 1 then
    -- This means the node is adjacent, swap and move are equivalent
    return M.swap_nodes_and_return_new_ranges(children[cur_node_idx], children[a_idx], bufnr, config.move_cursor)
  end

  local children_ranges = vim.tbl_map(function(node) return { node:range() } end, children)
  local cur_range = children_ranges[cur_node_idx]

  local incr = (cur_node_idx < a_idx) and 1 or -1
  for i = cur_node_idx + incr, a_idx, incr do
    local _, b_range =
      unpack(M.swap_ranges_and_return_new_ranges(cur_range, children_ranges[i], bufnr, config.move_cursor))
    cur_range = b_range
  end

  return { cur_range }
end

function M.attach(bufnr, lang)
  -- TODO: Fill this with what you need to do when attaching to a buffer
end

function M.detach(bufnr)
  -- TODO: Fill this with what you need to do when detaching from a buffer
end

-- Export helper functions
M.get_named_children = get_named_children
M.get_node_at_cursor = get_node_at_cursor

return M
