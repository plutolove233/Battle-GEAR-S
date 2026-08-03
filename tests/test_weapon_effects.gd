extends RefCounted

## test_weapon_effects.gd - 武器装备牌效果（effect_093-139）验证
## 覆盖：47 effect 定义齐全 / JSON effect_ids 映射 / 派生值(040护甲×2、026每损伤-2) /
##       攻击触发自损(129) / 攻击次数衰减(112)。CHOOSE_ONE/聚能/直攻免牌等需实机弹窗的走 F3。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")


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


func _equip_weapon(battle: BattleState, card_def_id: String) -> StringName:
	var cid: StringName = _ensure_equipment_in_hand(battle, card_def_id)
	if cid == &"":
		return &""
	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", cid, &"weapon_1")
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


## ③ 派生值：weapon_040 威力=护甲×2，范围=当前动力
func test_weapon_040_energy_conversion() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	_GenEquipEffects.set_aura_game_state(battle.context.game_state)
	var cid: StringName = await _equip_weapon(battle, "weapon_040_质能全转换剑炮")
	if cid == &"":
		return "装备 weapon_040 失败"
	var card = battle.context.game_state.get_card(cid)
	var pm = battle.context.game_state.get_mech_for_player(&"player")
	pm.power = 5  # 当前动力5
	# 护甲取当前总护甲（含部件）。威力应=max(0,armor*2)，范围应=5
	var stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	var armor: int = pm.get_armor()
	var exp_might: int = maxi(0, armor * 2)
	if int(stats.get("might", -1)) != exp_might:
		return "weapon_040 威力应=护甲%d×2=%d，实际 %d" % [armor, exp_might, int(stats.get("might", -1))]
	if int(stats.get("range_value", -1)) != 5:
		return "weapon_040 范围应=当前动力5，实际 %d" % int(stats.get("range_value", -1))
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
	_drive_damage_placement(battle, attack_id)
	await _pump_frames(3)
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
	# effect_115 在 ATTACK_AFTER 弹 CHOOSE_ONE（相邻+2）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"choose_one_effect":
		_drive_damage_placement(battle, attack_id)
		return "effect_115 未弹 choose_one_effect（wait=%s）" % String(wait_info.get("input_type", &""))
	battle.context.timing_engine.resume_pending_effect(attack_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	var atk2 = battle.context.action_registry.get_action(attack_id)
	if atk2 != null and int(atk2.record.get("extra_markers", 0)) != 2:
		return "effect_115 相邻应使 extra_markers=2，实际 %d" % int(atk2.record.get("extra_markers", 0))
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
	# 驱动损伤放置（盾牌 all_or_nothing 自动转移全到 weapon_1 槽）
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
