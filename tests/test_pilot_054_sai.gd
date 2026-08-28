## test_pilot_054_sai.gd - 萨伊（pilot_054，秩序 R）效果测试
##
## 萨伊 1 个主动效果按钮（DIRECT，机师槽可点按钮）：
##   effect_01（每我方回合2次）「弃1行动抽1装」：弹单选窗列持有者所有行动牌
##     （OWNER_ACTION_HAND 通用来源，min_count=1 必选、可取消不计次数），
##     选1张弃置 -> 抽1张装备牌（equipment_deck）。
##     无行动牌可弃按钮置灰（HAS_ACTION_CARD_IN_HAND count=1 条件）。
##
## 通用机制（后续可复用，纯通用组装不新增底层）：
##   · HAS_ACTION_CARD_IN_HAND params.count 表达「至少 N 张行动牌」门槛（按钮置灰）
##   · CHOOSE_MANY_CARDS OWNER_ACTION_HAND 来源（列出持有者所有行动牌）+ store_result_key
##   · store_result_key 确认路径才 mark once_per_turn（取消不计次数）
##   · once_per_turn_key/max 表达「我方回合2次」
##   · EXECUTE_DISCARD -> EXECUTE_GAIN_CARD(equipment_deck) 弃1抽1链
##
## 关键覆盖点：
##   1. 效果定义（MODE_DIRECT + once_per_turn_max=2 + 条件 + NO_TARGET + 3 动作链）。
##   2. 完整流程：选1张行动牌 -> 弃置 -> 抽1张装备牌（装备手牌+1、装备牌堆-1）。
##   3. 取消选择 -> 中止不弃牌不抽牌不消耗次数（可再触发）。
##   4. 每回合2次用满 -> 第3次触发被跳过。
##   5. 无行动牌 -> HAS_ACTION_CARD_IN_HAND 条件不满足按钮置灰（不弹窗）。
##   6. PVP3 多人类玩家通用：third 玩家触发按玩家隔离（弃/抽只动 third 的）。
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
	battle.rng_seed = 90052
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


## 设萨伊为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_saier(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_054_萨伊", owner_id)
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


## 触发萨伊 DIRECT 按钮（effect_fire）。
## 需要输入（CHOOSE_MANY_CARDS）返回挂起的 effect_fire action；无输入直接完成返回 null。
func _fire_pilot_054(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
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


## resume 选择窗：选中 selected 张牌确认（store_result_key 路径，弃置+抽牌续跑）
func _resume_select(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(12)


## resume 取消选择窗（中止，不消耗次数）
func _resume_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


func _equip_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).equipment_hand.size()


func _equip_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.equipment_deck.size()


## 检查 cid 是否在行动牌弃牌堆
func _in_action_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：效果定义正确
func test_pilot_054_effect_definition() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_054_effect_01")
	if e1 == null:
		return "缺 pilot_054_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_054_effect_01":
		return "once_per_turn_key 应 pilot_054_effect_01"
	if int(e1.once_per_turn_max) != 2:
		return "once_per_turn_max 应 2（我方回合2次）"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	for c in e1.conditions:
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND":
			if int(c.get("params", {}).get("count", -1)) != 1:
				return "effect_01 HAS_ACTION_CARD_IN_HAND count 应1（至少1张行动牌可弃）"
	if String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	var e1_costs = e1.costs
	if not (e1_costs is Array) or e1_costs.size() != 0:
		return "effect_01 不应有 cost（费用走动作链选牌弃置）"
	var e1_acts = e1.actions
	if e1_acts.size() != 3:
		return "effect_01 应有3个动作 实=%d" % e1_acts.size()
	if String(e1_acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "effect_01 动作0 应 CHOOSE_MANY_CARDS"
	var cm_p = e1_acts[0].get("params", {})
	if String(cm_p.get("source", &"")) != "OWNER_ACTION_HAND":
		return "effect_01 选择来源应 OWNER_ACTION_HAND"
	if int(cm_p.get("max_count", 0)) != 1 or int(cm_p.get("min_count", 0)) != 1:
		return "effect_01 应 max_count=1 min_count=1（必选1张）"
	if String(cm_p.get("store_result_key", &"")) != "pilot_054_discard_ids":
		return "effect_01 store_result_key 应 pilot_054_discard_ids"
	if String(e1_acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "effect_01 动作1 应 EXECUTE_DISCARD"
	if String(e1_acts[2].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 动作2 应 EXECUTE_GAIN_CARD"
	var eg_p = e1_acts[2].get("params", {})
	if String(eg_p.get("from_zone", &"")) != "equipment_deck":
		return "effect_01 抽牌来源应 equipment_deck"
	if String(eg_p.get("card_kind", &"")) != "equipment":
		return "effect_01 抽牌种类应 equipment"
	if int(eg_p.get("count", 0)) != 1:
		return "effect_01 抽牌数量应1"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：完整流程——选1张行动牌 -> 弃置 -> 抽1张装备牌
func test_pilot_054_full_flow_discard_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_saier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var equip_hand_before: int = _equip_hand_size(battle, &"player")
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"player", &"pilot_054_effect_01")
	if ef == null:
		return "effect_01 未挂起（应弹选行动牌窗）"
	await _resume_select(battle, ef, [c1])
	if not _in_action_discard(battle, c1):
		return "被弃行动牌应在行动牌弃牌堆"
	if _action_hand_size(battle, &"player") != 1:
		return "弃1张后行动手牌应剩1张（c2） 实=%d" % _action_hand_size(battle, &"player")
	# 弃1抽1 -> 装备手牌 +1，装备牌堆 -1
	if _equip_hand_size(battle, &"player") != equip_hand_before + 1:
		return "弃1抽1后装备手牌应+1 实变=%d" % (_equip_hand_size(battle, &"player") - equip_hand_before)
	if _equip_deck_size(battle) != deck_before - 1:
		return "装备牌堆应-1 实变=%d" % (_equip_deck_size(battle) - deck_before)
	return true


## 测试3：取消选择 -> 中止，不弃牌不抽牌不消耗次数（可再触发）
func test_pilot_054_cancel_abort_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_saier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var equip_hand_before: int = _equip_hand_size(battle, &"player")
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"player", &"pilot_054_effect_01")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_cancel(battle, ef)
	if _in_action_discard(battle, c1) or _in_action_discard(battle, c2):
		return "取消不应弃牌"
	if _action_hand_size(battle, &"player") != 2:
		return "取消后行动手牌应仍2张 实=%d" % _action_hand_size(battle, &"player")
	if _equip_hand_size(battle, &"player") != equip_hand_before:
		return "取消不应抽牌"
	if _equip_deck_size(battle) != deck_before:
		return "取消装备牌堆不应变化"
	# 次数未消耗：可再触发
	var ef2 = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"player", &"pilot_054_effect_01")
	if ef2 == null:
		return "取消中止后应可再触发"
	await _resume_cancel(battle, ef2)
	return true


## 测试4：每回合2次用满 -> 第3次触发被跳过
func test_pilot_054_once_per_turn_max_2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_saier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	var c3 = _add_action_to_hand(battle, &"player", "action_003_猛击")
	if c1 == &"" or c2 == &"" or c3 == &"":
		return "行动牌设置失败"
	var equip_hand_before: int = _equip_hand_size(battle, &"player")
	# 第一次：完整发动（弃1抽1）
	var ef1 = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"player", &"pilot_054_effect_01")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_select(battle, ef1, [c1])
	# 第二次：完整发动（弃1抽1）
	var ef2 = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"player", &"pilot_054_effect_01")
	if ef2 == null:
		return "第2次未挂起"
	await _resume_select(battle, ef2, [c2])
	# 两次完整发动 -> 装备手牌 +2
	if _equip_hand_size(battle, &"player") != equip_hand_before + 2:
		return "两次完整发动后装备手牌应+2 实变=%d" % (_equip_hand_size(battle, &"player") - equip_hand_before)
	# 第三次：once_per_turn_max=2 用满 -> 跳过，不挂起，手牌/弃牌不变
	var deck_before: int = _equip_deck_size(battle)
	var ef3 = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"player", &"pilot_054_effect_01")
	if ef3 != null:
		return "第3次不应挂起（once_per_turn 用满）"
	if _equip_deck_size(battle) != deck_before:
		return "第3次跳过不应再抽牌"
	if _in_action_discard(battle, c3):
		return "第3次跳过不应弃牌"
	return true


## 测试5：无行动牌 -> HAS_ACTION_CARD_IN_HAND 条件不满足 -> 按钮置灰（不弹窗）
func test_pilot_054_no_action_card_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_saier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var equip_hand_before: int = _equip_hand_size(battle, &"player")
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"player", &"pilot_054_effect_01")
	if ef != null:
		return "无行动牌时 effect_01 不应挂起（按钮应置灰）"
	if _equip_hand_size(battle, &"player") != equip_hand_before:
		return "无行动牌不应抽牌"
	if _equip_deck_size(battle) != deck_before:
		return "无行动牌装备牌堆不应变化"
	return true


## 测试6：PVP3 多人类玩家通用——third 玩家触发按玩家隔离（弃/抽只动 third 的）
func test_pilot_054_owner_actions_across_players() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_saier(battle, &"third")
	if s.is_empty():
		return "third setup 失败（萨伊设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	# player 给2张行动牌（不应被 third 效果触及）
	var p1 = _add_action_to_hand(battle, &"player", "action_001_进攻")
	var p2 = _add_action_to_hand(battle, &"player", "action_002_强袭")
	# third 清空行动手牌，加2张自己的行动牌
	_clear_action_hand(battle, &"third")
	var t1 = _add_action_to_hand(battle, &"third", "action_003_猛击")
	var t2 = _add_action_to_hand(battle, &"third", "action_004_破甲")
	if t1 == &"" or t2 == &"":
		return "third 行动牌设置失败"
	var player_hand_before: int = _action_hand_size(battle, &"player")
	var third_equip_before: int = _equip_hand_size(battle, &"third")
	# third 完整发动：弃 t1 -> 抽1张装备
	var ef = await _fire_pilot_054(battle, s.pilot_card, s.mech, &"third", &"pilot_054_effect_01")
	if ef == null:
		return "third 触发 effect_01 未挂起"
	await _resume_select(battle, ef, [t1])
	if not _in_action_discard(battle, t1):
		return "third 被弃行动牌应在行动牌弃牌堆"
	if _in_action_discard(battle, p1) or _in_action_discard(battle, p2):
		return "player 的行动牌不应进弃牌堆"
	if _action_hand_size(battle, &"third") != 1:
		return "third 弃1后行动手牌应剩1张 实=%d" % _action_hand_size(battle, &"third")
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "third 触发不应影响 player 行动手牌"
	if _equip_hand_size(battle, &"third") != third_equip_before + 1:
		return "third 弃1抽1后装备手牌应+1 实变=%d" % (_equip_hand_size(battle, &"third") - third_equip_before)
	return true
