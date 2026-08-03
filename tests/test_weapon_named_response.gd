extends RefCounted

## test_weapon_named_response.gd - 光束/热能武器响应效果（094/096）验证
## 覆盖：
##   ① 可用性过滤：只有持有者（被攻击方）且攻击武器名匹配时 094 才进响应窗口；
##      非 光束 武器攻击或非持有者 -> 不出现。
##   ② 选效果 -> 弹"弃1张行动牌"选择窗（任意行动牌）-> 弃置后执行（攻击威力-5）。
##   ③ 命中后由攻击目标（响应方）设置损伤位置（responded 而非 counter_attacked）。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _GeneratedEquipmentEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")


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


## 把指定装备牌从牌堆/手牌取出放入指定玩家的装备手牌，再设置到槽位。返回 card_instance_id。
func _equip_weapon_for(battle: BattleState, player_id: String, card_def_id: String, slot: String) -> StringName:
	var gs = battle.context.game_state
	var pid: StringName = StringName(player_id)
	var player = gs.players.get(pid)
	if player == null:
		return &""
	# 先查手牌
	var cid: StringName = &""
	for c in player.equipment_hand:
		var card = gs.get_card(c)
		if card and card.def and card.def.card_id == card_def_id:
			cid = c
			break
	if cid == &"":
		for pile in [gs.deck_state.equipment_deck, gs.deck_state.advanced_equipment_deck]:
			for i in range(pile.size()):
				var c: StringName = pile[i]
				var card = gs.get_card(c)
				if card and card.def and card.def.card_id == card_def_id:
					pile.remove_at(i)
					player.equipment_hand.append(c)
					card.zone = &"equipment_hand"
					card.owner_player_id = pid
					cid = c
					break
			if cid != &"":
				break
	if cid == &"":
		return &""
	var result: Dictionary = battle.context.card_set_service.set_equipment(pid, cid, StringName(slot))
	if not result.get("ok", false):
		return &""
	await _pump_frames(3)
	return cid


## 确保指定玩家手牌有至少1张行动牌，返回一张可弃的 action card id
func _ensure_action_card_for(battle: BattleState, player_id: String) -> StringName:
	var gs = battle.context.game_state
	var pid: StringName = StringName(player_id)
	var player = gs.players.get(pid)
	if player == null:
		return &""
	if not player.action_hand.is_empty():
		return player.action_hand[0]
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = pid
			return cid
	return &""


func _find_attack(battle: BattleState):
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			return a
	return null


## 驱动 attack 的损伤设置效果动作完成（damage_change 暂停在 place_damage_tokens）。
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 15:
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
			await _pump_frames(1)
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


## ── 094 响应流程：被光束武器攻击 -> 选光束步枪响应 -> 弃1行动牌 -> 威力-5 ──
func test_weapon_094_response_flow():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"

	# enemy 装备光束军刀（光束名武器，攻击方），player 装备光束步枪（094 响应效果，防御方）
	var saber_cid: StringName = await _equip_weapon_for(battle, "enemy", "weapon_001_光束军刀", "weapon_1")
	if saber_cid == &"":
		return "enemy 装备光束军刀失败"
	var rifle_cid: StringName = await _equip_weapon_for(battle, "player", "weapon_016_光束步枪", "weapon_2")
	if rifle_cid == &"":
		return "player 装备光束步枪失败"
	# 确保 player 有行动牌可弃
	var discard_cid: StringName = _ensure_action_card_for(battle, "player")
	if discard_cid == &"":
		return "player 无行动牌可弃"
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()

	# enemy 站到 player 相邻格（光束军刀 range=2 内）
	var pp = player_mech.position
	enemy_mech.position = {"q": int(pp["q"]) + 1, "r": int(pp["r"])}

	battle.context.action_ui_bridge.context = battle.context
	# enemy 用光束军刀攻击 player
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", saber_cid, &"")
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"respond_attack":
		return "被光束武器攻击应暂停在 respond_attack，实际: %s" % String(wait_info.get("input_type", &""))

	# ① 响应窗口应含 094（player 的光束步枪）
	var avail: Array = wait_info.get("input_params", {}).get("available_cards", [])
	var has_094: bool = false
	for c in avail:
		if String(c.get("effect_id", &"")) == "equipment_effect_094":
			has_094 = true
			break
	if not has_094:
		return "被光束武器攻击时响应窗口应含 effect_094，available=%s" % str(avail)

	# ② 选 094 -> 弹弃牌窗
	var eff_094 = _GeneratedEquipmentEffects.build_equipment_effects().get(&"equipment_effect_094")
	var sel: Array[Dictionary] = [{
		"effect_id": &"equipment_effect_094",
		"card_instance_id": rifle_cid,
		"effect": eff_094,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_action_id, sel)
	await _pump_frames(3)
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_discard_cards":
		return "选094后应弹 select_discard_cards，实际: %s" % String(wait2.get("input_type", &""))
	var dp: StringName = wait2.get("input_params", {}).get("discard_player_id", wait2.get("input_params", {}).get("player_id", &""))
	if String(dp) != "player":
		return "弃牌对象应为 player（持有者），实际: %s" % String(dp)

	# ③ 选1张行动牌弃置 -> 续跑（弃牌 + 执行 -5威力）
	battle.context.timing_engine.resume_pending_effect(attack_action_id, {"selected_action_card_ids": [discard_cid]})
	await _pump_frames(5)

	# 验证：威力-5（extra_might=-5）、responded=true、弃牌已进弃牌堆
	var attack = battle.context.action_registry.get_action(attack_action_id)
	if attack == null:
		return "攻击动作已完成/找不到"
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != -5:
		return "094 响应应 extra_might=-5，实际: %d" % extra_might
	if not bool(attack.record.get("responded", false)):
		return "094 响应应写 responded=true"
	var in_discard: bool = gs.deck_state.action_discard_pile.has(discard_cid)
	if not in_discard:
		return "弃置的行动牌应进弃牌堆"
	if gs.players.get(&"player").action_hand.size() != player_hand_before - 1:
		return "player 手牌应-1，实际: %d" % gs.players.get(&"player").action_hand.size()
	# 清理：驱动损伤设置完成
	await _drive_damage_placement(battle, attack_action_id)
	return true


## ── 非 光束 武器攻击 -> 094 不进响应窗口 ──
func test_weapon_094_not_available_for_non_beam():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"
	# player 装备光束步枪（094），enemy 用基础武器（非光束名）攻击
	var rifle_cid: StringName = await _equip_weapon_for(battle, "player", "weapon_016_光束步枪", "weapon_2")
	if rifle_cid == &"":
		return "player 装备光束步枪失败"
	# enemy 取一把实体非光束武器：用热能战斧（"热能"非"光束"）
	var axe_cid: StringName = await _equip_weapon_for(battle, "enemy", "weapon_002_热能战斧", "weapon_1")
	if axe_cid == &"":
		return "enemy 装备热能战斧失败"
	var pp = player_mech.position
	enemy_mech.position = {"q": int(pp["q"]) + 1, "r": int(pp["r"])}

	battle.context.action_ui_bridge.context = battle.context
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", axe_cid, &"")
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	# 被热能（非光束）武器攻击：094 不应出现；若有响应窗口，available 不含 094
	var it: String = String(wait_info.get("input_type", &""))
	if it == &"respond_attack":
		var avail: Array = wait_info.get("input_params", {}).get("available_cards", [])
		for c in avail:
			if String(c.get("effect_id", &"")) == "equipment_effect_094":
				return "非光束武器攻击时 094 不应出现，但 available 含 094: %s" % str(avail)
		# 无 094：通过；关闭响应窗口（pass）让攻击可继续
		var empty_sel: Array[Dictionary] = []
		battle.context.timing_engine.handle_response_selection(attack_action_id, empty_sel)
	else:
		# 无响应窗口（player 无迎击牌）也算通过（094 未出现）
		pass
	return true
