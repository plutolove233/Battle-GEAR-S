## test_pvp3_setup.gd - 3人 PvP 建局验证（阶段1）
##
## 验证 GameSetupService.setup_pvp3_battle + BattleState.start_pvp3：
##   - 3玩家3机甲3起始位置 + 全人类
##   - GameState.get_next_player_id 三人轮转（player->enemy->third->player）
##   - 跳过淘汰玩家
##   - alive_player_count
##   - 同种子双端建局牌堆/instance_id 一致（锁步前提）
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


## 同种子建 3人局（不走 app_root 入口，直接 BattleState.start_pvp3）。
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
# 3玩家3机甲3起始位置 + 全人类
# ═══════════════════════════════════════════

func test_pvp3_setup_creates_three_players_and_mechs() -> Variant:
	var app_root = await _build_pvp3(12345)
	if app_root == null:
		return "3人建局失败"
	var gs = app_root.battle.context.game_state
	# 3玩家
	if not gs.players.has(&"player") or not gs.players.has(&"enemy") or not gs.players.has(&"third"):
		await _free_app_root(app_root)
		return "缺少玩家：keys=%s" % str(gs.players.keys())
	# 全人类
	for pid: StringName in gs.players:
		if not gs.players[pid].is_human:
			await _free_app_root(app_root)
			return "%s 不是人类玩家" % String(pid)
	# 3机甲
	if gs.mechs.size() < 3:
		await _free_app_root(app_root)
		return "机甲数不足：%d" % gs.mechs.size()
	var pm = gs.get_mech_for_player(&"player")
	var em = gs.get_mech_for_player(&"enemy")
	var tm = gs.get_mech_for_player(&"third")
	if pm == null or em == null or tm == null:
		await _free_app_root(app_root)
		return "某玩家无机甲"
	if pm.owner_player_id != &"player" or em.owner_player_id != &"enemy" or tm.owner_player_id != &"third":
		await _free_app_root(app_root)
		return "机甲归属错误"
	# 起始位置
	if int(pm.position.get("q", -1)) != 2 or int(pm.position.get("r", -1)) != 2:
		await _free_app_root(app_root)
		return "player 起始位置错误：%s" % str(pm.position)
	if int(em.position.get("q", -1)) != 20 or int(em.position.get("r", -1)) != -6:
		await _free_app_root(app_root)
		return "enemy 起始位置错误：%s" % str(em.position)
	if int(tm.position.get("q", -1)) != 11 or int(tm.position.get("r", -1)) != -3:
		await _free_app_root(app_root)
		return "third 起始位置错误：%s" % str(tm.position)
	# third 复用 frame_001（与 player 同框架 25HP 联邦）
	if tm.max_hp != pm.max_hp:
		await _free_app_root(app_root)
		return "third 框架 HP 与 player 不一致（应复用 frame_001）"
	# 三方各抽4张初始行动牌
	var ph: int = gs.players.get(&"player").action_hand.size()
	var eh: int = gs.players.get(&"enemy").action_hand.size()
	var th: int = gs.players.get(&"third").action_hand.size()
	if ph != 4 or eh != 4 or th != 4:
		await _free_app_root(app_root)
		return "初始行动牌数错误 player=%d enemy=%d third=%d（应各4）" % [ph, eh, th]
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# get_next_player_id 三人轮转
# ═══════════════════════════════════════════

func test_pvp3_next_player_rotation() -> Variant:
	var app_root = await _build_pvp3(222)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	if gs.get_next_player_id(&"player") != &"enemy":
		await _free_app_root(app_root)
		return "player 之后应为 enemy"
	if gs.get_next_player_id(&"enemy") != &"third":
		await _free_app_root(app_root)
		return "enemy 之后应为 third"
	if gs.get_next_player_id(&"third") != &"player":
		await _free_app_root(app_root)
		return "third 之后应回到 player"
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# get_next_player_id 跳过淘汰玩家
# ═══════════════════════════════════════════

func test_pvp3_next_player_skips_eliminated() -> Variant:
	var app_root = await _build_pvp3(333)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	# 淘汰 third
	var tm = gs.get_mech_for_player(&"third")
	tm.destroyed = true
	tm.current_hp = 0
	# enemy 之后应跳过 third 直接到 player
	if gs.get_next_player_id(&"enemy") != &"player":
		await _free_app_root(app_root)
		return "enemy 之后淘汰 third 应跳到 player，实际 %s" % String(gs.get_next_player_id(&"enemy"))
	# player 之后应到 enemy（跳过 third）
	if gs.get_next_player_id(&"player") != &"enemy":
		await _free_app_root(app_root)
		return "player 之后淘汰 third 应到 enemy，实际 %s" % String(gs.get_next_player_id(&"player"))
	# 再淘汰 enemy，只剩 player 存活：get_next 返回自身（不卡流程，胜负由 VictoryService 判定）
	gs.get_mech_for_player(&"enemy").destroyed = true
	gs.get_mech_for_player(&"enemy").current_hp = 0
	if gs.get_next_player_id(&"player") != &"player":
		await _free_app_root(app_root)
		return "只剩 player 存活时 get_next 应返回自身 player，实际 %s" % String(gs.get_next_player_id(&"player"))
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# alive_player_count
# ═══════════════════════════════════════════

func test_pvp3_alive_count() -> Variant:
	var app_root = await _build_pvp3(444)
	if app_root == null:
		return "建局失败"
	var gs = app_root.battle.context.game_state
	if gs.alive_player_count() != 3:
		await _free_app_root(app_root)
		return "初始存活数应为3，实际 %d" % gs.alive_player_count()
	# 淘汰1个
	gs.get_mech_for_player(&"third").destroyed = true
	if gs.alive_player_count() != 2:
		await _free_app_root(app_root)
		return "淘汰 third 后存活数应为2，实际 %d" % gs.alive_player_count()
	# 淘汰2个
	gs.get_mech_for_player(&"enemy").destroyed = true
	if gs.alive_player_count() != 1:
		await _free_app_root(app_root)
		return "淘汰 enemy 后存活数应为1，实际 %d" % gs.alive_player_count()
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 同种子双端建局牌堆/instance_id 一致（锁步前提）
# ═══════════════════════════════════════════

func test_pvp3_seed_deterministic_deck() -> Variant:
	var host = await _build_pvp3(777)
	var client = await _build_pvp3(777)
	if host == null or client == null:
		await _free_app_root(host)
		await _free_app_root(client)
		return "双端建局失败"
	var hg = host.battle.context.game_state
	var cg = client.battle.context.game_state
	# 行动牌堆顺序一致
	if hg.deck_state.action_deck != cg.deck_state.action_deck:
		await _free_app_root(host)
		await _free_app_root(client)
		return "行动牌堆顺序不一致（种子确定性失败）"
	# 三方初始手牌 instance_id 一致（next_id 同序）
	for pid in [&"player", &"enemy", &"third"]:
		if hg.players[pid].action_hand != cg.players[pid].action_hand:
			await _free_app_root(host)
			await _free_app_root(client)
			return "%s 手牌 instance_id 不一致（建局顺序不同步）" % String(pid)
	# third 机甲 HP 一致（复用 frame_001）
	if hg.get_mech_for_player(&"third").current_hp != cg.get_mech_for_player(&"third").current_hp:
		await _free_app_root(host)
		await _free_app_root(client)
		return "third 机甲 HP 不一致"
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 2人兼容：get_next_player_id 对 2人局（无 third）仍正确
# ═══════════════════════════════════════════

func test_get_next_player_id_two_player_compat() -> Variant:
	# 2人 start_tutorial 建 player+enemy（无 third）
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		await _free_app_root(app_root)
		return "app_root 初始化失败"
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = 999
	var r = app_root.battle.start_tutorial(app_root.registry)
	if not app_root._status_ok(r):
		await _free_app_root(app_root)
		return "2人建局失败"
	var gs = app_root.battle.context.game_state
	# 2人：player->enemy, enemy->player（third 不在 players 被跳过）
	if gs.get_next_player_id(&"player") != &"enemy":
		await _free_app_root(app_root)
		return "2人 player 之后应为 enemy，实际 %s" % String(gs.get_next_player_id(&"player"))
	if gs.get_next_player_id(&"enemy") != &"player":
		await _free_app_root(app_root)
		return "2人 enemy 之后应为 player，实际 %s" % String(gs.get_next_player_id(&"enemy"))
	await _free_app_root(app_root)
	return true
