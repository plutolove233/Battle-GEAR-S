## test_pilot_033_uri.gd - 尤里（pilot_033，联邦 R）效果测试
##
## 尤里 2 个主动效果按钮（DIRECT，同时渲染主动/被动按钮区）：
##   effect_01（每我方回合2次）「弃装抽装」：弹单选窗列持有者所有装备牌
##     （装备手牌 + 其所有机甲已设置槽位含备用区，OWNER_EQUIPMENT_CARDS 通用来源），
##     选1张弃置 -> 抽1张装备牌。无装备可弃按钮置灰（HAS_EQUIPMENT_CARD 条件）。
##   effect_02（本局游戏1次）「弃装抽高级」：同上选1张装备弃置 -> 抽1张高级装备牌
##     （DRAW_ADVANCED_EQUIPMENT 原子动作，本局1次 once_per_game_key）。
##
## 通用机制（后续可复用，如 pilot_036 等）：
##   · ConditionChecker.HAS_EQUIPMENT_CARD + _equipment_card_ids 枚举（PVP3 多玩家/多机甲通用）
##   · TimingEngine CHOOSE_MANY_CARDS 新增 OWNER_EQUIPMENT_CARDS 来源（装备手牌+已设置槽位+备用区）
##   · store_result_key 确认路径同时消耗 once_per_game（本局1次）
##   · DeckService.draw_advanced_equipment（DRAW_ADVANCED_EQUIPMENT 原子动作补全）
##
## 关键覆盖点：
##   1. 两个效果定义（MODE_DIRECT + 条件 IS_OWNER_MAIN_PHASE/HAS_EQUIPMENT_CARD + NO_TARGET
##      + once_per_turn_max=2 / once_per_game_max=1 + 动作链 CHOOSE_MANY_CARDS->EXECUTE_DISCARD->抽牌）。
##   2. effect_01 完整流程：弃装备手牌 / 已设置槽位 / 备用区 -> 抽1张装备牌。
##   3. effect_02 完整流程：弃1张装备 -> 抽1张高级装备牌。
##   4. 取消选择 -> 中止不消耗次数（可再触发）。
##   5. effect_01 每回合2次用满 -> 第3次触发被跳过。
##   6. effect_02 本局1次用满 -> 第2次触发被跳过。
##   7. HAS_EQUIPMENT_CARD 条件：无装备可弃 -> effect_fire 不挂起（按钮置灰）。
##   8. PVP3 多人类玩家通用：third 玩家机甲上装备也计入 OWNER_EQUIPMENT_CARDS（按玩家隔离）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _ConditionChecker = preload("res://scripts/action_core/ConditionChecker.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90033
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


## 设尤里为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_yuri(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_033_尤里", owner_id)
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
	# 6 部件 + 2 武器 + 2 备用（含 HEAD 用于 _equip_on_slot）
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿", &"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2", &"event", &"pilot"]:
		var sl := _MechSlotState.new()
		sl.slot_id = slot_id
		sl.slot_kind = &"PART"
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m
	return m


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


## 给机甲某槽位设一张装备牌（直接赋值 equipped_card，与 test_pilot_008 一致），返回实例 id
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


## 清空玩家装备（装备手牌 + 所有机甲已设置槽位含备用区）——从测试洁净起点开始
func _clear_player_equipment(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var p = gs.players.get(pid)
	if p == null:
		return
	p.equipment_hand.clear()
	for mech in gs.mechs.values():
		if mech == null or String(mech.owner_player_id) != String(pid):
			continue
		for sid: StringName in mech.slots:
			var slot = mech.slots.get(sid)
			if slot != null:
				slot.equipped_card = null


## 触发尤里 DIRECT 按钮（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_033(battle, pilot_card, mech, player_id: StringName, effect_id: StringName) -> _Action:
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


func _equip_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.equipment_deck.size()


func _adv_deck_size(battle) -> int:
	return battle.context.game_state.deck_state.advanced_equipment_deck.size()


## 检查 cid 是否在玩家装备手牌
func _in_equip_hand(battle, pid: StringName, cid: StringName) -> bool:
	return battle.context.game_state.players.get(pid).equipment_hand.has(cid)


## 检查 cid 是否在装备弃牌堆
func _in_equip_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.equipment_discard_pile.has(cid)


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：两个效果定义正确
func test_pilot_033_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_033_effect_01")
	if e1 == null:
		return "缺 pilot_033_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_033_effect_01":
		return "once_per_turn_key 应 pilot_033_effect_01"
	if int(e1.once_per_turn_max) != 2:
		return "once_per_turn_max 应 2（我方回合2次）"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_EQUIPMENT_CARD"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	if String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	var e1_acts = e1.actions
	if e1_acts.size() != 3:
		return "effect_01 应有3个动作 实=%d" % e1_acts.size()
	if String(e1_acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "effect_01 动作0 应 CHOOSE_MANY_CARDS"
	var cm_p = e1_acts[0].get("params", {})
	if String(cm_p.get("source", &"")) != "OWNER_EQUIPMENT_CARDS":
		return "effect_01 选择来源应 OWNER_EQUIPMENT_CARDS"
	if int(cm_p.get("max_count", 0)) != 1 or int(cm_p.get("min_count", 0)) != 1:
		return "effect_01 应 max_count=1 min_count=1"
	if String(cm_p.get("store_result_key", &"")) != "pilot_033_discard_ids":
		return "effect_01 store_result_key 应 pilot_033_discard_ids"
	if String(e1_acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "effect_01 动作1 应 EXECUTE_DISCARD"
	if String(e1_acts[2].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 动作2 应 EXECUTE_GAIN_CARD"
	if String(e1_acts[2].get("params", {}).get("from_zone", &"")) != "equipment_deck":
		return "effect_01 抽牌来源应 equipment_deck"
	var e2 = effects.get(&"pilot_033_effect_02")
	if e2 == null:
		return "缺 pilot_033_effect_02"
	if e2.mode != _TimingConst.MODE_DIRECT:
		return "effect_02 mode 应 MODE_DIRECT 实=%s" % String(e2.mode)
	if e2.once_per_game_key != &"pilot_033_effect_02":
		return "once_per_game_key 应 pilot_033_effect_02"
	if int(e2.once_per_game_max) != 1:
		return "once_per_game_max 应 1（本局游戏1次）"
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String(c.get("op", &"")))
	if not e2_ops.has("HAS_EQUIPMENT_CARD"):
		return "effect_02 应含 HAS_EQUIPMENT_CARD"
	var e2_acts = e2.actions
	if e2_acts.size() != 3:
		return "effect_02 应有3个动作 实=%d" % e2_acts.size()
	if String(e2_acts[2].get("type", &"")) != "DRAW_ADVANCED_EQUIPMENT":
		return "effect_02 动作2 应 DRAW_ADVANCED_EQUIPMENT"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：effect_01 完整流程——弃装备手牌1张 -> 抽1张装备牌
func test_pilot_033_effect1_discard_hand_draw_equipment() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	var hand_cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	if hand_cid == &"":
		return "缺 part_001_量产装_头部"
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef == null:
		return "effect_01 未挂起（应弹选装备窗）"
	await _resume_select(battle, ef, [hand_cid])
	if not _in_equip_discard(battle, hand_cid):
		return "被弃装备牌应在装备弃牌堆"
	if _in_equip_hand(battle, &"player", hand_cid):
		return "被弃装备牌不应仍在装备手牌"
	# 弃1抽1 -> 手牌净1张，装备牌堆 -1
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 1:
		return "弃1抽1后装备手牌应1张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	if _equip_deck_size(battle) != deck_before - 1:
		return "装备牌堆应-1 实变=%d" % (_equip_deck_size(battle) - deck_before)
	return true


## 测试3：effect_01 完整流程——弃已设置槽位装备（部件槽）-> 抽1张装备牌，槽位清空
func test_pilot_033_effect1_discard_equipped_slot() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	var slot_cid = _equip_on_slot(battle, s.mech, &"头部", "part_001_量产装_头部")
	if slot_cid == &"":
		return "缺 part_001_量产装_头部"
	if s.mech.slots.get(&"头部").equipped_card == null:
		return "槽位装备设置失败"
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_select(battle, ef, [slot_cid])
	if s.mech.slots.get(&"头部").equipped_card != null:
		return "被弃槽位装备后 equipped_card 应清空"
	if not _in_equip_discard(battle, slot_cid):
		return "被弃槽位装备应在装备弃牌堆"
	# 弃槽位装备（非手牌）-> 抽1 -> 手牌 +1
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 1:
		return "弃槽位装备抽1后装备手牌应1张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	if _equip_deck_size(battle) != deck_before - 1:
		return "装备牌堆应-1 实变=%d" % (_equip_deck_size(battle) - deck_before)
	return true


## 测试4：effect_01 完整流程——弃备用区装备 -> 抽1张装备牌
func test_pilot_033_effect1_discard_reserve_slot() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	var reserve_cid = _equip_on_slot(battle, s.mech, &"reserve_1", "part_001_量产装_头部")
	if reserve_cid == &"":
		return "缺 part_001_量产装_头部"
	if s.mech.slots.get(&"reserve_1").equipped_card == null:
		return "备用区装备设置失败"
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_select(battle, ef, [reserve_cid])
	if s.mech.slots.get(&"reserve_1").equipped_card != null:
		return "被弃备用区装备后 equipped_card 应清空"
	if not _in_equip_discard(battle, reserve_cid):
		return "被弃备用区装备应在装备弃牌堆"
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 1:
		return "弃备用区装备抽1后装备手牌应1张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	if _equip_deck_size(battle) != deck_before - 1:
		return "装备牌堆应-1 实变=%d" % (_equip_deck_size(battle) - deck_before)
	return true


## 测试5：effect_02 完整流程——弃1张装备 -> 抽1张高级装备牌
func test_pilot_033_effect2_discard_draw_advanced() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	var hand_cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	if hand_cid == &"":
		return "缺 part_001_量产装_头部"
	var adv_before: int = _adv_deck_size(battle)
	if adv_before <= 0:
		return "高级装备牌堆为空，无法验证抽高级"
	var ef = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_02")
	if ef == null:
		return "effect_02 未挂起"
	await _resume_select(battle, ef, [hand_cid])
	if not _in_equip_discard(battle, hand_cid):
		return "effect_02 被弃装备应在装备弃牌堆"
	# 弃手牌1 + 抽高级1 -> 装备手牌净1张（抽的是高级装备）
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 1:
		return "弃1抽高级1后装备手牌应1张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	if _adv_deck_size(battle) != adv_before - 1:
		return "高级装备牌堆应-1 实变=%d" % (_adv_deck_size(battle) - adv_before)
	return true


## 测试6：取消选择 -> 中止，不弃牌不抽牌不消耗次数（可再触发）
func test_pilot_033_cancel_abort_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	var hand_cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	if hand_cid == &"":
		return "缺 part_001_量产装_头部"
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_cancel(battle, ef)
	if _in_equip_discard(battle, hand_cid):
		return "取消不应弃牌"
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 1:
		return "取消后装备手牌应仍1张"
	if _equip_deck_size(battle) != deck_before:
		return "取消不应抽牌"
	# 次数未消耗：可再触发
	var ef2 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef2 == null:
		return "取消中止后应可再触发"
	await _resume_cancel(battle, ef2)
	return true


## 测试7：effect_01 每回合2次用满 -> 第3次触发被跳过
func test_pilot_033_effect1_once_per_turn_max_2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	var c1 = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	var c2 = _add_equip_to_hand(battle, &"player", "part_002_量产装_躯干")
	if c1 == &"" or c2 == &"":
		return "装备牌设置失败"
	# 第一次
	var ef1 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_select(battle, ef1, [c1])
	# 第二次
	var ef2 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef2 == null:
		return "第2次未挂起"
	await _resume_select(battle, ef2, [c2])
	# 第三次：once_per_turn_max=2 用满 -> 跳过，不挂起
	var ef3 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef3 != null:
		return "第3次不应挂起（once_per_turn 用满）"
	# 弃2抽2 -> 手牌2张
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != 2:
		return "两次完整发动后装备手牌应2张 实=%d" % battle.context.game_state.players.get(&"player").equipment_hand.size()
	return true


## 测试8：effect_02 本局1次用满 -> 第2次触发被跳过
func test_pilot_033_effect2_once_per_game_max_1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	var c1 = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	if c1 == &"":
		return "装备牌设置失败"
	# 第一次：完整发动（弃1抽高级1）
	var ef1 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_02")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_select(battle, ef1, [c1])
	var hand_after_first: int = battle.context.game_state.players.get(&"player").equipment_hand.size()
	# 第二次：once_per_game 用满 -> 跳过，不挂起
	var ef2 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_02")
	if ef2 != null:
		return "第2次不应挂起（once_per_game 用满）"
	if battle.context.game_state.players.get(&"player").equipment_hand.size() != hand_after_first:
		return "第2次跳过不应再抽牌"
	return true


## 测试9：无装备可弃 -> HAS_EQUIPMENT_CARD 条件不满足 -> 按钮置灰（不挂起）
func test_pilot_033_no_equipment_gray() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yuri(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_equipment(battle, &"player")
	# 玩家无任何装备（手牌/槽位/备用区全空）-> effect_01/02 条件 HAS_EQUIPMENT_CARD 不满足
	var ef1 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_01")
	if ef1 != null:
		return "无装备时 effect_01 不应挂起（按钮应置灰）"
	var ef2 = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"player", &"pilot_033_effect_02")
	if ef2 != null:
		return "无装备时 effect_02 不应挂起（按钮应置灰）"
	return true


## 测试10：PVP3 多人类玩家通用——third 玩家机甲装备计入 OWNER_EQUIPMENT_CARDS（按玩家隔离）
func test_pilot_033_owner_equipment_across_players() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_yuri(battle, &"third")
	if s.is_empty():
		return "third setup 失败（尤里设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	# player 放1张装备手牌（不应出现在 third 的可选列表）
	_add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	# third 机甲头部槽位放1张装备（应计入 third 的可选列表）
	var third_equip = _equip_on_slot(battle, s.mech, &"头部", "part_002_量产装_躯干")
	if third_equip == &"":
		return "third 装备设置失败"
	# 枚举 helper 按玩家隔离
	var gs = s.gs
	var third_ids: Array = _ConditionChecker._equipment_card_ids(gs, &"third")
	if third_ids.size() != 1 or String(third_ids[0]) != String(third_equip):
		return "third OWNER_EQUIPMENT_CARDS 应只含 third 自己的装备 实=%s" % str(third_ids)
	var player_ids: Array = _ConditionChecker._equipment_card_ids(gs, &"player")
	if player_ids.size() != 1 or String(player_ids[0]) == String(third_equip):
		return "player 枚举应只含 player 自己的装备且不含 third 的"
	# third 完整发动 effect_01：弃自己槽位装备 -> 抽1张装备
	var deck_before: int = _equip_deck_size(battle)
	var ef = await _fire_pilot_033(battle, s.pilot_card, s.mech, &"third", &"pilot_033_effect_01")
	if ef == null:
		return "third 触发 effect_01 未挂起"
	await _resume_select(battle, ef, [third_equip])
	if s.mech.slots.get(&"头部").equipped_card != null:
		return "third 被弃槽位装备后 equipped_card 应清空"
	if not _in_equip_discard(battle, third_equip):
		return "third 被弃装备应在装备弃牌堆"
	if gs.players.get(&"third").equipment_hand.size() != 1:
		return "third 弃1抽1后装备手牌应1张 实=%d" % gs.players.get(&"third").equipment_hand.size()
	if _equip_deck_size(battle) != deck_before - 1:
		return "third 发动后装备牌堆应-1 实变=%d" % (_equip_deck_size(battle) - deck_before)
	return true
