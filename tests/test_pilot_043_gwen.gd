## test_pilot_043_gwen.gd - 格温（pilot_043，帝国 R，cost 6, attack_limit 1, action_card_limit 4）效果1测试
##
## 格温效果1「宣言抽取」（运行时机师效果走 ActionPilotEffects 新体系）：
##   effect_01（按钮，LISTEN GAIN_CARD_BEFORE priority 10）「宣言抽取」：我方每次"抽取行动牌"
##     的获取牌动作发出获取牌前时点时，弹单选（攻击/迎击/辅助，可取消）。选择后经 CHOOSE_ONE
##     通用 store_record_key 机制，把宣言类型写入本次 gain_card 动作 record 的
##     declared_action_type 键；取消则不写（无后续）。
##   effect_02（隐藏，merge_desc_into_index=1，LISTEN GAIN_CARD_AFTER）「宣言抽牌」：本次抽到的牌
##     （drawn_card_ids）中存在宣言类型（record[declared_action_type]）的行动牌时（复数抽到只要含
##     1 张即生效），立即再抽 1 张行动牌（EXECUTE_GAIN_CARD）。新动作会再次触发本效果（可连续
##     宣言，直到抽空牌堆/取消/不含类型）。
##
## "抽取行动牌"判定用 gain_card 统一抽取标（extract_info 预打 draw/draw_card_kind + 抽取方==格温
##   拥有者）：回合开始抽牌/2金币抽牌/效果抽牌/回忆弃牌堆抽均命中；装备抽取（draw_card_kind=
##   equipment）、非我方抽取（draw_player_id/draw_mech_ids != 拥有者）天然不命中。
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
	battle.rng_seed = 90043
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	# 默认玩家/敌方均 is_human=true（格温 GAIN_CARD_BEFORE 弹单选需要人类玩家路径）
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


## 设格温为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, enemy_mech}
func _setup_gwen(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_043_格温", owner_id)
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


## 构造并 fire 一个 mock gain_card 的 GAIN_CARD_BEFORE 时点（直接测 effect_01 弹窗条件）。
## record_extra 合并进 record（draw/draw_card_kind/draw_mech_ids/draw_player_id 等）。
func _fire_gain_card_before(battle, record_extra: Dictionary = {}) -> _Action:
	var mock := _Action.new()
	mock.action_id = &"test_p043_gcb_%d" % [randi() % 1000000]
	mock.action_type = &"gain_card"
	mock.record = record_extra
	mock.state = &"running"
	mock.context = battle.context
	battle.context.action_registry.register(mock)
	battle.context.timing_engine.fire_timing(_TimingConst.GAIN_CARD_BEFORE, mock)
	return mock


## 构造并 fire 一个 mock gain_card 的 GAIN_CARD_AFTER 时点（直接测 effect_02 监听条件）。
func _fire_gain_card_after(battle, record_extra: Dictionary = {}) -> _Action:
	var mock := _Action.new()
	mock.action_id = &"test_p043_gca_%d" % [randi() % 1000000]
	mock.action_type = &"gain_card"
	mock.record = record_extra
	mock.state = &"running"
	mock.context = battle.context
	battle.context.action_registry.register(mock)
	battle.context.timing_engine.fire_timing(_TimingConst.GAIN_CARD_AFTER, mock)
	return mock


## 找一张指定 action_type 的行动牌 def_id（cdb 已加载全部行动牌）。
func _find_action_def_id(cdb, want_type: String) -> String:
	for def in cdb.list_cards_by_kind(&"action"):
		if String(def.action_type) == want_type:
			return String(def.card_id)
	return ""


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：2 效果定义正确（e1 按钮宣言弹单选 / e2 隐藏抽牌检查）
func test_p043_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()

	var e1 = effs.get(&"pilot_043_effect_01")
	if e1 == null:
		return "缺 pilot_043_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN"
	if e1.listen_timing != _TimingConst.GAIN_CARD_BEFORE:
		return "effect_01 应监听 GAIN_CARD_BEFORE"
	if String(e1.listen_action_type) != "gain_card":
		return "effect_01 listen_action_type 应 gain_card"
	if e1.hide_button:
		return "effect_01 应是可见按钮"
	var ops1: Array = []
	for c in e1.conditions:
		ops1.append(String(c.get("op", &"")))
	for want in ["GAIN_CARD_IS_DRAW", "GAIN_CARD_IS_ACTION_DRAW", "GAIN_CARD_DRAW_OWNER_IS_BINDING"]:
		if not ops1.has(want):
			return "effect_01 缺条件 %s" % want
	if e1.actions.is_empty() or String(e1.actions[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 actions[0] 应 CHOOSE_ONE"
	var p1: Dictionary = e1.actions[0].get("params", {})
	if not p1.get("optional", false):
		return "effect_01 CHOOSE_ONE 应 optional（可取消）"
	if String(p1.get("store_record_key", &"")) != "declared_action_type":
		return "effect_01 CHOOSE_ONE 应 store_record_key=declared_action_type"
	var opts1: Array = p1.get("options", [])
	if opts1.size() != 3:
		return "effect_01 应有 3 个宣言选项 实=%d" % opts1.size()
	for oi in range(opts1.size()):
		var want_val: String = ["攻击", "迎击", "辅助"][oi]
		if String(opts1[oi].get("value", &"")) != want_val:
			return "选项 %d value 应 %s" % [oi, want_val]

	var e2 = effs.get(&"pilot_043_effect_02")
	if e2 == null:
		return "缺 pilot_043_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN"
	if e2.listen_timing != _TimingConst.GAIN_CARD_AFTER:
		return "effect_02 应监听 GAIN_CARD_AFTER"
	if String(e2.listen_action_type) != "gain_card":
		return "effect_02 listen_action_type 应 gain_card"
	if not e2.hide_button:
		return "effect_02 应 hide_button"
	if int(e2.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1（并入按钮描述）"
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	for want in ["GAIN_CARD_IS_DRAW", "GAIN_CARD_IS_ACTION_DRAW", "GAIN_CARD_DRAW_OWNER_IS_BINDING", "GAIN_CARD_DRAWN_INCLUDE_RECORD_ACTION_TYPE"]:
		if not ops2.has(want):
			return "effect_02 缺条件 %s" % want
	var dirc_found := false
	for c in e2.conditions:
		if String(c.get("op", &"")) == "GAIN_CARD_DRAWN_INCLUDE_RECORD_ACTION_TYPE":
			if String(c.get("params", {}).get("record_key", &"")) != "declared_action_type":
				return "effect_02 类型匹配条件 record_key 应 declared_action_type"
			dirc_found = true
	if not dirc_found:
		return "effect_02 缺 GAIN_CARD_DRAWN_INCLUDE_RECORD_ACTION_TYPE"
	if e2.actions.is_empty() or String(e2.actions[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_02 actions[0] 应 EXECUTE_GAIN_CARD"
	var p2: Dictionary = e2.actions[0].get("params", {})
	if String(p2.get("from_zone", &"")) != "action_deck" or String(p2.get("card_kind", &"")) != "action" or int(p2.get("count", 0)) != 1:
		return "effect_02 EXECUTE_GAIN_CARD 应抽 1 张行动牌（action_deck）"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：真实我方抽取行动牌 -> GAIN_CARD_BEFORE 预打抽取标并弹宣言单选；取消 -> 手牌+1 无递归
func test_p043_real_draw_popup_and_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# 真实我方抽取 1 张行动牌（gain_card 动作）-> extract_info 预打标 -> BEFORE 弹宣言窗挂起
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p043_draw",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(4)
	var aid := _find_pending_action(battle, "pre_actions_target")
	if aid == &"":
		return "我方抽取行动牌应挂起宣言单选窗"

	# 挂起动作 = gain_card 本身，record 已含预打抽取标
	var act = battle.context.action_registry.get_action(aid)
	if act == null:
		return "挂起动作不可取"
	if not act.record.get("draw", false):
		return "gain_card 预打抽取标 draw 应 true"
	if String(act.record.get("draw_card_kind", &"")) != "action":
		return "draw_card_kind 应 action 实=%s" % String(act.record.get("draw_card_kind", &""))
	if String(act.record.get("draw_player_id", &"")) != "player":
		return "draw_player_id 应 player 实=%s" % String(act.record.get("draw_player_id", &""))
	var dmids: Array = act.record.get("draw_mech_ids", [])
	if not dmids.has(s.mech.mech_id):
		return "draw_mech_ids 应含我方机甲"

	# 取消宣言 -> 不写 record、无后续抽牌；本动作抽到的 1 张照常入左手牌
	battle.context.timing_engine.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(8)
	if act.record.has("declared_action_type"):
		return "取消宣言不应写 declared_action_type"
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "取消宣言后本动作应抽到 1 张 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试3：mock BEFORE 弹窗 -> 选择"攻击" -> record 写入 declared_action_type=攻击
func test_p043_declare_writes_record() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context

	var mock := _fire_gain_card_before(battle, {
		"draw": true, "draw_card_kind": &"action",
		"mech_ids": [s.mech.mech_id], "draw_player_id": &"player", "draw_mech_ids": [s.mech.mech_id],
	})
	if mock == null:
		return "mock gain_card BEFORE 未创建"
	await _pump_frames(2)
	var aid := _find_pending_action(battle, "pre_actions_target")
	if aid == &"":
		return "BEFORE 应挂起宣言单选窗"
	if aid != mock.action_id:
		return "挂起动作应即 mock 本动作 实=%s" % String(aid)
	battle.context.timing_engine.resume_pending_effect(aid, {"chosen_option_index": 0})
	await _pump_frames(3)
	if String(mock.record.get("declared_action_type", &"")) != "攻击":
		return "选择攻击后 record.declared_action_type 应=攻击 实=%s" % String(mock.record.get("declared_action_type", &""))
	return true


## 测试4：mock BEFORE 弹窗 -> 取消 -> 不写 record（无后续）
func test_p043_cancel_writes_nothing() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context

	var mock := _fire_gain_card_before(battle, {
		"draw": true, "draw_card_kind": &"action",
		"mech_ids": [s.mech.mech_id], "draw_player_id": &"player", "draw_mech_ids": [s.mech.mech_id],
	})
	await _pump_frames(2)
	var aid := _find_pending_action(battle, "pre_actions_target")
	if aid == &"":
		return "BEFORE 应挂起宣言单选窗"
	battle.context.timing_engine.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(3)
	if mock.record.has("declared_action_type"):
		return "取消宣言不应写 declared_action_type"
	return true


## 测试5：mock AFTER 命中（drawn 含宣言类型）-> 触发再抽 1 张行动牌
## （effect_02 触发 EXECUTE_GAIN_CARD 子动作；子动作 BEFORE 又弹窗挂起 -> 取消子动作宣言
##   以可控收尾 -> 本动作抽到 1 张 + 子动作抽到 1 张）
func test_p043_after_match_triggers_extra_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	battle.context.action_ui_bridge.context = battle.context

	var atk_def_id := _find_action_def_id(cdb, "攻击")
	if atk_def_id == "":
		return "cdb 无攻击行动牌"
	var atk_card = _make_instance(gs, cdb, atk_def_id, &"player")
	if atk_card == null:
		return "攻击牌实例创建失败"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	var mock := _fire_gain_card_after(battle, {
		"draw": true, "draw_card_kind": &"action",
		"mech_ids": [s.mech.mech_id], "draw_player_id": &"player", "draw_mech_ids": [s.mech.mech_id],
		"declared_action_type": &"攻击", "drawn_card_ids": [atk_card.instance_id],
	})
	if mock == null:
		return "mock gain_card AFTER 未创建"
	await _pump_frames(4)
	# effect_02 触发 EXECUTE_GAIN_CARD 子动作 -> 子动作 BEFORE 弹窗挂起
	var aid := _find_pending_action(battle, "pre_actions_target")
	if aid == &"":
		return "命中宣言类型应触发再抽子动作（其 BEFORE 应弹窗挂起）"
	battle.context.timing_engine.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(8)
	# 本动作(drawn 的 atk_card 未真正入左手，仅 mock)不计数；子动作抽到 1 张真实行动牌
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "命中宣言类型应再抽 1 张行动牌 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试6：mock AFTER 不含宣言类型 -> 不触发（drawn 只含非宣言类型）
func test_p043_after_no_match_no_extra() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	battle.context.action_ui_bridge.context = battle.context

	var non_def_id := _find_action_def_id(cdb, "迎击")
	if non_def_id == "":
		non_def_id = _find_action_def_id(cdb, "辅助")
	if non_def_id == "":
		return "cdb 无迎击/辅助行动牌"
	var non_card = _make_instance(gs, cdb, non_def_id, &"player")
	if non_card == null:
		return "非宣言类型牌实例创建失败"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	var mock := _fire_gain_card_after(battle, {
		"draw": true, "draw_card_kind": &"action",
		"mech_ids": [s.mech.mech_id], "draw_player_id": &"player", "draw_mech_ids": [s.mech.mech_id],
		"declared_action_type": &"攻击", "drawn_card_ids": [non_card.instance_id],
	})
	if mock == null:
		return "mock gain_card AFTER 未创建"
	await _pump_frames(6)
	if _find_pending_action(battle, "pre_actions_target") != &"":
		return "不含宣言类型不应触发再抽（无挂起）"
	if gs.players.get(&"player").action_hand.size() != player_before:
		return "不含宣言类型不应再抽 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试7：敌方抽取行动牌 -> 不弹窗（抽取方 != 格温拥有者）
func test_p043_enemy_draw_no_popup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	var enemy_before: int = gs.players.get(&"enemy").action_hand.size()

	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"enemy", "mech_ids": [s.enemy_mech.mech_id], "reason": &"test_p043_enemy",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card(敌方) 未创建"
	await _pump_frames(6)
	if _find_pending_action(battle, "pre_actions_target") != &"":
		return "敌方抽取不应弹宣言窗（owner 条件排除）"
	if gs.players.get(&"enemy").action_hand.size() != enemy_before + 1:
		return "敌方本动作应抽到 1 张 实增=%d" % (gs.players.get(&"enemy").action_hand.size() - enemy_before)
	return true


## 测试8：我方抽取装备牌 -> 不弹窗（draw_card_kind=equipment 非行动牌抽取）
func test_p043_equipment_draw_no_popup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context

	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p043_equip",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card(装备) 未创建"
	await _pump_frames(6)
	if _find_pending_action(battle, "pre_actions_target") != &"":
		return "装备抽取不应弹宣言窗（IS_ACTION_DRAW 排除）"
	return true


## 测试9：回忆（从弃牌堆抽行动牌）同样触发宣言窗；取消后照常抽到 1 张
func test_p043_recall_draw_also_popups() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	battle.context.action_ui_bridge.context = battle.context

	# 弃牌堆塞入 1 张行动牌保证可抽（从行动牌堆借 1 张到弃牌堆）
	if gs.deck_state.action_deck.is_empty():
		return "行动牌堆空，无法测回忆抽"
	var borrow: StringName = gs.deck_state.action_deck[0]
	gs.deck_state.action_deck.remove_at(0)
	gs.deck_state.action_discard_pile.push_front(borrow)
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# 回忆：from_zone=action_discard + random=true（随机从弃牌堆取，走 _resolve_card_sources，
	#   与规则一致）-> card_ids 空 = 抽取，打 draw 标
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_discard", "card_kind": &"action", "count": 1, "random": true,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p043_recall",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card(回忆) 未创建"
	await _pump_frames(4)
	var aid := _find_pending_action(battle, "pre_actions_target")
	if aid == &"":
		return "回忆抽取也应挂起宣言单选窗"
	battle.context.timing_engine.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(8)
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "回忆抽取取消宣言后应抽到 1 张 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试10：连续宣言链路——宣言攻击命中 -> 再抽子动作 -> 子动作再宣言（递归机会）
## 子动作抽到 deck 顶部的迎击牌（push_front 控制）-> 与"攻击"不符 -> 递归终止，仅多抽 1 张
func test_p043_recursive_redeclare_chain() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_gwen(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	battle.context.action_ui_bridge.context = battle.context

	var atk_def_id := _find_action_def_id(cdb, "攻击")
	var await_def_id := _find_action_def_id(cdb, "迎击")
	if await_def_id == "":
		await_def_id = _find_action_def_id(cdb, "辅助")
	if atk_def_id == "" or await_def_id == "":
		return "cdb 缺攻击/迎击(或辅助)行动牌"
	var atk_card = _make_instance(gs, cdb, atk_def_id, &"player")
	if atk_card == null:
		return "攻击牌实例创建失败"
	# 子动作将抽到 deck 顶部这张迎击牌（≠宣言"攻击"），可控终止递归
	var await_card = _make_instance(gs, cdb, await_def_id, &"player")
	if await_card == null:
		return "迎击牌实例创建失败"
	gs.deck_state.action_deck.push_front(await_card.instance_id)
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# ① mock BEFORE：选"攻击" -> 写入 declared_action_type
	var mock := _fire_gain_card_before(battle, {
		"draw": true, "draw_card_kind": &"action",
		"mech_ids": [s.mech.mech_id], "draw_player_id": &"player", "draw_mech_ids": [s.mech.mech_id],
	})
	await _pump_frames(2)
	var aid1 := _find_pending_action(battle, "pre_actions_target")
	if aid1 == &"":
		return "第一抽 BEFORE 应挂起宣言单选窗"
	battle.context.timing_engine.resume_pending_effect(aid1, {"chosen_option_index": 0})
	await _pump_frames(3)
	if String(mock.record.get("declared_action_type", &"")) != "攻击":
		return "第一抽宣言应=攻击"

	# ② mock AFTER：drawn 含攻击牌 -> 触发再抽子动作
	mock.record["drawn_card_ids"] = [atk_card.instance_id]
	battle.context.timing_engine.fire_timing(_TimingConst.GAIN_CARD_AFTER, mock)
	await _pump_frames(4)
	var aid2 := _find_pending_action(battle, "pre_actions_target")
	if aid2 == &"":
		return "命中宣言类型应触发再抽子动作（其 BEFORE 应弹窗挂起）"
	if aid2 == aid1:
		return "再抽子动作应是独立新动作"
	# ③ 子动作宣言（递归机会）：选"攻击" -> 子动作 transfer 抽到 deck 顶部迎击牌 -> 不命中终止
	battle.context.timing_engine.resume_pending_effect(aid2, {"chosen_option_index": 0})
	await _pump_frames(8)
	# 本动作(drawn 的 atk_card 仅 mock)不计数；子动作抽到 1 张迎击牌；不命中不再递归
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "递归链路应恰好多抽 1 张（迎击牌）实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	if _find_pending_action(battle, "pre_actions_target") != &"":
		return "不命中宣言类型后不应再挂起"
	return true
