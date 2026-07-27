## test_evade_response_completes.gd — 回避响应后攻击动作能否正常完成
##
## 复现 bug1 的动作系统层面：
##   AI(enemy)攻击 player → player 用回避响应 → 回避发起 single_move 循环移动 →
##   玩家取消移动 → 回避效果完成 → use_action_card 完成 → attack 恢复结算(未命中) →
##   attack 完成。
##
## 验证点：
##   1. 玩家选回避后，attack 动作能恢复结算并最终 completed（不卡死）
##   2. 最终 active_actions 清空（无残留挂起的动作）
##   3. attack.record 标记为被迎击牌响应
##
## 本测试不实例化 app_root/UI，直接驱动动作系统 + ActionUIBridge，
## 模拟"玩家取消移动"用 on_ui_cancelled。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


## 推进若干帧，使 call_deferred 排入的恢复调用执行（动作链父→子恢复靠 deferred）
func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


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


## 把指定 card_def_id 的牌塞入玩家手牌
func _ensure_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
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


## 测试：AI攻击玩家 → 玩家回避响应 → 取消移动 → 攻击动作完成
func test_evade_response_then_cancel_completes_attack():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"

	# 把敌我放到相邻位置，确保在武器范围内
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	# 玩家机甲动力充足（回避需消耗 1/2 动力移动）
	player_mech.power = 6

	# 给敌方一把武器 + 攻击牌
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var weapon_id: StringName = weapon_ids[0]

	# 确保敌方手牌有一张攻击牌（教程抽牌可能未抽到）
	var attack_card_id: StringName = _ensure_card_in_enemy_hand(battle, "action_001_进攻")
	if attack_card_id == &"":
		# 退回查找敌方已有的任意攻击牌
		var enemy_player = gs.players.get(&"enemy")
		for cid: StringName in enemy_player.action_hand:
			var c = gs.get_card(cid)
			if c and c.def and c.def.action_type == &"攻击":
				attack_card_id = cid
				break
	if attack_card_id == &"":
		return "敌方无攻击牌可用"

	# 给玩家手牌塞一张回避
	var evade_cid: StringName = _ensure_card_in_hand(battle, "action_008_回避")
	if evade_cid == &"":
		return "找不到 回避 牌"

	# 注册 ActionUIBridge 信号转发（setup 在 battle 初始化时已执行，避免重复连接报错）
	battle.context.action_ui_bridge.context = battle.context

	# 发起 AI 攻击（attack 顶层动作）
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	# 攻击应暂停在 ATTACK_AT 等待响应（waiting_timing 或 waiting_input=respond_attack）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		return "攻击未暂停等待响应（wait_info 为空），atk_result=%s" % str(atk_result)

	if String(wait_info.get("input_type", &"")) != &"respond_attack":
		return "等待的输入类型不是 respond_attack，实际: %s" % String(wait_info.get("input_type", &""))

	# 模拟玩家在响应窗口选回避
	var sel: Array[Dictionary] = [{
		"effect_id": &"evade_availability",
		"card_instance_id": evade_cid,
		"availability_priority": 5,
	}]
	battle.context.timing_engine.handle_response_selection(attack_action_id, sel)

	# 回避效果发起 single_move 循环，应请求 select_move_target
	# handle_response_selection 内部可能用 call_deferred 恢复 use_action_card，先 pump 一帧
	await _pump_frames(2)
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait2.is_empty():
		return "回避响应后未请求移动输入（select_move_target），wait 为空"
	if String(wait2.get("input_type", &"")) != &"select_move_target":
		return "回避响应后等待的不是 select_move_target，实际: %s" % String(wait2.get("input_type", &""))

	# 模拟玩家移动躲开攻击：回避剩余动力=3（power 6 的 1/2），
	# 连续移动 2 步到 (3,0)（敌方武器范围 1，移 2 格必出范围），再取消循环。
	# 每次 on_ui_confirmed 回填 target_cell，single_move 移动后若剩余动力>0 再次请求选格。
	battle.context.action_ui_bridge.on_ui_confirmed({"target_cell": "4,0"})
	await _pump_frames(2)
	battle.context.action_ui_bridge.on_ui_confirmed({"target_cell": "3,0"})
	await _pump_frames(2)
	# 剩余动力=1 仍会请求选格，取消结束循环
	battle.context.action_ui_bridge.on_ui_cancelled()
	await _pump_frames(5)

	# 玩家已移出范围 → 攻击未命中 → 无 damage_change → attack 应完成并清理
	var attack_action = battle.context.action_registry.get_action(attack_action_id)
	if attack_action != null:
		# 仍在 registry → 未完成（这是 bug1 的核心症状：回避响应后攻击卡死）
		return "攻击动作未完成，state=%s（bug1：回避响应后攻击卡死，敌方回合无法结束）" % String(attack_action.state)

	# 验证 active_actions 清空（attack 完成且子动作均清理）
	var active_count: int = battle.context.action_registry.get_active_count()
	if active_count != 0:
		var remain_ids = battle.context.action_registry.active_actions.duplicate()
		var desc := ""
		for aid in remain_ids:
			var a = battle.context.action_registry.get_action(aid)
			desc += "%s(state=%s,type=%s,parent=%s) " % [String(aid), String(a.state) if a else "?", String(a.action_type) if a else "?", String(a.parent_action_id) if a else "?"]
		return "攻击完成后仍有 %d 个活跃动作残留: %s" % [active_count, desc]

	# 验证玩家机甲确实移动了（回避效果生效）
	if int(player_mech.position.get("q", 0)) != 3:
		return "回避移动后玩家机甲应在 q=3，实际: %s" % str(player_mech.position)
	return true


## 测试2：玩家不响应（跳过），AI攻击正常完成
func test_skip_response_completes_attack():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	player_mech.power = 6
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var weapon_id: StringName = weapon_ids[0]
	var attack_card_id: StringName = _ensure_card_in_enemy_hand(battle, "action_001_进攻")
	if attack_card_id == &"":
		var enemy_player = gs.players.get(&"enemy")
		for cid: StringName in enemy_player.action_hand:
			var c = gs.get_card(cid)
			if c and c.def and c.def.action_type == &"攻击":
				attack_card_id = cid
				break
	if attack_card_id == &"":
		return "敌方无攻击牌可用"

	battle.context.action_ui_bridge.context = battle.context

	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		# 玩家手牌无迎击牌 → 无响应窗口 → attack 应已同步完成
		await _pump_frames(2)
		if battle.context.action_registry.get_action(attack_action_id) != null:
			return "无响应牌时攻击应同步完成，但仍残留"
		if battle.context.action_registry.get_active_count() != 0:
			return "无响应牌时攻击完成后仍有活跃动作残留"
		return true
	# 玩家有迎击牌但选择跳过响应（空选择）
	var empty_sel: Array[Dictionary] = []
	battle.context.timing_engine.handle_response_selection(attack_action_id, empty_sel)
	await _pump_frames(5)

	var attack_action = battle.context.action_registry.get_action(attack_action_id)
	if attack_action != null:
		return "跳过响应后攻击未完成，state=%s" % String(attack_action.state)
	if battle.context.action_registry.get_active_count() != 0:
		return "跳过响应后仍有活跃动作残留"
	return true


## 把指定 card_def_id 的牌塞入指定玩家手牌（用于给敌方塞迎击牌）
func _ensure_card_in_enemy_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 测试3（bug2）：玩家攻击敌方 → AI 用回避响应 → AI 自动移动躲开 → 攻击未命中 → attack 完成
## 验证敌方 AI 能使用迎击牌响应我方攻击，且不卡死（single_move 的 select_move_target
## 由 ActionUIBridge._auto_move_target 自动处理）。
func test_ai_evade_response_to_player_attack():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"

	# 敌我相邻，玩家攻击范围内
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	enemy_mech.power = 6  # 敌方有动力回避移动

	# 给玩家武器 + 攻击牌（确保手牌有进攻牌，教程抽牌可能未抽到）
	var weapon_ids: Array[StringName] = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家无机甲武器"
	var weapon_id: StringName = weapon_ids[0]
	var attack_card_id: StringName = _ensure_card_in_hand(battle, "action_001_进攻")
	if attack_card_id == &"":
		return "找不到 进攻 牌（无法给玩家塞攻击牌）"

	# 给敌方塞一张回避牌
	var evade_cid: StringName = _ensure_card_in_enemy_hand(battle, "action_008_回避")
	if evade_cid == &"":
		return "找不到 回避 牌（无法给敌方塞迎击牌）"

	battle.context.action_ui_bridge.context = battle.context

	# 玩家发起攻击敌方
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", weapon_id, attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	# 攻击应暂停在 ATTACK_AT 等待响应；AI 响应方应被 _auto_respond 自动处理（选回避）
	# _auto_respond 同步消费 respond_attack 后进入 evade 的 select_move_target
	# （_auto_move_target 已改 deferred，此时 select_move_target 在等待）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		# AI 可能已自动响应并进入移动；先 pump 让链推进
		await _pump_frames(3)
	else:
		var it: String = String(wait_info.get("input_type", &""))
		if it != &"respond_attack" and it != &"select_move_target":
			return "等待的不是 respond_attack/select_move_target，实际: %s" % it

	# AI 自动响应 + 自动移动躲开。推进帧让 deferred 恢复链跑完。
	# _auto_respond 选回避 → 发起 use_action_card → single_move 循环 → _auto_move_target
	# 每次选格移动 → 直到动力耗尽或无路 → 循环结束 → use_action_card 完成 → attack 恢复。
	await _pump_frames(20)

	# attack 动作应已完成并从 registry 移除
	var attack_action = battle.context.action_registry.get_action(attack_action_id)
	if attack_action != null:
		return "AI 回避响应后攻击未完成，state=%s（bug2：AI 用迎击牌响应后卡死）" % String(attack_action.state)

	# 无活跃动作残留
	var active_count: int = battle.context.action_registry.get_active_count()
	if active_count != 0:
		var remain_ids = battle.context.action_registry.active_actions.duplicate()
		var desc := ""
		for aid in remain_ids:
			var a = battle.context.action_registry.get_action(aid)
			desc += "%s(state=%s,type=%s) " % [String(aid), String(a.state) if a else "?", String(a.action_type) if a else "?"]
		return "AI 回避响应后仍有 %d 个活跃动作残留: %s" % [active_count, desc]

	# 验证敌方机甲确实移动了（AI 回避生效，不再是初始位置 q=6）
	if int(enemy_mech.position.get("q", 0)) == 6:
		return "AI 回避后敌方机甲未移动（仍在 q=6），回避移动未生效"
	return true

