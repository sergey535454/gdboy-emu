extends RefCounted
class_name MMU

var gb = null
var cart: Cartridge
var ppu: PPU
var timer: GBTimer
var joypad: Joypad

var cgb_mode: bool = false

# WRAM: bank 0 is fixed at 0xC000-0xCFFF; banks 1-7 are switchable at
# 0xD000-0xDFFF via SVBK (CGB only — on DMG only bank 1 of the 7 exists/used).
var wram_bank0: PackedByteArray = PackedByteArray()   # 0xC000-0xCFFF
var wram_banks: Array = []                            # 7 banks of 0x1000, index 0 = WRAM bank 1
var wram_bank_select: int = 1                         # 1-7

var hram: PackedByteArray = PackedByteArray()   # 0xFF80-0xFFFE
var io: PackedByteArray = PackedByteArray()     # misc IO regs fallback storage

var boot_rom_enabled: bool = false # we skip boot ROM (no bootrom bundled), start post-boot state

var ie_reg: int = 0
var if_reg: int = 0xE1

# Serial (stubbed, no link cable)
var sb: int = 0
var sc: int = 0

# CGB speed switch (KEY1, 0xFF4D)
var double_speed: bool = false
var key1_armed: bool = false

# CGB VRAM DMA (HDMA1-5, 0xFF51-0xFF55)
var hdma_src: int = 0
var hdma_dst: int = 0

func _init() -> void:
	wram_bank0.resize(0x1000)
	wram_bank0.fill(0)
	wram_banks.resize(7)
	for i in range(7):
		var bank: PackedByteArray = PackedByteArray()
		bank.resize(0x1000)
		bank.fill(0)
		wram_banks[i] = bank
	hram.resize(0x7F)
	hram.fill(0)
	io.resize(0x80)
	io.fill(0)

func reset_banking() -> void:
	wram_bank_select = 1
	double_speed = false
	key1_armed = false

# ---------- WRAM helpers (bank-aware, also used for echo RAM) ----------
func _wram_read(addr: int) -> int:
	# addr must already be in the 0xC000-0xDFFF logical range
	if addr < 0xD000:
		return wram_bank0[addr - 0xC000]
	else:
		var bank: PackedByteArray = wram_banks[wram_bank_select - 1]
		return bank[addr - 0xD000]

func _wram_write(addr: int, value: int) -> void:
	if addr < 0xD000:
		wram_bank0[addr - 0xC000] = value
	else:
		var bank: PackedByteArray = wram_banks[wram_bank_select - 1]
		bank[addr - 0xD000] = value

func read8(addr: int) -> int:
	addr = addr & 0xFFFF
	if addr < 0x8000:
		return cart.read_rom(addr)
	elif addr < 0xA000:
		return ppu.read_vram(addr)
	elif addr < 0xC000:
		return cart.read_ram(addr)
	elif addr < 0xE000:
		return _wram_read(addr)
	elif addr < 0xFE00:
		return _wram_read(addr - 0x2000) # echo RAM mirrors 0xC000-0xDDFF
	elif addr < 0xFEA0:
		return ppu.read_oam(addr)
	elif addr < 0xFF00:
		return 0xFF # unusable
	elif addr < 0xFF80:
		return _read_io(addr)
	elif addr < 0xFFFF:
		return hram[addr - 0xFF80]
	else:
		return ie_reg

func write8(addr: int, value: int) -> void:
	addr = addr & 0xFFFF
	value = value & 0xFF
	if addr < 0x8000:
		cart.write_rom_control(addr, value)
	elif addr < 0xA000:
		ppu.write_vram(addr, value)
	elif addr < 0xC000:
		cart.write_ram(addr, value)
	elif addr < 0xE000:
		_wram_write(addr, value)
	elif addr < 0xFE00:
		_wram_write(addr - 0x2000, value)
	elif addr < 0xFEA0:
		ppu.write_oam(addr, value)
	elif addr < 0xFF00:
		pass # unusable
	elif addr < 0xFF80:
		_write_io(addr, value)
	elif addr < 0xFFFF:
		hram[addr - 0xFF80] = value
	else:
		ie_reg = value

func read16(addr: int) -> int:
	return read8(addr) | (read8(addr + 1) << 8)

func write16(addr: int, value: int) -> void:
	write8(addr, value & 0xFF)
	write8(addr + 1, (value >> 8) & 0xFF)

func _read_io(addr: int) -> int:
	match addr:
		0xFF00:
			return joypad.read()
		0xFF01:
			return sb
		0xFF02:
			return sc
		0xFF04:
			return timer.read_div()
		0xFF05:
			return timer.tima
		0xFF06:
			return timer.tma
		0xFF07:
			return timer.tac | 0xF8
		0xFF0F:
			return if_reg | 0xE0
		0xFF4D:
			return (0x80 if double_speed else 0x00) | (0x01 if key1_armed else 0x00) | 0x7E
		0xFF55:
			return 0xFF # HDMA always reports "no active transfer" (we complete instantly)
		0xFF70:
			return wram_bank_select | 0xF8
		0xFF10, 0xFF11, 0xFF12, 0xFF13, 0xFF14, \
		0xFF16, 0xFF17, 0xFF18, 0xFF19, \
		0xFF1A, 0xFF1B, 0xFF1C, 0xFF1D, 0xFF1E, \
		0xFF20, 0xFF21, 0xFF22, 0xFF23, 0xFF24, 0xFF25, 0xFF26:
			return io[addr - 0xFF00] # APU stub: store/return only
		0xFF40, 0xFF41, 0xFF42, 0xFF43, 0xFF44, 0xFF45, 0xFF47, 0xFF48, 0xFF49, 0xFF4A, 0xFF4B, \
		0xFF4F, 0xFF68, 0xFF69, 0xFF6A, 0xFF6B:
			return ppu.read_reg(addr)
		_:
			return io[addr - 0xFF00]

func _write_io(addr: int, value: int) -> void:
	match addr:
		0xFF00:
			joypad.write_select(value)
		0xFF01:
			sb = value
		0xFF02:
			sc = value
		0xFF04:
			timer.write_div_reset()
		0xFF05:
			timer.tima = value
		0xFF06:
			timer.tma = value
		0xFF07:
			timer.tac = value & 0x07
		0xFF0F:
			if_reg = value & 0x1F
		0xFF46:
			_do_dma(value)
		0xFF4D:
			if cgb_mode:
				key1_armed = (value & 0x01) != 0
		0xFF51:
			hdma_src = (hdma_src & 0x00FF) | (value << 8)
		0xFF52:
			hdma_src = (hdma_src & 0xFF00) | (value & 0xF0)
		0xFF53:
			hdma_dst = (hdma_dst & 0x00FF) | ((value & 0x1F) << 8)
		0xFF54:
			hdma_dst = (hdma_dst & 0xFF00) | (value & 0xF0)
		0xFF55:
			_do_hdma(value)
		0xFF70:
			if cgb_mode:
				var bank: int = value & 0x07
				wram_bank_select = bank if bank != 0 else 1
		0xFF40, 0xFF41, 0xFF42, 0xFF43, 0xFF44, 0xFF45, 0xFF47, 0xFF48, 0xFF49, 0xFF4A, 0xFF4B, \
		0xFF4F, 0xFF68, 0xFF69, 0xFF6A, 0xFF6B:
			ppu.write_reg(addr, value)
		_:
			io[addr - 0xFF00] = value

func _do_dma(value: int) -> void:
	var src: int = value << 8
	for i in range(0xA0):
		var b: int = read8(src + i)
		ppu.write_oam(0xFE00 + i, b)

# General-purpose / H-Blank VRAM DMA (CGB only). Real hardware either copies
# instantly (general purpose) or in 0x10-byte chunks per H-Blank; this
# performs the whole transfer immediately in both cases, which is not
# cycle-accurate but produces correct end results for the vast majority of
# games (VRAM updates during blanking periods aren't usually observed mid-transfer).
func _do_hdma(value: int) -> void:
	if not cgb_mode:
		return
	var length: int = ((value & 0x7F) + 1) * 0x10
	var src: int = hdma_src & 0xFFF0
	var dst: int = 0x8000 + (hdma_dst & 0x1FF0)
	for i in range(length):
		var b: int = read8(src + i)
		ppu.write_vram(dst + i, b)
	hdma_src = (src + length) & 0xFFFF
	hdma_dst = 0x8000 + (((dst - 0x8000) + length) & 0x1FF0)

func request_interrupt(bit: int) -> void:
	if_reg |= (1 << bit)
