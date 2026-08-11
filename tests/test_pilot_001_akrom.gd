## test_pilot_001_akrom.gd - 阿克罗姆（pilot_001）双重生效测试
##
## 验证重构后的双重生效机制：
##   01a LISTEN USE_ACTION_BEFORE：非迎击行动牌弹窗确认（确认消耗每回合1次，取消不消耗）
##   01b LISTEN USE_ACTION_AFTER + requires_effect=01a：自动 REPEAT 重跑 DIRECT 效果链
##   迎击牌排除（一次攻击只能被响应一次）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


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


## 构造一个已注册的 use_action_card 动作（running 态），fire USE_ACTION_* 时点用。
func _make_use_action_card(battle, mech_id: StringName, card, owner_id: StringName) -> _Action:
	var use_action := _Action.new()
	use_action.action_id = &"test_p001_%d" % [randi() % 1000000]
	use_action.action_type = &"use_action_card"
	use_action.record = {
		"card_instance_id": card.instance_id,
		"card_def_id": card.def.card_id,
		"mech_id": mech_id,
		"source_mech_id": mech_id,
		"player_id": owner_id,
		"is_virtual": false,
		"virtual_transform": false,
	}
	use_action.state = &"running"
	use_action.context = battle.context
	use_action.source = {"mech_id": mech_id, "player_id": owner_id}
	battle.context.action_registry.register(use_action)
	return use_action


## 测试1：01a 对进攻牌触发 CHOOSE_ONE + 确认消耗每回合1次
func test_pilot_001_01a_confirm_consumes_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "player 机甲缺失"
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	var player = gs.players.get(&"player")
	var atk_card = _make_instance(gs, cdb, "action_001_进攻", &"player")
	if atk_card == null:
		return "找不到 action_001_进攻"
	player.action_hand.append(atk_card.instance_id)
	var te = battle.context.timing_engine
	var use_action := _make_use_action_card(battle, player_mech.mech_id, atk_card, &"player")
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, use_action)
	if use_action.state != &"waiting_timing":
		return "01a 应对进攻牌触发 CHOOSE_ONE 挂起，state=%s" % String(use_action.state)
	var _pend: Dictionary = te._pending_effect.get(use_action.action_id, {})
	var _pend_eff = _pend.get("effect", null)
	if _pend_eff == null or String(_pend_eff.effect_id) != "pilot_001_effect_01a":
		return "挂起 effect 应为 01a，实=%s" % String(_pend_eff.effect_id if _pend_eff != null else "null")
	# 确认（option 0：使该行动牌的效果再生效1次）
	te.resume_pending_effect(use_action.action_id, {"chosen_option_index": 0})
	# once_per_turn 应消耗（绑 pilot 牌实例）。use_action 手动无 steps，resume 后 continue_action
	# 立即完成会 clear_executed_effects_for_action 清掉 _executed_effects，故不查 executed，
	# 改查 once_per_turn_used（不被 clear）以证明确认路径完整执行到 _mark_once_per_turn_used。
	var _once_key: String = "%s:%s" % [String(pilot_card.instance_id), "pilot_001_effect_01"]
	var _once_map: Dictionary = te._once_per_turn_used.get(_once_key, {})
	if int(_once_map.get(0, 0)) < 1:
		return "确认后 once_per_turn 应消耗（pilot=%s），once_map=%s" % [String(pilot_card.instance_id), str(te._once_per_turn_used)]
	# once_per_turn 已消耗：第2次 use_action_card 不触发 01a（line 976 once_per_turn_used_up 跳过）
	var atk_card2 = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(atk_card2.instance_id)
	var use_action2 := _make_use_action_card(battle, player_mech.mech_id, atk_card2, &"player")
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, use_action2)
	if use_action2.state == &"waiting_timing":
		return "01a once_per_turn 已消耗，第2次不应触发"
	_clear_all_pilot_static()
	return true


## 测试2：01a 取消不消耗每回合1次（第2次仍可触发）
func test_pilot_001_01a_cancel_keeps_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	var player = gs.players.get(&"player")
	var atk_card = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(atk_card.instance_id)
	var te = battle.context.timing_engine
	var use_action := _make_use_action_card(battle, player_mech.mech_id, atk_card, &"player")
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, use_action)
	if use_action.state != &"waiting_timing":
		return "01a 应触发 CHOOSE_ONE 挂起"
	# 取消
	te.resume_pending_effect(use_action.action_id, {"cancelled": true})
	if te._executed_effects.get(use_action.action_id, {}).get("pilot_001_effect_01a", false):
		return "取消后 01a 不应 executed"
	# once_per_turn 未消耗：第2次 use_action_card 仍触发 01a
	var atk_card2 = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(atk_card2.instance_id)
	var use_action2 := _make_use_action_card(battle, player_mech.mech_id, atk_card2, &"player")
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, use_action2)
	if use_action2.state != &"waiting_timing":
		return "取消不消耗，第2次 01a 应仍触发，state=%s" % String(use_action2.state)
	_clear_all_pilot_static()
	return true


## 测试3：01a 对迎击牌不触发（一次攻击只能被响应一次）
func test_pilot_001_01a_skips_counter_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	var player = gs.players.get(&"player")
	var counter_card = _make_instance(gs, cdb, "action_010_反击", &"player")
	if counter_card == null:
		return "找不到 action_010_反击"
	player.action_hand.append(counter_card.instance_id)
	var te = battle.context.timing_engine
	var use_action := _make_use_action_card(battle, player_mech.mech_id, counter_card, &"player")
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, use_action)
	if use_action.state == &"waiting_timing":
		return "01a 不应对迎击牌触发 CHOOSE_ONE"
	_clear_all_pilot_static()
	return true


## 测试4：01b requires_effect=01a--01a 确认后 fire USE_ACTION_AFTER 触发 REPEAT 创建第二次 attack
func test_pilot_001_01b_repeats_after_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	var player = gs.players.get(&"player")
	var atk_card = _make_instance(gs, cdb, "action_001_进攻", &"player")
	if atk_card == null:
		return "找不到 action_001_进攻"
	player.action_hand.append(atk_card.instance_id)
	var te = battle.context.timing_engine
	var use_action := _make_use_action_card(battle, player_mech.mech_id, atk_card, &"player")
	# 模拟 01a 已确认（标记 executed，满足 01b requires_effect=01a）
	te._mark_effect_executed(&"pilot_001_effect_01a", use_action.action_id)
	# fire USE_ACTION_AFTER，01b 触发 REPEAT 重跑 DIRECT（EXECUTE_ATTACK）
	te.fire_timing(_TimingConst.USE_ACTION_AFTER, use_action)
	# REPEAT 创建 attack 子动作 -> use_action_card waiting_effect_action
	if use_action.state != &"waiting_effect_action":
		return "01b REPEAT 应创建 attack 子动作挂起，state=%s" % String(use_action.state)
	if use_action.pending_effect_action_ids.is_empty():
		return "01b REPEAT 应创建 attack 子动作（pending 非空）"
	var sub_id: StringName = use_action.pending_effect_action_ids[0]
	var sub = battle.context.action_registry.get_action(sub_id)
	if sub == null or sub.action_type != &"attack":
		return "REPEAT 创建的子动作应为 attack，实=%s" % String(sub.action_type if sub != null else "null")
	_clear_all_pilot_static()
	return true


## 测试5：01b requires_effect=01a--01a 未确认（取消/未触发）时 01b 不触发 REPEAT
func test_pilot_001_01b_skipped_without_01a_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var pilot_card = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"player")
	if pilot_card == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	var player = gs.players.get(&"player")
	var atk_card = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(atk_card.instance_id)
	var te = battle.context.timing_engine
	var use_action := _make_use_action_card(battle, player_mech.mech_id, atk_card, &"player")
	# 不标记 01a executed（模拟取消/未确认）
	te.fire_timing(_TimingConst.USE_ACTION_AFTER, use_action)
	# 01b requires_effect=01a 未满足，不应触发 REPEAT
	if use_action.state == &"waiting_effect_action":
		return "01a 未确认时 01b 不应触发 REPEAT 创建子动作"
	if not use_action.pending_effect_action_ids.is_empty():
		return "01a 未确认时 01b 不应创建 attack 子动作"
	_clear_all_pilot_static()
	return true
