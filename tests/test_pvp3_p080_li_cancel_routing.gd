## test_pvp3_p080_li_cancel_routing.gd - 回归：effect_choice 取消必须按 action_id 精确路由
##
## 0827 实机根因①回归测试。_on_choice_cancelled 此前先隐藏 choice_panel 再查弹窗栈，
## visible=false 同步触发 _on_popup_visibility_changed -> _pop_popup_entry 弹出栈顶，
## 精确路由分支恒为死码 -> effect_choice 取消退化为无向 ui_cancelled op：该 op 只在
## 共享等待槽恰好持有该动作的一端落地，其余端槽位已被 skip_remote_waiting 清空而静默
## 丢弃 -> 李拦截动作在其余端永久挂起 + 三端动作 id 发散 -> use2 选格 resume 跨端落空
## -> 李端完全卡死无弹窗（用户实机 bug2），敌袭 instant 不结算（bug1 症状之一）。
##
## 与既有 test_pvp3_p080_event_li_desync 的区别：该测试手动构造 resume_effect 转发对端，
## 恰好掩盖了生产取消路径的真实缺陷。本测试用 NetSpy 捕获 _net_exec 的真实广播 op
## 并原样转发对端（模拟星型中继），断言：
##   A. 取消广播的是 resume_effect（带 action_id + cancelled:true），绝非 ui_cancelled；
##   B. 三端拦截动作全部完成、id 序列一致、事件牌堆-2、事件区无残留（bug1 语义闭环）。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


## 网络间谍：伪装 net_host/net_client 捕获 _broadcast_input 的真实出站消息。
## 仅 _broadcast_input 在战斗流程中调用 send（握手/停止路径测试不触发），无副作用。
class NetSpy extends Node:
	var messages: Array = []

	func is_client_connected() -> bool:
		return true

	func is_connected_to_host() -> bool:
		return true

	func send(msg: Dictionary) -> void:
		messages.append(msg)


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


func _attach_spies(h, c1, c2) -> void:
	## h 是 host 端（is_network_client=false 走 net_host.send），c1/c2 是 client 端（走 net_client.send）
	h.net_host = NetSpy.new()
	c1.net_client = NetSpy.new()
	c2.net_client = NetSpy.new()


func _spy_of(app):
	return app.net_host if app.is_network_client == false else app.net_client


## 排空 spy 捕获的真实广播 op，原样转发给其余两端（模拟星型中继送达），再 pump。
## 消息按捕获序 FIFO 转发，保锁步 op 顺序；只转发 type=="input" 的引擎 op。
func _flush(src, others: Array, frames: int = 4) -> void:
	var spy = _spy_of(src)
	if spy == null:
		await _pump(1)
		return
	var msgs: Array = spy.messages.duplicate()
	spy.messages.clear()
	for msg in msgs:
		if String(msg.get("type", "")) != "input":
			continue
		for other in others:
			other._apply_remote_input(String(msg.get("op", "")), msg.get("data", {}))
	await _pump(frames)


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


func _event_zone_card(app) -> String:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var slot = mech.slots.get(&"event")
	if slot != null and slot.equipped_card != null:
		return String(slot.equipped_card.def.card_id)
	return "-"


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


func _live_actions(app) -> int:
	var live: int = 0
	for at in [&"effect_fire", &"set_event_card", &"damage_change"]:
		for a in app.battle.context.action_registry.get_actions_by_type(at):
			if a.state != &"completed" and a.state != &"cancelled":
				live += 1
	return live


func test_p080_li_cancel_real_relay() -> Variant:
	var h = await _build(88117, &"player")
	var c1 = await _build(88117, &"enemy")
	var c2 = await _build(88117, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_pilots_3(h, c1, c2)
	if err != "":
		return err
	_attach_spies(h, c1, c2)
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
			StringName("m_rt_%d_%d" % [cell.q, cell.r]), cell.q, cell.r, &"EVENT")
	var deck_before: int = h.battle.context.game_state.deck_state.event_deck.size()

	# ① 墨尘按钮：h 真实 _net_exec 广播 -> spy 转发两端（不再手动构造 op）
	var pid_card: StringName = _pilot_instance_id(h, &"player")
	h._net_exec("equipment_active", {"card_instance_id": pid_card, "effect_id": &"pilot_080_effect_01"})
	await _flush(h, [c1, c2], 2)
	var wi: Dictionary = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"select_map_cell":
		await _free3(h, c1, c2)
		return "未进入选格（wait=%s）" % String(wi.get("input_type", &""))
	# ② 选标记格：h 真实点击路径（内部 resume_effect 广播由 spy 捕获转发）
	h._on_battle_hex_clicked({"q": cell.q, "r": cell.r})
	await _flush(h, [c1, c2], 3)
	wi = _wait_info(h)
	if String(wi.get("input_type", &"")) != &"choose_one_effect":
		await _free3(h, c1, c2)
		return "未进入二选一（wait=%s）" % String(wi.get("input_type", &""))
	# ③ 选「移至」：h 真实确认路径
	h.choice_panel._on_option_selected(&"option_1")
	h.choice_panel._on_confirm()
	await _flush(h, [c1, c2], 6)
	var id_err: String = _assert_id_consistency(h, c1, c2)
	if id_err != "":
		await _free3(h, c1, c2)
		return "移至后 " + id_err

	# ④ 循环驱动两轮，全部走真实 UI 路径 + spy 原样转发：
	#    李拦截(真实取消) -> 敌袭选择(真实确认) -> 损伤放置(auto 广播+转发)
	var intercept_cnt: int = 0
	var raid_cnt: int = 0
	var first_cancel_checked: bool = false
	var guard: int = 0
	while guard < 60:
		guard += 1
		var progressed: bool = false
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
					# ── 核心回归点：归属端真实取消路径 ──
					var owner_aid: StringName = app._effect_choice_action_id
					app._on_choice_cancelled()
					if not first_cancel_checked:
						first_cancel_checked = true
						var chk: String = _check_cancel_op(app, owner_aid)
						if chk != "":
							await _free3(h, c1, c2)
							return "第%d次拦截取消 " % intercept_cnt + chk
					var others_a: Array = []
					for a in [h, c1, c2]:
						if a != app:
							others_a.append(a)
					await _flush(app, others_a, 4)
					progressed = true
					break
				if phase == "pre_actions_target":
					raid_cnt += 1
					app.choice_panel._on_option_selected(&"option_1")
					app.choice_panel._on_confirm()
					var others_b: Array = []
					for a in [h, c1, c2]:
						if a != app:
							others_b.append(a)
					await _flush(app, others_b, 4)
					progressed = true
					break
		if progressed:
			continue
		# 损伤放置：h 端逐 token 放置（真实 _net_exec 广播 -> spy 转发），完成广播恢复
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
						h._net_exec("damage_place", {"slot_id": String(slots_order[si]), "target_mech_id": String(dmg_mid)})
						await _flush(h, [c1, c2], 2)
						tokens_left -= 1
						si += 1
					h._net_exec("damage_placement_done", {"action_id": String(dmg_aid)})
					await _flush(h, [c1, c2], 4)
					dmg_done = true
					break
			if dmg_done:
				break
		if dmg_done:
			continue
		# 无挂起无输入：排空残余广播后检查是否全部结束
		await _flush(h, [c1, c2], 2)
		await _flush(c1, [h, c2], 2)
		await _flush(c2, [h, c1], 2)
		var all_done: bool = true
		for app in [h, c1, c2]:
			if _live_actions(app) > 0:
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
		var live: int = _live_actions(app)
		if live > 0:
			errs.append("%s端 动作残留=%d" % [String(app.local_player_id), live])
		if app.battle.context.timing_engine._pending_effect.size() > 0:
			errs.append("%s端 挂起残留=%d" % [String(app.local_player_id), app.battle.context.timing_engine._pending_effect.size()])
	id_err = _assert_id_consistency(h, c1, c2)
	if id_err != "":
		errs.append(id_err)
	if errs.size() > 0:
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(errs))
	await _free3(h, c1, c2)
	return true


## 取消 op 断言（核心回归点 A）：_on_choice_cancelled 广播的必须是
## resume_effect{action_id: <挂起拦截动作>, data:{cancelled:true}}，不能是无向 ui_cancelled。
func _check_cancel_op(owner, owner_aid: StringName) -> String:
	var spy = _spy_of(owner)
	var ops: Array = []
	for msg in spy.messages:
		if String(msg.get("type", "")) == "input":
			ops.append(String(msg.get("op", "")))
	if ops.has("ui_cancelled"):
		return "广播了无向 ui_cancelled（精确路由死码回归，0827根因①复现）ops=%s" % str(ops)
	var has_resume: bool = false
	for msg in spy.messages:
		if String(msg.get("type", "")) != "input" or String(msg.get("op", "")) != "resume_effect":
			continue
		has_resume = true
		var rd: Dictionary = msg.get("data", {})
		var r_aid: String = String(rd.get("action_id", ""))
		if owner_aid != &"" and r_aid != String(owner_aid):
			return "取消 resume_effect 的 action_id=%s 与弹窗捕获=%s 不符" % [r_aid, String(owner_aid)]
		var inner: Dictionary = rd.get("data", {})
		if not inner.get("cancelled", false):
			return "取消 resume_effect 未携带 cancelled:true data=%s" % str(inner)
	if not has_resume:
		return "取消未广播 resume_effect（ops=%s）" % str(ops)
	return ""


func _collect_tests() -> Array:
	return [
		{"name": "p080_li_cancel_real_relay", "fn": test_p080_li_cancel_real_relay},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
