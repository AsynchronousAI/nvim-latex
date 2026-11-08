local config = require("nvim-latex.config")
local terminal = require("nvim-latex.terminal")
local ratex = require("nvim-latex.ratex")
local parser = require("nvim-latex.parser")

local M = {}

local ns = vim.api.nvim_create_namespace("nvim_latex")
M.ns = ns

-- Buffer state map: bufnr -> { formulas = { [key] = formula_record }, active_formula = nil, timer = nil }
local state = {}

--- Check if cursor (0-indexed row, col) is inside a formula range
---@param r number
---@param c number
---@param range table { start_row, start_col, end_row, end_col }
---@return boolean
local function is_cursor_inside(r, c, range)
  if r < range[1] or r > range[3] then
    return false
  end
  if range[1] == range[3] then
    return c >= range[2] and c <= range[4]
  end
  if r == range[1] then
    return c >= range[2]
  end
  if r == range[3] then
    return c <= range[4]
  end
  return true
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

  -- Delete previous extmark if present
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

--- Expand formula back into raw editable text
---@param bufnr number
---@param f table Formula record
local function expand_formula(bufnr, f)
  if f.extmark_id and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, f.extmark_id)
    f.extmark_id = nil
  end
  f.is_expanded = true
end

--- Check cursor position and expand/collapse formulas dynamically
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

  local cursor = vim.api.nvim_win_get_cursor(win)
  local cur_row = cursor[1] - 1
  local cur_col = cursor[2]

  local current_hovered_f = nil

  for _, f in pairs(buf_state.formulas) do
    if is_cursor_inside(cur_row, cur_col, f.range) then
      current_hovered_f = f
      break
    end
  end

  -- If hovered formula changed
  if buf_state.active_formula ~= current_hovered_f then
    -- Collapse previous active formula if any
    if buf_state.active_formula and buf_state.active_formula.is_expanded then
      collapse_formula(bufnr, buf_state.active_formula)
    end

    -- Expand newly hovered formula
    if current_hovered_f and not current_hovered_f.is_expanded then
      expand_formula(bufnr, current_hovered_f)
    end

    buf_state.active_formula = current_hovered_f
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
  if existing and existing.extmark_id then
    return
  end

  local is_inline = item.type == "inline"
  ratex.compile(item.formula, is_inline, item.is_comment, function(png_path, pw, ph, err)
    if not png_path or err or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local cell_w, cell_h = terminal.get_cell_size()
    local cols = math.max(1, math.ceil(pw / cell_w))
    local rows = is_inline and 1 or math.max(1, math.ceil(ph / cell_h))

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
      is_expanded = false,
    }

    buf_state.formulas[key] = f_record

    -- Check if cursor is currently inside before collapsing
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local cursor = vim.api.nvim_win_get_cursor(win)
      if is_cursor_inside(cursor[1] - 1, cursor[2], item.range) and config.options.expand_on_cursor then
        f_record.is_expanded = true
        buf_state.active_formula = f_record
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

  buf_state = state[bufnr]
  if not buf_state then
    state[bufnr] = { formulas = {}, active_formula = nil }
    buf_state = state[bufnr]
  end

  -- Ensure conceallevel is set so Neovim can conceal text
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
    state[bufnr] = { formulas = {}, active_formula = nil }
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
    if f.id then
      terminal.delete_image(f.id)
    end
  end

  state[bufnr] = nil
end

return M
