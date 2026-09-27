extends RefCounted
class_name Gameboy

const CYCLES_PER_FRAME: int = 70224 # 4194304 Hz / 59.7 fps, in real (single-speed) T-cycles

var cpu: CPU
var mmu: MMU
var ppu: PPU
var timer: GBTimer
var joypad: Joypad
var cart: Cartridge

var loaded: bool = false

func _init() -> void:
	cpu = CPU.new()
	mmu = MMU.new()
	ppu = PPU.new()
	timer = GBTimer.new()
	joypad = Joypad.new()
	cart = Cartridge.new()

	cpu.gb = self
	cpu.mmu = mmu
	mmu.gb = self
	mmu.cart = cart
	mmu.ppu = ppu
	mmu.timer = timer
	mmu.joypad = joypad
	ppu.gb = self
	timer.gb = self
	joypad.gb = self

func request_interrupt(bit: int) -> void:
	mmu.if_reg |= (1 << bit)

func load_rom(path: String) -> bool:
	var ok: bool = cart.load_rom(path)
	if ok:
		mmu.cgb_mode = cart.cgb_mode
		ppu.cgb_mode = cart.cgb_mode
		cpu.reset(cart.cgb_mode)
		ppu.reset()
		timer.reset()
		mmu.reset_banking()
		mmu.if_reg = 0xE1
		mmu.ie_reg = 0x00
		loaded = true
	return ok

func run_frame() -> void:
	if not loaded:
		return
	var cycles_done: int = 0
	while cycles_done < CYCLES_PER_FRAME:
		var c: int = cpu.step()
		if c <= 0:
			c = 4
		# In CGB double-speed mode the CPU clock doubles, but the PPU/timer
		# keep running at the original real-world rate — so only half of the
		# CPU's raw T-cycles count towards real time (letting roughly twice
		# as many instructions execute per rendered frame).
		var real_c: int = c
		if mmu.double_speed:
			real_c = c >> 1
			if real_c <= 0:
				real_c = 1
		ppu.step(real_c)
		timer.step(real_c)
		cycles_done += real_c

func save() -> void:
	if loaded:
		cart.save_ram()

func get_display_texture() -> ImageTexture:
	return ppu.texture
