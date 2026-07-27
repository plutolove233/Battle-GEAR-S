extends RefCounted
class_name HexGrid

## flat-top odd-q offset 坐标系的邻居方向表。
## 本项目坐标(q,r) 实为 odd-q offset 伪装成 axial（见 generate_rectangle
## 与 battle_board._axial_to_grid 的 r + (q+(q&1))/2 转换），
## 因此邻居方向随列号 q 的奇偶而变化，不能用一组固定偏移。
# 偶数列(q%2==0)的6个邻居偏移(dq,dr in offset row)：
#   右、右上、左上、左、左下、右下
const DIRS_EVEN: Array[Dictionary] = [
	{"dq": 1, "dr": 0},
	{"dq": 1, "dr": -1},
	{"dq": 0, "dr": -1},
	{"dq": -1, "dr": -1},
	{"dq": -1, "dr": 0},
	{"dq": 0, "dr": 1},
]
# 奇数列(q%2==1)的6个邻居偏移：
const DIRS_ODD: Array[Dictionary] = [
	{"dq": 1, "dr": 1},
	{"dq": 1, "dr": 0},
	{"dq": -1, "dr": 0},
	{"dq": -1, "dr": 1},
	{"dq": 0, "dr": 1},
	{"dq": 0, "dr": -1},
]

static func key(hex: Dictionary) -> String:
	return "%s,%s" % [int(hex.get("q", 0)), int(hex.get("r", 0))]

static func add(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"q": int(a.get("q", 0)) + int(b.get("q", 0)), "r": int(a.get("r", 0)) + int(b.get("r", 0))}

## odd-q offset 距离：先把(q,r)转 offset(col,row) 再转 cube 算距离。
## 与 neighbors() 的 BFS 步数一致（flat-top odd-q 标准算法）。
static func distance(a: Dictionary, b: Dictionary) -> int:
	var aq := int(a.get("q", 0))
	var ar := int(a.get("r", 0))
	var bq := int(b.get("q", 0))
	var br := int(b.get("r", 0))
	# axial(q,r) -> offset(col,row): col=q, row=r+(q+(q&1))/2
	var acol := aq
	var arow := ar + (aq + (aq % 2 + 2) % 2) / 2
	var bcol := bq
	var brow := br + (bq + (bq % 2 + 2) % 2) / 2
	# offset(col,row) -> cube(x,y,z) for odd-q flat-top
	var ax := acol
	var az := arow - (acol - (acol % 2 + 2) % 2) / 2
	var ay := -ax - az
	var bx := bcol
	var bz := brow - (bcol - (bcol % 2 + 2) % 2) / 2
	var by := -bx - bz
	return int((abs(ax - bx) + abs(ay - by) + abs(az - bz)) / 2)

## flat-top odd-q 邻居：按 q 的奇偶查表，返回6个相邻 hex。
static func neighbors(hex: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var q := int(hex.get("q", 0))
	var r := int(hex.get("r", 0))
	# offset(col,row)
	var col := q
	var row := r + (q + (q % 2 + 2) % 2) / 2
	var tbl: Array[Dictionary] = DIRS_ODD if (q % 2 + 2) % 2 == 1 else DIRS_EVEN
	for d: Dictionary in tbl:
		var ncol: int = col + int(d.get("dq", 0))
		var nrow: int = row + int(d.get("dr", 0))
		# offset(col,row) -> axial(q,r)
		var nq: int = ncol
		var nr: int = nrow - (ncol + (ncol % 2 + 2) % 2) / 2
		result.append({"q": nq, "r": nr})
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
	# 生成以(0,0)为中心、odd-q 距离 ≤ radius 的圆形格子集合，
	# 与 generate_rectangle 同属 odd-q offset 坐标系。
	var blocked_keys := {}
	for item in blocked:
		blocked_keys[key(item)] = true
	var result: Array[Dictionary] = []
	var origin := {"q": 0, "r": 0}
	# offset(col,row) 遍历范围：col∈[-radius,radius]，row 覆盖偏移后的圆
	for col in range(-radius, radius + 1):
		var row_min: int = -radius
		var row_max: int = radius
		for row in range(row_min, row_max + 1):
			# offset(col,row) -> axial(q,r)
			var q: int = col
			var r: int = row - (col + (col % 2 + 2) % 2) / 2
			var hex := {"q": q, "r": r}
			if blocked_keys.has(key(hex)):
				continue
			if distance(origin, hex) <= radius:
				result.append(hex)
	return result

static func contains_hex(tiles: Array, hex: Dictionary) -> bool:
	var target := key(hex)
	for tile in tiles:
		if key(tile) == target:
			return true
	return false
