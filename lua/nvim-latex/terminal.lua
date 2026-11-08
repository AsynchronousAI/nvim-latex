local config = require("nvim-latex.config")

local M = {}

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- stylua: ignore
local diacritics = vim.split(
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244",
  ","
)

local positions = {}
setmetatable(positions, {
  __index = function(_, k)
    if diacritics[k] then
      positions[k] = vim.fn.nr2char(tonumber(diacritics[k], 16))
      return positions[k]
    end
    return ""
  end,
})

local _next_id = 100

--- Generate a unique 24-bit image ID
function M.next_image_id()
  _next_id = _next_id + 1
  if _next_id > 0xFFFFFF then
    _next_id = 100
  end
  return _next_id
end

--- Check if running in a Kitty-compatible graphics terminal
function M.is_supported()
  local term_prog = vim.env.TERM_PROGRAM or ""
  local term = vim.env.TERM or ""
  if term_prog == "ghostty" or term_prog == "kitty" or vim.env.KITTY_WINDOW_ID then
    return true
  end
  if term:find("kitty") or term:find("ghostty") or term:find("wezterm") then
    return true
  end
  return true -- optimistic default for modern terminals
end

--- Query character cell dimensions (pixels) via ioctl
function M.get_cell_size()
  local cell_w = config.options.cell_width or 9
  local cell_h = config.options.cell_height or 18

  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return cell_w, cell_h
  end

  pcall(function()
    ffi.cdef([[
      typedef struct {
        unsigned short row;
        unsigned short col;
        unsigned short xpixel;
        unsigned short ypixel;
      } winsize;
      int ioctl(int, int, ...);
    ]])

    local TIOCGWINSZ = (vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1) and 0x40087468 or 0x5413
    local sz = ffi.new("winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, sz) == 0 and sz.col > 0 and sz.row > 0 and sz.xpixel > 0 and sz.ypixel > 0 then
      cell_w = sz.xpixel / sz.col
      cell_h = sz.ypixel / sz.row
    end
  end)

  return cell_w, cell_h
end

--- Send raw data to terminal UI
function M.write(data)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    io.stdout:write(data)
    io.stdout:flush()
  end
end

--- Transmit PNG to terminal memory and create a virtual placement
---@param id number 24-bit image ID
---@param png_path string Path to PNG file on disk
---@param cols number Number of columns (cells)
---@param rows number Number of rows (cells)
function M.transmit_and_place(id, png_path, cols, rows)
  local f = io.open(png_path, "rb")
  if not f then
    return false
  end
  local bytes = f:read("*a")
  f:close()

  if not bytes or #bytes == 0 then
    return false
  end

  local b64 = vim.base64.encode(bytes)
  local chunk_size = 4096

  if #b64 <= chunk_size then
    local seq = string.format("\027_Ga=T,f=100,t=d,i=%d,c=%d,r=%d,U=1,q=2;%s\027\\", id, cols, rows, b64)
    M.write(seq)
  else
    local offset = 1
    local total = #b64
    local first = true
    while offset <= total do
      local chunk = b64:sub(offset, offset + chunk_size - 1)
      offset = offset + chunk_size
      local last = offset > total
      local m = last and 0 or 1
      if first then
        local seq = string.format("\027_Ga=T,f=100,t=d,i=%d,c=%d,r=%d,U=1,m=%d,q=2;%s\027\\", id, cols, rows, m, chunk)
        M.write(seq)
        first = false
      else
        local seq = string.format("\027_Gm=%d;%s\027\\", m, chunk)
        M.write(seq)
      end
    end
  end

  return true
end

--- Delete an image from terminal memory
---@param id number
function M.delete_image(id)
  local seq = string.format("\027_Ga=d,d=i,i=%d,q=2\027\\", id)
  M.write(seq)
end

--- Create the Unicode placeholder text grid and highlight group for an image
---@param id number
---@param cols number
---@param rows number
---@return string[] lines Array of placeholder strings for each row
---@return string hl_group Name of the highlight group carrying the image ID
function M.create_placeholder_grid(id, cols, rows)
  local hl_group = "NvimLatex_" .. id
  -- In Kitty protocol, the foreground color of the placeholder cell carries the image ID
  vim.api.nvim_set_hl(0, hl_group, {
    fg = id,
    nocombine = true,
  })

  local lines = {}
  local h = math.min(#diacritics, math.max(1, rows))
  local w = math.min(#diacritics, math.max(1, cols))

  for r = 1, h do
    local row_chars = {}
    for c = 1, w do
      row_chars[#row_chars + 1] = PLACEHOLDER
      row_chars[#row_chars + 1] = positions[r]
      row_chars[#row_chars + 1] = positions[c]
    end
    lines[#lines + 1] = table.concat(row_chars)
  end

  return lines, hl_group
end

return M
