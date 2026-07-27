## test_thrust_effect2_real_flow.gd - 推进 effect2 真实流程验证
##
## 验证推进 effect2：持有者使用迎击牌时弹多选窗，选推进一起打出（各动力+4），
## 先执行推进效果再执行迎击牌。
##
## 流程：enemy 攻击 player -> player 选防御响应 -> 防御 use_action_card 在 USE_ACTION_AT
##   暂停弹 select_thrust_cards -> 选1张推进 -> 执行推进(+4动力+弃置) -> 继续防御效果1
##   (+5护甲/-1损伤) -> 攻击结算。
##
## 验证点：
##   1. 防御响应后弹出 select_thrust_cards（thrust_effect2 触发），列出手中推进
##   2. 选1张推进 -> 动力+4、推进进弃牌堆
##   3. 推进效果先于防御执行（动力+4 在防御 +5护甲之前）
##   4. 防御 +5护甲减HP伤害、-1损伤标记照常（与 test_defend_real_flow 一致）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


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


func _set_enemy_first_weapon_might(enemy_mech, might: int) -> void:
	if not enemy_mech.base_weapons.is_empty():
		enemy_mech.base_weapons[0]["might"] = might
	var w1_slot = enemy_mech.slots.get(&"weapon_1") if enemy_mech.slots.has(&"weapon_1") else null
	if w1_slot != null and w1_slot.equipped_card != null and w1_slot.equipped_card.def != null:
		w1_slot.equipped_card.def.might = might


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


## 测试：推进 effect2 多选 + 先于迎击牌执行
func test_thrust_effect2_multi_select_before_counter():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"

	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	_set_enemy_first_weapon_might(enemy_mech, 12)
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var weapon_id: StringName = weapon_ids[0]

	var attack_card_id: StringName = _ensure_card_in_enemy_hand(battle, "action_001_进攻")
	if attack_card_id == &"":
		return "敌方无攻击牌可用"

	# 玩家手牌：防御 + 推进
	var defend_cid: StringName = _ensure_card_in_hand(battle, "action_009_防御")
	if defend_cid == &"":
		return "找不到 防御 牌"
	var thrust_cid: StringName = _ensure_card_in_hand(battle, "action_015_推进")
	if thrust_cid == &"":
		return "找不到 推进 牌"

	var player_hp_before: int = player_mech.current_hp
	var player_armor_before: int = int(player_mech.get_armor())
	var player_power_before: int = int(player_mech.power)
	var player_tokens_before: int = _count_damage_tokens(player_mech)

	battle.context.action_ui_bridge.context = battle.context

	# 发起敌方攻击
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	# 攻击暂停在 respond_attack
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"respond_attack":
		return "等待的不是 respond_attack: %s" % String(wait_info.get("input_type", &""))

	# 选防御响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"defend_availability",
		"card_instance_id": defend_cid,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_action_id, sel)
	await _pump_frames(3)

	# ① 防御 use_action_card 在 USE_ACTION_AT 暂停弹 select_thrust_cards
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_thrust_cards":
		return "防御响应后应弹 select_thrust_cards，实际: %s" % String(wait2.get("input_type", &""))
	var thrust_action_id: StringName = wait2.get("action_id", &"")
	var card_ids: Array = wait2.get("input_params", {}).get("card_ids", [])
	if not card_ids.has(thrust_cid):
		return "select_thrust_cards 未列出推进 %s，card_ids=%s" % [String(thrust_cid), str(card_ids)]

	# ② 选1张推进确认 -> 执行推进效果(+4动力+弃置) -> 继续防御效果1
	battle.context.timing_engine.resume_pending_effect(thrust_action_id, {"selected_card_ids": [thrust_cid]})
	await _pump_frames(3)

	# ③ 推进动力+4 已生效（先于防御）
	if int(player_mech.power) != player_power_before + 4:
		return "推进应使动力+4（%d -> %d），实际: %d" % [player_power_before, player_power_before + 4, int(player_mech.power)]
	# 推进进弃牌堆
	var thrust_card = gs.get_card(thrust_cid)
	if thrust_card == null or String(thrust_card.zone) != &"discard":
		return "推进应进弃牌堆，实际 zone: %s" % (String(thrust_card.zone) if thrust_card else "null")

	# ④ 驱动损伤设置（防御 +5护甲/-1损伤 后攻击结算）
	var drive_ret: Dictionary = _drive_damage_placement(battle, attack_action_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "损伤设置驱动失败")
	await _pump_frames(5)

	# ⑤ HP伤害 = max(0, 12 - (护甲 + 5))（防御 +5护甲生效）
	var expected_damage: int = max(0, 12 - (player_armor_before + 5))
	var hp_loss: int = player_hp_before - player_mech.current_hp
	if hp_loss != expected_damage:
		return "防御+5护甲后 HP伤害应=%d，实际: %d" % [expected_damage, hp_loss]

	# ⑥ 损伤标记 = floor(12/5)-1 = 1（-1生效）
	var expected_markers: int = max(0, (12 / 5) - 1)
	var tokens_placed: int = _count_damage_tokens(player_mech) - player_tokens_before
	if tokens_placed != expected_markers:
		return "防御-1损伤后标记应=%d，实际: %d" % [expected_markers, tokens_placed]

	# ⑦ 攻击结算后护甲恢复（temp_armor_bonus=0）
	if int(player_mech.temp_armor_bonus) != 0:
		return "攻击结算后 temp_armor_bonus 应恢复0，实际: %d" % int(player_mech.temp_armor_bonus)

	# ⑧ 攻击动作完成
	if battle.context.action_registry.get_action(attack_action_id) != null:
		return "攻击动作未完成"
	return true
