local M = {}

M.defaults = {
  -- Path to RaTeX 'render' binary.
  -- If nil, checks vim.fn.exepath("ratex"), vim.fn.exepath("render"), or plugin's bin/render.
  bin = nil,

  -- Supported filetypes to auto-attach ("*" matches all code and markdown files)
  filetypes = {
    "*",
  },

  -- Math delimiters
  delimiters = {
    inline = { "$", "$" },
    block = { "$$", "$$" },
  },

  -- Base font size (in pixels) for RaTeX rendering (24 gives prominent, highly legible glyphs)
  font_size = 24,

  -- Render scale factor / Device Pixel Ratio (e.g. 2.0 or 3.0 for ultra-crisp Retina / 4K rendering)
  dpr = 2.0,

  -- Padding around formula glyphs (0 eliminates extra empty margin/box padding)
  padding = 0,

  -- Formula color override (e.g. "#8b949e"). If nil, auto-detects from active colorscheme
  color = nil,

  -- Highlight group to link the $ delimiter to when expanded (default: "Conceal")
  -- Compatible with any colorscheme (Catppuccin, TokyoNight, Gruvbox, GitHub, etc.)
  delimiter_hl = "Conceal",

  -- Expand back to raw text when cursor enters the line or visual selection
  expand_on_cursor = true,

  -- Dynamically adapt window line-wrap based on textual (expanded) vs rendered mode
  -- Prevents phantom wrapped blank lines when rendered latex comfortably fits on screen
  auto_wrap_mode = true,

  -- Default cell dimensions (pixels) fallback when terminal ioctl is unavailable
  cell_width = 9,
  cell_height = 18,

  -- Debounce delay (in milliseconds) for re-scanning buffer changes
  debounce_ms = 150,

  -- Cache directory for compiled formula PNGs
  cache_dir = vim.fn.stdpath("cache") .. "/nvim-latex",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(user_opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
  return M.options
end

return M
