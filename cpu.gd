extends RefCounted
class_name CPU

var gb = null
var mmu: MMU

# 8-bit registers
var a: int = 0x01
var b: int = 0x00
var c: int = 0x13
var d: int = 0x00
var e: int = 0xD8
var h: int = 0x01
var l: int = 0x4D
var f: int = 0xB0 # Z N H C 0 0 0 0

var sp: int = 0xFFFE
var pc: int = 0x0100

var ime: bool = false
var ime_pending: bool = false
var halted: bool = false
var halt_bug: bool = false
var stopped: bool = false

const FLAG_Z: int = 0x80
const FLAG_N: int = 0x40
const FLAG_H: int = 0x20
const FLAG_C: int = 0x10

func reset(cgb_mode: bool = false) -> void:
	if cgb_mode:
		a = 0x11; f = 0x80
		b = 0x00; c = 0x00
		d = 0xFF; e = 0x56
		h = 0x00; l = 0x0D
	else:
		a = 0x01; f = 0xB0
		b = 0x00; c = 0x13
		d = 0x00; e = 0xD8
		h = 0x01; l = 0x4D
	sp = 0xFFFE
	pc = 0x0100
	ime = false
	halted = false
	stopped = false

# ---------- flag helpers ----------
func flag_z() -> bool: return (f & FLAG_Z) != 0
func flag_n() -> bool: return (f & FLAG_N) != 0
func flag_h() -> bool: return (f & FLAG_H) != 0
func flag_c() -> bool: return (f & FLAG_C) != 0

func set_flags(z: bool, n: bool, h_: bool, carry: bool) -> void:
	var nf: int = 0
	if z: nf |= FLAG_Z
	if n: nf |= FLAG_N
	if h_: nf |= FLAG_H
	if carry: nf |= FLAG_C
	f = nf

func set_flag(mask: int, on: bool) -> void:
	if on:
		f |= mask
	else:
		f &= ~mask

# ---------- 16-bit register pairs ----------
func get_bc() -> int: return (b << 8) | c
func set_bc(v: int) -> void: b = (v >> 8) & 0xFF; c = v & 0xFF
func get_de() -> int: return (d << 8) | e
func set_de(v: int) -> void: d = (v >> 8) & 0xFF; e = v & 0xFF
func get_hl() -> int: return (h << 8) | l
func set_hl(v: int) -> void: h = (v >> 8) & 0xFF; l = v & 0xFF
func get_af() -> int: return (a << 8) | (f & 0xF0)
func set_af(v: int) -> void: a = (v >> 8) & 0xFF; f = v & 0xF0

# ---------- memory / fetch helpers ----------
func fetch8() -> int:
	var v: int = mmu.read8(pc)
	pc = (pc + 1) & 0xFFFF
	return v

func fetch16() -> int:
	var lo: int = fetch8()
	var hi: int = fetch8()
	return (hi << 8) | lo

func push16(v: int) -> void:
	sp = (sp - 1) & 0xFFFF
	mmu.write8(sp, (v >> 8) & 0xFF)
	sp = (sp - 1) & 0xFFFF
	mmu.write8(sp, v & 0xFF)

func pop16() -> int:
	var lo: int = mmu.read8(sp)
	sp = (sp + 1) & 0xFFFF
	var hi: int = mmu.read8(sp)
	sp = (sp + 1) & 0xFFFF
	return (hi << 8) | lo

# r8 register code decode: 0=B 1=C 2=D 3=E 4=H 5=L 6=(HL) 7=A
func get_r8(code: int) -> int:
	match code:
		0: return b
		1: return c
		2: return d
		3: return e
		4: return h
		5: return l
		6: return mmu.read8(get_hl())
		7: return a
	return 0

func set_r8(code: int, v: int) -> void:
	v = v & 0xFF
	match code:
		0: b = v
		1: c = v
		2: d = v
		3: e = v
		4: h = v
		5: l = v
		6: mmu.write8(get_hl(), v)
		7: a = v

func get_rr(code: int) -> int: # 0=BC 1=DE 2=HL 3=SP
	match code:
		0: return get_bc()
		1: return get_de()
		2: return get_hl()
		3: return sp
	return 0

func set_rr(code: int, v: int) -> void:
	match code:
		0: set_bc(v)
		1: set_de(v)
		2: set_hl(v)
		3: sp = v & 0xFFFF

func get_rr_stack(code: int) -> int: # 0=BC 1=DE 2=HL 3=AF (for PUSH/POP)
	match code:
		0: return get_bc()
		1: return get_de()
		2: return get_hl()
		3: return get_af()
	return 0

func set_rr_stack(code: int, v: int) -> void:
	match code:
		0: set_bc(v)
		1: set_de(v)
		2: set_hl(v)
		3: set_af(v)

func check_cc(code: int) -> bool: # 0=NZ 1=Z 2=NC 3=C
	match code:
		0: return not flag_z()
		1: return flag_z()
		2: return not flag_c()
		3: return flag_c()
	return false

# ---------- ALU ----------
func alu_add(val: int) -> void:
	var res: int = a + val
	set_flags(res & 0xFF == 0, false, ((a & 0xF) + (val & 0xF)) > 0xF, res > 0xFF)
	a = res & 0xFF

func alu_adc(val: int) -> void:
	var carry: int = 1 if flag_c() else 0
	var res: int = a + val + carry
	set_flags(res & 0xFF == 0, false, ((a & 0xF) + (val & 0xF) + carry) > 0xF, res > 0xFF)
	a = res & 0xFF

func alu_sub(val: int) -> void:
	var res: int = a - val
	set_flags((res & 0xFF) == 0, true, (a & 0xF) < (val & 0xF), res < 0)
	a = res & 0xFF

func alu_sbc(val: int) -> void:
	var carry: int = 1 if flag_c() else 0
	var res: int = a - val - carry
	set_flags((res & 0xFF) == 0, true, (a & 0xF) < ((val & 0xF) + carry), res < 0)
	a = res & 0xFF

func alu_and(val: int) -> void:
	a = a & val
	set_flags(a == 0, false, true, false)

func alu_xor(val: int) -> void:
	a = (a ^ val) & 0xFF
	set_flags(a == 0, false, false, false)

func alu_or(val: int) -> void:
	a = (a | val) & 0xFF
	set_flags(a == 0, false, false, false)

func alu_cp(val: int) -> void:
	var res: int = a - val
	set_flags((res & 0xFF) == 0, true, (a & 0xF) < (val & 0xF), res < 0)

func alu_inc_r(code: int) -> void:
	var v: int = (get_r8(code) + 1) & 0xFF
	set_flag(FLAG_Z, v == 0)
	set_flag(FLAG_N, false)
	set_flag(FLAG_H, (v & 0x0F) == 0)
	set_r8(code, v)

func alu_dec_r(code: int) -> void:
	var v: int = (get_r8(code) - 1) & 0xFF
	set_flag(FLAG_Z, v == 0)
	set_flag(FLAG_N, true)
	set_flag(FLAG_H, (v & 0x0F) == 0x0F)
	set_r8(code, v)

func add_hl_rr(val: int) -> void:
	var hl: int = get_hl()
	var res: int = hl + val
	set_flag(FLAG_N, false)
	set_flag(FLAG_H, ((hl & 0xFFF) + (val & 0xFFF)) > 0xFFF)
	set_flag(FLAG_C, res > 0xFFFF)
	set_hl(res & 0xFFFF)

func add_sp_signed(n: int) -> int:
	var signed_n: int = n
	if signed_n >= 128:
		signed_n -= 256
	var res: int = sp + signed_n
	set_flag(FLAG_Z, false)
	set_flag(FLAG_N, false)
	set_flag(FLAG_H, ((sp & 0xF) + (n & 0xF)) > 0xF)
	set_flag(FLAG_C, ((sp & 0xFF) + (n & 0xFF)) > 0xFF)
	return res & 0xFFFF

func daa() -> void:
	var adjust: int = 0
	var carry: bool = false
	if flag_h() or (not flag_n() and (a & 0xF) > 9):
		adjust |= 0x06
	if flag_c() or (not flag_n() and a > 0x99):
		adjust |= 0x60
		carry = true
	if flag_n():
		a = (a - adjust) & 0xFF
	else:
		a = (a + adjust) & 0xFF
	set_flag(FLAG_Z, a == 0)
	set_flag(FLAG_H, false)
	set_flag(FLAG_C, carry)

# ---------- rotate/shift (CB block 0x00-0x3F) ----------
func op_rlc(v: int) -> int:
	var carry: int = (v >> 7) & 1
	var res: int = ((v << 1) | carry) & 0xFF
	set_flags(res == 0, false, false, carry == 1)
	return res

func op_rrc(v: int) -> int:
	var carry: int = v & 1
	var res: int = ((v >> 1) | (carry << 7)) & 0xFF
	set_flags(res == 0, false, false, carry == 1)
	return res

func op_rl(v: int) -> int:
	var old_carry: int = 1 if flag_c() else 0
	var carry: int = (v >> 7) & 1
	var res: int = ((v << 1) | old_carry) & 0xFF
	set_flags(res == 0, false, false, carry == 1)
	return res

func op_rr(v: int) -> int:
	var old_carry: int = 1 if flag_c() else 0
	var carry: int = v & 1
	var res: int = ((v >> 1) | (old_carry << 7)) & 0xFF
	set_flags(res == 0, false, false, carry == 1)
	return res

func op_sla(v: int) -> int:
	var carry: int = (v >> 7) & 1
	var res: int = (v << 1) & 0xFF
	set_flags(res == 0, false, false, carry == 1)
	return res

func op_sra(v: int) -> int:
	var carry: int = v & 1
	var msb: int = v & 0x80
	var res: int = ((v >> 1) | msb) & 0xFF
	set_flags(res == 0, false, false, carry == 1)
	return res

func op_swap(v: int) -> int:
	var res: int = ((v << 4) | (v >> 4)) & 0xFF
	set_flags(res == 0, false, false, false)
	return res

func op_srl(v: int) -> int:
	var carry: int = v & 1
	var res: int = (v >> 1) & 0xFF
	set_flags(res == 0, false, false, carry == 1)
	return res

# ---------- interrupt handling ----------
func request_interrupt(bit: int) -> void:
	mmu.if_reg |= (1 << bit)

func service_interrupts() -> int:
	var fired: int = mmu.if_reg & mmu.ie_reg & 0x1F
	if fired == 0:
		return 0
	if halted:
		halted = false
	if not ime:
		return 0
	for bit in range(5):
		if fired & (1 << bit):
			ime = false
			mmu.if_reg &= ~(1 << bit)
			push16(pc)
			pc = [0x40, 0x48, 0x50, 0x58, 0x60][bit]
			return 20
	return 0

# ---------- main step ----------
func step() -> int:
	if ime_pending:
		ime = true
		ime_pending = false

	var int_cycles: int = service_interrupts()
	if int_cycles > 0:
		return int_cycles

	if halted:
		return 4

	var opcode: int = fetch8()

	if halt_bug:
		halt_bug = false
		pc = (pc - 1) & 0xFFFF

	return execute(opcode)

func execute(op: int) -> int:
	# ---- explicit / irregular opcodes first ----
	match op:
		0x00: return 4 # NOP
		0x08: # LD (nn),SP
			var addr: int = fetch16()
			mmu.write16(addr, sp)
			return 20
		0x10: # STOP
			if mmu.cgb_mode and mmu.key1_armed:
				mmu.double_speed = not mmu.double_speed
				mmu.key1_armed = false
			else:
				stopped = true
			pc = (pc + 1) & 0xFFFF
			return 4
		0x18: # JR n
			var n: int = fetch8()
			var s: int = n - 256 if n >= 128 else n
			pc = (pc + s) & 0xFFFF
			return 12
		0x76: # HALT
			if not ime and (mmu.if_reg & mmu.ie_reg & 0x1F) != 0:
				halt_bug = true
			else:
				halted = true
			return 4
		0x07: a = op_rlc(a); set_flag(FLAG_Z, false); return 4
		0x0F: a = op_rrc(a); set_flag(FLAG_Z, false); return 4
		0x17: a = op_rl(a); set_flag(FLAG_Z, false); return 4
		0x1F: a = op_rr(a); set_flag(FLAG_Z, false); return 4
		0x27: daa(); return 4
		0x2F: a = (~a) & 0xFF; set_flag(FLAG_N, true); set_flag(FLAG_H, true); return 4
		0x37: set_flag(FLAG_N, false); set_flag(FLAG_H, false); set_flag(FLAG_C, true); return 4
		0x3F: set_flag(FLAG_N, false); set_flag(FLAG_H, false); set_flag(FLAG_C, not flag_c()); return 4
		0xC3: pc = fetch16(); return 16
		0xC9: pc = pop16(); return 16
		0xD9: pc = pop16(); ime = true; return 16
		0xE9: pc = get_hl(); return 4
		0xF9: sp = get_hl(); return 8
		0xE0:
			var n: int = fetch8()
			mmu.write8(0xFF00 + n, a)
			return 12
		0xF0:
			var n: int = fetch8()
			a = mmu.read8(0xFF00 + n)
			return 12
		0xE2: mmu.write8(0xFF00 + c, a); return 8
		0xF2: a = mmu.read8(0xFF00 + c); return 8
		0xE8:
			var n: int = fetch8()
			sp = add_sp_signed(n)
			return 16
		0xF8:
			var n: int = fetch8()
			set_hl(add_sp_signed(n))
			return 12
		0xEA:
			var addr: int = fetch16()
			mmu.write8(addr, a)
			return 16
		0xFA:
			var addr: int = fetch16()
			a = mmu.read8(addr)
			return 16
		0xF3: ime = false; ime_pending = false; return 4
		0xFB: ime_pending = true; return 4
		0xCB:
			return execute_cb(fetch8())
		0x02: mmu.write8(get_bc(), a); return 8
		0x12: mmu.write8(get_de(), a); return 8
		0x22: mmu.write8(get_hl(), a); set_hl((get_hl() + 1) & 0xFFFF); return 8
		0x32: mmu.write8(get_hl(), a); set_hl((get_hl() - 1) & 0xFFFF); return 8
		0x0A: a = mmu.read8(get_bc()); return 8
		0x1A: a = mmu.read8(get_de()); return 8
		0x2A: a = mmu.read8(get_hl()); set_hl((get_hl() + 1) & 0xFFFF); return 8
		0x3A: a = mmu.read8(get_hl()); set_hl((get_hl() - 1) & 0xFFFF); return 8
		# unused / illegal opcodes -> treat as NOP to avoid crashing on bad dumps
		0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD:
			return 4

	# ---- structured blocks ----
	if op >= 0x40 and op <= 0x7F:
		var dst: int = (op >> 3) & 7
		var src: int = op & 7
		set_r8(dst, get_r8(src))
		return 8 if (dst == 6 or src == 6) else 4

	if op >= 0x80 and op <= 0xBF:
		var alu_op: int = (op >> 3) & 7
		var src: int = op & 7
		var val: int = get_r8(src)
		_do_alu(alu_op, val)
		return 8 if src == 6 else 4

	if (op & 0xC7) == 0x06: # LD r,n
		var dst: int = (op >> 3) & 7
		var n: int = fetch8()
		set_r8(dst, n)
		return 12 if dst == 6 else 8

	if (op & 0xC7) == 0x04: # INC r
		var r: int = (op >> 3) & 7
		alu_inc_r(r)
		return 12 if r == 6 else 4

	if (op & 0xC7) == 0x05: # DEC r
		var r: int = (op >> 3) & 7
		alu_dec_r(r)
		return 12 if r == 6 else 4

	if (op & 0xCF) == 0x01: # LD rr,nn
		var rr: int = (op >> 4) & 3
		set_rr(rr, fetch16())
		return 12

	if (op & 0xCF) == 0x03: # INC rr
		var rr: int = (op >> 4) & 3
		set_rr(rr, (get_rr(rr) + 1) & 0xFFFF)
		return 8

	if (op & 0xCF) == 0x0B: # DEC rr
		var rr: int = (op >> 4) & 3
		set_rr(rr, (get_rr(rr) - 1) & 0xFFFF)
		return 8

	if (op & 0xCF) == 0x09: # ADD HL,rr
		var rr: int = (op >> 4) & 3
		add_hl_rr(get_rr(rr))
		return 8

	if (op & 0xE7) == 0x20: # JR cc,n
		var cc: int = (op >> 3) & 3
		var n: int = fetch8()
		if check_cc(cc):
			var s: int = n - 256 if n >= 128 else n
			pc = (pc + s) & 0xFFFF
			return 12
		return 8

	if (op & 0xC7) == 0xC0 and op < 0xE0: # RET cc  (0xC0,0xC8,0xD0,0xD8)
		var cc: int = (op >> 3) & 3
		if check_cc(cc):
			pc = pop16()
			return 20
		return 8

	if (op & 0xC7) == 0xC2 and op < 0xE0: # JP cc,nn
		var cc: int = (op >> 3) & 3
		var addr: int = fetch16()
		if check_cc(cc):
			pc = addr
			return 16
		return 12

	if (op & 0xC7) == 0xC4 and op < 0xE0: # CALL cc,nn
		var cc: int = (op >> 3) & 3
		var addr: int = fetch16()
		if check_cc(cc):
			push16(pc)
			pc = addr
			return 24
		return 12

	if (op & 0xCF) == 0xC1: # POP rr
		var rr: int = (op >> 4) & 3
		set_rr_stack(rr, pop16())
		return 12

	if (op & 0xCF) == 0xC5: # PUSH rr
		var rr: int = (op >> 4) & 3
		push16(get_rr_stack(rr))
		return 16

	if (op & 0xC7) == 0xC6: # ALU A,n
		var alu_op: int = (op >> 3) & 7
		var n: int = fetch8()
		_do_alu(alu_op, n)
		return 8

	if (op & 0xC7) == 0xC7: # RST n
		var addr: int = op & 0x38
		push16(pc)
		pc = addr
		return 16

	if op == 0xCD: # CALL nn
		var addr: int = fetch16()
		push16(pc)
		pc = addr
		return 24

	# fallback: unimplemented opcode, treat as NOP (keeps emulator running on edge cases)
	return 4

func _do_alu(alu_op: int, val: int) -> void:
	match alu_op:
		0: alu_add(val)
		1: alu_adc(val)
		2: alu_sub(val)
		3: alu_sbc(val)
		4: alu_and(val)
		5: alu_xor(val)
		6: alu_or(val)
		7: alu_cp(val)

func execute_cb(op: int) -> int:
	var reg: int = op & 7
	var is_mem: bool = reg == 6

	if op < 0x40:
		var shift_op: int = (op >> 3) & 7
		var v: int = get_r8(reg)
		var res: int
		match shift_op:
			0: res = op_rlc(v)
			1: res = op_rrc(v)
			2: res = op_rl(v)
			3: res = op_rr(v)
			4: res = op_sla(v)
			5: res = op_sra(v)
			6: res = op_swap(v)
			7: res = op_srl(v)
			_: res = v
		set_r8(reg, res)
		return 16 if is_mem else 8

	elif op < 0x80: # BIT b,r
		var bit: int = (op >> 3) & 7
		var v: int = get_r8(reg)
		set_flag(FLAG_Z, (v & (1 << bit)) == 0)
		set_flag(FLAG_N, false)
		set_flag(FLAG_H, true)
		return 12 if is_mem else 8

	elif op < 0xC0: # RES b,r
		var bit: int = (op >> 3) & 7
		var v: int = get_r8(reg) & ~(1 << bit)
		set_r8(reg, v)
		return 16 if is_mem else 8

	else: # SET b,r
		var bit: int = (op >> 3) & 7
		var v: int = get_r8(reg) | (1 << bit)
		set_r8(reg, v)
		return 16 if is_mem else 8
