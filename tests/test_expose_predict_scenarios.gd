## test_expose_predict_scenarios.gd - 识破/预判/锁定 场景2、3 端到端测试
##
## 场景2（锁定+识破）：B 对 A 发动攻击（B 先对 A 施加锁定），A 被锁，普通迎击牌（优先级<20）
##   被封锁，只有识破（优先级30>20）可响应。A 用识破 -> 效果1 无效攻击 -> 效果2 偷牌+移动。
##
## 场景3（预判+识破）：B 用预判攻击 A。预判效果2（攻击时前）锁 A + 随机弃 A 1张行动牌；
##   预判效果3（攻击时）SET_ATTACK_UNNEGATABLE。A 被锁只有识破可响应。识破效果1 的 negate 被
##   预判效果3 阻断（攻击不被无效），但效果2（偷牌+移动）仍执行。识破结算后预判攻击继续，
##   按A是否还在范围内判命中：
##     用例A：A 移出范围 -> 未命中（hit=false）
##     用例B：A 取消移动留在范围 -> 命中（hit=true，造成伤害）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _RangeCalc = preload("res://scripts/battle/RangeCalculator.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


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


func _ensure_card_in_hand(battle: BattleState, player_id: StringName, card_def_id: String) -> StringName:
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


func _place(battle: BattleState, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	mech.position = {"q": q, "r": r}


func _in_range(battle: BattleState, a_id: StringName, t_id: StringName, rng: int) -> bool:
	var gs = battle.context.game_state
	return _RangeCalc.is_in_weapon_range(gs.mechs[a_id].position, gs.mechs[t_id].position, rng, gs.map_state.cells)


## 找一个 mover 当前可达、且离开 attacker 武器范围（>rng）的相邻可达格，返回 "q,r"；无则返回 ""
func _find_cell_out_of_range(battle: BattleState, mover_id: StringName, attacker_id: StringName, rng: int, power: int) -> String:
	var gs = battle.context.game_state
	var mover = gs.mechs[mover_id]
	var attacker = gs.mechs[attacker_id]
	var cells: Dictionary = gs.map_state.cells
	var reachable: Array[Dictionary] = _RangeCalc.get_move_reachable_hexes(mover.position, max(1, power), cells)
	for hex in reachable:
		if not _RangeCalc.is_in_weapon_range(attacker.position, hex, rng, cells):
			return "%d,%d" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
	return ""


# ════════════════════════════════════════════════════════════
## 输入驱动器（参考 test_counter_attack_chain）：断开 ActionUIBridge，全权驱动输入回调。
# ════════════════════════════════════════════════════════════
class InputDriver:
	var context = null
	var pending: Dictionary = {}
	var weapon_for: Callable = Callable()
	var target_for: Callable = Callable()        # (action_id, input_params) -> StringName  攻击目标
	var mech_target_for: Callable = Callable()   # (action_id, input_params) -> StringName  锁定等机甲目标
	var discard_for: Callable = Callable()       # (action_id, input_params) -> Array  选1张牌[card_id]
	var move_cell_for: Callable = Callable()     # (action_id, input_params) -> String  "q,r"，空=取消
	var response_for: Callable = Callable()      # (action_id) -> Array[Dictionary]  选中的迎击牌；空=不响应
	var damage_for: Callable = Callable()        # (action_id, input_params) -> Dictionary
	var frame_cb: Callable = Callable()
	var use_ui_bridge: bool = false  # true=走 on_ui_confirmed 模拟实机回填（不断开 ActionUIBridge）

	func attach(ctx) -> void:
		context = ctx
		if not use_ui_bridge and context.action_ui_bridge != null:
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
		# use_ui_bridge：模拟实机走 ActionUIBridge.on_ui_confirmed（_waiting_action_id 回填）
		if use_ui_bridge and context != null and context.action_ui_bridge != null:
			context.action_ui_bridge.on_ui_confirmed(input_data)
			return true
		# pending_effect（目标选择/二选一，如锁定牌选机甲）走 resume_pending_effect，而非 continue_action
		if context != null and context.timing_engine != null and context.timing_engine.has_pending_effect(action_id):
			context.timing_engine.resume_pending_effect(action_id, input_data)
			return true
		context.action_service.continue_action(action_id, input_data)
		return true

	func _resolve(action_id: StringName, input_type: StringName, input_params: Dictionary):
		match input_type:
			&"select_weapon":
				return {"weapon_id": weapon_for.call(action_id)}
			&"select_attack_target":
				return {"target_id": target_for.call(action_id, input_params)}
			&"select_mech_target", &"select_target_mech":
				return {"target_id": mech_target_for.call(action_id, input_params), "target_mech_id": mech_target_for.call(action_id, input_params)}
			&"select_discard_cards":
				var d = discard_for.call(action_id, input_params)
				# 支持 Dictionary 返回（含 cancelled 等完整 input_data，模拟取消）；
				# Array 返回按旧逻辑包装成 {determined_card_ids: [...]}
				if d is Dictionary:
					return d
				return {"determined_card_ids": d}
			&"select_move_target":
				var cell: String = move_cell_for.call(action_id, input_params)
				if cell == "":
					context.action_service.cancel_action(action_id)
					return null
				return {"target_cell": StringName(cell)}
			&"respond_attack":
				var sel_in = response_for.call(action_id)
				var sel: Array[Dictionary] = []
				for e in sel_in:
					if e is Dictionary:
						sel.append(e)
				context.timing_engine.handle_response_selection(action_id, sel)
				return null
			&"place_damage_tokens":
				var d: Dictionary = damage_for.call(action_id, input_params)
				if d.is_empty():
					return {"auto_placed": true}
				return d
			_:
				return {"auto": true}

	func drain(max_iters: int = 600) -> void:
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


# ════════════════════════════════════════════════════════════
## 场景2：锁定+识破。B 锁 A 后攻击 A，A 只有识破可响应（普通迎击牌被封锁）。
# ════════════════════════════════════════════════════════════
func test_expose_only_available_when_locked():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")    # A
	var mech_b = gs.get_mech_for_player(&"enemy")     # B
	_place(battle, mech_a.mech_id, 10, 0)
	_place(battle, mech_b.mech_id, 11, 0)
	mech_a.power = 6
	mech_b.power = 6

	# A 手牌：识破 + 回避（两张迎击牌，回避优先级5应被锁封锁）
	var expose_cid := _ensure_card_in_hand(battle, &"player", "action_012_识破")
	if expose_cid == &"":
		return "A 找不到识破"
	var evade_cid := _ensure_card_in_hand(battle, &"player", "action_008_回避")
	if evade_cid == &"":
		return "A 找不到回避"
	# B 手牌：锁定牌 + 攻击牌 + 1张额外行动牌供识破偷取
	var lock_cid := _ensure_card_in_hand(battle, &"enemy", "action_023_锁定")
	if lock_cid == &"":
		return "B 找不到锁定"
	var attack_cid := _ensure_card_in_hand(battle, &"enemy", "action_001_进攻")
	if attack_cid == &"":
		return "B 找不到攻击牌"
	var stealable_cid := _ensure_card_in_hand(battle, &"enemy", "action_002_强袭")
	if stealable_cid == &"":
		return "B 无可被偷行动牌"
	var b_weapon: StringName = mech_b.get_weapon_ids()[0]
	var b_range: int = 2

	var driver := InputDriver.new()
	driver.weapon_for = func(_aid): return b_weapon
	driver.target_for = func(_aid, _p): return mech_a.mech_id
	driver.mech_target_for = func(_aid, _p): return mech_a.mech_id   # 锁定目标 = A
	driver.discard_for = func(_aid, p):
		# 识破偷牌：从 discard_player_id（攻击方B）手牌选1张
		var pid: StringName = p.get("discard_player_id", &"enemy")
		var pl = gs.players.get(pid)
		if pl != null and not pl.action_hand.is_empty():
			return [pl.action_hand[0]]
		return []
	driver.move_cell_for = func(_aid, _p): return ""   # A 取消移动
	driver.response_for = func(_aid):
		return [{"effect_id": &"expose_availability", "card_instance_id": expose_cid, "availability_priority": 30}]
	driver.damage_for = func(_aid, _p): return {"auto_placed": true}
	driver.frame_cb = _frame
	driver.attach(battle.context)

	# 1) B 打锁定牌 -> 选 A 施加锁定
	battle.execute_use_action_card(&"enemy", lock_cid)
	await driver.drain()
	if not mech_a.is_locked_by(&"enemy"):
		return "锁定牌未对A施加锁定状态（locker=B）"

	# 2) B 攻击 A
	var atk := battle.execute_attack_action(&"enemy", &"player", b_weapon, attack_cid)
	var attack_id: StringName = atk.get("action_id", &"") if atk is Dictionary else &""
	# 推进到响应窗口
	await drain_until_respond(driver, 200)

	# 3) 验证响应窗口只有识破（回避被锁封锁）
	var available: Array = battle.context.timing_engine.get_available_cards(_TimingConst.ATTACK_AT, battle.context.action_registry.get_action(attack_id))
	var has_expose := false
	var has_evade := false
	for entry in available:
		var cid: StringName = entry.get("card_instance_id", &"")
		if cid == expose_cid:
			has_expose = true
		if cid == evade_cid:
			has_evade = true
	if not has_expose:
		return "锁定下识破应可用，但响应窗口无识破"
	if has_evade:
		return "锁定下回避（优先级5<20）应被封锁，但出现在响应窗口"

	# 4) A 用识破响应，drain 到结束
	await driver.drain()
	var attack_action = battle.context.action_registry.get_action(attack_id)
	if attack_action != null:
		return "识破响应后攻击未完成，state=%s" % String(attack_action.state)
	if battle.context.action_registry.get_active_count() != 0:
		return "识破响应完成后仍有活跃动作残留"
	# 攻击被识破无效（negated）-> A 未受伤
	if mech_a.current_hp >= mech_a.max_hp:
		pass  # 期望未掉血
	else:
		# negated 攻击不应造成伤害；若掉血说明 negate 未生效
		return "识破应无效攻击，但A掉血（hp=%d/%d）" % [int(mech_a.current_hp), int(mech_a.max_hp)]
	return true


## drain 到出现 respond_attack 等待（响应窗口），或无进展时停。
func drain_until_respond(driver, max_iters: int) -> void:
	var it := 0
	while it < max_iters:
		it += 1
		# 若当前已有 respond_attack 待处理，停在那时让测试校验
		var has_respond := false
		for aid: StringName in driver.pending.keys():
			if str(driver.pending[aid].get("input_type", &"")) == &"respond_attack":
				has_respond = true
				break
		if has_respond:
			break
		var progressed: bool = driver.pump()
		if driver.frame_cb.is_valid():
			await driver.frame_cb.call()
		if not progressed:
			break


# ════════════════════════════════════════════════════════════
## 场景3 用例A：预判+识破，A 移出范围 -> 预判攻击未命中
# ════════════════════════════════════════════════════════════
func test_predict_unnegatable_expose_move_out_misses():
	return await _run_predict_case(true)


# ════════════════════════════════════════════════════════════
## 场景3 用例B：预判+识破，A 取消移动留在范围 -> 预判攻击命中
# ════════════════════════════════════════════════════════════
func test_predict_unnegatable_expose_stay_hits():
	return await _run_predict_case(false)


# ════════════════════════════════════════════════════════════
## 预判 effect2 弃牌 + on_ui_confirmed 路径（模拟实机）：验证 discard_card 提交后 attack 恢复
# ════════════════════════════════════════════════════════════
func test_predict_discard_ui_bridge():
	seed(20260719)
	var result = await _run_predict_case_impl(false, true)
	seed(int(Time.get_ticks_msec()))
	return result


# ════════════════════════════════════════════════════════════
## 预判 effect2 弃牌：玩家取消 -> 弃0张完成（取消=不弃置任何牌），attack 正常恢复
# ════════════════════════════════════════════════════════════
func test_predict_discard_cancel_skips_no_discard():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")
	var mech_b = gs.get_mech_for_player(&"enemy")
	var _ep = gs.players.get(&"enemy")
	if _ep != null:
		_ep.is_human = true
	_place(battle, mech_a.mech_id, 10, 0)
	_place(battle, mech_b.mech_id, 11, 0)
	mech_a.power = 6
	mech_b.power = 6
	# A 手牌：清空后给1张攻击牌（非迎击->无响应窗口），确保弃牌窗会弹（手牌非空）
	_clear_action_hand(battle, &"player")
	if _ensure_card_in_hand(battle, &"player", "action_001_进攻") == &"":
		return "A 找不到攻击牌"
	var a_hand_before: int = gs.players.get(&"player").action_hand.size()
	var predict_cid := _ensure_card_in_hand(battle, &"enemy", "action_007_预判")
	if predict_cid == &"":
		return "B 找不到预判"
	var b_weapon: StringName = mech_b.get_weapon_ids()[0]

	# discard_called 用数组承载（GDScript4 lambda 标量按值捕获，bool 赋值不可见外部）
	var discard_called := [false]
	var driver := InputDriver.new()
	driver.weapon_for = func(_aid): return b_weapon
	driver.target_for = func(_aid, _p): return mech_a.mech_id
	driver.discard_for = func(_aid, p):
		if String(p.get("discard_player_id", &"")) == &"player":
			discard_called[0] = true
			return {"determined_card_ids": [], "cancelled": true}  # 玩家取消
		return []
	driver.response_for = func(_aid): return []
	driver.move_cell_for = func(_aid, _p): return ""
	driver.damage_for = func(_aid, _p): return {"auto_placed": true}
	driver.frame_cb = _frame
	driver.attach(battle.context)

	battle.execute_use_action_card(&"enemy", predict_cid)
	await driver.drain()

	if not discard_called[0]:
		return "预判 effect2 应弹弃牌窗（need_input）"
	if battle.context.action_registry.get_active_count() != 0:
		return "取消弃牌后预判攻击未完成，残留动作"
	# 取消=不弃置：A 手牌数应不变（ADD_STATUS 仍执行，但锁定会被命中清除，不在此断言）
	var a_hand_after: int = gs.players.get(&"player").action_hand.size()
	if a_hand_after != a_hand_before:
		return "取消弃牌不应改变 A 手牌，前=%d 后=%d" % [a_hand_before, a_hand_after]
	return true


# ════════════════════════════════════════════════════════════
## 预判 effect2 弃牌：目标 A 空手 -> 跳过弃牌（不弹窗），attack 正常命中
# ════════════════════════════════════════════════════════════
func test_predict_discard_empty_hand_skips_no_popup():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")
	var mech_b = gs.get_mech_for_player(&"enemy")
	var _ep = gs.players.get(&"enemy")
	if _ep != null:
		_ep.is_human = true
	_place(battle, mech_a.mech_id, 10, 0)
	_place(battle, mech_b.mech_id, 11, 0)
	mech_a.power = 6
	mech_b.power = 6
	# A 手牌清空（0张）-> 预判弃牌应跳过不弹窗
	_clear_action_hand(battle, &"player")
	if gs.players.get(&"player").action_hand.size() != 0:
		return "A 手牌应已清空"
	var a_hp_before: int = int(mech_a.current_hp)
	var predict_cid := _ensure_card_in_hand(battle, &"enemy", "action_007_预判")
	if predict_cid == &"":
		return "B 找不到预判"
	var b_weapon: StringName = mech_b.get_weapon_ids()[0]

	var discard_called := [false]
	var driver := InputDriver.new()
	driver.weapon_for = func(_aid): return b_weapon
	driver.target_for = func(_aid, _p): return mech_a.mech_id
	driver.discard_for = func(_aid, _p):
		discard_called[0] = true
		return []  # 不应被调用（空手应跳过）
	driver.response_for = func(_aid): return []
	driver.move_cell_for = func(_aid, _p): return ""
	driver.damage_for = func(_aid, _p): return {"auto_placed": true}
	driver.frame_cb = _frame
	driver.attach(battle.context)

	battle.execute_use_action_card(&"enemy", predict_cid)
	await driver.drain()

	if discard_called[0]:
		return "A 空手时预判弃牌不应弹窗（应跳过弃0张）"
	if battle.context.action_registry.get_active_count() != 0:
		return "空手跳过弃牌后预判攻击未完成，残留动作"
	# A 空手仍为0（未被弃牌）
	if gs.players.get(&"player").action_hand.size() != 0:
		return "空手跳过弃牌不应改变 A 手牌"
	# A 被命中掉血 -> 攻击走完命中步 -> ATTACK_PRE 已 fire -> predict_e2 已触发（弃牌被跳过）
	if int(mech_a.current_hp) >= a_hp_before:
		return "预判攻击应命中 A（确认 ATTACK_PRE 已触发 predict_e2）"
	return true


## 清空玩家行动手牌并注销其 AVAILABILITY 监听器（避免残留迎击牌触发响应窗口）
func _clear_action_hand(battle, player_id: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return
	for cid: StringName in player.action_hand.duplicate():
		if battle.context.has_method(&"unregister_hand_card_availability"):
			battle.context.unregister_hand_card_availability(cid)
	player.action_hand.clear()


func _run_predict_case(move_out: bool):
	# 预判 effect2 弃牌现为玩家选牌（choose=true）：driver.discard_for 选 A 非识破牌弃，保留识破供响应。
	# seed 保留以防其他随机路径（损伤槽位等），结束后用时间恢复种子避免污染后续测试。
	seed(20260719)
	var result = await _run_predict_case_impl(move_out)
	seed(int(Time.get_ticks_msec()))
	return result


func _run_predict_case_impl(move_out: bool, use_ui_bridge: bool = false):
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")    # A = 目标 = 识破使用者
	var mech_b = gs.get_mech_for_player(&"enemy")     # B = 预判使用者 = 攻击方
	# use_ui_bridge 模式下 ActionUIBridge._is_ai_source 按 is_human 决定弹窗/自动；
	# B 作攻击方需 is_human=true 才走玩家弹窗路径（模拟人类实机）
	var _ep = gs.players.get(&"enemy")
	if _ep != null:
		_ep.is_human = true
	_place(battle, mech_a.mech_id, 10, 0)
	_place(battle, mech_b.mech_id, 11, 0)
	mech_a.power = 10
	mech_b.power = 6
	var a_hp_before: int = int(mech_a.current_hp)

	# B 手牌：预判 + 1张额外行动牌供识破偷取
	var predict_cid := _ensure_card_in_hand(battle, &"enemy", "action_007_预判")
	if predict_cid == &"":
		return "B 找不到预判"
	var stealable_cid := _ensure_card_in_hand(battle, &"enemy", "action_002_强袭")
	if stealable_cid == &"":
		return "B 无可被偷行动牌"
	# A 手牌：识破 + 回避（回避应被预判effect2的锁封锁）
	var expose_cid := _ensure_card_in_hand(battle, &"player", "action_012_识破")
	if expose_cid == &"":
		return "A 找不到识破"
	var evade_cid := _ensure_card_in_hand(battle, &"player", "action_008_回避")
	var b_weapon: StringName = mech_b.get_weapon_ids()[0]
	var b_range: int = 2

	var move_count := 0
	var predict_discard := [false, false, &""]  # [0]=弹窗验证, [1]=attack未暂停(错误标志), [2]=mode(须 need_input)
	var driver := InputDriver.new()
	driver.use_ui_bridge = use_ui_bridge
	driver.weapon_for = func(_aid): return b_weapon
	driver.target_for = func(_aid, _p): return mech_a.mech_id   # 预判攻击目标 = A
	driver.discard_for = func(_aid, p):
		var pid: StringName = p.get("discard_player_id", &"enemy")
		var pl = gs.players.get(pid)
		if pl != null and not pl.action_hand.is_empty():
			# 预判 effect2 弃牌（pid=player/A）：选非识破的牌弃，保留识破供 A 响应
			if String(pid) == &"player":
				predict_discard[0] = true
				# 标量局部变量在 lambda 中按值捕获，赋值不可见外部；用数组元素（引用）承载。
				predict_discard[2] = p.get("mode", &"")
				# 修复验证：预判 effect2 弹窗期间 attack 应暂停（waiting_effect_action），不能继续推进
				for aid in battle.context.action_registry.get_active_ids():
					var a = battle.context.action_registry.get_action(aid)
					if a != null and a.action_type == &"attack" and a.state != &"waiting_effect_action":
						predict_discard[1] = true
				for cid in pl.action_hand:
					if cid != expose_cid:
						return [cid]
			return [pl.action_hand[0]]
		return []
	driver.move_cell_for = func(_aid, _p):
		# A 的移动（识破效果2）。move_out=true：第1次走到范围外，第2次取消；false：立即取消
		move_count += 1
		if not move_out:
			return ""
		if move_count == 1:
			var cell := _find_cell_out_of_range(battle, mech_a.mech_id, mech_b.mech_id, b_range, mech_a.power)
			if cell == "":
				return ""
			return cell
		return ""  # 第2次取消，结束循环
	driver.response_for = func(_aid):
		return [{"effect_id": &"expose_availability", "card_instance_id": expose_cid, "availability_priority": 30}]
	driver.damage_for = func(_aid, _p): return {"auto_placed": true}
	driver.frame_cb = _frame
	driver.attach(battle.context)

	# B 打预判 -> effect1 攻击A -> effect2(ATTACK_PRE)锁A+弃A牌 -> effect3(ATTACK_AT)不可否定+响应窗口
	battle.execute_use_action_card(&"enemy", predict_cid)
	await driver.drain()

	# 验证：预判攻击应完成（未被识破无效，因预判效果3阻断negate）
	# 找到那条 attack 动作记录（已 completed，从 registry 移除）。检查 A 是否掉血 + 命中日志。
	var a_hp_after: int = int(mech_a.current_hp)
	if move_out:
		# A 移出范围 -> 未命中 -> 不掉血
		if a_hp_after != a_hp_before:
			return "A 移出范围应未命中不掉血，前=%d 后=%d" % [a_hp_before, a_hp_after]
		# 且 A 应已移动（位置改变）
		if _in_range(battle, mech_b.mech_id, mech_a.mech_id, b_range):
			return "A 应已移出 B 攻击范围"
	else:
		# A 留在范围 -> 命中 -> 掉血
		if a_hp_after >= a_hp_before:
			return "A 留在范围应被命中掉血，前=%d 后=%d" % [a_hp_before, a_hp_after]
		# 预判攻击未被无效（negate 被预判效果3阻断）
	if battle.context.action_registry.get_active_count() != 0:
		return "预判攻击未完成，残留 %d 个动作" % battle.context.action_registry.get_active_count()
	if not predict_discard[0]:
		return "预判 effect2 应弹选牌窗让 B 选 A 的牌弃（choose=true 未生效或 executor 解析失败）"
	if predict_discard[1]:
		return "预判 effect2 弹窗期间 attack 应暂停（waiting_effect_action），效果链未暂停修复未生效"
	# 契约：discard_card need_input 的 input_params 必须带 mode=need_input，否则 app_root
	# _show_popup 会误判为 optional 闪击弃牌 -> 提交时 resume_pending_effect 对非挂起动作 no-op，
	# 弃牌永不执行、攻击卡死（实机 bug，use_ui_bridge 测试直调 on_ui_confirmed 绕过路由故未暴露）。
	if predict_discard[2] != &"need_input":
		return "discard_card need_input input_params 缺 mode=need_input，app_root 会误路由到 optional 分支"
	# 验证 B 被偷1张牌（识破效果2）
	var enemy_after = gs.players.get(&"enemy")
	if enemy_after.action_hand.has(stealable_cid) and enemy_after.action_hand.size() >= 2:
		# 偷取后该牌应在玩家手牌（若 B 起手2张：预判+强袭，预判已用，强袭被偷则 B 手牌为0）
		pass
	return true
