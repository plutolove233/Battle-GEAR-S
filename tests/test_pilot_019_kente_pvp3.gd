## test_pilot_019_kente_pvp3.gd - 诊断：肯耳忒 pilot_019 缴械冲击 PvP3 三端锁步失步
##
## 用户反馈：肯耳忒效果发动造成与其他玩家的失步（骇客/青瞳同款根因）。
## 根因：p019 目标多选（select_attack_target, target_kind=pilot_019, target_count=2）是引擎级挂起
## （_pending_effect），但选满提交走 _submit_multi_attack_targets 共享槽 ui_confirmed、取消走
## _on_cancel_attack 多选分支共享槽 ui_cancelled——对端（非持有端）共享槽被 skip_remote_waiting
## 清空后 on_ui_confirmed/on_ui_cancelled 早退丢输入 -> 对端停在 _pending_effect 三方失步。
##
## 修复（app_root）：_submit_multi_attack_targets 空 precise_action_id 兜底 + _on_cancel_attack
## 多选空选分支，按 has_pending_effect 判定走 resume_effect 按 action_id 精确路由广播；
## 双连等纯桥槽 need_input 无 _pending_effect 保持共享槽 per-end 自驱。
##
## 本测试三端对等引擎，驱动真实 equipment_active op -> effect_fire -> 目标多选挂起 ->
## _multi_attack_target_handle_click 选满自动提交（真实路径）-> resume_effect 广播 ->
## 支付 -> 逐目标弃牌 + 4伤害，逐步断言三端挂起/阶段/手牌/HP 一致，定位失步环节。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


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
	_clear_pilot_static()
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


## 三端给 player 机甲设肯耳忒机师牌。返回 {ok, pilot_id, message}（pilot_id 跨端相同）。
func _setup_kente_3(h, c1, c2) -> Dictionary:
	var first_id: String = ""
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var mech = gs.get_mech_for_player(&"player")
		if mech == null:
			return {"ok": false, "pilot_id": "", "message": "player 机甲不存在"}
		var cdb = app.battle.context.card_database
		var pdef = cdb.get_card(&"pilot_019_肯耳忒")
		if pdef == null:
			return {"ok": false, "pilot_id": "", "message": "pilot_019_肯耳忒 定义不存在"}
		var inst_id: StringName = gs.next_id(&"card")
		var card = _CardInstance.new(inst_id, pdef)
		card.owner_player_id = &"player"
		gs.cards[inst_id] = card
		app.battle.context.game_setup_service.set_pilot(mech.mech_id, card)
		if first_id == "":
			first_id = String(inst_id)
	await _pump(2)
	return {"ok": true, "pilot_id": first_id, "message": ""}


## 三端重设行动手牌：plan = {pid: [card_def_id, ...]}（先清空全部玩家手牌）。
func _set_hands_3(h, c1, c2, plan: Dictionary) -> String:
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var cdb = app.battle.context.card_database
		for pid in gs.players:
			var p = gs.players[pid]
			for cid in p.action_hand.duplicate():
				app.battle.context.timing_engine.unregister_listeners_for_card(cid)
				p.action_hand.erase(cid)
				var c = gs.get_card(cid)
				if c != null:
					c.zone = &"action_deck"
					gs.deck_state.action_deck.append(cid)
		for pid_str: String in plan:
			var pid: StringName = StringName(pid_str)
			for def_id_str: String in plan[pid_str]:
				var cdef = cdb.get_card(StringName(def_id_str))
				if cdef == null:
					return "缺牌定义 %s" % def_id_str
				var inst_id: StringName = gs.next_id(&"card")
				var card = _CardInstance.new(inst_id, cdef)
				card.owner_player_id = pid
				card.zone = &"action_hand"
				gs.cards[inst_id] = card
				gs.players[pid].action_hand.append(inst_id)
	await _pump(2)
	return ""


## 三端把 enemy/third 机甲挪到 player 相邻两格（hex 距离1 < 4，保证在缴械冲击范围）。
func _reposition_targets_3(h, c1, c2) -> String:
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var pm = gs.get_mech_for_player(&"player")
		if pm == null:
			return "player 机甲不存在"
		var free_cells: Array = []
		for n: Dictionary in _HexGrid.neighbors(pm.position):
			var cid: String = "%d,%d" % [int(n.q), int(n.r)]
			if gs.map_state.cells.has(StringName(cid)):
				free_cells.append({"q": int(n.q), "r": int(n.r)})
		if free_cells.size() < 2:
			return "无可用的两个相邻格"
		var em = gs.get_mech_for_player(&"enemy")
		if em == null:
			return "enemy 机甲不存在"
		em.position = free_cells[0].duplicate()
		var tm = gs.get_mech_for_player(&"third")
		if tm == null:
			return "third 机甲不存在"
		tm.position = free_cells[1].duplicate()
	await _pump(2)
	return ""


func _wait_info(app) -> Dictionary:
	if app.battle == null or app.battle.context == null or app.battle.context.action_ui_bridge == null:
		return {}
	return app.battle.context.action_ui_bridge.get_waiting_action_info()


func _pending_count(app) -> int:
	return app.battle.context.timing_engine._pending_effect.size()


func _pending_phase(app, aid: StringName) -> String:
	var pe = app.battle.context.timing_engine._pending_effect.get(aid, {})
	return String(pe.get("phase", &"")) if pe != null else ""


func _hand_size(app, pid: StringName) -> int:
	var p = app.battle.context.game_state.players.get(pid)
	if p == null:
		return -99
	return p.action_hand.size()


func _hp(app, pid: StringName) -> int:
	var m = app.battle.context.game_state.get_mech_for_player(pid)
	if m == null:
		return -99
	return int(m.current_hp)


func _mech_id(app, pid: StringName) -> StringName:
	var m = app.battle.context.game_state.get_mech_for_player(pid)
	return m.mech_id if m != null else &""


func _mech_pos(app, pid: StringName) -> String:
	var m = app.battle.context.game_state.get_mech_for_player(pid)
	if m == null:
		return "?"
	return "%d,%d" % [int(m.position.get("q", -99)), int(m.position.get("r", -99))]


func _exec3(h, c1, c2, op: String, data: Dictionary, frames: int = 4) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c1._apply_remote_input(op, data)
	c2._apply_remote_input(op, data)
	await _pump(frames)


func _free3(h, c1, c2) -> void:
	for app in [h, c1, c2]:
		if app != null:
			app.queue_free()
	await _pump(3)


## 主场景①：三端发动缴械冲击 -> 目标多选挂起 -> host 点击2台机甲选满自动提交
## （_multi_attack_target_handle_click 真实路径）-> resume_effect 广播 -> 支付 -> 逐目标4伤害，
## 断言三端阶段/手牌/HP 全程一致（修复前对端共享槽丢输入停挂起）。
func test_p019_multi_submit_pvp3_sync() -> Variant:
	var h = await _build(19001, &"player")
	var c1 = await _build(19001, &"enemy")
	var c2 = await _build(19001, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var setup: Dictionary = await _setup_kente_3(h, c1, c2)
	if not setup.get("ok", false):
		await _free3(h, c1, c2)
		return String(setup.get("message", "setup失败"))
	var pilot_id: String = String(setup.get("pilot_id", ""))
	# player 1张（X=1支付）；enemy/third 各1张（< X+1=2 -> 直接弃全部 -> 各4伤害，避开第三个输入窗）
	var err: String = await _set_hands_3(h, c1, c2, {
		"player": ["action_001_进攻"],
		"enemy": ["action_001_进攻"],
		"third": ["action_001_进攻"],
	})
	if err != "":
		await _free3(h, c1, c2)
		return err
	# enemy/third 挪到 player 相邻格
	err = await _reposition_targets_3(h, c1, c2)
	if err != "":
		await _free3(h, c1, c2)
		return err
	var enemy_mid: StringName = _mech_id(h, &"enemy")
	var third_mid: StringName = _mech_id(h, &"third")
	var pay_card: StringName = StringName(h.battle.context.game_state.players[&"player"].action_hand[0])
	var diag: Array = []
	# ① 三端发动效果（equipment_active op -> 各端本地 effect_fire）
	await _exec3(h, c1, c2, "equipment_active", {"card_instance_id": StringName(pilot_id), "effect_id": "pilot_019_effect_01"})
	var wi_h: Dictionary = _wait_info(h)
	if String(wi_h.get("input_type", &"")) != &"select_attack_target":
		diag.append("FAIL h 未挂起目标多选 wait=%s" % String(wi_h.get("input_type", &"")))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if not (_pending_count(h) == 1 and _pending_count(c1) == 1 and _pending_count(c2) == 1):
		diag.append("FAIL 发动后 pending 不同步 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	var aid: StringName = StringName(wi_h.get("action_id", &""))
	if aid == &"":
		diag.append("FAIL 目标多选 action_id 为空")
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if not (_pending_phase(h, aid) == "pilot_019_wait_targets" and _pending_phase(c1, aid) == "pilot_019_wait_targets" and _pending_phase(c2, aid) == "pilot_019_wait_targets"):
		diag.append("FAIL 三端挂起阶段不一致 h=%s c1=%s c2=%s" % [_pending_phase(h, aid), _pending_phase(c1, aid), _pending_phase(c2, aid)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	diag.append("发动后: pending=1/1/1 phase=pilot_019_wait_targets wait=%s" % String(wi_h.get("input_type", &"")))
	# ② host 点击2台机甲（真实路径 _multi_attack_target_handle_click）：
	#    第2台选满 -> 自动提交 _submit_multi_attack_targets(空 action_id 兜底) -> resume_effect 广播
	var em_pos: Dictionary = h.battle.context.game_state.get_mech_for_player(&"enemy").position.duplicate()
	var tm_pos: Dictionary = h.battle.context.game_state.get_mech_for_player(&"third").position.duplicate()
	h._multi_attack_target_count = 2
	h._multi_attack_target_chosen = []
	# 第1台
	h._multi_attack_target_handle_click({"q": int(em_pos.get("q", 0)), "r": int(em_pos.get("r", 0))}, enemy_mid, wi_h)
	await _pump(1)
	# 第2台 -> 选满自动提交（内部 _submit_multi_attack_targets(&"") -> 兜底 resume_effect）
	h._multi_attack_target_handle_click({"q": int(tm_pos.get("q", 0)), "r": int(tm_pos.get("r", 0))}, third_mid, wi_h)
	await _pump(2)
	# 对端接收同 op（真实网络帧尾送达；数据与 _submit_multi_attack_targets 广播一致）
	var relay_submit: Dictionary = {
		"action_id": String(aid),
		"data": {"target_ids": [String(enemy_mid), String(third_mid)]},
	}
	c1._apply_remote_input("resume_effect", relay_submit)
	await _pump(2)
	c2._apply_remote_input("resume_effect", relay_submit)
	await _pump(2)
	# ③ 三端应都进入支付挂起（pilot_019_pay / thrust_select）
	if not (_pending_phase(h, aid) == "pilot_019_pay" and _pending_phase(c1, aid) == "pilot_019_pay" and _pending_phase(c2, aid) == "pilot_019_pay"):
		diag.append("FAIL 提交后三端阶段不一致 h=%s c1=%s c2=%s" % [_pending_phase(h, aid), _pending_phase(c1, aid), _pending_phase(c2, aid)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	var wait_pay_h: StringName = _wait_info(h).get("input_type", &"")
	if wait_pay_h != &"thrust_select":
		diag.append("FAIL 提交后 h 未挂起支付 wait=%s" % String(wait_pay_h))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	diag.append("提交目标后: phase=pilot_019_pay wait=thrust_select")
	# ④ host 支付弃 X=1 张 -> 逐目标弃牌 + 4伤害
	var hp_e_before: int = _hp(h, &"enemy")
	var hp_t_before: int = _hp(h, &"third")
	var relay_pay: Dictionary = {
		"action_id": String(aid),
		"data": {"selected_card_ids": [String(pay_card)]},
	}
	h._net_exec("resume_effect", relay_pay)
	await _pump(2)
	c1._apply_remote_input("resume_effect", relay_pay)
	await _pump(2)
	c2._apply_remote_input("resume_effect", relay_pay)
	# ⑤ 逐目标链（弃 player 1张 -> enemy 弃1+4伤害 -> third 弃1+4伤害 -> 完成），子动作串行需多帧
	await _pump(30)
	var errs: Array = []
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs.append("pending 残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	if not (_hand_size(h, &"enemy") == 0 and _hand_size(h, &"third") == 0):
		errs.append("目标手牌应清空 enemy=%d third=%d" % [_hand_size(h, &"enemy"), _hand_size(h, &"third")])
	if _hp(h, &"enemy") != hp_e_before - 4:
		errs.append("enemy 应-4 实扣=%d" % (hp_e_before - _hp(h, &"enemy")))
	if _hp(h, &"third") != hp_t_before - 4:
		errs.append("third 应-4 实扣=%d" % (hp_t_before - _hp(h, &"third")))
	if not (_hp(h, &"enemy") == _hp(c1, &"enemy") and _hp(c1, &"enemy") == _hp(c2, &"enemy")):
		errs.append("enemy HP 不同步 h=%d c1=%d c2=%d" % [_hp(h, &"enemy"), _hp(c1, &"enemy"), _hp(c2, &"enemy")])
	if not (_hp(h, &"third") == _hp(c1, &"third") and _hp(c1, &"third") == _hp(c2, &"third")):
		errs.append("third HP 不同步 h=%d c1=%d c2=%d" % [_hp(h, &"third"), _hp(c1, &"third"), _hp(c2, &"third")])
	if not (_hand_size(c1, &"enemy") == 0 and _hand_size(c2, &"enemy") == 0):
		errs.append("enemy 手牌不同步 h=%d c1=%d c2=%d" % [_hand_size(h, &"enemy"), _hand_size(c1, &"enemy"), _hand_size(c2, &"enemy")])
	var wt_h: StringName = _wait_info(h).get("input_type", &"")
	var wt_c1: StringName = _wait_info(c1).get("input_type", &"")
	var wt_c2: StringName = _wait_info(c2).get("input_type", &"")
	if not (wt_h == &"" and wt_c1 == &"" and wt_c2 == &""):
		errs.append("wait 残留 h=%s c1=%s c2=%s" % [String(wt_h), String(wt_c1), String(wt_c2)])
	diag.append("结算后: pending=0/0/0 HP[%d/%d/%d] wait空" % [_hp(h, &"enemy"), _hp(c1, &"enemy"), _hp(c2, &"enemy")])
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	# ⑥ once_per_turn 已消耗：再次发动不挂起（三端一致）
	await _exec3(h, c1, c2, "equipment_active", {"card_instance_id": StringName(pilot_id), "effect_id": "pilot_019_effect_01"})
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs.append("once_per_turn 用满后不应再挂起 pending=%d/%d/%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	diag.append("once_per_turn 用满后: pending=0/0/0")
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	print("DIAG: " + " | ".join(PackedStringArray(diag)))
	await _free3(h, c1, c2)
	return true


## 主场景②：三端发动缴械冲击 -> host 取消（空选）-> _on_cancel_attack 多选空选分支
## resume_effect cancelled 广播 -> 三端中止不消耗 once_per_turn（可再触发）。
func test_p019_cancel_empty_pvp3_sync() -> Variant:
	var h = await _build(19002, &"player")
	var c1 = await _build(19002, &"enemy")
	var c2 = await _build(19002, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var setup: Dictionary = await _setup_kente_3(h, c1, c2)
	if not setup.get("ok", false):
		await _free3(h, c1, c2)
		return String(setup.get("message", "setup失败"))
	var pilot_id: String = String(setup.get("pilot_id", ""))
	var err: String = await _set_hands_3(h, c1, c2, {
		"player": ["action_001_进攻"],
		"enemy": ["action_001_进攻"],
		"third": ["action_001_进攻"],
	})
	if err != "":
		await _free3(h, c1, c2)
		return err
	err = await _reposition_targets_3(h, c1, c2)
	if err != "":
		await _free3(h, c1, c2)
		return err
	var hp_e_before: int = _hp(h, &"enemy")
	var hp_t_before: int = _hp(h, &"third")
	var diag: Array = []
	# ① 三端发动 -> 挂起目标多选
	await _exec3(h, c1, c2, "equipment_active", {"card_instance_id": StringName(pilot_id), "effect_id": "pilot_019_effect_01"})
	if not (_pending_count(h) == 1 and _pending_count(c1) == 1 and _pending_count(c2) == 1):
		diag.append("FAIL 发动后 pending 不同步 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	var aid: StringName = StringName(_wait_info(h).get("action_id", &""))
	if aid == &"":
		await _free3(h, c1, c2)
		return "FAIL 目标多选 action_id 为空"
	# ② host 点取消（空选）-> _on_cancel_attack 多选空选分支 -> resume_effect cancelled 广播
	h._multi_attack_target_count = 2
	h._multi_attack_target_chosen = []
	h._on_cancel_attack()
	await _pump(2)
	var relay_cancel: Dictionary = {"action_id": String(aid), "data": {"cancelled": true}}
	c1._apply_remote_input("resume_effect", relay_cancel)
	await _pump(2)
	c2._apply_remote_input("resume_effect", relay_cancel)
	await _pump(4)
	# ③ 三端都应中止：pending 清零 / 无弃牌 / 无伤害 / once_per_turn 未消耗
	var errs: Array = []
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs.append("取消后 pending 残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	if not (_hand_size(h, &"enemy") == 1 and _hand_size(h, &"third") == 1 and _hand_size(h, &"player") == 1):
		errs.append("取消不应弃任何牌 player=%d enemy=%d third=%d" % [_hand_size(h, &"player"), _hand_size(h, &"enemy"), _hand_size(h, &"third")])
	if not (_hp(h, &"enemy") == hp_e_before and _hp(h, &"third") == hp_t_before):
		errs.append("取消不应伤害 enemy=%d third=%d" % [_hp(h, &"enemy"), _hp(h, &"third")])
	var wt_h: StringName = _wait_info(h).get("input_type", &"")
	var wt_c1: StringName = _wait_info(c1).get("input_type", &"")
	var wt_c2: StringName = _wait_info(c2).get("input_type", &"")
	if not (wt_h == &"" and wt_c1 == &"" and wt_c2 == &""):
		errs.append("取消后 wait 残留 h=%s c1=%s c2=%s" % [String(wt_h), String(wt_c1), String(wt_c2)])
	diag.append("取消后: pending=0/0/0 无弃牌无伤害")
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	# ④ once_per_turn 未消耗：可再触发并正常挂起（三端一致）
	await _exec3(h, c1, c2, "equipment_active", {"card_instance_id": StringName(pilot_id), "effect_id": "pilot_019_effect_01"})
	if not (_pending_count(h) == 1 and _pending_count(c1) == 1 and _pending_count(c2) == 1):
		errs.append("取消后应可再触发 pending=%d/%d/%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	diag.append("再次触发: pending=1/1/1（once_per_turn 未消耗）")
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	print("DIAG: " + " | ".join(PackedStringArray(diag)))
	await _free3(h, c1, c2)
	return true


func _collect_tests() -> Array:
	return [
		{"name": "p019_multi_submit_pvp3_sync", "fn": test_p019_multi_submit_pvp3_sync},
		{"name": "p019_cancel_empty_pvp3_sync", "fn": test_p019_cancel_empty_pvp3_sync},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
