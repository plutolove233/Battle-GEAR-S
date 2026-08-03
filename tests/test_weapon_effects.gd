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
