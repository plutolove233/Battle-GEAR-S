## test_pvp3_victory.gd - 3人胜利条件验证（阶段5）
##
## 验证 VictoryService._check_pvp3_victory：
##   - 淘汰制：存活数<=1 终局，存活者胜
##   - 未终局：只淘汰1方仍 active
##   - 回合上限：全员 HP 比较，最高者胜
##   - 2人兼容：winner 字段 + state 相对 player
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")


func _pump(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _free_app_root(app_root) -> void:
	if app_root != null:
		app_root.queue_free()
	await _pump(2)


## 建 PVP3 host（start_pvp3，设 game_mode=PVP3 temp_value）。
func _build_pvp3(seed_val: int):
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		await _free_app_root(app_root)
		return null
	app_root.game_mode = &"PVP3"
	app_root.local_player_id = &"player"
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = seed_val
	app_root.battle.pvp_map_features = true
	var r = app_root.battle.start_pvp3(app_root.registry)
	if not app_root._status_ok(r):
		await _free_app_root(app_root)
		return null
	return app_root


## 建 2人局（start_tutorial，默认 2人胜利路径）。
func _build_two_player(seed_val: int):
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		await _free_app_root(app_root)
		return null
	app_root.game_mode = &"PVE"
	app_root.local_player_id = &"player"
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = seed_val
	var r = app_root.battle.start_tutorial(app_root.registry)
	if not app_root._status_ok(r):
		await _free_app_root(app_root)
		return null
	return app_root


func _kill(mech) -> void:
	if mech != null:
		mech.destroyed = true
		mech.current_hp = 0


# ═══════════════════════════════════════════
# 淘汰制：player 最后存活 -> victory
# ═══════════════════════════════════════════

func test_pvp3_elimination_player_survives() -> Variant:
	var app_root = await _build_pvp3(6789)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	_kill(gs.get_mech_for_player(&"enemy"))
	_kill(gs.get_mech_for_player(&"third"))
	var result = app_root.battle.context.victory_service.check_victory()
	if String(result.get("state", "")) != "victory":
		await _free_app_root(app_root)
		return "player 存活应 victory，实际 %s" % String(result.get("state", ""))
	if String(result.get("winner", "")) != "player":
		await _free_app_root(app_root)
		return "winner 应为 player，实际 %s" % String(result.get("winner", ""))
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 淘汰制：enemy 最后存活 -> defeat（相对 player）
# ═══════════════════════════════════════════

func test_pvp3_elimination_enemy_survives() -> Variant:
	var app_root = await _build_pvp3(7890)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	_kill(gs.get_mech_for_player(&"player"))
	_kill(gs.get_mech_for_player(&"third"))
	var result = app_root.battle.context.victory_service.check_victory()
	if String(result.get("state", "")) != "defeat":
		await _free_app_root(app_root)
		return "enemy 存活应 defeat（相对 player），实际 %s" % String(result.get("state", ""))
	if String(result.get("winner", "")) != "enemy":
		await _free_app_root(app_root)
		return "winner 应为 enemy，实际 %s" % String(result.get("winner", ""))
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 未终局：只淘汰1方仍 active
# ═══════════════════════════════════════════

func test_pvp3_not_over_when_two_alive() -> Variant:
	var app_root = await _build_pvp3(8901)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	_kill(gs.get_mech_for_player(&"third"))
	var result = app_root.battle.context.victory_service.check_victory()
	if String(result.get("state", "")) != "active":
		await _free_app_root(app_root)
		return "2方存活应 active，实际 %s" % String(result.get("state", ""))
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 回合上限：全员 HP 比较，最高者胜
# ═══════════════════════════════════════════

func test_pvp3_turn_limit_highest_hp_wins() -> Variant:
	var app_root = await _build_pvp3(9012)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	gs.temp_values["turn_limit"] = 30
	gs.turn_number = 30
	# player HP 最高
	gs.get_mech_for_player(&"player").current_hp = 20
	gs.get_mech_for_player(&"enemy").current_hp = 10
	gs.get_mech_for_player(&"third").current_hp = 15
	var result = app_root.battle.context.victory_service.check_victory()
	if String(result.get("state", "")) != "victory":
		await _free_app_root(app_root)
		return "player HP 最高应 victory，实际 %s" % String(result.get("state", ""))
	if String(result.get("winner", "")) != "player":
		await _free_app_root(app_root)
		return "winner 应为 player，实际 %s" % String(result.get("winner", ""))
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 回合上限：enemy HP 最高 -> defeat（相对 player）
# ═══════════════════════════════════════════

func test_pvp3_turn_limit_enemy_highest() -> Variant:
	var app_root = await _build_pvp3(1122)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	gs.temp_values["turn_limit"] = 30
	gs.turn_number = 30
	gs.get_mech_for_player(&"player").current_hp = 10
	gs.get_mech_for_player(&"enemy").current_hp = 20
	gs.get_mech_for_player(&"third").current_hp = 15
	var result = app_root.battle.context.victory_service.check_victory()
	if String(result.get("state", "")) != "defeat":
		await _free_app_root(app_root)
		return "enemy HP 最高应 defeat，实际 %s" % String(result.get("state", ""))
	if String(result.get("winner", "")) != "enemy":
		await _free_app_root(app_root)
		return "winner 应为 enemy，实际 %s" % String(result.get("winner", ""))
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 2人兼容：淘汰 enemy -> winner=player, state=victory
# ═══════════════════════════════════════════

func test_two_player_winner_field() -> Variant:
	var app_root = await _build_two_player(2233)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	_kill(gs.get_mech_for_player(&"enemy"))
	var result = app_root.battle.context.victory_service.check_victory()
	if String(result.get("state", "")) != "victory":
		await _free_app_root(app_root)
		return "2人淘汰 enemy 应 victory，实际 %s" % String(result.get("state", ""))
	if String(result.get("winner", "")) != "player":
		await _free_app_root(app_root)
		return "2人 winner 应为 player，实际 %s" % String(result.get("winner", ""))
	await _free_app_root(app_root)
	return true
