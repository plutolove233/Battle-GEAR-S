extends RefCounted

## test_multi_target_attack.gd - 多目标攻击（双连）fork 机制验证
##
## 双连(action_005)：主攻击只发 ATTACK_BEFORE/PRE，在 ATTACK_AT 步 fork 出多个"复制攻击"
## 子动作（深拷贝主攻击 record 快照），每个复制攻击单目标走完整 AT->AFTER->SETTLE。
## 主攻击不发 ATTACK_AT/AFTER/SETTLE。机制按 target_count 参数可扩展到 3+ 目标。
##
## 覆盖：
##   1. 基本：双连打 2 台机甲，各自独立命中掉血；主攻击 record 无 hit/damage（未走命中/伤害步）。
##   2. 单目标退化：双连只选 1 个目标（target_ids.size()==1）-> 不 fork，走普通单目标攻击。
##   3. 衰减武器单次：weapon_014 等离子螺旋矛 用双连打 2 目标，衰减只触发 1 次（-4 而非 -8）。
##      验证"记录攻击次数来发动效果的都在 PRE 时记录次数"规则：effect_112b 在 ATTACK_PRE 记录
##      count=1，各复制 ATTACK_SETTLE 消费（首个 -4 清零，后续 -0）。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")


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


## 把指定 card_def_id 的行动牌塞入玩家手牌，返回 card_instance_id
func _ensure_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


## 在任意位置找装备牌并强制移入玩家装备手牌
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


## 创建第 2 台敌方机甲（敌方阵营），放在指定位置，6 个部件槽位（无装备，护甲=0）。
func _create_second_enemy(battle: BattleState, mech_id: StringName, pos: Dictionary) -> MechState:
	var gs = battle.context.game_state
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = &"enemy"
	m.max_hp = 25
	m.current_hp = 25
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		m.slots[slot_id] = s
	gs.mechs[m.mech_id] = m
	return m


## 驱动 attack 的损伤设置效果动作完成（复用自 test_flash_real_flow 的同款 helper）。
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
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
	return {"ok": true}


## 找到主攻击动作（use_action_card 的 attack 类型子动作）
func _find_main_attack(battle: BattleState) -> StringName:
	var ar = battle.context.action_registry
	for aid in ar.get_active_ids():
		var a = ar.get_action(aid)
		if a and a.action_type == &"attack":
			return aid
	return &""


## 找到主攻击当前 pending 的复制攻击（attack 类型子动作）id
func _find_pending_fork(battle: BattleState, main_attack) -> StringName:
	var ar = battle.context.action_registry
	for fid: StringName in main_attack.pending_effect_action_ids:
		var sub = ar.get_action(fid)
		if sub != null and sub.action_type == &"attack":
			return fid
	return &""


## 驱动一个复制攻击完成（损伤放置 + 同步通知主攻击恢复）。
## 返回下一个 fork id（若主攻击又派生了新复制攻击），否则 &""。
func _drive_fork_and_notify(battle: BattleState, fork_id: StringName, main_attack_id: StringName) -> StringName:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var ret: Dictionary = _drive_damage_placement(battle, fork_id)
	if not ret.get("ok", false):
		return &"__err__"
	# fork 完成靠 call_deferred 通知主攻击；测试同步模式手动同步通知
	ae.notify_effect_action_completed(fork_id, main_attack_id)
	# 主攻击恢复后可能派生下一个复制攻击（_continue_fork_attacks -> _create_next_fork）
	var main_attack = ar.get_action(main_attack_id)
	if main_attack == null:
		return &""  # 主攻击已整体完成（队列空）
	return _find_pending_fork(battle, main_attack)


# ═══════════════════════════════════════════
# 基本：双连打 2 台机甲，各自独立命中掉血
# ═══════════════════════════════════════════
func test_multi_target_dual_strike_hits_both() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"

	# 第 2 台敌方机甲放在玩家相邻格（玩家(2,2) 的另一侧）
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 2, "r": 3})
	# enemy1 放在玩家相邻格
	enemy_mech.position = {"q": 3, "r": 2}

	# 清空地形（避免绿/红格干扰射程）+ 敌方迎击牌（避免 ATTACK_AT 响应窗口拦截）
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	# 双连牌塞入玩家手牌
	var dual_id = _ensure_card_in_hand(battle, "action_005_双连")
	if dual_id == &"":
		return "牌堆/弃牌堆中找不到 双连"

	# 玩家基础武器
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]

	var enemy1_hp_before: int = enemy_mech.current_hp
	var enemy2_hp_before: int = enemy2_mech.current_hp

	# 真实打出双连 -> use_action_card 暂停（等 attack A 选武器）
	battle.execute_use_action_card(&"player", dual_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a_id := _find_main_attack(battle)
	if attack_a_id == &"":
		return "找不到主攻击动作"
	var attack_a = ar.get_action(attack_a_id)

	# 选武器
	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	# 选 2 个目标
	ae.continue_action(attack_a_id, {"target_ids": [enemy_mech.mech_id, enemy2_mech.mech_id]})

	# 主攻击应在 fork 分支暂停（waiting_effect_action），且 record 无 hit/damage（未走命中/伤害步）
	if String(attack_a.state) != &"waiting_effect_action":
		return "主攻击应在 fork 后暂停 waiting_effect_action，实际 state=%s" % String(attack_a.state)
	if attack_a.record.has("hit") or attack_a.record.has("damage"):
		return "主攻击不应走命中/伤害步（record 不应有 hit/damage）"

	# 派生并驱动 fork1（enemy1）：先驱动损伤设置（fork1 完成，但主攻击靠 deferred 通知尚未恢复，
	# 故 fork2 尚未创建），再校验 enemy2 未受影响，最后手动通知主攻击派生 fork2。
	var fork1_id := _find_pending_fork(battle, attack_a)
	if fork1_id == &"":
		return "未派生第 1 个复制攻击"
	var fork1 = ar.get_action(fork1_id)
	if String(fork1.record.get("target_id", &"")) != String(enemy_mech.mech_id):
		return "fork1 目标应为 enemy1，实际=%s" % String(fork1.record.get("target_id", &""))
	var drive_ret1: Dictionary = _drive_damage_placement(battle, fork1_id)
	if not drive_ret1.get("ok", false):
		return "fork1 损伤设置驱动失败"
	# enemy1 应已掉血
	if enemy_mech.current_hp >= enemy1_hp_before:
		return "fork1 应对 enemy1 造成伤害，前=%d 后=%d" % [enemy1_hp_before, enemy_mech.current_hp]
	# enemy2 此时不应受影响（fork2 尚未创建）
	if enemy2_mech.current_hp != enemy2_hp_before:
		return "fork1 不应影响 enemy2，前=%d 后=%d" % [enemy2_hp_before, enemy2_mech.current_hp]
	# 通知主攻击 fork1 完成 -> 派生 fork2（fork2 的 hp_change 会立即扣 enemy2 HP）
	ae.notify_effect_action_completed(fork1_id, attack_a_id)
	var fork2_id := _find_pending_fork(battle, attack_a)
	if fork2_id == &"":
		return "fork1 完成后应派生 fork2"
	var fork2 = ar.get_action(fork2_id)
	if String(fork2.record.get("target_id", &"")) != String(enemy2_mech.mech_id):
		return "fork2 目标应为 enemy2，实际=%s" % String(fork2.record.get("target_id", &""))

	# 驱动 fork2（enemy2）
	var drive_ret2: Dictionary = _drive_damage_placement(battle, fork2_id)
	if not drive_ret2.get("ok", false):
		return "fork2 损伤设置驱动失败"
	# enemy2 应已掉血
	if enemy2_mech.current_hp >= enemy2_hp_before:
		return "fork2 应对 enemy2 造成伤害，前=%d 后=%d" % [enemy2_hp_before, enemy2_mech.current_hp]
	# 通知主攻击 fork2 完成 -> 队列空 -> 主攻击整体完成
	ae.notify_effect_action_completed(fork2_id, attack_a_id)
	# attack_a 应已完成（_continue_fork_attacks 队列空 -> _complete_action -> cleanup 移出注册表）
	attack_a = ar.get_action(attack_a_id)
	if attack_a != null and attack_a.state != &"completed":
		return "主攻击应在 fork2 完成后整体完成，state=%s" % String(attack_a.state)
	return true


# ═══════════════════════════════════════════
# 单目标退化：双连只选 1 个目标 -> 不 fork，走普通单目标攻击
# ═══════════════════════════════════════════
func test_multi_target_dual_strike_single_target_no_fork() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"
	enemy_mech.position = {"q": 3, "r": 2}
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var dual_id = _ensure_card_in_hand(battle, "action_005_双连")
	if dual_id == &"":
		return "找不到 双连"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]
	var enemy_hp_before: int = enemy_mech.current_hp

	battle.execute_use_action_card(&"player", dual_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a_id := _find_main_attack(battle)
	if attack_a_id == &"":
		return "找不到主攻击动作"
	var attack_a = ar.get_action(attack_a_id)
	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	# 只提交 1 个目标（target_ids.size()==1）：不应 fork，走普通单目标攻击
	ae.continue_action(attack_a_id, {"target_ids": [enemy_mech.mech_id]})

	# 单目标不应 fork：主攻击自身走完整流程（命中/伤害步），pending 中无 attack 类型复制攻击
	# （pending 会有 damage_change 损伤设置子动作，那是正常的，不是 fork）
	if _find_pending_fork(battle, attack_a) != &"":
		return "单目标不应派生 fork（复制攻击）"
	# 主攻击应走命中步（record 有 hit）--fork 路径不会写 hit
	if not attack_a.record.has("hit"):
		return "单目标主攻击应走命中步（record 有 hit）"
	# 驱动损伤设置（主攻击自身的 damage_change）
	var drive_ret: Dictionary = _drive_damage_placement(battle, attack_a_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "单目标损伤设置驱动失败")
	# enemy 应已掉血
	if enemy_mech.current_hp >= enemy_hp_before:
		return "单目标双连应对 enemy 造成伤害，前=%d 后=%d" % [enemy_hp_before, enemy_mech.current_hp]
	return true


# ═══════════════════════════════════════════
# 衰减武器单次：weapon_014 等离子螺旋矛 用双连打 2 目标，威力只衰减 1 次（-4 而非 -8）
# ═══════════════════════════════════════════
func test_multi_target_decay_weapon_decays_once() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 2, "r": 3})
	enemy_mech.position = {"q": 3, "r": 2}
	# weapon_014 威力 24，提升敌方 HP 避免被摧毁触发战斗结束中断流程
	enemy_mech.max_hp = 100
	enemy_mech.current_hp = 100
	enemy2_mech.max_hp = 100
	enemy2_mech.current_hp = 100
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	# 装备 weapon_014 等离子螺旋矛（衰减型武器，effect_112+effect_112b）
	var w014_id := _force_equipment_to_hand(battle, "weapon_014_等离子螺旋矛")
	if w014_id == &"":
		return "找不到 weapon_014"
	var set_ret: Dictionary = battle.context.card_set_service.set_equipment(&"player", w014_id, &"weapon_1")
	if not set_ret.get("ok", false):
		return "装备 weapon_014 失败"
	# 装备效果注册需帧 flush
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		for _i in 3:
			await tree.process_frame

	var dual_id = _ensure_card_in_hand(battle, "action_005_双连")
	if dual_id == &"":
		return "找不到 双连"
	# 用 weapon_014 作为攻击武器（而非基础武器）
	var weapon_id: StringName = w014_id
	var enemy1_hp_before: int = enemy_mech.current_hp
	var enemy2_hp_before: int = enemy2_mech.current_hp

	# 记录 weapon_014 装备后的有效威力（衰减前）
	var w014_card = gs.get_card(w014_id)
	var power_before: int = int(_GenEquipEffects.get_effective_weapon_stats(w014_card).get("might", 0))

	battle.execute_use_action_card(&"player", dual_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a_id := _find_main_attack(battle)
	if attack_a_id == &"":
		return "找不到主攻击动作"
	var attack_a = ar.get_action(attack_a_id)
	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	ae.continue_action(attack_a_id, {"target_ids": [enemy_mech.mech_id, enemy2_mech.mech_id]})

	# 驱动 fork1
	var fork1_id := _find_pending_fork(battle, attack_a)
	if fork1_id == &"":
		return "未派生 fork1"
	var next_after_fork1 := _drive_fork_and_notify(battle, fork1_id, attack_a_id)
	if next_after_fork1 == &"__err__":
		return "fork1 损伤设置驱动失败"
	if enemy_mech.current_hp >= enemy1_hp_before:
		return "fork1 应对 enemy1 造成伤害"

	# 驱动 fork2
	if next_after_fork1 == &"":
		return "应派生 fork2"
	var next_after_fork2 := _drive_fork_and_notify(battle, next_after_fork1, attack_a_id)
	if next_after_fork2 == &"__err__":
		return "fork2 损伤设置驱动失败"
	if enemy2_mech.current_hp >= enemy2_hp_before:
		return "fork2 应对 enemy2 造成伤害"

	# 验证 weapon_014 威力只衰减 1 次（-4），而非 2 次（-8）
	w014_card = gs.get_card(w014_id)
	if w014_card == null:
		return "weapon_014 卡牌实例丢失"
	var power_after: int = int(_GenEquipEffects.get_effective_weapon_stats(w014_card).get("might", 0))
	var decay: int = power_before - power_after
	if decay != 4:
		return "weapon_014 应只衰减 1 次（-4），实际衰减=%d（before=%d after=%d）" % [decay, power_before, power_after]
	return true


## 把一张迎击牌照常塞入 enemy 手牌，但绑定到指定 mech_id（手动注册 AVAILABILITY）。
## register_hand_card_availability 会把 mech_id 覆盖为玩家第一台机甲，故对第2台机甲需手动注册。
func _ensure_counter_for_mech(battle: BattleState, card_def_id: String, mech_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"enemy")
	if player == null:
		return &""
	var cid: StringName = &""
	for i in range(gs.deck_state.action_deck.size()):
		var d_cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(d_cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			cid = d_cid
			break
	if cid == &"":
		for i in range(gs.deck_state.action_discard_pile.size()):
			var d_cid: StringName = gs.deck_state.action_discard_pile[i]
			var c = gs.get_card(d_cid)
			if c and c.def and c.def.card_id == card_def_id:
				gs.deck_state.action_discard_pile.remove_at(i)
				cid = d_cid
				break
	if cid == &"":
		return &""
	player.action_hand.append(cid)
	var card = gs.get_card(cid)
	card.zone = &"action_hand"
	card.owner_player_id = &"enemy"
	card.mech_id = mech_id
	# 手动注册 AVAILABILITY 监听器到该机甲
	var mappings: Array = _GeneratedActionEffects.get_effects_for_card(card_def_id)
	var all_effects: Dictionary = _GeneratedActionEffects.build_all_effects()
	for mapping in mappings:
		var effect_id: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
		var effect = all_effects.get(effect_id)
		if effect != null and effect.mode == "AVAILABILITY":
			var timing: StringName = effect.listen_timing if effect.listen_timing != &"" else _TimingConst.ATTACK_AT
			battle.context.timing_engine.register_availability_listener(timing, &"", effect, cid)
	return cid


# ═══════════════════════════════════════════
# fork 响应窗口：双连 fork 攻击持有迎击牌的机甲时，应在 fork 的 ATTACK_AT 弹响应窗口
# 问题4：双连先攻击另一台机甲时，那台的响应窗口不弹。本测试验证 fork1（先攻击目标）
# 的 ATTACK_AT 是否 fire 响应窗口（has_response_window=true）。
# 注：测试模式 enemy 为 AI，会自动响应（state 变 waiting_effect_action），
# 故断言 has_response_window 而非 waiting_timing（后者仅人类玩家场景）。
# ═══════════════════════════════════════════
func test_multi_target_fork_response_window() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"
	# 第 2 台敌方机甲放在玩家相邻格
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 2, "r": 3})
	enemy_mech.position = {"q": 3, "r": 2}
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	# 清空敌方原有迎击牌
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()
	# 给 enemy1（先攻击目标=fork1）塞一张反击牌并注册 AVAILABILITY
	# enemy1 是教程默认 enemy_mech，register_hand_card_availability 绑到它
	var counter_e1 := _ensure_counter_for_mech(battle, "action_010_反击", enemy_mech.mech_id)
	if counter_e1 == &"":
		return "无法给 enemy1 塞反击牌"

	var dual_id = _ensure_card_in_hand(battle, "action_005_双连")
	if dual_id == &"":
		return "找不到 双连"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]

	# 真实打出双连 -> 选武器 -> 选 2 个目标（enemy1 先=fork1，enemy2 后=fork2）
	battle.execute_use_action_card(&"player", dual_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a_id := _find_main_attack(battle)
	if attack_a_id == &"":
		return "找不到主攻击动作"
	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	ae.continue_action(attack_a_id, {"target_ids": [enemy_mech.mech_id, enemy2_mech.mech_id]})

	# fork1=enemy1（有反击牌）：ATTACK_AT 应 fire 响应窗口
	var fork1_id := _find_pending_fork(battle, ar.get_action(attack_a_id))
	if fork1_id == &"":
		return "未派生 fork1"
	var fork1 = ar.get_action(fork1_id)
	if String(fork1.record.get("target_id", &"")) != String(enemy_mech.mech_id):
		return "fork1 目标应为 enemy1，实际=%s" % String(fork1.record.get("target_id", &""))
	# fork1 的 ATTACK_AT 应 fire 响应窗口（has_response_window=true）
	# AI（enemy）会自动响应，state 变 waiting_effect_action（迎击牌子动作执行中）；
	# 人类玩家场景会停在 waiting_timing 弹窗口。两者都证明窗口已开。
	var has_rw: bool = bool(fork1.record.get("has_response_window", false))
	if not has_rw:
		return "fork1 ATTACK_AT 应 fire 响应窗口（has_response_window=true），实际 state=%s csi=%d" % [String(fork1.state), fork1.current_step_index]
	# 验证 fork1 的响应窗口 available_cards 含 enemy1 的反击牌（fire 时收集，存于 record）
	var rw_cards: Array = fork1.record.get("response_available_cards", [])
	var has_counter := false
	for entry in rw_cards:
		if StringName(entry.get("card_instance_id", &"")) == counter_e1:
			has_counter = true
			break
	if not has_counter:
		return "fork1 响应窗口应含 enemy1 的反击牌，available=%d 条" % rw_cards.size()
	return true
