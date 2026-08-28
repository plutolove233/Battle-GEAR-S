## test_pilot_016_murdock.gd - 默多克（pilot_016）效果1测试
##
## 展示转化（被动监听 USE_ACTION_BEFORE，显示说明按钮）：
## 每玩家回合1次，使用行动牌前可展示此牌，将另外1张行动牌当作此牌使用（转化机制）。
## 流程：CHOOSE_ONE optional 询问 -> 确认 -> PILOT_016_SHOW_AND_CONVERT（展示牌A给其他玩家 +
##   选1张B排除牌A + 改造父record为B当牌A virtual_transform）。
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
	battle.rng_seed = 90016
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


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


func _set_pilot_on_mech(battle, owner_id: StringName, mech, pilot_def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, pilot_def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return card


func _clear_action_hand(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var p = gs.players.get(pid)
	if p == null:
		return
	for cid in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


func _add_card_to_hand(battle, pid: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, pid)
	if card == null:
		return &""
	card.zone = &"hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 构造 use_action_card action（牌A，主动使用，无 attack_action_id）
func _make_use_action(battle, card_id: StringName, player_id: StringName, mech_id: StringName) -> _Action:
	var ua := _Action.new()
	ua.action_id = &"test_p016u_%d" % [randi() % 1000000]
	ua.action_type = &"use_action_card"
	ua.record = {
		"card_instance_id": card_id,
		"player_id": player_id,
		"mech_id": mech_id,
	}
	ua.state = &"running"
	ua.context = battle.context
	ua.source = {"mech_id": mech_id, "player_id": player_id, "card_instance_id": card_id}
	battle.context.action_registry.register(ua)
	return ua


func _disconnect_needs_input(te) -> void:
	for _c in te.action_needs_input.get_connections():
		te.action_needs_input.disconnect(_c.callable)


## 设默多克机师到 player 机甲，返回 {gs, mech, pilot_card}
func _setup_murdoch(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var pilot_card = _set_pilot_on_mech(battle, owner_id, mech, "pilot_016_默多克")
	if pilot_card == null:
		return {}
	return {"gs": gs, "mech": mech, "pilot_card": pilot_card}


# ═══════════════════════════════════════════
# 白盒：效果定义
# ═══════════════════════════════════════════

## 测试1：效果定义结构正确
func test_p016_definition() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	var e1 = effs.get(&"pilot_016_effect_01")
	if e1 == null:
		return "缺 pilot_016_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "mode 应 LISTEN"
	if e1.listen_timing != _TimingConst.USE_ACTION_BEFORE:
		return "listen_timing 应 USE_ACTION_BEFORE"
	if e1.listen_action_type != &"use_action_card":
		return "listen_action_type 应 use_action_card"
	if int(e1.priority) != 20:
		return "priority 应 20 实=%d" % int(e1.priority)
	if e1.once_per_turn_key != &"pilot_016_effect_01":
		return "once_per_turn_key 应 pilot_016_effect_01"
	if int(e1.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1"
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("USED_CARD_EXECUTOR_IS_SELF"):
		return "应含 USED_CARD_EXECUTOR_IS_SELF"
	if not ops.has("PAYLOAD_IS_PHYSICAL_ACTION_CARD"):
		return "应含 PAYLOAD_IS_PHYSICAL_ACTION_CARD"
	if not ops.has("HAS_ACTION_CARD_IN_HAND"):
		return "应含 HAS_ACTION_CARD_IN_HAND"
	if String(e1.actions[0].get("type", &"")) != "CHOOSE_ONE":
		return "action[0] 应 CHOOSE_ONE"
	if not bool(e1.actions[0].get("params", {}).get("optional", false)):
		return "CHOOSE_ONE 应 optional"
	var options: Array = e1.actions[0].get("params", {}).get("options", [])
	if options.is_empty():
		return "CHOOSE_ONE 应有 option"
	var opt_actions: Array = options[0].get("actions", [])
	if opt_actions.is_empty() or String(opt_actions[0].get("type", &"")) != "PILOT_016_SHOW_AND_CONVERT":
		return "option action 应 PILOT_016_SHOW_AND_CONVERT"
	return true


# ═══════════════════════════════════════════
# 转化主流程
# ═══════════════════════════════════════════

## 测试2：完整转化流程（CHOOSE_ONE确认 -> 选1张B -> B当作A virtual_transform，
##  B 进临时区 -> 牌A保留手牌 -> settle 弃 B）
func test_p016_show_convert() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_murdoch(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	# player 2张手牌：牌A=进攻 + B=防御（新语义只需展示牌A+另外1张）
	_clear_action_hand(battle, &"player")
	var card_a_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var card_b_id = _add_card_to_hand(battle, &"player", "action_009_防御")
	if gs.players.get(&"player").action_hand.size() != 2:
		return "setup 应2张牌"
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	# 通过 Action Engine 完整驱动 use_action_card（牌A）。注意：必须走 execute_action，
	# 手动 fire_timing(USE_ACTION_BEFORE, ua) 的 ua 未经引擎启动，current_step_index 停留初始值，
	# resume 后 continue_action 无法推进到 card_to_temp_zone（B 进 temp_zone 依赖父动作推进）。
	var use_result: Dictionary = battle.context.action_service.execute(&"use_action_card", {
		"card_instance_id": card_a_id,
		"player_id": &"player",
		"mech_id": mech.mech_id,
		"source": {"player_id": &"player", "mech_id": mech.mech_id},
	})
	if use_result.get("state", &"") == &"error":
		return "use_action_card 发起失败: %s" % str(use_result)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	await _pump_frames(3)
	# 找父 use_action_card 动作（牌A实体，非虚拟）
	var ua: _Action = null
	for _a in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if String(_a.record.get("card_instance_id", &"")) == String(card_a_id) and not bool(_a.record.get("virtual_transform", false)):
			ua = _a
			break
	if ua == null:
		return "找不到 use_action_card 动作"
	# fire USE_ACTION_BEFORE -> pilot_016 CHOOSE_ONE 挂起
	if not te._pending_effect.has(ua.action_id):
		return "应挂起 _pending_effect（CHOOSE_ONE）"
	# resume CHOOSE_ONE 确认（option 0=展示转化）
	te.resume_pending_effect(ua.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	if not te._pending_effect.has(ua.action_id):
		return "确认后应挂起 _pending_effect（pilot_016_choose_one）"
	# resume 选1张 B
	te.resume_pending_effect(ua.action_id, {"selected_action_card_ids": [card_b_id], "cancelled": false})
	await _pump_frames(5)
	# 验证 record 改造：B 当牌A virtual_transform
	if StringName(ua.record.get("card_instance_id", &"")) != card_b_id:
		return "record.card_instance_id 应=B 实=%s" % String(ua.record.get("card_instance_id", &""))
	if String(ua.record.get("as_card_def_id", &"")) != "action_001_进攻":
		return "record.as_card_def_id 应=牌A def_id 实=%s" % String(ua.record.get("as_card_def_id", &""))
	if not bool(ua.record.get("virtual_transform", false)):
		return "record.virtual_transform 应 true"
	# 牌A 保留手牌（pilot_016 不动牌A）
	if not gs.players.get(&"player").action_hand.has(card_a_id):
		return "牌A 应保留手牌"
	# B 进 temp_zone（父 card_to_temp_zone 移入）
	var b_card = gs.get_card(card_b_id)
	if b_card == null or String(b_card.zone) != "temp_zone":
		return "B 应在临时区(temp_zone) 实=%s" % (String(b_card.zone) if b_card != null else "null")
	# 父动作继续 execute_effects -> 创建虚拟进攻子动作（attack 挂起选目标）。enemy 在远处
	# 无可选目标，取消攻击子动作，父 settle 仍弃 B（避免驱动完整攻击结算，聚焦转化语义）。
	await _pump_frames(3)
	for _atk in battle.context.action_registry.get_actions_by_type(&"attack"):
		battle.context.action_service.cancel_action(_atk.action_id)
	await _pump_frames(8)
	# 结算后：B 入弃牌堆，牌A保留手牌
	var b_final = gs.get_card(card_b_id)
	if b_final == null or String(b_final.zone) != "discard":
		return "B 应在弃牌堆（settle 后） 实=%s" % (String(b_final.zone) if b_final != null else "null")
	if not gs.deck_state.action_discard_pile.has(card_b_id):
		return "B 应在 action_discard_pile"
	if not gs.players.get(&"player").action_hand.has(card_a_id):
		return "结算后 牌A 应仍保留手牌"
	return true


## 测试3：取消 CHOOSE_ONE 不转化（牌A正常使用，once_per_turn 不 mark）
func test_p016_cancel_no_convert() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_murdoch(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var card_a_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	_add_card_to_hand(battle, &"player", "action_009_防御")
	_add_card_to_hand(battle, &"player", "action_013_维修")
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var ua := _make_use_action(battle, card_a_id, &"player", mech.mech_id)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, ua)
	await _pump_frames(3)
	if not te._pending_effect.has(ua.action_id):
		return "应挂起 CHOOSE_ONE"
	# 取消
	te.resume_pending_effect(ua.action_id, {"cancelled": true})
	await _pump_frames(3)
	# 验证：record 未改造
	if ua.record.has("virtual_transform"):
		return "取消后不应改造 record"
	# 验证：3张牌都还在手牌（未转化）
	if gs.players.get(&"player").action_hand.size() != 3:
		return "取消后手牌应3张 实=%d" % gs.players.get(&"player").action_hand.size()
	# 验证：once_per_turn 未 mark（第二次 fire 仍触发 CHOOSE_ONE）
	var ua2 := _make_use_action(battle, card_a_id, &"player", mech.mech_id)
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, ua2)
	await _pump_frames(3)
	if not te._pending_effect.has(ua2.action_id):
		return "取消不 mark once_per_turn，第二次应仍触发 CHOOSE_ONE"
	return true


## 测试4：手牌<2张不触发（条件 HAS_ACTION_CARD_IN_HAND count:2 失败）
func test_p016_fewer_than_2_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_murdoch(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var card_a_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	# 只1张牌（A），无另外可转化的牌
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	var ua := _make_use_action(battle, card_a_id, &"player", mech.mech_id)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, ua)
	await _pump_frames(3)
	if te._pending_effect.has(ua.action_id):
		return "手牌<2张不应触发 CHOOSE_ONE"
	return true


## 测试5：每回合1次（转化后同回合第二次不触发）
func test_p016_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_murdoch(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var card_a_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var card_b_id = _add_card_to_hand(battle, &"player", "action_009_防御")
	var te = battle.context.timing_engine
	_disconnect_needs_input(te)
	# 第一次转化
	var ua := _make_use_action(battle, card_a_id, &"player", mech.mech_id)
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, ua)
	await _pump_frames(3)
	te.resume_pending_effect(ua.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	te.resume_pending_effect(ua.action_id, {"selected_action_card_ids": [card_b_id], "cancelled": false})
	await _pump_frames(3)
	# 补2张牌（B 已移入临时区；牌A保留手牌，不影响新 action）
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	_add_card_to_hand(battle, &"player", "action_009_防御")
	# 第二次 fire（同回合）应被 once_per_turn 拦截
	var ua2 := _make_use_action(battle, card_a_id, &"player", mech.mech_id)
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, ua2)
	await _pump_frames(3)
	if te._pending_effect.has(ua2.action_id):
		return "同回合第二次应被 once_per_turn 拦截"
	return true
