extends RefCounted
class_name BattleMath

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")

static func calculate_attack(attack_power: int, target_armor: int) -> Dictionary:
	var damage = max(0, attack_power - target_armor)
	var markers = int(floor(float(attack_power) / 5.0))
	return {"damage": damage, "markers": markers}

## 检查目标是否在武器射程内（BFS动力可达）
## 简化版：只有origin, target, weapon_range时使用hex距离作为回退
## 完整版：传入map_cells使用BFS动力可达
static func is_in_range(origin: Dictionary, target: Dictionary, weapon_range: int, map_cells: Dictionary = {}) -> bool:
	if map_cells.is_empty():
		# 回退：简单hex距离（无地形信息时）
		return _HexGrid.distance(origin, target) <= weapon_range
	return _RangeCalculator.is_in_weapon_range(origin, target, weapon_range, map_cells)

## 检查目标是否在技能范围内（hex距离圆）
static func is_in_skill_range(origin: Dictionary, target: Dictionary, skill_range: int) -> bool:
	return _RangeCalculator.is_in_skill_range(origin, target, skill_range)

static func can_move(origin: Dictionary, target: Dictionary, available_power: int, map_tiles: Array) -> Dictionary:
	# 转换 map_tiles（Array[Dictionary]）为 map_cells（Dictionary）格式
	var map_cells: Dictionary = {}
	for tile: Dictionary in map_tiles:
		var key: String = _HexGrid.key(tile)
		var terrain = StringName(tile.get("terrain", &"NORMAL"))
		if tile.has("blocked") and tile.blocked:
			terrain = &"RED"
		map_cells[key] = {"q": int(tile.get("q", 0)), "r": int(tile.get("r", 0)), "terrain": terrain}

	return {"ok": _RangeCalculator.is_in_move_range(origin, target, available_power, map_cells)}

static func make_log(message: String, details: Dictionary = {}) -> Dictionary:
	return {"message": message, "details": details.duplicate(true)}
