## single_move_action.gd — 单次移动动作
##
## 按新规则文档定义的单次移动动作生命周期：
##   ① 选择移动的目标格子
##   ② 确定最优路径，逐格执行基础移动动作
##   ③ 单次移动结算 → 发出 SINGLE_MOVE_SETTLE
##
## 一般机甲的移动都以单次移动动作为主体。
## 回避/疾行/反击等效果产生的移动也是循环执行此动作（loop_until_cancel=true）：
##   每次选一格→移动→扣动力→若剩余动力>0且玩家未取消，继续请求选格，直到动力耗尽或取消。
##
## 选定终点后计算最低动力路径，并为路径中的每个格子动态插入一个 basic_move 子动作步骤。
##
## 参考：new_logic/各动作的生命周期与时点.docx "单次移动动作"
extends Action
class_name SingleMoveAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"single_move"


func setup_steps() -> void:
	steps = [
		{step_name = &"select_target", timing_point = &"", handler = _step_select_target},
		{step_name = &"settle",      timing_point = _TimingConst.SINGLE_MOVE_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "单次移动"


## 移动循环状态（实例字段，循环内持续递减）
var _remaining_power: int = 0
## 是否已初始化本次循环的剩余动力（避免重入 move_step 时重置）
var _power_initialized: bool = false
## 上一步移动的起点（供 _auto_move_target 防回访振荡，B1 修复）
var _prev_pos: Dictionary = {}


## ①② 合并：选择目标 + 执行移动（支持 loop_until_cancel 循环）
## - 首次进入：初始化 _remaining_power（按 available_power / power_fraction 计算），请求选格
## - 玩家回填 target_cell 后重入：执行移动、扣动力、清 target_cell
##   若 loop_until_cancel 且剩余动力>0：再次请求选格（循环）
##   否则：返回结果，进入 settle
func _step_select_target(action: Action) -> Dictionary:
	var mech_id: StringName = action.record.get("mech_id", &"")
	if mech_id == &"":
		return {"error": "缺少 mech_id"}

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return {"error": "机甲不存在"}

	# 首次进入：初始化剩余动力
	if not _power_initialized:
		var available_power: int = action.record.get("available_power", 0)
		if available_power <= 0:
			available_power = mech.power
		var power_fraction: float = action.record.get("power_fraction", 0.0)
		if power_fraction > 0.0:
			available_power = int(available_power * power_fraction)
		_remaining_power = available_power
		_power_initialized = true

	var loop_until_cancel: bool = action.record.get("loop_until_cancel", false)
	var target_cell: StringName = action.record.get("target_cell", &"")

	if target_cell == &"":
		return {
			"need_input": true,
			"input_type": &"select_move_target",
			"input_params": {
				"mech_id": mech_id,
				"available_power": _remaining_power,
				"current_position": mech.position,
				"previous_position": _prev_pos,
				"loop_until_cancel": loop_until_cancel,
			},
		}
	var parts: PackedStringArray = String(target_cell).split(",")
	if parts.size() < 2:
		action.record.erase("target_cell")
		return {"error": "目标格格式错误"}
	var target_hex := {"q": int(parts[0]), "r": int(parts[1])}
	var path: Array[Dictionary] = context.map_service.find_optimal_path(mech_id, target_hex, _remaining_power)
	if path.is_empty():
		action.record.erase("target_cell")
		return {
			"need_input": true, "input_type": &"select_move_target",
			"input_params": {"mech_id": mech_id, "available_power": _remaining_power, "current_position": mech.position, "previous_position": _prev_pos, "invalid_target": true, "loop_until_cancel": loop_until_cancel},
		}
	# 记录本步起点，供下一步 need_input 防回访（B1 振荡修复）
	_prev_pos = mech.position
	var insert_at: int = action.current_step_index + 1
	for cell: Dictionary in path:
		var cell_key: StringName = StringName("%d,%d" % [int(cell.q), int(cell.r)])
		var terrain_cell = context.game_state.map_state.get_cell(cell)
		var cost: int = 2 if terrain_cell != null and terrain_cell.terrain == &"GREEN" else 1
		action.steps.insert(insert_at, {
			step_name = &"execute_basic_move",
			timing_point = &"",
			handler = _step_execute_basic_move.bind(cell_key, cost),
		})
		insert_at += 1
		_remaining_power -= cost
	if loop_until_cancel and _remaining_power > 0:
		action.steps.insert(insert_at, {step_name = &"select_target", timing_point = &"", handler = _step_select_target})
	action.record.erase("target_cell")
	return {"remaining_power": _remaining_power}


func _step_execute_basic_move(action: Action, target_cell: StringName, cost: int) -> Dictionary:
	var result: Dictionary = context.action_service.execute_sub_action({
		"type": &"EXECUTE_BASIC_MOVE",
		"params": {"mech_id": action.record.get("mech_id", &""), "target_cell": target_cell, "available_power": cost},
	}, action.record.duplicate(), action)
	if not action.pending_effect_action_ids.is_empty():
		return {"effect_action_created": true}
	return result


## ③ 单次移动结算
func _step_settle(action: Action) -> Dictionary:
	return {}
