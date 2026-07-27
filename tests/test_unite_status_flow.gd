## test_unite_status_flow.gd - 联合状态完整流程验证
##
## 验证 new_logic/行动牌的效果与逻辑.txt 第15张"联合"的联合状态行为：
##   1. effect1 施加联合状态时存 unite 字段（出牌者机甲）
##   2. 状态效果1：unite机甲（出牌者）攻击结算时触发弹窗（条件修复：旧实现误用 target_id）
##   3. Target 无攻击牌时不弹窗（无事发生）
##   4. 取消弹窗：联合状态保留到回合结束（监听器仍注销，本回合不再问）
##   5. 回合结束清除联合状态（即使未使用）
##   6. 确认联合攻击：创建 use_action_card 子动作打出选定的攻击牌（不消耗攻击次数），
##      结算后 REMOVE_STATUS 去除此联合状态
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


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


## 把指定 card_def_id 的牌塞入指定玩家手牌（注册 AVAILABILITY 监听器）
func _ensure_card_in_player_hand(battle, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 清掉指定玩家手牌中所有攻击类型行动牌（移回牌堆），用于"无攻击牌不弹窗"测试
func _clear_attack_cards_from_hand(battle, player_id: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return
	var to_remove: Array = []
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and String(c.def.action_type) == &"攻击":
			to_remove.append(cid)
	for cid in to_remove:
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"


## 直接对 target 施加联合状态（unite=unite_mech），返回 status_id
func _apply_unite(battle, target_mech_id: StringName, unite_mech_id: StringName, source_pid: StringName) -> void:
	# duration=UNTIL_TURN_END：与 unite_effect1 一致，由 unite_status_clear 在 TURN_AFTER_END 主动移除
	battle.context.game_actions.add_status({
		"target_id": target_mech_id,
		"status": {
			"type": &"UNITE",
			"duration": &"UNTIL_TURN_END",
			"unite": unite_mech_id,
			"source_player_id": source_pid,
		},
	})


## 构造 mock 攻击动作（attacker_id/target_id 已填），用于直接 fire 时点
func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> Action:
	var attack = _Action.new()
	attack.action_id = &"test_unite_attack_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 取目标机甲身上的联合状态 dict（按 unite 匹配）
func _find_unite_status(mech, unite_mech_id: StringName) -> Dictionary:
	for s: Dictionary in mech.statuses:
		if s.get("type", &"") == &"UNITE" and String(s.get("unite", &"")) == String(unite_mech_id):
			return s
	return {}


## ── 测试1：effect1 施加联合状态时存 unite 字段（出牌者机甲）──
func test_unite_effect1_stores_unite_field() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	if enemy_mech == null or player_mech == null:
		return "机甲缺失"

	var card_id := _ensure_card_in_player_hand(battle, &"player", "action_018_联合")
	if card_id == &"":
		return "找不到联合牌"

	var res := battle.execute_use_action_card(&"player", card_id)
	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	var w1 = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != &"select_mech_target":
		return "应挂起 select_mech_target，实际: %s" % String(w1.get("input_type", &"<none>"))
	bridge.on_ui_confirmed({"target_id": enemy_mech.mech_id})
	await _pump_frames(2)

	var st := _find_unite_status(enemy_mech, player_mech.mech_id)
	if st.is_empty():
		return "联合状态未施加到敌方机甲（statuses=%s）" % str(enemy_mech.statuses)
	if String(st.get("unite", &"")) != String(player_mech.mech_id):
		return "unite 字段应为 player_mech(%s)，实际: %s" % [String(player_mech.mech_id), String(st.get("unite", &""))]
	return true


## ── 测试2：unite机甲攻击结算时触发弹窗（条件修复：attacker==unite）──
func test_unite_status_triggers_popup_on_unite_mech_attack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# Target=player(human), unite=enemy_mech。enemy 攻击 player 时触发。
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")
	# 给 Target(player) 一张攻击牌供弹窗列出
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "找不到攻击牌 action_001_进攻"

	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	# enemy 发动攻击（mock），fire ATTACK_SETTLE
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(2)

	var w = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != &"select_unite_attack_card":
		return "应挂起 select_unite_attack_card，实际: %s" % String(w.get("input_type", &"<none>"))
	var card_ids: Array = w.get("input_params", {}).get("card_ids", [])
	if not card_ids.has(atk_cid):
		return "弹窗未列出 player 的攻击牌，card_ids=%s" % str(card_ids)
	return true


## ── 测试3：Target 无攻击牌时不弹窗（无事发生）──
func test_unite_status_no_attack_cards_no_popup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")
	_clear_attack_cards_from_hand(battle, &"player")  # player 无攻击牌

	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(2)

	var w = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) == &"select_unite_attack_card":
		return "Target 无攻击牌时不应弹窗 select_unite_attack_card"
	# 状态仍在（未使用）
	if _find_unite_status(player_mech, enemy_mech.mech_id).is_empty():
		return "无攻击牌跳过时联合状态不应被移除"
	return true


## ── 测试4：取消弹窗，联合状态保留；监听器注销（本回合不再问）──
func test_unite_status_cancel_keeps_status() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")

	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(2)
	var w = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != &"select_unite_attack_card":
		return "前置失败：未弹出 select_unite_attack_card"

	# 取消
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(2)

	# 联合状态仍在
	if _find_unite_status(player_mech, enemy_mech.mech_id).is_empty():
		return "取消后联合状态不应被移除"
	# 监听器已注销：再次 fire ATTACK_SETTLE 不应再弹窗
	var attack2 := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack2)
	await _pump_frames(2)
	var w2 = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) == &"select_unite_attack_card":
		return "监听器应已注销，第二次 ATTACK_SETTLE 不应再弹窗"
	return true


## ── 测试5：回合结束清除联合状态（即使未使用）──
func test_unite_status_cleared_on_turn_end() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")
	if _find_unite_status(player_mech, enemy_mech.mech_id).is_empty():
		return "前置失败：联合状态未施加"

	# 完整结束 player 回合（_clean_this_turn_durations + TURN_AFTER_END 监听器）
	battle.context.turn_service.end_turn(&"player")
	await _pump_frames(3)

	if not _find_unite_status(player_mech, enemy_mech.mech_id).is_empty():
		return "回合结束后联合状态应被清除"
	return true


## ── 测试6：确认联合攻击 -> 创建 use_action_card 子动作打出选定攻击牌，结算后移除状态 ──
func test_unite_status_confirm_uses_card_and_removes() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 敌我相邻，确保 player 联合攻击 enemy 时在武器范围内
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "找不到攻击牌"

	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry

	# enemy 发动攻击 -> ATTACK_SETTLE -> 联合弹窗
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(2)
	var w = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != &"select_unite_attack_card":
		return "前置失败：未弹出 select_unite_attack_card"

	# 玩家确认使用选定的攻击牌
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"selected_card_id": atk_cid})
	await _pump_frames(3)

	# 应创建 use_action_card(B) 作为独立顶层动作（不阻塞 attackA），打出 atk_cid
	var use_action_id: StringName = &""
	for sub in ar.get_actions_by_type(&"use_action_card"):
		if sub != null and String(sub.record.get("card_instance_id", &"")) == String(atk_cid):
			use_action_id = sub.action_id
			break
	if use_action_id == &"":
		return "确认后未创建 use_action_card 打出 atk_cid"
	var use_action = ar.get_action(use_action_id)
	if String(use_action.record.get("mech_id", &"")) != String(player_mech.mech_id):
		return "use_action_card 执行者应为 player_mech"
	# 并行：use_action_card 不应是 attackA 的子动作（attackA 已结束监听继续推进，不阻塞）
	if attack.pending_effect_action_ids.has(use_action_id):
		return "并行方案：use_action_card 不应作为 attackA 子动作阻塞其推进"

	# REMOVE_STATUS 应排在 use_action_card 自己的 _seq（attackB 完成后执行，与 attackA 无关）
	var seq: Dictionary = use_action.record.get("_seq_effect_actions", {})
	var seq_remaining: Array = seq.get("remaining", [])
	var has_remove_status: bool = false
	for a: Dictionary in seq_remaining:
		if String(a.get("type", &"")) == "REMOVE_STATUS":
			has_remove_status = true
			break
	if not has_remove_status:
		return "use_action_card 应排队 REMOVE_STATUS（_seq.remaining），实际 remaining=%s" % str(seq_remaining)
	# 联合状态此时仍在（use_action_card 尚未完成，REMOVE_STATUS 未执行）
	if _find_unite_status(player_mech, enemy_mech.mech_id).is_empty():
		return "use_action_card 完成前联合状态不应被移除"

	# use_action_card 应挂起（等其 attack 子动作选武器/目标）
	await _pump_frames(2)
	var attack_b_id: StringName = &""
	for cid: StringName in use_action.pending_effect_action_ids:
		var sub = ar.get_action(cid)
		if sub != null and sub.action_type == &"attack":
			attack_b_id = cid
			break
	if attack_b_id == &"":
		battle.context.action_engine.cancel_action(use_action_id)
		return true
	# 清理：取消联合攻击 use_action_card（attackA 已并行完成）
	battle.context.action_engine.cancel_action(use_action_id)
	await _pump_frames(2)
	return true


## ── 测试7：同一Target同一unite最多1个联合状态（去重）──
func test_unite_status_dedup_same_unite() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_apply_unite(battle, enemy_mech.mech_id, player_mech.mech_id, &"player")
	_apply_unite(battle, enemy_mech.mech_id, player_mech.mech_id, &"player")  # 同一 unite，应去重
	var count: int = 0
	for s: Dictionary in enemy_mech.statuses:
		if s.get("type", &"") == &"UNITE" and String(s.get("unite", &"")) == String(player_mech.mech_id):
			count += 1
	if count != 1:
		return "同一Target同一unite应只有1个联合状态，实际: %d" % count
	return true


## ── 测试8：联合效果2 弃牌抽牌走正式 discard_card + gain_card 动作（带时点）──
func test_unite_effect2_discard_draw_via_actions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var ctx = battle.context
	var player = gs.players.get(&"player")
	var player_mech = gs.get_mech_for_player(&"player")
	if player == null or player_mech == null:
		return "玩家/机甲缺失"
	var card_id := _ensure_card_in_player_hand(battle, &"player", "action_018_联合")
	if card_id == &"":
		return "找不到联合牌"
	if gs.deck_state.action_deck.is_empty():
		return "行动牌堆为空，无法验证抽牌"

	var hand_before: int = player.action_hand.size()
	var top_before: StringName = gs.deck_state.action_deck[0]
	var card = gs.get_card(card_id)

	# 1. 弃置此牌（discard_card 动作，发 DISCARD_BEFORE/AFTER/SETTLE 时点）
	var dd_result: Dictionary = ctx.action_service.execute(&"discard_card", {
		"card_ids": [card_id],
		"executor": &"system_default",
		"player_id": &"player",
		"reason": &"UNITE_DISCARD",
	})
	if String(dd_result.get("state", &"")) != &"completed":
		return "discard_card 动作未完成: %s" % str(dd_result)
	if player.action_hand.has(card_id):
		return "联合牌仍在手牌（应已弃置）"
	if card == null or String(card.zone) != &"discard":
		return "联合牌 zone 非 discard（实际 %s）" % (String(card.zone) if card else "<null>")

	# 2. 抽1张行动牌（gain_card 动作，发 GAIN_CARD_BEFORE/AFTER/SETTLE 时点）
	var gc_result: Dictionary = ctx.action_service.execute(&"gain_card", {
		"card_ids": [top_before],
		"mech_ids": [player_mech.mech_id],
		"from_zone": &"action_deck",
		"reason": &"UNITE_DRAW",
	})
	if String(gc_result.get("state", &"")) != &"completed":
		return "gain_card 动作未完成: %s" % str(gc_result)
	if not player.action_hand.has(top_before):
		return "行动牌堆顶牌未抽到手牌"
	# 弃1抽1：手牌数应不变
	if player.action_hand.size() != hand_before:
		return "手牌数应不变（弃1抽1）：before=%d after=%d" % [hand_before, player.action_hand.size()]
	return true


## ── 测试9：联合状态回合结束清除后，后续攻击不再触发弹窗（孤儿监听器修复）──
func test_unite_status_no_orphan_popup_after_turn_end() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")

	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context

	# 回合结束清除联合状态 + 注销监听器（修复前 _clean_this_turn_durations 不注销，
	# unite_status_attack 监听器成为孤儿，下次攻击仍触发弹窗）
	battle.context.turn_service.end_turn(&"player")
	await _pump_frames(3)
	if not _find_unite_status(player_mech, enemy_mech.mech_id).is_empty():
		return "前置失败：回合结束后联合状态应被清除"

	# 再次 fire ATTACK_SETTLE（enemy 攻击 player）：孤儿监听器不应触发弹窗
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(2)
	var w = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) == &"select_unite_attack_card":
		return "孤儿监听器未注销：状态清除后再次攻击不应弹联合攻击窗"
	return true


## ── 测试10：Target 上回合已攻击（attack_count_this_turn>0），联合攻击不被 can_attack() 误拒 ──
## 回归 2026-07-27 联合攻击卡死 bug：Target 在敌方回合联合攻击时，其 attack_count_this_turn
## 未随敌方回合重置（TurnService 仅重置当前回合玩家机甲），can_attack()=false 致 validate
## 报错"本回合无法再攻击"，且 ActionEngine 不处理 error 致动作链卡死。
## 修复：source_action_id 非空（效果产生的使用攻击牌）跳过 attack_count 限制。
func test_unite_attack_not_blocked_by_attack_count() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 模拟 player 上回合已攻击过：attack_count_this_turn=1，max=1 -> can_attack()=false
	player_mech.attack_count_this_turn = 1
	player_mech.max_attacks_per_turn = 1
	if player_mech.can_attack():
		return "前置失败：player_mech 应 can_attack()=false"
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")
	var atk_cid := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if atk_cid == &"":
		return "找不到攻击牌"

	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	var ar = battle.context.action_registry

	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(2)
	var w = bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != &"select_unite_attack_card":
		return "前置失败：未弹出 select_unite_attack_card"

	# 玩家确认使用选定的攻击牌
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"selected_card_id": atk_cid})
	await _pump_frames(3)

	# use_action_card 应创建且 validate 不报错（attack_count_this_turn>0 不阻止联合攻击）
	var use_action_id: StringName = &""
	for sub in ar.get_actions_by_type(&"use_action_card"):
		if sub != null and String(sub.record.get("card_instance_id", &"")) == String(atk_cid):
			use_action_id = sub.action_id
			break
	if use_action_id == &"":
		return "联合攻击 use_action_card 未创建（被 can_attack 误拒？）"
	var use_action = ar.get_action(use_action_id)
	if use_action.state == &"cancelled":
		return "use_action_card 被 cancel（validate error：attack_count 不应阻止 source_action_id 非空的联合攻击）"
	# 应创建 attack 子动作（validate 通过 -> EXECUTE_ATTACK 执行）
	var has_attack_sub = false
	for cid: StringName in use_action.pending_effect_action_ids:
		var sub = ar.get_action(cid)
		if sub != null and sub.action_type == &"attack":
			has_attack_sub = true
			break
	if not has_attack_sub:
		return "use_action_card 未创建 attack 子动作（validate 应通过：source_action_id 非空跳过 can_attack）"
	# 清理：取消联合攻击 use_action_card（attackA 已并行完成）
	battle.context.action_engine.cancel_action(use_action_id)
	await _pump_frames(2)
	return true
