extends RefCounted
class_name PPU

const SCREEN_W: int = 160
const SCREEN_H: int = 144

# LCD Control (0xFF40) bits
const LCDC_BG_ENABLE: int       = 0x01 # in CGB mode this doubles as "BG/OBJ master priority"
const LCDC_OBJ_ENABLE: int      = 0x02
const LCDC_OBJ_SIZE: int        = 0x04
const LCDC_BG_TILEMAP: int      = 0x08
const LCDC_BG_WIN_TILEDATA: int = 0x10
const LCDC_WIN_ENABLE: int      = 0x20
const LCDC_WIN_TILEMAP: int     = 0x40
const LCDC_LCD_ENABLE: int      = 0x80

var cgb_mode: bool = false

# VRAM: 2 banks of 0x2000 bytes each on CGB (bank 0 only is used/relevant on DMG)
var vram: PackedByteArray = PackedByteArray()
var vram_bank: int = 0
var oam: PackedByteArray = PackedByteArray()

var lcdc: int = 0x91
var stat: int = 0x85
var scy: int = 0
var scx: int = 0
var ly: int = 0
var lyc: int = 0
var bgp: int = 0xFC
var obp0: int = 0xFF
var obp1: int = 0xFF
var wy: int = 0
var wx: int = 0

# --- CGB palette memory: 8 palettes x 4 colors x 2 bytes (RGB555, little endian) ---
var bg_palette_ram: PackedByteArray = PackedByteArray()
var obj_palette_ram: PackedByteArray = PackedByteArray()
var bcps_index: int = 0
var bcps_autoinc: bool = false
var ocps_index: int = 0
var ocps_autoinc: bool = false

var mode: int = 2 # 0=HBlank 1=VBlank 2=OAM 3=Transfer
var mode_clock: int = 0
var window_line: int = 0

var gb = null

# framebuffer: SCREEN_W*SCREEN_H pixels, 3 bytes (R,G,B) each — used for both
# DMG (grayscale written as R=G=B) and CGB (real colors) so the rest of the
# app (Image/TextureRect) doesn't need to care which mode is active.
var framebuffer: PackedByteArray = PackedByteArray()
var image: Image
var texture: ImageTexture

# reusable per-scanline scratch buffers (avoid per-line allocation)
var _line_rgb: PackedByteArray = PackedByteArray()      # SCREEN_W * 3
var _line_colorid: PackedByteArray = PackedByteArray()  # SCREEN_W, raw 2-bit BG/window color index (0-3)
var _line_bgpriority: PackedByteArray = PackedByteArray() # SCREEN_W, CGB BG-to-OBJ priority attribute bit

const SHADES: PackedInt32Array = [255, 170, 85, 0] # DMG 0=white .. 3=black grayscale

func _init() -> void:
	vram.resize(0x4000) # 2 banks x 0x2000
	vram.fill(0)
	oam.resize(0xA0)
	oam.fill(0)
	framebuffer.resize(SCREEN_W * SCREEN_H * 3)
	framebuffer.fill(0)
	_line_rgb.resize(SCREEN_W * 3)
	_line_colorid.resize(SCREEN_W)
	_line_bgpriority.resize(SCREEN_W)
	bg_palette_ram.resize(64)
	bg_palette_ram.fill(0xFF)
	obj_palette_ram.resize(64)
	obj_palette_ram.fill(0xFF)
	image = Image.create(SCREEN_W, SCREEN_H, false, Image.FORMAT_RGB8)
	texture = ImageTexture.create_from_image(image)

func reset() -> void:
	lcdc = 0x91
	stat = 0x85
	scy = 0; scx = 0; ly = 0; lyc = 0
	bgp = 0xFC; obp0 = 0xFF; obp1 = 0xFF
	wy = 0; wx = 0
	mode = 2
	mode_clock = 0
	window_line = 0
	vram_bank = 0
	bcps_index = 0; bcps_autoinc = false
	ocps_index = 0; ocps_autoinc = false

# ---------- VRAM access (bank-aware) ----------
func read_vram(addr: int) -> int:
	return vram[vram_bank * 0x2000 + (addr - 0x8000)]

func write_vram(addr: int, value: int) -> void:
	vram[vram_bank * 0x2000 + (addr - 0x8000)] = value

# Internal helper: read a specific bank regardless of the VBK-selected bank.
# Needed because CGB tile attributes always live in bank 1 while the tile
# number for the same map cell always lives in bank 0.
func _vram_bank_byte(bank: int, addr: int) -> int:
	return vram[bank * 0x2000 + (addr - 0x8000)]

func read_oam(addr: int) -> int:
	return oam[addr - 0xFE00]

func write_oam(addr: int, value: int) -> void:
	oam[addr - 0xFE00] = value

func read_reg(addr: int) -> int:
	match addr:
		0xFF40: return lcdc
		0xFF41: return stat | mode | (0x04 if ly == lyc else 0)
		0xFF42: return scy
		0xFF43: return scx
		0xFF44: return ly
		0xFF45: return lyc
		0xFF47: return bgp
		0xFF48: return obp0
		0xFF49: return obp1
		0xFF4A: return wy
		0xFF4B: return wx
		0xFF4F: return vram_bank | 0xFE
		0xFF68: return bcps_index | (0x80 if bcps_autoinc else 0) | 0x40
		0xFF69: return bg_palette_ram[bcps_index]
		0xFF6A: return ocps_index | (0x80 if ocps_autoinc else 0) | 0x40
		0xFF6B: return obj_palette_ram[ocps_index]
	return 0xFF

func write_reg(addr: int, value: int) -> void:
	match addr:
		0xFF40:
			var was_enabled: bool = (lcdc & LCDC_LCD_ENABLE) != 0
			lcdc = value
			if not was_enabled and (lcdc & LCDC_LCD_ENABLE) != 0:
				ly = 0
				mode_clock = 0
				mode = 2
		0xFF41: stat = value & 0xF8
		0xFF42: scy = value
		0xFF43: scx = value
		0xFF44: pass # read-only
		0xFF45: lyc = value
		0xFF47: bgp = value
		0xFF48: obp0 = value
		0xFF49: obp1 = value
		0xFF4A: wy = value
		0xFF4B: wx = value
		0xFF4F:
			if cgb_mode:
				vram_bank = value & 0x01
		0xFF68:
			bcps_index = value & 0x3F
			bcps_autoinc = (value & 0x80) != 0
		0xFF69:
			bg_palette_ram[bcps_index] = value
			if bcps_autoinc:
				bcps_index = (bcps_index + 1) & 0x3F
		0xFF6A:
			ocps_index = value & 0x3F
			ocps_autoinc = (value & 0x80) != 0
		0xFF6B:
			obj_palette_ram[ocps_index] = value
			if ocps_autoinc:
				ocps_index = (ocps_index + 1) & 0x3F

# Converts a CGB palette entry (RGB555) to 0-255 RGB components.
func _cgb_color(ram: PackedByteArray, palette_num: int, color_id: int) -> Vector3i:
	var idx: int = (palette_num * 8) + (color_id * 2)
	var lo: int = ram[idx]
	var hi: int = ram[idx + 1]
	var word: int = lo | (hi << 8)
	var r5: int = word & 0x1F
	var g5: int = (word >> 5) & 0x1F
	var b5: int = (word >> 10) & 0x1F
	return Vector3i((r5 * 255) / 31, (g5 * 255) / 31, (b5 * 255) / 31)

# Called with T-cycles elapsed; steps the PPU state machine and draws lines.
func step(cycles: int) -> void:
	if lcdc & LCDC_LCD_ENABLE == 0:
		return
	mode_clock += cycles
	match mode:
		2: # OAM search (80 cycles)
			if mode_clock >= 80:
				mode_clock -= 80
				mode = 3
		3: # Pixel transfer (172 cycles)
			if mode_clock >= 172:
				mode_clock -= 172
				mode = 0
				_render_scanline()
				if stat & 0x08:
					gb.request_interrupt(1) # LCD STAT
		0: # HBlank (204 cycles)
			if mode_clock >= 204:
				mode_clock -= 204
				ly += 1
				if ly == 144:
					mode = 1
					gb.request_interrupt(0) # VBlank
					if stat & 0x10:
						gb.request_interrupt(1)
					_flush_frame()
				else:
					mode = 2
					if stat & 0x20:
						gb.request_interrupt(1)
				_check_lyc()
		1: # VBlank (10 lines * 456 cycles)
			if mode_clock >= 456:
				mode_clock -= 456
				ly += 1
				if ly > 153:
					ly = 0
					window_line = 0
					mode = 2
					if stat & 0x20:
						gb.request_interrupt(1)
				_check_lyc()

func _check_lyc() -> void:
	if ly == lyc and stat & 0x40:
		gb.request_interrupt(1)

func _render_scanline() -> void:
	if ly >= SCREEN_H:
		return
	_line_rgb.fill(0)
	_line_colorid.fill(0)
	_line_bgpriority.fill(0)

	if lcdc & LCDC_BG_ENABLE or cgb_mode:
		# On CGB, LCDC bit0 no longer disables the background (it becomes the
		# BG/OBJ master-priority switch instead), so BG/window always render;
		# on DMG it still gates BG/window rendering entirely.
		_render_bg_line()
		if lcdc & LCDC_WIN_ENABLE:
			_render_window_line()
	if lcdc & LCDC_OBJ_ENABLE:
		_render_sprites_line()

	var row_start: int = ly * SCREEN_W * 3
	for i in range(SCREEN_W * 3):
		framebuffer[row_start + i] = _line_rgb[i]

func _bg_palette_shade(color_id: int, palette: int) -> int:
	var shade: int = (palette >> (color_id * 2)) & 0x03
	return shade

func _render_bg_line() -> void:
	var tile_map_base: int = 0x9C00 if (lcdc & LCDC_BG_TILEMAP) else 0x9800
	var y: int = (ly + scy) & 0xFF
	var tile_row: int = y >> 3

	if not cgb_mode:
		var line_in_tile: int = y % 8
		for x in range(SCREEN_W):
			var scrolled_x: int = (x + scx) & 0xFF
			var tile_col: int = scrolled_x >> 3
			var map_addr: int = tile_map_base + tile_row * 32 + tile_col
			var tile_num: int = read_vram(map_addr)
			var tile_addr: int = _tile_data_addr(tile_num)
			var b1: int = read_vram(tile_addr + line_in_tile * 2)
			var b2: int = read_vram(tile_addr + line_in_tile * 2 + 1)
			var bit: int = 7 - (scrolled_x % 8)
			var color_id: int = ((b2 >> bit) & 1) << 1 | ((b1 >> bit) & 1)
			var shade: int = SHADES[_bg_palette_shade(color_id, bgp)]
			_line_rgb[x * 3] = shade
			_line_rgb[x * 3 + 1] = shade
			_line_rgb[x * 3 + 2] = shade
			_line_colorid[x] = color_id
		return

	# --- CGB path: per-tile attributes (palette, bank, flips, priority) ---
	for x in range(SCREEN_W):
		var scrolled_x: int = (x + scx) & 0xFF
		var tile_col: int = scrolled_x >> 3
		var map_addr: int = tile_map_base + tile_row * 32 + tile_col
		var tile_num: int = _vram_bank_byte(0, map_addr)
		var attr: int = _vram_bank_byte(1, map_addr)
		var palette_num: int = attr & 0x07
		var tile_bank: int = (attr >> 3) & 0x01
		var xflip: bool = (attr & 0x20) != 0
		var yflip: bool = (attr & 0x40) != 0
		var priority: int = 1 if (attr & 0x80) != 0 else 0

		var line_in_tile: int = (7 - (y % 8)) if yflip else (y % 8)
		var tile_addr: int = _tile_data_addr(tile_num)
		var b1: int = _vram_bank_byte(tile_bank, tile_addr + line_in_tile * 2)
		var b2: int = _vram_bank_byte(tile_bank, tile_addr + line_in_tile * 2 + 1)
		var px_in_tile: int = scrolled_x % 8
		var bit: int = px_in_tile if xflip else (7 - px_in_tile)
		var color_id: int = ((b2 >> bit) & 1) << 1 | ((b1 >> bit) & 1)
		var rgb: Vector3i = _cgb_color(bg_palette_ram, palette_num, color_id)
		_line_rgb[x * 3] = rgb.x
		_line_rgb[x * 3 + 1] = rgb.y
		_line_rgb[x * 3 + 2] = rgb.z
		_line_colorid[x] = color_id
		_line_bgpriority[x] = priority

func _render_window_line() -> void:
	if ly < wy:
		return
	var wx_pos: int = wx - 7
	if wx_pos >= SCREEN_W:
		return
	var tile_map_base: int = 0x9C00 if (lcdc & LCDC_WIN_TILEMAP) else 0x9800
	var y: int = window_line
	var tile_row: int = y >> 3
	var drew_any: bool = false

	if not cgb_mode:
		var line_in_tile: int = y % 8
		for x in range(max(wx_pos, 0), SCREEN_W):
			var win_x: int = x - wx_pos
			var tile_col: int = win_x >> 3
			var map_addr: int = tile_map_base + tile_row * 32 + tile_col
			var tile_num: int = read_vram(map_addr)
			var tile_addr: int = _tile_data_addr(tile_num)
			var b1: int = read_vram(tile_addr + line_in_tile * 2)
			var b2: int = read_vram(tile_addr + line_in_tile * 2 + 1)
			var bit: int = 7 - (win_x % 8)
			var color_id: int = ((b2 >> bit) & 1) << 1 | ((b1 >> bit) & 1)
			var shade: int = SHADES[_bg_palette_shade(color_id, bgp)]
			_line_rgb[x * 3] = shade
			_line_rgb[x * 3 + 1] = shade
			_line_rgb[x * 3 + 2] = shade
			_line_colorid[x] = color_id
			drew_any = true
		if drew_any:
			window_line += 1
		return

	for x in range(max(wx_pos, 0), SCREEN_W):
		var win_x: int = x - wx_pos
		var tile_col: int = win_x >> 3
		var map_addr: int = tile_map_base + tile_row * 32 + tile_col
		var tile_num: int = _vram_bank_byte(0, map_addr)
		var attr: int = _vram_bank_byte(1, map_addr)
		var palette_num: int = attr & 0x07
		var tile_bank: int = (attr >> 3) & 0x01
		var xflip: bool = (attr & 0x20) != 0
		var yflip: bool = (attr & 0x40) != 0
		var priority: int = 1 if (attr & 0x80) != 0 else 0

		var line_in_tile: int = (7 - (y % 8)) if yflip else (y % 8)
		var tile_addr: int = _tile_data_addr(tile_num)
		var b1: int = _vram_bank_byte(tile_bank, tile_addr + line_in_tile * 2)
		var b2: int = _vram_bank_byte(tile_bank, tile_addr + line_in_tile * 2 + 1)
		var px_in_tile: int = win_x % 8
		var bit: int = px_in_tile if xflip else (7 - px_in_tile)
		var color_id: int = ((b2 >> bit) & 1) << 1 | ((b1 >> bit) & 1)
		var rgb: Vector3i = _cgb_color(bg_palette_ram, palette_num, color_id)
		_line_rgb[x * 3] = rgb.x
		_line_rgb[x * 3 + 1] = rgb.y
		_line_rgb[x * 3 + 2] = rgb.z
		_line_colorid[x] = color_id
		_line_bgpriority[x] = priority
		drew_any = true
	if drew_any:
		window_line += 1

func _tile_data_addr(tile_num: int) -> int:
	if lcdc & LCDC_BG_WIN_TILEDATA:
		return 0x8000 + tile_num * 16
	else:
		var signed_num: int = tile_num
		if signed_num >= 128:
			signed_num -= 256
		return 0x9000 + signed_num * 16

func _render_sprites_line() -> void:
	var sprite_height: int = 16 if (lcdc & LCDC_OBJ_SIZE) else 8
	var sprites_on_line: Array[int] = []
	for i in range(40):
		var base: int = i * 4
		var sy: int = oam[base] - 16
		if ly >= sy and ly < sy + sprite_height:
			sprites_on_line.append(i)
			if sprites_on_line.size() >= 10:
				break
	# Draw in reverse OAM order so sprite 0 has highest priority (drawn last/on top)
	sprites_on_line.reverse()
	var master_priority: bool = (lcdc & LCDC_BG_ENABLE) != 0

	for i in sprites_on_line:
		var base: int = i * 4
		var sy: int = oam[base] - 16
		var sx: int = oam[base + 1] - 8
		var tile_num: int = oam[base + 2]
		var flags: int = oam[base + 3]
		var flip_x: bool = (flags & 0x20) != 0
		var flip_y: bool = (flags & 0x40) != 0
		var behind_bg: bool = (flags & 0x80) != 0

		var tile_bank: int = 0
		var cgb_palette_num: int = 0
		var palette: int = obp1 if (flags & 0x10) else obp0
		if cgb_mode:
			cgb_palette_num = flags & 0x07
			tile_bank = (flags >> 3) & 0x01

		if sprite_height == 16:
			tile_num &= 0xFE

		var line_in_sprite: int = ly - sy
		if flip_y:
			line_in_sprite = sprite_height - 1 - line_in_sprite

		var actual_tile: int = tile_num
		var line_offset: int = line_in_sprite
		if sprite_height == 16 and line_in_sprite >= 8:
			actual_tile = tile_num + 1
			line_offset = line_in_sprite - 8

		var tile_addr: int = 0x8000 + actual_tile * 16
		var b1: int = _vram_bank_byte(tile_bank, tile_addr + line_offset * 2)
		var b2: int = _vram_bank_byte(tile_bank, tile_addr + line_offset * 2 + 1)

		for px in range(8):
			var sxp: int = sx + px
			if sxp < 0 or sxp >= SCREEN_W:
				continue
			var bit: int = px if flip_x else (7 - px)
			var color_id: int = ((b2 >> bit) & 1) << 1 | ((b1 >> bit) & 1)
			if color_id == 0:
				continue # transparent

			var bg_wins: bool = false
			if cgb_mode:
				if master_priority:
					if _line_bgpriority[sxp] == 1 and _line_colorid[sxp] != 0:
						bg_wins = true
					elif behind_bg and _line_colorid[sxp] != 0:
						bg_wins = true
				# if master_priority is false, sprites are always drawn on top
			else:
				if behind_bg and _line_colorid[sxp] != 0:
					bg_wins = true
			if bg_wins:
				continue

			if cgb_mode:
				var rgb: Vector3i = _cgb_color(obj_palette_ram, cgb_palette_num, color_id)
				_line_rgb[sxp * 3] = rgb.x
				_line_rgb[sxp * 3 + 1] = rgb.y
				_line_rgb[sxp * 3 + 2] = rgb.z
			else:
				var shade: int = SHADES[_bg_palette_shade(color_id, palette)]
				_line_rgb[sxp * 3] = shade
				_line_rgb[sxp * 3 + 1] = shade
				_line_rgb[sxp * 3 + 2] = shade

func _flush_frame() -> void:
	# framebuffer already holds RGB triplets matching FORMAT_RGB8 exactly,
	# so we can hand it straight to the Image instead of calling set_pixel().
	image.set_data(SCREEN_W, SCREEN_H, false, Image.FORMAT_RGB8, framebuffer)
	texture.update(image)
