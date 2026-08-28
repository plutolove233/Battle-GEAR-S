## test_pvp3_p080_li_two_rounds.gd - 复现实机bug2：李「确认」拦截（消耗本局1次）后，
## 墨尘第二次使用标记交互 -> 李端无弹窗直接卡死（位置不更新/效果不发动，其余两端正常）。
##
## 三端对等引擎锁步（h=player 墨尘owner / c1=enemy 李owner / c2=third），全程走真实 UI
## 路径（choice_panel 确认 / _on_battle_hex_clicked 选格 / 归属端 _net_exec），逐批 op 后
## 断言三端 action id 一致（发散=resume_effect 跨端路由落空 -> 挂起死锁，实机症状）。
##
## 用例：
##   discard  = 李确认「弃置」分支 + 墨尘第二次使用；
##   transfer = 李确认「转设我方」分支 + 墨尘第二次使用（敌袭#1 在李机甲上结算）。
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
		var mech_p = gs.get_mech_for_player(&"player")
		var pdef080 = cdb.get_card(&"pilot_080_墨尘")
		if pdef080 == null:
			return "pilot_080_墨尘 定义不存在"
		var iid080: StringName = gs.next_id(&"card")
		var card080 = _CardInstance.new(iid080, pdef080)
		card080.owner_player_id = &"player"
		gs.cards[iid080] = card080
		app.battle.context.game_setup_service.set_pilot(mech_p.mech_id, card080)
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


func _inject_raid(app, n_extra: int) -> Array:
	## 注入 n_extra 张敌袭（event_002）实例到事件牌堆底（三端各自调用，next_id 须一致）
	var gs = app.battle.context.game_state
	var cdb = app.battle.context.card_database
	var def = cdb.get_card(&"event_002")
	var out: Array = []
	if def == null:
		return out
	for i in n_extra:
		var iid: StringName = gs.next_id(&"card")
		var c = _CardInstance.new(iid, def)
		gs.cards[iid] = c
		gs.deck_state.event_deck.append(iid)
		out.append(iid)
	return out


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


func _event_zone_card(app, pid: StringName = &"player") -> String:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(pid)
	var slot = mech.slots.get(&"event")
	if slot != null and slot.equipped_card != null:
		return String(slot.equipped_card.def.card_id)
	return "-"


func _snap(apps: Array, tag: String, d: Array) -> void:
	var parts: Array = []
	for app in apps:
		var wi: Dictionary = _wait_info(app)
		var pend: Dictionary = app.battle.context.timing_engine._pending_effect
		var phases: Array = []
		for pk: StringName in pend:
			phases.append("%s:%s" % [String(pk), String(pend[pk].get("phase", &"-"))])
		var pm = app.battle.context.game_state.get_mech_for_player(&"player")
		parts.append("%s wait=%s aid=%s pend=[%s] pos=(%s,%s) zone=%s" % [
			String(app.local_player_id), String(wi.get("input_type", &"")),
			String(wi.get("action_id", &"")), ", ".join(PackedStringArray(phases)),
			String(pm.position.get("q", 0)), String(pm.position.get("r", 0)), _event_zone_card(app)])
	d.append("%s: %s" % [tag, " || ".join(PackedStringArray(parts))])


## 根因回归断言：三端 ActionRegistry 的 id 发号顺序必须严格一致。
## 发散时 resume_effect/damage_placement_done 的跨端 action_id 路由会静默落空
## -> 挂起死锁（用户实机：李端位置不更新/效果不发动，其余两端正常）。
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


func _mech_pos(app, pid: StringName) -> Vector2i:
	var m = app.battle.context.game_state.get_mech_for_player(pid)
	return Vector2i(int(m.position.get("q", 0)), int(m.position.get("r", 0)))


func _adjacent_free_cell(app, from_hex: Dictionary) -> Dictionary:
	var gs = app.battle.context.game_state
	for n: Dictionary in _HexGrid.neighbors(from_hex):
		var cid: String = "%d,%d" % [int(n.q), int(n.r)]
		if not gs.map_state.cells.has(StringName(cid)):
			continue
		var occupied: bool = false
		for mid: StringName in gs.mechs:
			var m = gs.mechs[mid]
			if m != null and not m.destroyed and int(m.position.get("q", 0)) == int(n.q) and int(m.position.get("r", 0)) == int(n.r):
				occupied = true
				break
		if not occupied:
			return {"q": int(n.q), "r": int(n.r), "cell_id": cid}
	return {}


func _add_marker_all(apps: Array, marker_id: String, cell: Dictionary) -> void:
	for app in apps:
		app.battle.context.game_state.map_state.add_marker(
			StringName(marker_id), int(cell.q), int(cell.r), &"EVENT")


## 驱动一次完整的墨尘标记交互使用（equipment_active -> 选格 -> 移至 -> 窗口循环到链路
## 结束），返回 {intercept_cnt, raid_cnt, err}。intercept_mode: "discard"/"transfer"/"cancel"。
func _drive_use(h, c1, c2, cell: Dictionary, intercept_mode: String, d: Array) -> Dictionary:
	var apps: Array = [h, c1, c2]
	var intercept_cnt: int = 0
	var raid_cnt: int = 0
	# ① 墨尘按钮（三端 op）
	h._net_exec("equipment_active", {"card_instance_id": _pilot_instance_id(h, &"player"), "effect_id": &"pilot_080_effect_01"})
	await _pump(2)
	c1._apply_remote_input("equipment_active", {"card_instance_id": _pilot_instance_id(h, &"player"), "effect_id": &"pilot_080_effect_01"})
	c2._apply_remote_input("equipment_active", {"card_instance_id": _pilot_instance_id(h, &"player"), "effect_id": &"pilot_080_effect_01"})
	await _pump(3)
	var wi: Dictionary = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"select_map_cell":
		return {"intercept_cnt": 0, "raid_cnt": 0, "err": "未进入选格（wait=%s）" % String(wi.get("input_type", &""))}
	# ② 选标记格（h 真实点击 + 转发）
	var smc_aid: StringName = h._map_cell_select_action_id
	h._on_battle_hex_clicked({"q": int(cell.q), "r": int(cell.r)})
	await _pump(2)
	if smc_aid != &"":
		var smc_data: Dictionary = {"action_id": String(smc_aid), "data": {"selected_cell_id": String(cell.cell_id)}}
		c1._apply_remote_input("resume_effect", smc_data)
		c2._apply_remote_input("resume_effect", smc_data)
	await _pump(3)
	wi = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"choose_one_effect":
		return {"intercept_cnt": 0, "raid_cnt": 0, "err": "未进入二选一（wait=%s）" % String(wi.get("input_type", &""))}
	# ③ 选「移至」（h 真实确认 + 转发）
	var ec_aid: StringName = h._effect_choice_action_id
	h.choice_panel._on_option_selected(&"option_1")
	h.choice_panel._on_confirm()
	await _pump(2)
	var relay: Dictionary = {"action_id": String(ec_aid), "data": {"chosen_effect_id": &"option_1", "confirmed": true, "chosen_option_index": 1}}
	c1._apply_remote_input("resume_effect", relay)
	c2._apply_remote_input("resume_effect", relay)
	await _pump(6)
	var id_err: String = _assert_id_consistency(h, c1, c2)
	if id_err != "":
		_snap(apps, "移至后", d)
		return {"intercept_cnt": 0, "raid_cnt": 0, "err": "移至后 " + id_err}
	# ④ 循环驱动：李拦截窗 / 敌袭选择窗 / 损伤放置，直到全链完成或卡死
	var guard: int = 0
	while guard < 150:
		guard += 1
		id_err = _assert_id_consistency(h, c1, c2)
		if id_err != "":
			_snap(apps, "iter%d发散" % guard, d)
			return {"intercept_cnt": intercept_cnt, "raid_cnt": raid_cnt, "err": "iter%d %s" % [guard, id_err]}
		var progressed: bool = false
		# ① choose_one_effect 窗（归属端真实 UI 路径；c1 优先=李拦截窗先于敌袭窗）
		for app in [c1, h, c2]:
			var awi: Dictionary = _wait_info(app)
			var awt: StringName = awi.get("input_type", &"")
			var a_aid: StringName = awi.get("action_id", &"")
			if awt != &"choose_one_effect" or a_aid == &"":
				continue
			var pend: Dictionary = app.battle.context.timing_engine._pending_effect
			var phase: String = String(pend.get(a_aid, {}).get("phase", &""))
			var owner_aid: StringName = app._effect_choice_action_id
			var opt: StringName = &"option_1"
			var opt_idx: int = 1
			if phase == &"pilot_053_intercept":
				intercept_cnt += 1
				if intercept_mode == &"cancel":
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
				if intercept_mode == &"discard":
					opt = &"option_0"
					opt_idx = 0
				else:
					opt = &"option_1"
					opt_idx = 1
			elif phase == &"pre_actions_target":
				raid_cnt += 1
			elif phase == &"pilot_080_choice":
				pass  # 已在 ③ 手动驱动；循环内出现视为异常，走同一确认路径兜底
			else:
				d.append("未知挂起phase=%s aid=%s" % [phase, String(a_aid)])
				return {"intercept_cnt": intercept_cnt, "raid_cnt": raid_cnt, "err": "未知挂起phase=%s" % phase}
			# 真实确认路径：选项 + 确认 -> _net_exec（本端defer）+ 手工转发其余两端
			app.choice_panel._on_option_selected(opt)
			app.choice_panel._on_confirm()
			await _pump(2)
			var confirm_data: Dictionary = {"action_id": String(owner_aid), "data": {"chosen_effect_id": StringName(opt), "confirmed": true, "chosen_option_index": opt_idx}}
			for other in [h, c1, c2]:
				if other == app:
					continue
				other._apply_remote_input("resume_effect", confirm_data)
			await _pump(4)
			progressed = true
			break
		if progressed:
			continue
		# ② 损伤放置：按 record.executor 找归属端，真实 _net_exec(damage_place/done)
		var dmg_done: bool = false
		for app in apps:
			var reg = app.battle.context.action_registry
			for a in reg.get_actions_by_type(&"damage_change"):
				if a.state != &"waiting_input":
					continue
				var amount: int = int(a.record.get("value", 0))
				var mech_ids: Array = a.record.get("mech_ids", [])
				var dmg_aid: StringName = a.action_id
				var dmg_mid: StringName = mech_ids[0] if mech_ids.size() > 0 else &""
				var exec_pid: StringName = StringName(String(a.record.get("executor", &"player")))
				var owner_app = h
				for cand in apps:
					if String(cand.local_player_id) == String(exec_pid):
						owner_app = cand
				var owner_gs = owner_app.battle.context.game_state
				var slots_order: Array = []
				var dm = owner_gs.mechs.get(dmg_mid)
				if dm != null:
					for sid: StringName in dm.slots:
						slots_order.append(sid)
				var tokens_left: int = amount
				var si: int = 0
				while tokens_left > 0 and si < slots_order.size():
					var place_op: Dictionary = {"slot_id": String(slots_order[si]), "target_mech_id": String(dmg_mid)}
					owner_app._net_exec("damage_place", place_op)
					for other in apps:
						if other == owner_app:
							continue
						other._apply_remote_input("damage_place", place_op)
					tokens_left -= 1
					si += 1
				await _pump(2)
				var done_op: Dictionary = {"action_id": String(dmg_aid)}
				owner_app._net_exec("damage_placement_done", done_op)
				for other in apps:
					if other == owner_app:
						continue
					other._apply_remote_input("damage_placement_done", done_op)
				dmg_done = true
				break
			if dmg_done:
				break
		if dmg_done:
			await _pump(4)
			continue
		# ③ 无挂起无输入：是否全链结束
		var all_done: bool = true
		for app in apps:
			var live: int = 0
			for aid2: StringName in app.battle.context.action_registry.active_actions:
				var a2 = app.battle.context.action_registry.active_actions[aid2]
				if a2.state != &"completed" and a2.state != &"cancelled":
					live += 1
			if live > 0:
				all_done = false
		if all_done:
			break
		await _pump(2)
	return {"intercept_cnt": intercept_cnt, "raid_cnt": raid_cnt, "err": ""}


func _free3(h, c1, c2) -> void:
	for app in [h, c1, c2]:
		if app != null:
			app.queue_free()
	await _pump(3)


## 主复现：李确认（弃置/转设）拦截 -> 墨尘第二次使用 -> 李端必须保持锁步。
func _run_two_rounds(intercept_mode: String) -> Variant:
	var h = await _build(77411, &"player")
	var c1 = await _build(77411, &"enemy")
	var c2 = await _build(77411, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_pilots_3(h, c1, c2)
	if err != "":
		return err
	var apps: Array = [h, c1, c2]
	var d: Array = []
	# 注入2张额外敌袭 + 堆顶4张（三端一致）
	for app in apps:
		_inject_raid(app, 2)
	var stacks: Array = []
	for app in apps:
		var got: Array = _stack_raid_top(app, 4)
		if got.size() < 4:
			await _free3(h, c1, c2)
			return "敌袭实例不足4"
		stacks.append(got)
	if str(stacks[0]) != str(stacks[1]) or str(stacks[0]) != str(stacks[2]):
		await _free3(h, c1, c2)
		return "三端敌袭堆顶不一致: %s / %s / %s" % [str(stacks[0]), str(stacks[1]), str(stacks[2])]
	var deck_before: int = h.battle.context.game_state.deck_state.event_deck.size()

	# ── 第1次使用 ──
	var p_start: Vector2i = _mech_pos(h, &"player")
	var cell1: Dictionary = _adjacent_free_cell(h, {"q": p_start.x, "r": p_start.y})
	if cell1.is_empty():
		await _free3(h, c1, c2)
		return "无相邻空格"
	_add_marker_all(apps, "m_r1_%d_%d" % [int(cell1.q), int(cell1.r)], cell1)
	var r1: Dictionary = await _drive_use(h, c1, c2, cell1, intercept_mode, d)
	if String(r1.get("err", "")) != "":
		await _free3(h, c1, c2)
		return "第1次使用失败: %s | %s" % [String(r1.get("err", "")), " || ".join(PackedStringArray(d))]

	# ── 第2次使用（实机bug2现场：李本局1次已耗，李端无任何弹窗） ──
	var pos1: Vector2i = _mech_pos(h, &"player")
	if pos1 != Vector2i(int(cell1.q), int(cell1.r)):
		await _free3(h, c1, c2)
		return "第1次移动未到位: h=(%d,%d) 期望(%d,%d)" % [pos1.x, pos1.y, int(cell1.q), int(cell1.r)]
	var cell2: Dictionary = _adjacent_free_cell(h, {"q": pos1.x, "r": pos1.y})
	if cell2.is_empty():
		await _free3(h, c1, c2)
		return "第2次无相邻空格"
	_add_marker_all(apps, "m_r2_%d_%d" % [int(cell2.q), int(cell2.r)], cell2)
	var r2: Dictionary = await _drive_use(h, c1, c2, cell2, "cancel", d)
	if String(r2.get("err", "")) != "":
		await _free3(h, c1, c2)
		return "第2次使用失败(实机bug2): %s | %s" % [String(r2.get("err", "")), " || ".join(PackedStringArray(d))]

	# ── 断言 ──
	var errs: Array = []
	# 位置三端同步（实机症状=李端位置不更新）
	var pos2_h: Vector2i = _mech_pos(h, &"player")
	var pos2_c1: Vector2i = _mech_pos(c1, &"player")
	var pos2_c2: Vector2i = _mech_pos(c2, &"player")
	if pos2_h != Vector2i(int(cell2.q), int(cell2.r)):
		errs.append("h端第2次移动未到位: (%d,%d) 期望(%d,%d)" % [pos2_h.x, pos2_h.y, int(cell2.q), int(cell2.r)])
	if pos2_c1 != pos2_h:
		errs.append("李端位置不同步(实机bug2): c1=(%d,%d) h=(%d,%d)" % [pos2_c1.x, pos2_c1.y, pos2_h.x, pos2_h.y])
	if pos2_c2 != pos2_h:
		errs.append("third端位置不同步: c2=(%d,%d) h=(%d,%d)" % [pos2_c2.x, pos2_c2.y, pos2_h.x, pos2_h.y])
	# 拦截窗：第1次1个（确认分支），第2次0个（本局1次已耗）
	if int(r1.get("intercept_cnt", -1)) != 1:
		errs.append("第1次李拦截窗应1 实=%d" % int(r1.get("intercept_cnt", -1)))
	if int(r2.get("intercept_cnt", -1)) != 0:
		errs.append("第2次李拦截窗应0 实=%d" % int(r2.get("intercept_cnt", -1)))
	# 敌袭窗：discard=1+2=3；transfer=2+2=4（敌袭#1 在李机甲结算）
	var raid_expect: int = 3 if intercept_mode == &"discard" else 4
	if int(r1.get("raid_cnt", -1)) + int(r2.get("raid_cnt", -1)) != raid_expect:
		errs.append("敌袭窗应%d 实=%d+%d" % [raid_expect, int(r1.get("raid_cnt", -1)), int(r2.get("raid_cnt", -1))])
	# 牌堆消耗4张、无事件区残留、无动作残留、无 pending
	for app in apps:
		var gs = app.battle.context.game_state
		if gs.deck_state.event_deck.size() != deck_before - 4:
			errs.append("%s端 事件牌堆应-4 实=%d->%d" % [String(app.local_player_id), deck_before, gs.deck_state.event_deck.size()])
		if _event_zone_card(app) != "-":
			errs.append("%s端 事件区残留=%s" % [String(app.local_player_id), _event_zone_card(app)])
		var live: int = 0
		for aid: StringName in app.battle.context.action_registry.active_actions:
			var a = app.battle.context.action_registry.active_actions[aid]
			if a.state != &"completed" and a.state != &"cancelled":
				live += 1
		if live > 0:
			errs.append("%s端 动作残留=%d" % [String(app.local_player_id), live])
		var pend_cnt: int = app.battle.context.timing_engine._pending_effect.size()
		if pend_cnt > 0:
			errs.append("%s端 pending残留=%d" % [String(app.local_player_id), pend_cnt])
	var id_err: String = _assert_id_consistency(h, c1, c2)
	if id_err != "":
		errs.append(id_err)
	if errs.size() > 0:
		errs.append_array(d)
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(errs))
	await _free3(h, c1, c2)
	return true


func test_pvp3_li_confirm_discard_second_use() -> Variant:
	return await _run_two_rounds(&"discard")


func test_pvp3_li_confirm_transfer_second_use() -> Variant:
	return await _run_two_rounds(&"transfer")


func _collect_tests() -> Array:
	return [
		{"name": "pvp3_li_confirm_discard_second_use", "fn": test_pvp3_li_confirm_discard_second_use},
		{"name": "pvp3_li_confirm_transfer_second_use", "fn": test_pvp3_li_confirm_transfer_second_use},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
