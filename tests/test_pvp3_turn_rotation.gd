## test_pvp3_turn_rotation.gd - 3人回合轮转验证（阶段3）
##
## 验证 _net_end_turn 接入的 get_next_player_id 序列：
##   - 完整轮转周期 player->enemy->third->player
##   - 淘汰玩家被跳过（enemy 结束后淘汰 third 直接到 player）
##   - 2人局 _is_pvp_mode / get_opponent_player_id 路径不受影响（兼容）
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


## 同种子建 3人局（直接 BattleState.start_pvp3）。
func _build_pvp3(seed_val: int):
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		await _free_app_root(app_root)
		return null
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = seed_val
	app_root.battle.pvp_map_features = true
	var r = app_root.battle.start_pvp3(app_root.registry)
	if not app_root._status_ok(r):
		await _free_app_root(app_root)
		return null
	return app_root


# ═══════════════════════════════════════════
# 完整轮转周期 player->enemy->third->player
# 模拟 _net_end_turn: end_turn(pid) + start_turn(get_next_player_id(pid))
# ═══════════════════════════════════════════

func test_pvp3_turn_full_cycle() -> Variant:
	var app_root = await _build_pvp3(1234)
	if app_root == null:
		return "建局失败"
	var battle = app_root.battle
	var gs = battle.context.game_state
	var ts = battle.context.turn_service
	# player 回合
	battle.start_turn("player")
	if gs.active_player_id != &"player":
		await _free_app_root(app_root)
		return "start_turn(player) 后 active 应为 player，实际 %s" % String(gs.active_player_id)
	# end player -> enemy（_net_end_turn 序列）
	ts.end_turn(&"player")
	battle.start_turn(String(gs.get_next_player_id(&"player")))
	if gs.active_player_id != &"enemy":
		await _free_app_root(app_root)
		return "player 结束后应到 enemy，实际 %s" % String(gs.active_player_id)
	# end enemy -> third
	ts.end_turn(&"enemy")
	battle.start_turn(String(gs.get_next_player_id(&"enemy")))
	if gs.active_player_id != &"third":
		await _free_app_root(app_root)
		return "enemy 结束后应到 third，实际 %s" % String(gs.active_player_id)
	# end third -> player（完整周期回到首位）
	ts.end_turn(&"third")
	battle.start_turn(String(gs.get_next_player_id(&"third")))
	if gs.active_player_id != &"player":
		await _free_app_root(app_root)
		return "third 结束后应回到 player，实际 %s" % String(gs.active_player_id)
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 淘汰玩家被跳过：third 淘汰后 enemy 结束直接到 player
# ═══════════════════════════════════════════

func test_pvp3_turn_skip_eliminated() -> Variant:
	var app_root = await _build_pvp3(2345)
	if app_root == null:
		return "建局失败"
	var battle = app_root.battle
	var gs = battle.context.game_state
	var ts = battle.context.turn_service
	# 淘汰 third
	var tm = gs.get_mech_for_player(&"third")
	tm.destroyed = true
	tm.current_hp = 0
	# player -> enemy（不经过 third）
	battle.start_turn("player")
	ts.end_turn(&"player")
	battle.start_turn(String(gs.get_next_player_id(&"player")))
	if gs.active_player_id != &"enemy":
		await _free_app_root(app_root)
		return "player 结束后应到 enemy，实际 %s" % String(gs.active_player_id)
	# enemy -> player（跳过淘汰的 third）
	ts.end_turn(&"enemy")
	battle.start_turn(String(gs.get_next_player_id(&"enemy")))
	if gs.active_player_id != &"player":
		await _free_app_root(app_root)
		return "enemy 结束后淘汰 third 应跳到 player，实际 %s" % String(gs.active_player_id)
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 2人兼容：_is_pvp_mode 对 PVP/PVE 判定 + 2人局仍走 get_opponent_player_id 路径
# ═══════════════════════════════════════════

func test_is_pvp_mode_and_two_player_compat() -> Variant:
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		await _free_app_root(app_root)
		return "app_root 初始化失败"
	# _is_pvp_mode 判定
	app_root.game_mode = &"PVE"
	if app_root._is_pvp_mode() != false:
		await _free_app_root(app_root)
		return "PVE 不应是 PvP 模式"
	app_root.game_mode = &"PVP"
	if app_root._is_pvp_mode() != true:
		await _free_app_root(app_root)
		return "PVP 应是 PvP 模式"
	app_root.game_mode = &"PVP3"
	if app_root._is_pvp_mode() != true:
		await _free_app_root(app_root)
		return "PVP3 应是 PvP 模式"
	# 2人局 get_opponent_player_id 路径不受 PVP3 改动影响
	app_root.game_mode = &"PVP"
	app_root.local_player_id = &"player"
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = 999
	var r = app_root.battle.start_tutorial(app_root.registry)
	if not app_root._status_ok(r):
		await _free_app_root(app_root)
		return "2人建局失败"
	var gs = app_root.battle.context.game_state
	# 2人 _pvp_start_other_turn 走 _opponent_player_id（player<->enemy）
	if app_root._opponent_player_id() != &"enemy":
		await _free_app_root(app_root)
		return "2人 player 的对手应为 enemy，实际 %s" % String(app_root._opponent_player_id())
	# 2人 _net_end_turn 走 get_opponent_player_id（非 get_next_player_id）
	if gs.get_opponent_player_id(&"player") != &"enemy":
		await _free_app_root(app_root)
		return "2人 get_opponent_player_id(player) 应为 enemy"
	await _free_app_root(app_root)
	return true
