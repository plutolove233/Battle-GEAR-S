## test_app_root_evade_enemy_turn.gd
##
## 用真实 app_root 场景验证：敌方回合中玩家用回避响应后，敌方回合能否自动结束。
## 驱动完整 UI 信号路径（_on_action_completed → _check_enemy_turn_complete → finish_enemy_turn）。
extends Node

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")

var app_root = null
var battle = null
var failures: int = 0


func _ready() -> void:
	_ensure_autoload("SessionLogger", "res://scripts/services/session_logger.gd")
	await get_tree().process_frame
	var result = await _run_evade_enemy_turn_test()
	if typeof(result) == TYPE_BOOL and result == true:
		print("PASS test_app_root_evade_enemy_turn::test_evade_enemy_turn_resumes")
	else:
		failures += 1
		print("FAIL test_app_root_evade_enemy_turn::test_evade_enemy_turn_resumes -> %s" % str(result))
	if failures > 0:
		print("TESTS FAILED: %d" % failures)
	else:
		print("TESTS PASSED")
	get_tree().quit(1 if failures > 0 else 0)


func _ensure_autoload(p_name: String, path: String) -> void:
	var tree := get_tree()
	if tree.root.has_node(p_name):
		return
	var script: Script = load(path)
	var inst = script.new()
	if inst is Node:
		inst.name = p_name
		tree.root.add_child(inst)


func _pump(n: int) -> void:
	var tree := get_tree()
	for i in n:
		await tree.process_frame


func _ensure_card_in_hand(player_id: StringName, card_def_id: String) -> StringName:
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


func _run_evade_enemy_turn_test() -> Variant:
	# 实例化真实 app_root 并初始化（_ready 载入 registry/campaign）
	app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_tree().root.add_child(app_root)
	await _pump(2)

	if app_root.registry == null or app_root.campaign == null:
		return "app_root 初始化失败"

	# 直接走教学战斗（绕过 loadout UI）
	app_root.selected_equipment = {}
	app_root._start_tutorial_battle()
	await _pump(2)
	battle = app_root.battle
	if battle == null or battle.context == null:
		return "battle 未启动"

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"

	# 把敌我放到相邻位置，玩家动力充足
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 7, "r": 0}
	player_mech.power = 6
	var enemy_player = gs.players.get(&"enemy")
	# 确保敌方有攻击牌
	var attack_card_id: StringName = _ensure_card_in_hand(&"enemy", "action_001_进攻")
	if attack_card_id == &"":
		return "敌方无攻击牌"
	# 玩家手牌塞一张回避
	var evade_cid: StringName = _ensure_card_in_hand(&"player", "action_008_回避")
	if evade_cid == &"":
		return "找不到回避牌"

	# 切到敌方回合并发起 AI 攻击
	gs.active_player_id = &"enemy"
	battle.context.turn_service.start_turn(&"enemy")
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_ids[0], attack_card_id)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		return "攻击未暂停等待响应"
	if String(wait_info.get("input_type", &"")) != &"respond_attack":
		return "等待的不是 respond_attack: %s" % String(wait_info.get("input_type", &""))

	# 模拟玩家在响应窗口选回避（走真实 app_root._on_response_selected 路径）
	app_root._on_response_selected(evade_cid)
	await _pump(3)

	# 回避发起 single_move，应请求 select_move_target
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_move_target":
		return "回避响应后未请求 select_move_target: %s" % String(wait2.get("input_type", &""))

	# 玩家移动躲出范围（敌方范围2，从(5,0)移2格到(3,0)脱离）
	app_root._on_battle_hex_clicked({"q": 4, "r": 0})
	await _pump(3)
	app_root._on_battle_hex_clicked({"q": 3, "r": 0})
	await _pump(3)
	# 取消结束循环（若有剩余动力仍在请求选格）
	var wait3: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait3.get("input_type", &"")) == &"select_move_target":
		app_root._on_cancel_attack()
	await _pump(10)

	# 处理可能的 place_damage_tokens（若攻击仍命中）
	for _i in 6:
		var w4: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if String(w4.get("input_type", &"")) == &"place_damage_tokens":
			# 真实游戏由 damage_placement_panel 驱动；此处直接回填
			battle.context.action_ui_bridge.on_ui_confirmed({"placed": true})
			await _pump(4)
		else:
			break
	await _pump(6)

	# 关键验证：敌方回合应已结束、切回玩家回合
	if gs.active_player_id != &"player":
		var ac: int = battle.context.action_registry.get_active_count()
		var wi: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		return "敌方回合未结束/未切回玩家 active=%s active_count=%d waiting_empty=%s（bug：玩家回避响应后敌方回合卡死）" % [String(gs.active_player_id), ac, bool(wi.is_empty())]
	return true
