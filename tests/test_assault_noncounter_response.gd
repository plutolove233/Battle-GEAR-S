## test_assault_noncounter_response.gd - 强袭·非迎击牌（装备牌）响应触发追击 测试
##
## 验证规则文档「强袭」effect2 在「非迎击牌（装备牌）响应」时也触发。
## 规则（行动牌的效果与逻辑.txt 第9-10行）：effect2 监听 ATTACK_AT，优先级 -1，
## 若本次攻击被响应则循环移动。「被响应」= 被任何效果响应都算（不限于迎击牌）。
##
## 场景：
##   1. B 设置测试装备牌（右腿，AVAILABILITY 响应：被攻击时可响应，用当前动力移动1次）
##   2. A 使用强袭牌攻击 B
##   3. ATTACK_AT 响应窗口：B 用装备牌响应（非迎击牌）-> B 移动1格
##   4. 响应窗口关闭 -> 补跑强袭 effect2（priority -1，最后结算）-> A 用当前动力追击移动
##   验证：B 装备牌效果执行（B 移动）+ A 强袭2追击移动触发（说明 responded=true 被正确写入并读取）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const SLog = preload("res://scripts/services/slog.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


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
	_ThrustHelper.clear_thrust_from_hand(battle)
	return battle


func _place_mech(battle: BattleState, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	mech.position = {"q": q, "r": r}


## 从牌堆/弃牌堆确保某张行动牌在指定玩家手里
func _ensure_card_in_player_hand(battle: BattleState, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
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
			c.owner_player_id = player_id
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = player_id
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 从装备牌堆确保某张装备牌在指定玩家装备手牌
func _ensure_equipment_in_hand(battle: BattleState, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	for cid: StringName in player.equipment_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.equipment_deck.size()):
		var cid: StringName = gs.deck_state.equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = player_id
			return cid
	return &""


## ════════════════════════════════════════════════════════════
## InputDriver：复用自 test_assault_chase_flow.gd 的输入驱动器
## ════════════════════════════════════════════════════════════

class InputDriver:
	var context = null
	var pending: Dictionary = {}
	var weapon_for: Callable = Callable()
	var target_for: Callable = Callable()
	var move_cell_for: Callable = Callable()
	var response_for: Callable = Callable()
	var damage_for: Callable = Callable()
	var frame_cb: Callable = Callable()

	func attach(ctx) -> void:
		context = ctx
		if context.action_ui_bridge != null:
			if context.action_engine != null:
				context.action_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
			if context.timing_engine != null:
				context.timing_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
		context.action_engine.action_needs_input.connect(_on_need)
		if context.timing_engine != null:
			context.timing_engine.action_needs_input.connect(_on_need)

	func _on_need(action_id: StringName, input_type: StringName, input_params: Dictionary) -> void:
		pending[action_id] = {"input_type": input_type, "input_params": input_params}

	func pump() -> bool:
		if pending.is_empty():
			return false
		var action_id: StringName = pending.keys()[0]
		var entry: Dictionary = pending[action_id]
		var input_type: StringName = entry["input_type"]
		var input_params: Dictionary = entry["input_params"]
		pending.erase(action_id)
		var input_data = _resolve(action_id, input_type, input_params)
		if input_data == null:
			return true
		context.action_service.continue_action(action_id, input_data)
		return true

	func _resolve(action_id: StringName, input_type: StringName, input_params: Dictionary):
		match input_type:
			&"select_weapon":
				return {"weapon_id": weapon_for.call(action_id)}
			&"select_attack_target":
				return {"target_id": target_for.call(action_id, input_params)}
			&"select_move_target":
				var cell: StringName = move_cell_for.call(action_id, input_params)
				if cell == &"":
					context.action_service.cancel_action(action_id)
					return null
				return {"target_cell": cell}
			&"respond_attack":
				var sel: Array[Dictionary] = response_for.call(action_id)
				context.timing_engine.handle_response_selection(action_id, sel)
				return null
			&"place_damage_tokens":
				var d: Dictionary = damage_for.call(action_id, input_params)
				if d.is_empty():
					return {"auto_placed": true}
				return d
			_:
				return {"auto": true}

	func drain(max_iters: int = 500) -> void:
		var it := 0
		while it < max_iters:
			it += 1
			var progressed: bool = pump()
			if frame_cb.is_valid():
				await frame_cb.call()
			if not pump():
				if not progressed and pending.is_empty():
					if not _has_waiting_actions():
						break
			if pending.is_empty() and not _has_waiting_actions():
				break

	func _has_waiting_actions() -> bool:
		if context == null or context.action_registry == null:
			return false
		for aid: StringName in context.action_registry.get_active_ids():
			var a = context.action_registry.get_action(aid)
			if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
				return true
		return false


## ════════════════════════════════════════════════════════════
## 场景：B 用测试装备牌（非迎击牌）响应 -> A 强袭2追击移动触发
## ════════════════════════════════════════════════════════════
func test_assault_triggers_after_equipment_response():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")   # A：强袭攻击方
	var mech_b = gs.get_mech_for_player(&"enemy")     # B：被攻击方（装备牌响应）

	# 布局：A(10,0)  B(11,0)，A 武器范围2，距离1在范围内
	_place_mech(battle, mech_a.mech_id, 10, 0)
	_place_mech(battle, mech_b.mech_id, 11, 0)

	# A 动力10（足够追击）；B 动力3（装备牌响应移动1格用1动力）
	mech_a.power = 10
	mech_b.power = 3

	# B 设置测试装备牌（右腿，AVAILABILITY 响应：被攻击时可响应移动1次）
	var b_equip := _ensure_equipment_in_hand(battle, &"enemy", "part_test_001_测试_右腿")
	if b_equip == &"":
		return "B 装备牌未找到 part_test_001"
	var set_result = battle.context.card_set_service.set_equipment(&"enemy", b_equip, &"右腿")
	if not set_result.get("ok", false):
		return "B 设置装备失败: %s" % str(set_result)
	for _i in range(5):
		await _frame()

	# A 手牌塞强袭牌
	var a_assault := _ensure_card_in_player_hand(battle, &"player", "action_002_强袭")
	if a_assault == &"":
		return "A 手牌未找到强袭牌"

	# ── InputDriver ──
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.frame_cb = _frame

	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"

	# 攻击目标：A 强袭攻击 -> 打 B
	driver.target_for = func(aid: StringName, _params: Dictionary) -> StringName:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return &""
		var attacker_id: StringName = act.record.get("attacker_id", &"")
		if attacker_id == mech_a.mech_id:
			return mech_b.mech_id
		return &""

	# 移动选格：区分 A/B
	# - B 装备牌响应：B 从(11,0)移到(12,0)（移动1格，跳出 A 范围2：距A(10,0)=2 仍在范围；改为移到13,0需2格超动力1次。
	#   装备牌效果是「用当前动力移动1次」loop_until_cancel=false，单次选格走1格即 settle。
	#   让 B 移到(12,0)（1格）。
	# - A 强袭2追击：A 从(10,0)追到(11,0)（追击1格，重新贴近 B）
	driver.move_cell_for = func(_aid: StringName, params: Dictionary) -> StringName:
		var mover_id: StringName = params.get("mech_id", &"")
		if mover_id == mech_b.mech_id:
			# B 装备牌响应移动（单次，不 loop）
			var call_count: int = _move_call_b
			_move_call_b += 1
			if call_count == 0:
				return &"12,0"
			return &""
		if mover_id == mech_a.mech_id:
			# A 强袭2追击（loop，第1次给终点，再请求取消）
			var call_count: int = _move_call_a
			_move_call_a += 1
			if call_count == 0:
				return &"11,0"
			return &""
		return &""

	# 响应窗口：A 强袭攻击（打B）-> B 用装备牌响应（非迎击牌）
	driver.response_for = func(aid: StringName) -> Array[Dictionary]:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return []
		var target_id: StringName = act.record.get("target_id", &"")
		if target_id == mech_b.mech_id:
			return [{"effect_id": &"equipment_effect_test_respond", "card_instance_id": b_equip, "availability_priority": 10}]
		return []

	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	_move_call_a = 0
	_move_call_b = 0

	# ── 发起：A 使用强袭牌 ──
	var use_result: Dictionary = battle.context.action_service.execute(&"use_action_card", {
		"card_instance_id": a_assault,
		"player_id": &"player",
		"mech_id": mech_a.mech_id,
		"source": {"player_id": &"player", "mech_id": mech_a.mech_id},
	})
	if use_result.get("state", &"") == &"error":
		return "使用强袭牌发起失败: %s" % str(use_result)

	await driver.drain(500)
	for _i in range(5):
		await _frame()

	# ── 诊断 ──
	print("[DIAG noncounter] A pos=", mech_a.position, " B pos=", mech_b.position)
	print("[DIAG noncounter] active actions:", battle.context.action_registry.get_active_ids())
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a_diag = battle.context.action_registry.get_action(aid)
		if a_diag:
			print("[DIAG noncounter]   ", aid, " type=", a_diag.action_type, " state=", a_diag.state, " step=", a_diag.current_step_index, " phase=", a_diag.current_step_phase)

	# ── 验证 ──
	# 1) B 装备牌响应移动了（B 在 12,0）-- 说明非迎击牌响应效果被执行
	var b_pos = mech_b.position
	if int(b_pos.get("q", -1)) != 12 or int(b_pos.get("r", -1)) != 0:
		return "B 应回装备牌响应移动到 (12,0)，实际: %s -- 非迎击牌响应效果未执行" % str(b_pos)

	# 2) A 强袭2追击移动了（A 在 11,0）-- 说明 responded=true 被写入并触发强袭2
	var a_pos = mech_a.position
	if int(a_pos.get("q", -1)) != 11 or int(a_pos.get("r", -1)) != 0:
		return "A 应强袭2追击到 (11,0)，实际: %s -- 强袭2在非迎击牌响应时未触发" % str(a_pos)

	# 3) 无残留等待动作
	var waiting: Array = []
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	if not waiting.is_empty():
		return "流程结束后仍有动作等待: %s" % str(waiting)

	return true


var _move_call_a: int = 0
var _move_call_b: int = 0
