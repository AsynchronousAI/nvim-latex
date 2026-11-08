local config = require("nvim-latex.config")
local terminal = require("nvim-latex.terminal")
local ratex = require("nvim-latex.ratex")
local parser = require("nvim-latex.parser")

local M = {}

local ns = vim.api.nvim_create_namespace("nvim_latex")
local delim_ns = vim.api.nvim_create_namespace("nvim_latex_delimiters")

M.ns = ns
M.delim_ns = delim_ns

--- Setup delimiter highlights using standard Neovim highlight links
--- Portable across any colorscheme (Catppuccin, TokyoNight, Gruvbox, GitHub, etc.)
function M.setup_highlights()
  local target_hl = config.options.delimiter_hl or "Conceal"

  -- Link NvimLatexDelimiter to standard Conceal (or user's choice) by default
  vim.api.nvim_set_hl(0, "NvimLatexDelimiter", {
    link = target_hl,
    default = true,
  })

  -- Fallback check: if Conceal doesn't specify an fg in this theme, link to Comment
  local hl = vim.api.nvim_get_hl(0, { name = "NvimLatexDelimiter", link = false })
  if not hl or (not hl.fg and not hl.link) then
    vim.api.nvim_set_hl(0, "NvimLatexDelimiter", {
      link = "Comment",
      default = true,
    })
  end
end

M.setup_highlights()

-- Buffer state map: bufnr -> { formulas = { [key] = formula_record }, active_line = nil, timer = nil }
local state = {}

--- Check if a formula spans across a specific buffer line
---@param f table Formula record
---@param line number 0-indexed line number
---@return boolean
local function formula_touches_line(f, line)
  return line >= f.range[1] and line <= f.range[3]
end

--- Apply subtle delimiter highlight on $ or $$ when expanded
---@param bufnr number
---@param f table Formula record
local function apply_delimiter_highlights(bufnr, f)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  f.delim_extmark_ids = f.delim_extmark_ids or {}

  -- Clear previous delimiter marks if any
  for _, mark_id in ipairs(f.delim_extmark_ids) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, delim_ns, mark_id)
  end
  f.delim_extmark_ids = {}

  local delim_len = f.type == "block" and 2 or 1

  -- Opening delimiter
  local ok1, id1 = pcall(vim.api.nvim_buf_set_extmark, bufnr, delim_ns, f.range[1], f.range[2], {
    end_row = f.range[1],
    end_col = f.range[2] + delim_len,
    hl_group = "NvimLatexDelimiter",
    priority = 5000,
  })
  if ok1 then
    table.insert(f.delim_extmark_ids, id1)
  end

  -- Closing delimiter
  local ok2, id2 = pcall(vim.api.nvim_buf_set_extmark, bufnr, delim_ns, f.range[3], f.range[4] - delim_len, {
    end_row = f.range[3],
    end_col = f.range[4],
    hl_group = "NvimLatexDelimiter",
    priority = 5000,
  })
  if ok2 then
    table.insert(f.delim_extmark_ids, id2)
  end
end

--- Clear delimiter highlights when collapsed
---@param bufnr number
---@param f table Formula record
local function clear_delimiter_highlights(bufnr, f)
  if f.delim_extmark_ids and vim.api.nvim_buf_is_valid(bufnr) then
    for _, mark_id in ipairs(f.delim_extmark_ids) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, delim_ns, mark_id)
    end
  end
  f.delim_extmark_ids = {}
end

--- Apply extmark to collapse formula into rendered Kitty graphic
---@param bufnr number
---@param f table Formula record
local function collapse_formula(bufnr, f)
  if not f.placeholder_lines or not f.hl_group then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Remove subtle delimiter highlights when collapsed into graphic
  clear_delimiter_highlights(bufnr, f)

  -- Delete previous graphic extmark if present
  if f.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, f.extmark_id)
    f.extmark_id = nil
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if f.range[1] >= line_count or f.range[3] >= line_count then
    return
  end

  if f.type == "inline" then
    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, f.range[1], f.range[2], {
      end_row = f.range[3],
      end_col = f.range[4],
      conceal = "",
      virt_text = { { f.placeholder_lines[1], f.hl_group } },
      virt_text_pos = "inline",
      priority = 4096,
    })
    if ok then
      f.extmark_id = mark_id
      f.is_expanded = false
    end
  else
    -- Block math
    local virt_lines = {}
    for _, line_str in ipairs(f.placeholder_lines) do
      table.insert(virt_lines, { { line_str, f.hl_group } })
    end

    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, f.range[1], f.range[2], {
      end_row = f.range[3],
      end_col = f.range[4],
      conceal = "",
      virt_lines = virt_lines,
      priority = 4096,
    })
    if ok then
      f.extmark_id = mark_id
      f.is_expanded = false
    end
  end
end

--- Expand formula back into normal raw text with dimmed $ delimiters
---@param bufnr number
---@param f table Formula record
local function expand_formula(bufnr, f)
  if f.extmark_id and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, f.extmark_id)
    f.extmark_id = nil
  end
  f.is_expanded = true

  -- Highlight $ delimiters with subtle, slightly transparent color
  apply_delimiter_highlights(bufnr, f)
end

--- Check cursor line and expand/collapse formulas on a per-line basis
---@param bufnr number
function M.on_cursor_moved(bufnr)
  local buf_state = state[bufnr]
  if not buf_state or not config.options.expand_on_cursor then
    return
  end

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end

  local cur_line = vim.api.nvim_win_get_cursor(win)[1] - 1

  -- If cursor line hasn't changed, no update needed
  if buf_state.active_line == cur_line then
    return
  end
  buf_state.active_line = cur_line

  -- Any formula on the current cursor line expands to normal text; all other lines collapse
  for _, f in pairs(buf_state.formulas) do
    if formula_touches_line(f, cur_line) then
      if not f.is_expanded then
        expand_formula(bufnr, f)
      end
    else
      if f.is_expanded then
        collapse_formula(bufnr, f)
      end
    end
  end
end

--- Render or update a parsed formula
---@param bufnr number
---@param item table Item parsed from buffer
local function render_item(bufnr, item)
  local buf_state = state[bufnr]
  if not buf_state then
    return
  end

  local key = string.format("%d_%d_%d_%d_%s", item.range[1], item.range[2], item.range[3], item.range[4], item.formula)

  -- Check if already rendered and up-to-date
  local existing = buf_state.formulas[key]
  if existing and existing.placeholder_lines then
    return
  end

  local is_inline = item.type == "inline"
  ratex.compile(item.formula, is_inline, item.is_comment, function(png_path, pw, ph, err)
    if not png_path or err or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local cell_w, cell_h = terminal.get_cell_size()
    local aspect = pw / ph
    local cell_aspect = cell_h / cell_w -- cell height-to-width ratio (typically ~2.0)

    -- Calculate exact column and row grid dimensions preserving aspect ratio without extra side padding
    local cols, rows
    if is_inline then
      rows = 1
      cols = math.max(1, math.floor(aspect * rows * cell_aspect + 0.5))
    else
      rows = math.max(1, math.min(10, math.floor(ph / cell_h + 0.5)))
      cols = math.max(1, math.floor(aspect * rows * cell_aspect + 0.5))
    end

    local image_id = terminal.next_image_id()
    local ok = terminal.transmit_and_place(image_id, png_path, cols, rows)
    if not ok then
      return
    end

    local lines, hl_group = terminal.create_placeholder_grid(image_id, cols, rows)

    local f_record = {
      id = image_id,
      key = key,
      formula = item.formula,
      type = item.type,
      range = item.range,
      placeholder_lines = lines,
      hl_group = hl_group,
      extmark_id = nil,
      delim_extmark_ids = {},
      is_expanded = false,
    }

    buf_state.formulas[key] = f_record

    -- Check if cursor is currently on this line
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local cur_line = vim.api.nvim_win_get_cursor(win)[1] - 1
      if formula_touches_line(f_record, cur_line) and config.options.expand_on_cursor then
        expand_formula(bufnr, f_record)
        return
      end
    end

    collapse_formula(bufnr, f_record)
  end)
end

--- Scan buffer and update all LaTeX formulas
---@param bufnr number
function M.refresh_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local buf_state = state[bufnr]
  if not buf_state then
    state[bufnr] = { formulas = {}, active_line = nil }
    buf_state = state[bufnr]
  end

  -- Ensure conceallevel is set so Neovim conceals text
  if vim.wo.conceallevel < 2 then
    vim.wo.conceallevel = 2
  end

  local items = parser.scan_buffer(bufnr)
  local found_keys = {}

  for _, item in ipairs(items) do
    local key = string.format("%d_%d_%d_%d_%s", item.range[1], item.range[2], item.range[3], item.range[4], item.formula)
    found_keys[key] = true
    render_item(bufnr, item)
  end

  -- Clean up formulas that no longer exist
  for k, f in pairs(buf_state.formulas) do
    if not found_keys[k] then
      if f.extmark_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, f.extmark_id)
      end
      clear_delimiter_highlights(bufnr, f)
      if f.id then
        terminal.delete_image(f.id)
      end
      buf_state.formulas[k] = nil
    end
  end
end

--- Schedule debounced buffer refresh
---@param bufnr number
function M.debounced_refresh(bufnr)
  local buf_state = state[bufnr]
  if not buf_state then
    state[bufnr] = { formulas = {}, active_line = nil }
    buf_state = state[bufnr]
  end

  if buf_state.timer then
    buf_state.timer:stop()
    buf_state.timer:close()
    buf_state.timer = nil
  end

  local timer = vim.uv.new_timer()
  buf_state.timer = timer
  timer:start(
    config.options.debounce_ms or 150,
    0,
    vim.schedule_wrap(function()
      if buf_state.timer == timer then
        buf_state.timer:close()
        buf_state.timer = nil
      end
      M.refresh_buffer(bufnr)
    end)
  )
end

--- Clean up all extmarks and terminal images for a buffer
---@param bufnr number
function M.clean_buffer(bufnr)
  local buf_state = state[bufnr]
  if not buf_state then
    return
  end

  if buf_state.timer then
    buf_state.timer:stop()
    buf_state.timer:close()
    buf_state.timer = nil
  end

  for _, f in pairs(buf_state.formulas) do
    if f.extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, f.extmark_id)
    end
    clear_delimiter_highlights(bufnr, f)
    if f.id then
      terminal.delete_image(f.id)
    end
  end

  state[bufnr] = nil
end

return M
