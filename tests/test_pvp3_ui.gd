## test_pvp3_ui.gd - 3人UI信息隐藏验证（阶段6）
##
## 验证 3人PvP 下 UI 正确显示多对手、隐藏己方：
##   1. enemy_info_popup 3人显示2个对手块（enemy+third）
##   2. 状态栏 _build_status_bar_text 含2个"敌方"段
##   3. 2人兼容：enemy_info_popup 只显示1个对手块
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _EnemyInfoPopup = preload("res://scripts/ui/enemy_info_popup.gd")


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


## 建 PVP3 host（start_pvp3，3玩家 player/enemy/third）。
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


## 建 2人局（start_tutorial，PVE）。
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


## 收集 enemy_info_popup 中对手标题（【pid】形式的 Label）
func _collect_opponent_titles(popup) -> Array[String]:
	var titles: Array[String] = []
	for child in popup._content_container.get_children():
		if child is Label:
			var t: String = child.text
			if t.begins_with("【"):
				titles.append(t)
	return titles


# ═══════════════════════════════════════════
# 3人：enemy_info_popup 显示2个对手块
# ═══════════════════════════════════════════
func test_pvp3_enemy_info_popup_two_opponents() -> Variant:
	var app_root = await _build_pvp3(42)
	if app_root == null:
		return "建局失败"
	app_root.battle._sync_compat_fields()
	var popup = _EnemyInfoPopup.new()
	Engine.get_main_loop().root.add_child(popup)
	await _pump(2)
	popup.configure(app_root.battle.context, &"player")
	var titles := _collect_opponent_titles(popup)
	popup.queue_free()
	await _pump(1)
	await _free_app_root(app_root)
	if titles.size() != 2:
		return "期望2个对手标题，实际 %d: %s" % [titles.size(), str(titles)]
	if not ("【enemy】" in titles and "【third】" in titles):
		return "缺少 enemy/third 标题: %s" % str(titles)
	return true


# ═══════════════════════════════════════════
# 3人：状态栏含2个"敌方"段
# ═══════════════════════════════════════════
func test_pvp3_status_bar_two_enemies() -> Variant:
	var app_root = await _build_pvp3(99)
	if app_root == null:
		return "建局失败"
	app_root.battle._sync_compat_fields()
	var text: String = app_root._build_status_bar_text()
	await _free_app_root(app_root)
	if "敌方(enemy)" not in text:
		return "状态栏缺少 enemy 段: %s" % text
	if "敌方(third)" not in text:
		return "状态栏缺少 third 段: %s" % text
	# 己方段应标记"我方(player)"
	if "我方(player)" not in text:
		return "状态栏缺少己方段: %s" % text
	return true


# ═══════════════════════════════════════════
# 2人兼容：enemy_info_popup 只显示1个对手块
# ═══════════════════════════════════════════
func test_two_player_enemy_info_one_opponent() -> Variant:
	var app_root = await _build_two_player(7)
	if app_root == null:
		return "建局失败"
	app_root.battle._sync_compat_fields()
	var popup = _EnemyInfoPopup.new()
	Engine.get_main_loop().root.add_child(popup)
	await _pump(2)
	popup.configure(app_root.battle.context, &"player")
	var titles := _collect_opponent_titles(popup)
	popup.queue_free()
	await _pump(1)
	await _free_app_root(app_root)
	if titles.size() != 1:
		return "2人局期望1个对手标题，实际 %d: %s" % [titles.size(), str(titles)]
	if "【enemy】" not in titles:
		return "2人局缺少 enemy 标题: %s" % str(titles)
	return true
