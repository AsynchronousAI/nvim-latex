local config = require("nvim-latex.config")
local render = require("nvim-latex.render")
local terminal = require("nvim-latex.terminal")

-- Defensive guard for Neovim 0.12+ Tree-sitter directive compatibility
if vim.treesitter and vim.treesitter.get_node_text then
  local orig_get_node_text = vim.treesitter.get_node_text
  vim.treesitter.get_node_text = function(node, source, opts)
    if type(node) == "table" and not getmetatable(node) then
      node = node[1]
    end
    if not node then
      return ""
    end
    return orig_get_node_text(node, source, opts)
  end
end

local M = {}

local is_enabled = true
local augroup = vim.api.nvim_create_augroup("nvim_latex", { clear = true })
local attached_buffers = {}

--- Check if buffer should be attached
--- Supports "*" for all code/text files, and filters out UI/tooling popups
---@param bufnr number
---@return boolean
local function is_supported_ft(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- Only attach to normal file buffers
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then
    return false
  end

  local ft = vim.bo[bufnr].filetype
  local ignored_ft = {
    [""] = true,
    ["TelescopePrompt"] = true,
    ["lazy"] = true,
    ["help"] = true,
    ["qf"] = true,
    ["gitcommit"] = true,
    ["NvimTree"] = true,
    ["neo-tree"] = true,
    ["notify"] = true,
  }
  if ignored_ft[ft] then
    return false
  end

  -- Check user filetype whitelist
  for _, target in ipairs(config.options.filetypes) do
    if target == "*" or target == ft then
      return true
    end
  end

  return false
end

--- Attach nvim-latex to a buffer
---@param bufnr? number
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not is_supported_ft(bufnr) then
    return
  end
  if attached_buffers[bufnr] then
    return
  end

  attached_buffers[bufnr] = true

  -- Ensure conceallevel is set so Neovim conceals text
  vim.api.nvim_buf_call(bufnr, function()
    if vim.wo.conceallevel < 2 then
      vim.wo.conceallevel = 2
    end
  end)

  -- Initial render
  render.refresh_buffer(bufnr)
end

--- Detach nvim-latex from a buffer
---@param bufnr? number
function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not attached_buffers[bufnr] then
    return
  end

  render.clean_buffer(bufnr)
  attached_buffers[bufnr] = nil
end

--- Toggle plugin on or off
function M.toggle()
  if is_enabled then
    M.disable()
  else
    M.enable()
  end
end

--- Enable plugin
function M.enable()
  is_enabled = true
  local cur = vim.api.nvim_get_current_buf()
  if is_supported_ft(cur) then
    M.attach(cur)
  end
end

--- Disable plugin
function M.disable()
  is_enabled = false
  for b, _ in pairs(attached_buffers) do
    render.clean_buffer(b)
  end
  attached_buffers = {}
end

--- Refresh current buffer
function M.refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  render.refresh_buffer(bufnr)
end

--- Setup plugin options and autocommands
---@param opts? table User options
function M.setup(opts)
  config.setup(opts)

  if not terminal.is_supported() then
    vim.notify("nvim-latex: Terminal does not appear to support Kitty graphics protocol.", vim.log.levels.WARN)
  end

  render.setup_highlights()

  -- Autocommands for lifecycle
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "FileType" }, {
    group = augroup,
    callback = function(args)
      if is_enabled and is_supported_ft(args.buf) then
        vim.schedule(function()
          M.attach(args.buf)
        end)
      end
    end,
  })

  -- Cursor and visual selection motion
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "CursorHold", "CursorHoldI" }, {
    group = augroup,
    callback = function(args)
      if is_enabled and attached_buffers[args.buf] then
        render.on_cursor_moved(args.buf)
      end
    end,
  })

  -- Visual mode changes (v, V, <C-v>, normal mode exit)
  vim.api.nvim_create_autocmd({ "ModeChanged" }, {
    group = augroup,
    pattern = "*:*",
    callback = function(args)
      if is_enabled and attached_buffers[args.buf] then
        render.on_cursor_moved(args.buf)
      end
    end,
  })

  -- Window / Terminal resize (recalculate clean line wrapping)
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = augroup,
    callback = function()
      if is_enabled then
        for b, _ in pairs(attached_buffers) do
          render.refresh_buffer(b)
        end
      end
    end,
  })

  -- Buffer edits
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    callback = function(args)
      if is_enabled and attached_buffers[args.buf] then
        render.debounced_refresh(args.buf)
      end
    end,
  })

  -- Buffer cleanup
  vim.api.nvim_create_autocmd({ "BufLeave", "BufUnload" }, {
    group = augroup,
    callback = function(args)
      if attached_buffers[args.buf] then
        M.detach(args.buf)
      end
    end,
  })

  -- ColorScheme adaptation
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      render.setup_highlights()
      for b, _ in pairs(attached_buffers) do
        render.refresh_buffer(b)
      end
    end,
  })

  -- Attach current buffer if already open
  local cur = vim.api.nvim_get_current_buf()
  if is_supported_ft(cur) then
    vim.schedule(function()
      M.attach(cur)
    end)
  end

  -- User commands
  vim.api.nvim_create_user_command("NvimLatexToggle", M.toggle, { desc = "Toggle nvim-latex rendering" })
  vim.api.nvim_create_user_command("NvimLatexRefresh", M.refresh, { desc = "Refresh nvim-latex formulas in current buffer" })
end

return M
