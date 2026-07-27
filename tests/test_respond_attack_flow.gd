## test_respond_attack_flow.gd — 响应窗口执行链路回归测试
##
## 验证迎击牌选中后走正式 use_action_card 动作：
##   1. RESPOND_ATTACK 把"被响应"信息写回 attack record
##   2. 防御的护甲+5 写到机甲 temp_armor_bonus（get_armor 计入、装备面板可见），并登记到 attack record.temp_armor_grants 供结算后恢复
##   3. 迎击牌离开手牌进入弃牌堆（AVAILABILITY 监听器注销，不再残留为下次选项）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_ThrustHelper.clear_thrust_from_hand(battle)
	return battle


## 把一张指定 card_def_id 的牌塞入玩家手牌（模拟 draw_from_deck 抽出，owner/mech 均空）
## 返回 card_instance_id
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


## 测试1：选防御响应攻击 → attack.record.responded 正确、机甲 temp_armor_bonus+5，防御牌进弃牌堆
func test_defend_response_writes_attack_record():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	var cid: StringName = _ensure_card_in_hand(battle, "action_009_防御")
	if cid == &"":
		return "教程牌堆/弃牌堆中找不到 防御"

	# 构造 enemy→player 攻击动作（注册到 registry，使其能被 RESPOND_ATTACK 定位）
	var attack := _Action.new()
	attack.action_id = &"test_attack_defend"
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
		return "响应窗口未收集到防御牌"

	# 选防御响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"defend_availability",
		"card_instance_id": cid,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack.action_id, sel)

	# 验证 attack record 被写
	if attack.record.get("responded", false) != true:
		return "attack.record.responded 应为 true（RESPOND_ATTACK 未写回），实际: %s" % str(attack.record.get("responded"))
	if attack.record.get("counter_attacked", false) != true:
		return "attack.record.counter_attacked 应为 true（防御是迎击牌）"
	if int(player_mech.temp_armor_bonus) != 5:
		return "player_mech.temp_armor_bonus 应为 5（防御护甲+5 写到机甲），实际: %d" % int(player_mech.temp_armor_bonus)
	# 验证攻击动作登记了 temp_armor_grants（供 _step_cleanup 结算后恢复）
	var grants: Array = attack.record.get("temp_armor_grants", [])
	if grants.size() != 1 or int(grants[0].get("delta", 0)) != 5:
		return "attack.record.temp_armor_grants 应登记 {delta:5}，实际: %s" % str(grants)

	# 验证防御牌离开手牌、进入弃牌堆
	if player_mech != null:
		var player = gs.players.get(&"player")
		if player and player.action_hand.has(cid):
			return "防御牌应已离开手牌"
	var card = gs.get_card(cid)
	if card == null or String(card.zone) != &"discard":
		return "防御牌应进入弃牌堆，实际 zone: %s" % (String(card.zone) if card else "null")
	return true


## 测试2：用过的迎击牌下次被攻击不再出现在响应窗口（AVAILABILITY 监听器已注销）
func test_used_counter_card_not_listed_next_time():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	var cid: StringName = _ensure_card_in_hand(battle, "action_009_防御")
	if cid == &"":
		return "找不到 防御"

	var attack := _Action.new()
	attack.action_id = &"test_attack_used"
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": enemy_mech.mech_id,
		"target_id": player_mech.mech_id,
		"target_count": 1,
	}
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)

	var sel: Array[Dictionary] = [{"effect_id": &"defend_availability", "card_instance_id": cid, "availability_priority": 5}]
	battle.context.timing_engine.handle_response_selection(attack.action_id, sel)

	# 第二次攻击
	var attack2 := _Action.new()
	attack2.action_id = &"test_attack_used_2"
	attack2.action_type = &"attack"
	attack2.record = {
		"attacker_id": enemy_mech.mech_id,
		"target_id": player_mech.mech_id,
		"target_count": 1,
	}
	attack2.state = &"running"
	attack2.context = battle.context
	battle.context.action_registry.register(attack2)

	var available2: Array[Dictionary] = battle.context.timing_engine.get_available_cards(_TimingConst.ATTACK_AT, attack2)
	for entry: Dictionary in available2:
		if entry.get("card_instance_id", &"") == cid:
			return "用过的防御牌不应再次出现在响应窗口（AVAILABILITY 监听器残留）"
	return true
