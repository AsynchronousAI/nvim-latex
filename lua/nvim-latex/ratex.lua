local config = require("nvim-latex.config")

local M = {}

local _bin_cache = nil

--- Locate the RaTeX 'render' binary without any internet auto-download
---@return string|nil path Path to binary or nil if not found
function M.find_binary()
  if _bin_cache and vim.fn.executable(_bin_cache) == 1 then
    return _bin_cache
  end

  -- 1. Check user configured binary path
  if config.options.bin and vim.fn.executable(config.options.bin) == 1 then
    _bin_cache = config.options.bin
    return _bin_cache
  end

  -- 2. Check PATH for 'ratex' or 'render'
  local in_path = vim.fn.exepath("ratex")
  if in_path ~= "" then
    _bin_cache = in_path
    return _bin_cache
  end

  in_path = vim.fn.exepath("render")
  if in_path ~= "" then
    _bin_cache = in_path
    return _bin_cache
  end

  -- 3. Check plugin's own bin/ directory
  local info = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(info)))
  local local_bin = plugin_root .. "/bin/render"
  if vim.fn.executable(local_bin) == 1 then
    _bin_cache = local_bin
    return _bin_cache
  end

  return nil
end

--- Extract pixel dimensions directly from PNG header (bytes 17..24)
---@param path string
---@return number|nil width
---@return number|nil height
function M.get_png_dimensions(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, nil
  end
  local header = f:read(24)
  f:close()

  if not header or #header < 24 then
    return nil, nil
  end

  -- Verify PNG signature: \137 P N G \r \n \26 \n
  if header:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil, nil
  end

  local w1, w2, w3, w4 = header:byte(17, 20)
  local width = (w1 * 16777216) + (w2 * 65536) + (w3 * 256) + w4

  local h1, h2, h3, h4 = header:byte(21, 24)
  local height = (h1 * 16777216) + (h2 * 65536) + (h3 * 256) + h4

  return width, height
end

--- Get dynamic foreground color matching current editor theme
--- Fully portable across any user's colorscheme and background mode
---@param is_comment boolean
---@return string hex_color
function M.get_color(is_comment)
  if config.options.color then
    if type(config.options.color) == "function" then
      return config.options.color(is_comment)
    end
    return config.options.color
  end

  local hl_name = is_comment and "Comment" or "Normal"
  local hl = vim.api.nvim_get_hl(0, { name = hl_name, link = false })
  if hl and hl.fg then
    return string.format("#%06x", hl.fg)
  end

  -- Dynamic fallback based on light/dark background
  local is_light = vim.o.background == "light"
  if is_comment then
    return is_light and "#5c6370" or "#8b949e"
  else
    return is_light and "#24292e" or "#c9d1d9"
  end
end

--- Asynchronously compile a LaTeX formula to a transparent PNG
--- Supports dynamic high-resolution scaling (DPR) matching font size
---@param formula string Raw LaTeX formula
---@param is_inline boolean True for inline $...$, false for block $$...$$
---@param is_comment boolean Whether formula is inside a code comment
---@param callback fun(png_path: string|nil, width: number|nil, height: number|nil, err: string|nil)
function M.compile(formula, is_inline, is_comment, callback)
  local bin = M.find_binary()
  if not bin then
    callback(nil, nil, nil, "RaTeX 'render' binary not found. Place it in PATH or plugin bin/render.")
    return
  end

  local color = M.get_color(is_comment)
  local font_size = config.options.font_size or 28
  local dpr = config.options.dpr or 2.0
  local padding = config.options.padding or 0
  local cache_dir = config.options.cache_dir or (vim.fn.stdpath("cache") .. "/nvim-latex")
  vim.fn.mkdir(cache_dir, "p")

  local hash_input = string.format("%s_%s_%s_%d_%d_%.2f", formula, is_inline and "inline" or "block", color, font_size, padding, dpr)
  local hash = vim.fn.sha256(hash_input)
  local final_png = string.format("%s/%s.png", cache_dir, hash)

  -- Cache hit
  if vim.fn.filereadable(final_png) == 1 then
    local w, h = M.get_png_dimensions(final_png)
    callback(final_png, w, h, nil)
    return
  end

  -- Cache miss: compile asynchronously
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, "p")

  local args = {
    bin,
    "--output-dir",
    tmp_dir,
    "--font-size",
    tostring(font_size),
    "--dpr",
    string.format("%.2f", dpr),
    "--padding",
    tostring(padding),
    "--color",
    color,
    "--background-color",
    "transparent",
  }
  if is_inline then
    table.insert(args, "--inline")
  end

  vim.system(args, { stdin = formula .. "\n" }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        vim.fn.delete(tmp_dir, "rf")
        callback(nil, nil, nil, obj.stderr or "RaTeX compilation failed")
        return
      end

      local generated = tmp_dir .. "/0001.png"
      if vim.fn.filereadable(generated) == 1 then
        vim.fn.rename(generated, final_png)
        vim.fn.delete(tmp_dir, "rf")
        local w, h = M.get_png_dimensions(final_png)
        callback(final_png, w, h, nil)
      else
        vim.fn.delete(tmp_dir, "rf")
        callback(nil, nil, nil, "No image generated by RaTeX")
      end
    end)
  end)
end

--- Transparently pad or resample PNG so canvas matches exact terminal grid boundaries
--- Ensures Ghostty / Kitty scales image by exactly 1.000, eliminating arbitrary enlargement
---@param png_path string Path to source PNG
---@param pw number|nil Source pixel width
---@param ph number|nil Source pixel height
---@param target_w number Target width in device pixels (cols * cell_width)
---@param target_h number Target height in device pixels (rows * cell_height)
---@param callback fun(final_png: string)
function M.fit_to_canvas(png_path, pw, ph, target_w, target_h, callback)
  if not png_path or vim.fn.filereadable(png_path) ~= 1 then
    callback(png_path)
    return
  end

  target_w = math.max(1, math.floor(target_w + 0.5))
  target_h = math.max(1, math.floor(target_h + 0.5))

  if not pw or not ph then
    pw, ph = M.get_png_dimensions(png_path)
    if not pw or not ph then
      callback(png_path)
      return
    end
  end

  -- If image already matches the exact target dimensions, no padding needed
  if pw == target_w and ph == target_h then
    callback(png_path)
    return
  end

  local padded_png = string.format("%s_%dx%d.png", png_path:gsub("%.png$", ""), target_w, target_h)
  if vim.fn.filereadable(padded_png) == 1 then
    callback(padded_png)
    return
  end

  -- Detect available image processing tool
  local is_mac = vim.fn.has("mac") == 1
  local has_sips = is_mac and vim.fn.executable("sips") == 1

  if has_sips then
    local args
    if ph > target_h then
      -- If formula height exceeds target height, resample height to fit, then pad to target_w
      args = { "sips", "--resampleHeight", tostring(target_h), "-p", tostring(target_h), tostring(target_w), png_path, "--out", padded_png }
    else
      args = { "sips", "-p", tostring(target_h), tostring(target_w), png_path, "--out", padded_png }
    end

    vim.system(args, {}, function(obj)
      vim.schedule(function()
        if obj.code == 0 and vim.fn.filereadable(padded_png) == 1 then
          callback(padded_png)
        else
          callback(png_path)
        end
      end)
    end)
    return
  end

  -- Fallback for Linux: check magick or convert
  local has_magick = vim.fn.executable("magick") == 1
  local has_convert = not has_magick and vim.fn.executable("convert") == 1
  local cmd = has_magick and "magick" or (has_convert and "convert" or nil)

  if cmd then
    local geom = string.format("%dx%d", target_w, target_h)
    local args = {
      cmd,
      png_path,
      "-resize",
      geom .. ">",
      "-gravity",
      "center",
      "-background",
      "none",
      "-extent",
      geom,
      padded_png,
    }
    vim.system(args, {}, function(obj)
      vim.schedule(function()
        if obj.code == 0 and vim.fn.filereadable(padded_png) == 1 then
          callback(padded_png)
        else
          callback(png_path)
        end
      end)
    end)
    return
  end

  -- No external padding tool available: pass through raw png
  callback(png_path)
end

return M
