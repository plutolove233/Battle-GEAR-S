## test_pilot_030_burook.gd - 布鲁克（pilot_030）效果测试
##
## 效果1（转守为攻）：AVAILABILITY ATTACK_AT，布鲁克被攻击时，每回合1次，
##   转化1张行动牌（temp_zone）当作防御使用（RESPOND_ATTACK + 本次攻击护甲+5 + 损伤-1），
##   之后给下个我方回合攻击数+1（可叠加，TurnService.start_turn 并入 max_attacks_per_turn 并清除）。
## 效果2（以身作盾）：AVAILABILITY ATTACK_AT（空 availability_condition，set_conditions fall-through），
##   相邻其他机甲被攻击 + 布鲁克在攻击范围内时，可用防御响应并将目标改为布鲁克（REDIRECT）。
##   防御手段弹窗三选一：实体防御牌（正常打出）/ 转化防御（消耗效果1额度+攻击数+1）/ 莱比尔EX防御。
## 通用化：转化防御复用迪恩 temp_zone 模式；攻击数+1 走通用 APPLY_NEXT_OWNER_TURN_ATTACK_BONUS；
## 挡攻转移复用通用 REDIRECT_ATTACK_TARGET_TO_SELF（_redirect_from/_redirect_rewind）。
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


## 设布鲁克为 player_mech 机师，返回 {player_mech, enemy_mech, pilot_card, gs}；失败返回空。
func _setup_brook(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_instance(gs, cdb, "pilot_030_布鲁克", &"player")
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	return {"player_mech": player_mech, "enemy_mech": enemy_mech, "pilot_card": card, "gs": gs}


## 相邻友军 ally 场景：布鲁克(player) 与 ally 相邻，enemy 与布鲁克范围2内。
func _setup_brook_with_ally(battle) -> Dictionary:
	var setup = _setup_brook(battle)
	if setup.is_empty():
		return {}
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally := _MechState.new()
	ally.mech_id = &"ally_mech_p030"
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


## 给 player 补 N 张行动牌（从牌堆顶抽），返回 [cid,...]
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


## 生成一张指定 card_def_id 的行动牌并放入 player 手牌，返回 card 实例
func _give_specific_action_card(battle, card_def_id: String) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, &"player")
	if card == null:
		return {}
	var player = gs.players.get(&"player")
	player.action_hand.append(card.instance_id)
	card.zone = &"action_hand"
	card.owner_player_id = &"player"
	return {"card": card, "cid": card.instance_id}


func _make_attack(battle, attacker_id: StringName, target_id: StringName, weapon_range: int = 2) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p030_%d" % [randi() % 1000000]
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


## 断开 action_needs_input 自动 resume（避免单行动被自动驱动）
func _disconnect_needs_input(te) -> void:
	for _c in te.action_needs_input.get_connections():
		te.action_needs_input.disconnect(_c.callable)


## 构造效果选中条目（sel: Array[Dictionary]）
func _make_sel(pilot_card, eff, ap: int) -> Array[Dictionary]:
	return [{
		"effect_id": eff.effect_id,
		"card_instance_id": pilot_card.instance_id,
		"effect": eff,
		"availability_priority": ap,
	}]


# ═══════════════════════════════════════════
# effect_01 转守为攻（转化防御）
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确
func test_pilot_030_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_01")
	if e == null:
		return "缺 pilot_030_effect_01"
	if e.mode != _TimingConst.MODE_AVAILABILITY:
		return "effect_01 mode 应 AVAILABILITY 实=%s" % String(e.mode)
	if e.availability_condition != _TimingConst.AVAIL_RESPOND_ATTACK:
		return "effect_01 availability_condition 应 AVAIL_RESPOND_ATTACK"
	if e.listen_timing != _TimingConst.ATTACK_AT:
		return "effect_01 listen_timing 应 ATTACK_AT"
	if e.once_per_turn_key != &"pilot_030_effect_01" or int(e.once_per_turn_max) != 1:
		return "effect_01 应每回合1次（key=pilot_030_effect_01 max=1）"
	# conditions: HAS_ACTION_CARD_IN_HAND(1) + ATTACK_NOT_RESPONDED
	var has_hand := false
	var has_not_responded := false
	for c in e.conditions:
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND" and int(c.get("params", {}).get("count", 0)) == 1:
			has_hand = true
		if String(c.get("op", &"")) == "ATTACK_NOT_RESPONDED":
			has_not_responded = true
	if not has_hand:
		return "effect_01 conditions 应含 HAS_ACTION_CARD_IN_HAND(1)"
	if not has_not_responded:
		return "effect_01 conditions 应含 ATTACK_NOT_RESPONDED"
	# cost: DISCARD_ACTION_CARD count=1 to_temp_zone
	var has_discard1 := false
	for c in e.costs:
		if String(c.get("cost_type", &"")) == "DISCARD_ACTION_CARD" and int(c.get("count", 0)) == 1:
			has_discard1 = bool(c.get("params", {}).get("to_temp_zone", false))
	if not has_discard1:
		return "effect_01 costs 应含 DISCARD_ACTION_CARD count=1 to_temp_zone"
	# actions: RESPOND_ATTACK -> ADD_MECH_TEMP_ARMOR(+5) -> MODIFY_ATTACK_MARKERS(-1) -> APPLY_NEXT_OWNER_TURN_ATTACK_BONUS(+1) -> DISCARD_TEMP_ZONE_CARDS
	var acts: Array = e.actions
	var types: Array = []
	for a in acts:
		types.append(String(a.get("type", &"")))
	for need in ["RESPOND_ATTACK", "ADD_MECH_TEMP_ARMOR", "MODIFY_ATTACK_MARKERS", "APPLY_NEXT_OWNER_TURN_ATTACK_BONUS", "DISCARD_TEMP_ZONE_CARDS"]:
		if not types.has(need):
			return "effect_01 actions 应含 %s 实=%s" % [need, str(types)]
	for a in acts:
		if String(a.get("type", &"")) == "ADD_MECH_TEMP_ARMOR":
			if int(a.get("params", {}).get("delta", 0)) != 5:
				return "ADD_MECH_TEMP_ARMOR delta 应 5"
			if String(a.get("params", {}).get("mech_id", &"")) != "$binding_context.mech_id":
				return "ADD_MECH_TEMP_ARMOR mech_id 应 $binding_context.mech_id"
		if String(a.get("type", &"")) == "MODIFY_ATTACK_MARKERS":
			if int(a.get("params", {}).get("delta", 0)) != -1:
				return "MODIFY_ATTACK_MARKERS delta 应 -1"
		if String(a.get("type", &"")) == "APPLY_NEXT_OWNER_TURN_ATTACK_BONUS":
			if int(a.get("params", {}).get("stacks", 0)) != 1:
				return "APPLY_NEXT_OWNER_TURN_ATTACK_BONUS stacks 应 1"
	return true


## 测试2：被攻击+1张行动牌时 effect_01 出现在响应窗口；0张时不出现
func test_pilot_030_effect_01_available_when_attacked_with_card() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook(battle)
	if setup.is_empty():
		return "setup 失败（缺 pilot_030_布鲁克）"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var te = battle.context.timing_engine
	_clear_action_hand(battle)
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_030_effect_01":
			return "无行动牌时 effect_01 不应出现"
	# 补1张行动牌
	if _give_action_cards(battle, 1).size() < 1:
		return "无法补1张行动牌"
	var attack2 = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var avail2 = te.get_available_cards(_TimingConst.ATTACK_AT, attack2)
	for entry in avail2:
		if String(entry.get("effect_id", &"")) == "pilot_030_effect_01":
			return true
	return "被攻击+1张行动牌时，响应窗口应含 pilot_030_effect_01（实=%d 项）" % avail2.size()


## 测试3：选中 effect_01 -> 转化1张（temp_zone）-> 护甲+5 + 损伤-1 + 攻击数status + responded
func test_pilot_030_effect_01_conversion_defend() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 2)
	if hand_cards.size() < 2:
		return "无法补2张行动牌"
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_01")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 5))
	if not te._pending_effect.has(attack.action_id):
		return "选中后应挂起 _pending_effect 等弃牌选择"
	var p0 = te._pending_effect[attack.action_id]
	if String(p0.get("phase", &"")) != "response_discard":
		return "应进入 response_discard 阶段 实=%s" % String(p0.get("phase", &""))
	var hand_before: int = gs.players[&"player"].action_hand.size()
	te.resume_pending_effect(attack.action_id, {"selected_action_card_ids": [hand_cards[0]], "cancelled": false})
	# 效果执行（全原子，同步完成）
	if attack.record.get("responded", false) != true:
		return "responded 应为 true"
	if gs.players[&"player"].action_hand.size() != hand_before - 1:
		return "应转化弃1张牌 before=%d after=%d" % [hand_before, gs.players[&"player"].action_hand.size()]
	# 效果链同步执行完毕：燃料牌已由链末 DISCARD_TEMP_ZONE_CARDS 入弃牌堆
	# （temp_zone 为中间态，链完成后不可观察；燃料入弃牌堆证明 to_temp_zone 成本 + 链末丢弃均生效）
	var fuel = gs.get_card(hand_cards[0])
	if player_mech.temp_armor_bonus != 5:
		return "护甲+5 应生效 temp_armor_bonus=5 实=%d" % player_mech.temp_armor_bonus
	if int(attack.record.get("extra_markers", 0)) != -1:
		return "损伤-1 应生效 extra_markers=-1 实=%d" % int(attack.record.get("extra_markers", 0))
	if player_mech.get_next_owner_turn_attack_bonus() != 1:
		return "下个我方回合攻击数+1 status 应为1 实=%d" % player_mech.get_next_owner_turn_attack_bonus()
	# 燃料牌链末入弃牌堆
	if fuel == null or String(fuel.zone) != "discard":
		return "链末 DISCARD_TEMP_ZONE_CARDS 后燃料牌应入弃牌堆 实=%s" % (String(fuel.zone) if fuel != null else "null")
	return true


## 测试4：转化后下个我方回合开始，max_attacks_per_turn +1 且 status 清除 + attack_limit 同步
func test_pilot_030_effect_01_attack_bonus_applied_next_turn() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var player = gs.players[&"player"]
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 1)
	if hand_cards.size() < 1:
		return "无法补1张行动牌"
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_01")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 5))
	te.resume_pending_effect(attack.action_id, {"selected_action_card_ids": [hand_cards[0]], "cancelled": false})
	if player_mech.get_next_owner_turn_attack_bonus() != 1:
		return "转化后应累计 +1 攻击数 status"
	var base_max: int = player_mech.max_attacks_per_turn
	# 模拟布鲁克下个我方回合开始
	battle.context.turn_service.start_turn(&"player")
	if player_mech.max_attacks_per_turn != base_max + 1:
		return "下个我方回合开始攻击数应 +1 实=%d（base=%d）" % [player_mech.max_attacks_per_turn, base_max]
	if player_mech.applied_next_turn_attack_bonus != 1:
		return "applied_next_turn_attack_bonus 应为1 实=%d" % player_mech.applied_next_turn_attack_bonus
	if player_mech.get_next_owner_turn_attack_bonus() != 0:
		return "应用后 status 应清除（不延续到下下回合）实=%d" % player_mech.get_next_owner_turn_attack_bonus()
	if player.attack_limit != player_mech.max_attacks_per_turn:
		return "player.attack_limit 应跟随 max_attacks_per_turn 实=%d" % player.attack_limit
	# 再模拟一次下回合开始：上一轮应用的加成应被还原（不延续）
	battle.context.turn_service.start_turn(&"player")
	if player_mech.max_attacks_per_turn != base_max:
		return "再下回合应还原攻击数加成 实=%d（base=%d）" % [player_mech.max_attacks_per_turn, base_max]
	if player_mech.applied_next_turn_attack_bonus != 0:
		return "再下回合 applied_next_turn_attack_bonus 应清零 实=%d" % player_mech.applied_next_turn_attack_bonus
	return true


## 测试5：每回合1次 -- 同回合第2次攻击 effect_01 不再出现
func test_pilot_030_effect_01_once_per_turn_second_attack_hidden() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 2)
	if hand_cards.size() < 2:
		return "无法补2张行动牌"
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_01")
	var attack1 = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	te.handle_response_selection(attack1.action_id, _make_sel(pilot_card, eff, 5))
	te.resume_pending_effect(attack1.action_id, {"selected_action_card_ids": [hand_cards[0]], "cancelled": false})
	# 同回合第2次攻击（换一张行动牌）：effect_01 不应再出现
	_clear_action_hand(battle)
	_give_action_cards(battle, 1)
	var attack2 = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack2)
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_030_effect_01":
			return "每回合1次 -- 同回合第2次攻击 effect_01 不应出现"
	return true


## 测试6：effect_01 转化后，attack 的攻击数上限条件（ATTACK_COUNT_ABOVE threshold=0）不受 pending bonus 影响
func test_pilot_030_effect_01_bonus_not_counted_same_turn() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 1)
	if hand_cards.size() < 1:
		return "无法补1张行动牌"
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_01")
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 5))
	te.resume_pending_effect(attack.action_id, {"selected_action_card_ids": [hand_cards[0]], "cancelled": false})
	# 待结算加成存在，但本回合 can_attack 不应因它 +1（加成属下一个我方回合）
	if player_mech.get_next_owner_turn_attack_bonus() != 1:
		return "前置：待结算加成应为1"
	if not player_mech.can_attack():
		return "本回合应还能攻击（攻击数未因 pending bonus 变化）"
	return true


# ═══════════════════════════════════════════
# effect_02 以身作盾（挡攻防御）
# ═══════════════════════════════════════════

## 测试7：effect_02 定义正确（无每回合1次限制 + 三选一防御手段）
func test_pilot_030_effect_02_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_02")
	if e == null:
		return "缺 pilot_030_effect_02"
	if e.mode != _TimingConst.MODE_AVAILABILITY:
		return "effect_02 mode 应 AVAILABILITY 实=%s" % String(e.mode)
	if e.availability_condition != _TimingConst.AVAIL_TRANSFER_TARGET:
		return "effect_02 availability_condition 应=AVAIL_TRANSFER_TARGET（转移目标窗口）实=%s" % String(e.availability_condition)
	if e.listen_timing != _TimingConst.ATTACK_AT:
		return "effect_02 listen_timing 应 ATTACK_AT"
	if e.once_per_turn_key != &"":
		return "effect_02 不应有每回合1次限制（实体防御/莱比尔EX 不受限）实=%s" % String(e.once_per_turn_key)
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET", "SELF_MECH_IN_CURRENT_ATTACK_RANGE", "ATTACKER_IS_NOT_SELF_MECH", "ATTACK_NOT_RESPONDED"]:
		if not ops.has(need):
			return "effect_02 应含条件 %s 实=%s" % [need, str(ops)]
	# actions: [CHOOSE_ONE(options 3)]
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_02 actions 应 [CHOOSE_ONE]"
	var options = acts[0].get("params", {}).get("options", [])
	if options.size() != 3:
		return "effect_02 CHOOSE_ONE options 应3个（实体防御牌/转化防御/莱比尔EX防御）实=%d" % options.size()
	if String(options[0].get("label", "")) != "使用实体防御牌":
		return "option0 应『使用实体防御牌』实=%s" % String(options[0].get("label", ""))
	if String(options[1].get("label", "")) != "转化防御（消耗转守为攻额度，下个我方回合攻击数+1）":
		return "option1 应『转化防御…』实=%s" % String(options[1].get("label", ""))
	if String(options[2].get("label", "")) != "莱比尔EX防御":
		return "option2 应『莱比尔EX防御』实=%s" % String(options[2].get("label", ""))
	# 实体防御牌分支：选牌(HAND_CARDS card_def_id 防御) -> REDIRECT -> EXECUTE_USE_ACTION_CARD
	var phys: Array = options[0].get("actions", [])
	if phys.size() != 3:
		return "实体防御牌分支 actions 应3个 实=%d" % phys.size()
	if String(phys[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "实体防御牌 actions[0] 应 CHOOSE_MANY_CARDS"
	if String(phys[0].get("params", {}).get("card_def_id", &"")) != "action_009_防御":
		return "实体防御牌 CHOOSE_MANY_CARDS 应 card_def_id=action_009_防御"
	if String(phys[1].get("type", &"")) != "REDIRECT_ATTACK_TARGET_TO_SELF":
		return "实体防御牌 actions[1] 应 REDIRECT_ATTACK_TARGET_TO_SELF"
	if String(phys[2].get("type", &"")) != "EXECUTE_USE_ACTION_CARD":
		return "实体防御牌 actions[2] 应 EXECUTE_USE_ACTION_CARD"
	# 转化防御分支：选燃料 -> MOVE temp_zone -> MARK 额度 -> REDIRECT -> 防御链 -> APPLY_NEXT_OWNER_TURN_ATTACK_BONUS
	var conv: Array = options[1].get("actions", [])
	var conv_types: Array = []
	for a in conv:
		conv_types.append(String(a.get("type", &"")))
	for need in ["CHOOSE_MANY_CARDS", "MOVE_ACTION_CARDS_TO_TEMP_ZONE", "MARK_EFFECT_ONCE_PER_TURN_USED", "REDIRECT_ATTACK_TARGET_TO_SELF", "RESPOND_ATTACK", "ADD_MECH_TEMP_ARMOR", "MODIFY_ATTACK_MARKERS", "APPLY_NEXT_OWNER_TURN_ATTACK_BONUS", "DISCARD_TEMP_ZONE_CARDS"]:
		if not conv_types.has(need):
			return "转化防御分支应含 %s 实=%s" % [need, str(conv_types)]
	# 转化防御分支 condition：EFFECT_ONCE_PER_TURN_AVAILABLE(pilot_030_effect_01) + HAS_ACTION_CARD_IN_HAND(1)
	var conv_conds: Array = options[1].get("condition", [])
	var has_opt_available := false
	var has_opt_hand := false
	for cc in conv_conds:
		if String(cc.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE" and String(cc.get("params", {}).get("once_per_turn_key", &"")) == "pilot_030_effect_01":
			has_opt_available = true
		if String(cc.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND" and int(cc.get("params", {}).get("count", 0)) == 1:
			has_opt_hand = true
	if not has_opt_available:
		return "转化防御分支 condition 应含 EFFECT_ONCE_PER_TURN_AVAILABLE(pilot_030_effect_01)"
	if not has_opt_hand:
		return "转化防御分支 condition 应含 HAS_ACTION_CARD_IN_HAND(1)"
	# 莱比尔EX分支：REDIRECT -> PILOT_002_USE_BATCH_AS_NAMED(防御)
	var leb: Array = options[2].get("actions", [])
	if String(leb[0].get("type", &"")) != "REDIRECT_ATTACK_TARGET_TO_SELF":
		return "莱比尔EX actions[0] 应 REDIRECT"
	var leb_use = leb[1]
	if String(leb_use.get("type", &"")) != "PILOT_002_USE_BATCH_AS_NAMED" or String(leb_use.get("params", {}).get("as_card_def_id", &"")) != "action_009_防御":
		return "莱比尔EX actions[1] 应 PILOT_002_USE_BATCH_AS_NAMED(as 防御)"
	return true


## 测试8：相邻友军被攻击+布鲁克在范围内时 effect_02 出现在响应窗口；布鲁克不在范围内时不出现
func test_pilot_030_effect_02_available_when_ally_attacked() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var te = battle.context.timing_engine
	_clear_action_hand(battle)
	if _HexGrid.distance(player_mech.position, ally.position) != 1:
		return "前置错误：ally 应与布鲁克相邻 实距离=%d" % _HexGrid.distance(player_mech.position, ally.position)
	var cells = battle.context.game_state.map_state.cells
	if not _RangeCalculator.is_in_weapon_range(enemy_mech.position, player_mech.position, 2, cells):
		return "前置错误：布鲁克应在 enemy 武器范围2内"
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var avail = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	var found := false
	for entry in avail:
		if String(entry.get("effect_id", &"")) == "pilot_030_effect_02":
			found = true
	if not found:
		return "相邻友军被攻击时，响应窗口应含 pilot_030_effect_02（实=%d 项）" % avail.size()
	# 布鲁克不在攻击范围内（enemy 移远）：effect_02 不出现
	var attack2 = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 1)
	attack2.record["weapon_range"] = 1
	var avail2 = te.get_available_cards(_TimingConst.ATTACK_AT, attack2)
	for entry in avail2:
		if String(entry.get("effect_id", &"")) == "pilot_030_effect_02":
			return "布鲁克不在攻击范围内时，effect_02 不应出现"
	return true


## 测试9：选中 effect_02 -> 转化防御分支 -> 选1张燃料 -> REDIRECT + 防御链 + 攻击数status + 消耗效果1额度
func test_pilot_030_effect_02_convert_defend_redirect() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var pilot_card = setup["pilot_card"]
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	_clear_action_hand(battle)
	var fuel_res = _give_specific_action_card(battle, "action_007_预判")
	if fuel_res.is_empty():
		return "无法生成燃料行动牌（action_007_预判）"
	var fuel_cid: StringName = fuel_res["cid"]
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_02")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 10))
	# 仅转化防御可用（手牌无实体防御牌、无莱比尔批次）：CHOOSE_ONE 自动选择 index=1，
	# 直接挂起 CHOOSE_MANY_CARDS 选燃料牌（不弹三选一）。三选一挂起由实体防御牌测试覆盖。
	if not te._pending_effect.has(attack.action_id):
		return "仅转化防御可用时，选中后应自动进入 CHOOSE_MANY_CARDS 选燃料牌"
	var p2 = te._pending_effect[attack.action_id]
	if String(p2.get("phase", &"")) != "choose_many_cards":
		return "应进入 choose_many_cards 选燃料 实=%s" % String(p2.get("phase", &""))
	# 3) 选1张燃料牌
	var hand_before: int = gs.players[&"player"].action_hand.size()
	te.resume_pending_effect(attack.action_id, {"selected_card_ids": [fuel_cid], "cancelled": false})
	# REDIRECT：目标由 ally 改为布鲁克
	if StringName(attack.record.get("target_id", &"")) != StringName(player_mech.mech_id):
		return "REDIRECT 后攻击目标应为布鲁克 实=%s" % String(attack.record.get("target_id", &""))
	if String(attack.record.get("_redirect_from", &"")) != String(ally.mech_id):
		return "应记录原目标 _redirect_from=ally 实=%s" % String(attack.record.get("_redirect_from", &""))
	if not bool(attack.record.get("_redirect_rewind", false)):
		return "REDIRECT 应设 _redirect_rewind（回退 PRE 重 fire）"
	if attack.record.get("responded", false) != true:
		return "responded 应为 true"
	if gs.players[&"player"].action_hand.size() != hand_before - 1:
		return "应转化弃1张燃料牌 before=%d after=%d" % [hand_before, gs.players[&"player"].action_hand.size()]
	if player_mech.temp_armor_bonus != 5:
		return "转化防御护甲+5 应生效 temp_armor_bonus=5 实=%d" % player_mech.temp_armor_bonus
	if int(attack.record.get("extra_markers", 0)) != -1:
		return "转化防御损伤-1 应生效 extra_markers=-1 实=%d" % int(attack.record.get("extra_markers", 0))
	if player_mech.get_next_owner_turn_attack_bonus() != 1:
		return "转化防御应给下个我方回合攻击数+1 实=%d" % player_mech.get_next_owner_turn_attack_bonus()
	# 燃料牌链末入弃牌堆
	var fuel = gs.get_card(fuel_cid)
	if fuel == null or String(fuel.zone) != "discard":
		return "燃料牌链末应入弃牌堆 实=%s" % (String(fuel.zone) if fuel != null else "null")
	# 消耗效果1额度
	if te.is_once_per_turn_key_available(&"pilot_030_effect_01", pilot_card.instance_id, 1):
		return "转化防御应消耗 effect_01 每回合1次额度"
	return true


## 测试10：effect_01 额度已用时，effect_02 转化防御分支不可选（只剩实体/莱比尔EX，需有牌）
func test_pilot_030_effect_02_convert_branch_hidden_when_effect_01_used() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var pilot_card = setup["pilot_card"]
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	_clear_action_hand(battle)
	var hand_cards = _give_action_cards(battle, 2)
	if hand_cards.size() < 2:
		return "无法补2张行动牌"
	# 先用掉 effect_01 额度（转化防御）
	var eff1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_01")
	var attack1 = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	te.handle_response_selection(attack1.action_id, _make_sel(pilot_card, eff1, 5))
	te.resume_pending_effect(attack1.action_id, {"selected_action_card_ids": [hand_cards[0]], "cancelled": false})
	if te.is_once_per_turn_key_available(&"pilot_030_effect_01", pilot_card.instance_id, 1):
		return "前置：effect_01 额度应已消耗"
	# 相邻友军被攻击，选 effect_02
	var attack2 = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var eff2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_02")
	te.handle_response_selection(attack2.action_id, _make_sel(pilot_card, eff2, 10))
	# 无手牌行动牌（燃料已用）+ 额度已用：转化防御分支不可用；也无实体防御牌/莱比尔EX -> 0可用，跳过
	if te._pending_effect.has(attack2.action_id):
		var p = te._pending_effect[attack2.action_id]
		if String(p.get("phase", &"")) == "pre_actions_target":
			return "无任何可用防御手段时 CHOOSE_ONE 应自动跳过（不挂起）"
		return "意外挂起 phase=%s" % String(p.get("phase", &""))
	return true


## 测试11：选中 effect_02 -> 实体防御牌分支 -> 选防御牌 -> REDIRECT + 打出防御牌（use_action_card 子动作）
func test_pilot_030_effect_02_physical_defend_redirect() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_brook_with_ally(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var ally = setup["ally_mech"]
	var pilot_card = setup["pilot_card"]
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	_clear_action_hand(battle)
	var def_res = _give_specific_action_card(battle, "action_009_防御")
	if def_res.is_empty():
		return "无法生成实体防御牌 action_009_防御"
	var defend_cid: StringName = def_res["cid"]
	var attack = _make_attack(battle, enemy_mech.mech_id, ally.mech_id, 2)
	var eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_030_effect_02")
	te.handle_response_selection(attack.action_id, _make_sel(pilot_card, eff, 10))
	if not te._pending_effect.has(attack.action_id):
		return "选中后应挂起 CHOOSE_ONE（三选一）"
	# 选实体防御牌（index=0）
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	if not te._pending_effect.has(attack.action_id):
		return "实体防御牌分支应挂起 CHOOSE_MANY_CARDS 选防御牌"
	var p = te._pending_effect[attack.action_id]
	if String(p.get("phase", &"")) != "choose_many_cards":
		return "应进入 choose_many_cards 选防御牌 实=%s" % String(p.get("phase", &""))
	# 选防御牌
	te.resume_pending_effect(attack.action_id, {"selected_card_ids": [defend_cid], "cancelled": false})
	# REDIRECT：目标由 ally 改为布鲁克
	if StringName(attack.record.get("target_id", &"")) != StringName(player_mech.mech_id):
		return "REDIRECT 后攻击目标应为布鲁克 实=%s" % String(attack.record.get("target_id", &""))
	if String(attack.record.get("_redirect_from", &"")) != String(ally.mech_id):
		return "应记录原目标 _redirect_from=ally 实=%s" % String(attack.record.get("_redirect_from", &""))
	if not bool(attack.record.get("_redirect_rewind", false)):
		return "REDIRECT 应设 _redirect_rewind"
	# 防御牌已从手牌打出（use_action_card 子动作挂起）
	if gs.players[&"player"].action_hand.has(defend_cid):
		return "实体防御牌应从手牌打出"
	var def_card = gs.get_card(defend_cid)
	if def_card == null or String(def_card.zone) == "action_hand":
		return "实体防御牌不应停留在行动手牌 zone=%s" % (String(def_card.zone) if def_card != null else "null")
	return true
