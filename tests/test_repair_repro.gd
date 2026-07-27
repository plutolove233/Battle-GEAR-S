## test_repair_repro.gd — 维修牌打出复现测试
##
## 复现"维修牌没有任何用"：构造玩家手牌含维修，直接 execute_use_action_card，
## 打印每一步动作状态/挂起类型/record，定位卡点在目标选择/二选一/子动作执行哪一步。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")


## 等一帧，flush call_deferred 排入的动作恢复（-s 模式靠 SceneTree 主循环）。
func _frame() -> void:
	var ml = Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


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


func _ensure_card_in_hand(battle, card_def_id: String) -> StringName:
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
	return &""


func test_repair_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"

	var gs = battle.context.game_state
	# 确保是玩家回合
	gs.active_player_id = &"player"

	# 给玩家机甲造成损伤与掉血，便于验证"移除损伤/回复4生命"
	var pmech = gs.get_mech_for_player(&"player")
	if pmech == null:
		return "找不到玩家机甲"
	var hp_before = pmech.current_hp
	pmech.current_hp = max(1, pmech.current_hp - 5)  # 掉5血，留出回复4空间
	# 给一个槽放3损伤，便于验证"移除2损伤"（优先有装备的槽，否则任意槽）
	var dmg_slot_id: StringName = &""
	for slot_id in pmech.slots:
		var slot = pmech.slots[slot_id]
		if slot and slot.equipped_card:
			slot.region_damage_tokens = 3
			dmg_slot_id = slot_id
			break
	if dmg_slot_id == &"":
		# 兜底：取第一个有 region_damage_tokens 字段的槽
		for slot_id in pmech.slots:
			var slot = pmech.slots[slot_id]
			if slot:
				slot.region_damage_tokens = 3
				dmg_slot_id = slot_id
				break
	print("[REPRO] 初始设置损伤 slot=%s tokens=3" % dmg_slot_id)

	var card_id := _ensure_card_in_hand(battle, "action_013_维修")
	if card_id == &"":
		return "找不到维修牌（action_013_维修）"

	# 先看 GeneratedActionEffects 是否为维修牌注册了 DIRECT 效果
	var mappings = _GeneratedActionEffects.get_effects_for_card("action_013_维修")
	print("[REPRO] 维修牌 effect mappings = ", mappings)
	if mappings.is_empty():
		return "GeneratedActionEffects 未为 action_013_维修 注册任何效果 → 这就是根因"

	# 直接执行 use_action_card（模拟玩家点了"确定使用"）
	var res := battle.execute_use_action_card(&"player", card_id)
	print("[REPRO] execute_use_action_card 返回 = ", res)

	var bridge = battle.context.action_ui_bridge
	var te = battle.context.timing_engine

	# 1) 应挂起 select_repair_target
	var w1 = bridge.get_waiting_action_info() if bridge else {}
	print("[REPRO] step1 waiting = ", w1.get("input_type", &"<none>"))
	if w1.get("input_type", &"") != &"select_repair_target":
		return "step1: 未挂起 select_repair_target，而是 %s" % w1.get("input_type", &"<none>")

	# 模拟玩家选自身机甲
	bridge.on_ui_confirmed({"target_id": pmech.mech_id})

	# 2) 应挂起 choose_one_effect
	var w2 = bridge.get_waiting_action_info() if bridge else {}
	print("[REPRO] step2 waiting = ", w2.get("input_type", &"<none>"))
	if w2.get("input_type", &"") != &"choose_one_effect":
		return "step2: 选完目标后未挂起 choose_one_effect（二选一窗口丢失），而是 %s" % w2.get("input_type", &"<none>")

	# 3) 选"回复4生命"（option_0）
	bridge.on_ui_confirmed({"chosen_option_index": 0, "chosen_effect_id": "option_0"})

	var hp_after = pmech.current_hp
	print("[REPRO] 回复分支 HP: before=%d 掉5后=%d after=%d" % [hp_before, hp_before-5, hp_after])
	if hp_after != (hp_before - 5) + 4:
		return "回复4生命未生效：期望 %d，实际 %d" % [(hp_before-5)+4, hp_after]

	# 4) 再打一张维修，测"移除2损伤"分支（option_1）
	var card_id2 := _ensure_card_in_hand(battle, "action_013_维修")
	if card_id2 == &"":
		print("[REPRO] 无第二张维修牌，跳过移除损伤分支")
	else:
		var dmg_before2 = 0
		if dmg_slot_id != &"":
			dmg_before2 = pmech.slots[dmg_slot_id].region_damage_tokens
		print("[REPRO] 第二次维修前，损伤=%d (slot=%s)" % [dmg_before2, dmg_slot_id])
		# 等一帧让上一次 use_action_card 的 deferred settle flush
		await _frame()
		battle.execute_use_action_card(&"player", card_id2)
		bridge.on_ui_confirmed({"target_id": pmech.mech_id})
		var w3 = bridge.get_waiting_action_info() if bridge else {}
		print("[REPRO] step3 waiting = ", w3.get("input_type", &"<none>"))
		if w3.get("input_type", &"") != &"choose_one_effect":
			return "step3: 第二次未挂起 choose_one_effect（实际 %s）" % w3.get("input_type", &"<none>")
		bridge.on_ui_confirmed({"chosen_option_index": 1, "chosen_effect_id": "option_1"})
		# 等一帧让 damage_change 子动作 deferred flush
		await _frame()
		# decrease 现弹损伤框（removal模式）：应挂起 place_damage_tokens 等玩家逐一移除
		var w4 = bridge.get_waiting_action_info() if bridge else {}
		print("[REPRO] step4 waiting = ", w4.get("input_type", &"<none>"))
		if w4.get("input_type", &"") != &"place_damage_tokens":
			return "step4: 移除损伤未挂起 place_damage_tokens（实际 %s）" % w4.get("input_type", &"<none>")
		# executor 应为发起方 player_id（维修使用者），非空--否则 PvP 双端都弹窗、维修作用多次
		var w4_exec: StringName = StringName(w4.get("input_params", {}).get("executor", &""))
		if w4_exec != &"player":
			return "step4: executor 应为发起方 player（实际 %s），为空会导致 PvP 双端都弹窗" % String(w4_exec)
		# 模拟玩家在损伤框逐一移除2个（damage_placement_panel._on_token_clicked 调 remove_damage_tokens）
		battle.context.game_actions.remove_damage_tokens({"mech_id": pmech.mech_id, "slot_id": dmg_slot_id, "amount": 2})
		bridge.on_ui_confirmed({"placed": true})
		await _frame()
		var dmg_after = 0
		if dmg_slot_id != &"":
			dmg_after = pmech.slots[dmg_slot_id].region_damage_tokens
		print("[REPRO] 移除分支 损伤: before2=%d after=%d" % [dmg_before2, dmg_after])
		if dmg_after != dmg_before2 - 2:  # 应减2
			return "移除2损伤未生效：期望 %d，实际 %d" % [dmg_before2-2, dmg_after]

	return true


## 满血+有损伤：CHOOSE_ONE 自动选"移除2损伤"（不弹二选一）
func test_repair_auto_remove_when_full_hp() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	var pmech = gs.get_mech_for_player(&"player")
	if pmech == null:
		return "找不到玩家机甲"
	# 满血 + 有损伤
	pmech.current_hp = pmech.max_hp
	var dmg_slot_id: StringName = &""
	for slot_id in pmech.slots:
		var slot = pmech.slots[slot_id]
		if slot:
			slot.region_damage_tokens = 3
			dmg_slot_id = slot_id
			break
	if dmg_slot_id == &"":
		return "找不到可设损伤的槽位"
	var card_id := _ensure_card_in_hand(battle, "action_013_维修")
	if card_id == &"":
		return "找不到维修牌"
	var bridge = battle.context.action_ui_bridge
	battle.execute_use_action_card(&"player", card_id)
	bridge.on_ui_confirmed({"target_id": pmech.mech_id})
	await _frame()
	# 满血有损伤 -> 自动选"移除2损伤"，不弹二选一，直接挂起 place_damage_tokens
	var w = bridge.get_waiting_action_info() if bridge else {}
	if w.get("input_type", &"") != &"place_damage_tokens":
		return "满血有损伤应自动选移除损伤并挂起 place_damage_tokens（实际 %s）" % w.get("input_type", &"<none>")
	var dmg_before = pmech.slots[dmg_slot_id].region_damage_tokens
	battle.context.game_actions.remove_damage_tokens({"mech_id": pmech.mech_id, "slot_id": dmg_slot_id, "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _frame()
	var dmg_after = pmech.slots[dmg_slot_id].region_damage_tokens
	if dmg_after != dmg_before - 2:
		return "移除2损伤未生效：期望 %d，实际 %d" % [dmg_before-2, dmg_after]
	# HP 应不变（满血目标没回血）
	if pmech.current_hp != pmech.max_hp:
		return "满血目标不应回血：HP 应=%d 实际=%d" % [pmech.max_hp, pmech.current_hp]
	return true


## HP不满+无损伤：CHOOSE_ONE 自动选"回复4生命"（不弹二选一）
func test_repair_auto_heal_when_no_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	var pmech = gs.get_mech_for_player(&"player")
	if pmech == null:
		return "找不到玩家机甲"
	# HP不满 + 无损伤
	pmech.current_hp = max(1, pmech.current_hp - 5)
	var hp_target = pmech.current_hp
	for slot_id in pmech.slots:
		var slot = pmech.slots[slot_id]
		if slot:
			slot.region_damage_tokens = 0
			if slot.equipped_card:
				slot.equipped_card.damage_tokens = 0
	var card_id := _ensure_card_in_hand(battle, "action_013_维修")
	if card_id == &"":
		return "找不到维修牌"
	var bridge = battle.context.action_ui_bridge
	battle.execute_use_action_card(&"player", card_id)
	bridge.on_ui_confirmed({"target_id": pmech.mech_id})
	await _frame()
	# 无损伤HP不满 -> 自动选"回复4生命"，不弹二选一，动作直接完成
	var w = bridge.get_waiting_action_info() if bridge else {}
	if not w.is_empty():
		return "无损伤HP不满应自动选回复生命并完成（不应挂起 %s）" % w.get("input_type", &"<none>")
	if pmech.current_hp != hp_target + 4:
		return "回复4生命未生效：期望 %d，实际 %d" % [hp_target+4, pmech.current_hp]
	return true

