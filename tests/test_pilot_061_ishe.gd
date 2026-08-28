## test_pilot_061_ishe.gd - 艾希（pilot_061，联邦 N）效果测试
##
## 1 按钮（效果1显示 + 效果2隐藏合并描述）：
##   效果2（隐藏，LISTEN TURN_START，priority 10）：我方回合开始时抽牌数+2。通用 SET_TURN_START_DRAW_BONUS
##     模块在 TURN_START 时点写 turn_start_action_draw_bonus，TurnService 回合开始抽牌 count=2+2=4（单次 gain_card）。
##   效果1（显示按钮，LISTEN TURN_AFTER_START，priority 10）：若我方有行动牌且3格内有其他机甲，选1台3格内其他机甲
##     （CHOOSE_OTHER_MECH，可取消不发动）→ 复选框选我方任意张行动牌（≥1张、no_cancel 无取消键）→
##     TRANSFER_ACTION_CARDS 交给该机甲。
## 通用化：SET_TURN_START_DRAW_BONUS 通用模块（任意"回合开始抽牌+X"效果复用）；交牌流程整段复用 pilot_031。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 61061
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
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


func _make_turn_action(battle, owner_id: StringName) -> _Action:
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p061_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": owner_id, "player_id": owner_id}
	turn_action.state = &"running"
	turn_action.context = battle.context
	var mech = battle.context.game_state.get_mech_for_player(owner_id)
	turn_action.source = {"player_id": owner_id, "mech_id": mech.mech_id if mech != null else &""}
	battle.context.action_registry.register(turn_action)
	return turn_action


## fire 指定回合时点，返回虚拟 action
func _fire_turn(battle, timing: StringName, owner_id: StringName) -> _Action:
	var ta := _make_turn_action(battle, owner_id)
	battle.context.timing_engine.fire_timing(timing, ta)
	return ta


## 读取当前等待输入信息（UI 路由等待），无则返回 {}
func _get_wait(battle) -> Dictionary:
	return battle.context.action_ui_bridge.get_waiting_action_info()


## 设艾希为 player 机甲机师，返回 {player_mech, enemy_mech, pilot_card, gs}；失败返回空。
func _setup_pilot_061(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_instance(gs, cdb, "pilot_061_艾希", &"player")
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	return {"player_mech": player_mech, "enemy_mech": enemy_mech, "pilot_card": card, "gs": gs}


## 放机甲到指定坐标
func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 清空 owner_id 行动手牌（移回牌堆顶，测试用占位）
func _clear_action_hand(battle, owner_id: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(owner_id)
	if player == null:
		return
	for cid in player.action_hand.duplicate():
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 查找挂起的艾希 effect_01 动作（target/cards 选择阶段），返回 action_id 或 &""
func _find_pending_061(battle) -> StringName:
	var te = battle.context.timing_engine
	for aid in te._pending_effect:
		var pe = te._pending_effect[aid]
		if pe is Dictionary:
			var eff = pe.get("effect")
			if eff != null and String(eff.effect_id) == "pilot_061_effect_01":
				return aid
	return &""


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN TURN_AFTER_START + 条件 + 目标规则 + CHOOSE_MANY_CARDS→TRANSFER 链）
##        与 effect_02 定义正确（隐藏 + LISTEN TURN_START + SET_TURN_START_DRAW_BONUS）。
func test_p061_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	var e1 = effs.get(&"pilot_061_effect_01")
	if e1 == null:
		return "缺 pilot_061_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.TURN_AFTER_START:
		return "effect_01 应监听 TURN_AFTER_START 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "turn":
		return "effect_01 listen_action_type 应 turn"
	if int(e1.priority) != 10:
		return "effect_01 priority 应 10 实=%d" % int(e1.priority)
	if e1.hide_button:
		return "effect_01 应是显示按钮（1显示按钮模式）"
	var ops1: Array = []
	for c in e1.conditions:
		ops1.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_TURN", "HAS_ACTION_CARD_IN_HAND", "HAS_OTHER_MECH_IN_HEX_RANGE"]:
		if not ops1.has(need):
			return "effect_01 应含条件 %s 实=%s" % [need, str(ops1)]
	for c in e1.conditions:
		if String(c.get("op", &"")) == "HAS_OTHER_MECH_IN_HEX_RANGE" and int(c.get("params", {}).get("range", 0)) != 3:
			return "HAS_OTHER_MECH_IN_HEX_RANGE range 应 3"
	# 目标规则：CHOOSE_OTHER_MECH + TARGET_IN_RANGE(3, hex_distance)
	var has_choose_other := false
	var has_range := false
	for r in e1.target_rules:
		if String(r.get("rule", &"")) == "CHOOSE_OTHER_MECH":
			has_choose_other = true
		if String(r.get("rule", &"")) == "TARGET_IN_RANGE" and int(r.get("params", {}).get("range", 0)) == 3 and String(r.get("params", {}).get("metric", &"")) == "hex_distance":
			has_range = true
	if not has_choose_other:
		return "目标规则应含 CHOOSE_OTHER_MECH（任意其他机甲）"
	if not has_range:
		return "目标规则应含 TARGET_IN_RANGE(3, hex_distance)"
	# actions: [CHOOSE_MANY_CARDS] + TRANSFER post_action
	var acts = e1.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "effect_01 actions 应 [CHOOSE_MANY_CARDS]"
	var cm: Dictionary = acts[0].get("params", {})
	if cm.get("source", &"") != &"OWNER_ACTION_HAND":
		return "CHOOSE_MANY_CARDS source 应 OWNER_ACTION_HAND"
	if int(cm.get("min_count", 0)) != 1:
		return "CHOOSE_MANY_CARDS min_count 应 1（至少选1张）"
	if int(cm.get("max_count", 0)) != -1:
		return "CHOOSE_MANY_CARDS max_count 应 -1（任意张）"
	if not bool(cm.get("no_cancel", false)):
		return "CHOOSE_MANY_CARDS no_cancel 应 true（选牌窗无取消键）"
	if bool(cm.get("discard_selected", true)):
		return "CHOOSE_MANY_CARDS discard_selected 应 false（交牌由 TRANSFER 执行，不弃置）"
	var post: Array = cm.get("post_actions", [])
	if post.size() != 1:
		return "post_actions 应1个（仅交牌）实=%d" % post.size()
	var pa0: Dictionary = post[0]
	if String(pa0.get("type", &"")) != "TRANSFER_ACTION_CARDS":
		return "post_actions[0] 应 TRANSFER_ACTION_CARDS"
	if pa0.get("params", {}).get("card_ids", &"") != "$choice.card_ids":
		return "TRANSFER card_ids 应 $choice.card_ids"
	if pa0.get("params", {}).get("target_mech_id", &"") != "$payload.target_id":
		return "TRANSFER target_mech_id 应 $payload.target_id"
	if pa0.get("params", {}).get("from_player_id", &"") != "$binding_context.player_id":
		return "TRANSFER from_player_id 应 $binding_context.player_id"
	# effect_02：隐藏 + TURN_START + SET_TURN_START_DRAW_BONUS
	var e2 = effs.get(&"pilot_061_effect_02")
	if e2 == null:
		return "缺 pilot_061_effect_02"
	if not e2.hide_button:
		return "effect_02 应 hide_button=true（隐藏，描述合并进按钮1 hover）"
	if int(e2.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN 实=%s" % String(e2.mode)
	if e2.listen_timing != _TimingConst.TURN_START:
		return "effect_02 应监听 TURN_START 实=%s" % String(e2.listen_timing)
	if String(e2.listen_action_type) != "turn":
		return "effect_02 listen_action_type 应 turn"
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("IS_OWNER_TURN"):
		return "effect_02 应含 IS_OWNER_TURN 条件"
	var acts2: Array = e2.actions
	if acts2.size() != 1 or String(acts2[0].get("type", &"")) != "SET_TURN_START_DRAW_BONUS":
		return "effect_02 actions 应 [SET_TURN_START_DRAW_BONUS]"
	if int(acts2[0].get("params", {}).get("add", 0)) != 2:
		return "effect_02 SET_TURN_START_DRAW_BONUS add 应 2"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 标准场景：player(2,2) + 敌机(4,2) 距离2（3格内）+ 双方行动手牌清空
func _setup_standard(battle) -> Dictionary:
	var setup = _setup_pilot_061(battle)
	if setup.is_empty():
		return {}
	_place_mech(battle, setup["enemy_mech"].mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	return setup


## 测试2：完整流程——start_turn 抽 2+2=4 张行动牌（效果2加成+消费清零）→
## TURN_AFTER_START 弹选目标 → 选敌机 → 复选框选2张 → 交给敌机。
func test_p061_draw_bonus_and_handover() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var player = gs.players[&"player"]
	var enemy = gs.players[&"enemy"]
	if _HexGrid.distance(player_mech.position, enemy_mech.position) > 3:
		return "前置错误：敌机应在3格内"
	var enemy_hand_before: int = enemy.action_hand.size()

	battle.context.turn_service.start_turn(&"player")
	await _pump_frames(3)
	# 抽牌加成：消费清零 + 手牌 = 2+2 = 4
	if int(player.turn_counters.get("turn_start_action_draw_bonus", 0)) != 0:
		return "抽牌加成应在抽牌后清零 实=%d" % int(player.turn_counters.get("turn_start_action_draw_bonus", 0))
	if player.action_hand.size() != 4:
		return "艾希回合开始应抽4张行动牌(2+2) 实=%d" % player.action_hand.size()
	# 弹选目标窗（select_mech_target）
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "select_mech_target":
		return "TURN_AFTER_START 应弹选目标窗(select_mech_target)，wait=%s" % str(wait_info)
	var aid := _find_pending_061(battle)
	if aid == &"":
		return "未找到挂起的 pilot_061_effect_01"
	# 选敌机
	te.resume_pending_effect(aid, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	if te._pending_effect.get(aid, {}).get("phase", &"") != &"choose_many_cards":
		return "选中机甲后应挂起选牌阶段(choose_many_cards) 实=%s" % String(te._pending_effect.get(aid, {}).get("phase", &""))
	# 选2张行动牌确认（no_cancel，必须确认）
	var hand: Array = player.action_hand.duplicate()
	if hand.size() < 2:
		return "前置：手牌应≥2 实=%d" % hand.size()
	var hand2: Array = [hand[0], hand[1]]
	te.resume_pending_effect(aid, {"selected_card_ids": hand2, "cancelled": false})
	await _pump_frames(12)
	# 交出的牌应进入敌方手牌、离开我方手牌；我方手牌 -=2
	for cid in hand2:
		if not enemy.action_hand.has(cid):
			return "交出的牌 %s 应进入敌方手牌" % String(cid)
		if player.action_hand.has(cid):
			return "交出的牌 %s 应离开我方手牌" % String(cid)
	if player.action_hand.size() != 2:
		return "我方交2张后手牌应=2 实=%d" % player.action_hand.size()
	if enemy.action_hand.size() != enemy_hand_before + 2:
		return "敌方应收2张 after=%d（before=%d）" % [enemy.action_hand.size(), enemy_hand_before]
	return true


## 测试3：选目标取消 -> 不发动（不交牌、我方手牌保留4张）
func test_p061_target_cancel_aborts() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var enemy = gs.players[&"enemy"]
	var player = gs.players[&"player"]
	var enemy_hand_before: int = enemy.action_hand.size()

	battle.context.turn_service.start_turn(&"player")
	await _pump_frames(3)
	if player.action_hand.size() != 4:
		return "前置：艾希应抽4张 实=%d" % player.action_hand.size()
	var aid := _find_pending_061(battle)
	if aid == &"":
		return "未找到挂起的 pilot_061_effect_01（应弹选目标）"
	# 取消选目标 = 不发动
	te.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(6)
	if enemy.action_hand.size() != enemy_hand_before:
		return "取消选目标后不应交牌 敌方实=%d" % enemy.action_hand.size()
	if player.action_hand.size() != 4:
		return "取消选目标后我方手牌应仍=4 实=%d" % player.action_hand.size()
	return true


## 测试4：敌机不在3格内 -> 不弹艾希选目标窗（效果1条件不满足），但抽牌数+2仍生效
func test_p061_no_in_range_mech_no_prompt() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_pilot_061(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var player = gs.players[&"player"]
	var enemy = gs.players[&"enemy"]
	# 敌机保持默认位置 (20,2)（player(2,2) 距离18，超出3格）
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	if _HexGrid.distance(player_mech.position, enemy_mech.position) <= 3:
		return "前置错误：敌机应在3格外"
	var enemy_hand_before: int = enemy.action_hand.size()

	battle.context.turn_service.start_turn(&"player")
	await _pump_frames(3)
	# 抽牌加成仍生效：抽 2+2=4
	if player.action_hand.size() != 4:
		return "无3格内目标时抽牌加成仍应生效(抽4) 实=%d" % player.action_hand.size()
	# 不弹艾希选目标窗、无交牌
	if _find_pending_061(battle) != &"":
		return "无3格内目标时不应弹艾希选目标窗"
	if enemy.action_hand.size() != enemy_hand_before:
		return "不应有交牌 敌方实=%d" % enemy.action_hand.size()
	return true


## 测试5：手牌无行动牌 -> 不弹艾希选目标窗（HAS_ACTION_CARD_IN_HAND 条件不满足）
func test_p061_no_action_cards_no_prompt() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_pilot_061(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var enemy_mech = setup["enemy_mech"]
	var enemy = gs.players[&"enemy"]
	# 敌机3格内 + 我方行动手牌清空
	_place_mech(battle, enemy_mech.mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	var enemy_hand_before: int = enemy.action_hand.size()

	await _fire_turn(battle, _TimingConst.TURN_AFTER_START, &"player")
	await _pump_frames(3)
	if _find_pending_061(battle) != &"":
		return "手牌无行动牌时不应弹艾希选目标窗"
	if enemy.action_hand.size() != enemy_hand_before:
		return "不应有交牌 敌方实=%d" % enemy.action_hand.size()
	return true
