## test_pilot_066_silvow.gd - 银雪（pilot_066，联邦 N，cost 4, attack_limit 1, action_card_limit 3）
##
## 银雪效果「窥牌拦截」（运行时机师效果走 ActionPilotEffects 新体系）：
##   effect_01（DIRECT 显示按钮，开关）：随时按弹"启用/禁用窥牌拦截"二选一（可取消）。
##     flag 存 card.counters["pilot_066_intercept"]（默认启用=true）。CHOOSE_ONE 两选项各带
##     CARD_COUNTER_IS 条件过滤——仅当前状态对应的"翻转"选项可见；选中即 SET_CARD_COUNTER 翻转。
##   effect_02（LISTEN GAIN_CARD_BEFORE 隐藏，merge_desc_into_index=1，priority 10）：
##     3格内机甲（含我方）从行动牌堆抽牌前，若我方有行动牌且开关启用，弹单选窗弃1张行动牌
##     作代价，再弹多选窗窥行动牌堆顶3张可弃任意（剩余保持原序置顶）。代价/堆顶弃置走
##     EXECUTE_DISCARD 触发弃置时点。组件全通用：SET_CARD_COUNTER/CARD_COUNTER_IS（开关）+
##     GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE（3格内）+ PEEK_DECK_TOP_AND_DISCARD（2阶段窥牌模块）。
##
## 覆盖：定义结构 / 开关翻转 / 完整窥牌流 / 代价取消 / 越程不触发 / 无行动牌不触发 /
##       开关禁用不触发 / 弃牌堆抽取不触发（PAYLOAD_FROM_ZONE_IS 排除）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90065
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	# 银雪 peek 单选/多选需人类玩家路径（AI 自动跳过不挂起）
	for pid in [&"player", &"enemy"]:
		var p = battle.context.game_state.players.get(pid)
		if p != null:
			p.is_human = true
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


## 设银雪为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, enemy_mech}
func _setup_yinxue(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_066_银雪", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {
		"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb,
		"enemy_mech": gs.get_mech_for_player(&"enemy"),
	}


## 在 _pending_effect 中找 phase 匹配的挂起 effect 动作 id；无返回 &""。
func _find_pending_action(battle, phase: String) -> StringName:
	var pending: Dictionary = battle.context.timing_engine._pending_effect
	for aid: StringName in pending:
		if String(pending[aid].get("phase", &"")) == phase:
			return aid
	return &""


## 找一张指定 action_type 的行动牌 def_id（cdb 已加载全部行动牌）。
func _find_action_def_id(cdb, want_type: String) -> String:
	for def in cdb.list_cards_by_kind(&"action"):
		if String(def.action_type) == want_type:
			return String(def.card_id)
	return ""


## 触发银雪 effect_01（DIRECT 开关按钮），返回挂起的 effect_fire action（或 null）
func _fire_pilot_066_toggle(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_066_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_066_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## 读取机师牌 counters["pilot_066_intercept"]（不存在按默认 true）
func _intercept_flag(pilot_card) -> bool:
	if pilot_card == null:
		return true
	if not "counters" in pilot_card:
		return true
	return bool(pilot_card.counters.get("pilot_066_intercept", true))


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：2 效果定义正确（e1 DIRECT 开关 CHOOSE_ONE / e2 隐藏 LISTEN GAIN_CARD_BEFORE 窥牌）
func test_p065_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()

	var e1 = effs.get(&"pilot_066_effect_01")
	if e1 == null:
		return "缺 pilot_066_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 DIRECT"
	if not e1.hide_button == false:
		return "effect_01 应是可见按钮"
	if e1.actions.is_empty() or String(e1.actions[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 actions[0] 应 CHOOSE_ONE"
	var p1: Dictionary = e1.actions[0].get("params", {})
	if not p1.get("optional", false):
		return "effect_01 CHOOSE_ONE 应 optional（可取消）"
	var opts1: Array = p1.get("options", [])
	if opts1.size() != 2:
		return "effect_01 应有 2 个开关选项 实=%d" % opts1.size()
	# 选项0=禁用（条件 flag==true，动作为 SET_CARD_COUNTER value=false）
	var o0: Dictionary = opts1[0] if opts1[0] is Dictionary else {}
	var o0_conds: Array = o0.get("condition", [])
	var o0_has_cbi := false
	for c in o0_conds:
		if String(c.get("op", &"")) == "CARD_COUNTER_IS":
			var cp: Dictionary = c.get("params", {})
			if String(cp.get("key", &"")) == "pilot_066_intercept" and bool(cp.get("value", true)) == true and bool(cp.get("default_when_absent", false)) == true:
				o0_has_cbi = true
	if not o0_has_cbi:
		return "选项0 缺 CARD_COUNTER_IS(key=pilot_066_intercept,value=true,default_when_absent=true)"
	var o0_acts: Array = o0.get("actions", [])
	if o0_acts.is_empty() or String(o0_acts[0].get("type", &"")) != "SET_CARD_COUNTER":
		return "选项0 动作应 SET_CARD_COUNTER"
	var o0_p: Dictionary = o0_acts[0].get("params", {}) if o0_acts[0] is Dictionary else {}
	if String(o0_p.get("key", &"")) != "pilot_066_intercept" or bool(o0_p.get("value", true)) != false:
		return "选项0 SET_CARD_COUNTER 应 value=false（禁用）"
	# 选项1=启用（条件 flag==false，动作为 SET_CARD_COUNTER value=true）
	var o1: Dictionary = opts1[1] if opts1[1] is Dictionary else {}
	var o1_acts: Array = o1.get("actions", [])
	if o1_acts.is_empty() or String(o1_acts[0].get("type", &"")) != "SET_CARD_COUNTER":
		return "选项1 动作应 SET_CARD_COUNTER"
	var o1_p: Dictionary = o1_acts[0].get("params", {}) if o1_acts[0] is Dictionary else {}
	if String(o1_p.get("key", &"")) != "pilot_066_intercept" or bool(o1_p.get("value", false)) != true:
		return "选项1 SET_CARD_COUNTER 应 value=true（启用）"

	var e2 = effs.get(&"pilot_066_effect_02")
	if e2 == null:
		return "缺 pilot_066_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN"
	if e2.listen_timing != _TimingConst.GAIN_CARD_BEFORE:
		return "effect_02 应监听 GAIN_CARD_BEFORE"
	if String(e2.listen_action_type) != "gain_card":
		return "effect_02 listen_action_type 应 gain_card"
	if not e2.hide_button:
		return "effect_02 应 hide_button"
	if int(e2.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1"
	if int(e2.priority) != 10:
		return "effect_02 priority 应 10"
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	for want in ["GAIN_CARD_IS_DRAW", "GAIN_CARD_IS_ACTION_DRAW", "PAYLOAD_FROM_ZONE_IS", "GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE", "HAS_ACTION_CARD_IN_HAND", "CARD_COUNTER_IS"]:
		if not ops2.has(want):
			return "effect_02 缺条件 %s" % want
	# PAYLOAD_FROM_ZONE_IS zone=action_deck
	var pfr_found := false
	var gdmwr_found := false
	for c in e2.conditions:
		var cop: String = String(c.get("op", &""))
		var cp: Dictionary = c.get("params", {})
		if cop == "PAYLOAD_FROM_ZONE_IS" and String(cp.get("zone", &"")) == "action_deck":
			pfr_found = true
		if cop == "GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE" and int(cp.get("range", 0)) == 3:
			gdmwr_found = true
	if not pfr_found:
		return "effect_02 PAYLOAD_FROM_ZONE_IS zone 应 action_deck"
	if not gdmwr_found:
		return "effect_02 GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE range 应 3"
	if e2.actions.is_empty() or String(e2.actions[0].get("type", &"")) != "PEEK_DECK_TOP_AND_DISCARD":
		return "effect_02 actions[0] 应 PEEK_DECK_TOP_AND_DISCARD"
	var p2: Dictionary = e2.actions[0].get("params", {})
	if int(p2.get("peek_count", 0)) != 3:
		return "effect_02 PEEK peek_count 应 3 实=%d" % int(p2.get("peek_count", 0))
	if String(p2.get("deck_zone", &"")) != "action_deck":
		return "effect_02 PEEK deck_zone 应 action_deck"
	return true


# ═══════════════════════════════════════════
# 开关测试
# ═══════════════════════════════════════════

## 测试2：默认启用(absent=true)->按按钮弹窗->选"禁用"(选项0)->flag=false；再按->选"启用"(选项1)->flag=true
func test_p065_toggle_off_then_on() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yinxue(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var pilot = s.pilot_card

	# 默认启用
	if not _intercept_flag(pilot):
		return "默认 flag 应启用(true)"

	# ① 按开关：应弹 CHOOSE_ONE（pre_actions_target），仅"禁用"选项可见
	var ef1 := await _fire_pilot_066_toggle(battle, pilot, s.mech, &"player")
	if ef1 == null:
		return "effect_01 应挂起弹开关二选一窗"
	if _find_pending_action(battle, "pre_actions_target") != ef1.action_id:
		return "effect_01 应挂起 pre_actions_target（即 effect_fire 本动作）"
	# 选"禁用"（选项0）
	battle.context.timing_engine.resume_pending_effect(ef1.action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	if _intercept_flag(pilot):
		return "选禁用后 flag 应 false 实=%s" % str(_intercept_flag(pilot))

	# ② 再按开关：应弹窗，仅"启用"选项可见（flag==false 命中选项1）
	var ef2 := await _fire_pilot_066_toggle(battle, pilot, s.mech, &"player")
	if ef2 == null:
		return "第二次 effect_01 应挂起弹开关二选一窗"
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"chosen_option_index": 1})
	await _pump_frames(6)
	if not _intercept_flag(pilot):
		return "选启用后 flag 应 true 实=%s" % str(_intercept_flag(pilot))
	return true


# ═══════════════════════════════════════════
# 窥牌行为测试
# ═══════════════════════════════════════════

## 测试3：完整窥牌流——我方抽行动牌 -> BEFORE 弹代价单选 -> 弃代价 -> 弹堆顶3多选 ->
## 弃其中1张 -> 宿主抽牌；堆顶剩余保持原序置顶
func test_p065_peek_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yinxue(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	battle.context.action_ui_bridge.context = battle.context

	# 准备代价牌（玩家手牌1张行动牌）
	var atk_def_id := _find_action_def_id(cdb, "攻击")
	if atk_def_id == "":
		return "cdb 无攻击行动牌"
	var cost_card = _make_instance(gs, cdb, atk_def_id, &"player")
	if cost_card == null:
		return "代价牌实例创建失败"
	# 清空玩家原有行动手牌，只放代价牌（便于断言）
	_clear_action_hand(gs, &"player")
	gs.players.get(&"player").action_hand.append(cost_card.instance_id)

	# 准备牌堆顶3张已知牌 A/B/C（A 最顶），从行动牌堆借3张不同牌实例
	var top_a = _make_instance(gs, cdb, atk_def_id, &"player")
	var top_b = _make_instance(gs, cdb, atk_def_id, &"player")
	var top_c = _make_instance(gs, cdb, atk_def_id, &"player")
	if top_a == null or top_b == null or top_c == null:
		return "堆顶牌实例创建失败"
	# push 顺序：先 C 再 B 再 A，使 A 在最前（顶）
	gs.deck_state.action_deck.push_front(top_c.instance_id)
	gs.deck_state.action_deck.push_front(top_b.instance_id)
	gs.deck_state.action_deck.push_front(top_a.instance_id)

	# 真实我方抽1张行动牌 -> GAIN_CARD_BEFORE -> effect_02 代价单选窗挂起
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p065_peek",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(4)
	var aid_cost := _find_pending_action(battle, "peek_select_cost")
	if aid_cost == &"":
		return "我方抽行动牌应挂起代价单选窗（peek_select_cost）"

	# ① 代价单选：选代价牌 -> 弃代价 -> 进入堆顶多选
	battle.context.timing_engine.resume_pending_effect(aid_cost, {"selected_card_ids": [cost_card.instance_id]})
	await _pump_frames(8)
	# 代价牌应已弃置到弃牌堆
	if not gs.deck_state.action_discard_pile.has(cost_card.instance_id):
		return "代价牌应弃置到行动弃牌堆"

	# ② 堆顶多选：窥视顶3张，选 B（中间那张）弃置
	var aid_peek := _find_pending_action(battle, "peek_select_discard")
	if aid_peek == &"":
		return "代价弃置后应挂起堆顶多选窗（peek_select_discard）"
	# 确认弹窗候选恰为顶3张 A/B/C
	var pend: Dictionary = battle.context.timing_engine._pending_effect.get(aid_peek, {})
	var peek_cards: Array = pend.get("peek_card_ids", [])
	if peek_cards.size() != 3:
		return "堆顶多选候选应3张 实=%d" % peek_cards.size()
	if String(peek_cards[0]) != String(top_a.instance_id) or String(peek_cards[1]) != String(top_b.instance_id) or String(peek_cards[2]) != String(top_c.instance_id):
		return "堆顶多选候选顺序应 A,B,C"
	battle.context.timing_engine.resume_pending_effect(aid_peek, {"selected_card_ids": [top_b.instance_id]})
	await _pump_frames(8)
	# B 应弃置到弃牌堆
	if not gs.deck_state.action_discard_pile.has(top_b.instance_id):
		return "选中堆顶牌 B 应弃置到行动弃牌堆"
	# B 不应仍在牌堆
	if gs.deck_state.action_deck.has(top_b.instance_id):
		return "B 应已从行动牌堆移除"

	# ③ 宿主抽牌完成：代价牌已弃（手牌-1），宿主抽1张 A（手牌+1），净0。
	# 关键验证内容：抽到的是原顶 A（A 离开牌堆进入手牌），代价牌已不在手牌，C 保持原序在牌堆顶。
	await _pump_frames(4)
	var hand: Array = gs.players.get(&"player").action_hand
	if hand.is_empty():
		return "窥牌流完成后应抽到1张（手牌空，宿主未抽？）"
	# 代价牌应已不在手牌（已弃置作代价）
	if hand.has(cost_card.instance_id):
		return "代价牌应已不在手牌（已弃置）"
	# 抽到的应是 A（原顶，被宿主抽走进入手牌）
	if not hand.has(top_a.instance_id):
		return "宿主应抽到原顶 A 实手牌=%s" % str(hand)
	# A 已不在牌堆
	if gs.deck_state.action_deck.has(top_a.instance_id):
		return "A 应被宿主抽走（不在牌堆）"
	# C 仍在牌堆顶（B 弃、A 抽后，C 应在牌堆最前）
	if gs.deck_state.action_deck.is_empty() or String(gs.deck_state.action_deck[0]) != String(top_c.instance_id):
		var top_now: String = String(gs.deck_state.action_deck[0]) if not gs.deck_state.action_deck.is_empty() else "<空>"
		return "C 应保持原序在牌堆顶 实顶=%s" % top_now
	return true


## 测试4：代价单选取消 -> 不发动窥牌，宿主照常抽1张
func test_p065_peek_cancel_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yinxue(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	battle.context.action_ui_bridge.context = battle.context

	var atk_def_id := _find_action_def_id(cdb, "攻击")
	if atk_def_id == "":
		return "cdb 无攻击行动牌"
	var cost_card = _make_instance(gs, cdb, atk_def_id, &"player")
	if cost_card == null:
		return "代价牌实例创建失败"
	_clear_action_hand(gs, &"player")
	gs.players.get(&"player").action_hand.append(cost_card.instance_id)
	var hand_before: int = gs.players.get(&"player").action_hand.size()

	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p065_cancel",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(4)
	var aid := _find_pending_action(battle, "peek_select_cost")
	if aid == &"":
		return "应挂起代价单选窗"
	# 取消 -> 不发动
	battle.context.timing_engine.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(8)
	# 代价牌未弃置（仍在手牌）
	if gs.deck_state.action_discard_pile.has(cost_card.instance_id):
		return "取消代价不应弃置代价牌"
	# 宿主照常抽1张
	if gs.players.get(&"player").action_hand.size() != hand_before + 1:
		return "取消后宿主应抽1张 实增=%d" % (gs.players.get(&"player").action_hand.size() - hand_before)
	# 无堆顶多选挂起
	if _find_pending_action(battle, "peek_select_discard") != &"":
		return "取消代价后不应进入堆顶多选"
	return true


## 测试5：敌方在3格外抽牌 -> 不触发窥牌（GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE 排除）
func test_p065_out_of_range_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yinxue(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context

	# 我方机甲(银雪)放 (0,0)，敌方机甲放 (10,0) -> 距离10 > 3
	s.mech.position = {"q": 0, "r": 0}
	s.enemy_mech.position = {"q": 10, "r": 0}
	# 确保我方有行动牌（满足 HAS_ACTION_CARD_IN_HAND，仅 isolate 距离条件）
	if gs.players.get(&"player").action_hand.is_empty():
		var atk_def_id := _find_action_def_id(s.cdb, "攻击")
		var pad = _make_instance(gs, s.cdb, atk_def_id, &"player") if atk_def_id != "" else null
		if pad != null:
			gs.players.get(&"player").action_hand.append(pad.instance_id)
	var enemy_before: int = gs.players.get(&"enemy").action_hand.size()

	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"enemy", "mech_ids": [s.enemy_mech.mech_id], "reason": &"test_p065_oor",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card(敌方) 未创建"
	await _pump_frames(6)
	if _find_pending_action(battle, "peek_select_cost") != &"":
		return "3格外抽取不应触发窥牌"
	if gs.players.get(&"enemy").action_hand.size() != enemy_before + 1:
		return "3格外抽取应照常抽1张 实增=%d" % (gs.players.get(&"enemy").action_hand.size() - enemy_before)
	return true


## 测试6：我方无行动牌 -> 不触发窥牌（HAS_ACTION_CARD_IN_HAND 拦截），但仍抽到1张
func test_p065_no_action_hand_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yinxue(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context

	# 清空我方行动手牌
	_clear_action_hand(gs, &"player")
	var player_before: int = gs.players.get(&"player").action_hand.size()
	if player_before != 0:
		return "清空后行动手牌应0张"

	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p065_no_hand",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(6)
	if _find_pending_action(battle, "peek_select_cost") != &"":
		return "无行动牌不应触发窥牌"
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "无行动牌时应照常抽1张 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试7：开关禁用后 -> 不触发窥牌（CARD_COUNTER_IS flag=false 拦截）
func test_p065_toggle_off_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yinxue(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context

	# 先禁用开关
	var ef := await _fire_pilot_066_toggle(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 应挂起"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	if _intercept_flag(s.pilot_card):
		return "禁用后 flag 应 false"

	# 确保有行动牌（避免被 HAS_ACTION_CARD_IN_HAND 误判）
	if gs.players.get(&"player").action_hand.is_empty():
		var atk_def_id := _find_action_def_id(s.cdb, "攻击")
		var pad = _make_instance(gs, s.cdb, atk_def_id, &"player") if atk_def_id != "" else null
		if pad != null:
			gs.players.get(&"player").action_hand.append(pad.instance_id)
	var player_before: int = gs.players.get(&"player").action_hand.size()

	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p065_off",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(6)
	if _find_pending_action(battle, "peek_select_cost") != &"":
		return "开关禁用后不应触发窥牌"
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "开关禁用后应照常抽1张 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试8：从弃牌堆抽行动牌 -> 不触发窥牌（PAYLOAD_FROM_ZONE_IS action_deck 排除）
func test_p065_discard_pile_draw_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yinxue(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context

	# 弃牌堆塞1张行动牌保证可抽
	if gs.deck_state.action_deck.is_empty():
		return "行动牌堆空，无法测"
	var borrow: StringName = gs.deck_state.action_deck[0]
	gs.deck_state.action_deck.remove_at(0)
	gs.deck_state.action_discard_pile.push_front(borrow)
	# 确保有行动牌
	if gs.players.get(&"player").action_hand.is_empty():
		var pad = _make_instance(gs, s.cdb, _find_action_def_id(s.cdb, "攻击"), &"player")
		if pad != null:
			gs.players.get(&"player").action_hand.append(pad.instance_id)
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# 从弃牌堆抽（回忆）：from_zone=action_discard
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_discard", "card_kind": &"action", "count": 1, "random": true,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p065_discard",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card(弃牌堆) 未创建"
	await _pump_frames(6)
	if _find_pending_action(battle, "peek_select_cost") != &"":
		return "弃牌堆抽取不应触发窥牌（仅行动牌堆抽取触发）"
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "弃牌堆抽取应照常抽1张 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


# ═══════════════════════════════════════════
# 辅助
# ═══════════════════════════════════════════

func _clear_action_hand(gs, pid: StringName) -> void:
	var p = gs.players.get(pid)
	if p == null:
		return
	for cid in p.action_hand.duplicate():
		p.action_hand.erase(cid)
