extends Control

const CPU_SCRIPT = preload("res://scripts/emulator/cpu.gd")
const MMU_SCRIPT = preload("res://scripts/emulator/mmu.gd")
const PPU_SCRIPT = preload("res://scripts/emulator/ppu.gd")
const TIMER_SCRIPT = preload("res://scripts/emulator/timer.gd")
const JOYPAD_SCRIPT = preload("res://scripts/emulator/joypad.gd")
const CART_SCRIPT = preload("res://scripts/emulator/cartridge.gd")
const GAMEBOY_SCRIPT = preload("res://scripts/emulator/gameboy.gd")

var gb # Gameboy
var screen_rect: TextureRect
var status_label: Label
var load_button: Button
var file_dialog: FileDialog
var paused: bool = false

var roms_dir: String = "user://roms"

# --- Multitouch on-screen controls ---
# Buttons are purely visual (mouse_filter = IGNORE); all press/release logic
# is handled manually in _input() so multiple fingers can hold multiple
# buttons at once (e.g. D-pad + A) without Godot's single-pointer Button
# click logic dropping presses.
var _control_nodes: Dictionary = {}   # action name -> Control (for rect + visual feedback)
var _control_base_color: Dictionary = {} # action name -> base Color for visual feedback
var _touch_owner: Dictionary = {}     # touch/mouse index -> action name currently held by that pointer

const MOUSE_POINTER_ID: int = -1 # synthetic "touch index" used for emulated mouse input

func _ready() -> void:
	OS.request_permissions()
	DirAccess.make_dir_recursive_absolute(roms_dir)

	gb = GAMEBOY_SCRIPT.new()

	_build_ui()
	get_tree().get_root().connect("close_requested", Callable(self, "_on_close_requested"))

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg = ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.13)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	# --- Top bar ---
	var topbar = HBoxContainer.new()
	topbar.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(topbar)

	load_button = Button.new()
	load_button.text = "Загрузить ROM"
	load_button.custom_minimum_size = Vector2(200, 48)
	load_button.pressed.connect(_on_load_pressed)
	topbar.add_child(load_button)

	var pause_button = Button.new()
	pause_button.text = "Пауза"
	pause_button.custom_minimum_size = Vector2(120, 48)
	pause_button.pressed.connect(_on_pause_pressed)
	topbar.add_child(pause_button)

	status_label = Label.new()
	status_label.text = "ROM не загружен. Поместите .gb/.gbc файл в: %s (или нажмите Загрузить ROM)" % ProjectSettings.globalize_path(roms_dir)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	status_label.custom_minimum_size = Vector2(0, 40)
	vbox.add_child(status_label)

	# --- Screen ---
	var screen_container = CenterContainer.new()
	screen_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(screen_container)

	screen_rect = TextureRect.new()
	screen_rect.custom_minimum_size = Vector2(320, 288) # 2x native GB res
	screen_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	screen_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	screen_container.add_child(screen_rect)

	# --- Touch controls ---
	var controls = Control.new()
	controls.custom_minimum_size = Vector2(0, 260)
	vbox.add_child(controls)
	_build_touch_controls(controls)

	# --- File dialog ---
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(["*.gb,*.gbc;Game Boy ROM"])
	file_dialog.current_dir = ProjectSettings.globalize_path(roms_dir)
	file_dialog.size = Vector2(600, 500)
	file_dialog.file_selected.connect(_on_file_selected)
	add_child(file_dialog)

func _build_touch_controls(parent: Control) -> void:
	# D-Pad (bottom-left, cross layout)
	var dpad = Control.new()
	dpad.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	dpad.position = Vector2(20, -240)
	dpad.custom_minimum_size = Vector2(180, 180)
	parent.add_child(dpad)

	_make_dpad_button(dpad, "▲", Vector2(60, 0), "up")
	_make_dpad_button(dpad, "▼", Vector2(60, 120), "down")
	_make_dpad_button(dpad, "◀", Vector2(0, 60), "left")
	_make_dpad_button(dpad, "▶", Vector2(120, 60), "right")

	# A / B buttons (bottom-right)
	var abbtns = Control.new()
	abbtns.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	abbtns.position = Vector2(-200, -240)
	abbtns.custom_minimum_size = Vector2(200, 180)
	parent.add_child(abbtns)

	_make_round_button(abbtns, "B", Vector2(10, 90), "b", Color(0.6, 0.2, 0.2))
	_make_round_button(abbtns, "A", Vector2(110, 30), "a", Color(0.2, 0.4, 0.6))

	# Start / Select (bottom-center)
	var ss = HBoxContainer.new()
	ss.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	ss.position = Vector2(-90, -40)
	ss.add_theme_constant_override("separation", 20)
	parent.add_child(ss)

	_make_pill_button(ss, "SELECT", "select")
	_make_pill_button(ss, "START", "start")

func _register_control(action: String, btn: Control, base_color: Color) -> void:
	# Purely visual from here on: raw touch/mouse handling in _input() drives
	# the actual button state, so Godot's Control click logic never sees it.
	btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_control_nodes[action] = btn
	_control_base_color[action] = base_color

func _make_dpad_button(parent: Control, label: String, pos: Vector2, action: String) -> void:
	var btn = Button.new()
	btn.text = label
	btn.position = pos
	btn.custom_minimum_size = Vector2(60, 60)
	btn.focus_mode = Control.FOCUS_NONE
	_register_control(action, btn, Color(1, 1, 1))
	parent.add_child(btn)

func _make_round_button(parent: Control, label: String, pos: Vector2, action: String, color: Color) -> void:
	var btn = Button.new()
	btn.text = label
	btn.position = pos
	btn.custom_minimum_size = Vector2(80, 80)
	btn.focus_mode = Control.FOCUS_NONE
	var sb = StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = 40
	sb.corner_radius_top_right = 40
	sb.corner_radius_bottom_left = 40
	sb.corner_radius_bottom_right = 40
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("focus", sb)
	_register_control(action, btn, Color(1, 1, 1))
	parent.add_child(btn)

func _make_pill_button(parent: Control, label: String, action: String) -> void:
	var btn = Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(90, 40)
	btn.focus_mode = Control.FOCUS_NONE
	_register_control(action, btn, Color(1, 1, 1))
	parent.add_child(btn)

func _on_load_pressed() -> void:
	file_dialog.popup_centered()

func _on_file_selected(path: String) -> void:
	if gb.loaded:
		gb.save()
	var ok = gb.load_rom(path)
	if ok:
		status_label.text = "Загружено: %s" % path.get_file()
		paused = false
	else:
		status_label.text = "Не удалось загрузить ROM: %s" % path.get_file()

func _on_pause_pressed() -> void:
	paused = not paused

func _on_close_requested() -> void:
	if gb and gb.loaded:
		gb.save()

func _process(_delta: float) -> void:
	if gb.loaded and not paused:
		gb.run_frame()
		screen_rect.texture = gb.get_display_texture()

# ---------- raw multitouch handling for on-screen controls ----------

func _find_action_at(global_pos: Vector2) -> String:
	for action in _control_nodes.keys():
		var ctrl: Control = _control_nodes[action]
		if ctrl.get_global_rect().has_point(global_pos):
			return action
	return ""

func _press_action(action: String) -> void:
	if action == "":
		return
	gb.joypad.set_button(action, true)
	var ctrl: Control = _control_nodes.get(action)
	if ctrl:
		ctrl.self_modulate = _control_base_color[action] * 0.6

func _release_action(action: String) -> void:
	if action == "":
		return
	gb.joypad.set_button(action, false)
	var ctrl: Control = _control_nodes.get(action)
	if ctrl:
		ctrl.self_modulate = _control_base_color[action]

func _handle_pointer_down(pointer_id: int, global_pos: Vector2) -> void:
	var action: String = _find_action_at(global_pos)
	if action != "":
		_touch_owner[pointer_id] = action
		_press_action(action)

func _handle_pointer_up(pointer_id: int) -> void:
	if _touch_owner.has(pointer_id):
		_release_action(_touch_owner[pointer_id])
		_touch_owner.erase(pointer_id)

func _handle_pointer_move(pointer_id: int, global_pos: Vector2) -> void:
	# Supports sliding a finger from one D-pad direction to another without
	# lifting it, same as real handhelds.
	if not _touch_owner.has(pointer_id):
		return
	var new_action: String = _find_action_at(global_pos)
	var old_action: String = _touch_owner[pointer_id]
	if new_action == old_action:
		return
	_release_action(old_action)
	if new_action != "":
		_touch_owner[pointer_id] = new_action
		_press_action(new_action)
	else:
		_touch_owner.erase(pointer_id)

func _input(event: InputEvent) -> void:
	# Keyboard support for desktop testing
	if event is InputEventKey and gb:
		var pressed = event.pressed
		match event.keycode:
			KEY_UP: gb.joypad.set_button("up", pressed)
			KEY_DOWN: gb.joypad.set_button("down", pressed)
			KEY_LEFT: gb.joypad.set_button("left", pressed)
			KEY_RIGHT: gb.joypad.set_button("right", pressed)
			KEY_Z: gb.joypad.set_button("a", pressed)
			KEY_X: gb.joypad.set_button("b", pressed)
			KEY_ENTER: gb.joypad.set_button("start", pressed)
			KEY_SHIFT: gb.joypad.set_button("select", pressed)
		return

	# Real multitouch (Android) — each finger is an independent pointer_id,
	# so several buttons can be held down simultaneously.
	if event is InputEventScreenTouch:
		if event.pressed:
			_handle_pointer_down(event.index, event.position)
		else:
			_handle_pointer_up(event.index)
		return

	if event is InputEventScreenDrag:
		_handle_pointer_move(event.index, event.position)
		return

	# Mouse fallback (desktop editor testing) — treated as a single pointer.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_handle_pointer_down(MOUSE_POINTER_ID, event.position)
		else:
			_handle_pointer_up(MOUSE_POINTER_ID)
		return

	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_handle_pointer_move(MOUSE_POINTER_ID, event.position)
		return
