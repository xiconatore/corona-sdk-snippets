--- A PNG loader and associated functionality.
--
-- Much of this is a (stripped-down) mechanical translation from [png.js's file of the same name](https://github.com/devongovett/png.js/blob/master/png.js).

--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- [ MIT license: http://www.opensource.org/licenses/mit-license.php ]
--

-- Standard library imports --
local abs = math.abs
local assert = assert
local byte = string.byte
local char = string.char
local concat = table.concat
local floor = math.floor
local pcall = pcall
local gmatch = string.gmatch
local open = io.open
local unpack = unpack

-- Modules --
local zlib = require("loader_ops.zlib")

-- Exports --
local M = {}

-- Helper to read out N bytes
local function Read (png, n, shift, div)
	local str = assert(png:read(n), "Unable to read integer")
	local sum, mul = 0, 2^shift

	for c in gmatch(str) do
		local num = byte(c)

		if num ~= 0 then
			sum = sum + mul * num
		end

		mul = mul / 256
	end

	return sum
end

-- Reads out four bytes as an integer
local function ReadU32 (png)
	return Read(png, 4, 24)
end

--- DOCME
function M.GetDims (name)
	local png, w, h = open(name, "rb")

	if png then
		png:read(12)

		if png:read(4) == "IHDR" then
			w = ReadU32(png)
			h = ReadU32(png)
		end

		png:close()
	end

	return w ~= nil, w, h
end

--
local function DecodePalette (palette)
	local pos, decoded = 1, {}

	for i = 1, #palette, 3 do
		local r, g, b = unpack(palette, i, i + 2)

		decoded[pos], decoded[pos + 1], decoded[pos + 2], decoded[pos + 3] = r, g, b, 255

		pos = pos + 4
	end

	return decoded
end

--
local function GetCol (i, pixel_bytes)
	return (i - i % pixel_bytes) / pixel_bytes
end

--
local function GetLeft (pixels, i, pos, pixel_bytes)
	return i < pixel_bytes and 0 or pixels[pos - pixel_bytes + 1]
end

--
local function GetUpper (pixels, i, pixel_bytes, row, col, sl_len)
	return pixels[(row - 1) * sl_len + col * pixel_bytes + (i % pixel_bytes) + 1]
end

-- --
local DecodeAlgorithm = {
	-- 0 --
	function(byte)
		return byte
	end,

	-- 1 --
	function(byte, pixels, i, pos, pixel_bytes)
		return (byte + GetLeft(pixels, i, pos, pixel_bytes)) % 256
	end,

	-- 2 --
	function(byte, _, pixels, i, _, pixel_bytes, scanline_len, row)
		local col = GetCol(i, pixel_bytes)
		local upper = row > 0 and GetUpper(pixels, i, pixel_bytes, row, col, scanline_len) or 0

		return (byte + upper) % 256
	end,

	-- 3 --
	function(byte, pixels, i, pos, pixel_bytes, scanline_len, row)
		local col, left = GetCol(i, pixel_bytes), GetLeft(pixels, i, pos, pixel_bytes)
		local upper = row > 0 and GetUpper(pixels, i, pixel_bytes, row, col, scanline_len) or 0

		return (byte + floor(left + upper) / 2) % 256
	end,

	-- 4 --
	function(byte, pixels, i, pos, pixel_bytes, scanline_len, row)
		local col, left, upper, ul = GetCol(i, pixel_bytes), GetLeft(pixels, i, pos, pixel_bytes), 0, 0

		if row > 0 then
			upper = GetUpper(pixels, i, pixel_bytes, row, col, scanline_len)

			if col > 0 then
				ul = GetUpper(pixels, i, pixel_bytes, row, col - 1, scanline_len)
			end
		end

		local p, paeth = left + upper - ul
		local pa, pb, pc = abs(p - left), abs(p - upper), abs(p - ul)

		if pa <= pb and pa <= pc then
			paeth = left
		elseif pb <= pc then
			paeth = upper
		else
			paeth = ul
		end

		return (byte + paeth) % 256
	end
}

--
local function DecodePixels (data, bit_len, w, h)
	if #data == 0 then
		return {}
	end

	data = zlib.NewFlateStream(data).GetBytes()

	local pixel_bytes = bit_len / 8
	local scanline_len = pixel_bytes * w
	local pixels, len, row, pos, c = {}, #data, 0, 1, 1

	while pos <= len do
		local algo = assert(data[pos] + 1, "Invalid filter algorithm")

		pos = pos + 1
	
		for i = 1, scanline_len do
			pixels[pos], pos = algo(data[pos], pixels, i - 1, pos, pixel_bytes, scanline_len, row), pos + 1
		end

		row = row + 1
	end
end

--
local function GetIndex (pixels, palette, index, count)
	if palette then
		return pixels[index / 4 + 1] * 4 + 1
	else
		return index * count + 1
	end
end

--
local function GetColor1 (input, i, j)
	local v, alpha = unpack(input, i, j)

	return v, v, v, alpha
end

--
local function CopyToImageData (data, bit_len, colors, has_alpha, palette, n)
	local pixels, output, input = DecodePixels(data, bit_len), {}

	if palette then
		palette, colors, has_alpha = DecodePalette(palette), 4, true

		input = palette
	else
		input = pixels
	end

	local j, extra, count, get_color = 1, has_alpha and 1 or 0

	if colors == 1 then
		count, get_color = 1 + extra, GetColor1
	else
		count, get_color = 3 + extra, unpack
	end

	for i = 1, n, 4 do
		local k = GetIndex(pixels, palette, i - 1, count)
		local r, g, b, alpha = get_color(input, k, k + count - 1)

		data[i], data[i + 1], data[i + 2], data[i + 3] = r, g, b, alpha or 255
	end
end

--
local function AuxLoad (png)
	local bits, bit_len, colors, color_type, data, has_alpha, palette, w, h

	png:read(8) -- PNG signature

	while true do
		local size = ReadU32(png)
		local code = png:read(4)

		-- Image Header --
		if code == "IDHR" then
			w = ReadU32(png)
			h = ReadU32(png)
			bits = png:read(1)
			color_type = png:read(1)

			png:read(3) -- compression, filter, interlace methods

		-- Palette --
		elseif code == "PLTE" then
			palette = png:read(size)

		-- Image Data --
		elseif code == "IDAT" then
			data = data or {}

			data[#data + 1] = png:read(size)

		-- Image End --
		elseif code == "IEND" then
			data = concat(data, "")

			if color_type == 0 or color_type == 3 or color_type == 4 then
				colors = 1
			elseif color_type == 2 or color_type == 6 then
				colors = 3
			end

			has_alpha = color_type == 4 or color_type == 6
			colors = colors + (has_alpha and 1 or 0)
			bit_len = bits * colors
			
			-- color space = (colors == 1): "gray" / (colors == 3) : "rgb"

			break

		-- Default --
		else
			png:read(size)
		end

		png:read(4) -- CRC

		-- assert(seek(cur) <= seek(end), "Incomplete or corrupt PNG file")
	end

	--
	local pixels

	return function(what, arg)
		-- Get Pixels --
		if what == "get_pixels" then
			if not pixels then
				local decoded = DecodePixels(data, bit_len, w, h)

				pixels, data = pixels or CopyToImageData(decoded, colors, has_alpha, palette, w * h * 4)
			end

			return pixels

		-- Get Dimensions --
		elseif what == "get_dims" then
			return w, h

		-- NYI --
		else
			-- get frame, set frame, has alpha, etc.
		end
	end
end

--- DOCME
function M.Load (name)
	--
	local png, func = open(name, "rb")

	if png then
		local ok, result = pcall(AuxLoad, png)

		png:close()

		if ok then
			func = result
		else
			return nil, result
		end
	end

	return func
end

-- Export the module.
return M