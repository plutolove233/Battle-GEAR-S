## test_pvp3_p051_ui_double_click.gd - 诊断：PvP3 李e2 拦截弹窗「要点两次」
##
## 三端对等引擎（host=player 李owner / c1=enemy / c2=third）。
## 复现实机 UI 路径：dev_edit set_event_card 到 enemy 机甲 -> 三端 set_event_card
## 动作挂起 -> host 弹 effect_choice（choice_panel）-> 模拟真实点击
## （_on_option_selected + _on_confirm -> choice_made -> _on_choice_made）->
## 检查第一击后：弹窗是否残留/重现（= 要点两次）、动作是否完成、三端状态是否一致。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")


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


## 三端都给 player 机甲设李 pilot_053（走 set_pilot 保持三端注册一致）
func _setup_li_3(h, c1, c2) -> String:
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var mech = gs.get_mech_for_player(&"player")
		if mech == null:
			return "player 机甲不存在"
		var cdb = app.battle.context.card_database
		var pdef = cdb.get_card(&"pilot_053_李")
		if pdef == null:
			return "pilot_053_李 定义不存在"
		var inst_id: StringName = gs.next_id(&"card")
		var card = _CardInstance.new(inst_id, pdef)
		card.owner_player_id = &"player"
		gs.cards[inst_id] = card
		app.battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	await _pump(2)
	return ""


func _pending_count(app) -> int:
	if app.battle == null or app.battle.context == null or app.battle.context.timing_engine == null:
		return -1
	return app.battle.context.timing_engine._pending_effect.size()


func _event_slot_card_name(app, pid: StringName) -> String:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(pid)
	if mech == null:
		return "无机甲"
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
		return "空"
	return String(slot.equipped_card.def.display_name)


## 主诊断：敌方设置事件牌 -> host 弹窗 -> 真实点击一次 -> 状态检查
func test_p051_ui_single_click() -> Variant:
	var h = await _build(77123, &"player")
	var c1 = await _build(77123, &"enemy")
	var c2 = await _build(77123, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_li_3(h, c1, c2)
	if err != "":
		return err

	# dev_edit set_event_card 到 enemy（三端执行，模拟实机 dev 面板）
	h._net_exec("dev_edit", {"op": &"set_event_card", "params": {"target": &"enemy", "event_def_id": &"event_005"}})
	await _pump(3)
	c1._apply_remote_input("dev_edit", {"op": &"set_event_card", "params": {"target": &"enemy", "event_def_id": &"event_005"}})
	c2._apply_remote_input("dev_edit", {"op": &"set_event_card", "params": {"target": &"enemy", "event_def_id": &"event_005"}})
	await _pump(5)

	# host（李owner）应弹 effect_choice
	var host_panel_visible: bool = h.choice_panel != null and h.choice_panel.visible
	var host_wait: Dictionary = {}
	if h.battle.context.action_ui_bridge != null:
		host_wait = h.battle.context.action_ui_bridge.get_waiting_action_info()
	var diag: Array = []
	diag.append("弹窗显示=%s wait_input=%s wait_aid=%s pending(h/c1/c2)=%d/%d/%d" % [
		host_panel_visible, String(host_wait.get("input_type", &"")), String(host_wait.get("action_id", &"")),
		_pending_count(h), _pending_count(c1), _pending_count(c2)])
	if not host_panel_visible:
		diag.append("host 未弹 effect_choice（bug：李owner 应见弹窗）")
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))

	# 模拟真实点击：选 option_0（弃置）+ 确认
	var ec_aid_before: StringName = h._effect_choice_action_id
	var stack_top: String = ""
	if not h._popup_stack.is_empty():
		stack_top = String(h._popup_stack.back().get("popup_type", ""))
	diag.append("点击前: 捕获aid=%s 栈顶=%s 栈深=%d" % [String(ec_aid_before), stack_top, h._popup_stack.size()])

	h.choice_panel._on_option_selected(&"option_0")
	h.choice_panel._on_confirm()  # -> choice_made(option_0) -> _on_choice_made -> 本地 resume + 广播
	# 星型中继：host 广播的 resume_effect 手动喂两个 client（测试无真实网络管道）
	var relay_op: Dictionary = {"action_id": String(ec_aid_before), "data": {"chosen_effect_id": &"option_0", "confirmed": true, "chosen_option_index": 0}}
	await _pump(2)
	c1._apply_remote_input("resume_effect", relay_op)
	c2._apply_remote_input("resume_effect", relay_op)
	await _pump(6)

	# 第一击后的状态
	var panel_after1: bool = h.choice_panel != null and h.choice_panel.visible
	var wait_after1: Dictionary = {}
	if h.battle.context.action_ui_bridge != null:
		wait_after1 = h.battle.context.action_ui_bridge.get_waiting_action_info()
	diag.append("第一击后: 弹窗仍可见=%s wait_input=%s 捕获aid=%s pending(h/c1/c2)=%d/%d/%d" % [
		panel_after1, String(wait_after1.get("input_type", &"")), String(h._effect_choice_action_id),
		_pending_count(h), _pending_count(c1), _pending_count(c2)])
	# 三端 enemy 事件槽
	diag.append("三端enemy事件槽: h=%s c1=%s c2=%s" % [
		_event_slot_card_name(h, &"enemy"), _event_slot_card_name(c1, &"enemy"), _event_slot_card_name(c2, &"enemy")])
	# host set_event_card 动作是否完成（残留=未完成）
	var h_act = h.battle.context.action_registry.get_action(host_wait.get("action_id", &"")) if host_wait.has("action_id") else null
	diag.append("host动作存活=%s" % str(h_act != null))
	if h_act != null:
		diag.append("host动作state=%s" % String(h_act.state))

	# 断言：一次点击即完成（弃置）--弹窗关闭、pending清空、三端enemy槽同步为空
	var errs: Array = []
	if panel_after1:
		errs.append("BUG复现：第一击后弹窗仍可见（要点两次）")
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs.append("pending残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	var s1: String = _event_slot_card_name(h, &"enemy")
	var s2: String = _event_slot_card_name(c1, &"enemy")
	var s3: String = _event_slot_card_name(c2, &"enemy")
	if not (s1 == "空" and s2 == "空" and s3 == "空"):
		errs.append("弃置后enemy槽不同步: %s/%s/%s" % [s1, s2, s3])
	await _free3(h, c1, c2)
	if errs.size() > 0:
		return " | ".join(PackedStringArray(errs + diag))
	return true


## 场景2：李owner点 e1 按钮（抽1张事件牌设置到我方区域）-> e2 拦截自己设置的牌 -> 弹窗
## 用户报「执行时要点两次」最可能是此路径：e1 按钮 -> e2 弹窗 -> 选弃置 -> 一次点击应完成
func test_p051_e1_button_then_intercept() -> Variant:
	var h = await _build(77124, &"player")
	var c1 = await _build(77124, &"enemy")
	var c2 = await _build(77124, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_li_3(h, c1, c2)
	if err != "":
		return err

	# 事件牌堆顶放 event_005（三端同步操作：从事件堆中提取再插顶）
	var li_card_id: StringName = &""
	for cid: StringName in h.battle.context.game_state.deck_state.event_deck:
		var c = h.battle.context.game_state.cards.get(cid)
		if c != null and c.def != null and c.def.card_id == &"event_005":
			li_card_id = cid
			break
	if li_card_id == &"":
		await _free3(h, c1, c2)
		return "事件堆中无 event_005"
	for app in [h, c1, c2]:
		var ds = app.battle.context.game_state.deck_state
		ds.event_deck.erase(li_card_id)
		ds.event_deck.insert(0, li_card_id)

	# host 点 e1 按钮：equipment_active op 三端执行
	h._net_exec("equipment_active", {"card_instance_id": _li_instance_id(h), "effect_id": &"pilot_053_effect_01"})
	await _pump(3)
	c1._apply_remote_input("equipment_active", {"card_instance_id": _li_instance_id(h), "effect_id": &"pilot_053_effect_01"})
	c2._apply_remote_input("equipment_active", {"card_instance_id": _li_instance_id(h), "effect_id": &"pilot_053_effect_01"})
	await _pump(5)

	var diag: Array = []
	var panel_v: bool = h.choice_panel != null and h.choice_panel.visible
	var wait: Dictionary = {}
	if h.battle.context.action_ui_bridge != null:
		wait = h.battle.context.action_ui_bridge.get_waiting_action_info()
	diag.append("e1后: 弹窗=%s wait=%s aid=%s pending=%d/%d/%d" % [
		panel_v, String(wait.get("input_type", &"")), String(wait.get("action_id", &"")),
		_pending_count(h), _pending_count(c1), _pending_count(c2)])
	if not panel_v:
		# e1 可能因门控没执行（回合/条件）：检查李按钮效果日志
		var logs: Array = h.battle.context.game_state.log
		var tail: Array = logs.slice(maxi(0, logs.size() - 6), logs.size())
		for e in tail:
			diag.append("log: %s" % String(e.get("type", "")))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))

	# 真实点击一次（弃置）+ 中继
	var ec_aid: StringName = h._effect_choice_action_id
	h.choice_panel._on_option_selected(&"option_0")
	h.choice_panel._on_confirm()
	await _pump(2)
	var relay: Dictionary = {"action_id": String(ec_aid), "data": {"chosen_effect_id": &"option_0", "confirmed": true, "chosen_option_index": 0}}
	c1._apply_remote_input("resume_effect", relay)
	c2._apply_remote_input("resume_effect", relay)
	await _pump(8)

	var panel_after: bool = h.choice_panel != null and h.choice_panel.visible
	var wait_after: Dictionary = {}
	if h.battle.context.action_ui_bridge != null:
		wait_after = h.battle.context.action_ui_bridge.get_waiting_action_info()
	diag.append("一击后: 弹窗=%s wait=%s 捕获aid=%s pending=%d/%d/%d" % [
		panel_after, String(wait_after.get("input_type", &"")), String(h._effect_choice_action_id),
		_pending_count(h), _pending_count(c1), _pending_count(c2)])
	diag.append("三端player事件槽: h=%s c1=%s c2=%s" % [
		_event_slot_card_name(h, &"player"), _event_slot_card_name(c1, &"player"), _event_slot_card_name(c2, &"player")])
	# 弹窗又可见=需要第二次点击（用户报的 bug）
	if panel_after:
		diag.append("BUG复现：第一击后弹窗仍可见（要点两次）")
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	# 断言：pending 清空 + 三端 player 槽同步为空（弃置）
	var errs2: Array = []
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs2.append("pending残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	var p1: String = _event_slot_card_name(h, &"player")
	var p2: String = _event_slot_card_name(c1, &"player")
	var p3: String = _event_slot_card_name(c2, &"player")
	if not (p1 == "空" and p2 == "空" and p3 == "空"):
		errs2.append("弃置后player槽不同步: %s/%s/%s" % [p1, p2, p3])
	await _free3(h, c1, c2)
	if errs2.size() > 0:
		return " | ".join(PackedStringArray(errs2 + diag))
	return true


## 李机师牌实例 id（player 机甲 pilot 槽）
func _li_instance_id(app) -> StringName:
	var gs = app.battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return &""
	var slot = mech.slots.get(&"pilot")
	if slot != null and slot.equipped_card != null:
		return slot.equipped_card.instance_id
	return &""


## 场景3：e2 转设分支（option_1）——转设的 EXECUTE_SET_EVENT_CARD 重入 EVENT_SET_BEFORE，
## 依赖 once_per_game 已标记拦截。若拦截失效会弹第二个拦截窗（=「要点两次」）。
func test_p051_e2_transfer_double_window() -> Variant:
	var h = await _build(77125, &"player")
	var c1 = await _build(77125, &"enemy")
	var c2 = await _build(77125, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var err: String = await _setup_li_3(h, c1, c2)
	if err != "":
		return err

	h._net_exec("dev_edit", {"op": &"set_event_card", "params": {"target": &"enemy", "event_def_id": &"event_005"}})
	await _pump(3)
	c1._apply_remote_input("dev_edit", {"op": &"set_event_card", "params": {"target": &"enemy", "event_def_id": &"event_005"}})
	c2._apply_remote_input("dev_edit", {"op": &"set_event_card", "params": {"target": &"enemy", "event_def_id": &"event_005"}})
	await _pump(5)

	var diag: Array = []
	if h.choice_panel == null or not h.choice_panel.visible:
		await _free3(h, c1, c2)
		return "host 未弹拦截窗"
	# 选 option_1 = 转设到我方
	var ec_aid: StringName = h._effect_choice_action_id
	h.choice_panel._on_option_selected(&"option_1")
	h.choice_panel._on_confirm()
	await _pump(2)
	var relay: Dictionary = {"action_id": String(ec_aid), "data": {"chosen_effect_id": &"option_1", "confirmed": true, "chosen_option_index": 1}}
	c1._apply_remote_input("resume_effect", relay)
	c2._apply_remote_input("resume_effect", relay)
	await _pump(8)

	# 转设完成判定：enemy 槽空 + player 槽=拾荒；弹窗不应再次可见（重入被 once_per_game 拦截）
	var panel_after: bool = h.choice_panel != null and h.choice_panel.visible
	diag.append("转设后: 弹窗再现=%s 捕获aid=%s pending=%d/%d/%d" % [
		panel_after, String(h._effect_choice_action_id),
		_pending_count(h), _pending_count(c1), _pending_count(c2)])
	# once_per_game 标记诊断：e2 的 key 是否已写入
	var te_h = h.battle.context.timing_engine
	var opg: Dictionary = te_h._once_per_game_used
	var li_id: StringName = _li_instance_id(h)
	diag.append("once_per_game_used=%s 李实例=%s 期望key=%s" % [
		str(opg), String(li_id), "%s:pilot_053_effect_02" % String(li_id)])
	var e2def = null
	var all_p: Dictionary = h.battle.context.timing_engine._generate_all_effects() if h.battle.context.timing_engine.has_method("_generate_all_effects") else {}
	diag.append("e2max=%s" % str(e2def))
	diag.append("三端enemy槽: %s/%s/%s player槽: %s/%s/%s" % [
		_event_slot_card_name(h, &"enemy"), _event_slot_card_name(c1, &"enemy"), _event_slot_card_name(c2, &"enemy"),
		_event_slot_card_name(h, &"player"), _event_slot_card_name(c1, &"player"), _event_slot_card_name(c2, &"player")])
	if panel_after:
		diag.append("BUG复现：转设后第二个拦截窗弹出（要点两次）")
	# 断言：转设一次完成--弹窗不再现、pending清空、enemy槽空×3、player槽=拾荒×3、key干净
	var errs3: Array = []
	if panel_after:
		errs3.append("转设后第二个拦截窗弹出（once_per_game失效）")
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs3.append("pending残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	var e_h: String = _event_slot_card_name(h, &"enemy")
	var e_c1: String = _event_slot_card_name(c1, &"enemy")
	var e_c2: String = _event_slot_card_name(c2, &"enemy")
	if not (e_h == "空" and e_c1 == "空" and e_c2 == "空"):
		errs3.append("转设后enemy槽不同步: %s/%s/%s" % [e_h, e_c1, e_c2])
	var q_h: String = _event_slot_card_name(h, &"player")
	var q_c1: String = _event_slot_card_name(c1, &"player")
	var q_c2: String = _event_slot_card_name(c2, &"player")
	if not (q_h == q_c1 and q_c1 == q_c2 and q_h != "空"):
		errs3.append("转设后player槽不同步: %s/%s/%s" % [q_h, q_c1, q_c2])
	var want_key: String = "%s:pilot_053_effect_02" % String(li_id)
	if not opg.has(want_key):
		errs3.append("once_per_game键缺失: 期望=%s 实际=%s" % [want_key, str(opg.keys())])
	await _free3(h, c1, c2)
	if errs3.size() > 0:
		return " | ".join(PackedStringArray(errs3 + diag))
	return true


func _free3(h, c1, c2) -> void:
	await _free_app_root(h)
	await _free_app_root(c1)
	await _free_app_root(c2)


func _collect_tests() -> Array:
	return [
		{"name": "p051_ui_single_click", "fn": test_p051_ui_single_click},
		{"name": "p051_e1_button_then_intercept", "fn": test_p051_e1_button_then_intercept},
		{"name": "p051_e2_transfer_double_window", "fn": test_p051_e2_transfer_double_window},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
