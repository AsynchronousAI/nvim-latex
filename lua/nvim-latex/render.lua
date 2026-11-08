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

-- Buffer state map: bufnr -> { formulas = { [key] = formula_record }, active_range = { -1, -1 }, timer = nil }
local state = {}

--- Get active line range affected by cursor or visual selection
--- Supports:
---   - Normal mode (single cursor line)
---   - Insert mode (single cursor line)
---   - Visual characterwise ('v')
---   - Visual linewise ('V')
---   - Visual blockwise ('\22' / Ctrl-V)
---   - Select modes ('s', 'S', Ctrl-S)
---@param win number
---@return number start_line 0-indexed
---@return number end_line 0-indexed
local function get_active_selection_range(win)
  local mode_info = vim.api.nvim_get_mode()
  local mode = mode_info.mode
  local cur_line = vim.api.nvim_win_get_cursor(win)[1] - 1

  -- Visual mode: 'v' (118), 'V' (86), Ctrl-V (22), 's' (115), 'S' (83), Ctrl-S (19)
  local b = mode:byte(1) or 0
  if b == 118 or b == 86 or b == 22 or b == 115 or b == 83 or b == 19 then
    local v_line = vim.fn.line("v") - 1
    local s_line = math.min(cur_line, v_line)
    local e_line = math.max(cur_line, v_line)
    return s_line, e_line
  end

  return cur_line, cur_line
end

--- Calculate visual column offset on a line before col_idx, accounting for collapsed formulas
--- Automatically determines if formula would wrap across lines and returns spaces needed
--- to push the formula cleanly to the beginning of the next screen line
---@param bufnr number
---@param row number 0-indexed line number
---@param col_idx number 0-indexed byte column
---@param formula_cols number Width of the formula in screen cells
---@param text_width number Available window columns
---@return number pad Number of spaces to pad before the formula to prevent splitting across lines
local function get_wrap_pad(bufnr, row, col_idx, formula_cols, text_width)
  if text_width <= 0 or formula_cols > text_width then
    return 0
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
  local line = lines[1] or ""
  local prefix = line:sub(1, col_idx)

  local buf_state = state[bufnr]
  local visual_w = 0

  if not buf_state then
    visual_w = vim.fn.strdisplaywidth(prefix)
  else
    -- Account for any collapsed formulas that appear earlier on this same line
    local cur_byte = 1
    while cur_byte <= #prefix do
      local matched_f = nil
      for _, other in pairs(buf_state.formulas) do
        if other.range[1] == row and other.range[2] == cur_byte - 1 and other.range[4] <= col_idx then
          matched_f = other
          break
        end
      end

      if matched_f and not matched_f.is_expanded and matched_f.cols then
        visual_w = visual_w + (matched_f.pad or 0) + matched_f.cols
        cur_byte = matched_f.range[4] + 1
      else
        local ch = prefix:sub(cur_byte, cur_byte)
        if ch == "\t" then
          local ts = vim.bo[bufnr].tabstop or 8
          visual_w = visual_w + (ts - (visual_w % ts))
        else
          visual_w = visual_w + vim.fn.strdisplaywidth(ch)
        end
        cur_byte = cur_byte + 1
      end
    end
  end

  local col_on_screen = visual_w % text_width
  if col_on_screen > 0 and (col_on_screen + formula_cols > text_width) then
    return text_width - col_on_screen
  end

  return 0
end

--- Check if a formula spans across or overlaps a specific line range
---@param f table Formula record
---@param s_line number 0-indexed start line
---@param e_line number 0-indexed end line
---@return boolean
local function formula_touches_range(f, s_line, e_line)
  return f.range[3] >= s_line and f.range[1] <= e_line
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
    local pad = 0
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].wrap then
      local wininfo = vim.fn.getwininfo(win)[1]
      local text_width = wininfo and (wininfo.width - wininfo.textoff) or (vim.api.nvim_win_get_width(win) - 4)
      local cols = f.cols or (f.placeholder_lines and #f.placeholder_lines[1]) or 1
      pad = get_wrap_pad(bufnr, f.range[1], f.range[2], cols, text_width)
    end
    f.pad = pad

    local virt_text = {}
    if pad > 0 then
      table.insert(virt_text, { string.rep(" ", pad), "Normal" })
    end
    table.insert(virt_text, { f.placeholder_lines[1], f.hl_group })

    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, f.range[1], f.range[2], {
      end_row = f.range[3],
      end_col = f.range[4],
      conceal = "",
      virt_text = virt_text,
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
  f.pad = 0
  f.is_expanded = true

  -- Highlight $ delimiters with subtle, slightly transparent color
  apply_delimiter_highlights(bufnr, f)
end

--- Check cursor position or visual selection and expand/collapse formulas
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

  local s_line, e_line = get_active_selection_range(win)

  -- Any formula overlapping the active line / visual selection expands; all other lines collapse
  for _, f in pairs(buf_state.formulas) do
    if formula_touches_range(f, s_line, e_line) then
      if not f.is_expanded then
        expand_formula(bufnr, f)
      end
    else
      if f.is_expanded then
        collapse_formula(bufnr, f)
      end
    end
  end

  M.update_wrap_mode(win, bufnr)
end

--- Update window line-wrapping mode based on textual (expanded) vs rendered mode
--- In textual mode (cursor on line with raw formula), wraps line for editing.
--- In rendered mode, disables wrapping if rendered text comfortably fits on screen.
---@param win number
---@param bufnr number
function M.update_wrap_mode(win, bufnr)
  if not config.options.auto_wrap_mode or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local buf_state = state[bufnr]
  if not buf_state then
    return
  end

  if buf_state.initial_wrap == nil then
    buf_state.initial_wrap = vim.wo[win].wrap
  end

  -- If user originally had nowrap, preserve their setting
  if buf_state.initial_wrap == false then
    return
  end

  local cur_line = vim.api.nvim_win_get_cursor(win)[1] - 1
  local is_textual = false

  for _, f in pairs(buf_state.formulas) do
    if f.range[1] <= cur_line and f.range[3] >= cur_line and f.is_expanded then
      is_textual = true
      break
    end
  end

  if is_textual then
    if not vim.wo[win].wrap then
      vim.wo[win].wrap = true
    end
  else
    local wininfo = vim.fn.getwininfo(win)[1]
    local text_width = wininfo and (wininfo.width - wininfo.textoff) or (vim.api.nvim_win_get_width(win) - 4)
    local needs_wrap = false
    if text_width > 0 then
      for _, f in pairs(buf_state.formulas) do
        if not f.is_expanded and f.cols then
          local lines = vim.api.nvim_buf_get_lines(bufnr, f.range[1], f.range[1] + 1, false)
          local line_str = lines[1] or ""
          local raw_len = f.range[4] - f.range[2]
          local rendered_len = #line_str - raw_len + f.cols + (f.pad or 0)
          if rendered_len > text_width then
            needs_wrap = true
            break
          end
        end
      end
    end

    if needs_wrap then
      if not vim.wo[win].wrap then
        vim.wo[win].wrap = true
      end
    else
      if vim.wo[win].wrap then
        vim.wo[win].wrap = false
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

    -- Calculate exact column and row grid dimensions:
    -- In Kitty graphics protocol, terminal emulators scale Unicode placeholder images to fit the allocated columns.
    -- To ensure all capital letters (A, B, K, N...) render at uniform cap-height without narrower letters
    -- being squashed into 1 column, we calculate columns using the display width with a minor sub-cell tolerance.
    local cols, rows
    if is_inline then
      rows = 1
      local max_height = rows * cell_h
      local scale = math.min(1.0, max_height / ph)
      local display_width = pw * scale
      cols = math.max(1, math.ceil((display_width - 2) / cell_w))
    else
      rows = math.max(1, math.min(16, math.ceil(ph / cell_h)))
      local max_height = rows * cell_h
      local scale = math.min(1.0, max_height / ph)
      local display_width = pw * scale
      cols = math.max(1, math.ceil(display_width / cell_w))
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
      cols = cols,
      rows = rows,
      pad = 0,
      placeholder_lines = lines,
      hl_group = hl_group,
      extmark_id = nil,
      delim_extmark_ids = {},
      is_expanded = false,
    }

    buf_state.formulas[key] = f_record

    -- Check if cursor / visual selection is currently overlapping this formula
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local s_line, e_line = get_active_selection_range(win)
      if formula_touches_range(f_record, s_line, e_line) and config.options.expand_on_cursor then
        expand_formula(bufnr, f_record)
        M.update_wrap_mode(win, bufnr)
        return
      end
    end

    collapse_formula(bufnr, f_record)
    if vim.api.nvim_win_get_buf(win) == bufnr then
      M.update_wrap_mode(win, bufnr)
    end
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
    state[bufnr] = { formulas = {}, active_range = { -1, -1 } }
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
    state[bufnr] = { formulas = {}, active_range = { -1, -1 } }
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

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(win) and buf_state.initial_wrap ~= nil then
    vim.wo[win].wrap = buf_state.initial_wrap
  end

  state[bufnr] = nil
end

return M
