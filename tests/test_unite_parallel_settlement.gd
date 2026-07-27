## test_unite_parallel_settlement.gd - 联合攻击并行结算验证
##
## 验证 2026-07-27 联合效果1 的"结束监听后并行"语义：
##   unite机甲(enemy)发动攻击A(打出攻击牌A) -> ATTACK_SETTLE 触发联合状态监听 ->
##   弹窗让 Target(player) 选1张攻击牌联合攻击 -> resume_pending_effect 创建
##   use_action_card(B) 作为独立顶层动作 + 继续 attackA 推进。
##
## 关键断言（并行）：玩家确认联合攻击后，attackA 应立即继续推进到 cleanup、
## use_action_card(A) 结算弃置攻击牌A，**不必等联合攻击B 结算**。
## 修复前 bug：攻击牌A 一直留临时区，直到攻击牌B 结算后才弃置（串行阻塞）。
##
## 走完整 use_action_card -> attack 真实步骤链 + InputDriver 驱动输入回调。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


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
	return battle


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
			return cid
	return &""


## 清掉指定玩家手牌中除 keep_cid 外的所有行动牌（移回牌堆），避免迎击牌开响应窗口干扰
func _clear_hand_except(battle: BattleState, player_id: StringName, keep_cid: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return
	var to_remove: Array = []
	for cid: StringName in player.action_hand:
		if cid != keep_cid:
			to_remove.append(cid)
	for cid in to_remove:
		if battle.context.timing_engine != null:
			battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"


## 直接对 target 施加联合状态（unite=unite_mech），与 unite_effect1 一致
func _apply_unite(battle: BattleState, target_mech_id: StringName, unite_mech_id: StringName, source_pid: StringName) -> void:
	battle.context.game_actions.add_status({
		"target_id": target_mech_id,
		"status": {
			"type": &"UNITE",
			"duration": &"UNTIL_TURN_END",
			"unite": unite_mech_id,
			"source_player_id": source_pid,
		},
	})


## ── 输入驱动器：收集 action_needs_input 信号，按 input_type 自动回填 ──
## select_unite_attack_card 不在此处理（记录到 unite_action_id，由测试手动 resume）。
class InputDriver:
	var context = null
	var pending: Dictionary = {}
	var unite_action_id: StringName = &""   # 捕获到的联合攻击弹窗所属动作
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

	func _on_need(action_id: StringName, input_type: StringName, _input_params: Dictionary) -> void:
		if input_type == &"select_unite_attack_card":
			unite_action_id = action_id
			return  # 不入 pending，由测试手动 resume_pending_effect
		pending[action_id] = {"input_type": input_type, "input_params": _input_params}

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

	## 驱动所有非联合弹窗的输入，直到无更多 pending（或达到 max_iters）。
	## 不处理 select_unite_attack_card（已拦截），便于测试在联合弹窗处接管。
	func drain(max_iters: int = 500) -> void:
		var it := 0
		while it < max_iters:
			it += 1
			var progressed: bool = pump()
			if frame_cb.is_valid():
				await frame_cb.call()
			if not pump():
				if not progressed and pending.is_empty():
					break
			if pending.is_empty():
				break

	func has_waiting_actions() -> bool:
		if context == null or context.action_registry == null:
			return false
		for aid: StringName in context.action_registry.get_active_ids():
			var a = context.action_registry.get_action(aid)
			if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
				return true
		return false


## ════════════════════════════════════════════════════════════
## 测试：联合攻击并行结算——攻击牌A 在联合弹窗确认后立即弃置，不等攻击牌B
## ════════════════════════════════════════════════════════════
func test_unite_attack_parallel_settlement() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null or player_mech == null:
		return "机甲缺失"

	# 相邻布局：enemy(6,0) 攻击 player(5,0)，基础武器范围>=1 可命中
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	player_mech.power = 10
	enemy_mech.power = 10

	# card A：enemy 的攻击牌（触发联合的攻击动作打出）
	var card_a := _ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	if card_a == &"":
		return "找不到 enemy 攻击牌 action_001_进攻"
	# card B：player 的攻击牌（联合诱导打出）
	var card_b := _ensure_card_in_player_hand(battle, &"player", "action_001_进攻")
	if card_b == &"":
		return "找不到 player 攻击牌 action_001_进攻"
	# 清掉 player 其余手牌（避免迎击牌开响应窗口）
	_clear_hand_except(battle, &"player", card_b)

	# 施加联合状态：Target=player_mech，unite=enemy_mech
	_apply_unite(battle, player_mech.mech_id, enemy_mech.mech_id, &"enemy")

	var ar = battle.context.action_registry

	# ── 输入驱动器 ──
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.frame_cb = _frame
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"
	driver.target_for = func(aid: StringName, _params: Dictionary) -> StringName:
		var act = ar.get_action(aid)
		if act == null:
			return &""
		var attacker_id: StringName = act.record.get("attacker_id", &"")
		if attacker_id == enemy_mech.mech_id:
			return player_mech.mech_id   # attackA：enemy 打 player
		if attacker_id == player_mech.mech_id:
			return enemy_mech.mech_id    # attackB：player 联合攻击打 enemy
		return &""
	driver.move_cell_for = func(_aid: StringName, _params: Dictionary) -> StringName:
		return &""  # 取消移动
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]:
		return []   # 不响应
	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	# ── enemy 打出攻击牌 A（真实 use_action_card -> attack 链）──
	var res := battle.execute_use_action_card(&"enemy", card_a)
	if String(res.get("state", &"")) == &"error":
		return "enemy use_action_card 发起失败: %s" % str(res)

	# 驱动到联合弹窗挂起（select_unite_attack_card 被拦截，drain 会停）
	await driver.drain(500)
	if driver.unite_action_id == &"":
		# 没弹联合窗——可能 attackA 未走到 ATTACK_SETTLE，诊断当前等待态
		var st := []
		for aid: StringName in ar.get_active_ids():
			var a = ar.get_action(aid)
			if a:
				st.append("%s:%s:%s" % [String(aid), String(a.action_type), String(a.state)])
		return "未捕获到 select_unite_attack_card（联合弹窗未弹）。活跃动作: %s" % str(st)

	# ── 玩家确认联合攻击：resume_pending_effect 创建 use_action_card(B) + 继续 attackA ──
	battle.context.timing_engine.resume_pending_effect(driver.unite_action_id, {"selected_card_id": card_b})
	# flush deferred（attackA 完成 -> 通知 use_action_card(A) 续跑结算弃牌）
	for _i in range(8):
		await _frame()

	# ═══ 关键断言（并行）═══
	# 1) 攻击牌 A 应已弃置（use_action_card(A) 结算弃牌），不在临时区
	var card_a_obj = gs.get_card(card_a)
	if card_a_obj == null:
		return "card_a 实例丢失"
	if String(card_a_obj.zone) == &"temp_zone":
		return "BUG：攻击牌A 仍在临时区（attackA 应在联合弹窗确认后立即推进结算弃牌，不等攻击B）。zone=%s" % String(card_a_obj.zone)
	if String(card_a_obj.zone) != &"discard":
		return "攻击牌A 应已弃置(discard)，实际 zone=%s" % String(card_a_obj.zone)

	# 2) use_action_card(B) 应已创建（联合诱导的攻击牌B 进入临时区或正在打）
	var use_b_id: StringName = &""
	for sub in ar.get_actions_by_type(&"use_action_card"):
		if sub != null and String(sub.record.get("card_instance_id", &"")) == String(card_b):
			use_b_id = sub.action_id
			break
	if use_b_id == &"":
		return "联合攻击 use_action_card(B) 未创建"
	var use_b = ar.get_action(use_b_id)
	if use_b == null:
		return "use_action_card(B) 未在注册表"
	# use_action_card(B) 应是独立顶层动作（parent_action_id 空），不阻塞 attackA
	if use_b.parent_action_id != &"":
		return "use_action_card(B) 应为独立顶层动作(parent_action_id 空)，实际=%s" % String(use_b.parent_action_id)

	# 3) 攻击牌B 应在临时区（use_action_card(B) 尚未结算弃牌，等 attackB 完成）
	var card_b_obj = gs.get_card(card_b)
	if card_b_obj == null:
		return "card_b 实例丢失"
	if String(card_b_obj.zone) != &"temp_zone":
		return "攻击牌B 应在临时区（attackB 未结算），实际 zone=%s" % String(card_b_obj.zone)

	# ── 清理：把联合攻击B 链跑完或取消，避免残留 ──
	# 取消 use_action_card(B) 子树（attackB 等）
	battle.context.action_engine.cancel_action(use_b_id)
	for _i in range(5):
		await _frame()
	return true
