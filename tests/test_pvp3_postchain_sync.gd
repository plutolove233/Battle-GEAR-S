## test_pvp3_postchain_sync.gd - 诊断：p080+李链完成后，后续对局是否继续同步
##
## 复现用户实机报告：李截到两次后，李端与其他端失步（别人位置不更新/效果不发动）。
## 链完成后继续驱动：host移动 -> host结束回合 -> 李回合(移动+e1效果) -> 李结束回合 ->
## third移动。逐步断言三端 mech 位置 / active_player_id / 金币 一致。
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
		var pdef051 = cdb.get_card(&"pilot_051_李")
		if pdef051 == null:
			return "pilot_051_李 定义不存在"
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


func _mech_pos(app, pid: StringName) -> String:
	var mech = app.battle.context.game_state.get_mech_for_player(pid)
	if mech == null:
		return "?"
	return "%d,%d" % [int(mech.position.get("q", -99)), int(mech.position.get("r", -99))]


func _active_pid(app) -> String:
	return String(app.battle.context.game_state.active_player_id)


func _gold(app, pid: StringName) -> int:
	var p = app.battle.context.game_state.players.get(pid)
	return int(p.gold) if p != null else -1


## 三端广播：src 端 _net_exec，另两端 _apply_remote_input（模拟 host 星型中继）
func _relay3(src, others: Array, op: String, data: Dictionary, frames: int = 3) -> void:
	src._net_exec(op, data)
	for app in others:
		app._apply_remote_input(op, data)
	await _pump(frames)


## 弃超限牌阻塞窗应答（正常流程）：owner 端选牌 -> resume_turn_discard 三端续跑
func _answer_discard_flow(owner, others: Array, pid: StringName, d: Array) -> void:
	var td_guard: int = 0
	while td_guard < 8:
		td_guard += 1
		var td_wi: Dictionary = _wait_info(owner)
		if String(td_wi.get("input_type", &"")) != &"select_discard_cards":
			break
		var td_aid: StringName = td_wi.get("action_id", &"")
		var td_params: Dictionary = td_wi.get("params", {})
		var need: int = int(td_params.get("count", 0))
		var exclude: Array = td_params.get("exclude_card_ids", [])
		var hand: Array = owner.battle.context.game_state.players.get(pid).action_hand.duplicate()
		var tdf_ids: Array = []
		for cid in hand:
			if exclude.has(cid):
				continue
			tdf_ids.append(String(cid))
			if tdf_ids.size() >= need:
				break
		if tdf_ids.size() < need:
			d.append("弃牌选不够 need=%d 可选=%d hand=%d" % [need, tdf_ids.size(), hand.size()])
			break
		await _relay3(owner, others, "resume_turn_discard", {"action_id": String(td_aid), "card_ids": tdf_ids}, 5)


func _find_empty_adjacent(app, pid: StringName) -> Dictionary:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(pid)
	for n: Dictionary in _HexGrid.neighbors(mech.position):
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
			return {"q": int(n.q), "r": int(n.r)}
	return {}


func _assert_sync(h, c1, c2, tag: String, d: Array) -> String:
	var errs: Array = []
	for pid: StringName in [&"player", &"enemy", &"third"]:
		var pos_h: String = _mech_pos(h, pid)
		var pos_c1: String = _mech_pos(c1, pid)
		var pos_c2: String = _mech_pos(c2, pid)
		if not (pos_h == pos_c1 and pos_c1 == pos_c2):
			errs.append("%s %s端pos不同步 h=%s c1=%s c2=%s" % [tag, String(pid), pos_h, pos_c1, pos_c2])
	var ap_h: String = _active_pid(h)
	var ap_c1: String = _active_pid(c1)
	var ap_c2: String = _active_pid(c2)
	if not (ap_h == ap_c1 and ap_c1 == ap_c2):
		errs.append("%s active_pid不同步 h=%s c1=%s c2=%s" % [tag, ap_h, ap_c1, ap_c2])
	var pc: Array = [_pending_count(h), _pending_count(c1), _pending_count(c2)]
	if not (pc[0] == 0 and pc[1] == 0 and pc[2] == 0):
		errs.append("%s pending残留 h=%d c1=%d c2=%d" % [tag, pc[0], pc[1], pc[2]])
	if errs.size() > 0:
		d.append("SYNC@%s: %s" % [tag, " | ".join(PackedStringArray(errs))])
	return " | ".join(PackedStringArray(errs))


func test_postchain_sync() -> Variant:
	var h = await _build(77401, &"player")
	var c1 = await _build(77401, &"enemy")
	var c2 = await _build(77401, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_pilots_3(h, c1, c2)
	if err != "":
		return err
	var d: Array = []
	for app in [h, c1, c2]:
		if _stack_raid_top(app, 2).size() < 2:
			return "敌袭实例不足"
	# EVENT 标记放 player 机甲相邻空格
	var cell: Dictionary = _find_empty_adjacent(h, &"player")
	if cell.is_empty():
		await _free3(h, c1, c2)
		return "无相邻空格"
	for app in [h, c1, c2]:
		app.battle.context.game_state.map_state.add_marker(
			StringName("m_pc_%d_%d" % [cell.q, cell.r]), cell.q, cell.r, &"EVENT")

	# ── 阶段1：p080 链（李两次都取消，与用户"都监听到"一致）──
	var pid_card: StringName = _pilot_instance_id(h, &"player")
	await _relay3(h, [c1, c2], "equipment_active", {"card_instance_id": pid_card, "effect_id": &"pilot_080_effect_01"}, 2)
	var wi: Dictionary = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"select_map_cell":
		await _free3(h, c1, c2)
		return "未进入选格（wait=%s）" % String(wi.get("input_type", &""))
	var smc_aid: StringName = h._map_cell_select_action_id
	h._on_battle_hex_clicked({"q": cell.q, "r": cell.r})
	await _pump(2)
	var cell_id: String = "%d,%d" % [cell.q, cell.r]
	for app in [c1, c2]:
		app._apply_remote_input("resume_effect", {"action_id": String(smc_aid), "data": {"selected_cell_id": cell_id}})
	await _pump(3)
	wi = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"choose_one_effect":
		await _free3(h, c1, c2)
		return "未进入二选一（wait=%s）" % String(wi.get("input_type", &""))
	var ec_aid: StringName = h._effect_choice_action_id
	h.choice_panel._on_option_selected(&"option_1")
	h.choice_panel._on_confirm()
	await _pump(2)
	var relay: Dictionary = {"action_id": String(ec_aid), "data": {"chosen_effect_id": &"option_1", "confirmed": true, "chosen_option_index": 1}}
	for app in [c1, c2]:
		app._apply_remote_input("resume_effect", relay)
	await _pump(6)

	# 循环驱动链：李拦截(cancel) / 敌袭选择(设2损伤) / 损伤放置(真实damage_place锁步)
	var guard: int = 0
	while guard < 60:
		guard += 1
		var progressed: bool = false
		for app in [c1, h, c2]:
			var awi: Dictionary = _wait_info(app)
			var pend: Dictionary = app.battle.context.timing_engine._pending_effect
			var awt: StringName = awi.get("input_type", &"")
			var a_aid: StringName = awi.get("action_id", &"")
			if awt == &"choose_one_effect" and a_aid != &"" and pend.has(a_aid):
				var phase: String = String(pend[a_aid].get("phase", &""))
				if phase == "pilot_051_intercept":
					var owner_aid: StringName = app._effect_choice_action_id
					app._on_choice_cancelled()
					await _pump(2)
					var cdata: Dictionary = {"action_id": String(owner_aid), "data": {"cancelled": true}}
					for other in [h, c1, c2]:
						if other != app:
							other._apply_remote_input("resume_effect", cdata)
					await _pump(4)
					progressed = true
					break
				if phase == "pre_actions_target":
					var raid_aid: StringName = app._effect_choice_action_id
					app.choice_panel._on_option_selected(&"option_1")
					app.choice_panel._on_confirm()
					await _pump(2)
					var rdata: Dictionary = {"action_id": String(raid_aid), "data": {"chosen_option_index": 1, "confirmed": true}}
					for other in [h, c1, c2]:
						if other != app:
							other._apply_remote_input("resume_effect", rdata)
					await _pump(4)
					progressed = true
					break
		if progressed:
			continue
		var dmg_done: bool = false
		for app in [h, c1, c2]:
			var reg = app.battle.context.action_registry
			for a in reg.get_actions_by_type(&"damage_change"):
				if a.state == &"waiting_input":
					var amount: int = int(a.record.get("value", 0))
					var mech_ids: Array = a.record.get("mech_ids", [])
					var dmg_aid: StringName = a.action_id
					var dmg_mid: StringName = mech_ids[0] if mech_ids.size() > 0 else &""
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
		var all_done: bool = true
		for app in [h, c1, c2]:
			for at in [&"effect_fire", &"set_event_card"]:
				for a in app.battle.context.action_registry.get_actions_by_type(at):
					if a.state != &"completed" and a.state != &"cancelled":
						all_done = false
		if all_done:
			break
		await _pump(2)
	var sync_err: String = _assert_sync(h, c1, c2, "链完成", d)
	if sync_err != "":
		await _free3(h, c1, c2)
		return "链完成后 " + sync_err

	# ── 阶段2：host 移动（host 回合内）──
	var host_dest: Dictionary = _find_empty_adjacent(h, &"player")
	if host_dest.is_empty():
		await _free3(h, c1, c2)
		return "host 无可移动相邻格"
	await _relay3(h, [c1, c2], "move", {"player_id": &"player", "q": host_dest.q, "r": host_dest.r}, 4)
	sync_err = _assert_sync(h, c1, c2, "host移动后", d)
	if sync_err != "":
		await _free3(h, c1, c2)
		return "host移动后 " + sync_err
	if _mech_pos(h, &"player") != "%d,%d" % [host_dest.q, host_dest.r]:
		d.append("host移动未生效 pos=%s 期望=%s" % [_mech_pos(h, &"player"), "%d,%d" % [host_dest.q, host_dest.r]])

	# ── 阶段3：host 结束回合 -> 李（enemy）回合 ──
	await _relay3(h, [c1, c2], "end_turn", {"player_id": &"player"}, 5)
	# 弃超限牌阻塞窗（正常流程）：host 应答选牌 -> resume_turn_discard 三端续跑
	await _answer_discard_flow(h, [c1, c2], &"player", d)
	for app in [h, c1, c2]:
		var dwi: Dictionary = _wait_info(app)
		var pend: Dictionary = app.battle.context.timing_engine._pending_effect
		var phases: Array = []
		for pk: StringName in pend:
			phases.append("%s:%s" % [String(pk), String(pend[pk].get("phase", &"-"))])
		var live: Array = []
		for at in [&"effect_fire", &"set_event_card", &"discard_card", &"turn_end", &"single_move", &"damage_change"]:
			for a in app.battle.context.action_registry.get_actions_by_type(at):
				if a.state != &"completed" and a.state != &"cancelled":
					live.append("%s[%s] st=%s step=%s" % [String(at), String(a.action_id), String(a.state), str(a.current_step_index)])
		d.append("end_turn后[%s端]: wait=%s/%s pend=[%s] flow=%s live=[%s]" % [
			String(app.local_player_id), String(dwi.get("input_type", &"")), String(dwi.get("action_id", &"")),
			", ".join(PackedStringArray(phases)), str(app._pending_turn_flow), " ".join(PackedStringArray(live))])
	sync_err = _assert_sync(h, c1, c2, "host结束后", d)
	if sync_err != "":
		await _free3(h, c1, c2)
		return "host结束后 " + sync_err
	if _active_pid(h) != &"enemy":
		await _free3(h, c1, c2)
		return "host结束后应轮到enemy(李) 实=%s c1=%s | %s" % [_active_pid(h), _active_pid(c1), " | ".join(PackedStringArray(d))]

	# ── 阶段4：李移动（李回合内，客户端发起）──
	var li_dest: Dictionary = _find_empty_adjacent(c1, &"enemy")
	if li_dest.is_empty():
		await _free3(h, c1, c2)
		return "李无可移动相邻格"
	await _relay3(c1, [h, c2], "move", {"player_id": &"enemy", "q": li_dest.q, "r": li_dest.r}, 4)
	sync_err = _assert_sync(h, c1, c2, "李移动后", d)
	if sync_err != "":
		await _free3(h, c1, c2)
		return "李移动后 " + sync_err

	# ── 阶段5：李发动 e1（抽设事件牌，DIRECT 按钮 -> equipment_active）──
	var li_card: StringName = _pilot_instance_id(c1, &"enemy")
	var ev_before: int = c1.battle.context.game_state.deck_state.event_deck.size()
	await _relay3(c1, [h, c2], "equipment_active", {"card_instance_id": li_card, "effect_id": &"pilot_051_effect_01"}, 4)
	# 李e1设牌触发李自己e2拦截窗（前两次cancel未消耗本局1次）：取消不拦截
	var e1_guard: int = 0
	while e1_guard < 6:
		e1_guard += 1
		var ewi: Dictionary = _wait_info(c1)
		if String(ewi.get("input_type", &"")) != &"choose_one_effect":
			break
		var epend: Dictionary = c1.battle.context.timing_engine._pending_effect
		var e_aid: StringName = ewi.get("action_id", &"")
		if not epend.has(e_aid) or String(epend[e_aid].get("phase", &"")) != "pilot_051_intercept":
			break
		var e_owner_aid: StringName = c1._effect_choice_action_id
		c1._on_choice_cancelled()
		await _pump(2)
		var ecancel: Dictionary = {"action_id": String(e_owner_aid), "data": {"cancelled": true}}
		for other in [h, c2]:
			other._apply_remote_input("resume_effect", ecancel)
		await _pump(4)
	for app in [h, c1, c2]:
		var lwi: Dictionary = _wait_info(app)
		var lpend: Dictionary = app.battle.context.timing_engine._pending_effect
		var lphases: Array = []
		for pk: StringName in lpend:
			var pe: Dictionary = lpend[pk]
			var l_eff = pe.get("effect", null)
			lphases.append("%s:%s(effect=%s)" % [String(pk), String(pe.get("phase", &"-")), String(l_eff.effect_id) if l_eff != null else "?"])
		var lzone: String = "-"
		var lmech = app.battle.context.game_state.get_mech_for_player(&"enemy")
		var lslot = lmech.slots.get(&"event")
		if lslot != null and lslot.equipped_card != null:
			lzone = String(lslot.equipped_card.def.card_id)
		d.append("李e1后[%s端]: wait=%s/%s pend=[%s] zone=%s" % [
			String(app.local_player_id), String(lwi.get("input_type", &"")), String(lwi.get("action_id", &"")),
			", ".join(PackedStringArray(lphases)), lzone])
	sync_err = _assert_sync(h, c1, c2, "李e1后", d)
	if sync_err != "":
		await _free3(h, c1, c2)
		return "李e1后 " + sync_err + " | " + " | ".join(PackedStringArray(d))
	var ev_after: int = c1.battle.context.game_state.deck_state.event_deck.size()
	if ev_after >= ev_before:
		d.append("李e1未抽事件牌 deck=%d->%d" % [ev_before, ev_after])

	# ── 阶段6：李结束回合 -> third 回合，third 移动 ──
	await _relay3(c1, [h, c2], "end_turn", {"player_id": &"enemy"}, 5)
	await _answer_discard_flow(c1, [h, c2], &"enemy", d)
	sync_err = _assert_sync(h, c1, c2, "李结束后", d)
	if sync_err != "":
		await _free3(h, c1, c2)
		return "李结束后 " + sync_err
	if _active_pid(h) != &"third":
		await _free3(h, c1, c2)
		return "李结束后应轮到third 实=%s c1=%s" % [_active_pid(h), _active_pid(c1)]
	var th_dest: Dictionary = _find_empty_adjacent(c2, &"third")
	if th_dest.is_empty():
		await _free3(h, c1, c2)
		return "third无可移动相邻格"
	await _relay3(c2, [h, c1], "move", {"player_id": &"third", "q": th_dest.q, "r": th_dest.r}, 4)
	sync_err = _assert_sync(h, c1, c2, "third移动后", d)
	if sync_err != "":
		await _free3(h, c1, c2)
		return "third移动后 " + sync_err

	# 金币一致性（回合流转增益后）
	for pid: StringName in [&"player", &"enemy", &"third"]:
		var g_h: int = _gold(h, pid)
		var g_c1: int = _gold(c1, pid)
		var g_c2: int = _gold(c2, pid)
		if not (g_h == g_c1 and g_c1 == g_c2):
			errs_final.append("gold %s 不同步 h=%d c1=%d c2=%d" % [String(pid), g_h, g_c1, g_c2])
	if errs_final.size() > 0:
		errs_final.append_array(d)
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(errs_final))
	await _free3(h, c1, c2)
	return true


var errs_final: Array = []


func _free3(h, c1, c2) -> void:
	for app in [h, c1, c2]:
		if app != null:
			app.queue_free()
	await _pump(3)


func _collect_tests() -> Array:
	return [
		{"name": "postchain_sync", "fn": test_postchain_sync},
	]


func run_tests() -> Dictionary:
	errs_final = []
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
