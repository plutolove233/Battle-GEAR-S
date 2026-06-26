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


## 移动机甲到目标六角格
## 验证可移动 → 路径可达 → 计算消耗 → 扣除动力 → 更新位置 → 触发钩子
func move_mech_to_hex(mech_id: StringName, target: Dictionary) -> Dictionary:
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

	if not BattleMath.can_move(mech.position, target, mech.power, map_tiles):
		return {"ok": false, "message": "目标格不可达或超出动力范围"}

	# ── 5. 计算动力消耗（基础地形每格消耗1点） ──
	var distance: int = HexGrid.distance(mech.position, target)
	var power_cost: int = _calculate_power_cost(mech.position, target, gs)

	if power_cost > mech.power:
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


## ── 内部方法 ──


## 计算移动动力消耗
## 基础地形每格消耗1点，特殊地形可增加消耗
func _calculate_power_cost(origin: Dictionary, target: Dictionary, gs: GameState) -> int:
	var base_cost: int = HexGrid.distance(origin, target)

	# 检查目标格是否有特殊地形
	var target_cell: Dictionary = gs.map_state.get_cell(target)
	var terrain: StringName = target_cell.get("terrain", &"normal")
	match terrain:
		&"rough":
			return base_cost + 1  # 粗糙地形额外消耗1点
		&"blocked":
			return 999  # 不可通过
		_:
			return base_cost


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
