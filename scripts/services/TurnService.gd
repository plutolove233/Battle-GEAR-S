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

	# ── 4. 发出 TURN_START 时点（回复动力） ──
	_fire_timing(_TimingConst.TURN_START, {
		"player_id": String(player_id),
		"turn_number": gs.turn_number,
	})

	# 恢复动力到最大值
	if mech and context.game_actions:
		context.game_actions.restore_power({"mech_id": mech.mech_id, "amount": "full"})

	# ── 5. 抽2张行动牌 ──
	var drawn_actions: Array[StringName] = []
	if context.deck_service != null:
		drawn_actions = context.deck_service.draw_from_deck(&"action_deck", 2)
		for card_id: StringName in drawn_actions:
			player.action_hand.append(card_id)
			# 标记归属玩家（draw_from_deck 不设 owner_player_id；条件检查/离场效果依赖此字段）
			var _ac = context.game_state.get_card(card_id)
			if _ac:
				_ac.owner_player_id = player_id
			# 注册 AVAILABILITY 效果（迎击牌等的响应窗口监听器）；
			# 否则后续被攻击时响应窗口不会弹出
			if context.has_method("register_hand_card_availability"):
				context.register_hand_card_availability(card_id)

	# ── 6. 抽1张装备牌 ──
	var drawn_equipment: Array[StringName] = []
	if context.deck_service != null:
		drawn_equipment = context.deck_service.draw_from_deck(&"equipment_deck", 1)
		for card_id: StringName in drawn_equipment:
			player.equipment_hand.append(card_id)
			var _ec = context.game_state.get_card(card_id)
			if _ec:
				_ec.owner_player_id = player_id

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
	while player.action_hand.size() > player.action_card_limit:
		var excess_card: StringName = player.action_hand.pop_back()
		context.deck_service.discard_card(excess_card, &"turn_cleanup")

	# ── 6. 弃掉未设置的装备牌 ──
	while player.equipment_hand.size() > 0:
		var unset_card: StringName = player.equipment_hand.pop_back()
		context.deck_service.discard_card(unset_card, &"turn_cleanup")

	# ── 7. 清理 THIS_TURN 持续时间的效果 ──
	_clean_this_turn_durations(player_id)

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
	# 创建一个轻量级的虚拟动作对象用于传递时点
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
	context.timing_engine.fire_timing(timing, virtual_action)


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
func _is_this_turn_duration(d) -> bool:
	var t: int = typeof(d)
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		return String(d) == "THIS_TURN"
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
