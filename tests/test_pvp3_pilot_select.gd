## test_pvp3_pilot_select.gd - 3人机师九选一流程验证（阶段4）
##
## 验证 PVP3 开局机师选择：
##   - _generate_pvp3_pilot_pool：9 张分 3 组各 3（host/enemy/third 不重复）
##   - _check_pvp3_all_selected：三方都选完 -> 按顺序 set_pilot + start_turn
##   - 2人 _generate_pvp_pilot_pool 仍 6 张分 2 组（兼容）
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


## 建 PVP3 host（start_pvp3 建局，不 spawn client / 不 start_turn / 不 _show_battle，
## 由测试按需触发）。game_mode=PVP3, local=player。
func _build_pvp3_host(seed_val: int):
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
	app_root.is_network_client = false
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = seed_val
	app_root.battle.pvp_map_features = true
	var r = app_root.battle.start_pvp3(app_root.registry)
	if not app_root._status_ok(r):
		await _free_app_root(app_root)
		return null
	return app_root


# ═══════════════════════════════════════════
# _generate_pvp3_pilot_pool：9 张分 3 组不重复
# ═══════════════════════════════════════════

func test_pvp3_pilot_pool_nine_split() -> Variant:
	var app_root = await _build_pvp3_host(3456)
	if app_root == null:
		return "建局失败"
	app_root._generate_pvp3_pilot_pool()
	# host 本方 3 张
	if app_root._pvp_pilot_pool.size() != 3:
		await _free_app_root(app_root)
		return "host 候选应为3张，实际 %d" % app_root._pvp_pilot_pool.size()
	# enemy 3 + third 3
	var e_ids: Array = app_root._pvp3_client_pilot_ids.get("enemy", [])
	var t_ids: Array = app_root._pvp3_client_pilot_ids.get("third", [])
	if e_ids.size() != 3 or t_ids.size() != 3:
		await _free_app_root(app_root)
		return "enemy/third 候选应各3张，实际 enemy=%d third=%d" % [e_ids.size(), t_ids.size()]
	# 9 张不重复
	var all_ids: Array = []
	for item in app_root._pvp_pilot_pool:
		all_ids.append(String(item.get("id", "")))
	all_ids += e_ids + t_ids
	var uniq: Dictionary = {}
	for id in all_ids:
		uniq[id] = true
	if uniq.size() != 9:
		await _free_app_root(app_root)
		return "9张候选有重复，唯一数 %d" % uniq.size()
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# _check_pvp3_all_selected：三方都选完 -> set_pilot + start_turn
# ═══════════════════════════════════════════

func test_pvp3_all_selected_sets_three_pilots() -> Variant:
	var app_root = await _build_pvp3_host(4567)
	if app_root == null:
		return "建局失败"
	app_root._generate_pvp3_pilot_pool()
	# 模拟三方选择：本方选 host 候选第1张，enemy/third 选各自候选第1张
	app_root._pvp_my_pilot_id = String(app_root._pvp_pilot_pool[0].get("id", ""))
	app_root._pvp_remote_pilots["enemy"] = app_root._pvp3_client_pilot_ids["enemy"][0]
	app_root._pvp_remote_pilots["third"] = app_root._pvp3_client_pilot_ids["third"][0]
	app_root._pvp_pilot_selecting = true
	app_root._check_pvp3_all_selected()
	await _pump(3)
	# 触发完成标志
	if app_root._pvp_pilot_selecting != false:
		await _free_app_root(app_root)
		return "_check_pvp3_all_selected 未触发完成（_pvp_pilot_selecting 仍为 true）"
	# 三方机师都 set_pilot
	var gs = app_root.battle.context.game_state
	for pid in [&"player", &"enemy", &"third"]:
		var mech = gs.get_mech_for_player(pid)
		if mech == null:
			await _free_app_root(app_root)
			return "%s 无机甲" % String(pid)
		var pslot = mech.slots.get(&"pilot")
		if pslot == null or pslot.equipped_card == null:
			await _free_app_root(app_root)
			return "%s 机师未设置" % String(pid)
	# 首回合启动（active=player）
	if gs.active_player_id != &"player":
		await _free_app_root(app_root)
		return "首回合未启动，active=%s" % String(gs.active_player_id)
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# _check_pvp3_all_selected 未集齐不触发（只2方选完）
# ═══════════════════════════════════════════

func test_pvp3_all_selected_not_triggered_when_missing() -> Variant:
	var app_root = await _build_pvp3_host(5678)
	if app_root == null:
		return "建局失败"
	app_root._generate_pvp3_pilot_pool()
	# 只有本方 + enemy 选完，third 未选
	app_root._pvp_my_pilot_id = String(app_root._pvp_pilot_pool[0].get("id", ""))
	app_root._pvp_remote_pilots["enemy"] = app_root._pvp3_client_pilot_ids["enemy"][0]
	app_root._pvp_pilot_selecting = true
	app_root._check_pvp3_all_selected()
	await _pump(2)
	# 不应触发完成（仍 selecting）
	if app_root._pvp_pilot_selecting != true:
		await _free_app_root(app_root)
		return "third 未选不应触发完成"
	# active 不应被设
	if app_root.battle.context.game_state.active_player_id != &"":
		await _free_app_root(app_root)
		return "未集齐不应 start_turn"
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# client(enemy)视角：收到 player+third 选择后触发开战
# 回归 bug1：原 _check_pvp3_all_selected 硬编码检查 enemy+third，client(enemy)视角
# 对手是 player+third，检查 enemy 永不满足 -> client 永不进游戏。
# ═══════════════════════════════════════════
func test_pvp3_client_view_all_selected_triggers() -> Variant:
	var app_root = await _build_pvp3_host(6789)
	if app_root == null:
		return "建局失败"
	app_root._generate_pvp3_pilot_pool()
	# client(enemy)视角：本方候选=enemy的3张，收到 player+third 选择
	var enemy_picks: Array = app_root._pvp3_client_pilot_ids["enemy"]
	var third_picks: Array = app_root._pvp3_client_pilot_ids["third"]
	var player_pick: String = String(app_root._pvp_pilot_pool[0].get("id", ""))
	app_root.local_player_id = &"enemy"
	app_root.is_network_client = true
	app_root._pvp_my_pilot_id = String(enemy_picks[0])
	app_root._pvp_remote_pilots["player"] = player_pick
	app_root._pvp_remote_pilots["third"] = String(third_picks[0])
	app_root._pvp_pilot_selecting = true
	app_root._check_pvp3_all_selected()
	await _pump(3)
	if app_root._pvp_pilot_selecting != false:
		await _free_app_root(app_root)
		return "client(enemy)视角收齐 player+third 后未触发开战（bug1 未修复：硬编码 enemy+third 检查）"
	var gs = app_root.battle.context.game_state
	if gs.active_player_id != &"player":
		await _free_app_root(app_root)
		return "client视角首回合未启动 active=%s" % String(gs.active_player_id)
	# 三方机师都 set_pilot（client 视角也按 player->enemy->third 顺序设）
	for pid in [&"player", &"enemy", &"third"]:
		var mech = gs.get_mech_for_player(pid)
		if mech == null or mech.slots.get(&"pilot") == null or mech.slots[&"pilot"].equipped_card == null:
			await _free_app_root(app_root)
			return "client视角 %s 机师未设置" % String(pid)
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 2人兼容：_generate_pvp_pilot_pool 仍 6 张分 2 组
# ═══════════════════════════════════════════

func test_pvp_pilot_pool_two_player_compat() -> Variant:
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		await _free_app_root(app_root)
		return "app_root 初始化失败"
	app_root.game_mode = &"PVP"
	app_root.local_player_id = &"player"
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = 8888
	var r = app_root.battle.start_tutorial(app_root.registry)
	if not app_root._status_ok(r):
		await _free_app_root(app_root)
		return "2人建局失败"
	app_root._generate_pvp_pilot_pool()
	# 2人：host 3 + client 3 = 6
	if app_root._pvp_pilot_pool.size() != 3:
		await _free_app_root(app_root)
		return "2人 host 候选应为3张，实际 %d" % app_root._pvp_pilot_pool.size()
	if app_root._pvp_client_pilot_ids.size() != 3:
		await _free_app_root(app_root)
		return "2人 client 候选应为3张，实际 %d" % app_root._pvp_client_pilot_ids.size()
	# 6 张不重复
	var all_ids: Array = []
	for item in app_root._pvp_pilot_pool:
		all_ids.append(String(item.get("id", "")))
	all_ids += app_root._pvp_client_pilot_ids
	var uniq: Dictionary = {}
	for id in all_ids:
		uniq[id] = true
	if uniq.size() != 6:
		await _free_app_root(app_root)
		return "2人 6张候选有重复，唯一数 %d" % uniq.size()
	await _free_app_root(app_root)
	return true
