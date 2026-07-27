## test_assault_chase_flow.gd — 强袭·追击移动 完整端到端场景测试
##
## 还原并验证规则文档「强袭」(第2张) effect2 的完整场景：
##   effect2 优先级 -1，监听攻击动作A的 ATTACK_AT 时点（与响应窗口同时点，因优先级最低，
##   永远最后一个结算）。响应窗口关闭、所有响应效果结算完后，补跑 regular listeners，
##   effect2 此时读到 responded=true → 循环执行单次移动（用当前动力）。
##
## 场景1（回避→追击重新命中）：
##   1. 玩家A 使用强袭牌攻击玩家B（use_action_card → assault_effect1=EXECUTE_ATTACK 子动作A）
##   2. ATTACK_AT 响应窗口：玩家B 用回避响应 → 回避 effect1 半动力移动跳出 A 的攻击范围
##   3. 响应窗口关闭 → 补跑强袭 effect2（priority -1）→ A 用当前动力追击移动，重新进入 B 的范围
##   4. 攻击动作A 继续到 _step_check_hit：用 A、B 的实时位置（A追击后、B回避后）算距离 → 命中 B
##   验证：B 掉血（强袭2追击使原本会被回避跳掉的攻击重新命中）+ A 的位置确实追上
##
## 场景2（反击→跳出范围躲避反打）：
##   1. 玩家A 使用强袭牌攻击玩家B
##   2. ATTACK_AT 响应窗口：玩家B 用反击响应 → 反击 effect1 半动力移动（本测试动力0 不移动）
##   3. 响应窗口关闭 → 补跑强袭 effect2 → A 用当前动力移动跳出 B 的武器范围
##      （B 的反击 effect2 在 ATTACK_SETTLE 才发动攻击B，此时 A 已跳出 B 范围 → 攻击B 未命中 A）
##   验证：A 未受反击攻击B 的伤害（强袭2的移动使 A 跳出了 B 反击的范围）
##
## 走完整 ActionService.execute("use_action_card") 路径 + InputDriver 输入回调
## （select_weapon / select_attack_target / select_move_target / respond_attack）。
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


## 把指定机甲放到指定 hex
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


## ════════════════════════════════════════════════════════════
## InputDriver：复用自 test_counter_attack_chain.gd 的输入驱动器
## 收集 action_needs_input 信号，按 input_type 自动回填。
## ════════════════════════════════════════════════════════════

class InputDriver:
	var context = null
	var pending: Dictionary = {}  # action_id -> {input_type, input_params}
	var weapon_for: Callable = Callable()
	var target_for: Callable = Callable()
	var move_cell_for: Callable = Callable()   # (action_id, input_params) -> StringName "q,r"，空=取消
	var response_for: Callable = Callable()
	var damage_for: Callable = Callable()
	var frame_cb: Callable = Callable()

	func attach(ctx) -> void:
		context = ctx
		# 断开 ActionUIBridge 信号：测试由 InputDriver 全权驱动，避免 AI 抢先响应
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


## 辅助：判断某机甲是否在另一机甲武器范围内
func _in_range(battle: BattleState, attacker_id: StringName, target_id: StringName, rng: int) -> bool:
	var gs = battle.context.game_state
	var a = gs.mechs.get(attacker_id)
	var t = gs.mechs.get(target_id)
	var _RangeCalc = load("res://scripts/battle/RangeCalculator.gd")
	return _RangeCalc.is_in_weapon_range(a.position, t.position, rng, gs.map_state.cells)


## ════════════════════════════════════════════════════════════
## 场景1：B 用回避响应跳出范围 → A 强袭2追击重新进入范围 → 攻击命中 B
## ════════════════════════════════════════════════════════════
func test_assault_chase_after_evade_hits():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")   # A：强袭攻击方
	var mech_b = gs.get_mech_for_player(&"enemy")     # B：被攻击方

	# 布局：A(10,0)  B(11,0)，A 武器范围2，距离1在范围内
	_place_mech(battle, mech_a.mech_id, 10, 0)
	_place_mech(battle, mech_b.mech_id, 11, 0)

	# A 动力10（足够追击3格到13,0）；B 动力6 → 回避半动力 X=3 → 移到(14,0)距A(10,0)=4>2 跳出范围
	mech_a.power = 10
	mech_b.power = 6

	# A 手里塞强袭牌，B 手里塞回避牌
	var a_assault := _ensure_card_in_player_hand(battle, &"player", "action_002_强袭")
	if a_assault == &"":
		return "A 手牌未找到强袭牌"
	var b_evade := _ensure_card_in_player_hand(battle, &"enemy", "action_008_回避")
	if b_evade == &"":
		return "B 手牌未找到回避牌"

	var b_hp0: int = mech_b.current_hp
	var a_hp0: int = mech_a.current_hp

	# ── InputDriver ──
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.frame_cb = _frame

	# 武器：A 用第1把基础武器（范围2）
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"

	# 攻击目标：强袭的 attack 子动作（A发起）→ 打 B
	driver.target_for = func(aid: StringName, _params: Dictionary) -> StringName:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return &""
		var attacker_id: StringName = act.record.get("attacker_id", &"")
		if attacker_id == mech_a.mech_id:
			return mech_b.mech_id
		return &""

	# 移动选格：区分是谁在移动
	# - B 回避 effect1：B 从(11,0)移到(14,0)跳出范围（半动力X=3，给终点14,0 path算逐格走完，X耗尽不再请求）
	# - A 强袭 effect2 追击：A 从(10,0)追到(13,0)（给终点13,0，path走完耗3动力剩7，loop再请求→返回空取消结束）
	# 通过 input_params.mech_id 区分
	driver.move_cell_for = func(_aid: StringName, params: Dictionary) -> StringName:
		var mover_id: StringName = params.get("mech_id", &"")
		if mover_id == mech_b.mech_id:
			return &"14,0"   # B 回避：跳出 A 范围2（距 A(10,0)=4）
		if mover_id == mech_a.mech_id:
			# A 强袭2追击：第1次给终点13,0（距B(14,0)=1 重新进入范围2）；loop 再请求则取消
			var call_count: int = _move_call_count_a
			_move_call_count_a += 1
			if call_count == 0:
				return &"13,0"
			return &""   # 取消，结束循环移动
		return &""

	# 响应窗口：强袭的 attack（打B）→ B 用回避响应
	driver.response_for = func(aid: StringName) -> Array[Dictionary]:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return []
		var target_id: StringName = act.record.get("target_id", &"")
		if target_id == mech_b.mech_id:
			return [{"effect_id": &"evade_availability", "card_instance_id": b_evade, "availability_priority": 5}]
		return []

	# 损伤放置：auto
	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	# 记录 A 强袭2 追击移动的调用次数（闭包外可变计数）
	_move_call_count_a = 0

	# ── 发起：A 使用强袭牌 ──
	var use_result: Dictionary = battle.context.action_service.execute(&"use_action_card", {
		"card_instance_id": a_assault,
		"player_id": &"player",
		"mech_id": mech_a.mech_id,
		"source": {"player_id": &"player", "mech_id": mech_a.mech_id},
	})
	if use_result.get("state", &"") == &"error":
		return "使用强袭牌发起失败: %s" % str(use_result)

	# 驱动整个流程
	await driver.drain(500)
	for _i in range(5):
		await _frame()

	# ── 诊断 ──
	print("[DIAG assault] A pos=", mech_a.position, " B pos=", mech_b.position)
	print("[DIAG assault] active actions:", battle.context.action_registry.get_active_ids())
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a_diag = battle.context.action_registry.get_action(aid)
		if a_diag:
			print("[DIAG assault]   ", aid, " type=", a_diag.action_type, " state=", a_diag.state, " step=", a_diag.current_step_index, " phase=", a_diag.current_step_phase)

	# ── 验证 ──
	# 1) A 确实追击移动到了 13,0
	var a_pos = mech_a.position
	if int(a_pos.get("q", -1)) != 13 or int(a_pos.get("r", -1)) != 0:
		return "A 应追击到 (13,0)，实际: %s" % str(a_pos)

	# 2) B 回避到了 14,0
	var b_pos = mech_b.position
	if int(b_pos.get("q", -1)) != 14 or int(b_pos.get("r", -1)) != 0:
		return "B 应回避到 (14,0)，实际: %s" % str(b_pos)

	# 3) A(13,0) 与 B(14,0) 距离1 ≤ 2 → 重新进入范围
	if not _in_range(battle, mech_a.mech_id, mech_b.mech_id, 2):
		return "A 追击后应重新进入 B 的范围2，实际未在范围内"

	# 4) 攻击命中 B（强袭2追击使攻击重新命中）→ B 掉血
	if mech_b.current_hp >= b_hp0:
		return "攻击应因强袭2追击命中 B（b_hp %d→%d），但 B 未掉血——强袭2追击移动未在命中判定前生效或未触发" % [b_hp0, mech_b.current_hp]

	# 5) A 未受伤害（本场景 B 只回避未反打）
	if mech_a.current_hp != a_hp0:
		return "A 不应受伤害（a_hp %d→%d）" % [a_hp0, mech_a.current_hp]

	# 6) 无残留等待动作
	var waiting: Array = []
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	if not waiting.is_empty():
		return "流程结束后仍有动作等待: %s" % str(waiting)

	return true


## 闭包外可变计数（GDScript 闭包捕获值类型需用成员变量）
var _move_call_count_a: int = 0


## ════════════════════════════════════════════════════════════
## 场景2：B 用反击响应 → A 强袭2移动跳出 B 反击范围 → B 反击2攻击未命中 A
##   B 反击 effect1 半动力移动（B 动力0 不移动）；攻击A 未命中（B 在范围但 A 强袭2先跳出）
##   注意：本场景 B 在原地，A 攻击 B 时 B 在范围内会命中——但强袭2在 ATTACK_AT 补跑后
##   A 移出，A 对 B 的攻击命中判定用实时位置：A 跳出后 A→B 距离>R → A 的攻击也未命中 B。
##   重点验证：B 反击 effect2 在 ATTACK_SETTLE 发动攻击B 打 A 时，A 已跳出 B 范围 → A 不掉血。
## ════════════════════════════════════════════════════════════
func test_assault_escape_after_counter_dodges_counterattack():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")   # A：强袭攻击方
	var mech_b = gs.get_mech_for_player(&"enemy")     # B：反击方

	# 布局：A(10,0)  B(11,0)，双方武器范围2，距离1在范围
	_place_mech(battle, mech_a.mech_id, 10, 0)
	_place_mech(battle, mech_b.mech_id, 11, 0)

	# A 动力10（足够跳出 B 范围2：从10,0移到7,0，距B(11,0)=4>2）
	# B 动力0 → 反击 effect1 半动力 X=0 不移动（专注验证 effect2 反打）
	mech_a.power = 10
	mech_b.power = 0

	var a_assault := _ensure_card_in_player_hand(battle, &"player", "action_002_强袭")
	if a_assault == &"":
		return "A 手牌未找到强袭牌"
	var b_counter := _ensure_card_in_player_hand(battle, &"enemy", "action_010_反击")
	if b_counter == &"":
		return "B 手牌未找到反击牌"

	var a_hp0: int = mech_a.current_hp
	var b_hp0: int = mech_b.current_hp

	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.frame_cb = _frame

	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"

	# 攻击目标：A 的强袭攻击→B；B 的反击攻击B→A
	driver.target_for = func(aid: StringName, _params: Dictionary) -> StringName:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return &""
		var attacker_id: StringName = act.record.get("attacker_id", &"")
		if attacker_id == mech_a.mech_id:
			return mech_b.mech_id   # 强袭攻击A：A 打 B
		if attacker_id == mech_b.mech_id:
			return mech_a.mech_id   # 反击攻击B：B 打 A
		return &""

	# 移动选格：
	# - B 反击 effect1：B 动力0，半动力X=0，single_move 不会请求选格（直接 settle）
	#   若意外请求则取消
	# - A 强袭 effect2：A 从(10,0)移到(7,0)跳出 B 范围2，loop 再请求则取消
	driver.move_cell_for = func(_aid: StringName, params: Dictionary) -> StringName:
		var mover_id: StringName = params.get("mech_id", &"")
		if mover_id == mech_a.mech_id:
			var call_count: int = _move_call_count_a2
			_move_call_count_a2 += 1
			if call_count == 0:
				return &"7,0"   # A 强袭2跳出 B 范围2（距 B(11,0)=4）
			return &""   # 取消，结束循环移动
		return &""   # B 反击 effect1 动力0 不应请求；若请求则取消

	# 响应窗口：A 强袭攻击（打B）→ B 用反击响应
	driver.response_for = func(aid: StringName) -> Array[Dictionary]:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return []
		var target_id: StringName = act.record.get("target_id", &"")
		if target_id == mech_b.mech_id:
			return [{"effect_id": &"counter_availability", "card_instance_id": b_counter, "availability_priority": 5}]
		return []

	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	_move_call_count_a2 = 0

	# 发起：A 使用强袭牌
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

	# ── 验证 ──
	# 1) A 强袭2 跳出到了 7,0
	var a_pos = mech_a.position
	if int(a_pos.get("q", -1)) != 7 or int(a_pos.get("r", -1)) != 0:
		return "A 应跳出至 (7,0)，实际: %s" % str(a_pos)

	# 2) A(7,0) 与 B(11,0) 距离4 > 2 → A 已跳出 B 武器范围
	if _in_range(battle, mech_b.mech_id, mech_a.mech_id, 2):
		return "A 应跳出 B 的武器范围2，但仍在范围内"

	# 3) B 反击 effect2 发动了攻击B 打 A，但 A 已跳出范围 → 未命中 → A 不掉血
	if mech_a.current_hp != a_hp0:
		return "A 应已跳出 B 反击范围不受反打伤害（a_hp %d→%d），强袭2移动未在 B 反击2命中判定前生效" % [a_hp0, mech_a.current_hp]

	# 4) B 也未掉血（A 强袭2跳出后 A→B 也超出范围2 → A 的攻击也未命中 B）
	#    这是预期：A 主动跳出放弃命中，换取不被反打
	#    （此断言可选，不强求 B 不掉血，重点是 A 不被反打）

	# 5) 无残留等待动作
	var waiting: Array = []
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	if not waiting.is_empty():
		return "流程结束后仍有动作等待: %s" % str(waiting)

	return true


var _move_call_count_a2: int = 0
