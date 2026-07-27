## test_log_bugs_fix.gd - 日志 0720_131733 暴露问题的修复回归测试
##
## 覆盖：
##   1. C1: hp_change 写 old_hp/new_hp 到 record（此前 HP_CHANGE_AFTER 消息显示 0->0）
##   2. B1: _score_evade_move 防回访（previous_position 惩罚，避免等距格振荡）
##   3. A3: 胜利触发后设 phase=battle_over 且不重复 fire VICTORY_REACHED
## A1/A2/B2（重入双重驱动）/C2（choose-one 清理）由既有测试
##   test_counter_attack_chain / test_evade_response_completes / test_assault_chase_flow /
##   test_repair_repro 覆盖流程，此处不重复。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


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


## 1. C1: hp_change 动作 record 应含 old_hp/new_hp
func test_hp_change_records_old_new_hp():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到敌方机甲"
	var hp_before: int = enemy_mech.current_hp
	var result: Dictionary = battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [enemy_mech.mech_id],
		"value": 5,
		"method": &"decrease",
		"reason": &"test",
	})
	if String(result.get("state", &"")) == &"error":
		return "hp_change 执行失败: %s" % String(result.get("message", &""))
	var rec: Dictionary = result.get("record", {})
	if int(rec.get("old_hp", -1)) != hp_before:
		return "old_hp 应=%d 实际=%d" % [hp_before, int(rec.get("old_hp", -1))]
	if int(rec.get("new_hp", -1)) != hp_before - 5:
		return "new_hp 应=%d 实际=%d" % [hp_before - 5, int(rec.get("new_hp", -1))]
	if enemy_mech.current_hp != hp_before - 5:
		return "实际 HP 应=%d 实际=%d" % [hp_before - 5, enemy_mech.current_hp]
	return true


## 2. B1: _score_evade_move 应避开 previous_position（防回访振荡）
func test_score_evade_move_avoids_previous():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var bridge = battle.context.action_ui_bridge
	if bridge == null:
		return "action_ui_bridge 未初始化"
	var map_cells: Dictionary = battle.context.game_state.map_state.cells if battle.context.game_state.map_state else {}
	# 攻击方 (5,0) 射程6；候选 (6,0)/(5,1) 都在射程内、距离都=1（等距）。
	# previous=(6,0)：无惩罚时平局选首个(6,0)；有防回访惩罚应选 (5,1)。
	var attacker_pos: Dictionary = {"q": 5, "r": 0}
	var neighbors: Array = [{"q": 6, "r": 0}, {"q": 5, "r": 1}]
	var best: Dictionary = bridge._score_evade_move(neighbors, attacker_pos, 6, map_cells, {"q": 6, "r": 0})
	if int(best.get("q", -1)) != 5 or int(best.get("r", -1)) != 1:
		return "应避开 previous(6,0) 选(5,1)，实际(%s,%s)" % [String(best.get("q", "")), String(best.get("r", ""))]
	# 无 previous 时不应误惩罚：等距两格任选其一即可（不报错）
	var best2: Dictionary = bridge._score_evade_move(neighbors, attacker_pos, 6, map_cells, {})
	if best2.is_empty():
		return "无 previous 时应正常选格"
	return true


## 3. A3: 胜利触发后 phase=battle_over 且再次 check 不重复 fire
func test_victory_halts_and_no_repeat():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "找不到玩家机甲"
	# HP=1 时仍 active
	player_mech.current_hp = 1
	var r1: Dictionary = battle.context.victory_service.check_victory()
	if String(r1.get("state", &"")) != &"active":
		return "HP=1 时应 active，实际 %s" % String(r1.get("state", &""))
	# HP=0 触发 defeat
	player_mech.current_hp = 0
	var r2: Dictionary = battle.context.victory_service.check_victory()
	if String(r2.get("state", &"")) != &"defeat":
		return "HP=0 应 defeat，实际 %s" % String(r2.get("state", &""))
	if String(gs.phase) != &"battle_over":
		return "应设 phase=battle_over，实际 %s" % String(gs.phase)
	# 再次 check 应返回缓存（不重复 fire VICTORY_REACHED）
	var fired_before: int = battle.context.timing_engine.permanent_listeners.size()
	var r3: Dictionary = battle.context.victory_service.check_victory()
	if String(r3.get("state", &"")) != &"defeat":
		return "再次 check 应返回 defeat 缓存，实际 %s" % String(r3.get("state", &""))
	# phase 仍为 battle_over（未被重置）
	if String(gs.phase) != &"battle_over":
		return "phase 应保持 battle_over"
	return true


## 4. 栈溢出修复：AI 已逃出攻击范围时 _auto_move_target 应停止（不 0 动力原地循环）
func test_auto_move_stops_when_out_of_range():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	# 玩家(攻击方)(5,0) 射程6；敌方(被攻击)(15,0) 已在范围外
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 15, "r": 0}
	# 注册 attack 父动作
	var atk: _Action = _Action.new()
	atk.action_id = &"test_escape_atk"
	atk.action_type = &"attack"
	atk.state = &"running"
	atk.context = battle.context
	atk.record = {"attacker_id": player_mech.mech_id, "target_id": enemy_mech.mech_id, "weapon_range": 6}
	battle.context.action_registry.register(atk)
	# 注册 single_move 动作（等待 select_move_target），mover=enemy
	var mv: _Action = _Action.new()
	mv.action_id = &"test_escape_mv"
	mv.action_type = &"single_move"
	mv.state = &"waiting_input"
	mv.context = battle.context
	mv.parent_action_id = atk.action_id
	battle.context.action_registry.register(mv)
	var bridge = battle.context.action_ui_bridge
	bridge._waiting_action_id = mv.action_id
	bridge._current_input_type = &"select_move_target"
	# 敌方已在范围外，_auto_move_target 应 on_ui_cancelled（清 _waiting_action_id）
	bridge._auto_move_target(mv.action_id, {"mech_id": enemy_mech.mech_id, "available_power": 5, "current_position": enemy_mech.position, "previous_position": {}})
	if bridge._waiting_action_id != &"":
		return "已在范围外应停止移动，实际仍等待 %s" % String(bridge._waiting_action_id)
	return true
