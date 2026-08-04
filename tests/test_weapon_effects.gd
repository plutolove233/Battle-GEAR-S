extends RefCounted

## test_weapon_effects.gd - 武器装备牌效果（effect_093-139）验证
## 覆盖：47 effect 定义齐全 / JSON effect_ids 映射 / 派生值(040护甲×2、026每损伤-2) /
##       攻击触发自损(129) / 攻击次数衰减(112)。CHOOSE_ONE/聚能/直攻免牌等需实机弹窗的走 F3。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


func _ensure_equipment_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.equipment_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for pile in [gs.deck_state.equipment_deck, gs.deck_state.advanced_equipment_deck]:
		for i in range(pile.size()):
			var cid: StringName = pile[i]
			var c = gs.get_card(cid)
			if c and c.def and c.def.card_id == card_def_id:
				pile.remove_at(i)
				player.equipment_hand.append(cid)
				c.zone = &"equipment_hand"
				c.owner_player_id = &"player"
				return cid
	return &""


## 在任意位置（牌堆/商店/弃牌堆）找 card_def_id 并强制移入玩家装备手牌（测试用）。
## 用于商店开局已抽走目标 SR 武器的情形（_ensure_equipment_in_hand 搜不到）。
func _force_equipment_to_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var pl = gs.players.get(&"player")
	if pl == null:
		return &""
	for c_id: StringName in gs.cards:
		var c = gs.get_card(c_id)
		if c and c.def and String(c.def.card_id) == card_def_id:
			if pl.equipment_hand.has(c_id):
				return c_id
			gs.remove_card_from_all_zones(c_id)
			var shop = gs.shop_state
			if shop != null:
				shop.normal_slots.erase(c_id)
				if shop.advanced_slot == c_id:
					shop.advanced_slot = &""
				if shop.hidden_advanced_slot == c_id:
					shop.hidden_advanced_slot = &""
			pl.equipment_hand.append(c_id)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			return c_id
	return &""


func _equip_weapon(battle: BattleState, card_def_id: String) -> StringName:
	var cid: StringName = _ensure_equipment_in_hand(battle, card_def_id)
	if cid == &"":
		return &""
	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", cid, &"weapon_1")
	if not result.get("ok", false):
		return &""
	await _pump_frames(3)
	return cid


## 装备武器到指定槽位（weapon_1/weapon_2），用于双武器测试
func _equip_weapon_in_slot(battle: BattleState, card_def_id: String, slot: StringName) -> StringName:
	var cid: StringName = _ensure_equipment_in_hand(battle, card_def_id)
	if cid == &"":
		return &""
	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", cid, slot)
	if not result.get("ok", false):
		return &""
	await _pump_frames(3)
	return cid


func _ensure_attack_card_in_hand(battle: BattleState) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


func _clear_enemy_hand(battle: BattleState) -> void:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return
	for cid: StringName in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	enemy.action_hand.clear()


## 把指定行动牌塞入敌方手牌并注册 availability（用于构造敌方迎击响应）。
func _ensure_card_in_enemy_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return &""
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &"enemy"
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> void:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id == &"":
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			continue
		var dc = ar.get_action(dc_id)
		var amount: int = int(dc.record.get("value", 0))
		var mech_ids: Array = dc.record.get("mech_ids", [])
		if dts != null and amount > 0:
			for mech_id: StringName in mech_ids:
				dts.place_damage_tokens({"mech_id": mech_id, "count": amount})
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)


## 驱动盾牌 all_or_nothing 转移确认弹窗：确认转移全部(减伤后)损伤到盾牌槽。
## 返回 "" 成功；非空则错误信息。调用方需 await。
func _drive_shield_redirect_confirm(battle: BattleState, attack_id: StringName, to_slot: StringName) -> String:
	var ar = battle.context.action_registry
	var te = battle.context.timing_engine
	var attack = ar.get_action(attack_id)
	if attack == null:
		return "attack 不存在"
	for cid: StringName in attack.pending_effect_action_ids:
		var sub = ar.get_action(cid)
		if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_timing":
			var value: int = int(sub.record.get("value", 0))
			var absorb: int = int(sub.record.get("_ao_absorb", 0))
			var transfer: int = maxi(0, value - absorb)
			var mech_ids: Array = sub.record.get("mech_ids", [])
			var target_mech: StringName = StringName(mech_ids[0]) if not mech_ids.is_empty() else &""
			var plan: Array = []
			if transfer > 0:
				plan = [{"to_mech_id": target_mech, "to_slot_id": to_slot, "count": transfer}]
			te.resume_pending_effect(cid, {"redirect_plan": plan, "all_or_nothing_confirmed": true})
			await _pump_frames(3)
			return ""
	return "未找到盾牌转移弹窗（damage_change waiting_timing）"


## 驱动 effect 的 CHOOSE_ONE(optional) 弹窗：确认选 index 0（如 effect_115 相邻+2）。
## 返回 "" 成功；非空则错误信息。调用方需 await。
func _drive_choose_one_confirm(battle, attack_id: StringName) -> String:
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		return "应弹 choose_one_effect，实际 %s" % String(wait_info.get("input_type", &""))
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	return ""


## ① 47 个武器 effect 定义齐全（093-139）
func test_weapon_effects_defined() -> Variant:
	var effects: Dictionary = _GenEquipEffects.build_equipment_effects()
	for i in range(93, 140):
		var eid: StringName = StringName("equipment_effect_%03d" % i)
		if not effects.has(eid):
			return "缺少武器效果定义: %s" % String(eid)
	# 共用 effect_id 只定义一次：097/101/105/115/120/128/129/125/126 等
	if effects.size() < 47 + 92:  # 部件 001-092 + 武器 47（去重后）
		return "effect 定义总数异常: %d" % effects.size()
	return true


## ② JSON effect_ids 映射正确（weapon_001 -> 093,094；weapon_040 -> 138,139）
func test_weapon_json_effect_ids() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var cdb = battle.context.card_database
	var w1 = cdb.get_card("weapon_001_光束军刀")
	if w1 == null:
		return "找不到 weapon_001 定义"
	var eids1: Array = _GenEquipEffects.get_effects_for_card("weapon_001_光束军刀", battle.context)
	if eids1.size() != 2 or not eids1.has(&"equipment_effect_093") or not eids1.has(&"equipment_effect_094"):
		return "weapon_001 effect_ids 应=[093,094]，实际 %s" % str(eids1)
	var w40 = cdb.get_card("weapon_040_质能全转换剑炮")
	if w40 == null:
		return "找不到 weapon_040 定义"
	if int(w40.might) != 1 or int(w40.range_value) != 1:
		return "weapon_040 牌面应为 1/1，实际 %d/%d" % [int(w40.might), int(w40.range_value)]
	return true


## ③ 主动触发：weapon_040 effect_138 主动将威力变为护甲×2、范围变为动力（快照保留）
func test_weapon_040_energy_conversion() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_040_质能全转换剑炮")
	if cid == &"":
		return "装备 weapon_040 失败"
	var gs = battle.context.game_state
	var card = gs.get_card(cid)
	var pm = gs.get_mech_for_player(&"player")
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context
	# 未触发：牌面 1/1
	var stats0: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(stats0.get("might", -1)) != 1 or int(stats0.get("range_value", -1)) != 1:
		return "weapon_040 未触发时应为牌面1/1，实际 %d/%d" % [int(stats0.get("might", -1)), int(stats0.get("range_value", -1))]
	pm.power = 5
	var armor: int = pm.get_armor()
	var exp_might: int = maxi(0, armor * 2)
	# 主动触发 effect_138（快照当前护甲*2/动力写入 card.counters）
	var ef_result: Dictionary = battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_138",
		"player_id": &"player", "source_mech_id": pm.mech_id, "card_instance_id": cid, "phase": &"MAIN",
		"source": {"card_instance_id": cid, "mech_id": pm.mech_id, "player_id": &"player", "effect_id": &"equipment_effect_138"},
	})
	var ef_id: StringName = ef_result.get("action_id", &"") if ef_result is Dictionary else &""
	if ef_id == &"":
		return "effect_138 effect_fire 未发起"
	await _pump_frames(3)
	var stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(stats.get("might", -1)) != exp_might:
		return "weapon_040 触发后威力应=护甲%d×2=%d，实际 %d" % [armor, exp_might, int(stats.get("might", -1))]
	if int(stats.get("range_value", -1)) != 5:
		return "weapon_040 触发后范围应=当前动力5，实际 %d" % int(stats.get("range_value", -1))
	# 保留性：动力改变后快照不变（除非再次使用此效果）
	pm.power = 3
	var stats2: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(stats2.get("range_value", -1)) != 5:
		return "weapon_040 快照应保留，动力变3后范围仍=5（除非再次使用），实际 %d" % int(stats2.get("range_value", -1))
	return true


## ④ 派生值：weapon_026 每1损伤威力-2
func test_weapon_026_self_damage_penalty() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_026_大型光束炮")
	if cid == &"":
		return "装备 weapon_026 失败"
	var card = battle.context.game_state.get_card(cid)
	# 无损伤：威力=14
	var s0: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(s0.get("might", -1)) != 14:
		return "weapon_026 无损伤威力应=14，实际 %d" % int(s0.get("might", -1))
	# 2损伤：威力=14-4=10
	card.damage_tokens = 2
	var s2: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(s2.get("might", -1)) != 10:
		return "weapon_026 2损伤威力应=10（14-4），实际 %d" % int(s2.get("might", -1))
	return true


## ⑤ effect_129：weapon_032 攻击结算后自损1
func test_weapon_129_settle_self_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_032_投掷式飞弹")
	if cid == &"":
		return "装备 weapon_032 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100  # 防止击毁
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程4内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起: %s" % str(atk_result)
	# 诊断：effect_129 是否注册
	var has_e129 := false
	var pl9 = battle.context.timing_engine.permanent_listeners
	if pl9.has(&"ATTACK_SETTLE"):
		for entry in pl9[&"ATTACK_SETTLE"]:
			var e = entry.get("effect") if entry is Dictionary else null
			if e and e.effect_id == &"equipment_effect_129":
				has_e129 = true
	if not has_e129:
		return "effect_129 未注册到 ATTACK_SETTLE"
	await _pump_frames(5)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	var atk9 = battle.context.action_registry.get_action(attack_id)
	var atk9_state: String = String(atk9.state) if atk9 != null else "removed"
	var card = gs.get_card(cid)
	var wslot = pm.slots.get(&"weapon_1")
	var region_dt: int = int(wslot.region_damage_tokens) if wslot != null else -1
	# effect_129 在 ATTACK_SETTLE 自损1
	if int(card.damage_tokens) != 1:
		return "effect_129 应使 weapon_032 自损1，实际 card_dt=%d region_dt=%d atk_state=%s em_hp=%d" % [int(card.damage_tokens), region_dt, atk9_state, int(em.current_hp)]
	return true


## ⑥ effect_112：weapon_014 攻击结算后威力-4并标记 used
func test_weapon_112_attack_decay() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_014_等离子螺旋矛")
	if cid == &"":
		return "装备 weapon_014 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程4内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	var card = gs.get_card(cid)
	# effect_112：威力-4（24->20）+ weapon_used_this_turn 标记
	var stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(stats.get("might", -1)) != 20:
		return "effect_112 攻击后威力应=20（24-4），实际 %d" % int(stats.get("might", -1))
	if not bool(card.counters.get("weapon_used_this_turn", false)):
		return "effect_112 应标记 weapon_used_this_turn"
	return true


## ⑦ effect_125：weapon_029 攻击结算后设置冷却（下个我方回合结束前不能再攻击）
func test_weapon_125_cooldown() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_029_超米伽荣光炮")
	if cid == &"":
		return "装备 weapon_029 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程7内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	var card = gs.get_card(cid)
	# effect_125：攻击结算后 cooldown_active=true
	if not bool(card.counters.get("cooldown_active", false)):
		return "effect_125 应设置武器冷却（cooldown_active=true）"
	# 冷却中 cooldown_until_turn 应>当前 turn_number（下个我方回合结束后才解除）
	if int(card.cooldown_until_turn) <= int(gs.turn_number):
		return "cooldown_until_turn 应>当前 turn_number"
	return true


## ⑧ effect_128：weapon_032 直攻免牌（DIRECT effect_fire -> EXECUTE_ATTACK cardless）
func test_weapon_128_cardless_attack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_032_投掷式飞弹")
	if cid == &"":
		return "装备 weapon_032 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程4内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	# 确保主阶段 + 本方回合（DIRECT effect_128 前置）
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	pm.attack_count_this_turn = 0  # 确保有攻击次数
	var used_before: int = int(pm.attack_count_this_turn)
	# 触发 DIRECT effect_fire（模拟装备面板"发动"按钮）
	var ef_result: Dictionary = battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_128",
		"player_id": &"player",
		"source_mech_id": pm.mech_id,
		"card_instance_id": cid,
		"phase": &"MAIN",
		"source": {"card_instance_id": cid, "mech_id": pm.mech_id, "player_id": &"player", "effect_id": &"equipment_effect_128"},
	})
	var ef_id: StringName = ef_result.get("action_id", &"") if ef_result is Dictionary else &""
	if ef_id == &"":
		return "effect_fire 未发起"
	await _pump_frames(5)
	var ef_action = battle.context.action_registry.get_action(ef_id)
	var ef_state: String = String(ef_action.state) if ef_action != null else "removed"
	# 找 attack 子动作（cardless 直攻创建的 attack，waiting_input 选目标）。effect_fire 可能已
	# 完成清理，故从 registry 全局查 type=attack 且 state=waiting_input 的最新动作。
	var attack_id: StringName = &""
	for a in battle.context.action_registry.get_actions_by_type(&"attack"):
		if a.state == &"waiting_input":
			attack_id = a.action_id
			break
	if attack_id == &"":
		return "cardless 直攻未创建 attack 子动作（ef_state=%s）" % ef_state
	# 驱动选目标（choose_new_target -> select_attack_target）
	battle.context.action_engine.continue_action(attack_id, {"target_id": em.mech_id})
	await _pump_frames(5)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	# 攻击次数应 +1（cardless consume_turn_attack_count）
	if int(pm.attack_count_this_turn) != used_before + 1:
		return "cardless 直攻应消耗1次攻击次数，实际 used %d->%d" % [used_before, int(pm.attack_count_this_turn)]
	# effect_129 自损1
	var card = gs.get_card(cid)
	if int(card.damage_tokens) != 1:
		return "effect_129 应使 weapon_032 自损1，实际 %d" % int(card.damage_tokens)
	return true


## ⑨ effect_097：weapon_003 命中后 CHOOSE_ONE 额外+2损伤标记
func test_weapon_097_hit_extra_markers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_003_破甲狼爪")
	if cid == &"":
		return "装备 weapon_003 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程1内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# effect_097 在 ATTACK_AFTER 弹 CHOOSE_ONE（optional），驱动选"额外设置2损伤"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		# 可能已自动进入 damage placement（CHOOSE_ONE 未挂起）；检查 extra_markers
		var atk_c = battle.context.action_registry.get_action(attack_id)
		var em_pre: int = int(atk_c.record.get("extra_markers", 0)) if atk_c != null else -1
		_drive_damage_placement(battle, attack_id)
		await _pump_frames(3)
		return "effect_097 未弹 choose_one_effect（wait=%s）extra_markers=%d" % [String(wait_info.get("input_type", &"")), em_pre]
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# extra_markers 应=2
	var atk2 = battle.context.action_registry.get_action(attack_id)
	if atk2 != null and int(atk2.record.get("extra_markers", 0)) != 2:
		return "effect_097 应使 extra_markers=2，实际 %d" % int(atk2.record.get("extra_markers", 0))
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ⑩b effect_115：weapon_018 光束霰弹枪 命中且目标相邻时额外2损伤（诊断）
func test_weapon_115_adjacent_extra() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_018_光束霰弹枪")
	if cid == &"":
		return "装备 weapon_018 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程3内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# effect_115 弹 CHOOSE_ONE（optional「可」）：相邻命中后玩家选「相邻：额外设置2损伤」
	var coe_b: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe_b != "":
		return "effect_115 相邻应弹 CHOOSE_ONE: %s" % coe_b
	var atk2 = battle.context.action_registry.get_action(attack_id)
	var em_val: int = int(atk2.record.get("extra_markers", 0)) if atk2 != null else -1
	if em_val != 2:
		return "effect_115 确认后应 extra_markers=2，实际 %d" % em_val
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ⑩b2 effect_115：用 odd-q 相邻但 axial 公式会误判的距离对（验证用 _HexGrid.distance 而非 axial）
## (4,4) 与 (5,2)：odd-q 距离1（相邻），但旧 axial 公式算=2（会漏触发）
func test_weapon_115_adjacent_oddq_distance() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_018_光束霰弹枪")
	if cid == &"":
		return "装备 weapon_018 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 4, "r": 4}
	em.position = {"q": 5, "r": 2}  # odd-q 距离1（相邻），axial 公式误算为2
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	# 先确认 odd-q 距离=1（相邻）
	if _HexGrid.distance(pm.position, em.position) != 1:
		return "测试前提：odd-q 距离应=1，实际 %d" % _HexGrid.distance(pm.position, em.position)
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起（目标可能在地图外/不可达，检查地形）"
	await _pump_frames(5)
	var coe_b2: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe_b2 != "":
		return "effect_115 odd-q相邻应弹 CHOOSE_ONE: %s" % coe_b2
	var atk2 = battle.context.action_registry.get_action(attack_id)
	var em_val: int = int(atk2.record.get("extra_markers", 0)) if atk2 != null else -1
	if em_val != 2:
		return "effect_115 odd-q相邻确认后应 extra_markers=2，实际 %d（若=0 说明用了错误 axial 公式）" % em_val
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ⑩c effect_115：目标不相邻时不触发（距离2）
func test_weapon_115_nonadjacent_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_018_光束霰弹枪")
	if cid == &"":
		return "装备 weapon_018 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 4, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离2，在射程3内但不相邻
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# 不相邻时 effect_115 不触发：extra_markers 应=0
	var atk_n = battle.context.action_registry.get_action(attack_id)
	var em_n: int = int(atk_n.record.get("extra_markers", 0)) if atk_n != null else -1
	if em_n != 0:
		return "effect_115 距离2不应加 extra_markers，实际 %d" % em_n
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ⑩d effect_115：use_action_card 完整流程 + 响应窗口（敌方有迎击牌并跳过），验证相邻+2 弹窗仍出现
func test_weapon_115_via_use_card_with_response_window() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_018_光束霰弹枪")
	if cid == &"":
		return "装备 weapon_018 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1=相邻，在射程3内
	# 敌方设为人类，使响应窗口不被 AI 自动处理（便于手动跳过）
	var enemy_pl = gs.players.get(&"enemy")
	if enemy_pl != null:
		enemy_pl.is_human = true
	battle.context.action_ui_bridge.context = battle.context
	# 清空双方手牌避免推进/迎击等干扰，再各自注入所需牌
	var pl = gs.players.get(&"player")
	if pl != null:
		for pcid: StringName in pl.action_hand.duplicate():
			battle.context.timing_engine.unregister_listeners_for_card(pcid)
		pl.action_hand.clear()
	for ecid: StringName in enemy_pl.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(ecid)
	enemy_pl.action_hand.clear()
	# 给敌方1张迎击牌并注册，使 ATTACK_AT 响应窗口打开
	var yj_cid: StringName = _ensure_counter_card_for_enemy(battle)
	if yj_cid == &"":
		return "敌方无迎击牌可注入"
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	# 走 use_action_card 完整流程（模拟实机）
	battle.execute_use_action_card(&"player", atk_card)
	await _pump_frames(3)
	var attack_a = null
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a = a
			break
	if attack_a == null:
		return "attack 未创建"
	# 选武器
	battle.context.action_engine.continue_action(attack_a.action_id, {"weapon_id": cid})
	await _pump_frames(3)
	# 选目标
	var wait_t: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_t.get("input_type", &"")) == &"select_attack_target":
		battle.context.action_engine.continue_action(attack_a.action_id, {"target_id": em.mech_id})
		await _pump_frames(3)
	# 响应窗口应打开
	var wait_r: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_r.get("input_type", &"")) != &"respond_attack":
		_drive_damage_placement(battle, attack_a.action_id)
		return "应暂停在 respond_attack（敌方有迎击牌），实际: %s" % String(wait_r.get("input_type", &""))
	# 跳过响应
	var empty_sel: Array[Dictionary] = []
	battle.context.timing_engine.handle_response_selection(attack_a.action_id, empty_sel)
	await _pump_frames(3)
	# effect_115 弹 CHOOSE_ONE（optional「可」）：响应窗口跳过后相邻命中，玩家确认额外+2
	var coe_d: String = await _drive_choose_one_confirm(battle, attack_a.action_id)
	if coe_d != "":
		var atk_diag = battle.context.action_registry.get_action(attack_a.action_id)
		var hit_v: bool = bool(atk_diag.record.get("hit", false)) if atk_diag != null else false
		_drive_damage_placement(battle, attack_a.action_id)
		return "响应窗口跳过后 effect_115 相邻应弹 CHOOSE_ONE: %s hit=%s" % [coe_d, str(hit_v)]
	var atk2 = battle.context.action_registry.get_action(attack_a.action_id)
	if atk2 != null and int(atk2.record.get("extra_markers", 0)) != 2:
		_drive_damage_placement(battle, attack_a.action_id)
		return "effect_115 确认后应 extra_markers=2，实际 %d" % int(atk2.record.get("extra_markers", 0))
	_drive_damage_placement(battle, attack_a.action_id)
	await _pump_frames(3)
	return true


## 给敌方注入1张迎击牌（从牌堆/弃牌堆找），注册为可用性监听器，返回实例id
func _ensure_counter_card_for_enemy(battle) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return &""
	var piles = [gs.deck_state.action_deck, gs.deck_state.action_discard_pile]
	for pile in piles:
		for i in range(pile.size()):
			var cid: StringName = pile[i]
			var c = gs.get_card(cid)
			if c and c.def and c.def.action_type == &"迎击":
				pile.remove_at(i)
				enemy.action_hand.append(cid)
				c.zone = &"action_hand"
				c.owner_player_id = &"enemy"
				if battle.context.has_method("register_hand_card_availability"):
					battle.context.register_hand_card_availability(cid)
				return cid
	return &""


## ⑩ effect_093：weapon_001 聚能后本回合范围+1（聚能联动 ENERGY_TARGET_IS_SELF）
func test_weapon_093_energy_range_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_001_光束军刀")
	if cid == &"":
		return "装备 weapon_001 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context
	# 聚能前范围=2
	var card = gs.get_card(cid)
	var range_before: int = int(_GenEquipEffects.get_effective_weapon_stats(card).get("range_value", 0))
	if range_before != 2:
		return "weapon_001 初始范围应=2，实际 %d" % range_before
	# 触发聚能：打出 action_014_聚能 行动牌（use_action_card -> energy_direct -> CHOOSE_OWN_WEAPON）
	var energy_card: StringName = &""
	for c in gs.deck_state.action_deck.duplicate():
		var cc = gs.get_card(c)
		if cc and cc.def and cc.def.card_id == "action_014_聚能":
			energy_card = c
			gs.deck_state.action_deck.erase(c)
			gs.players.get(&"player").action_hand.append(c)
			cc.zone = &"action_hand"
			break
	if energy_card == &"":
		for c in gs.players.get(&"player").action_hand:
			var cc = gs.get_card(c)
			if cc and cc.def and cc.def.card_id == "action_014_聚能":
				energy_card = c
				break
	if energy_card == &"":
		return "找不到 action_014_聚能 牌"
	var uc_result: Dictionary = battle.context.action_service.execute(&"use_action_card", {
		"card_instance_id": energy_card, "player_id": &"player", "mech_id": pm.mech_id,
	})
	var ef_id: StringName = uc_result.get("action_id", &"") if uc_result is Dictionary else &""
	if ef_id == &"":
		return "聚能 use_action_card 未发起"
	await _pump_frames(5)
	# effect_fire 应等待选武器（select_weapon_for_charge）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"select_weapon_for_charge":
		return "聚能应弹 select_weapon_for_charge，实际 %s" % String(wait_info.get("input_type", &""))
	# 选 weapon_001 聚能
	battle.context.timing_engine.resume_pending_effect(ef_id, {"selected_weapon_id": cid})
	await _pump_frames(5)
	# 诊断：energy_target 是否写入 + range_modifiers
	var uc_a = battle.context.action_registry.get_action(ef_id)
	var energy_tgt: String = String(uc_a.record.get("energy_target_weapon_instance_id", &"")) if uc_a != null else "removed"
	var range_mods: Array = card.range_modifiers if "range_modifiers" in card else []
	# effect_093：范围+2（2->4）
	var range_after: int = int(_GenEquipEffects.get_effective_weapon_stats(card).get("range_value", 0))
	if range_after != 4:
		return "effect_093 聚能后范围应=4（2+2），实际 %d energy_tgt=%s range_mods=%s" % [range_after, energy_tgt, str(range_mods)]
	return true


## 触发聚能并选指定武器（从手牌/牌堆/弃牌堆找 action_014_聚能）。返回是否成功。
func _trigger_energy_charge_on(battle: BattleState, weapon_cid: StringName) -> bool:
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context
	var energy_card: StringName = &""
	for c in gs.players.get(&"player").action_hand:
		var cc = gs.get_card(c)
		if cc and cc.def and cc.def.card_id == "action_014_聚能":
			energy_card = c
			break
	if energy_card == &"":
		for c in gs.deck_state.action_deck.duplicate():
			var cc = gs.get_card(c)
			if cc and cc.def and cc.def.card_id == "action_014_聚能":
				gs.deck_state.action_deck.erase(c)
				gs.players.get(&"player").action_hand.append(c)
				cc.zone = &"action_hand"
				energy_card = c
				break
	if energy_card == &"":
		for c in gs.deck_state.action_discard_pile.duplicate():
			var cc = gs.get_card(c)
			if cc and cc.def and cc.def.card_id == "action_014_聚能":
				gs.deck_state.action_discard_pile.erase(c)
				gs.players.get(&"player").action_hand.append(c)
				cc.zone = &"action_hand"
				energy_card = c
				break
	if energy_card == &"":
		return false
	var uc_result: Dictionary = battle.context.action_service.execute(&"use_action_card", {
		"card_instance_id": energy_card, "player_id": &"player", "mech_id": pm.mech_id,
	})
	var ef_id: StringName = uc_result.get("action_id", &"") if uc_result is Dictionary else &""
	if ef_id == &"":
		return false
	await _pump_frames(5)
	battle.context.timing_engine.resume_pending_effect(ef_id, {"selected_weapon_id": weapon_cid})
	await _pump_frames(5)
	return true


## ⑩b effect_093 不可叠加：同回合多次聚能只加一次范围+2
func test_weapon_093_energy_range_no_stack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_001_光束军刀")
	if cid == &"":
		return "装备 weapon_001 失败"
	var gs = battle.context.game_state
	var card = gs.get_card(cid)
	# 第一次聚能：范围 2->4
	if not await _trigger_energy_charge_on(battle, cid):
		return "第一次聚能触发失败"
	var range1: int = int(_GenEquipEffects.get_effective_weapon_stats(card).get("range_value", 0))
	if range1 != 4:
		return "第一次聚能后范围应=4（2+2），实际 %d" % range1
	# 第二次聚能（同回合同武器）：不可叠加，范围应仍=4（不是6）
	if not await _trigger_energy_charge_on(battle, cid):
		return "第二次聚能触发失败"
	var range2: int = int(_GenEquipEffects.get_effective_weapon_stats(card).get("range_value", 0))
	if range2 != 4:
		return "第二次聚能后范围应仍=4（不可叠加），实际 %d" % range2
	# 聚能状态本身可叠加（stacks=2，攻击时威力+8），但 effect_093 范围加成不叠加
	var stacks := 0
	for s: Dictionary in gs.get_mech_for_player(&"player").statuses:
		if s.get("type", &"") == &"ENERGY_CHARGE" and s.get("weapon_id", &"") == cid:
			stacks = int(s.get("stacks", 1))
			break
	if stacks != 2:
		return "聚能状态应叠加 stacks=2，实际 %d" % stacks
	return true


## ⑩c effect_093 修正回合末清除：聚能后结束持有者回合 -> 范围加成消失（THIS_OWNER_TURN 原永续bug）
func test_weapon_093_modifier_clears_on_turn_end() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_001_光束军刀")
	if cid == &"":
		return "装备 weapon_001 失败"
	var gs = battle.context.game_state
	var card = gs.get_card(cid)
	if not await _trigger_energy_charge_on(battle, cid):
		return "聚能触发失败"
	var range1: int = int(_GenEquipEffects.get_effective_weapon_stats(card).get("range_value", 0))
	if range1 != 4:
		return "聚能后范围应=4（2+2），实际 %d" % range1
	# 结束玩家回合 -> THIS_OWNER_TURN 修正应清除（原 bug：永续不清）
	gs.active_player_id = &"player"
	battle.context.turn_service.end_turn(&"player")
	await _pump_frames(3)
	var range2: int = int(_GenEquipEffects.get_effective_weapon_stats(card).get("range_value", 0))
	if range2 != 2:
		return "回合末范围加成应清除恢复2，实际 %d（THIS_OWNER_TURN 未清）" % range2
	return true


## ⑪ effect_104：weapon_010 拘束钩爪命中后施加锁定（CHOOSE_ONE -> SET_WEAPON_LOCK）
func test_weapon_104_lock_target() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_010_拘束钩爪")
	if cid == &"":
		return "装备 weapon_010 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程5内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# effect_104 在 ATTACK_AFTER 弹 CHOOSE_ONE（施加锁定），驱动选"施加锁定"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		_drive_damage_placement(battle, attack_id)
		return "effect_104 未弹 choose_one_effect（wait=%s）" % String(wait_info.get("input_type", &""))
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# weapon_010.lock_target_mech_id 应=enemy
	var card = gs.get_card(cid)
	var lock_tgt: StringName = card.lock_target_mech_id if "lock_target_mech_id" in card else &""
	if String(lock_tgt) != String(em.mech_id):
		return "effect_104 应锁定目标 %s，实际 %s" % [String(em.mech_id), String(lock_tgt)]
	# 目标应有 LOCKED 状态（source_card_id=本武器，source_player_id=持有者），即真实锁定生效
	var has_lock_status := false
	for s in em.statuses:
		if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == String(cid):
			has_lock_status = true
	if not has_lock_status:
		return "effect_104 应在目标身上施加 LOCKED 状态（source_card_id=本牌）"
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ⑪b effect_104：持有者下次命中被锁目标后，锁定解除（lock_status_clear_on_hit）
func test_weapon_104_lock_clears_on_holder_hit() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var hook_cid: StringName = await _equip_weapon(battle, "weapon_010_拘束钩爪")
	if hook_cid == &"":
		return "装备 weapon_010 失败"
	# 第二把武器：光束军刀（effect_093 仅监听 EFFECT_FIRE_AFTER，攻击时不弹 CHOOSE_ONE），设到 weapon_2
	var saber_cid: StringName = await _equip_weapon_in_slot(battle, "weapon_001_光束军刀", &"weapon_2")
	if saber_cid == &"":
		return "装备 weapon_001 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 1000
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，两把武器都在射程内
	pm.max_attacks_per_turn = 2
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	# 攻击1：拘束钩爪命中并施加锁定
	var atk1: StringName = _ensure_attack_card_in_hand(battle)
	if atk1 == &"":
		return "无攻击牌1"
	var r1: Dictionary = battle.execute_attack_action(&"player", &"enemy", hook_cid, atk1)
	var aid1: StringName = r1.get("action_id", &"") if r1 is Dictionary else &""
	if aid1 == &"":
		return "攻击1未发起"
	await _pump_frames(5)
	if String(battle.context.action_ui_bridge.get_waiting_action_info().get("input_type", &"")) != &"choose_one_effect":
		_drive_damage_placement(battle, aid1)
		return "effect_104 攻击1应弹 choose_one_effect"
	battle.context.timing_engine.resume_pending_effect(aid1, {"chosen_option_index": 0})
	await _pump_frames(3)
	_drive_damage_placement(battle, aid1)
	await _pump_frames(3)
	var hook_card = gs.get_card(hook_cid)
	var has_lock1 := false
	for s in em.statuses:
		if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == String(hook_cid):
			has_lock1 = true
	if not has_lock1:
		return "攻击1后目标应有 LOCKED 状态"
	# 攻击2：光束军刀命中同一目标 -> 锁定解除
	var atk2: StringName = _ensure_attack_card_in_hand(battle)
	if atk2 == &"":
		return "无攻击牌2"
	var r2: Dictionary = battle.execute_attack_action(&"player", &"enemy", saber_cid, atk2)
	var aid2: StringName = r2.get("action_id", &"") if r2 is Dictionary else &""
	if aid2 == &"":
		return "攻击2未发起"
	await _pump_frames(5)
	_drive_damage_placement(battle, aid2)
	await _pump_frames(3)
	# 验证锁定已解除（状态移除 + 缓存清空）
	var still_locked := false
	for s in em.statuses:
		if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == String(hook_cid):
			still_locked = true
	if still_locked:
		return "持有者命中后锁定应解除"
	var lock_tgt_after: StringName = hook_card.lock_target_mech_id if "lock_target_mech_id" in hook_card else &""
	if lock_tgt_after != &"":
		return "锁定解除后 lock_target_mech_id 应清空，实际 %s" % String(lock_tgt_after)
	return true


## ⑪c effect_104：本牌弃置（离开机甲区域）时，其施加的锁定解除
func test_weapon_104_lock_clears_on_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var hook_cid: StringName = await _equip_weapon(battle, "weapon_010_拘束钩爪")
	if hook_cid == &"":
		return "装备 weapon_010 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 1000
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", hook_cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	if String(battle.context.action_ui_bridge.get_waiting_action_info().get("input_type", &"")) == &"choose_one_effect":
		battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
		await _pump_frames(3)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	# 验证锁定已施加
	var has_lock := false
	for s in em.statuses:
		if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == String(hook_cid):
			has_lock = true
	if not has_lock:
		return "应先施加 LOCKED 状态"
	# 弃置拘束钩爪（离开机甲区域）
	battle.context.deck_service.discard_card(hook_cid, &"test_discard")
	await _pump_frames(5)
	# 验证锁定已解除
	var still_locked := false
	for s in em.statuses:
		if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == String(hook_cid):
			still_locked = true
	if still_locked:
		return "本牌弃置后锁定应解除"
	return true


## ⑬b effect_126：对冷却中的超米伽荣光炮使用聚能后清除冷却（可再次攻击）
func test_weapon_126_charge_clears_cooldown() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_029_超米伽荣光炮")
	if cid == &"":
		return "装备 weapon_029 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 1000
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程7内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	# 攻击 -> effect_125 设冷却
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(5)
	var card = gs.get_card(cid)
	if not bool(card.counters.get("cooldown_active", false)):
		return "effect_125 攻击后应设冷却"
	# 对冷却武器使用聚能 -> effect_126 清除冷却
	var charge_ok: bool = await _trigger_energy_charge_on(battle, cid)
	if not charge_ok:
		return "聚能触发失败"
	await _pump_frames(5)
	if bool(card.counters.get("cooldown_active", false)):
		return "effect_126 聚能后应清除冷却，仍 cooldown_active=true"
	return true


## ⑫ effect_098：weapon_004 流星钢锤主阶段切形态（DIRECT effect_fire + CHOOSE_ONE + SET_WEAPON_MODE）
func test_weapon_098_mode_switch() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_004_流星钢锤")
	if cid == &"":
		return "装备 weapon_004 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context
	var card = gs.get_card(cid)
	# 初始 normal：威力18范围1
	var s0: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(s0.get("might", -1)) != 18 or int(s0.get("range_value", -1)) != 1:
		return "weapon_004 normal 应 18/1，实际 %d/%d" % [int(s0.get("might", -1)), int(s0.get("range_value", -1))]
	# 触发 DIRECT effect_098（主阶段切形态）
	var ef_result: Dictionary = battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_098",
		"player_id": &"player", "source_mech_id": pm.mech_id, "card_instance_id": cid, "phase": &"MAIN",
		"source": {"card_instance_id": cid, "mech_id": pm.mech_id, "player_id": &"player", "effect_id": &"equipment_effect_098"},
	})
	var ef_id: StringName = ef_result.get("action_id", &"") if ef_result is Dictionary else &""
	if ef_id == &"":
		return "effect_098 effect_fire 未发起"
	await _pump_frames(5)
	# 诊断：effect_098 注册 + effect_fire 状态
	var has_e98 := false
	var e98_eff = null
	var e98_bind: Dictionary = {}
	for tl in battle.context.timing_engine.permanent_listeners:
		for entry in battle.context.timing_engine.permanent_listeners[tl]:
			var e = entry.get("effect") if entry is Dictionary else null
			if e and e.effect_id == &"equipment_effect_098":
				has_e98 = true
				e98_eff = e
				e98_bind = entry.get("binding_context", {}) if entry is Dictionary else {}
	var can_trig98: bool = battle.context.timing_engine.can_trigger_active_effect(e98_eff, e98_bind) if e98_eff != null else false
	var ef_a98 = battle.context.action_registry.get_action(ef_id)
	# CHOOSE_ONE 选"威力-5范围+2"（option 0 = extended）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		return "effect_098 应弹 choose_one_effect，实际 %s registered=%s can_trig=%s ef_state=%s" % [String(wait_info.get("input_type", &"")), str(has_e98), str(can_trig98), String(ef_a98.state) if ef_a98 != null else "removed"]
	battle.context.timing_engine.resume_pending_effect(ef_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# extended：威力13范围3
	if String(card.weapon_mode) != "extended":
		return "weapon_004 应切到 extended，实际 %s" % String(card.weapon_mode)
	var s1: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	if int(s1.get("might", -1)) != 13 or int(s1.get("range_value", -1)) != 3:
		return "weapon_004 extended 应 13/3，实际 %d/%d" % [int(s1.get("might", -1)), int(s1.get("range_value", -1))]
	return true


## ⑬ effect_122：weapon_027 热能加特林命中后自损2+额外3损伤标记（CHOOSE_ONE 组合动作）
func test_weapon_122_self_damage_extra_markers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_027_热能加特林")
	if cid == &"":
		return "装备 weapon_027 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程5内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# effect_122 在 ATTACK_AFTER 弹 CHOOSE_ONE（自损2+3 markers）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		_drive_damage_placement(battle, attack_id)
		return "effect_122 未弹 choose_one_effect（wait=%s）" % String(wait_info.get("input_type", &""))
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# weapon_027 自损2 + extra_markers=3
	var card = gs.get_card(cid)
	if int(card.damage_tokens) != 2:
		return "effect_122 应使 weapon_027 自损2，实际 %d" % int(card.damage_tokens)
	var atk2 = battle.context.action_registry.get_action(attack_id)
	if atk2 != null and int(atk2.record.get("extra_markers", 0)) != 3:
		return "effect_122 应使 extra_markers=3，实际 %d" % int(atk2.record.get("extra_markers", 0))
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ⑭ effect_115：weapon_018 光束霰弹枪命中相邻目标+2损伤（TARGET_IS_ADJACENT 条件）
func test_weapon_115_adjacent_extra_markers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_018_光束霰弹枪")
	if cid == &"":
		return "装备 weapon_018 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1=相邻，在射程3内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# effect_115 弹 CHOOSE_ONE（optional「可」）：相邻命中后玩家确认额外+2
	var coe_14: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe_14 != "":
		return "effect_115 相邻应弹 CHOOSE_ONE: %s" % coe_14
	var atk2 = battle.context.action_registry.get_action(attack_id)
	if atk2 != null and int(atk2.record.get("extra_markers", 0)) != 2:
		return "effect_115 确认后应 extra_markers=2，实际 %d" % int(atk2.record.get("extra_markers", 0))
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ⑮ effect_127：weapon_031 合金盾牌将攻击损伤全转移到自身（enemy 攻击 player）
func test_weapon_127_shield_redirect() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_031_合金盾牌")
	if cid == &"":
		return "装备 weapon_031 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	pm.current_hp = 100
	em.current_hp = 100
	# enemy 攻击 player（相邻）
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	# 清 player 手牌（避免 player 迎击）
	var pl = gs.players.get(&"player")
	if pl != null:
		for c in pl.action_hand.duplicate():
			battle.context.timing_engine.unregister_listeners_for_card(c)
		pl.action_hand.clear()
	battle.context.action_ui_bridge.context = battle.context
	# enemy 武器 + 攻击牌
	var enemy_weapons: Array = em.get_weapon_ids()
	if enemy_weapons.is_empty():
		return "enemy 无武器"
	var enemy_weapon: StringName = enemy_weapons[0]
	var ep = gs.players.get(&"enemy")
	if ep == null:
		return "enemy 玩家不存在"
	var enemy_atk: StringName = &""
	for c in ep.action_hand:
		var cc = gs.get_card(c)
		if cc and cc.def and cc.def.action_type == &"攻击":
			enemy_atk = c
			break
	if enemy_atk == &"":
		for c in gs.deck_state.action_deck:
			var cc = gs.get_card(c)
			if cc and cc.def and cc.def.action_type == &"攻击":
				enemy_atk = c
				gs.deck_state.action_deck.erase(c)
				ep.action_hand.append(c)
				cc.zone = &"action_hand"
				break
	if enemy_atk == &"":
		return "enemy 无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", enemy_weapon, enemy_atk)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "enemy 攻击未发起"
	await _pump_frames(5)
	# 盾牌 all_or_nothing 转移弹窗（人类玩家可选）：确认转移全部损伤到 weapon_1 槽
	var redirect_err: String = await _drive_shield_redirect_confirm(battle, attack_id, &"weapon_1")
	if redirect_err != "":
		return redirect_err
	# 驱动剩余损伤放置（合金盾牌 reduction=0，全转移后无剩余）
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	# 盾牌槽（weapon_1）应有损伤
	var shield_slot = pm.slots.get(&"weapon_1")
	if shield_slot == null:
		return "weapon_1 槽不存在"
	var shield_region: int = int(shield_slot.region_damage_tokens)
	if shield_region <= 0:
		return "effect_127 应将损伤转移到盾牌槽，weapon_1 region_damage=%d" % shield_region
	return true


## effect_136：weapon_038 太空合金盾牌 攻击后时点(ATTACK_AFTER)转移损伤(-1)并使造成的伤害-2
## 损伤和伤害不分离：同一弹窗确认即同时转移损伤(-1)与减HP伤害(-2)。
func test_weapon_136_shield_redirect_and_hp_reduction() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_038_月神合金盾牌")
	if cid == &"":
		return "装备 weapon_038 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	pm.current_hp = 100
	em.current_hp = 100
	var armor_before: int = int(pm.get_armor())
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	# 清 player 手牌（避免 player 迎击）
	var pl = gs.players.get(&"player")
	if pl != null:
		for c in pl.action_hand.duplicate():
			battle.context.timing_engine.unregister_listeners_for_card(c)
		pl.action_hand.clear()
	battle.context.action_ui_bridge.context = battle.context
	# enemy 武器 + 攻击牌；确保威力>=10（markers>=2，便于见 -1）
	var enemy_weapons: Array = em.get_weapon_ids()
	if enemy_weapons.is_empty():
		return "enemy 无武器"
	var enemy_weapon: StringName = enemy_weapons[0]
	if not em.base_weapons.is_empty():
		em.base_weapons[0]["might"] = 12
	var ep = gs.players.get(&"enemy")
	if ep == null:
		return "enemy 玩家不存在"
	var enemy_atk: StringName = &""
	for c in ep.action_hand:
		var cc = gs.get_card(c)
		if cc and cc.def and cc.def.action_type == &"攻击":
			enemy_atk = c
			break
	if enemy_atk == &"":
		for c in gs.deck_state.action_deck:
			var cc = gs.get_card(c)
			if cc and cc.def and cc.def.action_type == &"攻击":
				enemy_atk = c
				gs.deck_state.action_deck.erase(c)
				ep.action_hand.append(c)
				cc.zone = &"action_hand"
				break
	if enemy_atk == &"":
		return "enemy 无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", enemy_weapon, enemy_atk)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "enemy 攻击未发起"
	await _pump_frames(5)
	# 盾牌 ATTACK_AFTER 转移弹窗（attack waiting_timing）：确认转移全部(损伤-1)并使伤害-2
	var ar = battle.context.action_registry
	var te = battle.context.timing_engine
	var attack = ar.get_action(attack_id)
	if attack == null:
		return "attack 不存在"
	if attack.state != &"waiting_timing":
		return "attack 未 waiting_timing（盾牌 ATTACK_AFTER 转移窗未弹）state=%s" % String(attack.state)
	var markers: int = int(attack.record.get("markers", 0))
	var absorb: int = int(attack.record.get("_ao_absorb", 0))
	var transfer: int = maxi(0, markers - absorb)
	var target_mech: StringName = attack.record.get("target_id", &"")
	var plan: Array = []
	if transfer > 0:
		plan = [{"to_mech_id": target_mech, "to_slot_id": &"weapon_1", "count": transfer}]
	te.resume_pending_effect(attack_id, {"redirect_plan": plan, "all_or_nothing_confirmed": true})
	await _pump_frames(3)
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	# 盾牌槽应有损伤（转移 markers-1，markers=floor(12/5)=2 -> 转1点）
	var shield_slot = pm.slots.get(&"weapon_1")
	if shield_slot == null or int(shield_slot.region_damage_tokens) <= 0:
		return "effect_136 应将损伤转移到盾牌槽"
	# HP伤害减2：base=max(0,12-armor)，reduced=max(0,base-2)，HP=100-reduced
	var base_dmg: int = maxi(0, 12 - armor_before)
	var expected_hp: int = 100 - maxi(0, base_dmg - 2)
	if int(pm.current_hp) != expected_hp:
		return "HP应=100-(伤害-2)=%d（base=%d armor=%d），实际 %d" % [expected_hp, base_dmg, armor_before, int(pm.current_hp)]
	return true


## effect_124：weapon_028 雷爆磁轨炮 随机弃牌为最后一张时 +3 威力（被动，无弹窗）
## 打出攻击牌后手牌恰剩1张 -> ATTACK_BEFORE 随机弃该牌 -> effect_124 ATTACK_BEFORE 写 extra_might+3
func test_weapon_124_plus3_last_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	# weapon_028 为 SR，开局常被商店抽走，用 _force_equipment_to_hand 从任意位置取回
	var cid: StringName = _force_equipment_to_hand(battle, "weapon_028_雷爆磁轨炮")
	if cid == &"":
		return "找不到 weapon_028"
	var eq_result: Dictionary = battle.context.card_set_service.set_equipment(&"player", cid, &"weapon_1")
	if not eq_result.get("ok", false):
		return "装备 weapon_028 失败: %s" % String(eq_result.get("message", ""))
	await _pump_frames(3)
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程6内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	# 玩家手牌设为：1张攻击牌 + 1张非攻击牌
	var pl = gs.players.get(&"player")
	if pl == null:
		return "player 不存在"
	for c in pl.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(c)
	pl.action_hand.clear()
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var other_card: StringName = &""
	for i in range(gs.deck_state.action_deck.size()):
		var dc: StringName = gs.deck_state.action_deck[i]
		var cc = gs.get_card(dc)
		if cc and cc.def and cc.def.action_type != &"攻击":
			gs.deck_state.action_deck.remove_at(i)
			pl.action_hand.append(dc)
			cc.zone = &"action_hand"
			cc.owner_player_id = &"player"
			other_card = dc
			break
	if other_card == &"":
		return "无非攻击牌可用"
	# 真实流程：打出攻击牌经 use_action_card 移入临时区，再发起 attack 子动作。
	# 测试直起 attack 动作，故手动把攻击牌移入 temp_zone，使 ATTACK_BEFORE 时手牌仅剩 other（最后一张）。
	var atk_card_obj = gs.get_card(atk_card)
	if atk_card_obj != null:
		pl.action_hand.erase(atk_card)
		atk_card_obj.zone = &"temp_zone"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# 攻击应已过 ATTACK_BEFORE：effect_123 随机弃置 other（最后一张），effect_124 写 extra_might+3。
	# 此时攻击停在损伤放置（或响应窗口已自动关闭），extra_might 已写入。
	var atk_mid = battle.context.action_registry.get_action(attack_id)
	if atk_mid == null:
		return "ATTACK_BEFORE 后攻击动作不存在（应停在损伤放置）"
	if int(atk_mid.record.get("extra_might", 0)) != 3:
		return "effect_124 应使 extra_might=3（最后一张弃置），实际 %d" % int(atk_mid.record.get("extra_might", 0))
	# 驱动损伤放置，完成攻击
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(5)
	# 被随机弃置的牌（other）应进弃牌堆
	var oc = gs.get_card(other_card)
	if oc == null or String(oc.zone) != &"discard":
		return "随机弃置的牌应进弃牌堆，zone=%s" % (String(oc.zone) if oc != null else "null")
	return true


## effect_130：weapon_033 维修机械臂 转化行动牌（选1张行动牌当维修打出，之后自损2）
## 验证：触发->列全部行动牌选1->维修目标选择->二选一回复4HP->素材牌进弃牌堆->本牌自损2
func test_weapon_130_transform_repair() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var pm = gs.get_mech_for_player(&"player")
	# 装备维修机械臂（N稀有度，在 equipment_deck）
	var arm_cid: StringName = _ensure_equipment_in_hand(battle, "weapon_033_维修机械臂")
	if arm_cid == &"":
		return "找不到 weapon_033"
	var set_res: Dictionary = battle.context.card_set_service.set_equipment(&"player", arm_cid, &"weapon_1")
	if not set_res.get("ok", false):
		return "装备 weapon_033 失败: %s" % String(set_res.get("message", ""))
	await _pump_frames(3)
	# 维修目标：玩家机甲掉血+有损伤（HP不满 + 有损伤 -> 回复/移除两选项均可，CHOOSE_ONE 弹窗）
	var hp_before: int = pm.current_hp
	pm.current_hp = max(1, pm.current_hp - 5)
	for slot_id in pm.slots:
		var slot = pm.slots[slot_id]
		if slot and slot.equipped_card:
			slot.region_damage_tokens = 3
			break
	# 确保 ≥2 行动牌（1张转化素材 + 余量）
	var pl = gs.players.get(&"player")
	while pl.action_hand.size() < 2 and not gs.deck_state.action_deck.is_empty():
		var dc: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		pl.action_hand.append(dc)
		var cc = gs.get_card(dc)
		if cc:
			cc.zone = &"action_hand"
			cc.owner_player_id = &"player"
	var transform_card: StringName = pl.action_hand[0]
	battle.context.action_ui_bridge.context = battle.context
	# 触发 effect_130（DIRECT 主动效果）
	var src: Dictionary = {"card_instance_id": arm_cid, "mech_id": pm.mech_id, "player_id": &"player", "effect_id": &"equipment_effect_130"}
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_130", "player_id": &"player",
		"source_mech_id": pm.mech_id, "card_instance_id": arm_cid,
		"phase": &"MAIN", "source": src,
	})
	await _pump_frames(3)
	# ① 应挂起 select_thrust_cards（CHOOSE_MANY_CARDS source=OWNER_ACTION_HAND 列出全部行动牌）
	var ef_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			ef_action = a
			break
	if ef_action == null:
		return "effect_130 未挂起在 CHOOSE_MANY_CARDS"
	var bridge = battle.context.action_ui_bridge
	var w0: Dictionary = bridge.get_waiting_action_info()
	if String(w0.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards，实际 %s" % String(w0.get("input_type", &""))
	# 选1张行动牌当作维修
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": [transform_card]})
	await _pump_frames(3)
	# ② use_action_card 应挂起 select_repair_target（维修目标选择）
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != &"select_repair_target":
		return "应弹 select_repair_target，实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"target_id": pm.mech_id})
	await _pump_frames(3)
	# ③ 应挂起 choose_one_effect（回复4生命/移除2损伤）
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != &"choose_one_effect":
		return "应弹 choose_one_effect，实际 %s" % String(w2.get("input_type", &""))
	bridge.on_ui_confirmed({"chosen_option_index": 0, "chosen_effect_id": "option_0"})
	await _pump_frames(6)
	# 断言：转化素材牌进弃牌堆，HP回复4，机械臂自损2（effect_130b）
	var tc = gs.get_card(transform_card)
	if tc == null or String(tc.zone) != &"discard":
		return "转化素材牌应进弃牌堆，zone=%s" % (String(tc.zone) if tc != null else "null")
	if pm.current_hp != (hp_before - 5) + 4:
		return "回复4生命未生效：期望 %d，实际 %d" % [(hp_before - 5) + 4, pm.current_hp]
	var arm_card = gs.get_card(arm_cid)
	if arm_card == null or int(arm_card.damage_tokens) != 2:
		return "机械臂应自损2，实际 damage_tokens=%d" % (int(arm_card.damage_tokens) if arm_card != null else -1)
	return true


## effect_135：满血(无维修目标)+≥2牌时触发按钮应可用（弃2抽2分支可用）
func test_weapon_135_trigger_enabled_with_discard_branch() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var pm = gs.get_mech_for_player(&"player")
	var arm_cid: StringName = _ensure_equipment_in_hand(battle, "weapon_037_多功能机械臂")
	if arm_cid == &"":
		return "找不到 weapon_037"
	battle.context.card_set_service.set_equipment(&"player", arm_cid, &"weapon_1")
	await _pump_frames(3)
	# 满血无损伤 -> 无维修目标
	pm.current_hp = pm.max_hp
	for slot_id in pm.slots:
		var slot = pm.slots[slot_id]
		if slot:
			slot.region_damage_tokens = 0
	# 确保 ≥2 行动牌（弃2抽2可用）
	var pl = gs.players.get(&"player")
	while pl.action_hand.size() < 2 and not gs.deck_state.action_deck.is_empty():
		var dc: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		pl.action_hand.append(dc)
		var cc = gs.get_card(dc)
		if cc:
			cc.zone = &"action_hand"
			cc.owner_player_id = &"player"
	var hand_n: int = pl.action_hand.size()
	if hand_n < 2:
		return "测试前置失败：手牌不足2张"
	# 找 effect_135 permanent listener，调 can_trigger_active_effect
	var te = battle.context.timing_engine
	var eff_135 = null
	var bind_135: Dictionary = {}
	for timing in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			if entry is Dictionary and entry.get("effect") != null and String(entry.effect.effect_id) == "equipment_effect_135":
				eff_135 = entry.effect
				bind_135 = entry.get("binding_context", {})
				break
	if eff_135 == null:
		return "effect_135 未注册为 permanent listener"
	var can_trigger: bool = te.can_trigger_active_effect(eff_135, bind_135)
	if not can_trigger:
		return "满血+≥2牌应可触发(弃2抽2分支可用)，can_trigger=false（手牌%d）" % hand_n
	return true


## effect_135：装备牌 owner_player_id 为空(历史抽牌/商店未设)时触发应仍可用（_equip_player_id 从机甲反查兜底）
func test_weapon_135_trigger_no_owner_id_fallback() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var pm = gs.get_mech_for_player(&"player")
	var arm_cid: StringName = _ensure_equipment_in_hand(battle, "weapon_037_多功能机械臂")
	if arm_cid == &"":
		return "找不到 weapon_037"
	# 模拟历史抽牌/商店未设 owner_player_id 的 bug 场景：装前清空
	var arm_card_pre = gs.get_card(arm_cid)
	if arm_card_pre != null:
		arm_card_pre.owner_player_id = &""
	battle.context.card_set_service.set_equipment(&"player", arm_cid, &"weapon_1")
	await _pump_frames(3)
	pm.current_hp = pm.max_hp
	for slot_id in pm.slots:
		var slot = pm.slots[slot_id]
		if slot:
			slot.region_damage_tokens = 0
	var pl = gs.players.get(&"player")
	while pl.action_hand.size() < 2 and not gs.deck_state.action_deck.is_empty():
		var dc: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		pl.action_hand.append(dc)
		var cc = gs.get_card(dc)
		if cc:
			cc.zone = &"action_hand"
			cc.owner_player_id = &"player"
	var te = battle.context.timing_engine
	var eff_135 = null
	var bind_135: Dictionary = {}
	for timing in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			if entry is Dictionary and entry.get("effect") != null and String(entry.effect.effect_id) == "equipment_effect_135":
				eff_135 = entry.effect
				bind_135 = entry.get("binding_context", {})
				break
	if eff_135 == null:
		return "effect_135 未注册"
	if String(bind_135.get("player_id", &"")) != &"":
		return "测试前置失败：binding_context.player_id 应为空(模拟未设 owner_player_id)"
	var can_trigger: bool = te.can_trigger_active_effect(eff_135, bind_135)
	if not can_trigger:
		return "owner_player_id 空时应从机甲反查玩家使触发可用，can_trigger=false"
	return true


## effect_135：weapon_037 多功能机械臂「弃2抽2」分支
## 验证：持有者自选2张行动牌弃置（非随机/非前N张），再抽2张，之后自损2
func test_weapon_135_discard_draw_branch() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var pm = gs.get_mech_for_player(&"player")
	# 装备多功能机械臂（R稀有度，在 equipment_deck）
	var arm_cid: StringName = _ensure_equipment_in_hand(battle, "weapon_037_多功能机械臂")
	if arm_cid == &"":
		return "找不到 weapon_037"
	var set_res: Dictionary = battle.context.card_set_service.set_equipment(&"player", arm_cid, &"weapon_1")
	if not set_res.get("ok", false):
		return "装备 weapon_037 失败: %s" % String(set_res.get("message", ""))
	await _pump_frames(3)
	# 玩家机甲满血无损伤 -> 无维修目标 -> CHOOSE_ONE 仅「弃2抽2」可用
	pm.current_hp = pm.max_hp
	for slot_id in pm.slots:
		var slot = pm.slots[slot_id]
		if slot:
			slot.region_damage_tokens = 0
	# 确保 ≥3 行动牌（弃2后留≥1）
	var pl = gs.players.get(&"player")
	while pl.action_hand.size() < 3 and not gs.deck_state.action_deck.is_empty():
		var dc: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		pl.action_hand.append(dc)
		var cc = gs.get_card(dc)
		if cc:
			cc.zone = &"action_hand"
			cc.owner_player_id = &"player"
	var hand_before: int = pl.action_hand.size()
	var discard_cards: Array = pl.action_hand.slice(0, 2)
	battle.context.action_ui_bridge.context = battle.context
	# 触发 effect_135
	var src: Dictionary = {"card_instance_id": arm_cid, "mech_id": pm.mech_id, "player_id": &"player", "effect_id": &"equipment_effect_135"}
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_135", "player_id": &"player",
		"source_mech_id": pm.mech_id, "card_instance_id": arm_cid,
		"phase": &"MAIN", "source": src,
	})
	await _pump_frames(3)
	# ① 应弹 choose_one_effect（仅「弃2抽2」可用，optional 弹窗）
	var ef_action = null
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			ef_action = a
			break
	if ef_action == null:
		return "effect_135 未挂起在 CHOOSE_ONE"
	var bridge = battle.context.action_ui_bridge
	var w0: Dictionary = bridge.get_waiting_action_info()
	if String(w0.get("input_type", &"")) != &"choose_one_effect":
		return "应弹 choose_one_effect，实际 %s" % String(w0.get("input_type", &""))
	# 选「弃2抽2」(option_1)
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"chosen_option_index": 1})
	await _pump_frames(3)
	# ② 应弹 select_discard_cards（持有者自选2张，非随机/非前N张）
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != &"select_discard_cards":
		return "应弹 select_discard_cards（玩家自选弃牌），实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"determined_card_ids": discard_cards})
	await _pump_frames(6)
	# 断言：弃2抽2 -> 手牌数不变，2张进弃牌堆，机械臂自损2
	if pl.action_hand.size() != hand_before:
		return "弃2抽2后手牌数应不变(%d)，实际 %d" % [hand_before, pl.action_hand.size()]
	for dc: StringName in discard_cards:
		var dc_card = gs.get_card(dc)
		if dc_card == null or String(dc_card.zone) != &"discard":
			return "弃置的牌应进弃牌堆，zone=%s" % (String(dc_card.zone) if dc_card != null else "null")
	var arm_card = gs.get_card(arm_cid)
	if arm_card == null or int(arm_card.damage_tokens) != 2:
		return "机械臂应自损2，实际 damage_tokens=%d" % (int(arm_card.damage_tokens) if arm_card != null else -1)
	return true


## effect_102/102b：weapon_008 断甲长刀 命中后+2，之后(ATTACK_SETTLE)自损1
## 验证「之后」：+2 在 ATTACK_AFTER 写入 extra_markers、step⑦ 放到目标后，自损1 才在 ATTACK_SETTLE 落点
func test_weapon_102_plus2_then_settle_self_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_008_断甲长刀")
	if cid == &"":
		return "装备 weapon_008 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程3内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# effect_102 在 ATTACK_AFTER 弹 CHOOSE_ONE（optional），选"额外设置2损伤"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		var atk_c = battle.context.action_registry.get_action(attack_id)
		var em_pre: int = int(atk_c.record.get("extra_markers", 0)) if atk_c != null else -1
		_drive_damage_placement(battle, attack_id)
		await _pump_frames(3)
		return "effect_102 未弹 choose_one_effect（wait=%s）extra_markers=%d" % [String(wait_info.get("input_type", &"")), em_pre]
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# extra_markers 应=2（+2 已写入，尚未放到目标）
	var atk2 = battle.context.action_registry.get_action(attack_id)
	if atk2 != null and int(atk2.record.get("extra_markers", 0)) != 2:
		return "effect_102 应使 extra_markers=2，实际 %d" % int(atk2.record.get("extra_markers", 0))
	# 变量 weapon_008_plus2_used 应=1（INCREMENT_VARIABLE 写入，供 102b 在 ATTACK_SETTLE 检查）
	var vars2: Dictionary = atk2.record.get("variables", {}) if atk2 != null else {}
	if int(vars2.get("weapon_008_plus2_used", 0)) != 1:
		return "INCREMENT_VARIABLE 应写 weapon_008_plus2_used=1，实际 %d" % int(vars2.get("weapon_008_plus2_used", 0))
	# 「之后」关键断言：ATTACK_AFTER 阶段本牌尚不应自损（自损在 ATTACK_SETTLE）
	var card_pre = gs.get_card(cid)
	if int(card_pre.damage_tokens) != 0:
		return "ATTACK_AFTER 阶段本牌不应自损（应在 ATTACK_SETTLE），实际 damage_tokens=%d" % int(card_pre.damage_tokens)
	# 驱动损伤放置（step⑦ 把 +2 放到目标），之后 ATTACK_SETTLE 触发 102b 自损1
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(5)
	var card = gs.get_card(cid)
	if int(card.damage_tokens) != 1:
		# 诊断：effect_102b 是否注册到 ATTACK_SETTLE / 变量是否写入
		var has_102b := false
		var pl_settle = battle.context.timing_engine.permanent_listeners
		if pl_settle.has(&"ATTACK_SETTLE"):
			for entry in pl_settle[&"ATTACK_SETTLE"]:
				var e = entry.get("effect") if entry is Dictionary else null
				if e and e.effect_id == &"equipment_effect_102b":
					has_102b = true
		var atk3 = battle.context.action_registry.get_action(attack_id)
		var vars: Dictionary = atk3.record.get("variables", {}) if atk3 != null else {}
		var var_val: int = int(vars.get("weapon_008_plus2_used", 0))
		var atk_state: String = String(atk3.state) if atk3 != null else "removed"
		return "effect_102b 应在 ATTACK_SETTLE 自损1，实际 damage_tokens=%d | 102b注册=%s 变量=%d atk_state=%s" % [int(card.damage_tokens), str(has_102b), var_val, atk_state]
	return true


## effect_103：weapon_009 重型锤矛 攻击未命中则本牌自损2
## 构造 miss：玩家攻击敌方，ATTACK_AT 响应窗口打开后手动把敌方移出射程，再跳过响应 -> check_hit 未命中
func test_weapon_103_miss_self_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_009_重型锤矛")
	if cid == &"":
		return "装备 weapon_009 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程内；回避移3步到q9（距离4>3）出范围
	em.power = 10  # 回避需消耗动力
	# 给敌方手牌塞一张回避（作为 AVAILABILITY 监听打开 ATTACK_AT 响应窗口）
	var ep = gs.players.get(&"enemy")
	var evade_cid: StringName = &""
	for c_id in ep.action_hand:
		var c = gs.get_card(c_id)
		if c and c.def and c.def.card_id == "action_008_回避":
			evade_cid = c_id
			break
	if evade_cid == &"":
		for pile in [gs.deck_state.action_deck, gs.deck_state.action_discard_pile]:
			for i in range(pile.size()):
				var c = gs.get_card(pile[i])
				if c and c.def and c.def.card_id == "action_008_回避":
					evade_cid = pile[i]
					pile.remove_at(i)
					ep.action_hand.append(evade_cid)
					c.zone = &"action_hand"
					c.owner_player_id = &"enemy"
					battle.context.register_hand_card_availability(evade_cid)
					break
			if evade_cid != &"":
				break
	if evade_cid == &"":
		return "敌方无回避牌用于打开响应窗口"
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(8)
	# 敌方(AI)自动用回避响应，移出射程 -> check_hit 未命中 -> effect_103 自损2
	var card = gs.get_card(cid)
	if int(card.damage_tokens) != 2:
		var atk_d = battle.context.action_registry.get_action(attack_id)
		var atk_state_d: String = String(atk_d.state) if atk_d != null else "removed"
		var hit_d: bool = bool(atk_d.record.get("hit", false)) if atk_d != null else false
		return "effect_103 未命中应自损2，实际 damage_tokens=%d | hit=%s atk_state=%s enemy_q=%d" % [int(card.damage_tokens), str(hit_d), atk_state_d, int(em.position.get("q", 0))]
	return true


## effect_100：weapon_005 扭转钢鞭 命中后弃置攻击目标2张行动牌
func test_weapon_100_discard_2_target_action_cards() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_005_扭转钢鞭")
	if cid == &"":
		return "装备 weapon_005 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程3内
	# 确保敌方手牌至少2张行动牌
	var ep = gs.players.get(&"enemy")
	while ep.action_hand.size() < 2:
		if gs.deck_state.action_deck.is_empty():
			break
		var did: StringName = gs.deck_state.action_deck.pop_back()
		ep.action_hand.append(did)
		var dc = gs.get_card(did)
		if dc != null:
			dc.zone = &"action_hand"
			dc.owner_player_id = &"enemy"
	if ep.action_hand.size() < 2:
		return "敌方行动牌不足2张，无法测试"
	var enemy_hand_before: int = ep.action_hand.size()
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# effect_100 在 ATTACK_AFTER 弹 CHOOSE_ONE（optional），选"弃置目标2张行动牌"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		_drive_damage_placement(battle, attack_id)
		await _pump_frames(3)
		return "effect_100 未弹 choose_one_effect，wait=%s" % str(wait_info)
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# 应弹 select_discard_cards（弃攻击目标2张行动牌，暗牌）
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_discard_cards":
		return "effect_100 确认后未弹 select_discard_cards，wait=%s" % str(wait2)
	var input_params: Dictionary = wait2.get("input_params", {})
	var discard_pid: StringName = input_params.get("discard_player_id", &"")
	if String(discard_pid) != "enemy":
		return "弃牌对象应为 enemy（攻击目标），实际 %s" % String(discard_pid)
	# 选敌方手牌前2张弃置
	var chosen: Array = ep.action_hand.slice(0, 2)
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": chosen})
	await _pump_frames(5)
	# 驱动主攻击损伤放置
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	if ep.action_hand.size() != enemy_hand_before - 2:
		return "敌方手牌应-2，前=%d 后=%d" % [enemy_hand_before, ep.action_hand.size()]
	return true


## effect_131/131b：weapon_034 手持推进器 主阶段动力+4，之后(EFFECT_FIRE_SETTLE)自损1
## 验证「之后」结构分离：动力+4 在 execute_effect 步，自损1 在 settle 步（不同批次）
func test_weapon_131_power_boost_then_settle_self_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_034_手持推进器")
	if cid == &"":
		return "装备 weapon_034 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	gs.phase = &"MAIN"
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context
	var card = gs.get_card(cid)
	var power_before: int = int(pm.power)
	# 触发 DIRECT effect_131（主阶段动力+4）
	var ef_result: Dictionary = battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"equipment_effect_131",
		"player_id": &"player", "source_mech_id": pm.mech_id, "card_instance_id": cid, "phase": &"MAIN",
		"source": {"card_instance_id": cid, "mech_id": pm.mech_id, "player_id": &"player", "effect_id": &"equipment_effect_131"},
	})
	var ef_id: StringName = ef_result.get("action_id", &"") if ef_result is Dictionary else &""
	if ef_id == &"":
		return "effect_131 effect_fire 未发起"
	await _pump_frames(5)
	# 动力+4 应已生效（execute_effect 步完成）
	if int(pm.power) != power_before + 4:
		return "effect_131 应使动力+4，前=%d 后=%d" % [power_before, int(pm.power)]
	# effect_131b 在 EFFECT_FIRE_SETTLE 自损1（settle 步在 execute_effect 之后）
	if int(card.damage_tokens) != 1:
		var ef_a = battle.context.action_registry.get_action(ef_id)
		return "effect_131b 应在 EFFECT_FIRE_SETTLE 自损1，实际 damage_tokens=%d ef_state=%s" % [int(card.damage_tokens), String(ef_a.state) if ef_a != null else "removed"]
	return true


## 临时动力系统：增加当前动力(临时)消耗优先扣减、回合末清剩余本身动力保留
## 场景：4/8 -> +4临时 -> 8/8 -> 消耗4 -> 4/8(临时已消耗) -> 回合末 -> 4/8(本身保留)
func test_temp_power_consume_first_and_preserve() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var pm = battle.context.game_state.get_mech_for_player(&"player")
	pm.max_power = 8
	pm.power = 4
	pm.temp_power = 0
	pm.reset_turn_power_counters()
	# 临时动力+4（推进/手持推进器 effect_131/132 走 add_temp_power）
	pm.add_temp_power(4)
	if int(pm.power) != 8 or int(pm.temp_power) != 4:
		return "add_temp_power 后应 8/8 temp=4，实际 %d temp=%d" % [int(pm.power), int(pm.temp_power)]
	# 消耗4：优先扣临时，本身动力保留
	pm.consume_power(4)
	if int(pm.power) != 4 or int(pm.temp_power) != 0:
		return "消耗4后应 4/8 temp=0（临时已优先消耗），实际 %d temp=%d" % [int(pm.power), int(pm.temp_power)]
	if int(pm.own_power_spent_this_turn) != 0:
		return "本身动力消耗应为0（全从临时扣），实际 %d" % int(pm.own_power_spent_this_turn)
	# 回合末：本身动力4保留，临时0清除
	pm.clear_temp_power()
	if int(pm.power) != 4:
		return "回合末本身动力应保留4，实际 %d" % int(pm.power)
	# 另一场景：临时未消耗完，回合末清剩余、本身保留
	pm.power = 4
	pm.temp_power = 0
	pm.reset_turn_power_counters()
	pm.add_temp_power(4)  # 8/8 temp=4
	pm.consume_power(2)  # 6/8 temp=2（消耗2临时）
	if int(pm.power) != 6 or int(pm.temp_power) != 2:
		return "消耗2后应 6/8 temp=2，实际 %d temp=%d" % [int(pm.power), int(pm.temp_power)]
	pm.clear_temp_power()  # 回合末：清剩余临时2，本身4保留
	if int(pm.power) != 4:
		return "回合末未消耗临时应清除、本身4保留，实际 %d" % int(pm.power)
	# 临时动力可超上限：上限8+临时4=12
	pm.power = 8
	pm.temp_power = 0
	pm.reset_turn_power_counters()
	pm.add_temp_power(4)
	if int(pm.power) != 12:
		return "临时动力应可超上限 8+4=12，实际 %d" % int(pm.power)
	# 回复本身动力不压回临时：power=12(own8+temp4)，restore full 不变（own已满）
	var restored = pm.restore_own_power_to_full()
	if restored != 0 or int(pm.power) != 12:
		return "本身已满时回复应为0且不动临时，restored=%d power=%d" % [int(restored), int(pm.power)]
	return true


## 「之后」代价损伤结构分离校验：各武器 effect_Xb 定义正确（时点/requires_effect），
## 主效果不再含 PLACE_DAMAGE_TOKENS，且 JSON effect_ids 含 b
func test_weapon_after_self_damage_split_registered() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var all_effects: Dictionary = _GenEquipEffects.build_equipment_effects()
	# 从 battle 的 CardDatabaseLoader 取 JSON effect_ids 映射
	var cdb_loader = battle.context.card_database.loader
	var eid_map: Dictionary = cdb_loader.get_effect_ids_map() if cdb_loader != null and cdb_loader.has_method(&"get_effect_ids_map") else {}
	# (card_def_id, 主effect_id, b_effect_id, 期望时点, 是否用 requires_effect)
	# 130b/135b 不用 requires_effect：主效果经 CHOOSE_MANY_CARDS 挂起致 executed 不标记，
	# 改由 VARIABLE_ABOVE(weapon_0xx_used) 判定（变量仅在玩家选牌确认后写入）。
	var cases: Array = [
		["weapon_033_维修机械臂", &"equipment_effect_130", &"equipment_effect_130b", &"EFFECT_FIRE_SETTLE", false],
		["weapon_034_手持推进器", &"equipment_effect_131", &"equipment_effect_131b", &"EFFECT_FIRE_SETTLE", true],
		["weapon_034_手持推进器", &"equipment_effect_132", &"equipment_effect_132b", &"USE_ACTION_SETTLE", true],
		["weapon_036_投掷式机雷", &"equipment_effect_134", &"equipment_effect_134b", &"EFFECT_FIRE_SETTLE", true],
		["weapon_037_多功能机械臂", &"equipment_effect_135", &"equipment_effect_135b", &"EFFECT_FIRE_SETTLE", false],
		["weapon_039_投掷式双子机雷", &"equipment_effect_137", &"equipment_effect_137b", &"EFFECT_FIRE_SETTLE", true],
	]
	for case in cases:
		var card_def_id: String = case[0]
		var main_id: StringName = case[1]
		var b_id: StringName = case[2]
		var expect_timing: StringName = case[3]
		var uses_requires: bool = case[4]
		var b_eff = all_effects.get(b_id)
		if b_eff == null:
			return "%s 未定义" % String(b_id)
		if b_eff.listen_timing != expect_timing:
			return "%s 时点应为 %s，实际 %s" % [String(b_id), String(expect_timing), String(b_eff.listen_timing)]
		if uses_requires:
			if b_eff.requires_effect != main_id:
				return "%s requires_effect 应为 %s，实际 %s" % [String(b_id), String(main_id), String(b_eff.requires_effect)]
		else:
			if b_eff.requires_effect != &"":
				return "%s 应不设 requires_effect（改用变量条件），实际 %s" % [String(b_id), String(b_eff.requires_effect)]
		var main_eff = all_effects.get(main_id)
		if main_eff == null:
			return "%s 未定义" % String(main_id)
		if _actions_contain_place_damage(main_eff.actions):
			return "%s 仍含 PLACE_DAMAGE_TOKENS（应已拆到 %s）" % [String(main_id), String(b_id)]
		# JSON effect_ids 应含 b
		var ids: Array = eid_map.get(card_def_id, [])
		if not ids.has(b_id):
			return "JSON %s.effect_ids 未含 %s" % [card_def_id, String(b_id)]
	return true


func _actions_contain_place_damage(actions: Array) -> bool:
	for a in actions:
		if a is Dictionary:
			if String(a.get("type", &"")) == &"PLACE_DAMAGE_TOKENS":
				return true
			var params: Dictionary = a.get("params", {})
			var options: Array = params.get("options", [])
			for opt in options:
				if opt is Dictionary and _actions_contain_place_damage(opt.get("actions", [])):
					return true
			var per_card: Array = params.get("per_card_actions", [])
			if _actions_contain_place_damage(per_card):
				return true
	return false


## 把本次攻击的全部损伤逐枚放置到同一指定槽位（驱动 effect_101「全在同区」条件成立）。
## 与 _drive_damage_placement 区别：不交给自动选择（会在多个已装备槽间随机分散），
## 而是强制全落到 slot_id，保证 damage_placement_log 全为同一 slot。
func _drive_damage_placement_on_slot(battle: BattleState, attack_id: StringName, slot_id: StringName) -> void:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id == &"":
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			continue
		var dc = ar.get_action(dc_id)
		var amount: int = int(dc.record.get("value", 0))
		var mech_ids: Array = dc.record.get("mech_ids", [])
		if dts != null and amount > 0:
			for mech_id: StringName in mech_ids:
				for _i in range(amount):
					dts.place_one_damage_token(mech_id, slot_id)
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)


## effect_101：weapon_006 光束战戟 攻击损伤全在同一区域 -> ATTACK_SETTLE 弹 CHOOSE_ONE ->
## 选「额外设置2损伤」-> 该区域 +2（含原装备牌已破损弃置的空槽场景）。
## 威力15 -> markers=3，全部置于头部；头部装备耐久置1使第1枚即破损弃置，验证空槽仍能放+2。
func test_weapon_101_same_region_extra_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_006_光束战戟")
	if cid == &"":
		return "装备 weapon_006 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100  # 防止击毁
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程3内
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	# 诊断：effect_101 是否注册到 ATTACK_SETTLE
	var has_e101 := false
	var pl = battle.context.timing_engine.permanent_listeners
	if pl.has(&"ATTACK_SETTLE"):
		for entry in pl[&"ATTACK_SETTLE"]:
			var e = entry.get("effect") if entry is Dictionary else null
			if e and e.effect_id == &"equipment_effect_101":
				has_e101 = true
	if not has_e101:
		return "effect_101 未注册到 ATTACK_SETTLE"
	# 头部装备耐久置1：第1枚损伤即破损弃置，后续2枚+效果+2落在空头部区域上（验证用户裁定）
	var head_slot = em.slots.get(&"头部")
	var head_card_orig = head_slot.equipped_card if head_slot != null else null
	if head_slot != null and head_card_orig != null:
		head_slot.base_durability = 1
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起: %s" % str(atk_result)
	await _pump_frames(5)
	# 全部3枚损伤置于头部（damage_placement_log = [头部,头部,头部]）
	_drive_damage_placement_on_slot(battle, attack_id, &"头部")
	await _pump_frames(5)
	# effect_101 在 ATTACK_SETTLE 弹 CHOOSE_ONE（optional）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		var atk_c = battle.context.action_registry.get_action(attack_id)
		var atk_state: String = String(atk_c.state) if atk_c != null else "removed"
		var dlog: Array = atk_c.record.get("damage_placement_log", []) if atk_c != null else []
		var sdsid: String = String(atk_c.record.get("single_damage_slot_id", &"")) if atk_c != null else ""
		return "effect_101 未弹 choose_one_effect（wait=%s atk_state=%s dlog=%s single=%s）" % [String(wait_info.get("input_type", &"")), atk_state, str(dlog), sdsid]
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	# 头部区域损伤应 = 3（原放置）+ 2（effect_101 追加）= 5
	var head_after = em.slots.get(&"头部")
	var region_dt: int = int(head_after.region_damage_tokens) if head_after != null else -1
	if region_dt != 5:
		var atk2 = battle.context.action_registry.get_action(attack_id)
		var dlog2: Array = atk2.record.get("damage_placement_log", []) if atk2 != null else []
		var still_has_card: bool = head_after != null and head_after.equipped_card != null
		return "effect_101 应使头部区域损伤=5（3+2），实际 %d | dlog=%s 头部仍有装备=%s" % [region_dt, str(dlog2), str(still_has_card)]
	# 头部装备牌应已破损弃置（耐久1承受3枚），但区域损伤仍累计到5——验证「装备弃置也照放」
	if head_card_orig != null and head_after != null and head_after.equipped_card != null:
		return "头部装备牌耐久1承受3枚损伤应已破损弃置，但 equipped_card 仍存在"
	return true


## effect_101 负向：损伤分散到两区 -> 不应触发额外2损伤
func test_weapon_101_split_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_006_光束战戟")
	if cid == &"":
		return "装备 weapon_006 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# 损伤分散：2枚头部 + 1枚躯干（手动逐枚放置不同槽）
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid2: StringName in pending:
			var sub = ar.get_action(cid2)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid2
				break
		if dc_id == &"":
			for cid2: StringName in pending:
				ae.notify_effect_action_completed(cid2, attack_id)
			continue
		# 手动分散放置
		dts.place_one_damage_token(em.mech_id, &"头部")
		dts.place_one_damage_token(em.mech_id, &"头部")
		dts.place_one_damage_token(em.mech_id, &"躯干")
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)
	await _pump_frames(5)
	# 损伤分散 -> effect_101 不触发，不应弹 CHOOSE_ONE
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) == &"choose_one_effect":
		return "损伤分散时 effect_101 不应触发 CHOOSE_ONE"
	# 头部2 + 躯干1 = 3，无额外
	var head_dt: int = int(em.slots.get(&"头部").region_damage_tokens)
	var torso_dt: int = int(em.slots.get(&"躯干").region_damage_tokens)
	if head_dt + torso_dt != 3:
		return "分散放置总损伤应为3，实际 头%d+躯%d" % [head_dt, torso_dt]
	return true


## effect_101 顺序：玩家A 用光束战戟攻击玩家B，B 反击响应 -> 损伤放置完成后，
## effect_101(priority=30) 应先于 counter_effect2(priority=20) 触发 -> 弹 CHOOSE_ONE，
## 反击攻击B 暂存到 _pending_regular_listeners 待 effect_101 结算后再触发。
## 验证用户报告的顺序 bug 已修（原 priority=10 时反击链先跑完才弹 effect_101）。
func test_weapon_101_fires_before_counter() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_006_光束战戟")
	if cid == &"":
		return "装备 weapon_006 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}  # 距离1，在射程3内
	# 双方人类玩家：响应窗口交还手动驱动
	gs.players.get(&"player").is_human = true
	gs.players.get(&"enemy").is_human = true
	em.power = 0  # 反击 effect1 半动力移动 X=0（首次仍请求选格->取消结束）
	_clear_enemy_hand(battle)
	var counter_id: StringName = _ensure_card_in_enemy_hand(battle, "action_010_反击")
	if counter_id == &"":
		return "找不到 action_010_反击"
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起: %s" % str(atk_result)
	await _pump_frames(5)
	var ar = battle.context.action_registry
	var ae = battle.context.action_engine
	var attack = ar.get_action(attack_id)
	if attack == null:
		return "攻击动作丢失"
	# execute_attack_action 已传 cid+target，通常直达 ATTACK_AT；兜底驱动选武器/目标
	var guard_sel: int = 0
	while String(attack.state) == &"waiting_input" and guard_sel < 6:
		guard_sel += 1
		if not attack.record.has("weapon_id"):
			ae.continue_action(attack_id, {"weapon_id": cid})
		else:
			ae.continue_action(attack_id, {"target_id": em.mech_id})
		await _pump_frames(2)
		attack = ar.get_action(attack_id)
	if attack == null:
		return "攻击动作丢失（选武器/目标后）"
	if String(attack.state) != &"waiting_timing":
		return "应在 ATTACK_AT waiting_timing（响应窗口），实际 state=%s" % String(attack.state)
	# 敌方选反击响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"counter_availability",
		"card_instance_id": counter_id,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_id, sel)
	await _pump_frames(3)
	# 反击 effect1 半动力移动（power=0 仍请求选格）-> 取消结束移动循环
	battle.context.action_ui_bridge.on_ui_cancelled()
	await _pump_frames(8)
	# 攻击恢复 -> ATTACK_AFTER -> 损伤设置（3枚全放头部）
	_drive_damage_placement_on_slot(battle, attack_id, &"头部")
	await _pump_frames(5)
	# ATTACK_SETTLE：effect_101(priority=30) 应先弹 CHOOSE_ONE，counter_effect2(priority=20) 暂存
	attack = ar.get_action(attack_id)
	if attack == null:
		return "ATTACK_SETTLE 后攻击动作丢失（effect_101 未挂起？）"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		var atk_state: String = String(attack.state)
		return "effect_101 应先于反击触发弹 CHOOSE_ONE，实际 wait=%s atk_state=%s" % [String(wait_info.get("input_type", &"")), atk_state]
	# counter_effect2 应被暂存到 _pending_regular_listeners（待 effect_101 结算后触发）
	var counter_deferred: bool = false
	for le: Dictionary in attack._pending_regular_listeners:
		var eff = le.get("effect")
		if eff and eff.effect_id == &"counter_effect2":
			counter_deferred = true
			break
	if not counter_deferred:
		return "counter_effect2 应暂存到 _pending_regular_listeners（待 effect_101 结算后触发），实际=%s" % str(attack._pending_regular_listeners)
	# 不应已创建反击攻击B 子动作（counter_effect2 未触发）
	for aid: StringName in attack.pending_effect_action_ids:
		var sub = ar.get_action(aid)
		if sub != null and sub.action_type == &"attack":
			return "effect_101 未先触发：反击攻击B 已提前创建"
	return true


## ─────────── effect_110/111 闪回激光剑：动力消耗检查 ───────────

## effect_110/111 正向：power=10，攻击确认 effect_111，应扣 2(110)+4(111)=6，extra_might=3
func test_weapon_110_111_full_power_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_013_闪回激光剑")
	if cid == &"":
		return "装备 weapon_013 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	pm.power = 10
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(6)
	# effect_111 弹 CHOOSE_ONE（effect_110 已在 ATTACK_BEFORE 扣2，power 10->8）
	var coe: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe != "":
		return "effect_111 应弹 CHOOSE_ONE: %s power=%d" % [coe, pm.power]
	var atk2 = battle.context.action_registry.get_action(attack_id)
	var em_val: int = int(atk2.record.get("extra_might", 0)) if atk2 != null else -1
	if em_val != 3:
		return "effect_111 确认后应 extra_might=3，实际 %d" % em_val
	if pm.power != 4:
		return "应扣 2+4=6 动力(10->4)，实际 power=%d" % pm.power
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## effect_110 动力不足(<2)：攻击应被取消（不能攻击）
func test_weapon_110_insufficient_power_cancels() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_013_闪回激光剑")
	if cid == &"":
		return "装备 weapon_013 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	pm.power = 1  # 不足2
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(6)
	# 攻击应被取消（effect_110 必耗2动力不可支付），动作被清理 -> get_action 返回 null
	var atk2 = battle.context.action_registry.get_action(attack_id)
	if atk2 != null and atk2.state != &"cancelled":
		return "动力不足应取消攻击，实际 state=%s power=%d" % [String(atk2.state), pm.power]
	if pm.power != 1:
		return "取消后动力不应扣，实际 power=%d" % pm.power
	return true


## effect_111 动力不足4：effect_110 扣2后无 effect_111 弹窗
func test_weapon_111_no_popup_low_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_013_闪回激光剑")
	if cid == &"":
		return "装备 weapon_013 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	pm.power = 3  # 够2不够4
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(6)
	# effect_110 扣2(3->1)，effect_111 条件 power>=4 失败 -> 不弹 CHOOSE_ONE，直接进损伤设置
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) == &"choose_one_effect":
		_drive_damage_placement(battle, attack_id)
		return "effect_111 power=1<4 不应弹 CHOOSE_ONE"
	if pm.power != 1:
		return "effect_110 应扣2(3->1)，实际 power=%d" % pm.power
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ─────────── effect_117/118 密集导弹炮：目标动力操纵 ───────────

## effect_117/118 正向：目标动力2，effect_117 -2 -> 0，effect_118 +2损伤标记
func test_weapon_117_118_power_drain_zero() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_024_密集导弹炮")
	if cid == &"":
		return "装备 weapon_024 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	em.power = 2  # 目标动力2
	pm.power = 10
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(6)
	# effect_117(ATTACK_PRE) 弹 CHOOSE_ONE：选「使目标当前动力-2」
	var coe1: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe1 != "":
		return "effect_117 应弹 CHOOSE_ONE: %s" % coe1
	if em.power != 0:
		return "effect_117 应使目标动力 2->0，实际 %d" % em.power
	await _pump_frames(4)
	# effect_118(ATTACK_AFTER) 弹 CHOOSE_ONE：目标动力0 -> 额外+2损伤标记
	var coe2: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe2 != "":
		_drive_damage_placement(battle, attack_id)
		return "effect_118 应弹 CHOOSE_ONE: %s" % coe2
	var atk2 = battle.context.action_registry.get_action(attack_id)
	var em_val: int = int(atk2.record.get("extra_markers", 0)) if atk2 != null else -1
	if em_val != 2:
		return "effect_118 确认后应 extra_markers=2，实际 %d" % em_val
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## effect_117 动力不减上限/不计消耗：目标动力3，-2后=1（非0），effect_118 不触发；持有者动力不变
func test_weapon_117_drain_no_spent_no_cap() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_024_密集导弹炮")
	if cid == &"":
		return "装备 weapon_024 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	em.power = 3
	var em_max_before: int = int(em.max_power) if "max_power" in em else 0
	pm.power = 10
	var pm_spent_before: int = int(pm.power_spent_this_turn) if "power_spent_this_turn" in pm else 0
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(6)
	var coe1: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe1 != "":
		return "effect_117 应弹 CHOOSE_ONE: %s" % coe1
	if em.power != 1:
		return "effect_117 应使目标动力 3->1，实际 %d" % em.power
	# max_power 不变（不减上限）
	var em_max_after: int = int(em.max_power) if "max_power" in em else 0
	if em_max_after != em_max_before:
		return "effect_117 不应改上限，max %d->%d" % [em_max_before, em_max_after]
	# 不计入持有者消耗（pm.power_spent_this_turn 不变）
	var pm_spent_after: int = int(pm.power_spent_this_turn) if "power_spent_this_turn" in pm else 0
	if pm_spent_after != pm_spent_before:
		return "effect_117 不应计入持有者 power_spent，%d->%d" % [pm_spent_before, pm_spent_after]
	await _pump_frames(4)
	# 目标动力1（非0）-> effect_118 不触发，无第二个 CHOOSE_ONE
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) == &"choose_one_effect":
		_drive_damage_placement(battle, attack_id)
		return "effect_118 目标动力1!=0 不应弹 CHOOSE_ONE"
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	return true


## ─────────── effect_119 超级火箭筒：损伤分散额外2损伤 ───────────

## effect_119 正向：主损伤分散到2区，弹 CHOOSE_ONE，确认后持有者额外设置2损伤
func test_weapon_119_scatter_extra_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_025_超级火箭筒")
	if cid == &"":
		return "装备 weapon_025 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	# 清空敌方装备使护甲0，保证 weapon_025(威力10) 产生2枚损伤(10/5=2)便于分散
	for slot_id in em.slots.keys():
		var s = em.slots[slot_id]
		if s != null:
			s.equipped_card = null
			s.base_armor = 0
			s.armor_modifier = 0
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# 主损伤2枚分散：1头部 + 1躯干
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	var guard: int = 0
	while attack != null and attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		var dc_id: StringName = &""
		for cid2: StringName in pending:
			var sub = ar.get_action(cid2)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid2
				break
		if dc_id == &"":
			break
		dts.place_one_damage_token(em.mech_id, &"头部")
		dts.place_one_damage_token(em.mech_id, &"躯干")
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)
	await _pump_frames(5)
	# ATTACK_SETTLE：effect_119 弹 CHOOSE_ONE
	var coe: String = await _drive_choose_one_confirm(battle, attack_id)
	if coe != "":
		return "effect_119 损伤分散应弹 CHOOSE_ONE: %s" % coe
	await _pump_frames(4)
	# effect_119 确认后 EXECUTE_DAMAGE_CHANGE 生成2枚额外损伤 -> 驱动放置
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
	# 额外2损伤已放置：主2(头1+躯1) + 额外2 = 总4（额外2由 _choose_slot_for_token 随机选空槽，故按全槽位合计）
	var total_dt: int = 0
	for sid in em.slots.keys():
		var s = em.slots[sid]
		if s != null:
			total_dt += int(s.region_damage_tokens)
	if total_dt != 4:
		return "主2+额外2应总4损伤，实际 %d" % total_dt
	return true


## effect_119 负向：主损伤全在同一区 -> 不触发
func test_weapon_119_same_slot_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_025_超级火箭筒")
	if cid == &"":
		return "装备 weapon_025 失败"
	var gs = battle.context.game_state
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	em.current_hp = 100
	for slot_id in em.slots.keys():
		var s = em.slots[slot_id]
		if s != null:
			s.equipped_card = null
			s.base_armor = 0
			s.armor_modifier = 0
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var atk_card: StringName = _ensure_attack_card_in_hand(battle)
	if atk_card == &"":
		return "玩家无攻击牌"
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", cid, atk_card)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起"
	await _pump_frames(5)
	# 主损伤2枚全放头部（同区）
	_drive_damage_placement_on_slot(battle, attack_id, &"头部")
	await _pump_frames(5)
	# 同区 -> effect_119 不触发，不弹 CHOOSE_ONE
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) == &"choose_one_effect":
		return "effect_119 损伤同区不应弹 CHOOSE_ONE"
	# 头部应=2（无额外）
	var head_dt: int = int(em.slots.get(&"头部").region_damage_tokens) if em.slots.get(&"头部") else -1
	if head_dt != 2:
		return "同区应无额外，头部=2，实际 %d" % head_dt
	return true
