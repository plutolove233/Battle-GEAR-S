## test_pilot_042_derendi.gd - 德伦迪（pilot_042，帝国 R）效果测试
##
## 德伦迪 2 个效果按钮：
##   effect_01（按钮1，被动 LISTEN DISCARD_AFTER）「弃牌回补」：每次弃置自己的行动牌
##     （仅从行动手牌 action_hand 弃置，用户裁定）后，强制抽1张行动牌。按「次」触发：
##     一次弃置动作（无论弃几张）只 fire 一次 DISCARD_AFTER，故只抽1张。触发源覆盖
##     主动/被动效果弃牌、回合结束超限弃牌等（DeckService.discard_card 走 discard_card 动作）。
##     时序：DISCARD_AFTER 先于 DISCARD_SETTLE，天然在肯耳忒(pilot_019)「弃后0张」检查前抽牌。
##   effect_02（按钮2，主动 DIRECT）「弃牌换牌」：我方回合2次，弹窗选「弃置1张行动牌」或
##     「弃置所有行动牌，之后再抽1张行动牌」或取消。取消不计次数；选分支即消耗1次
##     （显式 MARK_EFFECT_ONCE_PER_TURN_USED）。空手按钮置灰（HAS_ACTION_CARD_IN_HAND minimum=1）。
##     弃置走 EXECUTE_DISCARD（弃1张：CHOOSE_MANY_CARDS 恰好选1张 no_cancel；弃所有：通用
##     discard_all_action_hand 参数），弃置结算后 EXECUTE_GAIN_CARD 再抽1。
##
## 通用机制（不新增硬编码，全部与效果 id 绑定）：
##   · DISCARD_INCLUDED_OWNER_ACTION_CARD 通用条件（from_zone=action_hand 可选参数）
##   · discard_all_action_hand 通用弃牌参数（弃置某玩家全部行动手牌）
##   · 额度机制 EFFECT_ONCE_PER_TURN_AVAILABLE + MARK_EFFECT_ONCE_PER_TURN_USED（pilot_037/038 同款）
##   · EXECUTE_GAIN_CARD mech_ids 挂到持有者机甲，保证再弃置时 from_mech_id 归属正确
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
	battle.rng_seed = 90042
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


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


## 设德伦迪为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_delendi(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_042_德伦迪", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
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


## 给玩家行动手牌加一张行动牌（mech_id 挂到所属机甲，与真实抽取行为一致：卡牌 mech_id=抽取机甲），
## 返回实例 id
func _add_action_to_hand(battle, pid: StringName, def_id: String, mech_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	card.mech_id = mech_id
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


func _action_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.action_deck.size()


func _in_action_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


## 触发德伦迪 DIRECT 按钮（effect_02）。弹窗挂起返回 effect_fire action；条件不满足/直接完成返回 null。
func _fire_pilot_042_e2(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_042_effect_02",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_042_effect_02",
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


## resume 首层二选一（选分支）：chosen_option_index 0=弃1张 1=弃所有
func _resume_choose(battle, ef_action, option_index: int) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"chosen_option_index": option_index})
	await _pump_frames(4)


## resume 取消首层二选一（取消不计次数）
func _resume_choose_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


## resume 选牌窗（弃1张的 CHOOSE_MANY_CARDS 恰好选1张确认）
func _resume_select(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(15)


## 真实弃置动作（走 discard_card 动作，fire DISCARD_AFTER/SETTLE 触发德伦迪监听）
func _real_discard(battle, pid: StringName, card_ids: Array, reason: StringName) -> void:
	battle.context.action_service.execute(&"discard_card", {
		"card_ids": card_ids,
		"reason": reason,
		"executor": &"system_default",
		"source": {"player_id": pid},
	})
	await _pump_frames(15)


## mock fire DISCARD_AFTER 时点（直接测 effect_01 监听条件）。返回 mock action。
func _fire_discard_after_mock(battle, snapshots: Array) -> _Action:
	var mock := _Action.new()
	mock.action_id = &"test_p042_da_%d" % [randi() % 1000000]
	mock.action_type = &"discard_card"
	mock.record = {"discard_snapshots": snapshots}
	mock.state = &"running"
	mock.context = battle.context
	battle.context.action_registry.register(mock)
	battle.context.timing_engine.fire_timing(_TimingConst.DISCARD_AFTER, mock)
	return mock


## 构造一条弃牌快照
func _snap(card_id: StringName, card_kind: String, from_mech_id: StringName, from_zone: String, reason: StringName = &"test") -> Dictionary:
	return {
		"card_id": card_id,
		"card_kind": card_kind,
		"from_mech_id": from_mech_id,
		"from_zone": from_zone,
		"reason": reason,
	}


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：两个效果定义正确
func test_pilot_042_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	# effect_01 被动
	var e1 = effects.get(&"pilot_042_effect_01")
	if e1 == null:
		return "缺 pilot_042_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_01 listen_timing 应 DISCARD_AFTER"
	if String(e1.listen_action_type) != "discard_card":
		return "effect_01 listen_action_type 应 discard_card"
	var e1_conds: Array = []
	for c in e1.conditions:
		e1_conds.append(String(c.get("op", &"")))
	if not e1_conds.has("DISCARD_INCLUDED_OWNER_ACTION_CARD"):
		return "effect_01 应含 DISCARD_INCLUDED_OWNER_ACTION_CARD 条件"
	for c in e1.conditions:
		if String(c.get("op", &"")) == "DISCARD_INCLUDED_OWNER_ACTION_CARD":
			var c_params = c.get("params", {})
			if String(c_params.get("from_zone", &"")) != "action_hand":
				return "effect_01 条件 from_zone 应 action_hand（仅从手牌弃置触发）"
	var e1_acts = e1.actions
	if e1_acts.size() != 1 or String(e1_acts[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 动作0 应 EXECUTE_GAIN_CARD"
	var e1_p = e1_acts[0].get("params", {})
	if String(e1_p.get("from_zone", &"")) != "action_deck" or int(e1_p.get("count", 0)) != 1:
		return "effect_01 应从 action_deck 抽1张"
	if String(e1_p.get("player_id", &"")) != "$binding_context.player_id":
		return "effect_01 抽牌 player_id 应绑定持有者玩家"
	# effect_02 主动
	var e2 = effects.get(&"pilot_042_effect_02")
	if e2 == null:
		return "缺 pilot_042_effect_02"
	if e2.mode != _TimingConst.MODE_DIRECT:
		return "effect_02 mode 应 MODE_DIRECT 实=%s" % String(e2.mode)
	var e2_conds: Array = []
	for c in e2.conditions:
		e2_conds.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "EFFECT_ONCE_PER_TURN_AVAILABLE", "HAS_ACTION_CARD_IN_HAND"]:
		if not e2_conds.has(need):
			return "effect_02 应含条件 %s" % need
	for c in e2.conditions:
		if String(c.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			var c_p = c.get("params", {})
			if String(c_p.get("once_per_turn_key", &"")) != "pilot_042_effect_02" or int(c_p.get("once_per_turn_max", 0)) != 2:
				return "effect_02 额度应为 pilot_042_effect_02 max=2（我方回合2次）"
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND":
			if int(c.get("params", {}).get("minimum", 0)) != 1:
				return "effect_02 空手按钮应置灰（HAS_ACTION_CARD_IN_HAND minimum=1）"
	var e2_acts = e2.actions
	if e2_acts.size() != 1 or String(e2_acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_02 动作0 应 CHOOSE_ONE"
	var co_params = e2_acts[0].get("params", {})
	if not bool(co_params.get("optional", false)):
		return "effect_02 CHOOSE_ONE 应 optional=true（可取消不计次）"
	var opts: Array = co_params.get("options", [])
	if opts.size() != 2:
		return "effect_02 应2个分支 实=%d" % opts.size()
	# 分支0：弃1张
	var opt0: Dictionary = opts[0]
	if String(opt0.get("label", &"")) != "弃置1张行动牌":
		return "分支0 label 应 弃置1张行动牌"
	var opt0_types: Array = []
	for a in opt0.get("actions", []):
		opt0_types.append(String(a.get("type", &"")))
	if opt0_types != ["CHOOSE_MANY_CARDS", "MARK_EFFECT_ONCE_PER_TURN_USED", "EXECUTE_DISCARD"]:
		return "分支0 动作应为 [选牌,计次,弃置] 实=%s" % str(opt0_types)
	var opt0_cm = opt0.get("actions", [])[0].get("params", {})
	if String(opt0_cm.get("source", &"")) != "OWNER_ACTION_HAND" or int(opt0_cm.get("min_count", 0)) != 1 or int(opt0_cm.get("max_count", 0)) != 1:
		return "分支0 选牌应 OWNER_ACTION_HAND 恰好1张"
	if not bool(opt0_cm.get("no_cancel", false)):
		return "分支0 选牌应 no_cancel=true（必须选恰好1张）"
	var opt0_disc = opt0.get("actions", [])[2].get("params", {})
	if String(opt0_disc.get("card_ids", &"")) != "$runtime.pilot_042_discard_one":
		return "分支0 弃置应引用选牌结果"
	# 分支1：弃所有
	var opt1: Dictionary = opts[1]
	if String(opt1.get("label", &"")) != "弃置所有行动牌，之后再抽1张行动牌":
		return "分支1 label 应 弃置所有行动牌，之后再抽1张行动牌"
	var opt1_types: Array = []
	for a in opt1.get("actions", []):
		opt1_types.append(String(a.get("type", &"")))
	if opt1_types != ["MARK_EFFECT_ONCE_PER_TURN_USED", "EXECUTE_DISCARD", "EXECUTE_GAIN_CARD"]:
		return "分支1 动作应为 [计次,弃所有,抽1] 实=%s" % str(opt1_types)
	var opt1_disc = opt1.get("actions", [])[1].get("params", {})
	if not bool(opt1_disc.get("discard_all_action_hand", false)):
		return "分支1 弃置应 discard_all_action_hand=true（弃全部手牌行动牌）"
	var opt1_gain = opt1.get("actions", [])[2].get("params", {})
	if String(opt1_gain.get("from_zone", &"")) != "action_deck" or int(opt1_gain.get("count", 0)) != 1:
		return "分支1 之后应抽1张行动牌"
	return true


# ═══════════════════════════════════════════
# effect_01 行为测试（被动弃牌回补）
# ═══════════════════════════════════════════

## 测试2：真实弃置自己的行动牌 -> 触发 effect_01 抽1张（净手牌 2-1+1=2，牌堆-1）
func test_pilot_042_effect1_real_discard_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭", s.mech.mech_id)
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var deck_before: int = _action_deck_size(battle)
	await _real_discard(battle, &"player", [c1], &"test_discard")
	if _action_hand_size(battle, &"player") != 2:
		return "弃1张后德伦迪应回补1张（净2）实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before - 1:
		return "行动牌堆应-1（德伦迪抽1）变=%d" % (_action_deck_size(battle) - deck_before)
	if not _in_action_discard(battle, c1):
		return "弃置牌应在弃牌堆"
	return true


## 测试3：一次弃置动作弃多张 -> 只触发1次（按次，非按张）
func test_pilot_042_effect1_once_per_discard_action() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭", s.mech.mech_id)
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var deck_before: int = _action_deck_size(battle)
	await _real_discard(battle, &"player", [c1, c2], &"test_discard")
	# 弃2张只回补1张：2-2+1=1
	if _action_hand_size(battle, &"player") != 1:
		return "一次弃置动作（2张）应只回补1张 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before - 1:
		return "行动牌堆应只-1 变=%d" % (_action_deck_size(battle) - deck_before)
	return true


## 测试4：mock 条件过滤——只算自己的行动牌从手牌弃置
func test_pilot_042_effect1_condition_filter() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var mech = s.mech
	var gs = s.gs
	# 场景a：装备牌弃置不触发
	var deck_a: int = _action_deck_size(battle)
	var hand_a: int = _action_hand_size(battle, &"player")
	await _fire_discard_after_mock(battle, [_snap(&"eq_1", "equipment", mech.mech_id, "action_hand")])
	await _pump_frames(6)
	if _action_hand_size(battle, &"player") != hand_a:
		return "弃装备牌不应触发抽牌"
	# 场景b：他人机甲的行动牌弃置不触发（from_mech_id 非持有者机甲）
	await _fire_discard_after_mock(battle, [_snap(&"act_other", "action", &"enemy_mech", "action_hand")])
	await _pump_frames(6)
	if _action_hand_size(battle, &"player") != hand_a:
		return "他人行动牌弃置不应触发抽牌"
	# 场景c：自己的行动牌从临时区（转化）弃置不触发（from_zone 非 action_hand）
	await _fire_discard_after_mock(battle, [_snap(&"act_tmp", "action", mech.mech_id, "temp_zone")])
	await _pump_frames(6)
	if _action_hand_size(battle, &"player") != hand_a:
		return "转化临时区弃置不应触发抽牌（仅从手牌）"
	if _action_deck_size(battle) != deck_a:
		return "不应有任何抽牌消耗牌堆"
	# 场景d：自己的行动牌从手牌弃置 -> 触发抽1
	var deck_d: int = _action_deck_size(battle)
	var hand_d: int = _action_hand_size(battle, &"player")
	await _fire_discard_after_mock(battle, [_snap(&"act_self", "action", mech.mech_id, "action_hand")])
	await _pump_frames(10)
	if _action_hand_size(battle, &"player") != hand_d + 1:
		return "自己的行动牌从手牌弃置应触发抽1 实=%d" % (_action_hand_size(battle, &"player") - hand_d)
	if _action_deck_size(battle) != deck_d - 1:
		return "触发后牌堆应-1"
	return true


## 测试5：混合弃置（自己的行动牌+装备牌）-> 触发1次
func test_pilot_042_effect1_mixed_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	if c1 == &"":
		return "行动牌设置失败"
	# mock 混入装备牌快照：只要含1张自己的手牌行动牌即触发1次
	var deck_before: int = _action_deck_size(battle)
	var hand_before: int = _action_hand_size(battle, &"player")
	await _fire_discard_after_mock(battle, [
		_snap(c1, "action", s.mech.mech_id, "action_hand"),
		_snap(&"eq_2", "equipment", s.mech.mech_id, "action_hand"),
	])
	await _pump_frames(10)
	if _action_hand_size(battle, &"player") != hand_before + 1:
		return "混合弃置含自己行动牌应触发抽1 实=%d" % (_action_hand_size(battle, &"player") - hand_before)
	if _action_deck_size(battle) != deck_before - 1:
		return "触发后牌堆应-1"
	return true


# ═══════════════════════════════════════════
# effect_02 行为测试（主动弃牌换牌）
# ═══════════════════════════════════════════

## 测试6：弃1张全流程——选分支->选恰好1张->弃置（触发效果1回补）->净手牌不变
func test_pilot_042_effect2_discard_one_full() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭", s.mech.mech_id)
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_02 应挂起首层二选一"
	await _resume_choose(battle, ef, 0)
	# 选1张确认弃置
	await _resume_select(battle, ef, [c1])
	# 弃1张 + 效果1回补1 = 净0变化（2-1+1=2）
	if _action_hand_size(battle, &"player") != 2:
		return "弃1张后手牌应2（弃1补1）实=%d" % _action_hand_size(battle, &"player")
	if not _in_action_discard(battle, c1):
		return "选中牌应进弃牌堆"
	if _action_deck_size(battle) != deck_before - 1:
		return "效果1回补应消耗牌堆1张 变=%d" % (_action_deck_size(battle) - deck_before)
	return true


## 测试7：弃所有全流程——弃全部手牌行动牌（触发效果1）+ 之后再抽1 -> 共补2张
func test_pilot_042_effect2_discard_all_full() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭", s.mech.mech_id)
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_02 应挂起首层二选一"
	await _resume_choose(battle, ef, 1)
	await _pump_frames(20)
	# 弃全部2张 -> 效果1在DISCARD_AFTER回补1 -> 结算后再抽1 -> 净2张
	if _action_hand_size(battle, &"player") != 2:
		return "弃所有后应共回补2张（效果1+之后抽1）实=%d" % _action_hand_size(battle, &"player")
	if not _in_action_discard(battle, c1) or not _in_action_discard(battle, c2):
		return "弃所有后全部牌应在弃牌堆"
	if _action_deck_size(battle) != deck_before - 2:
		return "应消耗牌堆2张（效果1抽1+之后抽1）变=%d" % (_action_deck_size(battle) - deck_before)
	return true


## 测试8：取消首层二选一 -> 不弃牌不抽牌、次数不消耗（可再次触发）
func test_pilot_042_effect2_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭", s.mech.mech_id)
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_02 应挂起首层二选一"
	await _resume_choose_cancel(battle, ef)
	if _action_hand_size(battle, &"player") != 2:
		return "取消不应弃牌 实=%d" % _action_hand_size(battle, &"player")
	if _action_deck_size(battle) != deck_before:
		return "取消不应抽牌"
	# 次数未消耗：可再次触发
	var ef2 = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "取消后应可再次触发 effect_02"
	await _resume_choose_cancel(battle, ef2)
	return true


## 测试9：每回合2次用满 -> 第3次触发被跳过（按钮置灰，不弹窗不弃牌）
func test_pilot_042_effect2_twice_per_turn_max() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var c1 = _add_action_to_hand(battle, &"player", "action_001_进攻", s.mech.mech_id)
	var c2 = _add_action_to_hand(battle, &"player", "action_002_强袭", s.mech.mech_id)
	if c1 == &"" or c2 == &"":
		return "行动牌设置失败"
	var deck_before: int = _action_deck_size(battle)
	# 第1次：弃1张
	var ef1 = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef1 == null:
		return "第1次应挂起"
	await _resume_choose(battle, ef1, 0)
	await _resume_select(battle, ef1, [c1])
	# 第2次：弃所有
	var ef2 = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "第2次应挂起"
	await _resume_choose(battle, ef2, 1)
	await _pump_frames(20)
	# 第3次：额度用满 -> 跳过，不挂起
	var ef3 = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef3 != null:
		return "第3次不应挂起（每回合2次用满）"
	var hand_final: int = _action_hand_size(battle, &"player")
	var deck_final: int = _action_deck_size(battle)
	await _pump_frames(6)
	if _action_hand_size(battle, &"player") != hand_final:
		return "第3次跳过不应再动手牌"
	if _action_deck_size(battle) != deck_final:
		return "第3次跳过不应再抽牌"
	return true


## 测试10：行动手牌为空 -> 按钮条件不满足，effect_02 不发动（置灰）
func test_pilot_042_effect2_empty_hand_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_delendi(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	_clear_action_hand(battle, &"player")
	var deck_before: int = _action_deck_size(battle)
	var ef = await _fire_pilot_042_e2(battle, s.pilot_card, s.mech, &"player")
	if ef != null:
		return "空手时 effect_02 不应挂起（按钮应置灰）"
	if _action_hand_size(battle, &"player") != 0:
		return "空手时不应抽牌"
	if _action_deck_size(battle) != deck_before:
		return "空手时牌堆不应变化"
	return true


# ═══════════════════════════════════════════
# PVP3 多人类玩家通用
# ═══════════════════════════════════════════

## 测试11：PVP3 third 玩家持有德伦迪 -> 弃牌回补只动 third 的，不影响 player
func test_pilot_042_pvp3_owner_isolation() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_delendi(battle, &"third")
	if s.is_empty():
		return "third setup 失败（德伦迪设置到 third 机甲）"
	var player_hand_before: int = _action_hand_size(battle, &"player")
	var deck_before: int = _action_deck_size(battle)
	# third 弃置自己的行动牌 -> 只给 third 回补1张
	var t1 = _add_action_to_hand(battle, &"third", "action_001_进攻", third_mech.mech_id)
	var t2 = _add_action_to_hand(battle, &"third", "action_002_强袭", third_mech.mech_id)
	if t1 == &"" or t2 == &"":
		return "third 行动牌设置失败"
	await _real_discard(battle, &"third", [t1], &"test_discard")
	# third 手牌：0 + 2(添加) - 1(弃) + 1(回补) = 2
	if _action_hand_size(battle, &"third") != 2:
		return "third 弃1张后应回补1张（净=2）实=%d" % _action_hand_size(battle, &"third")
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "third 弃牌不应影响 player 手牌"
	if _action_deck_size(battle) != deck_before - 1:
		return "third 回补应消耗牌堆1张"
	# player 弃自己的牌 -> third（德伦迪持有者）不应回补
	var deck_before2: int = _action_deck_size(battle)
	var p1 = _add_action_to_hand(battle, &"player", "action_003_猛击", battle.context.game_state.get_mech_for_player(&"player").mech_id)
	if p1 == &"":
		return "player 行动牌设置失败"
	var third_before2: int = _action_hand_size(battle, &"third")
	await _real_discard(battle, &"player", [p1], &"test_discard")
	if _action_hand_size(battle, &"third") != third_before2:
		return "player 弃牌不应给 third（德伦迪）回补"
	if _action_deck_size(battle) != deck_before2:
		return "player 弃牌不应消耗牌堆（无德伦迪回补）"
	return true
