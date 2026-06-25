extends RefCounted
class_name HexGrid

const DIRECTIONS: Array[Dictionary] = [
	{"q": 1, "r": 0},
	{"q": 1, "r": -1},
	{"q": 0, "r": -1},
	{"q": -1, "r": 0},
	{"q": -1, "r": 1},
	{"q": 0, "r": 1},
]

static func key(hex: Dictionary) -> String:
	return "%s,%s" % [int(hex.get("q", 0)), int(hex.get("r", 0))]

static func add(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"q": int(a.get("q", 0)) + int(b.get("q", 0)), "r": int(a.get("r", 0)) + int(b.get("r", 0))}

static func distance(a: Dictionary, b: Dictionary) -> int:
	var aq := int(a.get("q", 0))
	var ar := int(a.get("r", 0))
	var bq := int(b.get("q", 0))
	var br := int(b.get("r", 0))
	var as_ := -aq - ar
	var bs := -bq - br
	return int((abs(aq - bq) + abs(ar - br) + abs(as_ - bs)) / 2)

static func neighbors(hex: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for direction in DIRECTIONS:
		result.append(add(hex, direction))
	return result

static func generate_rectangle(cols: int, rows: int, blocked: Array) -> Array[Dictionary]:
	# 生成矩形网格 (flat-top odd-q offset)
	# cols = q (列号), rows 范围根据 q 计算（奇数列向下偏移）
	var blocked_keys := {}
	for item in blocked:
		blocked_keys[key(item)] = true
	var result: Array[Dictionary] = []
	for q in range(cols):
		# odd-q: 奇数列向下偏移，所以行范围需要调整
		var row_start := 0
		var row_end := rows - 1
		for r_offset in range(row_start, row_end + 1):
			# 从偏移坐标反推 axial r
			var r := r_offset - (q + (q % 2)) / 2
			var hex := {"q": q, "r": r}
			if not blocked_keys.has(key(hex)):
				result.append(hex)
	return result

static func generate_radius(radius: int, blocked: Array) -> Array[Dictionary]:
	var blocked_keys := {}
	for item in blocked:
		blocked_keys[key(item)] = true
	var result: Array[Dictionary] = []
	for q in range(-radius, radius + 1):
		var r_min = max(-radius, -q - radius)
		var r_max = min(radius, -q + radius)
		for r in range(r_min, r_max + 1):
			var hex := {"q": q, "r": r}
			if not blocked_keys.has(key(hex)):
				result.append(hex)
	return result

static func contains_hex(tiles: Array, hex: Dictionary) -> bool:
	var target := key(hex)
	for tile in tiles:
		if key(tile) == target:
			return true
	return false
