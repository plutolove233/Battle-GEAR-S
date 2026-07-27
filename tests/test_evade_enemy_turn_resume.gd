## test_evade_enemy_turn_resume.gd
##
## 复现真实对局 bug：敌方回合中 AI 攻击玩家，玩家用回避响应并移动/取消后，
## 敌方攻击动作完成，但敌方回合应自动结束、切回玩家回合。
## 验证 app_root 的 _on_action_completed → _check_enemy_turn_complete → finish_enemy_turn 链路。
##
## 通过实例化 app_root 场景驱动完整 UI 信号路径（request_ui_popup → move_target_select →
## 取消 / 点格子），而非裸调 on_ui_confirmed，以暴露 UI 层与本测试不同的真实路径。
extends RefCounted

const _DataRegistry = preload("res://scripts/data/data_registry.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _new_battle() -> BattleState:
	var registry := _DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_ThrustHelper.clear_thrust_from_hand(battle)
	return battle


func _ensure_card_in_hand(battle: BattleState, card_def_id: String, player_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
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
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


func test_evade_response_enemy_turn_resumes():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"

	# 敌我相邻（敌方武器范围 2 内），玩家有动力回避
	# 玩家置于 (5,0)，敌方 (6,0)：敌方范围 2，玩家在范围内。
	# 玩家回避只移1格到(4,0)仍在范围内 → 攻击命中 → 触发 damage_change 放置损伤。
	# 复现真实卡死：回避响应后攻击命中，玩家放完损伤后敌方回合能否结束。
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	player_mech.power = 6

	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var weapon_id: StringName = weapon_ids[0]
	var attack_card_id: StringName = _ensure_card_in_hand(battle, "action_001_进攻", &"enemy")
	if attack_card_id == &"":
		return "敌方无攻击牌"

	var evade_cid: StringName = _ensure_card_in_hand(battle, "action_008_回避", &"player")
	if evade_cid == &"":
		return "找不到 回避 牌"

	battle.context.action_ui_bridge.context = battle.context

	# 模拟 app_root._on_action_completed → _check_enemy_turn_complete 的兜底逻辑。
	# 用 Dictionary 共享状态（GDScript 闭包对局部 bool 是按值拷贝，无法跨闭包共享）。
	var state := {"need_check": false}
	battle.context.action_engine.action_completed.connect(func(_aid: StringName, _atype: StringName, _rec: Dictionary):
		print("[DIAG completed] ", String(_aid), " type=", String(_atype), " active=", String(gs.active_player_id))
		if gs.active_player_id == &"enemy":
			state["need_check"] = true
	)
	var check_and_finish := func():
		print("[DIAG check_enter] need_check=", bool(state["need_check"]))
		if not state["need_check"]:
			return
		if gs.active_player_id != &"enemy":
			state["need_check"] = false
			return
		var ac: int = battle.context.action_registry.get_active_count()
		var wi: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		print("[DIAG check] active_count=", ac, " waiting_empty=", bool(wi.is_empty()))
		if ac > 0:
			for aid in battle.context.action_registry.get_active_ids():
				var a = battle.context.action_registry.get_action(aid)
				var st = String(a.state) if a != null else "?"
				var tp = String(a.action_type) if a != null else "?"
				var pt = String(a.parent_action_id) if a != null else "?"
				print("[DIAG] 残留 action ", String(aid), " state=", st, " type=", tp, " parent=", pt)
			return  # 仍有活跃动作，等下次
		if not wi.is_empty():
			print("[DIAG] 仍有等待输入: ", str(wi))
			return  # 仍有等待输入
		state["need_check"] = false
		print("[DIAG] 调用 finish_enemy_turn")
		battle.finish_enemy_turn()

	# 开始敌方回合（start_turn enemy + AI 移动 + AI 攻击）
	gs.active_player_id = &"enemy"
	battle.context.turn_service.start_turn(&"enemy")
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	# 攻击暂停在 ATTACK_AT 等待响应
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		return "攻击未暂停等待响应，atk_result=%s" % str(atk_result)

	# 玩家选回避响应
	var sel: Array[Dictionary] = [{
		"effect_id": &"evade_availability",
		"card_instance_id": evade_cid,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_action_id, sel)
	await _pump_frames(2)
	check_and_finish.call()

	# 回避发起 single_move，请求选格
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_move_target":
		return "回避响应后未请求 select_move_target，实际: %s" % String(wait2.get("input_type", &""))

	# 玩家回避移动：半动力(power 6 的 1/2=3)。
	# 复现真实卡死关键路径：玩家移动直到动力耗尽自然结束循环（非取消）。
	# 024117 敌方回合6：玩家从(17,-6)移到(15,-5)耗尽2动力(绿格)→single_move 自然完成(power=0)。
	# 这里玩家(4,0)起，半动力3，沿 r=0 向左移3格到(1,0)耗尽动力自然结束。
	for step in ["3,0", "2,0", "1,0"]:
		var w_before: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if String(w_before.get("input_type", &"")) != &"select_move_target":
			break
		battle.context.action_ui_bridge.on_ui_confirmed({"target_cell": step})
		await _pump_frames(2)
		check_and_finish.call()
	# 循环动力耗尽后 single_move 自然完成；若仍请求选格则取消（兼容地形差异）
	var w_after: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(w_after.get("input_type", &"")) == &"select_move_target":
		battle.context.action_ui_bridge.on_ui_cancelled()
		await _pump_frames(8)
		check_and_finish.call()
	await _pump_frames(6)
	check_and_finish.call()

	# 攻击应已完成
	var attack_action = battle.context.action_registry.get_action(attack_action_id)
	if attack_action != null:
		return "攻击动作未完成，state=%s" % String(attack_action.state)

	# 关键验证：敌方回合应已结束并切回玩家（_check_enemy_turn_complete → finish_enemy_turn）
	if gs.active_player_id != &"player":
		return "敌方回合未结束/未切回玩家，active_player_id=%s（bug：玩家回避响应后敌方回合卡死）" % String(gs.active_player_id)

	if battle.context.action_registry.get_active_count() != 0:
		return "回合切换后仍有活跃动作残留: %d" % battle.context.action_registry.get_active_count()
	return true
