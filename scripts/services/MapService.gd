## MapService.gd — 地图移动服务
##
## 负责：
## - 机甲移动验证与执行
## - 路径可达性检查（基于 BattleMath BFS）
## - 移动动力消耗计算
class_name MapService
extends RefCounted

var context = null  # type: GameContext

const HexGrid = preload("res://scripts/battle/hex_grid.gd")
const BattleMath = preload("res://scripts/battle/battle_math.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")


## 移动机甲到目标六角格
## 验证可移动 → 路径可达 → 计算消耗 → 扣除动力 → 更新位置 → 触发钩子
## power_budget: 可选的动力上限（用于回避/疾行等"使用部分动力移动"的效果）。
##   为 -1 时不限制（使用机甲当前全部动力）；否则可达性与消耗都按 min(机甲动力, power_budget) 判断，
##   但实际扣除仍从机甲动力中扣除（剩余动力保留）。
func move_mech_to_hex(mech_id: StringName, target: Dictionary, power_budget: int = -1) -> Dictionary:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)

	# ── 1. 验证机甲可以移动 ──
	if mech == null:
		return {"ok": false, "message": "机甲不存在"}
	if not mech.can_move():
		return {"ok": false, "message": "机甲无法移动（动力不足或被锁定）"}
	if mech.power <= 0:
		return {"ok": false, "message": "动力不足"}
	if mech.destroyed:
		return {"ok": false, "message": "机甲已被摧毁"}

	# 本次移动可使用的动力上限
	var avail_power: int = mech.power
	if power_budget >= 0:
		avail_power = min(mech.power, power_budget)

	# ── 2. 验证目标格在地图上 ──
	if not gs.map_state.has_cell(target):
		return {"ok": false, "message": "目标格不在地图上"}

	# ── 3. 验证目标格没有被其他机甲占据 ──
	for other_id: StringName in gs.mechs:
		var other: MechState = gs.mechs[other_id]
		if other_id != mech_id and not other.destroyed:
			if HexGrid.key(other.position) == HexGrid.key(target):
				return {"ok": false, "message": "目标格已被占据"}

	# ── 4. 验证路径可达（BFS） ──
	var map_tiles: Array = []
	for cell_key: String in gs.map_state.cells:
		map_tiles.append(gs.map_state.cells[cell_key].to_dict())

	if not BattleMath.can_move(mech.position, target, avail_power, map_tiles):
		return {"ok": false, "message": "目标格不可达或超出动力范围"}

	# ── 5. 计算动力消耗（基础地形每格消耗1点） ──
	var distance: int = HexGrid.distance(mech.position, target)
	var power_cost: int = _calculate_power_cost(mech.position, target, gs)

	if power_cost > avail_power:
		return {"ok": false, "message": "动力不足以移动到目标格"}

	# ── 6. 扣除动力 ──
	if context.game_actions:
			context.game_actions.spend_power({"mech_id": mech_id, "amount": power_cost})
	else:
		mech.power -= power_cost

	# ── 7. 更新位置 ──
	var old_position: Dictionary = mech.position.duplicate()
	mech.position = {"q": int(target.get("q", 0)), "r": int(target.get("r", 0))}

	# ── 8. 触发移动钩子 ──
	_fire_hook(_EffectConst.HOOK_MECH_MOVED, {
		"mech_id": String(mech_id),
		"from": old_position,
		"to": target,
		"power_spent": power_cost,
	})

	# ── 9. 检查目标格地图标记（后续阶段实现） ──
	_check_map_markers(mech, target)

	gs.write_log(&"mech_moved", {
		"mech_id": String(mech_id),
		"from_q": int(old_position.get("q", 0)),
		"from_r": int(old_position.get("r", 0)),
		"to_q": int(target.get("q", 0)),
		"to_r": int(target.get("r", 0)),
		"power_cost": power_cost,
	})
	return {"ok": true, "mech_id": mech_id, "position": target, "power_cost": power_cost}


## 计算到目标格的最低动力路径（不包含起点，包含终点）。
## GREEN=2、NORMAL=1、RED不可通过；其他机甲所在格不可进入。
func find_optimal_path(mech_id: StringName, target: Dictionary, power_budget: int) -> Array[Dictionary]:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null or not gs.map_state.has_cell(target):
		return []
	var start: Dictionary = mech.position.duplicate()
	var start_key: String = HexGrid.key(start)
	var target_key: String = HexGrid.key(target)
	if start_key == target_key:
		return []

	var blocked: Dictionary = {}
	for other_id: StringName in gs.mechs:
		var other: MechState = gs.mechs[other_id]
		if other_id != mech_id and not other.destroyed:
			blocked[HexGrid.key(other.position)] = true

	var frontier: Array[Dictionary] = [{"hex": start, "cost": 0}]
	var costs: Dictionary = {start_key: 0}
	var previous: Dictionary = {}
	while not frontier.is_empty():
		frontier.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["cost"]) < int(b["cost"]))
		var current_entry: Dictionary = frontier.pop_front()
		var current: Dictionary = current_entry["hex"]
		var current_key: String = HexGrid.key(current)
		var current_cost: int = int(current_entry["cost"])
		if current_cost != int(costs.get(current_key, 1 << 30)):
			continue
		if current_key == target_key:
			break
		for neighbor: Dictionary in HexGrid.neighbors(current):
			var neighbor_key: String = HexGrid.key(neighbor)
			if blocked.has(neighbor_key):
				continue
			var cell = gs.map_state.cells.get(neighbor_key)
			if cell == null:
				continue
			var terrain: StringName = _get_cell_terrain(cell)
			if terrain == &"RED" or terrain == &"blocked":
				continue
			var step_cost: int = 2 if terrain == &"GREEN" or terrain == &"rough" else 1
			var next_cost: int = current_cost + step_cost
			if next_cost > power_budget or next_cost >= int(costs.get(neighbor_key, 1 << 30)):
				continue
			costs[neighbor_key] = next_cost
			previous[neighbor_key] = current_key
			frontier.append({"hex": neighbor, "cost": next_cost})

	if not costs.has(target_key):
		return []
	var reversed_path: Array[Dictionary] = []
	var cursor: String = target_key
	while cursor != start_key:
		var parts: PackedStringArray = cursor.split(",")
		reversed_path.append({"q": int(parts[0]), "r": int(parts[1])})
		if not previous.has(cursor):
			return []
		cursor = previous[cursor]
	reversed_path.reverse()
	return reversed_path


## 基础移动的“更新位置”阶段调用：这里只提交位置，不再次扣动力。
func commit_basic_move(mech_id: StringName, target: Dictionary, power_cost: int) -> Dictionary:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null:
		return {"ok": false, "message": "机甲不存在"}
	var old_position: Dictionary = mech.position.duplicate()
	mech.position = {"q": int(target.get("q", 0)), "r": int(target.get("r", 0))}
	_fire_hook(_EffectConst.HOOK_MECH_MOVED, {
		"mech_id": String(mech_id), "from": old_position, "to": target, "power_spent": power_cost,
	})
	# 地图标记触发尚未实装，移动时暂不处理标记（避免调用未实现的 MapState.get_marker_at）。
	gs.write_log(&"mech_moved", {
		"mech_id": String(mech_id),
		"from_q": int(old_position.get("q", 0)), "from_r": int(old_position.get("r", 0)),
		"to_q": int(target.get("q", 0)), "to_r": int(target.get("r", 0)),
		"power_cost": power_cost,
	})
	return {"ok": true, "position": target, "power_cost": power_cost}


## ── 内部方法 ──


## 计算移动动力消耗
## 基础地形每格消耗1点，特殊地形可增加消耗
func _calculate_power_cost(origin: Dictionary, target: Dictionary, gs: GameState) -> int:
	var base_cost: int = HexGrid.distance(origin, target)

	# 检查目标格是否有特殊地形
	var target_cell = gs.map_state.get_cell(target)
	var terrain: StringName = _get_cell_terrain(target_cell)
	match terrain:
		&"rough", &"GREEN":
			return base_cost + 1  # 粗糙地形额外消耗1点
		&"blocked", &"RED":
			return 999  # 不可通过
		_:
			return base_cost


func _get_cell_terrain(cell) -> StringName:
	if cell == null:
		return &"normal"
	if cell is _MapCellState:
		return cell.terrain
	if typeof(cell) == TYPE_DICTIONARY:
		return cell.get("terrain", &"normal")
	return &"normal"


## 检查目标格的地图标记
## 后续阶段实现，当前为占位
func _check_map_markers(mech: MechState, target: Dictionary) -> void:
	var gs: GameState = context.game_state
	for marker: Dictionary in gs.map_state.markers:
		var marker_pos: Dictionary = marker.get("position", {})
		if HexGrid.key(marker_pos) == HexGrid.key(target):
			# 触发标记效果（后续实现）
			pass


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
