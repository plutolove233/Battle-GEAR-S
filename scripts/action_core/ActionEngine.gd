## ActionEngine.gd — 动作执行引擎
##
## ActionEngine 负责驱动动作的步骤执行：
##   execute_action —— 同步执行动作，遇到 need_input 或 timing 暂停时暂停
##   continue_action —— UI 提供输入或响应窗口关闭后继续执行
##   cancel_action —— 取消动作
##
## 执行流程：
##   1. 依次执行每个步骤
##   2. 如果步骤有时点，先发出时点（触发监听效果）
##   3. 发出时点后检查是否需要暂停（响应窗口等）
##   4. 执行步骤 handler
##   5. handler 返回 need_input 时暂停并返回等待信号
##   6. 所有步骤执行完毕后，标记为 completed
##
## 父效果动作等待机制：
##   当步骤产生效果动作时，父动作暂停等待效果动作完成。
##   效果动作完成后通知父动作继续执行。
##
## 参考：new_logic/各动作的生命周期与时点.docx
extends RefCounted
class_name ActionEngine
const SLog = preload("res://scripts/services/slog.gd")

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")

## 逐格移动动画每格延迟（秒）。仅 UI 模式（context.move_animation_enabled）生效：
## single_move 每格 basic_move 完成后 yield_frame 让出，由定时器在此延迟后 resume 父动作，
## 让棋盘逐格重绘机甲位置。测试模式不开启动画，不经过此路径。
const _MOVE_FRAME_DELAY := 0.05

## 诊断开关（bug3b 攻击二次结算排查遗留）。
## 默认关闭：这些诊断块每个都在动作驱动热路径上调 get_stack() 拼调用栈再落盘，
## 一旦动作被反复驱动（敌方回合卡死/二次结算余波），会写入 GB 级日志。
## 仅在复现 bug3b 时手动置 true。
const _DIAG_BUG3B := false

func _diag_trace(max_frames: int) -> String:
	var _st: Array = get_stack()
	var _trace := ""
	for i in range(1, min(_st.size(), max_frames + 1)):
		var f = _st[i]
		_trace += "%s:%d@%s " % [String(f.get("source", "").get_file()), int(f.get("line", 0)), String(f.get("function", ""))]
	return _trace

## 依赖注入：GameContext 容器
var context = null

## 当前正在执行步骤的动作（_execute_step 入口压栈/出口恢复，嵌套子动作天然成栈）。
## 供深层代码（GameActions.spend_power -> TimingEngine.fire_power_spent_event 等）反查
## "当前宿主动作"，以便把阻塞式效果动作（动力税弹窗等）正确挂到其下等待。
var current_step_action = null

## 取当前正在执行步骤的最内层动作（无进行中的步骤时为 null）。
func get_current_action():
	return current_step_action

## ── 信号 ──
signal action_started(action_id: StringName, action_type: StringName)
signal action_step_executed(action_id: StringName, step_name: StringName, step_index: int)
signal action_completed(action_id: StringName, action_type: StringName, record: Dictionary)
signal action_cancelled(action_id: StringName, action_type: StringName)
signal action_needs_input(action_id: StringName, input_type: StringName, input_params: Dictionary)


## 执行动作（同步，直到需要输入、时点暂停或完成）
func execute_action(action: Action) -> Dictionary:
	if action == null:
		return {"state": &"error", "message": "动作为空"}

	# 守卫：已完成/已取消的动作不再重复执行。
	# 某些 deferred 通知路径（迎击效果动作完成 → notify_effect_action_completed → continue_action）
	# 可能在动作已完成后再次驱动同一动作，导致带时点的步骤（如 execute_attack 的 ATTACK_AT）
	# 被重跑、时点重复 fire、攻击被"结算两次"。此处直接拒绝重复驱动。
	if action.state == &"completed" or action.state == &"cancelled":
		if _DIAG_BUG3B:
			SLog.log_raw("[DIAG execute_action REJECTED] action=%s state=%s trace=%s" % [String(action.action_id), String(action.state), _diag_trace(7)])
		return {"state": &"error", "message": "动作已结束，不可重复执行: %s (状态: %s)" % [String(action.action_id), String(action.state)]}

	# 战斗已结束：拒绝执行新动作（A3：胜利后动作链应停止）
	if context != null and context.game_state != null and context.game_state.phase == &"battle_over":
		return {"state": &"error", "message": "战斗已结束"}

	action.state = &"running"
	action_started.emit(action.action_id, action.action_type)

	# 记录动作开始
	SLog.log_raw("[ACTION] ===== 开始执行动作 %s (type=%s) =====" % [String(action.action_id), String(action.action_type)])
	SLog.log_raw("[ACTION] 初始参数: %s" % _compact_str(action.record))

	# 从 current_step_index+1 开始执行
	var start_index: int = max(0, action.current_step_index + 1)

	var result := _run_step_loop(action, start_index)
	if not result.is_empty():
		return result

	# 重入守卫：_run_step_loop 期间若被重入 continue_action 完成（state=completed/cancelled），
	# 不再二次 _complete_action（避免二次 emit action_completed / 二次 notify 父动作）。
	if action.state == &"completed" or action.state == &"cancelled":
		return {"state": action.state, "action_id": action.action_id, "record": action.record}

	# 所有步骤执行完毕
	_complete_action(action)
	return {
		"state": &"completed",
		"action_id": action.action_id,
		"record": action.record,
	}


## 辅助方法：将任意对象转成紧凑字符串
func _compact_str(value) -> String:
	var s := str(value)
	s = s.replace("\n", "\\n").replace("\r", "")
	# 截断过长的字符串
	if s.length() > 500:
		s = s.substr(0, 500) + "...[truncated]"
	return s


## 继续执行等待输入的动作
func continue_action(action_id: StringName, input_data: Dictionary) -> Dictionary:
	if context == null or context.action_registry == null:
		return {"state": &"error", "message": "context 或 action_registry 未初始化"}

	var action: Action = context.action_registry.get_action(action_id)
	if action == null:
		# 诊断：动作可能已被 cleanup 移除（完成/取消后），但仍被 continue 驱动——bug3b 二次结算线索。
		if _DIAG_BUG3B:
			SLog.log_raw("[DIAG continue_action NULL] action_id=%s trace=%s" % [String(action_id), _diag_trace(7)])
		return {"state": &"error", "message": "找不到动作: %s" % String(action_id)}
	# 战斗已结束：拒绝继续执行（A3：胜利后动作链应停止）
	if context != null and context.game_state != null and context.game_state.phase == &"battle_over":
		return {"state": &"error", "message": "战斗已结束"}
	if action.state != &"waiting_input" and action.state != &"waiting_timing" and action.state != &"waiting_effect_action":
		if _DIAG_BUG3B:
			SLog.log_raw("[DIAG continue_action REJECTED] action=%s state=%s trace=%s" % [String(action_id), String(action.state), _diag_trace(7)])
		return {"state": &"error", "message": "动作不在等待状态: %s (当前状态: %s)" % [String(action_id), String(action.state)]}

	# 记录恢复前的状态：
	# 翻转后（handler 先跑再 fire timing）由 action.current_step_phase 决定恢复后从哪阶段续跑，
	# 不再用 was_waiting_input 决定是否重跑 handler：
	#   waiting_input + phase==""            —— handler 上次返回 need_input 暂停，重跑 handler 处理输入
	#   waiting_input + phase==timing_firing —— resume_pending_effect 挂起（监听器执行中），不重跑，推进到完成
	#   waiting_timing + phase==timing_firing—— 响应窗口/监听器目标选择挂起，补跑剩余 regular listeners 后推进
	#   waiting_sub_action + phase==handler_done —— 效果动作完成，进阶段3 fire timing
	# phase==timing_done 表示本步已完成、应进下一步（start_index = current+1）。

	# 记录继续执行
	SLog.log_raw("[ACTION] 继续执行动作 %s (type=%s) 输入数据: %s" % [String(action_id), String(action.action_type), _compact_str(input_data)])

	# 将输入数据合并到 record
	action.record.merge(input_data, true)
	action.state = &"running"

	# 决定从哪步续跑：phase==timing_done 表示当前步已完成，进下一步；否则续跑当前步剩余阶段
	var start_index: int
	if action.current_step_phase == &"timing_done":
		start_index = action.current_step_index + 1
		action.current_step_phase = &""  # 清空，让下一步从阶段1开始
	else:
		start_index = action.current_step_index
	if start_index < 0:
		if _DIAG_BUG3B:
			SLog.log_raw("[DIAG continue_action NEG_START] action=%s state=%s csi=%d phase=%s steps=%d" % [String(action_id), String(action.state), action.current_step_index, String(action.current_step_phase), action.steps.size()])

	var loop_result := _run_step_loop(action, start_index)
	if not loop_result.is_empty():
		return loop_result

	# 重入守卫：_run_step_loop 期间若被重入 continue_action 完成（state=completed/cancelled），
	# 不再二次 _complete_action（避免二次 emit action_completed / 二次 notify 父动作）。
	if action.state == &"completed" or action.state == &"cancelled":
		return {"state": action.state, "action_id": action.action_id, "record": action.record}

	# 所有步骤执行完毕
	_complete_action(action)
	return {
		"state": &"completed",
		"action_id": action.action_id,
		"record": action.record,
	}


## 取消动作
## 递归取消所有未完成的效果动作（避免遗留子树），再取消自身并通知父动作
func cancel_action(action_id: StringName) -> void:
	if context == null or context.action_registry == null:
		return

	var action: Action = context.action_registry.get_action(action_id)
	if action == null:
		return

	# 先递归取消所有未完成的效果动作（如联合cancel父use_action_card时，需连带取消其子attack A）
	_cancel_subtree(action)

	action.state = &"cancelled"
	action_cancelled.emit(action.action_id, action.action_type)

	# 若有父动作，从父动作的等待列表中移除，避免父动作永久等待已取消的效果动作
	if action.parent_action_id != &"":
		_notify_parent_cancelled(action.parent_action_id, action_id)

	# 清理动作和关联的临时监听器
	context.action_registry.cleanup_action(action_id)

	# 清除TimingEngine中此动作的已执行效果记录
	if context.timing_engine != null:
		context.timing_engine.clear_executed_effects_for_action(action_id)


## 取消所有活跃动作（回合结束时清理残留）
func cancel_all_actions() -> void:
	if context == null or context.action_registry == null:
		return
	# 复制 ID 列表，避免遍历时修改字典
	var ids: Array[StringName] = context.action_registry.get_active_ids()
	for action_id: StringName in ids:
		cancel_action(action_id)
	# 清空 ActionUIBridge 的等待状态
	if context.action_ui_bridge != null:
		context.action_ui_bridge._waiting_action_id = &""
		context.action_ui_bridge._current_input_type = &""
		context.action_ui_bridge._current_input_params = {}


## 递归取消一个动作的所有未完成效果动作
func _cancel_subtree(action: Action) -> void:
	if action == null or context == null or context.action_registry == null:
		return
	# 复制列表，避免遍历时修改
	var child_ids: Array = action.pending_effect_action_ids.duplicate()
	for child_id: StringName in child_ids:
		var child: Action = context.action_registry.get_action(child_id)
		if child == null:
			continue
		if child.state == &"completed" or child.state == &"cancelled":
			continue
		# 递归取消效果动作（再向下清理其子树）
		cancel_action(child_id)


## 通知父动作：效果动作被取消，从等待列表移除
func _notify_parent_cancelled(parent_action_id: StringName, sub_action_id: StringName) -> void:
	if context == null or context.action_registry == null:
		return
	var parent_action = context.action_registry.get_action(parent_action_id)
	if parent_action == null:
		return
	parent_action.pending_effect_action_ids.erase(sub_action_id)
	# 若父动作所有效果动作都已结束（完成或取消），恢复继续执行
	# 不在此处置 running——continue_action 仅接受等待态(waiting_input/waiting_timing/
	# waiting_sub_action)，先置 running 会被其开头的状态检查拒绝，父动作卡死、
	# 其上游(原攻击动作)也跟着永远无法结算。由 continue_action 内部统一转换状态。
	if parent_action.pending_effect_action_ids.is_empty() and parent_action.state == &"waiting_effect_action":
		_after_sub_action_finished.call_deferred(parent_action)


## ── 内部方法 ──


## 步骤执行循环（phase 驱动，翻转后 handler 先跑再 fire timing）
## 返回 {} 表示所有步骤执行完毕，返回 Dictionary 表示需要暂停
## 每步调 _execute_step，它按 action.current_step_phase 决定从哪阶段续跑
func _run_step_loop(action: Action, start_index: int) -> Dictionary:
	# 诊断(bug3b 二次结算)：每次进入 step loop 都留痕，捕获"同一动作被第二次驱动"的调用栈。
	# 默认关闭（_DIAG_BUG3B）：热路径上 get_stack() + flush 落盘，反复驱动时会写爆日志。
	if _DIAG_BUG3B and action.action_type == &"attack":
		SLog.log_raw("[DIAG step_loop ENTER] action=%s state=%s csi=%d start=%d steps=%d phase=%s _execute_attack_ran=%s trace=%s" % [String(action.action_id), String(action.state), action.current_step_index, start_index, action.steps.size(), String(action.current_step_phase), str(action._execute_attack_ran), _diag_trace(8)])
	var i: int = start_index
	# 守卫：start_index 越界（如测试用 _make_attack 直接 fire 时点、attack 无 steps 或 current_step_index=-1）
	# 直接视为完成，避免 steps[-1] 越界。
	if i < 0 or i >= action.steps.size():
		return {}
	while i < action.steps.size():
		var sig: StringName = _execute_step(action, i)
		# 重入守卫：need_input 信号里 AI 同步自动决策会重入 continue_action 把本动作跑完
		# （_complete_action 已调用、state=completed）。若不在此拦截，外层 loop 会继续 i++ 重跑
		# 步骤并再次 _complete_action -> 双重 notify 沿父链传播 -> 攻击二次结算/移动错误子动作。
		if action.state == &"completed" or action.state == &"cancelled":
			return {}
		# 暂停：need_input / waiting_timing / waiting_sub_action 任一发生
		if action.state == &"waiting_input":
			return {
				"state": &"waiting_input",
				"action_id": action.action_id,
				"step_index": i,
				"input_type": action.record.get("_last_input_type", &"generic"),
				"input_params": action.record.get("_last_input_params", {}),
			}
			# need_input 的 input_type/params 由 _execute_step 阶段1 写入 record
		if action.state == &"waiting_timing":
			return {
				"state": &"waiting_timing",
				"action_id": action.action_id,
				"step_index": i,
				"timing_point": action.steps[i].get("timing_point", &""),
			}
		if action.state == &"waiting_effect_action":
			return {
				"state": &"waiting_effect_action",
				"action_id": action.action_id,
				"step_index": i,
				"pending_effect_action_ids": action.pending_effect_action_ids.duplicate(),
			}
		# negated 跳步：_execute_step 阶段3 已把 current_step_index 设为 settle-1、phase 清空
		# 从 settle 步继续（i 跟随 current_step_index+1）
		if sig == &"skip":
			i = action.current_step_index + 1
		elif sig == &"rewind":
			# pilot_011 挡攻转移：回退到 ATTACK_PRE 步重 fire（phase=timing_firing 已设，跳过 handler）
			i = action.current_step_index
			continue
		else:
			i += 1
	# 所有步骤执行完毕
	return {}  # 空字典表示完成，不需要暂停


## 执行单个步骤（phase 驱动，翻转后 handler 先跑再 fire timing）
## 固定阶段顺序：①handler → ②sub_action → ③fire timing → ④完成
## 按 action.current_step_phase 决定从哪阶段续跑（暂停恢复后续跑剩余阶段）
## 返回 &"ok" 正常推进；&"skip" negated 跳步（仅 attack，跳到 settle 步）
## 暂停时设 action.state（waiting_input/waiting_timing/waiting_sub_action），由 _run_step_loop 检测
func _execute_step(action: Action, i: int) -> StringName:
	# 压栈：记录当前执行步骤的动作；出口恢复上一层（嵌套子动作 handler 内同步执行时天然成栈）
	var _prev_step_action: Variant = current_step_action
	current_step_action = action
	var _step_sig: StringName = _execute_step_inner(action, i)
	current_step_action = _prev_step_action
	return _step_sig


func _execute_step_inner(action: Action, i: int) -> StringName:
	var step: Dictionary = action.steps[i]
	action.current_step_index = i
	# result 仅在阶段1 handler 跑完后有值；恢复重入时 result 为空，阶段2 sub_action 检查因 result.is_empty() 跳过
	var result: Dictionary = {}

	# ── 阶段1：执行 handler（phase=="" 时进入；need_input 恢复时 phase 仍""，重跑 handler） ──
	if action.current_step_phase == &"":
		var handler: Callable = step.get("handler", Callable())
		if handler.is_valid():
			result = handler.call(action)

		# 通知步骤执行完成 + 记录
		action_step_executed.emit(action.action_id, step.get("step_name", &""), i)
		SLog.log_action_step(action.action_id, action.action_type, step.get("step_name", &""), i, {}, result)

		# need_input：暂停，phase 仍""，恢复时重跑本步 handler
		if not result.is_empty() and result.has("need_input"):
			action.state = &"waiting_input"
			var input_type: StringName = result.get("input_type", &"generic")
			var input_params: Dictionary = result.get("input_params", {})
			action.record["_last_input_type"] = input_type
			action.record["_last_input_params"] = input_params
			action_needs_input.emit(action.action_id, input_type, input_params)
			return &"ok"

		# cancelled：步骤判定动作无法继续（如攻击范围内无目标，按规则不产生攻击动作）。
		# 直接取消本动作（递归取消子树、通知 parent），不在本步推进。
		if not result.is_empty() and result.get("cancelled", false):
			cancel_action(action.action_id)
			return &"ok"
		# error：步骤判定动作无法执行（如 use_action_card.validate_card 攻击次数超限、
		# 缺牌、找不到牌实例等）。同 cancelled 处理：取消本动作，避免 error 后继续执行
		# （牌进临时区 / 创建空 attacker 攻击子动作致 UI 无法路由、整链卡死）。
		if not result.is_empty() and result.has("error"):
			SLog.log_raw("[ACTION] %s 步骤 %s 返回 error，取消动作: %s" % [String(action.action_id), String(step.get("step_name", &"")), String(result.get("error", ""))])
			cancel_action(action.action_id)
			return &"ok"

		# multi_target_complete：多目标攻击（双连等）所有复制攻击已同步完成 / 武器已不持有，
		# 主攻击直接完成（不发 ATTACK_AT/AFTER/SETTLE--这些时点由各复制攻击各自发出）。
		if not result.is_empty() and result.get("multi_target_complete", false):
			_complete_action(action)
			return &"ok"

		# yield_frame：handler 请求本步完成后让出一帧（逐格移动动画用，仅 UI 模式）。
		# 标记本步已完成（phase=timing_done，恢复时 continue_action 进下一步而非重跑 handler），
		# 置 waiting_timing 暂停，由 _schedule_move_frame_resume 的 50ms 定时器恢复。
		# 用 waiting_timing 而非 waiting_effect_action：basic_move 子动作同步完成时 _complete_action
		# 已 call_deferred 排入 _notify_parent_deferred，它会检查 state==waiting_effect_action 才恢复--
		# 若用 waiting_effect_action，该贪心 deferred 会在同帧提前恢复（瞬移）。waiting_timing 不被该路径恢复，
		# 仅由定时器恢复，保证每格跨帧可见。
		if not result.is_empty() and result.get("yield_frame", false):
			action.current_step_phase = &"timing_done"
			action.state = &"waiting_timing"
			_schedule_move_frame_resume(action)
			return &"ok"

		# 合并 result 到 record
		if not result.is_empty():
			action.record.merge(result, true)
		action.current_step_phase = &"handler_done"

		# handler 内 effect 选目标/选武器挂起（_request_target_selection 设 waiting_timing，
		# 如聚能 CHOOSE_OWN_WEAPON / 维修 CHOOSE_ENEMY_MECH）：不可立即进阶段3 fire timing--
		# 否则 USE_ACTION_AFTER 触发 pilot_001 01b REPEAT 重跑 effect 又挂起，覆盖第一次的
		# _pending_effect，第一次 effect 永不执行（聚能双重生效只生效1次根因）。
		# 暂停等 resume effect 完成后，continue_action 续跑阶段2/3（phase=handler_done 跳过 handler 不重跑）。
		if action.state == &"waiting_timing":
			return &"ok"

	# ── 阶段2：检查效果动作（phase==handler_done，fire timing 之前） ──
	# sub_action 在 fire 前暂停，恢复后进阶段3 fire（保证监听器读到效果动作完成后的完整 record）
	# effect_action_created 仅在 handler 刚跑完这一次判断（result 非空）；暂停恢复后 result 为空，不重入
	if action.current_step_phase == &"handler_done":
		if not result.is_empty() and result.get("effect_action_created", false):
			if _handle_effect_action_created(action, result):
				# 父动作暂停等待效果动作完成（phase 保持 handler_done）
				action.state = &"waiting_effect_action"
				return &"ok"
		action.current_step_phase = &"timing_firing"

	# ── 阶段3：fire timing（phase==timing_firing） ──
	# 首次进入时 fire timing；暂停恢复后（waiting_timing/waiting_input from resume_pending_effect）
	# 不重 fire，仅补跑待执行的 regular listeners（响应窗口关闭后补跑，含强袭 effect2）。
	# 用 action._step_timing_fired 区分"已 fire"与"待 fire"，避免恢复后重 fire。
	if action.current_step_phase == &"timing_firing":
		var timing_point: StringName = step.get("timing_point", &"")
		if timing_point != &"" and context != null and context.timing_engine != null:
			# pilot_011 挡攻转移回退后：跳过 ATTACK_AT 重 fire。迪恩已用转化效果响应过此攻击，
			# 重 fire 会弹第2次响应窗口并卡死；首次 ATTACK_AT 的 fire + regular listeners 已跑过，
			# 重跑会导致强袭 effect2 等 LISTEN 效果双重结算。直接跳到 timing_done 推进 check_hit。
			var _p011_skip_at: bool = timing_point == _TimingConst.ATTACK_AT and bool(action.record.get("_skip_at_fire", false))
			if _p011_skip_at:
				action.record.erase("_skip_at_fire")
			else:
				if not action._step_timing_fired:
					action._step_timing_fired = true
					context.timing_engine.fire_timing(timing_point, action)
				# 补跑待执行的 regular listeners（响应窗口关闭后补跑，含强袭 effect2）
				# _run_pending_regular_listeners 开头守卫 state==waiting_timing 时 no-op：
				# 首次 fire ATTACK_AT 开响应窗口置 waiting_timing 时跳过补跑（避免提前消费
				# 强袭 effect2 读到 responded=false）；响应窗口关闭恢复后 state=running 才补跑。
				if context.timing_engine.has_method("_run_pending_regular_listeners"):
					context.timing_engine._run_pending_regular_listeners(action)
				# 时点/补跑导致暂停：
				# - waiting_timing：响应窗口 / 监听器目标选择 / resume_pending_effect 挂起
				# - waiting_effect_action：补跑的 listener 创建了子动作（如强袭 effect2 的
				#   EXECUTE_SINGLE_MOVE 创建 single_move），需等子动作完成后恢复继续补跑/推进。
				#   若不在此 return，会清 _step_timing_fired 并推进到下一步（check_hit）用旧位置，
				#   导致强袭2追击移动来不及在命中判定前生效。
				if action.state == &"waiting_timing" or action.state == &"waiting_effect_action":
					return &"ok"
		action._step_timing_fired = false  # 本步 timing 处理完毕，清标志
		action.current_step_phase = &"timing_done"

	# ── 阶段4：完成本步（phase==timing_done） ──
	if action.current_step_phase == &"timing_done":
		# 识破跳步：negated 在 ATTACK_AT fire 期间由识破 effect1 设置，故必须在 fire 之后检查
		# 仅当当前步在 settle 之前才跳--否则 settle 步自身也会满足 negated+attack 而跳到自身，
		# 形成无限循环反复重发 ATTACK_SETTLE（既有 bug，曾因识破测试早失败而被掩盖）。
		if action.negated and action.action_type == &"attack":
			var settle_index: int = _find_settle_step(action)
			if settle_index >= 0 and action.current_step_index < settle_index:
				action.current_step_phase = &""
				action.current_step_index = settle_index - 1
				return &"skip"
			# 已在 settle 或之后 / 无 settle 步：正常结束
		# pilot_011 挡攻转移后回退 ATTACK_PRE 重 fire（让新目标迪恩的 PRE 装备被动触发）。
		# 仅在 ATTACK_AT 步（execute_attack）完成时检测；回退到 PRE 步 phase=timing_firing 跳过
		# select_target handler（目标已由 REDIRECT 设定），重 fire PRE 后推进到 ATTACK_AT 步。
		# 迪恩已用转化效果响应过此攻击（responded=true），重 fire ATTACK_AT 会再次收集 AVAILABILITY
		# 监听器弹第2次响应窗口（迪恩自身成为目标后 effect_01 也可选），导致攻击流程卡死在 ATTACK_AT。
		# 故设 _skip_at_fire：重 fire PRE 后到 ATTACK_AT 步时直接跳过 fire（见阶段3）。
		if action.action_type == &"attack" and action.record.get("_redirect_rewind", false):
			action.record.erase("_redirect_rewind")
			var _rewind_idx := _find_step_by_timing(action, _TimingConst.ATTACK_PRE)
			if _rewind_idx >= 0 and action.current_step_index > _rewind_idx:
				action.current_step_index = _rewind_idx
				action.current_step_phase = &"timing_firing"  # 跳过 handler，直接重 fire PRE
				action._step_timing_fired = false  # 让 PRE 重新 fire
				action.record["_skip_at_fire"] = true  # 重 fire PRE 后跳过 ATTACK_AT 重 fire
				return &"rewind"
		# 清空 phase，准备下一步
		action.current_step_phase = &""

	return &"ok"



## 处理效果动作创建
## 父子关系由 ActionService.execute_sub_action 在创建效果动作时显式登记
## （child.parent_action_id 与 parent.pending_effect_action_ids），这里只读取。
## 返回 true 表示父动作需要暂停等待
func _handle_effect_action_created(parent_action: Action, _result: Dictionary) -> bool:
	if context == null or context.action_registry == null:
		return false

	# pending_effect_action_ids 由 execute_sub_action 显式追加，取末尾即为最新效果动作
	if parent_action.pending_effect_action_ids.is_empty():
		return false

	var sub_action_id: StringName = parent_action.pending_effect_action_ids[-1]
	var sub_action = context.action_registry.get_action(sub_action_id)
	if sub_action == null:
		# 效果动作已不在注册表中（异常），从等待列表移除
		parent_action.pending_effect_action_ids.erase(sub_action_id)
		return false

	# 如果效果动作已完成（同步完成的情况），不需要等待
	if sub_action.state == &"completed" or sub_action.state == &"cancelled":
		parent_action.pending_effect_action_ids.erase(sub_action_id)
		return false

	# 父动作暂停等待
	parent_action.state = &"waiting_effect_action"
	SLog.log_raw("[ACTION] 父动作 %s 等待效果动作 %s 完成" % [String(parent_action.action_id), String(sub_action_id)])
	return true


## 效果动作完成后通知父动作继续
## 效果动作在 _complete_action 中以 call_deferred 延迟调用本方法，避免在清理过程中递归。
## parent_action_id 由 _complete_action 显式传入（cleanup 已移除效果动作，无法再从注册表取其 parent_action_id）。
func notify_effect_action_completed(sub_action_id: StringName, parent_action_id: StringName = &"") -> void:
	if context == null or context.action_registry == null:
		return

	# parent_action_id 优先用传入值；退路：从注册表取效果动作读其 parent_action_id（兼容旧调用方）
	if parent_action_id == &"":
		var sub_action = context.action_registry.get_action(sub_action_id)
		if sub_action != null:
			parent_action_id = sub_action.parent_action_id
	if parent_action_id == &"":
		return

	var parent_action = context.action_registry.get_action(parent_action_id)
	if parent_action == null:
		return

	# 从父动作的等待列表中移除已完成的效果动作
	parent_action.pending_effect_action_ids.erase(sub_action_id)

	SLog.log_raw("[ACTION] 效果动作 %s 完成，父动作 %s(type=%s) 剩余等待: %d" % [String(sub_action_id), String(parent_action_id), String(parent_action.action_type), parent_action.pending_effect_action_ids.size()])

	# 如果所有效果动作都完成了，恢复父动作继续执行
	# 不在此处置 running——continue_action 仅接受等待态(waiting_input/waiting_timing/
	# waiting_sub_action)，先置 running 会被其开头的状态检查拒绝，父动作便永远卡在
	# waiting_sub_action 无法继续后续步骤（表现为攻击既不显示命中也不造成伤害）。
	# 由 continue_action 内部统一完成 waiting_sub_action → running 的转换。
	if parent_action.pending_effect_action_ids.is_empty() and parent_action.state == &"waiting_effect_action":
		SLog.log_raw("[ACTION] 父动作 %s 所有效果动作完成，继续执行" % String(parent_action_id))
		# 继续执行父动作（从下一个步骤开始，不重新执行当前步骤）；
		# 若有串行待创建的效果子动作（_seq），_after_sub_action_finished 会先创建它而非推进。
		_after_sub_action_finished(parent_action)


## 子动作（完成或取消）后的统一续跑逻辑：
## 父动作所有子动作都结束时：先尝试串行续跑下一个效果子动作（TimingEngine._seq），
## 若无可续跑则恢复父动作继续执行。供 notify_effect_action_completed（完成）与
## _notify_parent_cancelled（取消）共用，确保两条路径都续跑串行子动作。
func _after_sub_action_finished(parent_action) -> void:
	if parent_action == null:
		return
	if not parent_action.pending_effect_action_ids.is_empty():
		return  # 还有其它子动作未结束
	if parent_action.state != &"waiting_effect_action":
		return  # 父动作不在等待态（可能已推进/取消）
	# 守卫：父动作正被 TimingEngine 时序效果弹窗挂起（_pending_effect 有记录，如泰格④弃装解锁）。
	# 子动作（如②弃牌 discard_card）完成触发本函数时，若父动作已切到新的时序弹窗挂起，
	# 不可恢复 step loop——否则攻击会跳过弹窗推进到 ATTACK_AFTER，把刚施加的锁定状态清掉。
	if context != null and context.timing_engine != null and context.timing_engine._pending_effect.has(parent_action.action_id):
		return
	# 串行续跑：若有效果子动作待创建（_seq），创建下一个；创建成功则父动作继续等待
	if context != null and context.timing_engine != null and context.timing_engine.has_method(&"_continue_seq_effect_actions"):
		if context.timing_engine._continue_seq_effect_actions(parent_action):
			return
	# pilot_022 塔莉娅 effect_01：抽牌 EXECUTE_GAIN_CARD 子动作（可能异步挂起）完成后续跑打标签+进循环。
	if parent_action.record.has("_pilot_022_draw_pending") and context != null and context.timing_engine != null and context.timing_engine.has_method(&"_continue_pilot_022_draw"):
		if context.timing_engine._continue_pilot_022_draw(parent_action):
			return
	# pilot_019 缴械冲击 弃牌链：EXECUTE_DISCARD 子动作（含 DISCARD_SETTLE 监听者挂起）完成后续跑链式阶段机。
	if parent_action.record.has("_pilot_019_chain") and context != null and context.timing_engine != null and context.timing_engine.has_method(&"_continue_pilot_019_chain"):
		if context.timing_engine._continue_pilot_019_chain(parent_action):
			return
	# pilot_020 肯德 弃任意行动牌：EXECUTE_DISCARD 子动作完成后手动 mark once_per_turn + 恢复。
	if parent_action.record.has("_pilot_020_active_pending") and context != null and context.timing_engine != null and context.timing_engine.has_method(&"_continue_pilot_020_active"):
		if context.timing_engine._continue_pilot_020_active(parent_action):
			return
	# 窗口附加选项串行续跑（洛尔恩 pilot_063 转化掩护 / 温斯顿 pilot_082 转化推进等）：真实牌
	# 批量挂起-恢复完成，或转化流程完成（选牌 use_action_card 子动作结束）后，若还有 pending extra
	# 未启动则续跑。无 pending 时本函数返回 false，继续往下恢复父动作。
	if context != null and context.timing_engine != null and context.timing_engine.has_method(&"_run_next_window_extra_if_pending"):
		if context.timing_engine._run_next_window_extra_if_pending(parent_action):
			return
	# 多目标攻击 fork 续跑：上一个复制攻击完成后，派生下一个或整体结束主攻击。
	# 主攻击不发 ATTACK_AT/AFTER/SETTLE（避免 continue_action 恢复后 fire 主攻击 ATTACK_AT）。
	if parent_action.has_method(&"_continue_fork_attacks"):
		if parent_action._continue_fork_attacks():
			return
	# 无可续跑，恢复父动作继续执行
	continue_action(parent_action.action_id, {})


## 逐格移动动画：yield_frame 后调度一个定时器在 _MOVE_FRAME_DELAY 后恢复父动作。
## ActionEngine 是 RefCounted（无 Node），借 Engine.get_main_loop() 取 SceneTree 创建定时器。
## 定时器到期 -> continue_action 恢复（父动作处于 waiting_timing，phase=timing_done，进下一步）。
## 若动作已被取消/清理，continue_action 会因找不到动作或状态不符安全返回。
func _schedule_move_frame_resume(action) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		# 无 SceneTree（异常环境）直接延迟恢复，避免永久卡死
		continue_action.call_deferred(action.action_id, {})
		return
	var aid: StringName = action.action_id
	var timer = tree.create_timer(_MOVE_FRAME_DELAY)
	timer.timeout.connect(func() -> void:
		continue_action(aid, {}))


## 完成动作（设置状态、发信号、清理）
func _complete_action(action: Action) -> void:
	# 诊断(bug3b 二次结算)：记录每次完成进入时的 state/csi，捕获"已完成动作再次被驱动完成"。
	# 默认关闭（_DIAG_BUG3B）：热路径上 get_stack() + flush，反复驱动时写爆日志。
	if _DIAG_BUG3B and action.action_type == &"attack":
		SLog.log_raw("[DIAG _complete_action ENTER] action=%s prev_state=%s csi=%d _execute_attack_ran=%s trace=%s" % [String(action.action_id), String(action.state), action.current_step_index, str(action._execute_attack_ran), _diag_trace(8)])
	action.state = &"completed"
	action_completed.emit(action.action_id, action.action_type, action.record)

	# 记录动作完成
	SLog.log_raw("[ACTION] ===== 动作完成 %s (type=%s) =====" % [String(action.action_id), String(action.action_type)])
	SLog.log_raw("[ACTION] 最终记录: %s" % _compact_str(action.record))

	# 清理动作（注册表会清理临时监听器）
	if context != null and context.action_registry != null:
		context.action_registry.cleanup_action(action.action_id)

	# 清除TimingEngine中此动作的已执行效果记录
	if context != null and context.timing_engine != null:
		context.timing_engine.clear_executed_effects_for_action(action.action_id)

	# 通知父动作（如果此动作是效果动作）
	if action.parent_action_id != &"":
		# 需要延迟一帧调用，避免在清理过程中递归。
		# 注意：cleanup_action 已从此动作从注册表移除，故此处直接传入 parent_action_id，
		# 避免延迟调用时再从注册表取效果动作（取不到）导致父动作永远不被通知。
		_notify_parent_deferred.call_deferred(action.action_id, action.parent_action_id)


## 延迟通知父动作（避免递归问题）
## sub_action_id 仅用于日志；parent_action_id 由调用方传入，不依赖注册表。
func _notify_parent_deferred(sub_action_id: StringName, parent_action_id: StringName) -> void:
	notify_effect_action_completed(sub_action_id, parent_action_id)


## 查找结算步骤的索引
func _find_settle_step(action: Action) -> int:
	for i in range(action.steps.size()):
		var step: Dictionary = action.steps[i]
		var step_name: StringName = step.get("step_name", &"")
		if step_name == &"settle":
			return i
	return -1


## 按时点查找步骤索引（pilot_011 挡攻转移后回退 ATTACK_PRE 用）
func _find_step_by_timing(action: Action, timing: StringName) -> int:
	for i in range(action.steps.size()):
		var step: Dictionary = action.steps[i]
		if StringName(step.get("timing_point", &"")) == timing:
			return i
	return -1
