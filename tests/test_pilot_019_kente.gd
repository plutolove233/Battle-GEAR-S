## test_pilot_019_kente.gd - 肯耳忒（pilot_019）缴械冲击 效果测试
##
## 效果（我方回合1次，DIRECT 按钮）：
##   选最多2台4格内其他机甲 -> 弹checkbox选自己≥1张行动牌(记X,弃X张) ->
##   逐目标(按选择顺序)暗牌选X+1张弃(X+1>目标手牌则直接弃全部) ->
##   弃完若目标行动牌被清空(原本≥1) -> 4伤害(直接扣HP,不吃护甲)。
##
## 阶段机（TimingEngine PILOT_019_DISCARD_CHAIN）挂起顺序：
##   目标多选(select_attack_target, target_kind=pilot_019)
##   -> 支付选牌(thrust_select) -> 逐目标暗牌弃牌(select_discard_cards)。
##
## 关键覆盖点：
##   1. effect_01 定义（MODE_DIRECT + once_per_turn_key + 3 conditions + NO_TARGET）。
##   2. 完整流程：选目标 -> 支付X=1 -> 目标弃X+1=2 -> 清空 -> 4伤害。
##   3. 目标手牌不足 X+1 -> 不弹窗直接弃全部 -> 清空 -> 4伤害。
##   4. 目标手牌空 -> 跳过该目标（原本无牌不伤害）。
##   5. 取消目标选择 / 支付选空 -> 中止不消耗 once_per_turn。
##   6. once_per_turn 用满 -> 第二次触发被跳过。
##   7. 多目标（2台）按顺序逐台处理。
##   8. 4格内无其他机甲 -> can_start 失败 -> deferred abort（不弹窗不消耗次数）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90019
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


func _set_pilot_on_mech(battle, owner_id: StringName, mech, pilot_def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, pilot_def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return card


## 清空玩家行动手牌（移回牌堆底）
func _clear_action_hand(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var p = gs.players.get(pid)
	if p == null:
		return
	for cid in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 给玩家行动手牌加一张牌，返回实例 id
func _add_card_to_hand(battle, pid: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 把 enemy 机甲移到指定位置（默认 (4,2)，距 player(2,2) 距离2）
func _move_enemy(battle, pos: Dictionary) -> void:
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech != null:
		enemy_mech.position = pos


## 设肯耳忒为 player 机师 + 移动 enemy 到 4 格内，返回 {pilot_card, mech, gs}
func _setup_kente(battle):
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var pilot_card = _set_pilot_on_mech(battle, &"player", mech, "pilot_019_肯耳忒")
	if pilot_card == null:
		return {}
	_move_enemy(battle, {"q": 4, "r": 2})
	return {"pilot_card": pilot_card, "mech": mech, "gs": gs}


## 触发肯耳忒 DIRECT 按钮（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_019(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_019_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_019_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## resume 目标选择：选中 target_ids（可多台），进入支付阶段
func _resume_targets(battle, ef_action, target_ids: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"target_ids": target_ids})
	await _pump_frames(4)


## resume 支付：弃 X 张自己行动牌，进入逐目标弃牌
func _resume_pay(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(8)


## resume 目标暗牌弃牌：弃 selected 张目标牌，判清空 -> 4伤害
func _resume_target_pick(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_action_card_ids": selected})
	await _pump_frames(8)


## 创建第二台敌方机甲（独立玩家 third，保证独立行动手牌）
func _create_second_enemy(battle, pos: Dictionary) -> _MechState:
	var gs = battle.context.game_state
	var p = _PlayerState.new()
	p.player_id = &"third"
	p.gold = 15
	p.is_human = true
	gs.players[&"third"] = p
	var m := _MechState.new()
	m.mech_id = &"third_mech"
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		m.slots[slot_id] = s
	gs.mechs[m.mech_id] = m
	return m


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确
func test_pilot_019_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_019_effect_01")
	if e == null:
		return "缺 pilot_019_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "mode 应 MODE_DIRECT 实=%s" % String(e.mode)
	if e.once_per_turn_key != &"pilot_019_effect_01":
		return "once_per_turn_key 应 pilot_019_effect_01"
	if int(e.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1"
	if int(e.priority) != 10:
		return "priority 应 10 实=%d" % int(e.priority)
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("IS_OWNER_MAIN_PHASE"):
		return "应含 IS_OWNER_MAIN_PHASE"
	if not ops.has("HAS_ACTION_CARD_IN_HAND"):
		return "应含 HAS_ACTION_CARD_IN_HAND"
	if not ops.has("HAS_OTHER_MECH_IN_HEX_RANGE"):
		return "应含 HAS_OTHER_MECH_IN_HEX_RANGE"
	if String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "target_rule 应 NO_TARGET"
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "PILOT_019_DISCARD_CHAIN":
		return "actions 应 [PILOT_019_DISCARD_CHAIN]"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：完整流程——player 弃 X=1，enemy 恰好2张 -> 弹暗牌弃牌窗 -> 弃2张清空 -> 4伤害
func test_pilot_019_full_flow_discard_clear_4_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kente(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# player 3张行动牌（X=1，弃1张后剩2）
	_clear_action_hand(battle, &"player")
	var p_card = _add_card_to_hand(battle, &"player", "action_001_进攻")
	if p_card == &"":
		return "缺 action_001_进攻"
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	# enemy 恰好2张（X+1=2，弹暗牌弃牌窗）
	_clear_action_hand(battle, &"enemy")
	var e1 = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	var e2 = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	if e1 == &"" or e2 == &"":
		return "enemy 手牌设置失败"
	var hp_before: int = enemy_mech.current_hp
	var ef = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹目标多选窗）"
	await _resume_targets(battle, ef, [enemy_mech.mech_id])
	# 此时应挂起在支付（thrust_select）
	if ef.state != &"waiting_timing":
		return "选完目标应挂起支付 实state=%s" % String(ef.state)
	await _resume_pay(battle, ef, [p_card])
	# 目标恰好2张 -> 弹暗牌弃牌窗（select_discard_cards）
	if ef.state != &"waiting_timing":
		return "支付后应挂起目标暗牌弃牌窗 实state=%s" % String(ef.state)
	await _resume_target_pick(battle, ef, [e1, e2])
	# 弃2张 -> enemy 手牌清空 -> 4伤害
	var enemy_player = gs.players.get(&"enemy")
	if not enemy_player.action_hand.is_empty():
		return "目标手牌应被清空 实剩=%d" % enemy_player.action_hand.size()
	if enemy_mech.current_hp != hp_before - 4:
		return "清空应造成4伤害 实扣=%d" % (hp_before - enemy_mech.current_hp)
	return true


## 测试3：目标手牌不足 X+1 -> 不弹窗直接弃全部 -> 清空 -> 4伤害
func test_pilot_019_target_insufficient_direct_discard_all() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kente(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var p_card = _add_card_to_hand(battle, &"player", "action_001_进攻")
	# enemy 仅1张（X+1=2 > 1）-> 直接弃全部
	_clear_action_hand(battle, &"enemy")
	var e1 = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	if p_card == &"" or e1 == &"":
		return "手牌设置失败"
	var hp_before: int = enemy_mech.current_hp
	var ef = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_targets(battle, ef, [enemy_mech.mech_id])
	await _resume_pay(battle, ef, [p_card])
	# 不足 X+1 -> 无暗牌弃牌窗，直接弃全部 -> 清空 -> 4伤害
	if gs.players.get(&"enemy").action_hand.size() != 0:
		return "不足 X+1 应直接弃全部 实剩=%d" % gs.players.get(&"enemy").action_hand.size()
	if enemy_mech.current_hp != hp_before - 4:
		return "清空应造成4伤害 实扣=%d" % (hp_before - enemy_mech.current_hp)
	return true


## 测试4：目标手牌空 -> 跳过该目标（无牌不伤害）
func test_pilot_019_target_empty_hand_no_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kente(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var p_card = _add_card_to_hand(battle, &"player", "action_001_进攻")
	_clear_action_hand(battle, &"enemy")
	if p_card == &"":
		return "手牌设置失败"
	var hp_before: int = enemy_mech.current_hp
	var ef = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_targets(battle, ef, [enemy_mech.mech_id])
	await _resume_pay(battle, ef, [p_card])
	# 目标手牌空 -> 跳过 -> 无伤害，效果完成
	if enemy_mech.current_hp != hp_before:
		return "目标无行动牌不应伤害"
	return true


## 测试5：取消目标选择 -> 中止，不消耗 once_per_turn（可再触发）
func test_pilot_019_cancel_targets_abort_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kente(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	_clear_action_hand(battle, &"enemy")
	_add_card_to_hand(battle, &"enemy", "action_001_进攻")
	var ef = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	# 取消目标选择
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(4)
	# 未弃牌
	if gs.players.get(&"player").action_hand.size() != 1:
		return "取消不应弃 player 牌"
	if gs.players.get(&"enemy").action_hand.size() != 1:
		return "取消不应弃 enemy 牌"
	# once_per_turn 未消耗：可再触发
	var ef2 = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "取消中止后应可再触发"
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"cancelled": true})
	return true


## 测试6：支付选空 -> 中止（不发动，不消耗次数）
func test_pilot_019_pay_empty_abort() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kente(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	_clear_action_hand(battle, &"enemy")
	_add_card_to_hand(battle, &"enemy", "action_001_进攻")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var hp_before: int = enemy_mech.current_hp
	var ef = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_targets(battle, ef, [enemy_mech.mech_id])
	# 支付选空 -> 中止
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": []})
	await _pump_frames(4)
	if enemy_mech.current_hp != hp_before:
		return "支付选空不应伤害"
	if gs.players.get(&"enemy").action_hand.size() != 1:
		return "支付选空不应弃 enemy 牌"
	return true


## 测试7：once_per_turn 用满 -> 第二次触发被跳过（不挂起）
func test_pilot_019_once_per_turn_used_up() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kente(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var p_card = _add_card_to_hand(battle, &"player", "action_001_进攻")
	_clear_action_hand(battle, &"enemy")
	var e1 = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	# 第一次：完整发动（enemy 1张不足X+1=2 -> 直接弃全部 -> 4伤害）
	var ef = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "第一次未挂起"
	await _resume_targets(battle, ef, [enemy_mech.mech_id])
	await _resume_pay(battle, ef, [p_card])
	var hp_after_first: int = enemy_mech.current_hp
	# 第二次：once_per_turn 用满 -> _execute_effect 跳过，effect_fire 不挂起
	var ef2 = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef2 != null:
		return "once_per_turn 用满第二次不应挂起"
	if enemy_mech.current_hp != hp_after_first:
		return "第二次不应再伤害"
	return true


## 测试8：多目标（2台，独立玩家）按顺序逐台处理
func test_pilot_019_multi_target_sequential() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kente(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var third_mech = _create_second_enemy(battle, {"q": 6, "r": 2})
	if third_mech == null:
		return "创建 third 机甲失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var p_card = _add_card_to_hand(battle, &"player", "action_001_进攻")
	_clear_action_hand(battle, &"enemy")
	var e1 = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	# third 手牌1张（不足 X+1=2 -> 直接弃全部 -> 4伤害）
	var t1 = _add_card_to_hand(battle, &"third", "action_001_进攻")
	if p_card == &"" or e1 == &"" or t1 == &"":
		return "手牌设置失败"
	var hp1_before: int = enemy_mech.current_hp
	var hp3_before: int = third_mech.current_hp
	var ef = await _fire_pilot_019(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_targets(battle, ef, [enemy_mech.mech_id, third_mech.mech_id])
	await _resume_pay(battle, ef, [p_card])
	# 两个目标都是1张 < X+1=2 -> 各直接弃全部 -> 各4伤害
	if enemy_mech.current_hp != hp1_before - 4:
		return "目标1应4伤害 实扣=%d" % (hp1_before - enemy_mech.current_hp)
	if third_mech.current_hp != hp3_before - 4:
		return "目标2应4伤害 实扣=%d" % (hp3_before - third_mech.current_hp)
	if gs.players.get(&"enemy").action_hand.size() != 0:
		return "目标1手牌应清空"
	if gs.players.get(&"third").action_hand.size() != 0:
		return "目标2手牌应清空"
	return true


## 测试9：4格内无其他机甲 -> can_start 失败 -> deferred abort（不弹窗不消耗次数）
func test_pilot_019_no_mech_in_range_abort() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var pilot_card = _set_pilot_on_mech(battle, &"player", mech, "pilot_019_肯耳忒")
	if pilot_card == null:
		return "setup 失败"
	# 不移动 enemy（(20,-6)，距 player(2,2) 远 > 4）
	_clear_action_hand(battle, &"player")
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	var ef = await _fire_pilot_019(battle, pilot_card, mech, &"player")
	if ef != null:
		return "4格外无其他机甲不应挂起（can_start 失败应 abort）"
	return true
