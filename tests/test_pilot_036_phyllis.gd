## test_pilot_036_phyllis.gd - 菲丽丝（pilot_036，联邦 R）效果测试
##
## 菲丽丝 2 个主动效果按钮（DIRECT，机师槽可点按钮）：
##   effect_01（每我方回合2次）「消耗2金币抽1张行动牌」：无输入点，
##     GOLD_ABOVE(threshold=1 即金币≥2) 条件 + SPEND_GOLD(2) cost
##     -> EXECUTE_GAIN_CARD(action_deck, action, 1)。金币不足按钮置灰。
##   effect_02（每我方回合1次）「弃置2张行动牌获得4金币」：
##     HAS_ACTION_CARD_IN_HAND(count=2) 条件 -> CHOOSE_MANY_CARDS(OWNER_ACTION_HAND, 2/2, store_result_key)
##     -> EXECUTE_DISCARD -> GAIN_GOLD(4)。取消选择不计次数（store_result_key 确认路径才 mark once_per_turn）。
##
## 通用机制（后续可复用）：
##   · GOLD_ABOVE threshold=1 表达「金币≥2」支付门槛（按钮置灰条件，与 SPEND_GOLD cost 配合）
##   · HAS_ACTION_CARD_IN_HAND params.count 表达「至少 N 张行动牌」门槛
##   · CHOOSE_MANY_CARDS OWNER_ACTION_HAND 来源（列出持有者所有行动牌）+ store_result_key
##   · once_per_turn_key/max 完全独立于基础 paid_draw（每回合1次）额度
##
## 关键覆盖点：
##   1. 两个效果定义（MODE_DIRECT + 条件 + NO_TARGET + once_per_turn_max=2/1 + 动作链）。
##   2. effect_01 完整流程：金币≥2 扣2金抽1张行动牌（无输入点直接完成）。
##   3. effect_02 完整流程：选2张行动牌 -> 弃置 -> +4金币。
##   4. 取消选择 -> 中止不弃牌不获金不消耗次数（可再触发）。
##   5. effect_01 每回合2次用满 -> 第3次触发被跳过（金币/手牌不变）。
##   6. effect_02 每回合1次用满 -> 第2次触发被跳过。
##   7. 金币=1（<2）-> effect_01 条件不满足按钮置灰（不扣钱不抽牌）。
##   8. 行动牌<2 -> effect_02 条件不满足按钮置灰（不弹窗）。
##   9. PVP3 多人类玩家通用：third 玩家触发 effect_01/02 按玩家隔离（金币/手牌/弃牌堆只动 third 的）。
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
	battle.rng_seed = 90036
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


## 设菲丽丝为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_felice(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_036_菲丽丝", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 创建独立玩家 third + 机甲（PVP3 多人），返回机甲；null 失败
func _create_third_player(battle) -> _MechState:
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
	m.position = {"q": 6, "r": 2}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿", &"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2", &"event", &"pilot"]:
		var sl := _MechSlotState.new()
		sl.slot_id = slot_id
		sl.slot_kind = &"PART"
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m
	return m


## 给玩家行动手牌加一张行动牌，返回实例 id
func _add_action_to_hand(battle, pid: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 清空玩家行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		p.action_hand.erase(cid)


## 触发菲丽丝 DIRECT 按钮（effect_fire）。
## 需要输入（CHOOSE_MANY_CARDS）返回挂起的 effect_fire action；无输入直接完成返回 null。
func _fire_pilot_036(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": effect_id,
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": effect_id,
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


## resume 选择窗：选中 selected 张牌确认（store_result_key 路径，弃置+获金续跑）
func _resume_select(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(12)


## resume 取消选择窗（中止，不消耗次数）
func _resume_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


func _gold(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).gold


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


func _action_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.action_deck.size()


## 检查 cid 是否在行动牌弃牌堆
func _in_action_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：两个效果定义正确
func test_pilot_036_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_036_effect_01")
	if e1 == null:
		return "缺 pilot_036_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_036_effect_01":
		return "once_per_turn_key 应 pilot_036_effect_01"
	if int(e1.once_per_turn_max) != 2:
		return "once_per_turn_max 应 2（我方回合2次）"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "GOLD_ABOVE"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	for c in e1.conditions:
		if String(c.get("op", &"")) == "GOLD_ABOVE" and int(c.get("threshold", -1)) != 1:
			return "effect_01 GOLD_ABOVE 阈值应1（金币≥2可点）"
	if String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	var e1_costs = e1.costs
	if e1_costs.size() != 1 or String(e1_costs[0].get("cost_type", &"")) != "SPEND_GOLD":
		return "effect_01 应有 SPEND_GOLD cost"
	if int(e1_costs[0].get("amount", 0)) != 2:
		return "effect_01 SPEND_GOLD 应 amount=2"
	var e1_acts = e1.actions
	if e1_acts.size() != 1:
		return "effect_01 应有1个动作 实=%d" % e1_acts.size()
	if String(e1_acts[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 动作0 应 EXECUTE_GAIN_CARD"
	var e1_p = e1_acts[0].get("params", {})
	if String(e1_p.get("from_zone", &"")) != "action_deck" or int(e1_p.get("count", 0)) != 1:
		return "effect_01 应从 action_deck 抽1张"

	var e2 = effects.get(&"pilot_036_effect_02")
	if e2 == null:
		return "缺 pilot_036_effect_02"
	if e2.mode != _TimingConst.MODE_DIRECT:
		return "effect_02 mode 应 MODE_DIRECT 实=%s" % String(e2.mode)
	if e2.once_per_turn_key != &"pilot_036_effect_02":
		return "once_per_turn_key 应 pilot_036_effect_02"
	if int(e2.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1（我方回合1次）"
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND"]:
		if not e2_ops.has(need):
			return "effect_02 应含条件 %s" % need
	var e2_acts = e2.actions
	if e2_acts.size() != 3:
		return "effect_02 应有3个动作 实=%d" % e2_acts.size()
	if String(e2_acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "effect_02 动作0 应 CHOOSE_MANY_CARDS"
	var cm_p = e2_acts[0].get("params", {})
	if String(cm_p.get("source", &"")) != "OWNER_ACTION_HAND":
		return "effect_02 选择来源应 OWNER_ACTION_HAND"
	if int(cm_p.get("max_count", 0)) != 2 or int(cm_p.get("min_count", 0)) != 2:
		return "effect_02 应 max_count=2 min_count=2"
	if String(cm_p.get("store_result_key", &"")) != "pilot_036_discard_ids":
		return "effect_02 store_result_key 应 pilot_036_discard_ids"
	if String(e2_acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "effect_02 动作1 应 EXECUTE_DISCARD"
	if String(e2_acts[2].get("type", &"")) != "GAIN_GOLD":
		return "effect_02 动作2 应 GAIN_GOLD"
	if int(e2_acts[2].get("params", {}).get("amount", 0)) != 4:
		return "effect_02 GAIN_GOLD 应 amount=4"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：effect_01 完整流程——金币≥2 扣2金抽1张行动牌（无输入点直接完成）
func test_pilot_036_effect1_spend2_draw1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_felice(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 15
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_01")
	if ef != null:
		return "effect_01 应无输入直接完成，实挂起"
	if _gold(battle, &"player") != 13:
		return "消耗2金币后金币应13 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 1:
		return "抽牌后行动手牌应1张 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before - 1:
		return "行动牌堆应-1 实变=%d" % (_action_deck_size(battle) - deck_before)
	return true


## 测试3：effect_02 完整流程——选2张行动牌 -> 弃置 -> +4金币
func test_pilot_036_effect2_discard2_gain4() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_felice(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 10
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var ef = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_02")
	if ef == null:
		return "effect_02 未挂起（应弹选行动牌窗）"
	await _resume_select(battle, ef, [c1, c2])
	if _gold(battle, &"player") != 14:
		return "弃2行动后金币应14 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 0:
		return "弃置2张后行动手牌应0 实=%d" % _action_hand_size(battle, &"player")
	if not _in_action_discard(battle, c1) or not _in_action_discard(battle, c2):
		return "被弃2张行动牌应在行动牌弃牌堆"
	return true


## 测试4：取消选择 -> 中止，不弃牌不获金不消耗次数（可再触发）
func test_pilot_036_effect2_cancel_abort_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_felice(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 10
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var ef = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_02")
	if ef == null:
		return "effect_02 未挂起"
	await _resume_cancel(battle, ef)
	if _gold(battle, &"player") != 10:
		return "取消不应获金 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "取消不应弃牌 实=%d" % _action_hand_size(battle, &"player")
	if _in_action_discard(battle, c1) or _in_action_discard(battle, c2):
		return "取消不应有牌进弃牌堆"
	# 次数未消耗：可再触发
	var ef2 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_02")
	if ef2 == null:
		return "取消中止后应可再触发"
	await _resume_cancel(battle, ef2)
	return true


## 测试5：effect_01 每回合2次用满 -> 第3次触发被跳过
func test_pilot_036_effect1_once_per_turn_max_2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_felice(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 10
	# 第一次
	var ef1 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_01")
	if ef1 != null:
		return "第1次不应挂起"
	if _gold(battle, &"player") != 8:
		return "第1次后金币应8 实=%d" % _gold(battle, &"player")
	# 第二次
	var ef2 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_01")
	if ef2 != null:
		return "第2次不应挂起"
	if _gold(battle, &"player") != 6:
		return "第2次后金币应6 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "两次完整发动后行动手牌应2张 实=%d" % _action_hand_size(battle, &"player")
	# 第三次：once_per_turn_max=2 用满 -> 跳过，金币/手牌不变
	var ef3 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_01")
	if ef3 != null:
		return "第3次不应挂起（once_per_turn 用满）"
	if _gold(battle, &"player") != 6:
		return "第3次跳过不应扣钱 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "第3次跳过不应再抽牌 实=%d" % _action_hand_size(battle, &"player")
	return true


## 测试6：effect_02 每回合1次用满 -> 第2次触发被跳过
func test_pilot_036_effect2_once_per_turn_max_1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_felice(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 10
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	var c3 = _add_action_to_hand(battle, &"player", "action_003_猛击")
	var c4 = _add_action_to_hand(battle, &"player", "action_004_破甲")
	if c1 == &"" or c2 == &"" or c3 == &"" or c4 == &"":
		return "行动牌设置失败"
	# 第一次：完整发动（弃2获4）
	var ef1 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_02")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_select(battle, ef1, [c1, c2])
	if _gold(battle, &"player") != 14:
		return "第1次后金币应14 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "第1次后行动手牌应2张 实=%d" % _action_hand_size(battle, &"player")
	# 第二次：once_per_turn 用满 -> 跳过，不挂起，金币/手牌不变
	var ef2 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_02")
	if ef2 != null:
		return "第2次不应挂起（once_per_turn 用满）"
	if _gold(battle, &"player") != 14:
		return "第2次跳过不应获金 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "第2次跳过不应弃牌 实=%d" % _action_hand_size(battle, &"player")
	return true


## 测试7：金币不足（<2）-> effect_01 条件不满足按钮置灰（不扣钱不抽牌）
func test_pilot_036_effect1_no_gold_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_felice(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 1
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_01")
	if ef != null:
		return "金币不足时 effect_01 不应挂起（按钮应置灰）"
	if _gold(battle, &"player") != 1:
		return "金币不足不应扣钱 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 0:
		return "金币不足不应抽牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before:
		return "金币不足行动牌堆不应变化"
	return true


## 测试8：行动牌不足2张 -> effect_02 条件不满足按钮置灰（不弹窗）
func test_pilot_036_effect2_no_action_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_felice(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 10
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	if c1 == &"":
		return "行动牌设置失败"
	var ef = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"player", &"pilot_036_effect_02")
	if ef != null:
		return "行动牌<2时 effect_02 不应挂起（按钮应置灰）"
	if _gold(battle, &"player") != 10:
		return "行动牌不足不应获金 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 1:
		return "行动牌不足不应弃牌 实=%d" % _action_hand_size(battle, &"player")
	return true


## 测试9：PVP3 多人类玩家通用——third 玩家触发 effect_01/02 按玩家隔离
func test_pilot_036_owner_actions_across_players() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_felice(battle, &"third")
	if s.is_empty():
		return "third setup 失败（菲丽丝设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	# player 给2张行动牌（不应被 third 效果触及）
	var p1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var p2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	# third 清空行动手牌，金币设15
	_clear_action_hand(battle, &"third")
	gs.players.get(&"third").gold = 15
	var player_hand_before: int = _action_hand_size(battle, &"player")
	# effect_01：third 扣2金抽1，player 手牌不动
	var ef1 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"third", &"pilot_036_effect_01")
	if ef1 != null:
		return "third effect_01 不应挂起"
	if gs.players.get(&"third").gold != 13:
		return "third effect_01 后 third 金币应13 实=%d" % gs.players.get(&"third").gold
	if _action_hand_size(battle, &"third") != 1:
		return "third effect_01 后 third 行动手牌应1 实=%d" % _action_hand_size(battle, &"third")
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "third effect_01 不应影响 player 手牌"
	# effect_02：third 加2张行动牌 -> 选2弃 -> +4金，player 不动
	var t1 = _add_action_to_hand(battle, &"third", "action_003_猛击")
	var t2 = _add_action_to_hand(battle, &"third", "action_004_破甲")
	if t1 == &"" or t2 == &"":
		return "third 行动牌设置失败"
	var ef2 = await _fire_pilot_036(battle, s.pilot_card, s.mech, &"third", &"pilot_036_effect_02")
	if ef2 == null:
		return "third effect_02 未挂起"
	await _resume_select(battle, ef2, [t1, t2])
	if gs.players.get(&"third").gold != 17:
		return "third effect_02 后 third 金币应17 实=%d" % gs.players.get(&"third").gold
	if _action_hand_size(battle, &"third") != 1:
		return "third effect_02 弃2后 third 行动手牌应1（effect_01抽的1张） 实=%d" % _action_hand_size(battle, &"third")
	if not _in_action_discard(battle, t1) or not _in_action_discard(battle, t2):
		return "third 被弃2张应在行动牌弃牌堆"
	if _in_action_discard(battle, p1) or _in_action_discard(battle, p2):
		return "player 的行动牌不应进弃牌堆"
	return true
