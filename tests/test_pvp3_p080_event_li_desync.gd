## test_pvp3_p080_event_li_desync.gd - 诊断：PvP3 墨尘移至EVENT标记 + 李拦截 + 敌袭instant
##
## 三端对等引擎（h=player 墨尘owner / c1=enemy 李owner / c2=third）。
## 复现用户报告：事件标记两次生效中，李的拦截窗只截到第2张、敌袭instant
## 留在事件区、instant效果不触发。逐步观察三端 action_id / 挂起 / 弹窗归属。
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


func _setup_pilots_3(h, c1, c2) -> String:
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var cdb = app.battle.context.card_database
		# 墨尘 -> player 方
		var mech_p = gs.get_mech_for_player(&"player")
		var pdef080 = cdb.get_card(&"pilot_080_墨尘")
		if pdef080 == null:
			return "pilot_080_墨尘 定义不存在"
		var iid080: StringName = gs.next_id(&"card")
		var card080 = _CardInstance.new(iid080, pdef080)
		card080.owner_player_id = &"player"
		gs.cards[iid080] = card080
		app.battle.context.game_setup_service.set_pilot(mech_p.mech_id, card080)
		# 李 -> enemy 方
		var mech_e = gs.get_mech_for_player(&"enemy")
		var pdef051 = cdb.get_card(&"pilot_053_李")
		if pdef051 == null:
			return "pilot_053_李 定义不存在"
		var iid051: StringName = gs.next_id(&"card")
		var card051 = _CardInstance.new(iid051, pdef051)
		card051.owner_player_id = &"enemy"
		gs.cards[iid051] = card051
		app.battle.context.game_setup_service.set_pilot(mech_e.mech_id, card051)
	await _pump(2)
	return ""


func _pilot_instance_id(app, pid: StringName) -> StringName:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(pid)
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


func _stack_raid_top(app, count: int) -> Array:
	## 把 count 张敌袭（event_002）挪到事件牌堆顶，返回实例id列表（三端各自调用，顺序一致）
	var gs = app.battle.context.game_state
	var found: Array = []
	for cid: StringName in gs.deck_state.event_deck:
		var card = gs.cards.get(cid)
		if card != null and card.def != null and card.def.card_id == &"event_002":
			found.append(cid)
			if found.size() >= count:
				break
	if found.size() < count:
		return []
	for cid in found:
		gs.deck_state.event_deck.erase(cid)
	for i in range(found.size() - 1, -1, -1):
		gs.deck_state.event_deck.insert(0, found[i])
	return found


func _event_zone_card(app) -> String:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var slot = mech.slots.get(&"event")
	if slot != null and slot.equipped_card != null:
		return String(slot.equipped_card.def.card_id)
	return "-"


func _exec3(h, c1, c2, op: String, data: Dictionary, frames: int = 3) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c1._apply_remote_input(op, data)
	c2._apply_remote_input(op, data)
	await _pump(frames)


func _relay_from(src, others: Array, op: String, data: Dictionary, frames: int = 3) -> void:
	## src 端广播 op 后由它自己 _net_exec；others 收到 _apply_remote_input
	for app in others:
		app._apply_remote_input(op, data)
	await _pump(frames)


func _snap(apps: Array, tag: String, d: Array) -> void:
	var parts: Array = []
	for app in apps:
		var wi: Dictionary = _wait_info(app)
		var pend: Dictionary = app.battle.context.timing_engine._pending_effect
		var phases: Array = []
		for pk: StringName in pend:
			phases.append("%s:%s" % [String(pk), String(pend[pk].get("phase", &"-"))])
		parts.append("%s wait=%s aid=%s pend=[%s] zone=%s" % [
			String(app.local_player_id), String(wi.get("input_type", &"")),
			String(wi.get("action_id", &"")), ", ".join(PackedStringArray(phases)), _event_zone_card(app)])
	d.append("%s: %s" % [tag, " || ".join(PackedStringArray(parts))])


## 主诊断：三端驱动全链，观察 set_event_card 的 action_id 三端是否一致
func test_p080_event_li_3ends() -> Variant:
	var h = await _build(77301, &"player")
	var c1 = await _build(77301, &"enemy")
	var c2 = await _build(77301, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_pilots_3(h, c1, c2)
	if err != "":
		return err
	var d: Array = []
	# 敌袭×2 堆顶（三端各自同步操作）
	for app in [h, c1, c2]:
		var got: Array = _stack_raid_top(app, 2)
		if got.size() < 2:
			return "敌袭实例不足"
	# EVENT 标记放 player 机甲相邻空格（三端同步）
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
	for app in [h, c1, c2]:
		app.battle.context.game_state.map_state.add_marker(
			StringName("m_diag_%d_%d" % [cell.q, cell.r]), cell.q, cell.r, &"EVENT")
	var deck_before: int = h.battle.context.game_state.deck_state.event_deck.size()

	# ① 墨尘按钮（三端广播）
	var pid_card: StringName = _pilot_instance_id(h, &"player")
	await _exec3(h, c1, c2, "equipment_active", {"card_instance_id": pid_card, "effect_id": &"pilot_080_effect_01"}, 2)
	var wi: Dictionary = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"select_map_cell":
		await _free3(h, c1, c2)
		return "未进入选格（wait=%s）" % String(wi.get("input_type", &""))
	# ② 选标记格（h 本地点击 + 转发）
	var smc_aid: StringName = h._map_cell_select_action_id
	h._on_battle_hex_clicked({"q": cell.q, "r": cell.r})
	await _pump(2)
	if smc_aid != &"":
		c1._apply_remote_input("resume_effect", {"action_id": String(smc_aid), "data": {"selected_cell_id": "%d,%d" % [cell.q, cell.r]}})
		c2._apply_remote_input("resume_effect", {"action_id": String(smc_aid), "data": {"selected_cell_id": "%d,%d" % [cell.q, cell.r]}})
	await _pump(3)
	wi = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"choose_one_effect":
		await _free3(h, c1, c2)
		return "未进入二选一（wait=%s）" % String(wi.get("input_type", &""))
	# ③ 选「移至」
	var ec_aid: StringName = h._effect_choice_action_id
	h.choice_panel._on_option_selected(&"option_1")
	h.choice_panel._on_confirm()
	await _pump(2)
	var relay: Dictionary = {"action_id": String(ec_aid), "data": {"chosen_effect_id": &"option_1", "confirmed": true, "chosen_option_index": 1}}
	c1._apply_remote_input("resume_effect", relay)
	c2._apply_remote_input("resume_effect", relay)
	await _pump(6)
	# id 一致性断言（根因回归）：三端动作注册顺序必须严格一致（counter 发散=
	# resume_effect 跨端路由落空 -> 挂起死锁，用户实机症状）
	var id_err: String = _assert_id_consistency(h, c1, c2)
	if id_err != "":
		await _free3(h, c1, c2)
		return "移至后 " + id_err

	# ④ 循环驱动两轮：李拦截(cancel) -> 敌袭选择(设2损伤) -> 损伤放置(auto)
	var intercept_cnt: int = 0
	var raid_cnt: int = 0
	var guard: int = 0
	while guard < 60:
		guard += 1
		var progressed: bool = false
		# 找一个挂起端：优先 c1（李弹窗归属 enemy），再 h（敌袭弹窗归属 player）
		for app in [c1, h, c2]:
			var awi: Dictionary = _wait_info(app)
			var pend: Dictionary = app.battle.context.timing_engine._pending_effect
			var awt: StringName = awi.get("input_type", &"")
			var a_aid: StringName = awi.get("action_id", &"")
			if awt == &"choose_one_effect" and a_aid != &"":
				var phase: String = ""
				if pend.has(a_aid):
					phase = String(pend[a_aid].get("phase", &""))
				if phase == "pilot_053_intercept":
					intercept_cnt += 1
					# 归属端真实取消路径：_on_choice_cancelled -> _net_exec(resume_effect cancelled)
					var owner_aid: StringName = app._effect_choice_action_id
					app._on_choice_cancelled()
					await _pump(2)
					var cancel_data: Dictionary = {"action_id": String(owner_aid), "data": {"cancelled": true}}
					for other in [h, c1, c2]:
						if other == app:
							continue
						other._apply_remote_input("resume_effect", cancel_data)
					await _pump(4)
					progressed = true
					break
				if phase == "pre_actions_target":
					raid_cnt += 1
					var raid_aid: StringName = app._effect_choice_action_id
					app.choice_panel._on_option_selected(&"option_1")
					app.choice_panel._on_confirm()
					await _pump(2)
					var raid_data: Dictionary = {"action_id": String(raid_aid), "data": {"chosen_option_index": 1, "confirmed": true}}
					for other in [h, c1, c2]:
						if other == app:
							continue
						other._apply_remote_input("resume_effect", raid_data)
					await _pump(4)
					progressed = true
					break
		if progressed:
			continue
		# 损伤放置：h 端弹损伤放置面板（executor=player），逐 token damage_place 广播，
		# 完成后 damage_placement_done 按 action_id 精确恢复（真实锁步路径）
		var dmg_done: bool = false
		for app in [h, c1, c2]:
			var reg = app.battle.context.action_registry
			for a in reg.get_actions_by_type(&"damage_change"):
				if a.state == &"waiting_input":
					var amount: int = int(a.record.get("value", 0))
					var mech_ids: Array = a.record.get("mech_ids", [])
					var dmg_aid: StringName = a.action_id
					var dmg_mid: StringName = mech_ids[0] if mech_ids.size() > 0 else &""
					# h 端面板逐 token 放置（简化选槽：按槽序找第一个部件槽），每步三端广播
					var gs_h = h.battle.context.game_state
					var slots_order: Array = []
					var dm = gs_h.mechs.get(dmg_mid)
					for sid: StringName in dm.slots:
						slots_order.append(sid)
					var tokens_left: int = amount
					var si: int = 0
					while tokens_left > 0 and si < slots_order.size():
						var place_op: Dictionary = {"slot_id": String(slots_order[si]), "target_mech_id": String(dmg_mid)}
						h._net_exec("damage_place", place_op)
						c1._apply_remote_input("damage_place", place_op)
						c2._apply_remote_input("damage_place", place_op)
						tokens_left -= 1
						si += 1
					await _pump(2)
					# 完成恢复：按记录的 damage_change action_id 三端广播
					var done_op: Dictionary = {"action_id": String(dmg_aid)}
					h._net_exec("damage_placement_done", done_op)
					c1._apply_remote_input("damage_placement_done", done_op)
					c2._apply_remote_input("damage_placement_done", done_op)
					dmg_done = true
					break
			if dmg_done:
				break
		if dmg_done:
			await _pump(4)
			continue
		# 无挂起无输入：检查是否全部结束
		var all_done: bool = true
		for app in [h, c1, c2]:
			for at in [&"effect_fire", &"set_event_card"]:
				for a in app.battle.context.action_registry.get_actions_by_type(at):
					if a.state != &"completed" and a.state != &"cancelled":
						all_done = false
		if all_done:
			break
		await _pump(2)

	var errs: Array = []
	if intercept_cnt != 2:
		errs.append("李拦截窗应2次 实=%d" % intercept_cnt)
	if raid_cnt != 2:
		errs.append("敌袭窗应2次 实=%d" % raid_cnt)
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		if gs.deck_state.event_deck.size() != deck_before - 2:
			errs.append("%s端 事件牌堆应-2 实=%d->%d" % [String(app.local_player_id), deck_before, gs.deck_state.event_deck.size()])
		if _event_zone_card(app) != "-":
			errs.append("%s端 事件区残留=%s" % [String(app.local_player_id), _event_zone_card(app)])
		var live: int = 0
		for at in [&"effect_fire", &"set_event_card"]:
			for a in app.battle.context.action_registry.get_actions_by_type(at):
				if a.state != &"completed" and a.state != &"cancelled":
					live += 1
		if live > 0:
			errs.append("%s端 动作残留=%d" % [String(app.local_player_id), live])
	if errs.size() > 0:
		errs.append_array(d)
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(errs))
	await _free3(h, c1, c2)
	return true


## 根因回归断言：三端 ActionRegistry 的 id 发号顺序必须严格一致。
## 发散时 resume_effect/damage_placement_done 的跨端 action_id 路由会静默落空
## -> 挂起死锁（用户实机：敌袭留事件区/李拦截窗漏弹）。比较方式：各端遍历
## active_actions 按「创建序」取 (id, type) 列表——active_actions 为插入序字典，
## 只要发号顺序一致，列表逐项相等（id 含计数器序号）。
func _assert_id_consistency(h, c1, c2) -> String:
	var lists: Array = []
	for app in [h, c1, c2]:
		var reg = app.battle.context.action_registry
		var items: Array = []
		for aid: StringName in reg.active_actions:
			var a = reg.active_actions[aid]
			items.append("%s:%s" % [String(aid), String(a.action_type)])
		lists.append(items)
	var base: Array = lists[0]
	for i in range(1, lists.size()):
		if lists[i] != base:
			return "action注册序列发散: h=%s c1=%s c2=%s" % [str(base), str(lists[1]), str(lists[2])]
	return ""


func _free3(h, c1, c2) -> void:
	for app in [h, c1, c2]:
		if app != null:
			app.queue_free()
	await _pump(3)


func _collect_tests() -> Array:
	return [
		{"name": "p080_event_li_3ends", "fn": test_p080_event_li_3ends},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
