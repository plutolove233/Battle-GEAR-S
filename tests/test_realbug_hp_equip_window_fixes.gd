## test_realbug_hp_equip_window_fixes.gd - 实机四 bug 修复回归测试
##
## 覆盖（2026-08-21 实机 bug 四连修复）：
##   Bug1 霍克 p055 卖出弹窗不出现：手牌装备牌 mech_id 为空（真实抽牌/购买路径）
##       -> 弃牌快照 from_mech_id 空 -> DISCARD_INCLUDED_OWNER_ACTION_CARD 不匹配。
##       修复：快照按 owner_player_id 反查持有者机甲兜底 + 各抽牌/购买路径补设 mech_id。
##   Bug2 杰狞 p049 转移不了里欧娜 p047 交牌差额伤害：直接改 current_hp 绕过
##       hp_change 动作 -> HP_CHANGE_BEFORE 不触发。修复：p047 差额 / p006 回落 /
##       p019 清空4伤害 统一转 EXECUTE_HP_CHANGE 子动作（通用 _deal_direct_hp_change_sub）。
##   Bug3 光束狙击枪 effect_101 强制落点损伤不破坏装备：place_damage_tokens_on_slot
##       从不检查装备损坏。修复：逐 token 调 _check_equipment_broken_after_damage
##       （与 place_damage_tokens 一致，损伤≥耐久立即触发损坏流）。
##   Bug4 洛尔恩 p062 转化掩护无处展示：掩护多选窗宿主是掩护牌手牌监听器，
##       无真实掩护牌时窗口不弹。修复：通用 cover_window_host / thrust_window_host
##       机师绑定宿主效果（JSON effect_ids 引用，无真实牌也弹窗）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90210
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
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


func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_rbf_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 创建独立第三方机甲（杰狞载体）+ third 人类玩家记录（弹窗路由需要），返回机甲；null 失败
func _create_third_mech(battle, mech_id: StringName, pos: Dictionary) -> _MechState:
	var gs = battle.context.game_state
	if not gs.players.has(&"third"):
		var p = preload("res://scripts/runtime/PlayerState.gd").new()
		p.player_id = &"third"
		p.gold = 15
		p.is_human = true
		gs.players[&"third"] = p
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var slot = _MechSlotState.new()
		slot.slot_id = slot_id
		slot.slot_kind = &"PART"
		m.slots[slot_id] = slot
	# 机师槽位：set_pilot 无 pilot 槽会静默 return（效果永不注册），必须补建
	# （真实机甲由 GameSetupService 统一创建 PILOT 槽）。
	var pilot_slot = _MechSlotState.new()
	pilot_slot.slot_id = &"pilot"
	pilot_slot.slot_kind = &"PILOT"
	m.slots[&"pilot"] = pilot_slot
	gs.mechs[m.mech_id] = m
	return m


## 清空地图全部格子地形为 NORMAL（避免随机 GREEN/RED 干扰射程 BFS）
func _clear_map_terrain(battle) -> void:
	var ms = battle.context.game_state.map_state
	if ms == null:
		return
	for key in ms.cells:
		ms.cells[key].terrain = &"NORMAL"


## 找挂起的 hp_change 动作（杰狞转移弹窗）；无返回 null
func _find_suspended_hp_change(battle):
	for a in battle.context.action_registry.get_actions_by_type(&"hp_change"):
		if a.state == &"waiting_timing":
			return a
	return null


# ═══════════════════════════════════════════
# Bug 1：霍克卖出弹窗（手牌装备 mech_id 为空）
# ═══════════════════════════════════════════

## Bug1 核心：装备牌进手牌但不设 mech_id（真实抽牌/商店购买路径的牌），
## 卖出后霍克确认弹窗应挂起（修复前快照 from_mech_id 为空 -> 条件不匹配 -> 永不弹窗）。
func test_bug1_hawk_sell_popup_equipment_without_mech_id() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return "player 机甲缺失"
	var hawk = _make_instance(gs, cdb, "pilot_055_霍克", &"player")
	if hawk == null:
		return "找不到 pilot_055_霍克"
	battle.context.game_setup_service.set_pilot(mech.mech_id, hawk)
	battle.context.action_ui_bridge.context = battle.context
	gs.players.get(&"player").gold = 50
	# bug 场景：装备牌在手牌但 mech_id 为空（真实抽牌/购买路径不设置）
	var card = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if card == null:
		return "找不到 part_001_量产装_头部"
	if card.mech_id != &"":
		return "测试前提：新实例 mech_id 应为空"
	card.zone = &"equipment_hand"
	gs.players.get(&"player").equipment_hand.append(card.instance_id)
	var cost: int = card.def.cost
	var gold_before: int = gs.players.get(&"player").gold
	# 真实卖出路径：gain_gold(sell_price) -> discard_card -> DISCARD_BEFORE -> 霍克
	gs.active_player_id = &"player"
	gs.players.get(&"player").sell_equipment_count_this_turn = 0
	battle.context.card_set_service.sell_equipment(&"player", card.instance_id)
	await _pump_frames(8)
	var suspended = null
	for a in battle.context.action_registry.get_actions_by_type(&"discard_card"):
		if a.state == &"waiting_timing" or a.state == &"waiting_input":
			suspended = a
			break
	if suspended == null:
		return "卖出后霍克确认弹窗未挂起（Bug1 未修复：from_mech_id 兜底失效）"
	# 确认发动 -> 金币 +2×卖价（补发1倍）
	battle.context.timing_engine.resume_pending_effect(suspended.action_id, {"chosen_option_index": 0})
	await _pump_frames(12)
	if gs.players.get(&"player").gold != gold_before + cost * 2:
		return "确认后金币应 +2×卖价=%d，实净变=%d" % [cost * 2, gs.players.get(&"player").gold - gold_before]
	return true


## Bug1 配套：抽装备牌路径补设 mech_id（draw_equipment_cards）。
func test_bug1_draw_equipment_cards_sets_mech_id() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return "player 机甲缺失"
	if gs.deck_state.equipment_deck.is_empty():
		return "装备牌堆为空，无法测抽牌"
	var drawn: Array = battle.context.game_actions.draw_equipment_cards({"player_id": &"player", "count": 1})
	if drawn.is_empty():
		return "抽牌失败"
	var card = gs.get_card(drawn[0])
	if card == null:
		return "抽到的牌实例缺失"
	if card.owner_player_id != &"player":
		return "抽到的牌 owner 应=player，实=%s" % String(card.owner_player_id)
	if String(card.mech_id) != String(mech.mech_id):
		return "Bug1 修复：抽到的装备牌 mech_id 应=持有者机甲 %s，实=%s" % [String(mech.mech_id), String(card.mech_id)]
	return true


## Bug1 配套：gain_specific_card 装备牌进手牌补设 mech_id。
func test_bug1_gain_specific_card_equipment_sets_mech_id() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return "player 机甲缺失"
	battle.context.game_actions.gain_specific_card({"player_id": &"player", "card_def_id": "part_001_量产装_头部"})
	var hand: Array = gs.players.get(&"player").equipment_hand
	if hand.is_empty():
		return "gain_specific_card 后装备手牌为空"
	var inst_id: StringName = hand[hand.size() - 1]
	var card = gs.get_card(inst_id)
	if card == null:
		return "牌实例缺失"
	if String(card.def.card_id) != "part_001_量产装_头部":
		return "进手牌的最后一张应为 part_001"
	if not gs.players.get(&"player").equipment_hand.has(inst_id):
		return "牌应进 equipment_hand"
	if String(card.mech_id) != String(mech.mech_id):
		return "Bug1 修复：gain_specific_card 装备牌 mech_id 应=持有者机甲，实=%s" % String(card.mech_id)
	return true


# ═══════════════════════════════════════════
# Bug 2：直接伤害转 EXECUTE_HP_CHANGE 子动作（杰狞可转移）
# ═══════════════════════════════════════════

## Bug2 核心：里欧娜 p047 威逼空手 enemy 交牌 -> 差额伤害（hp_change 子动作）
## -> 杰狞（third 机甲，4格内）转移弹窗挂起 -> 确认 -> third 扣血、enemy 不扣。
## 修复前：直接改 enemy.current_hp，HP_CHANGE_BEFORE 不触发，杰狞无法转移。
func test_bug2_p047_shortfall_damage_transferable_by_jiening() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	battle.context.action_ui_bridge.context = battle.context
	_clear_map_terrain(battle)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	# 里欧娜在 player 机甲（攻击方+威逼发起者）
	var leona = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	if leona == null:
		return "找不到 pilot_047_里欧娜"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, leona)
	# 杰狞在 third 机甲（距 enemy ≤4，可转移 enemy 受到的伤害）
	var third = _create_third_mech(battle, &"third_mech_rbf", {"q": 4, "r": 2})
	var jiening = _make_instance(gs, cdb, "pilot_049_杰狞", &"third")
	if jiening == null:
		return "找不到 pilot_049_杰狞"
	battle.context.game_setup_service.set_pilot(third.mech_id, jiening)
	# enemy 空手（无攻击牌无手牌）-> 全差额 3张*2=6伤害
	gs.players.get(&"enemy").action_hand.clear()
	enemy_mech.position = {"q": 6, "r": 2}  # 距 player 2格(≤5 威逼范围)；距 third 2格(≤4 转移范围)
	player_mech.position = {"q": 6, "r": 0}
	var enemy_hp_before: int = enemy_mech.current_hp
	var third_hp_before: int = third.current_hp
	# 走真实 ATTACK_SETTLE 链：确认发动 -> 选 enemy 机甲 -> 空手自动交牌 -> 差额伤害
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	if attack.state != &"waiting_timing":
		return "应挂起确认弹窗 state=%s" % String(attack.state)
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(8)
	# 差额伤害应走 hp_change 子动作：enemy 伤害被杰狞拦截（挂起转移弹窗）
	var hp_sub = _find_suspended_hp_change(battle)
	if hp_sub == null:
		if enemy_mech.current_hp == enemy_hp_before - 6 and third.current_hp == third_hp_before:
			return "差额伤害直接扣了 enemy HP（Bug2 未修复：未走 hp_change 子动作，杰狞无法转移）"
		return "差额伤害后应挂起杰狞转移弹窗（hp_change waiting_timing），未找到"
	if attack.state != &"waiting_effect_action":
		return "父 attack 应等待 hp_change 子动作，实=%s" % String(attack.state)
	# 确认转移 -> mech_ids 改 third
	battle.context.timing_engine.resume_pending_effect(hp_sub.action_id, {"chosen_option_index": 0})
	await _pump_frames(12)
	if enemy_mech.current_hp != enemy_hp_before:
		return "转移后 enemy HP 应不变（before=%d after=%d）" % [enemy_hp_before, enemy_mech.current_hp]
	if third.current_hp != third_hp_before - 6:
		return "转移后 third 应扣6 HP（before=%d after=%d）" % [third_hp_before, third.current_hp]
	return true


## Bug2 配套：p047 差额伤害无杰狞时正常扣血（子动作同步完成，无回归）。
func test_bug2_p047_shortfall_damage_no_listener() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	battle.context.action_ui_bridge.context = battle.context
	_clear_map_terrain(battle)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var leona = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, leona)
	gs.players.get(&"enemy").action_hand.clear()
	enemy_mech.position = {"q": 6, "r": 2}
	player_mech.position = {"q": 6, "r": 0}
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(10)
	if enemy_mech.current_hp != hp_before - 6:
		return "无监听者差额伤害应同步扣6 HP（before=%d after=%d）" % [hp_before, enemy_mech.current_hp]
	return true


## Bug2 配套：p006 战后逼迫回落4伤害走 hp_change 子动作（杰狞可拦截）。
func test_bug2_p006_fallback_damage_hp_change_sub() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_map_terrain(battle)
	# 杰狞在 third（距 enemy ≤4）
	var third = _create_third_mech(battle, &"third_mech_rbf2", {"q": 5, "r": 2})
	var jiening = _make_instance(gs, cdb, "pilot_049_杰狞", &"third")
	battle.context.game_setup_service.set_pilot(third.mech_id, jiening)
	enemy_mech.position = {"q": 6, "r": 2}
	player_mech.position = {"q": 6, "r": 0}
	var third_hp_before: int = third.current_hp
	var enemy_hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	var payload: Dictionary = {"binding_context": {"mech_id": player_mech.mech_id, "player_id": &"player"}}
	var paused: bool = battle.context.timing_engine._pilot_006_fallback_damage(enemy_mech.mech_id, attack, payload)
	if not paused:
		return "回落4伤害应挂起（杰狞转移弹窗拦截 hp_change）"
	if attack.state != &"waiting_effect_action":
		return "父 attack 应 waiting_effect_action，实=%s" % String(attack.state)
	var hp_sub = _find_suspended_hp_change(battle)
	if hp_sub == null:
		return "应存在挂起的 hp_change 子动作"
	battle.context.timing_engine.resume_pending_effect(hp_sub.action_id, {"chosen_option_index": 0})
	await _pump_frames(12)
	if enemy_mech.current_hp != enemy_hp_before:
		return "转移后 enemy HP 应不变"
	if third.current_hp != third_hp_before - 4:
		return "转移后 third 应扣4 HP（before=%d after=%d）" % [third_hp_before, third.current_hp]
	return true


## Bug2 配套：通用 _deal_direct_hp_change_sub 无监听器同步完成扣血（直接伤害路径无回归）。
func test_bug2_deal_direct_hp_change_sub_sync() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	var hp_before: int = enemy_mech.current_hp
	var paused: bool = battle.context.timing_engine._deal_direct_hp_change_sub(
		attack, {}, enemy_mech.mech_id, 4, player_mech.mech_id, &"test_direct")
	if paused:
		return "无监听者应同步完成不挂起"
	if enemy_mech.current_hp != hp_before - 4:
		return "同步路径应扣4 HP（before=%d after=%d）" % [hp_before, enemy_mech.current_hp]
	if attack.state == &"waiting_effect_action":
		return "同步完成后父动作不应停在 waiting_effect_action"
	return true


## Bug2 配套：通用 _deal_direct_hp_change_sub 致死走 destroy_mech（hp_change 步骤语义）。
func test_bug2_deal_direct_hp_change_sub_lethal() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	enemy_mech.current_hp = 3
	battle.context.timing_engine._deal_direct_hp_change_sub(
		attack, {}, enemy_mech.mech_id, 4, player_mech.mech_id, &"test_lethal")
	await _pump_frames(5)
	if not enemy_mech.destroyed:
		return "4伤害打3 HP 机甲应被摧毁"
	return true


# ═══════════════════════════════════════════
# Bug 3：place_damage_tokens_on_slot 装备破坏
# ═══════════════════════════════════════════

## Bug3 核心：强制落点放置损伤 ≥ 耐久 -> 装备立即损坏弃置（光束狙击枪 effect_101 实机 bug）。
func test_bug3_place_tokens_on_slot_breaks_equipment() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(&"player")
	var card = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if card == null:
		return "找不到 part_001_量产装_头部"
	var dura: int = int(card.def.durability)
	if dura <= 0:
		return "测试装备耐久应>0，实=%d" % dura
	card.damage_tokens = 0
	mech.slots[&"头部"].equipped_card = card
	battle.context.game_actions.place_damage_tokens_on_slot({
		"mech_id": mech.mech_id, "slot_id": &"头部", "amount": dura})
	await _pump_frames(5)
	if mech.slots[&"头部"].equipped_card != null:
		return "Bug3 修复：损伤%d≥耐久%d 装备应被弃置（槽位应清空）" % [dura, dura]
	if not gs.deck_state.equipment_discard_pile.has(card.instance_id):
		return "损坏装备应进装备弃牌堆，zone=%s" % String(card.zone)
	return true


## Bug3 配套：低于耐久不破坏（正常放置仍工作）。
func test_bug3_place_tokens_below_durability_no_break() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(&"player")
	var card = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	var dura: int = int(card.def.durability)
	if dura < 2:
		return "测试装备耐久应≥2，实=%d" % dura
	card.damage_tokens = 0
	mech.slots[&"头部"].equipped_card = card
	battle.context.game_actions.place_damage_tokens_on_slot({
		"mech_id": mech.mech_id, "slot_id": &"头部", "amount": dura - 1})
	await _pump_frames(5)
	if mech.slots[&"头部"].equipped_card == null:
		return "低于耐久 %d/%d 装备不应被弃置" % [dura - 1, dura]
	if int(card.damage_tokens) != dura - 1:
		return "损伤应=%d，实=%d" % [dura - 1, int(card.damage_tokens)]
	return true


# ═══════════════════════════════════════════
# Bug 4：通用窗口宿主效果定义 + JSON 引用
# ═══════════════════════════════════════════

## Bug4 配套：cover_window_host / thrust_window_host 定义形状正确（真实路径行为
## 由 test_pilot_062_realpath.gd 覆盖：无掩护牌也弹窗 + extra 选项展示）。
func test_bug4_window_host_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var ch = effects.get(&"cover_window_host")
	if ch == null:
		return "缺 cover_window_host"
	if ch.mode != _TimingConst.MODE_LISTEN:
		return "cover_window_host mode 应 LISTEN"
	if ch.listen_timing != _TimingConst.ATTACK_PRE:
		return "cover_window_host 应监听 ATTACK_PRE，实=%s" % String(ch.listen_timing)
	if ch.listen_action_type != &"attack":
		return "cover_window_host listen_action_type 应 attack"
	if not bool(ch.hide_button):
		return "cover_window_host 应 hide_button=true"
	var ch_ops: Array = []
	for c in ch.conditions:
		ch_ops.append(String(c.get("op", &"")))
	if not ch_ops.has("TARGET_IN_COVER_RANGE"):
		return "cover_window_host 应含条件 TARGET_IN_COVER_RANGE"
	var ch_acts = ch.actions
	if ch_acts.size() != 1 or String(ch_acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "cover_window_host actions 应 [CHOOSE_MANY_CARDS]"
	if not bool(ch_acts[0].get("params", {}).get("collect_cover_window_extras", false)):
		return "cover_window_host CHOOSE_MANY_CARDS 应 collect_cover_window_extras=true"
	if StringName(String(ch_acts[0].get("params", {}).get("card_def_id", &""))) != &"action_016_掩护":
		return "cover_window_host card_def_id 应 action_016_掩护"

	var th = effects.get(&"thrust_window_host")
	if th == null:
		return "缺 thrust_window_host"
	if th.mode != _TimingConst.MODE_LISTEN:
		return "thrust_window_host mode 应 LISTEN"
	if th.listen_timing != _TimingConst.USE_ACTION_AT:
		return "thrust_window_host 应监听 USE_ACTION_AT，实=%s" % String(th.listen_timing)
	if th.listen_action_type != &"use_action_card":
		return "thrust_window_host listen_action_type 应 use_action_card"
	if not bool(th.hide_button):
		return "thrust_window_host 应 hide_button=true"
	var th_ops: Array = []
	for c in th.conditions:
		th_ops.append(String(c.get("op", &"")))
	if not th_ops.has("USED_COUNTER_CARD"):
		return "thrust_window_host 应含条件 USED_COUNTER_CARD"
	if not bool(th.actions[0].get("params", {}).get("collect_thrust_window_extras", false)):
		return "thrust_window_host CHOOSE_MANY_CARDS 应 collect_thrust_window_extras=true"
	return true


## Bug4 配套：pilot_062/pilot_082 JSON effect_ids 引用宿主效果（两份数据目录一致）。
func test_bug4_pilot_json_references_hosts() -> Variant:
	for base in ["res://data/cards/pilot_cards.json", "res://data/new_cards/pilot_cards.json"]:
		var f = FileAccess.open(base, FileAccess.READ)
		if f == null:
			return "打不开 %s" % base
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed == null:
			return "%s JSON 解析失败" % base
		var by_id: Dictionary = {}
		for rec in parsed:
			by_id[String(rec.get("id", ""))] = rec
		var p062: Dictionary = by_id.get("pilot_062_洛尔恩", {})
		if not p062.get("effect_ids", []).has("cover_window_host"):
			return "%s：pilot_062 effect_ids 应含 cover_window_host" % base
		var p082: Dictionary = by_id.get("pilot_082_温斯顿", {})
		var p082_ids: Array = p082.get("effect_ids", [])
		if not p082_ids.has("cover_window_host"):
			return "%s：pilot_082 effect_ids 应含 cover_window_host" % base
		if not p082_ids.has("thrust_window_host"):
			return "%s：pilot_082 effect_ids 应含 thrust_window_host" % base
	return true
