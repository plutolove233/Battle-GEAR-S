## RangeCalculator.gd — 攻击/技能范围计算器
##
## 核心范围计算逻辑：
##   武器攻击范围：BFS动力可达（从攻击方出发，消耗射程点动力能抵达=在范围内）
##     - 每步消耗1动力（GREEN地形消耗2，RED不可通过）
##     - 不考虑朝向，任何方向都可攻击
##     - 地形影响可达性
##
##   技能范围：hex距离圆（distance(origin, target) ≤ range_value）
##     - 不考虑地形
##
##   移动范围：BFS动力可达（与武器共享BFS逻辑，但使用实际动力值）
class_name RangeCalculator
extends RefCounted

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")

## 获取武器射程可达的所有hex
## origin: 攻击方位置 {q, r}
## range_value: 武器射程值
## map_cells: MapState.cells 或等效的格子字典
## 返回: 可达的hex坐标数组 [{q, r}, ...]
static func get_weapon_reachable_hexes(origin: Dictionary, range_value: int, map_cells: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var origin_key: String = _HexGrid.key(origin)

	# BFS
	var frontier: Array[Dictionary] = [origin]
	var costs: Dictionary = {origin_key: 0}
	var index: int = 0

	while index < frontier.size():
		var current: Dictionary = frontier[index]
		index += 1
		var current_key: String = _HexGrid.key(current)
		var current_cost: int = int(costs[current_key])

		if current_cost >= range_value:
			continue

		for neighbor: Dictionary in _HexGrid.neighbors(current):
			var neighbor_key: String = _HexGrid.key(neighbor)
			if costs.has(neighbor_key):
				continue

			# 检查地形
			var cell = map_cells.get(neighbor_key)
			if cell == null:
				continue

			var terrain: StringName = cell.terrain if cell is _MapCellState else StringName(cell.get("terrain", &"NORMAL"))

			# RED 不可通过
			if terrain == &"RED":
				continue

			# GREEN 消耗2动力
			var move_cost: int = 2 if terrain == &"GREEN" else 1
			var next_cost: int = current_cost + move_cost

			if next_cost > range_value:
				continue

			costs[neighbor_key] = next_cost
			frontier.append(neighbor)

	# 收集所有可达hex（不包含origin自身）
	for key: String in costs:
		if key != origin_key:
			var parts: PackedStringArray = key.split(",")
			result.append({"q": int(parts[0]), "r": int(parts[1])})

	return result


## 检查目标是否在武器射程内（BFS动力可达）
static func is_in_weapon_range(origin: Dictionary, target: Dictionary, range_value: int, map_cells: Dictionary) -> bool:
	var target_key: String = _HexGrid.key(target)
	var origin_key: String = _HexGrid.key(origin)

	if target_key == origin_key:
		return false  # 不能攻击自身

	# BFS
	var frontier: Array[Dictionary] = [origin]
	var costs: Dictionary = {origin_key: 0}
	var index: int = 0

	while index < frontier.size():
		var current: Dictionary = frontier[index]
		index += 1
		var current_key: String = _HexGrid.key(current)
		var current_cost: int = int(costs[current_key])

		if current_cost >= range_value:
			continue

		for neighbor: Dictionary in _HexGrid.neighbors(current):
			var neighbor_key: String = _HexGrid.key(neighbor)
			if costs.has(neighbor_key):
				continue

			var cell = map_cells.get(neighbor_key)
			if cell == null:
				continue

			var terrain: StringName = cell.terrain if cell is _MapCellState else StringName(cell.get("terrain", &"NORMAL"))

			if terrain == &"RED":
				continue

			var move_cost: int = 2 if terrain == &"GREEN" else 1
			var next_cost: int = current_cost + move_cost

			if next_cost > range_value:
				continue

			# 找到目标
			if neighbor_key == target_key:
				return true

			costs[neighbor_key] = next_cost
			frontier.append(neighbor)

	return false


## 获取技能范围内的所有hex（hex距离圆）
static func get_skill_range_hexes(origin: Dictionary, range_value: int, map_cells: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var origin_key: String = _HexGrid.key(origin)

	for key: String in map_cells:
		if key == origin_key:
			continue
		var cell = map_cells[key]
		var q: int = cell.q if cell is _MapCellState else int(cell.get("q", 0))
		var r: int = cell.r if cell is _MapCellState else int(cell.get("r", 0))
		var hex: Dictionary = {"q": q, "r": r}
		if _HexGrid.distance(origin, hex) <= range_value:
			result.append(hex)

	return result


## 检查目标是否在技能范围内（hex距离）
static func is_in_skill_range(origin: Dictionary, target: Dictionary, range_value: int) -> bool:
	return _HexGrid.distance(origin, target) <= range_value


## 获取移动可达的所有hex（BFS动力可达，与武器共享逻辑）
static func get_move_reachable_hexes(origin: Dictionary, available_power: int, map_cells: Dictionary) -> Array[Dictionary]:
	return get_weapon_reachable_hexes(origin, available_power, map_cells)


## 检查目标是否在移动范围内
static func is_in_move_range(origin: Dictionary, target: Dictionary, available_power: int, map_cells: Dictionary) -> bool:
	return is_in_weapon_range(origin, target, available_power, map_cells)
