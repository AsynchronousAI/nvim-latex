# nvim-latex

A lightweight Neovim plugin that renders inline LaTeX math expressions as crisp, native graphics using the **Kitty Graphics Protocol** and **RaTeX**. 

> **NOTE:** You need **RaTeX** installed in your system path to use this tool.
## Features
- **Direct Kitty Graphics Protocol**: Uses native Kitty Unicode Placeholders supported by modern terminals like **Ghostty**, **Kitty**, and **WezTerm**.
- **Pixel-Accurate Grid Fit**: Transparently scales and pads formula images to exact cell grid multiples, maintaining a strict 1.000 scale factor and uniform glyph height.
- **Tree-sitter Comment Scoping**: Automatically identifies LaTeX formulas (`$...$`) inside code comments across all programming languages using Neovim's built-in Tree-sitter.
- **Persistent Asset Cache**: Fast disk cache (`stdpath("cache")/nvim-latex`) ensures repeated formulas render instantly. 
