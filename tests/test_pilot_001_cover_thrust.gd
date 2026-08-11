## test_pilot_001_cover_thrust.gd - 阿克罗姆对掩护/推进双重生效验证
##
## 验证掩护/推进重构后经 use_action_card 打出，触发 pilot_001 01a/01b 双重生效：
##   掩护：ATTACK_PRE 多选窗选掩护 -> 批量 use_action_card -> 01a确认 + cover_effect1_direct -5 + 01b重跑 -5
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")


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
	battle.rng_seed = 12345
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	_clear_all_pilot_static()
	return battle


func _clear_all_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_006_marks.keys():
		_ActionPilotEffects.clear_pilot_006_mark(src)
	var ctl_sources: Array = []
	for target in _ActionPilotEffects._pilot_009_control.keys():
		var types: Dictionary = _ActionPilotEffects._pilot_009_control[target]
		for ct in types.keys():
			ctl_sources.append(types[ct].get("source_pilot", &""))
	for s in ctl_sources:
		_ActionPilotEffects.clear_pilot_009_control_for_source(s)
	var b_sources: Array = []
	for bid in _ActionPilotEffects._pilot_002_batches.keys():
		b_sources.append(_ActionPilotEffects._pilot_002_batches[bid].get("grant_source", &""))
	for s in b_sources:
		_ActionPilotEffects.clear_pilot_002_batches_for_source(s)
	for src in _ActionPilotEffects._pilot_003_skip.keys():
		_ActionPilotEffects.clear_pilot_003_skip_for_source(src)


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


func _make_attack(battle: BattleState, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_attack_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": extra.get("weapon_id", &""),
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 测试1：pilot_001 + 掩护 -> 掩护经 use_action_card 触发 01a确认 + 01b重跑，双重生效 -10
func test_pilot_001_cover_double_active() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 11, "r": 0}
	player_mech.position = {"q": 10, "r": 0}
	var player = gs.players.get(&"player")
	# 清空玩家迎击牌避免响应窗口干扰
	for cid: StringName in player.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	player.action_hand.clear()
	# pilot_001 -> player_mech（注册 01a/01b permanent listener）
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	# player_mech 持1张掩护 + 注册 cover_effect1 permanent listener
	var cover = _make_instance(gs, cdb, "action_016_掩护", &"player")
	if cover == null:
		return "找不到 action_016_掩护"
	cover.mech_id = player_mech.mech_id
	player.action_hand.append(cover.instance_id)
	cover.zone = &"action_hand"
	var effects: Dictionary = _GeneratedActionEffects.build_all_effects()
	var cover_e1 = effects.get(&"cover_effect1")
	if cover_e1 == null:
		return "找不到 cover_effect1"
	battle.context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_PRE, cover_e1, {
		"card_instance_id": cover.instance_id,
		"player_id": &"player",
		"mech_id": player_mech.mech_id,
		"card_def_id": &"action_016_掩护",
		"slot_id": &"action_hand",
	})
	# enemy 攻击 player_mech（holder 自身被攻击 -> cover_effect1 触发）
	var attack: _Action = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.action_ui_bridge.context = battle.context
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# ① 应弹 select_thrust_cards（掩护多选窗）
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards(掩护)，实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")
	# ② 选1掩护确认 -> use_action_card 子动作 -> 01a CHOOSE_ONE 弹窗
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {"selected_card_ids": [cover.instance_id]})
	await _pump_frames(3)
	# ③ 01a CHOOSE_ONE 弹窗（pilot_001 双重生效确认）
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"choose_one_effect":
		return "应弹 choose_one_effect(01a确认)，实际: %s" % String(wait2.get("input_type", &""))
	var pilot_action_id: StringName = wait2.get("action_id", &"")
	# ④ 01a 确认 -> cover_effect1_direct -5 + 01b REPEAT 重跑 -5 -> settle 弃置
	battle.context.timing_engine.resume_pending_effect(pilot_action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	# ⑤ extra_might = -10（effect1 -5 + 01b 重跑 -5）
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != -10:
		return "掩护双重生效 extra_might 应=-10(effect1 -5 + 01b -5)，实际: %d" % extra_might
	# ⑥ 掩护进弃牌堆
	var cover_card = gs.get_card(cover.instance_id)
	if cover_card == null or String(cover_card.zone) != &"discard":
		return "掩护应进弃牌堆，zone=%s" % String(cover_card.zone if cover_card else "null")
	_clear_all_pilot_static()
	return true


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
			c.owner_player_id = &"player"
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
			c.owner_player_id = &"player"
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
			c.owner_player_id = &"enemy"
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


## 测试2：pilot_001 + 推进 -> 迎击时推进经 use_action_card 触发 01a确认 + 01b重跑，双重生效 +8
func test_pilot_001_thrust_double_active() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
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
	# pilot_001 -> player_mech
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	# player 持防御 + 推进
	var defend_cid: StringName = _ensure_card_in_hand(battle, "action_009_防御")
	if defend_cid == &"":
		return "找不到 防御 牌"
	var thrust_cid: StringName = _ensure_card_in_hand(battle, "action_015_推进")
	if thrust_cid == &"":
		return "找不到 推进 牌"
	var power_before: int = int(player_mech.power)
	battle.context.action_ui_bridge.context = battle.context
	# 发起敌方攻击
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	# 攻击暂停在 respond_attack
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"respond_attack":
		return "等待的不是 respond_attack: %s" % String(wait.get("input_type", &""))
	# 选防御响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"defend_availability",
		"card_instance_id": defend_cid,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_action_id, sel)
	await _pump_frames(3)
	# ① 防御 use_action_card 在 USE_ACTION_AT 暂停弹 select_thrust_cards（thrust_effect2）
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_thrust_cards":
		return "防御响应后应弹 select_thrust_cards，实际: %s" % String(wait2.get("input_type", &""))
	var thrust_action_id: StringName = wait2.get("action_id", &"")
	# ② 选1推进 -> use_action_card[推进] -> 01a CHOOSE_ONE 弹窗
	battle.context.timing_engine.resume_pending_effect(thrust_action_id, {"selected_card_ids": [thrust_cid]})
	await _pump_frames(3)
	# ③ 01a CHOOSE_ONE 弹窗（pilot_001 双重生效确认）
	var wait3: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait3.get("input_type", &"")) != &"choose_one_effect":
		return "应弹 choose_one_effect(01a确认)，实际: %s" % String(wait3.get("input_type", &""))
	var pilot_action_id: StringName = wait3.get("action_id", &"")
	# ④ 01a 确认 -> thrust_effect1 +4 + 01b REPEAT +4 -> settle 弃置
	battle.context.timing_engine.resume_pending_effect(pilot_action_id, {"chosen_option_index": 0})
	await _pump_frames(10)
	# ⑤ power += 8（effect1 +4 + 01b 重跑 +4）
	if int(player_mech.power) != power_before + 8:
		return "推进双重生效 power 应+8(%d->%d)，实际: %d" % [power_before, power_before + 8, int(player_mech.power)]
	# ⑥ 推进进弃牌堆
	var thrust_card = gs.get_card(thrust_cid)
	if thrust_card == null or String(thrust_card.zone) != &"discard":
		return "推进应进弃牌堆，zone=%s" % String(thrust_card.zone if thrust_card else "null")
	_clear_all_pilot_static()
	return true
