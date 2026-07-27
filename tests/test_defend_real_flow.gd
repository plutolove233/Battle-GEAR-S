## test_defend_real_flow.gd - 防御迎击牌真实流程验证
##
## 现有 test_respond_attack_flow 用 mock 攻击动作，只验 +5 写到 record，不验真实伤害结算。
## 本测试走真实流程：enemy 攻击 player -> player 用防御响应 ->
##   +5护甲(机甲 temp_armor_bonus，装备面板可见) 减 HP 伤害、-1 损伤标记、攻击结算后护甲恢复。
##
## 验证点：
##   1. 防御响应后 player_mech.temp_armor_bonus=5（结算前 +5 护甲已加，面板可见）
##   2. HP 伤害 = max(0, weapon_might - (player_armor + 5))（+5 护甲生效，减 HP 伤害）
##   3. 损伤标记 = max(0, floor(weapon_might/5) - 1)（-1 损伤标记生效）
##   4. 攻击结算完成后 player_mech.temp_armor_bonus=0（防御结算后恢复护甲数值）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


## 推进若干帧，使 call_deferred 排入的恢复调用执行（动作链父->子恢复靠 deferred）
func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


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


## 把指定 card_def_id 的牌塞入玩家手牌
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


## 把指定 card_def_id 的牌塞入敌方手牌
func _ensure_card_in_enemy_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 设敌方首武器威力为 might（基础武器改 base_weapons，装备牌改 def.might）
func _set_enemy_first_weapon_might(enemy_mech, might: int) -> void:
	if not enemy_mech.base_weapons.is_empty():
		enemy_mech.base_weapons[0]["might"] = might
	var w1_slot = enemy_mech.slots.get(&"weapon_1") if enemy_mech.slots.has(&"weapon_1") else null
	if w1_slot != null and w1_slot.equipped_card != null and w1_slot.equipped_card.def != null:
		w1_slot.equipped_card.def.might = might


## 驱动 attack 的损伤设置效果动作完成（damage_change 暂停在 place_damage_tokens）
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id == &"":
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			continue
		var dc = ar.get_action(dc_id)
		var amount: int = int(dc.record.get("value", 0))
		var mech_ids: Array = dc.record.get("mech_ids", [])
		if dts != null and amount > 0:
			for mech_id: StringName in mech_ids:
				dts.place_damage_tokens({"mech_id": mech_id, "count": amount})
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)
	return {"ok": true}


func _count_damage_tokens(mech) -> int:
	if mech == null:
		return 0
	var total: int = 0
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null:
			total += int(slot.region_damage_tokens)
	return total


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


## 测试：enemy 攻击 player -> player 用防御响应 -> +5护甲减HP伤害、-1损伤标记、结算后护甲恢复
func test_defend_real_flow_armor_and_markers():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"

	# 敌我相邻，确保在武器范围内
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}

	# 敌方首武器威力设 12：markers=floor(12/5)=2（-1 后=1，可验证 -1 生效）；伤害=12-护甲，+5 明显减伤
	_set_enemy_first_weapon_might(enemy_mech, 12)
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var weapon_id: StringName = weapon_ids[0]

	# 给敌方一张攻击牌
	var attack_card_id: StringName = _ensure_card_in_enemy_hand(battle, "action_001_进攻")
	if attack_card_id == &"":
		var enemy_player = gs.players.get(&"enemy")
		for cid: StringName in enemy_player.action_hand:
			var c = gs.get_card(cid)
			if c and c.def and c.def.action_type == &"攻击":
				attack_card_id = cid
				break
	if attack_card_id == &"":
		return "敌方无攻击牌可用"

	# 给玩家防御牌
	var defend_cid: StringName = _ensure_card_in_hand(battle, "action_009_防御")
	if defend_cid == &"":
		return "找不到 防御 牌"

	# 推进 effect2 会在使用迎击牌时弹多选窗干扰本测试，清掉玩家手牌中的推进（移回牌堆）
	_clear_thrust_from_hand(battle)

	# 记录结算前数据（temp_armor_bonus 此时为 0）
	var player_hp_before: int = player_mech.current_hp
	var player_armor_before: int = int(player_mech.get_armor())
	var player_tokens_before: int = _count_damage_tokens(player_mech)

	battle.context.action_ui_bridge.context = battle.context

	# 发起敌方攻击
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	# 攻击应暂停在 ATTACK_AT 等待响应
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		return "攻击未暂停等待响应，atk_result=%s" % str(atk_result)
	if String(wait_info.get("input_type", &"")) != &"respond_attack":
		return "等待的不是 respond_attack: %s" % String(wait_info.get("input_type", &""))

	# 捕获 weapon_might（weapon_id 预填，select_weapon 已跑，record 已含）
	var attack = battle.context.action_registry.get_action(attack_action_id)
	var weapon_might: int = int(attack.record.get("weapon_might", 0))
	if weapon_might != 12:
		return "weapon_might 应为 12（测试设定），实际: %d" % weapon_might

	# 玩家选防御响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"defend_availability",
		"card_instance_id": defend_cid,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_action_id, sel)
	await _pump_frames(3)

	# ① 防御响应后 player_mech.temp_armor_bonus=5（结算前 +5 护甲已加，装备面板可见）
	if int(player_mech.temp_armor_bonus) != 5:
		return "防御响应后 player_mech.temp_armor_bonus 应=5，实际: %d" % int(player_mech.temp_armor_bonus)

	# ② 驱动损伤设置完成（damage_change 暂停在 place_damage_tokens）
	var drive_ret: Dictionary = _drive_damage_placement(battle, attack_action_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "损伤设置驱动失败")
	await _pump_frames(5)

	# ③ HP 伤害 = max(0, weapon_might - (player_armor + 5))（+5 护甲生效）
	var expected_damage: int = max(0, weapon_might - (player_armor_before + 5))
	var hp_loss: int = player_hp_before - player_mech.current_hp
	if hp_loss != expected_damage:
		return "防御 +5 护甲后 HP 伤害应=%d (might %d - (armor %d + 5))，实际: %d（+5 护甲未生效？）" % [expected_damage, weapon_might, player_armor_before, hp_loss]

	# ④ 损伤标记 = max(0, floor(weapon_might/5) - 1)（-1 损伤标记生效）
	var expected_markers: int = max(0, (weapon_might / 5) - 1)
	var tokens_placed: int = _count_damage_tokens(player_mech) - player_tokens_before
	if tokens_placed != expected_markers:
		return "防御 -1 损伤后标记应=%d (floor(12/5)=2 - 1)，实际: %d（-1 损伤未生效？）" % [expected_markers, tokens_placed]

	# ⑤ 攻击结算完成后 player_mech.temp_armor_bonus=0（防御结算后恢复护甲数值）
	if int(player_mech.temp_armor_bonus) != 0:
		return "攻击结算后 player_mech.temp_armor_bonus 应恢复为 0，实际: %d" % int(player_mech.temp_armor_bonus)

	# ⑥ 攻击动作完成、无残留
	if battle.context.action_registry.get_action(attack_action_id) != null:
		var leftover = battle.context.action_registry.get_action(attack_action_id)
		return "攻击动作未完成，state=%s" % String(leftover.state)
	return true
