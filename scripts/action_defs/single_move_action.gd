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
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


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
		var max_cells: int = int(action.record.get("max_cells", 0))
		var free_move: bool = bool(action.record.get("free_move", false))
		var available_power: int = action.record.get("available_power", 0)
		if free_move:
			# 免费移动：格数由 max_cells 决定，不依赖动力（狙击腿免费1格相邻）
			available_power = max_cells if max_cells > 0 else 1
		else:
			if available_power <= 0:
				available_power = mech.power
			var power_fraction: float = action.record.get("power_fraction", 0.0)
			if power_fraction > 0.0:
				available_power = int(available_power * power_fraction)
			if max_cells > 0:
				available_power = min(available_power, max_cells)
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
	# adjacent_only：仅允许相邻1格（狙击腿免费相邻移动）
	var adjacent_only: bool = bool(action.record.get("adjacent_only", false))
	if adjacent_only and _HexGrid.distance(mech.position, target_hex) != 1:
		action.record.erase("target_cell")
		return {
			"need_input": true, "input_type": &"select_move_target",
			"input_params": {"mech_id": mech_id, "available_power": _remaining_power, "current_position": mech.position, "previous_position": _prev_pos, "invalid_target": true, "loop_until_cancel": loop_until_cancel},
		}
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
		"params": {"mech_id": action.record.get("mech_id", &""), "target_cell": target_cell, "available_power": cost, "free_move": bool(action.record.get("free_move", false))},
	}, action.record.duplicate(), action)
	# 判断 basic_move 子动作是否仍挂起：effect_017/050 等监听 BASIC_MOVE_AFTER 的效果
	# 可能创建挂起的效果动作，使 basic_move 子动作停在 waiting_effect_action（此时父动作应走
	# 现有 waiting_effect_action 等待机制，由 _handle_effect_action_created 处理）。
	# 子动作已同步完成/取消时 cleanup 已将其从注册表移除 -> get_action 返回 null。
	# 注意：execute_sub_action 总会把子动作 append 进 pending，故不能仅凭 pending 非空判断挂起。
	var child_paused := false
	if not action.pending_effect_action_ids.is_empty():
		var child_id: StringName = action.pending_effect_action_ids[-1]
		var child = context.action_registry.get_action(child_id)
		if child != null and child.state != &"completed" and child.state != &"cancelled":
			child_paused = true
		else:
			# 子动作已同步结束：手动从 pending 清理（deferred _notify_parent 尚未跑），
			# 避免 _handle_effect_action_created 拿到已结束的子动作。
			action.pending_effect_action_ids.erase(child_id)
	if child_paused:
		return {"effect_action_created": true}
	# basic_move 已同步完成。UI 模式逐格动画：每格让出一帧（50ms 定时器），让棋盘逐格重绘
	# 机甲位置（避免多格同帧执行只见终点=瞬移）。仅顶层 single_move（玩家自由移动，
	# move_unit -> execute）生效；效果驱动的子动作 single_move（回避/反击/强袭 EXECUTE_SINGLE_MOVE，
	# parent_action_id 非空）不走逐格动画，避免响应窗口流程被打断/测试需补帧。
	# 仅后续仍有 basic_move 步骤时才暂停--最后一格（下一步为 settle/select_target）不暂停，
	# 避免1格移动也短暂显示取消按钮造成闪烁。测试模式 move_animation_enabled=false 不走此分支。
	# yield_frame 由 ActionEngine 处理：置 waiting_timing 暂停 + 定时器 resume，用 waiting_timing
	# 而非 waiting_effect_action 以避开 basic_move 子动作完成时 call_deferred 的 _notify_parent_deferred 贪心同帧恢复。
	var _next_idx: int = action.current_step_index + 1
	var _has_next_move: bool = _next_idx < action.steps.size() and String(action.steps[_next_idx].get("step_name", &"")) == &"execute_basic_move"
	# 仅人类移动方逐格动画：AI 移动(is_human=false)保持同步瞬移，避免 AI 回合被动画拖慢。
	var _mover_pid: StringName = action.record.get("player_id", &"")
	var _mover_is_human: bool = false
	if _mover_pid != &"" and context.game_state != null and context.game_state.players.has(_mover_pid):
		_mover_is_human = bool(context.game_state.players[_mover_pid].is_human)
	if context.move_animation_enabled and action.parent_action_id == &"" and _has_next_move and _mover_is_human:
		return {"yield_frame": true}
	return result


## ③ 单次移动结算
func _step_settle(action: Action) -> Dictionary:
	return {}
