## test_pilot_066_hacker_pvp3.gd - 诊断：骇客pilot_066窥牌效果 PvP3 三端同步失步
##
## 用户反馈：移动后窥牌查到"攻击"+"迎击"，加成(攻击次数/行动牌上限)延迟才加，
## 且骇客与其他玩家不再同步（不更新位置和响应）。
## 本测试三端对等引擎，驱动真实 move op -> BASIC_MOVE_AFTER -> effect_02 挂起选目标 ->
## resume 广播 -> 加成，逐步断言三端挂起/加成/位置/随机结果一致，定位失步环节。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _pump(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _build(seed_val: int, local_pid: StringName):
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		return null
	app_root.game_mode = &"PVP3"
	app_root.local_player_id = local_pid
	app_root.is_network_client = (String(local_pid) != &"player")
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = seed_val
	app_root.battle.pvp_map_features = true
	var r = app_root.battle.start_pvp3(app_root.registry)
	if not app_root._status_ok(r):
		return null
	var gs = app_root.battle.context.game_state
	for pid: StringName in gs.players:
		gs.players[pid].is_human = true
	app_root.battle.start_turn(&"player")
	app_root._show_battle()
	await _pump(2)
	return app_root


## 三端给 player 机甲设骇客机师牌
func _setup_hacker_3(h, c1, c2) -> String:
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var mech = gs.get_mech_for_player(&"player")
		if mech == null:
			return "player 机甲不存在"
		var cdb = app.battle.context.card_database
		var pdef = cdb.get_card(&"pilot_066_骇客")
		if pdef == null:
			return "pilot_066_骇客 定义不存在"
		var inst_id: StringName = gs.next_id(&"card")
		var card = _CardInstance.new(inst_id, pdef)
		card.owner_player_id = &"player"
		gs.cards[inst_id] = card
		app.battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	await _pump(2)
	return ""


## 三端直接改 enemy 机甲位置到 player 相邻格（保证在 range 3 内）
func _reposition_enemy_3(h, c1, c2) -> void:
	var pos: Dictionary = {}
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var pm = gs.get_mech_for_player(&"player")
		# 选 player 的一个相邻格（避开 player 当前格）
		for n: Dictionary in _HexGrid.neighbors(pm.position):
			var cid: String = "%d,%d" % [int(n.q), int(n.r)]
			if gs.map_state.cells.has(StringName(cid)):
				pos = {"q": int(n.q), "r": int(n.r)}
				break
		if pos.is_empty():
			pos = {"q": int(pm.position.get("q", 2)) + 1, "r": int(pm.position.get("r", 2))}
		var em = gs.get_mech_for_player(&"enemy")
		em.position = pos.duplicate()


## 找一张指定 action_type 的行动牌 def_id
func _find_action_def_id(cdb, want_type: String) -> String:
	for def in cdb.list_cards_by_kind(&"action"):
		if String(def.action_type) == want_type:
			return String(def.card_id)
	return ""


## 三端给 pid 玩家 action_hand 放指定类型行动牌（保证三端手牌内容一致）
func _set_hand_3(h, c1, c2, pid: StringName, types: Array) -> String:
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var p = gs.players.get(pid)
		if p == null:
			return "玩家 %s 不存在" % pid
		p.action_hand.clear()
		var cdb = app.battle.context.card_database
		for t: String in types:
			var def_id := _find_action_def_id(cdb, t)
			if def_id == "":
				return "无%s行动牌定义" % t
			var inst_id: StringName = gs.next_id(&"card")
			var c = _CardInstance.new(inst_id, cdb.get_card(def_id))
			c.owner_player_id = pid
			gs.cards[inst_id] = c
			p.action_hand.append(inst_id)
	await _pump(2)
	return ""


func _wait_info(app) -> Dictionary:
	if app.battle == null or app.battle.context == null or app.battle.context.action_ui_bridge == null:
		return {}
	return app.battle.context.action_ui_bridge.get_waiting_action_info()


func _pending_count(app) -> int:
	return app.battle.context.timing_engine._pending_effect.size()


func _exec3(h, c1, c2, op: String, data: Dictionary, frames: int = 3) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c1._apply_remote_input(op, data)
	c2._apply_remote_input(op, data)
	await _pump(frames)


func _mech_pos(app, pid: StringName) -> String:
	var mech = app.battle.context.game_state.get_mech_for_player(pid)
	if mech == null:
		return "?"
	return "%d,%d" % [int(mech.position.get("q", -99)), int(mech.position.get("r", -99))]


func _attack_bonus(app, pid: StringName) -> int:
	var mech = app.battle.context.game_state.get_mech_for_player(pid)
	if mech == null:
		return -99
	return int(mech.max_attacks_per_turn)


func _hand_limit(app, pid: StringName) -> int:
	var p = app.battle.context.game_state.players.get(pid)
	if p == null:
		return -99
	return int(p.action_card_limit)


func _free3(h, c1, c2) -> void:
	for app in [h, c1, c2]:
		if app != null:
			app.queue_free()
	await _pump(3)


## 主场景：三端移动触发窥牌 -> 选目标 -> resume -> 断言三端一致
func test_p066_peek_pvp3_sync() -> Variant:
	var h = await _build(66201, &"player")
	var c1 = await _build(66201, &"enemy")
	var c2 = await _build(66201, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_hacker_3(h, c1, c2)
	if err != "":
		await _free3(h, c1, c2)
		return err
	# 目标手牌：enemy 持 攻击+迎击（触发攻击+行动牌上限加成）
	err = await _set_hand_3(h, c1, c2, &"enemy", ["攻击", "迎击"])
	if err != "":
		await _free3(h, c1, c2)
		return err
	# enemy 机甲挪到 player 相邻格（range 3 内）
	_reposition_enemy_3(h, c1, c2)
	await _pump(2)
	var diag: Array = []
	# player 机甲找一个相邻空格移动
	var pm = h.battle.context.game_state.get_mech_for_player(&"player")
	var cell: Dictionary = {}
	for n: Dictionary in _HexGrid.neighbors(pm.position):
		var cid: String = "%d,%d" % [int(n.q), int(n.r)]
		if not h.battle.context.game_state.map_state.cells.has(StringName(cid)):
			continue
		var occupied: bool = false
		for mid: StringName in h.battle.context.game_state.mechs:
			var m = h.battle.context.game_state.mechs[mid]
			if m != null and not m.destroyed and int(m.position.get("q", 0)) == int(n.q) and int(m.position.get("r", 0)) == int(n.r):
				occupied = true
				break
		if not occupied:
			cell = {"q": int(n.q), "r": int(n.r)}
			break
	if cell.is_empty():
		await _free3(h, c1, c2)
		return "无相邻空格"
	# ① 三端移动 op
	await _exec3(h, c1, c2, "move", {"player_id": "player", "q": cell.q, "r": cell.r})
	var pos_h: String = _mech_pos(h, &"player")
	var b_slot := func(app) -> String:
		var b = app.battle.context.action_ui_bridge
		return "%s/%s" % [String(b._waiting_action_id), String(b._current_input_type)]
	diag.append("移动后: pos=%s pending=%d/%d/%d wait=%s/%s/%s slot=%s|%s|%s" % [pos_h,
		_pending_count(h), _pending_count(c1), _pending_count(c2),
		String(_wait_info(h).get("input_type", &"")), String(_wait_info(c1).get("input_type", &"")), String(_wait_info(c2).get("input_type", &"")),
		b_slot.call(h), b_slot.call(c1), b_slot.call(c2)])
	# ② 三端应都挂起 select_mech_target（骇客窥牌选目标）
	if String(_wait_info(h).get("input_type", &"")) != &"select_mech_target":
		diag.append("FAIL h 未进入窥牌选目标 wait=%s" % String(_wait_info(h).get("input_type", &"")))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if not (_pending_count(h) == 1 and _pending_count(c1) == 1 and _pending_count(c2) == 1):
		diag.append("FAIL pending 不同步 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	# ③ 修复后真实路径：骇客端本地点格子 -> select_mech_target 确认带 action_id 走
	#    resume_effect 精确路由广播到三端（各自帧末 deferred 执行）；差异化帧延迟模拟网络时序。
	#    （修复前走 ui_confirmed 共享槽，对端槽被 skip_remote_waiting 清空后丢输入失步）
	var aid: StringName = StringName(_wait_info(h).get("action_id", &""))
	var enemy_mech = h.battle.context.game_state.get_mech_for_player(&"enemy")
	var relay_uc: Dictionary = {"action_id": String(aid), "data": {"target_id": String(enemy_mech.mech_id)}}
	h._net_exec("resume_effect", relay_uc)
	await _pump(1)
	c1._apply_remote_input("resume_effect", relay_uc)
	await _pump(2)
	c2._apply_remote_input("resume_effect", relay_uc)
	# 逐帧读骇客端 hand_panel 状态标签，定位"数值延迟显示"在第几帧
	var ui_frames: Array = []
	for f in range(1, 9):
		await _pump(1)
		var hp = h.hand_panel
		if hp == null:
			ui_frames.append("f%d:no-panel" % f)
			continue
		var atk_txt: String = hp._stat_attack_label.text if hp._stat_attack_label != null else "?"
		var act_txt: String = hp._stat_action_label.text if hp._stat_action_label != null else "?"
		ui_frames.append("f%d:[%s|%s]" % [f, atk_txt, act_txt])
	diag.append("UI帧: " + " ".join(PackedStringArray(ui_frames)))
	diag.append("resume后: pending=%d/%d/%d wait=%s/%s/%s" % [_pending_count(h), _pending_count(c1), _pending_count(c2),
		String(_wait_info(h).get("input_type", &"")), String(_wait_info(c1).get("input_type", &"")), String(_wait_info(c2).get("input_type", &""))])
	# ④ 断言三端一致：pending 清零 / 位置一致 / 加成一致
	var errs: Array = []
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs.append("pending残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	var pos_c1: String = _mech_pos(c1, &"player")
	var pos_c2: String = _mech_pos(c2, &"player")
	if not (pos_h == pos_c1 and pos_c1 == pos_c2):
		errs.append("位置不同步 h=%s c1=%s c2=%s" % [pos_h, pos_c1, pos_c2])
	var ab_h: int = _attack_bonus(h, &"player")
	var ab_c1: int = _attack_bonus(c1, &"player")
	var ab_c2: int = _attack_bonus(c2, &"player")
	var hl_h: int = _hand_limit(h, &"player")
	var hl_c1: int = _hand_limit(c1, &"player")
	var hl_c2: int = _hand_limit(c2, &"player")
	if not (ab_h == ab_c1 and ab_c1 == ab_c2):
		errs.append("攻击加成不同步 h=%d c1=%d c2=%d" % [ab_h, ab_c1, ab_c2])
	if not (hl_h == hl_c1 and hl_c1 == hl_c2):
		errs.append("行动牌上限加成不同步 h=%d c1=%d c2=%d" % [hl_h, hl_c1, hl_c2])
	diag.append("加成: 攻[%d/%d/%d] 上限[%d/%d/%d]" % [ab_h, ab_c1, ab_c2, hl_h, hl_c1, hl_c2])
	# 期望攻击+1（初始max_attacks=1 -> 2） 上限+1（初始action_card_limit=4 -> 5），enemy 持攻击+迎击
	if ab_h != 2:
		errs.append("攻击期望2 实际%d" % ab_h)
	if hl_h != 5:
		errs.append("行动牌上限期望5 实际%d" % hl_h)
	var wt_h: StringName = _wait_info(h).get("input_type", &"")
	var wt_c1: StringName = _wait_info(c1).get("input_type", &"")
	var wt_c2: StringName = _wait_info(c2).get("input_type", &"")
	if not (wt_h == &"" and wt_c1 == &"" and wt_c2 == &""):
		errs.append("wait残留 h=%s c1=%s c2=%s" % [String(wt_h), String(wt_c1), String(wt_c2)])
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	# ⑤ 修复后仍可继续锁步：player 再移动一格，三端应一致同步（用户反馈"不更新位置和响应"）
	var pm2 = h.battle.context.game_state.get_mech_for_player(&"player")
	var cell2: Dictionary = {}
	for n: Dictionary in _HexGrid.neighbors(pm2.position):
		var cid2: String = "%d,%d" % [int(n.q), int(n.r)]
		if not h.battle.context.game_state.map_state.cells.has(StringName(cid2)):
			continue
		var occupied2: bool = false
		for mid2: StringName in h.battle.context.game_state.mechs:
			var m2 = h.battle.context.game_state.mechs[mid2]
			if m2 != null and not m2.destroyed and int(m2.position.get("q", 0)) == int(n.q) and int(m2.position.get("r", 0)) == int(n.r):
				occupied2 = true
				break
		if not occupied2:
			cell2 = {"q": int(n.q), "r": int(n.r)}
			break
	if not cell2.is_empty():
		await _exec3(h, c1, c2, "move", {"player_id": "player", "q": cell2.q, "r": cell2.r})
		var pos2_h: String = _mech_pos(h, &"player")
		if not (pos2_h == _mech_pos(c1, &"player") and pos2_h == _mech_pos(c2, &"player")):
			errs.append("后续移动不同步 h=%s c1=%s c2=%s" % [pos2_h, _mech_pos(c1, &"player"), _mech_pos(c2, &"player")])
		# 第二次窥牌（2次额度用第1次后仍剩1次）应正常挂起 -> 取消不计数 -> 继续
		if not (_pending_count(h) == 1 and _pending_count(c1) == 1 and _pending_count(c2) == 1):
			errs.append("第二次窥牌挂起不同步 pending=%d/%d/%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
		else:
			var aid2: StringName = StringName(_wait_info(h).get("action_id", &""))
			var relay_cancel: Dictionary = {"action_id": String(aid2), "data": {"cancelled": true}}
			c1._apply_remote_input("resume_effect", relay_cancel)
			c2._apply_remote_input("resume_effect", relay_cancel)
			h._net_exec("resume_effect", relay_cancel)
			await _pump(10)
			if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
				errs.append("取消后 pending 残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	print("DIAG: " + " | ".join(PackedStringArray(diag)))
	await _free3(h, c1, c2)
	return true


func _collect_tests() -> Array:
	return [
		{"name": "p066_peek_pvp3_sync", "fn": test_p066_peek_pvp3_sync},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
