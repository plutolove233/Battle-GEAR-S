## test_counter_attack_effect2.gd — 反击牌效果2（反击攻击B）触发回归测试
##
## 验证：被攻击时使用反击牌响应，原攻击 ATTACK_SETTLE 时点应触发 counter_effect2，
## 对原攻击者发起反击攻击B。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


func _ensure_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 清掉玩家手牌中的推进（移回行动牌堆+注销监听器），避免推进 effect2 弹窗干扰迎击牌测试
func _clear_thrust_from_hand(battle: BattleState) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	if player == null:
		return
	var to_remove: Array = []
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == &"action_015_推进":
			to_remove.append(cid)
	for cid in to_remove:
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"


## 测试：反击牌响应后，ATTACK_SETTLE 时点 counter_effect2 被触发（产生反击攻击B效果动作）
func test_counter_effect2_fires_on_attack_settle():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	# 把 player 动力清零，使 e1 的半动力移动立即结束（available_power=0 → single_move 直接 settle）
	# 这样测试无需驱动移动目标选择，专注验证 e2 触发。
	player_mech.power = 0

	var cid: StringName = _ensure_card_in_hand(battle, "action_010_反击")
	if cid == &"":
		return "教程牌堆/弃牌堆中找不到 反击"

	# 推进 effect2 会在使用迎击牌时弹多选窗干扰本测试，清掉玩家手牌中的推进
	_clear_thrust_from_hand(battle)

	# 构造 enemy→player 攻击动作
	var attack := _Action.new()
	attack.action_id = &"test_attack_counter"
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": enemy_mech.mech_id,
		"target_id": player_mech.mech_id,
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
	}
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)

	# 响应窗口收集可用牌
	var available: Array[Dictionary] = battle.context.timing_engine.get_available_cards(_TimingConst.ATTACK_AT, attack)
	var found: bool = false
	for entry: Dictionary in available:
		if entry.get("card_instance_id", &"") == cid:
			found = true
			break
	if not found:
		return "响应窗口未收集到反击牌"

	# 选反击响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"counter_availability",
		"card_instance_id": cid,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack.action_id, sel)

	# 验证 attack record 被标记为已响应
	if attack.record.get("responded", false) != true:
		return "attack.record.responded 应为 true，实际: %s" % str(attack.record.get("responded"))

	# 诊断：检查 ATTACK_SETTLE 临时监听器是否包含 counter_effect2
	var settle_listeners: Array = battle.context.timing_engine.temporary_listeners.get(_TimingConst.ATTACK_SETTLE, [])
	var has_counter_e2: bool = false
	for le: Dictionary in settle_listeners:
		var le_eff: ActionEffect = le.get("effect")
		if le_eff and le_eff.effect_id == &"counter_effect2":
			has_counter_e2 = true
			break
	if not has_counter_e2:
		var all_e2_ids: Array = []
		for le: Dictionary in settle_listeners:
			var le_eff: ActionEffect = le.get("effect")
			if le_eff:
				all_e2_ids.append(String(le_eff.effect_id))
		return "ATTACK_SETTLE 监听器中未找到 counter_effect2（监听器未注册）。现有: %s" % str(all_e2_ids)

	# 记录当前 attack 效果动作数（反击攻击B应作为新效果动作出现）
	var attack_pending_before := attack.pending_effect_action_ids.duplicate()

	# 触发 ATTACK_SETTLE 时点 — counter_effect2 应在此被调用
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)

	# 验证：counter_effect2 执行后应在 attack.pending_effect_action_ids 增加一个 attack 类效果动作（反击攻击B）
	# 或在 action_registry 中出现新的 attack 动作
	var new_attack_sub := false
	for aid: StringName in attack.pending_effect_action_ids:
		if not attack_pending_before.has(aid):
			var sub = battle.context.action_registry.get_action(aid)
			if sub and sub.action_type == &"attack":
				new_attack_sub = true
				break
	if not new_attack_sub:
		return "ATTACK_SETTLE 后未产生反击攻击B效果动作（counter_effect2 未触发）— pending_before=%s pending_after=%s" % [str(attack_pending_before), str(attack.pending_effect_action_ids)]
	return true
