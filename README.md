# nvim-latex

A lightweight Neovim plugin that renders inline LaTeX math expressions as crisp, native graphics using the **Kitty Graphics Protocol** and **RaTeX**, with zero visual jumps or line splitting.

---

## Features

- **Direct Kitty Graphics Protocol**: Uses native Kitty Unicode Placeholders (`U+10EEEE`) supported by modern terminals like **Ghostty**, **Kitty**, and **WezTerm**.
- **Pixel-Accurate Grid Fit**: Transparently scales and pads formula images to exact cell grid multiples, maintaining a strict 1.000 scale factor and uniform glyph height.
- **Tree-sitter Comment Scoping**: Automatically identifies LaTeX formulas (`$ ... $`) inside code comments across all programming languages using Neovim's built-in Tree-sitter.
- **Clean Inline Wrapping**: Prevents formulas from being sliced across screen line boundaries when `'wrap'` is enabled by dynamically padding formulas to column 0 of the next screen row.
- **Persistent Asset Cache**: Fast disk cache (`stdpath("cache")/nvim-latex`) ensures repeated formulas render instantly.
- **Expand on Cursor**: Automatically reveals the underlying LaTeX syntax with subtle delimiters when the cursor is on the line.

---

## Prerequisites

1. **Terminal**: A terminal emulator supporting the Kitty Graphics Protocol (e.g. **Ghostty**, **Kitty**, or **WezTerm**).
2. **RaTeX**: The `ratex` (or `render`) binary must be installed on your system `PATH`.

### Installing RaTeX

#### Option A: Using Cargo (Rust)
```bash
cargo install ratex
```

#### Option B: Pre-built Binary
1. Download the pre-built `render` or `ratex` binary for your platform from the [RaTeX Releases](https://github.com/erweixin/RaTeX/releases).
2. Make it executable and place it in any directory on your `$PATH` (e.g., `~/.local/bin` or `/usr/local/bin`):
```bash
chmod +x ratex
mv ratex ~/.local/bin/
```
3. Verify that `ratex` is available in your shell:
```bash
which ratex
```

---

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "nvim-latex",
  opts = {
    font_size = 26,
    dpr = 2.0,
    expand_on_cursor = true,
    filetypes = { "*" },
  },
}
```

---

## Configuration

Default options:

```lua
require("nvim-latex").setup({
  -- Custom path to RaTeX binary if not in system PATH
  bin = nil,

  -- Supported filetypes to auto-attach ("*" matches all code and markdown files)
  filetypes = { "*" },

  -- Math delimiters (inline $...$)
  delimiters = {
    inline = { "$", "$" },
  },

  -- Base font size (in pixels) for formula rendering
  font_size = 26,

  -- Device Pixel Ratio (2.0 for Retina / high-DPI displays)
  dpr = 2.0,

  -- Formula color override (nil auto-detects from active colorscheme)
  color = nil,

  -- Delimiter highlight group when expanded
  delimiter_hl = "Conceal",

  -- Expand back to raw text when cursor enters the line
  expand_on_cursor = true,

  -- Debounce delay (ms) for re-scanning buffer changes
  debounce_ms = 150,

  -- Cache directory for compiled formula PNGs
  cache_dir = vim.fn.stdpath("cache") .. "/nvim-latex",
})
```
