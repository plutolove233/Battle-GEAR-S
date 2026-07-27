## test_response_window_registration.gd — 响应窗口监听器注册回归测试
##
## 验证迎击牌（回避/防御/反击/疾行/识破）的 AVAILABILITY 效果在牌进入手牌后
## 被正确注册为 ATTACK_AT 时点的监听器，且 card.mech_id 指向持有者机甲。
##
## 背景 bug：TurnService.start_turn 通过 deck_service.draw_from_deck 抽出的牌
## owner_player_id 与 mech_id 均为空，导致 register_hand_card_availability 提前 return，
## 迎击牌的响应窗口监听器永不注册——被攻击时响应窗口不弹出。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
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


## 辅助：在玩家手牌中找一张指定 card_def_id 的牌，没有则从牌堆/弃牌堆强制塞入手牌
func _ensure_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	# 先看手牌是否已有
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	# 从行动牌堆找
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			# 走与 TurnService 抽牌一致的注册路径
			battle.context.register_hand_card_availability(cid)
			return cid
	# 从弃牌堆找
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


## 测试1：经 draw_from_deck 路径抽出的迎击牌（owner/mech 均空）注册后
##        card.mech_id == player_mech，且 ATTACK_AT 时点存在其 AVAILABILITY 监听器
func test_drawn_counter_card_registers_availability():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "找不到 player_mech"

	# 把一张回避塞入玩家手牌（模拟 draw_from_deck 抽出，owner/mech 均空）
	var cid: StringName = _ensure_card_in_hand(battle, "action_008_回避")
	if cid == &"":
		return "教程牌堆/弃牌堆中找不到 回避"

	var card = gs.get_card(cid)
	if card.mech_id != player_mech.mech_id:
		return "注册后 card.mech_id=%s 应为 %s（owner/mech 空路径未回填持有者机甲）" % [String(card.mech_id), String(player_mech.mech_id)]

	# 检查 TimingEngine 的 ATTACK_AT 临时监听器里存在此牌的 AVAILABILITY 效果
	var temp_listeners: Array = battle.context.timing_engine.temporary_listeners.get(_TimingConst.ATTACK_AT, [])
	var found: bool = false
	for entry: Dictionary in temp_listeners:
		if entry.get("card_instance_id", &"") == cid:
			var eff = entry.get("effect")
			if eff and eff.mode == _TimingConst.MODE_AVAILABILITY:
				found = true
				break
	if not found:
		return "ATTACK_AT 时点未注册该迎击牌的 AVAILABILITY 监听器（被攻击时响应窗口不会弹出）"
	return true


## 测试2：被攻击目标为玩家机甲时，响应窗口能收集到该迎击牌
func test_response_window_collects_counter_card():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	var cid: StringName = _ensure_card_in_hand(battle, "action_008_回避")
	if cid == &"":
		return "教程牌堆/弃牌堆中找不到 回避"

	# 构造一个 enemy→player 的攻击动作记录，触发 _check_availability
	var attack := _Action.new()
	attack.action_id = &"test_attack_1"
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": enemy_mech.mech_id,
		"target_id": player_mech.mech_id,
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
	}
	attack.state = &"running"

	var available: Array[Dictionary] = battle.context.timing_engine.get_available_cards(_TimingConst.ATTACK_AT, attack)
	var found_cid: bool = false
	for entry: Dictionary in available:
		if entry.get("card_instance_id", &"") == cid:
			found_cid = true
			break
	if not found_cid:
		return "被攻击时响应窗口未收集到玩家手中的回避（可用条件失败或监听器未注册）"
	return true
