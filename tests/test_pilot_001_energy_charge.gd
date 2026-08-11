## test_pilot_001_energy_charge.gd - 阿克罗姆 + 聚能双重生效验证
##
## 验证 pilot_001 对聚能(action_014)双重生效：第二次 REPEAT 也应弹选武器窗，
## 对所选武器再施加1层聚能。复现用户反馈"聚能没生效两次"。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


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


func _energy_stacks_for_weapon(mech, weapon_id: StringName) -> int:
	if mech == null:
		return 0
	for s: Dictionary in mech.statuses:
		if s.get("type", &"") == &"ENERGY_CHARGE" and s.get("weapon_id", &"") == weapon_id:
			return int(s.get("stacks", 1))
	return 0


## pilot_001 + 聚能 -> 01a确认 + 第一次选武器A聚能 + 01b REPEAT 第二次选武器B聚能
func test_pilot_001_energy_charge_double_active() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "机甲缺失"
	var weapon_ids: Array[StringName] = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家无机甲武器"
	var wid_a: StringName = weapon_ids[0]
	var wid_b: StringName = weapon_ids[1] if weapon_ids.size() > 1 else wid_a
	# pilot_001 -> player_mech
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	var charge_cid: StringName = _ensure_card_in_hand(battle, "action_014_聚能")
	if charge_cid == &"":
		return "找不到 action_014_聚能"
	gs.active_player_id = &"player"
	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	battle.execute_use_action_card(&"player", charge_cid)
	await _pump_frames(3)
	# ① 01a CHOOSE_ONE 确认（USE_ACTION_BEFORE）
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != &"choose_one_effect":
		return "应弹 choose_one_effect(01a确认)，实际: %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"chosen_option_index": 0})
	await _pump_frames(3)
	# ② 第一次 select_weapon_for_charge（energy_direct）
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != &"select_weapon_for_charge":
		return "第一次应弹 select_weapon_for_charge，实际: %s" % String(w2.get("input_type", &""))
	bridge.on_ui_confirmed({"selected_weapon_id": wid_a})
	await _pump_frames(5)
	# wid_a 应已 stacks=1
	if _energy_stacks_for_weapon(player_mech, wid_a) != 1:
		return "第一次聚能后 wid_a 应 stacks=1，实际: %d" % _energy_stacks_for_weapon(player_mech, wid_a)
	# ③ 第二次 select_weapon_for_charge（01b REPEAT 重跑 energy_direct）
	var w3: Dictionary = bridge.get_waiting_action_info()
	if String(w3.get("input_type", &"")) != &"select_weapon_for_charge":
		return "第二次(01b REPEAT)应弹 select_weapon_for_charge，实际: %s" % String(w3.get("input_type", &""))
	bridge.on_ui_confirmed({"selected_weapon_id": wid_b})
	await _pump_frames(5)
	# ④ 验证：wid_a stacks=1 + wid_b stacks=1（两次各选一把武器聚能）
	var sa: int = _energy_stacks_for_weapon(player_mech, wid_a)
	var sb: int = _energy_stacks_for_weapon(player_mech, wid_b)
	if wid_a == wid_b:
		# 同一把武器：应叠加 stacks=2
		if sa != 2:
			return "同武器双重生效应 stacks=2，实际: %d" % sa
	else:
		if sa != 1 or sb != 1:
			return "两把武器应各 stacks=1，实际 a=%d b=%d" % [sa, sb]
	_clear_all_pilot_static()
	return true
