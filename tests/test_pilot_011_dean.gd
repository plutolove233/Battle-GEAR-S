## test_pilot_011_dean.gd - 迪恩（pilot_011）效果测试
##
## 2 效果重构（用户口述 2026-08-10）：
##   effect_01 迪恩--响应：AVAILABILITY ATTACK_AT，迪恩被攻击时，每回合1次，
##     选择转化使用的2张行动牌（移 temp_zone 不触发时点），弹二选一（当作疾行/反击，optional=false），
##     转化时立即回复4动力，执行结算后抽1张行动牌。
##   effect_02 迪恩--挡攻：AVAILABILITY ATTACK_AT（set_conditions fall-through），相邻其他机甲被攻击
##     且迪恩在攻击范围内时，同样每回合1次（共享 pilot_011_effect_01 转化额度），转化后先将攻击目标
##     改为迪恩自身（REDIRECT + 回退 PRE 重 fire），再二选一当作疾行/反击响应。
##   pilot_011_counter_strike：当作反击转化后，绑原攻击 ATTACK_SETTLE 的反击攻击效果2。
## 转化执行链（响应选中）：response_discard 选2张 -> _pay_costs（temp_zone）-> CHOOSE_ONE 二选一挂起
## -> resume chosen_option_index -> 执行分支（RESTORE_POWER(4) -> RESPOND_ATTACK -> 移动 -> 抽1）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _AttackAction = preload("res://scripts/action_defs/attack_action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 77711
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura），避免跨测试泄漏
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


## 设迪恩为 player_mech 机师，返回 {player_mech, enemy_mech, pilot_card, gs}；失败返回空。
func _setup_dean(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_instance(gs, cdb, "pilot_011_迪恩", &"player")
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	return {"player_mech": player_mech, "enemy_mech": enemy_mech, "pilot_card": card, "gs": gs}


## 给 player 补 N 张行动牌（从牌堆顶抽），返回 [cid,...]。
func _give_action_cards(battle, count: int) -> Array:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var out: Array = []
	for i in range(count):
		if gs.deck_state.action_deck.is_empty():
			break
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		player.action_hand.append(cid)
		var c = gs.get_card(cid)
		if c != null:
			c.zone = &"action_hand"
			c.owner_player_id = &"player"
		out.append(cid)
	return out


## 清空 player 行动手牌（移回牌堆底，测试用占位）
func _clear_action_hand(battle) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	if player == null:
		return
	for cid in player.action_hand.duplicate():
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


func _make_attack(battle, attacker_id: StringName, target_id: StringName, weapon_range: int = 2) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p011_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_might": 5,
		"weapon_range": weapon_range,
		"extra_range": 0,
		"target_count": 1,
	}
	attack.state = &"waiting_timing"
	attack.context = battle.context
	attack.source = {"player_id": &"enemy", "mech_id": attacker_id}
	battle.context.action_registry.register(attack)
	return attack


## 断开 action_needs_input 自动 resume（避免 single_move 被自动驱动）
func _disconnect_needs_input(te) -> void:
	for _c in te.action_needs_input.get_connections():
		te.action_needs_input.disconnect(_c.callable)


## 构造迪恩效果的响应选中条目（sel: Array[Dictionary]）
func _make_sel(pilot_card, eff, ap: int) -> Array[Dictionary]:
	return [{
		"effect_id": eff.effect_id,
		"card_instance_id": pilot_card.instance_id,
		"effect": eff,
		"availability_priority": ap,
	}]


## 执行迪恩转化的完整两步：选中 -> response_discard 选2张 -> 二选一选分支
## 返回：失败信息字符串；成功返回 ""。选项 index：0=当作疾行，1=当作反击。
func _run_conversion(te, attack, hand_cards: Array, branch: int) -> String:
	if not te._pending_effect.has(attack.action_id):
		return "选中后应挂起 _pending_effect 等弃牌选择"
	var p0 = te._pending_effect[attack.action_id]
	if String(p0.get("phase", &"")) != "response_discard":
		return "应进入 response_discard 阶段 实=%s" % String(p0.get("phase", &""))
	te.resume_pending_effect(attack.action_id, {"selected_action_card_ids": [hand_cards[0], hand_cards[1]], "cancelled": false})
	# 弃牌 + _pay_costs 后，CHOOSE_ONE 未选 -> 挂起二选一（phase=pre_actions_target）
	if not te._pending_effect.has(attack.action_id):
		return "弃牌后应挂起 CHOOSE_ONE 二选一（pre_actions_target）"
	var p1 = te._pending_effect[attack.action_id]
	if String(p1.get("phase", &"")) != "pre_actions_target":
		return "应进入 pre_actions_target 二选一 实=%s" % String(p1.get("phase", &""))
	if not bool(attack.record.get("_waiting_for_choose_one", false)):
		return "应设 _waiting_for_choose_one 标志"
	# 选分支
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": branch})
	return ""


# ═══════════════════════════════════════════
# effect_01 迪恩--响应（当作疾行/反击转化）
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（含二选一分支）
func test_pilot_011_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_01")
	if e == null:
		return "缺 pilot_011_effect_01"
	if e.mode != _TimingConst.MODE_AVAILABILITY:
		return "effect_01 mode 应 AVAILABILITY 实=%s" % String(e.mode)
	if e.availability_condition != _TimingConst.AVAIL_RESPOND_ATTACK:
		return "effect_01 availability_condition 应 AVAIL_RESPOND_ATTACK 实=%s" % String(e.availability_condition)
	if int(e.availability_priority) != 5:
		return "effect_01 availability_priority 应 5 实=%d" % int(e.availability_priority)
	if e.listen_timing != _TimingConst.ATTACK_AT:
		return "effect_01 listen_timing 应 ATTACK_AT"
	if e.once_per_turn_key != &"pilot_011_effect_01":
		return "effect_01 once_per_turn_key 应 pilot_011_effect_01"
	if int(e.once_per_turn_max) != 1:
		return "effect_01 once_per_turn_max 应 1"
	# conditions: HAS_ACTION_CARD_IN_HAND(2) + ATTACK_NOT_RESPONDED
	var has_hand2 := false
	var has_not_responded := false
	for c in e.conditions:
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND" and int(c.get("params", {}).get("count", 0)) == 2:
			has_hand2 = true
		if String(c.get("op", &"")) == "ATTACK_NOT_RESPONDED":
			has_not_responded = true
	if not has_hand2:
		return "effect_01 conditions 应含 HAS_ACTION_CARD_IN_HAND(2)"
	if not has_not_responded:
		return "effect_01 conditions 应含 ATTACK_NOT_RESPONDED"
	# costs: DISCARD_ACTION_CARD count=2 + label="选择转化使用的2张行动牌"
	var has_discard2 := false
	var label_ok := false
	for c in e.costs:
		if String(c.get("cost_type", &"")) == "DISCARD_ACTION_CARD" and int(c.get("count", 0)) == 2:
			has_discard2 = true
			label_ok = String(c.get("params", {}).get("label", "")) == "选择转化使用的2张行动牌"
	if not has_discard2:
		return "effect_01 costs 应含 DISCARD_ACTION_CARD count=2"
	if not label_ok:
		return "effect_01 弃牌 cost label 应『选择转化使用的2张行动牌』（不是弃置）"
	# actions: [CHOOSE_ONE(options 2)]
	var acts = e.actions
	if acts.size() != 1:
		return "effect_01 actions 应1个（CHOOSE_ONE 二选一）实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 actions[0] 应 CHOOSE_ONE 实=%s" % String(acts[0].get("type", &""))
	var options = acts[0].get("params", {}).get("options", [])
	if options.size() != 2:
		return "effect_01 CHOOSE_ONE options 应2个（当作疾行/当作反击）实=%d" % options.size()
	# 疾行分支 5 项：RESTORE_POWER(4)->RESPOND_ATTACK->EXECUTE_SINGLE_MOVE(全动力)->EXECUTE_GAIN_CARD(1)->DISCARD_TEMP_ZONE_CARDS
	var dash: Array = options[0].get("actions", [])
	if String(options[0].get("label", "")) != "当作疾行":
		return "option0 label 应『当作疾行』实=%s" % String(options[0].get("label", ""))
	if dash.size() != 5:
		return "当作疾行分支 actions 应5个 实=%d" % dash.size()
	if String(dash[0].get("type", &"")) != "RESTORE_POWER" or int(dash[0].get("params", {}).get("amount", 0)) != 4:
		return "当作疾行 actions[0] 应 RESTORE_POWER amount=4"
	if String(dash[0].get("params", {}).get("mech_id", &"")) != "$binding_context.mech_id":
		return "当作疾行 RESTORE_POWER 应 mech_id=$binding_context.mech_id"
	if String(dash[1].get("type", &"")) != "RESPOND_ATTACK":
		return "当作疾行 actions[1] 应 RESPOND_ATTACK"
	if String(dash[2].get("type", &"")) != "EXECUTE_SINGLE_MOVE" or not bool(dash[2].get("params", {}).get("use_current_power", false)):
		return "当作疾行 actions[2] 应 EXECUTE_SINGLE_MOVE use_current_power=true"
	if String(dash[3].get("type", &"")) != "EXECUTE_GAIN_CARD" or int(dash[3].get("params", {}).get("count", 0)) != 1:
		return "当作疾行 actions[3] 应 EXECUTE_GAIN_CARD count=1"
	# 反击分支 5 项：RESTORE_POWER(4)->RESPOND_ATTACK->REGISTER_LISTEN(counter_strike)->EXECUTE_SINGLE_MOVE(半动力)->DISCARD_TEMP_ZONE_CARDS
	var counter: Array = options[1].get("actions", [])
	if String(options[1].get("label", "")) != "当作反击":
		return "option1 label 应『当作反击』实=%s" % String(options[1].get("label", ""))
	if counter.size() != 5:
		return "当作反击分支 actions 应5个 实=%d" % counter.size()
	if String(counter[2].get("type", &"")) != "REGISTER_LISTEN":
		return "当作反击 actions[2] 应 REGISTER_LISTEN"
	var rl = counter[2].get("params", {})
	if String(rl.get("timing", &"")) != "ATTACK_SETTLE" or String(rl.get("listen_effect_id", &"")) != "pilot_011_counter_strike":
		return "当作反击 REGISTER_LISTEN 应绑 ATTACK_SETTLE + pilot_011_counter_strike"
	if String(counter[3].get("type", &"")) != "EXECUTE_SINGLE_MOVE" or float(counter[3].get("params", {}).get("power_fraction", 0.0)) != 0.5:
		return "当作反击 actions[3] 应 EXECUTE_SINGLE_MOVE power_fraction=0.5（半动力，反击移动）"
	return true


## 测试2：被攻击+≥2行动牌时，effect_01 出现在响应窗口
func test_pilot_011_effect_01_available_when_attacked_with_2_cards() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return "setup 失败（缺 pilot_011_迪恩）"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	_clear_action_hand(battle)
	if _give_action_cards(battle, 2).size() < 2:
		return "无法补2张行动牌"
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_01":
			return true
	return "被攻击+2张牌时，响应窗口应含 pilot_011_effect_01（实=%d 项）" % avail.size()


## 测试3：<2张行动牌时，effect_01 不出现在响应窗口
func test_pilot_011_effect_01_hidden_when_fewer_than_2_cards() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	_clear_action_hand(battle)
	_give_action_cards(battle, 1)
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_01":
			return "仅1张行动牌时，effect_01 不应出现在响应窗口（HAS_ACTION_CARD_IN_HAND(2) 不满足）"
	return true


## 测试4：迪恩被攻击者锁定时，effect_01 不出现在响应窗口（AVAIL_RESPOND_ATTACK 锁封锁）
func test_pilot_011_effect_01_hidden_when_locked() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	_clear_action_hand(battle)
	_give_action_cards(battle, 2)
	player_mech.add_status({"type": &"LOCKED", "source_player_id": &"enemy"})
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_01":
			return "迪恩被攻击者锁定时，effect_01 不应出现在响应窗口"
	return true


## 测试5：选中 effect_01 -> 弃2张（temp_zone）-> 二选一选「当作疾行」-> responded + 回复4 + 移动挂起
func test_pilot_011_effect_01_conversion_dash_respond_restore() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 3)
	if hand_cards.size() < 3:
		return "无法补3张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_01")
	var sel = _make_sel(pilot_card, eff, 5)
	te.handle_response_selection(attack.action_id, sel)
	var hand_before: int = gs.players[&"player"].action_hand.size()
	var err = _run_conversion(te, attack, hand_cards, 0)
	if err != "":
		return err
	# responded=true（RESPOND_ATTACK 已执行）
	if attack.record.get("responded", false) != true:
		return "responded 应为 true"
	# 弃2张
	if gs.players[&"player"].action_hand.size() != hand_before - 2:
		return "应弃2张牌 before=%d after=%d" % [hand_before, gs.players[&"player"].action_hand.size()]
	# 2张燃料牌移入临时区（非立即入弃牌堆）
	var fc0 = gs.get_card(hand_cards[0])
	var fc1 = gs.get_card(hand_cards[1])
	if fc0 == null or String(fc0.zone) != "temp_zone":
		return "燃料牌0应在temp_zone 实=%s" % (String(fc0.zone) if fc0 != null else "null")
	if fc1 == null or String(fc1.zone) != "temp_zone":
		return "燃料牌1应在temp_zone 实=%s" % (String(fc1.zone) if fc1 != null else "null")
	# 回复4动力（RESTORE_POWER 在 EXECUTE_SINGLE_MOVE 挂起前已执行）
	if player_mech.power != 4:
		return "迪恩动力应回复到4 实=%d" % player_mech.power
	# EXECUTE_SINGLE_MOVE 创建挂起子动作 -> attack waiting_effect_action
	if attack.state != &"waiting_effect_action":
		return "转化后 attack 应 waiting_effect_action（等 single_move 完成）实=%s" % String(attack.state)
	return true


## 测试6：每回合1次 -- 同回合第2次攻击，effect_01 不再出现
func test_pilot_011_effect_01_once_per_turn_second_attack_hidden() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 4)
	if hand_cards.size() < 4:
		return "无法补4张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	var attack1 = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_01")
	te.handle_response_selection(attack1.action_id, _make_sel(pilot_card, eff, 5))
	var err = _run_conversion(te, attack1, hand_cards, 0)
	if err != "":
		return err
	# 第2次攻击（同回合）：effect_01 应因 once_per_turn 已用满而隐藏
	var attack2 = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	if gs.players[&"player"].action_hand.size() < 2:
		return "前置错误：第2次攻击时手牌应>=2 实=%d" % gs.players[&"player"].action_hand.size()
	var avail2 = te.get_available_cards(_TimingConst.ATTACK_AT, attack2)
	for entry in avail2:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_01":
			return "同回合第2次攻击，effect_01 应因 once_per_turn 已用满而隐藏"
	return true


## 测试7：effect_01 当作反击分支 -- 弃2 + 回复4 + 注册 counter_strike 监听器
func test_pilot_011_effect_01_conversion_counter_registers() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 3)
	if hand_cards.size() < 3:
		return "无法补3张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_01")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 5))
	var err = _run_conversion(te, attack, hand_cards, 1)
	if err != "":
		return err
	if attack.record.get("responded", false) != true:
		return "responded 应为 true"
	if player_mech.power != 4:
		return "迪恩动力应回复到4 实=%d" % player_mech.power
	# REGISTER_LISTEN 在 EXECUTE_SINGLE_MOVE 挂起前已执行：注册 pilot_011_counter_strike 绑原攻击
	var settle_listeners: Array = te.temporary_listeners.get(_TimingConst.ATTACK_SETTLE, [])
	for le: Dictionary in settle_listeners:
		var le_eff = le.get("effect")
		if le_eff != null and String(le_eff.effect_id) == "pilot_011_counter_strike":
			if String(le.get("action_id", &"")) == String(attack.action_id):
				return true
	return "应注册 pilot_011_counter_strike 监听器绑定原攻击 action_id"


## 测试8：pilot_011_counter_strike 定义 + 原攻击 ATTACK_SETTLE 时点触发反击攻击子动作
func test_pilot_011_counter_strike_fires_on_settle() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var cs = effects.get(&"pilot_011_counter_strike")
	if cs == null:
		return "缺 pilot_011_counter_strike"
	if cs.mode != _TimingConst.MODE_LISTEN or cs.listen_timing != _TimingConst.ATTACK_SETTLE or int(cs.priority) != 30:
		return "counter_strike 应 LISTEN ATTACK_SETTLE priority30（与反击额外攻击对齐）"
	if cs.requires_effect != &"":
		return "counter_strike 不应有 requires_effect（迪恩反击非出牌触发）"
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 3)
	if hand_cards.size() < 3:
		return "无法补3张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_01")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 5))
	var err = _run_conversion(te, attack, hand_cards, 1)
	if err != "":
		return err
	# 此时 single_move 挂起（attack waiting_effect_action），counter_strike 监听器已注册
	var pending_before: Array = attack.pending_effect_action_ids.duplicate()
	te.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	for aid: StringName in attack.pending_effect_action_ids:
		if not pending_before.has(aid):
			var sub = battle.context.action_registry.get_action(aid)
			if sub != null and sub.action_type == &"attack":
				return true
	return "ATTACK_SETTLE 后未产生反击攻击子动作（pilot_011_counter_strike 未触发）"


# ═══════════════════════════════════════════
# effect_02 迪恩--挡攻（替相邻友军响应 + 转移）
# ═══════════════════════════════════════════

## 创建1台 player 阵营的友军机甲（紧邻 player_mech 放置），并把 enemy_mech 挪到
## player_mech 武器范围（2）内、与友军相邻的位置。返回 {player_mech, enemy_mech, ally_mech, pilot_card, gs}。
## 几何：player(2,2) Dean；ally(2,3) 与 Dean 相邻；enemy(2,4) 与 ally 相邻、距 Dean 距离2（在武器范围2内）。
func _setup_dean_with_ally(battle) -> Dictionary:
	var setup = _setup_dean(battle)
	if setup.is_empty():
		return {}
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally := _MechState.new()
	ally.mech_id = &"ally_mech_p011"
	ally.owner_player_id = &"player"
	ally.max_hp = 25
	ally.current_hp = 25
	ally.position = {"q": 2, "r": 3}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		ally.slots[slot_id] = s
	gs.mechs[ally.mech_id] = ally
	enemy_mech.position = {"q": 2, "r": 4}
	return {"player_mech": player_mech, "enemy_mech": enemy_mech, "ally_mech": ally, "pilot_card": setup["pilot_card"], "gs": gs}


## 测试9：effect_02 定义正确（含 REDIRECT + 二选一）
func test_pilot_011_effect_02_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_02")
	if e == null:
		return "缺 pilot_011_effect_02"
	if e.mode != _TimingConst.MODE_AVAILABILITY:
		return "effect_02 mode 应 AVAILABILITY 实=%s" % String(e.mode)
	if e.availability_condition != &"":
		return "effect_02 availability_condition 应为空（迪恩非攻击目标，走 set_conditions）实=%s" % String(e.availability_condition)
	if int(e.availability_priority) != 10:
		return "effect_02 availability_priority 应 10 实=%d" % int(e.availability_priority)
	if e.listen_timing != _TimingConst.ATTACK_AT:
		return "effect_02 listen_timing 应 ATTACK_AT"
	if e.once_per_turn_key != &"pilot_011_effect_01":
		return "effect_02 once_per_turn_key 应 pilot_011_effect_01（与 effect_01 共享）"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET", "SELF_MECH_IN_CURRENT_ATTACK_RANGE", "ATTACKER_IS_NOT_SELF_MECH", "ATTACK_NOT_RESPONDED", "HAS_ACTION_CARD_IN_HAND"]:
		if not ops.has(need):
			return "effect_02 应含条件 %s 实=%s" % [need, str(ops)]
	# costs: DISCARD_ACTION_CARD count=2 + label
	var has_d2 := false
	var label_ok2 := false
	for c in e.costs:
		if String(c.get("cost_type", &"")) == "DISCARD_ACTION_CARD" and int(c.get("count", 0)) == 2:
			has_d2 = true
			label_ok2 = String(c.get("params", {}).get("label", "")) == "选择转化使用的2张行动牌"
	if not has_d2 or not label_ok2:
		return "effect_02 costs 应含 DISCARD_ACTION_CARD count=2 + label『选择转化使用的2张行动牌』"
	# actions: [CHOOSE_ONE(options 2)]，每个分支开头 REDIRECT_ATTACK_TARGET_TO_SELF
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_02 actions 应 [CHOOSE_ONE]"
	var options = acts[0].get("params", {}).get("options", [])
	if options.size() != 2:
		return "effect_02 CHOOSE_ONE options 应2个 实=%d" % options.size()
	for opt in options:
		var oa: Array = opt.get("actions", [])
		if oa.size() != 6:
			return "effect_02 %s 分支 actions 应6个（REDIRECT 开头）实=%d" % [String(opt.get("label", "")), oa.size()]
		if String(oa[0].get("type", &"")) != "REDIRECT_ATTACK_TARGET_TO_SELF":
			return "effect_02 %s 分支 actions[0] 应 REDIRECT_ATTACK_TARGET_TO_SELF" % String(opt.get("label", ""))
		if String(oa[0].get("params", {}).get("protect_target_id", &"")) != "$payload.target_id":
			return "effect_02 REDIRECT protect_target_id 应 $payload.target_id（被攻击友军）"
	return true


## 测试10：相邻友军被攻击+迪恩在范围内+≥2行动牌时，effect_02 出现在响应窗口
func test_pilot_011_effect_02_available_when_ally_attacked() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	if _give_action_cards(battle, 2).size() < 2:
		return "无法补2张行动牌"
	if _HexGrid.distance(player_mech.position, ally.position) != 1:
		return "前置错误：ally 应与 Dean 相邻 实距离=%d" % _HexGrid.distance(player_mech.position, ally.position)
	var cells = battle.context.game_state.map_state.cells
	if not _RangeCalculator.is_in_weapon_range(enemy_mech.position, player_mech.position, 2, cells):
		return "前置错误：Dean 应在 enemy 武器范围2内"
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return true
	return "相邻友军被攻击时，响应窗口应含 pilot_011_effect_02（实=%d 项）" % avail.size()


## 测试11：迪恩不在攻击范围内时，effect_02 不出现
func test_pilot_011_effect_02_hidden_when_dean_out_of_range() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	_give_action_cards(battle, 2)
	enemy_mech.position = {"q": 20, "r": 2}
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 1)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return "迪恩不在攻击范围内时，effect_02 不应出现"
	return true


## 测试12：被攻击目标被攻击者锁定时，effect_02 不出现（锁定转移封锁）
func test_pilot_011_effect_02_hidden_when_ally_locked_by_attacker() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	_give_action_cards(battle, 2)
	ally.add_status({"type": &"LOCKED", "source_player_id": &"enemy"})
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return "被攻击目标被攻击者锁定时，effect_02 不应出现（锁定转移封锁）"
	return true


## 测试13：选中 effect_02 -> 弃2张 -> 二选一选「当作疾行」-> REDIRECT 目标改迪恩 + 回复4 + 回退标志
func test_pilot_011_effect_02_redirect_and_conversion() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 3)
	if hand_cards.size() < 3:
		return "无法补3张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_02")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 10))
	var hand_before: int = gs.players[&"player"].action_hand.size()
	var err = _run_conversion(te, attack, hand_cards, 0)
	if err != "":
		return err
	if attack.record.get("responded", false) != true:
		return "responded 应为 true"
	if gs.players[&"player"].action_hand.size() != hand_before - 2:
		return "应弃2张牌"
	if player_mech.power != 4:
		return "迪恩动力应回复到4 实=%d" % player_mech.power
	# REDIRECT：攻击目标应由 ally 改为 Dean(player_mech)
	if StringName(attack.record.get("target_id", &"")) != StringName(player_mech.mech_id):
		return "REDIRECT 后攻击目标应为迪恩 实=%s 期望=%s" % [String(attack.record.get("target_id", &"")), String(player_mech.mech_id)]
	if String(attack.record.get("_redirect_from", &"")) != String(ally.mech_id):
		return "应记录原目标 _redirect_from=ally 实=%s" % String(attack.record.get("_redirect_from", &""))
	if not bool(attack.record.get("_redirect_rewind", false)):
		return "REDIRECT 应设 _redirect_rewind 标志（回退 PRE 重 fire）"
	if attack.state != &"waiting_effect_action":
		return "转化后 attack 应 waiting_effect_action 实=%s" % String(attack.state)
	return true


## 测试14：选中 effect_02 选「当作反击」-> REDIRECT + 注册 counter_strike
func test_pilot_011_effect_02_redirect_registers_counter_strike() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 3)
	if hand_cards.size() < 3:
		return "无法补3张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_02")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 10))
	var err = _run_conversion(te, attack, hand_cards, 1)
	if err != "":
		return err
	if StringName(attack.record.get("target_id", &"")) != StringName(player_mech.mech_id):
		return "REDIRECT 后攻击目标应为迪恩 实=%s" % String(attack.record.get("target_id", &""))
	if player_mech.power != 4:
		return "迪恩动力应回复到4 实=%d" % player_mech.power
	var settle_listeners: Array = te.temporary_listeners.get(_TimingConst.ATTACK_SETTLE, [])
	for le: Dictionary in settle_listeners:
		var le_eff = le.get("effect")
		if le_eff != null and String(le_eff.effect_id) == "pilot_011_counter_strike":
			if String(le.get("action_id", &"")) == String(attack.action_id):
				return true
	return "应注册 pilot_011_counter_strike 监听器绑定原攻击"


## 测试15：迪恩被攻击者锁定时，effect_02 不出现（响应封锁）
func test_pilot_011_effect_02_hidden_when_dean_locked() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	_give_action_cards(battle, 2)
	player_mech.add_status({"type": &"LOCKED", "source_player_id": &"enemy"})
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return "迪恩被攻击者锁定时，effect_02 不应出现（响应封锁）"
	return true


## 测试16：攻击已被响应时，effect_02 不出现（ATTACK_NOT_RESPONDED）
func test_pilot_011_effect_02_hidden_when_already_responded() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	_give_action_cards(battle, 2)
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	attack.record["responded"] = true
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return "攻击已被响应时，effect_02 不应出现（ATTACK_NOT_RESPONDED 不满足）"
	return true


## 测试17：effect_01/02 共享 once_per_turn -- 用 effect_02 后同回合 effect_01 隐藏（双向）
func test_pilot_011_effect_01_02_shared_once_per_turn() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 4)
	if hand_cards.size() < 4:
		return "无法补4张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	# 第1次：enemy 攻 ally，用 effect_02 转化（当作疾行）
	var attack1 = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff_02 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_02")
	te.handle_response_selection(attack1.action_id, _make_sel(pilot_card, eff_02, 10))
	var err = _run_conversion(te, attack1, hand_cards, 0)
	if err != "":
		return err
	# 第2次（同回合）：enemy 攻 Dean，effect_01 应因共享 once_per_turn 已用满而隐藏
	var attack2 = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, 2)
	if gs.players[&"player"].action_hand.size() < 2:
		return "前置错误：第2次攻击时手牌应>=2 实=%d" % gs.players[&"player"].action_hand.size()
	var avail2 = te.get_available_cards(_TimingConst.ATTACK_AT, attack2)
	for entry in avail2:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_01":
			return "用 effect_02 后同回合，effect_01 应因共享 once_per_turn 已用满而隐藏"
	return true


## 测试18：迪恩自己发出的攻击，effect_02 不出现（ATTACKER_IS_NOT_SELF_MECH）
func test_pilot_011_effect_02_hidden_when_dean_is_attacker() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	if _give_action_cards(battle, 2).size() < 2:
		return "无法补2张行动牌"
	var attack = _make_attack(battle, player_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return "迪恩自己发出的攻击，effect_02 不应出现（ATTACKER_IS_NOT_SELF_MECH）"
	return true


## 测试19：在弃牌成本窗口取消 -> 不弃牌/不回复/不转移/不消耗共享次数
func test_pilot_011_effect_02_cancel_cost_window() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 3)
	if hand_cards.size() < 3:
		return "无法补3张行动牌"
	player_mech.power = 0
	player_mech.max_power = 10
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_011_effect_02")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 10))
	var hand_before: int = gs.players[&"player"].action_hand.size()
	te.resume_pending_effect(attack.action_id, {"cancelled": true})
	if gs.players[&"player"].action_hand.size() != hand_before:
		return "取消后不应弃牌 before=%d after=%d" % [hand_before, gs.players[&"player"].action_hand.size()]
	if player_mech.power != 0:
		return "取消后不应回复动力 实=%d" % player_mech.power
	if bool(attack.record.get("responded", false)):
		return "取消后 responded 应回退为 false"
	if StringName(attack.record.get("target_id", &"")) != StringName(ally.mech_id):
		return "取消后攻击目标不应改变 实=%s" % String(attack.record.get("target_id", &""))
	# 共享次数未消耗：第2次攻击 effect_02 仍可用
	var attack2 = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var avail2 = te.get_available_cards(_TimingConst.ATTACK_AT, attack2)
	for entry in avail2:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return true
	return "取消成本窗口后共享次数应未消耗，第2次攻击 effect_02 仍应可用"


## 测试20：挡攻转移后回退 ATTACK_PRE 重 fire 白盒（_redirect_rewind 机制）
func test_pilot_011_02_rewind_to_pre_mechanism() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var ae = battle.context.action_engine
	var attack := _AttackAction.new()
	attack.action_id = &"test_p011_rewind_%d" % [randi() % 1000000]
	attack.context = battle.context
	attack.source = {"player_id": &"enemy", "mech_id": enemy_mech.mech_id}
	attack.record = {
		"attacker_id": enemy_mech.mech_id,
		"target_id": player_mech.mech_id,
		"weapon_might": 5,
		"weapon_range": 2,
		"extra_range": 0,
		"target_count": 1,
		"responded": true,
		"counter_attacked": false,
		"response_source": &"pilot_011_effect_02",
		"_redirect_from": ally.mech_id,
		"_redirect_rewind": true,
	}
	battle.context.action_registry.register(attack)
	attack.setup_steps()
	var pre_idx := -1
	var at_idx := -1
	for i in range(attack.steps.size()):
		var tp = StringName(attack.steps[i].get("timing_point", &""))
		if tp == _TimingConst.ATTACK_PRE:
			pre_idx = i
		elif tp == _TimingConst.ATTACK_AT:
			at_idx = i
	if pre_idx < 0 or at_idx < 0:
		return "attack steps 应含 ATTACK_PRE/ATTACK_AT 步"
	attack.current_step_index = at_idx
	attack.current_step_phase = &"timing_done"
	attack._step_timing_fired = true
	var sig: StringName = ae._execute_step(attack, at_idx)
	if sig != &"rewind":
		return "ATTACK_AT 阶段4 检测 _redirect_rewind 应返回 rewind 实=%s" % String(sig)
	if attack.current_step_index != pre_idx:
		return "回退后 csi 应=%d(ATTACK_PRE) 实=%d" % [pre_idx, attack.current_step_index]
	if attack.current_step_phase != &"timing_firing":
		return "回退后 phase 应 timing_firing（跳过 select_target handler，目标已由 REDIRECT 设定）实=%s" % String(attack.current_step_phase)
	if attack._step_timing_fired != false:
		return "回退后 _step_timing_fired 应 false（让 PRE 重新 fire）"
	if attack.record.has("_redirect_rewind"):
		return "回退后 _redirect_rewind 应已 erase（防重复回退）"
	return true


# ═══════════════════════════════════════════
# 问题3：多响应方响应窗口（迪恩替别人响应）
# ═══════════════════════════════════════════

## 构造指定行动牌（反击 action_010_反击 / 疾行 action_011_疾行）加入 player 手牌并注册
## AVAILABILITY 监听器（register_hand_card_availability 会设 card.mech_id=持有者机甲）。
## 返回 instance_id；失败返回空。
func _give_specific_action_card(battle, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var inst = _make_instance(gs, battle.context.card_database, card_def_id, &"player")
	if inst == null:
		return &""
	var player = gs.players.get(&"player")
	player.action_hand.append(inst.instance_id)
	inst.zone = &"action_hand"
	battle.context.register_hand_card_availability(inst.instance_id)
	return inst.instance_id


## 构造行动牌响应条目（行动牌路径不依赖 effect 对象，effect_id 留空跳过 granted 推导）
func _sel_for_card(card_instance_id: StringName) -> Array[Dictionary]:
	return [{
		"effect_id": &"",
		"card_instance_id": card_instance_id,
		"effect": null,
		"availability_priority": 5,
	}]


## 测试21：相邻友军被攻击+迪恩在攻击范围内时，迪恩手牌「反击/疾行」进入响应窗口
## （替别人响应）+ effect_02 挡攻转化也在窗口；每条 avail 带 owner_player_id=player
func test_pilot_011_ally_respond_counter_dash_in_window() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	var counter = _give_specific_action_card(battle, "action_010_反击")
	var dash = _give_specific_action_card(battle, "action_011_疾行")
	if counter == &"" or dash == &"":
		return "无法构造反击/疾行牌"
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	var found_counter := false
	var found_dash := false
	var owner_ok := true
	var found_e2 := false
	for entry in avail:
		if String(entry.get("card_instance_id", &"")) == String(counter):
			found_counter = true
			if StringName(entry.get("owner_player_id", &"")) != &"player":
				owner_ok = false
		if String(entry.get("card_instance_id", &"")) == String(dash):
			found_dash = true
			if StringName(entry.get("owner_player_id", &"")) != &"player":
				owner_ok = false
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			found_e2 = true
			if StringName(entry.get("owner_player_id", &"")) != &"player":
				owner_ok = false
	if not found_counter:
		return "迪恩手牌反击牌应进入响应窗口（替 ally 响应）实=%d项" % avail.size()
	if not found_dash:
		return "迪恩手牌疾行牌应进入响应窗口（替 ally 响应）"
	if not found_e2:
		return "迪恩窗口应含 pilot_011_effect_02（转化挡攻）"
	if not owner_ok:
		return "avail 条目应带 owner_player_id=player（多响应方过滤用）"
	return true


## 测试22：迪恩非攻击目标时，effect_01（迪恩--响应转化）不进窗口
## （仅反击/疾行 + effect_02 挡攻在迪恩替别人响应的窗口里）
func test_pilot_011_effect_01_not_in_window_when_ally_attacked() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	_give_specific_action_card(battle, "action_010_反击")
	_give_specific_action_card(battle, "action_011_疾行")
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_01":
			return "迪恩非攻击目标时，effect_01 不应进入窗口（替别人窗口只含反击/疾行+effect_02）"
	return true


## 测试23：迪恩不在攻击范围内时，反击/疾行 + effect_02 均不进窗口
func test_pilot_011_ally_respond_hidden_when_dean_out_of_range() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	var counter = _give_specific_action_card(battle, "action_010_反击")
	var dash = _give_specific_action_card(battle, "action_011_疾行")
	enemy_mech.position = {"q": 20, "r": 2}
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 1)
	var te = battle.context.timing_engine
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		var eid := String(entry.get("card_instance_id", &""))
		if eid == String(counter) or eid == String(dash):
			return "迪恩不在攻击范围内时，反击/疾行不应进入窗口（SELF_MECH_IN_CURRENT_ATTACK_RANGE）"
		if String(entry.get("effect_id", &"")) == "pilot_011_effect_02":
			return "迪恩不在攻击范围内时，effect_02 不应出现"
	return true


## 测试24：迪恩用疾行牌替别人响应 -> 攻击目标转移为迪恩（_redirect_rewind 回退 PRE 重 fire）
func test_pilot_011_ally_respond_redirects_target() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_dean_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	_clear_action_hand(battle)
	var dash = _give_specific_action_card(battle, "action_011_疾行")
	if dash == &"":
		return "无法构造疾行牌"
	player_mech.power = 5
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	te.handle_response_selection(attack.action_id, _sel_for_card(dash))
	if not bool(attack.record.get("responded", false)):
		return "迪恩替 ally 响应后 responded 应为 true"
	if StringName(attack.record.get("target_id", &"")) != StringName(player_mech.mech_id):
		return "迪恩替 ally 响应后攻击目标应改为迪恩 实=%s 期望=%s" % [String(attack.record.get("target_id", &"")), String(player_mech.mech_id)]
	if String(attack.record.get("_redirect_from", &"")) != String(ally.mech_id):
		return "应记录原目标 _redirect_from=ally 实=%s" % String(attack.record.get("_redirect_from", &""))
	if not bool(attack.record.get("_redirect_rewind", false)):
		return "迪恩替别人响应应设 _redirect_rewind（回退 PRE 重 fire）"
	# 疾行牌 use_action_card 子动作挂起（EXECUTE_SINGLE_MOVE），attack 等其完成
	return true
