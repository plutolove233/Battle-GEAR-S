## test_awaken_real_flow.gd - 觉醒（action_024_觉醒）效果端到端测试
##
## 验证规格（new_logic/行动牌的效果与逻辑.txt 第23项）：
##   两轮（预判/识破）：弃牌堆有目标牌则取随机1张；否则弹框选1种行动牌，
##   取弃牌堆该种类1张 + 牌堆顶1张。最后获取牌（集合A -> 使用方手牌）。
##
## 旧实现 bug：用 find("predict"/"expose") 匹配英文子串，中文卡ID永不命中 ->
##   "存在"分支永不触发、无弹窗、直接取 discard[0]。本测试覆盖正确分支。
##
## 场景：
##   1. 预判+识破都在弃牌堆 -> 无弹窗，取随机各1张（共2张）
##   2. 都不在弃牌堆、弃牌堆有2张其他牌 -> 两次弹窗，各取弃牌堆1张+牌堆顶1张（共4张）
##   3. 预判在弃牌堆、识破不在 -> 1次弹窗（识破轮），共3张
##   4. 弃牌堆为空 -> 无弹窗，各抽牌堆顶1张（共2张，用户拍板）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")

const PREDICT_DEF := "action_007_预判"
const EXPOSE_DEF := "action_012_识破"
const AWAKEN_DEF := "action_024_觉醒"
const ASSAULT_DEF := "action_002_强袭"
const ATTACK_DEF := "action_001_进攻"


## 推进若干帧，使 call_deferred 排入的恢复调用执行
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


## 在所有区域（牌堆/弃牌堆/手牌）中查找指定 card_def_id 的1个卡实例
func _find_card(battle, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var zones: Array = [gs.deck_state.action_deck, gs.deck_state.action_discard_pile,
		gs.players.get(&"player").action_hand, gs.players.get(&"enemy").action_hand]
	for zone in zones:
		for cid: StringName in zone:
			var c = gs.get_card(cid)
			if c and c.def and c.def.card_id == card_def_id:
				return cid
	return &""


## 把卡从所在区域移除（不改变 zone，由调用方决定去哪）
func _remove_card_from_current(battle, card_id: StringName) -> void:
	var gs = battle.context.game_state
	gs.remove_card_from_all_zones(card_id)


## 把指定 card_def_id 的1张牌移入行动弃牌堆（从牌堆/手牌中取）
func _put_in_discard(battle, card_def_id: String) -> StringName:
	var cid: StringName = _find_card(battle, card_def_id)
	if cid == &"":
		return &""
	_remove_card_from_current(battle, cid)
	var gs = battle.context.game_state
	gs.deck_state.action_discard_pile.append(cid)
	var c = gs.get_card(cid)
	if c:
		c.zone = &"action_discard"
	return cid


## 把指定 card_def_id 的1张牌移到行动牌堆顶（front）
func _put_at_deck_top(battle, card_def_id: String) -> StringName:
	var cid: StringName = _find_card(battle, card_def_id)
	if cid == &"":
		return &""
	_remove_card_from_current(battle, cid)
	var gs = battle.context.game_state
	gs.deck_state.action_deck.push_front(cid)
	var c = gs.get_card(cid)
	if c:
		c.zone = &"action_deck"
	return cid


## 清空行动弃牌堆（把其中卡牌放回牌堆底，避免丢失）
func _clear_action_discard(battle) -> void:
	var gs = battle.context.game_state
	var pile: Array = gs.deck_state.action_discard_pile
	while not pile.is_empty():
		var cid: StringName = pile.pop_back()
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"


## 确保觉醒牌在玩家手牌
func _ensure_awaken_in_hand(battle) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == AWAKEN_DEF:
			return cid
	var cid: StringName = _find_card(battle, AWAKEN_DEF)
	if cid == &"":
		return &""
	_remove_card_from_current(battle, cid)
	player.action_hand.append(cid)
	var c = gs.get_card(cid)
	if c:
		c.zone = &"action_hand"
	return cid


## 玩家手牌中含某 card_def_id 的数量
func _hand_count(battle, card_def_id: String) -> int:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var n := 0
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			n += 1
	return n


## 拿到当前等待输入的 awaken 选项里第1个 def_id；非 awaken 等待返回空
func _current_awaken_pick(battle) -> StringName:
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait.is_empty():
		return &""
	if String(wait.get("input_type", &"")) != &"select_awaken_card_type":
		return &""
	var opts: Array = wait.get("input_params", {}).get("options", [])
	if opts.is_empty():
		return &""
	var first: Dictionary = opts[0] if opts[0] is Dictionary else {}
	return first.get("def_id", &"")


# ════════════════════════════════════════════════════════════════
# 场景1：预判+识破都在弃牌堆 -> 无弹窗，取随机各1张
# ════════════════════════════════════════════════════════════════
func test_awaken_both_in_discard_no_popup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context

	_clear_action_discard(battle)
	var predict_cid := _put_in_discard(battle, PREDICT_DEF)
	var expose_cid := _put_in_discard(battle, EXPOSE_DEF)
	if predict_cid == &"" or expose_cid == &"":
		return "无法把预判/识破放入弃牌堆"

	var awaken_cid := _ensure_awaken_in_hand(battle)
	if awaken_cid == &"":
		return "找不到觉醒牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()

	var res := battle.execute_use_action_card(&"player", awaken_cid)
	await _pump_frames(5)

	# 无弹窗（两轮都直接取弃牌堆目标牌）
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if not wait.is_empty():
		return "预判识破都在弃牌堆时不应弹窗，实际 input_type=%s" % String(wait.get("input_type", &""))

	# 验证：玩家获得1张预判+1张识破（觉醒牌本身弃置，净+1）
	if _hand_count(battle, PREDICT_DEF) < 1:
		return "未获得预判"
	if _hand_count(battle, EXPOSE_DEF) < 1:
		return "未获得识破"
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after - hand_before != 1:
		return "手牌净变化应为+1（-觉醒+2获得），前=%d 后=%d" % [hand_before, hand_after]

	# 弃牌堆不再有该预判/识破（已入手牌）
	if gs.deck_state.action_discard_pile.has(predict_cid) or gs.deck_state.action_discard_pile.has(expose_cid):
		return "获取后弃牌堆仍含目标牌"

	if battle.context.action_registry.get_active_count() != 0:
		return "活跃动作残留: %d" % battle.context.action_registry.get_active_count()
	return true


# ════════════════════════════════════════════════════════════════
# 场景2：都不在弃牌堆、弃牌堆有2张其他牌 -> 两次弹窗，共4张
# ════════════════════════════════════════════════════════════════
func test_awaken_neither_in_discard_two_popups() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context

	_clear_action_discard(battle)
	var atk_cid := _put_in_discard(battle, ATTACK_DEF)
	var asl_cid := _put_in_discard(battle, ASSAULT_DEF)
	if atk_cid == &"" or asl_cid == &"":
		return "无法把进攻/强袭放入弃牌堆"

	var awaken_cid := _ensure_awaken_in_hand(battle)
	if awaken_cid == &"":
		return "找不到觉醒牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()

	var res := battle.execute_use_action_card(&"player", awaken_cid)
	await _pump_frames(5)

	# 第1次弹窗（预判轮）—— 两张命名牌都不在弃牌堆，提示应为空
	var pick1 := _current_awaken_pick(battle)
	if pick1 == &"":
		return "预判轮未弹 select_awaken_card_type（wait=%s）" % str(battle.context.action_ui_bridge.get_waiting_action_info())
	var hint1: String = battle.context.action_ui_bridge.get_waiting_action_info().get("input_params", {}).get("hint", "")
	if hint1 != "":
		return "两命名牌都不在弃牌堆时提示应为空，实际: '%s'" % hint1
	battle.context.action_ui_bridge.on_ui_confirmed({"chosen_card_def_id": pick1})
	await _pump_frames(5)

	# 第2次弹窗（识破轮）—— 预判经弹窗选取（非直接获取），提示应为空
	var pick2 := _current_awaken_pick(battle)
	if pick2 == &"":
		return "识破轮未弹 select_awaken_card_type"
	var hint2: String = battle.context.action_ui_bridge.get_waiting_action_info().get("input_params", {}).get("hint", "")
	if hint2 != "":
		return "识破轮提示应为空（预判非直接获取），实际: '%s'" % hint2
	battle.context.action_ui_bridge.on_ui_confirmed({"chosen_card_def_id": pick2})
	await _pump_frames(8)

	# 无残留等待
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if not wait.is_empty():
		return "两次选择后仍挂起 input_type=%s" % String(wait.get("input_type", &""))

	# 验证：获得4张（2弃牌堆+2牌堆顶），觉醒弃置，净+3
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after - hand_before != 3:
		return "手牌净变化应为+3（-觉醒+4获得），前=%d 后=%d" % [hand_before, hand_after]
	# 两张弃牌堆的牌应入手
	if not gs.players.get(&"player").action_hand.has(atk_cid) and not gs.players.get(&"player").action_hand.has(asl_cid):
		return "弃牌堆选中的牌未入手"

	if battle.context.action_registry.get_active_count() != 0:
		return "活跃动作残留: %d" % battle.context.action_registry.get_active_count()
	return true


# ════════════════════════════════════════════════════════════════
# 场景3：预判在弃牌堆、识破不在 -> 1次弹窗（识破轮），共3张
# ════════════════════════════════════════════════════════════════
func test_awaken_predict_in_discard_one_popup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context

	_clear_action_discard(battle)
	var predict_cid := _put_in_discard(battle, PREDICT_DEF)
	var asl_cid := _put_in_discard(battle, ASSAULT_DEF)  # 识破轮弹窗时供选
	if predict_cid == &"" or asl_cid == &"":
		return "无法构造弃牌堆"

	var awaken_cid := _ensure_awaken_in_hand(battle)
	if awaken_cid == &"":
		return "找不到觉醒牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()

	var res := battle.execute_use_action_card(&"player", awaken_cid)
	await _pump_frames(5)

	# 预判轮不弹窗（直接取预判）；识破轮弹窗
	var pick := _current_awaken_pick(battle)
	if pick == &"":
		return "识破轮未弹 select_awaken_card_type"
	# 提示：预判已直接获取，应显示"已获得 预判 ×1"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	var hint: String = wait_info.get("input_params", {}).get("hint", "")
	if hint != "已获得 预判 ×1":
		return "识破轮弹框提示应为'已获得 预判 ×1'，实际: '%s'" % hint
	battle.context.action_ui_bridge.on_ui_confirmed({"chosen_card_def_id": pick})
	await _pump_frames(8)

	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if not wait.is_empty():
		return "选择后仍挂起 input_type=%s" % String(wait.get("input_type", &""))

	# 获得3张（1预判 + 1弃牌堆 + 1牌堆顶），觉醒弃置，净+2
	if _hand_count(battle, PREDICT_DEF) < 1:
		return "未获得预判"
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after - hand_before != 2:
		return "手牌净变化应为+2（-觉醒+3获得），前=%d 后=%d" % [hand_before, hand_after]

	if battle.context.action_registry.get_active_count() != 0:
		return "活跃动作残留: %d" % battle.context.action_registry.get_active_count()
	return true


# ════════════════════════════════════════════════════════════════
# 场景4：弃牌堆为空 -> 无弹窗，各抽牌堆顶1张（共2张，用户拍板）
# ════════════════════════════════════════════════════════════════
func test_awaken_empty_discard_draws_deck_top() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context

	_clear_action_discard(battle)
	if not gs.deck_state.action_discard_pile.is_empty():
		return "清空弃牌堆失败"
	# 确保牌堆至少有2张
	if gs.deck_state.action_deck.size() < 2:
		return "行动牌堆不足2张"

	var awaken_cid := _ensure_awaken_in_hand(battle)
	if awaken_cid == &"":
		return "找不到觉醒牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	var deck_before: int = gs.deck_state.action_deck.size()

	var res := battle.execute_use_action_card(&"player", awaken_cid)
	await _pump_frames(5)

	# 无弹窗
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if not wait.is_empty():
		return "弃牌堆为空时不应弹窗，实际 input_type=%s" % String(wait.get("input_type", &""))

	# 各抽牌堆顶1张（共2张），觉醒弃置，净+1
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after - hand_before != 1:
		return "手牌净变化应为+1（-觉醒+2抽牌），前=%d 后=%d" % [hand_before, hand_after]
	# 牌堆减少2
	if deck_before - gs.deck_state.action_deck.size() != 2:
		return "牌堆应减少2，前=%d 后=%d" % [deck_before, gs.deck_state.action_deck.size()]

	if battle.context.action_registry.get_active_count() != 0:
		return "活跃动作残留: %d" % battle.context.action_registry.get_active_count()
	return true


# ════════════════════════════════════════════════════════════════
# 场景5：识破在弃牌堆、预判不在 -> 预判轮弹窗，提示"已获得 识破 ×1"（前瞻）
# ════════════════════════════════════════════════════════════════
func test_awaken_expose_in_discard_predict_missing_hint() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context

	_clear_action_discard(battle)
	# 强袭在前：弹窗 options[0]=强袭（默认选强袭），识破留给识破轮直接获取
	var asl_cid := _put_in_discard(battle, ASSAULT_DEF)
	var expose_cid := _put_in_discard(battle, EXPOSE_DEF)
	if expose_cid == &"" or asl_cid == &"":
		return "无法构造弃牌堆"

	var awaken_cid := _ensure_awaken_in_hand(battle)
	if awaken_cid == &"":
		return "找不到觉醒牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()

	var res := battle.execute_use_action_card(&"player", awaken_cid)
	await _pump_frames(5)

	# 预判轮弹窗（预判不在）；识破在弃牌堆将直接获取 -> 提示"已获得 识破 ×1"
	var pick := _current_awaken_pick(battle)
	if pick == &"":
		return "预判轮未弹 select_awaken_card_type"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	var hint: String = wait_info.get("input_params", {}).get("hint", "")
	if hint != "已获得 识破 ×1":
		return "预判轮弹框提示应为'已获得 识破 ×1'，实际: '%s'" % hint
	battle.context.action_ui_bridge.on_ui_confirmed({"chosen_card_def_id": pick})
	await _pump_frames(8)

	# 识破轮不弹窗（直接取识破）
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if not wait.is_empty():
		return "识破轮不应弹窗，实际 input_type=%s" % String(wait.get("input_type", &""))

	# 获得3张（1弃牌堆 + 1牌堆顶 + 1识破），觉醒弃置，净+2
	if _hand_count(battle, EXPOSE_DEF) < 1:
		return "未获得识破"
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after - hand_before != 2:
		return "手牌净变化应为+2（-觉醒+3获得），前=%d 后=%d" % [hand_before, hand_after]

	if battle.context.action_registry.get_active_count() != 0:
		return "活跃动作残留: %d" % battle.context.action_registry.get_active_count()
	return true


# ════════════════════════════════════════════════════════════════
# 场景6：弃牌堆有2张识破(SSR)+1张强袭(非SSR) -> 选框不含SSR，识破只随机取1张
#   验证bug修复：SSR牌不进选框；2张识破只获取1张（随机），剩余1张留弃牌堆
# ════════════════════════════════════════════════════════════════
func test_awaken_ssr_not_in_popup_only_one_taken() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	battle.context.action_ui_bridge.context = battle.context

	_clear_action_discard(battle)
	var asl_cid := _put_in_discard(battle, ASSAULT_DEF)  # 非SSR攻击牌，供选框
	var ex1 := _put_in_discard(battle, EXPOSE_DEF)  # 识破1
	var ex2 := _put_in_discard(battle, EXPOSE_DEF)  # 识破2
	if asl_cid == &"" or ex1 == &"" or ex2 == &"":
		return "无法构造弃牌堆(强袭+2识破)"

	var awaken_cid := _ensure_awaken_in_hand(battle)
	if awaken_cid == &"":
		return "找不到觉醒牌"
	var hand_before: int = gs.players.get(&"player").action_hand.size()

	var res := battle.execute_use_action_card(&"player", awaken_cid)
	await _pump_frames(5)

	# 第1轮(SSR攻击牌)：弃牌堆无SSR攻击牌(强袭非SSR) -> 弹框。选框应只含强袭，不含识破(SSR)
	var pick := _current_awaken_pick(battle)
	if pick == &"":
		return "第1轮未弹 select_awaken_card_type"
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	var opts: Array = wait_info.get("input_params", {}).get("options", [])
	for opt in opts:
		var od: Dictionary = opt if opt is Dictionary else {}
		if String(od.get("def_id", &"")) == EXPOSE_DEF:
			return "选框不应含SSR识破（修复前bug：2识破取1后剩余入选框）"
	if pick != ASSAULT_DEF:
		return "选框默认项应为强袭(非SSR)，实际: %s" % String(pick)
	battle.context.action_ui_bridge.on_ui_confirmed({"chosen_card_def_id": pick})
	await _pump_frames(5)

	# 第2轮(SSR迎击牌)：弃牌堆有2张识破 -> 随机取1张，不弹框
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if not wait2.is_empty():
		return "第2轮(SSR迎击)应直接随机取识破不弹框，实际 input_type=%s" % String(wait2.get("input_type", &""))

	# 验证：只获得1张识破（另1张仍留弃牌堆），+强袭+牌堆顶，觉醒弃置，净+2
	if _hand_count(battle, EXPOSE_DEF) != 1:
		return "应只获得1张识破，实际: %d" % _hand_count(battle, EXPOSE_DEF)
	# 弃牌堆应仍剩1张识破
	var expose_in_discard: int = 0
	for cid: StringName in gs.deck_state.action_discard_pile:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == EXPOSE_DEF:
			expose_in_discard += 1
	if expose_in_discard != 1:
		return "弃牌堆应剩1张识破，实际: %d" % expose_in_discard
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after - hand_before != 2:
		return "手牌净变化应为+2（-觉醒+强袭+牌堆顶+识破=+3净+2），前=%d 后=%d" % [hand_before, hand_after]

	if battle.context.action_registry.get_active_count() != 0:
		return "活跃动作残留: %d" % battle.context.action_registry.get_active_count()
	return true


