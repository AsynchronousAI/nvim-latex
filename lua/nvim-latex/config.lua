local M = {}

M.defaults = {
  -- Path to RaTeX 'render' binary.
  -- If nil, checks vim.fn.exepath("ratex"), vim.fn.exepath("render"), or plugin's bin/render.
  bin = nil,

  -- Supported filetypes to auto-attach
  filetypes = {
    "c",
    "cpp",
    "rust",
    "python",
    "markdown",
  },

  -- Math delimiters
  delimiters = {
    inline = { "$", "$" },
    block = { "$$", "$$" },
  },

  -- Base font size (in pixels) for RaTeX rendering (28 gives crisp glyphs matching standard fonts)
  font_size = 28,

  -- Padding around formula glyphs (0 eliminates extra empty margin/box padding)
  padding = 0,

  -- Formula color override (e.g. "#8b949e"). If nil, auto-detects from active colorscheme
  color = nil,

  -- Highlight group to link the $ delimiter to when expanded (default: "Conceal")
  -- Compatible with any colorscheme (Catppuccin, TokyoNight, Gruvbox, GitHub, etc.)
  delimiter_hl = "Conceal",

  -- Expand back to raw text when cursor enters the line
  expand_on_cursor = true,

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
