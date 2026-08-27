## RangeCalculator.gd - 攻击/技能范围计算器
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
##     - 绿格光环（汀兰 pilot_081 等）：aura_green_cells 内的格子视为绿格；
##       green_move_cost 控制绿格消耗（折扣玩家=1，默认=2）。
##     - 武器攻击范围同样受光环影响：光环格在攻击 BFS 中视为绿格、耗 2 射程预算
##       （全场无折扣，含光环持有者自己的攻击；天然绿格照旧耗 2；红格照旧阻挡）。
##       攻击路径调用方通过 MapService.get_attack_aura_cells() 传入全局光环集合。
class_name RangeCalculator
extends RefCounted

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")

## 取格子的地形（MapCellState 或字典）。
static func _terrain_of(cell) -> StringName:
	if cell is _MapCellState:
		return cell.terrain
	if typeof(cell) == TYPE_DICTIONARY:
		return StringName(cell.get("terrain", &"NORMAL"))
	return &"NORMAL"

## 通用 BFS：从 origin 出发，消耗 budget 动力能抵达的格子（不含 origin）。
## green_cost：绿格消耗（默认2）。aura_green_cells：额外视为绿格的格子集合（{cell_key: true}）。
## blocked_keys：不可穿过的格子 {cell_key: true}（如其他机甲所在格）--
## 可入 costs（可作终点：机甲格可被指向/命中），但不入 frontier（不可穿过向外扩展，
## 打后面的目标须绕路）。与 get_path_move_hexes 的 blocked 语义一致。
## RED 不可通过；aura 不覆盖 RED（调用方构造 aura 时已排除红格）。
static func _reachable_hexes(origin: Dictionary, budget: int, map_cells: Dictionary, green_cost: int = 2, aura_green_cells: Dictionary = {}, blocked_keys: Dictionary = {}) -> Array[Dictionary]:
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

		if current_cost >= budget:
			continue

		for neighbor: Dictionary in _HexGrid.neighbors(current):
			var neighbor_key: String = _HexGrid.key(neighbor)
			if costs.has(neighbor_key):
				continue

			# 检查地形
			var cell = map_cells.get(neighbor_key)
			if cell == null:
				continue

			var terrain: StringName = _terrain_of(cell)

			# RED 不可通过
			if terrain == &"RED":
				continue

			# GREEN 消耗 green_cost 动力（光环格视为绿格）
			var is_green: bool = terrain == &"GREEN" or aura_green_cells.has(neighbor_key)
			var move_cost: int = green_cost if is_green else 1
			var next_cost: int = current_cost + move_cost

			if next_cost > budget:
				continue

			costs[neighbor_key] = next_cost
			# blocked 格（机甲所在等）：可作终点，但不入 frontier--不可穿过继续向外扩展
			if blocked_keys.has(neighbor_key):
				continue
			frontier.append(neighbor)

	# 收集所有可达hex（不包含origin自身）
	for key: String in costs:
		if key != origin_key:
			var parts: PackedStringArray = key.split(",")
			result.append({"q": int(parts[0]), "r": int(parts[1])})

	return result


## 通用 BFS 判定：target 是否在 budget 动力可达范围内（不含 origin）。
## blocked_keys 语义同 _reachable_hexes：blocked 格可作终点（target 即 blocked 格时可达），
## 不可作为中途格穿过。
static func _in_range(origin: Dictionary, target: Dictionary, budget: int, map_cells: Dictionary, green_cost: int = 2, aura_green_cells: Dictionary = {}, blocked_keys: Dictionary = {}) -> bool:
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

		if current_cost >= budget:
			continue

		for neighbor: Dictionary in _HexGrid.neighbors(current):
			var neighbor_key: String = _HexGrid.key(neighbor)
			if costs.has(neighbor_key):
				continue

			var cell = map_cells.get(neighbor_key)
			if cell == null:
				continue

			var terrain: StringName = _terrain_of(cell)

			if terrain == &"RED":
				continue

			var is_green: bool = terrain == &"GREEN" or aura_green_cells.has(neighbor_key)
			var move_cost: int = green_cost if is_green else 1
			var next_cost: int = current_cost + move_cost

			if next_cost > budget:
				continue

			# 找到目标（target 为 blocked 格也可达：blocked 可作终点）
			if neighbor_key == target_key:
				return true

			costs[neighbor_key] = next_cost
			# blocked 格：不可穿过向外扩展
			if blocked_keys.has(neighbor_key):
				continue
			frontier.append(neighbor)

	return false


## 获取武器射程可达的所有hex（绿格耗2；光环格由调用方传入视为绿格、同样耗2）。
## origin: 攻击方位置 {q, r}
## range_value: 武器射程值
## map_cells: MapState.cells 或等效的格子字典
## aura_green_cells: 全场光环转化的绿格集合（{cell_key: true}），来自 MapService.get_attack_aura_cells()；
##   默认 {} 保持向后兼容（无光环时行为不变）。红格不在 aura 内（构造时已排除）。
## blocked_keys: 攻击路径上的障碍格集合（{cell_key: true}），来自 MapService.get_attack_blocked_keys()--
##   其他机甲所在格（含陷落"不能被选为目标"的机甲：依然作为障碍）。可作终点（机甲格可被
##   指向/命中）但不可穿过（打后面的目标须绕路）。默认 {} 保持向后兼容。
## 返回: 可达的hex坐标数组 [{q, r}, ...]
static func get_weapon_reachable_hexes(origin: Dictionary, range_value: int, map_cells: Dictionary, aura_green_cells: Dictionary = {}, blocked_keys: Dictionary = {}) -> Array[Dictionary]:
	return _reachable_hexes(origin, range_value, map_cells, 2, aura_green_cells, blocked_keys)


## 检查目标是否在武器射程内（BFS动力可达，绿格耗2；光环格由调用方传入视为绿格、同样耗2）
## blocked_keys 语义同 get_weapon_reachable_hexes。
static func is_in_weapon_range(origin: Dictionary, target: Dictionary, range_value: int, map_cells: Dictionary, aura_green_cells: Dictionary = {}, blocked_keys: Dictionary = {}) -> bool:
	return _in_range(origin, target, range_value, map_cells, 2, aura_green_cells, blocked_keys)


## 获取技能范围内的所有hex（hex距离圆）。
## include_origin=true 时含 origin 所在格（奥黛尔 pilot_038 多选机甲含自己用；
## 默认 false 保持攻击范围/设陷选格等既有调用不变——自己不能是攻击目标/陷阱格）。
static func get_skill_range_hexes(origin: Dictionary, range_value: int, map_cells: Dictionary, include_origin: bool = false) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var origin_key: String = _HexGrid.key(origin)

	for key: String in map_cells:
		if key == origin_key and not include_origin:
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


## 获取移动可达的所有hex（BFS动力可达，与武器共享逻辑但受光环影响）
## green_move_cost：绿格消耗（折扣玩家=1，默认2=与武器一致）。
## aura_green_cells：光环转化的绿格集合（{cell_key: true}）；这些格视为绿格。
static func get_move_reachable_hexes(origin: Dictionary, available_power: int, map_cells: Dictionary, green_move_cost: int = 2, aura_green_cells: Dictionary = {}) -> Array[Dictionary]:
	return _reachable_hexes(origin, available_power, map_cells, green_move_cost, aura_green_cells)


## 检查目标是否在移动范围内（受光环影响）
static func is_in_move_range(origin: Dictionary, target: Dictionary, available_power: int, map_cells: Dictionary, green_move_cost: int = 2, aura_green_cells: Dictionary = {}) -> bool:
	return _in_range(origin, target, available_power, map_cells, green_move_cost, aura_green_cells)


## 获取路径式移动可达的所有hex（BFS 连续移动；与 _reachable_hexes 同地形规则：
## GREEN 耗 green_cost（默认2），RED 不可通过也不可作终点）。
## blocked_keys：不可穿过的格子 {cell_key: true}（如机甲所在格）--可被选为终点
## （陷阱移入机甲格即触发/引爆），但 BFS 不再从这些格向外扩展（不构成连续移动的
## 中途经条件）。通用件：任何「沿路径连续移动 N 格」的效果（格雷厄姆移陷等）复用。
## 返回不含 origin 的全部可达hex（含 blocked 终点格）。
static func get_path_move_hexes(origin: Dictionary, budget: int, map_cells: Dictionary, blocked_keys: Dictionary = {}, green_cost: int = 2) -> Array[Dictionary]:
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

		if current_cost >= budget:
			continue

		for neighbor: Dictionary in _HexGrid.neighbors(current):
			var neighbor_key: String = _HexGrid.key(neighbor)
			if costs.has(neighbor_key):
				continue

			var cell = map_cells.get(neighbor_key)
			if cell == null:
				continue

			var terrain: StringName = _terrain_of(cell)

			# RED 不可通过、不可作终点
			if terrain == &"RED":
				continue

			# GREEN 消耗 green_cost（路径移动不受光环影响）
			var move_cost: int = green_cost if terrain == &"GREEN" else 1
			var next_cost: int = current_cost + move_cost

			if next_cost > budget:
				continue

			costs[neighbor_key] = next_cost
			# blocked 格（机甲所在等）：可作终点，但不入 frontier--不可穿过继续向外扩展
			if blocked_keys.has(neighbor_key):
				continue
			frontier.append(neighbor)

	# 收集所有可达hex（不包含origin自身；含 blocked 终点格）
	for key: String in costs:
		if key != origin_key:
			var parts: PackedStringArray = key.split(",")
			result.append({"q": int(parts[0]), "r": int(parts[1])})

	return result
