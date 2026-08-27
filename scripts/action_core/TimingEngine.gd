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
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

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

## 早到输入信箱（通用件）：恢复输入先于目标动作挂起到达时暂存，挂起注册后补投。
## 见 EffectInputMailbox.gd 头注释。排空钩子：fire_timing 顶部（兜底）+
## ActionUIBridge._on_action_needs_input 顶部（主汇入点，挂起后引擎静默也能补投）。
const EffectInputMailboxScript = preload("res://scripts/action_core/EffectInputMailbox.gd")
var _effect_input_mailbox = EffectInputMailboxScript.new()

## 每回合1次使用记录：{ "{card_instance_id}:{once_per_turn_key}": { turn_number: used_count } }
## effect.once_per_turn_key 非空时，_execute_effect 成功执行后在此 +1；
## 触发前检查本回合 used_count >= once_per_turn_max 则跳过。
## scope = turn_number（换 turn 自动失效，无需显式清零）。owner 维度由 card_instance_id 区分。
var _once_per_turn_used: Dictionary = {}

## 每局1次使用记录：{ "{card_instance_id}:{once_per_game_key}": used_count }
## effect.once_per_game_key 非空时，_execute_effect 成功执行后在此 +1；
## 触发前检查 used_count >= once_per_game_max 则跳过。
## 不带 turn 维度（本局持久，机师牌/装备牌本局1次效果用，如 pilot_033 弃2装抽高级）。
var _once_per_game_used: Dictionary = {}

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

## 琳 pilot_024 RE 维修窗口开/关通知（app_root 显示取消维修按钮/锁定琳手牌维修牌）。
signal pilot_024_repair_window_changed(opened: bool, requester_mech_id: StringName)


## 排空早到信箱中「已挂起」动作的暂存输入（deferred 补投，待当前执行链 unwind 后生效）。
## 兜底钩子：fire_timing 顶部调用（信箱空时零开销）。主钩子在
## ActionUIBridge._on_action_needs_input 顶部（挂起后引擎静默无后续时点时仍能补投）。
func _drain_effect_input_mailbox_ready() -> void:
	if _effect_input_mailbox.is_empty():
		return
	for aid in _effect_input_mailbox.collect_ready(_pending_effect):
		for stashed_input in _effect_input_mailbox.drain(aid):
			SLog.log_raw("[MAILBOX] 补投早到恢复输入 action=%s（挂起已注册）" % String(aid))
			resume_pending_effect.call_deferred(aid, stashed_input)


## 供 ActionUIBridge._on_action_needs_input 汇入点调用：信箱里若有该动作的早到输入，
## 取出并 deferred 补投。返回 true 表示本次挂起等待由补投接管（调用方应直接 return，
## 不弹窗不占槽）。动作挂起注册先于 action_needs_input.emit（见各 _handle_*），
## 故此处补投时 _pending_effect 必已含该动作。
func drain_effect_input_for(action_id: StringName) -> bool:
	if _effect_input_mailbox.is_empty():
		return false
	var stashed_inputs: Array = _effect_input_mailbox.drain(action_id)
	if stashed_inputs.is_empty():
		return false
	for input_data in stashed_inputs:
		SLog.log_raw("[MAILBOX] 补投早到恢复输入 action=%s（挂起汇入点）" % String(action_id))
		resume_pending_effect.call_deferred(action_id, input_data)
	return true


## 发出时点
## 1. 收集所有匹配的监听器（永久+临时）
## 2. 处理被抑制的效果（锁定状态等）
## 3. 检查是否有AVAILABILITY监听器（响应窗口）
## 4. 如果有响应窗口，暂停动作等待玩家选择
## 5. 按优先级排序执行所有监听效果
func fire_timing(timing: StringName, action) -> void:
	# 早到输入信箱兜底排空（须在 waiting 早退之前：挂起动作自身不再 fire，靠其它时点驱动）。
	_drain_effect_input_mailbox_ready()
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

	# 通用：把发起动作的 source 信息并入 payload，供时点监听器解析伤害/效果来源。
	# source 由 _create_action 注入（_build_source_from_params/_build_source_from_payload），含：
	#   source_action_id（父攻击动作 id：攻击伤害 HP_CHANGE_AFTER 经此回退 attack.attacker_id）、
	#   mech_id（显式效果伤害来源，如肯耳忒缴械冲击 EXECUTE_HP_CHANGE 的 source_mech_id）、
	#   card_instance_id / player_id。
	# 塞万提斯 pilot_034 effect_02 记录「对我方造成过伤害的机甲」依赖此：此前 HP_CHANGE_AFTER
	# 的 payload 只有 record（source 不在 record_keys），来源恒空导致记录集永不填充、复仇反击
	# 条件 ATTACK_TARGET_IN_PILOT_034_RECORDED 恒 false（完全没触发）。
	# 仅当 payload 无 source 且含非空链接字段时注入（避免覆盖显式写入；无字段的裸 source 不注入）。
	# 攻击时点注入的 attack.source 无 mech_id/card_instance_id（params 只带 player_id），
	# 不污染 _effect_source_mech_id/_effect_card_instance_id 的绑定优先解析（防御监听器安全）。
	if not payload.has("source") and action.source is Dictionary \
			and (String(action.source.get("source_action_id", &"")) != "" \
				or String(action.source.get("mech_id", &"")) != "" \
				or String(action.source.get("card_instance_id", &"")) != ""):
		payload["source"] = action.source

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
	# 洛尔恩效果2「掩护后该攻击不能被响应」：SET_ATTACK_NO_RESPONSE 写入 attack record["no_response"]，
	# 此时点 fire（含 ATTACK_AT 响应窗口）直接跳过——任何响应（迎击/识破）都不弹窗。
	if not bool(action.record.get("no_response", false)):
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
		var pa: int = _effective_priority(a, action)
		var pb: int = _effective_priority(b, action)
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
		# pilot_015 诺拉 effect_01a/01b：攻击牌额外效果剥离。
		# flag 设置后（ATTACK_PRE 的 01a 或 ATTACK_AT 的 01b 写入），跳过 attack_card_id 对应攻击牌的
		# 额外效果 listener（强袭2/猛击2/破甲2/预判2/预判3 等 bind_to_sub 的 card_instance_id==attack_card_id）。
		# 已在 flag 设置前 fire 的额外效果（如猛击2 在 ATTACK_BEFORE）保留生效，但威力由 _step_calculate_damage 还原。
		var _p015_flags: Dictionary = action.record.get("_effect_flags", {}) if action.record != null else {}
		if _p015_flags.has(&"pilot_015_force_pure_assault"):
			var _p015_atk_card: StringName = payload.get("attack_card_id", &"")
			var _p015_entry_card: StringName = entry.get("card_instance_id", &"")
			if _p015_atk_card != &"" and _p015_entry_card == _p015_atk_card:
				SLog.log_raw("[TIMING] %s 跳过 %s：pilot_015 强制纯进攻剥离攻击牌额外效果" % [String(action.action_id), String(effect.effect_id)])
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


## 收集时点的常规监听器（按 fire_timing 同规则排序后返回），并完成时点公告
## （SLog 日志 + timing_fired 信号，各一次）。返回的每个条目结构与 fire_timing 内部一致：
## {effect, card_instance_id, source_type, binding_context, seq, tier, seat, ...}。
## 供 TurnService 对 TURN_BEFORE_END 做「按归属玩家并行分发」（拾荒/宝藏/修悟多玩家并行）：
## fire_timing 顺序执行下，首个挂起的监听器会把剩余暂存到虚拟动作 _pending_regular_listeners，
## 而 turn 虚拟动作无 steps，恢复路径（_execute_step 阶段3 的补跑）不会执行 ->
## 多玩家各设拾荒类事件牌时只有第一个设置的玩家生效。并行分发把每个归属玩家的监听器
## 组交给独立虚拟动作执行/挂起，天然全覆盖。
## 限制：不处理 AVAILABILITY 监听器（响应窗口路径，TURN_BEFORE_END 无此类效果）；
## 临时监听器仅收集无 action 绑定的（绑定特定动作的随宿主动作 fire_timing 执行）。
## payload 由调用方构造（player_id/turn_number 等时点字段），公告与监听器执行共用。
func collect_regular_listeners(timing: StringName, payload: Dictionary) -> Array:
	# 时点公告（与 fire_timing 一致，只公告一次；无宿主动作，action 公共字段用占位值）
	var log_payload := payload.duplicate()
	log_payload["timing_name"] = String(timing)
	SLog.log_timing(timing, &"", &"turn", log_payload)
	timing_fired.emit(timing, payload)

	# 收集所有匹配的监听器（永久+临时；过滤规则与 fire_timing 相同）
	var listeners: Array = []
	var perm: Array = permanent_listeners.get(timing, [])
	for entry: Dictionary in perm:
		var effect: ActionEffect = entry.get("effect")
		if effect == null:
			continue
		# 检查 action_type 过滤（本路径无宿主动作，仅收对 turn 类型开放的）
		if effect.listen_action_type != &"" and effect.listen_action_type != &"turn":
			continue
		if _is_effect_suppressed(timing, effect):
			continue
		listeners.append({"effect": effect, "card_instance_id": entry.get("binding_context", {}).get("card_instance_id", &""), "source_type": &"permanent", "binding_context": entry.get("binding_context", {}), "seq": entry.get("seq", 0)})
	var temp: Array = temporary_listeners.get(timing, [])
	for entry: Dictionary in temp:
		# 绑定特定 action_id 的临时监听器不在本路径执行（无宿主动作可匹配）
		if entry.get("action_id", &"") != &"":
			continue
		var bound_type: StringName = entry.get("action_type", &"")
		if bound_type != &"" and bound_type != &"turn":
			continue
		var effect: ActionEffect = entry.get("effect")
		if effect == null:
			continue
		if _is_effect_suppressed(timing, effect):
			continue
		listeners.append({"effect": effect, "card_instance_id": entry.get("card_instance_id", &""), "source_type": &"temporary", "binding_context": entry.get("binding_context", {}), "seq": entry.get("seq", 0)})
	if listeners.is_empty():
		return []

	# 标注 tier/seat（同优先级排序用）
	for entry: Dictionary in listeners:
		_annotate_listener_meta(entry)

	# 分离常规监听器（AVAILABILITY 走响应窗口路径，本路径不处理）
	var regular: Array = []
	for entry: Dictionary in listeners:
		if entry["effect"].mode != _TimingConst.MODE_AVAILABILITY:
			regular.append(entry)
	if regular.is_empty():
		return []

	# 与 fire_timing 同规则排序（优先级降序 -> tier -> 装备牌 seat -> 注册序号；
	# 本路径无宿主动作，_effective_priority 传 null，仅 pilot_005/004 特例受影响，不监听本时点）
	regular.sort_custom(func(a, b) -> bool:
		var pa: int = _effective_priority(a, null)
		var pb: int = _effective_priority(b, null)
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
	return regular


## 「动力消耗事件」通用虚拟时点（&"power_spent"，杰西卡 pilot_050 等动力税效果监听）。
## 由 GameActions.spend_power 对全部消耗路径统一通知（reason=BASIC_MOVE 除外：移动消耗由
## BASIC_MOVE_AT 时点监听真正逐格阻塞，此处不重复通知以免双计）。玛丽尔/巴托洛夫等"减动力"
## 走 modify_mech_power 不经 spend_power，天然不计入消耗。
## 把事件写到当前正在执行步骤的宿主动作 record（fire_timing 会拷贝进 payload），监听器
## （POWER_SPEND_TAX 等）读 payload._power_spent_event 获得消耗方与数值；消耗时立即阻塞：
## 监听器可设 waiting_timing / waiting_effect_action 暂停宿主动作。
## 无宿主动作（消耗发生在动作步骤之外）时跳过：无处阻塞，动力税不触发。
func fire_power_spent_event(event: Dictionary) -> void:
	if not permanent_listeners.has(&"power_spent"):
		return
	if context == null or context.action_engine == null:
		return
	var host = context.action_engine.get_current_action()
	if host == null:
		return
	var _prev_evt: Variant = host.record.get("_power_spent_event", null)
	host.record["_power_spent_event"] = event
	fire_timing(&"power_spent", host)
	if _prev_evt == null:
		host.record.erase("_power_spent_event")
	else:
		host.record["_power_spent_event"] = _prev_evt


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
			var pa: int = _effective_priority(a, action)
			var pb: int = _effective_priority(b, action)
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
		# pilot_015 诺拉 effect_01a/01b：攻击牌额外效果剥离。
		# flag 设置后（ATTACK_PRE 的 01a 或 ATTACK_AT 的 01b 写入），跳过 attack_card_id 对应攻击牌的
		# 额外效果 listener（强袭2/猛击2/破甲2/预判2/预判3 等 bind_to_sub 的 card_instance_id==attack_card_id）。
		# 已在 flag 设置前 fire 的额外效果（如猛击2 在 ATTACK_BEFORE）保留生效，但威力由 _step_calculate_damage 还原。
		var _p015_flags: Dictionary = action.record.get("_effect_flags", {}) if action.record != null else {}
		if _p015_flags.has(&"pilot_015_force_pure_assault"):
			var _p015_atk_card: StringName = payload.get("attack_card_id", &"")
			var _p015_entry_card: StringName = entry.get("card_instance_id", &"")
			if _p015_atk_card != &"" and _p015_entry_card == _p015_atk_card:
				SLog.log_raw("[TIMING] %s 跳过 %s：pilot_015 强制纯进攻剥离攻击牌额外效果" % [String(action.action_id), String(effect.effect_id)])
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
	# 收集有可用响应牌的玩家集合（eligible），用于多玩家 pass 追踪（问题4）：
	# 任一玩家跳过只放弃自己响应权，其他人仍可响应；所有人 pass 才关闭窗口继续攻击。
	var eligible_pids: Array[StringName] = []

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
		# 收集 eligible 玩家（binding_context.player_id = 响应方拥有者）
		var _ep_bc: Dictionary = entry.get("binding_context", {})
		var _ep_pid: StringName = _ep_bc.get("player_id", &"")
		if _ep_pid != &"" and not eligible_pids.has(_ep_pid):
			eligible_pids.append(_ep_pid)

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
	# 问题4：记录 eligible 玩家集合与已 pass 玩家，用于多玩家 pass 追踪。
	# 任一玩家 pass 只放弃自己响应权；所有 eligible 都 pass 才 continue_action 关闭窗口。
	action.record["_response_eligible_players"] = eligible_pids
	action.record["_response_passed_players"] = []

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
## pass_player_id：pass（空选择）时传入放弃响应的玩家 id（PvP 人类玩家）；为空则走旧行为（AI/兼容）直接关闭。
## 返回 true=窗口应关闭（全 pass 或确认响应）；false=窗口保持（部分玩家 pass，其他人仍可响应）。
func handle_response_selection(action_id: StringName, selected_cards: Array[Dictionary], pass_player_id: StringName = &"") -> bool:
	if context == null or context.action_registry == null or context.action_service == null:
		return true

	var attack_action = context.action_registry.get_action(action_id)
	if attack_action == null:
		return true

	var is_pass: bool = selected_cards.is_empty()

	# 重入保护：响应窗口的玩家选择可能被多个信号回调重复触发
	# （response_panel._on_confirm 同时 emit availability_effect_selected 与 response_selected，
	#  二者在 app_root 中都调用本方法）。若该攻击动作已处理过响应，再次发起 use_action_card 会导致：
	#  同一张迎击牌被使用两次、迎击牌错误绑定到正在等待输入的 single_move 效果动作
	#  （attack_action_id 被偷换成 single_move 的 id）、原攻击动作永远卡在等待状态无法结算
	#  （攻击既不显示命中也不造成伤害）。
	# 用按 action_id 记录"已处理"标记去重，而不依赖 attack_action.state——
	# 单测中攻击动作可能处于 running 态（非 waiting_timing），靠状态判断会误拒合法的首次调用。
	# 动作 cleanup 时通过 clear_handled_response_for_action 清除此标记。
	# 问题4：pass 路径不去重（多玩家 pass 追踪，每个玩家独立 pass；只有确认响应才标记已处理）。
	if not is_pass:
		if _handled_response_actions.has(action_id):
			return true
		_handled_response_actions[action_id] = true

	# 玩家取消响应（空选择）：直接恢复 attack 继续执行（不跳过 execute_attack）
	# 注意：不要在此处把 state 设为 running——continue_action 仅接受等待态
	# (waiting_input/waiting_timing/waiting_sub_action)，先置 running 会被它拒绝，
	# 导致攻击动作永远卡在 ATTACK_AT 无法继续 check_hit/apply_damage/settle。
	if is_pass:
		if pass_player_id == &"":
			response_window_closed.emit(action_id, selected_cards)
			attack_action.record.erase("_response_eligible_players")
			attack_action.record.erase("_response_passed_players")
			if context.action_engine != null:
				context.action_engine.continue_action(action_id, {})
			return true
		# 人类玩家 pass：标记该玩家已放弃响应
		var passed: Array = attack_action.record.get("_response_passed_players", [])
		if not passed.has(pass_player_id):
			passed.append(pass_player_id)
			attack_action.record["_response_passed_players"] = passed
		# 检查是否所有 eligible 玩家都已 pass
		var eligible: Array = attack_action.record.get("_response_eligible_players", [])
		var all_passed: bool = true
		for ep in eligible:
			if not passed.has(ep):
				all_passed = false
				break
		if all_passed:
			response_window_closed.emit(action_id, selected_cards)
			attack_action.record.erase("_response_eligible_players")
			attack_action.record.erase("_response_passed_players")
			if context.action_engine != null:
				context.action_engine.continue_action(action_id, {})
			return true
		# 还有其他玩家未 pass：不关闭窗口，不 continue（保持其他玩家响应权）
		# pass 玩家端窗口已由 _on_response_passed 关闭；其他端窗口保持。
		SLog.log_raw("[TIMING] %s 响应 pass by %s，剩余 eligible 未全 pass，保持窗口" % [String(action_id), String(pass_player_id)])
		return false

	# 确认响应（竞争响应）：清理 pass 追踪记录，执行响应牌
	attack_action.record.erase("_response_eligible_players")
	attack_action.record.erase("_response_passed_players")

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
		return true

	var card = context.game_state.get_card(card_instance_id)
	if card == null:
		return true

	# 响应方持有者（行动牌由 register_hand_card_availability 设置；装备牌由 set_equipment 设置）
	var responder_player_id: StringName = card.owner_player_id
	var responder_mech_id: StringName = card.mech_id
	var effect_id: StringName = card_data.get("effect_id", &"")

	# granted 跨机甲响应（pilot_002 莱比尔协同·防御）：效果来源牌 pilot_002 在莱比尔机甲上，
	# 但实际响应机甲是被攻击的联邦机甲 A（card.mech_id=莱比尔≠A）。此时按攻击目标从 granted
	# listener 的 binding_context 推导响应机甲 A 及其 player_id，否则后续 ADD_MECH_TEMP_ARMOR
	# 等会误作用到莱比尔机甲。单目标用 target_id；多目标(双连)取首个有匹配 granted listener 的目标。
	if card.mech_id != &"" and effect_id != &"":
		var _atk_targets: Array = []
		var _stid: StringName = attack_action.record.get("target_id", &"")
		if _stid != &"":
			_atk_targets.append(_stid)
		for _etid in attack_action.record.get("target_ids", []):
			var _etid_sn: StringName = StringName(_etid)
			if _etid_sn != &"" and not _atk_targets.has(_etid_sn):
				_atk_targets.append(_etid_sn)
		if not _atk_targets.is_empty():
			var _found_granted := false
			for _atid in _atk_targets:
				var _g_entry = _find_effect_listener(effect_id, card_instance_id, _atid)
				if _g_entry != null:
					var _g_bind: Dictionary = _g_entry.get("binding_context", {})
					responder_mech_id = _g_bind.get("mech_id", _atid)
					responder_player_id = _g_bind.get("player_id", responder_player_id)
					_found_granted = true
					break
			# 未命中（非 granted 效果）保持 card.mech_id 不变

	# 迪恩替别人响应（问题3）：响应方机甲(迪恩)非本次攻击目标时，其手牌"反击/疾行"迎击牌
	# 替相邻友军响应。此时攻击目标应转变为迪恩（复用 _p011_redirect_rewind 回退 PRE 重 fire）。
	# 在 responded 写入前判定（_is_dean_ally_respond_eligible 含 ATTACK_NOT_RESPONDED 检查）。
	var _atk_first_target: StringName = StringName(attack_action.record.get("target_id", &""))
	if StringName(responder_mech_id) != &"" and _atk_first_target != &"" \
			and StringName(responder_mech_id) != _atk_first_target \
			and _is_dean_ally_respond_eligible(responder_mech_id, card, attack_action):
		# 单目标：替换 target_id 为响应方；多目标 target_ids 中匹配项同步替换（被保护目标）。
		if not attack_action.record.has("_redirect_from"):
			attack_action.record["_redirect_from"] = String(_atk_first_target)
		attack_action.record["target_id"] = responder_mech_id
		var _rd_ids: Array = attack_action.record.get("target_ids", [])
		for _ri in range(_rd_ids.size()):
			if StringName(_rd_ids[_ri]) == _atk_first_target:
				_rd_ids[_ri] = responder_mech_id
		if not _rd_ids.is_empty():
			attack_action.record["target_ids"] = _rd_ids
		attack_action.record["_redirect_rewind"] = true
		SLog.log_raw("[ACTION] %s 迪恩(%s) 替 %s 响应，攻击目标转移为迪恩" % [String(action_id), String(responder_mech_id), String(_atk_first_target)])

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
			# 攻击目标/发起方：供 effect_084 的 SELF_MECH_IS_ATTACK_TARGET 等 condition 读取。
			# attack_target_id 为攻击目标（独立字段，不被 resume 选牌目标 target_id 覆盖）；
			# target_id 初始也是攻击目标，但 pilot_002 防御选 B 后被 resume 覆盖为交牌目标 B。
			"attack_target_id": attack_action.record.get("target_id", &""),
			"target_id": attack_action.record.get("target_id", &""),
			"attacker_id": attack_action.record.get("attacker_id", &""),
		}
		# 装备响应效果含弃牌费用（094/096 光束/热能响应）：先弹"弃1张行动牌"选择窗，
		# 玩家选牌后续跑（弃牌 + 执行效果 actions）。不直接 _execute_effect_by_id--
		# 那会走非可选弃牌的 _pay_costs 自动弃第一张牌（无弹窗），且无攻击牌时 can_pay 失败致效果不执行。
		var nc_effect: ActionEffect = card_data.get("effect")
		if nc_effect != null and _effect_has_discard_cost(nc_effect):
			var _rd_count := 1
			var _rd_no_cancel := false
			var _rd_label := ""
			var _rd_verb: StringName = &"discard"
			for _rd_cost in nc_effect.costs:
				if _rd_cost is Dictionary and _rd_cost.get("cost_type", &"") == &"DISCARD_ACTION_CARD":
					_rd_count = int(_rd_cost.get("count", 1))
					_rd_no_cancel = bool(_rd_cost.get("params", {}).get("no_cancel", false))
					_rd_label = String(_rd_cost.get("params", {}).get("label", ""))
					# 转化类 cost（迪恩 to_temp_zone + reason=pilot_conversion_cost）用"转化"文案
					if bool(_rd_cost.get("params", {}).get("to_temp_zone", false)) or String(_rd_cost.get("params", {}).get("reason", &"")) == &"pilot_conversion_cost":
						_rd_verb = &"convert"
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
				"no_cancel": _rd_no_cancel,
				"effect_id": effect_id,
				"action_verb": _rd_verb,
				# 转化类 cost（迪恩）自定义选牌框文案（"选择转化使用的2张行动牌"），非转化回退默认描述
				"source_label": _rd_label if _rd_label != "" else "%s：弃置%d张行动牌响应" % [String(card.def.display_name), _rd_count],
			})
			SLog.log_raw("[ACTION] %s 装备响应效果 %s 挂起弃牌选择（持有者 %s）" % [String(action_id), String(effect_id), String(responder_player_id)])
			return true
		_execute_effect_by_id(effect_id, nc_payload, attack_action)
		SLog.log_raw("[ACTION] %s 被 %s 响应(非迎击牌效果 %s)" % [String(action_id), String(card_instance_id), String(effect_id)])
		# granted 防御效果挂起选目标/选牌（waiting_timing + _pending_effect）：attack 保持暂停等 resume，
		# 不能 continue_action，否则攻击越过 ATTACK_AT 直接结算命中（防御流程没走）。
		# resume 链：选B->重跑->CHOOSE_MANY_CARDS选牌->续跑 TRANSFER+护甲+损伤-1+抽2->continue_action 推进攻击。
		if attack_action.state == &"waiting_timing" and _pending_effect.has(action_id):
			response_window_closed.emit(action_id, selected_cards)
			return true
		# 若创建了子动作（如 single_move），attack 等其完成；否则同步完成恢复 attack
		if not attack_action.pending_effect_action_ids.is_empty() and attack_action.state != &"waiting_effect_action":
			attack_action.state = &"waiting_effect_action"
		response_window_closed.emit(action_id, selected_cards)
		if attack_action.pending_effect_action_ids.is_empty():
			if context.action_engine != null:
				context.action_engine.continue_action(action_id, {})
		return true

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
		return true

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
		return true

	# use_action_card 仍在执行（等待 single_move 等效果动作输入）：
	# 建立父子关系，attack 从 waiting_timing 切到 waiting_sub_action，
	# 等 use_action_card 完成后由 notify_effect_action_completed 恢复。
	# （uc_action 尚未完成，parent_action_id 在此设置可被其 _complete_action 的延迟父通知正确捕获。）
	uc_action.parent_action_id = action_id
	if not attack_action.pending_effect_action_ids.has(uc_action_id):
		attack_action.pending_effect_action_ids.append(uc_action_id)
	attack_action.state = &"waiting_effect_action"

	response_window_closed.emit(action_id, selected_cards)
	return true


## 效果动作 resume 阶段顶层 execute(use_action_card) 后手动建立父子链接
## （与上方响应窗口模板同款模式，通用件--pilot_027/006/047 强制使用行动牌共用）：
## 若派生的 use_action_card 未同步完成（挂起在选牌/选目标/攻击时序），链接为效果动作的
## 子动作并让效果动作等待。否则效果动作立即完成 -> 被监听的攻击（双连 fork）继续推进、
## 派生 fork2 -> fork2 攻击时响应窗口的 needs_input 覆盖共享等待槽，把本 use_action_card
## 的输入弹窗孤儿化 -> 输入无处回填、死锁在攻击时点（bug2）。
## 返回 true=已链接（调用方走等待分支）；false=无需等待（同步完成/执行失败，照旧继续）。
func _link_spawned_use_action_as_child(spawn_result, effect_action) -> bool:
	if effect_action == null or spawn_result == null or not (spawn_result is Dictionary):
		return false
	var uc_id: StringName = StringName((spawn_result as Dictionary).get("action_id", &""))
	if uc_id == &"" or context == null or context.action_registry == null:
		return false
	var uc_action = context.action_registry.get_action(uc_id)
	if uc_action == null or uc_action.state == &"completed" or uc_action.state == &"cancelled":
		# 同步完成/取消/失败：不链接（已完成动作不会再发父通知，父等待会永久卡死）
		return false
	# 未同步完成：建立父子关系，效果动作等 use_action_card 完成后由 notify_effect_action_completed
	# 恢复。（uc_action 尚未完成，parent_action_id 在此设置可被其 _complete_action 的延迟父通知
	# 正确捕获。）
	uc_action.parent_action_id = effect_action.action_id
	if not effect_action.pending_effect_action_ids.has(uc_id):
		effect_action.pending_effect_action_ids.append(uc_id)
	effect_action.state = &"waiting_effect_action"
	SLog.log_raw("[TIMING] 强制使用行动牌 %s 链接为效果动作 %s 的子动作（父等待完成）" % [String(uc_id), String(effect_action.action_id)])
	return true


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


## 按来源牌实例 + 机甲定向注销永久监听器（泰特 pilot_074 授予到期/换机师等）。
## 只移除 binding_context.card_instance_id==card_instance_id 且 mech_id==mech_id 的条目，
## 保留该来源牌在其他机甲（含其自身）上的监听器——泰特自己的按钮/监听不受他机授予到期影响。
func unregister_permanent_listeners_for_card_and_mech(card_instance_id: StringName, mech_id: StringName) -> void:
	if card_instance_id == &"" or mech_id == &"":
		return
	for timing: StringName in permanent_listeners.keys():
		var list: Array = permanent_listeners[timing]
		var filtered: Array = list.filter(func(entry: Dictionary) -> bool:
			var ctx: Dictionary = entry.get("binding_context", {})
			return not (ctx.get("card_instance_id", &"") == card_instance_id and ctx.get("mech_id", &"") == mech_id)
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


## 注销某机甲的 pilot_002 granted 监听器（换机师时清旧加成）。
## 遍历所有时点，移除 effect_id 以 pilot_002_granted_ 开头且 binding_context.mech_id==mech_id 的条目。
## 与 unregister_permanent_listeners_for_card 不同：granted 的 card_instance_id 是莱比尔实例（非该机甲机师牌），
## 故按来源牌注销会漏删，须按 mech_id + effect_id 前缀精确清理。
func ungrant_pilot_002_for_mech(mech_id: StringName) -> void:
	if mech_id == &"":
		return
	for timing: StringName in permanent_listeners.keys():
		var list: Array = permanent_listeners[timing]
		var filtered: Array = list.filter(func(entry: Dictionary) -> bool:
			var eff: ActionEffect = entry.get("effect")
			if eff == null or not String(eff.effect_id).begins_with("pilot_002_granted_"):
				return true
			var ctx: Dictionary = entry.get("binding_context", {})
			return ctx.get("mech_id", &"") != mech_id
		)
		if filtered.is_empty():
			permanent_listeners.erase(timing)
		else:
			permanent_listeners[timing] = filtered


## 注销某机甲的 pilot_005 肯特 granted listener（换机师时调用，按 effect_id 前缀 + mech_id 精确删）。
## granted 的 card_instance_id=肯特实例≠换下的机师牌，unregister_permanent_listeners_for_card 会漏删。
func ungrant_pilot_005_for_mech(mech_id: StringName) -> void:
	if mech_id == &"":
		return
	for timing: StringName in permanent_listeners.keys():
		var list: Array = permanent_listeners[timing]
		var filtered: Array = list.filter(func(entry: Dictionary) -> bool:
			var eff: ActionEffect = entry.get("effect")
			if eff == null or not String(eff.effect_id).begins_with("pilot_005_granted_"):
				return true
			var ctx: Dictionary = entry.get("binding_context", {})
			return ctx.get("mech_id", &"") != mech_id
		)
		if filtered.is_empty():
			permanent_listeners.erase(timing)
		else:
			permanent_listeners[timing] = filtered


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
				"owner_player_id": _resolve_avail_owner(entry.get("card_instance_id", &""), entry.get("binding_context", {})),
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
				"owner_player_id": _resolve_avail_owner(pcid, pbind),
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


## 解析 AVAILABILITY 条目的持有者玩家（多响应方窗口用）：
## 优先 binding_context.player_id（装备/机师效果注册时带），否则查 card 实例的 owner_player_id，
## 再退回通过 card.mech_id 反查持有玩家。返回空时由 UI 层兜底（无法归属的条目不入本地窗口）。
func _resolve_avail_owner(card_instance_id: StringName, bind_ctx: Dictionary) -> StringName:
	var pid: StringName = bind_ctx.get("player_id", &"")
	if pid != &"":
		return pid
	if card_instance_id == &"" or context == null or context.game_state == null:
		return &""
	var card = context.game_state.get_card(card_instance_id)
	if card == null:
		return &""
	if card.owner_player_id != &"":
		return card.owner_player_id
	if card.mech_id != &"":
		var op = context.game_state.get_player_for_mech(card.mech_id)
		if op != null:
			return op.player_id
	return &""


## 根据 effect_id + card_instance_id + mech_id 精确查找监听器 entry。
## granted 跨机甲场景（pilot_002 莱比尔授予）：多个 listener 共享同一来源 card_instance_id
## （=pilot_002 实例），须按执行机甲 mech_id 去歧义——
##   进攻：source.mech_id = 被授予联邦机甲 A（EX 按钮所在机甲）；
##   防御：source.mech_id = A（响应窗口注入的被攻击目标）。
## mech_id 为空或无精确命中时返回 null，交由调用方回退到原 card_id 首匹配逻辑。
func _find_effect_listener(effect_id: StringName, card_id: StringName, mech_id: StringName):
	if mech_id == &"":
		return null
	for store in [permanent_listeners, temporary_listeners]:
		for _timing: StringName in store:
			for entry: Dictionary in store[_timing]:
				var eff: ActionEffect = entry.get("effect")
				if eff == null or eff.effect_id != effect_id:
					continue
				var bind_ctx: Dictionary = entry.get("binding_context", {})
				var entry_card: StringName = entry.get("card_instance_id", bind_ctx.get("card_instance_id", &""))
				if card_id != &"" and entry_card != card_id:
					continue
				if bind_ctx.get("mech_id", &"") == mech_id:
					return entry
	return null


## 根据效果ID执行效果（用于EffectFireAction等场景）
## 若 payload.source.card_instance_id 指定，精确匹配该装备牌的 listener entry（双方同名装备区分），
## 并把 entry.binding_context 注入 payload，供 condition/once_per_turn 取来源。
## granted 跨机甲场景：先按 source.mech_id 精确匹配执行机甲，避免多机甲共享来源牌时误取首条。
func _execute_effect_by_id(effect_id: StringName, payload: Dictionary, action) -> void:
	var src: Dictionary = payload.get("source", {}) if payload.has("source") else {}
	var want_card_id: StringName = src.get("card_instance_id", payload.get("card_instance_id", &""))
	var want_mech_id: StringName = src.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	# granted 跨机甲去歧义：source.mech_id 指定执行机甲 A 时，优先取 mech_id==A 的 listener。
	if want_mech_id != &"":
		var matched = _find_effect_listener(effect_id, want_card_id, want_mech_id)
		if matched != null:
			var m_eff: ActionEffect = matched.get("effect")
			var m_bind: Dictionary = matched.get("binding_context", {})
			var m_payload: Dictionary = payload
			if not m_bind.is_empty():
				m_payload = payload.duplicate()
				m_payload["binding_context"] = m_bind
			_execute_effect(m_eff, m_payload, action)
			return
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
			# granted 跨机甲去歧义：want_mech_id 指定时跳过其他机甲的 listener（空 mech 透传保留旧行为）
			if want_mech_id != &"":
				var _em: StringName = bind_ctx.get("mech_id", &"")
				if _em != &"" and _em != want_mech_id:
					continue
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
			# granted 跨机甲去歧义：want_mech_id 指定时跳过其他机甲的 listener（空 mech 透传保留旧行为）
			if want_mech_id != &"":
				var _em2: StringName = bind_ctx.get("mech_id", &"")
				if _em2 != &"" and _em2 != want_mech_id:
					continue
			var eff_payload: Dictionary = payload
			if not bind_ctx.is_empty():
				eff_payload = payload.duplicate()
				eff_payload["binding_context"] = bind_ctx
			_execute_effect(effect, eff_payload, action)
			return


## ── 内部方法 ──


## 执行一个效果
## 计算监听器的有效优先级（排序用）。
## 攻击/被攻击合并的被动效果（pilot_005_granted_suppression 帝国压制 / pilot_004_effect_02 动力穿透）
## 不拆分 effect：按 binding_context.mech_id 是攻击方（30）还是被攻击方（10）动态调整，
## 攻击方先于防御方结算、被攻击方晚于攻击方结算。其余 effect 用 effect.priority 原值。
func _effective_priority(entry: Dictionary, action) -> int:
	var eff = entry.get("effect", null)
	if eff == null:
		return 0
	var base_pri: int = eff.priority
	var eid: String = String(eff.effect_id)
	if eid != "pilot_005_granted_suppression" and eid != "pilot_004_effect_02":
		return base_pri
	var bc: Dictionary = entry.get("binding_context", {})
	var mid: StringName = bc.get("mech_id", &"")
	if mid == &"" or action == null:
		return base_pri
	var rec = action.record if action.get("record") != null else {}
	if rec is Dictionary:
		var atk: StringName = rec.get("attacker_id", &"")
		if atk != &"" and mid == atk:
			return 30  # 攻击方先手
		return 10  # 被攻击方后手
	return base_pri


func _execute_effect(effect: ActionEffect, payload: Dictionary, action) -> void:
	# 记录效果开始执行
	SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "checking_conditions"})

	# 检查效果间依赖
	if effect.requires_effect != &"":
		if not _is_required_effect_executed(effect.requires_effect, action.action_id):
			SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "requires_effect_not_executed", "required": String(effect.requires_effect)})
			return

	# 条件检查
	# resume 重跑豁免：效果挂起（等待玩家输入/时点）前条件已通过；挂起期间回合可能已切换
	# （TURN_AFTER_END 挂起后 _net_end_turn 立即 start_turn 下家），重检 IS_OWNER_TURN 等
	# 依赖 active_player_id 的条件会误判"不再满足"致效果被 skip（弥雅 pilot_071 选完目标无反应）。
	# 各 resume 分支确认时设 _effect_conditions_prechecked=true，重跑跳过条件重检，仅续跑后续 actions。
	if not payload.get("_effect_conditions_prechecked", false) and not _check_conditions(effect, payload, action):
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "conditions_not_met"})
		return

	# 每回合1次检查：effect.once_per_turn_key 非空时，若本回合已用满则跳过
	# （机动头部抽牌、狙击右臂弃牌回动力、帝国腿移动回复等用）
	if effect.once_per_turn_key != &"" and _is_once_per_turn_used_up(effect, payload):
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "once_per_turn_used_up"})
		return

	# 每局1次检查：effect.once_per_game_key 非空时，若本局已用满则跳过
	if effect.once_per_game_key != &"" and _is_once_per_game_used_up(effect, payload):
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "skipped", "reason": "once_per_game_used_up"})
		return

	# force_select：效果需自己选目标，独立于 attack 被攻击目标。LISTEN effect 复用 attack.record
	# 作 payload 时 target_id 被攻击目标污染，CHOOSE_OTHER_MECH 误判“已选”跳过玩家选择。
	# 首次触发清空 target_id 强制选；resume 注入后 _effect_target_selected 标志避免重跑再清（死循环）。
	# （里昂战后逼迫 pilot_006_effect_03：攻击结算后选5格内其他机甲，不沿用本次攻击目标）
	if not bool(payload.get("_effect_target_selected", false)) and _effect_has_force_select(effect):
		payload["_attack_target_id_backup"] = payload.get("target_id", &"")
		payload["target_id"] = &""

	# 琳 RE 维修窗口：窗口激活且维修来源是琳时，锁定目标为请求方（无视距离，跳过目标选择）。
	# 目标注入本效果 payload（record 副本），CHOOSE_ONE 分支 mech_ids 自动取请求方。
	# _pilot_024_window_locked 标志随 payload 存 _seq，分支挂起续跑完成后据此关闭窗口。
	if effect.effect_id == &"repair_direct" and context != null and context.game_state != null:
		var p24_lock_bind = _make_binding_from_effect(effect, action, payload)
		var p24_lock_mid: StringName = p24_lock_bind.get_source_mech_id() if p24_lock_bind != null else &""
		if p24_lock_mid != &"":
			var p24_lock_req: StringName = _ActionPilotEffects.pilot_024_window_requester_for(context.game_state, p24_lock_mid)
			if p24_lock_req != &"":
				payload["target_id"] = p24_lock_req
				payload["_pilot_024_window_locked"] = true

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
	# _optional_discard_paid=true 时跳过：费用已在 response_discard/optional 弃牌 resume 阶段支付
	# （迪恩转化弃2张移 temp_zone），CHOOSE_ONE 等挂起 resume 重跑本函数时若重查 can_pay，
	# 会因弃牌后手牌不足而误判失败——迪恩必耗 cost 还会进而取消父攻击动作。
	if not (payload.get("_optional_discard_paid", false) or _check_costs(effect, payload, action)):
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
	# FOR_EACH_TARGET 子动作挂起场景：_run_flat_inline 设了 waiting_effect_action + _seq，
	# 等 _after_sub_action_finished -> _continue_seq_effect_actions 续跑（pilot_012 e1 偷牌后减动力）。
	if action.state == &"waiting_effect_action":
		return
	if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
		return

	# 标记每回合1次使用（机动头部/狙击右臂等 once_per_turn_key 效果）
	_mark_once_per_turn_used(effect, payload)
	# 标记每局1次使用（once_per_game_key 效果，如 pilot_033 弃2装抽高级 本局1次）
	_mark_once_per_game_used(effect, payload)

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


## 效果 target_rules 是否含 force_select（效果自己选目标，不复用 attack 被攻击目标）
## 用于 LISTEN effect（如里昂战后逼迫）触发时清空 payload.target_id 强制玩家选机甲
func _effect_has_force_select(effect: ActionEffect) -> bool:
	for r in effect.target_rules:
		if r is Dictionary and bool(r.get("force_select", false)):
			return true
	return false


## 请求玩家选择目标
func _request_target_selection(effect: ActionEffect, payload: Dictionary, action) -> void:
	# 选目标前确认：confirm_before_target 效果（如里昂战后逼迫）先弹"是否发动"确认窗，
	# 确认（或 AI 自动确认）后才进入目标选择。确认标记写 payload._effect_confirmed。
	if effect.confirm_before_target and not bool(payload.get("_effect_confirmed", false)):
		var cbt_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		var cbt_pid: StringName = cbt_bind.get("player_id", &"")
		var cbt_mid: StringName = cbt_bind.get("mech_id", &"")
		if _is_ai_owner(cbt_pid, cbt_mid):
			payload["_effect_confirmed"] = true
		else:
			_prompt_confirm_before_target(effect, payload, action)
			return
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
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "pre_actions_target"}

	# 通知 ActionUIBridge 弹目标选择 UI，同时标记动作暂停（waiting_timing 与 ActionEngine 兼容）
	# input_type 用 select_repair_target / select_mech_target，与 ActionUIBridge 已注册的弹窗分支对齐。
	var bridge_input_type: StringName = &"select_mech_target"
	if rule_name == "repair_target_select":
		bridge_input_type = &"select_repair_target"
	elif rule_name == "weapon_charge_select":
		bridge_input_type = &"select_weapon_for_charge"
	# 源机甲（用于 UI 排除"自己"）：机师/装备 permanent listener 的来源机甲在
	# binding_context.mech_id（payload 顶层无 source_mech_id/mech_id），须优先取；
	# 否则回退到 action.source.mech_id（=轮次开始玩家 turn_order[0] 的机甲），
	# 3人PvP下里昂 ROUND_START 标记会排除错误机甲、候选列表反而能选自己。
	var _src_bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var src_mech_id: StringName = _src_bind_ctx.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	if src_mech_id == &"" and action.source is Dictionary:
		src_mech_id = action.source.get("mech_id", action.source.get("source_mech_id", &""))
	# 通用目标选择合法候选计算（塔妮拉 p087 等带范围/阵营过滤的效果）：之前只发 mech_id，
	# app_root 无 valid_mech_ids 时高亮全部非自身机甲，范围限制失效（3格外也能点，点了被
	# TargetChecker 拒后反复重弹）。按 target_rules 组合算出合法集合；算不出（变量范围取不到）
	# 返回空数组，UI 回退当前"高亮全部非自身"行为，不误伤合法目标。
	var valid_mech_ids: Array = []
	if rule_name == "mech_target_select":
		valid_mech_ids = _compute_mech_target_valid_ids(effect, payload, src_mech_id)
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, bridge_input_type, {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"rule": rule_name,
		"mech_id": src_mech_id,
		"valid_mech_ids": valid_mech_ids,
		"card_instance_id": payload.get("card_instance_id", &""),
		"player_id": _effect_popup_owner_pid(effect, payload, action),
	})
	SLog.log_raw("[TIMING] %s 挂起目标选择 effect=%s rule=%s valid=%d" % [String(action.action_id), String(effect.effect_id), rule_name, valid_mech_ids.size()])


## 按 target_rules 计算合法目标机甲集合（通用，塔妮拉 p087 等带范围/阵营过滤的效果）。
## 组合规则：CHOOSE_OTHER_MECH（排除自身）/ CHOOSE_ENEMY_MECH（同阵营排除）/
## TARGET_IN_RANGE（range 上限）/ CHOOSE_ENEMY_MECH_IN_RANGE / CHOOSE_MECH_IN_VARIABLE_RANGE。
## 无法精确计算的约束（变量范围取不到 payload 变量）跳过该约束而不是排除，保证合法目标不被误删。
## 返回空数组 = UI 回退"高亮全部非自身"（当前行为，无回归）。
func _compute_mech_target_valid_ids(effect, payload: Dictionary, src_mech_id: StringName) -> Array:
	var result: Array = []
	if context == null or context.game_state == null or effect == null or src_mech_id == &"":
		return result
	var gs = context.game_state
	var src_mech = gs.mechs.get(src_mech_id)
	if src_mech == null or src_mech.destroyed:
		return result
	var owner_pid: StringName = src_mech.owner_player_id
	var need_enemy: bool = false
	var has_range: bool = false
	var max_range: int = 0
	var range_unsafe: bool = false  # 变量范围读不到 -> 跳过范围约束
	for rule in effect.target_rules:
		if not (rule is Dictionary):
			continue
		var rn: String = String(rule.get("rule", &""))
		if rn == &"CHOOSE_OTHER_MECH":
			pass
		elif rn == &"CHOOSE_ENEMY_MECH":
			need_enemy = true
		elif rn == &"CHOOSE_ENEMY_MECH_IN_RANGE":
			need_enemy = true
			has_range = true
			max_range = max(max_range, int(rule.get("range", 5)))
		elif rn == &"TARGET_IN_RANGE":
			var rp: Dictionary = rule.get("params", rule)
			has_range = true
			max_range = max(max_range, int(rp.get("range", rule.get("range", 1))))
		elif rn == &"CHOOSE_MECH_IN_VARIABLE_RANGE":
			has_range = true
			var v_base: int = int(rule.get("base_range", 4))
			var v_name: StringName = rule.get("variable_name", &"")
			if v_name != &"":
				var v_key: String = "%s_%s_%s" % [String(owner_pid), String(src_mech_id), String(v_name)]
				if payload.has("variable_%s" % v_key):
					max_range = max(max_range, v_base + int(payload.get("variable_%s" % v_key, 0)))
				else:
					range_unsafe = true
			else:
				max_range = max(max_range, v_base)
	if range_unsafe:
		has_range = false  # 变量范围无法精确计算：只按阵营/自身过滤，不过滤范围
	for mid: StringName in gs.mechs:
		if mid == src_mech_id:
			continue
		var m = gs.mechs.get(mid)
		if m == null or m.destroyed:
			continue
		if need_enemy and String(m.owner_player_id) == String(owner_pid):
			continue
		if has_range and int(_HexGrid.distance(src_mech.position, m.position)) > max_range:
			continue
		result.append(mid)
	return result


## 弹"是否发动"确认窗（choose_one_effect 弹窗），确认后进入目标选择；取消=效果不发动。
## 通用 confirm_before_target 机制：显示效果说明，单选项"发动"+取消。
func _prompt_confirm_before_target(effect: ActionEffect, payload: Dictionary, action) -> void:
	var cbt_label: String = effect.confirm_label
	if cbt_label == "":
		cbt_label = "发动%s" % String(effect.display_name)
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"confirm_before_target"}
	action.record["_waiting_for_confirm_before_target"] = true
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": cbt_label, "effect_id": &"option_0", "option_index": 0},
		],
		"optional": true,
		"player_id": _effect_popup_owner_pid(effect, payload, action),
		"source_label": String(effect.description),
	})
	SLog.log_raw("[TIMING] %s 挂起选目标前确认 effect=%s" % [String(action.action_id), String(effect.effect_id)])


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


## 解析机甲ID表达式（$payload.xxx / $binding_context.xxx / $current_target.xxx / 字面值）。
## 供 CHOOSE_ONE chooser_mech_id 等 param 表达式解析用（pilot_006 e3 被选机甲作选择者；
## pilot_040 泰格 FOR_EACH_TARGET 逐目标时取 current_target.mech_id 作弃装解锁选择者）。
func _resolve_mech_id_expr(expr: String, payload: Dictionary) -> StringName:
	if expr.begins_with("$payload."):
		return payload.get(expr.substr(9), &"")
	if expr.begins_with("$binding_context."):
		var _bc: Dictionary = payload.get("binding_context", {})
		return _bc.get(expr.substr(17), &"")
	if expr.begins_with("$current_target."):
		var _ct: Dictionary = payload.get("current_target", {})
		return _ct.get(expr.substr(16), &"")
	return StringName(expr)


## pilot_016 默多克展示转化（CHOOSE_ONE 确认后分支内执行）。返回 true=已挂起弹窗。
## 阶段1：展示牌A给其他玩家（复用美杜莎 pilot_009_show_display 非阻塞浮窗；
##   target_id=默多克机甲=牌A持有者，除其拥有者外全显示）。
## 阶段2：选2张B/C（排除牌A）选牌窗（阻塞，phase=pilot_016_choose_two）。
## 候选不足2张 -> 返回 false（不转化，回父正常用牌A）。
## resume(phase=pilot_016_choose_two)：B/C 都移入临时区（B 由父 card_to_temp_zone 移入并当牌A
##   virtual_transform，C 写 record.temp_zone_card_ids 由父 settle 弃置）+
##   改造父record(B当牌A virtual_transform) + 清空剩余 listener（避免旧 payload 误触发阿克罗姆01a 等）+
##   mark once_per_turn。
## 牌A保留手牌；父 execute_effects 执行牌A的 DIRECT 效果（"调用执行A的效果"）；父 settle 弃B和C。
func _handle_pilot_016_show_and_convert(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	# 重跑幂等：已转化则跳过（resume 推进父动作后不再触发）
	if payload.has("pilot_016_converted"):
		return false
	var bind: Dictionary = payload.get("binding_context", {})
	var p016_pid: StringName = bind.get("player_id", payload.get("player_id", &""))
	var p016_mech_id: StringName = bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	var p016_card_a_id: StringName = payload.get("card_instance_id", &"")  # 牌A（当前要用的实体牌）
	var p016_card_a_def: StringName = payload.get("card_def_id", &"")  # 牌A def_id
	# fallback：validate_card 未写 card_def_id 时从牌实例查 def_id
	if p016_card_a_def == &"" and p016_card_a_id != &"" and context.game_state != null:
		var p016_ca_def_card = context.game_state.get_card(p016_card_a_id)
		if p016_ca_def_card != null and p016_ca_def_card.def != null:
			p016_card_a_def = p016_ca_def_card.def.card_id
	if context == null or context.game_state == null or p016_pid == &"":
		return false
	# 收集候选 B/C（手牌行动牌，排除牌A）
	var p016_candidates: Array = []
	var p016_player = context.game_state.players.get(p016_pid)
	if p016_player == null:
		return false
	for p016_cid: StringName in p016_player.action_hand:
		if p016_cid == p016_card_a_id:
			continue  # 排除牌A
		var p016_c = context.game_state.get_card(p016_cid)
		if p016_c != null and p016_c.def != null and p016_c.def.card_kind == &"action":
			p016_candidates.append(p016_cid)
	if p016_candidates.size() < 2:
		SLog.log_raw("[TIMING] %s pilot_016 候选牌不足2张，中止转化 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false  # 不转化，回父正常用牌A
	# 阶段1：展示牌A给其他玩家（非阻塞浮窗，复用美杜莎展示框）
	var p016_display_cards: Array = []
	if p016_card_a_id != &"":
		var p016_ca = context.game_state.get_card(p016_card_a_id)
		if p016_ca != null and p016_ca.def != null:
			p016_display_cards.append({"card_id": p016_card_a_id, "name": String(p016_ca.def.display_name), "type": String(p016_ca.def.action_type)})
	action_needs_input.emit(action.action_id, &"pilot_009_show_display", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"target_id": p016_mech_id,
		"display_cards": p016_display_cards,
		"player_id": p016_pid,
		"source_label": "默多克·展示转化：展示的行动牌",
	})
	# 阶段2：选2张B/C（阻塞，候选已排除牌A；exclude_card_ids 让面板再保险排除牌A）
	_pending_effect[action.action_id] = {
		"action": action, "effect": effect, "payload": payload,
		"phase": &"pilot_016_choose_two",
		"card_a_id": p016_card_a_id, "card_a_def": p016_card_a_def,
		"mech_id": p016_mech_id, "player_id": p016_pid,
	}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_discard_cards", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"executor": p016_pid,
		"discard_player_id": p016_pid,
		"count": 2,
		"face_up": true,
		"action_verb": &"select",
		"no_cancel": true,
		"player_id": p016_pid,
		"exclude_card_ids": [p016_card_a_id],
		"source_label": "默多克·展示转化：选择2张行动牌当作展示牌使用",
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_016 选2张转化牌 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p016_candidates.size()])
	return true


## pilot_006 e3 战后逼迫：被选机甲选1张攻击牌 use_action_card（passive，不计攻击数）。
## 选牌取消/无牌可打 -> 回落4伤害。返回 true=已挂起弹窗。
# ════════════════════════════════════════════════════════════
# pilot_027 维罗妮卡
# ════════════════════════════════════════════════════════════
## 效果1（获金分半·被动）：4+X格内其他机甲获得非我方给予金币时，我方获一半（向下取整，剩留给目标）。
## 直接增减双方玩家金币字段（不走 gain_gold，避免维罗妮卡获金再 fire 时点 -> 递归再分半）。
## 全部判定（gainer≠自己 / from≠自己 / 距离≤4+X / amount>0 / split>0）在此做，不满足静默跳过。
## 返回 false（同步完成），_execute_effect 末尾自动 mark once_per_turn（效果1无 key 无影响）。
func _handle_pilot_027_split_gold(_act: Dictionary, _effect: ActionEffect, payload: Dictionary, _action) -> bool:
	if context == null or context.game_state == null:
		return false
	var p27_gainer_pid: StringName = payload.get("gainer_player_id", &"")
	var p27_gainer_mid: StringName = payload.get("gainer_mech_id", &"")
	var p27_amount: int = int(payload.get("amount", 0))
	var p27_from_pid: StringName = payload.get("from_player_id", &"")
	if p27_gainer_pid == &"" or p27_amount <= 0:
		return false
	var p27_bind: Dictionary = payload.get("binding_context", {})
	var p27_v_mid: StringName = p27_bind.get("mech_id", &"")
	var p27_v_pid: StringName = p27_bind.get("player_id", &"")
	if p27_v_mid == &"":
		return false
	# 其他机甲获金 + 非我方给予
	if p27_gainer_mid == p27_v_mid or p27_from_pid == p27_v_pid:
		return false
	var p27_v_mech = context.game_state.mechs.get(p27_v_mid)
	var p27_g_mech = context.game_state.mechs.get(p27_gainer_mid)
	if p27_v_mech == null or p27_g_mech == null or p27_g_mech.destroyed:
		return false
	# 距离 ≤ 4+X
	var p27_x: int = _ActionPilotEffects.get_pilot_027_x(_ActionPilotEffects.pilot_027_pilot_card(context.game_state))
	if int(_HexGrid.distance(p27_g_mech.position, p27_v_mech.position)) > 4 + p27_x:
		return false
	var p27_split: int = int(floor(p27_amount / 2.0))
	if p27_split <= 0:
		return false
	var p27_g_player = context.game_state.players.get(p27_gainer_pid)
	var p27_v_player = context.game_state.players.get(p27_v_pid)
	if p27_g_player == null or p27_v_player == null:
		return false
	p27_g_player.gold = maxi(0, p27_g_player.gold - p27_split)
	p27_v_player.gold = p27_v_player.gold + p27_split
	# 专用日志类型 gold_split（battle_message_log 友好渲染），避免 gold_gained 缺 current_gold 显示0 + 英文 reason
	context.game_state.write_log(&"gold_split", {
		"player_id": String(p27_v_pid),
		"gainer_player_id": String(p27_gainer_pid),
		"amount": p27_split,
		"total": p27_amount,
	})
	SLog.log_raw("[TIMING] pilot_027 获金分半：%s 获%d金，维罗妮卡分走%d（剩%d）" % [String(p27_gainer_mid), p27_amount, p27_split, p27_g_player.gold])
	return false


## 效果2（给予金币X+1·被动）：我方给予其他机甲金币时 X+1（每回合1次由 once_per_turn_key 管理）。
## 条件 giver==自己 在此判定；X 写维罗妮卡机师牌实例 counters（换机师不转移）。
## 返回 false（同步），_execute_effect 末尾自动 mark once_per_turn。
func _handle_pilot_027_x_inc(_act: Dictionary, _effect: ActionEffect, payload: Dictionary, _action) -> bool:
	if context == null or context.game_state == null:
		return false
	var p27_giver_pid: StringName = payload.get("giver_player_id", payload.get("from_player_id", &""))
	var p27_bind: Dictionary = payload.get("binding_context", {})
	var p27_v_mid: StringName = p27_bind.get("mech_id", &"")
	var p27_v_pid: StringName = p27_bind.get("player_id", &"")
	if p27_giver_pid == &"" or p27_giver_pid != p27_v_pid or p27_v_mid == &"":
		return false
	var p27_card = _ActionPilotEffects.pilot_027_pilot_card(context.game_state)
	if p27_card == null:
		return false
	_ActionPilotEffects.set_pilot_027_x(p27_card, _ActionPilotEffects.get_pilot_027_x(p27_card) + 1)
	SLog.log_raw("[TIMING] pilot_027 给予金币X+1：%s 给予后 X=%d" % [String(p27_v_mid), _ActionPilotEffects.get_pilot_027_x(p27_card)])
	return false


## 效果3（给予金币并使用行动牌·主动，每回合2次）多阶段状态机：
##   阶段① select_mech_target 选 4+X 范围内其他机甲（取消=中止，不消耗次数）
##   阶段② choose_integer stepper 输给金金额（2~当前金币，步长5，可取消=中止，不消耗次数）
##   阶段③ 给金：spend_gold(自己)+gain_gold(目标, from=自己) -> 触发 GIVE_GOLD_AFTER 效果2 X+1。
##          给金完成即 mark once_per_turn（每回合2次用掉1次）；②取消不消耗。
##   阶段④ 目标有可用行动牌（攻击+辅助，排除迎击）才弹 choose_one 询问是否立即使用（可取消=结束）
##   阶段⑤ 是：select_pilot_006_attack_card 目标选1张（确认即 use_action_card 被动使用；取消兜底=结束）
## 返回 true=已挂起（等输入），false=无需处理（无目标/AI/已结束）交由调用方继续。
func _handle_pilot_027_gift_and_use(_act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var p27_bind: Dictionary = payload.get("binding_context", {})
	var p27_v_pid: StringName = p27_bind.get("player_id", &"")
	var p27_v_mid: StringName = p27_bind.get("mech_id", &"")
	if p27_v_mid == &"":
		return false
	# AI：暂跳过（先 PvP 人类）
	if _is_ai_owner(p27_v_pid, p27_v_mid):
		SLog.log_raw("[TIMING] pilot_027 效果3：维罗妮卡为 AI，跳过 effect=%s" % String(effect.effect_id))
		return false
	# 收集 4+X 范围内其他存活机甲
	var p27_src = context.game_state.mechs.get(p27_v_mid)
	if p27_src == null or p27_src.destroyed:
		return false
	var p27_x: int = _ActionPilotEffects.get_pilot_027_x(_ActionPilotEffects.pilot_027_pilot_card(context.game_state))
	var p27_range: int = 4 + p27_x
	var p27_candidates: Array[StringName] = []
	for p27_mid in context.game_state.mechs:
		if p27_mid == p27_v_mid:
			continue
		var p27_m = context.game_state.mechs.get(p27_mid)
		if p27_m == null or p27_m.destroyed:
			continue
		if int(_HexGrid.distance(p27_m.position, p27_src.position)) <= p27_range:
			p27_candidates.append(p27_mid)
	if p27_candidates.is_empty():
		return false
	# 阶段① 选目标
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
		"phase": &"pilot_027_target_select", "pilot_027_owner_mid": p27_v_mid, "pilot_027_owner_pid": p27_v_pid}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_mech_target", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"mech_id": p27_v_mid,
		"player_id": p27_v_pid,
		"valid_mech_ids": p27_candidates,
		"label": "维罗妮卡：选择给予金币的机甲（%d格内）" % p27_range,
	})
	SLog.log_raw("[TIMING] %s pilot_027 效果3选目标 candidates=%d" % [String(action.action_id), p27_candidates.size()])
	return true


## 效果3 给金动作：维罗妮卡扣 amount，目标获 amount（from_player_id 传递触发 GIVE_GOLD_AFTER 效果2 X+1）。
## 目标获金触发 GAIN_GOLD_AFTER 但 from==自己 -> 效果1「非我方给予」条件不满足跳过（天然互斥）。
func _pilot_027_give_gold(v_pid: StringName, target_mech: StringName, amount: int) -> void:
	if context == null or context.game_actions == null or context.game_state == null:
		return
	if amount <= 0:
		return
	var p27_target_player = context.game_state.get_player_for_mech(target_mech)
	if p27_target_player == null:
		return
	# 先扣自己（stepper max=当前金币，必然够）
	context.game_actions.spend_gold({"player_id": v_pid, "amount": amount, "reason": &"PILOT_027_GIFT"})
	context.game_actions.gain_gold({"player_id": p27_target_player.player_id, "amount": amount,
		"from_player_id": v_pid, "reason": &"PILOT_027_GIFT"})


## 目标机甲可用行动牌（攻击+辅助，排除迎击）。
## 攻击牌：该机甲武器射程内存在其他存活机甲（被动攻击可打，不预判目标选择）。取最大武器射程。
## 辅助牌：目标手牌 action_type=辅助 均列入（宽松；实际使用由 use_action_card 校验条件/目标）。
func _pilot_027_usable_action_cards(target_mech: StringName) -> Array:
	if context == null or context.game_state == null:
		return []
	var p27_player = context.game_state.get_player_for_mech(target_mech)
	if p27_player == null:
		return []
	var p27_mech = context.game_state.mechs.get(target_mech)
	var p27_has_attack_target: bool = false
	if p27_mech != null and not p27_mech.destroyed:
		var p27_range: int = _pilot_027_mech_attack_range(p27_mech)
		p27_has_attack_target = p27_range > 0 and _pilot_027_mech_has_target_in_range(p27_mech, p27_range)
	var p27_result: Array = []
	for p27_cid in p27_player.action_hand:
		var p27_card = context.game_state.get_card(p27_cid)
		if p27_card == null or p27_card.def == null:
			continue
		var p27_at: StringName = p27_card.def.action_type
		if p27_at == &"攻击":
			if p27_has_attack_target:
				p27_result.append(p27_cid)
		elif p27_at == &"辅助":
			p27_result.append(p27_cid)
		# 迎击（counter）排除
	return p27_result


## 机甲最大武器射程（装备武器 range_value + 基础武器 range_value）。无武器返回0。
func _pilot_027_mech_attack_range(mech) -> int:
	var max_range: int = 0
	if mech == null or mech.slots == null:
		return 0
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		var def = slot.equipped_card.def
		# 守卫：机师槽的 PilotCardDef 无 equipment_kind 字段（跨文件 extends 子类手动复制字段），
		# 直接访问会运行期报错中断 resume（维罗妮卡027 给金后冻结根因）。只统计装备武器牌。
		if "equipment_kind" in def and def.equipment_kind == &"WEAPON":
			max_range = maxi(max_range, int(def.range_value))
	if mech.base_weapons != null:
		for bw in mech.base_weapons:
			if bw is Dictionary:
				max_range = maxi(max_range, int(bw.get("range_value", 0)))
	return max_range


## 机甲在射程内是否有其他存活目标（攻击牌可用预判；被动攻击可打任意存活机甲）。
func _pilot_027_mech_has_target_in_range(mech, range: int) -> bool:
	if context == null or context.game_state == null or mech == null:
		return false
	for p27_mid in context.game_state.mechs:
		var p27_other = context.game_state.mechs.get(p27_mid)
		if p27_other == null or p27_other.destroyed:
			continue
		if p27_other == mech:
			continue
		if int(_HexGrid.distance(p27_other.position, mech.position)) <= range:
			return true
	return false


## 目标是否仍在维罗妮卡 4+X 范围内（resume 时复查，防止目标移动/摧毁）。
func _pilot_027_target_in_range(owner_mid: StringName, target_mid: StringName) -> bool:
	if context == null or context.game_state == null:
		return false
	var p27_owner = context.game_state.mechs.get(owner_mid)
	var p27_target = context.game_state.mechs.get(target_mid)
	if p27_owner == null or p27_target == null or p27_target.destroyed:
		return false
	var p27_x: int = _ActionPilotEffects.get_pilot_027_x(_ActionPilotEffects.pilot_027_pilot_card(context.game_state))
	return int(_HexGrid.distance(p27_target.position, p27_owner.position)) <= 4 + p27_x


# ════════════════════════════════════════════════════════════
# pilot_028 乌尔：宣言 / 需交牌 / X+1
# ════════════════════════════════════════════════════════════
## 弹乌尔宣言展示浮窗（非阻塞，给所有玩家，含乌尔自己）。宣言类型从机师牌实例读。
func _show_pilot_028_declared(p28_card, action, owner_pid: StringName) -> void:
	if p28_card == null or action == null:
		return
	var declared: String = _ActionPilotEffects.get_pilot_028_declared(p28_card)
	action_needs_input.emit(action.action_id, &"pilot_028_show_declared", {
		"action_id": action.action_id,
		"declared_type": declared,
		"player_id": owner_pid,
		"source_label": "乌尔宣言",
	})


## PILOT_028_DECLARE：乌尔效果1 宣言。每轮 ROUND_START 触发。
## 首次：重置本轮宣言（清类型 + X=0），弹三选一（攻击/迎击/辅助，可取消=本轮无宣言）。
## AI 拥有者自动宣言"攻击"（暂不做 AI 决策）。返回 true=已挂起等输入；false=已同步处理/重入。
func _handle_pilot_028_declare(_act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	# 重入守卫：声明流程已挂起过，不二次弹窗
	if action.record.get("_p028_declare_shown", false):
		return false
	var p28_card = _ActionPilotEffects.pilot_028_pilot_card(context.game_state)
	if p28_card == null:
		return false
	var p28_bind: Dictionary = payload.get("binding_context", {})
	var p28_owner_pid: StringName = p28_bind.get("player_id", &"")
	var p28_owner_mid: StringName = p28_bind.get("mech_id", &"")
	if p28_owner_pid == &"":
		return false
	# 新轮开始：重置本轮宣言（无论是否宣言，旧类型/旧X作废）
	_ActionPilotEffects.set_pilot_028_declared(p28_card, "")
	_ActionPilotEffects.set_pilot_028_x(p28_card, 0)
	if _is_ai_owner(p28_owner_pid, p28_owner_mid):
		_ActionPilotEffects.set_pilot_028_declared(p28_card, "攻击")
		_show_pilot_028_declared(p28_card, action, p28_owner_pid)
		SLog.log_raw("[TIMING] %s pilot_028 AI 拥有者自动宣言=攻击 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	action.record["_p028_declare_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_028_declare"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": "攻击", "effect_id": &"option_0", "option_index": 0, "declared_type": &"攻击"},
			{"label": "迎击", "effect_id": &"option_1", "option_index": 1, "declared_type": &"迎击"},
			{"label": "辅助", "effect_id": &"option_2", "option_index": 2, "declared_type": &"辅助"},
		],
		"optional": true,
		"player_id": p28_owner_pid,
		"source_label": "乌尔：宣言本轮行动牌类型（取消=本轮无宣言，效果2/3失效）",
	})
	SLog.log_raw("[TIMING] %s 挂起乌尔宣言 effect=%s 拥有者=%s" % [String(action.action_id), String(effect.effect_id), String(p28_owner_pid)])
	return true


## PILOT_028_X_INC：乌尔效果3 X+1。USE_ACTION_AT 触发，每回合1次（机师牌实例计数器手动管理）。
## 条件：已宣言 + 乌尔自己使用 + 实体牌 + 宣言类型牌。满足才 X+1 并标记本回合已用。
## 返回 false（同步）。
func _handle_pilot_028_x_inc(_act: Dictionary, _effect: ActionEffect, payload: Dictionary, _action) -> bool:
	if context == null or context.game_state == null:
		return false
	var p28_card = _ActionPilotEffects.pilot_028_pilot_card(context.game_state)
	if p28_card == null:
		return false
	var declared: String = _ActionPilotEffects.get_pilot_028_declared(p28_card)
	if declared == "":
		return false
	var turn_id: int = _current_turn_number()
	if _ActionPilotEffects.pilot_028_xinc_used_this_turn(p28_card, turn_id):
		return false
	# 乌尔自己使用
	var p28_w_mid: StringName = _ActionPilotEffects.pilot_028_find_w_mech(context.game_state)
	var use_mech: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
	if use_mech == &"" or use_mech != p28_w_mid:
		return false
	# 实体牌（转化虚拟不算）
	if bool(payload.get("virtual_transform", false)):
		return false
	# 宣言类型牌
	var card_id: StringName = payload.get("card_instance_id", &"")
	var card = context.game_state.get_card(card_id) if card_id != &"" else null
	if card == null or card.def == null:
		return false
	var card_type: String = String(card.def.action_type) if "action_type" in card.def else ""
	if card_type != declared:
		return false
	_ActionPilotEffects.set_pilot_028_x(p28_card, _ActionPilotEffects.get_pilot_028_x(p28_card) + 1)
	_ActionPilotEffects.pilot_028_mark_xinc_used(p28_card, turn_id)
	SLog.log_raw("[TIMING] pilot_028 X+1：%s 使用宣言[%s]牌后 X=%d" % [String(p28_w_mid), declared, _ActionPilotEffects.get_pilot_028_x(p28_card)])
	return false


## PILOT_058_SHOW_COUNT_BONUS：卡米拉效果1 展示牌型加成（同步结算，不挂起）。
## 由效果动作链在 ATTACK_PRE 确认后调用。流程：
##   ① 收集 binding_context 所属玩家 action_hand 所有行动牌；
##   ② 统计不同 action_type（攻击/迎击/辅助）的类型数（1~3）；
##   ③ 给其他玩家弹非阻塞展示浮窗（自己不看自己的牌——参考美杜莎 p009 显示对象）；
##   ④ 本次攻击威力 += 类型数×might_per_type（写父动作 record extra_might）；
##   ⑤ 若类型数 >= required_type_count，本次攻击范围 += range_bonus（写 extra_range）。
## 通用可复用：数值/文案由 params 决定，效果绑定 effect 而非机师，复用=复制定义+改 params。
## 返回 false（同步）。
func _handle_pilot_058_show_count_bonus(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null or action == null:
		return false
	var p58_params: Dictionary = act.get("params", {})
	var p58_might_per_type: int = int(p58_params.get("might_per_type", 2))
	var p58_range_bonus: int = int(p58_params.get("range_bonus", 2))
	var p58_required_types: int = int(p58_params.get("required_type_count", 3))
	var p58_label: String = String(p58_params.get("source_label", "展示行动牌"))
	var p58_bind: Dictionary = payload.get("binding_context", {})
	var p58_owner_pid: StringName = p58_bind.get("player_id", &"")
	var p58_owner_mid: StringName = p58_bind.get("mech_id", &"")
	if p58_owner_pid == &"" or p58_owner_mid == &"":
		return false
	if not context.game_state.players.has(p58_owner_pid):
		return false
	var p58_player = context.game_state.players[p58_owner_pid]
	if p58_player == null:
		return false
	# ① 收集所有行动牌 + ② 统计类型数
	var p58_cards: Array = []
	var p58_types := {}
	for p58_cid: StringName in p58_player.action_hand:
		var p58_c = context.game_state.get_card(p58_cid)
		if p58_c == null or p58_c.def == null:
			continue
		var p58_type: String = String(p58_c.def.action_type) if "action_type" in p58_c.def else ""
		if p58_type != "":
			p58_types[p58_type] = true
		p58_cards.append({"name": String(p58_c.def.display_name), "type": p58_type})
	var p58_type_count: int = p58_types.size()
	# ③ 展示浮窗：只给其他玩家（自己不看自己的牌），非阻塞
	action_needs_input.emit(action.action_id, &"pilot_058_show_display", {
		"action_id": action.action_id,
		"owner_mech_id": p58_owner_mid,
		"display_cards": p58_cards,
		"player_id": p58_owner_pid,
		"source_label": p58_label,
	})
	# ④⑤ 加成：威力 += 类型数×might_per_type；类型数达标则范围 += range_bonus
	action.record["extra_might"] = int(action.record.get("extra_might", 0)) + p58_type_count * p58_might_per_type
	var p58_range_added: int = 0
	if p58_type_count >= p58_required_types:
		action.record["extra_range"] = int(action.record.get("extra_range", 0)) + p58_range_bonus
		p58_range_added = p58_range_bonus
	SLog.log_raw("[TIMING] %s pilot_058 展示牌型：类型数=%d 威力+%d 范围+%d 展示牌=%d effect=%s" % [String(action.action_id), p58_type_count, p58_type_count * p58_might_per_type, p58_range_added, p58_cards.size(), String(effect.effect_id)])
	return false


## ═══════════════════════════════════════════
## 通用「随机查看其他机甲行动牌+类型加成」模块（VIEW_RANDOM_OTHER_HAND_CARDS，骇客 pilot_066）。
## ═══════════════════════════════════════════
## LISTEN 监听 BASIC_MOVE_AFTER 等时点触发：我方回合内我方机甲基础移动后，若范围内存在持行动牌
## 的其他机甲（条件 OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE 已 gating），直接弹目标选择
## （常规目标UI + valid_mech_ids 高亮，仅可选范围内持牌机甲；取消不消耗次数）。
## 选定后（resume 注入 target 重跑本 effect）：随机查看目标 player 的 view_count 张行动牌
## （context.synced_shuffle 保证 PvP 双端同步；不足 view_count 看全部，0 张也弹空窗并结算加成）
## → 非阻塞浮窗只给骇客玩家本人看 → 类型加成（各计一次可叠加）：含"攻击" -> MODIFY_ATTACK_COUNT
## 本回合+attack_bonus；含"迎击" -> MODIFY_ACTION_HAND_LIMIT 本回合+action_hand_bonus；含"辅助"
## -> RESTORE_POWER +support_power。确认选目标才 MARK_EFFECT_ONCE_PER_TURN_USED（取消不计次）。
## params: range / view_count / attack_bonus / action_hand_bonus / support_power /
##         once_per_turn_key / store_target_key / source_label。复用=整段复制改参数即可。
func _handle_view_random_other_hand(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null or action == null:
		return false
	var v_params: Dictionary = act.get("params", {})
	var v_bind: Dictionary = payload.get("binding_context", {})
	var v_owner_mid: StringName = v_bind.get("mech_id", &"")
	var v_owner_pid: StringName = v_bind.get("player_id", &"")
	if v_owner_mid == &"":
		return false
	var v_store_key: String = String(v_params.get("store_target_key", &"pilot_066_target_id"))
	# 重跑幂等：目标已选定（resume 注入）-> 直接执行查看+加成，不再弹目标选择
	if payload.get(v_store_key, &"") != &"":
		_apply_view_random_other_hand_bonuses(act, effect, payload, action)
		return false
	# AI 持有者：暂不支持（PvP/PvP3 人类玩家优先）
	if _is_ai_owner(v_owner_pid, v_owner_mid):
		return false
	# 计算候选：范围内其他存活机甲 + 其玩家 action_hand 非空
	var v_range: int = int(v_params.get("range", 3))
	var v_mech = context.game_state.mechs.get(v_owner_mid)
	if v_mech == null or v_mech.destroyed:
		return false
	var v_candidates: Array = []
	for v_mid: StringName in context.game_state.mechs:
		if v_mid == v_owner_mid:
			continue
		var v_m = context.game_state.mechs[v_mid]
		if v_m == null or v_m.destroyed:
			continue
		if _HexGrid.distance(v_mech.position, v_m.position) > v_range:
			continue
		var v_owner: StringName = v_m.owner_player_id
		var v_player = context.game_state.players.get(v_owner) if v_owner != &"" else null
		if v_player != null and not v_player.action_hand.is_empty():
			v_candidates.append(v_mid)
	if v_candidates.is_empty():
		return false  # 无候选（条件已 gating，防御）
	# 挂起目标选择（常规目标UI，valid_mech_ids 高亮；chooser=骇客玩家本人）
	action.record["_waiting_for_target"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"view_random_other_hand_target", "view_params": v_params}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_mech_target", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"rule": &"mech_target_select",
		"mech_id": v_owner_mid,
		"valid_mech_ids": v_candidates,
		"player_id": v_owner_pid,
		"source_label": String(v_params.get("source_label", "选择1台%d格内持有行动牌的其他机甲" % v_range)),
	})
	SLog.log_raw("[TIMING] %s 挂起骇客窥牌选目标（候选%d台 范围%d）effect=%s" % [String(action.action_id), v_candidates.size(), v_range, String(effect.effect_id)])
	return true


## 骇客窥牌选定目标后：随机查看目标行动牌 + 展示浮窗 + 类型加成（确认才 MARK 计次）。
## 所有随机经 context.synced_shuffle（PvP 锁步双端同种子同步）。
func _apply_view_random_other_hand_bonuses(act: Dictionary, effect, payload: Dictionary, action) -> void:
	if context == null or context.game_state == null:
		return
	var v_params: Dictionary = act.get("params", {})
	var v_bind: Dictionary = payload.get("binding_context", {})
	var v_owner_mid: StringName = v_bind.get("mech_id", &"")
	var v_owner_pid: StringName = v_bind.get("player_id", &"")
	if v_owner_mid == &"":
		return
	var v_store_key: String = String(v_params.get("store_target_key", &"pilot_066_target_id"))
	var v_target_mid: StringName = payload.get(v_store_key, &"")
	if v_target_mid == &"":
		return
	var v_target_player = context.game_state.get_player_for_mech(v_target_mid)
	var v_view_count: int = int(v_params.get("view_count", 2))
	# ① 随机抽取目标玩家 view_count 张行动牌（synced_shuffle 就地洗牌）
	var v_hand: Array = []
	if v_target_player != null:
		v_hand = v_target_player.action_hand.duplicate()
	context.synced_shuffle(v_hand)
	var v_picked: Array = v_hand.slice(0, mini(v_view_count, v_hand.size()))
	# ② 构建展示牌 + 收集类型（各计一次）
	var v_display: Array = []
	var v_seen_types := {}
	for v_cid: StringName in v_picked:
		var v_card = context.game_state.get_card(v_cid)
		if v_card == null or v_card.def == null:
			continue
		var v_type: String = String(v_card.def.action_type) if "action_type" in v_card.def else ""
		if v_type != "":
			v_seen_types[v_type] = true
		v_display.append({"name": String(v_card.def.display_name), "type": v_type})
	# ③ 展示浮窗：只给骇客玩家本人（非阻塞；PvP 双端都触发，app_root 按 owner==local 过滤）
	action_needs_input.emit(action.action_id, &"view_random_other_hand_show_display", {
		"action_id": action.action_id,
		"owner_mech_id": v_owner_mid,
		"owner_player_id": v_owner_pid,
		"target_mech_id": v_target_mid,
		"display_cards": v_display,
		"source_label": String(v_params.get("source_label", "骇客：查看目标行动牌")),
	})
	# ④ 类型加成链（各计一次可叠加；确认才 MARK 计数）
	var v_remaining: Array = []
	var v_mark_key: StringName = v_params.get("once_per_turn_key", &"")
	if v_mark_key != &"":
		v_remaining.append({"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": v_mark_key}})
	if v_seen_types.has("攻击") and int(v_params.get("attack_bonus", 0)) > 0:
		v_remaining.append({"type": &"MODIFY_ATTACK_COUNT", "params": {"mech_id": v_owner_mid, "delta": int(v_params.get("attack_bonus", 0)), "duration": &"THIS_TURN"}})
	if v_seen_types.has("迎击") and int(v_params.get("action_hand_bonus", 0)) > 0:
		v_remaining.append({"type": &"MODIFY_ACTION_HAND_LIMIT", "params": {"player_id": v_owner_pid, "delta": int(v_params.get("action_hand_bonus", 0)), "duration": &"THIS_TURN"}})
	if v_seen_types.has("辅助") and int(v_params.get("support_power", 0)) > 0:
		v_remaining.append({"type": &"RESTORE_POWER", "params": {"mech_id": v_owner_mid, "amount": int(v_params.get("support_power", 0))}})
	if not v_remaining.is_empty():
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": v_remaining, "effect": effect}
		if _continue_seq_effect_actions(action):
			action.state = &"waiting_effect_action"
	var v_a: int = int(v_params.get("attack_bonus", 0)) if v_seen_types.has("攻击") else 0
	var v_h: int = int(v_params.get("action_hand_bonus", 0)) if v_seen_types.has("迎击") else 0
	var v_p: int = int(v_params.get("support_power", 0)) if v_seen_types.has("辅助") else 0
	SLog.log_raw("[TIMING] %s 骇客窥牌：目标=%s 看%d张 类型=%s 加成[攻+%d 迎+%d 辅+%d] effect=%s" % [String(action.action_id), String(v_target_mid), v_display.size(), str(v_seen_types.keys()), v_a, v_h, v_p, String(effect.effect_id)])


## PILOT_088_CONQUER：征服宣言弃置——首次弹选目标（3格内持有行动牌的其他机甲）。
## 幂等守卫：payload 已选目标则跳过（resume 直接走 _pilot_088_show_type_select/finish）。
## valid_mech_ids 过滤（同骇客 p066），取消=不计次不消耗。返回 true=已挂起等输入。
func _handle_pilot_088_conquer(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null or action == null:
		return false
	if payload.has("pilot_088_target_id"):
		return false
	var p088_bind: Dictionary = payload.get("binding_context", {})
	var p088_pid: StringName = p088_bind.get("player_id", payload.get("player_id", &""))
	var p088_mid: StringName = p088_bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	if p088_pid == &"" or p088_mid == &"":
		return false
	var p088_mech = context.game_state.mechs.get(p088_mid)
	if p088_mech == null or p088_mech.destroyed:
		return false
	var p088_candidates: Array = []
	for p088_omid: StringName in context.game_state.mechs:
		if p088_omid == p088_mid:
			continue
		var p088_om = context.game_state.mechs[p088_omid]
		if p088_om == null or p088_om.destroyed:
			continue
		if _HexGrid.distance(p088_mech.position, p088_om.position) > 3:
			continue
		var p088_owner: StringName = p088_om.owner_player_id
		var p088_player = context.game_state.players.get(p088_owner) if p088_owner != &"" else null
		if p088_player != null and not p088_player.action_hand.is_empty():
			p088_candidates.append(p088_omid)
	if p088_candidates.is_empty():
		return false  # 无候选（条件 OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE 已 gating，防御）
	action.record["_waiting_for_target"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_088_target"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_mech_target", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"rule": &"mech_target_select",
		"mech_id": p088_mid,
		"valid_mech_ids": p088_candidates,
		"player_id": p088_pid,
		"source_label": "征服：选择3格范围内持有行动牌的1台其他机甲（取消=不计次数）",
	})
	SLog.log_raw("[TIMING] %s 挂起征服选目标（候选%d台）effect=%s" % [String(action.action_id), p088_candidates.size(), String(effect.effect_id)])
	return true


## 征服宣言：弹三选一类型（攻击/迎击/辅助），不可取消（choice_panel allow_cancel=false）。
## 选定目标后由 resume(phase=pilot_088_target) 调用；返回 true=已挂起等输入。
func _pilot_088_show_type_select(effect, payload: Dictionary, action) -> bool:
	if context == null or action == null:
		return false
	var p088_bind: Dictionary = payload.get("binding_context", {})
	var p088_pid: StringName = p088_bind.get("player_id", payload.get("player_id", &""))
	if p088_pid == &"":
		return false
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_088_type"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"pilot_088_type_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"player_id": p088_pid,
		"options": [
			{"label": "攻击", "effect_id": &"type_攻击", "declared_type": "攻击"},
			{"label": "迎击", "effect_id": &"type_迎击", "declared_type": "迎击"},
			{"label": "辅助", "effect_id": &"type_辅助", "declared_type": "辅助"},
		],
		"source_label": "征服：宣言1种行动牌类型（选定目标后本回合次数已消耗，不能取消）",
	})
	SLog.log_raw("[TIMING] %s 挂起征服选类型 effect=%s" % [String(action.action_id), String(effect.effect_id)])
	return true


## 征服收尾：随机取目标1张行动牌 → 非阻塞浮窗（所有玩家端显示宣言类型+展示牌）→
## 类型匹配弃置：相同→弃目标除展示牌外全部行动牌；不同→弃展示牌（EXECUTE_DISCARD card_ids 显式，
## 走 _seq_effect_actions 串行，无 UI 直接弃）。若弃置子动作挂起则置 action waiting_effect_action。
func _pilot_088_finish_conquer(effect, payload: Dictionary, action) -> void:
	if context == null or context.game_state == null or action == null:
		return
	var p088_target_id: StringName = payload.get("pilot_088_target_id", &"")
	var p088_declared: String = String(payload.get("pilot_088_declared_type", ""))
	if p088_target_id == &"" or p088_declared == "":
		return
	var p088_target_player = context.game_state.get_player_for_mech(p088_target_id)
	if p088_target_player == null:
		return
	var p088_hand: Array = p088_target_player.action_hand.duplicate()
	if p088_hand.is_empty():
		SLog.log_raw("[TIMING] %s 征服目标无行动牌（异常），中止 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return
	# 随机取1张：确定性 hash 派生（瑟尔基尔 pilot_003 同款修复模式）。
	# 种子 = 施法者机师牌实例id + 回合数*97，双端一致且不依赖 context.rng 消耗序列--
	# synced_shuffle 在 PvP/PvP3 中一旦各端 rng 序列分叉（此前实机 3 端展示牌不一致的根因）
	# 即永久分叉；hash 派生各端独立计算结果恒同。同回合同施法者多次发动也能取到不同牌
	# （回合数/实例id 变化 -> 种子变化；同种子重入场景展示同一张，可接受--效果本身幂等展示）。
	var p088_bc: Dictionary = payload.get("binding_context", {})
	var p088_seed: int = abs(int(String(p088_bc.get("card_instance_id", "")).hash()) + int(context.game_state.turn_number) * 97)
	var p088_shown_id: StringName = p088_hand[p088_seed % p088_hand.size()]
	var p088_shown_type: String = ""
	var p088_shown_name: String = "?"
	var p088_shown_card = context.game_state.get_card(p088_shown_id)
	if p088_shown_card != null and p088_shown_card.def != null:
		p088_shown_type = String(p088_shown_card.def.action_type) if "action_type" in p088_shown_card.def else ""
		p088_shown_name = String(p088_shown_card.def.display_name)
	# 非阻塞浮窗：所有玩家端显示「宣言类型 + 随机展示的牌」（app_root 全部显示，不过滤持有者）
	var p088_holder_name: String = String(p088_target_id)
	var p088_tm = context.game_state.mechs.get(p088_target_id)
	if p088_tm != null and p088_tm.frame_def != null and String(p088_tm.frame_def.display_name) != "":
		p088_holder_name = String(p088_tm.frame_def.display_name)
	action_needs_input.emit(action.action_id, &"pilot_088_conquer_display", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"owner_mech_id": p088_target_id,
		"display_cards": [
			{"name": "宣言类型", "type": p088_declared},
			{"name": "随机展示：%s" % p088_shown_name, "type": p088_shown_type},
		],
		"source_label": "征服：宣言与目标随机展示（目标：%s）" % p088_holder_name,
	})
	# 类型匹配决定弃置
	var p088_discard_ids: Array = []
	if p088_shown_type == p088_declared:
		# 相同：弃目标除展示牌外全部行动牌
		for p088_cid: StringName in p088_target_player.action_hand:
			if p088_cid != p088_shown_id:
				p088_discard_ids.append(p088_cid)
	else:
		# 不同：弃展示牌
		p088_discard_ids = [p088_shown_id]
	SLog.log_raw("[TIMING] %s 征服结算：目标=%s 宣言=%s 展示=%s(类型%s) 弃%d张 effect=%s" % [String(action.action_id), String(p088_target_id), p088_declared, String(p088_shown_id), p088_shown_type, p088_discard_ids.size(), String(effect.effect_id)])
	if p088_discard_ids.is_empty():
		return
	action.record["_seq_effect_actions"] = {
		"payload": payload,
		"remaining": [
			{"type": &"EXECUTE_DISCARD", "params": {
				"card_ids": p088_discard_ids,
				"player_id": p088_target_player.player_id,
				"reason": &"pilot_088_conquer",
			}},
		],
		"effect": effect,
	}
	if _continue_seq_effect_actions(action):
		action.state = &"waiting_effect_action"


## PILOT_059_TURN_START_FLOW：薇尔效果1 回合开始损伤调整+分支（多阶段挂起）。
## 被动 LISTEN TURN_START，首次进入弹损伤调整面板（damage_adjust：每槽位 +1/-1+取消，
## 仅1次机会，也可取消不调整），挂起等待 resume_pending_effect phase=pilot_059_adjust。
## resume 阶段：应用调整（set 放1损+查装备损坏 / remove 移1损 / cancel 不动）→ 用
## PILOT_044_COMPUTE_DAMAGE 统计调整后损伤数 N → 三分支（<threshold 获金 / ==threshold
## 视为补给抽2行动+1装备 / >threshold 移除最多 max_remove）经 _seq_effect_actions 串行执行。
## 通用可复用：threshold/gold_amount/max_remove/store_key/source_label 全由 params 决定，
## 效果绑定 effect 而非机师。返回 true=已挂起等输入。
func _handle_pilot_059_turn_start_flow(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null or action == null:
		return false
	# 已进入后续阶段（resume 后不再重进顶层 _execute_actions）
	if payload.has("pilot_059_phase"):
		return false
	var p59_params: Dictionary = act.get("params", {})
	var p59_bind: Dictionary = payload.get("binding_context", {})
	var p59_owner_pid: StringName = p59_bind.get("player_id", &"")
	var p59_owner_mid: StringName = p59_bind.get("mech_id", &"")
	if p59_owner_pid == &"" or p59_owner_mid == &"":
		return false
	if not context.game_state.mechs.has(p59_owner_mid):
		return false
	# 首次：存阶段标志+params，弹损伤调整面板并挂起
	payload["pilot_059_phase"] = &"adjust"
	payload["pilot_059_params"] = p59_params
	var p59_label: String = String(p59_params.get("source_label", "薇尔·损伤调整"))
	_pending_effect[action.action_id] = {
		"action": action, "effect": effect, "payload": payload, "phase": &"pilot_059_adjust",
	}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"damage_adjust", {
		"action_id": action.action_id,
		"mech_id": p59_owner_mid,
		"player_id": p59_owner_pid,
		"source_label": p59_label,
	})
	SLog.log_raw("[TIMING] %s pilot_059 回合开始弹损伤调整面板 mech=%s effect=%s" % [String(action.action_id), String(p59_owner_mid), String(effect.effect_id)])
	return true


## PILOT_028_FORCE_TRIBUTE：乌尔效果2 需交牌。USE_ACTION_AT 触发。
## 条件：已宣言 + 其他机甲使用 + 实体牌 + 宣言类型牌 + 距离≤4+X + 用牌玩家手牌≥2。
## 满足且玩家非 AI：弹交给牌窗（thrust_select，min_count=2）给用牌玩家，挂起等待。
## 手牌<2 -> 不弹窗直接设跳过标志（行动牌不生效）；AI 用牌玩家自动交出前2张。
## 返回 true=已挂起等输入；false=已同步处理/跳过。
func _handle_pilot_028_force_tribute(_act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var p28_card = _ActionPilotEffects.pilot_028_pilot_card(context.game_state)
	if p28_card == null:
		return false
	var declared: String = _ActionPilotEffects.get_pilot_028_declared(p28_card)
	if declared == "":
		return false
	var p28_w_mid: StringName = _ActionPilotEffects.pilot_028_find_w_mech(context.game_state)
	if p28_w_mid == &"":
		return false
	var p28_w_mech = context.game_state.mechs.get(p28_w_mid)
	if p28_w_mech == null:
		return false
	var use_mech_id: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
	if use_mech_id == &"" or use_mech_id == p28_w_mid:
		return false  # 其他机甲使用才触发
	var use_mech = context.game_state.mechs.get(use_mech_id)
	if use_mech == null or use_mech.destroyed:
		return false
	# 实体牌（转化虚拟不算）
	if bool(payload.get("virtual_transform", false)):
		return false
	# 宣言类型牌
	var card_id: StringName = payload.get("card_instance_id", &"")
	var card = context.game_state.get_card(card_id) if card_id != &"" else null
	if card == null or card.def == null:
		return false
	var card_type: String = String(card.def.action_type) if "action_type" in card.def else ""
	if card_type != declared:
		return false
	# 距离 ≤ 4+X
	var p28_x: int = _ActionPilotEffects.get_pilot_028_x(p28_card)
	if int(_HexGrid.distance(use_mech.position, p28_w_mech.position)) > 4 + p28_x:
		return false
	# 用牌玩家
	var use_pid: StringName = payload.get("player_id", &"")
	if use_pid == &"":
		var use_player_0 = context.game_state.get_player_for_mech(use_mech_id)
		if use_player_0 != null:
			use_pid = use_player_0.player_id
	if use_pid == &"":
		return false
	var use_player = context.game_state.players.get(use_pid)
	if use_player == null:
		return false
	# 交给牌候选 = 用牌玩家行动手牌（正在使用的牌已在临时区，不在此列）
	var tribute_candidates: Array = use_player.action_hand.duplicate()
	if tribute_candidates.size() < 2:
		# 牌不够2张 -> 不弹窗，行动牌不生效（跳过效果阶段）
		action.record["_pilot_028_skip_effects"] = true
		SLog.log_raw("[TIMING] %s pilot_028 需交牌：%s 手牌<2，%s 使用宣言[%s]不生效" % [String(action.action_id), String(use_pid), String(card.def.display_name), declared])
		return false
	# 去重守卫：同一动作只弹一次（多个 USE_ACTION_AT 监听器/重跑场景）
	if action.record.get("_p028_tribute_shown", false):
		return false
	action.record["_p028_tribute_shown"] = true
	if _is_ai_owner(use_pid, use_mech_id):
		_pilot_028_do_tribute(action, tribute_candidates.slice(0, 2))
		SLog.log_raw("[TIMING] %s pilot_028 需交牌：AI %s 自动交出2张，%s 使用宣言[%s]生效" % [String(action.action_id), String(use_mech_id), String(card.def.display_name), declared])
		return false
	# 人类用牌玩家：弹交给牌窗（max_count=2 只选恰好2张，min_count=2 不足不可确认）
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_028_tribute"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_thrust_cards", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": tribute_candidates,
		"player_id": use_pid,
		"label": "乌尔「需交牌」：使用宣言[%s]牌须交给乌尔2张行动牌才能生效" % declared,
		"confirm_verb": "交出",
		"cancel_label": "不交牌（行动牌不生效）",
		"max_count": 2,
		"min_count": 2,
	})
	SLog.log_raw("[TIMING] %s 挂起乌尔需交牌 effect=%s 用牌=%s 手牌=%d" % [String(action.action_id), String(effect.effect_id), String(use_mech_id), tribute_candidates.size()])
	return true


## 执行交给牌：把用牌玩家（action.record.player_id）的 card_ids（至多2张）转移给乌尔玩家。
## 交给牌成功（交足）后行动牌正常生效；调用方在交不够/取消时已设跳过标志。
func _pilot_028_do_tribute(action, card_ids: Array) -> void:
	if context == null or context.game_state == null or action == null:
		return
	var p28_w_mid: StringName = _ActionPilotEffects.pilot_028_find_w_mech(context.game_state)
	if p28_w_mid == &"":
		return
	var p28_w_player = context.game_state.get_player_for_mech(p28_w_mid)
	var from_pid: StringName = action.record.get("player_id", &"") if action.record != null else &""
	if p28_w_player == null or from_pid == &"":
		return
	var xfer: Array = card_ids.slice(0, 2)
	if xfer.is_empty() or from_pid == StringName(p28_w_player.player_id):
		return
	context.game_actions.transfer_action_cards({
		"from_player_id": from_pid,
		"to_player_id": p28_w_player.player_id,
		"card_ids": xfer,
	})
	SLog.log_raw("[TIMING] %s pilot_028 交给牌：%s 交 %d 张给 %s" % [String(action.action_id), String(from_pid), xfer.size(), String(p28_w_player.player_id)])


func _handle_pilot_006_force_use_attack(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	var p06_params: Dictionary = act.get("params", {})
	var p06_target_mech: StringName = _resolve_mech_id_expr(String(p06_params.get("target_mech_id", &"")), payload)
	if p06_target_mech == &"":
		p06_target_mech = payload.get("target_id", payload.get("target_mech_id", &""))
	if p06_target_mech == &"" or context == null or context.game_state == null:
		return false
	var p06_player = context.game_state.get_player_for_mech(p06_target_mech)
	if p06_player == null:
		return _pilot_006_fallback_damage(p06_target_mech, action, payload)
	# AI 被选机甲：暂跳过（pilot_006 e3 先 PvP 人类）
	if _is_ai_owner(p06_player.player_id, p06_target_mech):
		SLog.log_raw("[TIMING] %s pilot_006 战后逼迫：被选机甲为 AI，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	var p06_card_ids: Array = []
	for hand_cid in p06_player.action_hand:
		var hand_card = context.game_state.get_card(hand_cid)
		if hand_card != null and hand_card.def != null and String(hand_card.def.action_type) == "攻击":
			p06_card_ids.append(hand_cid)
	# 无攻击牌：回落4伤害（二选一选了攻击但无牌可打）
	if p06_card_ids.is_empty():
		return _pilot_006_fallback_damage(p06_target_mech, action, payload)
	# 去重守卫
	if action.record.get("_pilot_006_force_shown", false):
		return false
	action.record["_pilot_006_force_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_006_force_use_attack", "pilot_006_target_mech": p06_target_mech}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_pilot_006_attack_card", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": p06_card_ids,
		"target_mech_id": p06_target_mech,
		"player_id": p06_player.player_id,
		"label": "战后逼迫：选择1张攻击牌使用（取消=受到4伤害）",
	})
	SLog.log_raw("[TIMING] %s pilot_006 战后逼迫选牌 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p06_card_ids.size()])
	return true


## 铠威 pilot_039 调度：被响应攻击结算时登记「攻击动作完成后」钩子（非阻塞，不弹窗）。
## ATTACK_SETTLE（priority 30，条件 SELF_MECH_IS_ATTACKER + responded）触发后：
## 取攻击方机甲/玩家，run_after_action_completed 挂到本次攻击 action 上；攻击动作完全
## 清理完成（含 _step_cleanup 关闭攻击窗口之后）由 ActionService 派发
## _ActionPilotEffects.pilot_039_after_attack_completed（入队+弹确认）。去重守卫防重跑。
func _handle_pilot_039_schedule_after_attack(effect: ActionEffect, payload: Dictionary, action) -> void:
	if context == null or context.game_state == null or context.action_service == null:
		return
	# 去重守卫：同一攻击动作只登记一次（LISTEN effect 在 ATTACK_SETTLE 每攻击仅 fire 一次，保险起见）
	if action.record.get("_pilot_039_scheduled", false):
		return
	action.record["_pilot_039_scheduled"] = true
	var bind = _make_binding_from_effect(effect, action, payload)
	var mech_id: StringName = bind.get_source_mech_id() if bind != null else &""
	if mech_id == &"":
		mech_id = payload.get("attacker_id", &"")
	if mech_id == &"":
		return
	var player = context.game_state.get_player_for_mech(mech_id)
	if player == null:
		return
	# 关键：钩子挂到「攻击」动作而非本效果动作——fire_timing_point(ATTACK_SETTLE) 时
	# payload["action_id"] 即攻击动作 id。效果动作在 ATTACK_SETTLE 内同步完成（过早），
	# 而攻击动作完成才是「此攻击结算后」的时点（伤害已结算、_step_cleanup 已关窗）。
	var attack_action_id: StringName = payload.get("action_id", &"")
	if attack_action_id == &"":
		return
	var pid: StringName = player.player_id
	var cb := Callable(func() -> void:
		_ActionPilotEffects.pilot_039_after_attack_completed(context, pid, mech_id))
	context.action_service.run_after_action_completed(attack_action_id, cb)
	SLog.log_raw("[TIMING] %s 铠威登记攻击完成钩子 attacker=%s effect=%s" % [String(attack_action_id), String(mech_id), String(effect.effect_id)])


## 铠厉 pilot_056 通用调度：被响应攻击结算时登记「攻击动作完成后」钩子（非阻塞，不弹窗）。
## 与铠威 pilot_039 同构：ATTACK_SETTLE（priority 30，条件 SELF_MECH_IS_ATTACKER + responded）触发后，
## run_after_action_completed 挂到本次攻击 action 上；攻击动作完全清理完成后由 ActionService 派发
## _ActionPilotEffects.responded_equip_after_attack_completed（入队触发+弹确认+逐张设置/弃置获金链）。
## 去重守卫防重跑（同一攻击只登记一次）。通用模块 responded_equip_chain_* 不绑机师，任意
## 含 RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK 动作的效果复用。
func _handle_responded_equip_schedule_after_attack(effect: ActionEffect, payload: Dictionary, action) -> void:
	if context == null or context.game_state == null or context.action_service == null:
		return
	# 去重守卫：同一攻击动作只登记一次
	if action.record.get("_responded_equip_scheduled", false):
		return
	action.record["_responded_equip_scheduled"] = true
	var bind = _make_binding_from_effect(effect, action, payload)
	var mech_id: StringName = bind.get_source_mech_id() if bind != null else &""
	if mech_id == &"":
		mech_id = payload.get("attacker_id", &"")
	if mech_id == &"":
		return
	var player = context.game_state.get_player_for_mech(mech_id)
	if player == null:
		return
	# 钩子挂到「攻击」动作而非本效果动作——fire_timing_point(ATTACK_SETTLE) 时
	# payload["action_id"] 即攻击动作 id；攻击动作完成才是「此攻击结算后」的时点。
	var attack_action_id: StringName = payload.get("action_id", &"")
	if attack_action_id == &"":
		return
	var pid: StringName = player.player_id
	var cb := Callable(func() -> void:
		_ActionPilotEffects.responded_equip_after_attack_completed(context, pid, mech_id))
	context.action_service.run_after_action_completed(attack_action_id, cb)
	SLog.log_raw("[TIMING] %s 铠厉登记被响应抽装链钩子 attacker=%s effect=%s" % [String(attack_action_id), String(mech_id), String(effect.effect_id)])


## 铠德 pilot_060 通用调度：被响应攻击结算时登记「攻击动作完成后」钩子（非阻塞，不弹窗）。
## 与铠威/铠厉同构：ATTACK_SETTLE（priority 30，条件 SELF_MECH_IS_ATTACKER + responded）触发后，
## run_after_action_completed 挂到本次攻击 action 上；攻击动作完全清理完成后由 ActionService 派发
## _ActionPilotEffects.pilot_060_after_attack_completed（入队触发+弹三选一）。去重守卫防重跑。
## 通用模块 pilot_060_* 不绑机师，任意含 PILOT_060_SCHEDULE_AFTER_ATTACK 动作的效果复用。
func _handle_pilot_060_schedule_after_attack(effect: ActionEffect, payload: Dictionary, action) -> void:
	if context == null or context.game_state == null or context.action_service == null:
		return
	# 去重守卫：同一攻击动作只登记一次
	if action.record.get("_pilot_060_scheduled", false):
		return
	action.record["_pilot_060_scheduled"] = true
	var bind = _make_binding_from_effect(effect, action, payload)
	var mech_id: StringName = bind.get_source_mech_id() if bind != null else &""
	if mech_id == &"":
		mech_id = payload.get("attacker_id", &"")
	if mech_id == &"":
		return
	var player = context.game_state.get_player_for_mech(mech_id)
	if player == null:
		return
	# 钩子挂到「攻击」动作而非本效果动作——fire_timing_point(ATTACK_SETTLE) 时
	# payload["action_id"] 即攻击动作 id；攻击动作完成才是「此攻击结算后」的时点。
	var attack_action_id: StringName = payload.get("action_id", &"")
	if attack_action_id == &"":
		return
	var pid: StringName = player.player_id
	var cb := Callable(func() -> void:
		_ActionPilotEffects.pilot_060_after_attack_completed(context, pid, mech_id))
	context.action_service.run_after_action_completed(attack_action_id, cb)
	SLog.log_raw("[TIMING] %s 铠德登记被响应三选一钩子 attacker=%s effect=%s" % [String(attack_action_id), String(mech_id), String(effect.effect_id)])


## 效果来源机甲是否处于攻击窗口中（铠威窗口攻击数豁免判定共用）。
## binding 来源机甲 == 窗口 owner_mech_id 时返回 true；窗口未激活/无来源机甲返回 false。
func _attack_window_active_for_binding(binding) -> bool:
	if binding == null or context == null or context.game_state == null:
		return false
	var mid: StringName = binding.get_source_mech_id()
	return _ActionPilotEffects.attack_window_active_for_mech(context.game_state, mid)


## 通用直接生命变动：原先直接改 current_hp 的效果伤害（pilot_006 战后逼迫回落 / pilot_047
## 交牌差额 / pilot_019 弃牌清空4伤害）统一转走 EXECUTE_HP_CHANGE 子动作，使
## HP_CHANGE_BEFORE/AFTER/SETTLE 时点正常触发（杰狞 pilot_049 差额转移等监听器可拦截）。
## 复用：直接伤害类效果按此模式调本 helper（仿 pilot_019 弃牌链的子动作挂起处理）。
## 返回 true = 子动作挂起（调用方停止推进，等 _after_sub_action_finished 通知续跑），
## false = 同步完成 / 前置不满足跳过（未创建子动作）。
func _deal_direct_hp_change_sub(action, payload: Dictionary, target_mech: StringName, amount: int, source_mech_id: StringName, reason: StringName) -> bool:
	if action == null or context == null or context.action_service == null or context.game_state == null:
		return false
	if target_mech == &"" or amount <= 0:
		return false
	var dmg_target = context.game_state.mechs.get(target_mech)
	if dmg_target == null or dmg_target.destroyed:
		return false
	context.action_service.execute_sub_action({
		"type": &"EXECUTE_HP_CHANGE",
		"params": {
			"mech_ids": [target_mech],
			"value": amount,
			"method": &"decrease",
			"source_mech_id": source_mech_id,
			"reason": reason,
		},
	}, payload, action)
	if _last_created_sub_action_paused(action):
		action.state = &"waiting_effect_action"
		SLog.log_raw("[TIMING] %s 直接伤害转 hp_change 子动作挂起 目标=%s 数值=%d 来源=%s 原因=%s" % [String(action.action_id), String(target_mech), amount, String(source_mech_id), String(reason)])
		return true
	return false


## pilot_006 e3 战后逼迫回落：对被选机甲造成4伤害（选牌取消/无牌可打时）。
## 转 EXECUTE_HP_CHANGE 子动作（HP_CHANGE_BEFORE 时点可被杰狞 pilot_049 转移等拦截）。
## 返回 true = 伤害子动作挂起。
func _pilot_006_fallback_damage(target_mech: StringName, action, payload: Dictionary) -> bool:
	if target_mech == &"" or context == null or context.game_state == null:
		return false
	var p06_bind: Dictionary = payload.get("binding_context", {})
	var p06_src: StringName = p06_bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	return _deal_direct_hp_change_sub(action, payload, target_mech, 4, p06_src, &"pilot_006_refused_attack")


## pilot_047 里欧娜 e1 分支①「立即使用1张攻击牌」：被选机甲选1张攻击牌被动使用。
## 复制自 pilot_006 e3 的 PILOT_006_FORCE_USE_ATTACK，差异：选牌窗 no_cancel 不可取消；
## 无攻击牌/取消（防御路径）转交牌流程（PILOT_047_FORCE_HANDOVER）。AI 被选机甲暂跳过。
## 返回 true=已挂起等输入；false=已同步处理/跳过。
func _handle_pilot_047_force_use_attack(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	var p47_params: Dictionary = act.get("params", {})
	var p47_target: StringName = _resolve_mech_id_expr(String(p47_params.get("target_mech_id", &"")), payload)
	if p47_target == &"":
		p47_target = payload.get("target_id", payload.get("target_mech_id", &""))
	if p47_target == &"" or context == null or context.game_state == null:
		return false
	var p47_to_mech: StringName = _resolve_mech_id_expr(String(p47_params.get("to_mech_id", &"")), payload)
	if p47_to_mech == &"":
		var p47_bind: Dictionary = payload.get("binding_context", {})
		p47_to_mech = p47_bind.get("mech_id", &"")
	var p47_count: int = int(p47_params.get("count", 3))
	var p47_dpm: int = int(p47_params.get("damage_per_missing", 2))
	var p47_player = context.game_state.get_player_for_mech(p47_target)
	if p47_player == null:
		# 防御：无玩家转交牌（空手牌全交 + 满差额伤害）
		return _pilot_047_do_handover(p47_target, p47_to_mech, [], p47_count, p47_dpm, action, payload)
	# AI 被选机甲：暂跳过（pilot_047 先 PvP 人类，同 pilot_006 e3）
	if _is_ai_owner(p47_player.player_id, p47_target):
		SLog.log_raw("[TIMING] %s pilot_047 战后威逼：被选机甲为 AI，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	var p47_card_ids: Array = []
	for hand_cid in p47_player.action_hand:
		var hand_card = context.game_state.get_card(hand_cid)
		if hand_card != null and hand_card.def != null and String(hand_card.def.action_type) == "攻击":
			p47_card_ids.append(hand_cid)
	# 无攻击牌：转交牌流程（空手牌全交 + 满差额伤害；正常 MECH_HAS_USABLE_ATTACK_CARD 置灰不会走到）
	if p47_card_ids.is_empty():
		return _handle_pilot_047_force_handover(act, effect, payload, action)
	# 去重守卫
	if action.record.get("_pilot_047_force_shown", false):
		return false
	action.record["_pilot_047_force_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
		"phase": &"pilot_047_force_use_attack", "pilot_047_target_mech": p47_target,
		"pilot_047_to_mech": p47_to_mech, "pilot_047_count": p47_count, "pilot_047_dpm": p47_dpm}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_pilot_006_attack_card", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": p47_card_ids,
		"target_mech_id": p47_target,
		"player_id": p47_player.player_id,
		"no_cancel": true,
		"label": "里欧娜：被选机甲立即使用1张攻击牌",
	})
	SLog.log_raw("[TIMING] %s pilot_047 战后威逼选攻击牌 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p47_card_ids.size()])
	return true


## pilot_047 里欧娜 e1 分支②「交给我方3张行动牌」：目标手牌>count 弹交给牌窗（目标玩家选
## count 张，min=max=count no_cancel）；手牌≤count 不弹窗直接全部交出；差额
## count - 实交数 每张 damage_per_missing 直接扣 HP（同 pilot_006 直接伤害先例）。
## AI 被选机甲自动交出（够则前 count 张，不够全交）+ 差额伤害。
## 返回 true=已挂起等输入；false=已同步处理/跳过。
func _handle_pilot_047_force_handover(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var p47_params: Dictionary = act.get("params", {})
	var p47_target: StringName = _resolve_mech_id_expr(String(p47_params.get("target_mech_id", &"")), payload)
	if p47_target == &"":
		p47_target = payload.get("target_id", payload.get("target_mech_id", &""))
	if p47_target == &"":
		return false
	var p47_to_mech: StringName = _resolve_mech_id_expr(String(p47_params.get("to_mech_id", &"")), payload)
	if p47_to_mech == &"":
		var p47_bind: Dictionary = payload.get("binding_context", {})
		p47_to_mech = p47_bind.get("mech_id", &"")
	var p47_count: int = int(p47_params.get("count", 3))
	var p47_dpm: int = int(p47_params.get("damage_per_missing", 2))
	var p47_player = context.game_state.get_player_for_mech(p47_target)
	var p47_owner = context.game_state.get_player_for_mech(p47_to_mech)
	if p47_player == null or p47_owner == null:
		return false
	var p47_hand: Array = p47_player.action_hand.duplicate()
	# AI 被选机甲：自动交出（够则前 count 张，不够全交）+ 差额伤害
	if _is_ai_owner(p47_player.player_id, p47_target):
		var p47_ai_paused: bool = _pilot_047_do_handover(p47_target, p47_to_mech, p47_hand.slice(0, p47_count), p47_count, p47_dpm, action, payload)
		SLog.log_raw("[TIMING] %s pilot_047 交牌：AI %s 自动交出 %d 张" % [String(action.action_id), String(p47_target), mini(p47_hand.size(), p47_count)])
		return p47_ai_paused
	# 手牌≤count：不弹窗，全部交出 + 差额伤害
	if p47_hand.size() <= p47_count:
		return _pilot_047_do_handover(p47_target, p47_to_mech, p47_hand, p47_count, p47_dpm, action, payload)
	# 去重守卫
	if action.record.get("_pilot_047_handover_shown", false):
		return false
	action.record["_pilot_047_handover_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
		"phase": &"pilot_047_force_handover", "pilot_047_target_mech": p47_target,
		"pilot_047_to_mech": p47_to_mech, "pilot_047_count": p47_count, "pilot_047_dpm": p47_dpm}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_thrust_cards", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": p47_hand,
		"player_id": p47_player.player_id,
		"label": "里欧娜「战后威逼交牌」：必须交给我方%d张行动牌（少交每张受%d伤害）" % [p47_count, p47_dpm],
		"confirm_verb": "交出",
		"cancel_label": "取消",
		"max_count": p47_count,
		"min_count": p47_count,
		"no_cancel": true,
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_047 交给牌窗 effect=%s 目标=%s 手牌=%d" % [String(action.action_id), String(effect.effect_id), String(p47_target), p47_hand.size()])
	return true


## 执行交给牌：把 target_mech 的 card_ids（至多 count 张）转移给 to_mech 的玩家，
## 差额 count - 实交数 每张 damage_per_missing 转 EXECUTE_HP_CHANGE 子动作扣 target_mech HP
## （HP_CHANGE_BEFORE 时点可被杰狞 pilot_049 转移等拦截）。返回 true = 伤害子动作挂起。
func _pilot_047_do_handover(target_mech: StringName, to_mech: StringName, card_ids: Array, count: int, dpm: int, action, payload: Dictionary = {}) -> bool:
	if context == null or context.game_state == null or context.game_actions == null:
		return false
	if target_mech == &"" or to_mech == &"":
		return false
	var from_player = context.game_state.get_player_for_mech(target_mech)
	var to_player = context.game_state.get_player_for_mech(to_mech)
	if from_player == null or to_player == null:
		return false
	var xfer: Array = card_ids.slice(0, count)
	var shortfall: int = maxi(0, count - xfer.size())
	if not xfer.is_empty() and StringName(from_player.player_id) != StringName(to_player.player_id):
		context.game_actions.transfer_action_cards({
			"from_player_id": from_player.player_id,
			"to_player_id": to_player.player_id,
			"card_ids": xfer,
		})
	var paused: bool = false
	if shortfall > 0:
		# 来源 = to_mech（里欧娜持有者机甲，效果来源）
		paused = _deal_direct_hp_change_sub(action, payload, target_mech, dpm * shortfall, to_mech, &"pilot_047_handover_shortfall")
	SLog.log_raw("[TIMING] %s pilot_047 交给牌：%s 交 %d 张给 %s，差额 %d，伤害 %d，挂起=%s" % [String(action.action_id), String(target_mech), xfer.size(), String(to_mech), shortfall, dpm * shortfall, str(paused)])
	return paused


## ═══════════════════════════════════════════
## 通用「动力税」机制（POWER_SPEND_TAX，杰西卡 pilot_050 e1/e1b；复用=复制定义改参数）
## ═══════════════════════════════════════════
## 监听其他机甲动力消耗：范围内（base_range + 绑定卡 counter_key 计数 X）其他机甲每累计
## 消耗 threshold 点动力 -> 弹确认窗询问效果持有者是否使该机甲与我方各受 damage 伤害。
## 确认 -> 两次独立 hp_change 子动作（先该机甲后我方，顺序结算：双方同濒死该机甲先死），
## 来源均为我方机甲。确认/拒绝都清掉这 threshold 点累计（拒绝清零），余数留累计继续记。
## 范围判定在消耗时快照（先消耗再移动：BASIC_MOVE_AT 在移位前触发，范围外消耗后移入不计、
## 范围内消耗后移出仍计入）。一次消耗 N 点 -> floor(N/threshold) 次询问串行执行（一次消耗10
## 按5次触发）。触发时机=消耗时立即阻塞（弹窗挂起宿主动作，移动逐格中断）。
## 消耗方/数值来源：power_spent 虚拟时点（非移动消耗）读 payload._power_spent_event；
## BASIC_MOVE_AT 路径读 payload.mech_id + power_cost（免费移动 free_move 未实际消耗不计）。
## 返回 true=已挂起（弹窗/伤害链），false=无事发生（不在范围/未达阈值/AI 持有者）。
func _handle_power_spend_tax(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var pt_params: Dictionary = act.get("params", {})
	var pt_base_range: int = int(pt_params.get("base_range", 4))
	var pt_counter_key: StringName = pt_params.get("counter_key", &"")
	var pt_damage: int = int(pt_params.get("damage", 2))
	var pt_threshold: int = int(pt_params.get("threshold", 2))
	var pt_accum_prefix: String = String(pt_params.get("accum_prefix", "power_tax_accum_"))
	var pt_bind: Dictionary = payload.get("binding_context", {})
	var pt_owner_mech: StringName = pt_bind.get("mech_id", &"")
	var pt_owner_pid: StringName = pt_bind.get("player_id", &"")
	var pt_cid: StringName = pt_bind.get("card_instance_id", &"")
	if pt_owner_mech == &"" or pt_cid == &"":
		return false
	var pt_card = context.game_state.get_card(pt_cid)
	var pt_owner_src = context.game_state.mechs.get(pt_owner_mech)
	if pt_card == null or pt_owner_src == null or pt_owner_src.destroyed:
		return false
	# 消耗方与数值
	var pt_spender: StringName = &""
	var pt_amount: int = 0
	var pt_evt: Dictionary = payload.get("_power_spent_event", {})
	if pt_evt is Dictionary and not pt_evt.is_empty():
		pt_spender = pt_evt.get("mech_id", &"")
		pt_amount = int(pt_evt.get("amount", 0))
	else:
		pt_spender = payload.get("mech_id", payload.get("source_mech_id", &""))
		pt_amount = int(payload.get("power_cost", 0))
		if bool(payload.get("free_move", false)):
			pt_amount = 0  # 免费移动未实际消耗动力
	if pt_amount <= 0 or pt_spender == &"" or String(pt_spender) == String(pt_owner_mech):
		return false
	var pt_spender_mech = context.game_state.mechs.get(pt_spender)
	if pt_spender_mech == null or pt_spender_mech.destroyed:
		return false
	# 范围判定（消耗时快照，hex 距离 <= base_range + X）
	var pt_counters0: Dictionary = pt_card.counters if pt_card.counters != null else {}
	var pt_x: int = int(pt_counters0.get("var_%s" % String(pt_counter_key), 0)) if pt_counter_key != &"" else 0
	if _HexGrid.distance(pt_owner_src.position, pt_spender_mech.position) > pt_base_range + pt_x:
		return false
	# 累计（存本卡实例 counters，按消耗方机甲分键；只可能是 0..threshold-1 的余数）
	var pt_accum_key: String = "%s%s" % [pt_accum_prefix, String(pt_spender)]
	var pt_accum: int = int(pt_counters0.get(pt_accum_key, 0)) + pt_amount
	var pt_triggers: int = 0
	if pt_threshold > 0 and pt_accum >= pt_threshold:
		pt_triggers = int(pt_accum / pt_threshold)
		pt_accum = pt_accum % pt_threshold
	if pt_card.counters == null:
		pt_card.counters = {}
	pt_card.counters[pt_accum_key] = pt_accum
	if pt_triggers <= 0:
		return false
	SLog.log_raw("[TIMING] %s 动力税：%s 消耗 %d 触发 %d 次（余 %d）effect=%s" % [String(action.action_id), String(pt_spender), pt_amount, pt_triggers, pt_accum, String(effect.effect_id)])
	# AI 持有者：暂不支持（自动不发动；累计已在触发时扣除）
	if _is_ai_owner(pt_owner_pid, pt_owner_mech):
		return false
	action.record["_power_tax_ctx"] = {
		"owner_mech_id": pt_owner_mech,
		"owner_player_id": pt_owner_pid,
		"target_mech_id": pt_spender,
		"damage": pt_damage,
		"threshold": pt_threshold,
		"prompts_left": pt_triggers,
		"trigger_total": pt_triggers,
	}
	_power_tax_prompt_confirm(action, payload, effect)
	return true


## 动力税确认弹窗（第 N/total 次询问，可选发动）。挂起 phase=power_tax_confirm。
func _power_tax_prompt_confirm(action, payload: Dictionary, effect) -> void:
	var pt_ctx: Dictionary = action.record.get("_power_tax_ctx", {})
	if int(pt_ctx.get("prompts_left", 0)) <= 0:
		action.record.erase("_power_tax_ctx")
		return
	var pt_total: int = int(pt_ctx.get("trigger_total", 1))
	var pt_done: int = pt_total - int(pt_ctx.get("prompts_left", 1)) + 1
	var pt_target: StringName = pt_ctx.get("target_mech_id", &"")
	var pt_tname: String = String(pt_target)
	if context != null and context.game_state != null:
		var pt_tm = context.game_state.mechs.get(pt_target)
		if pt_tm != null:
			pt_tname = pt_tm.get_display_name() if pt_tm.has_method("get_display_name") else String(pt_target)
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"power_tax_confirm"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": "发动：%s 与我方各受到%d伤害（第%d/%d次）" % [pt_tname, int(pt_ctx.get("damage", 2)), pt_done, pt_total], "effect_id": &"option_0", "option_index": 0},
		],
		"optional": true,
		"player_id": pt_ctx.get("owner_player_id", &""),
		"source_label": "动力税：%s 已累计消耗%d点动力（可发动使其与我方各受%d伤害）" % [pt_tname, int(pt_ctx.get("threshold", 2)), int(pt_ctx.get("damage", 2))],
	})
	SLog.log_raw("[TIMING] %s 挂起动力税确认（%d/%d）effect=%s" % [String(action.action_id), pt_done, pt_total, String(effect.effect_id)])


## 动力税/动力税贡赋收尾：效果链全部结束后恢复宿主动作（与各 resume 阶段守卫一致）。
func _power_tax_resume_host(action, action_id: StringName) -> void:
	if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
		return
	if not action.pending_effect_action_ids.is_empty():
		action.state = &"waiting_effect_action"
		return
	if context != null and context.action_engine != null:
		action.state = &"waiting_input"
		context.action_engine.continue_action(action_id, {})


## ═══════════════════════════════════════════
## 通用「受伤 X+1 + 弃双方行动牌」状态机（POWER_TAX_TRIBUTE，杰西卡 pilot_050 e2；复用=复制改参数）
## ═══════════════════════════════════════════
## 监听我方受伤（HP_CHANGE_SETTLE 实际掉血）：
##   ① 确认弹窗（取消=不发动，不消耗每回合1次次数）；
##   ② 确认 -> mark once_per_turn + 绑定卡 counter_key X+1（先于范围计算，按新X取范围）；
##   ③ 选 base_range+新X 范围内 1 台其他机甲（常规目标UI valid_mech_ids 高亮；
##      无候选 -> 仅 X+1，弃牌整段跳过；选目标后取消 -> X+1 已生效，跳过弃牌）；
##   ④ 连续两次独立弃置（先我方后目标机甲，chooser 均为我方）：
##      我方牌信息可见；目标牌背面不可见（hide_card_info）。手牌 <= discard_count 直接全选
##      不弹窗（0 张不弃）。弃置走 EXECUTE_DISCARD 子动作链（POWER_TAX_TRIBUTE_DISCARD_SIDE 哨兵）。
func _handle_power_tax_tribute(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var tt_params: Dictionary = act.get("params", {})
	var tt_bind: Dictionary = payload.get("binding_context", {})
	var tt_owner_mech: StringName = tt_bind.get("mech_id", &"")
	var tt_owner_pid: StringName = tt_bind.get("player_id", &"")
	var tt_cid: StringName = tt_bind.get("card_instance_id", &"")
	if tt_owner_mech == &"" or tt_cid == &"":
		return false
	# AI 持有者：暂不支持
	if _is_ai_owner(tt_owner_pid, tt_owner_mech):
		return false
	action.record["_power_tax_tribute"] = {
		"card_instance_id": tt_cid,
		"owner_mech_id": tt_owner_mech,
		"owner_player_id": tt_owner_pid,
		"params": {
			"base_range": int(tt_params.get("base_range", 4)),
			"counter_key": tt_params.get("counter_key", &""),
			"discard_count": int(tt_params.get("discard_count", 2)),
			"once_per_turn_key": tt_params.get("once_per_turn_key", effect.once_per_turn_key),
		},
	}
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"power_tax_tribute_confirm"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": "发动：X+1 并弃置双方行动牌", "effect_id": &"option_0", "option_index": 0},
		],
		"optional": true,
		"player_id": tt_owner_pid,
		"source_label": String(tt_params.get("confirm_text", effect.description)),
	})
	SLog.log_raw("[TIMING] %s 挂起动力税贡赋确认 effect=%s" % [String(action.action_id), String(effect.effect_id)])
	return true


## ═══════════════════════════════════════════
## 通用「范围内受伤→确认→回复生命+抽行动牌」状态机（INJURY_HEAL_DRAW，芮贝卡 pilot_078 等；复用=复制改参数）
## ═══════════════════════════════════════════
## 监听 HP_CHANGE_SETTLE（实际掉血：decrease 且 value>0；目标=绑定机甲 base_range 格内【含自身】，
##   由通用条件 HP_CHANGE_TARGET_WITHIN_RANGE_INCLUDING_SELF 校验）：
##   ① 确认弹窗给持有者玩家（取消=不发动，不消耗次数）；
##   ② 确认 -> mark once_per_turn（消耗1次，once_per_turn 每玩家回合自动重置）-> 串行
##      [EXECUTE_HP_CHANGE(受伤机甲回复 heal_amount 生命，来源=持有者机甲),
##       EXECUTE_GAIN_CARD(受伤机甲所属玩家抽 draw_count 张行动牌)]。
func _handle_injury_heal_draw(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var ihd_params: Dictionary = act.get("params", {})
	var ihd_bind: Dictionary = payload.get("binding_context", {})
	var ihd_owner_mech: StringName = ihd_bind.get("mech_id", &"")
	var ihd_owner_pid: StringName = ihd_bind.get("player_id", &"")
	var ihd_cid: StringName = ihd_bind.get("card_instance_id", &"")
	if ihd_owner_mech == &"" or ihd_cid == &"":
		return false
	# AI 持有者：暂不支持（用户：先不管 AI 逻辑）
	if _is_ai_owner(ihd_owner_pid, ihd_owner_mech):
		return false
	# 受伤机甲 = 被监听 hp_change 动作的目标（条件已校验：decrease>0 且 base_range 内含自身）
	var ihd_target: StringName = &""
	var ihd_mids: Array = payload.get("mech_ids", [])
	if not ihd_mids.is_empty():
		ihd_target = StringName(ihd_mids[0])
	else:
		ihd_target = StringName(payload.get("target_id", payload.get("target_mech_id", &"")))
	if ihd_target == &"":
		return false
	# 受伤机甲所属玩家（抽牌接收者）
	var ihd_target_pid: StringName = &""
	if context.game_state.has_method(&"get_player_for_mech"):
		var ihd_tplayer = context.game_state.get_player_for_mech(ihd_target)
		if ihd_tplayer != null:
			ihd_target_pid = ihd_tplayer.player_id
	if ihd_target_pid == &"":
		var ihd_tmech = context.game_state.mechs.get(ihd_target)
		if ihd_tmech != null:
			ihd_target_pid = ihd_tmech.owner_player_id
	if ihd_target_pid == &"":
		return false
	# 剩余可发动次数（确认弹窗展示用）
	var ihd_key0: StringName = ihd_params.get("once_per_turn_key", effect.once_per_turn_key)
	var ihd_used: int = 0
	if ihd_key0 != &"":
		var ihd_ckey0: String = "%s:%s" % [String(ihd_cid), String(ihd_key0)]
		var ihd_turn0: int = _current_turn_number()
		var ihd_tmap0: Dictionary = _once_per_turn_used.get(ihd_ckey0, {})
		ihd_used = int(ihd_tmap0.get(ihd_turn0, 0))
	var ihd_remain: int = maxi(0, int(effect.once_per_turn_max) - ihd_used)
	var ihd_heal: int = int(ihd_params.get("heal_amount", 2))
	var ihd_draw: int = int(ihd_params.get("draw_count", 1))
	# 受伤机甲显示名
	var ihd_tname: String = String(ihd_target)
	var ihd_tm2 = context.game_state.mechs.get(ihd_target)
	if ihd_tm2 != null and ihd_tm2.has_method(&"get_display_name"):
		ihd_tname = ihd_tm2.get_display_name()
	action.record["_injury_heal_draw"] = {
		"card_instance_id": ihd_cid,
		"owner_mech_id": ihd_owner_mech,
		"owner_player_id": ihd_owner_pid,
		"target_mech_id": ihd_target,
		"target_player_id": ihd_target_pid,
		"params": {
			"heal_amount": ihd_heal,
			"draw_count": ihd_draw,
			"once_per_turn_key": ihd_key0,
		},
	}
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"injury_heal_draw_confirm"}
	action.state = &"waiting_timing"
	var ihd_label: String = "确认：%s回复%d生命并抽%d张行动牌" % [ihd_tname, ihd_heal, ihd_draw]
	var ihd_src: String = String(ihd_params.get("confirm_text", ""))
	if ihd_src.strip_edges() == "":
		ihd_src = "范围内机甲受到伤害，是否使其回复%d生命并抽%d张行动牌？（本回合可发动%d次）" % [ihd_heal, ihd_draw, ihd_remain]
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": ihd_label, "effect_id": &"option_0", "option_index": 0},
		],
		"optional": true,
		"player_id": ihd_owner_pid,
		"source_label": ihd_src,
	})
	SLog.log_raw("[TIMING] %s 挂起受伤回复确认 目标=%s 剩余次数=%d effect=%s" % [String(action.action_id), String(ihd_target), ihd_remain, String(effect.effect_id)])
	return true


## ATTACK_SETTLE_DRAW_REATTACK：范围内攻击结算触发（维奥拉 pilot_077 等）。
## 触发先抽 draw_count 张行动牌（强制，无次数限制），再每回合1次弹多选窗弃 discard_count 张
## （可取消不计次数）-> 给攻击方开凯威攻击窗口。仿 INJURY_HEAL_DRAW 状态机。
func _handle_attack_settle_draw_reattack(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null or context.action_service == null:
		return false
	var asdr_params: Dictionary = act.get("params", {})
	var asdr_bind: Dictionary = payload.get("binding_context", {})
	var asdr_owner_pid: StringName = asdr_bind.get("player_id", &"")
	var asdr_owner_mech: StringName = asdr_bind.get("mech_id", &"")
	var asdr_cid: StringName = asdr_bind.get("card_instance_id", &"")
	if asdr_owner_mech == &"" or asdr_cid == &"":
		return false
	# AI 持有者：暂不支持（用户：先不管 AI 逻辑）
	if _is_ai_owner(asdr_owner_pid, asdr_owner_mech):
		return false
	# 攻击方机甲 = 被监听 attack 动作的攻击者（条件已校验：base_range 内含自身）
	var asdr_attacker: StringName = payload.get("attacker_id", &"")
	if asdr_attacker == &"":
		return false
	var asdr_atk_mech = context.game_state.mechs.get(asdr_attacker)
	if asdr_atk_mech == null or asdr_atk_mech.destroyed:
		return false
	var asdr_atk_pid: StringName = asdr_atk_mech.owner_player_id
	# AI 攻击方：暂不支持（用户：先不管 AI 逻辑）
	if _is_ai_owner(asdr_atk_pid, asdr_attacker):
		return false
	action.record["_attack_settle_draw_reattack"] = {
		"card_instance_id": asdr_cid,
		"owner_mech_id": asdr_owner_mech,
		"owner_player_id": asdr_owner_pid,
		"attacker_mech_id": asdr_attacker,
		"attacker_player_id": asdr_atk_pid,
		"attack_action_id": payload.get("action_id", &""),
		"params": {
			"draw_count": int(asdr_params.get("draw_count", 1)),
			"discard_count": int(asdr_params.get("discard_count", 2)),
			"once_per_turn_key": asdr_params.get("once_per_turn_key", effect.once_per_turn_key),
		},
	}
	# 串行链：先强制抽牌，再检查每回合1次+手牌弹弃牌窗
	action.record["_seq_effect_actions"] = {"payload": payload, "remaining": [
		{"type": &"EXECUTE_GAIN_CARD", "params": {
			"from_zone": &"action_deck",
			"card_kind": &"action",
			"count": int(asdr_params.get("draw_count", 1)),
			"player_id": asdr_owner_pid,
			"reason": &"attack_settle_draw_reattack",
		}},
		{"type": &"ATTACK_SETTLE_DRAW_REATTACK_AFTER_DRAW", "params": {}},
	], "source_check": false, "effect": effect}
	SLog.log_raw("[TIMING] %s 攻击结算触发 攻击方=%s 抽%d张 effect=%s" % [String(action.action_id), String(asdr_attacker), int(asdr_params.get("draw_count", 1)), String(effect.effect_id)])
	if not _continue_seq_effect_actions(action):
		return false
	return true


## 抽牌完成哨兵：每回合1次可用（key 非空时）+ 手牌足够才弹多选窗选 discard_count 张。
## 取消 -> resume phase 不 mark 不弃直接恢复主机；确认 -> mark 次数 + EXECUTE_DISCARD + 开窗。
func _asdr_offer_discard(action, payload: Dictionary, effect) -> bool:
	if context == null or context.game_state == null or context.action_service == null:
		return false
	var asdr_ctx: Dictionary = action.record.get("_attack_settle_draw_reattack", {})
	if asdr_ctx.is_empty():
		return false
	var asdr_p: Dictionary = asdr_ctx.get("params", {})
	var asdr_cid: StringName = asdr_ctx.get("card_instance_id", &"")
	var asdr_owner_pid: StringName = asdr_ctx.get("owner_player_id", &"")
	var asdr_discard: int = int(asdr_p.get("discard_count", 2))
	var asdr_key: StringName = asdr_p.get("once_per_turn_key", &"")
	if asdr_key != &"" and not is_once_per_turn_key_available(asdr_key, asdr_cid, 1):
		SLog.log_raw("[TIMING] %s 攻击结算弃牌每回合次数已用，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	var asdr_player = context.game_state.players.get(asdr_owner_pid)
	if asdr_player == null:
		return false
	var asdr_hand: Array = asdr_player.action_hand.duplicate()
	if asdr_hand.size() < asdr_discard:
		return false
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"attack_settle_draw_reattack_discard"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"thrust_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": asdr_hand,
		"player_id": asdr_owner_pid,
		"label": "弃置%d张行动牌，使攻击方再立即发动1次攻击？" % asdr_discard,
		"per_card_suffix": "",
		"confirm_verb": "弃置",
		"cancel_label": "不发动",
		"max_count": asdr_discard,
		"min_count": asdr_discard,
		"no_cancel": false,
	})
	SLog.log_raw("[TIMING] %s 挂起攻击结算弃牌（%d张里选%d）effect=%s" % [String(action.action_id), asdr_hand.size(), asdr_discard, String(effect.effect_id)])
	return true


## 弃牌完成哨兵：给攻击方开凯威攻击窗口（攻击动作完整完成后打开，避免结算中途开窗）。
func _asdr_open_attack_window(action, payload: Dictionary, effect) -> void:
	if context == null or context.game_state == null or context.action_service == null:
		return
	var asdr_ctx: Dictionary = action.record.get("_attack_settle_draw_reattack", {})
	if asdr_ctx.is_empty():
		return
	var asdr_atk_pid: StringName = asdr_ctx.get("attacker_player_id", &"")
	var asdr_atk_mid: StringName = asdr_ctx.get("attacker_mech_id", &"")
	var asdr_atk_action_id: StringName = asdr_ctx.get("attack_action_id", &"")
	action.record.erase("_attack_settle_draw_reattack")
	if asdr_atk_pid == &"" or asdr_atk_mid == &"":
		return
	if asdr_atk_action_id != &"":
		context.action_service.run_after_action_completed(asdr_atk_action_id, Callable(self, "_asdr_do_open_window").bind(asdr_atk_pid, asdr_atk_mid))
	else:
		_asdr_do_open_window(asdr_atk_pid, asdr_atk_mid)


func _asdr_do_open_window(atk_pid: StringName, atk_mid: StringName) -> void:
	if context == null or context.game_state == null:
		return
	_ActionPilotEffects.attack_window_open(context.game_state, atk_pid, atk_mid)
	SLog.log_raw("[TIMING] 攻击结算弃牌后给 %s/%s 开凯威攻击窗口" % [String(atk_pid), String(atk_mid)])


## 弃牌侧处理（POWER_TAX_TRIBUTE_DISCARD_SIDE 哨兵调用，也用于 resume 直接续跑）：
## side=owner -> 我方行动牌（信息可见）；side=target -> 目标机甲行动牌（牌背 hide_card_info）。
## 手牌 <= discard_count 直接全选 EXECUTE_DISCARD（0 张不弃）；否则弹多选窗（min=max=count
## no_cancel 必选，chooser 均为我方玩家）。返回 true=已挂起/子动作未完成。
func _power_tax_tribute_discard_side(action, payload: Dictionary, effect, side: StringName) -> bool:
	if context == null or context.game_state == null or context.action_service == null:
		return false
	var tt_ctx: Dictionary = action.record.get("_power_tax_tribute", {})
	var tt_p: Dictionary = tt_ctx.get("params", {})
	var tt_count: int = int(tt_p.get("discard_count", 2))
	var tt_owner_pid: StringName = tt_ctx.get("owner_player_id", &"")
	var tt_side_pid: StringName = tt_owner_pid
	var tt_side_mech: StringName = tt_ctx.get("owner_mech_id", &"")
	var tt_hide: bool = false
	var tt_label: String = "弃置我方%d张行动牌" % tt_count
	if side == &"target":
		tt_side_mech = tt_ctx.get("target_mech_id", &"")
		var tt_side_player = context.game_state.get_player_for_mech(tt_side_mech)
		if tt_side_player == null:
			return false
		tt_side_pid = tt_side_player.player_id
		tt_hide = true  # 别人的牌不可见：牌背显示，选择权在我方
		var tt_tname: String = String(tt_side_mech)
		var tt_tm = context.game_state.mechs.get(tt_side_mech)
		if tt_tm != null:
			tt_tname = tt_tm.get_display_name() if tt_tm.has_method("get_display_name") else tt_tname
		tt_label = "弃置%s的%d张行动牌（牌背）" % [tt_tname, tt_count]
	var tt_player = context.game_state.players.get(tt_side_pid)
	if tt_player == null:
		return false
	var tt_cards: Array = []
	for hand_cid: StringName in tt_player.action_hand:
		tt_cards.append(hand_cid)
	tt_ctx["discard_side"] = side
	action.record["_power_tax_tribute"] = tt_ctx
	# <= discard_count：直接全选弃置（不弹窗；0 张不弃）
	if tt_cards.size() <= tt_count:
		if tt_cards.is_empty():
			SLog.log_raw("[TIMING] %s 动力税贡 tribute %s 侧无行动牌，跳过" % [String(action.action_id), String(side)])
			return false
		context.action_service.execute_sub_action({"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": tt_cards, "reason": &"power_tax_tribute",
		}}, payload, action)
		SLog.log_raw("[TIMING] %s 动力税贡 tribute %s 侧手牌≤%d 直接全弃 %d 张" % [String(action.action_id), String(side), tt_count, tt_cards.size()])
		return _last_created_sub_action_paused(action)
	# 弹多选窗（必选 count 张，不可取消；chooser=我方玩家）
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"power_tax_tribute_discard"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"thrust_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": tt_cards,
		"player_id": tt_owner_pid,
		"label": tt_label,
		"per_card_suffix": "",
		"confirm_verb": "弃置",
		"cancel_label": "取消",
		"max_count": tt_count,
		"min_count": tt_count,
		"no_cancel": true,
		"hide_card_info": tt_hide,
	})
	SLog.log_raw("[TIMING] %s 挂起动力税贡 tribute %s 侧选牌（%d张里选%d）hide=%s" % [String(action.action_id), String(side), tt_cards.size(), tt_count, tt_hide])
	return true


## pilot_018 苔丝 effect_01b：迎击后弃攻击方的2张行动牌或1张损伤≥2装备牌。
## 两阶段：①CHOOSE_ONE 选弃行动牌/装备牌（仅1种可行则自动选，0种可行则跳过）；
##         ②选行动牌：≥3弹复选选2，=2直接弃，<2直接弃全部；选装备牌：列出损伤≥2装备牌选1（无则结束）。
## 弃置走 discard_card 动作（card_ids 指定）。弃的是本次攻击武器牌时，attack_action._step_check_hit
## 检测 _weapon_still_held 失败 -> 未命中立即结算（不造成伤害）。
## 返回 true=已挂起（等玩家选），false=已完成或无可弃（继续推进 attack）。
func _handle_pilot_018_respond_discard(_act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	# 攻击方机甲（attacker_id）-> 反查玩家
	var p18_attacker: StringName = payload.get("attacker_id", &"")
	if p18_attacker == &"":
		return false
	var p18_attacker_player = context.game_state.get_player_for_mech(p18_attacker)
	if p18_attacker_player == null:
		return false
	var p18_attacker_pid: StringName = p18_attacker_player.player_id
	# 去重守卫：同一 attack 只处理一次
	if action.record.get("_pilot_018_discard_done", false):
		return false
	# 已选过类型（resume 重跑）-> 走分支处理
	if payload.has("pilot_018_chosen_type"):
		return _pilot_018_execute_discard(effect, payload, action, p18_attacker, p18_attacker_pid)
	# 收集攻击方可弃行动牌 + 损伤≥2装备牌
	var p18_action_cards: Array = []
	for hand_cid in p18_attacker_player.action_hand:
		p18_action_cards.append(hand_cid)
	var p18_equipment_cards: Array = []  # [{card_id, slot_id, name, kind, damage, durability}]
	var p18_mech = context.game_state.mechs.get(p18_attacker)
	if p18_mech != null:
		for sid in p18_mech.slots:
			var slot = p18_mech.slots[sid]
			if slot == null or slot.equipped_card == null:
				continue
			var ec = slot.equipped_card
			if ec.def == null:
				continue
			if ec.get("face_down") == true:
				continue  # 备用区背面装备不弃
			# 损伤≥2（取装备牌上的 damage_tokens）
			if int(ec.damage_tokens) >= 2:
				var _ekind: String = String(ec.def.equipment_kind) if "equipment_kind" in ec.def else ""
				var _edur: int = int(ec.def.durability) if "durability" in ec.def else 0
				p18_equipment_cards.append({
					"card_id": ec.instance_id, "slot_id": sid,
					"name": String(ec.def.display_name), "kind": _ekind,
					"damage": int(ec.damage_tokens), "durability": _edur,
				})
	# 构造 CHOOSE_ONE options
	var p18_options: Array = []
	if not p18_action_cards.is_empty():
		p18_options.append({"label": "弃置2张行动牌", "value": &"action_cards"})
	if not p18_equipment_cards.is_empty():
		p18_options.append({"label": "弃置1张损伤≥2装备牌", "value": &"equipment_card"})
	# 0 个可选 -> 无事发生
	if p18_options.is_empty():
		SLog.log_raw("[TIMING] %s pilot_018 迎击弃牌：攻击方无可弃行动牌/损伤≥2装备牌，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		action.record["_pilot_018_discard_done"] = true
		return false
	# 仅1个可选 -> 自动选（无需弹窗）
	if p18_options.size() == 1:
		payload["pilot_018_chosen_type"] = p18_options[0]["value"]
		return _pilot_018_execute_discard(effect, payload, action, p18_attacker, p18_attacker_pid)
	# 苔丝拥有者（弹窗给苔丝玩家选）
	var p18_bind: Dictionary = payload.get("binding_context", {})
	var p18_owner_pid: StringName = p18_bind.get("player_id", &"")
	var p18_mech_id: StringName = p18_bind.get("mech_id", &"")
	# AI 苔丝：暂不支持决策，跳过（不弃牌）
	if _is_ai_owner(p18_owner_pid, p18_mech_id):
		SLog.log_raw("[TIMING] %s pilot_018 迎击弃牌：苔丝为 AI，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		action.record["_pilot_018_discard_done"] = true
		return false
	# 挂起弹 CHOOSE_ONE（苔丝玩家选弃行动牌/装备牌）
	action.record["_pilot_018_discard_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_018_choose_type"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [{
			"label": String(p18_options[0].get("label", "")), "effect_id": &"option_0", "option_index": 0,
		}, {
			"label": String(p18_options[1].get("label", "")), "effect_id": &"option_1", "option_index": 1,
		}],
		"optional": false,
		"player_id": p18_owner_pid,
		"source_label": "苔丝：我方迎击响应成功，选择弃置攻击方的2张行动牌或1张损伤≥2装备牌（弃攻击武器牌则此攻击失效）",
	})
	SLog.log_raw("[TIMING] %s pilot_018 迎击弃牌弹窗 effect=%s 攻击方行动牌=%d 损伤≥2装备=%d" % [String(action.action_id), String(effect.effect_id), p18_action_cards.size(), p18_equipment_cards.size()])
	return true


## pilot_025 约书亚 1b：选1张备用区装备牌设置 + 抽2张行动牌。
## CHOOSE_ONE 确认后分支内执行：收集备用区装备 -> 弹单选窗 -> 选目标槽 -> 移除备用区设入 +
## set_equipment 子动作（即时使用 hook 自动生效）-> 抽2张行动牌（_seq 串行）。
## 返回 true=已挂起弹窗；false=无需处理（无备用装备/AI/已完成）交由调用方继续。
func _handle_pilot_025_select_reserve_and_set(_act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	# 去重守卫：同一 effect 只处理一次（resume 重跑 _execute_effect 时跳过）
	if action.record.get("_pilot_025_done", false):
		return false
	var p025_bind: Dictionary = payload.get("binding_context", {})
	var p025_mech_id: StringName = p025_bind.get("mech_id", &"")
	var p025_owner_pid: StringName = p025_bind.get("player_id", &"")
	if p025_mech_id == &"":
		return false
	var p025_mech = context.game_state.mechs.get(p025_mech_id)
	if p025_mech == null:
		return false
	# 收集备用区装备牌（reserve_1/reserve_2 的 equipped_card）
	var p025_candidates: Array = []
	for p025_sid in [&"reserve_1", &"reserve_2"]:
		var p025_slot = p025_mech.slots.get(p025_sid)
		if p025_slot == null or p025_slot.equipped_card == null:
			continue
		var p025_ec = p025_slot.equipped_card
		if p025_ec.def == null:
			continue
		var p025_ekind: String = String(p025_ec.def.equipment_kind) if "equipment_kind" in p025_ec.def else "PART"
		var p025_kind_label: String = "武器" if p025_ekind == &"WEAPON" else ("部件" if p025_ekind == &"PART" else p025_ekind)
		p025_candidates.append({
			"card_id": p025_ec.instance_id, "slot_id": p025_sid,
			"name": String(p025_ec.def.display_name), "kind": p025_ekind, "kind_label": p025_kind_label,
		})
	if p025_candidates.is_empty():
		SLog.log_raw("[TIMING] %s pilot_025 备用区无装备，跳过 1b effect=%s" % [String(action.action_id), String(effect.effect_id)])
		action.record["_pilot_025_done"] = true
		return false
	# AI 约书亚：暂不支持决策，跳过（不设置/抽牌）。避免弹窗挂死。
	if _is_ai_owner(p025_owner_pid, p025_mech_id):
		SLog.log_raw("[TIMING] %s pilot_025 约书亚为 AI，跳过 1b effect=%s" % [String(action.action_id), String(effect.effect_id)])
		action.record["_pilot_025_done"] = true
		return false
	# 挂起弹单选窗（约书亚玩家选1张备用区装备）
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_025_reserve_select"}
	action.state = &"waiting_timing"
	var p025_ui_opts: Array[Dictionary] = []
	for p025_c in p025_candidates:
		if p025_c is Dictionary:
			p025_ui_opts.append({
				"label": "%s [%s]" % [String(p025_c.get("name", "")), String(p025_c.get("kind_label", ""))],
				"effect_id": p025_c.get("card_id", &""),
			})
	action_needs_input.emit(action.action_id, &"pilot_025_reserve_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": p025_ui_opts,
		"player_id": p025_owner_pid,
		"label": "约书亚：选择1张备用区装备牌设置到区域（并抽2张行动牌）",
	})
	SLog.log_raw("[TIMING] %s pilot_025 选备用装备弹窗 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p025_candidates.size()])
	return true


# ════════════════════════════════════════════════════════════
# 通用「查看隐藏装备+花费金币获取」（霍恩 pilot_046）
# ════════════════════════════════════════════════════════════
# 效果文本：我方可以无条件查看商店和其他机甲备用区内的隐藏装备牌（背面朝上）。我方回合1次，
#   可以消耗隐藏装备牌其上记述的金币获得该牌，之后将其背面朝上置于我方或其他机甲的备用区域上。
# 通用机制（不绑机师，复用=整段复制改参数）：
#   - HIDDEN_VIEW_AND_ACQUIRE act_type（_execute_actions 分发到 _handle_hidden_view_and_acquire）：
#       Phase A 打开 hidden_card_view_panel（阻塞，可关闭=取消效果可反复再点；打开即给商店隐藏牌
#       known_to 标记本玩家，幂等）。候选 = 商店隐藏高级槽 + 所有其他玩家机甲 RESERVE 槽白板。
#       Phase B（resume_pending_effect phase=hidden_reserve_slot）选目标 RESERVE 槽（全部玩家，
#       allow_cancel=false）→ 清来源 + 重置卡归属 + 追加目标手牌 →
#       _seq[SPEND_GOLD(牌面原价), MARK_EFFECT_ONCE_PER_TURN_USED, EXECUTE_SET_EQUIP(card,mech,slot)]。
#   - 查看无条件：effect 不设 once_per_turn_key（按钮常亮）；获取每回合1次由内部
#     is_once_per_turn_key_available(once_per_turn_key, binding.card_instance_id) 校验 + 面板置灰。
#   - 商店隐藏牌每玩家独立得知：known_to（CardInstance.known_to，已快照）。商店面板/买价按
#     (shop.hidden_revealed 或 known_to 含查看者) 显示真名+1.5x 价；否则 ★★★ 隐藏卡 ★★★ + 10金盲买。

## HIDDEN_VIEW_AND_ACQUIRE 首次执行：标记商店隐藏牌 known_to + 收集候选 + 打开查看面板（阻塞）。
func _handle_hidden_view_and_acquire(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	# 去重守卫：resume 重跑 _execute_effect 时跳过本动作（面板只开一次）
	if action.record.get("_pilot_046_panel_shown", false):
		return false
	var hva_params: Dictionary = act.get("params", {})
	var hva_bind: Dictionary = payload.get("binding_context", {})
	var hva_owner_pid: StringName = hva_bind.get("player_id", &"")
	var hva_mech_id: StringName = hva_bind.get("mech_id", &"")
	if hva_owner_pid == &"" or hva_mech_id == &"":
		return false
	# AI 跳过（暂不处理 AI 逻辑，避免弹窗挂死）
	if _is_ai_owner(hva_owner_pid, hva_mech_id):
		action.record["_pilot_046_panel_shown"] = true
		return false
	var gs = context.game_state
	# 打开面板即给商店隐藏牌标记已知（每玩家独立得知，幂等）
	var shop = gs.shop_state
	if shop != null and shop.hidden_advanced_slot != &"":
		var hva_hidden = gs.get_card(shop.hidden_advanced_slot)
		if hva_hidden != null and hva_hidden.known_to != null and not hva_hidden.known_to.has(hva_owner_pid):
			hva_hidden.known_to.append(hva_owner_pid)
			SLog.log_raw("[TIMING] %s 霍恩查看商店隐藏牌标记已知 %s effect=%s" % [String(action.action_id), String(hva_owner_pid), String(effect.effect_id)])
	# 收集候选（商店隐藏 + 其他玩家备用区白板）
	var hva_candidates: Array = _collect_hidden_view_candidates(hva_owner_pid)
	action.record["_pilot_046_panel_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"hidden_card_view", "act": act, "owner_pid": hva_owner_pid}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"hidden_card_view", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"player_id": hva_owner_pid,
		"candidates": hva_candidates,
		"once_per_turn_key": hva_params.get("once_per_turn_key", &""),
		"source_card_instance_id": hva_bind.get("card_instance_id", &""),
	})
	SLog.log_raw("[TIMING] %s 打开隐藏装备查看面板 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), hva_candidates.size()])
	return true


## 收集隐藏装备候选：商店隐藏高级槽 + 所有其他玩家机甲 RESERVE 槽（白板）。每项含 card_id/name/cost/来源。
func _collect_hidden_view_candidates(owner_pid: StringName) -> Array:
	var out: Array = []
	var gs = context.game_state
	if gs == null:
		return out
	# 商店隐藏高级槽
	var shop = gs.shop_state
	if shop != null and shop.hidden_advanced_slot != &"":
		var sc = gs.get_card(shop.hidden_advanced_slot)
		if sc != null and sc.def != null:
			out.append({
				"card_id": sc.instance_id,
				"name": String(sc.def.display_name),
				"rarity": String(sc.def.rarity),
				"cost": _hidden_card_face_cost(sc),
				"source_type": &"shop",
				"source_label": "商店",
			})
	# 其他玩家机甲 RESERVE 槽（排除自己）
	for m in gs.mechs.values():
		if m == null or String(m.owner_player_id) == String(owner_pid):
			continue
		for sid in m.slots:
			var slot = m.slots[sid]
			if slot == null or slot.slot_kind != &"RESERVE" or slot.equipped_card == null:
				continue
			var ec = slot.equipped_card
			if ec.def == null:
				continue
			var mname: String = String(m.frame_def.display_name) if m.frame_def != null and "display_name" in m.frame_def else String(m.mech_id)
			out.append({
				"card_id": ec.instance_id,
				"name": String(ec.def.display_name),
				"rarity": String(ec.def.rarity),
				"cost": _hidden_card_face_cost(ec),
				"source_type": &"reserve",
				"source_label": "%s·备用区" % mname,
				"source_mech_id": m.mech_id,
				"source_slot_id": sid,
			})
	return out


## 隐藏装备牌牌面原价（card.def.cost，缺省回退商店 1.5x 买价作为基准）。
func _hidden_card_face_cost(card) -> int:
	if card == null or card.def == null:
		return 0
	if "cost" in card.def and int(card.def.cost) > 0:
		return int(card.def.cost)
	if context != null and context.shop_service != null:
		return context.shop_service._get_buy_price(card)
	return 3


## 清空隐藏牌来源（商店隐藏槽 / 来源机甲 RESERVE 槽），重置 zone/mech/slot/face_down。
func _clear_hidden_card_source(card, gs) -> void:
	if gs == null or card == null:
		return
	if gs.shop_state != null and gs.shop_state.hidden_advanced_slot == card.instance_id:
		gs.shop_state.hidden_advanced_slot = &""
	for m in gs.mechs.values():
		if m == null:
			continue
		for sid in m.slots:
			var slot = m.slots[sid]
			if slot != null and slot.equipped_card != null and slot.equipped_card.instance_id == card.instance_id:
				slot.equipped_card = null
	card.zone = &""
	card.mech_id = &""
	card.slot_id = &""
	card.face_down = false


## CHOOSE_RESERVE_SLOT_AND_SET_EQUIP（通用「抽到的装备背面置备用区」第2阶段，法尔科 pilot_073 等）：
## 读取父 record[sink_key] 拿抽到的牌 → 收集全部机甲 RESERVE 槽（仅显示占位不翻牌，强制选择不可取消）
## → 复用 hidden_reserve_slot 弹窗（phase=choose_reserve_slot_and_set）→ 确认后效果驱动背面设置。
## params: {sink_key(默认 effect_id_drawn), label}
func _handle_choose_reserve_slot_and_set(act: Dictionary, effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var rs_params: Dictionary = act.get("params", {})
	var rs_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var rs_owner_pid: StringName = rs_bind.get("player_id", &"")
	var rs_mech_id: StringName = rs_bind.get("mech_id", &"")
	if rs_owner_pid == &"":
		return false
	# AI 跳过（暂不处理 AI 逻辑，避免弹窗挂死；抽到的牌保留在手牌，下回合开始清标签）
	if _is_ai_owner(rs_owner_pid, rs_mech_id):
		return false
	var rs_sink_key: StringName = rs_params.get("sink_key", &"%s_drawn" % String(effect.effect_id))
	var rs_drawn: Array = action.record.get(rs_sink_key, [])
	var rs_card_id: StringName = rs_drawn[0] if not rs_drawn.is_empty() else &""
	var rs_card = context.game_state.get_card(rs_card_id)
	if rs_card == null:
		SLog.log_raw("[TIMING] %s %s 抽到的牌缺失（sink=%s），跳过置备用区 effect=%s" % [String(action.action_id), String(act.get("type", &"")), String(rs_sink_key), String(effect.effect_id)])
		return false
	# 收集全部机甲的 RESERVE 槽作为目标候选（含自己；占用仅显示"（有牌）"不翻牌）
	var rs_target_opts: Array[Dictionary] = []
	var rs_target_map: Dictionary = {}
	for rs_m in context.game_state.mechs.values():
		if rs_m == null:
			continue
		for rs_sid in rs_m.slots:
			var rs_slot = rs_m.slots[rs_sid]
			if rs_slot == null or rs_slot.slot_kind != &"RESERVE":
				continue
			var rs_mname: String = String(rs_m.frame_def.display_name) if rs_m.frame_def != null and "display_name" in rs_m.frame_def else String(rs_m.mech_id)
			var rs_opt_id: String = "%s:%s" % [String(rs_m.mech_id), String(rs_sid)]
			rs_target_opts.append({
				"label": "%s·%s%s" % [rs_mname, String(rs_sid), "（有牌）" if rs_slot.equipped_card != null else "（空）"],
				"effect_id": StringName(rs_opt_id),
			})
			rs_target_map[rs_opt_id] = {"mech_id": rs_m.mech_id, "slot_id": rs_sid}
	if rs_target_opts.is_empty():
		SLog.log_raw("[TIMING] %s %s 无目标备用区，跳过 effect=%s" % [String(action.action_id), String(act.get("type", &"")), String(effect.effect_id)])
		return false
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
		"phase": &"choose_reserve_slot_and_set", "act": act, "owner_pid": rs_owner_pid,
		"card_id": rs_card_id, "target_map": rs_target_map}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"hidden_reserve_slot", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"player_id": rs_owner_pid,
		"options": rs_target_opts,
		"label": rs_params.get("label", "选择放置的备用区域（该牌背面朝上，替换旧牌）"),
	})
	SLog.log_raw("[TIMING] %s %s 选目标备用区 effect=%s 牌=%s" % [String(action.action_id), String(act.get("type", &"")), String(effect.effect_id), String(rs_card_id)])
	return true


## pilot_018 弃牌分支执行：按 chosen_type 弃行动牌或装备牌。
func _pilot_018_execute_discard(effect: ActionEffect, payload: Dictionary, action, attacker_mech: StringName, attacker_pid: StringName) -> bool:
	var p18_chosen: StringName = payload.get("pilot_018_chosen_type", &"")
	var p18_bind: Dictionary = payload.get("binding_context", {})
	var p18_owner_pid: StringName = p18_bind.get("player_id", &"")
	var p18_mech_id: StringName = p18_bind.get("mech_id", &"")
	var p18_attacker_player = context.game_state.players.get(attacker_pid) if context.game_state != null else null
	if p18_chosen == &"action_cards":
		# 弃2张行动牌：=2直接弃，<2直接弃全部，≥3弹复选选2
		if p18_attacker_player == null:
			action.record["_pilot_018_discard_done"] = true
			return false
		var p18_hand: Array = []
		for hand_cid in p18_attacker_player.action_hand:
			p18_hand.append(hand_cid)
		if p18_hand.size() <= 2:
			# 直接弃全部
			_pilot_018_do_discard(action, p18_hand, attacker_pid)
			action.record["_pilot_018_discard_done"] = true
			return false
		# ≥3张：弹复选选2（苔丝玩家选攻击方哪2张）
		# AI 苔丝跳过
		if _is_ai_owner(p18_owner_pid, p18_mech_id):
			action.record["_pilot_018_discard_done"] = true
			return false
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_018_select_action_cards"}
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"select_discard_cards", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"card_ids": p18_hand,
			# 弹窗给苔丝玩家操作（_popup_owner 优先 executor），弃的是攻击方（discard_player_id）的牌
			"player_id": p18_owner_pid,
			"executor": p18_owner_pid,
			"discard_player_id": attacker_pid,
			# 恰好弃2张：count/max_count=2 允许多选，min_count=2 确认按钮灰置直到选满，no_cancel 强制
			"count": 2,
			"max_count": 2,
			"min_count": 2,
			# 暗牌：PvP 下苔丝看不到攻击方手牌，只显示"行动牌 #N"
			"face_up": false,
			"no_cancel": true,
			"mode": &"resume_pending",
			"source_label": "苔丝：选择攻击方要弃置的2张行动牌（暗牌）",
		})
		SLog.log_raw("[TIMING] %s pilot_018 弃行动牌复选 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p18_hand.size()])
		return true
	elif p18_chosen == &"equipment_card":
		# 弃1张损伤≥2装备牌：列出候选弹单选
		var p18_mech = context.game_state.mechs.get(attacker_mech) if context.game_state != null else null
		var p18_eq_candidates: Array = []
		if p18_mech != null:
			for sid in p18_mech.slots:
				var slot = p18_mech.slots[sid]
				if slot == null or slot.equipped_card == null:
					continue
				var ec = slot.equipped_card
				if ec.def == null or ec.get("face_down") == true:
					continue
				if int(ec.damage_tokens) >= 2:
					var _ekind: String = String(ec.def.equipment_kind) if "equipment_kind" in ec.def else ""
					var _edur: int = int(ec.def.durability) if "durability" in ec.def else 0
					p18_eq_candidates.append({
						"card_id": ec.instance_id, "slot_id": sid,
						"name": String(ec.def.display_name), "kind": _ekind,
						"damage": int(ec.damage_tokens), "durability": _edur,
					})
		if p18_eq_candidates.is_empty():
			# 无损伤≥2装备牌（CHOOSE_ONE 选了装备但实际无候选）：结束
			action.record["_pilot_018_discard_done"] = true
			return false
		# AI 苔丝跳过
		if _is_ai_owner(p18_owner_pid, p18_mech_id):
			action.record["_pilot_018_discard_done"] = true
			return false
		# 弹单选窗（苔丝玩家选1张装备牌弃）
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_018_select_equipment"}
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"pilot_018_select_equipment", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"candidates": p18_eq_candidates,
			"player_id": p18_owner_pid,
			"label": "苔丝：选择弃置攻击方的1张损伤≥2装备牌",
		})
		SLog.log_raw("[TIMING] %s pilot_018 弃装备牌单选 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p18_eq_candidates.size()])
		return true
	# 未知类型：结束
	action.record["_pilot_018_discard_done"] = true
	return false


## pilot_018 执行弃置：走 discard_card 动作（card_ids 指定，发 DISCARD 时点）。
## 弃的是本次攻击武器牌时，attack._step_check_hit 检测 _weapon_still_held 失败 -> 未命中。
func _pilot_018_do_discard(_action, card_ids: Array, attacker_pid: StringName) -> void:
	if card_ids.is_empty() or context == null or context.action_service == null:
		return
	if context.action_service != null:
		context.action_service.execute(&"discard_card", {
			"card_ids": card_ids,
			"player_id": attacker_pid,
			"reason": &"pilot_018_respond_discard",
		})


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
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload}
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


## ════════════════════════════════════════════════════════════
# pilot_021 塔莉娅 effect_01：循环赐予行动牌
## ════════════════════════════════════════════════════════════
## 抽3张行动牌打"禁"标签（owner=塔莉娅玩家，本回合塔莉娅无法使用），然后循环：
##   选机甲（4格内其他存活机甲，取消=结束循环）-> 选剩余禁牌(至少1张，取消=回选机甲)
##   -> 转移（GameActions.transfer_action_cards 挂钩自动打"策"标签+清"禁"标签）
## 直到牌给完或选机甲界面取消。循环状态存 action.record["_pilot_021_loop"]；
## 挂起时 _pending_effect 记 phase=pilot_021_choose_mech / pilot_021_choose_cards。
## 抽牌统一走 gain_card 子动作（发 GAIN_CARD_BEFORE/AFTER/SETTLE 时点 + 抽取标，库马斯 pilot_035
## 等 GAIN_CARD_AFTER 监听器可响应"塔莉娅赐予抽3"）；抽取结果经 _draw_result_sink 回写父 record，
## 子动作完成（含异步挂起，由 _continue_pilot_021_draw 续跑）后 _finish_pilot_021_draw 打"禁"标签。
## 返回 true=已挂起(应 return)；false=循环结束/无候选(continue)。
func _handle_pilot_021_loop_deal(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var loop: Dictionary = action.record.get("_pilot_021_loop", {})
	if loop.is_empty():
		# 抽牌子动作是否进行中/已完成（_continue_pilot_021_draw 消费后清空）
		var pending: Dictionary = action.record.get("_pilot_021_draw_pending", {})
		if pending.is_empty():
			var bind = _make_binding_from_effect(effect, action, payload)
			var player_id: StringName = bind.get_owner_player_id()
			var mech_id: StringName = bind.get_source_mech_id()
			if player_id == &"" or mech_id == &"":
				return false
			# 循环开始即 mark 每回合1次：抽牌/赐予循环是"1次效果"，开始消耗就占住额度，
			# 避免弹窗挂起期间按钮仍可点、重复点击再抽3张。循环结束 _finish_pilot_021_deal 会再 mark 一次
			# （计数累加>max 无副作用，used_up 判定是 used>=max）。
			_mark_once_per_turn_used(effect, payload)
			action.record["_pilot_021_draw_pending"] = {
				"player_id": player_id, "mech_id": mech_id,
				"effect_ref": effect, "payload_ref": payload,
			}
			if context.action_service != null:
				context.action_service.execute_sub_action({
					"type": &"EXECUTE_GAIN_CARD",
					"params": {
						"from_zone": &"action_deck", "card_kind": &"action", "count": 3,
						"player_id": player_id, "reason": &"pilot_021_draw_3",
						# 抽取结果回写父 record["_pilot_021_draw_drawn"]（子动作完成后读）
						"_draw_result_sink": {"parent_action_id": action.action_id, "key": &"_pilot_021_draw_drawn"},
					},
				}, payload, action)
				# 子动作异步挂起（库马斯监听 GAIN_CARD_AFTER 触发子动作）-> 父挂起等 _continue_pilot_021_draw
				if _last_created_sub_action_paused(action):
					return true
			# 子动作同步完成：sink 已把 drawn 回写父 record
			action.record.erase("_pilot_021_draw_pending")
			var drawn: Array = action.record.get("_pilot_021_draw_drawn", [])
			action.record.erase("_pilot_021_draw_drawn")
			_finish_pilot_021_draw(action, effect, payload, player_id, mech_id, drawn)
			return _pilot_021_choose_mech(effect, payload, action, action.record.get("_pilot_021_loop", {}))
		# 防御：_continue_pilot_021_draw 已消费 pending，理论不达此处
		return false
	# 已有 loop：进入选机甲阶段
	return _pilot_021_choose_mech(effect, payload, action, loop)


## 塔莉娅 effect_01 抽牌完成（同步/异步共用）：打"禁"标签 + 存 loop（剩余牌）+ 日志。
func _finish_pilot_021_draw(action, effect, payload: Dictionary, player_id: StringName, mech_id: StringName, drawn: Array) -> void:
	for cid in drawn:
		var card = context.game_state.get_card(cid)
		if card != null:
			_ActionPilotEffects.pilot_021_tag_jin(card, player_id)
	action.record["_pilot_021_loop"] = {"player_id": player_id, "mech_id": mech_id, "remaining": drawn}
	SLog.log_raw("[pilot_021] 塔莉娅抽3张行动牌打禁标签 player=%s drawn=%d" % [String(player_id), drawn.size()])


## 塔莉娅 effect_01 抽牌子动作（EXECUTE_GAIN_CARD）完成后的续跑：打"禁"标签 + 进选机甲循环。
## 供 ActionEngine._after_sub_action_finished 调用。返回 true=又挂起（选机甲/选牌），false=处理完毕。
func _continue_pilot_021_draw(parent_action) -> bool:
	if parent_action == null or not parent_action.record.has("_pilot_021_draw_pending"):
		return false
	if parent_action.record.has("_pilot_021_loop"):
		# 防御：循环已开始，清 pending 直接继续选机甲
		var _ploop: Dictionary = parent_action.record["_pilot_021_loop"]
		parent_action.record.erase("_pilot_021_draw_pending")
		parent_action.record.erase("_pilot_021_draw_drawn")
		return _pilot_021_choose_mech(_ploop.get("_effect_ref", null), _ploop.get("_payload_ref", {}), parent_action, _ploop)
	var pending: Dictionary = parent_action.record["_pilot_021_draw_pending"]
	var player_id: StringName = pending.get("player_id", &"")
	var mech_id: StringName = pending.get("mech_id", &"")
	var effect = pending.get("effect_ref", null)
	var payload: Dictionary = pending.get("payload_ref", {})
	var drawn: Array = parent_action.record.get("_pilot_021_draw_drawn", [])
	parent_action.record.erase("_pilot_021_draw_pending")
	parent_action.record.erase("_pilot_021_draw_drawn")
	_finish_pilot_021_draw(parent_action, effect, payload, player_id, mech_id, drawn)
	return _pilot_021_choose_mech(effect, payload, parent_action, parent_action.record.get("_pilot_021_loop", {}))


## 效果1循环-选机甲阶段：收集4格内其他存活机甲；无候选=结束循环；人类挂起弹窗。
func _pilot_021_choose_mech(effect, payload: Dictionary, action, loop: Dictionary) -> bool:
	if context == null or context.game_state == null:
		return false
	var player_id: StringName = loop.get("player_id", &"")
	var mech_id: StringName = loop.get("mech_id", &"")
	var remaining: Array = loop.get("remaining", [])
	if remaining.is_empty():
		return false
	var src_mech = context.game_state.mechs.get(mech_id)
	if src_mech == null:
		return false
	var _HexGrid = _ActionPilotEffects._get_hex_grid()
	var candidates: Array[StringName] = []
	for mid: StringName in context.game_state.mechs:
		if mid == mech_id:
			continue
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if _HexGrid.distance(m.position, src_mech.position) <= 4:
			candidates.append(mid)
	if candidates.is_empty():
		SLog.log_raw("[pilot_021] 塔莉娅 4格内无其他机甲，赐予循环结束")
		return false
	# AI：直接把剩余全部牌给第一个候选（不弹窗）
	if _is_ai_owner(player_id, mech_id):
		_transfer_pilot_021_cards(action, loop, remaining, candidates[0])
		loop["remaining"] = []
		action.record["_pilot_021_loop"] = loop
		return false
	# 人类：挂起选机甲（复用 select_mech_target 输入类型，valid_mech_ids 供 app_root 高亮/校验）
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_021_choose_mech"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_mech_target", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"mech_id": mech_id,
		"player_id": player_id,
		"valid_mech_ids": candidates,
		"label": "选择要给予行动牌的机甲（4格内）",
	})
	SLog.log_raw("[TIMING] %s pilot_021 挂起选机甲 candidates=%d" % [String(action.action_id), candidates.size()])
	return true


## 效果1循环-选牌阶段：弹 discard_select_panel 列剩余禁牌（至少选1张，取消=回选机甲不结束循环）。
func _pilot_021_choose_cards(effect, payload: Dictionary, action, loop: Dictionary) -> bool:
	if context == null or context.game_state == null:
		return false
	var player_id: StringName = loop.get("player_id", &"")
	var mech_id: StringName = loop.get("mech_id", &"")
	var remaining: Array = loop.get("remaining", [])
	if remaining.is_empty():
		return false
	# AI：给第一张给当前目标
	if _is_ai_owner(player_id, mech_id):
		var to_mech_id: StringName = loop.get("target_mech", &"")
		if to_mech_id == &"":
			return false
		var give_one: Array = [remaining[0]]
		_transfer_pilot_021_cards(action, loop, give_one, to_mech_id)
		remaining.erase(remaining[0])
		loop["remaining"] = remaining
		action.record["_pilot_021_loop"] = loop
		if remaining.is_empty():
			return false  # 给完结束循环
		return _pilot_021_choose_mech(effect, payload, action, loop)  # 继续选机甲
	# 人类：挂起选牌（discard_select_panel 只列剩余禁牌）
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_021_choose_cards"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_discard_cards", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"discard_player_id": player_id,
		"count": remaining.size(),
		"min_count": 1,
		"face_up": true,
		"action_verb": &"give",
		"source_label": "塔莉娅：选择要给予的行动牌（可取消重选机甲）",
		"title_override": "选择要给予的行动牌（至少1张）",
		"allowed_card_ids": remaining,
		"player_id": player_id,
	})
	SLog.log_raw("[TIMING] %s pilot_021 挂起选牌 remaining=%d" % [String(action.action_id), remaining.size()])
	return true


## 转移指定牌给目标机甲（走 transfer_action_cards -> GameActions 挂钩自动打"策"标签+清"禁"标签）。
func _transfer_pilot_021_cards(action, loop: Dictionary, card_ids: Array, target_mech_id: StringName) -> void:
	if context == null or context.game_state == null or context.game_actions == null:
		return
	var player_id: StringName = loop.get("player_id", &"")
	var to_player_id: StringName = &""
	var target_player = context.game_state.get_player_for_mech(target_mech_id)
	if target_player != null:
		to_player_id = target_player.player_id
	if to_player_id == &"" or card_ids.is_empty():
		return
	context.game_actions.transfer_action_cards({
		"from_player_id": player_id,
		"to_player_id": to_player_id,
		"card_ids": card_ids,
	})
	SLog.log_raw("[pilot_021] 塔莉娅交牌 %d 张 -> mech=%s" % [card_ids.size(), String(target_mech_id)])


## 效果1循环结束：清循环状态 + mark once_per_turn（抽牌已发生，取消也消耗次数）+ 恢复父动作。
## 供 resume_pending_effect 的 pilot_021_choose_mech/pilot_021_choose_cards 分支结束路径调用。
func _finish_pilot_021_deal(effect, payload: Dictionary, action) -> void:
	if action == null:
		return
	action.record.erase("_pilot_021_loop")
	_mark_once_per_turn_used(effect, payload)
	if effect.once_per_game_key != &"":
		_mark_once_per_game_used(effect, payload)
	effect_executed.emit(effect.effect_id, action.action_id)
	_mark_effect_executed(effect.effect_id, action.action_id)
	SLog.log_raw("[TIMING] %s pilot_021 赐予循环结束 effect=%s" % [String(action.action_id), String(effect.effect_id)])
	if context != null and context.action_engine != null:
		action.state = &"waiting_input"
		context.action_engine.continue_action(action.action_id, {})


## 恢复挂起的效果（闪击弹窗玩家选牌/取消；维修等目标选择/二选一续跑）
func resume_pending_effect(action_id: StringName, input_data: Dictionary) -> void:
	if not _pending_effect.has(action_id):
		# 未命中挂起：先入早到信箱（挂起注册后由排空钩子补投），并留响亮告警。
		# 此前静默返回，丢失的 resume 在日志里完全不可见，实机排查只能靠数动作 id
		#（0827 根因⑤）。错 id（发散）输入永远不匹配挂起 -> 信箱有界淘汰兜底，不泄漏。
		SLog.log_raw("[TIMING][WARN] resume_pending_effect 未命中挂起：action=%s 输入键=%s -> 入早到信箱待补投"
			% [String(action_id), str(input_data.keys())])
		_effect_input_mailbox.stash(action_id, input_data)
		return
	var pending: Dictionary = _pending_effect[action_id]
	_pending_effect.erase(action_id)
	# 挂起输入已被本次调用消费：释放共享等待槽中该动作的残留等待（若槽仍指向它），
	# 否则排队语义下效果续跑弹出的新窗（不同动作）会被判"槽被占"而排队不弹。
	# 实机网络路径走 bridge.resolve_effect_input（调用前已清槽，此处幂等）；
	# 直调本方法的路径（测试、非效果弹窗确认）依赖此清理。
	if context != null and context.action_ui_bridge != null:
		context.action_ui_bridge.release_waiting_slot_if_owner(action_id)
	var effect: ActionEffect = pending.get("effect")
	var payload: Dictionary = pending.get("payload", {})
	var phase: StringName = pending.get("phase", &"pre_actions_discard")
	if context == null:
		return
	# 优先从 pending 取 action 引用（TurnService 虚拟 turn action 不注册到 ActionRegistry，
	# registry.get_action 返回 null 会导致 CHOOSE_ONE 确认后无法 resume 到 CHOOSE_INTEGER 等
	# 后续挂起阶段）。回退 registry 取真实 action（ActionEngine 驱动的 use_action_card 等）。
	var action = pending.get("action", null)
	if action == null and context.action_registry != null:
		action = context.action_registry.get_action(action_id)
	# 条件重检豁免（resume 通用）：效果挂起（等待输入/时点）前条件已通过；挂起期间回合可能已切换
	# （TURN_AFTER_END 挂起后 _net_end_turn 立即 start_turn 下家，如弥雅 pilot_071 回合后选机甲），
	# 重检 IS_OWNER_TURN 等依赖 active_player_id 的条件会误判致效果被 skip。所有 resume 分支确认
	# 后重跑 _execute_effect 统一跳过条件重检，仅续跑后续 actions（取消分支不走重跑，无影响）。
	payload["_effect_conditions_prechecked"] = true
	if action == null or effect == null:
		return

	# ── 选目标前确认阶段：确认才进入目标选择，取消=效果不发动 ──
	if phase == &"confirm_before_target":
		action.record.erase("_waiting_for_confirm_before_target")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 选目标前确认被取消，effect=%s 不发动" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 确认：标记已确认，重跑 _execute_effect → 进入目标选择（不再弹确认）
		payload["_effect_confirmed"] = true
		_execute_effect(effect, payload, action)
		# 守卫：重跑后再次挂起（目标选择/其他弹窗）则等待，不可推进父动作
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 獠鼠 pilot_086 骰子确认：确认=掷骰分支出 _seq 动作链；取消=不发动（恢复动作推进）──
	if phase == &"pilot_086_confirm":
		action.record.erase("_pilot_086_confirm_shown")
		var p86_cancelled: bool = input_data.get("cancelled", false) or int(input_data.get("chosen_option_index", -1)) != 0
		if p86_cancelled:
			SLog.log_raw("[TIMING] %s 獠鼠骰子取消，effect=%s 不发动" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		_pilot_086_confirm_resume(effect, payload, action)
		return

	# ── 李 pilot_051 e2 拦截事件牌设置：三选一弹窗 resume ──
	# 取消=不发动不消耗每局1次（原 set_event_card 照常继续，效果正常注册生效）；
	# 弃置(0)=消耗每局1次 + 中止旗 + 摘牌 + EXECUTE_DISCARD；
	# 转设我方(1)=消耗每局1次 + 中止旗 + 摘牌 + EXECUTE_SET_EVENT_CARD 设到我方机甲
	#（完整流程：顶掉我方旧事件牌+注册效果+instant结算；内层 EVENT_SET_BEFORE 重入时
	#  once_per_game 已标记 -> _execute_effect 1434 行自动跳过，无递归）。
	if phase == &"pilot_051_intercept":
		action.record.erase("_pilot_051_intercept_shown")
		var p051_cancelled: bool = input_data.get("cancelled", false)
		var p051_choice: int = int(input_data.get("chosen_option_index", -1))
		if p051_cancelled or p051_choice < 0 or p051_choice > 1:
			SLog.log_raw("[TIMING] %s 李拦截取消（不消耗次数），原设置继续 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 确认：消耗每局1次
		_mark_once_per_game_used(effect, payload)
		var p051_card_id: StringName = payload.get("event_card_id", &"")
		var p051_target_mid: StringName = payload.get("mech_id", &"")
		var p051_card = context.game_state.get_card(p051_card_id) if p051_card_id != &"" else null
		var p051_target_mech = context.game_state.mechs.get(p051_target_mid) if p051_target_mid != &"" else null
		# 摘牌：新牌已入区（EVENT_SET_BEFORE 在放置后 fire）但未注册效果，直接清槽
		if p051_target_mech != null and p051_card != null:
			var p051_slot = p051_target_mech.slots.get(&"event")
			if p051_slot != null and p051_slot.equipped_card == p051_card:
				p051_slot.equipped_card = null
		# 中止旗：set_event_card 剩余步骤（③激活/④instant标记/⑥弃置）全部空跑
		action.record["event_set_cancelled"] = true
		var p051_remaining: Array = []
		if p051_choice == 0:
			p051_remaining.append({"type": &"EXECUTE_DISCARD", "params": {
				"card_ids": [p051_card_id], "count": 1,
				"executor": &"system_default", "reason": &"pilot_051_effect_02",
			}})
		else:
			var p051_li_mid: StringName = payload.get("binding_context", {}).get("mech_id", &"")
			p051_remaining.append({"type": &"EXECUTE_SET_EVENT_CARD", "params": {
				"mech_id": p051_li_mid, "event_card_id": p051_card_id,
			}})
		context.game_state.write_log(&"pilot_051_intercept", {
			"card_id": String(p051_card_id) if p051_card != null and p051_card.def != null else String(p051_card_id),
			"target_mech_id": String(p051_target_mid),
			"branch": "discard" if p051_choice == 0 else "transfer",
		})
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": p051_remaining, "effect": effect}
		action.state = &"waiting_effect_action"
		if _continue_seq_effect_actions(action):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 墨尘 pilot_080 e1 相邻标记交互：移去/移至 弹窗 resume ──
	# 取消=不发动（效果无次数限制，直接恢复推进）；
	# 移去(0)=整格标记全部移除（不触发效果）；
	# 移至(1)=先摘下整格标记（移动本身不触发）-> 免费基础移动（free_move）-> 标记第1次生效
	# -> 完全结束后（含instant弹窗/陷阱连锁）-> 第2次生效，两次相互独立。
	if phase == &"pilot_080_choice":
		action.record.erase("_pilot_080_choice_shown")
		var p080_cancelled: bool = input_data.get("cancelled", false)
		var p080_choice: int = int(input_data.get("chosen_option_index", -1))
		if p080_cancelled or p080_choice < 0:
			SLog.log_raw("[TIMING] %s 墨尘标记交互取消，不发动 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p080_cell: String = String(pending.get("pilot_080_cell", ""))
		var p080_mech_id: StringName = pending.get("pilot_080_mech_id", &"")
		var p080_pid: StringName = pending.get("pilot_080_player_id", &"")
		var p080_parts := p080_cell.split(",")
		var p080_q: int = int(p080_parts[0]) if p080_parts.size() >= 1 else 0
		var p080_r: int = int(p080_parts[1]) if p080_parts.size() >= 2 else 0
		if p080_choice == 0:
			# 移去：整格标记全部移除（不触发）
			var p080_removed: Array = context.game_state.map_state.get_markers_at(p080_q, p080_r)
			for p080_m: Dictionary in p080_removed.duplicate(true):
				context.game_state.map_state.remove_marker(p080_m.get("marker_id", &""))
			context.game_state.write_log(&"pilot_080_marker_removed", {
				"mech_id": String(p080_mech_id), "cell": p080_cell, "count": p080_removed.size(),
			})
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 移至：摘下整格标记（快照）-> 免费移动 -> 第1次生效 -> 第2次生效
		var p080_markers: Array = context.game_state.map_state.get_markers_at(p080_q, p080_r).duplicate(true)
		for p080_m2: Dictionary in p080_markers:
			context.game_state.map_state.remove_marker(p080_m2.get("marker_id", &""))
		var p080_remaining: Array = [{
			"type": &"EXECUTE_BASIC_MOVE", "params": {
				"mech_id": p080_mech_id, "target_cell": StringName(p080_cell), "free_move": true,
			},
		}]
		for p080_pass in range(2):
			for p080_mk: Dictionary in p080_markers:
				var p080_atom: Dictionary = _pilot_080_marker_trigger_atom(p080_mk, p080_mech_id, p080_pid)
				if not p080_atom.is_empty():
					p080_remaining.append(p080_atom)
		context.game_state.write_log(&"pilot_080_marker_move", {
			"mech_id": String(p080_mech_id), "cell": p080_cell, "markers": p080_markers.size(),
		})
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": p080_remaining, "effect": effect}
		action.state = &"waiting_effect_action"
		if _continue_seq_effect_actions(action):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── PEEK_DECK_TOP_AND_DISCARD 第1阶段（代价选牌）resume（通用窥牌模块，银雪 pilot_065）──
	# 取消/未选=不发动；确认=串行 [EXECUTE_DISCARD 代价, PEEK_DECK_SHOW 哨兵] 续跑。
	# 代价弃置走子动作触发弃置时点；完成后 _seq 续跑到 PEEK_DECK_SHOW 弹堆顶多选窗。
	if phase == &"peek_select_cost":
		action.record.erase("_peek_cost_shown")
		var pk_params: Dictionary = pending.get("peek_params", {})
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 银雪窥牌-代价取消，不发动 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var pk_cost_selected: Array = input_data.get("selected_card_ids", [])
		if pk_cost_selected.is_empty():
			# 未选代价牌=不发动
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var pk_remaining: Array = [
			{"type": &"EXECUTE_DISCARD", "params": {"card_ids": [pk_cost_selected[0]], "reason": &"PILOT_065_PEEK_COST"}},
			{"type": &"PEEK_DECK_SHOW", "params": pk_params},
		]
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": pk_remaining, "effect": effect}
		action.state = &"waiting_effect_action"
		if _continue_seq_effect_actions(action):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── PEEK_DECK_TOP_AND_DISCARD 第2阶段（堆顶多选弃置）resume ──
	# 取消/不选=不弃置堆顶牌；确认=串行弃置选中的堆顶牌（每张 EXECUTE_DISCARD 触发弃置时点）。
	# 完成后恢复宿主动作（gain_card 继续 GAIN_CARD_AFTER 真正抽牌，此时堆顶已被银雪调整）。
	if phase == &"peek_select_discard":
		var pd_selected: Array = input_data.get("selected_card_ids", [])
		if input_data.get("cancelled", false) or pd_selected.is_empty():
			SLog.log_raw("[TIMING] %s 银雪窥牌-堆顶不弃置 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var pd_remaining: Array = []
		for pd_cid in pd_selected:
			pd_remaining.append({"type": &"EXECUTE_DISCARD", "params": {"card_ids": [pd_cid], "reason": &"PILOT_065_PEEK_DISCARD"}})
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": pd_remaining, "effect": effect}
		action.state = &"waiting_effect_action"
		if _continue_seq_effect_actions(action):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── CHOOSE_MAP_CELL 选格阶段（机雷设陷 legacy + 通用 cells 源）──
	# 取消=效果不发动不消耗次数（恢复动作继续后续步骤）；
	# 确认=选中格存 payload[store_result_key]（默认 selected_cell_id）：
	#   · 挂起于 _seq 序列内（如 CHOOSE_MANY_CARDS store 路径剩余链中的第二次选格）：
	#     继续跑 _seq，不重跑 _execute_effect（避免链上 MARK/EXECUTE_DISCARD 等重复执行）。
	#   · 顶层挂起：重跑 _execute_effect（幂等守卫：已选格跳过）。
	if phase == &"map_cell_select":
		action.record.erase("_waiting_for_map_cell")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 选格被取消，effect=%s 不执行" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		if input_data.has("selected_cell_id"):
			var mc_key: StringName = pending.get("map_cell_store_key", &"")
			if mc_key != &"":
				payload[mc_key] = input_data["selected_cell_id"]
			else:
				payload["selected_cell_id"] = input_data["selected_cell_id"]
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_map_cell", "input": input_data})
		# 序列内挂起：继续 _seq 剩余链（CHOOSE_MAP_CELL 由 _continue_seq_effect_actions 特判挂起）
		if action.record.has("_seq_effect_actions"):
			action.state = &"waiting_effect_action"
			if _continue_seq_effect_actions(action):
				return
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 顶层挂起：重跑 _execute_effect（已选格跳过；未就绪会再次挂起，幂等）
		_execute_effect(effect, payload, action)
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_059 薇尔：回合开始损伤调整面板 ──
	# 应用玩家选择（set 放1损+查装备损坏 / remove 移1损 / cancel 不动）→ 统计调整后损伤数 N
	# → 三分支（<threshold 获金 / ==threshold 视为补给抽2行动+1装备 / >threshold 移除最多
	# max_remove）经 _seq_effect_actions 串行执行。分支动作含子动作时挂起等待
	# （_after_sub_action_finished -> _continue_seq_effect_actions 续跑），全部同步完成则
	# 直接 continue_action 恢复 turn 动作继续流程。
	if phase == &"pilot_059_adjust":
		action.record.erase("_pilot_059_adjust")
		var p59_p: Dictionary = payload.get("pilot_059_params", {})
		var p59_threshold: int = int(p59_p.get("threshold", 4))
		var p59_gold: int = int(p59_p.get("gold_amount", 3))
		var p59_max_remove: int = int(p59_p.get("max_remove", 2))
		var p59_store_key: String = String(p59_p.get("store_key", "pilot_059_damage_x"))
		var p59_label: String = String(p59_p.get("source_label", "薇尔·损伤调整"))
		var p59_bind2: Dictionary = payload.get("binding_context", {})
		var p59_owner_pid: StringName = p59_bind2.get("player_id", &"")
		var p59_owner_mid: StringName = p59_bind2.get("mech_id", &"")
		# ① 应用调整（set/remove/cancel）
		var p59_choice: String = String(input_data.get("choice", &"cancel"))
		var p59_slot: StringName = StringName(input_data.get("slot_id", &""))
		if p59_choice != &"cancel" and p59_owner_mid != &"" and context.game_state.mechs.has(p59_owner_mid):
			if p59_choice == &"set" and p59_slot != &"":
				context.damage_token_service.place_one_damage_token(p59_owner_mid, p59_slot)
				context.damage_token_service.check_and_handle_equipment_break(p59_owner_mid, p59_slot)
			elif p59_choice == &"remove" and p59_slot != &"":
				context.game_actions.remove_damage_tokens({"mech_id": p59_owner_mid, "slot_id": p59_slot, "amount": 1})
		# ② 统计调整后损伤数 N（复用 PILOT_044_COMPUTE_DAMAGE，store_key 由 params 指定）
		var p59_n: int = 0
		if context.game_actions != null and p59_owner_mid != &"" and context.game_state.mechs.has(p59_owner_mid):
			context.game_actions.pilot_044_compute_damage({"mech_id": p59_owner_mid, "store_key": p59_store_key}, payload)
			p59_n = int(payload.get(p59_store_key, 0))
		# ③ 三分支构造动作链
		var p59_remaining: Array = []
		if p59_n < p59_threshold:
			p59_remaining.append({"type": &"GAIN_GOLD", "params": {"amount": p59_gold, "player_id": p59_owner_pid, "reason": &"pilot_059_gold"}})
		elif p59_n == p59_threshold:
			# 视为使用1张补给：抽2行动牌 + 1装备牌（纯虚拟，无实体补给牌）
			p59_remaining.append({"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 2, "player_id": p59_owner_pid, "mech_ids": [p59_owner_mid], "reason": &"pilot_059_supply"}})
			p59_remaining.append({"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1, "player_id": p59_owner_pid, "mech_ids": [p59_owner_mid], "reason": &"pilot_059_supply"}})
		else:
			# 移除最多 max_remove 损伤：damage_change decrease + allow_cancel/max_mode（面板可提前结束/取消）
			p59_remaining.append({"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"mech_ids": [p59_owner_mid], "value": p59_max_remove, "method": &"decrease", "executor": p59_owner_pid, "reason": &"pilot_059_remove", "allow_cancel": true, "max_mode": true, "source_label": p59_label}})
		SLog.log_raw("[TIMING] %s pilot_059 调整choice=%s 后损伤数 N=%d 分支=%s" % [String(action.action_id), p59_choice, p59_n, "gold" if p59_n < p59_threshold else ("supply" if p59_n == p59_threshold else "remove")])
		if p59_remaining.is_empty():
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action.action_id, {})
			return
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": p59_remaining, "source_check": false, "effect": effect}
		action.state = &"waiting_effect_action"
		if _continue_seq_effect_actions(action):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action.action_id, {})
		return

	# ── 骇客窥牌选目标阶段（通用 VIEW_RANDOM_OTHER_HAND_CARDS）：──
	# 取消=效果不发动不消耗次数（恢复动作继续后续步骤）；
	# 确认=把目标机甲 id 注入 payload[store_target_key]，重跑 _execute_effect
	# （模块幂等守卫见 payload[store_key] != &"" 跳过选目标，直接查看+加成）。
	if phase == &"view_random_other_hand_target":
		action.record.erase("_waiting_for_target")
		var vr_params: Dictionary = pending.get("view_params", {})
		var vr_store_key: String = String(vr_params.get("store_target_key", &"pilot_066_target_id"))
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 骇客窥牌选目标被取消，effect=%s 不发动不计数" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var vr_tgt: StringName = input_data.get("target_mech_id", input_data.get("target_id", &""))
		if vr_tgt == &"":
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		payload[vr_store_key] = vr_tgt
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_hack_peek_target", "target": vr_tgt, "input": input_data})
		_execute_effect(effect, payload, action)
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 征服宣言选目标阶段（PILOT_088_CONQUER）：──
	# 取消=效果不发动不消耗次数（恢复动作继续后续步骤）；确认=选定目标即消耗本回合1次
	# （_mark_once_per_turn_used，用户决策：选好目标后消耗），随后弹三选一类型（不可取消）。
	if phase == &"pilot_088_target":
		action.record.erase("_waiting_for_target")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 征服选目标被取消，effect=%s 不发动不计数" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p088_tgt: StringName = input_data.get("target_mech_id", input_data.get("target_id", &""))
		if p088_tgt == &"":
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		payload["pilot_088_target_id"] = p088_tgt
		# 选定目标即消耗本回合1次
		_mark_once_per_turn_used(effect, payload)
		SLog.log_raw("[TIMING] %s 征服选定目标=%s 消耗本回合1次 effect=%s" % [String(action_id), String(p088_tgt), String(effect.effect_id)])
		if _pilot_088_show_type_select(effect, payload, action):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 征服宣言类型选择阶段（PILOT_088_CONQUER）：──
	# 三选一（攻击/迎击/辅助）确定后：随机展示目标1张行动牌 + 非阻塞浮窗（所有玩家端显示）+
	# 类型匹配弃置（相同→弃目标除展示牌外全部；不同→弃展示牌）。
	if phase == &"pilot_088_type":
		var p088_declared: String = String(input_data.get("pilot_088_declared_type", ""))
		if p088_declared == "":
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		payload["pilot_088_declared_type"] = p088_declared
		_pilot_088_finish_conquer(effect, payload, action)
		if action.state == &"waiting_effect_action":
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 目标选择/二选一阶段：注入输入后重跑整个 _execute_effect ──
	# （目标检查在费用/动作之前；CHOOSE_ONE 在 _execute_actions 里读 chosen_option_index）
	if phase == &"pre_actions_target":
		# 取消：不执行效果，恢复动作继续后续步骤
		if input_data.get("cancelled", false):
			# pilot_012 e2 inner CHOOSE_ONE per-target 取消：跳过该 target 续跑下一个（非整个 effect 取消）
			if action.record.has("_fet_choose_chosen") or action.record.has("_fet_choose_executed"):
				var ct_d2: Dictionary = payload.get("current_target", {})
				var ct_mid2: StringName = ct_d2.get("mech_id", &"") if ct_d2 is Dictionary else &""
				if ct_mid2 != &"":
					var cd2: Dictionary = action.record.get("_fet_choose_chosen", {})
					cd2[ct_mid2] = -1
					action.record["_fet_choose_chosen"] = cd2
					var ed2: Dictionary = action.record.get("_fet_choose_executed", {})
					ed2[ct_mid2] = true
					action.record["_fet_choose_executed"] = ed2
				action.record.erase("_waiting_for_choose_one")
				action.record.erase("_choose_one_effect_id")
				SLog.log_raw("[TIMING] %s inner CHOOSE_ONE per-target 取消 effect=%s，续跑下一个" % [String(action_id), String(effect.effect_id)])
				_execute_effect(effect, payload, action)
				if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
					return
				if action.state == &"waiting_effect_action":
					return
				if _last_created_sub_action_paused(action):
					action.state = &"waiting_effect_action"
					return
				if context.action_engine != null:
					action.state = &"waiting_input"
					context.action_engine.continue_action(action_id, {})
				return
			SLog.log_raw("[TIMING] %s 目标选择被取消，effect=%s 不执行" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 注入 target_id（目标选择）或 chosen_option_index（二选一），续跑 _execute_effect
		if input_data.has("target_id"):
			payload["target_id"] = input_data["target_id"]
			# force_select effect 标记已选目标，避免重跑 _execute_effect 时再次清空 target_id（死循环）
			payload["_effect_target_selected"] = true
		if input_data.has("target_mech_id"):
			payload["target_id"] = input_data["target_mech_id"]
			payload["_effect_target_selected"] = true
		if input_data.has("chosen_option_index"):
			payload["chosen_option_index"] = input_data["chosen_option_index"]
			# pilot_012 e2 inner CHOOSE_ONE per-target：记录当前 target 的选择（重跑时跳过已处理）
			var ct_d: Dictionary = payload.get("current_target", {})
			var ct_mid: StringName = ct_d.get("mech_id", &"") if ct_d is Dictionary else &""
			if ct_mid != &"":
				var cd: Dictionary = action.record.get("_fet_choose_chosen", {})
				cd[ct_mid] = int(input_data["chosen_option_index"])
				action.record["_fet_choose_chosen"] = cd
		# 聚能等 CHOOSE_OWN_WEAPON 目标规则读 selected_weapon_id（非 target_id），
		# 需在此注入，否则重跑 _execute_effect 仍判定无目标->重新挂起->选武器死循环。
		if input_data.has("selected_weapon_id"):
			payload["selected_weapon_id"] = input_data["selected_weapon_id"]
		# CHOOSE_MAP_CELL 选格（机雷设陷）：注入选中格 id，续跑 _execute_effect 时
		# CHOOSE_MAP_CELL 见已选则跳过，后续 PLACE_OR_TRIGGER_TRAP 读 $payload.selected_cell_id。
		# （CHOOSE_MAP_CELL 现挂起于专用 phase=map_cell_select，此分支仅为兼容保留。）
		if input_data.has("selected_cell_id"):
			payload["selected_cell_id"] = input_data["selected_cell_id"]
		# CHOOSE_MANY_MAP_CELLS 多格选格（双子机雷）：注入选中格 id 数组，PLACE_OR_TRIGGER_TRAP(place_each) 读 $payload.selected_cell_ids。
		if input_data.has("selected_cell_ids"):
			payload["selected_cell_ids"] = input_data["selected_cell_ids"]
		action.record.erase("_waiting_for_map_cell")
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

	# ── pilot_024 琳 RE 请求确认：取消=无事发生（RE 已消耗，不刷新）；确认=开维修窗口并保持挂起 ──
	# 窗口关闭时（维修完成/取消按钮）由 _pilot_024_close_repair_window -> continue_action 恢复。
	if phase == &"pilot_024_re_confirm":
		action.record.erase("_waiting_for_p024_re_confirm")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 琳拒绝 RE 维修请求，effect=%s 无事发生（RE 已消耗）" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 确认：开维修窗口，动作保持挂起（waiting_timing，无 pending），请求方回合被阻塞。
		payload["_p024_re_confirm_done"] = true
		var _p24c_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		var _p24c_req: StringName = StringName(_p24c_ctx.get("mech_id", payload.get("mech_id", &"")))
		var _p24c_lin: StringName = _ActionPilotEffects.pilot_024_find_lin_mech(context.game_state)
		if _p24c_lin == &"" or _p24c_req == &"":
			# 琳离场/请求方失效（防御）：直接恢复请求方回合
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		_ActionPilotEffects.pilot_024_open_repair_window(context.game_state, _p24c_lin, _p24c_req, action_id)
		pilot_024_repair_window_changed.emit(true, _p24c_req)
		SLog.log_raw("[TIMING] %s 琳确认 RE，维修窗口开启 requester=%s（请求方回合阻塞）" % [String(action_id), String(_p24c_req)])
		return

	# ── pilot_081 汀兰 RE 请求确认：取消=无事发生（RE 已消耗，不刷新）；
	# 同意=请求方回2血+获2金，立即恢复请求方回合（不开窗口，不像琳阻塞） ──
	if phase == &"pilot_081_re_confirm":
		action.record.erase("_waiting_for_p081_re_confirm")
		var _p81c_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		var _p81c_req: StringName = StringName(_p81c_ctx.get("mech_id", payload.get("mech_id", &"")))
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 汀兰拒绝 RE 回复请求，effect=%s 无事发生（RE 已消耗）" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 同意：请求方回2血 + 获2金
		payload["_p081_re_confirm_done"] = true
		var _p81c_hinst: StringName = StringName(_p81c_ctx.get("card_instance_id", payload.get("card_instance_id", &"")))
		var _p81c_holder: StringName = _ActionPilotEffects.pilot_081_find_holder_for_pilot_instance(context.game_state, _p81c_hinst)
		if _p81c_req == &"" or _p81c_holder == &"" or context.game_actions == null:
			# 持有者离场/请求方失效（防御）：直接恢复请求方回合
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 请求方回2血（来源=汀兰持有者）
		context.game_actions.heal_hp({
			"mech_id": _p81c_req, "amount": 2,
			"source_card_id": &"pilot_081_汀兰",
		})
		# 请求方所属玩家获2金
		var _p81c_req_m = context.game_state.mechs.get(_p81c_req)
		if _p81c_req_m != null:
			context.game_actions.gain_gold({
				"player_id": _p81c_req_m.owner_player_id, "amount": 2,
				"reason": &"pilot_081_re_heal",
			})
		SLog.log_raw("[TIMING] %s 汀兰同意 RE，请求方回2血+获2金 requester=%s" % [String(action_id), String(_p81c_req)])
		# 恢复请求方回合（效果立即结算，不阻塞）
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_083 瓦恩武器修改两阶段：phase1 武器单选 → phase2 三横排选项 → 施加 ──
	# 取消=不施加（owner 模式不耗每回合1次；re 模式 RE 已在点击时消耗不退）。
	# 确认=打包状态施加到所选武器（mode=owner 另标记效果1每回合1次已用）。
	if phase == &"p083_weapon_select":
		action.record.erase("_waiting_for_p083_weapon_select")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 瓦恩武器修改 phase1 取消，effect=%s 不施加" % [String(action_id), String(effect.effect_id)])
			_finish_pilot_083_flow(action, payload)
			return
		var p83_wk: String = String(input_data.get("chosen_effect_id", input_data.get("selected_card_id", "")))
		if p83_wk == "":
			_finish_pilot_083_flow(action, payload)
			return
		payload["_p083_weapon_key"] = p83_wk
		_prompt_pilot_083_options(effect, payload, action)
		return
	if phase == &"p083_options":
		action.record.erase("_waiting_for_p083_options")
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s 瓦恩武器修改 phase2 取消，effect=%s 不施加" % [String(action_id), String(effect.effect_id)])
			_finish_pilot_083_flow(action, payload)
			return
		var p83_opts: Dictionary = input_data.get("options", {})
		if not (p83_opts is Dictionary):
			p83_opts = {}
		payload["_p083_options"] = p83_opts
		_apply_pilot_083_flow(effect, payload, action)
		return

	# ── pilot_021 塔莉娅效果1 循环赐予：选机甲 / 选牌 阶段 ──
	# 选机甲取消=结束循环（抽牌已发生，mark once_per_turn）；选中机甲转选牌。
	# 选牌取消=回选机甲（不结束循环）；选牌确定=转移并从剩余移除，牌给完结束循环否则回选机甲。
	if phase == &"pilot_021_choose_mech":
		var p21_loop: Dictionary = action.record.get("_pilot_021_loop", {})
		if p21_loop.is_empty():
			# 防御：循环状态丢失，直接完成效果
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		if input_data.get("cancelled", false):
			_finish_pilot_021_deal(effect, payload, action)
			return
		var p21_target: StringName = StringName(input_data.get("target_id", input_data.get("target_mech_id", &"")))
		if p21_target == &"":
			_finish_pilot_021_deal(effect, payload, action)
			return
		p21_loop["target_mech"] = p21_target
		action.record["_pilot_021_loop"] = p21_loop
		# 转选牌阶段；未挂起（牌给完/异常）则循环结束
		if not _pilot_021_choose_cards(effect, payload, action, p21_loop):
			_finish_pilot_021_deal(effect, payload, action)
		return

	if phase == &"pilot_021_choose_cards":
		var p21b_loop: Dictionary = action.record.get("_pilot_021_loop", {})
		if p21b_loop.is_empty():
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		if input_data.get("cancelled", false):
			# 选牌取消：回选机甲（不结束循环）
			p21b_loop.erase("target_mech")
			action.record["_pilot_021_loop"] = p21b_loop
			if not _pilot_021_choose_mech(effect, payload, action, p21b_loop):
				_finish_pilot_021_deal(effect, payload, action)
			return
		var p21_sel: Array = input_data.get("selected_action_card_ids", [])
		if p21_sel.is_empty() and input_data.has("card_ids"):
			p21_sel = input_data.get("card_ids", [])
		var p21_tgt2: StringName = StringName(p21b_loop.get("target_mech", &""))
		if p21_tgt2 == &"":
			_finish_pilot_021_deal(effect, payload, action)
			return
		# 只转移仍属于剩余列表的牌（防御）
		var p21_rem: Array = p21b_loop.get("remaining", [])
		var p21_give: Array = []
		for cid in p21_sel:
			if cid in p21_rem:
				p21_give.append(cid)
		if not p21_give.is_empty():
			_transfer_pilot_021_cards(action, p21b_loop, p21_give, p21_tgt2)
			for cid in p21_give:
				p21_rem.erase(cid)
			p21b_loop["remaining"] = p21_rem
			action.record["_pilot_021_loop"] = p21b_loop
		# 牌给完 -> 结束循环；否则回选机甲继续
		if p21_rem.is_empty():
			_finish_pilot_021_deal(effect, payload, action)
			return
		p21b_loop.erase("target_mech")
		action.record["_pilot_021_loop"] = p21b_loop
		if not _pilot_021_choose_mech(effect, payload, action, p21b_loop):
			_finish_pilot_021_deal(effect, payload, action)
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

	# ── pilot_009 弹窗① 支付阶段：玩家选了1张自己行动牌（selected_action_card_ids）或取消 ──
	# 选定：弃置该牌、记录其类型到 payload.pilot_009_recorded_type，重跑 _execute_effect（CHOOSE_ONE 读 $runtime）。
	# 取消：中止整个效果（不授控制/不弃目标牌）。
	if phase == &"pilot_009_pay":
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s pilot_009 支付取消，effect=%s 不执行" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p9_sel: Array = input_data.get("selected_action_card_ids", [])
		if p9_sel.is_empty() and input_data.has("card_id"):
			p9_sel = [input_data.get("card_id")]
		if p9_sel.is_empty():
			# 无选择（不应发生）：按取消处理
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p9_card_id: StringName = StringName(String(p9_sel[0]))
		var p9_recorded_type: StringName = &""
		if context.game_actions != null and context.game_actions.has_method(&"pilot_009_pay_and_record_type"):
			p9_recorded_type = context.game_actions.pilot_009_pay_and_record_type({"card_id": p9_card_id})
		payload["pilot_009_recorded_type"] = p9_recorded_type
		SLog.log_raw("[TIMING] %s pilot_009 支付完成，记录类型=%s effect=%s" % [String(action_id), String(p9_recorded_type), String(effect.effect_id)])
		_execute_effect(effect, payload, action)
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_016 选2张转化牌阶段：玩家选了2张B/C（selected_action_card_ids）──
	# 新语义：B/C 都移入临时区（C 写 record.temp_zone_card_ids 由父 settle 弃置，同步移牌不发时点，
	#   与迪恩 temp_zone 弃置一致，避免与父动作推进竞争）+ 改造父 use_action_card.record(B当牌A
	#   virtual_transform) + 清空剩余 listener + mark once_per_turn。
	# 牌A保留手牌；B 由父 card_to_temp_zone 移入 temp_zone + 注册牌A效果；父 execute_effects 执行牌A效果；
	# 父 settle 弃B和C。
	if phase == &"pilot_016_choose_two":
		var p016_c_a_id: StringName = pending.get("card_a_id", &"")
		var p016_c_a_def: StringName = pending.get("card_a_def", &"")
		var p016_sel: Array = input_data.get("selected_action_card_ids", [])
		# 取消/不足2张（不应发生，no_cancel）：不转化，回父正常用牌A
		if input_data.get("cancelled", false) or p016_sel.size() < 2:
			SLog.log_raw("[TIMING] %s pilot_016 转化选牌取消/不足2张，不转化 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p016_b_id: StringName = StringName(String(p016_sel[0]))  # B：当牌A用（虚拟）
		var p016_c_id: StringName = StringName(String(p016_sel[1]))  # C：弃置消耗
		# 保险：B/C 不应为牌A（面板已排除，AI 路径可能误选则回退不转化）
		if p016_b_id == p016_c_a_id or p016_c_id == p016_c_a_id:
			SLog.log_raw("[TIMING] %s pilot_016 选牌含展示牌A，回退不转化 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# C 移入临时区（新语义：B/C 都进临时区，链末随父 use_action_card settle 统一入弃牌堆）。
		# 同步移牌不发时点；写 action.record.temp_zone_card_ids 供父 settle 读取弃置（use_action_card_action 通用支持）。
		var p016_c_card = context.game_state.get_card(p016_c_id) if context.game_state != null else null
		if p016_c_card != null:
			var p016_c_owner: StringName = p016_c_card.owner_player_id
			if p016_c_owner != &"" and context.game_state.players.has(p016_c_owner):
				context.game_state.players[p016_c_owner].action_hand.erase(p016_c_id)
			if context.timing_engine != null:
				context.timing_engine.unregister_listeners_for_card(p016_c_id)
			p016_c_card.zone = &"temp_zone"
			var _p016_tz: Array = action.record.get("temp_zone_card_ids", [])
			if not _p016_tz.has(p016_c_id):
				_p016_tz.append(p016_c_id)
			action.record["temp_zone_card_ids"] = _p016_tz
			SLog.log_raw("[TIMING] %s pilot_016 C=%s 移入临时区（链末随父 settle 弃）" % [String(action_id), String(p016_c_id)])
		# 改造父 use_action_card.record：B 当牌A virtual_transform
		action.record["card_instance_id"] = p016_b_id
		action.record["as_card_def_id"] = p016_c_a_def
		action.record["virtual_transform"] = true
		payload["pilot_016_converted"] = true
		SLog.log_raw("[TIMING] %s pilot_016 转化完成 B=%s 当 %s，B/C进临时区，牌A=%s 保留手牌 effect=%s" % [String(action_id), String(p016_b_id), String(p016_c_a_def), String(p016_c_a_id), String(effect.effect_id)])
		# 标记每回合1次（多阶段挂起，_execute_effect 未走到末尾 mark，此处补）
		_mark_once_per_turn_used(effect, payload)
		# 清空剩余 USE_ACTION_BEFORE listener：转化后牌A不打（B虚拟牌A打），
		# 补跑会用旧 payload（牌A实体）误触发阿克罗姆01a 等 listener，故跳过。
		action._pending_regular_listeners = []
		# 推进父动作继续（card_to_temp_zone 移B入temp_zone+注册牌A效果 -> execute_effects -> settle 弃B）
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	if phase == &"pilot_014_select":
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s pilot_014 选机师牌取消，effect=%s 不执行" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p014_sel_pilot: StringName = input_data.get("pilot_014_target_pilot", &"")
		var p014_sel_player: StringName = input_data.get("pilot_014_player_id", &"")
		var p014_sel_mech: StringName = input_data.get("pilot_014_mech_id", &"")
		var p014_bind2: Dictionary = payload.get("binding_context", {})
		var p014_src_pilot2: StringName = p014_bind2.get("card_instance_id", &"")
		var p014_src_pid2: StringName = p014_bind2.get("player_id", &"")
		if p014_sel_pilot != &"" and context.game_actions != null:
			context.game_actions.grant_pilot_014_bonus({
				"target_pilot_instance": p014_sel_pilot,
				"target_player_id": p014_sel_player,
				"target_mech_id": p014_sel_mech,
				"source_pilot_instance": p014_src_pilot2,
				"duration_owner_id": p014_src_pid2,
			})
			payload["pilot_014_granted"] = true
		# 续跑 _execute_effect：PILOT_014 拦截见 pilot_014_granted 跳过，到 1320 自动 mark once_per_turn。
		_execute_effect(effect, payload, action)
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_032 阶段① 弃牌支付：玩家选了1张自己行动牌（selected_action_card_ids）或取消 ──
	# 选定：弃置选定牌 -> 直接续跑到阶段②选机师（不重跑 _execute_effect，避免 HAS_ACTION_CARD_IN_HAND
	# 因手牌变空在重查条件时误判失败）。取消：中止不计次数（不弃牌、不施加）。
	if phase == &"pilot_032_pay":
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s pilot_032 弃牌取消，effect=%s 不执行（不计次数）" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p032_sel: Array = input_data.get("selected_action_card_ids", [])
		if p032_sel.is_empty() and input_data.has("card_id"):
			p032_sel = [input_data.get("card_id")]
		if p032_sel.is_empty():
			SLog.log_raw("[TIMING] %s pilot_032 弃牌空选，effect=%s 中止" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p032_discard_pid: StringName = payload.get("binding_context", {}).get("player_id", &"")
		if context.game_actions != null:
			for p032_cid in p032_sel:
				context.game_actions.discard_action_card({
					"player_id": p032_discard_pid,
					"card_id": StringName(String(p032_cid)),
					"reason": &"PILOT_032_DISCARD",
				})
		payload["pilot_032_paid"] = true
		SLog.log_raw("[TIMING] %s pilot_032 弃牌支付完成 effect=%s" % [String(action_id), String(effect.effect_id)])
		var p032_pay_params: Dictionary = pending.get("params", {})
		if _pilot_032_show_pilot_select(effect, payload, action, p032_pay_params):
			return
		# 场上无机师牌兜底：中止（已弃牌不返还、不计次数）
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_032 阶段② 选机师牌：确认施加行动牌上限+2，取消=中止（已弃牌不返还、不计次数）──
	# 选定后手动完成（仿 pilot_019_finish：不重跑 _execute_effect，mark once_per_turn + 通知），
	# 再推进 effect_fire 动作。
	if phase == &"pilot_032_select":
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s pilot_032 选机师牌取消，effect=%s 不执行（已弃牌不返还、不计次数）" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p032_sel_pilot: StringName = input_data.get("pilot_032_target_pilot", &"")
		var p032_sel_player: StringName = input_data.get("pilot_032_player_id", &"")
		var p032_sel_mech: StringName = input_data.get("pilot_032_mech_id", &"")
		var p032_bind2: Dictionary = payload.get("binding_context", {})
		var p032_src_pilot2: StringName = p032_bind2.get("card_instance_id", &"")
		var p032_src_pid2: StringName = p032_bind2.get("player_id", &"")
		if p032_sel_pilot != &"" and context.game_actions != null:
			context.game_actions.grant_pilot_014_bonus({
				"target_pilot_instance": p032_sel_pilot,
				"target_player_id": p032_sel_player,
				"target_mech_id": p032_sel_mech,
				"source_pilot_instance": p032_src_pilot2,
				"duration_owner_id": p032_src_pid2,
			})
		payload["pilot_032_granted"] = true
		_mark_once_per_turn_used(effect, payload)
		if effect.once_per_game_key != &"":
			_mark_once_per_game_used(effect, payload)
		effect_executed.emit(effect.effect_id, action.action_id)
		_mark_effect_executed(effect.effect_id, action.action_id)
		SLog.log_raw("[TIMING] %s pilot_032 完成 effect=%s target_pilot=%s" % [String(action_id), String(effect.effect_id), String(p032_sel_pilot)])
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_019 缴械冲击 阶段机：目标多选（select_attack_target → ui_confirmed target_ids）──
	# 取消/空选 -> 中止整效果（不消耗 once_per_turn）；选定 -> 记录目标、进入支付选牌（wait_pay）。
	if phase == &"pilot_019_wait_targets":
		var p019_tids: Array = input_data.get("target_ids", [])
		if input_data.get("cancelled", false) or p019_tids.is_empty():
			SLog.log_raw("[TIMING] %s pilot_019 目标选择取消/空选，effect=%s 中止" % [String(action_id), String(effect.effect_id)])
			_pilot_019_abort_resume(action_id)
			return
		if not action.record.has("_pilot_019_chain"):
			_pilot_019_abort_resume(action_id)
			return
		var p019_chain: Dictionary = action.record["_pilot_019_chain"]
		var p019_targets: Array = []
		for p019_t in p019_tids:
			var p019_mid: StringName = StringName(String(p019_t))
			if p019_mid != &"":
				p019_targets.append(p019_mid)
		p019_chain["targets"] = p019_targets
		p019_chain["stage"] = &"wait_pay"
		SLog.log_raw("[TIMING] %s pilot_019 选定目标 %d 台 effect=%s" % [String(action_id), p019_targets.size(), String(effect.effect_id)])
		_pilot_019_drive(action)
		return

	# ── pilot_019 支付阶段：玩家选了 N 张自己行动牌（selected_card_ids，ThrustSelectPanel confirm）──
	# 选空/取消 -> 中止；选定 -> X=N，弃置后进入逐目标暗牌弃牌链。
	if phase == &"pilot_019_pay":
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s pilot_019 支付取消，effect=%s 中止" % [String(action_id), String(effect.effect_id)])
			_pilot_019_abort_resume(action_id)
			return
		var p019_sel: Array = input_data.get("selected_card_ids", [])
		if p019_sel.is_empty():
			SLog.log_raw("[TIMING] %s pilot_019 支付选牌为空，effect=%s 中止" % [String(action_id), String(effect.effect_id)])
			_pilot_019_abort_resume(action_id)
			return
		if not action.record.has("_pilot_019_chain"):
			_pilot_019_abort_resume(action_id)
			return
		var p019_chain2: Dictionary = action.record["_pilot_019_chain"]
		p019_chain2["x"] = p019_sel.size()
		p019_chain2["pay_cards"] = p019_sel.duplicate()
		p019_chain2["stage"] = &"pay_discarding"
		p019_chain2["discard_issued"] = false
		SLog.log_raw("[TIMING] %s pilot_019 支付选定 X=%d 张 effect=%s" % [String(action_id), p019_sel.size(), String(effect.effect_id)])
		_pilot_019_drive(action)
		return

	# ── pilot_019 目标暗牌弃牌阶段：玩家从目标手牌选 X+1 张（selected_action_card_ids，DiscardSelectPanel optional confirm）──
	# no_cancel=true 正常不会取消；取消/空选则跳过该目标（视为未选满，不弃不判伤害）。
	if phase == &"pilot_019_target_pick":
		if not action.record.has("_pilot_019_chain"):
			_pilot_019_abort_resume(action_id)
			return
		var p019_chain3: Dictionary = action.record["_pilot_019_chain"]
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s pilot_019 目标选牌取消，跳过该目标 effect=%s" % [String(action_id), String(effect.effect_id)])
			p019_chain3["idx"] = int(p019_chain3.get("idx", 0)) + 1
			p019_chain3["stage"] = &"per_target"
			p019_chain3["discard_issued"] = false
			p019_chain3["target_cards"] = []
			_pilot_019_drive(action)
			return
		var p019_sel2: Array = input_data.get("selected_action_card_ids", [])
		if p019_sel2.is_empty():
			SLog.log_raw("[TIMING] %s pilot_019 目标选牌为空，跳过该目标 effect=%s" % [String(action_id), String(effect.effect_id)])
			p019_chain3["idx"] = int(p019_chain3.get("idx", 0)) + 1
			p019_chain3["stage"] = &"per_target"
			p019_chain3["discard_issued"] = false
			p019_chain3["target_cards"] = []
			_pilot_019_drive(action)
			return
		p019_chain3["target_cards"] = p019_sel2.duplicate()
		p019_chain3["stage"] = &"target_discarding"
		p019_chain3["discard_issued"] = false
		SLog.log_raw("[TIMING] %s pilot_019 目标选牌 %d 张，进入弃置 effect=%s" % [String(action_id), p019_sel2.size(), String(effect.effect_id)])
		_pilot_019_drive(action)
		return

	# ── pilot_020 肯德 弃任意行动牌：玩家选了 N 张自己行动牌（selected_card_ids，ThrustSelectPanel confirm）──
	# 取消/空选 -> 中止（不消耗 once_per_turn）；选定 -> EXECUTE_DISCARD 子动作弃置，
	# 子动作完成由 _after_sub_action_finished -> _continue_pilot_020_active 手动 mark once_per_turn + 恢复。
	if phase == &"pilot_020_discard":
		if input_data.get("cancelled", false):
			SLog.log_raw("[TIMING] %s pilot_020 弃牌取消，effect=%s 中止" % [String(action_id), String(effect.effect_id)])
			_pilot_020_abort_resume(action_id)
			return
		var p020_sel: Array = input_data.get("selected_card_ids", [])
		if p020_sel.is_empty():
			SLog.log_raw("[TIMING] %s pilot_020 弃牌选空，effect=%s 中止" % [String(action_id), String(effect.effect_id)])
			_pilot_020_abort_resume(action_id)
			return
		var p020_pend_effect: ActionEffect = effect
		action.record["_pilot_020_active_pending"] = {"effect": p020_pend_effect, "payload": payload}
		if context.action_service != null:
			context.action_service.execute_sub_action({
				"type": &"EXECUTE_DISCARD",
				"params": {"card_ids": p020_sel.duplicate(), "reason": &"pilot_020_active"},
			}, payload, action)
		SLog.log_raw("[TIMING] %s pilot_020 选定弃 %d 张行动牌，进入弃置 effect=%s" % [String(action_id), p020_sel.size(), String(effect.effect_id)])
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		# 子动作同步完成：直接 mark + 恢复
		_continue_pilot_020_active(action)
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
				# 盾牌确认转移：HP伤害减 _ao_hp_reduction（太空合金盾牌 effect_136）
				_apply_shield_hp_reduction(action, int(action.record.get("_ao_hp_reduction", 0)))
			else:
				action.record["redirect_absorbed"] = 0
		action.record.erase("_ao_absorb")
		action.record.erase("_ao_hp_reduction")
		# 续跑 _execute_actions（剩余动作）；redirect_plan 已写 record，_step_set_damage 读它
		# 注意：转移效果是 damage_change 动作在 DAMAGE_REDIRECT_WINDOW 触发的，恢复后 damage_change 继续 _step_set_damage
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 多选阶段：玩家选了若干牌（selected_card_ids）或取消 ──
	# ── CHOOSE_MANY_MECHS 通用多选机甲（奥黛尔 pilot_038）：确认存 target_ids 后重跑 _execute_effect
	# （shown 守卫仍保留，跳过 CHOOSE_MANY_MECHS 续跑 MARK_EFFECT_ONCE_PER_TURN_USED + FOR_EACH_TARGET
	# 逐目标执行）；取消=不发动不计次（清守卫）。AI 玩家由 _prompt_choose_many_mechs 跳过不挂起 ──
	if phase == &"choose_many_mechs":
		if input_data.get("cancelled", false):
			action.record.erase("_choose_many_mechs_shown")
			SLog.log_raw("[TIMING] %s 多选机甲被取消，effect=%s 不发动" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var mm_store_key: String = String(pending.get("mech_select_action", {}).get("params", {}).get("store_result_key", &""))
		var mm_targets: Array = input_data.get("target_ids", [])
		if mm_store_key != &"":
			payload[mm_store_key] = mm_targets
		SLog.log_raw("[TIMING] %s 多选机甲确认 %d 台 effect=%s" % [String(action_id), mm_targets.size(), String(effect.effect_id)])
		# 重跑：_choose_many_mechs_shown 守卫仍在，CHOOSE_MANY_MECHS 跳过；续跑 MARK 计次 + FOR_EACH_TARGET
		_execute_effect(effect, payload, action)
		# 守卫：重跑后再次挂起（FOR_EACH 内嵌子动作暂停等待等）则等待，不可推进父动作
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if action.state == &"waiting_effect_action":
			return
		if _last_created_sub_action_paused(action):
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# 推进：per_card_actions=动力+4，discard_selected=true 弃置选中推进。
	# effect_063/078：per_card_actions=NEGATE_EQUIPMENT_EFFECT（$chosen_card.card_instance_id），discard_selected=false 不弃置。
	if phase == &"choose_many_cards":
		var cm_action: Dictionary = pending.get("choose_many_action", {})
		var cm_params: Dictionary = cm_action.get("params", {})
		var per_card_actions: Array = cm_params.get("per_card_actions", [])
		var cm_selected: Array = input_data.get("selected_card_ids", [])
		# 掩护窗口附加选项（洛尔恩 pilot_062 等）：选中的 extra 效果 effect_id 列表（数组内元素可能是
		# String/StringName，统一转 String 存储于 record，供 _run_next_cover_extra_if_pending 匹配）。
		var cm_selected_extra: Array = input_data.get("selected_extra_ids", [])
		var cm_discard_selected: bool = bool(cm_params.get("discard_selected", true))
		var cm_discard_reason: StringName = cm_params.get("discard_reason", &"ACTION_CARD_PLAYED")
		action.record.erase("_choose_many_shown")
		# store_result_key 路径（pilot_002 批次转化）：存 payload[key]=选中牌，续跑主循环剩余 actions
		var cm_store_key: StringName = cm_params.get("store_result_key", &"")
		if cm_store_key != &"":
				if input_data.get("cancelled", false):
					SLog.log_raw("[TIMING] %s pilot_002 交牌取消，能力不发动 effect=%s" % [String(action.action_id), String(effect.effect_id)])
					# 取消也清分支 _seq（CHOOSE_ONE 分支内 CHOOSE_MANY_CARDS：放弃整个分支，
					# 剩余 REDIRECT/防御链不执行）。顶层取消路径 _seq 本不存在，erase 无害。
					action.record.erase("_seq_effect_actions")
					if context.action_engine != null:
						action.state = &"waiting_input"
						context.action_engine.continue_action(action_id, {})
					return
				payload[cm_store_key] = cm_selected
				SLog.log_raw("[TIMING] %s pilot_002 批次存 %s=%d张 effect=%s" % [String(action.action_id), String(cm_store_key), cm_selected.size(), String(effect.effect_id)])
				# store_result_key 路径确认即消耗每回合次数（pilot_003 埋牌 / pilot_022 弃甲铸威）。
				# 取消已早退；空选(0张)视为无效操作不消耗。无 once_per_turn_key 的效果为 no-op。
				# 效果若同时声明 once_per_game_key（如 pilot_033 本局1次），确认一并消耗本局次数。
				if not cm_selected.is_empty():
					_mark_once_per_turn_used(effect, payload)
					if effect.once_per_game_key != &"":
						_mark_once_per_game_used(effect, payload)
				var cm_act_idx: int = int(pending.get("act_idx", -1))
				# store_next_phase：存牌后弹下一阶段弹窗再续跑剩余 actions（pilot_003 effect_01 选置顶牌）。
				# phase 链：CHOOSE_MANY 选牌 -> 弹"选1张置顶(可取消)"窗(phase=store_next_phase) ->
				# resume 存 pilot_003_top_card_id 后续跑剩余 actions（INSERT 用 deck_top_card_id 置顶+打标签）。
				var cm_next_phase: StringName = cm_params.get("store_next_phase", &"")
				if cm_next_phase != &"" and not cm_selected.is_empty():
					_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": cm_next_phase, "act_idx": cm_act_idx}
					action.state = &"waiting_timing"
					action_needs_input.emit(action.action_id, &"select_pilot_003_choose_top", {
						"action_id": action.action_id,
						"effect_id": effect.effect_id,
						"card_ids": cm_selected,
						"player_id": payload.get("binding_context", {}).get("player_id", &""),
						"label": String(cm_params.get("store_next_phase_label", "选择1张正面牌放置到牌堆顶（可取消）")),
					})
					SLog.log_raw("[TIMING] %s store_next_phase=%s 弹窗 候选=%d effect=%s" % [String(action.action_id), String(cm_next_phase), cm_selected.size(), String(effect.effect_id)])
					return
				# 续跑 effect.actions 剩余（TRANSFER/GRANT_BATCH/DRAW）。若 CHOOSE_MANY_CARDS 挂起于
				# CHOOSE_ONE 分支内（布鲁克 effect_02 转化防御/实体防御牌），分支剩余已存
				# _seq_effect_actions（branch_seq=true），resume 优先续跑分支；完成后继续主循环。
				var cm_has_branch_seq: bool = action.record.has("_seq_effect_actions") and bool(action.record["_seq_effect_actions"].get("branch_seq", false))
				if cm_has_branch_seq:
					action.state = &"waiting_effect_action"
					if _continue_seq_effect_actions(action):
						return
				# 续跑 effect.actions 剩余（TRANSFER/GRANT_BATCH/DRAW/FOR_EACH_TARGET）。
				# effect 引用随 _seq 保存：后续 FET 分支内嵌 CHOOSE_MANY_CARDS（泰格弃装解锁）需 effect
				# 挂起 _pending_effect；缺失则 null-effect 守卫跳过弹窗（锁无法解锁）。
				if cm_act_idx >= 0 and effect.actions.size() > cm_act_idx + 1:
					action.record["_seq_effect_actions"] = {"payload": payload, "remaining": effect.actions.slice(cm_act_idx + 1), "effect": effect}
					action.state = &"waiting_effect_action"
					if _continue_seq_effect_actions(action):
						return
				if context.action_engine != null:
					action.state = &"waiting_input"
					context.action_engine.continue_action(action_id, {})
				return
		if not input_data.get("cancelled", false):
			var cm_as_use_action_card: bool = bool(cm_params.get("as_use_action_card", false))
			var cm_batch_suspended: bool = false
			if cm_as_use_action_card:
				# 掩护/推进重构：多选窗确认后批量创建 use_action_card 子动作（串行 _seq），
				# 每张走完整使用流程（USE_ACTION_BEFORE 01a确认 + effect1 + USE_ACTION_AFTER 01b重跑 + settle弃牌），
				# 使阿克罗姆双重生效对辅助/掩护牌生效。use_action_card settle 自带弃置，不需 EXECUTE_DISCARD。
				# attack_action_id 由 _extract_use_action_card_params 从 payload 自动推导（掩护 -5 定位 attack）。
				var cm_bind: Dictionary = payload.get("binding_context", {})
				var cm_holder_mech: StringName = cm_bind.get("mech_id", payload.get("source_mech_id", &""))
				var cm_holder_pid: StringName = cm_bind.get("player_id", payload.get("player_id", &""))
				var cm_use_actions: Array = []
				# 温斯顿 pilot_082 转化（as_card_def_id）：把选中的攻击牌当作掩护/推进批量打出。
				# as_use_action_card 选中的实体牌虚拟转化为 as_card_def_id（virtual_transform=true，
				# 不消耗攻击次数），逐张完整使用流程；无 as_card_def_id 时保持原有语义（打出原牌）。
				var cm_as_def: StringName = cm_params.get("as_card_def_id", &"")
				for sel_cid in cm_selected:
					var _ua_params: Dictionary = {
						"card_instance_id": sel_cid,
						"mech_id": cm_holder_mech,
						"player_id": cm_holder_pid,
					}
					if cm_as_def != &"":
						_ua_params["as_card_def_id"] = cm_as_def
						_ua_params["virtual_transform"] = true
						_ua_params["consume_attack_count"] = false
					cm_use_actions.append({
						"type": &"EXECUTE_USE_ACTION_CARD",
						"params": _ua_params,
					})
				for cm_ui: int in range(cm_use_actions.size()):
					if context != null and context.action_service != null:
						context.action_service.execute_sub_action(cm_use_actions[cm_ui], payload, action)
					if _last_created_sub_action_paused(action):
						cm_batch_suspended = true
						var cm_u_remaining: Array = cm_use_actions.slice(cm_ui + 1)
						if not cm_u_remaining.is_empty():
							action.record["_seq_effect_actions"] = {
								"payload": payload,
								"remaining": cm_u_remaining,
							}
						break
			else:
				for sel_cid in cm_selected:
					# 注入 chosen_card 供 per_card_actions 中 $chosen_card.card_instance_id 解析
					payload["chosen_card"] = {"card_instance_id": sel_cid}
					for sub_act: Dictionary in per_card_actions:
						if context != null and context.action_service != null:
							context.action_service.execute_sub_action(sub_act, payload, action)
					if cm_discard_selected and context != null and context.action_service != null:
						context.action_service.execute_sub_action({"type": &"EXECUTE_DISCARD", "params": {"card_ids": [sel_cid], "reason": cm_discard_reason}}, payload, action)
			# 窗口附加选项（洛尔恩 pilot_062 转化掩护 / 温斯顿 pilot_082 转化推进）：真实掩护/推进全部
			# 执行后，串行启动选中的 extra 效果（真实牌先按顺序执行，然后转化）。批量挂起时
			# （use_action_card 子动作等待）只存 pending，由 _after_sub_action_finished 恢复钩子
			# _run_next_window_extra_if_pending 在全部完成后续跑；同步完成则此处直接启动。
			if not cm_selected_extra.is_empty():
				# 窗口附加选项虚拟时点从 record 读取（开窗时写入 _window_extra_timing；
				# 此作用域无 cm_collect_* 局部变量，不可在此重算）
				var cm_window_timing: StringName = action.record.get("_window_extra_timing", &"")
				if cm_window_timing != &"":
					action.record["_window_extra_pending"] = cm_selected_extra
					action.record["_window_extra_payload"] = payload
					action.record["_window_extra_timing"] = cm_window_timing
					if not cm_batch_suspended:
						if _run_next_window_extra_if_pending(action):
							return
			# 标记每回合1次（赤枭躯干 effect_040/041：确认即消耗次数，含选0张=弃0+0动力；
			# 取消路径不至此，不消耗。无 once_per_turn_key 的效果为 no-op）
			_mark_once_per_turn_used(effect, payload)
			_mark_once_per_game_used(effect, payload)
			# post_actions：选牌完成后执行一次（雄鹰躯干 effect_071/072 按弃牌数移动）。
			# $choice.count = 选中牌数。预解析 *_expr/$binding_context/$choice 后串行执行
			# （仿 CHOOSE_INTEGER）。选0张时跳过（如雄鹰弃0=移0格，无事发生）。
			var cm_post_actions: Array = cm_params.get("post_actions", [])
			if not cm_post_actions.is_empty() and not cm_selected.is_empty():
				var cm_choice_full: Dictionary = payload.get("choice", {})
				cm_choice_full["count"] = cm_selected.size()
				cm_choice_full["card_ids"] = cm_selected  # 供 post_actions 的 $choice.card_ids 引用（莱特交牌）
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
		# flat 内嵌 CM（泰格弃装解锁逐目标）：标记当前 target 已处理，续跑 flat _seq 剩余。
		# 目标玩家确认（弃1装解锁）或取消（不弃置，锁保留）都推进到下一个目标；全部完成后父动作继续。
		if bool(pending.get("_flat_cm", false)):
			var fet_tgt: StringName = pending.get("_flat_cm_target", &"")
			if fet_tgt != &"":
				var fec: Dictionary = action.record.get("_fet_cm_executed", {})
				fec[fet_tgt] = true
				action.record["_fet_cm_executed"] = fec
			action.state = &"waiting_effect_action"
			if action.record.has("_seq_effect_actions"):
				if _continue_seq_effect_actions(action):
					return
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
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
				# 联合攻击来源标记：use_action_card(B) 的 record 自动注入（_ 前缀键），
				# USE_ACTION_AT payload 携带 -> 莎菲雅 pilot_084 被动据此区分"因联合的效果使用攻击牌"。
				"_unite_attack_origin": true,
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

	# ── pilot_028 乌尔效果1 宣言：三选一（攻击/迎击/辅助）确认或取消 ──
	if phase == &"pilot_028_declare":
		action.record.erase("_p028_declare_shown")
		var p28_d_card = _ActionPilotEffects.pilot_028_pilot_card(context.game_state)
		var p28_owner_pid: StringName = payload.get("binding_context", {}).get("player_id", &"")
		var p28_chosen: int = int(input_data.get("chosen_option_index", -1))
		if input_data.get("cancelled", false) or p28_chosen < 0:
			SLog.log_raw("[TIMING] %s 乌尔宣言取消：本轮无宣言 effect=%s" % [String(action_id), String(effect.effect_id)])
		else:
			var p28_decl: String = "辅助"
			if p28_chosen == 0:
				p28_decl = "攻击"
			elif p28_chosen == 1:
				p28_decl = "迎击"
			if p28_d_card != null:
				_ActionPilotEffects.set_pilot_028_declared(p28_d_card, p28_decl)
				# 展示浮窗（非阻塞，所有玩家可见）：紧接 continue_action 前发出，随虚拟动作完成清空等待槽
				_show_pilot_028_declared(p28_d_card, action, p28_owner_pid)
			SLog.log_raw("[TIMING] %s 乌尔宣言=%s effect=%s" % [String(action_id), p28_decl, String(effect.effect_id)])
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_028 乌尔效果2 需交牌：用牌玩家交2张行动牌给乌尔 / 取消或不足 → 行动牌不生效 ──
	if phase == &"pilot_028_tribute":
		action.record.erase("_p028_tribute_shown")
		var p28_t_selected: Array = input_data.get("selected_card_ids", [])
		if input_data.get("cancelled", false) or p28_t_selected.size() < 2:
			action.record["_pilot_028_skip_effects"] = true
			SLog.log_raw("[TIMING] %s 乌尔需交牌未交足（%d张），行动牌不生效 effect=%s" % [String(action_id), p28_t_selected.size(), String(effect.effect_id)])
		else:
			_pilot_028_do_tribute(action, p28_t_selected)
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_006 战后逼迫选牌（effect_03）：被选机甲选1张攻击牌 use_action_card / 取消回落4伤害 ──
	# ── pilot_027 维罗妮卡效果3 多阶段 ──
	# ① 选目标：确认（target_id）→ stepper 给金金额；取消 → 不执行（不消耗次数）
	if phase == &"pilot_027_target_select":
		var p27_ts_target: StringName = input_data.get("target_id", input_data.get("target_mech_id", &""))
		if input_data.get("cancelled", false) or p27_ts_target == &"":
			SLog.log_raw("[TIMING] %s pilot_027 效果3选目标取消，不执行 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p27_ts_owner_mid: StringName = pending.get("pilot_027_owner_mid", &"")
		var p27_ts_owner_pid: StringName = pending.get("pilot_027_owner_pid", &"")
		# 目标仍须在 4+X 范围内（防移动/摧毁）
		if p27_ts_owner_mid == &"" or not _pilot_027_target_in_range(p27_ts_owner_mid, p27_ts_target):
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# ② stepper 给金金额：min 2，max=当前金币，步长5，可取消
		var p27_ts_player = context.game_state.players.get(p27_ts_owner_pid) if p27_ts_owner_pid != &"" else null
		var p27_ts_max: int = p27_ts_player.gold if p27_ts_player != null else 2
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
			"phase": &"pilot_027_choose_integer", "pilot_027_target_mech": p27_ts_target,
			"pilot_027_owner_mid": p27_ts_owner_mid, "pilot_027_owner_pid": p27_ts_owner_pid}
		action.record["_waiting_for_choose_integer"] = true
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"choose_integer", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"label": "维罗妮卡：给予 %s 多少金币（至少2）" % String(p27_ts_target),
			"min_value": 2,
			"max_value": p27_ts_max,
			"bind_as": "n",
			"optional": true,
			"stepper": true,
			"step": 5,
			"player_id": _effect_popup_owner_pid(effect, payload, action),
		})
		return
	# ② 给金金额：确认（chosen_value）→ 给金 + mark 次数 + 询问是否使用；取消 → 不执行（不消耗）
	if phase == &"pilot_027_choose_integer":
		action.record.erase("_waiting_for_choose_integer")
		var p27_ci_target: StringName = pending.get("pilot_027_target_mech", &"")
		var p27_ci_owner_mid: StringName = pending.get("pilot_027_owner_mid", &"")
		var p27_ci_owner_pid: StringName = pending.get("pilot_027_owner_pid", &"")
		if input_data.get("cancelled", false) or p27_ci_target == &"":
			SLog.log_raw("[TIMING] %s pilot_027 效果3给金取消，不执行 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p27_ci_amount: int = maxi(2, int(input_data.get("chosen_value", 2)))
		# ③ 给金（先扣自己再给目标；from_player 传递触发 GIVE_GOLD_AFTER 效果2 X+1）
		_pilot_027_give_gold(p27_ci_owner_pid, p27_ci_target, p27_ci_amount)
		# 给金完成即 mark once_per_turn（每回合2次用掉1次）；取消给金不消耗
		_mark_once_per_turn_used(effect, payload)
		# ④ 目标可用行动牌 → 询问是否立即使用（无可用牌则不弹询问，给金已生效结束）
		var p27_ci_usable: Array = _pilot_027_usable_action_cards(p27_ci_target)
		if p27_ci_usable.is_empty():
			SLog.log_raw("[TIMING] %s pilot_027 效果3给金完成但目标无可用行动牌，不询问 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
			"phase": &"pilot_027_ask_use", "pilot_027_target_mech": p27_ci_target}
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"choose_one_effect", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"options": [
				{"label": "是，使其立即使用1张行动牌", "effect_id": &"option_0", "option_index": 0},
				{"label": "否", "effect_id": &"option_1", "option_index": 1},
			],
			"optional": false,
			"source_label": "维罗妮卡：是否使 %s 立即使用1张行动牌？" % String(p27_ci_target),
			"player_id": _effect_popup_owner_pid(effect, payload, action),
		})
		return
	# ④ 询问是否立即使用：选"是"→ 目标选牌；"否"/取消 → 结束（给金已生效）
	if phase == &"pilot_027_ask_use":
		var p27_au_target: StringName = pending.get("pilot_027_target_mech", &"")
		var p27_au_opt: int = int(input_data.get("chosen_option_index", 1))
		if input_data.get("cancelled", false) or p27_au_opt != 0:
			SLog.log_raw("[TIMING] %s pilot_027 效果3选择不使用行动牌，结束 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var p27_au_usable: Array = _pilot_027_usable_action_cards(p27_au_target)
		if p27_au_usable.is_empty():
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# ⑤ 目标选1张可用行动牌（必须选；单选面板取消兜底=不使用结束）
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
			"phase": &"pilot_027_card_select", "pilot_027_target_mech": p27_au_target}
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"select_pilot_006_attack_card", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"card_ids": p27_au_usable,
			"target_mech_id": p27_au_target,
			"player_id": _effect_popup_owner_pid(effect, payload, action),
			"label": "维罗妮卡：选择1张行动牌使 %s 立即使用" % String(p27_au_target),
		})
		return
	# ⑤ 目标选牌：确认（selected_card_id）→ use_action_card 被动使用；取消 → 结束（给金已生效）
	if phase == &"pilot_027_card_select":
		var p27_cs_target: StringName = pending.get("pilot_027_target_mech", &"")
		var p27_cs_sel: StringName = input_data.get("selected_card_id", input_data.get("card_instance_id", &""))
		if p27_cs_sel != &"" and not input_data.get("cancelled", false):
			var p27_cs_player = context.game_state.get_player_for_mech(p27_cs_target) if (p27_cs_target != &"" and context != null and context.game_state != null) else null
			if p27_cs_player != null:
				# source_action_id 非空：效果产生的使用攻击牌不计攻击次数（被动攻击），
				# 并继承本效果动作作父动作（attack/use_action_card 挂起时父等待）。
				# 顶层 execute 后手动建父子链接（bug2：双连场景 fork2 响应窗口会覆盖其
				# 选牌/选目标弹窗的共享等待槽 -> 死锁），未同步完成则效果动作等待它。
				_link_spawned_use_action_as_child(context.action_service.execute(&"use_action_card", {
					"card_instance_id": p27_cs_sel,
					"mech_id": p27_cs_target,
					"player_id": p27_cs_player.player_id,
					"is_virtual": false,
					"target_count": 1,
					"source_action_id": action.action_id,
				}), action)
		SLog.log_raw("[TIMING] %s pilot_027 效果3选牌结束 use=%s effect=%s" % [String(action_id), String(p27_cs_sel), String(effect.effect_id)])
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	if phase == &"pilot_006_force_use_attack":
		var p06_target_mech: StringName = pending.get("pilot_006_target_mech", &"")
		var p06_selected: StringName = input_data.get("selected_card_id", input_data.get("card_instance_id", &""))
		var p06_cancelled: bool = input_data.get("cancelled", false) or p06_selected == &""
		if p06_cancelled:
			# 取消/无选择：回落4伤害（转 hp_change 子动作，挂起由下方 pending 检查捕获）
			_pilot_006_fallback_damage(p06_target_mech, action, payload)
		else:
			# 选牌：use_action_card（passive，source_action_id 非空不计攻击数，选攻击目标）
			var p06_player = context.game_state.get_player_for_mech(p06_target_mech) if (p06_target_mech != &"" and context != null and context.game_state != null) else null
			var p06_pid: StringName = p06_player.player_id if p06_player != null else &""
			var p06_use_params: Dictionary = {
				"card_instance_id": p06_selected,
				"mech_id": p06_target_mech,
				"player_id": p06_pid,
				"is_virtual": false,
				"target_count": 1,
				"source_action_id": action.action_id,
			}
			if context.action_service != null:
				# 顶层 execute 后手动建父子链接（bug2：双连场景 fork2 响应窗口会覆盖其
				# 选牌/选目标弹窗的共享等待槽 -> 死锁），未同步完成则效果动作等待它。
				_link_spawned_use_action_as_child(context.action_service.execute(&"use_action_card", p06_use_params), action)
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_pilot_006_force", "cancelled": p06_cancelled})
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_047 里欧娜 e1 分支① 立即使用1张攻击牌：被选机甲选攻击牌（no_cancel）→ use_action_card ──
	if phase == &"pilot_047_force_use_attack":
		action.record.erase("_pilot_047_force_shown")
		var p47_fu_target: StringName = pending.get("pilot_047_target_mech", &"")
		var p47_fu_to: StringName = pending.get("pilot_047_to_mech", &"")
		var p47_fu_count: int = int(pending.get("pilot_047_count", 3))
		var p47_fu_dpm: int = int(pending.get("pilot_047_dpm", 2))
		var p47_fu_selected: StringName = input_data.get("selected_card_id", input_data.get("card_instance_id", &""))
		var p47_fu_cancelled: bool = input_data.get("cancelled", false) or p47_fu_selected == &""
		if p47_fu_cancelled:
			# no_cancel 不应触发；防御：转交牌流程
			_handle_pilot_047_force_handover({"type": &"PILOT_047_FORCE_HANDOVER", "params": {
				"target_mech_id": p47_fu_target, "to_mech_id": p47_fu_to,
				"count": p47_fu_count, "damage_per_missing": p47_fu_dpm,
			}}, effect, payload, action)
		else:
			# 选牌：use_action_card（passive，source_action_id 非空不计攻击数）
			var p47_fu_player = context.game_state.get_player_for_mech(p47_fu_target) if (p47_fu_target != &"" and context != null and context.game_state != null) else null
			var p47_fu_pid: StringName = p47_fu_player.player_id if p47_fu_player != null else &""
			var p47_fu_use_params: Dictionary = {
				"card_instance_id": p47_fu_selected,
				"mech_id": p47_fu_target,
				"player_id": p47_fu_pid,
				"is_virtual": false,
				"target_count": 1,
				"source_action_id": action.action_id,
			}
			if context.action_service != null:
				# 顶层 execute 后手动建父子链接（bug2：双连场景 fork2 响应窗口会覆盖其
				# 选牌/选目标弹窗的共享等待槽 -> 死锁），未同步完成则效果动作等待它。
				_link_spawned_use_action_as_child(context.action_service.execute(&"use_action_card", p47_fu_use_params), action)
		SLog.log_raw("[TIMING] %s pilot_047 立即使用攻击牌 resume cancelled=%s effect=%s" % [String(action.action_id), p47_fu_cancelled, String(effect.effect_id)])
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_047 里欧娜 e1 分支② 交给牌：被选机甲选 count 张行动牌交出（no_cancel min=max=count）──
	if phase == &"pilot_047_force_handover":
		action.record.erase("_pilot_047_handover_shown")
		var p47_fh_target: StringName = pending.get("pilot_047_target_mech", &"")
		var p47_fh_to: StringName = pending.get("pilot_047_to_mech", &"")
		var p47_fh_count: int = int(pending.get("pilot_047_count", 3))
		var p47_fh_dpm: int = int(pending.get("pilot_047_dpm", 2))
		var p47_fh_selected: Array = input_data.get("selected_card_ids", [])
		if input_data.get("cancelled", false) or p47_fh_selected.is_empty():
			# no_cancel 不应触发；防御：视为 0 张交出 → 满差额伤害
			_pilot_047_do_handover(p47_fh_target, p47_fh_to, [], p47_fh_count, p47_fh_dpm, action, payload)
		else:
			_pilot_047_do_handover(p47_fh_target, p47_fh_to, p47_fh_selected, p47_fh_count, p47_fh_dpm, action, payload)
		SLog.log_raw("[TIMING] %s pilot_047 交给牌 resume 交出=%d effect=%s" % [String(action.action_id), p47_fh_selected.size(), String(effect.effect_id)])
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_018 苔丝 effect_01b 迎击弃牌：选了弃行动牌/装备牌类型 ──
	if phase == &"pilot_018_choose_type":
		var p18ct_cancelled: bool = input_data.get("cancelled", false)
		var p18ct_idx: int = int(input_data.get("chosen_option_index", -1))
		action.record.erase("_pilot_018_discard_shown")
		if p18ct_cancelled or p18ct_idx < 0:
			# 取消：不弃牌，结束
			action.record["_pilot_018_discard_done"] = true
			SLog.log_raw("[TIMING] %s pilot_018 迎击弃牌类型选择取消 effect=%s" % [String(action.action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# option_index 0=弃行动牌, 1=弃装备牌（与 _handle 弹窗顺序一致）
		payload["pilot_018_chosen_type"] = &"action_cards" if p18ct_idx == 0 else &"equipment_card"
		var p18ct_attacker: StringName = payload.get("attacker_id", &"")
		var p18ct_attacker_player = context.game_state.get_player_for_mech(p18ct_attacker) if (p18ct_attacker != &"" and context != null and context.game_state != null) else null
		var p18ct_pid: StringName = p18ct_attacker_player.player_id if p18ct_attacker_player != null else &""
		# 走分支（可能再次挂起弹选牌窗）
		if _pilot_018_execute_discard(effect, payload, action, p18ct_attacker, p18ct_pid):
			return  # 挂起弹选牌窗，等 resume
		# 已完成（直接弃/无可弃）：恢复 attack 继续
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_018 苔丝：选了要弃的2张行动牌 ──
	if phase == &"pilot_018_select_action_cards":
		var p18ac_selected: Array = input_data.get("card_ids", input_data.get("selected_card_ids", input_data.get("selected_action_card_ids", [])))
		var p18ac_attacker: StringName = payload.get("attacker_id", &"")
		var p18ac_player = context.game_state.get_player_for_mech(p18ac_attacker) if (p18ac_attacker != &"" and context != null and context.game_state != null) else null
		var p18ac_pid: StringName = p18ac_player.player_id if p18ac_player != null else &""
		if not p18ac_selected.is_empty():
			_pilot_018_do_discard(action, p18ac_selected, p18ac_pid)
		action.record["_pilot_018_discard_done"] = true
		SLog.log_raw("[TIMING] %s pilot_018 弃行动牌完成 effect=%s 弃=%d" % [String(action.action_id), String(effect.effect_id), p18ac_selected.size()])
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_018 苔丝：选了要弃的1张损伤≥2装备牌 ──
	if phase == &"pilot_018_select_equipment":
		var p18eq_selected: StringName = input_data.get("selected_card_id", input_data.get("card_instance_id", &""))
		var p18eq_attacker: StringName = payload.get("attacker_id", &"")
		var p18eq_player = context.game_state.get_player_for_mech(p18eq_attacker) if (p18eq_attacker != &"" and context != null and context.game_state != null) else null
		var p18eq_pid: StringName = p18eq_player.player_id if p18eq_player != null else &""
		if p18eq_selected != &"":
			_pilot_018_do_discard(action, [p18eq_selected], p18eq_pid)
		action.record["_pilot_018_discard_done"] = true
		SLog.log_raw("[TIMING] %s pilot_018 弃装备牌完成 effect=%s 弃=%s" % [String(action.action_id), String(effect.effect_id), String(p18eq_selected)])
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if not action.pending_effect_action_ids.is_empty():
			action.state = &"waiting_effect_action"
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_025 约书亚 1b：选了要设置的备用区装备牌 ──
	# payload._p025_reserve_cards 候选；选 selected_card_id -> 算合法目标槽，弹槽位选择窗。
	# 取消/无选 -> 结束（不发动 1b，恢复 attack）。
	if phase == &"pilot_025_reserve_select":
		var p025r_sel: StringName = input_data.get("selected_card_id", input_data.get("card_instance_id", &""))
		var p025r_cancelled: bool = input_data.get("cancelled", false) or p025r_sel == &""
		if p025r_cancelled:
			SLog.log_raw("[TIMING] %s pilot_025 取消设置备用区装备 effect=%s" % [String(action.action_id), String(effect.effect_id)])
			_pending_effect.erase(action.action_id)
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 算该装备牌可设置的合法目标槽（PART->对应槽+备用区，WEAPON->武器槽+备用区）
		var p025r_mech: StringName = payload.get("binding_context", {}).get("mech_id", &"")
		var p025r_valid_slots: Array = []
		var p025r_src_slot: StringName = &""
		if context != null and context.game_state != null and p025r_mech != &"":
			var p025r_m = context.game_state.mechs.get(p025r_mech)
			var p025r_card = context.game_state.get_card(p025r_sel)
			if p025r_m != null and p025r_card != null:
				p025r_valid_slots = _valid_set_slots_for_drawn_card(p025r_m, p025r_card)
				# 记录来源备用区槽（设置前需先从该槽移除）
				for p025r_sid in [&"reserve_1", &"reserve_2"]:
					var p025r_sslot = p025r_m.slots.get(p025r_sid)
					if p025r_sslot != null and p025r_sslot.equipped_card != null and p025r_sslot.equipped_card.instance_id == p025r_sel:
						p025r_src_slot = p025r_sid
						break
		if p025r_valid_slots.is_empty():
			SLog.log_raw("[TIMING] %s pilot_025 备用装备无合法目标槽，放弃 effect=%s" % [String(action.action_id), String(effect.effect_id)])
			_pending_effect.erase(action.action_id)
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 弹槽位选择窗（复用 immediate_set_equipment 面板，显示该牌+可选目标槽）
		var p025r_player_id: StringName = payload.get("binding_context", {}).get("player_id", &"")
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_025_slot_select",
			"selected_card_id": p025r_sel, "valid_slots": p025r_valid_slots, "src_slot": p025r_src_slot,
			"mech_id": p025r_mech, "player_id": p025r_player_id}
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"pilot_025_slot_select", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"drawn_card_id": p025r_sel,
			"valid_slots": p025r_valid_slots,
			"mech_id": p025r_mech,
			"player_id": p025r_player_id,
			"source_label": "约书亚：选择目标区域设置该备用区装备",
		})
		SLog.log_raw("[TIMING] %s pilot_025 选目标槽 effect=%s 牌=%s 槽=%d" % [String(action.action_id), String(effect.effect_id), String(p025r_sel), p025r_valid_slots.size()])
		return

	# ── pilot_025 约书亚 1b：选了目标槽 -> 移除备用区设入 + set_equipment 子动作 + 抽2行动牌 ──
	if phase == &"pilot_025_slot_select":
		var p025s_slot: StringName = input_data.get("chosen_slot_id", &"")
		var p025s_cancelled: bool = input_data.get("cancelled", false) or p025s_slot == &""
		var p025s_valid: Array = pending.get("valid_slots", [])
		var p025s_card: StringName = pending.get("selected_card_id", &"")
		var p025s_mech: StringName = pending.get("mech_id", &"")
		var p025s_pid: StringName = pending.get("player_id", &"")
		var p025s_src: StringName = pending.get("src_slot", &"")
		if p025s_cancelled or not p025s_valid.has(p025s_slot):
			SLog.log_raw("[TIMING] %s pilot_025 取消目标槽 effect=%s" % [String(action.action_id), String(effect.effect_id)])
			_pending_effect.erase(action.action_id)
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 从来源备用区槽移除装备牌，放回装备手牌（供 set_equipment 走标准设置流程 erasing hand）。
		# reserve 装备为 face_down 白板，移除即变回普通手牌（face_down 在 set_equipment._step_place_equip 按目标槽重设）。
		if context != null and context.game_state != null and p025s_mech != &"" and p025s_src != &"":
			var p025s_m = context.game_state.mechs.get(p025s_mech)
			var p025s_player = context.game_state.get_player_for_mech(p025s_mech)
			if p025s_m != null and p025s_player != null:
				var p025s_sslot = p025s_m.slots.get(p025s_src)
				if p025s_sslot != null and p025s_sslot.equipped_card != null and p025s_sslot.equipped_card.instance_id == p025s_card:
					p025s_sslot.equipped_card = null
				if not p025s_player.equipment_hand.has(p025s_card):
					p025s_player.equipment_hand.append(p025s_card)
		# 串行执行：set_equipment（带 slot_id，即时使用 hook 自动生效）-> 抽2张行动牌。
		# 用 _seq_effect_actions 标准串行机制，子动作完成后由 _after_sub_action_finished 续跑抽牌。
		var p025s_remaining: Array = [
			{"type": &"EXECUTE_SET_EQUIP", "params": {"card_id": p025s_card, "mech_id": p025s_mech, "slot_id": p025s_slot}},
			{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 2, "player_id": p025s_pid, "mech_ids": [p025s_mech]}},
		]
		_pending_effect.erase(action.action_id)
		action.record["_pilot_025_done"] = true
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": p025s_remaining, "source_check": false}
		action.state = &"waiting_effect_action"
		SLog.log_raw("[TIMING] %s pilot_025 设置装备+抽2 牌=%s 槽=%s effect=%s" % [String(action.action_id), String(p025s_card), String(p025s_slot), String(effect.effect_id)])
		if _continue_seq_effect_actions(action):
			return
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 通用「查看隐藏装备」Phase B（霍恩 pilot_046 等）：选了要获取的隐藏牌 → 校验金够/每回合未用
	#     → 弹 choice_panel(allow_cancel=false) 选目标 RESERVE 槽（全部玩家）。取消/无效 → 结束（不扣金）。
	if phase == &"hidden_card_view":
		var h46_params: Dictionary = pending.get("act", {}).get("params", {})
		var h46_key: StringName = h46_params.get("once_per_turn_key", &"")
		var h46_bind: Dictionary = payload.get("binding_context", {})
		var h46_src_cid: StringName = h46_bind.get("card_instance_id", &"")
		var h46_owner_pid: StringName = pending.get("owner_pid", &"")
		var h46_sel: StringName = input_data.get("selected_card_id", &"")
		var h46_cancelled: bool = input_data.get("cancelled", false) or h46_sel == &""
		if h46_cancelled:
			SLog.log_raw("[TIMING] %s 隐藏查看面板关闭 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 校验：每回合未用（查看无条件但获取限次）+ 牌有效 + 金币够（牌面原价）
		if h46_key != &"" and h46_src_cid != &"" and not is_once_per_turn_key_available(h46_key, h46_src_cid, 1):
			SLog.log_raw("[TIMING] %s 隐藏获取每回合已用满，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var h46_gs = context.game_state
		var h46_card = h46_gs.get_card(h46_sel) if h46_gs != null else null
		var h46_price: int = _hidden_card_face_cost(h46_card)
		var h46_player = h46_gs.players.get(h46_owner_pid) if h46_gs != null else null
		if h46_card == null or h46_player == null or h46_player.gold < h46_price:
			SLog.log_raw("[TIMING] %s 隐藏获取校验失败（牌无效/金币不足 需%d），中止 effect=%s" % [String(action_id), h46_price, String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 收集全部机甲的 RESERVE 槽作为目标候选（含自己）
		var h46_target_opts: Array[Dictionary] = []
		var h46_target_map: Dictionary = {}
		for h46_m in h46_gs.mechs.values():
			if h46_m == null:
				continue
			for h46_sid in h46_m.slots:
				var h46_slot = h46_m.slots[h46_sid]
				if h46_slot == null or h46_slot.slot_kind != &"RESERVE":
					continue
				var h46_mname: String = String(h46_m.frame_def.display_name) if h46_m.frame_def != null and "display_name" in h46_m.frame_def else String(h46_m.mech_id)
				var h46_occ: String = ""
				if h46_slot.equipped_card != null and h46_slot.equipped_card.def != null:
					h46_occ = String(h46_slot.equipped_card.def.display_name)
				var h46_opt_id: String = "%s:%s" % [String(h46_m.mech_id), String(h46_sid)]
				h46_target_opts.append({
					"label": "%s·%s%s" % [h46_mname, String(h46_sid), ("（当前:%s）" % h46_occ) if h46_occ != "" else "（空）"],
					"effect_id": StringName(h46_opt_id),
				})
				h46_target_map[h46_opt_id] = {"mech_id": h46_m.mech_id, "slot_id": h46_sid}
		if h46_target_opts.is_empty():
			SLog.log_raw("[TIMING] %s 无目标备用区，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload,
			"phase": &"hidden_reserve_slot", "act": pending.get("act", {}), "owner_pid": h46_owner_pid,
			"selected_card_id": h46_sel, "price": h46_price, "target_map": h46_target_map}
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"hidden_reserve_slot", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"player_id": h46_owner_pid,
			"options": h46_target_opts,
			"label": "选择放置的备用区域（显示当前牌）",
		})
		SLog.log_raw("[TIMING] %s 隐藏获取选目标备用区 effect=%s 牌=%s" % [String(action_id), String(effect.effect_id), String(h46_sel)])
		return

	# ── 通用「查看隐藏装备」Phase B（霍恩 pilot_046 等）：选定目标 RESERVE 槽 → 清来源 + 重置归属
	#     + 追加目标手牌 + _seq[SPEND_GOLD(原价), MARK计次, EXECUTE_SET_EQUIP]。目标强制选择不可取消。
	if phase == &"hidden_reserve_slot":
		var h46b_sel: StringName = pending.get("selected_card_id", &"")
		var h46b_price: int = pending.get("price", 0)
		var h46b_owner_pid: StringName = pending.get("owner_pid", &"")
		var h46b_tmid: StringName = input_data.get("target_mech_id", &"")
		var h46b_tsid: StringName = input_data.get("target_slot_id", &"")
		var h46b_cancelled: bool = input_data.get("cancelled", false) or h46b_tmid == &"" or h46b_tsid == &""
		var h46b_tmap: Dictionary = pending.get("target_map", {})
		if h46b_cancelled or not h46b_tmap.has("%s:%s" % [String(h46b_tmid), String(h46b_tsid)]):
			SLog.log_raw("[TIMING] %s 隐藏获取目标备用区无效，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var h46b_gs = context.game_state
		var h46b_card = h46b_gs.get_card(h46b_sel) if h46b_gs != null else null
		if h46b_card == null:
			SLog.log_raw("[TIMING] %s 隐藏获取来源牌缺失，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var h46b_target_player = h46b_gs.get_player_for_mech(h46b_tmid) if h46b_gs != null else null
		if h46b_target_player == null:
			h46b_target_player = h46b_gs.players.get(h46b_owner_pid)
		if h46b_target_player == null:
			SLog.log_raw("[TIMING] %s 目标玩家不存在，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 清来源（商店隐藏槽/来源机甲 RESERVE 槽）+ 重置归属到目标玩家 + 追加目标手牌（供 set_equipment 走标准流程）
		_clear_hidden_card_source(h46b_card, h46b_gs)
		h46b_card.owner_player_id = h46b_target_player.player_id
		if not h46b_target_player.equipment_hand.has(h46b_sel):
			h46b_target_player.equipment_hand.append(h46b_sel)
		# 串行执行：扣金（牌面原价）→ 标记每回合1次 → 设置装备（目标 RESERVE 槽自动 face_down，
		# 旧牌 equipment_replace 弃置）。
		var h46b_remaining: Array = [
			{"type": &"SPEND_GOLD", "params": {"player_id": h46b_owner_pid, "amount": h46b_price, "reason": &"pilot_046_acquire"}},
			{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": pending.get("act", {}).get("params", {}).get("once_per_turn_key", &"")}},
			{"type": &"EXECUTE_SET_EQUIP", "params": {"card_id": h46b_sel, "mech_id": h46b_tmid, "slot_id": h46b_tsid}},
		]
		_pending_effect.erase(action.action_id)
		action.record["_pilot_046_done"] = true
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": h46b_remaining, "source_check": false}
		action.state = &"waiting_effect_action"
		SLog.log_raw("[TIMING] %s 隐藏获取执行 effect=%s 牌=%s 目标=%s/%s 金=%d" % [String(action_id), String(effect.effect_id), String(h46b_sel), String(h46b_tmid), String(h46b_tsid), h46b_price])
		if _continue_seq_effect_actions(action):
			return
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 通用「抽到的装备背面置备用区」（CHOOSE_RESERVE_SLOT_AND_SET_EQUIP，法尔科 pilot_073 等）：
	#     已选目标 RESERVE 槽（复用 hidden_reserve_slot 弹窗回填 target_mech_id/target_slot_id，强制不可取消）
	#     → 从打标签玩家手牌移除 + 归属改目标玩家 → _seq[EXECUTE_SET_EQUIP(card,mech,slot)]（RESERVE 自动 face_down）。
	if phase == &"choose_reserve_slot_and_set":
		var rs_b_tmid: StringName = input_data.get("target_mech_id", &"")
		var rs_b_tsid: StringName = input_data.get("target_slot_id", &"")
		var rs_b_cancelled: bool = input_data.get("cancelled", false) or rs_b_tmid == &"" or rs_b_tsid == &""
		var rs_b_tmap: Dictionary = pending.get("target_map", {})
		if rs_b_cancelled or not rs_b_tmap.has("%s:%s" % [String(rs_b_tmid), String(rs_b_tsid)]):
			SLog.log_raw("[TIMING] %s 置备用区目标无效，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var rs_b_card_id: StringName = pending.get("card_id", &"")
		var rs_b_owner_pid: StringName = pending.get("owner_pid", &"")
		var rs_b_gs = context.game_state
		var rs_b_card = rs_b_gs.get_card(rs_b_card_id) if rs_b_gs != null else null
		if rs_b_card == null:
			SLog.log_raw("[TIMING] %s 置备用区牌缺失，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		var rs_b_target_player = rs_b_gs.get_player_for_mech(rs_b_tmid) if rs_b_gs != null else null
		if rs_b_target_player == null:
			rs_b_target_player = rs_b_gs.players.get(rs_b_owner_pid)
		if rs_b_target_player == null:
			SLog.log_raw("[TIMING] %s 目标玩家不存在，中止 effect=%s" % [String(action_id), String(effect.effect_id)])
			if context.action_engine != null:
				action.state = &"waiting_input"
				context.action_engine.continue_action(action_id, {})
			return
		# 从打标签玩家（抽牌玩家）手牌移除 + 归属改目标玩家（供 set_equipment 走标准流程；
		# 禁标签 owner 不变，仍由打标签玩家下回合开始后清除）
		var rs_b_owner_player = rs_b_gs.players.get(rs_b_owner_pid)
		if rs_b_owner_player != null:
			rs_b_owner_player.equipment_hand.erase(rs_b_card_id)
		rs_b_card.owner_player_id = rs_b_target_player.player_id
		if not rs_b_target_player.equipment_hand.has(rs_b_card_id):
			rs_b_target_player.equipment_hand.append(rs_b_card_id)
		# 串行执行：效果驱动设置到目标 RESERVE 槽（自动 face_down，旧牌 equipment_replace 弃置）。
		# 每回合1次已在 CHOOSE_MANY_CARDS 确认时标记，此处不再 MARK。
		var rs_b_remaining: Array = [
			{"type": &"EXECUTE_SET_EQUIP", "params": {"card_id": rs_b_card_id, "mech_id": rs_b_tmid, "slot_id": rs_b_tsid}},
		]
		_pending_effect.erase(action.action_id)
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": rs_b_remaining, "source_check": false}
		action.state = &"waiting_effect_action"
		SLog.log_raw("[TIMING] %s 置备用区执行 effect=%s 牌=%s 目标=%s/%s" % [String(action_id), String(effect.effect_id), String(rs_b_card_id), String(rs_b_tmid), String(rs_b_tsid)])
		if _continue_seq_effect_actions(action):
			return
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── 通用「动力税」确认（POWER_SPEND_TAX，杰西卡 pilot_050 e1）：
	#     拒绝 -> 清掉本次累计（已在触发时扣），剩余询问继续问；确认 -> 两次独立 hp_change
	#     子动作链（先该机甲后我方，顺序结算），链尾 POWER_SPEND_TAX_CONTINUE 检查剩余询问。 ──
	if phase == &"power_tax_confirm":
		var ptx_ctx: Dictionary = action.record.get("_power_tax_ctx", {})
		var ptx_cancelled: bool = input_data.get("cancelled", false) or int(input_data.get("chosen_option_index", -1)) < 0
		if ptx_cancelled:
			# 拒绝：本次累计清零（已扣），剩余询问继续弹
			ptx_ctx["prompts_left"] = int(ptx_ctx.get("prompts_left", 1)) - 1
			SLog.log_raw("[TIMING] %s 动力税确认被拒（剩%d次）effect=%s" % [String(action_id), int(ptx_ctx["prompts_left"]), String(effect.effect_id)])
			if int(ptx_ctx["prompts_left"]) > 0:
				action.record["_power_tax_ctx"] = ptx_ctx
				_power_tax_prompt_confirm(action, payload, effect)
				return
			action.record.erase("_power_tax_ctx")
			_continue_seq_effect_actions(action)  # 清空残留链（若有）
			_power_tax_resume_host(action, action_id)
			return
		# 确认：两次独立生命变动（先该机甲后我方；来源均为我方；顺序结算：双方同濒死该机甲先死），
		# 链尾哨兵续问剩余次数。
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": [
			{"type": &"EXECUTE_HP_CHANGE", "params": {
				"mech_ids": [ptx_ctx.get("target_mech_id", &"")],
				"value": int(ptx_ctx.get("damage", 2)),
				"method": &"decrease",
				"source_mech_id": ptx_ctx.get("owner_mech_id", &""),
				"reason": &"power_tax",
			}},
			{"type": &"EXECUTE_HP_CHANGE", "params": {
				"mech_ids": [ptx_ctx.get("owner_mech_id", &"")],
				"value": int(ptx_ctx.get("damage", 2)),
				"method": &"decrease",
				"source_mech_id": ptx_ctx.get("owner_mech_id", &""),
				"reason": &"power_tax",
			}},
			{"type": &"POWER_SPEND_TAX_CONTINUE"},
		], "source_check": false, "effect": effect}
		SLog.log_raw("[TIMING] %s 动力税确认执行双 hp_change effect=%s" % [String(action_id), String(effect.effect_id)])
		if not _continue_seq_effect_actions(action):
			_power_tax_resume_host(action, action_id)
		return

	# ── 通用「动力税贡赋」确认（POWER_TAX_TRIBUTE，杰西卡 pilot_050 e2）：
	#     取消 -> 不发动不 mark（不消耗每回合1次）；确认 -> mark + X+1 -> 按新X选目标机甲。 ──
	if phase == &"power_tax_tribute_confirm":
		var tt_ctx: Dictionary = action.record.get("_power_tax_tribute", {})
		var tt_p: Dictionary = tt_ctx.get("params", {})
		var tt_cancelled: bool = input_data.get("cancelled", false) or int(input_data.get("chosen_option_index", -1)) < 0
		if tt_cancelled:
			action.record.erase("_power_tax_tribute")
			SLog.log_raw("[TIMING] %s 动力税贡赋确认被取消（不消耗次数）effect=%s" % [String(action_id), String(effect.effect_id)])
			_power_tax_resume_host(action, action_id)
			return
		# 确认：mark 每回合1次 + X+1（写绑定卡实例 counters["var_<counter_key>"]，先于范围计算）
		var tt_key: StringName = tt_p.get("once_per_turn_key", &"")
		if tt_key != &"":
			mark_once_per_turn_key_used(tt_key, tt_ctx.get("card_instance_id", &""))
		var tt_card = context.game_state.get_card(tt_ctx.get("card_instance_id", &""))
		var tt_x: int = 0
		if tt_card != null:
			if tt_card.counters == null:
				tt_card.counters = {}
			var tt_ck: String = "var_%s" % String(tt_p.get("counter_key", &""))
			tt_x = int(tt_card.counters.get(tt_ck, 0)) + 1
			tt_card.counters[tt_ck] = tt_x
		SLog.log_raw("[TIMING] %s 动力税贡赋确认：X+1 -> %d effect=%s" % [String(action_id), tt_x, String(effect.effect_id)])
		# 按新 X 算候选（base_range + X 内其他机甲）；无候选 -> 仅 X+1，弃牌整段跳过
		var tt_owner_mid: StringName = tt_ctx.get("owner_mech_id", &"")
		var tt_owner = context.game_state.mechs.get(tt_owner_mid)
		var tt_candidates: Array = []
		if tt_owner != null:
			for mid: StringName in context.game_state.mechs:
				if mid == tt_owner_mid:
					continue
				var m = context.game_state.mechs[mid]
				if m == null or m.destroyed:
					continue
				if _HexGrid.distance(tt_owner.position, m.position) <= int(tt_p.get("base_range", 4)) + tt_x:
					tt_candidates.append(mid)
		if tt_candidates.is_empty():
			action.record.erase("_power_tax_tribute")
			SLog.log_raw("[TIMING] %s 动力税贡赋：4+%d格内无其他机甲，仅 X+1 effect=%s" % [String(action_id), tt_x, String(effect.effect_id)])
			_power_tax_resume_host(action, action_id)
			return
		# 选目标机甲（常规目标UI，valid_mech_ids 高亮；chooser=我方玩家）
		action.record["_waiting_for_target"] = true
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"power_tax_tribute_target"}
		action.state = &"waiting_timing"
		action_needs_input.emit(action.action_id, &"select_mech_target", {
			"action_id": action.action_id,
			"effect_id": effect.effect_id,
			"rule": &"mech_target_select",
			"mech_id": tt_owner_mid,
			"valid_mech_ids": tt_candidates,
			"player_id": tt_ctx.get("owner_player_id", &""),
			"source_label": "选择1台%d格内的其他机甲（弃其%d张行动牌）" % [int(tt_p.get("base_range", 4)) + tt_x, int(tt_p.get("discard_count", 2))],
		})
		SLog.log_raw("[TIMING] %s 挂起动力税贡赋选目标（候选%d台 范围%d+%d）effect=%s" % [String(action_id), tt_candidates.size(), int(tt_p.get("base_range", 4)), tt_x, String(effect.effect_id)])
		return

	# ── 动力税贡赋：选定目标机甲 -> 启动弃牌链（先我方后目标，两段哨兵串行）。
	#     取消/无选 -> X+1 已生效（次数已消耗），跳过弃牌。 ──
	if phase == &"power_tax_tribute_target":
		action.record.erase("_waiting_for_target")
		var tt2_ctx: Dictionary = action.record.get("_power_tax_tribute", {})
		var tt2_target: StringName = input_data.get("target_id", input_data.get("target_mech_id", &""))
		if input_data.get("cancelled", false) or tt2_target == &"":
			action.record.erase("_power_tax_tribute")
			SLog.log_raw("[TIMING] %s 动力税贡赋选目标取消（X+1 已生效，跳过弃牌）effect=%s" % [String(action_id), String(effect.effect_id)])
			_power_tax_resume_host(action, action_id)
			return
		tt2_ctx["target_mech_id"] = tt2_target
		action.record["_power_tax_tribute"] = tt2_ctx
		# 弃牌链：我方侧 -> 目标侧 -> 清理（两段独立 EXECUTE_DISCARD；>count 弹窗挂起由 resume 续跑）
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": [
			{"type": &"POWER_TAX_TRIBUTE_DISCARD_SIDE", "params": {"side": &"owner"}},
			{"type": &"POWER_TAX_TRIBUTE_DISCARD_SIDE", "params": {"side": &"target"}},
			{"type": &"POWER_TAX_TRIBUTE_CLEANUP"},
		], "source_check": false, "effect": effect}
		SLog.log_raw("[TIMING] %s 动力税贡赋目标=%s 启动弃牌链 effect=%s" % [String(action_id), String(tt2_target), String(effect.effect_id)])
		if not _continue_seq_effect_actions(action):
			_power_tax_resume_host(action, action_id)
		return

	# ── 动力税贡赋：选定了该侧要弃的 count 张行动牌 -> EXECUTE_DISCARD 子动作 ──
	if phase == &"power_tax_tribute_discard":
		var tt3_ctx: Dictionary = action.record.get("_power_tax_tribute", {})
		var tt3_side: StringName = tt3_ctx.get("discard_side", &"owner")
		var tt3_selected: Array = input_data.get("card_ids", input_data.get("selected_card_ids", []))
		if input_data.get("cancelled", false) or tt3_selected.is_empty():
			# no_cancel 不应触发；防御：跳过该侧弃牌
			SLog.log_raw("[TIMING] %s 动力税贡赋 %s 侧空选跳过 effect=%s" % [String(action_id), String(tt3_side), String(effect.effect_id)])
			_power_tax_resume_host(action, action_id)
			return
		# 弃置所选牌：插到现有 _seq 链头部（保留哨兵弹出前已存的后续动作，如 CLEANUP），
		# 子动作完成后由 _continue_seq_effect_actions 续跑。
		var tt3_rem: Array = [{"type": &"EXECUTE_DISCARD", "params": {"card_ids": tt3_selected, "reason": &"power_tax_tribute"}}]
		if action.record.has("_seq_effect_actions"):
			var tt3_seq: Dictionary = action.record["_seq_effect_actions"]
			tt3_rem.append_array(tt3_seq.get("remaining", []))
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": tt3_rem, "source_check": false, "effect": effect}
		SLog.log_raw("[TIMING] %s 动力税贡赋 %s 侧弃 %d 张 effect=%s" % [String(action_id), String(tt3_side), tt3_selected.size(), String(effect.effect_id)])
		if not _continue_seq_effect_actions(action):
			_power_tax_resume_host(action, action_id)
		return

	# ── 通用「受伤回复」确认（INJURY_HEAL_DRAW，芮贝卡 pilot_078）：
	#     取消 -> 不发动不 mark（不消耗每回合次数）；确认 -> mark 每回合1次（消耗1次）+
	#     串行 [EXECUTE_HP_CHANGE 受伤机甲回复, EXECUTE_GAIN_CARD 受伤机甲所属玩家抽牌]。 ──
	if phase == &"injury_heal_draw_confirm":
		var ihd_r_ctx: Dictionary = action.record.get("_injury_heal_draw", {})
		var ihd_r_p: Dictionary = ihd_r_ctx.get("params", {})
		var ihd_r_cancelled: bool = input_data.get("cancelled", false) or int(input_data.get("chosen_option_index", -1)) < 0
		if ihd_r_cancelled:
			action.record.erase("_injury_heal_draw")
			SLog.log_raw("[TIMING] %s 受伤回复确认被取消（不消耗次数）effect=%s" % [String(action_id), String(effect.effect_id)])
			_power_tax_resume_host(action, action_id)
			return
		# 确认：mark 每回合1次（消耗1次，每玩家回合自动重置）
		var ihd_r_key: StringName = ihd_r_p.get("once_per_turn_key", &"")
		if ihd_r_key != &"":
			mark_once_per_turn_key_used(ihd_r_key, ihd_r_ctx.get("card_instance_id", &""))
		# 哨兵：本效果已确认发动，重跑 _execute_effect 时直接跳过（不重复弹窗）
		payload["_injury_heal_draw_done"] = true
		var ihd_r_tgt: StringName = ihd_r_ctx.get("target_mech_id", &"")
		var ihd_r_tpid: StringName = ihd_r_ctx.get("target_player_id", &"")
		var ihd_r_src: StringName = ihd_r_ctx.get("owner_mech_id", &"")
		# 串行子动作链：先回复生命，再受伤机甲所属玩家抽行动牌（链空 -> 恢复主机）
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": [
			{"type": &"EXECUTE_HP_CHANGE", "params": {
				"mech_ids": [ihd_r_tgt],
				"value": int(ihd_r_p.get("heal_amount", 2)),
				"method": &"restore",
				"source_mech_id": ihd_r_src,
				"reason": &"injury_heal_draw",
			}},
			{"type": &"EXECUTE_GAIN_CARD", "params": {
				"from_zone": &"action_deck",
				"card_kind": &"action",
				"count": int(ihd_r_p.get("draw_count", 1)),
				"player_id": ihd_r_tpid,
				"mech_ids": [ihd_r_tgt],
				"reason": &"injury_heal_draw",
			}},
		], "source_check": false, "effect": effect}
		SLog.log_raw("[TIMING] %s 受伤回复确认：%s回复%d生命+抽%d行动牌 effect=%s" % [String(action_id), String(ihd_r_tgt), int(ihd_r_p.get("heal_amount", 2)), int(ihd_r_p.get("draw_count", 1)), String(effect.effect_id)])
		if not _continue_seq_effect_actions(action):
			_power_tax_resume_host(action, action_id)
		return
	# 存置顶牌到 payload(pilot_003_top_card_id)，标记 once，续跑剩余 actions（INSERT 用 deck_top_card_id 置顶+打标签）。
	# ── 通用「攻击结算→抽牌+弃X再攻击」确认（ATTACK_SETTLE_DRAW_REATTACK，维奥拉 pilot_077）：
	#     取消 -> 不发动不 mark（不消耗每回合次数）；确认 -> mark 每回合1次（消耗1次）+
	#     串行 [EXECUTE_DISCARD 弃所选牌, 开凯威攻击窗口给攻击方]。 ──
	if phase == &"attack_settle_draw_reattack_discard":
		var asr_r_ctx: Dictionary = action.record.get("_attack_settle_draw_reattack", {})
		var asr_r_p: Dictionary = asr_r_ctx.get("params", {})
		var asr_r_selected: Array = input_data.get("card_ids", input_data.get("selected_card_ids", []))
		if input_data.get("cancelled", false) or asr_r_selected.is_empty():
			action.record.erase("_attack_settle_draw_reattack")
			SLog.log_raw("[TIMING] %s 攻击结算弃牌取消（不消耗次数）effect=%s" % [String(action_id), String(effect.effect_id)])
			_power_tax_resume_host(action, action_id)
			return
		# 确认：mark 每回合1次（消耗1次，每玩家回合自动重置）
		var asr_r_key: StringName = asr_r_p.get("once_per_turn_key", &"")
		if asr_r_key != &"":
			mark_once_per_turn_key_used(asr_r_key, asr_r_ctx.get("card_instance_id", &""))
		# 哨兵：本效果已确认发动，重跑 _execute_effect 时直接跳过（不重复弹窗）
		payload["_attack_settle_draw_reattack_done"] = true
		# 串行子动作链：先弃所选牌，再给攻击方开凯威攻击窗口（链空 -> 恢复主机）
		action.record["_seq_effect_actions"] = {"payload": payload, "remaining": [
			{"type": &"EXECUTE_DISCARD", "params": {"card_ids": asr_r_selected, "reason": &"attack_settle_draw_reattack"}},
			{"type": &"ATTACK_SETTLE_DRAW_REATTACK_OPEN_WINDOW", "params": {}},
		], "source_check": false, "effect": effect}
		if not _continue_seq_effect_actions(action):
			_power_tax_resume_host(action, action_id)
		return
	if phase == &"pilot_003_choose_top":
		var p003t_sel: StringName = input_data.get("selected_card_id", input_data.get("card_instance_id", &""))
		var p003t_cancelled: bool = input_data.get("cancelled", false) or p003t_sel == &""
		payload["pilot_003_top_card_id"] = p003t_sel if not p003t_cancelled else &""
		SLog.log_raw("[TIMING] %s pilot_003 置顶 %s" % [String(action.action_id), "取消" if p003t_cancelled else String(p003t_sel)])
		# 玩家已在 CHOOSE_MANY 确认选牌（非取消才到此），消耗本回合1次
		_mark_once_per_turn_used(effect, payload)
		_mark_once_per_game_used(effect, payload)
		# 续跑剩余 actions（INSERT：deck_top_card_id=$runtime.pilot_003_top_card_id 置顶 + face_up_bury 标签）
		var p003t_act_idx: int = int(pending.get("act_idx", -1))
		if p003t_act_idx >= 0 and effect.actions.size() > p003t_act_idx + 1:
			action.record["_seq_effect_actions"] = {"payload": payload, "remaining": effect.actions.slice(p003t_act_idx + 1), "effect": effect}
			action.state = &"waiting_effect_action"
			if _continue_seq_effect_actions(action):
				return
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
			return
		if context.action_engine != null:
			action.state = &"waiting_input"
			context.action_engine.continue_action(action_id, {})
		return

	# ── pilot_003 effect_03 复选框提交：玩家勾选了跳过玩家集合 ──
	if phase == &"pilot_003_skip_players":
		var sp_player_ids: Array = input_data.get("player_ids", [])
		var sp_cancelled: bool = bool(input_data.get("cancelled", false))
		if not sp_cancelled and context != null and context.game_actions != null:
			context.game_actions.set_pilot_003_skip_players({"player_ids": sp_player_ids}, payload)
		SLog.log_raw("[TIMING] %s pilot_003 复选框 %s 跳过玩家: %s" % [String(action.action_id), "取消" if sp_cancelled else "提交", str(sp_player_ids)])
		if action.state == &"waiting_timing" and _pending_effect.has(action.action_id):
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

	# ── 机师牌放置阶段（事件牌招募 e008）：玩家选了「设置到机师区域 / 放回牌堆底」 ──
	if phase == &"pilot_draw_place":
		var pdp_card_id_r: StringName = pending.get("pilot_card_id", &"")
		var pdp_mech_id_r: StringName = pending.get("mech_id", &"")
		var pdp_choice: int = int(input_data.get("chosen_option_index", -1))
		if pdp_choice == 0:
			_pilot_place_to_slot(pdp_mech_id_r, pdp_card_id_r, false)
		elif pdp_choice == 1 or pdp_choice < 0:
			# 放回牌堆底（取消/非法选择兜底也是放牌堆底：牌已离堆不可弃置）
			if context != null and context.deck_service != null:
				context.deck_service.move_card_to_deck_bottom(pdp_card_id_r, &"pilot_deck")
		SLog.log_effect(effect.effect_id, action.source, action.action_id, String(action.action_type), {"status": "resuming_after_pilot_place", "choice": pdp_choice})
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
		_mark_once_per_game_used(effect, payload)
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
	_mark_once_per_game_used(effect, payload)

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
	if cid == &"":
		return cid
	# 授予/跨机甲使用：各目标独立计数（泰特 pilot_074 授予他机后不共享来源的每回合N次）。
	# equipment_panel 显示（EX 按钮悬停）须调用同一 once_per_turn_scope_cid，保证计数键一致。
	return once_per_turn_scope_cid(bind_ctx, cid, payload if payload != null else {})


## 授予/跨机甲使用 once_per_turn 计数隔离（通用件，不绑机师）：
## 同一效果被授予到目标机甲后，应各目标独立计数，而不是共享来源牌实例的每回合N次。
## 判定：① binding.granted=true（LISTEN 触发/显示侧，bind_ctx 携带 mech_id=目标机甲）
##       ② 来源牌所在机甲 ≠ 执行机甲（DIRECT effect_fire 授予路径——_net_granted_effect
##          的 payload 无 binding_context，用结构判定兜底）。
## 合成独立计数键 = "{cid}__granted__{mech_id}"。engine 计数与面板显示共用此键。
## 若无法判定（无目标机甲/来源牌不在场/牌无机甲归属）则原样返回 cid（不隔离）。
## 兜底仅限 bind_ctx 为空的调用（DIRECT effect_fire 授予路径 payload 无 ctx）：
## LISTEN 监听路径 fire_timing 注入的 bind_ctx.mech_id=注册监听器的来源牌机甲，执行机甲
## 即它；若仍跑结构判定，payload.mech_id 是被监听动作的目标机甲（如李 pilot_051 e2 拦截
## 敌方 EVENT_SET_BEFORE 时 =敌方机甲），会被误判"授予"合成 __granted__ 键；转设我方重入时
## payload.mech_id=我方机甲，键名又变回原样，mark 与 check 两键不一致 -> once_per_game 失效
## -> 第二个拦截窗（PvP3 实机「李本局1次要点两次」根因）。
func once_per_turn_scope_cid(bind_ctx: Dictionary, cid: StringName, payload: Dictionary = {}) -> StringName:
	if cid == &"":
		return cid
	var target_mech: StringName = &""
	if not bind_ctx.is_empty() and bool(bind_ctx.get("granted", false)):
		target_mech = bind_ctx.get("mech_id", &"")
	if target_mech == &"" and bind_ctx.is_empty() and payload != null and not payload.is_empty():
		var acting: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
		if acting != &"" and context != null and context.get("game_state") != null:
			var card = context.game_state.get_card(cid)
			if card != null:
				var card_mech: StringName = card.mech_id
				if String(card_mech) != "" and String(card_mech) != String(acting):
					target_mech = acting
	if target_mech != &"":
		return StringName("%s__granted__%s" % [String(cid), String(target_mech)])
	return cid

## 取当前回合号（once_per_turn 的 scope key）。
## "每回合1次"= 每个玩家回合各1次（先手回合用1次，后手回合还能用1次），非"每轮1次"。
## game_state.turn_number 只在先手回合递增（TurnService），故用 turn_number * 玩家数 + 位次
## 区分各玩家回合。原硬编码 *2 仅适用2人，3人模式 seat=2 时 base*2+2=(base+1)*2 与下轮先手
## 回合冲突，致 once_per_turn 误判已用（迪恩效果1 3人模式应3次实只生效更少）。
func _current_turn_number() -> int:
	if context == null or context.get("game_state") == null:
		return 0
	var gs = context.game_state
	var base: int = int(gs.turn_number)
	if context.round_service != null:
		var order_size: int = context.round_service.turn_order.size()
		if order_size > 0:
			var seat: int = context.round_service.turn_order.find(gs.active_player_id)
			if seat >= 0:
				return base * order_size + seat
	return base

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


## 按 key 检查某来源牌实例的每回合N次是否可用（跨效果共享额度的通用件）。
## 用于效果分支里"消耗另一个效果的额度"（如布鲁克 effect_02 的转化防御分支复用 effect_01 的每回合1次）。
## card_instance_id 为空时视为不限制（可用），与 _is_once_per_turn_used_up 的空实例退路一致。
func is_once_per_turn_key_available(once_per_turn_key: StringName, card_instance_id: StringName, once_per_turn_max: int = 1) -> bool:
	if once_per_turn_key == &"" or card_instance_id == &"":
		return true
	var key: String = "%s:%s" % [String(card_instance_id), String(once_per_turn_key)]
	var turn_id: int = _current_turn_number()
	var turn_map: Dictionary = _once_per_turn_used.get(key, {})
	var used: int = int(turn_map.get(turn_id, 0))
	return used < once_per_turn_max


## 按 key 标记某来源牌实例的每回合N次已使用（+1）。供原子动作 MARK_EFFECT_ONCE_PER_TURN_USED 调用。
func mark_once_per_turn_key_used(once_per_turn_key: StringName, card_instance_id: StringName) -> void:
	if once_per_turn_key == &"" or card_instance_id == &"":
		return
	var key: String = "%s:%s" % [String(card_instance_id), String(once_per_turn_key)]
	var turn_id: int = _current_turn_number()
	if not _once_per_turn_used.has(key):
		_once_per_turn_used[key] = {}
	var turn_map: Dictionary = _once_per_turn_used[key]
	turn_map[turn_id] = int(turn_map.get(turn_id, 0)) + 1
	_once_per_turn_used[key] = turn_map


## 每局1次是否已用满（不带 turn 维度，本局持久）
func _is_once_per_game_used_up(effect: ActionEffect, payload: Dictionary) -> bool:
	var cid: StringName = _once_per_turn_card_instance_id(effect, payload)
	if cid == &"":
		return false  # 无来源牌实例，不限制（退路）
	var key: String = "%s:%s" % [String(cid), String(effect.once_per_game_key)]
	var used: int = int(_once_per_game_used.get(key, 0))
	return used >= effect.once_per_game_max

## 标记每局1次已使用（+1，本局持久）
func _mark_once_per_game_used(effect: ActionEffect, payload: Dictionary) -> void:
	if effect.once_per_game_key == &"":
		return
	var cid: StringName = _once_per_turn_card_instance_id(effect, payload)
	if cid == &"":
		return
	var key: String = "%s:%s" % [String(cid), String(effect.once_per_game_key)]
	_once_per_game_used[key] = int(_once_per_game_used.get(key, 0)) + 1


## DIRECT 主动效果「触发」按钮是否可点：复用 _execute_effect 的条件 + 每回合1次检查。
## bind_ctx 即装备 listener 的 binding_context（含 card_instance_id/mech_id/player_id/slot_id）。
## 供 equipment_panel 据此把按钮置灰（不满足条件/已用满时 disabled），
## 避免玩家点了才被 effect_fire 静默跳过（如帝国腿未移动8格点触发无反应）。
func can_trigger_active_effect(effect: ActionEffect, bind_ctx: Dictionary) -> bool:
	if effect == null:
		return false
	# 铠威攻击窗口：只放行「攻击产生」类主动效果（伏特转化进攻 / 莱比尔EX / 投掷式飞弹等），
	# 其余主动效果（维修/回能/抽牌等）在窗口期间置灰——严格只开放攻击。
	if _attack_window_active_for_binding_ctx(bind_ctx) and not _effect_is_attack_producing(effect):
		return false
	# 通用弹窗锁定：有等待输入（目标选择/二选一/弃牌等弹窗进行中）时所有主动效果按钮置灰，
	# 防止弹窗期间重复触发（塔莉娅021 点效果1后按钮仍可点，能一直抽3张牌）。
	# 当前输入被确认/取消后 _waiting_action_id 清空，按钮自动恢复可点。
	if context != null and context.get("action_ui_bridge") != null and not context.action_ui_bridge.get_waiting_action_info().is_empty():
		return false
	var payload: Dictionary = {"binding_context": bind_ctx}
	# 条件检查（action=null：走 binding_context 取来源，不依赖某个具体动作）
	if not _check_conditions(effect, payload, null):
		return false
	# 每回合1次检查
	if effect.once_per_turn_key != &"" and _is_once_per_turn_used_up(effect, payload):
		return false
	# 每局1次检查
	if effect.once_per_game_key != &"" and _is_once_per_game_used_up(effect, payload):
		return false
	return true


## 铠威攻击窗口归属判定（bind_ctx 版，equipment_panel 主动效果按钮置灰用）。
## bind_ctx 含 mech_id（装备/机师 listener 的 binding_context）。
func _attack_window_active_for_binding_ctx(bind_ctx: Dictionary) -> bool:
	if context == null or context.game_state == null:
		return false
	var mid: StringName = bind_ctx.get("mech_id", &"")
	if mid == &"":
		return false
	return _ActionPilotEffects.attack_window_active_for_mech(context.game_state, mid)


## 效果是否为「攻击产生」效果（铠威攻击窗口期间只放行攻击类主动效果）。
## 递归扫描 effect.actions：EXECUTE_ATTACK / PLAY_AS_NAMED(attack_is_active=true 或指向攻击牌) /
## EXECUTE_USE_ACTION_CARD(指向攻击牌) 及其嵌套分支（CHOOSE_ONE options /
## FOR_EACH_TARGET actions / CONDITIONAL_ACTIONS 分支）。找不到卡定义时宽松放行。
func _effect_is_attack_producing(effect: ActionEffect) -> bool:
	if effect == null:
		return false
	for act in effect.actions:
		if act is Dictionary and _action_produces_attack(act):
			return true
	return false


func _action_produces_attack(act: Dictionary) -> bool:
	var t: StringName = act.get("type", &"")
	var params: Dictionary = act.get("params", {})
	if t == &"EXECUTE_ATTACK":
		return true
	if t == &"PLAY_AS_NAMED":
		# attack_is_active=true 明确标记为攻击转化（伏特/莱比尔EX 进攻分支）；false=防御转化。
		if bool(params.get("attack_is_active", false)):
			return true
		var named_id: StringName = params.get("as_card_def_id", &"")
		if named_id != &"" and _card_def_is_attack(named_id):
			return true
		return false
	if t == &"EXECUTE_USE_ACTION_CARD":
		# 无法解析卡定义时宽松放行（避免误禁攻击类效果）
		var use_id: StringName = params.get("card_id", &"")
		if use_id == &"":
			use_id = params.get("card_instance_id", &"")
		if use_id != &"" and not _card_def_is_attack(use_id):
			return false
		return true
	if t == &"CHOOSE_ONE":
		for opt in params.get("options", []):
			if opt is Dictionary:
				for oa in opt.get("actions", []):
					if oa is Dictionary and _action_produces_attack(oa):
						return true
		return false
	if t == &"FOR_EACH_TARGET":
		for ia in params.get("actions", []):
			if ia is Dictionary and _action_produces_attack(ia):
				return true
		return false
	if t == &"CONDITIONAL_ACTIONS":
		for ca in params.get("if_true_actions", []) + params.get("if_false_actions", []):
			if ca is Dictionary and _action_produces_attack(ca):
				return true
		return false
	return false


## 卡定义是否为攻击牌（ActionCardDef.action_type == "攻击"）。
func _card_def_is_attack(card_id: StringName) -> bool:
	if card_id == &"":
		return false
	var def = null
	if context != null and context.get("card_database") != null:
		def = context.card_database.get_card(card_id)
	if def == null and context != null and context.get("game_state") != null:
		var inst = context.game_state.cards.get(card_id)
		if inst != null and inst.def != null:
			def = inst.def
	if def == null:
		return false
	# 兼容两种卡定义形态：CardDatabase.get_card() 返回类型化 CardDef（Resource 对象，
	# 不能用 .get()）；game_state.cards 兜底路径可能拿到 Dictionary。
	var kind: String
	var action_type: String
	if def is Dictionary:
		kind = String(def.get("card_kind", ""))
		action_type = String(def.get("action_type", ""))
	else:
		kind = String(def.card_kind)
		action_type = String(def.action_type)
	if kind != "action":
		return false
	return action_type == "攻击"


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


## 盾牌转移确认时，将 HP 伤害减量写入父 attack/trap_explosion 动作 record。
## effect_136（太空合金盾牌）监听 ATTACK_AFTER（造成HP伤害前）：此时 action 即 attack，直接写。
## effect_136b 监听 DAMAGE_REDIRECT_WINDOW（陷阱爆炸损伤变动）：action=damage_change，沿 parent_action_id 链找 attack 或 trap_explosion。
## 由 attack._step_apply_damage 或 trap_explosion 的 hp_change 读取并扣减HP伤害。
func _apply_shield_hp_reduction(action, hp_reduction: int) -> void:
	if hp_reduction <= 0 or action == null:
		return
	var target = action
	if target.action_type != &"attack" and target.action_type != &"trap_explosion":
		# damage_change 上下文：沿父链找 attack 或 trap_explosion
		if context == null or context.action_registry == null:
			return
		target = null
		var pid: StringName = action.parent_action_id
		while pid != &"":
			var parent = context.action_registry.get_action(pid)
			if parent == null:
				break
			if parent.action_type == &"attack" or parent.action_type == &"trap_explosion":
				target = parent
				break
			pid = parent.parent_action_id
	if target != null and (target.action_type == &"attack" or target.action_type == &"trap_explosion"):
		target.record["shield_hp_reduction"] = int(target.record.get("shield_hp_reduction", 0)) + hp_reduction




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
## 迪恩替别人响应资格（问题3）：持有者(迪恩)机甲非攻击目标时，其手牌"反击/疾行"迎击牌
## 在相邻友军被攻击+迪恩在攻击范围内+非迪恩攻击+未响应+目标未被攻击者锁定 时可替友军响应
## （单独弹迪恩窗口）。复用 effect_02 的 set_conditions 评估，但排除 HAS_ACTION_CARD_IN_HAND：
## 打反击/疾行牌本身不需要转化用的2张行动牌（那是 effect_02 转化 cost）。
func _is_dean_ally_respond_eligible(card_mech_id: StringName, card, action) -> bool:
	if action == null or action.action_type != &"attack":
		return false
	if card == null or card.def == null or card.def.card_kind != &"action":
		return false
	# 仅"反击/疾行"迎击牌可替别人响应（用户裁定：其他类型迎击牌不可替别人响应）
	var cname: String = String(card.def.display_name)
	if cname != "反击" and cname != "疾行":
		return false
	if context == null or context.game_state == null:
		return false
	# 持有者机甲必须是迪恩（pilot 槽 pilot_011_迪恩）
	var mech = context.game_state.mechs.get(card_mech_id)
	if mech == null:
		return false
	var ps = mech.slots.get(&"pilot")
	var pc = ps.get("equipped_card") if ps != null else null
	if pc == null or pc.def == null or String(pc.def.card_id) != "pilot_011_迪恩":
		return false
	# 复用 effect_02 条件（相邻友军被攻击/迪恩在范围/非自己攻击/未响应/目标未被锁），排除转化手牌要求
	var e02 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_02")
	if e02 == null:
		return false
	var conds: Array = []
	for c in e02.conditions:
		if String(c.get("op", &"")) != "HAS_ACTION_CARD_IN_HAND":
			conds.append(c)
	var bind_ctx: Dictionary = {
		"card_instance_id": pc.instance_id,
		"mech_id": card_mech_id,
		"player_id": card.owner_player_id,
		"card_def_id": pc.def.card_id,
		"slot_id": &"pilot",
	}
	var avail_payload: Dictionary = action.record.duplicate()
	avail_payload["action_id"] = action.action_id
	avail_payload["action_type"] = action.action_type
	avail_payload["binding_context"] = bind_ctx
	return _check_conditions(e02, avail_payload, action, conds)


func _check_availability(effect: ActionEffect, action, card_instance_id: StringName = &"", bind_ctx: Dictionary = {}) -> bool:
	var condition: StringName = effect.availability_condition
	# availability_condition 为空时跳过专用可用性检查，回退到通用 set_conditions 检查（见函数末尾）。
	# 装备 AVAILABILITY 效果（094/096 光束/热能响应）用 set_conditions 表达
	# "持有者被攻击 + 攻击武器名匹配 + 手牌有行动牌"，须在可用性阶段过滤，
	# 否则所有玩家的同名武器牌都会进入响应窗口（只有持有者才能用）。
	if condition != &"" and (context == null or context.get("game_state") == null):
		return false

	# 每回合N次检查（gather 阶段过滤已用满的 AVAILABILITY 条目）。
	# 迪恩转化等带弃牌 cost 的 AVAILABILITY 走 response_discard 路径不经 _execute_effect
	# （_execute_effect 的 once_per_turn 检查不会触发），故在此处拦截，避免已用满仍可选中。
	if effect.once_per_turn_key != &"" and not bind_ctx.is_empty():
		var opt_payload: Dictionary = action.record.duplicate() if action != null and action.record != null else {}
		opt_payload["action_id"] = action.action_id if action != null else &""
		opt_payload["action_type"] = action.action_type if action != null else &""
		opt_payload["binding_context"] = bind_ctx
		if _is_once_per_turn_used_up(effect, opt_payload):
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
			# 迪恩替别人响应（问题3）：持有者(迪恩)机甲非攻击目标时，其手牌"反击/疾行"
			# 迎击牌在相邻友军被攻击+迪恩在攻击范围内时，可替友军响应（单独弹迪恩窗口，
			# 不进 target 窗口）。通过后落入下方通用锁检查 + set_conditions 评估。
			if _is_dean_ally_respond_eligible(card_mech_id, card, action):
				holder_is_target = true
			else:
				return false
		# 锁定状态封锁响应：仅被锁目标自身的响应牌不可用（priority < 20），
		# 识破(≥20)不受影响。普通迎击牌 holder=card.mech_id（牌持有者机甲）。
		if _is_response_locked_out(effect, action, card_mech_id):
			return false
		# 不直接 return true：落入下方通用锁检查 + set_conditions 评估，
		# 使 AVAIL_RESPOND_ATTACK 效果可叠加额外 set_conditions（迪恩转化需 HAS_ACTION_CARD_IN_HAND(2)
		# + ATTACK_NOT_RESPONDED）。现有迎击牌 set_conditions 为空，2516 行 size()>0 守卫跳过，行为不变。

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
		var _cover_aura: Dictionary = context.map_service.get_attack_aura_cells()
		# 掩护射程同样受机甲障碍影响（与攻击判定口径一致）
		var _cover_blocked: Dictionary = context.map_service.get_attack_blocked_keys(holder_mech_id)
		return _RangeCalculator.is_in_weapon_range(holder_mech.position, attacker_mech.position, max_range, map_cells, _cover_aura, _cover_blocked)

	# 锁定状态封锁响应（通用路径：无 availability_condition 的 AVAILABILITY 响应效果，
	# 如 granted 防御/094 光束/096 热能响应）：仅被锁目标自身的响应被封锁（priority < 20），相邻机甲不再被封锁。
	# holder 优先 binding_context.mech_id（granted 跨机甲=A），回退 card.mech_id。
	if effect.mode == _TimingConst.MODE_AVAILABILITY:
		if context != null and context.get("game_state") != null:
			var lock_holder: StringName = bind_ctx.get("mech_id", &"")
			if lock_holder == &"" and card_instance_id != &"":
				var lh_card = context.game_state.get_card(card_instance_id)
				if lh_card != null:
					lock_holder = lh_card.mech_id
			if lock_holder != &"" and _is_response_locked_out(effect, action, lock_holder):
				return false
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

## 锁定状态封锁响应检查（规则书 行动牌效果20·锁定效果1）：
## locker(攻击者玩家)对攻击目标施加锁定后，仅该目标自身的"响应攻击"效果
## 不可用——所有 availability_priority < 20 的响应效果被取消（不进响应窗口）。
## 识破等 priority ≥ 20 的效果不受封锁。掩护不属于"响应攻击"，不走此检查。
## holder_mech_id = 响应方机甲：granted/装备效果用 binding_context.mech_id，普通迎击牌用 card.mech_id。
func _is_response_locked_out(effect: ActionEffect, action, holder_mech_id: StringName) -> bool:
	if int(effect.availability_priority) >= _LOCK_SUPPRESS_PRIORITY:
		return false
	if context == null or context.get("game_state") == null:
		return false
	var attacker_id_l: StringName = action.record.get("attacker_id", &"")
	if attacker_id_l == &"":
		return false
	var attacker_player = context.game_state.get_player_for_mech(attacker_id_l)
	if attacker_player == null:
		return false
	# 收集本次攻击的全部目标（单目标 target_id + 双连等多目标 target_ids）
	var attack_targets: Array = []
	var _tid_l: StringName = action.record.get("target_id", &"")
	if _tid_l != &"":
		attack_targets.append(_tid_l)
	for _etid_l in action.record.get("target_ids", []):
		attack_targets.append(StringName(_etid_l))
	for _atid2 in attack_targets:
		var locked_mech = context.game_state.mechs.get(_atid2)
		if locked_mech != null and locked_mech.is_locked_by(attacker_player.player_id):
			# 仅 holder 是被锁目标本身时封锁其响应；相邻机甲不再被锁封锁响应能力。
			# 相邻机甲替被锁目标挡攻的"转移攻击目标"另由挡攻条件拦截（见 pilot_011 effect_02）。
			if holder_mech_id == _atid2:
				return true
	# holder 自身被攻击者锁定时也封锁其响应（pilot_011 effect_02 挡攻转移：迪恩非攻击目标，
	# 但若迪恩被攻击者锁定，则不能响应/转移攻击目标到自身）。通用：被锁机甲不可响应。
	var holder_mech_l = context.game_state.mechs.get(holder_mech_id)
	if holder_mech_l != null and holder_mech_l.is_locked_by(attacker_player.player_id):
		return true
	return false

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
## custom_conds 非空时用它替代 effect.conditions（迪恩替别人响应资格检查复用 effect_02
## 条件但排除 HAS_ACTION_CARD_IN_HAND——打反击/疾行牌不需转化用的2张行动牌）。
func _check_conditions(effect: ActionEffect, payload: Dictionary, action, custom_conds: Array = []) -> bool:
	if effect.conditions.is_empty() and custom_conds.is_empty():
		return true
	# 响应转化/弃牌已支付后（CHOOSE_ONE 等挂起 resume 重跑 _execute_effect，如迪恩转化 effect_01/02），
	# 跳过 availability 门槛条件：HAS_ACTION_CARD_IN_HAND（弃牌后手牌减少会误判失败）与
	# ATTACK_NOT_RESPONDED（responded 选中时已置 true）。这俩只在响应窗口 gather 阶段过滤用。
	# 否则重跑条件检查会因弃牌后状态变质而静默跳过效果/取消父攻击。
	var conds: Array = effect.conditions
	if not custom_conds.is_empty():
		conds = custom_conds
	if bool(payload.get("_optional_discard_paid", false)):
		conds = []
		for c in effect.conditions:
			var cop: String = String(c.get("op", &""))
			if cop != "HAS_ACTION_CARD_IN_HAND" and cop != "ATTACK_NOT_RESPONDED":
				conds.append(c)
	# 创建临时 EffectBinding 用于 ConditionChecker
	var binding = _make_binding_from_effect(effect, action, payload)
	# 攻击窗口豁免：铠威等窗口归属机甲在窗口中发动攻击不依赖回合攻击次数——
	# 跳过攻击门槛条件（ATTACK_COUNT_ABOVE 剩余攻击次数 / WEAPON_CAN_ATTACK_AGAIN）。
	# 这样攻击类主动效果（伏特转化/莱比尔EX/投掷式飞弹）在窗口内即使回合攻击数已用完也可用。
	# 窗口归属从 binding 来源机甲取（bind_ctx.mech_id == 窗口 owner_mech_id）。
	if _attack_window_active_for_binding(binding):
		var _bypass: Array = []
		for c in conds:
			var _cop: String = String(c.get("op", &""))
			if _cop != "ATTACK_COUNT_ABOVE" and _cop != "WEAPON_CAN_ATTACK_AGAIN":
				_bypass.append(c)
		conds = _bypass
	var ok: bool = _ConditionChecker.check_all(binding, payload, conds)
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


## REGISTER_LISTEN 内联逻辑（顶层 _execute_actions 与 CHOOSE_ONE 分支内共用）。
## 迪恩当作反击转化（pilot_011_effect_01/02 反击分支）在 CHOOSE_ONE 分支内注册
## pilot_011_counter_strike 监听器：execute_sub_action 无该工厂会静默失败，须内联。
## listen_action_id 支持 $payload.xxx / $binding_context.xxx 表达式（绑原攻击用 $payload.attack_action_id，
## 使监听器只在该攻击的指定时点触发）。
func _register_listen_for_effect(act: Dictionary, payload: Dictionary, action) -> void:
	var rl_params: Dictionary = act.get("params", {})
	var listen_timing: StringName = rl_params.get("timing", act.get("timing", &""))
	var listen_action_id: StringName = _resolve_mech_id_expr(String(rl_params.get("listen_action_id", act.get("listen_action_id", &""))), payload)
	# listen_effect：优先用 params 直接给的 ActionEffect 对象；否则按 listen_effect_id 从机师效果表查
	var listen_effect = rl_params.get("listen_effect", act.get("listen_effect"))
	var listen_effect_id: StringName = rl_params.get("listen_effect_id", &"")
	if listen_effect == null and listen_effect_id != &"":
		listen_effect = _ActionPilotEffects.build_pilot_effects().get(listen_effect_id)
	# binding_context：params 显式指定优先；否则从 payload.binding_context 派生
	# （含 responder_mech_id/player_id/card_id 供 counter_strike 攻击取发动方，仿 use_action_card bind_to_attack_action）
	var rl_bind: Dictionary = rl_params.get("binding_context", {})
	if rl_bind.is_empty():
		var rl_src: Dictionary = payload.get("binding_context", {})
		if not rl_src.is_empty():
			rl_bind = {
				"responder_mech_id": rl_src.get("mech_id", &""),
				"responder_player_id": rl_src.get("player_id", &""),
				"responder_card_id": rl_src.get("card_instance_id", &""),
				"mech_id": rl_src.get("mech_id", &""),
				"player_id": rl_src.get("player_id", &""),
				"card_instance_id": rl_src.get("card_instance_id", &""),
			}
	var rl_cid: StringName = rl_params.get("card_instance_id", payload.get("binding_context", {}).get("card_instance_id", &""))
	if listen_timing != &"" and listen_effect != null:
		register_temporary_listener(listen_timing, listen_action_id, &"attack", listen_effect, rl_cid, &"", rl_bind)


## CHOOSE_MANY_CARDS：效果多选弹窗（顶层 effect.actions 与 CHOOSE_ONE 分支内共用）。
## 列出手牌候选供多选，确认后由 resume_pending_effect(phase=choose_many_cards) 处理
## （per_card_actions 逐张执行 / store_result_key 存 payload[key] / as_use_action_card 批量打出）。
## 挂起返回 true；无候选 / AI 持有者 / 已弹过则返回 false（调用方继续下一动作）。
func _prompt_choose_many_cards(effect, payload: Dictionary, action, act: Dictionary, act_idx: int) -> bool:
	var cm_params: Dictionary = act.get("params", {})
	var cm_source: StringName = cm_params.get("source", &"HAND_CARDS")
	var cm_bind_ctx: Dictionary = payload.get("binding_context", {})
	# 主体优先级：binding_context.player_id（效果持有者/牌主）优先于 payload.player_id（时点发起者）。
	# 事件牌"每当回合即将结束"类效果（拾荒 e005 等）在他人回合结束时触发，若取 payload.player_id
	# （回合玩家）会导致：候选手牌取错人（弃的是回合玩家的牌）+ 弹窗路由错玩家（PvP3 实测
	# 玩家1的拾荒弹给了玩家2）。无 binding（行动牌使用路径）回退 payload.player_id 不变。
	var cm_player_id: StringName = cm_bind_ctx.get("player_id", payload.get("player_id", &""))
	var cm_card_ids: Array = []
	if cm_source == &"ATTACK_TARGET_EQUIPMENT":
		# 收集攻击目标机甲正面设置、未压制的装备牌（供 effect_063/078 选目标装备无效 / 泰格弃装解锁）。
		# FOR_EACH_TARGET 逐目标时优先读 current_target（泰格 pilot_040 双连多目标各自独立解锁）。
		var ct_mech: StringName = &""
		var ct_d: Variant = payload.get("current_target", {})
		if ct_d is Dictionary:
			ct_mech = ct_d.get("mech_id", &"")
		var tgt_mech_id: StringName = ct_mech if ct_mech != &"" else payload.get("target_id", cm_bind_ctx.get("target_id", &""))
		cm_player_id = cm_bind_ctx.get("player_id", cm_player_id)  # 弹窗默认给攻击方（效果持有者），chooser_mech_id 可覆盖
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
					# 只选装备牌（排除 PILOT/EVENT 槽的机师/事件牌）：泰格弃装解锁「正面设置的装备牌」；
					# effect_063/078 选目标装备无效同理只针对装备。
					if ec.def.card_kind != &"equipment":
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
	# OWNER_ACTION_HAND：列出持有者所有行动牌（赤枭躯干 effect_040/041 弃牌换动力 / 布鲁克转化防御）
	# 不按 card_def_id 过滤，整手行动牌供多选弃置/转化。
	# card_type_filter（温斯顿 pilot_082 当作掩护/推进）：仅列持有者手牌中 action_type==指定类型的行动牌
	# （如只选攻击牌），与按钮条件 HAS_ACTION_CARD_TYPE_IN_HAND 共用语义。
	if cm_source == &"OWNER_ACTION_HAND":
		cm_card_ids.clear()
		var cm_card_type: StringName = cm_params.get("card_type_filter", &"")
		if cm_player_id != &"" and context != null and context.game_state != null:
			var cm_player = context.game_state.players.get(cm_player_id)
			if cm_player != null:
				for hand_cid: StringName in cm_player.action_hand:
					if cm_card_type == &"":
						cm_card_ids.append(hand_cid)
					else:
						var cm_hand_card = context.game_state.get_card(hand_cid)
						if cm_hand_card != null and cm_hand_card.def != null and String(cm_hand_card.def.action_type) == String(cm_card_type):
							cm_card_ids.append(hand_cid)
	# OWNER_WEAPON_EQUIPMENT_CARDS：列出持有者所有武器装备牌（提比里安 pilot_022 effect_01 弃甲铸威）。
	# 范围=装备手牌+机甲已设置槽位中 def.equipment_kind==WEAPON 的牌（虚拟武器天然排除）。
	# 复用 ConditionChecker 枚举 helper 保证与条件检查一致。
	if cm_source == &"OWNER_WEAPON_EQUIPMENT_CARDS":
		cm_card_ids = _ConditionChecker._weapon_equipment_card_ids(
			context.game_state, cm_player_id)
	# OWNER_EQUIPMENT_CARDS：列出持有者所有装备牌（装备手牌+所有机甲已设置槽位含备用区），
	# 不限武器/部件，供"弃1张装备抽装备/高级装备"类主动效果（尤里 pilot_033 等）选择弃置。
	if cm_source == &"OWNER_EQUIPMENT_CARDS":
		cm_card_ids = _ConditionChecker._equipment_card_ids(
			context.game_state, cm_player_id)
	# OWNER_UNEQUIPPED_EQUIPMENT_CARDS：仅列出持有者"未设置的装备牌"（装备手牌，不含已设置槽位），
	# 供"弃置未设置的装备牌"类主动效果弹窗候选（柏格 pilot_064 弃装获金抽装 等）。与按钮条件
	# HAS_UNEQUIPPED_EQUIPMENT_CARD 共用 helper，保证候选与可用性判定一致。
	if cm_source == &"OWNER_UNEQUIPPED_EQUIPMENT_CARDS":
		cm_card_ids = _ConditionChecker._unequipped_equipment_card_ids(
			context.game_state, cm_player_id)
	# 窗口附加选项（collect_cover_window_extras / collect_thrust_window_extras）：扫描窗口拥有玩家
	# 注册在 COVER_WINDOW_EXTRA / THRUST_WINDOW_EXTRA 虚拟时点的永久监听效果（洛尔恩 pilot_062 转化掩护 /
	# 温斯顿 pilot_082 转化推进等），条件满足（次数可用/有攻击牌）时作为复选框选项展示。
	# 即使无真实掩护/推进牌，只要存在可用 extra 选项也可弹窗。
	var cm_extra_options: Array = []
	var cm_collect_cover: bool = bool(cm_params.get("collect_cover_window_extras", false))
	var cm_collect_thrust: bool = bool(cm_params.get("collect_thrust_window_extras", false))
	# 把窗口附加选项的虚拟时点写进 record：确认路径 resume 时（另一个函数作用域）局部变量
	# cm_collect_* 不可见，须经 record 持久化才能知道去 COVER_WINDOW_EXTRA / THRUST_WINDOW_EXTRA
	# 查找选中的 extra 效果（_run_next_window_extra_if_pending 读取该键）。
	if cm_collect_cover:
		action.record["_window_extra_timing"] = _TimingConst.COVER_WINDOW_EXTRA
		cm_extra_options = _collect_window_extra_options(_TimingConst.COVER_WINDOW_EXTRA, cm_player_id, payload, action)
	elif cm_collect_thrust:
		action.record["_window_extra_timing"] = _TimingConst.THRUST_WINDOW_EXTRA
		cm_extra_options = _collect_window_extra_options(_TimingConst.THRUST_WINDOW_EXTRA, cm_player_id, payload, action)
	if cm_card_ids.is_empty() and cm_extra_options.is_empty():
		return false  # 无牌可选，跳过
	# 仅人类玩家弹多选窗；AI 暂不支持（跳过=选0，避免挂死）
	var cm_mech_id: StringName = payload.get("source_mech_id", cm_bind_ctx.get("mech_id", &""))
	# chooser_mech_id 路由（泰格弃装解锁：弹窗给目标机甲持有者，而非效果持有者；FOR_EACH_TARGET
	# 逐目标时 chooser_mech_id 传 $current_target.mech_id，各目标玩家各自弹各自独立解锁）。
	var cm_chooser_expr: Variant = cm_params.get("chooser_mech_id", &"")
	if cm_chooser_expr != null and String(cm_chooser_expr) != &"":
		var chooser_mech_id: StringName = _resolve_mech_id_expr(String(cm_chooser_expr), payload)
		if chooser_mech_id != &"" and context != null and context.game_state != null:
			var chooser_mech = context.game_state.mechs.get(chooser_mech_id)
			if chooser_mech != null and chooser_mech.owner_player_id != &"":
				cm_player_id = chooser_mech.owner_player_id
				cm_mech_id = chooser_mech_id
	if _is_ai_owner(cm_player_id, cm_mech_id):
		return false
	# 去重守卫：同一动作只弹一次（多张共享一个监听，首个挂起后循环已中断）
	if action.record.get("_choose_many_shown", false):
		return false
	action.record["_choose_many_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "choose_many_cards", "choose_many_action": act, "act_idx": act_idx}
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
		"min_count": int(cm_params.get("min_count", 0)),
		"no_cancel": bool(cm_params.get("no_cancel", false)),
		"extra_options": cm_extra_options,
	})
	SLog.log_raw("[TIMING] %s 挂起多选 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), cm_card_ids.size()])
	return true


## 收集窗口附加选项（洛尔恩 pilot_062 效果1 转化掩护 / 温斯顿 pilot_082 转化推进等，通用时点机制）。
## 窗口多选窗（collect_cover_window_extras / collect_thrust_window_extras）调用：遍历窗口拥有玩家
## 注册在指定虚拟时点（COVER_WINDOW_EXTRA / THRUST_WINDOW_EXTRA）的永久监听效果，用其自身
## binding_context（机师/玩家）构造独立 payload 评估 conditions，通过者作为复选框选项返回
## [{effect_id, label}]。虚拟时点不会被 fire_timing 触发，仅作存储/遍历入口；
## 选项选中后由确认路径直接 _execute_actions 该效果。
func _collect_window_extra_options(window_timing: StringName, cm_player_id: StringName, cover_payload: Dictionary, action) -> Array:
	var result: Array = []
	var extras: Array = permanent_listeners.get(window_timing, [])
	if extras.is_empty():
		return result
	for entry in extras:
		var eff: ActionEffect = entry.get("effect")
		if eff == null:
			continue
		var entry_ctx: Dictionary = entry.get("binding_context", {})
		# 仅收集窗口拥有玩家（掩护/推进牌持有者）自己的附加选项
		if String(entry_ctx.get("player_id", &"")) != String(cm_player_id):
			continue
		# 构造该效果独立 payload：保留 cover 上下文（target_id/attacker_id 等攻击信息），
		# 替换 binding_context 为本效果绑定（洛尔恩/温斯顿 mech/player），供条件精确匹配。
		var extra_payload: Dictionary = cover_payload.duplicate(true)
		extra_payload["binding_context"] = entry_ctx
		if entry_ctx.has("player_id"):
			extra_payload["player_id"] = entry_ctx["player_id"]
		if entry_ctx.has("mech_id"):
			extra_payload["source_mech_id"] = entry_ctx["mech_id"]
		var cond_ok: bool = _check_conditions(eff, extra_payload, action)
		if cond_ok:
			result.append({
				"effect_id": String(eff.effect_id),
				"label": eff.display_name,
			})
	return result


## 串行启动窗口附加选项效果（洛尔恩 pilot_062 转化掩护 / 温斯顿 pilot_082 转化推进等）。返回 true=
## 已启动并挂起（等 resume 续跑），false=无 pending 或已全部处理完。
## 调用点：① 窗口确认路径（真实牌同步执行完后）；② ActionEngine._after_sub_action_finished
## （真实牌批量挂起-恢复完成后 / 转化流程完成后）。每个 extra 效果经 _execute_actions 独立执行
## （洛尔恩/温斯顿效果1：选行动牌→转化），挂起时父动作等待其完成。
## 窗口时点记录于 record._window_extra_timing（COVER_WINDOW_EXTRA / THRUST_WINDOW_EXTRA），
## 从对应永久监听列表查找效果与其绑定。
func _run_next_window_extra_if_pending(parent_action) -> bool:
	if parent_action == null:
		return false
	var pending: Array = parent_action.record.get("_window_extra_pending", [])
	if pending.is_empty():
		return false
	var cover_payload: Dictionary = parent_action.record.get("_window_extra_payload", {})
	var window_timing: StringName = parent_action.record.get("_window_extra_timing", _TimingConst.COVER_WINDOW_EXTRA)
	# 取第一个 extra effect_id（UI 返回 String/StringName 均可），从 pending 移除
	var extra_effect_id: String = String(pending.pop_front())
	parent_action.record["_window_extra_pending"] = pending
	# 从窗口虚拟时点找到对应效果与其绑定（洛尔恩/温斯顿 mech/player）
	var extras: Array = permanent_listeners.get(window_timing, [])
	var found_eff: ActionEffect = null
	var found_ctx: Dictionary = {}
	for entry in extras:
		var eff: ActionEffect = entry.get("effect")
		if eff != null and String(eff.effect_id) == extra_effect_id:
			found_eff = eff
			found_ctx = entry.get("binding_context", {})
			break
	if found_eff == null:
		SLog.log_raw("[TIMING] %s 窗口附加选项 %s 未找到效果，跳过" % [String(parent_action.action_id), extra_effect_id])
		return _run_next_window_extra_if_pending(parent_action)
	# 构造该效果独立 payload：保留窗口上下文（target_id/attacker_id 等攻击信息），
	# 替换 binding_context 为本效果绑定（洛尔恩/温斯顿 mech/player），供 OWNER_ACTION_HAND 取手牌。
	var extra_payload: Dictionary = cover_payload.duplicate(true)
	extra_payload["binding_context"] = found_ctx
	if found_ctx.has("player_id"):
		extra_payload["player_id"] = found_ctx["player_id"]
	if found_ctx.has("mech_id"):
		extra_payload["source_mech_id"] = found_ctx["mech_id"]
	SLog.log_raw("[TIMING] %s 启动窗口附加选项 effect=%s" % [String(parent_action.action_id), extra_effect_id])
	_execute_actions(found_eff, extra_payload, parent_action)
	# 挂起（选行动牌窗等）→ 等 resume 续跑，完成由 _after_sub_action_finished 钩子续下一个；
	# 同步完成（无攻击牌不发动等）→ 继续处理下一个 extra
	if parent_action.record.has("_seq_effect_actions") or _pending_effect.has(parent_action.action_id):
		return true
	return _run_next_window_extra_if_pending(parent_action)


## PEEK_DECK_TOP_AND_DISCARD 第1阶段（通用"窥视牌堆顶并弃置"模块，银雪 pilot_065 effect_02）：
## 单选我方1张行动牌作发动代价（max=1/min=0=可取消）。确认后弃置代价牌 -> 第2阶段窥视堆顶。
## 无行动牌 / AI 持有者 -> 返回 false（不发动，效果跳过）。
## params: {peek_count(默认3), deck_zone(默认action_deck), cost_label/cost_confirm_verb/cost_cancel_label, peek_*}
func _handle_peek_select_cost(effect, payload: Dictionary, action, act: Dictionary) -> bool:
	var pk_params: Dictionary = act.get("params", {})
	var pk_bind: Dictionary = payload.get("binding_context", {})
	var pk_player_id: StringName = pk_bind.get("player_id", payload.get("player_id", &""))
	var pk_mech_id: StringName = pk_bind.get("mech_id", payload.get("source_mech_id", &""))
	if pk_player_id == &"" or context == null or context.game_state == null:
		return false
	if _is_ai_owner(pk_player_id, pk_mech_id):
		return false
	var pk_player = context.game_state.players.get(pk_player_id)
	if pk_player == null:
		return false
	var pk_cost_cards: Array = []
	for pk_cid in pk_player.action_hand:
		pk_cost_cards.append(pk_cid)
	if pk_cost_cards.is_empty():
		return false  # 无行动牌，不发动
	if action.record.get("_peek_cost_shown", false):
		return false
	action.record["_peek_cost_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "peek_select_cost", "peek_params": pk_params}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_thrust_cards", {
		"action_id": action.action_id, "effect_id": effect.effect_id,
		"card_ids": pk_cost_cards, "player_id": pk_player_id,
		"label": String(pk_params.get("cost_label", "弃置1张行动牌以窥视行动牌堆顶3张（可弃置其中任意牌）")),
		"confirm_verb": String(pk_params.get("cost_confirm_verb", "弃置发动")),
		"cancel_label": String(pk_params.get("cost_cancel_label", "不发动")),
		"max_count": 1, "min_count": 0, "no_cancel": false,
	})
	SLog.log_raw("[TIMING] %s 银雪窥牌-代价阶段挂起 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), pk_cost_cards.size()])
	return true


## PEEK_DECK_TOP_AND_DISCARD 第2阶段哨兵 PEEK_DECK_SHOW：窥视行动牌堆顶 N 张，多选弃置（可不选）。
## 由 _seq 续跑触发（代价牌弃置完成后 remaining 中的 PEEK_DECK_SHOW）。剩余牌保持原顺序置顶
## （EXECUTE_DISCARD 用 remove_card_from_all_zones 仅删选中，未删的保留在前）。牌堆空/AI -> 返回 false。
func _handle_peek_deck_show(act: Dictionary, effect, payload: Dictionary, parent_action) -> bool:
	var pds_params: Dictionary = act.get("params", {})
	var pds_count: int = int(pds_params.get("peek_count", 3))
	var pds_deck_zone: StringName = pds_params.get("deck_zone", &"action_deck")
	if context == null or context.game_state == null:
		return false
	if pds_deck_zone != &"action_deck":
		return false  # 仅行动牌堆顶受支持
	var pds_deck: Array = context.game_state.deck_state.action_deck
	var pds_take: int = pds_count if pds_count < pds_deck.size() else pds_deck.size()
	var pds_top: Array = []
	for pds_i in range(pds_take):
		pds_top.append(pds_deck[pds_i])
	if pds_top.is_empty():
		return false
	var pds_bind: Dictionary = payload.get("binding_context", {})
	var pds_player_id: StringName = pds_bind.get("player_id", payload.get("player_id", &""))
	var pds_mech_id: StringName = pds_bind.get("mech_id", payload.get("source_mech_id", &""))
	if _is_ai_owner(pds_player_id, pds_mech_id):
		return false
	_pending_effect[parent_action.action_id] = {"action": parent_action, "effect": effect, "payload": payload, "phase": "peek_select_discard", "peek_card_ids": pds_top}
	parent_action.state = &"waiting_timing"
	var pds_eff_id: StringName = effect.effect_id if effect != null else &""
	action_needs_input.emit(parent_action.action_id, &"select_thrust_cards", {
		"action_id": parent_action.action_id, "effect_id": pds_eff_id,
		"card_ids": pds_top, "player_id": pds_player_id,
		"label": String(pds_params.get("peek_label", "行动牌堆顶%d张（选择要弃置的牌，可不选）" % pds_top.size())),
		"confirm_verb": String(pds_params.get("peek_confirm_verb", "弃置选中")),
		"cancel_label": String(pds_params.get("peek_cancel_label", "不弃置")),
		"max_count": pds_top.size(), "min_count": 0, "no_cancel": false,
	})
	SLog.log_raw("[TIMING] %s 银雪窥牌-堆顶阶段挂起 effect=%s 候选=%d" % [String(parent_action.action_id), String(pds_eff_id), pds_top.size()])
	return true


## CHOOSE_MANY_MECHS：通用「选多台机甲」地图点选（奥黛尔 pilot_038 等含我方主动效果）。
## params: {range(hex距离,默认4), min_count(至少,默认1), max_count(最多,默认1),
##          include_self(自己可选,默认false), store_result_key(选中mech_id数组存payload[key]), label}
## 挂起 phase=choose_many_mechs -> action_needs_input(mech_multi_select) 由 app_root 弹地图点选；
## resume：确认存 payload[key] 重跑 _execute_effect（shown 守卫跳过本动作续跑后续 MARK/FOR_EACH_TARGET），
## 取消=不发动不计次。AI 跳过（暂不处理 AI 逻辑）。
func _prompt_choose_many_mechs(effect, payload: Dictionary, action, act: Dictionary, act_idx: int) -> bool:
	var mm_params: Dictionary = act.get("params", {})
	var mm_bind_ctx: Dictionary = payload.get("binding_context", {})
	var mm_mech_id: StringName = payload.get("source_mech_id", mm_bind_ctx.get("mech_id", &""))
	var mm_player_id: StringName = payload.get("player_id", mm_bind_ctx.get("player_id", &""))
	if mm_mech_id == &"" or context == null or context.game_state == null:
		return false
	var mm_src = context.game_state.mechs.get(mm_mech_id)
	if mm_src == null:
		return false
	var mm_range: int = int(mm_params.get("range", 4))
	var mm_min: int = int(mm_params.get("min_count", 1))
	var mm_max: int = int(mm_params.get("max_count", 1))
	var mm_include_self: bool = bool(mm_params.get("include_self", false))
	# 候选：hex 距离 range 内存活机甲（include_self=false 排除自己）
	var mm_candidates: int = 0
	for mid: StringName in context.game_state.mechs:
		if mid == mm_mech_id and not mm_include_self:
			continue
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if _HexGrid.distance(mm_src.position, m.position) <= mm_range:
			mm_candidates += 1
	if mm_candidates < mm_min:
		return false  # 无可选项（条件已保证，兜底）
	# 仅人类玩家弹地图点选；AI 跳过（暂不处理 AI 逻辑）
	if _is_ai_owner(mm_player_id, mm_mech_id):
		return false
	# 去重守卫：resume 重跑 _execute_effect 时跳过本动作
	if action.record.get("_choose_many_mechs_shown", false):
		return false
	action.record["_choose_many_mechs_shown"] = true
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "choose_many_mechs", "mech_select_action": act, "act_idx": act_idx}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"mech_multi_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"source_mech_id": mm_mech_id,
		"range": mm_range,
		"max_count": mm_max,
		"min_count": mm_min,
		"include_self": mm_include_self,
		"store_result_key": String(mm_params.get("store_result_key", &"")),
		"label": String(mm_params.get("label", "选择目标机甲")),
	})
	SLog.log_raw("[TIMING] %s 挂起多选机甲 effect=%s 范围=%d 候选=%d" % [String(action.action_id), String(effect.effect_id), mm_range, mm_candidates])
	return true


func _execute_actions(effect: ActionEffect, payload: Dictionary, action) -> void:
	if effect.actions.is_empty():
		return

	var _actions_list: Array = effect.actions
	for _act_idx: int in range(_actions_list.size()):
		var act: Dictionary = _actions_list[_act_idx]
		var act_type: StringName = act.get("type", &"")
		# 跳过注册监听器的动作
		if act_type == &"REGISTER_LISTEN":
			_register_listen_for_effect(act, payload, action)
			continue
		# CHOOSE_MANY_MECHS（奥黛尔 pilot_038「选最多2台4格内机甲」通用主动效果）：地图点选多台机甲。
		# 收集 hex 范围内（含自己可选）存活机甲候选，弹 mech_multi_select 窗；确认 target_ids 存
		# payload[store_result_key]，resume 重跑 _execute_effect（shown 守卫跳过本动作）续跑 MARK 计次 +
		# FOR_EACH_TARGET 逐目标执行；取消=效果不发动不计次。AI 跳过（暂不处理 AI 逻辑）。
		if act_type == &"CHOOSE_MANY_MECHS":
			if _prompt_choose_many_mechs(effect, payload, action, act, _act_idx):
				return
			continue
		# FOR_EACH_TARGET（pilot_012/013）：逐目标串行执行 inner actions。
		# targets=$selected_targets（由 ALL_CURRENT_ATTACK_MECH_TARGETS / ALL_HIT_TARGETS_* 注入 payload）。
		# 展开为 flat 列表 [(target_id, action)]：CONDITIONAL_ACTIONS 按当前 target 评估条件取分支。
		# 支持 inner 为 原子/EXECUTE_*（EXECUTE_STEAL 选牌暂停走 _seq 子动作机制）/CONDITIONAL_ACTIONS。
		# 不支持 inner 为 CHOOSE_ONE（_pending_effect 重跑会破坏迭代，pilot_012 e2 奖励另走专用处理）。
		if act_type == &"FOR_EACH_TARGET":
			var fet_params: Dictionary = act.get("params", {})
			var fet_targets_raw = fet_params.get("targets", &"")
			var fet_targets: Array = _resolve_fet_targets(fet_targets_raw, payload, action)
			if fet_targets.is_empty():
				continue
			var fet_inner: Array = fet_params.get("actions", [])
			var fet_var: StringName = fet_params.get("current_target_variable", &"current_target")
			var fet_flat: Array = _build_for_each_flat(fet_targets, fet_inner, fet_var, effect, payload, action)
			if fet_flat.is_empty():
				continue
			if _run_flat_inline(fet_flat, 0, effect, payload, action, fet_var):
				return
			continue
		# CONDITIONAL_ACTIONS 顶层：按当前 payload 评估条件取 if_true/if_false 分支，
		# 与剩余动作拼接后经 _seq_effect_actions 串行执行（青瞳 pilot_037 偷牌后按手牌差 -4 威力）。
		# FOR_EACH_TARGET 内嵌的 CONDITIONAL_ACTIONS 由 _build_for_each_flat 展开，不走到这里。
		if act_type == &"CONDITIONAL_ACTIONS":
			var tca_params: Dictionary = act.get("params", {})
			var tca_conds: Array = tca_params.get("conditions", [])
			var tca_branch: Array = tca_params.get("if_false_actions", [])
			var tca_bind = _make_binding_from_effect(effect, action, payload)
			if tca_conds.is_empty() or _ConditionChecker.check_all(tca_bind, payload, tca_conds):
				tca_branch = tca_params.get("if_true_actions", [])
			if tca_branch.is_empty():
				continue
			# 拼接分支 + 剩余动作，交给 _continue_seq_effect_actions 串行执行（原子动作同步完成；
			# 分支含需输入子动作时挂起等待，完成后继续剩余）。全部同步完成则 break——
			# 剩余动作已随分支拼入 seq 处理完，continue 会让 for 循环把 slice(_act_idx+1) 重复执行一遍。
			action.record["_seq_effect_actions"] = {"payload": payload, "remaining": tca_branch + _actions_list.slice(_act_idx + 1), "effect": effect}
			if _continue_seq_effect_actions(action):
				return
			break
		# PILOT_024_RE_CONFIRM：琳 RE 请求确认弹窗（请求方点击 RE 后弹给琳）。
		# 首次挂起确认窗（_pending_effect phase=pilot_024_re_confirm）；resume 后由
		# resume_pending_effect 处理（确认=开维修窗口并保持动作挂起阻塞请求方回合，取消=无事发生）。
		# 窗口关闭后 continue_action 恢复本动作完成（handler 跳过不重跑）。
		if act_type == &"PILOT_024_RE_CONFIRM":
			if bool(payload.get("_p024_re_confirm_done", false)):
				continue
			_prompt_pilot_024_re_confirm(effect, payload, action)
			return
		# PILOT_081_RE_CONFIRM：汀兰 RE 请求确认弹窗（请求方点 RE 后弹给汀兰持有者）。
		# 首次挂起确认窗（_pending_effect phase=pilot_081_re_confirm）；resume 后由
		# resume_pending_effect 处理（同意=请求方回2血+获2金；取消=无事，RE 已消耗不退）。
		if act_type == &"PILOT_081_RE_CONFIRM":
			if bool(payload.get("_p081_re_confirm_done", false)):
				continue
			_prompt_pilot_081_re_confirm(effect, payload, action)
			return
		# PILOT_083_MODIFY_FLOW：瓦恩「武器修改」两阶段流程（主动按钮1 / RE 请求）。
		# 首次挂起 phase1 武器单选（choose_one_effect）；resume 后转 phase2 三横排选项
		# （weapon_modify_options_panel）；确认施加 / 取消由 resume_pending_effect 的
		# p083_weapon_select / p083_options 阶段处理。流程完成设 _p083_flow_done 跳过不重跑。
		# mode（owner/re）来自动作 params，注入 payload 供两阶段及施加读取。
		if act_type == &"PILOT_083_MODIFY_FLOW":
			if bool(payload.get("_p083_flow_done", false)):
				continue
			payload["_p083_mode"] = String(act.get("params", {}).get("mode", "owner"))
			_start_pilot_083_flow(effect, payload, action)
			return
		# PILOT_039_SCHEDULE_AFTER_ATTACK：铠威「被响应攻击结算后抽1再攻」被动调度（非阻塞）。
		# ATTACK_SETTLE 时登记完成钩子：攻击动作完成（action_completed）后由 ActionService
		# 派发 pilot_039_after_attack_completed（入队触发 + 弹确认/开窗口）。不在此弹窗，
		# 保证「此攻击结算后」= 攻击动作完全清理完成才提示。同一次攻击只登记一次（去重守卫）。
		if act_type == &"PILOT_039_SCHEDULE_AFTER_ATTACK":
			_handle_pilot_039_schedule_after_attack(effect, payload, action)
			continue
		# RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK：铠厉「被响应→抽2装备→逐张设置/弃置获金」被动调度（非阻塞）。
		# 与 PILOT_039_SCHEDULE_AFTER_ATTACK 同构：ATTACK_SETTLE 时登记攻击完成钩子，攻击动作完全
		# 结算（action_completed）后由 ActionService 派发 responded_equip_after_attack_completed
		# （入队触发+弹确认+逐张「立即设置/弃置获金(cost)」链）。通用模块不绑机师。
		if act_type == &"RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK":
			_handle_responded_equip_schedule_after_attack(effect, payload, action)
			continue
		# PILOT_060_SCHEDULE_AFTER_ATTACK：铠德「被响应→三选一」被动调度（非阻塞）。
		# 与 PILOT_039/RESPONDED_EQUIP 同构：ATTACK_SETTLE 时登记攻击完成钩子，攻击动作完全
		# 结算（action_completed）后由 ActionService 派发 pilot_060_after_attack_completed
		# （入队触发 + 弹三选一）。通用模块 pilot_060_* 不绑机师。
		if act_type == &"PILOT_060_SCHEDULE_AFTER_ATTACK":
			_handle_pilot_060_schedule_after_attack(effect, payload, action)
			continue
		# HIDDEN_VIEW_AND_ACQUIRE（霍恩 pilot_046 等通用「查看隐藏装备+花费金币获取」主动效果）：
		# Phase A 打开 hidden_card_view_panel（阻塞，可关闭=取消效果可反复再点；打开即给商店隐藏牌
		# known_to 标记本玩家）。选中牌点「花费获取」→ Phase B 弹 choice_panel(allow_cancel=false)
		# 选目标 RESERVE 槽（全部玩家）→ 清来源 + 重置归属 + 追加目标手牌 →
		# _seq[SPEND_GOLD(原价), MARK_EFFECT_ONCE_PER_TURN_USED, EXECUTE_SET_EQUIP]。全通用，AI 跳过。
		if act_type == &"HIDDEN_VIEW_AND_ACQUIRE":
			if _handle_hidden_view_and_acquire(act, effect, payload, action):
				return
			continue
		# CHOOSE_ONE：维修等二选一。inline options[] 每项含 {label, actions[]}。
		# 玩家未选时挂起弹窗（choose_one_effect）；选了则执行对应分支 actions[]，
		# 并把目标机甲注入效果动作的 mech_ids（EXECUTE_HP_CHANGE/EXECUTE_DAMAGE_CHANGE 读 mech_ids）。
		if act_type == &"CHOOSE_ONE":
			var chosen_idx: int = int(payload.get("chosen_option_index", -1))
			var params_co: Dictionary = act.get("params", {})
			var options: Array = params_co.get("options", [])
			# 维修增强（通用机制 REPAIR_BOOST）：维修效果执行方机师牌带 repair_boost 时，改写维修
			# 二选一选项：移除2→合并移除(2+extra_removal)；回复4→之后额外移除 extra_removal
			# （带 TARGET_HAS_DAMAGE 条件，无损伤不生效）。坎得 pilot_023 等机师复用。
			# 只改本地 options（深拷贝），不写回静态 effect.actions 防全局污染。
			if effect.effect_id == &"repair_direct":
				var rb_binding = _make_binding_from_effect(effect, action, payload)
				var rb_mech: StringName = rb_binding.get_source_mech_id() if rb_binding != null else &""
				if rb_mech != &"" and context != null and context.game_state != null:
					var rb_boost: Dictionary = _ActionPilotEffects.get_repair_boost(context.game_state, rb_mech)
					if not rb_boost.is_empty():
						options = _apply_repair_boost_options(options, rb_boost)
					# 琳 pilot_024 效果2：我方对其他机甲使用维修后，我方与该机甲各抽2张行动牌
					# （我方先抽、目标后抽，串行）。任意来源维修（转化/实体牌/维修机械臂）都走
					# repair_direct，在此统一给各可用分支追加抽牌动作。目标读本效果 payload。
					options = _append_pilot_024_repair_draws(options, rb_mech, payload)
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
					_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "pre_actions_target"}
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
					# chooser_mech_id：CHOOSE_ONE 选择者机甲（pilot_006 e3 被选机甲二选一），
					# 覆盖默认 effect 拥有者，路由弹窗到被选机甲玩家窗口。
					var co_player_id: StringName = _effect_popup_owner_pid(effect, payload, action)
					var co_chooser_expr: String = String(params_co.get("chooser_mech_id", &""))
					if co_chooser_expr != "":
						var co_chooser_mid: StringName = _resolve_mech_id_expr(co_chooser_expr, payload)
						if co_chooser_mid != &"" and context != null and context.game_state != null:
							var co_chooser_player = context.game_state.get_player_for_mech(co_chooser_mid)
							if co_chooser_player != null:
								co_player_id = co_chooser_player.player_id
					# pilot_008 逆转弹窗描述（PILOT_008_BUILD_*_PROMPT 写入 payload._popup_description）
					# 无 _popup_description 时回退 effect.description（如 pilot_006 e2 狩猎追击询问弹窗显示效果说明）
					var _co_src: String = String(payload.get("_popup_description", ""))
					if _co_src == "":
						_co_src = String(effect.description)
					action_needs_input.emit(action.action_id, &"choose_one_effect", {
						"action_id": action.action_id,
						"effect_id": effect.effect_id,
						"options": ui_options,
						"optional": co_optional,
						"player_id": co_player_id,
						"source_label": _co_src,
					})
					SLog.log_raw("[TIMING] %s 挂起二选一 effect=%s options=%d optional=%s" % [String(action.action_id), String(effect.effect_id), ui_options.size(), str(co_optional)])
					return
			# 已选：执行该分支的 actions[]，注入目标机甲到 mech_ids
			# 清理挂起标志（C2 修复：此前最终记录残留 _waiting_for_choose_one=true）
			action.record.erase("_waiting_for_choose_one")
			action.record.erase("_choose_one_effect_id")
			var chosen_opt: Dictionary = options[chosen_idx] if options[chosen_idx] is Dictionary else {}
			# 通用 store_record_key：选择后将选中 option 的 value 写入父动作 record 的指定键。
			# （格温 pilot_043 宣言抽取：GAIN_CARD_BEFORE 宣言类型 -> GAIN_CARD_AFTER 监听器读 record 检查。）
			# 幂等：重跑 _execute_effect 时写同值，无副作用。
			if params_co.has("store_record_key"):
				var _srk: StringName = StringName(params_co.get("store_record_key", &""))
				if _srk != &"":
					action.record[_srk] = chosen_opt.get("value", chosen_opt.get("label", &""))
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
				# 通用分支动作条件（维修增强 REPAIR_BOOST 追加的额外移除等）：
				# 分支动作带 condition 时，条件不满足则跳过该动作（防止目标无损伤时弹空移除框卡死）。
				var _ba_cond: Variant = sub_act.get("condition", [])
				if _ba_cond is Dictionary:
					_ba_cond = [_ba_cond]
				if _ba_cond is Array and not (_ba_cond as Array).is_empty():
					var _ba_cbind = _make_binding_from_effect(effect, action, payload)
					if not _ConditionChecker.check_all(_ba_cbind, payload, _ba_cond):
						_ba_idx += 1
						continue
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
				# PILOT_006_FORCE_USE_ATTACK：pilot_006 e3 战后逼迫选牌 use_action_card（分支内特判，仿 CHOOSE_*）
				# PILOT_016_SHOW_AND_CONVERT：默多克展示转化（CHOOSE_ONE 确认后分支内执行）。
				# 阶段1：展示牌A给其他玩家（复用美杜莎 pilot_009_show_display 非阻塞浮窗）。
				# 阶段2：选2张B/C（排除牌A）选牌窗（阻塞，phase=pilot_016_choose_two）。
				# resume：弃置C + 改造父record(B当牌A virtual_transform) + 清空剩余 listener + mark once_per_turn。
				# 牌A保留手牌；B 由父 card_to_temp_zone 移入 temp_zone + 注册牌A效果；父 settle 弃B。
				if sub_type == &"PILOT_016_SHOW_AND_CONVERT":
					if _handle_pilot_016_show_and_convert(sub_act_merged, effect, payload, action):
						return
					_ba_idx += 1
					continue
				if sub_type == &"PILOT_006_FORCE_USE_ATTACK":
					if _handle_pilot_006_force_use_attack(sub_act_merged, effect, payload, action):
						var _p06_remaining: Array = branch_actions.slice(_ba_idx + 1)
						if not _p06_remaining.is_empty():
							action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _p06_remaining, "source_check": false}
						return
					_ba_idx += 1
					continue
				# PILOT_047_FORCE_USE_ATTACK / PILOT_047_FORCE_HANDOVER：里欧娜 e1 战后二选一分支
				# （CHOOSE_ONE 内特判，仿 PILOT_006；命中弹窗则挂起，剩余分支存 _seq_effect_actions）。
				if sub_type == &"PILOT_047_FORCE_USE_ATTACK":
					if _handle_pilot_047_force_use_attack(sub_act_merged, effect, payload, action):
						var _p047_remaining: Array = branch_actions.slice(_ba_idx + 1)
						if not _p047_remaining.is_empty():
							action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _p047_remaining, "source_check": false}
						return
					_ba_idx += 1
					continue
				if sub_type == &"PILOT_047_FORCE_HANDOVER":
					if _handle_pilot_047_force_handover(sub_act_merged, effect, payload, action):
						var _p047h_remaining: Array = branch_actions.slice(_ba_idx + 1)
						if not _p047h_remaining.is_empty():
							action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _p047h_remaining, "source_check": false}
						return
					_ba_idx += 1
					continue
				# PILOT_025_SELECT_RESERVE_AND_SET：约书亚 1b 选备用装备设置+抽2（分支内特判，仿 PILOT_006）。
				# handler 挂起 reserve_select 弹窗；resume 后由 _seq 续跑 set_equipment + 抽2。
				if sub_type == &"PILOT_025_SELECT_RESERVE_AND_SET":
					if _handle_pilot_025_select_reserve_and_set(sub_act_merged, effect, payload, action):
						var _p025_remaining: Array = branch_actions.slice(_ba_idx + 1)
						if not _p025_remaining.is_empty():
							action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _p025_remaining, "source_check": false}
						return
					_ba_idx += 1
					continue
				# CHOOSE_MAP_CELL / CHOOSE_MANY_MAP_CELLS：分支内共用顶层 helper（execute_sub_action 无法处理 CHOOSE_*）
				if sub_type == &"CHOOSE_MAP_CELL":
					if _handle_choose_map_cell(sub_act_merged, effect, payload, action):
						return
					_ba_idx += 1
					continue
				if sub_type == &"CHOOSE_MANY_MAP_CELLS":
					if _handle_choose_many_map_cells(sub_act_merged, effect, payload, action):
						return
					_ba_idx += 1
					continue
				# REGISTER_LISTEN 嵌套在 CHOOSE_ONE 分支内（迪恩当作反击转化注册 counter_strike）：
				# 顶层 for 循环有特判，此处同样需要——execute_sub_action 无工厂会静默失败。
				if sub_type == &"REGISTER_LISTEN":
					_register_listen_for_effect(sub_act_merged, payload, action)
					_ba_idx += 1
					continue
				# PILOT_058_SHOW_COUNT_BONUS：卡米拉效果1 展示牌型加成（CHOOSE_ONE 确认后分支内执行，同步）。
				# 顶层 for 循环有特判，此处同样需要——execute_sub_action 无工厂会静默失败。
				if sub_type == &"PILOT_058_SHOW_COUNT_BONUS":
					_handle_pilot_058_show_count_bonus(sub_act_merged, effect, payload, action)
					_ba_idx += 1
					continue
				# FOR_EACH_TARGET 嵌套在 CHOOSE_ONE 分支内（pilot_012 e1 / pilot_013 e2a）：
				# 逐目标串行执行 inner actions。挂起存 flat _seq；分支内 FOR_EACH 之后的动作
				# （pilot_012 e1 的 SET_ACTION_RECORD_FLAG 写 flag 供 e02 判定）须在 flat 全部
				# 完成（所有目标处理完）后续跑--追加到 flat _seq.remaining 末尾，_continue_seq
				# 处理完 flat 项后按普通动作执行（is_flat 但 act.has("type") 走非 flat 分支）。
				if sub_type == &"FOR_EACH_TARGET":
					var fet_params_ba: Dictionary = sub_act_merged.get("params", {})
					var fet_targets_ba: Array = _resolve_fet_targets(fet_params_ba.get("targets", &""), payload, action)
					var fet_var_ba: StringName = fet_params_ba.get("current_target_variable", &"current_target")
					var fet_flat_ba: Array = _build_for_each_flat(fet_targets_ba, fet_params_ba.get("actions", []), fet_var_ba, effect, payload, action)
					if _run_flat_inline(fet_flat_ba, 0, effect, payload, action, fet_var_ba):
						# FOR_EACH_TARGET 挂起：flat _seq 已设。追加分支内 FOR_EACH 之后的动作
						# （SET_ACTION_RECORD_FLAG 等）到 _seq.remaining 末尾，flat 完成后续跑。
						var _ba_after_fet: Array = branch_actions.slice(_ba_idx + 1)
						if not _ba_after_fet.is_empty() and action.record.has("_seq_effect_actions"):
							var _fet_seq: Dictionary = action.record["_seq_effect_actions"]
							var _fet_rem: Array = _fet_seq.get("remaining", [])
							_fet_rem.append_array(_ba_after_fet)
							_fet_seq["remaining"] = _fet_rem
							action.record["_seq_effect_actions"] = _fet_seq
						return
					_ba_idx += 1
					continue
				# CHOOSE_INTEGER 嵌套在 CHOOSE_ONE 分支内（pilot_004 装甲转能）：
				# CHOOSE_INTEGER 不在 _is_atomic_action 里，走 execute_sub_action 会创建无工厂
				# child Action 立即完成（不挂起弹窗）。此处特判，仿 _execute_actions 顶层 CHOOSE_INTEGER 分支：
				# choice 未设 -> 挂起弹窗；choice 已设 -> 展开 actions 串行执行。
				if sub_type == &"CHOOSE_INTEGER":
					var _ci_params: Dictionary = sub_act_merged.get("params", {})
					var _ci_bind_as: String = String(_ci_params.get("bind_as", "n"))
					var _ci_min: int = int(_ci_params.get("min_value", 1))
					var _ci_max_expr: String = String(_ci_params.get("max_value_expr", ""))
					var _ci_max: int = _ci_min
					if _ci_max_expr != "":
						_ci_max = int(_eval_expr(_ci_max_expr, payload, {}))
					else:
						_ci_max = int(_ci_params.get("max_value", _ci_min))
					var _ci_choice: Dictionary = payload.get("choice", {})
					if not _ci_choice.has(_ci_bind_as):
						if _ci_max < _ci_min:
							_ba_idx += 1
							continue
						var _ci_bind_ctx: Dictionary = payload.get("binding_context", {})
						var _ci_owner_pid: StringName = _ci_bind_ctx.get("player_id", &"")
						var _ci_owner_mid: StringName = _ci_bind_ctx.get("mech_id", &"")
						if _is_ai_owner(_ci_owner_pid, _ci_owner_mid):
							_ci_choice[_ci_bind_as] = _ci_min
							payload["choice"] = _ci_choice
						else:
							_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"choose_integer", "bind_as": _ci_bind_as}
							action.record["_waiting_for_choose_integer"] = true
							action.state = &"waiting_timing"
							action_needs_input.emit(action.action_id, &"choose_integer", {
								"action_id": action.action_id,
								"effect_id": effect.effect_id,
								"label": String(_ci_params.get("label", "")),
								"min_value": _ci_min,
								"max_value": _ci_max,
								"bind_as": _ci_bind_as,
								"optional": bool(_ci_params.get("optional", false)),
								"stepper": bool(_ci_params.get("stepper", false)),
								"player_id": _effect_popup_owner_pid(effect, payload, action),
							})
							var _ci_rem: Array = branch_actions.slice(_ba_idx + 1)
							if not _ci_rem.is_empty():
								action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _ci_rem, "source_check": false}
							return
					# 已选：展开嵌套 actions 的 *_expr 与 $binding_context -> 串行执行（仿顶层 CHOOSE_INTEGER）
					var _ci_actions: Array = _ci_params.get("actions", [])
					var _ci_choice_full: Dictionary = payload.get("choice", {})
					var _ci_resolved: Array = []
					for _ci_sub: Dictionary in _ci_actions:
						var _ci_merged: Dictionary = _ci_sub.duplicate(true)
						var _ci_sp: Dictionary = _ci_merged.get("params", {})
						var _ci_erase: Array = []
						for _ci_k in _ci_sp:
							if String(_ci_k).ends_with("_expr"):
								var _ci_base: String = String(_ci_k).trim_suffix("_expr")
								_ci_sp[_ci_base] = _eval_expr(String(_ci_sp[_ci_k]), payload, _ci_choice_full)
								_ci_erase.append(_ci_k)
							elif context != null and context.action_service != null:
								_ci_sp[_ci_k] = context.action_service._resolve_atomic_value(_ci_sp[_ci_k], payload, action)
						for _ci_k in _ci_erase:
							_ci_sp.erase(_ci_k)
						_ci_merged["params"] = _ci_sp
						_ci_resolved.append(_ci_merged)
					for _ci_i: int in range(_ci_resolved.size()):
						var _ci_act: Dictionary = _ci_resolved[_ci_i]
						if context != null and context.action_service != null:
							context.action_service.execute_sub_action(_ci_act, payload, action)
						if _last_created_sub_action_paused(action):
							var _ci_remaining: Array = _ci_resolved.slice(_ci_i + 1)
							if not _ci_remaining.is_empty():
								action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _ci_remaining}
							return
					_ba_idx += 1
					continue
				# CHOOSE_MANY_CARDS 嵌套在 CHOOSE_ONE 分支内（布鲁克 effect_02 转化防御/实体防御牌）：
				# 复用顶层多选 helper 挂起弹窗；挂起时把剩余 branch_actions 存 _seq（branch_seq 标记），
				# resume（store_result_key 路径）优先续跑分支剩余，避免 payload["chosen_option_index"] 持久
				# 导致重跑 _execute_actions 再次命中 CHOOSE_MANY_CARDS 挂死。取消路径由 resume 清 _seq。
				if sub_type == &"CHOOSE_MANY_CARDS":
					if _prompt_choose_many_cards(effect, payload, action, sub_act_merged, _act_idx):
						var _cm_rem: Array = branch_actions.slice(_ba_idx + 1)
						if not _cm_rem.is_empty():
							action.record["_seq_effect_actions"] = {"payload": payload, "remaining": _cm_rem, "source_check": false, "branch_seq": true}
						return
					_ba_idx += 1
					continue
				if sub_type in [&"EXECUTE_HP_CHANGE", &"EXECUTE_DAMAGE_CHANGE", &"HEAL_HP", &"REMOVE_DAMAGE_TOKENS", &"DEAL_DAMAGE", &"PLACE_DAMAGE_TOKENS", &"MODIFY_DAMAGE_TOKENS"]:
					if not sub_params.has("mech_ids"):
						sub_params["mech_ids"] = [target_id_co]
					if not sub_params.has("mech_id") and sub_type in [&"HEAL_HP", &"REMOVE_DAMAGE_TOKENS", &"DEAL_DAMAGE", &"PLACE_DAMAGE_TOKENS", &"MODIFY_DAMAGE_TOKENS"]:
						sub_params["mech_id"] = target_id_co
					sub_act_merged["params"] = sub_params
				# 解析 params 的 $-占位符与 *_expr（仿 CHOOSE_INTEGER 分支）：CHOOSE_ONE 分支此前
				# 不解析嵌套动作参数，$binding_context.mech_id / $payload.target_id 等占位符会以
				# 字面字符串传入原子动作（spend_power / set_attack_defense_stat_source 等）而失败。
				# 放在所有特判之后、execute_sub_action 之前：特判动作（FOR_EACH_TARGET / CHOOSE_MAP_CELL
				# 等）已 continue/return，仅叶子动作走到此处被解析。
				var _ba_erase: Array = []
				for _ba_k in sub_params:
					if String(_ba_k).ends_with("_expr"):
						var _ba_base: String = String(_ba_k).trim_suffix("_expr")
						sub_params[_ba_base] = _eval_expr(String(sub_params[_ba_k]), payload, payload.get("choice", {}))
						_ba_erase.append(_ba_k)
					elif context != null and context.action_service != null:
						sub_params[_ba_k] = context.action_service._resolve_atomic_value(sub_params[_ba_k], payload, action)
				for _ba_k in _ba_erase:
					sub_params.erase(_ba_k)
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
		# ── 琳 RE 维修窗口关闭钩子（同步分支路径）──
		# 维修二选一分支全部执行完毕（未挂起）：窗口内维修完成时关闭窗口并恢复请求方回合。
		# 分支挂起（如移除损伤面板）的关闭由 _continue_seq_effect_actions 末尾统一处理。
		_pilot_024_close_if_window_repair_done(effect, payload, action)
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
					_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"choose_integer", "bind_as": ci_bind_as}
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
						"stepper": bool(ci_params.get("stepper", false)),
						"step": int(ci_params.get("step", 3)),
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
			# hp_reduction（太空合金盾牌 effect_136）：转移确认时使本次攻击造成的HP伤害-N。
			# 写入父 attack.record["shield_hp_reduction"]，由 attack._step_apply_hp 读取扣减。
			var odr_hp_reduction: int = int(odr_params.get("hp_reduction", 0))
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
				# effect_136 监听 ATTACK_AFTER（造成HP伤害前）：payload 无 total_points/value，
				# 取 markers(+extra_markers) 作为待转移损伤数。
				if ao_total == 0:
					ao_total = int(payload.get("markers", 0)) + int(payload.get("extra_markers", 0))
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
					_apply_shield_hp_reduction(action, odr_hp_reduction)
					continue
				# 人类玩家：弹可选确认窗（转移全部 / 不转移）
				action.record["_ao_absorb"] = ao_absorb
				action.record["_ao_hp_reduction"] = odr_hp_reduction
				_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "redirect_select"}
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
				_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "redirect_select"}
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
			if _prompt_choose_many_cards(effect, payload, action, act, _act_idx):
				return
			continue
		# PEEK_DECK_TOP_AND_DISCARD（通用"窥视牌堆顶并弃置"模块，银雪 pilot_065 effect_02）：
		# 第1阶段单选我方1张行动牌作代价（可取消=不发动）-> 弃置代价 -> 第2阶段窥视行动牌堆顶 N 张
		# 多选弃置（可不选，剩余保持原顺序置顶）。代价弃置/堆顶弃置均走 EXECUTE_DISCARD 子动作
		# （触发弃置时点，与其它"弃置后"效果联动）。无行动牌/AI -> 跳过。
		# PEEK_DECK_SHOW 哨兵（第2阶段窥视）由 _seq 续跑触发。
		if act_type == &"PEEK_DECK_TOP_AND_DISCARD":
			if _handle_peek_select_cost(effect, payload, action, act):
				return
			continue
		# CHOOSE_MANY_PLAYERS：pilot_003 effect_03 复选框——列出所有玩家（含自己），
		# 勾选"抽牌跳过正面牌"的玩家，提交后生效（裁定权威"重要补充"）。resume 走
		# phase=pilot_003_skip_players，用 player_ids 整组覆盖该瑟尔基尔来源的跳过集合。
		if act_type == &"CHOOSE_MANY_PLAYERS":
			var p003s_bind: Dictionary = payload.get("binding_context", {})
			var p003s_source: StringName = p003s_bind.get("card_instance_id", &"")
			var p003s_pid: StringName = p003s_bind.get("player_id", &"")
			if p003s_source == &"" or p003s_pid == &"" or context == null or context.game_state == null:
				continue
			# 列出所有玩家（含自己）；回显当前勾选状态
			var p003s_players: Array = []
			for pid: StringName in context.game_state.players:
				p003s_players.append(String(pid))
			if p003s_players.is_empty():
				continue
			if action.record.get("_p003_skip_shown", false):
				continue
			action.record["_p003_skip_shown"] = true
			_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_003_skip_players"}
			action.state = &"waiting_timing"
			action_needs_input.emit(action.action_id, &"select_pilot_003_skip_players", {
				"action_id": action.action_id,
				"effect_id": effect.effect_id,
				"player_ids": p003s_players,
				"checked": _ActionPilotEffects.get_pilot_003_skip_players(p003s_source),
				"player_id": p003s_pid,
				"label": "勾选「抽牌跳过正面牌」的玩家（提交后生效）",
			})
			SLog.log_raw("[TIMING] %s pilot_003 复选框 players=%d effect=%s" % [String(action.action_id), p003s_players.size(), String(effect.effect_id)])
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
			_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"unite_attack_offer", "unite_attack_action": act}
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
		# PILOT_027_SPLIT_GOLD：维罗妮卡效果1 获金分半（同步结算，不挂起）
		if act_type == &"PILOT_027_SPLIT_GOLD":
			_handle_pilot_027_split_gold(act, effect, payload, action)
			continue
		# PILOT_027_X_INC：维罗妮卡效果2 给予金币X+1（同步结算，不挂起）
		if act_type == &"PILOT_027_X_INC":
			_handle_pilot_027_x_inc(act, effect, payload, action)
			continue
		# PILOT_027_GIFT_AND_USE：维罗妮卡效果3 给予金币并使用行动牌（多阶段状态机，挂起）
		if act_type == &"PILOT_027_GIFT_AND_USE":
			if _handle_pilot_027_gift_and_use(act, effect, payload, action):
				return
			continue
		# PILOT_028_DECLARE：乌尔效果1 宣言（每轮 ROUND_START，弹三选一可取消，挂起等输入）
		if act_type == &"PILOT_028_DECLARE":
			if _handle_pilot_028_declare(act, effect, payload, action):
				return
			continue
		# PILOT_028_FORCE_TRIBUTE：乌尔效果2 需交牌（USE_ACTION_AT，弹交给牌窗挂起等输入）
		if act_type == &"PILOT_028_FORCE_TRIBUTE":
			if _handle_pilot_028_force_tribute(act, effect, payload, action):
				return
			continue
		# PILOT_028_X_INC：乌尔效果3 X+1（USE_ACTION_AT，同步结算，不挂起）
		if act_type == &"PILOT_028_X_INC":
			_handle_pilot_028_x_inc(act, effect, payload, action)
			continue
		# PILOT_058_SHOW_COUNT_BONUS：卡米拉效果1 展示牌型加成（同步结算，不挂起）。
		# 正常在 CHOOSE_ONE 分支内执行；此处顶层防御供复用者直接置于效果动作顶层。
		if act_type == &"PILOT_058_SHOW_COUNT_BONUS":
			_handle_pilot_058_show_count_bonus(act, effect, payload, action)
			continue
		# VIEW_RANDOM_OTHER_HAND_CARDS：通用「随机查看其他机甲行动牌+类型加成」模块（骇客 pilot_066）。
		# LISTEN BASIC_MOVE_AFTER 触发：范围内持行动牌其他机甲目标选择（挂起），选定后随机查看
		# view_count 张 + 展示浮窗 + 类型加成链（确认才 MARK 计次）。取消/无目标不计数。
		if act_type == &"VIEW_RANDOM_OTHER_HAND_CARDS":
			if _handle_view_random_other_hand(act, effect, payload, action):
				return
			continue
		# PILOT_059_TURN_START_FLOW：薇尔效果1 回合开始损伤调整+分支（多阶段挂起）。
		# 首次弹损伤调整面板（phase=pilot_059_adjust 由 resume_pending_effect 续跑），挂起即 return。
		if act_type == &"PILOT_059_TURN_START_FLOW":
			if _handle_pilot_059_turn_start_flow(act, effect, payload, action):
				return
			continue
		# PILOT_006_FORCE_USE_ATTACK：pilot_006 e3 战后逼迫选牌（顶层防御；正常在 CHOOSE_ONE 分支内特判）
		if act_type == &"PILOT_006_FORCE_USE_ATTACK":
			if _handle_pilot_006_force_use_attack(act, effect, payload, action):
				return
			continue
		# PILOT_047_FORCE_USE_ATTACK / PILOT_047_FORCE_HANDOVER：里欧娜 e1（顶层防御；正常在 CHOOSE_ONE 分支内特判）
		if act_type == &"PILOT_047_FORCE_USE_ATTACK":
			if _handle_pilot_047_force_use_attack(act, effect, payload, action):
				return
			continue
		if act_type == &"PILOT_047_FORCE_HANDOVER":
			if _handle_pilot_047_force_handover(act, effect, payload, action):
				return
			continue
		# POWER_SPEND_TAX：通用「动力税」（杰西卡 pilot_050 e1/e1b；复用=复制定义改参数）。
		# 监听其他机甲动力消耗（BASIC_MOVE_AT 移动 / power_spent 虚拟时点非移动消耗），
		# 范围内每累计消耗 threshold 点弹确认窗，确认 -> 该机甲与我方各受 damage 伤害。
		if act_type == &"POWER_SPEND_TAX":
			if _handle_power_spend_tax(act, effect, payload, action):
				return
			continue
		# POWER_TAX_TRIBUTE：通用「受伤 X+1 + 弃双方行动牌」状态机（杰西卡 pilot_050 e2）。
		# 确认 -> X+1（先于范围计算）+ mark 每回合1次 -> 按新X选范围内其他机甲（无候选仅X+1）
		# -> 我方/目标各弃 discard_count 张行动牌（chooser 均为我方，目标牌背面）。
		if act_type == &"POWER_TAX_TRIBUTE":
			if _handle_power_tax_tribute(act, effect, payload, action):
				return
			continue
		# INJURY_HEAL_DRAW：通用「范围内受伤→确认→回复生命+抽行动牌」状态机（芮贝卡 pilot_078）。
		# 监听 HP_CHANGE_SETTLE 实际掉血；确认弹窗给持有者 -> 回血+抽牌串行链（_seq_effect_actions）。
		# 完成后哨兵 _injury_heal_draw_done 置位，重跑幂等。
		if act_type == &"INJURY_HEAL_DRAW":
			if bool(payload.get("_injury_heal_draw_done", false)):
				continue
			if _handle_injury_heal_draw(act, effect, payload, action):
				return
			continue
		# ATTACK_SETTLE_DRAW_REATTACK：通用「范围内攻击结算→抽牌+每回合1次弃X再开攻击窗口」状态机
		# （维奥拉 pilot_077 等）。监听 ATTACK_SETTLE（条件已校验攻击方在 base_range 内含自身）：
		# 触发先抽 draw_count 张行动牌（强制），再每回合1次弹多选窗弃 discard_count 张（可取消不计次数）
		# -> 给攻击方开凯威攻击窗口。哨兵 _attack_settle_draw_reattack_done 置位，重跑幂等。
		if act_type == &"ATTACK_SETTLE_DRAW_REATTACK":
			if bool(payload.get("_attack_settle_draw_reattack_done", false)):
				continue
			if _handle_attack_settle_draw_reattack(act, effect, payload, action):
				return
			continue
		# PILOT_018_RESPOND_DISCARD：苔丝 effect_01b 迎击后弃攻击方牌。
		# 两阶段弹窗：①CHOOSE_ONE 选弃2行动牌/1损伤≥2装备牌；②根据选择弹选牌窗（或直接弃）。
		# 弃置后若弃的是本次攻击武器牌，attack_action._step_check_hit 检测 _weapon_still_held 失败 -> 未命中。
		if act_type == &"PILOT_018_RESPOND_DISCARD":
			if _handle_pilot_018_respond_discard(act, effect, payload, action):
				return
			continue
		# PILOT_025_SELECT_RESERVE_AND_SET：约书亚 1b 选备用装备设置+抽2（顶层防御；正常在 CHOOSE_ONE 分支内特判）
		if act_type == &"PILOT_025_SELECT_RESERVE_AND_SET":
			if _handle_pilot_025_select_reserve_and_set(act, effect, payload, action):
				return
			continue
		# PILOT_009_PAY_AND_RECORD_TYPE：美杜莎弹窗① 支付+记录类型。
		# 首次：弹非阻塞展示浮窗（目标行动牌，只弹给美杜莎）+ 弹弃牌选1窗（美杜莎自己行动牌，可取消=中止）。
		#   弃牌窗走 optional 路径（mode 非 need_input）：confirm 发 selected_action_card_ids、cancel 发 cancelled，
		#   均经 resume_pending_effect(phase=pilot_009_pay)。
		# 选定：弃置选定牌、记录其类型到 payload.pilot_009_recorded_type，续跑（CHOOSE_ONE 读 $runtime）。
		# 取消：中止整个效果（不授控制/不弃目标牌）。重跑幂等：已记录类型则跳过。
		if act_type == &"PILOT_009_PAY_AND_RECORD_TYPE":
			if payload.has("pilot_009_recorded_type"):
				continue
			var p9_params: Dictionary = act.get("params", {})
			var p9_optional: bool = bool(p9_params.get("optional", true))
			var p9_bind: Dictionary = payload.get("binding_context", {})
			var p9_ctrl_pid: StringName = p9_bind.get("player_id", &"")
			var p9_target_id: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
			# 收集目标行动牌（展示浮窗）+ 美杜莎可弃行动牌（兜底校验）
			var p9_display_cards: Array = []
			var p9_can_pay: bool = false
			if context != null and context.game_state != null:
				if p9_target_id != &"":
					var p9_tgt_player = context.game_state.get_player_for_mech(p9_target_id)
					if p9_tgt_player != null:
						for p9_cid: StringName in p9_tgt_player.action_hand:
							var p9_c = context.game_state.get_card(p9_cid)
							if p9_c != null and p9_c.def != null:
								p9_display_cards.append({"card_id": p9_cid, "name": p9_c.def.display_name, "type": String(p9_c.def.action_type)})
				var p9_ctrl_player = context.game_state.players.get(p9_ctrl_pid) if p9_ctrl_pid != &"" else null
				if p9_ctrl_player != null:
					for p9_cid2: StringName in p9_ctrl_player.action_hand:
						var p9_c2 = context.game_state.get_card(p9_cid2)
						if p9_c2 != null and p9_c2.def != null and p9_c2.def.card_kind == &"action":
							p9_can_pay = true
							break
			if not p9_can_pay:
				# 无可弃行动牌兜底中止（不授控制）。p9_can_pay 是唯一手牌门槛：
				# set_conditions 不含 HAS_ACTION_CARD_IN_HAND（否则支付弃牌后重跑会误判失败）。
				SLog.log_raw("[TIMING] %s pilot_009 美杜莎无可弃行动牌，中止 effect=%s" % [String(action.action_id), String(effect.effect_id)])
				if context.action_engine != null:
					action.state = &"waiting_input"
					context.action_engine.continue_action(action.action_id, {})
				continue
			_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_009_pay"}
			action.state = &"waiting_timing"
			# 先弹非阻塞展示浮窗（目标行动牌，给除目标外所有客户端）：玩家先看到目标牌再决定弃哪张。
			# 非模态不抢焦点、不捕获 _waiting_action_id（紧接着的 pay_select 才捕获，二者同 action_id）。
			action_needs_input.emit(action.action_id, &"pilot_009_show_display", {
				"action_id": action.action_id,
				"effect_id": effect.effect_id,
				"target_id": p9_target_id,
				"display_cards": p9_display_cards,
				"player_id": p9_ctrl_pid,
				"source_label": "蛇发支配：目标行动牌（可拖拽/可关闭）",
			})
			# 再弹弃牌选1窗（阻塞，捕获 _waiting_action_id；optional 路径 confirm/cancel 走 resume_effect）
			action_needs_input.emit(action.action_id, &"pilot_009_pay_select", {
				"action_id": action.action_id,
				"effect_id": effect.effect_id,
				"executor": p9_ctrl_pid,
				"discard_player_id": p9_ctrl_pid,
				"count": 1,
				"face_up": true,
				"action_verb": &"discard",
				"no_cancel": not p9_optional,
				"player_id": p9_ctrl_pid,
				"source_label": "蛇发支配：弃1张自己行动牌（记录其类型）",
			})
			SLog.log_raw("[TIMING] %s 挂起 pilot_009 支付选牌 effect=%s 展示牌=%d" % [String(action.action_id), String(effect.effect_id), p9_display_cards.size()])
			return
		# PILOT_088_CONQUER：征服宣言弃置（DIRECT 主动按钮，多阶段挂起模块）。
		# 首次：弹 select_mech_target 选3格内持有行动牌的其他机甲（valid_mech_ids 过滤，取消=不计次不消耗）。
		# 选定目标经 resume(phase=pilot_088_target)：消耗每回合1次 + 弹三选一类型（攻击/迎击/辅助，
		# 不可取消）→ resume(phase=pilot_088_type)：随机展示+类型匹配弃置（_pilot_088_finish_conquer）。
		if act_type == &"PILOT_088_CONQUER":
			if _handle_pilot_088_conquer(act, effect, payload, action):
				return
			continue
		# PILOT_051_INTERCEPT_EVENT_SET：李 e2「拦截事件牌设置」（LISTEN EVENT_SET_BEFORE，
		# 每局1次，通用件不绑机师）。此时新牌已入区、效果未注册：弹窗三选（弃置/转设我方/取消
		# 不计次），确认后写中止旗 + 摘牌 + _seq 分支（见 _handle_pilot_051_intercept）。
		if act_type == &"PILOT_051_INTERCEPT_EVENT_SET":
			if _handle_pilot_051_intercept(act, effect, payload, action):
				return
			continue
		# PILOT_080_MARKER_INTERACT：墨尘 e1「相邻标记交互」（DIRECT 按钮，通用件不绑机师）。
		# 前置 CHOOSE_MAP_CELL 已选相邻标记格；弹窗二选一（移去 / 移至该格后标记再生效2次，
		# 可取消）。移至分支 _seq：免费基础移动 -> 标记第1次生效 -> 完全结束后第2次生效。
		if act_type == &"PILOT_080_MARKER_INTERACT":
			if _handle_pilot_080_marker_interact(act, effect, payload, action):
				return
			continue
		# PILOT_014_SELECT_TARGET_PILOT_AND_GRANT：亚伦弹窗选场上机师牌施加行动牌上限+2。
		# 首次：收集场上所有机师牌(含自己+所有玩家，mech 未 destroyed)，弹列表选框(每项显示机师名+行动牌上限)，
		#   玩家选1个确定 -> resume grant_pilot_014_bonus + 续跑 _execute_effect(1320 自动 mark once_per_turn)；
		#   取消 -> 中止不计次数。重跑幂等：payload.pilot_014_granted 已置则跳过(已施加，续跑 mark 路径)。
		if act_type == &"PILOT_014_SELECT_TARGET_PILOT_AND_GRANT":
			if payload.has("pilot_014_granted"):
				continue
			var p014_params: Dictionary = act.get("params", {})
			var p014_optional: bool = bool(p014_params.get("optional", true))
			var p014_bind: Dictionary = payload.get("binding_context", {})
			var p014_src_pid: StringName = p014_bind.get("player_id", &"")
			var p014_options: Array = []
			if context != null and context.game_state != null:
				for p014_mid: StringName in context.game_state.mechs:
					var p014_m = context.game_state.mechs[p014_mid]
					if p014_m == null or p014_m.destroyed:
						continue
					var p014_slot = p014_m.slots.get(&"pilot")
					if p014_slot == null or p014_slot.equipped_card == null:
						continue
					var p014_pcard = p014_slot.equipped_card
					var p014_player = context.game_state.get_player_for_mech(p014_mid)
					var p014_limit: int = int(p014_player.action_card_limit) if p014_player != null else 0
					var p014_pname: String = String(p014_pcard.def.display_name) if p014_pcard.def != null else "?"
					p014_options.append({
						"label": "%s（%s）  行动牌上限 %d" % [p014_pname, String(p014_m.owner_player_id), p014_limit],
						"effect_id": p014_pcard.instance_id,
						"pilot_instance": p014_pcard.instance_id,
						"player_id": p014_m.owner_player_id,
						"mech_id": p014_mid,
					})
			if p014_options.is_empty():
				SLog.log_raw("[TIMING] %s pilot_014 场上无机师牌，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
				if context.action_engine != null:
					action.state = &"waiting_input"
					context.action_engine.continue_action(action.action_id, {})
				continue
			_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_014_select"}
			action.state = &"waiting_timing"
			action_needs_input.emit(action.action_id, &"pilot_014_target_select", {
				"action_id": action.action_id,
				"effect_id": effect.effect_id,
				"options": p014_options,
				"optional": p014_optional,
				"executor": p014_src_pid,
				"player_id": p014_src_pid,
				"source_label": "亚伦：选择1张机师牌，使其行动牌上限+2",
			})
			SLog.log_raw("[TIMING] %s 挂起 pilot_014 选机师牌 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p014_options.size()])
			return
		# PILOT_032_SELECT_TARGET_PILOT_AND_GRANT：爱瑞娅 弃1张行动牌 + 选场上机师牌 施加行动牌上限+2。
		# 两阶段：先弹弃牌窗（pilot_032_pay，可取消=中止不计次数）确认弃牌，再弹选机师窗
		# （pilot_032_select，可取消=已弃牌不返还、不计次数）。重跑幂等：pilot_032_paid 跳过弃牌、
		# pilot_032_granted 跳过全部（完成手动 mark once_per_turn）。
		# 阶段①弃牌后直接续跑到阶段②（不重跑 _execute_effect），避免 HAS_ACTION_CARD_IN_HAND
		# 因手牌变空在重查条件时误判失败。
		if act_type == &"PILOT_032_SELECT_TARGET_PILOT_AND_GRANT":
			if payload.has("pilot_032_granted"):
				continue
			var p032_params: Dictionary = act.get("params", {})
			var p032_discard_count: int = int(p032_params.get("discard_count", 0))
			if p032_discard_count > 0 and not payload.has("pilot_032_paid"):
				if _pilot_032_show_discard_pay(effect, payload, action, p032_params):
					return
				continue  # 无可弃行动牌兜底中止（条件已置灰按钮，此处双保险）
			if _pilot_032_show_pilot_select(effect, payload, action, p032_params):
				return
			continue  # 场上无机师牌兜底中止
		# PILOT_019_DISCARD_CHAIN：肯耳忒 缴械冲击 弃牌链。
		# 阶段机状态存 action.record["_pilot_019_chain"]，跨多个输入窗口（目标多选 → 支付选牌 →
		# 逐目标暗牌弃牌 X+1 → 清空判4伤害）。首次：防御校验（手牌≥1 + 4格内有其他机甲），
		# 失败 -> deferred abort（不消耗 once_per_turn）；成功 -> 弹目标多选窗挂起。
		# 重跑幂等：_pilot_019_chain 已置则跳过（链内续跑全走 resume_pending_effect 各 phase /
		# ActionEngine._after_sub_action_finished -> _continue_pilot_019_chain，不重跑本拦截）。
		if act_type == &"PILOT_019_DISCARD_CHAIN":
			if action.record.has("_pilot_019_chain"):
				continue
			if _pilot_019_begin(action, effect, payload):
				return  # 已挂起（弹目标选择窗 或 deferred abort）
			continue
		# PILOT_020_ACTIVE_DISCARD：肯德 效果1 主动弃任意张行动牌。
		# 首次：手牌非空校验（条件已查 HAS_ACTION_CARD_IN_HAND，此处兜底）-> 弹 thrust_select 多选窗挂起；
		#   取消/空选在 resume 阶段走 _pilot_020_abort_resume（不消耗 once_per_turn）。
		# 选定 -> EXECUTE_DISCARD 子动作（DISCARD_SETTLE 触发 effect_02 计数计入 X），
		#   子动作完成后由 _after_sub_action_finished -> _continue_pilot_020_active 手动 mark once_per_turn。
		if act_type == &"PILOT_020_ACTIVE_DISCARD":
			if _pilot_020_begin_active_discard(action, effect, payload):
				return
			continue
		# PILOT_020_COUNT_DISCARD：肯德 效果2 弃置计数（LISTEN DISCARD_SETTLE）。
		# 按快照 from_zone=="action_hand" && 牌归属肯德玩家 计数（使用牌 temp_zone 天然排除；
		# 回合超限/预判/肯特/肯耳忒弃的牌也走 discard_card -> DISCARD_SETTLE 计入）。
		# X≥2 时护甲+3 动力+3（上限+当前，cap_bonus 补满），每回合只触发一次。
		if act_type == &"PILOT_020_COUNT_DISCARD":
			_pilot_020_count_discard(effect, payload, action)
			continue
		# PILOT_020_DRAW_X：肯德 效果4 回合结束后抽 min(X,6) 张行动牌（LISTEN TURN_AFTER_END）。
		if act_type == &"PILOT_020_DRAW_X":
			_pilot_020_draw_x(effect, payload, action)
			continue
		# PILOT_085_DISCARD_GOLD：莽克 效果1 弃装获金（LISTEN DISCARD_SETTLE）。
		# 按快照统计「原先正面设置在机甲上」的装备牌：原先属莽克机甲每张+4金、其他机甲每张+3金，
		# 累加后一次通用获金（ga.gain_gold，自动 fire GAIN_GOLD_AFTER 时点）。
		if act_type == &"PILOT_085_DISCARD_GOLD":
			_pilot_085_discard_gold(effect, payload, action)
			continue
		# PILOT_086_DICE_BRANCH：獠鼠 效果1 攻击骰子分支（LISTEN ATTACK_PRE）。
		# 首次：弹「发动/取消」二选一确认窗挂起（_pending_effect phase=pilot_086_confirm）；
		# 取消=不发动；确认=掷骰后按点数分支出 _seq 动作链串行执行。_pilot_086_done 防重跑。
		if act_type == &"PILOT_086_DICE_BRANCH":
			if bool(action.record.get("_pilot_086_done", false)) or bool(payload.get("_pilot_086_done", false)):
				continue
			if _pilot_086_dice_branch(effect, payload, action):
				return
			continue
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
		# CHOOSE_MAP_CELL：机雷设陷选格（顶层与 CHOOSE_ONE 分支共用 _handle_choose_map_cell）
		if act_type == &"CHOOSE_MAP_CELL":
			if _handle_choose_map_cell(act, effect, payload, action):
				return
			continue
		# CHOOSE_MANY_MAP_CELLS：双子机雷设陷多格选格（顶层与分支共用 _handle_choose_many_map_cells）
		if act_type == &"CHOOSE_MANY_MAP_CELLS":
			if _handle_choose_many_map_cells(act, effect, payload, action):
				return
			continue
		# GAIN_GOLD_BY_DIE（事件牌宝藏 e011 等通用）：投1骰子按区间查表获金。
		# params: {player_id, reason, branches: [[min,max,amount],...]}。同步执行不挂起
		# （roll_d6 走 context.rng 同步随机，双端同种子锁步；gain_gold 走 GameActions 原子）。
		if act_type == &"GAIN_GOLD_BY_DIE":
			_handle_gain_gold_by_die(act.get("params", {}), payload, action)
			continue
		# DRAW_PILOT_SET_TO_SLOT_OR_DECK_BOTTOM（事件牌招募 e008 等通用）：从机师牌堆抽1张，
		# 弹"设置到机师区域 / 放回牌堆底"选择（互斥；不设置必须放牌堆底）。挂起 phase=pilot_draw_place。
		if act_type == &"DRAW_PILOT_SET_TO_SLOT_OR_DECK_BOTTOM":
			if _handle_draw_pilot_place(effect, payload, action):
				return
			continue
		# pilot_003 e02 串行化（问题2）：正面牌因 gain_card/discard_card 离堆时延迟到 cause 动作 SETTLE。
		# 此动作作为 cause 动作子动作，逐张串行执行判定（可用->use_action_card / 不可用->弃置+补偿抽），
		# 使父级动作（如攻击中抽牌）等待判定完成。_run_p003_deferred_judgment 设 _seq 并启动首个子动作。
		if act_type == &"PILOT_003_RUN_DEFERRED_JUDGE":
			if context != null and context.action_service != null:
				context.action_service._run_p003_deferred_judgment(action, payload)
			# 子动作挂起 -> cause 动作被 fire_timing 置 waiting_effect_action，_seq 已由 Service 设好，保留并返回
			if _last_created_sub_action_paused(action):
				return
			continue
		# pilot_021 塔莉娅 effect_01：抽3张行动牌打"禁"标签 + 循环赐予（选机甲->选牌->转移）。
		# 循环状态存 action.record["_pilot_021_loop"]；挂起时 _pending_effect 记 phase 指针，
		# resume 后按 phase 分发（pilot_021_choose_mech/pilot_021_choose_cards）续跑循环。
		if act_type == &"PILOT_021_LOOP_DEAL":
			if _handle_pilot_021_loop_deal(act, effect, payload, action):
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
	var deis_reason: StringName = StringName(String(act_params.get("reason", "effect_065_draw_and_set")))
	var deis_drawn_id: StringName = &""
	if deis_player_id != &"" and context != null and context.action_service != null:
		# 走 gain_card 动作拿 GAIN_CARD 时点（gain_card 委托 draw_equipment_cards 自动 append+owner+hook）
		context.action_service.execute(&"gain_card", {
			"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1,
			"player_id": deis_player_id, "reason": deis_reason
		})
		if context.game_state != null:
			var deis_player = context.game_state.players.get(deis_player_id)
			if deis_player != null and not deis_player.equipment_hand.is_empty():
				deis_drawn_id = deis_player.equipment_hand[-1]
	if deis_drawn_id == &"":
		SLog.log_raw("[TIMING] %s %s 牌堆为空，无牌可抽" % [String(action.action_id), String(act_type)])
		return &"skip"
	# only_off_turn=true（事件牌增援等"我方回合外抽到的装备不立即设置则直接弃置"语义）：
	# 我方回合内（owner 是当前回合玩家）抽到的装备牌留装备手牌（回合结束统一弃未设置装备），
	# 不弹"立即设置"窗；我方回合外继续走立即设置/弃置流程。
	if bool(act_params.get("only_off_turn", false)) and context != null and context.game_state != null:
		if context.game_state.active_player_id == deis_player_id:
			SLog.log_raw("[TIMING] %s %s 我方回合内抽取，装备牌留手牌（only_off_turn）effect=%s" % [String(action.action_id), String(act_type), String(effect.effect_id)])
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


## GAIN_GOLD_BY_DIE（事件牌宝藏 e011 等通用）：投1骰子按区间查表获金。
## params: {player_id, reason, branches: [[min,max,amount],...]}。同步执行不挂起：
## roll_d6 走 context.rng（双端同种子锁步），gain_gold 走 GameActions 原子（发 GAIN_GOLD_AFTER）。
func _handle_gain_gold_by_die(gb_params: Dictionary, payload: Dictionary, action) -> void:
	if context == null or context.game_actions == null:
		return
	var asvc = context.action_service if context != null else null
	var gb_bind_ctx: Dictionary = payload.get("binding_context", {})
	var gb_player_id: StringName = gb_bind_ctx.get("player_id", payload.get("player_id", &""))
	var gb_pid_raw = gb_params.get("player_id", &"")
	if String(gb_pid_raw).begins_with("$") and asvc != null:
		var gb_resolved = asvc._resolve_atomic_value(gb_pid_raw, payload, action)
		gb_player_id = gb_resolved if gb_resolved is StringName else StringName(str(gb_resolved))
	elif String(gb_pid_raw) != "":
		gb_player_id = StringName(String(gb_pid_raw))
	if gb_player_id == &"":
		SLog.log_raw("[TIMING] %s GAIN_GOLD_BY_DIE 无 player_id，跳过" % String(action.action_id))
		return
	var gb_roll: int = context.game_actions.roll_d6({})
	var gb_amount: int = 0
	var gb_branches: Array = gb_params.get("branches", [])
	for gb_branch in gb_branches:
		if gb_branch is Array and gb_branch.size() >= 3 \
				and int(gb_branch[0]) <= gb_roll and gb_roll <= int(gb_branch[1]):
			gb_amount = int(gb_branch[2])
			break
	if gb_amount > 0:
		context.game_actions.gain_gold({
			"player_id": gb_player_id, "amount": gb_amount,
			"reason": StringName(String(gb_params.get("reason", "gain_gold_by_die"))),
		})
	context.game_state.write_log(&"event_die_gold", {
		"player_id": String(gb_player_id),
		"die": gb_roll,
		"amount": gb_amount,
		"reason": String(gb_params.get("reason", "")),
	})
	SLog.log_raw("[TIMING] %s GAIN_GOLD_BY_DIE 骰子=%d -> %s 获%d金" % [String(action.action_id), gb_roll, String(gb_player_id), gb_amount])


## ══ 李 pilot_051 e2「拦截事件牌设置」（通用件，不绑机师）══
## LISTEN EVENT_SET_BEFORE（handler 先行翻转：此时新牌已入目标机甲事件区、效果未注册）。
## 人类拥有者弹三选一窗：0=弃置（该牌后续流程空跑、效果不生效）/ 1=转设到我方机甲事件区
##（完整设置-生效流程，顶掉我方旧事件牌）/ 取消=不发动不消耗本局1次。
## 确认/取消路径见 resume_pending_effect 的 pilot_051_intercept 分支。
func _handle_pilot_051_intercept(_act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	# 去重：同一次设置动作只弹一次窗（resume 经 _pending_effect 直达，不走重跑）
	if action.record.has("_pilot_051_intercept_shown"):
		return false
	var p051_card_id: StringName = payload.get("event_card_id", &"")
	var p051_target_mid: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
	var p051_card = context.game_state.get_card(p051_card_id) if p051_card_id != &"" else null
	var p051_target_mech = context.game_state.mechs.get(p051_target_mid) if p051_target_mid != &"" else null
	if p051_card == null or p051_target_mech == null:
		return false
	# 防御：新牌须确已入目标机甲事件区（EVENT_SET_BEFORE 在放置步骤后 fire）
	var p051_slot = p051_target_mech.slots.get(&"event")
	if p051_slot == null or p051_slot.equipped_card != p051_card:
		return false
	var p051_bind_ctx: Dictionary = payload.get("binding_context", {})
	var p051_owner_pid: StringName = p051_bind_ctx.get("player_id", &"")
	if p051_owner_pid == &"":
		return false
	action.record["_pilot_051_intercept_shown"] = true
	var p051_card_name: String = String(p051_card.def.display_name) if p051_card.def != null else String(p051_card_id)
	var p051_target_label: String = String(p051_target_mid)
	# frame_def 是 MechFrameDef 对象（非 Dictionary），Object.get() 不支持双参默认值，直接读属性
	if p051_target_mech.frame_def != null and p051_target_mech.frame_def.display_name != "":
		p051_target_label = p051_target_mech.frame_def.display_name
	_pending_effect[action.action_id] = {
		"action": action, "effect": effect, "payload": payload, "phase": &"pilot_051_intercept",
	}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": "弃置该事件牌（其效果不生效）", "effect_id": &"option_0", "option_index": 0},
			{"label": "将该事件牌转设到我方区域（顶掉我方旧事件牌）", "effect_id": &"option_1", "option_index": 1},
		],
		"optional": true,
		"executor": p051_owner_pid,
		"player_id": p051_owner_pid,
		"source_label": "李：拦截事件牌「%s」→ 设置到 %s（本局1次，取消不消耗）" % [p051_card_name, p051_target_label],
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_051 拦截窗 effect=%s 牌=%s 目标=%s" % [String(action.action_id), String(effect.effect_id), String(p051_card_id), String(p051_target_mid)])
	return true


## ══ 墨尘 pilot_080 e1「相邻标记交互」（通用件，不绑机师）══
## DIRECT 按钮，前置 CHOOSE_MAP_CELL 已选相邻标记格。弹二选一窗：
##   0=移去（整格标记全部移除，不触发）/ 1=移至该格（免费基础移动，移到后该格标记再生效2次）
##   / 取消=不发动（本效果无次数限制）。移至分支的 _seq 构造见 resume pilot_080_choice 分支。
func _handle_pilot_080_marker_interact(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null or context.game_state.map_state == null:
		return false
	# 去重：同一次按钮动作只弹一次窗
	if action.record.has("_pilot_080_choice_shown"):
		return false
	var p080_params: Dictionary = act.get("params", {})
	var p080_cell_key: StringName = p080_params.get("cell_key", &"pilot_080_cell")
	var p080_cell: String = String(payload.get(p080_cell_key, ""))
	if p080_cell == "":
		return false
	var p080_parts := p080_cell.split(",")
	var p080_q: int = int(p080_parts[0]) if p080_parts.size() >= 1 else 0
	var p080_r: int = int(p080_parts[1]) if p080_parts.size() >= 2 else 0
	# 防御：格上已无标记（选格与弹窗之间标记可能被移走）
	var p080_markers: Array = context.game_state.map_state.get_markers_at(p080_q, p080_r)
	if p080_markers.is_empty():
		return false
	var p080_bind_ctx: Dictionary = payload.get("binding_context", {})
	var p080_pid: StringName = p080_bind_ctx.get("player_id", &"")
	var p080_mech_id: StringName = p080_bind_ctx.get("mech_id", payload.get("mech_id", payload.get("source_mech_id", &"")))
	if p080_pid == &"" or p080_mech_id == &"" or not context.game_state.mechs.has(p080_mech_id):
		return false
	# AI 拥有者：不弹窗不发动（AI 逻辑暂不实现，直接跳过）
	if _is_ai_owner(p080_pid, p080_mech_id):
		return false
	action.record["_pilot_080_choice_shown"] = true
	# 移至选项可行性：目标格非 RED / 无其他机甲占据 / 本机甲无 cannot_move 状态
	var p080_move_ok: bool = true
	var p080_cell_state = context.game_state.map_state.cells.get(p080_cell)
	if p080_cell_state != null and p080_cell_state.terrain == &"RED":
		p080_move_ok = false
	for p080_mid: StringName in context.game_state.mechs:
		var p080_other = context.game_state.mechs[p080_mid]
		if p080_other == null or p080_other.destroyed or p080_mid == p080_mech_id:
			continue
		if int(p080_other.position.get("q", 0)) == p080_q and int(p080_other.position.get("r", 0)) == p080_r:
			p080_move_ok = false
			break
	var p080_mech = context.game_state.mechs[p080_mech_id]
	for p080_status: Dictionary in p080_mech.statuses:
		if String(p080_status.get("status_id", "")) == "cannot_move":
			p080_move_ok = false
			break
	var p080_options: Array = [
		{"label": "移去该格全部标记（%d枚，不触发）" % p080_markers.size(), "effect_id": &"option_0", "option_index": 0},
	]
	if p080_move_ok:
		p080_options.append({"label": "移至该格，移到后该格标记再生效2次（不耗动力）", "effect_id": &"option_1", "option_index": 1})
	_pending_effect[action.action_id] = {
		"action": action, "effect": effect, "payload": payload, "phase": &"pilot_080_choice",
		"pilot_080_cell": p080_cell, "pilot_080_mech_id": p080_mech_id, "pilot_080_player_id": p080_pid,
	}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": p080_options,
		"optional": true,
		"executor": p080_pid,
		"player_id": p080_pid,
		"source_label": "墨尘：与格(%d,%d)上的标记交互" % [p080_q, p080_r],
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_080 标记交互窗 effect=%s 格=(%d,%d) 标记=%d" % [String(action.action_id), String(effect.effect_id), p080_q, p080_r, p080_markers.size()])
	return true


## 墨尘 pilot_080 移至分支的单标记单次生效原子：通用「标记生效」模块
## （MarkerService.build_marker_trigger_atom，效果 _seq 链串行触发标准入口）。
## 两次生效各取一枚原子，相互独立（陷阱连锁完整算1次后再独立爆1次）。
func _pilot_080_marker_trigger_atom(marker: Dictionary, mech_id: StringName, player_id: StringName) -> Dictionary:
	if context == null or context.marker_service == null:
		return {}
	return context.marker_service.build_marker_trigger_atom(marker, mech_id, player_id)


## DRAW_PILOT_SET_TO_SLOT_OR_DECK_BOTTOM（事件牌招募 e008 等通用）：从机师牌堆抽1张，
## 玩家选「设置到机师区域 / 放回牌堆底」（不设置必须放牌堆底，不弃置）。
## 返回 true=已挂起（弹 choose_one_effect 窗）/ AI 已自动处理完成；false=牌堆空跳过。
## 设置时若机师区域已有旧机师：先 unset_pilot 弃置旧牌，再 set_pilot（换机师规则）。
func _handle_draw_pilot_place(effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.deck_service == null or context.game_setup_service == null:
		return false
	var pdp_bind_ctx: Dictionary = payload.get("binding_context", {})
	var pdp_mech_id: StringName = pdp_bind_ctx.get("mech_id", payload.get("mech_id", payload.get("source_mech_id", &"")))
	var pdp_player_id: StringName = pdp_bind_ctx.get("player_id", &"")
	if pdp_mech_id == &"" or pdp_player_id == &"" or not context.game_state.mechs.has(pdp_mech_id):
		SLog.log_raw("[TIMING] %s DRAW_PILOT_SET 缺 mech_id/player_id，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	var pdp_drawn: Array = context.deck_service.draw_from_deck(&"pilot_deck", 1)
	if pdp_drawn.is_empty():
		SLog.log_raw("[TIMING] %s DRAW_PILOT_SET 机师牌堆为空（永久离场不重洗），跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	var pdp_card_id: StringName = pdp_drawn[0]
	var pdp_card = context.game_state.get_card(pdp_card_id)
	if pdp_card != null:
		pdp_card.owner_player_id = pdp_player_id
		pdp_card.mech_id = pdp_mech_id
	# AI owner：自动决策（机师区域空则设置，否则放牌堆底），避免挂死
	if _is_ai_owner(pdp_player_id, pdp_mech_id):
		_pilot_place_to_slot(pdp_mech_id, pdp_card_id, true)
		return true
	# 人类：挂起弹「设置到机师区域 / 放回牌堆底」选择窗（choose_one_effect 链路）
	_pending_effect[action.action_id] = {
		"action": action, "effect": effect, "payload": payload, "phase": &"pilot_draw_place",
		"pilot_card_id": pdp_card_id, "mech_id": pdp_mech_id, "player_id": pdp_player_id,
	}
	action.state = &"waiting_timing"
	var pdp_pilot_name: String = ""
	if pdp_card != null and pdp_card.def != null:
		pdp_pilot_name = String(pdp_card.def.display_name)
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": "设置到机师区域（%s）" % (pdp_pilot_name if pdp_pilot_name != "" else "替换当前机师"), "effect_id": &"option_0", "option_index": 0},
			{"label": "放回机师牌堆底", "effect_id": &"option_1", "option_index": 1},
		],
		"optional": false,
		"player_id": pdp_player_id,
		"source_label": "招募：抽到机师牌 %s，设置到机师区域或放回牌堆底" % pdp_pilot_name,
	})
	SLog.log_raw("[TIMING] %s 挂起机师牌放置 effect=%s card=%s mech=%s" % [String(action.action_id), String(effect.effect_id), String(pdp_card_id), String(pdp_mech_id)])
	return true


## 机师牌落位：option 0=设置到机师区域（旧机师先弃置）；option 1=放回机师牌堆底。
## ai_auto=true 时机师区域空才设置（否则放牌堆底）。
func _pilot_place_to_slot(mech_id: StringName, pilot_card_id: StringName, ai_auto: bool) -> void:
	if context == null or context.game_setup_service == null or context.game_state == null:
		return
	var pdp_mech = context.game_state.mechs.get(mech_id)
	if pdp_mech == null:
		return
	var pdp_slot = pdp_mech.slots.get(&"pilot")
	if pdp_slot == null:
		return
	var pdp_has_old: bool = pdp_slot.equipped_card != null
	if ai_auto and pdp_has_old:
		context.deck_service.move_card_to_deck_bottom(pilot_card_id, &"pilot_deck")
		SLog.log_raw("[TIMING] AI 机师牌放置：区域已有机师，放回牌堆底 card=%s" % String(pilot_card_id))
		return
	# 旧机师先弃置（换机师规则：须先弃旧再设新）
	if pdp_has_old:
		var pdp_old_id: StringName = pdp_slot.equipped_card.instance_id
		context.game_setup_service.unset_pilot(mech_id)
		if context.deck_service != null:
			context.deck_service.discard_card(pdp_old_id, &"pilot_replaced")
	var pdp_card = context.game_state.get_card(pilot_card_id)
	if pdp_card != null:
		context.game_setup_service.set_pilot(mech_id, pdp_card)
		SLog.log_raw("[TIMING] 机师牌设置到区域 card=%s mech=%s" % [String(pilot_card_id), String(mech_id)])


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


## ── pilot_019 肯耳忒 缴械冲击：弃牌链阶段机 ──
## 主动效果：弃我方X张行动牌（X≥1），逐目标弃X+1张，清空目标行动手牌则4伤害。
## 状态存 action.record["_pilot_019_chain"]（Dictionary 引用语义，链内各处直接改）。

## 起始：防御校验 + 初始化阶段机。返回 true = 已挂起（弹目标选择窗 或 deferred abort）。
func _pilot_019_begin(action, effect: ActionEffect, payload: Dictionary) -> bool:
	var info: Dictionary = _pilot_019_owner_info(payload, action)
	var owner_pid: StringName = info.get("owner_pid", &"")
	var owner_mech: StringName = info.get("owner_mech", &"")
	if not _pilot_019_can_start(owner_pid, owner_mech):
		# 防御校验失败（条件已由 set_conditions 检查过，此处兜底）：deferred abort 不消耗 once_per_turn。
		# 不能同步 continue_action：_execute_effect 返回后 state 检查会误 mark once_per_turn；
		# deferred 时 _pending_effect 仍挂着 waiting_timing -> 早退不 mark，再由 _pilot_019_abort_resume 恢复。
		SLog.log_raw("[TIMING] %s pilot_019 肯耳忒不可发动（手牌<1 或 4格内无其他机甲）effect=%s" % [String(action.action_id), String(effect.effect_id)])
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_019_abort"}
		action.state = &"waiting_timing"
		call_deferred("_pilot_019_abort_resume", action.action_id)
		return true
	action.record["_pilot_019_chain"] = {
		"payload": payload,
		"effect": effect,
		"targets": [],
		"idx": 0,
		"x": 0,
		"stage": &"wait_targets",
		"pay_cards": [],
		"target_cards": [],
		"discard_issued": false,
		"damage_issued": false,
		"owner_pid": owner_pid,
		"owner_mech": owner_mech,
	}
	_pilot_019_emit_target_select(action)
	return true


## 取 pilot_019 来源玩家/机甲（binding_context 优先，回退 payload/action.source）。
func _pilot_019_owner_info(payload: Dictionary, action) -> Dictionary:
	var bind: Dictionary = payload.get("binding_context", {})
	var owner_pid: StringName = bind.get("player_id", payload.get("player_id", &""))
	var owner_mech: StringName = bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	if owner_pid == &"" and action != null and action.source is Dictionary:
		owner_pid = action.source.get("player_id", &"")
	if owner_mech == &"" and action != null and action.source is Dictionary:
		owner_mech = action.source.get("mech_id", &"")
	if owner_mech == &"" and owner_pid != &"" and context != null and context.game_state != null:
		for mid in context.game_state.mechs:
			var m = context.game_state.mechs[mid]
			if m != null and m.owner_player_id == owner_pid:
				owner_mech = mid
				break
	return {"owner_pid": owner_pid, "owner_mech": owner_mech}


## 防御校验：肯耳忒有行动牌 + 4格内存在其他存活机甲。
func _pilot_019_can_start(owner_pid: StringName, owner_mech: StringName) -> bool:
	if context == null or context.game_state == null:
		return false
	var owner_player = context.game_state.players.get(owner_pid) if owner_pid != &"" else null
	if owner_player == null or owner_player.action_hand.is_empty():
		return false
	var src = context.game_state.mechs.get(owner_mech)
	if src == null or src.destroyed or src.position.is_empty():
		return false
	for mid in context.game_state.mechs:
		if mid == owner_mech:
			continue
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed or m.position.is_empty():
			continue
		if _ConditionChecker._hex_distance(src.position, m.position) <= 4:
			return true
	return false


## 目标手牌（目标机甲归属玩家的 action_hand）
func _pilot_019_target_hand(target_mech: StringName) -> Array:
	if context == null or context.game_state == null:
		return []
	var player = context.game_state.get_player_for_mech(target_mech)
	if player == null:
		return []
	return player.action_hand


## 目标归属玩家 id
func _pilot_019_target_pid(target_mech: StringName) -> StringName:
	if context == null or context.game_state == null:
		return &""
	var mech = context.game_state.mechs.get(target_mech)
	if mech != null:
		return mech.owner_player_id
	return &""


## 弹目标多选窗（select_attack_target，target_count=2，hex 距离4）。
## 路由：_popup_owner(attack_target_select) 按 attacker_id（=owner_mech）归属 -> 弹给肯耳忒持有者。
func _pilot_019_emit_target_select(action) -> void:
	var chain: Dictionary = action.record.get("_pilot_019_chain", {})
	var effect: ActionEffect = chain.get("effect")
	var owner_mech: StringName = chain.get("owner_mech", &"")
	var owner_pid: StringName = chain.get("owner_pid", &"")
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": chain.get("payload", {}), "phase": &"pilot_019_wait_targets"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_attack_target", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"attacker_id": owner_mech,
		"player_id": owner_pid,
		"executor": owner_pid,
		"weapon_range": 4,
		"target_count": 2,
		"target_kind": &"pilot_019",
		"source_label": "缴械冲击：选择最多2台4格范围内的其他机甲（点「取消」用已选目标继续）",
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_019 选目标 effect=%s" % [String(action.action_id), String(effect.effect_id)])


## 弹支付选牌窗（thrust_select 多选checkbox，可悬停看效果文本）。
## 玩家选 N 张自己行动牌确认 -> selected_card_ids；ThrustSelectPanel confirm 永不禁用，
## 空选在 resume 阶段视为取消中止。
func _pilot_019_emit_pay(action, chain: Dictionary) -> void:
	var effect: ActionEffect = chain.get("effect")
	var owner_pid: StringName = chain.get("owner_pid", &"")
	var owner_player = context.game_state.players.get(owner_pid) if (context != null and context.game_state != null) else null
	var pay_cards: Array = []
	if owner_player != null:
		pay_cards = owner_player.action_hand.duplicate()
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": chain.get("payload", {}), "phase": &"pilot_019_pay"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"thrust_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": pay_cards,
		"player_id": owner_pid,
		"executor": owner_pid,
		"label": "缴械冲击：弃置我方 X 张行动牌（X 最低为1，悬停看效果）",
		"per_card_suffix": "",
		"confirm_verb": "确认弃置",
		"cancel_label": "取消（不发动）",
		"max_count": 0,
		"min_count": 1,
		"source_label": "缴械冲击",
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_019 支付选牌 effect=%s 手牌=%d" % [String(action.action_id), String(effect.effect_id), pay_cards.size()])


## 弹目标暗牌弃牌窗（select_discard_cards optional 分支：confirm -> selected_action_card_ids）。
## discard_player_id=目标玩家（面板列出目标暗牌"行动牌 #N"）；executor=肯耳忒持有者（弹窗路由给持有者）。
## no_cancel=true 强制选满 X+1 张。
func _pilot_019_emit_target_pick(action, chain: Dictionary, tgt: StringName, need: int) -> void:
	var effect: ActionEffect = chain.get("effect")
	var owner_pid: StringName = chain.get("owner_pid", &"")
	var tgt_pid: StringName = _pilot_019_target_pid(tgt)
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": chain.get("payload", {}), "phase": &"pilot_019_target_pick"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"select_discard_cards", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"executor": owner_pid,
		"discard_player_id": tgt_pid,
		"count": need,
		"max_count": need,
		"min_count": need,
		"face_up": false,
		"action_verb": &"discard",
		"no_cancel": true,
		"player_id": owner_pid,
		"mode": &"resume_pending",
		"source_label": "缴械冲击：选择目标弃置的行动牌（未知），需弃 %d 张" % need,
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_019 目标 %s 选弃牌 effect=%s need=%d" % [String(action.action_id), String(tgt), String(effect.effect_id), need])


## 阶段机主循环：按 chain.stage 推进，返回 true = 已挂起（等待 UI/子动作），false = 完成/已推进。
## 各阶段：
##   wait_pay          -> 弹支付窗挂起
##   pay_discarding    -> 弃置肯耳忒 X 张（EXECUTE_DISCARD 子动作），完成后进入 per_target
##   per_target        -> 逐目标：手牌空跳过；不足 X+1 直接弃全部；足量弹目标暗牌弃牌窗挂起
##   target_discarding -> 弃目标牌，弃完判清空 -> 4伤害，进入下一目标
func _pilot_019_drive(action) -> bool:
	var chain: Dictionary = action.record.get("_pilot_019_chain", {})
	if chain.is_empty():
		return false
	while true:
		var stage: StringName = chain.get("stage", &"wait_targets")
		match stage:
			&"wait_pay":
				chain["stage"] = &"paying"
				_pilot_019_emit_pay(action, chain)
				return true
			&"pay_discarding":
				if not chain.get("discard_issued", false):
					chain["discard_issued"] = true
					if _pilot_019_discard_cards(action, chain, chain.get("pay_cards", []), &"pilot_019_pay"):
						return true
				chain["stage"] = &"per_target"
				chain["idx"] = 0
				chain["discard_issued"] = false
				continue
			&"per_target":
				var targets: Array = chain.get("targets", [])
				var idx: int = int(chain.get("idx", 0))
				if idx >= targets.size():
					_pilot_019_finish(action, chain)
					return false
				var tgt: StringName = StringName(String(targets[idx]))
				var tgt_hand: Array = _pilot_019_target_hand(tgt)
				if tgt_hand.is_empty():
					chain["idx"] = idx + 1
					chain["discard_issued"] = false
					chain["target_cards"] = []
					continue
				var need: int = int(chain.get("x", 1)) + 1
				if tgt_hand.size() < need:
					# 目标手牌不足 X+1：不弹窗直接弃全部（弃完必清空 -> 判4伤害）
					chain["target_cards"] = tgt_hand.duplicate()
					chain["stage"] = &"target_discarding"
					chain["discard_issued"] = false
					continue
				chain["stage"] = &"target_picking"
				_pilot_019_emit_target_pick(action, chain, tgt, need)
				return true
			&"target_discarding":
				var t_cards: Array = chain.get("target_cards", [])
				if not chain.get("discard_issued", false):
					chain["discard_issued"] = true
					if not t_cards.is_empty():
						if _pilot_019_discard_cards(action, chain, t_cards, &"pilot_019_target"):
							return true
				# 弃牌完成（或原为空）：目标行动手牌被清空 -> 4伤害
				# （转 EXECUTE_HP_CHANGE 子动作：HP_CHANGE_BEFORE 可被杰狞 pilot_049 转移等拦截；
				#   挂起时 damage_issued 防重入重复发伤害，子动作完成后经 _continue_pilot_019_chain 重入推进）
				var tgt2: StringName = StringName(String(chain.get("targets", [])[int(chain.get("idx", 0))]))
				if _pilot_019_target_hand(tgt2).is_empty() and not chain.get("damage_issued", false):
					chain["damage_issued"] = true
					if _deal_direct_hp_change_sub(action, chain.get("payload", {}), tgt2, 4, chain.get("owner_mech", &""), &"pilot_019_clear_discard"):
						return true
				chain["idx"] = int(chain.get("idx", 0)) + 1
				chain["stage"] = &"per_target"
				chain["discard_issued"] = false
				chain["damage_issued"] = false
				chain["target_cards"] = []
				continue
			_:
				# 未知阶段（不应发生）：安全结束
				_pilot_019_finish(action, chain)
				return false
	return false


## 弃置指定牌（EXECUTE_DISCARD 子动作，card_ids 预指定无 UI，发 DISCARD_BEFORE/AFTER/SETTLE 时点）。
## 返回 true = 子动作挂起（父动作切 waiting_effect_action，等 _after_sub_action_finished -> _continue_pilot_019_chain 续跑）。
func _pilot_019_discard_cards(action, chain: Dictionary, card_ids: Array, reason: StringName) -> bool:
	if card_ids.is_empty() or context == null or context.action_service == null:
		return false
	context.action_service.execute_sub_action({
		"type": &"EXECUTE_DISCARD",
		"params": {
			"card_ids": card_ids.duplicate(),
			"reason": reason,
		},
	}, chain.get("payload", {}), action)
	if _last_created_sub_action_paused(action):
		action.state = &"waiting_effect_action"
		return true
	return false


## 阶段机完成：清状态 + 手动 mark once_per_turn（多阶段挂起，_execute_effect 未走到末尾 mark）
## + emit effect_executed + 恢复父动作。
func _pilot_019_finish(action, chain: Dictionary) -> void:
	action.record.erase("_pilot_019_chain")
	_pending_effect.erase(action.action_id)
	var effect: ActionEffect = chain.get("effect")
	var payload: Dictionary = chain.get("payload", {})
	if effect != null:
		_mark_once_per_turn_used(effect, payload)
		if effect.once_per_game_key != &"":
			_mark_once_per_game_used(effect, payload)
		effect_executed.emit(effect.effect_id, action.action_id)
		_mark_effect_executed(effect.effect_id, action.action_id)
		SLog.log_raw("[TIMING] %s pilot_019 缴械冲击 完成 effect=%s" % [String(action.action_id), String(effect.effect_id)])
	if context != null and context.action_engine != null:
		action.state = &"waiting_input"
		context.action_engine.continue_action(action.action_id, {})


## 中止：清状态 + 恢复父动作（不消耗 once_per_turn）。
## 从 _pilot_019_begin 防御失败路径经 call_deferred 调用（避免 _execute_effect 末尾误 mark）；
## 从 resume_pending_effect 取消路径同步调用（此时 _pending_effect 已 pop，无 mark 风险）。
func _pilot_019_abort_resume(action_id: StringName) -> void:
	_pending_effect.erase(action_id)
	if context == null or context.action_engine == null:
		return
	var action = context.action_registry.get_action(action_id) if context.action_registry != null else null
	if action == null:
		return
	action.record.erase("_pilot_019_chain")
	action.state = &"waiting_input"
	context.action_engine.continue_action(action_id, {})


## ActionEngine._after_sub_action_finished 钩子：EXECUTE_DISCARD 子动作完成后续跑弃牌链。
func _continue_pilot_019_chain(parent_action) -> bool:
	if parent_action == null or not parent_action.record.has("_pilot_019_chain"):
		return false
	return _pilot_019_drive(parent_action)


# ════════════════════════════════════════════════════════════
# pilot_032 爱瑞娅：弃1张行动牌 + 选场上机师牌 施加行动牌上限+2（两阶段弹窗）
# ════════════════════════════════════════════════════════════

## 阶段①：弹弃牌窗（从我方手牌选1张弃置，可取消=中止不计次数）。
## 返回 true=已挂起等输入；false=无可弃行动牌（调用方 continue 中止，不消耗次数）。
func _pilot_032_show_discard_pay(effect: ActionEffect, payload: Dictionary, action, p032_params: Dictionary) -> bool:
	var p032_optional: bool = bool(p032_params.get("optional", true))
	var p032_discard_count: int = int(p032_params.get("discard_count", 1))
	var p032_bind: Dictionary = payload.get("binding_context", {})
	var p032_ctrl_pid: StringName = p032_bind.get("player_id", &"")
	# 兜底校验：持有者至少1张行动牌（条件 HAS_ACTION_CARD_IN_HAND 已置灰按钮，此处双保险）。
	var p032_can_pay: bool = false
	if context != null and context.game_state != null and p032_ctrl_pid != &"":
		var p032_ctrl_player = context.game_state.players.get(p032_ctrl_pid)
		if p032_ctrl_player != null:
			for p032_cid: StringName in p032_ctrl_player.action_hand:
				var p032_c = context.game_state.get_card(p032_cid)
				if p032_c != null and p032_c.def != null and p032_c.def.card_kind == &"action":
					p032_can_pay = true
					break
	if not p032_can_pay:
		SLog.log_raw("[TIMING] %s pilot_032 爱瑞娅无可弃行动牌，中止 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_032_pay", "params": p032_params}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"pilot_032_pay_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"executor": p032_ctrl_pid,
		"discard_player_id": p032_ctrl_pid,
		"count": p032_discard_count,
		"face_up": true,
		"action_verb": &"discard",
		"no_cancel": not p032_optional,
		"player_id": p032_ctrl_pid,
		"source_label": "爱瑞娅：弃置1张我方行动牌，使1张场上机师牌行动牌上限+2",
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_032 弃牌支付 effect=%s" % [String(action.action_id), String(effect.effect_id)])
	return true


## 阶段②：弹场上机师牌选择窗（choice_panel，选项含机师名+归属+当前行动牌上限）。
## 返回 true=已挂起等输入；false=场上无机师牌（调用方 continue 中止，不消耗次数）。
func _pilot_032_show_pilot_select(effect: ActionEffect, payload: Dictionary, action, p032_params: Dictionary) -> bool:
	var p032_optional: bool = bool(p032_params.get("optional", true))
	var p032_bind: Dictionary = payload.get("binding_context", {})
	var p032_src_pid: StringName = p032_bind.get("player_id", &"")
	var p032_options: Array = []
	if context != null and context.game_state != null:
		for p032_mid: StringName in context.game_state.mechs:
			var p032_m = context.game_state.mechs[p032_mid]
			if p032_m == null or p032_m.destroyed:
				continue
			var p032_slot = p032_m.slots.get(&"pilot")
			if p032_slot == null or p032_slot.equipped_card == null:
				continue
			var p032_pcard = p032_slot.equipped_card
			var p032_player = context.game_state.get_player_for_mech(p032_mid)
			var p032_limit: int = int(p032_player.action_card_limit) if p032_player != null else 0
			var p032_pname: String = String(p032_pcard.def.display_name) if p032_pcard.def != null else "?"
			p032_options.append({
				"label": "%s（%s）  行动牌上限 %d" % [p032_pname, String(p032_m.owner_player_id), p032_limit],
				"effect_id": p032_pcard.instance_id,
				"pilot_instance": p032_pcard.instance_id,
				"player_id": p032_m.owner_player_id,
				"mech_id": p032_mid,
			})
	if p032_options.is_empty():
		SLog.log_raw("[TIMING] %s pilot_032 场上无机师牌，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_032_select", "params": p032_params}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"pilot_032_target_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": p032_options,
		"optional": p032_optional,
		"executor": p032_src_pid,
		"player_id": p032_src_pid,
		"source_label": "爱瑞娅：选择1张机师牌，使其行动牌上限+2",
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_032 选机师牌 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), p032_options.size()])
	return true


# ════════════════════════════════════════════════════════════
# pilot_020 肯德：弃任意行动牌 + X 计数 + 回合末抽牌
# ════════════════════════════════════════════════════════════

## 取 pilot_020 来源玩家/机甲（binding_context 优先，回退 payload/action.source）。
func _pilot_020_owner_info(payload: Dictionary, action) -> Dictionary:
	var bind: Dictionary = payload.get("binding_context", {})
	var owner_pid: StringName = bind.get("player_id", payload.get("player_id", &""))
	var owner_mech: StringName = bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	if owner_pid == &"" and action != null and action.source is Dictionary:
		owner_pid = action.source.get("player_id", &"")
	if owner_mech == &"" and action != null and action.source is Dictionary:
		owner_mech = action.source.get("mech_id", &"")
	return {"owner_pid": owner_pid, "owner_mech": owner_mech}


## 效果1 起始：防御校验（手牌非空）+ 弹 thrust_select 多选窗挂起。返回 true=已挂起。
func _pilot_020_begin_active_discard(action, effect: ActionEffect, payload: Dictionary) -> bool:
	var info: Dictionary = _pilot_020_owner_info(payload, action)
	var owner_pid: StringName = info.get("owner_pid", &"")
	var owner_player = context.game_state.players.get(owner_pid) if (owner_pid != &"" and context != null and context.game_state != null) else null
	if owner_player == null or owner_player.action_hand.is_empty():
		# 防御失败（条件已由 set_conditions 查过 HAS_ACTION_CARD_IN_HAND，此处兜底）：
		# deferred abort 不消耗 once_per_turn（与 _pilot_019_begin 同款防误 mark）。
		SLog.log_raw("[TIMING] %s pilot_020 肯德不可发动（无行动牌）effect=%s" % [String(action.action_id), String(effect.effect_id)])
		_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_020_abort"}
		action.state = &"waiting_timing"
		call_deferred("_pilot_020_abort_resume", action.action_id)
		return true
	var hand: Array = owner_player.action_hand.duplicate()
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_020_discard"}
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"thrust_select", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"card_ids": hand,
		"player_id": owner_pid,
		"executor": owner_pid,
		"label": "肯德·弃任意行动牌：选择要弃置的行动牌（至少1张，悬停看效果）",
		"per_card_suffix": "",
		"confirm_verb": "确认弃置",
		"cancel_label": "取消（不发动）",
		"max_count": 0,
		"min_count": 1,
		"source_label": "肯德·弃任意行动牌",
	})
	SLog.log_raw("[TIMING] %s 挂起 pilot_020 弃牌选牌 effect=%s 手牌=%d" % [String(action.action_id), String(effect.effect_id), hand.size()])
	return true


## 效果2 计数 + X≥2 护甲+3 动力+3（LISTEN DISCARD_SETTLE 每张弃置牌快照过滤后累加）。
## 只做同步数值变更，不挂起。返回 false（不中断 _execute_actions）。
func _pilot_020_count_discard(effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var bind: Dictionary = payload.get("binding_context", {})
	var pcard = _ActionPilotEffects.get_pilot_020_pilot_card(context.game_state, bind)
	if pcard == null:
		return false
	var owner_pid: StringName = bind.get("player_id", &"")
	if owner_pid == &"":
		return false
	var mech_id: StringName = bind.get("mech_id", &"")
	var snapshots: Array = payload.get("discard_snapshots", [])
	var counted: int = 0
	for snap in snapshots:
		if not (snap is Dictionary):
			continue
		# 只计「手牌区(action_hand)」弃出的、归属肯德玩家的行动牌。
		# 使用牌走 temp_zone 弃入（快照 from_zone=temp_zone）天然排除；
		# 回合超限弃牌/预判/肯特/肯耳忒弃牌均走 discard_card，快照 from_zone=action_hand 计入。
		# 归属判定用牌实例 owner_player_id（真实玩法手牌行动卡 mech_id 为空，
		# draw_action_cards 不设 mech_id，故不能按 from_mech_id 过滤）。
		if String(snap.get("from_zone", &"")) != "action_hand":
			continue
		var s_card = context.game_state.cards.get(snap.get("card_id", &""))
		if s_card == null or s_card.owner_player_id != owner_pid:
			continue
		counted += 1
	if counted == 0:
		return false
	var turn: int = int(context.game_state.turn_number)
	_ActionPilotEffects.increment_pilot_020_x(pcard, turn, counted)
	var x: int = _ActionPilotEffects.get_pilot_020_x(pcard, turn)
	SLog.log_raw("[pilot_020] 肯德行动牌弃置 +%d，X=%d player=%s mech=%s turn=%d" % [counted, x, String(owner_pid), String(mech_id), turn])
	# X≥2（大于1）时：护甲+3 + 动力+3（上限+当前，cap_bonus 补满），每回合只触发一次。
	if x >= 2 and not _ActionPilotEffects.is_pilot_020_armor_applied(pcard, turn):
		_ActionPilotEffects.mark_pilot_020_armor_applied(pcard, turn)
		if context.game_actions != null:
			context.game_actions.modify_armor({"mech_id": mech_id, "delta": 3, "duration": &"THIS_TURN", "source_card_id": pcard.instance_id})
			context.game_actions.modify_mech_power({"mech_id": mech_id, "delta": 3, "mode": &"cap_bonus", "duration": &"THIS_TURN", "source_card_id": pcard.instance_id})
		SLog.log_raw("[pilot_020] 肯德 X=%d>=2，护甲+3 动力+3(上限+当前) mech=%s" % [x, String(mech_id)])
	return false


## 效果4 回合结束后抽 min(X,6) 张行动牌（LISTEN TURN_AFTER_END）。
## 条件已查 X≥4，此处兜底并读 X 确定数量。gain_card 走动作拿 GAIN_CARD 时点。返回 false。
func _pilot_020_draw_x(effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null or context.action_service == null:
		return false
	var bind: Dictionary = payload.get("binding_context", {})
	var pcard = _ActionPilotEffects.get_pilot_020_pilot_card(context.game_state, bind)
	if pcard == null:
		return false
	var turn: int = int(context.game_state.turn_number)
	var x: int = _ActionPilotEffects.get_pilot_020_x(pcard, turn)
	if x < 4:
		return false
	var draw_n: int = mini(x, 6)
	var owner_pid: StringName = bind.get("player_id", &"")
	if owner_pid == &"":
		owner_pid = pcard.owner_player_id
	if owner_pid == &"":
		return false
	SLog.log_raw("[pilot_020] 肯德 X=%d>=4，回合结束后抽 %d 张行动牌 player=%s" % [x, draw_n, String(owner_pid)])
	context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": draw_n,
		"player_id": owner_pid, "reason": &"pilot_020_draw"
	})
	return false


## 莽克 pilot_085 效果1 弃装获金（LISTEN DISCARD_SETTLE）。
## 按本次弃置动作快照统计「原先正面设置在机甲上」的装备牌：
##   原先属于莽克所在机甲(from_mech_id==bind.mech_id) → 每张+4金；其他机甲 → 每张+3金。
## 每张都发、累加后一次通用获金（ga.gain_gold，自动 fire GAIN_GOLD_AFTER 供维罗妮卡等监听）。
func _pilot_085_discard_gold(effect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var bind: Dictionary = payload.get("binding_context", {})
	var owner_pid: StringName = bind.get("player_id", &"")
	var mech_id: StringName = bind.get("mech_id", &"")
	if owner_pid == &"" or mech_id == &"":
		return false
	var snapshots: Array = payload.get("discard_snapshots", [])
	var self_count: int = 0
	var other_count: int = 0
	for snap in snapshots:
		if not (snap is Dictionary):
			continue
		# 只计「原先正面设置在机甲上」的装备牌（from_zone==equipment_slot 且非 face_down）。
		# 手上未设置(from_zone=equipment_hand)/临时区(temp_zone)/备用区背面(face_down)不计。
		if String(snap.get("card_kind", &"")) != "equipment":
			continue
		if String(snap.get("from_zone", &"")) != "equipment_slot":
			continue
		var from_mech: StringName = StringName(snap.get("from_mech_id", &""))
		if from_mech == &"":
			continue
		if bool(snap.get("face_down", false)):
			continue
		if from_mech == mech_id:
			self_count += 1
		else:
			other_count += 1
	var total_gold: int = self_count * 4 + other_count * 3
	if total_gold <= 0:
		return false
	SLog.log_raw("[pilot_085] 莽克装弃获金 +%d (自%d*4 + 他%d*3) player=%s mech=%s" % [total_gold, self_count, other_count, String(owner_pid), String(mech_id)])
	if context.game_actions != null:
		context.game_actions.gain_gold({
			"player_id": owner_pid,
			"amount": total_gold,
			"source_card_id": bind.get("card_instance_id", &""),
			"reason": &"pilot_085_discard_gold",
		})
	return false


## 獠鼠 pilot_086 效果1 攻击骰子分支（LISTEN ATTACK_PRE，priority 40）。
## 「指定目标发动攻击时，可以投掷1个骰子：1：我方机甲设置2损伤；2~3：我方抽2张行动牌；
##  4~5：弃置目标2张行动牌；6：对目标施加锁定效果。」
## 首次：弹「发动/取消」二选一确认窗挂起（_pending_effect phase=pilot_086_confirm，
## choose_one_effect options=[发动/取消]，source_label=效果说明）；AI 自动确认直接掷骰。
## 取消=不发动（不耗资源，恢复动作继续后续步骤）。返回 true=已挂起（应 return）。
func _pilot_086_dice_branch(effect: ActionEffect, payload: Dictionary, action) -> bool:
	if context == null or context.game_state == null:
		return false
	var p86_bind: Dictionary = payload.get("binding_context", {})
	var p86_owner_pid: StringName = p86_bind.get("player_id", &"")
	var p86_owner_mid: StringName = p86_bind.get("mech_id", &"")
	# 防御：无归属（机师未设置/离场）则不弹窗不发动
	if p86_owner_pid == &"" or p86_owner_mid == &"":
		return false
	if _is_ai_owner(p86_owner_pid, p86_owner_mid):
		# AI：暂不处理 AI 确认弹窗逻辑，直接跳过（用户明确 PvP/PvP3 人类玩家优先）
		SLog.log_raw("[TIMING] %s 獠鼠为 AI 持有者，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_086_confirm"}
	action.record["_pilot_086_confirm_shown"] = true
	action.state = &"waiting_timing"
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [
			{"label": "发动", "effect_id": &"option_0", "option_index": 0},
			{"label": "取消", "effect_id": &"option_1", "option_index": 1},
		],
		"player_id": _effect_popup_owner_pid(effect, payload, action),
		"source_label": String(effect.description),
	})
	SLog.log_raw("[TIMING] %s 挂起獠鼠骰子确认 effect=%s player=%s mech=%s" % [String(action.action_id), String(effect.effect_id), String(p86_owner_pid), String(p86_owner_mid)])
	return true


## 獠鼠骰子确认后掷骰+分支。构建 _seq 动作链串行执行（原子动作同步完成；含挂起子动作
## ——EXECUTE_DAMAGE_CHANGE 弹放置损伤UI / FOR_EACH_TARGET 内嵌弃牌选框——由
## _continue_seq_effect_actions 挂起等待，ActionEngine._after_sub_action_finished 续跑）。
func _pilot_086_confirm_resume(effect: ActionEffect, payload: Dictionary, action) -> void:
	if context == null or context.game_state == null:
		return
	var p86_dice: int = int(payload.get("pilot_086_forced_dice", 0))
	if p86_dice < 1 or p86_dice > 6:
		# 确定性 hash 派生（瑟尔基尔/征服同款修复模式）：种子=施法者机师牌实例id+回合数*97+action_id。
		# 不依赖 context.rng 消耗序列（PvP/PvP3 各端 rng 一旦分叉即永久分叉）；action_id 参与
		# 保证同一回合多次发动骰子不同。pilot_086_forced_dice 注入后门保留（测试用）。
		var p86_bc: Dictionary = payload.get("binding_context", {})
		var p86_seed: int = abs(int(String(p86_bc.get("card_instance_id", "")).hash()) \
			+ int(context.game_state.turn_number) * 97 \
			+ int(String(action.action_id).hash()))
		p86_dice = p86_seed % 6 + 1
	payload["pilot_086_dice"] = p86_dice
	SLog.log_raw("[TIMING] %s 獠鼠骰子=%d effect=%s" % [String(action.action_id), p86_dice, String(effect.effect_id)])
	var p86_bind: Dictionary = payload.get("binding_context", {})
	var p86_owner_pid: StringName = p86_bind.get("player_id", &"")
	var p86_owner_mid: StringName = p86_bind.get("mech_id", &"")
	var p86_branch: Array = []
	if p86_dice == 1:
		# 1：我方机甲设置2损伤（逐点弹放置UI，executor=我方）
		p86_branch.append({"type": &"EXECUTE_DAMAGE_CHANGE", "params": {
			"mech_ids": [p86_owner_mid],
			"value": 2,
			"method": &"increase",
			"executor": p86_owner_pid,
			"source_label": String(effect.description),
			"reason": &"pilot_086_dice_1",
		}})
	elif p86_dice == 2 or p86_dice == 3:
		# 2~3：我方抽2张行动牌（走 GAIN_CARD 时点）
		p86_branch.append({"type": &"EXECUTE_GAIN_CARD", "params": {
			"from_zone": &"action_deck",
			"card_kind": &"action",
			"count": 2,
			"player_id": p86_owner_pid,
			"mech_ids": [p86_owner_mid],
			"reason": &"pilot_086_dice_2_3",
		}})
	elif p86_dice == 4 or p86_dice == 5:
		# 4~5：弃置目标2张行动牌。多目标按目标顺序逐目标迭代；目标行动牌≤2 直接弃不弹窗
		# （auto_discard_all_if_covered），>2 逐目标弹未知选框（face_up=false）。
		p86_branch.append({"type": &"FOR_EACH_TARGET", "params": {
			"targets": "$payload.target_ids",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"EXECUTE_DISCARD", "params": {
					"from_target": true,
					"target_id": "$current_target.mech_id",
					"count": 2,
					"choose": true,
					"face_up": false,
					"auto_discard_all_if_covered": true,
					"reason": &"pilot_086_dice_4_5",
				}},
			],
		}})
	else:
		# 6：对攻击所有目标施加锁定（预判样式 duration=1，skip_clear_on_hit=false：本攻击命中即清除）
		p86_branch.append({"type": &"FOR_EACH_TARGET", "params": {
			"targets": "$payload.target_ids",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"APPLY_OR_CHECK_LOCKED", "params": {
					"mode": &"apply",
					"duration": 1,
					"skip_clear_on_hit": false,
					"target_id": "$current_target.mech_id",
					"source_player_id": "$binding_context.player_id",
					"source_card_id": "$binding_context.card_instance_id",
				}},
			],
		}})
	# 标记完成防重跑（dispatch 读 record/payload 双保险）
	action.record["_pilot_086_done"] = true
	payload["_pilot_086_done"] = true
	action.record.erase("_pilot_086_confirm_shown")
	action.record["_seq_effect_actions"] = {"payload": payload, "remaining": p86_branch, "source_check": false, "effect": effect, "branch_seq": true}
	action.state = &"waiting_effect_action"
	if _continue_seq_effect_actions(action):
		return
	# 分支全部同步完成：恢复父动作推进
	if context.action_engine != null:
		action.state = &"waiting_input"
		context.action_engine.continue_action(action.action_id, {})


## 效果1 完成：EXECUTE_DISCARD 子动作完成后手动 mark once_per_turn + 恢复父动作。
## 由 ActionEngine._after_sub_action_finished 钩子调用（子动作挂起路径）；同步完成路径直接调用。
func _continue_pilot_020_active(parent_action) -> bool:
	if parent_action == null or not parent_action.record.has("_pilot_020_active_pending"):
		return false
	var pend: Dictionary = parent_action.record["_pilot_020_active_pending"]
	parent_action.record.erase("_pilot_020_active_pending")
	var effect: ActionEffect = pend.get("effect")
	var payload: Dictionary = pend.get("payload", {})
	if effect != null:
		_mark_once_per_turn_used(effect, payload)
		if effect.once_per_game_key != &"":
			_mark_once_per_game_used(effect, payload)
		effect_executed.emit(effect.effect_id, parent_action.action_id)
		_mark_effect_executed(effect.effect_id, parent_action.action_id)
	SLog.log_raw("[TIMING] %s pilot_020 弃任意行动牌 完成 effect=%s" % [String(parent_action.action_id), String(effect.effect_id) if effect != null else "?"])
	if context != null and context.action_engine != null:
		parent_action.state = &"waiting_input"
		context.action_engine.continue_action(parent_action.action_id, {})
	return true


## 中止：清状态 + 恢复父动作（不消耗 once_per_turn）。
## 从 _pilot_020_begin_active_discard 防御失败路径经 call_deferred 调用（避免 _execute_effect 末尾误 mark）；
## 从 resume_pending_effect 取消路径同步调用（此时 _pending_effect 已 pop，无 mark 风险）。
func _pilot_020_abort_resume(action_id: StringName) -> void:
	_pending_effect.erase(action_id)
	if context == null or context.action_engine == null:
		return
	var action = context.action_registry.get_action(action_id) if context.action_registry != null else null
	if action == null:
		return
	action.record.erase("_pilot_020_active_pending")
	action.state = &"waiting_input"
	context.action_engine.continue_action(action_id, {})


## 串行续跑：上一个效果子动作完成/取消后，创建下一个待执行的效果子动作。
## 由 ActionEngine._after_sub_action_finished 在父动作所有子动作结束时调用。
## 返回 true 表示创建了新的未完成子动作（父动作继续等待）；false 表示无更多动作（父动作可推进）。

## 处理 CHOOSE_MAP_CELL（通用单格选格）。返回 true=已挂起(应return)；false=已处理/无可用格(continue)。
## 人类：挂起 select_map_cell 选格 UI（标绿+点击）；AI：自动选第一格。
## 选中格 id 由 resume_pending_effect 注入 payload（store_result_key 或默认 selected_cell_id），
## 后续动作经 $payload.<key> / $runtime.<key> 读取。
## 顶层 _execute_actions 与 CHOOSE_ONE 分支循环共用本方法（分支内 execute_sub_action 无法处理 CHOOSE_*）。
##
## 两种候选格来源：
##   · 无 params.cells（legacy 机雷设陷）：武器有效范围内可放陷阱格（get_valid_trap_cells）。
##   · params.cells 通用源（效果绑定不绑机师，格雷厄姆 pilot_057 等）：
##     - {"markers": {"type": &"TRAP", "range": 4}}：源机甲 hex 距离 range 内含该类型标记的格子
##       （复用 ConditionChecker.get_marker_cells_in_range）。
##     - {"circle": {"center": "$runtime.key", "radius": 8}}
##       或 {"circle": {"center": "$runtime.key", "per_count_key": "$runtime.ids", "per": 4}}：
##       以 center（"q,r" 字符串，支持 $ 引用）为圆心的 hex 距离圆；radius 或
##       per×len(per_count_key 解析数组) 定半径；排除红格（RED）与圆心本身，
##       含有机甲/其他标记的格子照常可选（由调用方语义决定后果）。
## params.store_result_key：选中格存 payload[key]（支持同链多次选格互不覆盖）；
## params.no_cancel：透传 UI 隐藏取消按钮（弃牌已付出的后续阶段用）。
func _handle_choose_map_cell(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	var cmc_params: Dictionary = act.get("params", {})
	var cmc_store_key: StringName = cmc_params.get("store_result_key", &"")
	var cmc_skip_key: String = String(cmc_store_key) if cmc_store_key != &"" else "selected_cell_id"
	if payload.has(cmc_skip_key):
		return false  # resume 重跑时已选格：跳过（后续动作读 $payload.<store_key>）
	var cmc_cells_spec: Dictionary = cmc_params.get("cells", {})
	var cmc_valid: Array[Dictionary] = []
	var cmc_mech_id: StringName = &""
	if cmc_cells_spec.is_empty():
		# legacy 机雷设陷：武器范围可放陷阱格
		var cmc_bind: Dictionary = payload.get("binding_context", {})
		var cmc_card_id: StringName = cmc_bind.get("card_instance_id", payload.get("card_instance_id", &""))
		cmc_mech_id = cmc_bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
		if cmc_card_id == &"" or cmc_mech_id == &"" or context == null or context.game_state == null:
			return false
		cmc_valid = _ConditionChecker.get_valid_trap_cells(context.game_state, cmc_card_id, cmc_mech_id, context.map_service.get_attack_aura_cells(), context.map_service.get_attack_blocked_keys(cmc_mech_id))
	else:
		var cmc_bind2: Dictionary = payload.get("binding_context", {})
		cmc_mech_id = payload.get("source_mech_id", cmc_bind2.get("mech_id", payload.get("mech_id", &"")))
		if context == null or context.game_state == null:
			return false
		var cmc_markers_spec: Dictionary = cmc_cells_spec.get("markers", {})
		var cmc_circle_spec: Dictionary = cmc_cells_spec.get("circle", {})
		var cmc_path_spec: Dictionary = cmc_cells_spec.get("path", {})
		if not cmc_markers_spec.is_empty():
			# 标记格源：源机甲 range 内含指定类型标记的格子（min_distance=1 仅严格相邻，
			# 墨尘 pilot_080「相邻格子上的标记」不含自身格）
			var cmc_src_mech = context.game_state.mechs.get(cmc_mech_id) if cmc_mech_id != &"" else null
			if cmc_src_mech == null:
				return false
			cmc_valid = _ConditionChecker.get_marker_cells_in_range(
				context.game_state, cmc_src_mech.position,
				cmc_markers_spec.get("type", &"TRAP"), int(cmc_markers_spec.get("range", 4)),
				int(cmc_markers_spec.get("min_distance", 0)))
		elif not cmc_circle_spec.is_empty() or not cmc_path_spec.is_empty():
			# 范围圆源（circle）或 路径式移动源（path）：center/半径(预算) 解析共用
			var ccb = _resolve_map_cell_center_and_budget(
				cmc_path_spec if not cmc_path_spec.is_empty() else cmc_circle_spec, payload, action)
			if ccb == null:
				return false
			var ccb_d: Dictionary = ccb
			var ccb_center: Dictionary = ccb_d.get("center", {})
			var ccb_budget: int = int(ccb_d.get("budget", 0))
			if not cmc_path_spec.is_empty():
				# 路径式移动源：从 center 出发 BFS 连续移动，预算=格数（红格排除）。
				# 绿格消耗由 spec.green_cost 决定（默认2=同普通移动；1=与普通格一视同仁）。
				# 机甲所在格可作终点（陷阱移入即触发/引爆）但不可穿过（不构成连续移动的
				# 中途经条件，blocked_by_mechs=false 可关）。通用件，不绑机师（格雷厄姆移陷）。
				var pm_blocked: Dictionary = {}
				if bool(cmc_path_spec.get("blocked_by_mechs", true)):
					for pm_mid: StringName in context.game_state.mechs:
						var pm_mech = context.game_state.mechs[pm_mid]
						if pm_mech != null and not pm_mech.destroyed:
							pm_blocked[_HexGrid.key(pm_mech.position)] = true
				var pm_green_cost: int = int(cmc_path_spec.get("green_cost", 2))
				for hx: Dictionary in _RangeCalculator.get_path_move_hexes(
						ccb_center, ccb_budget, context.game_state.map_state.cells, pm_blocked, pm_green_cost):
					var hx_id: String = "%d,%d" % [int(hx.get("q", 0)), int(hx.get("r", 0))]
					cmc_valid.append({"q": int(hx.get("q", 0)), "r": int(hx.get("r", 0)), "cell_id": hx_id})
			else:
				for hx: Dictionary in _RangeCalculator.get_skill_range_hexes(
						ccb_center, ccb_budget, context.game_state.map_state.cells):
					var hx_id: String = "%d,%d" % [int(hx.get("q", 0)), int(hx.get("r", 0))]
					var hx_cell = context.game_state.map_state.cells.get(StringName(hx_id))
					# 红格（RED）不可承载陷阱：圆内排除
					if hx_cell != null and hx_cell.terrain == &"RED":
						continue
					cmc_valid.append({"q": int(hx.get("q", 0)), "r": int(hx.get("r", 0)), "cell_id": hx_id})
		else:
			return false  # 未知 cells 源
	if cmc_valid.is_empty():
		SLog.log_raw("[TIMING] %s CHOOSE_MAP_CELL 无可选格，跳过 effect=%s" % [String(action.action_id), String(effect.effect_id)])
		return false
	var cmc_owner_pid: StringName = _effect_popup_owner_pid(effect, payload, action)
	if _is_ai_owner(cmc_owner_pid, cmc_mech_id):
		if cmc_store_key != &"":
			payload[cmc_store_key] = String(cmc_valid[0].get("cell_id", &""))
		else:
			payload["selected_cell_id"] = String(cmc_valid[0].get("cell_id", &""))
		return false
	_pending_effect[action.action_id] = {
		"action": action, "effect": effect, "payload": payload,
		"phase": &"map_cell_select", "map_cell_store_key": cmc_store_key,
	}
	action.record["_waiting_for_map_cell"] = true
	action.state = &"waiting_timing"
	var cmc_cells: Array = []
	for c in cmc_valid:
		cmc_cells.append({"q": int(c.get("q", 0)), "r": int(c.get("r", 0)), "cell_id": String(c.get("cell_id", ""))})
	action_needs_input.emit(action.action_id, &"select_map_cell", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"valid_cells": cmc_cells,
		"count": 1,
		"mech_id": cmc_mech_id,
		"card_instance_id": payload.get("binding_context", {}).get("card_instance_id", payload.get("card_instance_id", &"")),
		"label": String(cmc_params.get("label", "选择格子")),
		"player_id": cmc_owner_pid,
		"no_cancel": bool(cmc_params.get("no_cancel", false)),
	})
	SLog.log_raw("[TIMING] %s 挂起选格 effect=%s 候选=%d" % [String(action.action_id), String(effect.effect_id), cmc_valid.size()])
	return true


## 解析 CHOOSE_MAP_CELL circle/path 源的 center 与「半径/预算」：
## center 支持 "$runtime.x"/"$payload.x"/字面 "q,r"；半径 = 字面 radius 或
## per × len(per_count_key 解析数组)（如弃N张×4格叠加）。失败返回 null。
func _resolve_map_cell_center_and_budget(spec: Dictionary, payload: Dictionary, action) -> Variant:
	var ccb_center_raw: Variant = spec.get("center", "")
	var ccb_center: String = String(ccb_center_raw)
	if ccb_center.begins_with("$"):
		var ccb_resolved = _resolve_center_ref(ccb_center, payload, action)
		if ccb_resolved == null:
			return null
		ccb_center = String(ccb_resolved)
	var ccb_parts := ccb_center.split(",")
	if ccb_parts.size() != 2:
		return null
	var ccb_budget: int = int(spec.get("radius", 0))
	var ccb_per_key: String = String(spec.get("per_count_key", ""))
	if ccb_budget <= 0 and ccb_per_key != "":
		var ccb_count_resolved = _resolve_center_ref(ccb_per_key, payload, action)
		var ccb_count: int = 0
		if typeof(ccb_count_resolved) == TYPE_ARRAY:
			ccb_count = (ccb_count_resolved as Array).size()
		elif typeof(ccb_count_resolved) == TYPE_INT or typeof(ccb_count_resolved) == TYPE_FLOAT:
			ccb_count = int(ccb_count_resolved)
		ccb_budget = int(spec.get("per", 1)) * ccb_count
	if ccb_budget <= 0:
		return null
	return {"center": {"q": int(ccb_parts[0]), "r": int(ccb_parts[1])}, "budget": ccb_budget}


## 解析 CHOOSE_MAP_CELL circle 源的 "$runtime.x"/"$payload.x" 引用（返回原值；失败 null）。
func _resolve_center_ref(ref: String, payload: Dictionary, action):
	if context == null or context.action_service == null:
		return null
	return context.action_service._resolve_atomic_value(ref, payload, action)


## 处理 CHOOSE_MANY_MAP_CELLS（双子机雷设陷多格选格，单次挂起收集 N 格）。返回 true=已挂起。
## 玩家逐格点击（已选格从高亮移除->不可再选）；收集满 count 格后 ui_confirmed selected_cell_ids(数组)。
## 后续 PLACE_OR_TRIGGER_TRAP(place_each) 读 $payload.selected_cell_ids。
func _handle_choose_many_map_cells(act: Dictionary, effect, payload: Dictionary, action) -> bool:
	if payload.has("selected_cell_ids"):
		return false  # resume 重跑时已选格：跳过（后续 PLACE_OR_TRIGGER_TRAP place_each 读 $payload.selected_cell_ids）
	var mmc_params: Dictionary = act.get("params", {})
	var mmc_count: int = int(mmc_params.get("count", 1))
	var mmc_bind: Dictionary = payload.get("binding_context", {})
	var mmc_card_id: StringName = mmc_bind.get("card_instance_id", payload.get("card_instance_id", &""))
	var mmc_mech_id: StringName = mmc_bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	if mmc_card_id == &"" or mmc_mech_id == &"" or context == null or context.game_state == null:
		return false
	var mmc_valid: Array[Dictionary] = _ConditionChecker.get_valid_trap_cells(context.game_state, mmc_card_id, mmc_mech_id, context.map_service.get_attack_aura_cells(), context.map_service.get_attack_blocked_keys(mmc_mech_id))
	if mmc_valid.size() < mmc_count:
		SLog.log_raw("[TIMING] %s CHOOSE_MANY_MAP_CELLS 可放陷阱格不足%d，跳过 effect=%s" % [String(action.action_id), mmc_count, String(effect.effect_id)])
		return false
	var mmc_owner_pid: StringName = _effect_popup_owner_pid(effect, payload, action)
	if _is_ai_owner(mmc_owner_pid, mmc_mech_id):
		var ai_ids: Array = []
		for i in range(mmc_count):
			ai_ids.append(String(mmc_valid[i].get("cell_id", &"")))
		payload["selected_cell_ids"] = ai_ids
		return false
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pre_actions_target"}
	action.record["_waiting_for_map_cell"] = true
	action.state = &"waiting_timing"
	var mmc_cells: Array = []
	for c in mmc_valid:
		mmc_cells.append({"q": int(c.get("q", 0)), "r": int(c.get("r", 0)), "cell_id": String(c.get("cell_id", ""))})
	action_needs_input.emit(action.action_id, &"select_map_cell", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"valid_cells": mmc_cells,
		"count": mmc_count,
		"mech_id": mmc_mech_id,
		"card_instance_id": mmc_card_id,
		"label": String(mmc_params.get("label", "选择%d个格子设置陷阱" % mmc_count)),
		"player_id": mmc_owner_pid,
	})
	SLog.log_raw("[TIMING] %s 挂起多格陷阱选格 effect=%s 候选=%d 需%d" % [String(action.action_id), String(effect.effect_id), mmc_valid.size(), mmc_count])
	return true

## 解析 FOR_EACH_TARGET 的 targets 参数（$selected_targets -> Array[{"mech_id":...}]）为 mech_id 数组。
func _resolve_fet_targets(targets_raw, payload: Dictionary, action) -> Array:
	var resolved = targets_raw
	if typeof(targets_raw) == TYPE_STRING and String(targets_raw).begins_with("$"):
		if context != null and context.action_service != null:
			resolved = context.action_service._resolve_atomic_value(targets_raw, payload, action)
	if resolved == null:
		return []
	var result: Array = []
	if typeof(resolved) == TYPE_ARRAY:
		for item in resolved:
			if item is Dictionary:
				result.append(item.get("mech_id", &""))
			else:
				result.append(item)
	elif resolved is Dictionary and resolved.has("range"):
		# 范围扫描目标源（肯兹尔 pilot_045 弃牌等通用需求）：收集距源机甲 range 内所有存活机甲，
		# 不分敌我。源机甲取 payload.source_mech_id 或 binding_context.mech_id；include_self=false
		# 排除自己。仿 _prompt_choose_many_mechs 的候选收集逻辑（_HexGrid.distance 轴向距离）。
		var rs_range: int = int(resolved.get("range", 1))
		var rs_include_self: bool = bool(resolved.get("include_self", false))
		var rs_src_mid: StringName = payload.get("source_mech_id", &"")
		if rs_src_mid == &"" and payload.has("binding_context"):
			var rs_bc: Dictionary = payload.get("binding_context", {})
			rs_src_mid = rs_bc.get("mech_id", &"")
		if rs_src_mid != &"" and context != null and context.game_state != null:
			var rs_src = context.game_state.mechs.get(rs_src_mid)
			if rs_src != null:
				for rs_mid: StringName in context.game_state.mechs:
					if rs_mid == rs_src_mid and not rs_include_self:
						continue
					var rs_m = context.game_state.mechs[rs_mid]
					if rs_m == null or rs_m.destroyed:
						continue
					if _HexGrid.distance(rs_src.position, rs_m.position) <= rs_range:
						result.append(rs_mid)
	elif resolved is Dictionary:
		for mid in resolved.get("mech_ids", []):
			result.append(mid)
	return result


## 把 FOR_EACH_TARGET 的 targets × inner_actions 展开为 flat 列表 [{action, target_id, var_name}]。
## CONDITIONAL_ACTIONS 按当前 target 评估条件取 if_true/if_false 分支（分支内动作须为 leaf）。
func _build_for_each_flat(targets: Array, inner_actions: Array, var_name: StringName, effect, payload: Dictionary, action) -> Array:
	var flat: Array = []
	var bind = _make_binding_from_effect(effect, action, payload)
	for t in targets:
		var t_sn: StringName = StringName(t) if t != null else &""
		if t_sn == &"":
			continue
		payload[String(var_name)] = {"mech_id": t_sn}
		for act in inner_actions:
			if act is Dictionary and act.get("type", &"") == &"CONDITIONAL_ACTIONS":
				var ca_params: Dictionary = act.get("params", {})
				var ca_conds: Array = ca_params.get("conditions", [])
				var branch: Array = ca_params.get("if_false_actions", [])
				if ca_conds.is_empty() or _ConditionChecker.check_all(bind, payload, ca_conds):
					branch = ca_params.get("if_true_actions", [])
				for ba in branch:
					flat.append({"action": ba, "target_id": t_sn, "var_name": var_name})
			else:
				flat.append({"action": act, "target_id": t_sn, "var_name": var_name})
	return flat


## FOR_EACH_TARGET 内嵌 CHOOSE_ONE 逐目标串行弹窗（pilot_012 e2 命中奖励）。
## per-target chosen/executed 标记避免 resume 重跑 _execute_effect 时重复弹窗/重复执行：
##   - chosen_d[tgt]>=0：玩家选了该 target 的 option -> 执行 branch -> exec_d[tgt]=true
##   - chosen_d[tgt]==-1：玩家取消该 target -> 跳过 -> exec_d[tgt]=true
##   - chosen_d 无 tgt：未选 -> 挂起弹窗（_pending_effect + waiting_timing）
## 返回：&"pass"（非 CHOOSE_ONE，调用方走 execute_sub_action）/ &"next"（已处理，i++）/ &"pause"（挂起，存 _seq+return）
func _flat_item_choose_one(item: Dictionary, effect, payload: Dictionary, action) -> StringName:
	var item_action: Dictionary = item.get("action", {})
	if item_action.get("type", &"") != &"CHOOSE_ONE":
		return &"pass"
	var fet_tgt: StringName = item.get("target_id", &"")
	var exec_d: Dictionary = action.record.get("_fet_choose_executed", {})
	if bool(exec_d.get(fet_tgt, false)):
		return &"next"  # 已处理（执行或取消），跳过
	var chosen_d: Dictionary = action.record.get("_fet_choose_chosen", {})
	if chosen_d.has(fet_tgt):
		var cidx: int = int(chosen_d[fet_tgt])
		if cidx >= 0:
			# 已选：执行该 option 的 branch actions（DRAW_ACTION/RESTORE_POWER 等原子，同步完成）
			var co_p: Dictionary = item_action.get("params", {})
			var opts: Array = co_p.get("options", [])
			if cidx < opts.size():
				var branch_acts: Array = opts[cidx].get("actions", [])
				for ba in branch_acts:
					if context != null and context.action_service != null:
						context.action_service.execute_sub_action(ba, payload, action)
					if _last_created_sub_action_paused(action):
						return &"pause"  # branch 子动作挂起（调用方存 _seq 续跑）
		# cidx>=0 执行完 or cidx==-1 取消：标记已处理
		exec_d[fet_tgt] = true
		action.record["_fet_choose_executed"] = exec_d
		return &"next"
	# 未选：挂起弹窗
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "pre_actions_target"}
	action.record["_waiting_for_choose_one"] = true
	action.record["_choose_one_effect_id"] = effect.effect_id
	var co_params: Dictionary = item_action.get("params", {})
	var opts2: Array = co_params.get("options", [])
	var ui_opts: Array[Dictionary] = []
	for oi in range(opts2.size()):
		var opt_d: Dictionary = opts2[oi] if opts2[oi] is Dictionary else {}
		ui_opts.append({"label": String(opt_d.get("label", "选项%d" % (oi + 1))), "effect_id": StringName("option_%d" % oi), "option_index": oi})
	action.state = &"waiting_timing"
	var co_pid: StringName = _effect_popup_owner_pid(effect, payload, action)
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id, "effect_id": effect.effect_id,
		"options": ui_opts, "optional": bool(co_params.get("optional", false)), "player_id": co_pid,
	})
	SLog.log_raw("[TIMING] %s FOR_EACH_TARGET inner CHOOSE_ONE 挂起 effect=%s target=%s" % [String(action.action_id), String(effect.effect_id), String(fet_tgt)])
	return &"pause"


## FOR_EACH_TARGET 内嵌 CHOOSE_MANY_CARDS 逐目标弹窗（泰格 pilot_040 弃装解锁）。
## 与 inner CHOOSE_ONE 同模式：per-target executed 标记（_fet_cm_executed）避免 resume 重跑时
## 重复弹窗/重复执行。_prompt_choose_many_cards 无候选 / AI 持有者返回 false -> 标记已处理跳过
## （锁保留，不弹窗）。返回同 _flat_item_choose_one：&"pass"（非 CM）/ &"next"（已处理）/ &"pause"。
func _flat_item_choose_many_cards(item: Dictionary, effect, payload: Dictionary, action) -> StringName:
	var item_action: Dictionary = item.get("action", {})
	if item_action.get("type", &"") != &"CHOOSE_MANY_CARDS":
		return &"pass"
	if effect == null:
		return &"pass"  # 防御：旧 _seq 无 effect 引用时走 execute_sub_action（无工厂静默失败）
	var fet_tgt: StringName = item.get("target_id", &"")
	var exec_d: Dictionary = action.record.get("_fet_cm_executed", {})
	if bool(exec_d.get(fet_tgt, false)):
		return &"next"  # 已处理（弃牌解锁或不弃置），跳过
	# 未处理：走标准多选弹窗。act_idx=-1 防止 resume 的 store 路径按 effect.actions 续跑
	# （flat 项不属于 effect.actions 顶层，续跑由 _seq_effect_actions 驱动）。
	if _prompt_choose_many_cards(effect, payload, action, item_action, -1):
		# 标记 flat 续跑信息：resume(phase=choose_many_cards) 据此标记 target 已处理并续跑 flat 剩余
		var pend: Dictionary = _pending_effect.get(action.action_id, {})
		pend["_flat_cm"] = true
		pend["_flat_cm_target"] = fet_tgt
		_pending_effect[action.action_id] = pend
		return &"pause"
	# 无候选（目标无正面装备）/ AI：视为已处理，锁保留不弹窗
	exec_d[fet_tgt] = true
	action.record["_fet_cm_executed"] = exec_d
	return &"next"


## 串行执行 flat 列表（FOR_EACH_TARGET 展开）。设 current_target 后 execute_sub_action；
## 子动作挂起则存 _seq(flat) 并返回 true。返回 false=全部完成。
func _run_flat_inline(flat: Array, start_idx: int, effect, payload: Dictionary, action, var_name: StringName) -> bool:
	var i: int = start_idx
	while i < flat.size():
		var item: Dictionary = flat[i]
		payload[String(item.get("var_name", var_name))] = {"mech_id": item.get("target_id", &"")}
		# inner CHOOSE_ONE（pilot_012 e2）：per-target 串行弹窗，走专用 helper
		var ci_ret: StringName = _flat_item_choose_one(item, effect, payload, action)
		if ci_ret == &"pause":
			var remaining_ci: Array = flat.slice(i + 1)
			if not remaining_ci.is_empty():
				action.record["_seq_effect_actions"] = {"payload": payload, "remaining": remaining_ci, "flat": true, "var_name": var_name, "effect": effect}
			action.state = &"waiting_effect_action"
			return true
		if ci_ret == &"next":
			i += 1
			continue
		# inner CHOOSE_MANY_CARDS（泰格 pilot_040 弃装解锁）：per-target 串行弹窗，走专用 helper
		var cm_ret: StringName = _flat_item_choose_many_cards(item, effect, payload, action)
		if cm_ret == &"pause":
			var remaining_cm: Array = flat.slice(i + 1)
			if not remaining_cm.is_empty():
				action.record["_seq_effect_actions"] = {"payload": payload, "remaining": remaining_cm, "flat": true, "var_name": var_name, "effect": effect}
			action.state = &"waiting_effect_action"
			return true
		if cm_ret == &"next":
			i += 1
			continue
		# pass：非 CHOOSE_ONE / CHOOSE_MANY_CARDS，走 execute_sub_action
		if context != null and context.action_service != null:
			context.action_service.execute_sub_action(item.get("action", {}), payload, action)
		if _last_created_sub_action_paused(action):
			var remaining: Array = flat.slice(i + 1)
			if not remaining.is_empty():
				action.record["_seq_effect_actions"] = {"payload": payload, "remaining": remaining, "flat": true, "var_name": var_name, "effect": effect}
			# 子动作挂起：父动作切 waiting_effect_action，等 ActionEngine._after_sub_action_finished
			# 调 _continue_seq_effect_actions 续跑剩余 flat（pilot_012 e1 EXECUTE_STEAL 选牌后继续 MODIFY_MECH_POWER）
			action.state = &"waiting_effect_action"
			return true
		i += 1
	return false


func _continue_seq_effect_actions(parent_action) -> bool:
	if parent_action == null or not parent_action.record.has("_seq_effect_actions"):
		return false
	var seq: Dictionary = parent_action.record["_seq_effect_actions"]
	var payload: Dictionary = seq.get("payload", {})
	var remaining: Array = seq.get("remaining", [])
	var is_flat: bool = bool(seq.get("flat", false))
	var flat_var: StringName = seq.get("var_name", &"current_target")
	while not remaining.is_empty():
		# Q3 守卫：来源装备牌离场则停止剩余（effect_035/039 自损致弃置后不减威力/损伤）
		if bool(seq.get("source_check", false)) and _source_equipment_discarded(payload):
			parent_action.record.erase("_seq_effect_actions")
			return false
		var act: Dictionary = remaining.pop_front()
		# 先回写 record（remaining 已 pop），供后续断点/取消路径读取一致状态（保留 source_check/flat 标记）
		parent_action.record["_seq_effect_actions"] = {"payload": payload, "remaining": remaining, "source_check": seq.get("source_check", false), "flat": is_flat, "var_name": flat_var, "branch_seq": bool(seq.get("branch_seq", false)), "effect": seq.get("effect")}
		var act_type: StringName = act.get("type", &"")
		# flat 模式（FOR_EACH_TARGET 展开）：item = {action, target_id, var_name}。
		# 设 current_target 后执行 item.action（item 本身无 type -> 走 flat 分支）。
		if is_flat and not act.has("type"):
			var fet_tgt: StringName = act.get("target_id", &"")
			payload[String(act.get("var_name", flat_var))] = {"mech_id": fet_tgt}
			# flat 内嵌 CHOOSE_MANY_CARDS（泰格弃装解锁）：逐目标弹窗，走专用 helper。
			# _seq 已在 pop 后 re-save（含当前 item 之后的 remaining），挂起时直接等 resume 续跑。
			var fcm_ret: StringName = _flat_item_choose_many_cards(act, seq.get("effect"), payload, parent_action)
			if fcm_ret == &"pause":
				parent_action.state = &"waiting_effect_action"
				return true
			if fcm_ret == &"next":
				continue
			if context != null and context.action_service != null:
				context.action_service.execute_sub_action(act.get("action", {}), payload, parent_action)
			if _last_created_sub_action_paused(parent_action):
				return true
			continue
		# CONDITIONAL_ACTIONS（顶层/序列）：按当前 payload 评估条件取 if_true/if_false 分支，
		# 拼接到 remaining 头部续跑。供 _seq 序列中分支动作（青瞳 pilot_037 偷牌挂起后 resume
		# 的剩余链含此动作）以及 _execute_actions 顶层 splice 的场景复用。
		if act_type == &"CONDITIONAL_ACTIONS":
			var seq_ca_params: Dictionary = act.get("params", {})
			var seq_ca_conds: Array = seq_ca_params.get("conditions", [])
			var seq_ca_branch: Array = seq_ca_params.get("if_false_actions", [])
			var seq_ca_bind = _make_binding_from_effect(null, parent_action, payload)
			if seq_ca_conds.is_empty() or _ConditionChecker.check_all(seq_ca_bind, payload, seq_ca_conds):
				seq_ca_branch = seq_ca_params.get("if_true_actions", [])
			remaining = seq_ca_branch + remaining
			parent_action.record["_seq_effect_actions"] = {"payload": payload, "remaining": remaining, "source_check": seq.get("source_check", false), "flat": is_flat, "var_name": flat_var, "branch_seq": bool(seq.get("branch_seq", false)), "effect": seq.get("effect")}
			continue
		# FOR_EACH_TARGET（_seq 序列中，如泰格 pilot_040 弃行动牌后对多目标施加锁+逐目标解锁弹窗）：
		# 顶层 _execute_actions / CHOOSE_ONE 分支都有特判，此处同样需要——execute_sub_action 无工厂会
		# 静默失败。展开为 flat 串行执行（内嵌 CHOOSE_MANY_CARDS 逐目标弹窗）。挂起时 flat _seq 已设
		# （_run_flat_inline 覆盖），把本 FET 之后的剩余动作追加到 flat _seq.remaining 末尾，
		# flat 全部完成后按普通动作续跑（泰格 ③锁 ④解锁 两段 FOR_EACH 串行）。
		if act_type == &"FOR_EACH_TARGET":
			var seq_fet_params: Dictionary = act.get("params", {})
			var seq_fet_targets: Array = _resolve_fet_targets(seq_fet_params.get("targets", &""), payload, parent_action)
			if seq_fet_targets.is_empty():
				continue
			var seq_fet_var: StringName = seq_fet_params.get("current_target_variable", &"current_target")
			var seq_fet_effect = seq.get("effect")
			var seq_fet_flat: Array = _build_for_each_flat(seq_fet_targets, seq_fet_params.get("actions", []), seq_fet_var, seq_fet_effect, payload, parent_action)
			if _run_flat_inline(seq_fet_flat, 0, seq_fet_effect, payload, parent_action, seq_fet_var):
				var seq_fet_after: Array = remaining
				if not seq_fet_after.is_empty() and parent_action.record.has("_seq_effect_actions"):
					var _sf_seq: Dictionary = parent_action.record["_seq_effect_actions"]
					var _sf_rem: Array = _sf_seq.get("remaining", [])
					_sf_rem.append_array(seq_fet_after)
					_sf_seq["remaining"] = _sf_rem
					_sf_seq["flat"] = true
					parent_action.record["_seq_effect_actions"] = _sf_seq
				return true
			continue
		# POWER_SPEND_TAX_CONTINUE：动力税伤害链尾哨兵（杰西卡 pilot_050 e1）。两次 hp_change
		# 完成后检查剩余询问次数：还有 -> 再弹确认窗（挂起）；没有 -> 清 ctx 结束。
		if act_type == &"POWER_SPEND_TAX_CONTINUE":
			var ptc_ctx: Dictionary = parent_action.record.get("_power_tax_ctx", {})
			ptc_ctx["prompts_left"] = int(ptc_ctx.get("prompts_left", 1)) - 1
			var ptc_left: int = int(ptc_ctx["prompts_left"])
			SLog.log_raw("[TIMING] %s 动力税伤害链完成（剩%d次询问）" % [String(parent_action.action_id), ptc_left])
			if ptc_left > 0:
				parent_action.record["_power_tax_ctx"] = ptc_ctx
				_power_tax_prompt_confirm(parent_action, payload, seq.get("effect"))
				return true
			parent_action.record.erase("_power_tax_ctx")
			continue
		# POWER_TAX_TRIBUTE_DISCARD_SIDE：动力税贡赋弃牌侧哨兵（杰西卡 pilot_050 e2）。
		# <=count 直接全选 EXECUTE_DISCARD（挂起检查由调用处 _last_created_sub_action_paused）；
		# >count 弹多选窗挂起（phase=power_tax_tribute_discard 由 resume 续跑）。
		if act_type == &"POWER_TAX_TRIBUTE_DISCARD_SIDE":
			var tds_side: StringName = act.get("params", {}).get("side", &"owner")
			if _power_tax_tribute_discard_side(parent_action, payload, seq.get("effect"), tds_side):
				return true
			continue
		# POWER_TAX_TRIBUTE_CLEANUP：动力税贡赋链尾清理（e2 全部完成）。
		if act_type == &"POWER_TAX_TRIBUTE_CLEANUP":
			parent_action.record.erase("_power_tax_tribute")
			continue
		# ATTACK_SETTLE_DRAW_REATTACK_AFTER_DRAW：抽牌完成后检查每回合1次可用+手牌足够，
		# 弹多选窗选 discard_count 张弃置（可取消不计次数；resume phase=attack_settle_draw_reattack_discard 续跑）。
		if act_type == &"ATTACK_SETTLE_DRAW_REATTACK_AFTER_DRAW":
			if _asdr_offer_discard(parent_action, payload, seq.get("effect")):
				return true
			continue
		# ATTACK_SETTLE_DRAW_REATTACK_OPEN_WINDOW：弃置完成后给攻击方开凯威攻击窗口（攻击动作完成后打开）。
		if act_type == &"ATTACK_SETTLE_DRAW_REATTACK_OPEN_WINDOW":
			_asdr_open_attack_window(parent_action, payload, seq.get("effect"))
			continue
		# CHOOSE_MAP_CELL（_seq 序列中，如格雷厄姆 pilot_057 e2 弃牌后的第二次选格）：
		# execute_sub_action 无工厂会静默失败，须走专用 helper 挂起选格 UI
		# （resume phase=map_cell_select 回到本序列续跑剩余链）。
		if act_type == &"CHOOSE_MAP_CELL":
			if _handle_choose_map_cell(act, seq.get("effect"), payload, parent_action):
				return true
			continue
		# CHOOSE_RESERVE_SLOT_AND_SET_EQUIP（通用「抽到的装备背面置备用区」，法尔科 pilot_073 等）：
		# execute_sub_action 无工厂会静默失败，须走专用 helper 读取抽牌 sink + 挂起备用区选择 UI
		# （复用 hidden_reserve_slot 弹窗，resume phase=choose_reserve_slot_and_set 回本序列续跑）。
		if act_type == &"CHOOSE_RESERVE_SLOT_AND_SET_EQUIP":
			if _handle_choose_reserve_slot_and_set(act, seq.get("effect"), payload, parent_action):
				return true
			continue
		# PEEK_DECK_SHOW（通用窥牌模块第2阶段哨兵，银雪 pilot_065）：代价牌弃置完成后由 _seq 续跑触发。
		# execute_sub_action 无工厂会静默失败，须走专用 helper 挂起堆顶多选窗（resume phase=peek_select_discard）。
		if act_type == &"PEEK_DECK_SHOW":
			if _handle_peek_deck_show(act, seq.get("effect"), payload, parent_action):
				return true
			continue
		# GAIN_GOLD_BY_DIE（事件牌宝藏 e011 等通用）：_seq 续跑同样拦截（首跑在 _execute_actions
		# 行 GAIN_GOLD_BY_DIE 分支处理；弃牌窗挂起恢复后续跑本序列时无工厂会静默失败 ->
		# 宝藏掷骰获金整链失效）。同步执行不挂起，continue 下一动作。
		if act_type == &"GAIN_GOLD_BY_DIE":
			_handle_gain_gold_by_die(act.get("params", {}), payload, parent_action)
			continue
		# DRAW_EQUIPMENT_AND_IMMEDIATELY_SET / DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL 伪动作：
		# _seq 恢复循环同样拦截（事件牌拾荒 e005 / 增援 e001 / 约书亚 pilot_025 等），
		# 否则 execute_sub_action 无注册工厂报"未注册的动作类型"静默失败
		# （PvP3 推进选格后 resume 续跑拾荒抽装备链的实机报错路径）。
		var _seq_deis_ret: StringName = _handle_draw_equipment_pseudo(act_type, act.get("params", {}), seq.get("effect"), payload, parent_action)
		if _seq_deis_ret == &"suspend":
			return true
		if _seq_deis_ret == &"skip":
			continue
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
	# 琳 RE 维修窗口：分支挂起续跑完成（如移除损伤面板）后关闭窗口并恢复请求方回合。
	# 窗口内维修的目标锁定标志 _pilot_024_window_locked 随 payload 存于 _seq，据此判断。
	if bool(payload.get("_pilot_024_window_locked", false)):
		_pilot_024_close_if_window_repair_done(null, payload, parent_action)
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
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": "repeat_continue", "repeat_params": rs_params}
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
	# $binding_context.mech_effective_armor 特殊：从 game_state 查机甲有效护甲（pilot_004 护甲转动力上限）
	if s.find("$binding_context.mech_effective_armor") >= 0:
		var mid_armor: StringName = bind_ctx.get("mech_id", &"")
		var armor_val: int = 0
		if mid_armor != &"" and context != null and context.game_state != null:
			var m_arm = context.game_state.mechs.get(mid_armor)
			if m_arm != null:
				armor_val = m_arm.get_armor()
		s = s.replace("$binding_context.mech_effective_armor", str(armor_val))
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


## 维修增强（通用机制 REPAIR_BOOST）：改写 repair_direct 二选一选项（深拷贝，不污染静态 effect）。
## - 含 method=decrease 的损伤移除选项：value += extra_removal（合并为一次移除，如 移除2→移除4）。
## - 其他选项（回复生命）：追加额外移除 extra_removal，带 TARGET_HAS_DAMAGE 条件（无损伤不生效，
##   否则 decrease 会对无损伤目标弹空移除框卡死）。坎得 pilot_023 等维修增强机师复用。
func _apply_repair_boost_options(options: Array, boost: Dictionary) -> Array:
	var extra: int = int(boost.get("extra_removal", 0))
	if extra <= 0:
		return options
	var result: Array = []
	for opt in options:
		if not (opt is Dictionary):
			result.append(opt)
			continue
		var opt_copy: Dictionary = opt.duplicate(true)
		var acts: Array = opt_copy.get("actions", [])
		var acts_out: Array = []
		var has_removal: bool = false
		for a in acts:
			if not (a is Dictionary):
				acts_out.append(a)
				continue
			var a_copy: Dictionary = a.duplicate(true)
			if a.get("type", &"") == &"EXECUTE_DAMAGE_CHANGE" and String(a.get("params", {}).get("method", &"increase")) == "decrease":
				a_copy["params"]["value"] = int(a.get("params", {}).get("value", 0)) + extra
				has_removal = true
			acts_out.append(a_copy)
		if not has_removal:
			acts_out.append({
				"type": &"EXECUTE_DAMAGE_CHANGE",
				"params": {"value": extra, "method": &"decrease"},
				"condition": [{"op": &"TARGET_HAS_DAMAGE"}],
			})
		opt_copy["actions"] = acts_out
		result.append(opt_copy)
	return result


# ════════════════════════════════════════════════════════════
# pilot_024 琳：RE 请求确认 / 维修后双方各抽2 / 维修窗口关闭
# ════════════════════════════════════════════════════════════

## 弹琳 RE 请求确认窗（choose_one_effect 单选项 + 请求方信息作来源说明）。
## 弹窗路由到琳玩家窗口；确认/取消由 resume_pending_effect phase=pilot_024_re_confirm 处理。
func _prompt_pilot_024_re_confirm(effect: ActionEffect, payload: Dictionary, action) -> void:
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_024_re_confirm"}
	action.record["_waiting_for_p024_re_confirm"] = true
	action.state = &"waiting_timing"
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var requester_mid: StringName = StringName(bind_ctx.get("mech_id", payload.get("mech_id", &"")))
	var lin_mid: StringName = _ActionPilotEffects.pilot_024_find_lin_mech(context.game_state)
	var lin_player: StringName = &""
	if lin_mid != &"":
		var lin_m = context.game_state.mechs.get(lin_mid)
		if lin_m != null:
			lin_player = lin_m.owner_player_id
	var desc: String = "请求维修"
	if requester_mid != &"":
		var r_m = context.game_state.mechs.get(requester_mid)
		if r_m != null:
			var r_player = context.game_state.players.get(r_m.owner_player_id) if context.game_state.players != null else null
			# PlayerState/MechFrameDef 是 RefCounted 对象（非 Dictionary）：.get() 只收1参，
			# 直接属性访问最稳。PlayerState 无 display_name 字段，用 player_id 作玩家名。
			var r_pname: String = String(r_player.player_id) if r_player != null else String(r_m.owner_player_id)
			var r_mname: String = String(r_m.frame_def.display_name) if r_m.frame_def != null else String(r_m.mech_id)
			desc = "【%s】的 %s（HP %d/%d，%s）请求维修" % [
				r_pname, r_mname, int(r_m.current_hp), int(r_m.max_hp), _pilot_024_damage_summary(r_m),
			]
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [{"label": "确认维修", "effect_id": &"option_0", "option_index": 0}],
		"optional": true,
		"player_id": lin_player,
		"source_label": desc,
	})
	SLog.log_raw("[TIMING] %s 琳 RE 请求确认弹窗 requester=%s" % [String(action.action_id), String(requester_mid)])


## 汀兰 pilot_081 RE 请求确认窗（choose_one_effect 单选项 + 请求方信息作来源说明）。
## 弹窗路由到汀兰持有者玩家（按 binding.card_instance_id 精确定位持有者，多汀兰可区分）；
## 同意/拒绝由 resume_pending_effect phase=pilot_081_re_confirm 处理。
func _prompt_pilot_081_re_confirm(effect: ActionEffect, payload: Dictionary, action) -> void:
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"pilot_081_re_confirm"}
	action.record["_waiting_for_p081_re_confirm"] = true
	action.state = &"waiting_timing"
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var requester_mid: StringName = StringName(bind_ctx.get("mech_id", payload.get("mech_id", &"")))
	var holder_inst: StringName = StringName(bind_ctx.get("card_instance_id", payload.get("card_instance_id", &"")))
	var holder_mid: StringName = _ActionPilotEffects.pilot_081_find_holder_for_pilot_instance(context.game_state, holder_inst)
	var holder_player: StringName = &""
	if holder_mid != &"":
		var h_m = context.game_state.mechs.get(holder_mid)
		if h_m != null:
			holder_player = h_m.owner_player_id
	var desc: String = "请求汀兰回复"
	if requester_mid != &"":
		var r_m = context.game_state.mechs.get(requester_mid)
		if r_m != null:
			var r_player = context.game_state.players.get(r_m.owner_player_id) if context.game_state.players != null else null
			# PlayerState/MechFrameDef 是 RefCounted 对象（非 Dictionary）：.get() 只收1参，
			# 直接属性访问最稳。PlayerState 无 display_name 字段，用 player_id 作玩家名。
			var r_pname: String = String(r_player.player_id) if r_player != null else String(r_m.owner_player_id)
			var r_mname: String = String(r_m.frame_def.display_name) if r_m.frame_def != null else String(r_m.mech_id)
			desc = "【%s】的 %s（HP %d/%d）请求汀兰回复2生命、获2金" % [
				r_pname, r_mname, int(r_m.current_hp), int(r_m.max_hp),
			]
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": [{"label": "同意回复", "effect_id": &"option_0", "option_index": 0}],
		"optional": true,
		"player_id": holder_player,
		"source_label": desc,
	})
	SLog.log_raw("[TIMING] %s 汀兰 RE 请求确认弹窗 requester=%s holder=%s" % [String(action.action_id), String(requester_mid), String(holder_mid)])


# ════════════════════════════════════════════════════════════
# pilot_083 瓦恩：武器修改两阶段流程（phase1 武器单选 → phase2 三横排选项 → 施加）
# ════════════════════════════════════════════════════════════

## 瓦恩武器修改流程启动：phase1 武器单选（choose_one_effect → choice_panel）。
## mode=owner：按钮1主动，武器=全场武器；mode=re：RE 请求，武器=请求方武器。
## 弹窗路由到瓦恩持有者玩家窗口（re 由 binding.card_instance_id 精确定位持有者）。
func _start_pilot_083_flow(effect: ActionEffect, payload: Dictionary, action) -> void:
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"p083_weapon_select"}
	action.record["_waiting_for_p083_weapon_select"] = true
	action.state = &"waiting_timing"
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var holder_inst: StringName = StringName(bind_ctx.get("card_instance_id", payload.get("card_instance_id", &"")))
	var mode: String = String(payload.get("_p083_mode", "owner"))
	var requester_mid: StringName = StringName(bind_ctx.get("mech_id", payload.get("mech_id", &"")))
	if requester_mid == &"":
		requester_mid = StringName(payload.get("source_mech_id", &""))
	var holder_mid: StringName = _ActionPilotEffects.pilot_083_find_holder_for_pilot_instance(context.game_state, holder_inst)
	var holder_player: StringName = &""
	if holder_mid != &"":
		var h_m = context.game_state.mechs.get(holder_mid)
		if h_m != null:
			holder_player = h_m.owner_player_id
	# 武器候选：owner=全场；re=请求方武器（含实体/虚拟/基础武器，基础武器键 "base:<mech_id>:<slot>"）
	var w_target_mech: StringName = &""
	if mode == &"re":
		w_target_mech = requester_mid
	var options: Array = _ActionPilotEffects.pilot_083_list_weapon_options(context.game_state, w_target_mech)
	# choice_panel 选项 effect_id 用作 weapon_key（"card:<instance_id>" / "base:<mech_id>:<slot>"），option_index 递增
	var typed_opts: Array[Dictionary] = []
	for o in options:
		if o is Dictionary:
			typed_opts.append({
				"label": String(o.get("label", "")),
				"effect_id": StringName(String(o.get("weapon_key", ""))),
				"option_index": typed_opts.size(),
				"mech_id": o.get("mech_id", &""),
				"slot_id": o.get("slot_id", &""),
				"is_virtual": bool(o.get("is_virtual", false)),
			})
	var desc: String = "瓦恩-武器修改：选择1把武器"
	if mode == &"re" and requester_mid != &"":
		var r_m = context.game_state.mechs.get(requester_mid)
		if r_m != null:
			var r_player = context.game_state.players.get(r_m.owner_player_id) if context.game_state.players != null else null
			var r_pname: String = String(r_player.player_id) if r_player != null else String(r_m.owner_player_id)
			var r_mname: String = String(r_m.frame_def.display_name) if r_m.frame_def != null else String(r_m.mech_id)
			desc = "【%s】的 %s（HP %d/%d）请求瓦恩对其武器使用武器修改：选择1把武器" % [
				r_pname, r_mname, int(r_m.current_hp), int(r_m.max_hp),
			]
	action_needs_input.emit(action.action_id, &"choose_one_effect", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"options": typed_opts,
		"optional": true,
		"player_id": holder_player,
		"source_label": desc,
	})
	SLog.log_raw("[TIMING] %s 瓦恩武器修改 phase1 武器选择 mode=%s requester=%s holder=%s" % [String(action.action_id), mode, String(requester_mid), String(holder_mid)])


## 瓦恩 phase2：选中武器后弹三横排选项面板（weapon_modify_options_panel）。
## 弹窗路由到瓦恩持有者玩家窗口；确认打包状态 / 取消由 resume_pending_effect phase=p083_options 处理。
func _prompt_pilot_083_options(effect: ActionEffect, payload: Dictionary, action) -> void:
	_pending_effect[action.action_id] = {"action": action, "effect": effect, "payload": payload, "phase": &"p083_options"}
	action.record["_waiting_for_p083_options"] = true
	action.state = &"waiting_timing"
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var holder_inst: StringName = StringName(bind_ctx.get("card_instance_id", payload.get("card_instance_id", &"")))
	var holder_mid: StringName = _ActionPilotEffects.pilot_083_find_holder_for_pilot_instance(context.game_state, holder_inst)
	var holder_player: StringName = &""
	if holder_mid != &"":
		var h_m = context.game_state.mechs.get(holder_mid)
		if h_m != null:
			holder_player = h_m.owner_player_id
	var weapon_name: String = _pilot_083_weapon_label(context.game_state, String(payload.get("_p083_weapon_key", "")))
	action_needs_input.emit(action.action_id, &"pilot_083_options", {
		"action_id": action.action_id,
		"effect_id": effect.effect_id,
		"player_id": holder_player,
		"weapon_name": weapon_name,
		"source_label": "瓦恩-武器修改",
	})
	SLog.log_raw("[TIMING] %s 瓦恩武器修改 phase2 三横排选项 weapon=%s" % [String(action.action_id), weapon_name])


## 瓦恩最终应用：把打包状态施加到所选武器 +（owner 模式）标记效果1每回合1次已用。
## 施加数据经 counters["pilot_083_apps"] 累积（数值叠加/名称后缀累积/类型最新覆盖）。
func _apply_pilot_083_flow(effect: ActionEffect, payload: Dictionary, action) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var holder_inst: StringName = StringName(bind_ctx.get("card_instance_id", payload.get("card_instance_id", &"")))
	var mode: String = String(payload.get("_p083_mode", "owner"))
	var weapon_key: String = String(payload.get("_p083_weapon_key", ""))
	var app: Dictionary = payload.get("_p083_options", {})
	var holder_mid: StringName = _ActionPilotEffects.pilot_083_find_holder_for_pilot_instance(context.game_state, holder_inst)
	var holder_player: StringName = &""
	if holder_mid != &"":
		var h_m = context.game_state.mechs.get(holder_mid)
		if h_m != null:
			holder_player = h_m.owner_player_id
	if weapon_key.begins_with("base:"):
		# 基础武器（无卡牌实例，施加存机甲 pilot_083_base_apps）：base:<mech_id>:<slot_index>
		var parts: PackedStringArray = weapon_key.substr(5).split(":")
		if parts.size() < 2:
			SLog.log_raw("[TIMING] %s 瓦恩武器修改非法基础武器键 weapon_key=%s，取消施加" % [String(action.action_id), weapon_key])
			_finish_pilot_083_flow(action, payload)
			return
		var b_mech = context.game_state.mechs.get(StringName(parts[0])) if context.game_state.mechs != null else null
		if b_mech == null:
			SLog.log_raw("[TIMING] %s 瓦恩武器修改找不到基础武器机甲 %s，取消施加" % [String(action.action_id), parts[0]])
			_finish_pilot_083_flow(action, payload)
			return
		_ActionPilotEffects.pilot_083_apply_to_base_weapon(b_mech, int(parts[1]), holder_player, int(context.game_state.turn_number), app)
		SLog.log_raw("[TIMING] %s 瓦恩武器修改施加(基础武器) weapon=%s app=%s mode=%s" % [String(action.action_id), weapon_key, str(app), mode])
	else:
		var card = _resolve_pilot_083_weapon_card(context.game_state, weapon_key)
		if card == null:
			SLog.log_raw("[TIMING] %s 瓦恩武器修改找不到武器卡 weapon_key=%s，取消施加" % [String(action.action_id), weapon_key])
			_finish_pilot_083_flow(action, payload)
			return
		_ActionPilotEffects.pilot_083_apply_to_weapon(card, holder_player, int(context.game_state.turn_number), app)
		SLog.log_raw("[TIMING] %s 瓦恩武器修改施加 weapon=%s app=%s mode=%s" % [String(action.action_id), weapon_key, str(app), mode])
	# owner 模式：标记效果1每回合1次已用（取消不计，仅在最终应用时标记）
	if mode == &"owner" and holder_inst != &"":
		mark_once_per_turn_key_used(&"pilot_083_effect_01", holder_inst)
	_finish_pilot_083_flow(action, payload)


## 瓦恩流程收尾：标记完成并恢复动作推进（handler 见 _p083_flow_done 跳过不重跑）。
func _finish_pilot_083_flow(action, payload: Dictionary) -> void:
	action.record.erase("_waiting_for_p083_weapon_select")
	action.record.erase("_waiting_for_p083_options")
	if payload != null:
		payload["_p083_flow_done"] = true
	action.record["_p083_flow_done"] = true
	if context != null and context.action_engine != null:
		action.state = &"waiting_input"
		context.action_engine.continue_action(action.action_id, {})


## 解析 weapon_key（"card:<instance_id>"）→ 武器卡；找不到返回 null。
func _resolve_pilot_083_weapon_card(gs, weapon_key: String) -> Variant:
	if gs == null or weapon_key == "" or not weapon_key.begins_with("card:"):
		return null
	var inst_id: StringName = StringName(weapon_key.substr(5))
	return gs.cards.get(inst_id) if gs.cards != null else null


## 取武器显示名（选项面板标题用），失败回退 weapon_key。
func _pilot_083_weapon_label(gs, weapon_key: String) -> String:
	if weapon_key.begins_with("base:"):
		var parts: PackedStringArray = weapon_key.substr(5).split(":")
		if parts.size() >= 2 and gs != null and gs.mechs != null:
			var b_mech = gs.mechs.get(StringName(parts[0]))
			if b_mech != null:
				var bws: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(b_mech, int(parts[1]))
				return String(bws.get("weapon_name", weapon_key))
		return weapon_key
	var card = _resolve_pilot_083_weapon_card(gs, weapon_key)
	if card == null:
		return weapon_key
	if card.get("def") != null and card.def != null:
		var _GEE = _ActionPilotEffects._get_gen_equip_effects()
		if _GEE != null and _GEE.has_method(&"get_effective_weapon_stats"):
			var st: Dictionary = _GEE.get_effective_weapon_stats(card)
			return String(st.get("weapon_name", card.def.display_name))
	return String(card.instance_id)


## 琳 pilot_024 效果2：维修后双方各抽2。向维修 CHOOSE_ONE 各分支追加抽牌动作。
## 只有维修来源是琳且目标非琳自己时追加（我方先抽、目标后抽，串行）。
## 追加到分支末尾：修复完成（HP/损伤变更）后抽牌，符合"使用维修后"语义。
func _append_pilot_024_repair_draws(options: Array, src_mech: StringName, payload: Dictionary) -> Array:
	var target_id: StringName = StringName(payload.get("target_id", payload.get("target_mech_id", &"")))
	var draw_players: Array = _ActionPilotEffects.pilot_024_draw_players_after_repair(context.game_state, src_mech, target_id)
	if draw_players.is_empty():
		return options
	var result: Array = []
	for opt in options:
		if not (opt is Dictionary):
			result.append(opt)
			continue
		var opt_copy: Dictionary = opt.duplicate(true)
		var acts: Array = opt_copy.get("actions", [])
		for pid: StringName in draw_players:
			acts.append({"type": &"EXECUTE_GAIN_CARD", "params": {
				"player_id": pid, "count": 2, "from_zone": &"action_deck",
				"reason": &"PILOT_024_REPAIR_DRAW",
			}})
		opt_copy["actions"] = acts
		result.append(opt_copy)
	return result


## 琳 RE 维修窗口关闭钩子：当前完成的 repair_direct 是窗口内维修（来源=琳、目标=窗口请求方）
## 时，关闭维修窗口并恢复被阻塞的 RE 请求动作（请求方回合继续）。
## effect 可为 null（_continue_seq_effect_actions 续跑路径无 effect），此时从 payload 反查来源。
func _pilot_024_close_if_window_repair_done(effect, payload: Dictionary, action) -> void:
	if context == null or context.game_state == null or payload == null:
		return
	var src_mech: StringName = &""
	if effect != null:
		var b = _make_binding_from_effect(effect, action, payload)
		src_mech = b.get_source_mech_id() if b != null else &""
	else:
		var src_d: Dictionary = payload.get("source", {}) if payload.has("source") else {}
		src_mech = StringName(src_d.get("mech_id", &""))
		if src_mech == &"":
			# source.mech_id 为空（顶层 use_action_card 来源仅带 card_instance_id）时
			# 回退 payload 的 mech_id/source_mech_id，保证窗口关闭判断仍能定位来源机甲。
			src_mech = StringName(payload.get("source_mech_id", payload.get("mech_id", &"")))
	if src_mech == &"":
		return
	if effect != null and effect.effect_id != &"repair_direct":
		return
	var target_id: StringName = StringName(payload.get("target_id", payload.get("target_mech_id", &"")))
	var wreq: StringName = _ActionPilotEffects.pilot_024_window_requester_for(context.game_state, src_mech)
	if wreq == &"" or wreq != target_id:
		return
	# 窗口关闭（维修已完成），恢复请求方回合
	_ActionPilotEffects.pilot_024_close_repair_window(context)
	pilot_024_repair_window_changed.emit(false, target_id)
	SLog.log_raw("[TIMING] 琳维修完成，RE 维修窗口关闭 requester=%s，请求方回合恢复" % String(target_id))


## 机甲损伤概况（供 RE 确认弹窗展示）：统计区域+装备牌损伤点数。
func _pilot_024_damage_summary(mech) -> String:
	if mech == null:
		return "无损伤"
	var total_dmg: int = 0
	if mech.slots != null:
		for sid: StringName in mech.slots:
			var slot = mech.slots[sid]
			if slot == null:
				continue
			total_dmg += int(slot.get("region_damage_tokens"))
			if slot.equipped_card != null:
				total_dmg += int(slot.equipped_card.get("damage_tokens"))
	if total_dmg <= 0:
		return "无损伤"
	return "损伤%d点" % total_dmg
