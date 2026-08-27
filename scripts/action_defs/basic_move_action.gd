## basic_move_action.gd — 基础移动动作
##
## 按新规则文档定义的基础移动动作生命周期：
##   ① 提取目标格子 → 发出 BASIC_MOVE_BEFORE
##   ② 消耗动力 → 发出 BASIC_MOVE_AT
##   ③ 移动位置 → 发出 BASIC_MOVE_AFTER
##   ④ 基础移动结算 → 发出 BASIC_MOVE_SETTLE
##
## 参考：new_logic/各动作的生命周期与时点.docx "基础移动动作"
extends Action
class_name BasicMoveAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _init() -> void:
	action_type = &"basic_move"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_target",  timing_point = _TimingConst.BASIC_MOVE_BEFORE, handler = _step_extract_target},
		{step_name = &"consume_power",   timing_point = _TimingConst.BASIC_MOVE_AT,     handler = _step_consume_power},
		{step_name = &"move_position",   timing_point = _TimingConst.BASIC_MOVE_AFTER,  handler = _step_move_position},
		{step_name = &"settle",          timing_point = _TimingConst.BASIC_MOVE_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "基础移动"


## ① 提取目标格子
## 检查：目标格子对机甲的当前可用动力是否可达
func _step_extract_target(action: Action) -> Dictionary:
	var mech_id: StringName = action.record.get("mech_id", &"")
	var target_cell: StringName = action.record.get("target_cell", &"")
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null or target_cell == &"":
		return {"error": "缺少机甲或目标格"}
	# 陷落等 cannot_move 状态：基础移动不可执行（UI 高亮已屏蔽，此处兜底程序化调用路径）
	if mech.has_status(&"cannot_move"):
		return {"error": "机甲无法移动"}
	var parts: PackedStringArray = String(target_cell).split(",")
	if parts.size() < 2:
		return {"error": "目标格格式错误"}
	var target := {"q": int(parts[0]), "r": int(parts[1])}
	if _HexGrid.distance(mech.position, target) != 1:
		return {"error": "基础移动只能移动到相邻格"}
	var cell = context.game_state.map_state.get_cell(target)
	if cell == null:
		return {"error": "目标格不在地图上"}
	var terrain: StringName = cell.terrain if "terrain" in cell else &"NORMAL"
	if terrain == &"RED":
		return {"error": "不可通过的地形"}
	for other_id: StringName in context.game_state.mechs:
		var other = context.game_state.mechs[other_id]
		if other_id != mech_id and not other.destroyed and _HexGrid.key(other.position) == _HexGrid.key(target):
			return {"error": "目标格已被占据"}
	# 通用移动消耗参数（效果元数据驱动）：绿格耗 green_cost（光环持有者玩家折扣），
	# 光环转化绿格对所有人视为绿格（红格已在上方排除，光环本就不含红格）。
	var _mcp: Dictionary = context.map_service.resolve_move_cost_params(mech.owner_player_id)
	var _target_key: StringName = StringName("%d,%d" % [int(target.q), int(target.r)])
	var _is_green: bool = terrain == &"GREEN" or _mcp["aura_cells"].has(_target_key)
	var cost: int = int(_mcp["green_cost"]) if _is_green else 1
	var free_move: bool = bool(action.record.get("free_move", false))
	# 免费移动（狙击腿）不检查动力
	if not free_move:
		var available_power: int = int(action.record.get("available_power", mech.power))
		if cost > mech.power or cost > available_power:
			return {"error": "动力不足"}
	return {"power_cost": cost}


## ② 消耗动力
func _step_consume_power(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var mech_id: StringName = action.record.get("mech_id", &"")
	var target_cell: StringName = action.record.get("target_cell", &"")

	if mech_id == &"" or target_cell == &"":
		return result

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return result

	var cost: int = int(action.record.get("power_cost", 0))
	if cost <= 0:
		return {"error": "无效的移动消耗"}

	# 消耗动力（免费移动跳过，仍走完 BASIC_MOVE_AT 时点）
	# reason=BASIC_MOVE：GameActions.spend_power 据此跳过 power_spent 事件通知
	# （移动消耗由 BASIC_MOVE_AT 时点监听，避免动力税效果双计）。
	var free_move: bool = bool(action.record.get("free_move", false))
	if not free_move and context.game_actions != null:
		context.game_actions.spend_power({"mech_id": mech_id, "amount": cost, "reason": &"BASIC_MOVE"})

	result["power_cost"] = cost
	# 注入本回合累计消耗动力，供 POWER_SPENT_THIS_TURN_ABOVE 条件（effect_044/045）在 BASIC_MOVE_AFTER 读
	result["power_spent_this_turn"] = mech.power_spent_this_turn
	return result


## ③ 移动机甲位置
func _step_move_position(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var mech_id: StringName = action.record.get("mech_id", &"")
	var target_cell: StringName = action.record.get("target_cell", &"")

	if mech_id == &"" or target_cell == &"" or context.map_service == null:
		return result

	var parts := target_cell.split(",")
	if parts.size() >= 2:
		var target_hex := {"q": int(parts[0]), "r": int(parts[1])}
		var move_result: Dictionary = context.map_service.commit_basic_move(
			mech_id, target_hex, int(action.record.get("power_cost", 0))
		)
		if not move_result.get("ok", false):
			return {"error": move_result.get("message", "移动失败")}
		result["moved_to"] = target_cell
		# 累计本回合移动格数（effect_012/013 帝国腿主动效果阈值用）
		var _mv_mech = context.game_state.mechs.get(mech_id)
		if _mv_mech != null:
			_mv_mech.cells_moved_this_turn += 1

	return result


## ④ 基础移动结算
func _step_settle(action: Action) -> Dictionary:
	return {}
