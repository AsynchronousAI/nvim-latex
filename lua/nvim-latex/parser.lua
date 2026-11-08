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

  -- 2. Inline math: $ ... $ (avoiding $$ and escaped \$)
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

--- Universal comment parser using built-in Tree-sitter for any language
---@param bufnr number
---@return table[] items List of formula records
function M.parse_comments_treesitter(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return M.parse_comments_regex(bufnr)
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    return M.parse_comments_regex(bufnr)
  end

  local root = trees[1]:root()
  local lang = parser:lang()

  -- Try standard query for this grammar
  local q_ok, query = pcall(vim.treesitter.query.parse, lang, "((comment) @comment)")
  if not q_ok or not query then
    q_ok, query = pcall(vim.treesitter.query.parse, lang, "([(comment) (line_comment) (block_comment)] @comment)")
  end

  if not q_ok or not query then
    return M.parse_comments_regex(bufnr)
  end

  local all_items = {}
  local seen_ranges = {}
  for _, node in query:iter_captures(root, bufnr, 0, -1) do
    if type(node) == "table" and not getmetatable(node) then
      node = node[1]
    end
    if node and type(node.range) == "function" then
      local sr, sc, er, ec = node:range()
      local text = vim.treesitter.get_node_text(node, bufnr)
      local items = extract_from_comment(text, sr, sc, bufnr)
      for _, item in ipairs(items) do
        local rk = string.format("%d_%d_%d_%d", item.range[1], item.range[2], item.range[3], item.range[4])
        if not seen_ranges[rk] then
          seen_ranges[rk] = true
          table.insert(all_items, item)
        end
      end
    end
  end

  -- If Tree-sitter found no comment formulas, fall back to universal regex parser
  if #all_items == 0 then
    return M.parse_comments_regex(bufnr)
  end

  return all_items
end

--- Universal regex comment parser across all programming languages
--- Supports:
---   -- (Lua, SQL, Haskell)
---   // (C, C++, Rust, Go, JS, TS, Java, Zig)
---   #  (Python, Bash, Ruby, YAML, TOML)
---   ;  (Lisp, Assembly, Clojure)
---   /* ... */, --[[ ... ]], <!-- ... -->
---@param bufnr number
---@return table[] items
function M.parse_comments_regex(bufnr)
  local ft = vim.bo[bufnr].filetype
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local all_items = {}

  local cs = vim.bo[bufnr].commentstring or ""
  local cs_prefix = cs:match("^%s*(%S+)%s*%%s")

  for r = 0, #lines - 1 do
    local line = lines[r + 1]
    local comment_start = nil

    -- 0. Check buffer commentstring leader if present
    if cs_prefix and cs_prefix ~= "" then
      local s_cs = line:find(cs_prefix, 1, true)
      if s_cs and (not comment_start or s_cs < comment_start) then
        comment_start = s_cs
      end
    end

    -- 1. Check Lua / SQL / Haskell '--'
    local s_lua = line:find("%-%-")
    if s_lua and (not comment_start or s_lua < comment_start) then
      comment_start = s_lua
    end

    -- 2. Check C / C++ / Rust / Go / JS / TS '//'
    local s_c = line:find("//")
    if s_c and (not comment_start or s_c < comment_start) then
      comment_start = s_c
    end

    -- 3. Check Python / Shell / Ruby '#' (exclude C/C++ preprocessor directives)
    if ft ~= "c" and ft ~= "cpp" then
      local s_hash = line:find("#")
      if s_hash and (not comment_start or s_hash < comment_start) then
        comment_start = s_hash
      end
    end

    -- 4. Check Lisp / Assembly / INI ';'
    if ft == "lisp" or ft == "clojure" or ft == "asm" or ft == "ini" then
      local s_semi = line:find(";")
      if s_semi and (not comment_start or s_semi < comment_start) then
        comment_start = s_semi
      end
    end

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
      -- Check for multiline block $$ ... $$
      -- Matches if line has $$ and does NOT close it on the same line
      local s_open, e_open = line:find("%$%$")
      if s_open and not line:find("%$%$", e_open + 1) then
        local block_start_r = r
        local start_col = s_open - 1
        local block_lines = {}

        local first_rest = vim.trim(line:sub(e_open + 1))
        if first_rest ~= "" then
          table.insert(block_lines, first_rest)
        end

        local block_end_r = nil
        local end_col = nil

        r = r + 1
        while r < #lines do
          local cur_line = lines[r + 1]
          local close_s, close_e = cur_line:find("%$%$")
          if close_s then
            local before_close = vim.trim(cur_line:sub(1, close_s - 1))
            if before_close ~= "" then
              table.insert(block_lines, before_close)
            end
            block_end_r = r
            end_col = close_e
            break
          else
            table.insert(block_lines, cur_line)
            r = r + 1
          end
        end

        if block_end_r and end_col then
          local content = table.concat(block_lines, "\n")
          table.insert(items, {
            bufnr = bufnr,
            type = "block",
            formula = content,
            range = { block_start_r, start_col, block_end_r, end_col },
            is_comment = false,
          })
        end
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

--- Scan a buffer based on filetype (markdown vs code comments)
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
