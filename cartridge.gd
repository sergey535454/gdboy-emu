extends RefCounted
class_name Cartridge

# --- Cartridge / MBC (Memory Bank Controller) ---
# Supports: ROM ONLY (0x00), MBC1, MBC1+RAM(+BATTERY), MBC3(+RAM+BATTERY+RTC), MBC5(+RAM+BATTERY)

var rom: PackedByteArray = PackedByteArray()
var ram: PackedByteArray = PackedByteArray()

var mbc_type: int = 0
var rom_bank_count: int = 2
var ram_bank_count: int = 0

var rom_bank: int = 1
var ram_bank: int = 0
var ram_enabled: bool = false
var banking_mode: int = 0 # 0 = ROM banking mode, 1 = RAM banking mode (MBC1)

var has_battery: bool = false
var save_path: String = ""
var cgb_mode: bool = false

# MBC3 RTC (very small stub: latched values only, no real wall clock accuracy)
var rtc_regs: PackedByteArray = PackedByteArray()
var rtc_latch: PackedByteArray = PackedByteArray()
var rtc_latch_state: int = -1

func load_rom(path: String) -> bool:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	rom = f.get_buffer(f.get_length())
	f.close()
	if rom.size() < 0x150:
		return false

	var cart_type: int = rom[0x147]
	var rom_size_code: int = rom[0x148]
	var ram_size_code: int = rom[0x149]
	var cgb_flag: int = rom[0x143]
	cgb_mode = cgb_flag == 0x80 or cgb_flag == 0xC0

	rom_bank_count = 2 << rom_size_code

	match ram_size_code:
		0: ram_bank_count = 0
		1: ram_bank_count = 1 # 2KB (treated as 1 bank of 8KB here for simplicity)
		2: ram_bank_count = 1 # 8KB
		3: ram_bank_count = 4 # 32KB
		4: ram_bank_count = 16 # 128KB
		5: ram_bank_count = 8 # 64KB
		_: ram_bank_count = 0

	var ram_bytes = max(ram_bank_count, 1) * 0x2000
	ram = PackedByteArray()
	ram.resize(ram_bytes)
	ram.fill(0)

	match cart_type:
		0x00:
			mbc_type = 0
		0x01, 0x02, 0x03:
			mbc_type = 1
			has_battery = cart_type == 0x03
		0x05, 0x06:
			mbc_type = 2
			has_battery = cart_type == 0x06
		0x0F, 0x10, 0x11, 0x12, 0x13:
			mbc_type = 3
			has_battery = cart_type in [0x0F, 0x10, 0x13]
			if rtc_regs.is_empty():
				rtc_regs.resize(5)
				rtc_regs.fill(0)
				rtc_latch.resize(5)
				rtc_latch.fill(0)
		0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E:
			mbc_type = 5
			has_battery = cart_type in [0x1B, 0x1E]
		_:
			mbc_type = 1 # best-effort fallback

	rom_bank = 1
	ram_bank = 0
	ram_enabled = false
	banking_mode = 0

	if has_battery:
		save_path = path.get_basename() + ".sav"
		_load_ram()

	return true

func _load_ram() -> void:
	if save_path == "" or not FileAccess.file_exists(save_path):
		return
	var f = FileAccess.open(save_path, FileAccess.READ)
	if f:
		var data = f.get_buffer(f.get_length())
		f.close()
		for i in range(min(data.size(), ram.size())):
			ram[i] = data[i]

func save_ram() -> void:
	if not has_battery or save_path == "":
		return
	var f = FileAccess.open(save_path, FileAccess.WRITE)
	if f:
		f.store_buffer(ram)
		f.close()

func read_rom(addr: int) -> int:
	if addr < 0x4000:
		return rom[addr] if addr < rom.size() else 0xFF
	else:
		var offset: int = (rom_bank * 0x4000) + (addr - 0x4000)
		return rom[offset] if offset < rom.size() else 0xFF

func write_rom_control(addr: int, value: int) -> void:
	match mbc_type:
		0:
			pass # no banking, ignore writes
		1:
			_mbc1_write(addr, value)
		2:
			_mbc2_write(addr, value)
		3:
			_mbc3_write(addr, value)
		5:
			_mbc5_write(addr, value)

func _mbc1_write(addr: int, value: int) -> void:
	if addr < 0x2000:
		ram_enabled = (value & 0x0F) == 0x0A
	elif addr < 0x4000:
		var bank: int = value & 0x1F
		if bank == 0:
			bank = 1
		rom_bank = (rom_bank & 0x60) | bank
		rom_bank = rom_bank % rom_bank_count
		if rom_bank == 0:
			rom_bank = 1
	elif addr < 0x6000:
		var bits: int = value & 0x03
		if banking_mode == 0:
			rom_bank = (rom_bank & 0x1F) | (bits << 5)
			rom_bank = rom_bank % rom_bank_count
			if rom_bank == 0:
				rom_bank = 1
		else:
			ram_bank = bits
	else:
		banking_mode = value & 0x01

func _mbc2_write(addr: int, value: int) -> void:
	if addr < 0x4000:
		if addr & 0x0100 == 0:
			ram_enabled = (value & 0x0F) == 0x0A
		else:
			var bank: int = value & 0x0F
			if bank == 0:
				bank = 1
			rom_bank = bank % rom_bank_count

func _mbc3_write(addr: int, value: int) -> void:
	if addr < 0x2000:
		ram_enabled = (value & 0x0F) == 0x0A
	elif addr < 0x4000:
		var bank: int = value & 0x7F
		if bank == 0:
			bank = 1
		rom_bank = bank % rom_bank_count
	elif addr < 0x6000:
		ram_bank = value # 0x00-0x03 RAM banks, 0x08-0x0C RTC registers
	else:
		if value == 0x01 and rtc_latch_state == 0x00:
			for i in range(5):
				rtc_latch[i] = rtc_regs[i]
		rtc_latch_state = value

func _mbc5_write(addr: int, value: int) -> void:
	if addr < 0x2000:
		ram_enabled = (value & 0x0F) == 0x0A
	elif addr < 0x3000:
		rom_bank = (rom_bank & 0x100) | value
		rom_bank = rom_bank % max(rom_bank_count, 1)
	elif addr < 0x4000:
		rom_bank = (rom_bank & 0xFF) | ((value & 0x01) << 8)
		rom_bank = rom_bank % max(rom_bank_count, 1)
	elif addr < 0x6000:
		ram_bank = value & 0x0F

func read_ram(addr: int) -> int:
	if not ram_enabled:
		return 0xFF
	if mbc_type == 3 and ram_bank >= 0x08:
		var idx: int = ram_bank - 0x08
		if idx < 5:
			return rtc_latch[idx]
		return 0xFF
	var offset: int = (ram_bank * 0x2000) + (addr - 0xA000)
	if offset >= 0 and offset < ram.size():
		return ram[offset]
	return 0xFF

func write_ram(addr: int, value: int) -> void:
	if not ram_enabled:
		return
	if mbc_type == 3 and ram_bank >= 0x08:
		var idx: int = ram_bank - 0x08
		if idx < 5:
			rtc_regs[idx] = value
		return
	var offset: int = (ram_bank * 0x2000) + (addr - 0xA000)
	if offset >= 0 and offset < ram.size():
		ram[offset] = value
