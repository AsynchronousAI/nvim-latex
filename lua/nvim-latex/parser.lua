local M = {}

--- Map index in text node to buffer (row, col)
local function index_to_pos(text, sr, sc, idx)
  local cur_row = sr
  local cur_col = sc
  for i = 1, idx - 1 do
    local b = text:byte(i)
    if b == 10 then -- newline
      cur_row = cur_row + 1
      cur_col = 0
    else
      cur_col = cur_col + 1
    end
  end
  return cur_row, cur_col
end

--- Extract LaTeX formulas from a comment string
local function extract_from_comment(text, sr, sc, bufnr)
  local items = {}
  local occupied = {}

  -- 1. Multiblock math: $$ ... $$
  local init = 1
  while true do
    local s, e, content = text:find("%$%$%s*(.-)%s*%$%$", init)
    if not s then
      break
    end
    local start_r, start_c = index_to_pos(text, sr, sc, s)
    local end_r, end_c = index_to_pos(text, sr, sc, e + 1)
    table.insert(items, {
      bufnr = bufnr,
      type = "block",
      formula = content,
      range = { start_r, start_c, end_r, end_c },
      is_comment = true,
      raw = text:sub(s, e),
    })
    for i = s, e do
      occupied[i] = true
    end
    init = e + 1
  end

  -- 2. Inline math: $ ... $ (avoiding $$)
  init = 1
  while true do
    local s, e, content = text:find("%$([^$\n]+)%$", init)
    if not s then
      break
    end
    local char_before = s > 1 and text:sub(s - 1, s - 1) or ""
    local char_after = e < #text and text:sub(e + 1, e + 1) or ""
    if char_before ~= "$" and char_after ~= "$" and char_before ~= "\\" and not occupied[s] then
      local start_r, start_c = index_to_pos(text, sr, sc, s)
      local end_r, end_c = index_to_pos(text, sr, sc, e + 1)
      table.insert(items, {
        bufnr = bufnr,
        type = "inline",
        formula = content,
        range = { start_r, start_c, end_r, end_c },
        is_comment = true,
        raw = text:sub(s, e),
      })
    end
    init = e + 1
  end

  return items
end

--- Parse code files using built-in Tree-sitter comment captures
---@param bufnr number
---@return table[] items List of formula records
function M.parse_comments_treesitter(bufnr)
  local ft = vim.bo[bufnr].filetype
  -- Map filetypes if necessary (e.g. cpp can fall back to c parser)
  local lang = ft
  if lang == "cpp" then
    lang = "cpp"
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    -- Try fallback to 'c' parser for C/C++
    if ft == "cpp" or ft == "c" then
      ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c")
    end
  end

  if not ok or not parser then
    return M.parse_comments_regex(bufnr)
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    return {}
  end

  local root = trees[1]:root()
  local query_str = "((comment) @comment)"
  local q_ok, query = pcall(vim.treesitter.query.parse, lang, query_str)
  if not q_ok or not query then
    -- Try c query
    q_ok, query = pcall(vim.treesitter.query.parse, "c", query_str)
  end

  if not q_ok or not query then
    return M.parse_comments_regex(bufnr)
  end

  local all_items = {}
  for _, node in query:iter_captures(root, bufnr, 0, -1) do
    if type(node) == "table" and not getmetatable(node) then
      node = node[1]
    end
    if node and type(node.range) == "function" then
      local sr, sc, er, ec = node:range()
      local text = vim.treesitter.get_node_text(node, bufnr)
      local items = extract_from_comment(text, sr, sc, bufnr)
      for _, item in ipairs(items) do
        table.insert(all_items, item)
      end
    end
  end

  return all_items
end

--- Fallback line-by-line scanner for comments if treesitter is not ready
---@param bufnr number
---@return table[] items
function M.parse_comments_regex(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_items = {}

  for r = 0, #lines - 1 do
    local line = lines[r + 1]
    -- Single line comments //
    local comment_start = line:find("//")
    if comment_start then
      local comment_text = line:sub(comment_start)
      local items = extract_from_comment(comment_text, r, comment_start - 1, bufnr)
      for _, it in ipairs(items) do
        table.insert(all_items, it)
      end
    end
  end

  return all_items
end

--- Parse Markdown files
---@param bufnr number
---@return table[] items
function M.parse_markdown(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_code_fence = false
  local items = {}

  local r = 0
  while r < #lines do
    local line = lines[r + 1]
    local trimmed = vim.trim(line)

    if trimmed:sub(1, 3) == "```" or trimmed:sub(1, 3) == "~~~" then
      in_code_fence = not in_code_fence
      r = r + 1
    elseif in_code_fence then
      r = r + 1
    else
      -- Multiline block $$ ... $$
      if trimmed == "$$" or (trimmed:sub(1, 2) == "$$" and trimmed:sub(-2) ~= "$$") then
        local block_start_r = r
        local block_lines = {}
        r = r + 1
        while r < #lines do
          local cur_line = lines[r + 1]
          if vim.trim(cur_line):sub(1, 2) == "$$" then
            break
          end
          table.insert(block_lines, cur_line)
          r = r + 1
        end
        local block_end_r = math.min(r, #lines - 1)
        local content = table.concat(block_lines, "\n")
        table.insert(items, {
          bufnr = bufnr,
          type = "block",
          formula = content,
          range = { block_start_r, 0, block_end_r, #lines[block_end_r + 1] },
          is_comment = false,
        })
        r = r + 1
      else
        -- Single-line block $$ ... $$
        local init = 1
        local occupied = {}
        while true do
          local s, e, content = line:find("%$%$%s*(.-)%s*%$%$", init)
          if not s then
            break
          end
          table.insert(items, {
            bufnr = bufnr,
            type = "block",
            formula = content,
            range = { r, s - 1, r, e },
            is_comment = false,
          })
          for i = s, e do
            occupied[i] = true
          end
          init = e + 1
        end

        -- Inline $ ... $
        init = 1
        while true do
          local s, e, content = line:find("%$([^$\n]+)%$", init)
          if not s then
            break
          end
          local char_before = s > 1 and line:sub(s - 1, s - 1) or ""
          local char_after = e < #line and line:sub(e + 1, e + 1) or ""
          if char_before ~= "$" and char_after ~= "$" and char_before ~= "\\" and not occupied[s] then
            table.insert(items, {
              bufnr = bufnr,
              type = "inline",
              formula = content,
              range = { r, s - 1, r, e },
              is_comment = false,
            })
          end
          init = e + 1
        end
        r = r + 1
      end
    end
  end

  return items
end

--- Scan a buffer based on filetype
---@param bufnr number
---@return table[] items List of formula items
function M.scan_buffer(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "markdown" then
    return M.parse_markdown(bufnr)
  else
    return M.parse_comments_treesitter(bufnr)
  end
end

return M
