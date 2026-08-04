## TimingEngine.gd — 时点分发与效果监听
##
## TimingEngine 是新效果系统的调度中心：
##   fire_timing —— 发出时点，暂停当前动作，按优先级执行所有监听器
##   register_permanent_listener —— 注册场上持续效果的永久监听器
##   register_temporary_listener —— 注册行动牌效果的临时监听器（绑定到特定 action_id）
##
## 关键设计：
##   - 时点发出后暂停当前动作，等待所有监听效果执行完毕
##   - 监听效果可产生效果动作，效果动作递归执行
##   - 同一时点多个效果按优先级排序执行（数值越大越先执行；同优先级按注册序号先来后到）
##   - 临时监听器在动作 cleanup 时自动清除
##   - AVAILABILITY模式的效果在响应窗口中处理
##
## 参考：new_logic/各动作的生命周期与时点.docx
extends RefCounted
class_name TimingEngine
const SLog = preload("res://scripts/services/slog.gd")

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionEffect = preload("res://scripts/action_core/ActionEffect.gd")
const _ConditionChecker = preload("res://scripts/action_core/ConditionChecker.gd")
const _TargetChecker = preload("res://scripts/action_core/TargetChecker.gd")
const _CostChecker = preload("res://scripts/action_core/CostChecker.gd")
const _EffectBinding = preload("res://scripts/action_core/EffectBinding.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")

## 诊断开关（时点/效果排查遗留）。默认关闭：ATTACK_SETTLE 等诊断在 fire_timing 路径上，
# 攻击被反复驱动时会写爆日志。复现时再置 true。
const _DIAG_TIMING := false

## 锁定状态封锁响应的优先级阈值：availability_priority 低于此值的迎击牌被封锁。
## 识破（availability_priority=30）≥ 此值，不受封锁，仍可响应。
const _LOCK_SUPPRESS_PRIORITY := 20

## 依赖注入：GameContext 容器
var context = null

## 永久监听器：从装备/机师等场上效果注册
## 格式：{ timing_point: Array[ActionEffect] }
var permanent_listeners: Dictionary = {}

## 临时监听器：从行动牌效果注册，绑定到特定 action_id
## 格式：{ timing_point: Array[{action_id: StringName, action_type: StringName, effect: ActionEffect, card_instance_id: StringName}] }
var temporary_listeners: Dictionary = {}

## 被抑制的响应效果（锁定状态等）
## 格式：{ timing_point: Array[{effect_id: StringName, suppress_below_priority: int}] }
var suppressed_effects: Dictionary = {}

## 监听器注册序号计数器（用于同优先级按"先来后到"稳定排序）
var _listener_seq_counter: int = 0

## 已处理过响应窗口选择的攻击动作集合（去重，防止 response_selected/availability_effect_selected
## 双信号重复触发 handle_response_selection）。动作 cleanup 时清除。
var _handled_response_actions: Dictionary = {}

## 挂起的效果（闪击 optional 弃牌等）：{action_id: {effect, payload}}
## _execute_effect 遇到 optional DISCARD_ACTION_CARD cost 时暂停，把 effect/payload 存此，
## 弹窗让玩家选「弃牌再攻 / 取消」，resume_pending_effect 续跑 _pay_costs + _execute_actions。
var _pending_effect: Dictionary = {}

## 每回合1次使用记录：{ "{card_instance_id}:{once_per_turn_key}": { turn_number: used_count } }
## effect.once_per_turn_key 非空时，_execute_effect 成功执行后在此 +1；
## 触发前检查本回合 used_count >= once_per_turn_max 则跳过。
## scope = turn_number（换 turn 自动失效，无需显式清零）。owner 维度由 card_instance_id 区分。
var _once_per_turn_used: Dictionary = {}

## ── 信号 ──
signal timing_fired(timing: StringName, payload: Dictionary)
signal action_needs_input(action_id: StringName, input_type: StringName, input_params: Dictionary)
signal effect_executed(effect_id: StringName, action_id: StringName)
signal response_window_opened(action_id: StringName, available_cards: Array[Dictionary])
signal response_window_closed(action_id: StringName, selected_effects: Array)
signal request_target_selection(action_id: StringName, effect: ActionEffect, input_type: StringName, payload: Dictionary)

## 装备牌效果实际发动时发出（供消息框显示「⚙ [装备] 牌名 发动效果: 描述」）。
## 仅装备牌来源效果触发；行动牌/机师牌效果走各自消息通道。
## 参数：card_name 牌名 / effect_id / description 效果描述 / source_mech_id 来源机甲
signal equipment_effect_fired(card_name: String, effect_id: StringName, description: String, source_mech_id: StringName)


## 发出时点
## 1. 收集所有匹配的监听器（永久+临时）
## 2. 处理被抑制的效果（锁定状态等）
## 3. 检查是否有AVAILABILITY监听器（响应窗口）
## 4. 如果有响应窗口，暂停动作等待玩家选择
## 5. 按优先级排序执行所有监听效果
func fire_timing(timing: StringName, action) -> void:
	# 如果动作已经被标记为等待状态，跳过执行监听器
	if action.state == &"waiting_timing" or action.state == &"waiting_input":
		return

	# 预初始化 attack-scope 变量字典：使同一时点内「先写后读」的变量可见。
	# payload = record.duplicate() 为浅拷贝，variables 子字典按引用共享，
	# 故高优先级 listener 写入的变量（如 effect_123 在 ATTACK_BEFORE 写 weapon_028_was_last）
	# 对同一 fire_timing 内低优先级 listener（如 effect_124 读取）可见。
	# 不预初始化时，variables 键在首次写入前不存在，payload 副本无此键，同后读 listener 读到空。
	if action.record != null and not action.record.has("variables"):
		action.record["variables"] = {}

	var payload: Dictionary = action.record.duplicate()
	payload["action_id"] = action.action_id
	payload["action_type"] = action.action_type

	# 记录时点触发 — 增强payload包含timing名
	var log_payload := payload.duplicate()
	log_payload["timing_name"] = String(timing)
	SLog.log_timing(timing, action.action_id, action.action_type, log_payload)

	# 发出信号（通知UI层）
	timing_fired.emit(timing, payload)

	# 收集所有匹配的监听器
	var listeners: Array = []

	# 永久监听器（统一字典结构 {"effect", "seq", "binding_context"}）
	var perm: Array = permanent_listeners.get(timing, [])
	for entry: Dictionary in perm:
		var effect: ActionEffect = entry.get("effect")
		if effect == null:
			continue
		# 检查 action_type 过滤
		if effect.listen_action_type != &"" and effect.listen_action_type != action.action_type:
			continue
		# 检查是否被抑制
		if _is_effect_suppressed(timing, effect):
			continue
		listeners.append({"effect": effect, "card_instance_id": entry.get("binding_context", {}).get("card_instance_id", &""), "source_type": &"permanent", "binding_context": entry.get("binding_context", {}), "seq": entry.get("seq", 0)})

	# 临时监听器（绑定到此 action_id 的，或无绑定限制的）
	var temp: Array = temporary_listeners.get(timing, [])
	for entry: Dictionary in temp:
		var bound_id: StringName = entry.get("action_id", &"")
		var bound_type: StringName = entry.get("action_type", &"")
		if bound_id != &"" and bound_id != action.action_id:
			continue
		if bound_type != &"" and bound_type != action.action_type:
			continue
		var effect: ActionEffect = entry.get("effect")
		if effect == null:
			continue
		# 检查是否被抑制
		if _is_effect_suppressed(timing, effect):
			continue
		var card_inst_id: StringName = entry.get("card_instance_id", &"")
		var bind_ctx: Dictionary = entry.get("binding_context", {})
		listeners.append({"effect": effect, "card_instance_id": card_inst_id, "source_type": &"temporary", "binding_context": bind_ctx, "seq": entry.get("seq", 0)})

	# 如果没有监听器，直接返回
	if listeners.is_empty():
		# 诊断：ATTACK_SETTLE 无监听器时留痕（闪击 effect2 未注册/已清理线索）
		if _DIAG_TIMING and String(timing) == "ATTACK_SETTLE":
			SLog.log_raw("[DIAG ATTACK_SETTLE no_listeners] action=%s type=%s state=%s" % [String(action.action_id), String(action.action_type), String(action.state)])
		return

	# 诊断：ATTACK_SETTLE 有监听器时列出 effect_id（确认 flash_effect2 是否被收集到）
	if _DIAG_TIMING and String(timing) == "ATTACK_SETTLE":
		var _ids: Array = []
		for _e: Dictionary in listeners:
			var _eff = _e.get("effect")
			_ids.append(String(_eff.effect_id) if _eff != null else "?")
		SLog.log_raw("[DIAG ATTACK_SETTLE listeners] action=%s listeners=[%s] action_state=%s" % [String(action.action_id), ", ".join(_ids), String(action.state)])

	# 标注每个监听器的 tier/seat/source_card_id，供同优先级排序与"离开手牌/临时区不再触发"校验
	for entry: Dictionary in listeners:
		_annotate_listener_meta(entry)

	# 分离出 AVAILABILITY 模式的效果（响应窗口）
	var availability_listeners: Array = []
	var regular_listeners: Array = []

	for entry: Dictionary in listeners:
		var effect: ActionEffect = entry["effect"]
		if effect.mode == _TimingConst.MODE_AVAILABILITY:
			availability_listeners.append(entry)
		else:
			regular_listeners.append(entry)

	# 处理响应窗口：若有可用响应牌，打开窗口并暂停动作，立即 return 不执行常规监听器
	# （文档第9行：响应窗口有可用牌则暂停，常规监听器等响应窗口关闭后再跑）
	# 翻转后补跑机制：开窗口前把 regular_listeners 暂存到 action，窗口关闭后由
	# ActionEngine._execute_step 阶段3 调 _run_pending_regular_listeners 补跑（含强袭 effect2：
	# 响应窗口关闭后 responded 已写入，effect2 此时执行能读到）。
	if not availability_listeners.is_empty():
		if _handle_response_window(timing, action, availability_listeners):
			# 暂存待补跑的 regular listeners（仅当非空）
			if not regular_listeners.is_empty():
				action._pending_regular_listeners = regular_listeners
				action._pending_timing = timing
				action._pending_timing_payload = payload
			return

	# 按优先级排序执行常规监听器（数值越大越先执行）。
	# 同优先级 tiebreak（设计文档 各动作的生命周期与时点.txt 第10行）：
	#   1) 行动牌(tier0)先于装备牌(tier1)--装备牌执行顺序天然比行动牌低1级；
	#   2) 装备牌之间按玩家座次（turn_order 序号）先后执行；
	#   3) 其余按注册序号 seq 先来后到（行动牌"先使用/进入手牌的先执行"）。
	regular_listeners.sort_custom(func(a, b) -> bool:
		var pa: int = a["effect"].priority
		var pb: int = b["effect"].priority
		if pa != pb:
			return pa > pb
		var ta: int = a.get("tier", 0)
		var tb: int = b.get("tier", 0)
		if ta != tb:
			return ta < tb
		if ta == 1:
			var sa: int = a.get("seat", 0)
			var sb: int = b.get("seat", 0)
			if sa != sb:
				return sa < sb
		return a.get("seq", 0) < b.get("seq", 0)
	)

	# 依次执行每个监听效果
	# 状态监听器携带 binding_context（target_id/weapon_id/source_player_id 等），
	# 注入到该 effect 专用的 payload 副本，供 ConditionChecker 精确匹配（如聚能只对该武器触发）。
	for entry: Dictionary in regular_listeners:
		var effect: ActionEffect = entry["effect"]
		# 行动牌离开手牌后不再触发（规则）：如预判弃掉了对方掩护，掩护虽已收集进本列表，
		# 但已不在手牌，此处校验后跳过。
		if not _listener_card_still_active(entry, effect):
			SLog.log_raw("[TIMING] %s 跳过 %s：来源行动牌已离开手牌" % [String(action.action_id), String(effect.effect_id)])
			continue
		var bind_ctx: Dictionary = entry.get("binding_context", {})
		var effect_payload: Dictionary = payload
		if not bind_ctx.is_empty():
			effect_payload = payload.duplicate()
			effect_payload["binding_context"] = bind_ctx
		_execute_effect(effect, effect_payload, action)
		# 必耗 cost 不可支付时 _execute_effect 已取消本动作（如 effect_110 闪回激光剑动力不足）：
		# 不再继续触发后续监听器，立即返回。
		if action.state == &"cancelled":
			return
		# 该 listener 创建了挂起的子动作（need_input/等更小子动作）：把本动作切
		# waiting_effect_action 并暂存剩余 listeners，等子动作完成后补跑。
		# 用 _last_created_sub_action_paused（检查 pending[-1] state）而非 pending 非空：
		# 同步完成子动作的 call_deferred erase 未执行时 pending 仍非空但未挂起，会误暂停卡死。
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			var _idx_pa: int = regular_listeners.find(entry)
			var _remaining_pa: Array = []
			for _j_pa in range(_idx_pa + 1, regular_listeners.size()):
				_remaining_pa.append(regular_listeners[_j_pa])
			action._pending_regular_listeners = _remaining_pa
			action._pending_timing = timing
			action._pending_timing_payload = payload
			return
		# 若该监听器请求了目标选择/多选弹窗（设 waiting_timing），暂存剩余 listeners 后中断，
		# 等挂起恢复后由 _run_pending_regular_listeners 补跑。否则同优先级后续装备牌效果会丢失
		# （如掩护 CHOOSE_MANY_CARDS 挂起后，effect_006 联邦右腿「被攻击+动力」不再触发）。
		if action.state == &"waiting_timing":
			var _idx_wt: int = regular_listeners.find(entry)
			var _remaining_wt: Array = []
			for _j_wt in range(_idx_wt + 1, regular_listeners.size()):
				_remaining_wt.append(regular_listeners[_j_wt])
			if not _remaining_wt.is_empty():
				action._pending_regular_listeners = _remaining_wt
				action._pending_timing = timing
				action._pending_timing_payload = payload
			return


## 补跑响应窗口关闭后暂存的 regular listeners（翻转后补跑机制）
## 由 ActionEngine._execute_step 阶段3 在 timing_firing 恢复后调用：
##   响应窗口打开时 fire_timing 把 regular_listeners 暂存到 action._pending_regular_listeners，
##   窗口关闭（迎击效果动作完成）后 attack 恢复，此处补跑——此时 responded 等字段已写入，
##   强袭 effect2 等监听 ATTACK_AT 的 LISTEN 效果能读到正确状态。
## 中断续跑：执行中若某 listener 设 waiting_timing（目标选择），保留剩余未执行的，return；
##   恢复后再次调用本方法从剩余继续。执行完毕清空暂存。
func _run_pending_regular_listeners(action) -> void:
	if action == null or action._pending_regular_listeners.is_empty():
		return
	# 守卫：首次 fire ATTACK_AT 若开了响应窗口，action 被置 waiting_timing，此时迎击牌尚未
	# 执行、responded 尚未写入，立即补跑会让强袭 effect2 读到 responded=false 被错误消费。
	# 故仅在 action 处于非 waiting_timing（响应窗口已关闭、从暂停恢复）时才补跑。
	# （首次 fire 后 ActionEngine._execute_step 阶段3 会调本方法，但此时 waiting_timing → no-op；
	#   响应窗口关闭后 continue_action 恢复，state 非 waiting_timing，再调本方法才真正执行。）
	# 扩展：AI 响应同步执行迎击牌 use_action_card 后 action 被置 waiting_effect_action
	# （响应效果动作尚未结算），此时补跑会让强袭 effect2 提前触发、与响应移动并发
	# waiting_input，call_deferred 的 _auto_move_target 把响应方移动目标错路由到攻击方
	# （玩家被 AI 自动移动 bug）。故 waiting_effect_action 也跳过，等响应效果动作全部
	# 结算、continue_action 恢复 state=running 后再补跑。
	if action.state == &"waiting_timing" or action.state == &"waiting_effect_action":
		return
	# 首次补跑时排序（暂存时未排序）；剩余续跑时已是排序后的子集，保持原序
	# _pending_sorted 是 Action 上声明的 bool 成员，直接访问（原 action.get("_pending_sorted", false)
	# 误对 Object 用 2 参数 Dictionary 风格 get，Object.get 只接受 1 参数，size>1 时即报错）
	if action._pending_regular_listeners.size() > 1 and not action._pending_sorted:
		action._pending_regular_listeners.sort_custom(func(a, b) -> bool:
			var pa: int = a["effect"].priority
			var pb: int = b["effect"].priority
			if pa != pb:
				return pa > pb
			var ta: int = a.get("tier", 0)
			var tb: int = b.get("tier", 0)
			if ta != tb:
				return ta < tb
			if ta == 1:
				var sa: int = a.get("seat", 0)
				var sb: int = b.get("seat", 0)
				if sa != sb:
					return sa < sb
			return a.get("seq", 0) < b.get("seq", 0)
		)
		action._pending_sorted = true

	var timing: StringName = action._pending_timing
	# 补跑时刷新 payload：用 action.record 的最新快照重建，而非 fire 时暂存的旧快照。
	# 关键：响应窗口关闭后补跑 regular listeners（如强袭 effect2）时，attack.record.responded
	# 已在窗口里被 RESPOND_ATTACK 写为 true，但 fire ATTACK_AT 时的旧 payload 快照仍 responded=false，
	# 会导致 ATTACK_WAS_RESPONDED 条件失败、强袭 effect2 不触发。此处刷新使条件读到最新状态。
	var payload: Dictionary = action.record.duplicate()
	payload["action_id"] = action.action_id
	payload["action_type"] = action.action_type
	payload["timing_name"] = String(timing)
	# 保留 binding_context 携带项的传递（permanent listener 等额外字段若有）
	var old_payload: Dictionary = action._pending_timing_payload
	for k in old_payload:
		if not payload.has(k):
			payload[k] = old_payload[k]
	var remaining: Array = []
	for entry: Dictionary in action._pending_regular_listeners:
		# 动作已暂停（上一轮某 listener 挂起后恢复，state 仍可能是 running 由调用方保证）
		var effect: ActionEffect = entry["effect"]
		# 行动牌离开手牌后不再触发（规则）：响应窗口暂存期间来源牌可能已被弃置。
		if not _listener_card_still_active(entry, effect):
			SLog.log_raw("[TIMING] %s 跳过 %s：来源行动牌已离开手牌" % [String(action.action_id), String(effect.effect_id)])
			continue
		var bind_ctx: Dictionary = entry.get("binding_context", {})
		var effect_payload: Dictionary = payload
		if not bind_ctx.is_empty():
			effect_payload = payload.duplicate()
			effect_payload["binding_context"] = bind_ctx
		_execute_effect(effect, effect_payload, action)
		# 该 listener 创建了待等待的子动作（如强袭 effect2 的 EXECUTE_SINGLE_MOVE 创建
		# single_move 子动作并挂起 select_move_target）：必须把本动作切 waiting_effect_action
		# 并保留剩余 listeners，等子动作完成后由 notify_effect_action_completed 恢复继续补跑。
		# 否则 ActionEngine 会推进到下一步（如 check_hit）用旧位置，移动来不及在命中判定前生效。
		# 用 _last_created_sub_action_paused（检查 pending[-1] state）而非 pending 非空+running：
		# 同步完成子动作的 call_deferred erase 未执行时 pending 仍非空但未挂起，会误暂停卡死。
		# 与 _fire_timing 的 regular listener 循环保持一致。
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			var idx_pe: int = action._pending_regular_listeners.find(entry)
			for j_pe in range(idx_pe + 1, action._pending_regular_listeners.size()):
				remaining.append(action._pending_regular_listeners[j_pe])
			action._pending_regular_listeners = remaining
			return
		# 该 listener 请求目标选择等挂起：保留剩余（含本轮未执行完的不需保留——_execute_effect 已存 _pending_effect 续跑）
		if action.state == &"waiting_timing":
			# 把当前 entry 之后未执行的加入 remaining
			var idx: int = action._pending_regular_listeners.find(entry)
			for j in range(idx + 1, action._pending_regular_listeners.size()):
				remaining.append(action._pending_regular_listeners[j])
			action._pending_regular_listeners = remaining
			return

	# 全部执行完毕，清空暂存
	action._pending_regular_listeners = []
	action._pending_timing = &""
	action._pending_timing_payload = {}
	action._pending_sorted = false



## 收集所有可用的AVAILABILITY效果，弹出UI让玩家选择
## 返回 true 表示打开了响应窗口（动作已暂停），false 表示无可用响应牌
func _handle_response_window(_timing: StringName, action, availability_entries: Array) -> bool:
	# 构建响应窗口的可用牌列表
	var available_cards: Array[Dictionary] = []

	for entry: Dictionary in availability_entries:
		var effect: ActionEffect = entry["effect"]
		var card_instance_id: StringName = entry.get("card_instance_id", &"")

		# 检查可用条件
		if not _check_availability(effect, action, card_instance_id, entry.get("binding_context", {})):
			continue

		# 构建显示数据
		var display_data: Dictionary = {
			"effect_id": effect.effect_id,
			"card_instance_id": card_instance_id,
			"display_name": effect.display_name,
			"availability_priority": effect.availability_priority,
			"effect": effect,
		}

		# 如果有对应的牌实例，获取牌名
		if card_instance_id != &"" and context != null and context.game_state != null:
			var card = context.game_state.get_card(card_instance_id)
			if card != null and card.def != null:
				display_data["card_name"] = card.def.display_name
				display_data["card_def_id"] = card.def.card_id
				# 标注迎击牌（仅行动牌有 action_type；装备牌/机师牌 card_kind!=action 跳过，避免访问不存在属性报错）
				if card.def.card_kind == &"action" and card.def.action_type == &"迎击":
					display_data["is_counter"] = true

		available_cards.append(display_data)

	# 按可用条件优先级排序（数值越大越先执行）
	# 设计文档（各动作的生命周期与时点.txt 第9行 + 行动牌效果文档第38行响应窗口）：从大到小，同优先级先来后到。
	available_cards.sort_custom(func(a, b) -> bool:
		var pa: int = a["availability_priority"]
		var pb: int = b["availability_priority"]
		if pa != pb:
			return pa > pb
		return a.get("seq", 0) < b.get("seq", 0)
	)

	if available_cards.is_empty():
		return false

	# 发出响应窗口信号，暂停动作
	response_window_opened.emit(action.action_id, available_cards)

	# 更新动作记录中的响应信息
	action.record["has_response_window"] = true
	action.record["response_available_cards"] = available_cards

	# 将动作状态改为等待响应
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"respond_attack", {
		"action_id": action.action_id,
		"available_cards": available_cards,
		"attacker_id": action.record.get("attacker_id", &""),
		"target_id": action.record.get("target_id", &""),
	})
	return true


## 处理响应窗口的选择结果
func handle_response_selection(action_id: StringName, selected_cards: Array[Dictionary]) -> void:
	if context == null or context.action_registry == null or context.action_service == null:
		return

	var attack_action = context.action_registry.get_action(action_id)
	if attack_action == null:
		return

	# 重入保护：响应窗口的玩家选择可能被多个信号回调重复触发
	# （response_panel._on_confirm 同时 emit availability_effect_selected 与 response_selected，
	#  二者在 app_root 中都调用本方法）。若该攻击动作已处理过响应，再次发起 use_action_card 会导致：
	#  同一张迎击牌被使用两次、迎击牌错误绑定到正在等待输入的 single_move 效果动作
	#  （attack_action_id 被偷换成 single_move 的 id）、原攻击动作永远卡在等待状态无法结算
	#  （攻击既不显示命中也不造成伤害）。
	# 用按 action_id 记录"已处理"标记去重，而不依赖 attack_action.state——
	# 单测中攻击动作可能处于 running 态（非 waiting_timing），靠状态判断会误拒合法的首次调用。
	# 动作 cleanup 时通过 clear_handled_response_for_action 清除此标记。
	if _handled_response_actions.has(action_id):
		return
	_handled_response_actions[action_id] = true

	# 玩家取消响应（空选择）：直接恢复 attack 继续执行（不跳过 execute_attack）
	# 注意：不要在此处把 state 设为 running——continue_action 仅接受等待态
	# (waiting_input/waiting_timing/waiting_sub_action)，先置 running 会被它拒绝，
	# 导致攻击动作永远卡在 ATTACK_AT 无法继续 check_hit/apply_damage/settle。
	if selected_cards.is_empty():
		response_window_closed.emit(action_id, selected_cards)
		if context.action_engine != null:
			context.action_engine.continue_action(action_id, {})
		return

	# 按优先级排序选择的效果（数值越大越先执行；同优先级按注册序"先来后到"）
	# 设计文档（行动牌的效果与逻辑.txt 第38行响应窗口）：按优先级顺序，优先级相等按先来后到。
	selected_cards.sort_custom(func(a, b) -> bool:
		var pa: int = a.get("availability_priority", 5)
		var pb: int = b.get("availability_priority", 5)
		if pa != pb:
			return pa > pb
		return a.get("seq", 0) < b.get("seq", 0)
	)

	# 取第一张选中的牌（按优先级排序后）
	# 文档：响应窗口按优先级顺序依次使用/执行；最多1张迎击牌，非迎击牌（装备牌/机师牌）可同选。
	var card_data: Dictionary = selected_cards[0]
	var card_instance_id: StringName = card_data.get("card_instance_id", &"")
	if card_instance_id == &"":
		# 无牌实例（不应发生），按取消处理
		response_window_closed.emit(action_id, selected_cards)
		if context.action_engine != null:
			context.action_engine.continue_action(action_id, {})
		return

	var card = context.game_state.get_card(card_instance_id)
	if card == null:
		return

	# 响应方持有者（行动牌由 register_hand_card_availability 设置；装备牌由 set_equipment 设置）
	var responder_player_id: StringName = card.owner_player_id
	var responder_mech_id: StringName = card.mech_id
	var effect_id: StringName = card_data.get("effect_id", &"")

	# 选中即写 responded（规则：被任何效果响应都算--迎击牌/装备牌/机师牌响应均算被响应）。
	# 强袭 effect2 的 ATTACK_WAS_RESPONDED 条件读此字段决定是否追击移动。
	# 迎击牌 effect1 的 RESPOND_ATTACK 也会写，此处统一提前写，覆盖非迎击牌响应。
	attack_action.record["responded"] = true
	attack_action.record["response_card_id"] = card_instance_id
	attack_action.record["response_source"] = {
		"player_id": responder_player_id,
		"mech_id": responder_mech_id,
		"card_instance_id": card_instance_id,
	}

	# 非迎击牌（装备牌/机师牌）：直接在 attack 动作上执行其 AVAILABILITY 效果的 actions。
	# 装备牌不走 use_action_card；其效果 actions 作为 attack 子动作执行，
	# attack 等子动作完成后由 notify_effect_action_completed 恢复，补跑强袭 effect2 等 regular listeners。
	if card.def.card_kind != &"action":
		# binding_context：装备 AVAILABILITY 效果（如 effect_084）的 condition（SELF_MECH_IS_ATTACK_TARGET
		# 等）经 _make_binding_from_effect 从 binding_context 取来源（响应方），否则回退到 attack.source
		# （攻击方）致条件误判。故注入响应方 card_instance_id/mech_id/player_id/slot_id。
		var nc_bind_ctx: Dictionary = {
			"card_instance_id": card_instance_id,
			"mech_id": responder_mech_id,
			"player_id": responder_player_id,
			"slot_id": card.slot_id if card.get("slot_id") else &"",
		}
		var nc_payload: Dictionary = {
			"source": {
				"card_instance_id": card_instance_id,
				"mech_id": responder_mech_id,
				"player_id": responder_player_id,
				"effect_id": effect_id,
				"source_action_id": action_id,
			},
			"card_instance_id": card_instance_id,
			"mech_id": responder_mech_id,
			"source_mech_id": responder_mech_id,
			"player_id": responder_player_id,
			"attack_action_id": action_id,
			"binding_context": nc_bind_ctx,
			# 攻击目标/发起方：供 effect_084 的 SELF_MECH_IS_ATTACK_TARGET 等 condition 读取
			"target_id": attack_action.record.get("target_id", &""),
			"attacker_id": attack_action.record.get("attacker_id", &""),
		}
		# 装备响应效果含弃牌费用（094/096 光束/热能响应）：先弹"弃1张行动牌"选择窗，
		# 玩家选牌后续跑（弃牌 + 执行效果 actions）。不直接 _execute_effect_by_id--
		# 那会走非可选弃牌的 _pay_costs 自动弃第一张牌（无弹窗），且无攻击牌时 can_pay 失败致效果不执行。
		var nc_effect: ActionEffect = card_data.get("effect")
		if nc_effect != null and _effect_has_discard_cost(nc_effect):
			var _rd_count := 1
			for _rd_cost in nc_effect.costs:
				if _rd_cost is Dictionary and _rd_cost.get("cost_type", &"") == &"DISCARD_ACTION_CARD":
					_rd_count = int(_rd_cost.get("count", 1))
					break
			_pending_effect[action_id] = {
				"effect": nc_effect,
				"payload": nc_payload,
				"phase": &"response_discard",
			}
			attack_action.state = &"waiting_timing"
			response_window_closed.emit(action_id, selected_cards)
			action_needs_input.emit(action_id, &"select_discard_cards", {
				"action_id": action_id,
				"player_id": responder_player_id,
				"discard_player_id": responder_player_id,
				"count": _rd_count,
				"face_up": true,
				"optional": false,
				"effect_id": effect_id,
				"source_label": "%s：弃置1张行动牌响应" % String(card.def.display_name),
			})
			SLog.log_raw("[ACTION] %s 装备响应效果 %s 挂起弃牌选择（持有者 %s）" % [String(action_id), String(effect_id), String(responder_player_id)])
			return
		_execute_effect_by_id(effect_id, nc_payload, attack_action)
		SLog.log_raw("[ACTION] %s 被 %s 响应(非迎击牌效果 %s)" % [String(action_id), String(card_instance_id), String(effect_id)])
		# 若创建了子动作（如 single_move），attack 等其完成；否则同步完成恢复 attack
		if not attack_action.pending_effect_action_ids.is_empty() and attack_action.state != &"waiting_effect_action":
			attack_action.state = &"waiting_effect_action"
		response_window_closed.emit(action_id, selected_cards)
		if attack_action.pending_effect_action_ids.is_empty():
			if context.action_engine != null:
				context.action_engine.continue_action(action_id, {})
		return

	# 行动牌（迎击/辅助等）：发起正式 use_action_card 动作
	var uc_result: Dictionary = context.action_service.execute(&"use_action_card", {
		"player_id": responder_player_id,
		"card_instance_id": card_instance_id,
		"mech_id": responder_mech_id,
		"source_mech_id": responder_mech_id,
		"attack_action_id": action_id,
		"source": {
			"player_id": responder_player_id,
			"mech_id": responder_mech_id,
			"card_instance_id": card_instance_id,
			"effect_id": &"",
			"source_action_id": action_id,
		},
	})

	# 从结果取 use_action_card 动作 id（execute 返回 action_id）
	var uc_action_id: StringName = uc_result.get("action_id", &"") if uc_result is Dictionary else &""
	if uc_action_id == &"":
		# use_action_card 同步失败或已完成，恢复 attack
		# 不在此处置 running——交由 continue_action 完成（它仅接受等待态）。
		response_window_closed.emit(action_id, selected_cards)
		if context.action_engine != null:
			context.action_engine.continue_action(action_id, {})
		return

	var uc_action = context.action_registry.get_action(uc_action_id)

	# 若 use_action_card 已同步完成（如防御牌无效果动作，或回避牌在0动力下立即结束移动），
	# 直接恢复 attack 继续 check_hit/apply_damage/settle。
	# 注意：uc_action 同步完成时其 _complete_action 已用 call_deferred 排入父通知，
	# 但此时 uc_action.parent_action_id 尚未被设置（下方才赋值），该延迟通知拿到空父id会空转。
	# 故此处必须显式恢复 attack，不能依赖效果动作完成回调。
	if uc_action == null or uc_action.state == &"completed" or uc_action.state == &"cancelled":
		response_window_closed.emit(action_id, selected_cards)
		if context.action_engine != null:
			context.action_engine.continue_action(action_id, {})
		return

	# use_action_card 仍在执行（等待 single_move 等效果动作输入）：
	# 建立父子关系，attack 从 waiting_timing 切到 waiting_sub_action，
	# 等 use_action_card 完成后由 notify_effect_action_completed 恢复。
	# （uc_action 尚未完成，parent_action_id 在此设置可被其 _complete_action 的延迟父通知正确捕获。）
	uc_action.parent_action_id = action_id
	if not attack_action.pending_effect_action_ids.has(uc_action_id):
		attack_action.pending_effect_action_ids.append(uc_action_id)
	attack_action.state = &"waiting_effect_action"

	response_window_closed.emit(action_id, selected_cards)


## 注册永久监听器（场上持续效果）
## 永久监听器统一存为字典结构 {"effect": ActionEffect, "seq": int, "binding_context": {}}
## seq 为注册序号，用于同优先级时按"先来后到"稳定排序
## binding_context 可选，携带 source 信息（card_instance_id/mech_id/player_id 等），
##   fire_timing 时注入到传给该 effect 的 payload，供 condition 精确匹配与 skill_bar 过滤当前玩家
func register_permanent_listener(timing: StringName, effect: ActionEffect, binding_context: Dictionary = {}) -> void:
	if not permanent_listeners.has(timing):
		permanent_listeners[timing] = []
	permanent_listeners[timing].append({
		"effect": effect,
		"seq": _next_listener_seq(),
		"binding_context": binding_context,
	})


## 按来源牌实例注销其所有永久监听器（装备弃置/替换时调用）
## 遍历所有时点的 permanent_listeners，移除 binding_context.card_instance_id == card_instance_id 的条目
func unregister_permanent_listeners_for_card(card_instance_id: StringName) -> void:
	if card_instance_id == &"":
		return
	for timing: StringName in permanent_listeners.keys():
		var list: Array = permanent_listeners[timing]
		var filtered: Array = list.filter(func(entry: Dictionary) -> bool:
			var ctx: Dictionary = entry.get("binding_context", {})
			return ctx.get("card_instance_id", &"") != card_instance_id
		)
		if filtered.is_empty():
			permanent_listeners.erase(timing)
		else:
			permanent_listeners[timing] = filtered


## 注销永久监听器
func unregister_permanent_listener(timing: StringName, effect: ActionEffect) -> void:
	if not permanent_listeners.has(timing):
		return
	var list: Array = permanent_listeners[timing]
	list = list.filter(func(entry: Dictionary) -> bool:
		return entry.get("effect") != effect
	)
	if list.is_empty():
		permanent_listeners.erase(timing)
	else:
		permanent_listeners[timing] = list


## 生成下一个监听器注册序号
func _next_listener_seq() -> int:
	_listener_seq_counter += 1
	return _listener_seq_counter


## 标注监听器条目的 tier/seat/source_card_id（供同优先级排序与"离开手牌/临时区不再触发"校验）
## - tier: 0=行动牌, 1=装备牌（装备牌执行顺序比行动牌低1级）
## - seat: 来源玩家在 round_service.turn_order 中的序号（装备牌同优先级按座次执行）
## - source_card_id: 来源牌实例ID（无来源牌的状态监听器为空，不受离开区域校验）
func _annotate_listener_meta(entry: Dictionary) -> void:
	var cid: StringName = entry.get("card_instance_id", &"")
	if cid == &"":
		var bc: Dictionary = entry.get("binding_context", {})
		cid = bc.get("card_instance_id", &"")
	entry["source_card_id"] = cid
	entry["tier"] = 0
	entry["seat"] = 0
	if cid == &"" or context == null or context.game_state == null:
		return
	var card = context.game_state.get_card(cid)
	if card == null or card.def == null:
		return
	if card.def.card_kind == &"equipment":
		entry["tier"] = 1
	var pid: StringName = &""
	var bc2: Dictionary = entry.get("binding_context", {})
	pid = bc2.get("player_id", &"")
	if pid == &"":
		pid = card.owner_player_id
	if pid != &"" and context.round_service != null:
		var idx: int = context.round_service.turn_order.find(pid)
		if idx >= 0:
			entry["seat"] = idx


## 行动牌离开手牌后，其手牌效果（permanent_while_in_hand，如掩护/推进）不再触发（规则，
## 各动作的生命周期与时点.txt）。例：预判 effect2 弃置了对方掩护，掩护虽已被收集进本批
## 监听器，但已不在手牌则跳过。
## 仅校验 permanent_while_in_hand：临时区监听器（打出后的行动牌效果）由动作生命周期
## cleanup 注销；且 counter_effect2 等"牌已结算但效果仍监听原攻击后续时点"的合法场景下
## 牌已在弃牌堆，强行校验 temp_zone 会误伤，故不校验。装备牌规则待定。
func _listener_card_still_active(entry: Dictionary, effect: ActionEffect) -> bool:
	# 效果被压制（NEGATE_EQUIPMENT_EFFECT）的装备：其监听器不触发（保留牌面 stats）
	var neg_cid: StringName = entry.get("card_instance_id", entry.get("source_card_id", &""))
	if neg_cid != &"" and context != null and context.game_state != null:
		var neg_card = context.game_state.get_card(neg_cid)
		if neg_card != null and neg_card.get("effect_negated") == true:
			return false
	if not effect.permanent_while_in_hand:
		return true
	var cid: StringName = entry.get("source_card_id", &"")
	if cid == &"":
		return true
	if context == null or context.game_state == null:
		return true
	var card = context.game_state.get_card(cid)
	if card == null:
		return false
	return card.zone == &"action_hand"


## 注册临时监听器（绑定到特定 action_id）
## status_id: 可选，关联的状态ID，用于状态移除时注销
## binding_context: 可选，监听器的绑定上下文（target_id/weapon_id/source_player_id 等），
##   fire_timing 时注入到传给该 effect 的 payload，供 condition 精确匹配（如聚能只对该武器触发）
func register_temporary_listener(timing: StringName, action_id: StringName, action_type: StringName, effect: ActionEffect, card_instance_id: StringName = &"", status_id: StringName = &"", binding_context: Dictionary = {}) -> void:
	if not temporary_listeners.has(timing):
		temporary_listeners[timing] = []
	temporary_listeners[timing].append({
		"action_id": action_id,
		"action_type": action_type,
		"effect": effect,
		"card_instance_id": card_instance_id,
		"status_id": status_id,
		"binding_context": binding_context,
		"seq": _next_listener_seq(),
	})


## 注册状态效果监听器（施加状态时调用）
## 使用 status_id 关联，状态移除时可精确注销
## binding_context 携带该状态绑定的 target_id/weapon_id/source_player_id 等，供 condition 精确匹配
func register_status_listener(timing: StringName, effect: ActionEffect, status_id: StringName, binding_context: Dictionary = {}) -> void:
	register_temporary_listener(timing, &"", &"", effect, &"", status_id, binding_context)


## 注册AVAILABILITY效果（响应窗口可用牌）
## 在手牌中的牌需要动态注册为AVAILABILITY监听器
func register_availability_listener(timing: StringName, action_id: StringName, effect: ActionEffect, card_instance_id: StringName) -> void:
	register_temporary_listener(timing, action_id, &"", effect, card_instance_id)


## 注销指定动作关联的所有临时监听器
func unregister_listeners_for_action(action_id: StringName) -> void:
	for timing: StringName in temporary_listeners.keys():
		var list: Array = temporary_listeners[timing]
		list = list.filter(func(entry: Dictionary) -> bool:
			return entry.get("action_id", &"") != action_id
		)
		if list.is_empty():
			temporary_listeners.erase(timing)
		else:
			temporary_listeners[timing] = list


## 注销指定牌的所有临时监听器
func unregister_listeners_for_card(card_instance_id: StringName) -> void:
	# 同时注销该牌的永久监听器（如推进 effect2 permanent_while_in_hand 注册的），
	# 保证行动牌离开手牌（打出/弃置/被偷）时其手牌期永久监听器一并清除。
	unregister_permanent_listeners_for_card(card_instance_id)
	for timing: StringName in temporary_listeners.keys():
		var list: Array = temporary_listeners[timing]
		list = list.filter(func(entry: Dictionary) -> bool:
			return entry.get("card_instance_id", &"") != card_instance_id
		)
		if list.is_empty():
			temporary_listeners.erase(timing)
		else:
			temporary_listeners[timing] = list


## 注销指定状态ID关联的所有临时监听器
## 状态移除时调用，确保状态效果不再监听任何时点
func unregister_listeners_for_status(status_id: StringName) -> void:
	for timing: StringName in temporary_listeners.keys():
		var list: Array = temporary_listeners[timing]
		list = list.filter(func(entry: Dictionary) -> bool:
			return entry.get("status_id", &"") != status_id
		)
		if list.is_empty():
			temporary_listeners.erase(timing)
		else:
			temporary_listeners[timing] = list


func unregister_status_effect_listener(status_id: StringName, effect_id: StringName) -> void:
	if status_id == &"" or effect_id == &"":
		return
	for timing: StringName in temporary_listeners.keys():
		var list: Array = temporary_listeners[timing]
		list = list.filter(func(entry: Dictionary) -> bool:
			var listener_effect: ActionEffect = entry.get("effect")
			return entry.get("status_id", &"") != status_id or listener_effect == null or listener_effect.effect_id != effect_id
		)
		if list.is_empty():
			temporary_listeners.erase(timing)
		else:
			temporary_listeners[timing] = list


## 抑制指定时点下低于某优先级的效果（锁定状态用）
func suppress_effects_below_priority(timing: StringName, min_priority: int, source_action_id: StringName = &"") -> void:
	if not suppressed_effects.has(timing):
		suppressed_effects[timing] = []
	suppressed_effects[timing].append({
		"suppress_below_priority": min_priority,
		"source_action_id": source_action_id,
	})


## 清除指定动作的抑制效果
func clear_suppressions_for_action(action_id: StringName) -> void:
	for timing: StringName in suppressed_effects.keys():
		var list: Array = suppressed_effects[timing]
		list = list.filter(func(entry: Dictionary) -> bool:
			return entry.get("source_action_id", &"") != action_id
		)
		if list.is_empty():
			suppressed_effects.erase(timing)
		else:
			suppressed_effects[timing] = list


## 获取指定时点的所有可用条件牌（AVAILABILITY 模式）
func get_available_cards(timing: StringName, action) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var temp: Array = temporary_listeners.get(timing, [])
	for entry: Dictionary in temp:
		var effect: ActionEffect = entry.get("effect")
		if effect == null:
			continue
		if effect.mode != _TimingConst.MODE_AVAILABILITY:
			continue
		# 检查 action_id 绑定
		var bound_id: StringName = entry.get("action_id", &"")
		if bound_id != &"" and bound_id != action.action_id:
			continue
		# 检查可用条件
		var card_instance_id: StringName = entry.get("card_instance_id", &"")
		if _check_availability(effect, action, card_instance_id, entry.get("binding_context", {})):
			result.append({
				"effect_id": effect.effect_id,
				"card_instance_id": entry.get("card_instance_id", &""),
				"display_name": effect.display_name,
				"availability_priority": effect.availability_priority,
				"effect": effect,
				"seq": entry.get("seq", 0),
			})
	# permanent 监听器（装备 AVAILABILITY 效果，如 effect_084 一角兽右腿响应攻击）：
	# 装备设置时注册为 permanent_listener(listen_timing)；card_instance_id 在 binding_context 内。
	# 临时监听器只含手牌迎击牌，装备响应效果须另查 permanent_listeners，否则响应窗口漏列装备效果。
	var perm_avail: Array = permanent_listeners.get(timing, [])
	for pentry: Dictionary in perm_avail:
		var peffect: ActionEffect = pentry.get("effect")
		if peffect == null:
			continue
		if peffect.mode != _TimingConst.MODE_AVAILABILITY:
			continue
		var pbind: Dictionary = pentry.get("binding_context", {})
		var pcid: StringName = pentry.get("card_instance_id", pbind.get("card_instance_id", &""))
		if _check_availability(peffect, action, pcid, pbind):
			result.append({
				"effect_id": peffect.effect_id,
				"card_instance_id": pcid,
				"display_name": peffect.display_name,
				"availability_priority": peffect.availability_priority,
				"effect": peffect,
				"seq": pentry.get("seq", 0),
			})
	# 按可用条件优先级排序（数值越大越先执行；同优先级按注册序"先来后到"）
	result.sort_custom(func(a, b) -> bool:
		var pa: int = a["availability_priority"]
		var pb: int = b["availability_priority"]
		if pa != pb:
			return pa > pb
		return a.get("seq", 0) < b.get("seq", 0)
	)
	return result


## 根据效果ID执行效果（用于EffectFireAction等场景）
## 若 payload.source.card_instance_id 指定，精确匹配该装备牌的 listener entry（双方同名装备区分），
## 并把 entry.binding_context 注入 payload，供 condition/once_per_turn 取来源。
func _execute_effect_by_id(effect_id: StringName, payload: Dictionary, action) -> void:
	var src: Dictionary = payload.get("source", {}) if payload.has("source") else {}
	var want_card_id: StringName = src.get("card_instance_id", payload.get("card_instance_id", &""))
	# 永久监听器（装备 DIRECT 主动效果注册时 timing=effect_id）
	for timing: StringName in permanent_listeners:
		for entry: Dictionary in permanent_listeners[timing]:
			var effect: ActionEffect = entry.get("effect")
			if effect == null or effect.effect_id != effect_id:
				continue
			var bind_ctx: Dictionary = entry.get("binding_context", {})
			var entry_card: StringName = entry.get("card_instance_id", bind_ctx.get("card_instance_id", &""))
			if want_card_id != &"" and entry_card != want_card_id:
				continue  # 精确匹配指定来源牌
			var eff_payload: Dictionary = payload
			if not bind_ctx.is_empty():
				eff_payload = payload.duplicate()
				eff_payload["binding_context"] = bind_ctx
			_execute_effect(effect, eff_payload, action)
			return
	# 临时监听器
	for timing: StringName in temporary_listeners:
		for entry: Dictionary in temporary_listeners[timing]:
			var effect: ActionEffect = entry.get("effect")
			if effect == null or effect.effect_id != effect_id:
				continue
			var bind_ctx: Dictionary = entry.get("binding_context", {})
			var entry_card2: StringName = entry.get("card_instance_id", bind_ctx.get("card_instance_id", &""))
			if want_card_id != &"" and entry_card2 != want_card_id:
				continue
			var eff_payload: Dictionary = payload
			if not bind_ctx.is_empty():
				eff_payload = payload.duplicate()
				eff_payload["binding_context"] = bind_ctx
			_execute_effect(effect, eff_payload, action)
			return


## ── 内部方法 ──


## 执行一个效果
func _execute_effect(effect: ActionEffect, payload: Dictionary, action) -> void:
	# 记录效果开始执行
	SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "checking_conditions"})

	# 检查效果间依赖
	if effect.requires_effect != &"":
		if not _is_required_effect_executed(effect.requires_effect, action.action_id):
			SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "requires_effect_not_executed", "required": String(effect.requires_effect)})
			return

	# 条件检查
	if not _check_conditions(effect, payload, action):
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "conditions_not_met"})
		return

	# 每回合1次检查：effect.once_per_turn_key 非空时，若本回合已用满则跳过
	# （机动头部抽牌、狙击右臂弃牌回动力、帝国腿移动回复等用）
	if effect.once_per_turn_key != &"" and _is_once_per_turn_used_up(effect, payload):
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "once_per_turn_used_up"})
		return

	# 目标检查：需要玩家选择目标时，弹出UI而不是静默跳过
	if not _check_targets(effect, payload, action):
		var needs_target: bool = _effect_needs_player_target(effect)
		if needs_target:
			# 需要玩家选择目标，弹出目标选择UI
			_request_target_selection(effect, payload, action)
			return
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "targets_not_valid"})
		return

	# 费用检查
	if not _check_costs(effect, payload, action):
		# 必耗 cost（optional=false，如 effect_110 闪回激光剑「攻击必耗2动力」）支付失败：
		# 不能静默跳过让父攻击继续（否则不付动力也能攻击）。取消父攻击动作（含反击/闪击复用本武器路径）。
		if _effect_has_mandatory_cost(effect):
			SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "cancelled_parent", "reason": "mandatory_cost_not_payable"})
			SLog.log_raw("[TIMING] %s 必耗 cost 不可支付，取消父动作 effect=%s" % [String(action.action_id), String(effect.effect_id)])
			_cancel_parent_action_for_mandatory_cost(action, effect)
			return
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "costs_not_payable"})
		return

	# optional 弃牌费用（闪击「弃1张行动牌再攻」/ 狙击右臂等装备主动效果）：不直接扣，
	# 弹窗让玩家选弃牌或取消。CostChecker.pay_single 已支持 selected_action_card_ids，玩家选牌后续跑时注入。
	# 手牌为0时跳过拦截走原流程（can_pay 已要求手牌≥1，此处再保险）。
	# 注意：payload 是 attack A 的 record（无顶层 player_id），必须从 action.source 取
	# 发动玩家，否则闪击效果2会因 player_id 取空而跳过弹窗、直接执行再攻。
	# _optional_discard_paid：optional 弃牌已在 resume_pending_effect 默认阶段付清（玩家选牌后），
	# 重跑 _execute_effect（如 effect_069 弃牌后 CHOOSE_ONE 续跑）时跳过弹窗，避免重复弹选牌框。
	if not payload.get("_optional_discard_paid", false) and _has_optional_discard_cost(effect) and _owner_action_hand_count(effect, payload, action) > 0:
		# AI 与人类区分：AI 不弹窗，自动决策弃哪张行动牌（底层逻辑与人类一致）；
		# 人类弹 select_discard_cards 窗让玩家自选。否则 AI 的闪击2会让人类替它选牌。
		var _flash_owner_id: StringName = _owner_player_id_for_effect(effect, payload, action)
		var _flash_mech_id: StringName = &""
		if action != null and action.source is Dictionary:
			_flash_mech_id = action.source.get("mech_id", &"")
		if _is_ai_owner(_flash_owner_id, _flash_mech_id):
			var _ai_sel: Array = _ai_decide_optional_discard(effect, payload, action)
			if _ai_sel.is_empty():
				# AI 无行动牌可弃（理论上不会到这，hand_count>0 已过滤），走不再攻
				SLog.log_raw("[TIMING] %s AI 闪击弃牌决策：无牌可弃，不再攻 effect=%s" % [String(action.action_id), String(effect.effect_id)])
				return
			payload["selected_action_card_ids"] = _ai_sel
			SLog.log_raw("[TIMING] %s AI 闪击弃牌决策：自动弃 %s 后再攻 effect=%s" % [String(action.action_id), str(_ai_sel), String(effect.effect_id)])
			# fall through 到 _pay_costs + _execute_actions（与人类 resume 选牌路径一致）
		else:
			_request_optional_discard(effect, payload, action)
			return

	# 支付费用（_optional_discard_paid 已在 resume 默认阶段付清则跳过，避免 CHOOSE_ONE 重跑 _execute_effect 时重复弃牌）
	if not payload.get("_optional_discard_paid", false):
		_pay_costs(effect, payload, action)

	# 记录效果通过检查，准备执行
	SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "executing", "conditions_passed": true})

	# 装备牌效果发动播报（消息框核查每件装备执行情况用；行动牌/机师牌效果不在此播报）
	_announce_equipment_effect(effect, payload, action)

	# 执行动作列表
	_execute_actions(effect, payload, action)

	# CHOOSE_ONE 等挂起场景：_execute_actions 设了 waiting_timing 并存了 _pending_effect，
	# 此时效果尚未真正执行完，不能 emit completed / mark executed（resume 后重跑 _execute_effect 会补）。
	if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
		return

	# 标记每回合1次使用（机动头部/狙击右臂等 once_per_turn_key 效果）
	_mark_once_per_turn_used(effect, payload)

	# 通知
	effect_executed.emit(effect.effect_id, action.action_id)

	# 记录效果执行完成 — 包含效果详细信息
	SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "completed", "priority": effect.priority, "mode": effect.mode, "actions_count": effect.actions.size()})
	SLog.log_action_detail(action.action_id, String(action.action_type), "effect_completed:" + String(effect.effect_id), action.record)

	# 标记效果已执行
	_mark_effect_executed(effect.effect_id, action.action_id)
	# 联合状态的攻击监听只触发一次；拒绝跟进时状态仍显示到回合结束，
	# 但本回合后续攻击不能再次询问。
	if effect.effect_id == &"unite_status_attack":
		var unite_bind: Dictionary = payload.get("binding_context", {})
		unregister_status_effect_listener(unite_bind.get("status_id", &""), effect.effect_id)
	# 迎击牌效果在 use_action_card 动作里执行，但其 effect2（如反击的反击攻击）
	# 监听原 attack 动作的时点，requires_effect 检查会在 attack 动作的 action_id 下查找。
	# 故迎击牌 effect1 执行后，需同步标记到其响应的 attack 动作，否则 effect2 跨动作查不到。
	var bind_attack_id: StringName = action.record.get("attack_action_id", &"")
	if bind_attack_id != &"" and bind_attack_id != action.action_id:
		_mark_effect_executed(effect.effect_id, bind_attack_id)


## 检查效果是否需要玩家选择目标
func _effect_needs_player_target(effect: ActionEffect) -> bool:
	if effect.target_rules.is_empty():
		return false
	for rule in effect.target_rules:
		var rule_name: String = String(rule.get("rule", ""))
		if rule_name in ["CHOOSE_ENEMY_MECH", "CHOOSE_ENEMY_MECH_IN_RANGE", "CHOOSE_OWN_WEAPON", "CHOOSE_OTHER_MECH", "CHOOSE_MECH_IN_VARIABLE_RANGE", "TARGET_IS_ADJACENT_OR_SELF"]:
			return true
	return false


## 请求玩家选择目标
func _request_target_selection(effect: ActionEffect, payload: Dictionary, action) -> void:
	var rule_name: String = ""
	for rule in effect.target_rules:
		var rn: String = String(rule.get("rule", ""))
		if rn in ["CHOOSE_ENEMY_MECH", "CHOOSE_ENEMY_MECH_IN_RANGE", "CHOOSE_OTHER_MECH", "CHOOSE_MECH_IN_VARIABLE_RANGE"]:
			rule_name = "mech_target_select"
			break
		elif rn == "CHOOSE_OWN_WEAPON":
			rule_name = "weapon_charge_select"
			break
		elif rn == "TARGET_IS_ADJACENT_OR_SELF":
			# 维修等效果：目标为自身+1格内机甲，用专用选择类型
			rule_name = "repair_target_select"
			break

	if rule_name == "":
		return

	# 发出目标选择请求信号
	# 同时设置 action 需要等待目标选择的信息
	action.record["_waiting_for_target"] = true
	action.record["_target_effect_id"] = effect.effect_id
	request_target_selection.emit(action.action_id, effect, rule_name, payload)

	# 存挂起态：玩家选目标后 resume_pending_effect 注入 target_id 续跑 _execute_effect
	# （目标检查在费用/动作之前，故需重跑整个 _execute_effect，而非像 optional 弃牌那样只跑 _pay_costs+_execute_actions）
	_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": "pre_actions_target"}

	# 通知 ActionUIBridge 弹目标选择 UI，同时标记动作暂停（waiting_timing 与 ActionEngine 兼容）
	# input_type 用 select_repair_target / select_mech_target，与 ActionUIBridge 已注册的弹窗分支对齐。
	var bridge_input_type: StringName = &"select_mech_target"
	if rule_name == "repair_target_select":
		bridge_input_type = &"select_repair_target"
	elif rule_name == "weapon_charge_select":
		bridge_input_type = &"select_weapon_for_charge"
	var src_mech_id: StringName = payload.get("source_mech_id", payload.get("mech_id", &""))
	if src_mech_id == &"" and action.source is Dictionary:
		src_mech_id = action.source.get("mech_id", action.source.get("source_mech_id", &""))
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, bridge_input_type, {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"rule": rule_name,
		"mech_id": src_mech_id,
		"card_instance_id": payload.get("card_instance_id", &""),
		"player_id": _effect_popup_owner_pid(effect, payload, action),
	})
	SLog.log_raw("[TIMING] %s 挂起目标选择 effect=%s rule=%s" % [String(action.action_id), String(effect.effect_id), rule_name])


## 效果是否含 optional 的 DISCARD_ACTION_CARD 费用（闪击用）
func _has_optional_discard_cost(effect: ActionEffect) -> bool:
	for cost in effect.costs:
		if cost is Dictionary and cost.get("cost_type", &"") == &"DISCARD_ACTION_CARD" and cost.get("optional", false):
			return true
	return false


## 效果是否含弃置行动牌费用（不论 optional）。用于装备响应效果（094/096）判断是否需弹弃牌选择窗。
func _effect_has_discard_cost(effect: ActionEffect) -> bool:
	for cost in effect.costs:
		if cost is Dictionary and cost.get("cost_type", &"") == &"DISCARD_ACTION_CARD":
			return true
	return false


## 取效果所属玩家的行动手牌数量（用于判断 optional 弃牌是否可弹窗）
## player_id 来源优先级：payload 顶层 → action.source.player_id（attack A 的 record
## 无顶层 player_id，但其 source 携带发动玩家）→ 退回空。
func _owner_action_hand_count(effect: ActionEffect, payload: Dictionary, action = null) -> int:
	var player_id: StringName = _effect_popup_owner_pid(effect, payload, action)
	if player_id == &"" or context == null or context.get("game_state") == null:
		return 0
	var player = context.game_state.players.get(player_id)
	if player == null:
		return 0
	return player.action_hand.size()


## 取效果所属玩家 id（payload 顶层 → action.source → effect.source）
## attack A 的 record 无顶层 player_id，但其 source 携带发动玩家，故必须回退到 action.source。
func _owner_player_id_for_effect(effect: ActionEffect, payload: Dictionary, action = null) -> StringName:
	var player_id: StringName = payload.get("player_id", &"")
	if player_id == &"" and action != null and action.source is Dictionary:
		player_id = action.source.get("player_id", &"")
	if player_id == &"" and effect.source is Dictionary:
		player_id = effect.source.get("player_id", &"")
	return player_id


## 解析效果弹窗应归属的玩家（PvP 路由到正确窗口用）。
## 装备效果优先 binding_context.player_id（装备拥有者）--即使时点由他人动作触发
## （如对手攻击时触发的装备效果），弹窗仍应归装备拥有者：
## "设置在玩家A机甲上的装备牌除非特殊说明，否则只对玩家A生效，选项弹窗只给玩家A弹"。
## 行动牌/状态效果（binding_context 无 player_id）回退 _owner_player_id_for_effect
## （payload 顶层 -> action.source -> effect.source）。
func _effect_popup_owner_pid(effect: ActionEffect, payload: Dictionary, action) -> StringName:
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var pid: StringName = bind_ctx.get("player_id", &"")
	if pid != &"":
		return pid
	return _owner_player_id_for_effect(effect, payload, action)


## AI 闪击 optional 弃牌决策：AI 总是选择再攻，弃自己手里第一张行动牌。
## 返回 [card_instance_id]；若无行动牌可弃则返回空（走取消路径，不再攻）。
## AI 与人类底层逻辑一致（弃1张行动牌→再攻），但选择方式不同：人类弹窗选，AI 自动选。
func _ai_decide_optional_discard(effect: ActionEffect, payload: Dictionary, action) -> Array:
	var player_id: StringName = _effect_popup_owner_pid(effect, payload, action)
	if player_id == &"" or context == null or context.get("game_state") == null:
		return []
	var player = context.game_state.players.get(player_id)
	if player == null or player.action_hand.is_empty():
		return []
	# 取第一张行动牌弃掉（简单策略：闪击本身刚打出已离手，剩余手牌任选一张即可）
	return [player.action_hand[0]]



## 请求 optional 弃牌弹窗（闪击「弃1张行动牌再攻 / 取消」）
func _request_optional_discard(effect: ActionEffect, payload: Dictionary, action) -> void:
	# 存挂起态，玩家选牌后 resume_pending_effect 续跑
	_pending_effect[action.action_id] = {"effect": effect, "payload": payload}
	# 弃牌对象 = 使用此牌的玩家（攻击者），手牌明牌
	# player_id 来源优先级同 _owner_action_hand_count：payload → action.source
	# 弃牌对象 = 效果弹窗归属玩家（装备效果优先 binding_context.player_id=持有者；
	# 行动牌闪击回退 payload/action.source=攻击者）。持有者被攻击时由持有者选弃自己的牌。
	var player_id: StringName = _effect_popup_owner_pid(effect, payload, action)
	var count: int = 1
	for cost in effect.costs:
		if cost is Dictionary and cost.get("cost_type", &"") == &"DISCARD_ACTION_CARD":
			count = int(cost.get("count", 1))
			break
	# 标记动作等待输入（waiting_timing 与 ActionEngine 兼容；fire_timing 循环检测后 return）
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_discard_cards", {
		"action_id": action.action_id,
		"player_id": player_id,
		"count": count,
		"face_up": true,
		"optional": true,
		"effect_id": effect.effect_id,
	})
	SLog.log_raw("[TIMING] %s 挂起 optional 弃牌选择 effect=%s" % [String(action.action_id), String(effect.effect_id)])


## 是否有挂起的效果等待输入（供 ActionUIBridge 决定走 resume_pending_effect 还是 continue_action）
func has_pending_effect(action_id: StringName) -> bool:
	return _pending_effect.has(action_id)


## 恢复挂起的效果（闪击弹窗玩家选牌/取消；维修等目标选择/二选一续跑）
func resume_pending_effect(action_id: StringName, input_data: Dictionary) -> void:
	if not _pending_effect.has(action_id):
		return
	var pending: Dictionary = _pending_effect[action_id]
	_pending_effect.erase(action_id)
	var effect: ActionEffect = pending.get("effect")
	var payload: Dictionary = pending.get("payload", {})
	var phase: StringName = pending.get("phase", &"pre_actions_discard")
	if context == null or context.action_registry == null:
		return
	var action = context.action_registry.get_action(action_id)
	if action == null or effect == null:
		return

	# ── 目标选择/二选一阶段：注入输入后重跑整个 _execute_effect ──
	# （目标检查在费用/动作之前；CHOOSE_ONE 在 _execute_actions 里读 chosen_option_index）
	if phase == &"pre_actions_target":
		# 取消：不执行效果，恢复动作继续后续步骤
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 目标选择被取消，effect=%s 不执行" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 注入 target_id（目标选择）或 chosen_option_index（二选一），续跑 _execute_effect
		if input_data.has("target_id"):
			payload["target_id"] = input_data["target_id"]
		if input_data.has("target_mech_id"):
			payload["target_id"] = input_data["target_mech_id"]
		if input_data.has("chosen_option_index"):
			payload["chosen_option_index"] = input_data["chosen_option_index"]
		# 聚能等 CHOOSE_OWN_WEAPON 目标规则读 selected_weapon_id（非 target_id），
		# 需在此注入，否则重跑 _execute_effect 仍判定无目标->重新挂起->选武器死循环。
		if input_data.has("selected_weapon_id"):
			payload["selected_weapon_id"] = input_data["selected_weapon_id"]
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_target", "input": input_data})
		action.record.erase("_waiting_for_target")
		action.record.erase("_target_effect_id")
		# 重跑：若目标/选择仍未就绪会再次挂起（幂等）
		_execute_effect(effect, payload, action)
		# 守卫：若重跑后效果再次挂起（如维修选完目标后又进入 CHOOSE_ONE 二选一，
		# _execute_actions 设了 waiting_timing 并存了 _pending_effect），此时不可覆盖
		# state、不可推进动作——否则二选一窗口被丢弃、效果静默失效（维修"没有任何用"根因）。
		# 必须等玩家选完二选一后再次 resume，才会真正完成。
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		# 守卫：内嵌动作创建了挂起子动作（如 effect_031 CHOOSE_ONE 确认后 EXECUTE_DAMAGE_CHANGE
		# -> damage_change 需输入损伤移除面板）：须切 waiting_effect_action 等其完成
		# （剩余内嵌动作已存 _seq 由 _continue_seq 续跑），否则父动作被推进、子动作孤立，
		# 其面板被后续时点（如 ATTACK_SETTLE 反击攻击）抢占——近战右腿+反击弹窗冲突根因。
		# 与 choose_integer 阶段（L1224）同款守卫。
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		# 恢复动作继续结算（use_action_card 的 settle 等后续步骤）
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 损伤转移选择阶段：玩家选了转移点数（redirect_plan）或取消 ──
	if phase == &"choose_integer":
		action.record.erase("_waiting_for_choose_integer")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 整数选择被取消，effect=%s 不执行" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var ci_bind_as: String = String(pending.get("bind_as", "n"))
		var ci_val: int = int(input_data.get("chosen_value", 0))
		var ci_choice2: Dictionary = payload.get("choice", {})
		ci_choice2[ci_bind_as] = ci_val
		payload["choice"] = ci_choice2
		_execute_effect(effect, payload, action)
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		# 内嵌动作创建了挂起子动作（如 EXECUTE_DISCARD 选牌 / EXECUTE_SINGLE_MOVE 选目标）：
		# 须切 waiting_effect_action 等其完成（剩余内嵌动作已存 _seq 由 _continue_seq 续跑），
		# 否则父动作被推进、子动作孤立（曾致 effect_040/071 选牌子动作 UI 丢失）。
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	if phase == &"repeat_continue":
		action.record.erase("_waiting_for_repeat_continue")
		var rp_params: Dictionary = pending.get("repeat_params", {})
		# chosen_option_index=0 -> 继续发动；取消或非0 -> 停止
		if input_data.get("cancelled", false) or int(input_data.get("chosen_option_index", -1)) != 0:
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 继续：再排一轮 [自损, 移动, 循环检查] 到 _seq，父动作切 waiting_effect_action，
		# 由 _continue_seq_effect_actions 启动本轮第一个子动作。
		var rp_iter: Array = _repeat_iteration_actions(rp_params, effect)
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": rp_iter}
		action.state = &"waiting_effect_action"
		if _continue_seq_effect_actions(action):
			return
		# 无子动作挂起（不应发生）：推进父动作
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	if phase == &"redirect_select":
		action.record.erase("_waiting_for_redirect")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 损伤转移被取消，effect=%s 不转移" % [String(action_id), String(effect.effect_id)])
			action.record["redirect_absorbed"] = 0
		else:
			var plan: Array = input_data.get("redirect_plan", [])
			_write_redirect_plan(action, plan)
			# 盾牌 all_or_nothing 确认转移时，减伤(absorb)点数被吸收消失；普通转移/不转移为0。
			# _ao_absorb 由 all_or_nothing 挂起时写入 record；非盾牌路径无此键，默认0。
			if bool(input_data.get("all_or_nothing_confirmed", false)):
				action.record["redirect_absorbed"] = int(action.record.get("_ao_absorb", 0))
			else:
				action.record["redirect_absorbed"] = 0
		action.record.erase("_ao_absorb")
		# 续跑 _execute_actions（剩余动作）；redirect_plan 已写 record，_step_set_damage 读它
		# 注意：转移效果是 damage_change 动作在 DAMAGE_REDIRECT_WINDOW 触发的，恢复后 damage_change 继续 _step_set_damage
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 多选阶段：玩家选了若干牌（selected_card_ids）或取消 ──
	# 推进：per_card_actions=动力+4，discard_selected=true 弃置选中推进。
	# effect_063/078：per_card_actions=NEGATE_EQUIPMENT_EFFECT（$chosen_card.card_instance_id），discard_selected=false 不弃置。
	if phase == &"choose_many_cards":
		var cm_action: Dictionary = pending.get("choose_many_action", {})
		var cm_params: Dictionary = cm_action.get("params", {})
		var per_card_actions: Array = cm_params.get("per_card_actions", [])
		var cm_selected: Array = input_data.get("selected_card_ids", [])
		var cm_discard_selected: bool = bool(cm_params.get("discard_selected", true))
		var cm_discard_reason: StringName = cm_params.get("discard_reason", &"ACTION_CARD_PLAYED")
		action.record.erase("_choose_many_shown")
		if not input_data.get("cancelled", false):
			for sel_cid in cm_selected:
				# 注入 chosen_card 供 per_card_actions 中 $chosen_card.card_instance_id 解析
				payload["chosen_card"] = {"card_instance_id": sel_cid}
				for sub_act: Dictionary in per_card_actions:
					if context != null and context.action_service != null:
						context.action_service.execute_sub_action(sub_act, payload, action)
				if cm_discard_selected and context != null and context.action_service != null:
					context.action_service.execute_sub_action({"type": &"EXECUTE_DISCARD", "params": {"card_ids": [sel_cid], "reason": cm_discard_reason}}, payload, action)
			# 标记每回合1次（赤枭躯干 effect_040/041：确认即消耗次数，含选0张=弃0+0动力；
			# 取消路径不至此，不消耗。无 once_per_turn_key 的效果为 no-op）
			_mark_once_per_turn_used(effect, payload)
			# post_actions：选牌完成后执行一次（雄鹰躯干 effect_071/072 按弃牌数移动）。
			# $choice.count = 选中牌数。预解析 *_expr/$binding_context/$choice 后串行执行
			# （仿 CHOOSE_INTEGER）。选0张时跳过（如雄鹰弃0=移0格，无事发生）。
			var cm_post_actions: Array = cm_params.get("post_actions", [])
			if not cm_post_actions.is_empty() and not cm_selected.is_empty():
				var cm_choice_full: Dictionary = payload.get("choice", {})
				cm_choice_full["count"] = cm_selected.size()
				payload["choice"] = cm_choice_full
				var cm_resolved_post: Array = []
				for cm_sub: Dictionary in cm_post_actions:
					var cm_merged: Dictionary = cm_sub.duplicate(true)
					var cm_sp: Dictionary = cm_merged.get("params", {})
					var cm_erase: Array = []
					for cm_k in cm_sp:
						if String(cm_k).ends_with("_expr"):
							var cm_base: String = String(cm_k).trim_suffix("_expr")
							cm_sp[cm_base] = _eval_expr(String(cm_sp[cm_k]), payload, cm_choice_full)
							cm_erase.append(cm_k)
						elif context != null and context.action_service != null:
							cm_sp[cm_k] = context.action_service._resolve_atomic_value(cm_sp[cm_k], payload, action)
					for cm_k in cm_erase:
						cm_sp.erase(cm_k)
					cm_merged["params"] = cm_sp
					cm_resolved_post.append(cm_merged)
				for cm_i: int in range(cm_resolved_post.size()):
					var cm_act: Dictionary = cm_resolved_post[cm_i]
					if context != null and context.action_service != null:
						context.action_service.execute_sub_action(cm_act, payload, action)
					if _last_created_sub_action_paused(action):
						var cm_remaining: Array = cm_resolved_post.slice(cm_i + 1)
						if not cm_remaining.is_empty():
							action.record["_seq_effect_actions"] = {
								"payload": payload,
								"remaining": cm_remaining,
							}
						break
		payload.erase("chosen_card")
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_target", "input": input_data})
		# 子动作挂起/未完成 -> 等 _after_sub_action_finished 恢复；否则恢复迎击牌 use_action_card 继续 effect1
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 联合攻击选牌阶段：Target 选了1张攻击牌（selected_card_id）或取消 ──
	if phase == &"unite_attack_offer":
		var uao_bind: Dictionary = payload.get("binding_context", {})
		var uao_target_mech: StringName = uao_bind.get("target_id", &"")
		var uao_status_id: StringName = uao_bind.get("status_id", &"")
		var uao_selected: StringName = input_data.get("selected_card_id", &"")
		action.record.erase("_unite_attack_shown")
		# 联合攻击监听器每状态只触发1次（规范"之后结束监听"）：无论确认/取消都注销本监听器，
		# 防止本回合 unite 机甲后续攻击再次弹窗。确认路径下 REMOVE_STATUS 移除状态时也会注销，
		# 此处先注销是幂等的（unregister_status_effect_listener 按 status_id+effect_id 过滤）。
		_mark_effect_executed(effect.effect_id, action.action_id)
		unregister_status_effect_listener(uao_status_id, effect.effect_id)
		if not input_data.get("cancelled", false) and uao_selected != &"":
			# 创建 use_action_card(B) 作为独立顶层动作（不阻塞 attackA）。
			# 文档"结束监听后"联合攻击独立结算：attackA 立即继续推进 cleanup（弃置等），
			# 联合攻击B 自行走完整攻击流程（选武器/目标/响应窗口/结算），两者并行。
			# source_action_id=attackA 非空 -> validate 跳过 can_attack（不消耗攻击次数）、settle 不 +1。
			var uao_player = context.game_state.get_player_for_mech(uao_target_mech) if (uao_target_mech != &"" and context.game_state != null) else null
			var uao_pid: StringName = uao_player.player_id if uao_player != null else &""
			var uao_params: Dictionary = {
				"card_instance_id": uao_selected,
				"mech_id": uao_target_mech,
				"player_id": uao_pid,
				"is_virtual": false,
				"target_count": 1,
				"source_action_id": action.action_id,
			}
			if context.action_service != null:
				var uao_result: Dictionary = context.action_service.execute(&"use_action_card", uao_params)
				var uao_use_action_id: StringName = uao_result.get("action_id", &"") if uao_result is Dictionary else &""
				# use_action_card(B) 排队 REMOVE_STATUS：其 attackB 结算完成后去除联合状态
				# （_after_sub_action_finished -> _continue_seq_effect_actions 续跑，与 attackA 无关）。
				# 守卫 state!=cancelled：use_action_card validate 失败（如缺牌）被修复2 cancel 时不排 _seq。
				if uao_use_action_id != &"" and context.action_registry != null:
					var uao_use_action = context.action_registry.get_action(uao_use_action_id)
					if uao_use_action != null and uao_use_action.state != &"cancelled":
						uao_use_action.record["_seq_effect_actions"] = {
							"payload": payload,
							"remaining": [{"type": &"REMOVE_STATUS", "params": {"status_type": &"UNITE", "status_id": uao_status_id, "target_id": uao_target_mech}}],
						}
						SLog.log_raw("[TIMING] %s 联合攻击 use_action_card(%s) 独立执行（不阻塞），排队 REMOVE_STATUS status=%s" % [String(action.action_id), String(uao_use_action_id), String(uao_status_id)])
		# 取消/无选择/已完成：恢复动作继续结算（attack 推进到 cleanup 步）
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_unite_attack", "input": input_data})
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 立即设置装备阶段（effect_005）：玩家选了合法槽(chosen_slot_id)或取消 ──
	if phase == &"draw_equipment_set":
		var deis_drawn_id_r: StringName = pending.get("drawn_card_id", &"")
		var deis_mech_id_r: StringName = pending.get("mech_id", &"")
		var deis_player_id_r: StringName = pending.get("player_id", &"")
		var deis_valid_slots_r: Array = pending.get("valid_slots", [])
		var deis_chosen_slot: StringName = input_data.get("chosen_slot_id", &"")
		if input_data.get("chosen_action", &"") == &"sell":
			# effect_065 卖出抽到的装备（走标准卖出：金币+2/turn计数）
			if context != null and context.card_set_service != null:
				var deis_sell_res: Dictionary = context.card_set_service.sell_equipment(deis_player_id_r, deis_drawn_id_r)
				if not deis_sell_res.get("ok", false) and context.deck_service != null:
					context.deck_service.discard_card(deis_drawn_id_r, &"effect_unset_discard")
			elif context != null and context.deck_service != null:
				context.deck_service.discard_card(deis_drawn_id_r, &"effect_unset_discard")
		elif not input_data.get("cancelled", false) and deis_chosen_slot != &"" and deis_valid_slots_r.has(deis_chosen_slot):
			_do_immediate_set_equipment(deis_mech_id_r, deis_player_id_r, deis_drawn_id_r, deis_chosen_slot)
		else:
			# 取消/无选择/非法槽：弃置抽到的牌（"若不立即设置则需要直接弃置"）
			if context != null and context.deck_service != null:
				context.deck_service.discard_card(deis_drawn_id_r, &"effect_unset_discard")
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_immediate_set", "input": input_data})
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 响应窗口装备效果的弃牌阶段（094/096 光束/热能响应）：玩家选了1张行动牌或取消 ──
	if phase == &"response_discard":
		if input_data.get("cancelled", false):
			# 取消：不执行效果，回退 responded（攻击目标未响应），attack 继续（攻击方放损伤）
			SLog.log_raw("[TIMING] %s 装备响应弃牌被取消，effect=%s 不执行，回退 responded" % [String(action_id), String(effect.effect_id)])
			action.record["responded"] = false
			action.record.erase("response_card_id")
			action.record.erase("response_source")
			if context.action_engine != null:
				action.state = &"waiting_timing"
				context.action_engine.continue_action(action_id, {})
			return
		# 选了牌：注入 selected_action_card_ids，支付弃牌费用后执行效果 actions
		var rd_selected: Array = input_data.get("selected_action_card_ids", [])
		payload["selected_action_card_ids"] = rd_selected
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_response_discard", "selected": rd_selected})
		# 支付弃牌费用（CostChecker.pay_single 用 selected_action_card_ids 弃指定牌）
		_pay_costs(effect, payload, action)
		payload["_optional_discard_paid"] = true  # 防 _execute_effect 重跑时再走弃牌弹窗/扣费
		_announce_equipment_effect(effect, payload, action)
		_execute_actions(effect, payload, action)
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		effect_executed.emit(effect.effect_id, action.action_id)
		_mark_effect_executed(effect.effect_id, action.action_id)
		_mark_once_per_turn_used(effect, payload)
		# 若创建了子动作（如 single_move），attack 等其完成；否则恢复 attack 继续结算
		var _rd_has_pending_sub := false
		if context.action_registry != null:
			for _rd_sub_id: StringName in action.pending_effect_action_ids:
				var _rd_sub = context.action_registry.get_action(_rd_sub_id)
				if _rd_sub != null and _rd_sub.state != &"completed" and _rd_sub.state != &"cancelled":
					_rd_has_pending_sub = true
					break
		if _rd_has_pending_sub:
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_timing"
			context.action_engine.continue_action(action_id, {})
		return

	# 取消：不弃牌、不执行 actions，直接恢复 attack 继续结算。
	# 翻转后（handler 先跑再 fire timing）：ATTACK_SETTLE fire 时 _step_settle handler 已执行（写日志），
	# flash_effect2 挂起使 attack 停在 settle 步的 timing_firing 阶段。恢复时应推进到 timing_done
	# → cleanup 步（弃攻击牌），而非重跑 settle handler。故置 waiting_timing（非 waiting_input），
	# continue_action 按 phase=timing_firing 推进，不重跑 handler。
	if input_data.get("cancelled", false):
		SLog.log_raw("[TIMING] %s optional 弃牌被取消，effect=%s 不执行" % [String(action_id), String(effect.effect_id)])
		if context.action_engine != null:
			action.state = &"waiting_timing"
			context.action_engine.continue_action(action_id, {})
		return

	# 玩家选了牌：把 selected_action_card_ids 注入 payload，续跑 _pay_costs + _execute_actions
	var selected: Array = input_data.get("selected_action_card_ids", [])
	payload["selected_action_card_ids"] = selected
	SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming", "selected": selected})
	_pay_costs(effect, payload, action)
	# 标记 optional 弃牌已付：重跑 _execute_effect（CHOOSE_ONE 续跑，如 effect_069 弃牌后二选一）
	# 时跳过选牌弹窗与重复扣费（_execute_effect 的 optional 弃牌拦截与 _pay_costs 均读此标志）。
	payload["_optional_discard_paid"] = true
	# 装备效果发动播报：_execute_effect 首轮在 optional 弃牌处提前返回未播报，此处补；
	# _announced_equipment_effects 去重保证幂等（CHOOSE_ONE 重跑 _execute_effect 再播报时跳过）。
	_announce_equipment_effect(effect, payload, action)
	_execute_actions(effect, payload, action)
	# CHOOSE_ONE 等挂起场景：_execute_actions 设 waiting_timing + _pending_effect 时效果尚未完成，
	# 不可 emit/mark/推进动作--等 pre_actions_target 重跑 _execute_effect 补齐（effect_069 圣牛右腿
	# 弃牌后弹"抽1牌/回2动力"二选一即走此路径）。否则动作被 continue_action 推进、二选一弹窗孤立。
	if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
		return
	effect_executed.emit(effect.effect_id, action.action_id)
	_mark_effect_executed(effect.effect_id, action.action_id)
	# 标记每回合1次使用：_execute_effect 首轮在 optional 弃牌处提前返回未标记，此处补标记，
	# 否则狙击右臂(024)/狙击影右臂(057)/圣牛右腿(069)等 optional 弃牌 + once_per_turn 效果
	# 可每回合重复触发（取消路径不至此，不消耗次数，符合"取消=不发动"裁定）。
	_mark_once_per_turn_used(effect, payload)

	# 闪击再攻：_execute_actions 创建的 attack B 若未立即完成（如等待玩家在武器范围内选目标），
	# 父动作 attack A 须等待其完成再继续 cleanup。仿 choose_many_cards / unite_attack_offer 阶段守卫：
	# 仅当存在未完成（非 completed/cancelled）的效果动作时才等待，否则恢复 attack 继续结算。
	var _has_pending_sub := false
	if context.action_registry != null:
		for _sub_id: StringName in action.pending_effect_action_ids:
			var _sub = context.action_registry.get_action(_sub_id)
			if _sub != null and _sub.state != &"completed" and _sub.state != &"cancelled":
				_has_pending_sub = true
				break
	if _has_pending_sub:
		action.state = &"waiting_effect_action"
		return

	# 恢复 attack 继续结算。闪击 effect2 监听 ATTACK_SETTLE，翻转后 fire 在 settle handler 之后，
	# 挂起时 attack 处于 settle 步的 timing_firing 阶段（handler 已跑）。恢复应推进到 timing_done →
	# cleanup 步（弃攻击牌），故置 waiting_timing 让 continue_action 按 phase 推进而非重跑 handler。
	if context.action_engine != null:
		action.state = &"waiting_timing"
		context.action_engine.continue_action(action_id, {})


## 记录已执行的效果（用于 requires_effect 检查）
var _executed_effects: Dictionary = {}  # {action_id: {effect_id: true}}

## 已播报过「装备效果发动」消息的 (action_id, effect_id) 集合。
## CHOOSE_ONE/目标选择 等挂起后 resume 会重跑 _execute_effect，借此去重，避免同一效果重复播报。
## 在 clear_executed_effects_for_action 随动作清理一并清除。
var _announced_equipment_effects: Dictionary = {}  # {action_id: {effect_id: true}}

## 取 once_per_turn 的使用计数 key 所需的 card_instance_id
## 优先 payload.binding_context.card_instance_id（装备 permanent listener），
## 退回 payload.card_instance_id（行动牌 DIRECT 效果）
func _once_per_turn_card_instance_id(effect: ActionEffect, payload: Dictionary) -> StringName:
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var cid: StringName = bind_ctx.get("card_instance_id", &"") if not bind_ctx.is_empty() else &""
	if cid == &"":
		cid = payload.get("card_instance_id", &"") if payload != null else &""
	if cid == &"" and effect.source is Dictionary:
		cid = effect.source.get("card_instance_id", &"")
	return cid

## 取当前回合号（scope key）。game_state 未就绪时返回 0（同一回合内多次触发仍受限）
func _current_turn_number() -> int:
	if context == null or context.get("game_state") == null:
		return 0
	return int(context.game_state.turn_number)

## 每回合1次是否已用满
func _is_once_per_turn_used_up(effect: ActionEffect, payload: Dictionary) -> bool:
	var cid: StringName = _once_per_turn_card_instance_id(effect, payload)
	if cid == &"":
		return false  # 无来源牌实例，不限制（退路）
	var key: String = "%s:%s" % [String(cid), String(effect.once_per_turn_key)]
	var turn_id: int = _current_turn_number()
	var turn_map: Dictionary = _once_per_turn_used.get(key, {})
	var used: int = int(turn_map.get(turn_id, 0))
	return used >= effect.once_per_turn_max

## 标记每回合1次已使用（+1）
func _mark_once_per_turn_used(effect: ActionEffect, payload: Dictionary) -> void:
	if effect.once_per_turn_key == &"":
		return
	var cid: StringName = _once_per_turn_card_instance_id(effect, payload)
	if cid == &"":
		return
	var key: String = "%s:%s" % [String(cid), String(effect.once_per_turn_key)]
	var turn_id: int = _current_turn_number()
	if not _once_per_turn_used.has(key):
		_once_per_turn_used[key] = {}
	var turn_map: Dictionary = _once_per_turn_used[key]
	turn_map[turn_id] = int(turn_map.get(turn_id, 0)) + 1
	_once_per_turn_used[key] = turn_map


## DIRECT 主动效果「触发」按钮是否可点：复用 _execute_effect 的条件 + 每回合1次检查。
## bind_ctx 即装备 listener 的 binding_context（含 card_instance_id/mech_id/player_id/slot_id）。
## 供 equipment_panel 据此把按钮置灰（不满足条件/已用满时 disabled），
## 避免玩家点了才被 effect_fire 静默跳过（如帝国腿未移动8格点触发无反应）。
func can_trigger_active_effect(effect: ActionEffect, bind_ctx: Dictionary) -> bool:
	if effect == null:
		return false
	var payload: Dictionary = {"binding_context": bind_ctx}
	# 条件检查（action=null：走 binding_context 取来源，不依赖某个具体动作）
	if not _check_conditions(effect, payload, null):
		return false
	# 每回合1次检查
	if effect.once_per_turn_key != &"" and _is_once_per_turn_used_up(effect, payload):
		return false
	return true


## 判断装备牌来源玩家是否为 AI（非人类）
func _is_ai_owner(player_id: StringName, mech_id: StringName) -> bool:
	if context == null or context.get("game_state") == null:
		return false
	var pid: StringName = player_id
	if pid == &"" and mech_id != &"":
		var mech = context.game_state.mechs.get(mech_id)
		if mech != null:
			pid = mech.owner_player_id
	if pid == &"":
		return false
	var player = context.game_state.players.get(pid)
	if player == null:
		return false
	return not player.is_human


## AI 损伤转移决策：尽量把点数转移到本牌区域（保护即将损坏的装备）
## 返回 redirect_plan = [{to_mech_id, to_slot_id, count}]
func _ai_decide_redirect(payload: Dictionary, max_points: int, redirect_mech_id: StringName) -> Array:
	if context == null or context.get("game_state") == null or redirect_mech_id == &"":
		return []
	var total: int = int(payload.get("total_points", payload.get("value", 0)))
	if total <= 0:
		return []
	var transfer: int = total
	if max_points > 0:
		transfer = mini(transfer, max_points)
	# 本牌所在 slot
	var to_slot: StringName = &""
	var mech = context.game_state.mechs.get(redirect_mech_id)
	if mech != null:
		for sid in mech.slots:
			var slot = mech.slots[sid]
			if slot == null or slot.equipped_card == null:
				continue
			# binding_context.card_instance_id 标识本牌
			var bind_ctx: Dictionary = payload.get("binding_context", {})
			if String(slot.equipped_card.instance_id) == String(bind_ctx.get("card_instance_id", &"")):
				to_slot = StringName(String(sid))
				break
	if to_slot == &"":
		return []
	return [{"to_mech_id": redirect_mech_id, "to_slot_id": to_slot, "count": transfer}]


## 把 redirect_plan 写回 action.record（供 _step_set_damage 读取）
func _write_redirect_plan(action, plan: Array) -> void:
	if action == null:
		return
	action.record["redirect_plan"] = plan


func _mark_effect_executed(effect_id: StringName, action_id: StringName) -> void:
	if not _executed_effects.has(action_id):
		_executed_effects[action_id] = {}
	_executed_effects[action_id][effect_id] = true


## 取效果来源牌实例ID（binding_context -> payload.card_instance_id -> payload.source -> effect.source）
func _effect_card_instance_id(effect: ActionEffect, payload: Dictionary) -> StringName:
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var cid: StringName = bind_ctx.get("card_instance_id", &"") if not bind_ctx.is_empty() else &""
	if cid == &"" and payload != null:
		cid = payload.get("card_instance_id", &"")
	if cid == &"" and payload != null and payload.has("source") and payload["source"] is Dictionary:
		cid = payload["source"].get("card_instance_id", &"")
	if cid == &"" and effect.source is Dictionary:
		cid = effect.source.get("card_instance_id", &"")
	return cid


## 装备牌效果发动时向消息框推送一条可读消息（供玩家核查每件装备执行情况）。
## 仅对来源为装备牌（card_kind=="equipment"）的效果触发。同一动作内同一效果只播报一次
## （CHOOSE_ONE/目标选择 等挂起后 resume 会重跑 _execute_effect，需去重）。
func _announce_equipment_effect(effect: ActionEffect, payload: Dictionary, action) -> void:
	if context == null or context.get("game_state") == null:
		return
	var cid: StringName = _effect_card_instance_id(effect, payload)
	if cid == &"":
		return
	var card = context.game_state.get_card(cid)
	if card == null or card.def == null:
		return
	if card.def.card_kind != &"equipment":
		return  # 行动牌/机师牌效果走各自消息通道，不在此播报
	var aid: StringName = action.action_id if action != null else &""
	if aid == &"":
		return
	if not _announced_equipment_effects.has(aid):
		_announced_equipment_effects[aid] = {}
	var done_map: Dictionary = _announced_equipment_effects[aid]
	if done_map.has(effect.effect_id):
		return
	done_map[effect.effect_id] = true
	_announced_equipment_effects[aid] = done_map
	# 描述文本：优先 effect.description，退回 display_name，再退回 effect_id
	var desc: String = effect.description
	if desc.strip_edges() == "":
		desc = effect.display_name
	if desc.strip_edges() == "":
		desc = String(effect.effect_id)
	# 来源机甲：binding_context -> payload.source -> effect.source -> card.mech_id
	var src_mech: StringName = &""
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	if not bind_ctx.is_empty():
		src_mech = bind_ctx.get("mech_id", &"")
	if src_mech == &"" and payload != null and payload.has("source") and payload["source"] is Dictionary:
		src_mech = payload["source"].get("mech_id", &"")
	if src_mech == &"" and effect.source is Dictionary:
		src_mech = effect.source.get("mech_id", &"")
	if src_mech == &"":
		src_mech = card.mech_id
	equipment_effect_fired.emit(card.def.display_name, effect.effect_id, desc, src_mech)


func _is_required_effect_executed(required_effect_id: StringName, action_id: StringName) -> bool:
	if not _executed_effects.has(action_id):
		return false
	return _executed_effects[action_id].get(required_effect_id, false)


## 取效果来源标签（"牌名：效果描述"），供 UI 弹框顶部显示来源。
## 优先 binding_context.card_instance_id -> 牌名；描述取 effect.description -> display_name -> effect_id。
func _effect_source_label(effect, payload) -> String:
	if effect == null:
		return ""
	var desc: String = effect.description
	if desc.strip_edges() == "":
		desc = effect.display_name
	if desc.strip_edges() == "":
		desc = String(effect.effect_id)
	var cid: StringName = _effect_card_instance_id(effect, payload)
	if cid != &"" and context != null and context.get("game_state") != null:
		var card = context.game_state.get_card(cid)
		if card != null and card.def != null:
			return "%s：%s" % [String(card.def.display_name), desc]
	return desc


## 供 ActionUIBridge 注入弹框来源标签：从挂起效果取"牌名：效果描述"。
func get_pending_source_label(action_id: StringName) -> String:
	if not _pending_effect.has(action_id):
		return ""
	var pending: Dictionary = _pending_effect[action_id]
	var effect = pending.get("effect")
	var payload: Dictionary = pending.get("payload", {})
	return _effect_source_label(effect, payload)


## 供损伤移除弹框取来源：沿父链找 discard_card 动作，取被弃装备牌名。
## effect_031/079 离场移除损伤的 damage_change 子动作父链指向 discard_card 动作。
func get_removal_source_label(action_id: StringName) -> String:
	if context == null or context.action_registry == null or context.get("game_state") == null:
		return ""
	var cur_id: StringName = action_id
	for _i in 6:
		var cur = context.action_registry.get_action(cur_id)
		if cur == null:
			return ""
		if cur.action_type == &"discard_card":
			var snaps: Array = cur.record.get("discard_snapshots", [])
			if not snaps.is_empty():
				var snap: Dictionary = snaps[0] if snaps[0] is Dictionary else {}
				var card_id: StringName = snap.get("card_id", &"")
				var card = context.game_state.get_card(card_id)
				if card != null and card.def != null:
					return "%s：离场移除其他区域损伤" % String(card.def.display_name)
			return ""
		cur_id = cur.parent_action_id
		if cur_id == &"":
			break
	return ""


## 清除指定动作的已执行效果记录
func clear_executed_effects_for_action(action_id: StringName) -> void:
	_executed_effects.erase(action_id)
	# 装备效果播报去重集合随动作清理一并清除
	_announced_equipment_effects.erase(action_id)
	# 同步清除"已处理响应"标记，使同一 action_id 在新一次攻击（复用id的极端情况）下可再次响应
	_handled_response_actions.erase(action_id)
	# 同步清除挂起的 optional 弃牌效果（动作被取消/清理时，弹窗不应再续跑）
	_pending_effect.erase(action_id)
	# 同步清除待补跑的 regular listeners（响应窗口关闭前暂存，动作取消/清理时不应再补跑）
	var cl_action = context.action_registry.get_action(action_id) if context != null and context.action_registry != null else null
	if cl_action != null:
		cl_action._pending_regular_listeners = []
		cl_action._pending_timing = &""
		cl_action._pending_timing_payload = {}
		cl_action._pending_sorted = false


## 检查可用条件
## card_instance_id 由调用方从监听器 entry 传入（注册时存入）；
## AVAILABILITY 效果是共享 Resource，其 source 不携带具体牌实例，故不能依赖 effect.source。
func _check_availability(effect: ActionEffect, action, card_instance_id: StringName = &"", bind_ctx: Dictionary = {}) -> bool:
	var condition: StringName = effect.availability_condition
	# availability_condition 为空时跳过专用可用性检查，回退到通用 set_conditions 检查（见函数末尾）。
	# 装备 AVAILABILITY 效果（094/096 光束/热能响应）用 set_conditions 表达
	# "持有者被攻击 + 攻击武器名匹配 + 手牌有行动牌"，须在可用性阶段过滤，
	# 否则所有玩家的同名武器牌都会进入响应窗口（只有持有者才能用）。
	if condition != &"" and (context == null or context.get("game_state") == null):
		return false

	if condition == _TimingConst.AVAIL_RESPOND_ATTACK:
		# 响应攻击：检查此牌持有者是否是被攻击目标
		if action.action_type != &"attack":
			return false
		# 优先用调用方传入的 card_instance_id；退路兼容 effect.source
		if card_instance_id == &"" and effect.source != null:
			card_instance_id = effect.source.get("card_instance_id", &"")
		if card_instance_id == &"":
			return false
		var card = context.game_state.get_card(card_instance_id)
		if card == null:
			return false
		var card_mech_id: StringName = card.mech_id
		# 收集本次攻击的全部目标（单目标 target_id + 双连等多目标 target_ids）。
		# 牌持有者机甲必须是攻击目标之一，其迎击牌才会进入响应窗口。
		var attack_targets: Array = []
		var _tid: StringName = action.record.get("target_id", &"")
		if _tid != &"":
			attack_targets.append(_tid)
		for _etid in action.record.get("target_ids", []):
			var _etid_sn: StringName = StringName(_etid)
			if _etid_sn != &"":
				attack_targets.append(_etid_sn)
		var holder_is_target := false
		for _atid in attack_targets:
			if _atid == card_mech_id:
				holder_is_target = true
				break
		if not holder_is_target:
			return false
		# 锁定状态封锁响应：locker(攻击者玩家)对"被锁定目标"发动的攻击，
		# 被锁目标及其相邻机甲（六边形相邻）的迎击牌不可用（availability_priority < 20）。
		# 识破（availability_priority=30）不受影响，仍可响应。
		# 多目标攻击(双连)中，只要有一个目标是 locker 锁定的机甲，则该被锁目标及其相邻机甲
		# （即使它们是 A 的其它共目标）的迎击牌都被封锁。
		if int(effect.availability_priority) < _LOCK_SUPPRESS_PRIORITY:
			var attacker_id_l: StringName = action.record.get("attacker_id", &"")
			if attacker_id_l != &"":
				var attacker_player = context.game_state.get_player_for_mech(attacker_id_l)
				if attacker_player != null:
					var holder_mech_l = context.game_state.mechs.get(card_mech_id)
					for _atid2 in attack_targets:
						var locked_mech = context.game_state.mechs.get(_atid2)
						if locked_mech != null and locked_mech.is_locked_by(attacker_player.player_id):
							# holder 是被锁目标本身 或 与被锁目标相邻 -> 封锁
							if card_mech_id == _atid2:
								return false
							if holder_mech_l != null and _HexGrid.distance(holder_mech_l.position, locked_mech.position) == 1:
								return false
		return true

	if condition == _TimingConst.AVAIL_ALLY_IN_RANGE_TARGETED:
		# 掩护：攻击目标为持有者最大攻击范围内的友方机甲（非自身被攻击）
		if action.action_type != &"attack":
			return false
		var target_id: StringName = action.record.get("target_id", &"")
		var attacker_id: StringName = action.record.get("attacker_id", &"")
		if target_id == &"" or attacker_id == &"":
			return false
		# 优先用调用方传入的 card_instance_id；退路兼容 effect.source
		if card_instance_id == &"" and effect.source != null:
			card_instance_id = effect.source.get("card_instance_id", &"")
		if card_instance_id == &"":
			return false
		var card = context.game_state.get_card(card_instance_id)
		if card == null:
			return false
		var holder_mech_id: StringName = card.mech_id
		# 持有者自身被攻击时不触发掩护（那是响应牌场景）
		if target_id == holder_mech_id:
			return false
		var holder_mech = context.game_state.mechs.get(holder_mech_id)
		var attacker_mech = context.game_state.mechs.get(attacker_id)
		if holder_mech == null or attacker_mech == null:
			return false
		# 持有者最大武器范围
		var max_range: int = 1
		for wid in holder_mech.get_weapon_ids():
			var wcard = context.game_state.get_card(wid)
			if wcard and wcard.def and "range_value" in wcard.def:
				max_range = max(max_range, int(wcard.def.range_value))
		# 攻击目标须在持有者最大武器范围内
		var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
		return _RangeCalculator.is_in_weapon_range(holder_mech.position, attacker_mech.position, max_range, map_cells)

	# 通用 set_conditions 检查：availability_condition 为空（或已通过专用检查）时，
	# 进一步用效果的 set_conditions 过滤（094/096 等）。payload 取攻击动作 record + binding_context。
	if effect.conditions.size() > 0:
		if context == null or context.get("game_state") == null:
			return false
		var avail_payload: Dictionary = action.record.duplicate()
		avail_payload["action_id"] = action.action_id
		avail_payload["action_type"] = action.action_type
		if not bind_ctx.is_empty():
			avail_payload["binding_context"] = bind_ctx
		elif card_instance_id != &"":
			var av_card = context.game_state.get_card(card_instance_id)
			if av_card != null:
				avail_payload["binding_context"] = {
					"card_instance_id": card_instance_id,
					"mech_id": av_card.mech_id,
					"player_id": av_card.owner_player_id,
				}
		if not _check_conditions(effect, avail_payload, action):
			return false
	return true

## 检查是否被抑制
func _is_effect_suppressed(timing: StringName, effect: ActionEffect) -> bool:
	# 只有 AVAILABILITY 模式（响应窗口可选牌）才受抑制；LISTEN/DIRECT 永不抑制。
	if effect.mode != _TimingConst.MODE_AVAILABILITY:
		return false
	var suppressions: Array = suppressed_effects.get(timing, [])
	if suppressions.is_empty():
		return false
	# AVAILABILITY 用 availability_priority 比较（迎击牌排序字段）。
	# 锁定封锁阈值=20：识破(30)不受影响，普通迎击(5)被封锁。
	var eff_pri: int = effect.availability_priority
	for suppression: Dictionary in suppressions:
		var min_priority: int = suppression.get("suppress_below_priority", 0)
		if eff_pri < min_priority:
			return true
	return false


## 检查条件
func _check_conditions(effect: ActionEffect, payload: Dictionary, action) -> bool:
	if effect.conditions.is_empty():
		return true
	# 创建临时 EffectBinding 用于 ConditionChecker
	var binding = _make_binding_from_effect(effect, action, payload)
	var ok: bool = _ConditionChecker.check_all(binding, payload, effect.conditions)
	if not ok:
		# 诊断：逐条件打印结果，定位 effect2 被跳过的根因（闪击不弹窗 bug）
		if _DIAG_TIMING:
			var parts: Array = []
			for condition in effect.conditions:
				var cop: String = String(condition.get("op", &"ALWAYS"))
				var cresult: bool = _ConditionChecker.check_single(binding, payload, condition)
				parts.append("%s=%s" % [cop, str(cresult)])
			var aid: String = String(action.action_id) if action != null else "?"
			var pid: StringName = binding.override_owner_player_id if binding != null else &""
			SLog.log_raw("[DIAG conditions_failed] effect=%s action=%s owner_player=%s conditions=[%s] payload_target=%s payload_weapon=%s payload_attacker=%s payload_weapon_range=%s" % [
				String(effect.effect_id), aid, String(pid), ", ".join(parts),
				String(payload.get("target_id", &"")), String(payload.get("weapon_id", &"")),
				String(payload.get("attacker_id", &"")), str(payload.get("weapon_range", -1)),
			])
	return ok


## 检查目标规则
func _check_targets(effect: ActionEffect, payload: Dictionary, action) -> bool:
	if effect.target_rules.is_empty():
		return true
	var binding = _make_binding_from_effect(effect, action, payload)
	return _TargetChecker.check_all(binding, payload, effect.target_rules)


## 检查费用
func _check_costs(effect: ActionEffect, payload: Dictionary, action) -> bool:
	if effect.costs.is_empty():
		return true
	var binding = _make_binding_from_effect(effect, action, payload)
	return _CostChecker.can_pay_all(binding, payload, effect.costs, context)


## 支付费用
func _pay_costs(effect: ActionEffect, payload: Dictionary, action) -> void:
	if effect.costs.is_empty():
		return
	var binding = _make_binding_from_effect(effect, action, payload)
	_CostChecker.pay_all(binding, payload, effect.costs, context)


## 效果是否含必耗（optional != true）费用。必耗费用不可静默跳过：
## 支付失败时必须取消父动作（如 effect_110 闪回激光剑攻击必耗2动力，动力不足则不能攻击）。
func _effect_has_mandatory_cost(effect: ActionEffect) -> bool:
	if effect == null or effect.costs.is_empty():
		return false
	for cost in effect.costs:
		if cost.get("cost_type", &"") == &"":
			continue
		if not cost.get("optional", false):
			return true
	return false


## 必耗费用不可支付时取消父动作（含反击/闪击复用本武器路径）。
## 沿 parent 链找到触发本效果的祖先动作（通常是 attack）并取消；若无 parent 直接取消本动作。
func _cancel_parent_action_for_mandatory_cost(action, effect: ActionEffect) -> void:
	if context == null or context.action_engine == null:
		return
	# effect 是某 attack 动作 ATTACK_BEFORE 的 permanent listener；action 即该 attack。
	# 直接取消该动作（_run_step_loop 会检测 cancelled 并停止推进后续步骤）。
	if action != null:
		context.action_engine.cancel_action(action.action_id)


## 执行动作列表
## effect_005 立即设置：把抽到的装备设到选定槽（顶层 set_equipment 动作，与原原子路径一致）
## 计算抽到的装备牌可设置的合法槽位（与正常从手牌设置装备 UI _show_set_equipment_panel 一致）：
## PART -> 对应槽位(card.def.slot) + 备用区；WEAPON -> 武器槽 + 备用区；其他 -> 备用区。
## 含已占用槽位（允许替换旧装备，由 set_equipment 动作走标准替换流程）。返回槽位 id 数组。
func _valid_set_slots_for_drawn_card(mech, card) -> Array:
	var result: Array = []
	if mech == null or card == null or card.def == null:
		return result
	# 注意：EquipmentCardDef 是 Object，.get() 只接受 1 参数（无默认值重载），故取后判 null
	var kind_val = card.def.get("equipment_kind")
	var kind: StringName = kind_val if kind_val != null else &"PART"
	if kind == &"WEAPON":
		for ws_id in [&"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2"]:
			if mech.slots.has(ws_id):
				result.append(ws_id)
	else:
		# PART 或其他装备：对应槽位 + 备用区
		var spec_slot_raw = card.def.get("slot")
		var spec_slot: StringName = StringName(spec_slot_raw) if spec_slot_raw != null else &""
		if spec_slot != &"" and mech.slots.has(spec_slot):
			result.append(spec_slot)
		for rs_id in [&"reserve_1", &"reserve_2"]:
			if mech.slots.has(rs_id):
				result.append(rs_id)
	return result


func _do_immediate_set_equipment(mech_id: StringName, player_id: StringName, card_id: StringName, slot_id: StringName) -> void:
	if context == null or context.action_service == null:
		return
	context.action_service.execute(&"set_equipment", {
		"card_id": card_id,
		"mech_id": mech_id,
		"slot_id": slot_id,
		"source": {"player_id": player_id, "mech_id": mech_id, "card_instance_id": card_id},
	})


func _execute_actions(effect: ActionEffect, payload: Dictionary, action) -> void:
	if effect.actions.is_empty():
		return

	var _actions_list: Array = effect.actions
	for _act_idx: int in range(_actions_list.size()):
		var act: Dictionary = _actions_list[_act_idx]
		var act_type: StringName = act.get("type", &"")
		# 跳过注册监听器的动作
		if act_type == &"REGISTER_LISTEN":
			var listen_timing: StringName = act.get("timing", &"")
			var listen_action_id: StringName = act.get("listen_action_id", &"")
			var listen_effect: ActionEffect = act.get("listen_effect")
			if listen_timing != &"" and listen_effect != null:
				register_temporary_listener(listen_timing, listen_action_id, &"", listen_effect)
			continue
		# CHOOSE_ONE：维修等二选一。inline options[] 每项含 {label, actions[]}。
		# 玩家未选时挂起弹窗（choose_one_effect）；选了则执行对应分支 actions[]，
		# 并把目标机甲注入效果动作的 mech_ids（EXECUTE_HP_CHANGE/EXECUTE_DAMAGE_CHANGE 读 mech_ids）。
		if act_type == &"CHOOSE_ONE":
			var chosen_idx: int = int(payload.get("chosen_option_index", -1))
			var params_co: Dictionary = act.get("params", {})
			var options: Array = params_co.get("options", [])
			if chosen_idx < 0 or chosen_idx >= options.size():
				# 按目标状态过滤可用 options（option.condition 评估，如维修：目标满血->只能移除损伤，
				# 目标无损伤->只能回复生命）。无 condition 的 option 总是可用。
				var bind_co = _make_binding_from_effect(effect, action, payload)
				var available_indices: Array[int] = []
				for i in range(options.size()):
					var opt_ci: Dictionary = options[i] if options[i] is Dictionary else {}
					var opt_conds = opt_ci.get("condition", [])
					# condition 可为单个 dict（如 effect_098/135 option condition），包装成 array
					if opt_conds is Dictionary:
						opt_conds = [opt_conds] if not opt_conds.is_empty() else []
					if opt_conds.is_empty() or _ConditionChecker.check_all(bind_co, payload, opt_conds):
						available_indices.append(i)
				# 仅1个可用 -> 自动选（不弹窗）；0个 -> 跳过此 CHOOSE_ONE；多个 -> 挂起弹窗
				# 例外：params.optional=true（如狙击装·躯干 effect_023 "可以弃此牌威力-4"）
				# 即使只有1个可用 option 也弹窗，让玩家可选取消。AI owner 保持自动选（AI 暂不支持 optional 决策）。
				var co_optional: bool = bool(params_co.get("optional", false))
				var co_ai_owner: bool = false
				if co_optional:
					var co_bind_ctx: Dictionary = payload.get("binding_context", {})
					var co_owner_pid: StringName = co_bind_ctx.get("player_id", &"")
					var co_owner_mid: StringName = co_bind_ctx.get("mech_id", &"")
					co_ai_owner = _is_ai_owner(co_owner_pid, co_owner_mid)
				if available_indices.size() == 1 and (not co_optional or co_ai_owner):
					chosen_idx = available_indices[0]
					payload["chosen_option_index"] = chosen_idx
				elif available_indices.is_empty():
					SLog.log_raw("[TIMING] %s CHOOSE_ONE 无可用 option（目标不满足任何条件），跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
					continue
				else:
					# 挂起：存 effect/payload，弹二选一窗（ui_options 只列可用）
					_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": "pre_actions_target"}
					action.record["_waiting_for_choose_one"] = true
					action.record["_choose_one_effect_id"] = effect.effect_id
					var ui_options: Array[Dictionary] = []
					for i in available_indices:
						var opt: Dictionary = options[i] if options[i] is Dictionary else {}
						ui_options.append({
							"label": String(opt.get("label", "选项%d" % (i + 1))),
							"effect_id": StringName("option_%d" % i),
							"option_index": i,
						})
					action.state = &"waiting_timing"
					action_needs_input.emit(action.action_id, &"choose_one_effect", {
						"action_id": action.action_id,
						"effect_id": effect.effect_id,
						"options": ui_options,
						"optional": co_optional,
						"player_id": _effect_popup_owner_pid(effect, payload, action),
					})
					SLog.log_raw("[TIMING] %s 挂起二选一 effect=%s options=%d optional=%s" % [String(action.action_id), String(effect.effect_id), ui_options.size(), str(co_optional)])
					return
			# 已选：执行该分支的 actions[]，注入目标机甲到 mech_ids
			# 清理挂起标志（C2 修复：此前最终记录残留 _waiting_for_choose_one=true）
			action.record.erase("_waiting_for_choose_one")
			action.record.erase("_choose_one_effect_id")
			var chosen_opt: Dictionary = options[chosen_idx] if options[chosen_idx] is Dictionary else {}
			var branch_actions: Array = chosen_opt.get("actions", [])
			var target_id_co: StringName = StringName(payload.get("target_id", payload.get("target_mech_id", &"")))
			if target_id_co == &"":
				# 退回来源机甲（自身）
				var binding_co = _make_binding_from_effect(effect, action, payload)
				target_id_co = binding_co.get_source_mech_id()
			# 串行执行 branch_actions（支持子动作挂起 + 来源装备牌离场检测）。
			# Q3 裁定：effect_035/039 的 EXECUTE_DAMAGE_CHANGE(fixed_slot 置损伤) 致来源牌弃置后，
			# 剩余动作（MODIFY_ATTACK_MIGHT/MARKERS）停止--"想生效，牌必须在机甲框架上而非弃牌堆"。
			var _ba_idx: int = 0
			while _ba_idx < branch_actions.size():
				var sub_act: Dictionary = branch_actions[_ba_idx]
				# 非首个子动作前，Q3 守卫：仅当上一个子动作是 fixed_slot EXECUTE_DAMAGE_CHANGE
				# （置损伤致来源牌弃置）时检测来源牌是否仍在 slot，是则停止剩余。
				# effect_019（主动弃自身换动力+4）等不在此列--弃置是主动成本，后续效果应执行。
				if _ba_idx > 0:
					var _pa: Dictionary = branch_actions[_ba_idx - 1]
					if _pa.get("type", &"") == &"EXECUTE_DAMAGE_CHANGE" and bool(_pa.get("params", {}).get("fixed_slot", false)) and _source_equipment_discarded(payload):
						break
				var sub_act_merged: Dictionary = sub_act.duplicate(true)
				var sub_params: Dictionary = sub_act_merged.get("params", {})
				# 仅对需要目标机甲的动作注入 mech_ids（HP/损伤变动）
				var sub_type: StringName = sub_act_merged.get("type", &"")
				# 抽装备伪动作嵌套在 CHOOSE_ONE 分支内时（effect_065 王牌臂），execute_sub_action 无注册工厂
				# 会静默失败，改走 _handle_draw_equipment_pseudo 内联处理（与顶层 action 同路径）。
				var _ba_deis_ret: StringName = _handle_draw_equipment_pseudo(sub_type, sub_params, effect, payload, action)
				if _ba_deis_ret == &"suspend":
					# 挂起弹窗：剩余 branch_actions 存 _seq，待 resume 后续跑（无剩余则不存，与顶层一致）
					var _ba_remaining: Array = branch_actions.slice(_ba_idx + 1)
					if not _ba_remaining.is_empty():
						action.record["_seq_effect_actions"] = {
							"payload": payload,
							"remaining": _ba_remaining,
							"source_check": false,
						}
					return
				if _ba_deis_ret == &"skip":
					_ba_idx += 1
					continue
				if sub_type in [&"EXECUTE_HP_CHANGE", &"EXECUTE_DAMAGE_CHANGE", &"HEAL_HP", &"REMOVE_DAMAGE_TOKENS", &"DEAL_DAMAGE", &"PLACE_DAMAGE_TOKENS", &"MODIFY_DAMAGE_TOKENS"]:
					if not sub_params.has("mech_ids"):
						sub_params["mech_ids"] = [target_id_co]
					if not sub_params.has("mech_id") and sub_type in [&"HEAL_HP", &"REMOVE_DAMAGE_TOKENS", &"DEAL_DAMAGE", &"PLACE_DAMAGE_TOKENS", &"MODIFY_DAMAGE_TOKENS"]:
						sub_params["mech_id"] = target_id_co
					sub_act_merged["params"] = sub_params
				if context != null and context.action_service != null:
					context.action_service.execute_sub_action(sub_act_merged, payload, action)
				# 子动作挂起（需输入/等更小子动作）：存剩余 branch_actions 到 _seq，待子动作完成后
				# 由 _continue_seq_effect_actions 续跑（仿 _execute_actions 顶层串行机制）。
				if _last_created_sub_action_paused(action):
					var _cur_dmg: bool = sub_act.get("type", &"") == &"EXECUTE_DAMAGE_CHANGE" and bool(sub_act.get("params", {}).get("fixed_slot", false))
					action.record["_seq_effect_actions"] = {
						"payload": payload,
						"remaining": branch_actions.slice(_ba_idx + 1),
						"source_check": _cur_dmg,
					}
					return
				_ba_idx += 1
			continue
		# CHOOSE_INTEGER：整数选择窗（effect_040/041 金币换动力）。选定后展开嵌套 actions 的
		# *_expr（$choice.n + $binding_context + 算术），执行。
		if act_type == &"CHOOSE_INTEGER":
			var ci_params: Dictionary = act.get("params", {})
			var ci_optional: bool = bool(ci_params.get("optional", false))
			var ci_bind_as: String = String(ci_params.get("bind_as", "n"))
			var ci_min: int = int(ci_params.get("min_value", 1))
			var ci_label: String = String(ci_params.get("label", ""))
			var ci_max_expr: String = String(ci_params.get("max_value_expr", ""))
			var ci_max: int = ci_min
			if ci_max_expr != "":
				ci_max = int(_eval_expr(ci_max_expr, payload, {}))
			else:
				ci_max = int(ci_params.get("max_value", ci_min))
			var ci_choice: Dictionary = payload.get("choice", {})
			if not ci_choice.has(ci_bind_as):
				if ci_max < ci_min:
					continue  # 金币不足等：不弹窗
				var ci_bind_ctx: Dictionary = payload.get("binding_context", {})
				var ci_owner_pid: StringName = ci_bind_ctx.get("player_id", &"")
				var ci_owner_mid: StringName = ci_bind_ctx.get("mech_id", &"")
				if _is_ai_owner(ci_owner_pid, ci_owner_mid):
					ci_choice[ci_bind_as] = ci_min
					payload["choice"] = ci_choice
				else:
					_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": &"choose_integer", "bind_as": ci_bind_as}
					action.record["_waiting_for_choose_integer"] = true
					action.state = &"waiting_timing"
					action_needs_input.emit(action.action_id, &"choose_integer", {
						"action_id": action.action_id,
						"effect_id": effect.effect_id,
						"label": ci_label,
						"min_value": ci_min,
						"max_value": ci_max,
						"bind_as": ci_bind_as,
						"optional": ci_optional,
						"player_id": _effect_popup_owner_pid(effect, payload, action),
					})
					return
			# 已选：展开嵌套 actions 的 *_expr（$choice.n + $binding_context + 算术），串行执行。
			# 串行：内嵌动作创建挂起子动作（如 EXECUTE_DISCARD 选牌 / EXECUTE_SINGLE_MOVE 选目标）时，
			# 暂停本循环，剩余内嵌动作存入 _seq_effect_actions，待子动作完成后由
			# _continue_seq_effect_actions 续跑（仿 _execute_actions 顶层串行机制）。
			# 避免多个需输入子动作同时 waiting_input 导致 UI 输入冲突（赤枭弃牌+动力 / 雄鹰弃牌+移动）。
			var ci_actions: Array = ci_params.get("actions", [])
			var ci_choice_full: Dictionary = payload.get("choice", {})
			# 预解析所有内嵌动作的 *_expr 与 $binding_context（choice 已知）-> 具体动作列表
			var ci_resolved: Array = []
			for ci_sub: Dictionary in ci_actions:
				var ci_merged: Dictionary = ci_sub.duplicate(true)
				var ci_sp: Dictionary = ci_merged.get("params", {})
				var ci_erase: Array = []
				for ci_k in ci_sp:
					if String(ci_k).ends_with("_expr"):
						var ci_base: String = String(ci_k).trim_suffix("_expr")
						ci_sp[ci_base] = _eval_expr(String(ci_sp[ci_k]), payload, ci_choice_full)
						ci_erase.append(ci_k)
					elif context != null and context.action_service != null:
						# 非 _expr 字段解析 $binding_context/$payload/$source（如 player_id/target_id）
						ci_sp[ci_k] = context.action_service._resolve_atomic_value(ci_sp[ci_k], payload, action)
				for ci_k in ci_erase:
					ci_sp.erase(ci_k)
				ci_merged["params"] = ci_sp
				ci_resolved.append(ci_merged)
			# 串行执行预解析后的动作：首个创建挂起子动作则存剩余到 _seq 并返回
			for ci_i: int in range(ci_resolved.size()):
				var ci_act: Dictionary = ci_resolved[ci_i]
				if context != null and context.action_service != null:
					context.action_service.execute_sub_action(ci_act, payload, action)
				if _last_created_sub_action_paused(action):
					var ci_remaining: Array = ci_resolved.slice(ci_i + 1)
					if not ci_remaining.is_empty():
						action.record["_seq_effect_actions"] = {
							"payload": payload,
							"remaining": ci_remaining,
						}
					return
			continue
		# OFFER_DAMAGE_REDIRECT：损伤转移汇总弹窗（A6）。玩家未选转移点数时挂起；
		# 选了则把 redirect_plan 写回 parent_action（damage_change）record，供 _step_set_damage 读取。
		# AI 自动决策（尽量转移保护装备）。
		if act_type == &"OFFER_DAMAGE_REDIRECT":
			var odr_params: Dictionary = act.get("params", {})
			var odr_max: int = int(odr_params.get("max_points", -1))
			var odr_mode: StringName = odr_params.get("mode", &"")
			var odr_reduction: int = int(odr_params.get("reduction", 0))
			var odr_plan: Array = payload.get("redirect_plan", []) if payload.has("redirect_plan") else []
			# 盾牌 all_or_nothing（effect_127/133/136）：把全部损伤(减 reduction 后)改向本牌槽，
			# 减伤部分(reduction)被盾牌吸收直接消失，不回原目标。人类弹可选确认窗(转移/不转移)，AI 自动转移。
			if odr_mode == &"all_or_nothing":
				# 多盾牌守卫：前序转移效果已处理全部损伤(redirect_plan 非空或已吸收)时，本盾牌不再弹窗。
				if not action.record.get("redirect_plan", []).is_empty() or int(action.record.get("redirect_absorbed", 0)) > 0:
					continue
				var bind_ctx_ao: Dictionary = payload.get("binding_context", {})
				var ao_mech: StringName = bind_ctx_ao.get("mech_id", &"")
				var ao_slot: StringName = bind_ctx_ao.get("slot_id", &"")
				var ao_total: int = int(payload.get("total_points", payload.get("value", 0)))
				var ao_transfer: int = maxi(0, ao_total - odr_reduction)
				var ao_absorb: int = ao_total - ao_transfer  # 确认转移时被盾牌减伤吸收(消失)的点数
				var ao_owner_player: StringName = bind_ctx_ao.get("player_id", &"")
				if _is_ai_owner(ao_owner_player, ao_mech):
					# AI 自动转移：transfer 点到盾牌槽，absorb 点消失
					if ao_mech != &"" and ao_slot != &"" and ao_transfer > 0:
						_write_redirect_plan(action, [{"to_mech_id": ao_mech, "to_slot_id": ao_slot, "count": ao_transfer}])
					else:
						_write_redirect_plan(action, [])
					action.record["redirect_absorbed"] = ao_absorb
					continue
				# 人类玩家：弹可选确认窗（转移全部 / 不转移）
				action.record["_ao_absorb"] = ao_absorb
				_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": "redirect_select"}
				action.record["_waiting_for_redirect"] = true
				action.state = &"waiting_timing"
				var ao_card_name: String = ""
				var ao_cid: StringName = bind_ctx_ao.get("card_instance_id", &"")
				if ao_cid != &"" and context != null and context.game_state != null:
					var ao_card = context.game_state.get_card(ao_cid)
					if ao_card != null and ao_card.def != null:
						ao_card_name = ao_card.def.display_name
				var ao_label: String = ("将本次全部 %d 损伤设置到%s" % [ao_total, ao_card_name]) if ao_card_name != "" else ("将本次全部 %d 损伤转移到此牌" % ao_total)
				if odr_reduction > 0:
					ao_label += "（减%d后放置%d点）" % [odr_reduction, ao_transfer]
				action_needs_input.emit(action.action_id, &"redirect_select", {
					"action_id": action.action_id,
					"effect_id": effect.effect_id,
					"mech_ids": payload.get("mech_ids", []),
					"total_points": ao_total,
					"max_points": ao_transfer,
					"redirect_mech_id": ao_mech,
					"redirect_slot_id": ao_slot,
					"all_or_nothing": true,
					"transfer": ao_transfer,
					"absorb": ao_absorb,
					"source_label": ao_label,
					"player_id": _effect_popup_owner_pid(effect, payload, action),
				})
				SLog.log_raw("[TIMING] %s 挂起盾牌转移确认 effect=%s total=%d transfer=%d absorb=%d" % [String(action.action_id), String(effect.effect_id), ao_total, ao_transfer, ao_absorb])
				return
			if odr_plan.is_empty():
				var bind_ctx_odr: Dictionary = payload.get("binding_context", {})
				var odr_owner_player: StringName = bind_ctx_odr.get("player_id", &"")
				var odr_mech_id: StringName = bind_ctx_odr.get("mech_id", &"")
				var odr_slot_id: StringName = bind_ctx_odr.get("slot_id", &"")
				if _is_ai_owner(odr_owner_player, odr_mech_id):
					var ai_plan: Array = _ai_decide_redirect(payload, odr_max, odr_mech_id)
					_write_redirect_plan(action, ai_plan)
					continue
				# 玩家：挂起弹 redirect_select 窗
				_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": "redirect_select"}
				action.record["_waiting_for_redirect"] = true
				action.state = &"waiting_timing"
				var odr_total: int = int(payload.get("total_points", payload.get("value", 0)))
				action_needs_input.emit(action.action_id, &"redirect_select", {
					"action_id": action.action_id,
					"effect_id": effect.effect_id,
					"mech_ids": payload.get("mech_ids", []),
					"total_points": odr_total,
					"max_points": odr_max,
					"redirect_mech_id": odr_mech_id,
					# 本牌所在槽位（effect_004 联邦右臂=右臂）：转移目标应为此牌区域，
					# 而非遍历机甲第一个有装备的槽位（曾误转至头部）。
					"redirect_slot_id": odr_slot_id,
					"player_id": _effect_popup_owner_pid(effect, payload, action),
				})
				SLog.log_raw("[TIMING] %s 挂起损伤转移选择 effect=%s max=%d" % [String(action.action_id), String(effect.effect_id), odr_max])
				return
			else:
				_write_redirect_plan(action, odr_plan)
				continue
		# CHOOSE_MANY_CARDS：推进 effect2 多选弹窗。持有者使用迎击牌时，列出手牌所有推进供多选，
		# 确认后逐张执行 per_card_actions 并弃置，再继续迎击牌。AI 由 ActionUIBridge 自动全选。
		if act_type == &"CHOOSE_MANY_CARDS":
			var cm_params: Dictionary = act.get("params", {})
			var cm_source: StringName = cm_params.get("source", &"HAND_CARDS")
			var cm_bind_ctx: Dictionary = payload.get("binding_context", {})
			var cm_player_id: StringName = payload.get("player_id", cm_bind_ctx.get("player_id", &""))
			var cm_card_ids: Array = []
			if cm_source == &"ATTACK_TARGET_EQUIPMENT":
				# 收集攻击目标机甲正面设置、未压制的装备牌（供 effect_063/078 选目标装备无效）
				var tgt_mech_id: StringName = payload.get("target_id", cm_bind_ctx.get("target_id", &""))
				cm_player_id = cm_bind_ctx.get("player_id", cm_player_id)  # 弹窗给攻击方（效果持有者）
				if tgt_mech_id != &"" and context != null and context.game_state != null:
					var tgt_mech = context.game_state.mechs.get(tgt_mech_id)
					if tgt_mech != null:
						for sid in tgt_mech.slots:
							var tslot = tgt_mech.slots[sid]
							if tslot == null:
								continue
							var ec = tslot.get("equipped_card")
							if ec == null or ec.def == null:
								continue
							if ec.get("face_down") == true or ec.get("disabled") == true or ec.get("effect_negated") == true:
								continue
							cm_card_ids.append(ec.instance_id)
			else:
				# 默认：收集手牌中所有该 card_def_id 的牌（推进/掩护）
				var cm_card_def_id: StringName = cm_params.get("card_def_id", &"")
				if cm_player_id != &"" and context != null and context.game_state != null:
					var cm_player = context.game_state.players.get(cm_player_id)
					if cm_player != null:
						for hand_cid: StringName in cm_player.action_hand:
							var hand_card = context.game_state.get_card(hand_cid)
							if hand_card != null and hand_card.def != null and String(hand_card.def.card_id) == String(cm_card_def_id):
								cm_card_ids.append(hand_cid)
			# OWNER_ACTION_HAND：列出持有者所有行动牌（赤枭躯干 effect_040/041 弃牌换动力）
			# 不按 card_def_id 过滤，整手行动牌供多选弃置。
			if cm_source == &"OWNER_ACTION_HAND":
				cm_card_ids.clear()
				if cm_player_id != &"" and context != null and context.game_state != null:
					var cm_player = context.game_state.players.get(cm_player_id)
					if cm_player != null:
						for hand_cid: StringName in cm_player.action_hand:
							cm_card_ids.append(hand_cid)
			if cm_card_ids.is_empty():
				continue  # 无牌可选，跳过
			# 仅人类玩家弹多选窗；AI 暂不支持（跳过=选0，避免挂死）
			var cm_mech_id: StringName = payload.get("source_mech_id", cm_bind_ctx.get("mech_id", &""))
			if _is_ai_owner(cm_player_id, cm_mech_id):
				continue
			# 去重守卫：同一动作只弹一次（多张共享一个监听，首个挂起后循环已中断）
			if action.record.get("_choose_many_shown", false):
				continue
			action.record["_choose_many_shown"] = true
			_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": "choose_many_cards", "choose_many_action": act}
			action.state = &"waiting_timing"
			action_needs_input.emit(action.action_id, &"select_thrust_cards", {
				"action_id": action.action_id,
				"effect_id": effect.effect_id,
				"card_ids": cm_card_ids,
				"player_id": cm_player_id,
				"label": String(cm_params.get("label", "选择要打出的牌")),
				"per_card_suffix": String(cm_params.get("per_card_suffix", "")),
				"confirm_verb": String(cm_params.get("confirm_verb", "打出")),
				"cancel_label": String(cm_params.get("cancel_label", "不打出")),
				"max_count": int(cm_params.get("max_count", 0)),
			})
			SLog.log_raw("[TIMING] %s 挂起多选 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), cm_card_ids.size()])
			return
		# UNITE_ATTACK_OFFER：联合状态效果1。unite机甲攻击结算时弹窗让 Target 选1张攻击牌联合攻击。
		# 无攻击牌不弹窗（无事发生）；AI Target 跳过（暂不处理 AI 联合攻击）；人类弹单选窗。
		# 确认后由 resume_pending_effect(phase=unite_attack_offer) 创建 use_action_card 子动作打出
		# （不消耗攻击次数，因 source_action_id=父attack 非空）+ REMOVE_STATUS 去除此联合状态；取消则无事发生。
		# 监听器在 _execute_effect 末尾按 status_id 注销（每状态只触发1次）。
		if act_type == &"UNITE_ATTACK_OFFER":
			var uao_params: Dictionary = act.get("params", {})
			var uao_card_type: String = String(uao_params.get("card_action_type", "攻击"))
			var uao_bind: Dictionary = payload.get("binding_context", {})
			var uao_target_mech: StringName = uao_bind.get("target_id", &"")
			var uao_status_id: StringName = uao_bind.get("status_id", &"")
			var uao_player_id: StringName = &""
			var uao_card_ids: Array = []
			if uao_target_mech != &"" and context != null and context.game_state != null:
				var uao_player = context.game_state.get_player_for_mech(uao_target_mech)
				if uao_player != null:
					uao_player_id = uao_player.player_id
					for hand_cid: StringName in uao_player.action_hand:
						var hand_card = context.game_state.get_card(hand_cid)
						if hand_card != null and hand_card.def != null and String(hand_card.def.action_type) == uao_card_type:
							uao_card_ids.append(hand_cid)
			# 无攻击牌：不弹窗，无事发生（效果结束，监听器照常注销）
			if uao_card_ids.is_empty():
				SLog.log_raw("[TIMING] %s 联合攻击：Target 无攻击牌，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
				continue
			# AI Target：暂不处理 AI 联合攻击，跳过
			if _is_ai_owner(uao_player_id, uao_target_mech):
				SLog.log_raw("[TIMING] %s 联合攻击：Target 为 AI，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
				continue
			# 去重守卫：同一动作只弹一次
			if action.record.get("_unite_attack_shown", false):
				continue
			action.record["_unite_attack_shown"] = true
			_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": &"unite_attack_offer", "unite_attack_action": act}
			action.state = &"waiting_timing"
			action_needs_input.emit(action.action_id, &"select_unite_attack_card", {
				"action_id": action.action_id,
				"effect_id": effect.effect_id,
				"card_ids": uao_card_ids,
				"target_mech_id": uao_target_mech,
				"status_id": uao_status_id,
				"player_id": uao_player_id,
				"label": String(uao_params.get("label", "联合攻击：选择1张攻击牌使用")),
			})
			SLog.log_raw("[TIMING] %s 挂起联合攻击选牌 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), uao_card_ids.size()])
			return
		# DRAW_EQUIPMENT_AND_IMMEDIATELY_SET / DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL 伪动作：
		# 抽装备立即设置(或卖出)。可作顶层 action（effect_005 联邦左臂/近战左腿离场诱发），也可嵌套在
		# CHOOSE_ONE 分支内（effect_065 王牌臂外层 optional CHOOSE_ONE）。嵌套时走 execute_sub_action
		# 无注册工厂会静默失败（"有选框但不生效"），故抽出 _handle_draw_equipment_pseudo 供此主循环
		# 与 CHOOSE_ONE 分支循环共用。
		var _deis_ret: StringName = _handle_draw_equipment_pseudo(act_type, act.get("params", {}), effect, payload, action)
		if _deis_ret == &"suspend":
			return  # 已挂起弹"立即设置/卖出"面板，结束 _execute_actions（与原内联 return 一致）
		if _deis_ret == &"skip":
			continue  # 牌堆空/无合法槽/AI 已自动处理，跳到下一动作
		# _deis_ret == ¬_handled：非抽装备伪动作，继续后续判定
		# REPEAT_SELF_DAMAGE_AND_FREE_MOVE：effect_084 响应攻击自损+免费移动，可继续发动（循环）。
		# 每轮：fixed_slot 自损 + free_move 移动；轮末 __REPEAT_LOOP_CHECK__ 检查是否继续
		# （来源牌仍在槽 + 此牌损伤<阈值 -> 弹"是否继续发动？"窗；确认则再排一轮，取消/不满足则结束）。
		if act_type == &"REPEAT_SELF_DAMAGE_AND_FREE_MOVE":
			# 解析 $binding_context.xxx 参数（响应路径 payload 无 binding_context，故 fallback 到
			# payload 顶层 card_instance_id/mech_id，slot_id 从来源牌实例查），得到具体 rs_params。
			var rs_params: Dictionary = _resolve_repeat_params(act.get("params", {}), payload, action)
			var rs_allow_continue: bool = bool(rs_params.get("allow_continue", false))
			var rs_iter: Array = _repeat_iteration_actions(rs_params, effect)
			# rs_iter = [self_damage_act, move_act, (loop_check)]
			# 自损（fixed_slot 置损伤）
			if context != null and context.action_service != null:
				context.action_service.execute_sub_action(rs_iter[0], payload, action)
			if _last_created_sub_action_paused(action):
				# 自损挂起（弃置链等）：把 move(+loop_check) 插到剩余动作首项
				var _rs_remaining: Array = rs_iter.slice(1)
				_rs_remaining.append_array(_actions_list.slice(_act_idx + 1))
				action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _rs_remaining}
				return
			# 自损未挂起：执行免费移动
			if context != null and context.action_service != null:
				context.action_service.execute_sub_action(rs_iter[1], payload, action)
			if _last_created_sub_action_paused(action):
				var _rs_remaining2: Array = rs_iter.slice(2)
				_rs_remaining2.append_array(_actions_list.slice(_act_idx + 1))
				action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _rs_remaining2}
				return
			# 移动也未挂起（AI 自动移动）：直接检查循环
			if rs_allow_continue and _handle_repeat_loop(action, effect, payload, rs_params):
				return
			continue
		# 委托给 ActionService 执行效果动作
		if context != null and context.action_service != null:
			context.action_service.execute_sub_action(act, payload, action)
			# 串行：本动作创建了"未立即完成"的子动作（需玩家输入/等更小子动作）时，
			# 暂停本循环，剩余动作存入 record，待子动作完成后再由
			# ActionEngine._after_sub_action_finished -> _continue_seq_effect_actions 续跑。
			# 避免同一效果内多个需输入子动作同时 waiting_input 导致 UI 输入冲突
			# （识破 effect2：偷牌选牌 + 循环移动选格）。
			if _last_created_sub_action_paused(action):
				action.record["_seq_effect_actions"] = {
					"payload": payload,
					"remaining": _actions_list.slice(_act_idx + 1),
				}
				return


## 处理 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET / DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL 伪动作。
## 这两个伪动作需 TimingEngine 上下文（挂起 _pending_effect + emit action_needs_input 弹"立即设置/卖出"
## 面板），既可作顶层 action（effect_005 联邦左臂/近战左腿离场诱发），也可嵌套在 CHOOSE_ONE 分支内
## （effect_065 王牌臂外层 optional CHOOSE_ONE）。嵌套时若走 execute_sub_action 会因无注册工厂而静默
## 失败（"有选框但不生效"），故抽出供 _execute_actions 主循环与 CHOOSE_ONE 分支循环共用。
## 返回: &"not_handled"(非此类动作) / &"skip"(已处理无需挂起:牌堆空/无槽/AI自动) / &"suspend"(已挂起弹窗)
func _handle_draw_equipment_pseudo(act_type: StringName, act_params: Dictionary, effect, payload: Dictionary, action) -> StringName:
	if act_type != &"DRAW_EQUIPMENT_AND_IMMEDIATELY_SET" and act_type != &"DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL":
		return &"not_handled"
	var allow_sell: bool = act_type == &"DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL"
	var deis_bind_ctx: Dictionary = payload.get("binding_context", {})
	var deis_mech_id: StringName = deis_bind_ctx.get("mech_id", payload.get("mech_id", payload.get("source_mech_id", &"")))
	var deis_player_id: StringName = deis_bind_ctx.get("player_id", &"")
	var deis_drawn_id: StringName = &""
	if deis_player_id != &"" and context != null and context.game_actions != null:
		context.game_actions.draw_equipment_cards({"player_id": deis_player_id, "count": 1})
		if context.game_state != null:
			var deis_player = context.game_state.players.get(deis_player_id)
			if deis_player != null and not deis_player.equipment_hand.is_empty():
				deis_drawn_id = deis_player.equipment_hand[-1]
	if deis_drawn_id == &"":
		SLog.log_raw("[TIMING] %s %s 牌堆为空，无牌可抽" % [String(action.action_id), String(act_type)])
		return &"skip"
	# 算合法设置槽位（PART->对应槽位+备用区，WEAPON->武器槽+备用区；含已占用槽允许替换）
	var deis_valid_slots: Array = []
	if context != null and context.game_state != null and deis_mech_id != &"":
		var deis_mech = context.game_state.mechs.get(deis_mech_id)
		var deis_card = context.game_state.get_card(deis_drawn_id)
		if deis_mech != null and deis_card != null:
			deis_valid_slots = _valid_set_slots_for_drawn_card(deis_mech, deis_card)
	# 卖出分支（仅 CHOOSE_SET_OR_SELL）：sell_equipment 走标准卖出（按稀有度金币+2/turn计数）
	var deis_can_sell: bool = false
	var deis_sell_price: int = 1
	if allow_sell and context != null and context.game_state != null:
		var deis_player = context.game_state.players.get(deis_player_id)
		if deis_player != null:
			deis_can_sell = deis_player.sell_equipment_count_this_turn < _GameConfig.SELL_EQUIPMENT_LIMIT_PER_TURN
		var deis_card_sc = context.game_state.get_card(deis_drawn_id)
		if deis_card_sc != null and deis_card_sc.def != null:
			var sp = deis_card_sc.def.get("cost")
			deis_sell_price = int(sp) if sp != null else 1
	if deis_valid_slots.is_empty() and not deis_can_sell:
		if context != null and context.deck_service != null:
			context.deck_service.discard_card(deis_drawn_id, &"effect_unset_discard")
		SLog.log_raw("[TIMING] %s %s 无合法槽%s，弃置抽到的牌 %s" % [String(action.action_id), String(act_type), "且卖出已满" if allow_sell else "", String(deis_drawn_id)])
		return &"skip"
	# AI owner：自动决策（AI 暂不支持选区域/卖出弹窗，避免挂死）。能卖则卖，否则设首槽。
	if _is_ai_owner(deis_player_id, deis_mech_id):
		if allow_sell and deis_can_sell:
			context.card_set_service.sell_equipment(deis_player_id, deis_drawn_id)
		elif not deis_valid_slots.is_empty():
			_do_immediate_set_equipment(deis_mech_id, deis_player_id, deis_drawn_id, deis_valid_slots[0])
		else:
			# 兜底（理论上上方已 return skip）：弃置抽到的牌
			if context != null and context.deck_service != null:
				context.deck_service.discard_card(deis_drawn_id, &"effect_unset_discard")
		return &"skip"
	# 人类：挂起弹"立即设置/卖出"面板
	_pending_effect[action.action_id] = {
		"effect": effect, "payload": payload, "phase": &"draw_equipment_set",
		"drawn_card_id": deis_drawn_id, "mech_id": deis_mech_id,
		"player_id": deis_player_id, "valid_slots": deis_valid_slots,
	}
	action.state = &"waiting_timing"
	var _ui_input: Dictionary = {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"drawn_card_id": deis_drawn_id,
		"valid_slots": deis_valid_slots,
		"mech_id": deis_mech_id,
		"player_id": deis_player_id,
	}
	if allow_sell:
		_ui_input["allow_sell"] = deis_can_sell
		_ui_input["sell_price"] = deis_sell_price
	action_needs_input.emit(action.action_id, &"immediate_set_equipment", _ui_input)
	SLog.log_raw("[TIMING] %s 挂起抽装备%s effect=%s 槽=%d can_sell=%s" % [String(action.action_id), "设置或卖出" if allow_sell else "立即设置", String(effect.effect_id), deis_valid_slots.size(), str(deis_can_sell)])
	return &"suspend"


## 判断父动作 pending 列表末尾的子动作是否"未立即完成"（挂起等待输入/时点/更小子动作）。
## 用于 _execute_actions 串行：仅当一个子动作挂起时才暂停循环、存剩余动作。
func _last_created_sub_action_paused(parent_action) -> bool:
	if parent_action == null or parent_action.pending_effect_action_ids.is_empty():
		return false
	if context == null or context.action_registry == null:
		return false
	var last_id: StringName = parent_action.pending_effect_action_ids[-1]
	var last_sub = context.action_registry.get_action(last_id)
	if last_sub == null:
		return false
	return last_sub.state == &"waiting_input" or last_sub.state == &"waiting_timing" or last_sub.state == &"waiting_effect_action"


## 串行续跑：上一个效果子动作完成/取消后，创建下一个待执行的效果子动作。
## 由 ActionEngine._after_sub_action_finished 在父动作所有子动作结束时调用。
## 返回 true 表示创建了新的未完成子动作（父动作继续等待）；false 表示无更多动作（父动作可推进）。
func _continue_seq_effect_actions(parent_action) -> bool:
	if parent_action == null or not parent_action.record.has("_seq_effect_actions"):
		return false
	var seq: Dictionary = parent_action.record["_seq_effect_actions"]
	var payload: Dictionary = seq.get("payload", {})
	var remaining: Array = seq.get("remaining", [])
	while not remaining.is_empty():
		# Q3 守卫：来源装备牌离场则停止剩余（effect_035/039 自损致弃置后不减威力/损伤）
		if bool(seq.get("source_check", false)) and _source_equipment_discarded(payload):
			parent_action.record.erase("_seq_effect_actions")
			return false
		var act: Dictionary = remaining.pop_front()
		# 先回写 record（remaining 已 pop），供后续断点/取消路径读取一致状态（保留 source_check）
		parent_action.record["_seq_effect_actions"] = {"payload": payload, "remaining": remaining, "source_check": seq.get("source_check", false)}
		var act_type: StringName = act.get("type", &"")
		# REGISTER_LISTEN/CHOOSE_ONE/OFFER_DAMAGE_REDIRECT 不创建子动作或走 waiting_timing 挂起，
		# 不应出现在 _seq remaining（_execute_actions 仅对 execute_sub_action 类动作设 _seq）。防御跳过。
		if act_type == &"REGISTER_LISTEN" or act_type == &"CHOOSE_ONE" or act_type == &"OFFER_DAMAGE_REDIRECT":
			continue
		# __REPEAT_LOOP_CHECK__：effect_084 一轮（自损+移动）完成后检查是否继续循环。
		# 不创建子动作，由 _handle_repeat_loop 决定：弹"是否继续发动？"窗（true）或结束循环（false）。
		if act_type == &"__REPEAT_LOOP_CHECK__":
			var lc_effect = act.get("effect_ref")
			if lc_effect != null and _handle_repeat_loop(parent_action, lc_effect, payload, act.get("params", {})):
				return true
			continue
		if context != null and context.action_service != null:
			context.action_service.execute_sub_action(act, payload, parent_action)
		# 创建了未完成子动作 -> 父动作继续等待它
		if _last_created_sub_action_paused(parent_action):
			return true
		# 否则（原子动作无子动作 / 子动作同步完成）继续下一个
	# 全部剩余动作处理完毕
	parent_action.record.erase("_seq_effect_actions")
	return false


## effect_084 一轮循环的动作列表：[自损(fixed_slot), 免费移动]；allow_continue 时附 __REPEAT_LOOP_CHECK__
func _repeat_iteration_actions(rs_params: Dictionary, effect) -> Array:
	var rs_mech: StringName = rs_params.get("target_mech_id", &"")
	var rs_slot: StringName = rs_params.get("target_slot_id", &"")
	var rs_damage: int = int(rs_params.get("damage_per_loop", 2))
	var rs_cells: int = int(rs_params.get("move_cells_per_loop", 2))
	var rs_reason: StringName = rs_params.get("damage_reason", &"equipment_effect_cost")
	var rs_allow_continue: bool = bool(rs_params.get("allow_continue", false))
	var iter: Array = [
		{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": rs_mech, "target_slot_id": rs_slot, "value": rs_damage, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": rs_reason, "fixed_slot": true}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"target_mech_id": rs_mech, "max_cells": rs_cells, "free_move": true, "loop_until_cancel": false}},
	]
	if rs_allow_continue:
		iter.append({"type": &"__REPEAT_LOOP_CHECK__", "params": rs_params, "effect_ref": effect})
	return iter


## 解析 REPEAT_SELF_DAMAGE_AND_FREE_MOVE 的 $binding_context.xxx 参数为具体值。
## 响应路径 payload 无 binding_context，故 fallback 到 payload 顶层（card_instance_id/mech_id），
## slot_id 从来源牌实例查。返回带具体 source_card_id/target_mech_id/target_slot_id 的 rs_params。
func _resolve_repeat_params(raw_params: Dictionary, payload: Dictionary, action) -> Dictionary:
	var resolved: Dictionary = raw_params.duplicate()
	var asvc = context.action_service if context != null else null
	# source_card_id
	var src_card: StringName = &""
	if asvc != null and raw_params.has("source_card_id"):
		var v = asvc._resolve_atomic_value(raw_params["source_card_id"], payload, action)
		src_card = v if v is StringName else StringName(str(v))
	if src_card == &"" or String(src_card) == "":
		src_card = payload.get("card_instance_id", &"")
	resolved["source_card_id"] = src_card
	# target_mech_id
	var rs_mech: StringName = &""
	if asvc != null and raw_params.has("target_mech_id"):
		var v2 = asvc._resolve_atomic_value(raw_params["target_mech_id"], payload, action)
		rs_mech = v2 if v2 is StringName else StringName(str(v2))
	if rs_mech == &"" or String(rs_mech) == "":
		rs_mech = payload.get("source_mech_id", payload.get("mech_id", &""))
	resolved["target_mech_id"] = rs_mech
	# target_slot_id
	var rs_slot: StringName = &""
	if asvc != null and raw_params.has("target_slot_id"):
		var v3 = asvc._resolve_atomic_value(raw_params["target_slot_id"], payload, action)
		rs_slot = v3 if v3 is StringName else StringName(str(v3))
	if (rs_slot == &"" or String(rs_slot) == "" or String(rs_slot).begins_with("$")) and src_card != &"" and context != null and context.game_state != null:
		var _sc = context.game_state.get_card(src_card)
		if _sc != null:
			rs_slot = _sc.slot_id
	resolved["target_slot_id"] = rs_slot
	return resolved


## effect_084 循环检查：一轮（自损+移动）完成后，决定是否再排一轮。
## 返回 true=父动作继续等待（弹了"是否继续发动？"窗）；false=循环结束（父动作可推进）。
## 停止条件：来源牌离场（自损致弃置）/ 此牌损伤≥stop_damage_threshold / AI（自动停）。
func _handle_repeat_loop(action, effect, payload: Dictionary, rs_params: Dictionary) -> bool:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var src_card_id: StringName = rs_params.get("source_card_id", bind_ctx.get("card_instance_id", &""))
	# 停止条件1：来源牌离场（自损致弃置）-- 查来源牌当前是否仍在某槽
	if bool(rs_params.get("stop_if_source_leaves_slot", true)) and _source_card_left_slot(src_card_id):
		return false
	# 停止条件2：此牌损伤 >= stop_damage_threshold（无法再承受）
	var stop_thresh: int = int(rs_params.get("stop_damage_threshold", 0))
	if stop_thresh > 0 and context != null and context.game_state != null:
		var sc = context.game_state.get_card(src_card_id) if src_card_id != &"" else null
		var tokens: int = int(sc.damage_tokens) if (sc != null and sc.get("damage_tokens")) else 0
		if tokens >= stop_thresh:
			return false
	# AI：自动停止循环（AI 连续决策留待后续）
	var rl_pid: StringName = bind_ctx.get("player_id", payload.get("player_id", &""))
	var rl_mid: StringName = bind_ctx.get("mech_id", rs_params.get("target_mech_id", &""))
	if _is_ai_owner(rl_pid, rl_mid):
		return false
	# 人类：弹"是否继续发动？"窗（choose_one_effect -> effect_choice 弹窗 -> on_ui_confirmed 续跑）
	_pending_effect[action.action_id] = {"effect": effect, "payload": payload, "phase": "repeat_continue", "repeat_params": rs_params}
	action.record["_waiting_for_repeat_continue"] = true
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": "继续发动（再自损2移动2格）", "effect_id": &"option_0", "option_index": 0},
			{"label": "停止", "effect_id": &"option_1", "option_index": 1},
		],
		"optional": true,
		"player_id": _effect_popup_owner_pid(effect, payload, action),
	})
	return true


## 来源装备牌是否已离开槽位（弃置/替换）：遍历机甲槽位，本牌不在任何槽的 equipped_card 即离场。
func _source_card_left_slot(card_id: StringName) -> bool:
	if card_id == &"" or context == null or context.game_state == null:
		return false
	for mech_id: StringName in context.game_state.mechs:
		var mech = context.game_state.mechs[mech_id]
		if mech == null or mech.get("slots") == null:
			continue
		for sid in mech.slots:
			var slot = mech.slots[sid]
			if slot == null:
				continue
			var ec = slot.get("equipped_card")
			if ec != null and ec.instance_id == card_id:
				return false  # 仍在槽
	return true  # 不在任何槽 -> 离场


## 检测来源装备牌（payload.binding_context）是否已从 slot 离场（弃置/替换）。
## Q3 裁定守卫：effect_035/039 的 EXECUTE_DAMAGE_CHANGE(fixed_slot 置损伤) 致来源牌弃置后，
## 剩余动作停止。离场诱发效果（DISCARD_AFTER，如 effect_031/005）不走此检测（来源牌本就弃置）。
func _source_equipment_discarded(payload: Dictionary) -> bool:
	if payload == null or context == null or context.game_state == null:
		return false
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var card_id: StringName = bind_ctx.get("card_instance_id", &"")
	var mech_id: StringName = bind_ctx.get("mech_id", &"")
	var slot_id: StringName = bind_ctx.get("slot_id", &"")
	if card_id == &"" or mech_id == &"" or slot_id == &"":
		return false  # 无来源装备牌信息，不检测（非装备 LISTEN 效果）
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return true
	var slot = mech.slots.get(slot_id)
	if slot == null:
		return true
	var equipped = slot.equipped_card
	if equipped == null:
		return true  # 槽空，牌已离场
	return equipped.instance_id != card_id


## 解析 CHOOSE_INTEGER 的 *_expr 表达式（$choice.n + $binding_context.owner_gold + 算术 + floor）。
## 用 Expression 计算：先替换变量引用为实际值，再 parse+execute。effect_040/041 金币换动力用。
func _eval_expr(expr_str: String, payload: Dictionary, choice: Dictionary):
	var s: String = expr_str
	# 替换 $choice.xxx
	for k in choice:
		s = s.replace("$choice." + String(k), str(choice[k]))
	# $binding_context.owner_gold 特殊：从 game_state 查玩家金币
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	if s.find("$binding_context.owner_gold") >= 0:
		var pid: StringName = bind_ctx.get("player_id", &"")
		var gold: int = 0
		if pid != &"" and context != null and context.game_state != null:
			var p = context.game_state.players.get(pid)
			if p != null:
				gold = p.gold
		s = s.replace("$binding_context.owner_gold", str(gold))
	# $binding_context.owner_action_hand_count 特殊：从 game_state 查玩家行动手牌数
	# effect_040/041（赤枭躯干）/effect_071/072（雄鹰躯干）弃行动牌换动力/移动的上限用
	if s.find("$binding_context.owner_action_hand_count") >= 0:
		var pid_ah: StringName = bind_ctx.get("player_id", &"")
		var ah_count: int = 0
		if pid_ah != &"" and context != null and context.game_state != null:
			var p_ah = context.game_state.players.get(pid_ah)
			if p_ah != null:
				ah_count = p_ah.action_hand.size()
		s = s.replace("$binding_context.owner_action_hand_count", str(ah_count))
	# 其他 $binding_context.xxx
	for k in bind_ctx:
		if String(k) == "owner_gold" or String(k) == "owner_action_hand_count":
			continue
		s = s.replace("$binding_context." + String(k), str(bind_ctx[k]))
	# floor() -> int()（Expression 内置 int；正数 int == floor）
	s = s.replace("floor(", "int(")
	var expr = Expression.new()
	if expr.parse(s) != OK:
		push_warning("[TIMING] CHOOSE_INTEGER expr 解析失败: %s -> %s" % [expr_str, s])
		return 0
	var result = expr.execute()
	if result == null:
		return 0
	return result


## 从 ActionEffect 和 action 创建 EffectBinding（兼容 ConditionChecker 等）
## payload 携带的 binding_context（permanent listener 注册时注入）优先作为来源：
##   装备牌 permanent listener 触发时，action 是被监听时点所属的动作（如 attack），
##   其 source 是攻击发起方而非装备牌。装备效果的 condition（如 SELF_MECH_IS_ATTACK_TARGET）
##   必须从 binding_context 取装备牌的 card_instance_id/mech_id/player_id。
func _make_binding_from_effect(effect: ActionEffect, action, payload: Dictionary = {}):
	var card_instance = null
	var card_instance_id: StringName = &""
	var src_player_id: StringName = &""
	var src_mech_id: StringName = &""

	# 优先从 payload.binding_context 取来源（装备/状态 permanent listener）
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	if not bind_ctx.is_empty():
		card_instance_id = bind_ctx.get("card_instance_id", &"")
		src_player_id = bind_ctx.get("player_id", &"")
		src_mech_id = bind_ctx.get("mech_id", &"")

	# 退回 action.source（行动牌 temporary listener、DIRECT 效果）
	if card_instance_id == &"" and action != null and action.source.has("card_instance_id"):
		card_instance_id = action.source.get("card_instance_id", &"")
	if card_instance_id != &"" and context != null and context.game_state != null:
		card_instance = context.game_state.cards.get(card_instance_id)

	var binding = _EffectBinding.new(card_instance, null)
	# 注入来源信息
	if src_player_id == &"" and action != null:
		src_player_id = action.source.get("player_id", &"")
	binding.override_owner_player_id = src_player_id
	# source.mech_id 优先；use_action_card 动作把 mech_id 算出后写进 action.record
	if src_mech_id == &"" and action != null:
		src_mech_id = action.source.get("mech_id", &"")
		if src_mech_id == &"" and action.record is Dictionary:
			src_mech_id = action.record.get("mech_id", action.record.get("source_mech_id", &""))
	binding.override_source_mech_id = src_mech_id
	# 注入 context，供 ConditionChecker 查询 game_state（ATTACK_TARGET_ALIVE 等）
	binding.context = context
	return binding
