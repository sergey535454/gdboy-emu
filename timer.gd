extends RefCounted
class_name GBTimer

var div_counter: int = 0   # internal 16-bit counter, DIV = high byte
var tima: int = 0
var tma: int = 0
var tac: int = 0

const FREQ_DIVIDERS: PackedInt32Array = [1024, 16, 64, 256]

var gb = null # back-reference to Gameboy, set externally, for interrupt requests

func reset() -> void:
	div_counter = 0
	tima = 0
	tma = 0
	tac = 0

func read_div() -> int:
	return (div_counter >> 8) & 0xFF

func write_div_reset() -> void:
	div_counter = 0

func step(cycles: int) -> void:
	div_counter = (div_counter + cycles) & 0xFFFF
	if tac & 0x04 == 0:
		return
	var freq: int = FREQ_DIVIDERS[tac & 0x03]
	# approximate: step in chunks based on cycles passed
	_ticks_accum += cycles
	while _ticks_accum >= freq:
		_ticks_accum -= freq
		tima += 1
		if tima > 0xFF:
			tima = tma
			if gb:
				gb.request_interrupt(2) # Timer interrupt bit

var _ticks_accum: int = 0
