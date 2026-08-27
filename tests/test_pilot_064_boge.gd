## test_pilot_064_boge.gd - 柏格（pilot_064，联邦 N）效果测试
##
## 柏格 1 个主动效果按钮（DIRECT）：
##   effect_01（我方回合1次）「弃装获金抽装」：弹单选窗只列持有者"未设置的装备牌"
##     （仅装备手牌，不含已设置槽位，OWNER_UNEQUIPPED_EQUIPMENT_CARDS 通用来源），
##     选1张弃置 -> +2金币 + 抽1张装备牌；若弃置的装备牌是武器则再抽2张行动牌。
##     无未设置装备可弃按钮置灰（HAS_UNEQUIPPED_EQUIPMENT_CARD 条件）。
##
## 通用机制（后续可复用）：
##   · ConditionChecker.HAS_UNEQUIPPED_EQUIPMENT_CARD + _unequipped_equipment_card_ids
##     枚举（PVP3 多玩家/多机甲通用，按玩家隔离）
##   · TimingEngine CHOOSE_MANY_CARDS 新增 OWNER_UNEQUIPPED_EQUIPMENT_CARDS 来源
##     （仅装备手牌，区别于尤里的 OWNER_EQUIPMENT_CARDS 含槽位）
##   · ConditionChecker.PAYLOAD_CARD_IS_WEAPON：读 payload[key]（store_result_key 存的
##     弃牌 id 数组）首张牌 def.equipment_kind 判断是否武器，驱动 CONDITIONAL_ACTIONS 分支
##   · store_result_key 确认路径同时 mark once_per_turn（取消=中止不消耗次数）
##
## 关键覆盖点：
##   1. 效果定义（MODE_DIRECT + 条件 IS_OWNER_MAIN_PHASE/HAS_UNEQUIPPED_EQUIPMENT_CARD
##      + NO_TARGET + once_per_turn_max=1 + 动作链 CHOOSE_MANY_CARDS->EXECUTE_DISCARD
##      ->GAIN_GOLD->EXECUTE_GAIN_CARD->CONDITIONAL_ACTIONS(PAYLOAD_CARD_IS_WEAPON)）。
##   2. 弃部件装 -> +2金 + 抽1张装备牌，不抽行动牌。
##   3. 弃武器装 -> +2金 + 抽1张装备牌 + 再抽2张行动牌。
##   4. "未设置"语义：仅有已设置槽位装备、装备手牌为空 -> 按钮置灰不挂起。
##   5. 取消选择 -> 中止不消耗次数（可再触发）。
##   6. 每回合1次用满 -> 第2次触发被跳过。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _ConditionChecker = preload("res://scripts/action_core/ConditionChecker.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90064
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


## 设柏格为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_boge(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_064_柏格", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 给玩家装备手牌加一张装备牌，返回实例 id
func _add_equip_to_hand(battle, pid: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"equipment_hand"
	gs.players.get(pid).equipment_hand.append(card.instance_id)
	return card.instance_id


## 给机甲某槽位设一张装备牌（直接赋值 equipped_card），返回实例 id
func _equip_on_slot(battle, mech, slot_id: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, mech.owner_player_id)
	if card == null:
		return &""
	card.zone = &"slot"
	card.mech_id = mech.mech_id
	card.slot_id = slot_id
	mech.slots.get(slot_id).equipped_card = card
	return card.instance_id


## 清空玩家装备手牌（"未设置"语义测试起点）
func _clear_equipment_hand(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var p = gs.players.get(pid)
	if p != null:
		p.equipment_hand.clear()


## 触发柏格 DIRECT 按钮（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_064(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
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


## resume 选择窗：选中 selected 张牌确认（store_result_key 路径，弃置+金币+抽牌续跑）
func _resume_select(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(15)


## resume 取消选择窗（中止，不消耗次数）
func _resume_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


func _equip_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.equipment_deck.size()


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


func _gold(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).gold


func _in_equip_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.equipment_discard_pile.has(cid)


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：效果定义正确
func test_pilot_064_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_064_effect_01")
	if e1 == null:
		return "缺 pilot_064_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_064_effect_01":
		return "once_per_turn_key 应 pilot_064_effect_01"
	if int(e1.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1（我方回合1次）"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_UNEQUIPPED_EQUIPMENT_CARD"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	if String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	var e1_acts = e1.actions
	if e1_acts.size() != 5:
		return "effect_01 应有5个动作 实=%d" % e1_acts.size()
	if String(e1_acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "effect_01 动作0 应 CHOOSE_MANY_CARDS"
	var cm_p = e1_acts[0].get("params", {})
	if String(cm_p.get("source", &"")) != "OWNER_UNEQUIPPED_EQUIPMENT_CARDS":
		return "effect_01 选择来源应 OWNER_UNEQUIPPED_EQUIPMENT_CARDS"
	if int(cm_p.get("max_count", 0)) != 1 or int(cm_p.get("min_count", 0)) != 1:
		return "effect_01 应 max_count=1 min_count=1"
	if String(cm_p.get("store_result_key", &"")) != "pilot_064_discard_ids":
		return "effect_01 store_result_key 应 pilot_064_discard_ids"
	if String(e1_acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "effect_01 动作1 应 EXECUTE_DISCARD"
	if String(e1_acts[2].get("type", &"")) != "GAIN_GOLD":
		return "effect_01 动作2 应 GAIN_GOLD"
	if int(e1_acts[2].get("params", {}).get("amount", 0)) != 2:
		return "effect_01 GAIN_GOLD 应 2"
	if String(e1_acts[3].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 动作3 应 EXECUTE_GAIN_CARD"
	if String(e1_acts[3].get("params", {}).get("from_zone", &"")) != "equipment_deck":
		return "effect_01 抽装备来源应 equipment_deck"
	if int(e1_acts[3].get("params", {}).get("count", 0)) != 1:
		return "effect_01 抽装备数量应 1"
	if String(e1_acts[4].get("type", &"")) != "CONDITIONAL_ACTIONS":
		return "effect_01 动作4 应 CONDITIONAL_ACTIONS"
	var ca_p = e1_acts[4].get("params", {})
	var ca_conds: Array = ca_p.get("conditions", [])
	if ca_conds.is_empty() or String(ca_conds[0].get("op", &"")) != "PAYLOAD_CARD_IS_WEAPON":
		return "effect_01 条件分支应 PAYLOAD_CARD_IS_WEAPON"
	if String(ca_conds[0].get("params", {}).get("key", &"")) != "pilot_064_discard_ids":
		return "effect_01 分支条件 key 应 pilot_064_discard_ids"
	var if_true: Array = ca_p.get("if_true_actions", [])
	if if_true.size() != 1 or String(if_true[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 if_true 应含1个 EXECUTE_GAIN_CARD"
	var true_p = if_true[0].get("params", {})
	if String(true_p.get("from_zone", &"")) != "action_deck" or String(true_p.get("card_kind", &"")) != "action":
		return "effect_01 武器分支应抽 action_deck 的行动牌"
	if int(true_p.get("count", 0)) != 2:
		return "effect_01 武器分支应再抽2张行动牌"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：弃部件装 -> +2金 + 抽1张装备牌，不抽行动牌
func test_pilot_064_discard_part_gold_draw_equipment() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_boge(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_equipment_hand(battle, &"player")
	var part_cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	if part_cid == &"":
		return "缺 part_001_量产装_头部"
	var deck_before: int = _equip_deck_size(battle)
	var gold_before: int = _gold(battle, &"player")
	var action_before: int = _action_hand_size(battle, &"player")
	var ef = await _fire_pilot_064(battle, s.pilot_card, s.mech, &"player", &"pilot_064_effect_01")
	if ef == null:
		return "effect_01 未挂起（应弹选装备窗）"
	await _resume_select(battle, ef, [part_cid])
	if not _in_equip_discard(battle, part_cid):
		return "被弃装备牌应在装备弃牌堆"
	if _gold(battle, &"player") != gold_before + 2:
		return "应 +2 金币 实=%d->%d" % [gold_before, _gold(battle, &"player")]
	if _equip_deck_size(battle) != deck_before - 1:
		return "装备牌堆应-1 实变=%d" % (_equip_deck_size(battle) - deck_before)
	# 弃部件装抽1 -> 装备手牌净1（起手1张，弃1抽1）
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 1:
		return "弃部件装抽1后装备手牌应1张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	# 不抽行动牌
	if _action_hand_size(battle, &"player") != action_before:
		return "弃部件装不应抽行动牌 实=%d->%d" % [action_before, _action_hand_size(battle, &"player")]
	return true


## 测试3：弃武器装 -> +2金 + 抽1张装备牌 + 再抽2张行动牌
func test_pilot_064_discard_weapon_bonus_actions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_boge(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_equipment_hand(battle, &"player")
	var weapon_cid = _add_equip_to_hand(battle, &"player", "weapon_001_光束军刀")
	if weapon_cid == &"":
		return "缺 weapon_001_光束军刀"
	var deck_before: int = _equip_deck_size(battle)
	var gold_before: int = _gold(battle, &"player")
	var action_before: int = _action_hand_size(battle, &"player")
	var ef = await _fire_pilot_064(battle, s.pilot_card, s.mech, &"player", &"pilot_064_effect_01")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_select(battle, ef, [weapon_cid])
	if not _in_equip_discard(battle, weapon_cid):
		return "被弃武器装备牌应在装备弃牌堆"
	if _gold(battle, &"player") != gold_before + 2:
		return "应 +2 金币 实=%d->%d" % [gold_before, _gold(battle, &"player")]
	if _equip_deck_size(battle) != deck_before - 1:
		return "装备牌堆应-1 实变=%d" % (_equip_deck_size(battle) - deck_before)
	# 弃武器装抽1 -> 装备手牌净1（起手1张，弃1抽1）
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 1:
		return "弃武器装抽1后装备手牌应1张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	# 武器分支 -> 再抽2张行动牌
	if _action_hand_size(battle, &"player") != action_before + 2:
		return "弃武器装应再抽2张行动牌 实=%d->%d" % [action_before, _action_hand_size(battle, &"player")]
	return true


## 测试4："未设置"语义——仅有已设置槽位装备、装备手牌为空 -> 按钮置灰（不挂起）
func test_pilot_064_no_unequipped_but_slot_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_boge(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_equipment_hand(battle, &"player")
	# 已设置槽位放1张装备（不该计入"未设置"候选，也不该让按钮亮起）
	var slot_cid = _equip_on_slot(battle, s.mech, &"头部", "part_001_量产装_头部")
	if slot_cid == &"":
		return "缺 part_001_量产装_头部"
	if s.mech.slots.get(&"头部").equipped_card == null:
		return "槽位装备设置失败"
	# 枚举 helper 只列装备手牌
	var gs = s.gs
	var uneq_ids: Array = _ConditionChecker._unequipped_equipment_card_ids(gs, &"player")
	if not uneq_ids.is_empty():
		return "装备手牌为空时 _unequipped_equipment_card_ids 应为空 实=%s" % str(uneq_ids)
	# 装备手牌为空 -> HAS_UNEQUIPPED_EQUIPMENT_CARD 不满足 -> 不挂起（按钮置灰）
	var ef = await _fire_pilot_064(battle, s.pilot_card, s.mech, &"player", &"pilot_064_effect_01")
	if ef != null:
		return "装备手牌为空时不应挂起（按钮应置灰）"
	return true


## 测试5：取消选择 -> 中止，不弃牌不消耗次数（可再触发）
func test_pilot_064_cancel_abort_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_boge(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_equipment_hand(battle, &"player")
	var hand_cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	if hand_cid == &"":
		return "缺 part_001_量产装_头部"
	var deck_before: int = _equip_deck_size(battle)
	var gold_before: int = _gold(battle, &"player")
	var ef = await _fire_pilot_064(battle, s.pilot_card, s.mech, &"player", &"pilot_064_effect_01")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_cancel(battle, ef)
	if _in_equip_discard(battle, hand_cid):
		return "取消不应弃牌"
	if _gold(battle, &"player") != gold_before:
		return "取消不应获得金币"
	if _equip_deck_size(battle) != deck_before:
		return "取消不应抽牌"
	# 次数未消耗：可再触发
	var ef2 = await _fire_pilot_064(battle, s.pilot_card, s.mech, &"player", &"pilot_064_effect_01")
	if ef2 == null:
		return "取消中止后应可再触发"
	await _resume_cancel(battle, ef2)
	return true


## 测试6：每回合1次用满 -> 第2次触发被跳过
func test_pilot_064_once_per_turn_max_1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_boge(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_equipment_hand(battle, &"player")
	var c1 = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	var c2 = _add_equip_to_hand(battle, &"player", "part_002_量产装_躯干")
	if c1 == &"" or c2 == &"":
		return "装备牌设置失败"
	# 第一次：完整发动（弃1抽1）
	var ef1 = await _fire_pilot_064(battle, s.pilot_card, s.mech, &"player", &"pilot_064_effect_01")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_select(battle, ef1, [c1])
	# 第二次：once_per_turn_max=1 用满 -> 跳过，不挂起
	var ef2 = await _fire_pilot_064(battle, s.pilot_card, s.mech, &"player", &"pilot_064_effect_01")
	if ef2 != null:
		return "第2次不应挂起（once_per_turn 用满）"
	# 起手2张，弃1抽1 -> 装备手牌2张（c2 仍在）
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 2:
		return "发动后装备手牌应2张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	return true
