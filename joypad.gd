extends RefCounted
class_name Joypad

# Bit layout of buttons (1 = pressed, stored inverted for register read)
var up: bool = false
var down: bool = false
var left: bool = false
var right: bool = false
var a: bool = false
var b: bool = false
var start: bool = false
var select: bool = false

var select_buttons: bool = false # P14 - select action buttons (A,B,Select,Start)
var select_dpad: bool = false    # P15 - select direction keys

var gb = null

func write_select(value: int) -> void:
	select_buttons = (value & 0x20) == 0
	select_dpad = (value & 0x10) == 0

func read() -> int:
	var result = 0xC0 # bits 6,7 always set
	if select_buttons:
		result |= 0x20
		if not a: result |= 0x01
		if not b: result |= 0x02
		if not select: result |= 0x04
		if not start: result |= 0x08
	elif select_dpad:
		result |= 0x10
		if not right: result |= 0x01
		if not left: result |= 0x02
		if not up: result |= 0x04
		if not down: result |= 0x08
	else:
		result |= 0x0F
	return result

func set_button(name: String, pressed: bool) -> void:
	match name:
		"up": up = pressed
		"down": down = pressed
		"left": left = pressed
		"right": right = pressed
		"a": a = pressed
		"b": b = pressed
		"start": start = pressed
		"select": select = pressed
	if pressed and gb:
		gb.request_interrupt(4) # Joypad interrupt bit
