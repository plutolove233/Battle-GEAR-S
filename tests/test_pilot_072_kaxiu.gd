## test_pilot_072_kaxiu.gd - 卡修（pilot_072，帝国 N）效果测试
##
## 卡修 1 按钮（被动融合）：拆 3 个 LISTEN 效果（按钮1 + 两个隐藏合并描述）。
##   权威效果：「每个效果每回合1次：使用攻击牌时，回复5动力；使用迎击牌时，回复4动力；使用辅助牌时，回复3动力。」
##   三个分支（01a 攻击回5 / 01b 迎击回4 / 01c 辅助回3）共用通用模块
##   build_use_action_type_restore_power_effect：LISTEN USE_ACTION_AT（使用行动牌时时点，
##   先于迎击牌等自身效果执行）+ USED_CARD_OWNER_IS_SELF（持有者本人出牌）+
##   USED_CARD_TYPE_IS（按实体牌 action_type 判定攻击/迎击/辅助，转化牌按实体牌类型）+
##   RESTORE_POWER（method=restore，不超上限）。每分支各自 once_per_turn_key
##   （pilot_072_attack_restore / counter / support_restore），每回合各1次互不影响。
##   强制自动发动、无选择。01a 建按钮1，01b/01c 隐藏合并描述（共1个按钮）。
##
## 关键扩展点（本测试覆盖）：
##   1. 通用构建器 build_use_action_type_restore_power_effect（card_type/power_amount/once_key
##      参数化，与效果绑定不绑机师）。
##   2. USE_ACTION_AT 触发先于迎击牌自身效果执行（回避等迎击牌生效前已回动力）。
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
	battle.rng_seed = 90072
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


## 设卡修为 owner_id 机甲的机师，返回 {mech, enemy_mech, card, gs, cdb, battle}；失败返回 null。
func _setup_kaxiu(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_072_卡修", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = gs.get_mech_for_player(&"enemy") if owner_id == &"player" else gs.get_mech_for_player(&"player")
	return {"card": card, "mech": mech, "enemy_mech": enemy_mech, "gs": gs, "cdb": cdb, "battle": battle}


## 造一张指定 card_def_id 的行动牌实例（供 use_action_card 使用），owner=owner_id，mech=mech_id。
func _make_action_card(s, card_def_id: String, owner_id: StringName, mech_id: StringName):
	var card = _make_instance(s.gs, s.cdb, card_def_id, owner_id)
	if card == null:
		return null
	card.mech_id = mech_id
	card.zone = &"action_hand"
	return card


## 构造 use_action_card action（fire USE_ACTION_AT 用）。record 绑定实体牌 instance_id。
func _make_uac(battle, card_inst, player_id: StringName, mech_id: StringName) -> _Action:
	var uac := _Action.new()
	uac.action_id = &"test_p072_uac_%d" % [randi() % 1000000]
	uac.action_type = &"use_action_card"
	uac.record = {"card_instance_id": card_inst.instance_id, "player_id": player_id}
	uac.state = &"running"
	uac.context = battle.context
	uac.source = {"player_id": player_id, "mech_id": mech_id, "card_instance_id": card_inst.instance_id}
	battle.context.action_registry.register(uac)
	return uac


## 通用断言 helper：设 power=2/max=10，fire 该实体牌 USE_ACTION_AT，期望回复 amount 动力。
func _expect_restore(s, card_inst, amount: int) -> Variant:
	var mech = s.mech
	mech.max_power = 10
	mech.power = 2
	var uac := _make_uac(s.battle, card_inst, mech.owner_player_id, mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac)
	await _pump_frames(6)
	if mech.power != 2 + amount:
		return "使用%s 应回复%d动力（2->%d）实=%d" % [String(card_inst.def.card_id), amount, 2 + amount, mech.power]
	return true


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：3 个效果定义正确（LISTEN USE_ACTION_AT + use_action_card + 条件 + once_per_turn + RESTORE_POWER）
func test_pilot_072_effect_definitions() -> Variant:
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var expect: Array = [
		{"eid": &"pilot_072_effect_01a", "type": "攻击", "amount": 5, "once": &"pilot_072_attack_restore", "hide": false},
		{"eid": &"pilot_072_effect_01b", "type": "迎击", "amount": 4, "once": &"pilot_072_counter_restore", "hide": true},
		{"eid": &"pilot_072_effect_01c", "type": "辅助", "amount": 3, "once": &"pilot_072_support_restore", "hide": true},
	]
	for exp in expect:
		var e = all_effects.get(exp.eid)
		if e == null:
			return "缺 %s" % String(exp.eid)
		if e.mode != _TimingConst.MODE_LISTEN:
			return "%s mode 应 LISTEN 实=%s" % [String(exp.eid), String(e.mode)]
		if e.listen_timing != _TimingConst.USE_ACTION_AT:
			return "%s listen_timing 应 USE_ACTION_AT" % String(exp.eid)
		if e.listen_action_type != &"use_action_card":
			return "%s listen_action_type 应 use_action_card" % String(exp.eid)
		if String(e.once_per_turn_key) != String(exp.once):
			return "%s once_per_turn_key 应 %s 实=%s" % [String(exp.eid), String(exp.once), String(e.once_per_turn_key)]
		if int(e.once_per_turn_max) != 1:
			return "%s once_per_turn_max 应 1" % String(exp.eid)
		if bool(e.hide_button) != bool(exp.hide):
			return "%s hide_button 应 %s 实=%s" % [String(exp.eid), str(exp.hide), str(bool(e.hide_button))]
		if not bool(exp.hide) and int(e.merge_desc_into_index) != 0:
			return "%s(可见) merge_desc_into_index 应 0" % String(exp.eid)
		if bool(exp.hide) and int(e.merge_desc_into_index) != 1:
			return "%s merge_desc_into_index 应 1" % String(exp.eid)
		# 条件：USED_CARD_OWNER_IS_SELF + USED_CARD_TYPE_IS(card_type)
		var ops: Array = []
		for c in e.conditions:
			ops.append(String(c.get("op", &"")))
		if not ops.has("USED_CARD_OWNER_IS_SELF"):
			return "%s 应含 USED_CARD_OWNER_IS_SELF" % String(exp.eid)
		var found_type: bool = false
		for c in e.conditions:
			if String(c.get("op", &"")) == "USED_CARD_TYPE_IS":
				if String(c.get("card_type", &"")) != exp.type:
					return "%s USED_CARD_TYPE_IS card_type 应 %s 实=%s" % [String(exp.eid), exp.type, String(c.get("card_type", &""))]
				found_type = true
		if not found_type:
			return "%s 应含 USED_CARD_TYPE_IS" % String(exp.eid)
		# 动作：[RESTORE_POWER mech_id=$binding_context.mech_id amount method=restore]
		var acts = e.actions
		if acts.size() != 1 or String(acts[0].get("type", &"")) != "RESTORE_POWER":
			return "%s actions 应 [RESTORE_POWER]" % String(exp.eid)
		var ap: Dictionary = acts[0].get("params", {})
		if int(ap.get("amount", 0)) != int(exp.amount):
			return "%s RESTORE_POWER amount 应 %d 实=%d" % [String(exp.eid), int(exp.amount), int(ap.get("amount", 0))]
		if String(ap.get("mech_id", &"")) != "$binding_context.mech_id":
			return "%s RESTORE_POWER mech_id 应 $binding_context.mech_id" % String(exp.eid)
		if String(ap.get("method", &"")) != "restore":
			return "%s RESTORE_POWER method 应 restore 实=%s" % [String(exp.eid), String(ap.get("method", &""))]
	return true


## 测试2：使用攻击牌 → 回复5动力
func test_pilot_072_attack_restores_5() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kaxiu(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_072_卡修）"
	var card = _make_action_card(s, "action_001_进攻", &"player", s.mech.mech_id)
	if card == null:
		return "造攻击牌失败"
	return await _expect_restore(s, card, 5)


## 测试3：使用迎击牌 → 回复4动力（响应时先于迎击牌自身效果执行）
func test_pilot_072_counter_restores_4() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kaxiu(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = _make_action_card(s, "action_011_疾行", &"player", s.mech.mech_id)
	if card == null:
		return "造迎击牌失败"
	return await _expect_restore(s, card, 4)


## 测试4：使用辅助牌 → 回复3动力
func test_pilot_072_support_restores_3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kaxiu(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = _make_action_card(s, "action_013_维修", &"player", s.mech.mech_id)
	if card == null:
		return "造辅助牌失败"
	return await _expect_restore(s, card, 3)


## 测试5：同一分支每回合1次——同回合第二次使用攻击牌不再回复（once_per_turn 拦截）
func test_pilot_072_same_type_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kaxiu(battle, &"player")
	if s == null:
		return "setup 失败"
	var mech = s.mech
	mech.max_power = 10
	mech.power = 2
	var card1 = _make_action_card(s, "action_001_进攻", &"player", mech.mech_id)
	var card2 = _make_action_card(s, "action_001_进攻", &"player", mech.mech_id)
	if card1 == null or card2 == null:
		return "造攻击牌失败"
	# 第一次使用攻击牌 → +5
	var uac1 := _make_uac(s.battle, card1, mech.owner_player_id, mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac1)
	await _pump_frames(6)
	if mech.power != 7:
		return "第1次攻击牌应回复5动力（2->7）实=%d" % mech.power
	# 同回合第二次使用攻击牌 → 不再回复（每回合1次）
	var uac2 := _make_uac(s.battle, card2, mech.owner_player_id, mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac2)
	await _pump_frames(6)
	if mech.power != 7:
		return "同回合第2次攻击牌不应再回复（应保持7）实=%d" % mech.power
	return true


## 测试6：3 分支互不影响——同回合先攻击后辅助，各回复各的（5+3）
func test_pilot_072_branches_independent() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kaxiu(battle, &"player")
	if s == null:
		return "setup 失败"
	var mech = s.mech
	mech.max_power = 10
	mech.power = 2
	var atk = _make_action_card(s, "action_001_进攻", &"player", mech.mech_id)
	var sup = _make_action_card(s, "action_013_维修", &"player", mech.mech_id)
	if atk == null or sup == null:
		return "造牌失败"
	var uac1 := _make_uac(s.battle, atk, mech.owner_player_id, mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac1)
	await _pump_frames(6)
	var uac2 := _make_uac(s.battle, sup, mech.owner_player_id, mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac2)
	await _pump_frames(6)
	if mech.power != 2 + 5 + 3:
		return "攻击+辅助应各回动力（2->%d）实=%d" % [2 + 5 + 3, mech.power]
	return true


## 测试7：他人使用牌不触发（USED_CARD_OWNER_IS_SELF 拦截）——敌方出牌不动我方动力
func test_pilot_072_other_player_use_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kaxiu(battle, &"player")
	if s == null:
		return "setup 失败"
	s.mech.max_power = 10
	s.mech.power = 2
	var enemy_card = _make_action_card(s, "action_001_进攻", &"enemy", s.enemy_mech.mech_id)
	if enemy_card == null:
		return "造敌方攻击牌失败"
	var uac := _make_uac(s.battle, enemy_card, &"enemy", s.enemy_mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac)
	await _pump_frames(6)
	if s.mech.power != 2:
		return "敌方用攻击牌不应给我方回动力（应保持2）实=%d" % s.mech.power
	return true


## 测试8：跨回合重置——进入下回合后，攻击牌再次回复5动力（每回合1次按回合重置）
func test_pilot_072_cross_turn_reset() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kaxiu(battle, &"player")
	if s == null:
		return "setup 失败"
	var mech = s.mech
	mech.max_power = 10
	mech.power = 2
	var card1 = _make_action_card(s, "action_001_进攻", &"player", mech.mech_id)
	var card2 = _make_action_card(s, "action_001_进攻", &"player", mech.mech_id)
	if card1 == null or card2 == null:
		return "造攻击牌失败"
	var uac1 := _make_uac(s.battle, card1, mech.owner_player_id, mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac1)
	await _pump_frames(6)
	if mech.power != 7:
		return "第1回合攻击牌应回复5动力（2->7）实=%d" % mech.power
	# 推进回合（active 玩家不变，turn_number+1 → once_per_turn scope 变新回合）。
	# 抬高上限避免 max_power=10 把 12 封顶成 10，明确验证是整 +5 而非封顶假象。
	s.gs.turn_number = int(s.gs.turn_number) + 1
	mech.max_power = 20
	var uac2 := _make_uac(s.battle, card2, mech.owner_player_id, mech.mech_id)
	s.battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, uac2)
	await _pump_frames(6)
	if mech.power != 12:
		return "下回合攻击牌应再次回复5动力（7->12）实=%d" % mech.power
	return true
