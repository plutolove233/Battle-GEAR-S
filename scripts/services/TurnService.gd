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

var context = null  # type: GameContext

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
		# 重置本回合临时动力计数（消耗/授予）与临时动力本身（临时动力不跨回合保留）
		mech.temp_power = 0
		mech.reset_turn_power_counters()

	# ── 3. 发出 ROUND_START 时点（位次1玩家回合开始前，优先于回合开始前） ──
	# 文档第143-145行：新轮次开始时点优先于回合开始前。1v1下player为位次1，首轮也发。
	if context.round_service != null:
		var turn_order: Array = context.round_service.turn_order
		if not turn_order.is_empty() and player_id == turn_order[0]:
			_fire_timing(_TimingConst.ROUND_START, {
				"player_id": String(player_id),
				"turn_number": gs.turn_number,
			})

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

	# ── 5. 抽2张行动牌（走 gain_card 动作拿 GAIN_CARD_BEFORE/AFTER/SETTLE 时点；
	# gain_card 委托 draw_action_cards，保留 pilot_003 跳过正面牌 / effect_02 离堆事后处理 /
	# AVAILABILITY 注册 / ON_CARD_DRAWN hook。PvP 锁步两端一致。返回实际抽到的牌用于日志） ──
	var drawn_actions: Array[StringName] = []
	if context.action_service != null:
		var _gc_res: Dictionary = context.action_service.execute(&"gain_card", {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
			"player_id": player_id, "reason": &"turn_start"
		})
		drawn_actions = _gc_res.get("record", {}).get("drawn_card_ids", [])

	# ── 6. 抽1张装备牌（走 gain_card 动作；gain_card 委托 draw_equipment_cards 自动
	# append equipment_hand + 设 owner + fire ON_CARD_DRAWN/ON_EQUIPMENT_CARD_DRAWN hook） ──
	var drawn_equipment: Array[StringName] = []
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

	gs.write_log(&"turn_start", {"player_id": String(player_id), "turn_number": gs.turn_number})
	return {"ok": true, "player_id": player_id, "turn_number": gs.turn_number, "phase": String(gs.phase)}


## 结束回合
func end_turn(player_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 1. 切换到回合结束阶段 ──
	gs.phase = &"TURN_END"

	# ── 2. 发出 TURN_BEFORE_END 时点 ──
	_fire_timing(_TimingConst.TURN_BEFORE_END, {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
	})

	# ── 3. 发出 TURN_END 时点（事件计时） ──
	_fire_timing(_TimingConst.TURN_END, {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
	})

	# ── 4. 推进事件计时器 ──
	var mech: MechState = gs.get_mech_for_player(player_id)
	if mech:
		context.event_timer_service.tick_on_turn_end(mech.mech_id)

	# ── 5. 弃掉超出手牌上限的行动牌 ──
	# 本回合被安德洛美达 effect_01b 回收的维修（标记 pilot_008_recovered）保留在手牌且不计入超限名额
	# （效果优先，每回合至多1张）。先收集 (size - effective_limit) 张非回收超限牌再弃，避免 while pop_back
	# 重取 append 到末尾的回收维修（once_per_turn 已用 -> 不再回收 -> 维修进弃牌堆）。
	var _recovered_n: int = 0
	for _cid_r in player.action_hand:
		if _ActionPilotEffects.is_pilot_008_recovered(_cid_r):
			_recovered_n += 1
	var _effective_limit: int = player.action_card_limit + _recovered_n
	if player.action_hand.size() > _effective_limit:
		var _excess_cards: Array[StringName] = []
		for i in range(player.action_hand.size() - 1, -1, -1):
			if player.action_hand.size() - _excess_cards.size() <= _effective_limit:
				break
			var _cid: StringName = player.action_hand[i]
			if _ActionPilotEffects.is_pilot_008_recovered(_cid):
				continue  # 回收牌保留，跳过
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

	# ── 7.5 清理 temp_zone 残留牌 ──
	# 兜底：行动牌使用中（如反击2效果2监听 ATTACK_SETTLE 未触发前留 temp_zone）若因
	# 攻击被取消等原因滞留，回合结束统一弃置，避免牌永久卡在临时区。
	_clean_temp_zone_residue()

	# ── 8. 发出 TURN_AFTER_END 时点 ──
	_fire_timing(_TimingConst.TURN_AFTER_END, {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
	})

	# ── 9. 检查胜利条件 ──
	var victory_result: Dictionary = context.victory_service.check_victory()

	gs.write_log(&"turn_end", {"player_id": String(player_id), "turn_number": gs.turn_number})
	return {"ok": true, "victory": victory_result}


## ── 内部方法 ──


## 触发时点（通过TimingEngine）
func _fire_timing(timing: StringName, payload: Dictionary = {}) -> void:
	if context.timing_engine == null:
		return
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
