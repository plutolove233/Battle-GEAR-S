## test_pilot_035_kumas.gd - 库马斯（pilot_035，联邦 R，cost 6, attack_limit 1, action_card_limit 4）效果测试
##
## 库马斯效果（运行时机师效果走 ActionPilotEffects 新体系）：
##   effect_01（隐藏 reset，ROUND_START priority 20）「轮始清标」：每轮开始时清除上一轮标记机甲
##     —— 上轮选择不延续；本轮不选/取消 = 本轮不监听。
##   effect_02（按钮1，ROUND_START priority 10）「狩猎契约」：每轮开始选 1 台其他机甲设为本轮标记
##     （可取消）。按钮条件 HAS_OTHER_MECH_ON_FIELD。
##   effect_03（隐藏 listen，GAIN_CARD_AFTER）「抽取联动」：标记机甲每次"抽取行动牌"时，
##     库马斯拥有者自动抽 1 张行动牌（EXECUTE_GAIN_CARD，强制无确认）。
##
## "抽取"判定用 gain_card 内部统一 draw 标（card_ids 空 + 牌堆/弃牌堆来源自动取牌）：
##   回合开始抽牌、2金购抽、效果抽牌（塔莉娅赐予/策略回收已统一走 gain_card）命中；
##   觉醒（选牌获取）、识破偷牌（steal_action_card）、给予转移（transfer）天然不命中。
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
	battle.rng_seed = 90035
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	# 默认玩家/敌方均 is_human=true（库马斯 ROUND_START 选目标弹窗需要人类玩家路径）
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


## 设库马斯为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, enemy_mech}
func _setup_kumas(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_035_库马斯", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {
		"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb,
		"enemy_mech": gs.get_mech_for_player(&"enemy"),
	}


## 构造 turn 虚拟 action（fire ROUND_START 用；action_type 须与 TurnService._fire_timing 一致 &"turn"）。
func _make_turn_action(battle, turn_owner: StringName) -> _Action:
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p035_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": turn_owner}
	turn_action.state = &"running"
	turn_action.context = battle.context
	battle.context.action_registry.register(turn_action)
	return turn_action


## 在 _pending_effect 中找 phase 匹配的挂起 effect 动作 id；无返回 &""。
func _find_pending_action(battle, phase: String) -> StringName:
	var pending: Dictionary = battle.context.timing_engine._pending_effect
	for aid: StringName in pending:
		if String(pending[aid].get("phase", &"")) == phase:
			return aid
	return &""


## 驱动库马斯轮始选择：fire ROUND_START -> e1 清标 -> e2 弹目标选择窗。
## target_mech_id 非空 = 选中标记；空 + cancel=true = 取消（本轮不选）。
## 返回是否成功挂起目标选择（无其他机甲或无弹窗返回 false）。
func _drive_round_start(battle, target_mech_id: StringName = &"", cancel: bool = false) -> bool:
	var te = battle.context.timing_engine
	var turn_action := _make_turn_action(battle, &"player")
	te.fire_timing(_TimingConst.ROUND_START, turn_action)
	var aid := _find_pending_action(battle, "pre_actions_target")
	if aid == &"":
		return false
	if cancel:
		te.resume_pending_effect(aid, {"cancelled": true})
	else:
		te.resume_pending_effect(aid, {"target_id": target_mech_id})
	await _pump_frames(3)
	return true


## 构造并 fire 一个 mock gain_card 的 GAIN_CARD_AFTER 时点（直接测 e3 监听条件）。
## record_extra 合并进 record（draw/draw_card_kind/draw_mech_ids 等）。
## 返回 mock action（供检查 effect 是否挂起/子动作是否创建）。
func _fire_gain_card_after(battle, record_extra: Dictionary = {}) -> _Action:
	var mock := _Action.new()
	mock.action_id = &"test_p035_gc_%d" % [randi() % 1000000]
	mock.action_type = &"gain_card"
	mock.record = record_extra
	mock.state = &"running"
	mock.context = battle.context
	battle.context.action_registry.register(mock)
	battle.context.timing_engine.fire_timing(_TimingConst.GAIN_CARD_AFTER, mock)
	return mock


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：3 效果定义正确（e1 隐藏清标 / e2 按钮选目标 / e3 隐藏抽取联动）
func test_p035_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	var e1 = effs.get(&"pilot_035_effect_01")
	if e1 == null:
		return "缺 pilot_035_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN"
	if e1.listen_timing != _TimingConst.ROUND_START:
		return "effect_01 应监听 ROUND_START"
	if String(e1.listen_action_type) != "turn":
		return "effect_01 listen_action_type 应 turn"
	if int(e1.priority) != 20:
		return "effect_01 priority 应 20（先于选择清上轮标）实=%d" % int(e1.priority)
	if not e1.hide_button:
		return "effect_01 应 hide_button"
	if int(e1.merge_desc_into_index) != 1:
		return "effect_01 merge_desc_into_index 应 1"
	var a1: Array = []
	for c in e1.actions:
		a1.append(String(c.get("type", &"")))
	if not a1.has("PILOT_035_CLEAR_MARK"):
		return "effect_01 actions 应含 PILOT_035_CLEAR_MARK"

	var e2 = effs.get(&"pilot_035_effect_02")
	if e2 == null:
		return "缺 pilot_035_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN"
	if e2.listen_timing != _TimingConst.ROUND_START:
		return "effect_02 应监听 ROUND_START"
	if int(e2.priority) != 10:
		return "effect_02 priority 应 10"
	if e2.hide_button:
		return "effect_02 应是可见按钮"
	var trs2: Array = []
	for r in e2.target_rules:
		trs2.append(String(r.get("rule", &"")))
	if not trs2.has("CHOOSE_OTHER_MECH"):
		return "effect_02 目标规则应含 CHOOSE_OTHER_MECH"
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("HAS_OTHER_MECH_ON_FIELD"):
		return "effect_02 应含 HAS_OTHER_MECH_ON_FIELD 条件"
	var a2: Array = []
	for c in e2.actions:
		a2.append(String(c.get("type", &"")))
	if not a2.has("PILOT_035_SET_MARK"):
		return "effect_02 actions 应含 PILOT_035_SET_MARK"

	var e3 = effs.get(&"pilot_035_effect_03")
	if e3 == null:
		return "缺 pilot_035_effect_03"
	if e3.mode != _TimingConst.MODE_LISTEN:
		return "effect_03 mode 应 LISTEN"
	if e3.listen_timing != _TimingConst.GAIN_CARD_AFTER:
		return "effect_03 应监听 GAIN_CARD_AFTER"
	if String(e3.listen_action_type) != "gain_card":
		return "effect_03 listen_action_type 应 gain_card"
	if not e3.hide_button:
		return "effect_03 应 hide_button"
	var ops3: Array = []
	for c in e3.conditions:
		ops3.append(String(c.get("op", &"")))
	for want in ["PILOT_035_MARK_ACTIVE", "GAIN_CARD_IS_DRAW", "GAIN_CARD_IS_ACTION_DRAW", "PILOT_035_DRAW_MECH_IS_MARKED"]:
		if not ops3.has(want):
			return "effect_03 缺条件 %s" % want
	var a3: Array = []
	for c in e3.actions:
		a3.append(String(c.get("type", &"")))
	if not a3.has("EXECUTE_GAIN_CARD"):
		return "effect_03 actions 应含 EXECUTE_GAIN_CARD"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：ROUND_START 选目标 -> 标记设置；取消 -> 无标记
func test_p035_round_start_select_and_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	# 选 enemy 机甲 -> 标记应设置
	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	if _ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id) != enemy_mech.mech_id:
		return "选中后标记应 = enemy 机甲 实=%s" % String(_ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id))

	# 再次 ROUND_START（e1 先清标）-> 取消选择 -> 无标记（本轮不监听）
	var ok2 := await _drive_round_start(battle, &"", true)
	if not ok2:
		return "第二轮 ROUND_START 应挂起目标选择窗"
	if _ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id) != &"":
		return "取消选择后标记应清空 实=%s" % String(_ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id))
	return true


## 测试3：标记机甲真实抽取行动牌（gain_card 动作）-> 库马斯拥有者抽 1 张行动牌
func test_p035_marked_mech_draw_triggers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	var player_before: int = gs.players.get(&"player").action_hand.size()
	var enemy_before: int = gs.players.get(&"enemy").action_hand.size()

	# 标记机甲经真实 gain_card 抽 1 张行动牌（mech_ids 显式 = 抽取方机甲）
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"enemy", "mech_ids": [enemy_mech.mech_id], "reason": &"test_p035_draw",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(8)
	# 敌方抽到 1 张（本动作）
	if gs.players.get(&"enemy").action_hand.size() != enemy_before + 1:
		return "标记机甲应抽到 1 张行动牌 实增=%d" % (gs.players.get(&"enemy").action_hand.size() - enemy_before)
	# 库马斯拥有者（player）应抽 1 张行动牌
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "标记机甲抽取后库马斯拥有者应抽 1 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试4：装备抽取不触发（draw_card_kind=equipment）
func test_p035_equipment_draw_excluded() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# 标记机甲抽 1 张装备牌（真实 gain_card from_zone=equipment_deck）
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1,
		"player_id": &"enemy", "mech_ids": [enemy_mech.mech_id], "reason": &"test_p035_equip",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card(装备) 未创建"
	await _pump_frames(8)
	if gs.players.get(&"player").action_hand.size() != player_before:
		return "装备抽取不应触发库马斯抽行动牌 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试5：非标记机甲抽取行动牌不触发（draw_mech_ids != 标记机甲）
func test_p035_non_marked_mech_draw_excluded() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# 库马斯拥有者自己（非标记机甲）真实抽 1 张行动牌（draw_mech_ids = player 机甲 != 标记 enemy）
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "mech_ids": [s.mech.mech_id], "reason": &"test_p035_self_draw",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(8)
	# 自己抽到的 1 张已在手牌；库马斯不应因"自己抽取"再额外抽（标记机甲是 enemy 非自己）
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "非标记机甲抽取不应触发库马斯额外抽 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试6：觉醒（选牌获取）不触发——gain_card 带明确 card_ids 无 draw 标
func test_p035_awaken_style_select_draw_excluded() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# 模拟"觉醒"选牌获取：明确指定 card_ids（无 draw 标）。从弃牌堆取 1 张保证存在。
	var src_card_id: StringName = &""
	if not gs.deck_state.action_discard_pile.is_empty():
		src_card_id = gs.deck_state.action_discard_pile[0]
	else:
		# 从行动牌堆顶取 1 张作为"选牌获取"目标
		if gs.deck_state.action_deck.is_empty():
			return "行动牌堆/弃牌堆均空，无法测选牌获取"
		src_card_id = gs.deck_state.action_deck[0]
	# 觉醒式：card_ids 明确 + 不从牌堆自动取 -> 走 _step_transfer_card 明确牌转移分支，不打 draw 标
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"card_ids": [src_card_id], "from_zone": &"awaken_temp",
		"player_id": &"enemy", "mech_ids": [enemy_mech.mech_id], "reason": &"test_p035_awaken",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card(选牌获取) 未创建"
	await _pump_frames(8)
	if gs.players.get(&"player").action_hand.size() != player_before:
		return "选牌获取（觉醒式）不应触发库马斯抽牌 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试7：mock GAIN_CARD_AFTER 直接驱动——不满足条件（无 draw 标）不触发
func test_p035_mock_no_draw_flag_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	# 偷牌/给予等不走 gain_card 的动作天然无 draw 标：mock 一个 record 无 draw 的 gain_card AFTER
	var mock := _fire_gain_card_after(battle, {
		"mech_ids": [enemy_mech.mech_id], "draw_mech_ids": [enemy_mech.mech_id],
	})
	if mock == null:
		return "mock gain_card AFTER 未创建"
	await _pump_frames(6)
	if gs.players.get(&"player").action_hand.size() != player_before:
		return "无 draw 标不应触发库马斯抽牌 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试8：标记机甲抽取但非行动牌来源（draw_card_kind=equipment）mock 不触发
func test_p035_mock_equipment_draw_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	var mock := _fire_gain_card_after(battle, {
		"draw": true, "draw_card_kind": &"equipment",
		"mech_ids": [enemy_mech.mech_id], "draw_mech_ids": [enemy_mech.mech_id],
	})
	if mock == null:
		return "mock gain_card AFTER 未创建"
	await _pump_frames(6)
	if gs.players.get(&"player").action_hand.size() != player_before:
		return "装备抽取（draw_card_kind=equipment）不应触发 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试9：mark 已设 + draw 标 + action 来源 + 抽取方=标记机甲（mock）-> 触发库马斯抽 1
func test_p035_mock_full_match_triggers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "ROUND_START 应挂起目标选择窗"
	var player_before: int = gs.players.get(&"player").action_hand.size()

	var mock := _fire_gain_card_after(battle, {
		"draw": true, "draw_card_kind": &"action",
		"mech_ids": [enemy_mech.mech_id], "draw_mech_ids": [enemy_mech.mech_id],
	})
	if mock == null:
		return "mock gain_card AFTER 未创建"
	await _pump_frames(8)
	if gs.players.get(&"player").action_hand.size() != player_before + 1:
		return "mock 全条件命中应触发库马斯抽 1 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试10：跨轮不延续——第二轮 ROUND_START 清标后，原标记机甲抽取不再触发
func test_p035_cross_round_not_carry_over() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context

	# 第一轮：选 enemy 标记
	var ok := await _drive_round_start(battle, enemy_mech.mech_id)
	if not ok:
		return "第一轮 ROUND_START 应挂起目标选择窗"
	if _ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id) != enemy_mech.mech_id:
		return "第一轮标记未设置"

	# 第二轮 ROUND_START：e1 先清标；玩家取消选择（本轮不监听）
	var ok2 := await _drive_round_start(battle, &"", true)
	if not ok2:
		return "第二轮 ROUND_START 应挂起目标选择窗"
	if _ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id) != &"":
		return "第二轮 e1 应清掉上轮标记 实=%s" % String(_ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id))

	# 原标记机甲再抽行动牌 -> 不应触发
	var player_before: int = gs.players.get(&"player").action_hand.size()
	var gc: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"enemy", "mech_ids": [enemy_mech.mech_id], "reason": &"test_p035_round2",
	})
	if gc.get("action_id", &"") == &"":
		return "gain_card 未创建"
	await _pump_frames(8)
	if gs.players.get(&"player").action_hand.size() != player_before:
		return "跨轮清标后不应再触发 实增=%d" % (gs.players.get(&"player").action_hand.size() - player_before)
	return true


## 测试11：PVP 快照 serialize/apply 含 pilot_035_marks
func test_p035_serialize_roundtrip() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kumas(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var pilot_card = s.pilot_card
	var enemy_mech = s.enemy_mech

	_ActionPilotEffects.set_pilot_035_mark(pilot_card.instance_id, enemy_mech.mech_id)
	var data: Dictionary = _ActionPilotEffects.serialize_pilot_static()
	if not data.has("pilot_035_marks"):
		return "serialize 应含 pilot_035_marks"
	var marks: Dictionary = data["pilot_035_marks"]
	if marks.get(String(pilot_card.instance_id), {}).get("target", &"") != enemy_mech.mech_id:
		return "serialize 标记内容错误"

	# 清空后 apply 恢复
	_ActionPilotEffects.clear_pilot_035_mark(pilot_card.instance_id)
	if _ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id) != &"":
		return "clear 后应为空"
	_ActionPilotEffects.apply_pilot_static(data)
	if _ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id) != enemy_mech.mech_id:
		return "apply 后标记应恢复 = enemy 机甲 实=%s" % String(_ActionPilotEffects.get_pilot_035_mark(pilot_card.instance_id))
	return true
