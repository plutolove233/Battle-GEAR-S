## test_pilot_041_gaiqite.gd - 盖奇特（pilot_041，帝国 R）效果测试
##
## 盖奇特 1 个主动效果按钮（DIRECT，机师槽可点按钮）：
##   effect_01（每我方回合1次）「花费3金币抽2张行动牌」：无输入点，
##     GOLD_ABOVE(threshold=2 即金币≥3) 条件 + SPEND_GOLD(3) cost
##     -> EXECUTE_GAIN_CARD(action_deck, action, 2)。金币不足按钮置灰。
##
## 通用机制（复用菲丽丝 pilot_036 同款付费抽牌结构，不新增底层）：
##   · GOLD_ABOVE threshold=2 表达「金币≥3」支付门槛（按钮置灰条件，与 SPEND_GOLD cost 配合）
##   · EXECUTE_GAIN_CARD count=2 从行动牌堆抽2张
##   · once_per_turn_key/max 完全独立于基础 paid_draw（每回合1次）额度
##   · 与效果绑定（effect_id=pilot_041_effect_01）：任意卡牌 effect_ids 含此 id 即自动生效，无机师硬编码
##
## 关键覆盖点：
##   1. 效果定义（MODE_DIRECT + 条件 + NO_TARGET + once_per_turn_max=1 + 动作链）。
##   2. 完整流程：金币≥3 扣3金抽2张行动牌（无输入点直接完成）。
##   3. 每回合1次用满 -> 第2次触发被跳过（金币/手牌不变）。
##   4. 金币=2（<3）-> 条件不满足按钮置灰（不扣钱不抽牌）。
##   5. PVP3 多人类玩家通用：third 玩家触发按玩家隔离（金币/手牌只动 third 的）。
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
	battle.rng_seed = 90041
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


## 设盖奇特为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_gaiqite(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_041_盖奇特", owner_id)
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


## 清空玩家行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		p.action_hand.erase(cid)


## 触发盖奇特 DIRECT 按钮（effect_fire）。无输入直接完成返回 null。
func _fire_pilot_041(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
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


func _gold(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).gold


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


func _action_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.action_deck.size()


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：效果定义正确
func test_pilot_041_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_041_effect_01")
	if e1 == null:
		return "缺 pilot_041_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_041_effect_01":
		return "once_per_turn_key 应 pilot_041_effect_01"
	if int(e1.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1（我方回合1次）"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "GOLD_ABOVE"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	for c in e1.conditions:
		if String(c.get("op", &"")) == "GOLD_ABOVE" and int(c.get("threshold", -1)) != 2:
			return "effect_01 GOLD_ABOVE 阈值应2（金币≥3可点）"
	if String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	var e1_costs = e1.costs
	if e1_costs.size() != 1 or String(e1_costs[0].get("cost_type", &"")) != "SPEND_GOLD":
		return "effect_01 应有 SPEND_GOLD cost"
	if int(e1_costs[0].get("amount", 0)) != 3:
		return "effect_01 SPEND_GOLD 应 amount=3"
	var e1_acts = e1.actions
	if e1_acts.size() != 1:
		return "effect_01 应有1个动作 实=%d" % e1_acts.size()
	if String(e1_acts[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 动作0 应 EXECUTE_GAIN_CARD"
	var e1_p = e1_acts[0].get("params", {})
	if String(e1_p.get("from_zone", &"")) != "action_deck" or int(e1_p.get("count", 0)) != 2:
		return "effect_01 应从 action_deck 抽2张"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：完整流程——金币≥3 扣3金抽2张行动牌（无输入点直接完成）
func test_pilot_041_full_flow_spend3_draw2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gaiqite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 15
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_041(battle, s.pilot_card, s.mech, &"player", &"pilot_041_effect_01")
	if ef != null:
		return "effect_01 应无输入直接完成，实挂起"
	if _gold(battle, &"player") != 12:
		return "消耗3金币后金币应12 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "抽牌后行动手牌应2张 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before - 2:
		return "行动牌堆应-2 实变=%d" % (_action_deck_size(battle) - deck_before)
	return true


## 测试3：每回合1次用满 -> 第2次触发被跳过（金币/手牌不变）
func test_pilot_041_once_per_turn_max_1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gaiqite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 10
	# 第一次：完整发动（扣3抽2）
	var ef1 = await _fire_pilot_041(battle, s.pilot_card, s.mech, &"player", &"pilot_041_effect_01")
	if ef1 != null:
		return "第1次不应挂起"
	if _gold(battle, &"player") != 7:
		return "第1次后金币应7 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "第1次后行动手牌应2张 实=%d" % _action_hand_size(battle, &"player")
	# 第二次：once_per_turn 用满 -> 跳过，不挂起，金币/手牌不变
	var ef2 = await _fire_pilot_041(battle, s.pilot_card, s.mech, &"player", &"pilot_041_effect_01")
	if ef2 != null:
		return "第2次不应挂起（once_per_turn 用满）"
	if _gold(battle, &"player") != 7:
		return "第2次跳过不应扣钱 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 2:
		return "第2次跳过不应再抽牌 实=%d" % _action_hand_size(battle, &"player")
	return true


## 测试4：金币不足（<3）-> 条件不满足按钮置灰（不扣钱不抽牌）
func test_pilot_041_no_gold_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gaiqite(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	battle.context.game_state.players.get(&"player").gold = 2
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_041(battle, s.pilot_card, s.mech, &"player", &"pilot_041_effect_01")
	if ef != null:
		return "金币不足时 effect_01 不应挂起（按钮应置灰）"
	if _gold(battle, &"player") != 2:
		return "金币不足不应扣钱 实=%d" % _gold(battle, &"player")
	if _action_hand_size(battle, &"player") != 0:
		return "金币不足不应抽牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before:
		return "金币不足行动牌堆不应变化"
	return true


## 测试5：PVP3 多人类玩家通用——third 玩家触发 effect_01 按玩家隔离
func test_pilot_041_owner_actions_across_players() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_gaiqite(battle, &"third")
	if s.is_empty():
		return "third setup 失败（盖奇特设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	# player 给2张行动牌（不应被 third 效果触及）
	_add_action_to_hand(battle, &"player", "action_001_进攻")
	_add_action_to_hand(battle, &"player", "action_002_强袭")
	# third 清空行动手牌，金币设15
	_clear_action_hand(battle, &"third")
	gs.players.get(&"third").gold = 15
	var player_hand_before: int = _action_hand_size(battle, &"player")
	var ef1 = await _fire_pilot_041(battle, s.pilot_card, s.mech, &"third", &"pilot_041_effect_01")
	if ef1 != null:
		return "third effect_01 不应挂起"
	if gs.players.get(&"third").gold != 12:
		return "third effect_01 后 third 金币应12 实=%d" % gs.players.get(&"third").gold
	if _action_hand_size(battle, &"third") != 2:
		return "third effect_01 后 third 行动手牌应2 实=%d" % _action_hand_size(battle, &"third")
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "third effect_01 不应影响 player 手牌"
	return true


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
