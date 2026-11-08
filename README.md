# nvim-latex

A lightweight Neovim plugin that renders inline and block LaTeX expressions as crisp graphics using the **Kitty Graphics Protocol** and **RaTeX**, with interactive cursor expansion (resolving back to editable text when hovered, just like ligatures).

Designed specifically for competitive programming and technical note-taking, it seamlessly renders math inside **C++ code comments** (`// $O(N \log N)$` or `/* ... $$ ... $$ ... */`) as well as **Markdown** files.

---

## Features

- **Direct Kitty Graphics Protocol**: Uses native Kitty Unicode Placeholders (`U+10EEEE`) for Ghostty, Kitty, and WezTerm. Zero external UI window lag or screen-tearing.
- **RaTeX Engine**: Uses `erweixin/RaTeX` for sub-millisecond math compilation with embedded KaTeX fonts and transparent background.
- **No Background Auto-Downloads**: Runs completely offline using the bundled or system `render` binary.
- **Tree-sitter Comment Scoping**: Uses Neovim's built-in Tree-sitter parser to find `$ ... $` and `$$ ... $$` math strictly inside code comments in C++, C, Rust, etc., keeping code clean.
- **Interactive Cursor Expansion**: When your cursor moves into a formula, it smoothly expands back into raw LaTeX text for easy editing. When the cursor leaves, it collapses back into the rendered graphic.
- **Smart Theme Color Matching**: Automatically matches your Neovim `Comment` highlight color for code comments and `Normal` text color for Markdown.
- **Persistent Asset Cache**: Fast disk cache (`stdpath("cache")/nvim-latex`) ensures repeated formulas render in 0ms.

---

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nvim-latex",
  dir = vim.fn.stdpath("config") .. "/nvim-latex", -- or your repo path
  opts = {
    -- Default options
    font_size = 22,
    expand_on_cursor = true,
    filetypes = { "c", "cpp", "rust", "python", "markdown" },
  },
}
```

---

## Syntax

### C++ Comments
```cpp
// Time complexity: $O(N \log N)$, Space: $O(N)$
// Condition: $1 \le A_i \le 10^9$

/* Multiline math:
$$
\sum_{i=1}^n i = \frac{n(n+1)}{2}
$$
*/
```

### Markdown
```markdown
Here is inline math: $E = mc^2$

$$
\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}
$$
```

---

## Commands

- `:NvimLatexToggle` - Toggle LaTeX rendering on/off.
- `:NvimLatexRefresh` - Force re-scan and refresh formulas in the current buffer.
