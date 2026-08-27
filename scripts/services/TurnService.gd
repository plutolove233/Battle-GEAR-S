## TurnService.gd — 回合管理服务
##
## 负责回合开始/结束的完整流程，使用新TimingEngine时点系统：
##
## 回合周期（按新规则文档）：
##   1. 回合开始前 → TURN_BEFORE_START
##   2. 回合开始时（回复动力）→ TURN_START
##   3. 抽2行动牌+1装备牌+2金币 → TURN_AFTER_START
##   4. 回合进行中（玩家通过ActionService操作）
##   5. 宣言回合结束 → TURN_BEFORE_END
##   6. 回合结束时（事件计时）→ TURN_END
##   7. 弃置超限牌 → TURN_AFTER_END
##
## 每轮周期：位次1的玩家TURN_BEFORE_START前发出ROUND_START
class_name TurnService
extends RefCounted

## 回合结束流程完成信号（end_turn 全部分段步骤跑完后 emit，含挂起恢复路径）。
## 调用方（_net_end_turn 等）在 end_turn 返回 suspended=true 时等待本信号再流转下家回合。
signal end_turn_flow_completed(player_id: StringName)

var context = null  # type: GameContext

## 结束回合弃超限牌阻塞窗（key=action_id -> {player_id}）。
## 人类玩家手牌超限时第5步弹选牌窗挂起流程（时点顺序：拾荒等 TURN_BEFORE_END 效果
## 先结算，之后才弹弃超限牌窗）；AI（is_human=false，如 PvE 敌方）跳窗自动弃尾部。
var _pending_discard_prompts: Dictionary = {}

## TURN_BEFORE_END 挂起组（key=组虚拟动作 action_id ->
## {owner_pid, turn_player_id, payload, entries, next_index, action}）。
## 多个玩家各设拾荒（event_005）等 TURN_BEFORE_END 事件牌时，fire_timing 顺序执行下
## 首个挂起监听器把剩余暂存到虚拟动作 _pending_regular_listeners，而 turn 虚拟动作
## 无 steps、恢复路径不补跑 -> 只有第一个设置的玩家生效。改为按归属玩家
## （binding_context.player_id，事件牌归属）分组，每组独立虚拟动作执行/挂起：
## 不同玩家的弹窗并行弹出（互不阻塞），全部组交互完成才续跑 step3（事件计时/弃牌）。
## 宝藏（event_011）/修悟（event_023）同监听本时点，自动复用同一分发。
var _before_end_groups: Dictionary = {}

const _GameConfig = preload("res://scripts/config/GameConfig.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _SLog = preload("res://scripts/services/slog.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


## 开始回合
func start_turn(player_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 1. 设置活跃玩家和阶段 ──
	gs.active_player_id = player_id
	gs.phase = &"TURN_START"

	# 先手玩家回合数递增
	if player_id == &"player":
		gs.turn_number += 1

	# ── 2. 重置每回合一次性标记和计数器 ──
	player.once_per_turn_used.clear()
	player.turn_counters.clear()
	player.sell_equipment_count_this_turn = 0
	player.paid_draw_count_this_turn = 0

	# 重置机甲回合攻击计数
	var mech: MechState = gs.get_mech_for_player(player_id)
	if mech:
		mech.attack_count_this_turn = 0
		mech.cells_moved_this_turn = 0
		mech.has_attacked_this_turn = false
		# 重置本回合临时动力计数（消耗/授予）与临时动力本身（临时动力不跨回合保留）
		mech.temp_power = 0
		mech.reset_turn_power_counters()

		# ── 下个我方回合攻击数加成（可叠加，不跨到下下回合）──
		# 1) 还原上一回合应用的部分（上一回合 max_attacks_per_turn 加过 applied，现在减回去）
		if mech.applied_next_turn_attack_bonus != 0:
			mech.max_attacks_per_turn = max(1, mech.max_attacks_per_turn - mech.applied_next_turn_attack_bonus)
			mech.applied_next_turn_attack_bonus = 0
		# 2) 应用本回合待结算的加成（累积的转化次数一次性并入，随后清除，保证不延续到下下回合）
		var pending_bonus: int = mech.get_next_owner_turn_attack_bonus()
		if pending_bonus > 0:
			mech.max_attacks_per_turn += pending_bonus
			mech.applied_next_turn_attack_bonus = pending_bonus
			mech.clear_next_owner_turn_attack_bonus()
			_SLog.log_raw("[ATTACK_BONUS] mech=%s 本回合攻击数 +%d → max=%d" % [String(mech.mech_id), pending_bonus, mech.max_attacks_per_turn])
		# 3) 同步 player.attack_limit（attack_limit 始终跟随 max_attacks_per_turn，见 GameSetupService）
		if player.attack_limit != mech.max_attacks_per_turn:
			player.attack_limit = mech.max_attacks_per_turn

		# ── 下个我方回合行动牌上限加成（亚林 pilot_053 等：立即生效、下个我方回合开始到期清除）──
		# 通用机制：APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS 已立即 action_card_limit += stacks 并记
		# player.statuses 的 next_owner_turn_action_hand_bonus；此处玩家自己回合开始把待到期部分扣回。
		# 平行于 attack bonus（布鲁克延迟生效并入），但此机制为「当下生效、到期恢复」语义。
		if player.get_next_owner_turn_action_hand_bonus() > 0:
			var pending_hand_bonus: int = player.get_next_owner_turn_action_hand_bonus()
			player.action_card_limit = max(0, player.action_card_limit - pending_hand_bonus)
			player.clear_next_owner_turn_action_hand_bonus()
			_SLog.log_raw("[HAND_BONUS] player=%s 行动牌上限 -%d → %d" % [String(player_id), pending_hand_bonus, player.action_card_limit])

	# ── 3. 发出 ROUND_START 时点（位次1玩家回合开始前，优先于回合开始前） ──
	# 文档第143-145行：新轮次开始时点优先于回合开始前。1v1下player为位次1，首轮也发。
	if context.round_service != null:
		var turn_order: Array = context.round_service.turn_order
		if not turn_order.is_empty() and player_id == turn_order[0]:
			_fire_timing(_TimingConst.ROUND_START, {
				"player_id": String(player_id),
				"turn_number": gs.turn_number,
			})
			# 瓦恩 pilot_083 孤儿清理：新轮开始移除 owner 已无存活瓦恩持有者的施加
			# （瓦恩被换下/机甲被毁，持续效果随持有者离场终止）。
			_ActionPilotEffects.pilot_083_expire_orphan_apps(gs)
			# 法尔科 pilot_073 等"禁"标签到期：下一轮开始（ROUND_START，全局一次）恢复可主动设置/卖出。
			# 权威规则「直到下个我方回合开始后」，在轮次语义下=下轮开始统一到期，清除所有玩家名下标签。
			_ActionPilotEffects.clear_all_equip_forbid(gs)

	# ── 4. 发出 TURN_BEFORE_START 时点 ──
	_fire_timing(_TimingConst.TURN_BEFORE_START, {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
	})

	# 移除本机甲 CANNOT_RESTORE_POWER（effect_088"直到下个我方回合开始无法回复"：
	# 下个我方回合开始前移除，故 TURN_START 回复正常）
	if mech and not mech.statuses.is_empty():
		mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
			return s.get("type", &"") != &"CANNOT_RESTORE_POWER"
		)

	# 清理 UNTIL_NEXT_OWNER_TURN 持续效果（pilot_013 effect_02a 上限 modifier 到期恢复）。
	# 仅清 duration_owner_id == 即将开始回合玩家的 ARMOR_MODIFIER/POWER_CAP_MODIFIER；
	# 当前值减幅不恢复（仅上限恢复）。pilot_004 的 UNTIL_NEXT_OWNER_TURN modifier 无 duration_owner_id，
	# 由其专有监听器清理，此处不重复。
	_clean_until_next_owner_turn(player_id)

	# 恢复动力到最大值（先于 TURN_START 时点：保证监听 TURN_START 的效果如玛沙装甲转能
	# cap_bonus 补满在动力已回复后触发；权威文档顺序为 TURN_START 时点后回复动力，但
	# TURN_START 监听器弹窗异步挂起时 TurnService 不阻塞、restore 紧随 fire 执行，
	# 前置到 fire 之前使"动力已回复"语义确定，不受异步时序影响。抽牌/金币仍在 fire 之后）
	if mech and context.game_actions:
		context.game_actions.restore_power({"mech_id": mech.mech_id, "amount": "full"})

	# ── 4. 发出 TURN_START 时点 ──
	_fire_timing(_TimingConst.TURN_START, {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
	})

	# ── 4.1 事件计时（next_own_turn_start 模式：当前回合玩家机甲的事件牌计时-1） ──
	if context.event_timer_service:
		context.event_timer_service.tick_on_turn_start(player_id)

	# ── 5. 抽2张行动牌（走 gain_card 动作拿 GAIN_CARD_BEFORE/AFTER/SETTLE 时点；
	# gain_card 委托 draw_action_cards，保留 pilot_003 跳过正面牌 / effect_02 离堆事后处理 /
	# AVAILABILITY 注册 / ON_CARD_DRAWN hook。PvP 锁步两端一致。返回实际抽到的牌用于日志） ──
	# 未 typed（非 Array[StringName]）：gain_card 在 GAIN_CARD_BEFORE 可能挂起（银雪窥牌等），
	# 此时 execute 返回无 "record" 键 → .get("record", {}) 兜底空字典 → .get 兜底未 typed 空数组，
	# typed 赋值会崩（Array → Array[StringName]）。抽牌结果仅用于日志/叠加，无需强类型。
	var drawn_actions: Array = []
	if context.action_service != null:
		# 回合开始抽牌数加成（SET_TURN_START_DRAW_BONUS 效果，如艾希 pilot_061 抽牌数+2）：
		# 效果在 TURN_START 时点写入 turn_counters["turn_start_action_draw_bonus"]，
		# 此处并入本次抽牌并清零，使该次抽牌实际抽 2+bonus 张（单次 gain_card，非额外抽牌）。
		var _turn_draw_bonus: int = int(player.turn_counters.get("turn_start_action_draw_bonus", 0))
		if _turn_draw_bonus != 0:
			player.turn_counters.erase("turn_start_action_draw_bonus")
		var _gc_res: Dictionary = context.action_service.execute(&"gain_card", {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 2 + _turn_draw_bonus,
			"player_id": player_id, "reason": &"turn_start"
		})
		drawn_actions = _gc_res.get("record", {}).get("drawn_card_ids", [])

	# ── 6. 抽1张装备牌（走 gain_card 动作；gain_card 委托 draw_equipment_cards 自动
	# append equipment_hand + 设 owner + fire ON_CARD_DRAWN/ON_EQUIPMENT_CARD_DRAWN hook） ──
	var drawn_equipment: Array = []
	if context.action_service != null:
		var _ge_res: Dictionary = context.action_service.execute(&"gain_card", {
			"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1,
			"player_id": player_id, "reason": &"turn_start"
		})
		drawn_equipment = _ge_res.get("record", {}).get("drawn_card_ids", [])

	# ── 7. 获得2金币 ──
	if context.game_actions:
		context.game_actions.gain_gold({"player_id": player_id, "amount": 2})

	# ── 8. 记录抽牌日志 ──
	var _drawn_action_str: Array = []
	for cid in drawn_actions:
		_drawn_action_str.append(String(cid))
	var _drawn_equip_str: Array = []
	for cid in drawn_equipment:
		_drawn_equip_str.append(String(cid))
	gs.write_log(&"turn_draw", {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
		"action_card_ids": _drawn_action_str,
		"equipment_card_ids": _drawn_equip_str,
	})

	# ── 9. 切换到主阶段 ──
	gs.phase = &"MAIN"

	# ── 10. 发出 TURN_AFTER_START 时点 ──
	_fire_timing(_TimingConst.TURN_AFTER_START, {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
	})

	# ── 10.1 清理"禁"标签（装备牌通用禁标签，法尔科 pilot_073 等）──
	# 到期时机已移至 ROUND_START（下轮开始统一清除，见 start_turn 第3步）。此处不再按玩家回合清除，
	# 避免 tag-owner 晚于位次1的回合内"下个我方回合"晚于下轮开始导致解除时机错误。
	# 保留 clear_all_equip_forbid_for_player 供其他复用方（如效果主动清除）调用。

	gs.write_log(&"turn_start", {"player_id": String(player_id), "turn_number": gs.turn_number})
	return {"ok": true, "player_id": player_id, "turn_number": gs.turn_number, "phase": String(gs.phase)}


## 结束回合（分段可挂起）。
## 各 fire 时点（TURN_BEFORE_END/TURN_END/事件到期/弃超限牌窗/TURN_AFTER_END）的监听效果
## 弹窗挂起时，暂停剩余步骤（弃装备/清理等），玩家交互完成（挂起动作 cleanup）后自动续跑
## （ActionRegistry.cleanup_action 的 _flow_resume_call 出口），保证「拾荒在弃置超限牌之前」
## 「事件到期效果在牌弃置之前」的时序。全部步骤完成 emit end_turn_flow_completed。
## 返回 {"ok": bool, "suspended": bool, ...}。
func end_turn(player_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 1. 切换到回合结束阶段 ──
	gs.phase = &"TURN_END"
	# 防御：上一回合流程若异常残留挂起组（理论上不可能：step2 挂起时流程停在本回合），
	# 新流程开始时清空，避免僵尸组回调续跑旧流程。
	_before_end_groups.clear()
	return _advance_end_turn(player_id, 2)


## 回合结束分段推进（步骤号与原 end_turn 顺序一致；挂起即返回，续跑由
## _flow_resume_call -> _advance_end_turn_cb 驱动）
func _advance_end_turn(player_id: StringName, next_step: int) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	match next_step:
		2:
			# ── 2. 发出 TURN_BEFORE_END 时点（拾荒/宝藏/修悟；挂起阻塞弃超限牌）──
			# 多个玩家都设了拾荒类事件牌时按归属玩家并行分发（各玩家弹窗同时弹出，
			# 全部交互完成才进 step3），见 _fire_turn_before_end_parallel。
			if _fire_turn_before_end_parallel(player_id):
				return {"ok": true, "suspended": true}
			return _advance_end_turn(player_id, 3)
		3:
			# ── 3. 发出 TURN_END 时点（修整等；挂起阻塞事件计时与弃牌）──
			var va_3 = _fire_timing(_TimingConst.TURN_END, {
				"player_id": String(player_id),
				"turn_number": gs.turn_number,
			})
			if _suspend_end_turn_flow(va_3, player_id, 4):
				return {"ok": true, "suspended": true}
			return _advance_end_turn(player_id, 4)
		4:
			# ── 4. 推进事件计时器（遍历全部机甲：every_turn_end 每回合结束都-1，
			# own_turn_end / next_own_turn_end 仅 owner==当前结束玩家的机甲-1）。
			# 到期效果（陷落抽新等）挂起时返回 true 暂停，玩家交互完成后经 on_ticks_done
			# 续跑第5步；返回 false（含无事件牌/全部同步完成）时本调用方自行续跑第5步 ──
			if context.event_timer_service:
				var on_ticks_done: Callable = Callable(self, "_advance_end_turn_cb").bind(player_id, 5)
				if context.event_timer_service.tick_on_turn_end(player_id, on_ticks_done):
					return {"ok": true, "suspended": true}
			return _advance_end_turn(player_id, 5)
		5, 6, 7:
			return _end_turn_discard_and_cleanup(player_id)
		8:
			# ── 8. 发出 TURN_AFTER_END 时点（弥雅等；挂起阻塞流转下家）──
			var va_8 = _fire_timing(_TimingConst.TURN_AFTER_END, {
				"player_id": String(player_id),
				"turn_number": gs.turn_number,
			})
			if _suspend_end_turn_flow(va_8, player_id, 9):
				return {"ok": true, "suspended": true}
			_advance_after_end_expires(player_id)
			return _advance_end_turn(player_id, 9)
		9:
			# ── 9. 检查胜利条件 ──
			var victory_result: Dictionary = context.victory_service.check_victory()
			gs.write_log(&"turn_end", {"player_id": String(player_id), "turn_number": gs.turn_number})
			end_turn_flow_completed.emit(player_id)
			return {"ok": true, "victory": victory_result, "suspended": false}
	return {"ok": true, "suspended": false}


## _flow_resume_call 目标（Callable bind 参数）：续跑回合结束流程
func _advance_end_turn_cb(player_id: StringName, next_step: int) -> void:
	_advance_end_turn(player_id, next_step)


## fire 后虚拟动作挂起 -> 写续跑回调并返回 true（暂停流程）
func _suspend_end_turn_flow(virtual_action, player_id: StringName, next_step: int) -> bool:
	if virtual_action == null:
		return false
	var st: StringName = virtual_action.state
	if st == &"waiting_timing" or st == &"waiting_input" or st == &"waiting_effect_action":
		virtual_action.record["_flow_resume_call"] = Callable(self, "_advance_end_turn_cb").bind(player_id, next_step)
		return true
	return false


## ── TURN_BEFORE_END 按归属玩家并行分发 ──

## 收集 TURN_BEFORE_END 全部常规监听器并按归属玩家分组，每组独立虚拟动作执行。
## 返回 true=有组挂起（流程暂停，全部组完成后经 _on_before_end_group_resume 续跑 step3）。
## 分组键 = 监听器 binding_context.player_id（事件牌归属玩家；空归回合玩家）。
## 组间并行：各玩家弹窗同时弹出互不阻塞（不同玩家可并行决策）；组内监听器顺序执行
## （保持 fire_timing 的时点内排序语义）。宝藏（event_011）/修悟（event_023）与拾荒
## （event_005）同监听本时点，自动复用同一分发。
func _fire_turn_before_end_parallel(player_id: StringName) -> bool:
	var gs: GameState = context.game_state
	if context.timing_engine == null:
		return false
	# 无注册表：挂起/恢复链不可用，退回旧的单动作顺序 fire（尽力而为，不阻塞）
	if context.action_registry == null:
		var va_fb = _fire_timing(_TimingConst.TURN_BEFORE_END, {
			"player_id": String(player_id), "turn_number": gs.turn_number})
		return _suspend_end_turn_flow(va_fb, player_id, 3)
	var payload: Dictionary = {
		"player_id": String(player_id),
		"turn_number": int(gs.turn_number),
		"action_id": &"",
		"action_type": &"turn",
	}
	var entries: Array = context.timing_engine.collect_regular_listeners(
		_TimingConst.TURN_BEFORE_END, payload)
	if entries.is_empty():
		return false
	# 按归属玩家分组（组序=全局排序中首现顺序，保证 PvP 各端按确定序生成组动作）
	var groups: Dictionary = {}
	var group_order: Array[StringName] = []
	for entry: Dictionary in entries:
		var owner_pid: StringName = entry.get("binding_context", {}).get("player_id", &"")
		if owner_pid == &"":
			owner_pid = player_id
		if not groups.has(owner_pid):
			groups[owner_pid] = []
			group_order.append(owner_pid)
		groups[owner_pid].append(entry)
	for owner_pid: StringName in group_order:
		_spawn_before_end_group(owner_pid, groups[owner_pid], payload, player_id)
	return not _before_end_groups.is_empty()


## 为一个归属玩家组建虚拟动作并顺序执行其 TURN_BEFORE_END 监听器。
## 同步跑完：立即完成清理（不占组表）；挂起：登记组表（存动作引用，cleanup 后注册表
## 取不到）并写 record._flow_resume_call（cleanup -> call_deferred -> 恢复回调）。
func _spawn_before_end_group(owner_pid: StringName, entries: Array, payload: Dictionary, turn_player_id: StringName) -> void:
	var gs: GameState = context.game_state
	var owner_mech: MechState = gs.get_mech_for_player(owner_pid)
	var va = Action.new()
	va.action_type = &"turn"
	va.record = {
		"player_id": String(owner_pid),
		"turn_player_id": String(turn_player_id),
		"turn_number": int(gs.turn_number),
		"_before_end_group": true,
	}
	va.state = &"running"
	va.context = context
	va.source = {
		"player_id": owner_pid,
		"mech_id": owner_mech.mech_id if owner_mech != null else &"",
	}
	context.action_registry.register(va)
	var group: Dictionary = {
		"owner_pid": owner_pid,
		"turn_player_id": turn_player_id,
		"payload": payload,
		"entries": entries,
		"next_index": 0,
		"action": va,
	}
	if _run_before_end_entries(va, group):
		_before_end_groups[va.action_id] = group
		va.record["_flow_resume_call"] = Callable(self, "_on_before_end_group_resume").bind(turn_player_id, va.action_id)
	else:
		# 同步完成（如 AI 玩家跳窗/无条件可弃）：直接清理，未挂回调不重入
		va.state = &"completed"
		context.action_registry.cleanup_action(va.action_id)


## 顺序执行组内剩余监听器（group.next_index 起跑）。挂起（waiting_timing/
## waiting_input/waiting_effect_action）时记录断点返回 true；全部跑完（或动作被取消：
## 必耗 cost 不可支付等，终止组不再续跑）返回 false。
func _run_before_end_entries(va, group: Dictionary) -> bool:
	var entries: Array = group.get("entries", [])
	var payload: Dictionary = group.get("payload", {})
	var i: int = int(group.get("next_index", 0))
	while i < entries.size():
		var entry: Dictionary = entries[i]
		var effect = entry.get("effect", null)
		if effect == null:
			i += 1
			continue
		# 效果 payload：时点公共字段 + 该监听器绑定上下文（拾荒弹窗按牌主路由窗口）
		var bind_ctx: Dictionary = entry.get("binding_context", {})
		var effect_payload: Dictionary = payload
		if not bind_ctx.is_empty():
			effect_payload = payload.duplicate()
			effect_payload["binding_context"] = bind_ctx
		context.timing_engine._execute_effect(effect, effect_payload, va)
		var st: StringName = va.state
		if st == &"cancelled":
			group["next_index"] = entries.size()
			return false
		if st == &"waiting_timing" or st == &"waiting_input" or st == &"waiting_effect_action":
			group["next_index"] = i + 1
			return true
		i += 1
	group["next_index"] = entries.size()
	return false


## 组挂起恢复（cleanup 的 _flow_resume_call 出口，call_deferred 帧末触发）：
## 重挂动作（cleanup 已移出注册表；register 幂等保留原 id，供 continue_action/弹窗取用）
## 续跑组内剩余监听器。又挂起：重设回调等待下一次交互；全部完成：组收尾，
## 组表空（全部玩家交互完成）才续跑 step3（事件计时/弃超限牌）。
func _on_before_end_group_resume(turn_player_id: StringName, action_id: StringName) -> void:
	var group: Dictionary = _before_end_groups.get(action_id, {})
	if group.is_empty():
		return  # 已处理过（重入防护）
	var va = group.get("action", null)
	if va == null or context == null or context.action_registry == null:
		_finish_before_end_group(action_id, turn_player_id)
		return
	context.action_registry.register(va)
	if va.state == &"cancelled":
		_finish_before_end_group(action_id, turn_player_id)
		return
	va.state = &"running"
	if _run_before_end_entries(va, group):
		if va.state == &"cancelled":
			_finish_before_end_group(action_id, turn_player_id)
			return
		# 再次挂起：重设续跑回调（cleanup 已 erase，须重写）等待下一次交互
		va.record["_flow_resume_call"] = Callable(self, "_on_before_end_group_resume").bind(turn_player_id, action_id)
		return
	_finish_before_end_group(action_id, turn_player_id)


## 组收尾：出组表 + 清回调 + 清理动作；组表空（全部归属玩家交互完成）-> 续跑 step3。
func _finish_before_end_group(action_id: StringName, turn_player_id: StringName) -> void:
	_before_end_groups.erase(action_id)
	if context != null and context.action_registry != null:
		var va = context.action_registry.get_action(action_id)
		if va != null:
			# 先 erase 回调再 cleanup：防 cleanup 的 call_deferred 二次触发本收尾（重入）
			va.record.erase("_flow_resume_call")
			va.state = &"completed"
			context.action_registry.cleanup_action(action_id)
	if _before_end_groups.is_empty():
		_advance_end_turn(turn_player_id, 3)


## step5~7：弃超限牌 + 弃未设置装备 + 清理时效效果（原 end_turn 第5~7.5步主体）
## 弃超限牌（人类玩家）：弹【阻塞】选牌窗挂起流程，选完经 resume_end_turn_discard
## 批量弃置后续跑（正常顺序执行：拾荒等 TURN_BEFORE_END 时点效果先结算完才轮到弃牌）。
## AI（is_human=false，PvE 敌方）：跳窗从手牌尾部自动弃足超额数。
func _end_turn_discard_and_cleanup(player_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}
	# 本回合被安德洛美达 effect_01b 回收的维修（标记 pilot_008_recovered）保留在手牌且不计入超限名额
	# （效果优先，每回合至多1张）。带"燃"标签的行动牌（烈火 pilot_070 命中抽3）本回合不占行动牌上限，
	# 同样排除。先收集 (counted_hand - effective_limit) 张非回收非燃超限牌再弃，避免 while pop_back
	# 重取 append 到末尾的回收维修（once_per_turn 已用 -> 不再回收 -> 维修进弃牌堆）。
	var _recovered_n: int = 0
	for _cid_r in player.action_hand:
		if _ActionPilotEffects.is_pilot_008_recovered(_cid_r):
			_recovered_n += 1
	var _effective_limit: int = player.action_card_limit + _recovered_n
	var _ran_hand: Array = _ActionPilotEffects.list_ran_tagged_hand(gs, player_id)
	var _counted_hand: int = player.action_hand.size() - _ran_hand.size()
	if _counted_hand > _effective_limit:
		var _excess_n: int = _counted_hand - _effective_limit
		# 受保护牌不可选弃：回收维修（效果保留）+ 燃标签牌（不占上限）
		var _protected: Array = []
		for _cid_x in player.action_hand:
			if _ActionPilotEffects.is_pilot_008_recovered(_cid_x) and not _protected.has(_cid_x):
				_protected.append(_cid_x)
		for _cid_x in _ran_hand:
			if not _protected.has(_cid_x):
				_protected.append(_cid_x)
		# 人类玩家：弹阻塞窗（挂起流程，选完 resume_end_turn_discard 续跑第5步）
		if player.is_human and _prompt_end_turn_discard(player_id, _excess_n, _protected):
			return {"ok": true, "suspended": true}
		# AI/无注册表环境：从手牌尾部自动弃足超额数（非回收非燃）
		var _excess_cards: Array[StringName] = []
		for i in range(player.action_hand.size() - 1, -1, -1):
			if _excess_cards.size() >= _excess_n:
				break
			var _cid: StringName = player.action_hand[i]
			if _ActionPilotEffects.is_pilot_008_recovered(_cid):
				continue  # 回收牌保留，跳过
			if _ActionPilotEffects.card_has_ran_tag(gs.get_card(_cid)):
				continue  # 燃标签牌不占上限，跳过
			_excess_cards.append(_cid)
		for _cid in _excess_cards:
			player.action_hand.erase(_cid)
			context.deck_service.discard_card(_cid, &"turn_cleanup")

	# ── 6. 弃掉未设置的装备牌 ──
	while player.equipment_hand.size() > 0:
		var unset_card: StringName = player.equipment_hand.pop_back()
		context.deck_service.discard_card(unset_card, &"turn_cleanup")

	# ── 7. 清理 THIS_TURN 持续时间的效果 ──
	_clean_this_turn_durations(player_id)

	# ── 7.1 清理 pilot_009 美杜莎临时卡牌控制（持续光环到回合结束） ──
	# 裁定：控制仅本回合有效，回合结束统一解除（无论哪个玩家回合结束都清，安全无害）。
	_ActionPilotEffects.clear_all_pilot_009_control()
	# 清理 pilot_008 安德洛美达本回合回收标记（仅 end_turn 第5步弃超限牌时用，回合结束失效）
	_ActionPilotEffects.clear_pilot_008_recovered()
	# 清理 pilot_021 塔莉娅"禁"标签（效果1剩余牌本回合结束后恢复可用）
	_ActionPilotEffects.pilot_021_clear_all_jin_for_player(context.game_state, player_id)
	# 清理"燃"标签（烈火 pilot_070 命中抽3：本回合不占行动牌上限，回合结束后恢复计上限）。
	# 在第5步弃超限牌之后清除——超限弃牌先按燃牌排除执行，本玩家回合结束后即失效。
	_ActionPilotEffects.clear_all_ran_tags_for_player(context.game_state, player_id)

	# ── 7.5 清理 temp_zone 残留牌 ──
	# 兜底：行动牌使用中（如反击2效果2监听 ATTACK_SETTLE 未触发前留 temp_zone）若因
	# 攻击被取消等原因滞留，回合结束统一弃置，避免牌永久卡在临时区。
	_clean_temp_zone_residue()

	# ── step8/9 转回分段推进（TURN_AFTER_END 挂起阻塞流转下家）──
	return _advance_end_turn(player_id, 8)


## 弹出弃超限牌阻塞窗（人类玩家）。虚拟 action 挂 waiting_input 占注册表，
## record._flow_resume_call 指回第5步（选牌弃置后重入：届时手牌已不超限，继续 6~9）。
## 经 TimingEngine.action_needs_input 信号走 ActionUIBridge 共享等待槽（排队/查询同现有窗口）；
## TurnService 不直接持有 UI，弹窗由 app_root 按 mode=turn_end_flow 路由（仅弃牌玩家本机显示）。
## 返回 false=基础设施缺失（无注册表/时点引擎），调用方回退自动弃。
func _prompt_end_turn_discard(player_id: StringName, count: int, protected_ids: Array) -> bool:
	if context == null or context.action_registry == null or context.timing_engine == null:
		return false
	# 同玩家已有挂起弃牌窗：不重复弹（防 _flow_resume_call 重入时重复建窗）
	for _aid_g in _pending_discard_prompts:
		if String(_pending_discard_prompts[_aid_g].get("player_id", &"")) == String(player_id):
			return true
	var va = Action.new()
	va.action_type = &"turn_end_discard"
	va.record = {
		"player_id": String(player_id),
		"count": count,
	}
	va.state = &"waiting_input"
	va.context = context
	va.source = {"player_id": player_id, "mech_id": &""}
	context.action_registry.register(va)
	va.record["_flow_resume_call"] = Callable(self, "_advance_end_turn_cb").bind(player_id, 5)
	_pending_discard_prompts[va.action_id] = {"player_id": player_id}
	context.timing_engine.action_needs_input.emit(va.action_id, &"select_discard_cards", {
		"action_id": va.action_id,
		"discard_player_id": player_id,
		"player_id": player_id,
		"count": count,
		"face_up": true,
		"no_cancel": true,
		"exclude_card_ids": protected_ids,
		"mode": &"turn_end_flow",
		"title_override": "回合结束：弃置超限行动牌",
		"source_label": "回合结束：弃置超限行动牌",
		"executor": player_id,
	})
	return true


## 弃超限牌窗口确认续跑（op resume_turn_discard / 测试直调）：
## 批量弃置所选（过滤已不在手/受保护牌），完成虚拟动作 -> cleanup 触发
## _flow_resume_call 重入第5步（届时不超限，同步继续 6~9 步直至流转下家）。
func resume_end_turn_discard(action_id: StringName, selected_ids: Array) -> void:
	var prompt: Dictionary = _pending_discard_prompts.get(action_id, {})
	if prompt.is_empty():
		return
	_pending_discard_prompts.erase(action_id)
	var player_id: StringName = prompt.get("player_id", &"")
	var gs: GameState = context.game_state if context != null else null
	var player: PlayerState = gs.players.get(player_id) if gs != null else null
	if player != null:
		# 批量弃（单动作单 SETTLE：安德洛美达 effect_01b 同批只回收一次的裁定保持）
		var ids: Array = []
		for _raw in selected_ids:
			var _cid: StringName = StringName(String(_raw))
			if _cid == &"" or not player.action_hand.has(_cid):
				continue
			if _ActionPilotEffects.is_pilot_008_recovered(_cid):
				continue
			if _ActionPilotEffects.card_has_ran_tag(gs.get_card(_cid)):
				continue
			ids.append(_cid)
			player.action_hand.erase(_cid)
		if not ids.is_empty():
			context.deck_service.discard_cards(ids, &"END_TURN_HAND_LIMIT")
	# 完成窗口动作 -> cleanup 的 _flow_resume_call 续跑（call_deferred）
	if context != null and context.action_registry != null:
		var va = context.action_registry.get_action(action_id)
		if va != null:
			va.state = &"completed"
			context.action_registry.cleanup_action(action_id)


## 原第8步尾部的瓦恩过期清理（TURN_AFTER_END 挂起恢复续跑后也要执行，抽为方法）
func _advance_after_end_expires(player_id: StringName) -> void:
	# 瓦恩 pilot_083 过期清理：当前回合玩家的武器修改施加在「下个我方回合结束」到期
	# （applied_turn=施加轮数；跨过施加轮的下个该玩家回合，TURN_AFTER_END 移除
	# applied_turn < 当前轮数的应用）。TURN_AFTER_END 时点监听器仍读到施加（持续到结束时点）。
	_ActionPilotEffects.pilot_083_expire_apps_for_turn(context.game_state, player_id, int(context.game_state.turn_number))


## ── 内部方法 ──


## 触发时点（通过TimingEngine）；返回虚拟 action（供调用方检查挂起态/挂续跑回调）
func _fire_timing(timing: StringName, payload: Dictionary = {}) -> Action:
	if context.timing_engine == null:
		return null
	# 创建一个轻量级的虚拟动作对象用于传递时点。
	# 必须注册到 ActionRegistry 以获取唯一 action_id（否则 action_id=&"" 导致多个虚拟 action
	# 的挂起效果互相覆盖；且 resume_pending_effect / continue_action 从 registry 取不到 action
	# 致 pilot LISTEN 效果 CHOOSE_ONE 确认后无法 resume 到 CHOOSE_INTEGER 等后续阶段）。
	var virtual_action = Action.new()
	virtual_action.action_type = &"turn"
	virtual_action.record = payload.duplicate()
	virtual_action.state = &"running"
	virtual_action.context = context
	# 注入 source 信息，使子动作能通过 binding 获取 player_id / mech_id
	var player_id: StringName = payload.get("player_id", &"")
	virtual_action.source = {
		"player_id": player_id,
		"mech_id": &"",
	}
	if player_id != &"":
		var mech = context.game_state.get_mech_for_player(player_id)
		if mech:
			virtual_action.source["mech_id"] = mech.mech_id
	# 注册到 registry 获取唯一 action_id（register 内部在 action_id 为空时分配）
	if context.action_registry != null:
		context.action_registry.register(virtual_action)
	context.timing_engine.fire_timing(timing, virtual_action)
	# fire 完成后：若虚拟 action 未挂起（无监听器响应或已同步完成），立即清理避免泄漏。
	# 挂起的（waiting_timing 等玩家弹窗确认）保留在 registry，待 resume 后 continue_action
	# 跑空 step 自动 completed -> cleanup。
	if context.action_registry != null and virtual_action.state != &"waiting_timing" and virtual_action.state != &"waiting_input" and virtual_action.state != &"waiting_effect_action":
		context.action_registry.cleanup_action(virtual_action.action_id)
	return virtual_action


## 清理 duration=UNTIL_NEXT_OWNER_TURN 且归属即将开始回合玩家的上限 modifier。
## pilot_013 effect_02a：护甲/动力上限-4 到期恢复（当前值-4 不恢复，仅上限恢复）。
## 仅清 ARMOR_MODIFIER/POWER_CAP_MODIFIER 中 duration_owner_id 匹配的项；移除后重算 max_power
## 并钳制 current power（cap 移除后上限恢复，当前动力不自动+4，但允许后续 restore_power 正常回满）。
func _clean_until_next_owner_turn(player_id: StringName) -> void:
	var gs: GameState = context.game_state
	if gs == null:
		return
	for mech_id: StringName in gs.mechs:
		var mech: MechState = gs.mechs[mech_id]
		var remove_ids: Array[StringName] = []
		for status: Dictionary in mech.statuses:
			var stype: StringName = status.get("type", &"")
			if stype != &"ARMOR_MODIFIER" and stype != &"POWER_CAP_MODIFIER":
				continue
			if String(status.get("duration", &"")) != "UNTIL_NEXT_OWNER_TURN":
				continue
			var owner_id = status.get("duration_owner_id", &"")
			if owner_id == &"" or String(owner_id) != String(player_id):
				continue
			var sid: StringName = status.get("status_id", &"")
			if sid != &"":
				remove_ids.append(sid)
		if remove_ids.is_empty():
			continue
		if context.timing_engine != null:
			for sid in remove_ids:
				context.timing_engine.unregister_listeners_for_status(sid)
		mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
			return not remove_ids.has(s.get("status_id", &""))
		)
		# 重算 max_power + 钳制 current power（cap modifier 移除后上限恢复，当前动力保留）
		mech.max_power = mech.get_total_power()
		var own: int = mech.get_own_power()
		var new_own: int = clampi(own, 0, mech.max_power)
		mech.power = new_own + mech.temp_power
		_SLog.log_raw("[pilot_013] %s 回合开始清理 UNTIL_NEXT_OWNER_TURN modifier，mech=%s max_power=%d power=%d" % [String(player_id), String(mech_id), mech.max_power, mech.power])
	# pilot_014 亚伦 +2 到期恢复：清理 duration_owner_id == 即将开始回合玩家的 pilot_014_action_limit_bonus。
	# 按 current_field 扣回 delta：action_card_limit 侧(player.statuses) -> player.action_card_limit -= delta；
	# max_attacks_per_turn 侧(mech.statuses，刻托交换翻转后迁来) -> mech.max_attacks_per_turn -= delta + 同步 attack_limit。
	# 目标机师牌已离场时由 unset_pilot/destroy_mech 提前清理，此处扫描不到（幂等）。
	for _p014_pid: StringName in gs.players:
		var _p014_player = gs.players[_p014_pid]
		if _p014_player == null:
			continue
		var _p014_rm_p: Array = _p014_player.statuses.filter(func(s): return String(s.get("type", &"")) == "pilot_014_action_limit_bonus" and String(s.get("duration_owner_id", &"")) == String(player_id))
		if _p014_rm_p.is_empty():
			continue
		for _s in _p014_rm_p:
			_p014_player.action_card_limit -= int(_s.get("delta", 2))
		_p014_player.statuses = _p014_player.statuses.filter(func(s): return not (String(s.get("type", &"")) == "pilot_014_action_limit_bonus" and String(s.get("duration_owner_id", &"")) == String(player_id)))
		_SLog.log_raw("[pilot_014] %s 回合开始到期清理：%d 个 +2 从 player=%s action_card_limit 扣回" % [String(player_id), _p014_rm_p.size(), String(_p014_pid)])
	for _p014_mid: StringName in gs.mechs:
		var _p014_mech = gs.mechs[_p014_mid]
		if _p014_mech == null:
			continue
		var _p014_rm_m: Array = _p014_mech.statuses.filter(func(s): return String(s.get("type", &"")) == "pilot_014_action_limit_bonus" and String(s.get("duration_owner_id", &"")) == String(player_id))
		if _p014_rm_m.is_empty():
			continue
		for _s in _p014_rm_m:
			_p014_mech.max_attacks_per_turn -= int(_s.get("delta", 2))
		var _p014_mowner: StringName = _p014_mech.owner_player_id
		if gs.players.has(_p014_mowner) and gs.players[_p014_mowner] != null:
			gs.players[_p014_mowner].attack_limit = _p014_mech.max_attacks_per_turn
		_p014_mech.statuses = _p014_mech.statuses.filter(func(s): return not (String(s.get("type", &"")) == "pilot_014_action_limit_bonus" and String(s.get("duration_owner_id", &"")) == String(player_id)))
		_SLog.log_raw("[pilot_014] %s 回合开始到期清理：%d 个 +2 从 mech=%s max_attacks_per_turn 扣回" % [String(player_id), _p014_rm_m.size(), String(_p014_mid)])


## 清理持续时间为 THIS_TURN 的效果
func _clean_this_turn_durations(turn_player_id: StringName = &"") -> void:
	var gs: GameState = context.game_state
	for mech_id: StringName in gs.mechs:
		var mech: MechState = gs.mechs[mech_id]
		var to_remove: Array = []
		for status: Dictionary in mech.statuses:
			if _is_this_turn_duration(status.get("duration", &"")):
				var status_type: StringName = status.get("type", &"")
				var delta: int = int(status.get("delta", 0))
				if status_type == &"POWER_MODIFIER" and delta != 0:
					# 正向 delta（临时动力）：不在此扣减（消耗时已优先扣 temp_power），
					# 剩余临时动力由下方 clear_temp_power 统一清除（本身动力保留）。
					# 负向 delta（减动力 debuff）：还原本身动力（power - delta = +|delta|），
					# clamp 上限保留 temp_power（临时动力不被压回）。
					if delta < 0:
						mech.power = clamp(mech.power - delta, 0, mech.max_power + mech.temp_power)
				elif status_type == &"attack_count_modifier" and delta != 0:
					# 本回合攻击数±X（MODIFY_ATTACK_COUNT）：回合末从 max_attacks_per_turn 还原
					# （可正可负，delta=+1 减回，delta=-1 加回），并同步 owner.attack_limit。
					# 注意：须是 POWER_MODIFIER 的兄弟分支——此前误嵌在 POWER_MODIFIER 内，
					# attack_count_modifier 的还原永不执行（本回合攻击数±X 永续残留）。
					mech.max_attacks_per_turn = max(1, mech.max_attacks_per_turn - delta)
					var _acm_owner: StringName = mech.owner_player_id
					if gs.players.has(_acm_owner) and gs.players[_acm_owner] != null:
						gs.players[_acm_owner].attack_limit = mech.max_attacks_per_turn
				to_remove.append(status)
		# 注销被清除状态关联的监听器，避免孤儿监听器在状态移除后仍触发。
		# 联合状态 unite_status_attack 监听 ATTACK_SETTLE，若不注销，状态下回合被清后，
		# unite 机甲下次攻击仍会触发联合攻击弹窗（条件读 binding_context.unite 仍成立）。
		if not to_remove.is_empty() and context.timing_engine != null:
			for status: Dictionary in to_remove:
				var status_id: StringName = status.get("status_id", &"")
				if status_id != &"":
					context.timing_engine.unregister_listeners_for_status(status_id)
		mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
			return not _is_this_turn_duration(s.get("duration", &""))
		)
		# 清除剩余临时动力（未消耗的临时动力不保留，本身动力保留）
		mech.clear_temp_power()
		# pilot_020 肯德 动力+3(POWER_CAP_MODIFIER THIS_TURN)：上限+当前同步+3，回合末清理后
		# 重算 max_power 还原上限+当前动力（无 POWER_CAP_MODIFIER 变化时 delta=0 为 no-op）。
		mech.recalc_power_limits()
	# 清理玩家级 THIS_TURN/UNTIL_TURN_END 修饰符（player.statuses）：本回合行动牌上限±X
	# （MODIFY_ACTION_HAND_LIMIT，如骇客 pilot_066 窥到迎击牌 +1）回合末还原 action_card_limit。
	# 原实现只清理 mech.statuses，遗漏 player.statuses 致 +上限 永续——亚林 p053 上限+1、
	# 骇客 p066 迎击+1 等 THIS_TURN 修饰符都会残留。
	for player_id: StringName in gs.players:
		var p_state = gs.players[player_id]
		if p_state == null or p_state.statuses.is_empty():
			continue
		var p_to_remove: Array = []
		for status: Dictionary in p_state.statuses:
			if not _is_this_turn_duration(status.get("duration", &"")):
				continue
			var p_status_type: StringName = status.get("type", &"")
			var p_delta: int = int(status.get("delta", 0))
			if p_status_type == &"action_hand_limit_modifier" and p_delta != 0:
				p_state.action_card_limit = max(0, p_state.action_card_limit - p_delta)
				_SLog.log_raw("[TurnService] 回合末清理 %s 行动牌上限%s%d：还原 action_card_limit=%d" % [String(player_id), "+" if p_delta >= 0 else "", p_delta, p_state.action_card_limit])
			p_to_remove.append(status)
		if not p_to_remove.is_empty():
			p_state.statuses = p_state.statuses.filter(func(s: Dictionary) -> bool:
				return not _is_this_turn_duration(s.get("duration", &""))
			)
	# 清理装备牌 effect_negated（THIS_TURN/UNTIL_TURN_END）：恢复被压制的效果
	for card_id: StringName in gs.cards:
		var card = gs.cards[card_id]
		if card == null:
			continue
		if card.effect_negated:
			card.effect_negated = false
		# 武器装备牌临时修正/标记清理（effect_093/095/112/113/125）
		# THIS_TURN 每回合末清；THIS_OWNER_TURN（聚能临时加成）仅在卡牌归属 == 当前结束回合玩家时清
		# （"到所属玩家回合结束"语义，原代码漏清致永续）。
		var card_owner: StringName = card.owner_player_id if "owner_player_id" in card else &""
		if card.get("might_modifiers") != null and not card.might_modifiers.is_empty():
			card.might_modifiers = card.might_modifiers.filter(func(m): return not _should_clear_weapon_mod(m, card_owner, turn_player_id))
		if card.get("range_modifiers") != null and not card.range_modifiers.is_empty():
			card.range_modifiers = card.range_modifiers.filter(func(m): return not _should_clear_weapon_mod(m, card_owner, turn_player_id))
		# weapon_used_this_turn 标记清除（effect_112 设，effect_113 在 TURN_END fire 后此处清）
		if card.get("counters") != null and card.counters.get("weapon_used_this_turn", false):
			card.counters["weapon_used_this_turn"] = false
		# 武器冷却解除：turn_number >= cooldown_until_turn 时清除（effect_125，下个我方回合结束后）
		if card.get("counters") != null and card.counters.get("cooldown_active", false):
			var cd_until: int = int(card.cooldown_until_turn) if card.get("cooldown_until_turn") != null else -1
			if cd_until >= 0 and int(gs.turn_number) >= cd_until:
				card.counters["cooldown_active"] = false
				card.cooldown_until_turn = -1


## duration 字段类型不统一：StringName(&"THIS_TURN") / int(锁定 duration=1) / 缺省(&"")，
## 异常情况下可能是 null 或 Dictionary（PvP 回合结束曾因 String(null) 构造崩溃，
## 报 "Nonexistent 'String' constructor"）。仅 String/StringName 才可能等于 "THIS_TURN"；
## int 视为非 THIS_TURN；其它类型打印诊断以便定位根因。
## UNTIL_TURN_END（联合状态用）语义同 THIS_TURN，回合结束统一清理--
## 原仅匹配 THIS_TURN 致联合状态永续（unite_status_clear 的 REMOVE_STATUS 缺 target_id 移除失败）。
func _is_this_turn_duration(d) -> bool:
	var t: int = typeof(d)
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		var s := String(d)
		return s == "THIS_TURN" or s == "UNTIL_TURN_END"
	if t != TYPE_INT:
		push_warning("[TurnService] status duration 非预期类型 %d: %s" % [t, str(d)])
	return false


## 武器修正项（might/range_modifiers）是否应在回合末清除。
## THIS_TURN：每回合末清；THIS_OWNER_TURN：仅当卡牌归属 == 当前结束回合玩家时清
## （聚能 effect_093/095 临时加成"到所属玩家回合结束"，原 _is_this_turn_duration 漏匹配致永续）。
func _should_clear_weapon_mod(m, card_owner_id: StringName, turn_player_id: StringName) -> bool:
	if not (m is Dictionary):
		return false
	var d: String = String(m.get("duration", &""))
	if d == "THIS_TURN":
		return true
	if d == "THIS_OWNER_TURN" and turn_player_id != &"" and String(card_owner_id) == String(turn_player_id):
		return true
	return false


## 清理 temp_zone 残留牌
## 行动牌使用期间进入 temp_zone，正常应在 use_action_card settle 或 attack cleanup 时进弃牌堆。
## 但含 bind_to_attack_action 效果的牌（反击2）改由 attack cleanup 在 ATTACK_SETTLE 后弃；
## 若攻击被取消导致 cleanup 未执行，牌会滞留 temp_zone。回合结束兜底统一弃置。
func _clean_temp_zone_residue() -> void:
	var gs: GameState = context.game_state
	if gs == null or context.deck_service == null:
		return
	# 收集所有 zone==temp_zone 的牌（边遍历边弃会改 deck_service 状态，先快照 id）
	var residue_ids: Array[StringName] = []
	for cid: StringName in gs.cards:
		var card = gs.cards[cid]
		if card != null and String(card.zone) == &"temp_zone":
			residue_ids.append(cid)
	for cid: StringName in residue_ids:
		context.deck_service.discard_card(cid, &"turn_cleanup")
