## test_pvp3_p080_move_desync.gd - 诊断：PvP3 墨尘e1「移至」分支三方不同步卡死
##
## 三端对等引擎（host=player 墨尘owner / c1=enemy / c2=third）。
## 流程：墨尘按钮 -> 选相邻标记格（ui_confirmed selected_cell_id）-> 二选一弹窗
## 选「移至」（option_1）-> 免费移动 + 标记再生效2次（GOLD=D6掷骰×2 / EVENT=设置×2 /
## TRAP=爆炸×2）。逐步检查三端挂起/状态一致性，定位卡死环节。
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


func _setup_mochen_3(h, c1, c2) -> String:
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var mech = gs.get_mech_for_player(&"player")
		if mech == null:
			return "player 机甲不存在"
		var cdb = app.battle.context.card_database
		var pdef = cdb.get_card(&"pilot_080_墨尘")
		if pdef == null:
			return "pilot_080_墨尘 定义不存在"
		var inst_id: StringName = gs.next_id(&"card")
		var card = _CardInstance.new(inst_id, pdef)
		card.owner_player_id = &"player"
		gs.cards[inst_id] = card
		app.battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	await _pump(2)
	return ""


func _pilot_instance_id(app) -> StringName:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return &""
	var slot = mech.slots.get(&"pilot")
	if slot != null and slot.equipped_card != null:
		return slot.equipped_card.instance_id
	return &""


func _wait_info(app) -> Dictionary:
	if app.battle == null or app.battle.context == null or app.battle.context.action_ui_bridge == null:
		return {}
	return app.battle.context.action_ui_bridge.get_waiting_action_info()


func _pending_count(app) -> int:
	return app.battle.context.timing_engine._pending_effect.size()


func _mech_pos(app, pid: StringName) -> String:
	var mech = app.battle.context.game_state.get_mech_for_player(pid)
	if mech == null:
		return "?"
	return "%d,%d" % [int(mech.position.get("q", -99)), int(mech.position.get("r", -99))]


func _gold(app, pid: StringName) -> int:
	var p = app.battle.context.game_state.players.get(pid)
	return int(p.gold) if p != null else -1


func _exec3(h, c1, c2, op: String, data: Dictionary, frames: int = 3) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c1._apply_remote_input(op, data)
	c2._apply_remote_input(op, data)
	await _pump(frames)


## 三端在某格放标记（直接操作 map_state，保持三端同步）
func _place_marker_3(h, c1, c2, q: int, r: int, mtype: String) -> void:
	for app in [h, c1, c2]:
		app.battle.context.game_state.map_state.add_marker(
			StringName("m_test_%d_%d" % [q, r]), q, r, StringName(mtype))


## 驱动到「移至」确认完成：marker_type 场景全链（选格->二选一->resume->再生效链跑完）
func _drive_move_branch(h, c1, c2, marker_q: int, marker_r: int, diag: Array) -> String:
	var pid_card: StringName = _pilot_instance_id(h)
	# ① 点墨尘按钮
	await _exec3(h, c1, c2, "equipment_active", {"card_instance_id": pid_card, "effect_id": &"pilot_080_effect_01"}, 2)
	var wi: Dictionary = _wait_info(h)
	diag.append("按钮后: wait=%s aid=%s pending=%d/%d/%d wait(c1/c2)=%s/%s" % [
		String(wi.get("input_type", &"")), String(wi.get("action_id", &"")),
		_pending_count(h), _pending_count(c1), _pending_count(c2),
		String(_wait_info(c1).get("input_type", &"")), String(_wait_info(c2).get("input_type", &""))])
	# c1 端日志尾部：e1 在 c1 端走到哪
	var c1_blogs: Array = c1.battle.log
	for e in c1_blogs.slice(maxi(0, c1_blogs.size() - 6), c1_blogs.size()):
		diag.append("c1blog: %s" % String(e.get("message", "")))
	# 三端 registry 存活动作 id 清单（对齐计数器）
	var reg_ids := func(app) -> String:
		var ids: Array = []
		if app.battle.context.action_registry != null:
			for k: StringName in app.battle.context.action_registry.active_actions:
				ids.append("%s:%s" % [String(k), String(app.battle.context.action_registry.active_actions[k].state)])
		return ",".join(PackedStringArray(ids))
	diag.append("registry: h=[%s] c1=[%s] c2=[%s]" % [reg_ids.call(h), reg_ids.call(c1), reg_ids.call(c2)])
	if String(wi.get("input_type", &"")) != &"select_map_cell":
		return "未进入选格（wait=%s）" % String(wi.get("input_type", &""))
	# ② 选标记格：走真实点击路径（_on_battle_hex_clicked -> select_map_cell 分支 ->
	#    resume_effect 按 action_id 精确路由，修复后不再走共享槽 ui_confirmed）
	var cell_id: String = "%d,%d" % [marker_q, marker_r]
	var smc_aid: StringName = h._map_cell_select_action_id
	diag.append("选格捕获 aid=%s" % String(smc_aid))
	if smc_aid == &"":
		return "选格弹窗未捕获 action_id（修复路由不生效）"
	h._on_battle_hex_clicked({"q": marker_q, "r": marker_r})
	await _pump(2)
	if smc_aid != &"":
		c1._apply_remote_input("resume_effect", {"action_id": String(smc_aid), "data": {"selected_cell_id": cell_id}})
		c2._apply_remote_input("resume_effect", {"action_id": String(smc_aid), "data": {"selected_cell_id": cell_id}})
	await _pump(3)
	wi = _wait_info(h)
	diag.append("选格后: wait=%s 弹窗=%s pending=%d/%d/%d" % [
		String(wi.get("input_type", &"")), str(h.choice_panel != null and h.choice_panel.visible),
		_pending_count(h), _pending_count(c1), _pending_count(c2)])
	if String(wi.get("input_type", &"")) != &"choose_one_effect":
		return "未进入二选一（wait=%s）" % String(wi.get("input_type", &""))
	# ③ 选「移至」（option_1）
	var aid: StringName = wi.get("action_id", &"")
	var ec_aid: StringName = h._effect_choice_action_id
	diag.append("二选一: wait_aid=%s 捕获aid=%s" % [String(aid), String(ec_aid)])
	h.choice_panel._on_option_selected(&"option_1")
	h.choice_panel._on_confirm()
	await _pump(2)
	var relay: Dictionary = {"action_id": String(ec_aid), "data": {"chosen_effect_id": &"option_1", "confirmed": true, "chosen_option_index": 1}}
	c1._apply_remote_input("resume_effect", relay)
	c2._apply_remote_input("resume_effect", relay)
	await _pump(10)
	diag.append("resume后: registry h=[%s] c1=[%s] c2=[%s]" % [reg_ids.call(h), reg_ids.call(c1), reg_ids.call(c2)])
	# c1 挂起详情：pending_effect 的 phase
	var c1_pe: Dictionary = c1.battle.context.timing_engine._pending_effect
	for pk: StringName in c1_pe:
		var c1_pend: Dictionary = c1_pe[pk]
		diag.append("c1 pending[%s] phase=%s cell=%s" % [String(pk), String(c1_pend.get("phase", &"")), String(c1_pend.get("pilot_080_cell", "-"))])
		var c1_act2 = c1.battle.context.action_registry.get_action(pk)
		if c1_act2 != null:
			var c1_rec: Dictionary = c1_act2.record
			diag.append("c1 act state=%s seq_remaining=%s step=%s phase=%s" % [
				String(c1_act2.state), str(c1_rec.get("_seq_effect_actions", {}).get("remaining", []).size() if c1_rec.has("_seq_effect_actions") else -1),
				str(c1_act2.current_step_index), String(c1_act2.current_step_phase)])
	# ── 三方一致性断言（回归）：pos / gold / pending / wait 全同步 ──
	var errs: Array = []
	var pos_h: String = _mech_pos(h, &"player")
	var pos_c1: String = _mech_pos(c1, &"player")
	var pos_c2: String = _mech_pos(c2, &"player")
	var gold_h: int = _gold(h, &"player")
	var gold_c1: int = _gold(c1, &"player")
	var gold_c2: int = _gold(c2, &"player")
	if not (pos_h == pos_c1 and pos_c1 == pos_c2):
		errs.append("pos不同步 h=%s c1=%s c2=%s" % [pos_h, pos_c1, pos_c2])
	if not (gold_h == gold_c1 and gold_c1 == gold_c2):
		errs.append("gold不同步 h=%d c1=%d c2=%d" % [gold_h, gold_c1, gold_c2])
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs.append("pending残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	var wt_h: StringName = _wait_info(h).get("input_type", &"")
	var wt_c1: StringName = _wait_info(c1).get("input_type", &"")
	var wt_c2: StringName = _wait_info(c2).get("input_type", &"")
	if not (wt_h == &"" and wt_c1 == &"" and wt_c2 == &""):
		errs.append("wait残留 h=%s c1=%s c2=%s" % [String(wt_h), String(wt_c1), String(wt_c2)])
	if pos_h != "%d,%d" % [marker_q, marker_r]:
		errs.append("移至后机甲不在标记格 pos=%s（期望%d,%d）" % [pos_h, marker_q, marker_r])
	if errs.size() > 0:
		return " | ".join(PackedStringArray(errs))
	return ""


## GOLD 标记场景：移至 -> 免费移动 + 2次 D6 掷骰
func test_p080_move_gold_3ends() -> Variant:
	var h = await _build(77201, &"player")
	var c1 = await _build(77201, &"enemy")
	var c2 = await _build(77201, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_mochen_3(h, c1, c2)
	if err != "":
		return err
	var diag: Array = []
	# 找 player 机甲的一个真实相邻空格
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
	_place_marker_3(h, c1, c2, cell.q, cell.r, "GOLD")
	var gold_before: int = _gold(h, &"player")
	var derr: String = await _drive_move_branch(h, c1, c2, cell.q, cell.r, diag)
	if derr != "":
		diag.append(derr)
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if _gold(h, &"player") <= gold_before:
		await _free3(h, c1, c2)
		return "GOLD标记再生效未触发: gold=%d（前=%d）" % [_gold(h, &"player"), gold_before]
	await _free3(h, c1, c2)
	return true


func _free3(h, c1, c2) -> void:
	for app in [h, c1, c2]:
		if app != null:
			app.queue_free()
	await _pump(3)


func _collect_tests() -> Array:
	return [
		{"name": "p080_move_gold_3ends", "fn": test_p080_move_gold_3ends},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
