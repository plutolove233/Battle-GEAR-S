## test_pilot_024_awaken_pvp3.gd - 诊断：觉醒（action_024_觉醒）PvP3 三端锁步失步
##
## 用户反馈："这个根因就他们仨（骇客/青瞳/肯耳忒）……确定吗"。穷尽审计后按失步定理
## （弹窗 input_params 含 action_id -> PvP 非持有端 skip_remote_waiting(action_id) 清共享槽
## -> 确认/取消走共享槽 on_ui_confirmed/on_ui_cancelled 早退丢输入 -> 该 need_input 动作对端
## 永不续跑 -> 三方失步）逆向核对全部弹窗站点，发现第 4 个同类漏网点：**觉醒 awaken_select**。
##
## 根因：awaken_action.gd 第④分支 need_input 的 input_params 含 "action_id"（122 行）+ "player_id"
## （125 行），_popup_owner("awaken_select") 走大列表读 player_id 路由到持有端；PvP 非持有端被
## skip_remote_waiting(action_id) 清共享槽，但 _on_awaken_selection_completed（app_root 6835）/
## _on_awaken_selection_cancelled（6842）确认/取消仍走 _net_exec("ui_confirmed") 共享槽
## -> 对端 on_ui_confirmed 槽空早退丢输入 -> 觉醒子动作对端停在 waiting_input、use_action_card
## 父动作永不完成 -> 三端手牌发散。
##
## 修复（app_root，通用不绑卡）：确认/取消改用 _awaken_select_action_id 捕获的 action_id 发
## "resolve_action_input" op 按 id 精确路由（镜像青瞳偷牌 STEAL 修复，见 resolve_action_input
## 分发表 1657），下游与 ui_confirmed 完全一致（_apply_action_input -> continue_action），
## 空捕获回退共享槽。觉醒为纯桥 need_input 无 _pending_effect，不走 resume_effect。
##
## 本测试三端对等引擎，驱动真实 play_action_card op -> 觉醒两轮弹窗 -> host 真实 UI 路径
## _on_awaken_selection_completed/_on_awaken_selection_cancelled（resolve_action_input 广播）
## -> 对端 _apply_remote_input 接收，逐步断言三端动作状态/手牌一致，定位失步环节。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

const AWAKEN_DEF := "action_024_觉醒"
const ATTACK_DEF := "action_001_进攻"
const ASSAULT_DEF := "action_002_强袭"


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


## 三端重设战场：清空全部玩家行动手牌 + 清空行动弃牌堆；重建"觉醒入 player 手牌"、
## "进攻/强袭入弃牌堆"（两者非SSR供选框；预判/识破不在 -> 觉醒两轮都弹窗）。
## 用 gs.next_id 新建实例（三端同序列 -> 同实例ID），不依赖牌堆洗牌顺序。
## 返回 {ok, awaken_id, message}（awaken_id 三端相同，取 host 的）。
func _setup_awaken_3(h, c1, c2) -> Dictionary:
	var awaken_id: String = ""
	for app in [h, c1, c2]:
		var gs = app.battle.context.game_state
		var cdb = app.battle.context.card_database
		# 清空全部玩家行动手牌 -> 放回牌堆底
		for pid in gs.players:
			var p = gs.players[pid]
			for cid in p.action_hand.duplicate():
				app.battle.context.timing_engine.unregister_listeners_for_card(cid)
				p.action_hand.erase(cid)
				var c = gs.get_card(cid)
				if c != null:
					c.zone = &"action_deck"
					gs.deck_state.action_deck.append(cid)
		# 清空行动弃牌堆 -> 放回牌堆底
		while not gs.deck_state.action_discard_pile.is_empty():
			var dcid: StringName = gs.deck_state.action_discard_pile.pop_back()
			gs.deck_state.action_deck.append(dcid)
			var dc = gs.get_card(dcid)
			if dc != null:
				dc.zone = &"action_deck"
		# 觉醒牌入 player 手牌
		var adef = cdb.get_card(&"action_024_觉醒")
		if adef == null:
			return {"ok": false, "awaken_id": "", "message": "action_024_觉醒 定义不存在"}
		var aw_id: StringName = gs.next_id(&"card")
		var aw_card = _CardInstance.new(aw_id, adef)
		aw_card.owner_player_id = &"player"
		aw_card.zone = &"action_hand"
		gs.cards[aw_id] = aw_card
		gs.players[&"player"].action_hand.append(aw_id)
		if awaken_id == "":
			awaken_id = String(aw_id)
		# 进攻/强袭入弃牌堆（非SSR，觉醒轮次选框可选；觉醒牌SSR被 _build_discard_type_options 排除）
		for def_id in [ATTACK_DEF, ASSAULT_DEF]:
			var cdef = cdb.get_card(StringName(def_id))
			if cdef == null:
				return {"ok": false, "awaken_id": "", "message": "缺牌定义 %s" % def_id}
			var inst_id: StringName = gs.next_id(&"card")
			var card = _CardInstance.new(inst_id, cdef)
			card.owner_player_id = &"player"
			card.zone = &"action_discard"
			gs.cards[inst_id] = card
			gs.deck_state.action_discard_pile.append(inst_id)
	await _pump(2)
	return {"ok": true, "awaken_id": awaken_id, "message": ""}


func _wait_info(app) -> Dictionary:
	if app.battle == null or app.battle.context == null or app.battle.context.action_ui_bridge == null:
		return {}
	return app.battle.context.action_ui_bridge.get_waiting_action_info()


func _pending_count(app) -> int:
	return app.battle.context.timing_engine._pending_effect.size()


## 读取动作状态：waiting_input/running/completed/cancelled；已从注册表清理返回 "gone"
func _action_state(app, aid: StringName) -> String:
	if app.battle == null or app.battle.context == null or app.battle.context.action_registry == null:
		return "?"
	var action = app.battle.context.action_registry.get_action(aid)
	return String(action.state) if action != null else "gone"


func _hand_size(app, pid: StringName) -> int:
	var p = app.battle.context.game_state.players.get(pid)
	if p == null:
		return -99
	return p.action_hand.size()


## 当前弹窗首个可选种类 def_id；非 select_awaken_card_type 等待返回空
func _current_awaken_pick(app) -> StringName:
	var wait: Dictionary = _wait_info(app)
	if String(wait.get("input_type", &"")) != &"select_awaken_card_type":
		return &""
	var opts: Array = wait.get("input_params", {}).get("options", [])
	if opts.is_empty():
		return &""
	var first: Dictionary = opts[0] if opts[0] is Dictionary else {}
	return first.get("def_id", &"")


func _exec3(h, c1, c2, op: String, data: Dictionary, frames: int = 4) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c1._apply_remote_input(op, data)
	await _pump(frames)
	c2._apply_remote_input(op, data)
	await _pump(frames)


## host 真实 UI 确认/取消已广播 resolve_action_input；对端按同 op+data 接收
func _relay_ri3(h, c1, c2, relay: Dictionary, frames: int = 4) -> void:
	c1._apply_remote_input("resolve_action_input", relay)
	await _pump(frames)
	c2._apply_remote_input("resolve_action_input", relay)
	await _pump(frames)


func _free3(h, c1, c2) -> void:
	for app in [h, c1, c2]:
		if app != null:
			app.queue_free()
	await _pump(3)


## 主场景①：三端打出觉醒牌 -> 预判轮弹窗 -> host 真实 UI 路径选种类（两轮）
## -> resolve_action_input 广播 -> 三端都完成、手牌一致（修复前对端共享槽丢输入停 waiting_input）。
func test_awaken_confirm_pvp3_sync() -> Variant:
	var h = await _build(24001, &"player")
	var c1 = await _build(24001, &"enemy")
	var c2 = await _build(24001, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var setup: Dictionary = await _setup_awaken_3(h, c1, c2)
	if not setup.get("ok", false):
		await _free3(h, c1, c2)
		return String(setup.get("message", "setup失败"))
	var awaken_id: String = String(setup.get("awaken_id", ""))
	var hand_before: int = _hand_size(h, &"player")
	var diag: Array = []
	# ① 三端打出觉醒牌（play_action_card op）-> 预判轮弹窗（select_awaken_card_type）
	await _exec3(h, c1, c2, "play_action_card", {"player_id": &"player", "card_instance_id": StringName(awaken_id)})
	var wi_h: Dictionary = _wait_info(h)
	var aid: StringName = StringName(wi_h.get("action_id", &""))
	if String(wi_h.get("input_type", &"")) != &"select_awaken_card_type":
		diag.append("FAIL h 未弹觉醒选框 wait=%s" % String(wi_h.get("input_type", &"")))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if aid == &"":
		await _free3(h, c1, c2)
		return "FAIL 觉醒 action_id 为空"
	# 对端共享槽被 skip_remote_waiting 清空（wait_info 空），但动作应停在 waiting_input
	if not (_action_state(h, aid) == "waiting_input" and _action_state(c1, aid) == "waiting_input" and _action_state(c2, aid) == "waiting_input"):
		diag.append("FAIL 觉醒动作三端状态不一致 h=%s c1=%s c2=%s" % [_action_state(h, aid), _action_state(c1, aid), _action_state(c2, aid)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	# 纯桥 need_input 无 _pending_effect
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		diag.append("FAIL 觉醒不应有 pending h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if h._awaken_select_action_id != aid:
		diag.append("FAIL 持有端 _awaken_select_action_id 未捕获 got=%s" % String(h._awaken_select_action_id))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	diag.append("发动后: wait=select_awaken_card_type aid=%s 对端waiting_input pending=0/0/0" % String(aid))
	# ② 第1轮 host 选种类（真实 UI 路径 _on_awaken_selection_completed -> resolve_action_input 广播）
	var pick1: StringName = _current_awaken_pick(h)
	if pick1 == &"":
		await _free3(h, c1, c2)
		return "预判轮选项为空"
	h._on_awaken_selection_completed(pick1)
	await _pump(3)
	var relay1: Dictionary = {"action_id": String(aid), "data": {"chosen_card_def_id": String(pick1)}}
	await _relay_ri3(h, c1, c2, relay1, 4)
	# ③ 第2轮（识破轮）再次弹窗（同一 awaken 子动作，action_id 不变）
	var wi2_h: Dictionary = _wait_info(h)
	var aid2: StringName = StringName(wi2_h.get("action_id", &""))
	if String(wi2_h.get("input_type", &"")) != &"select_awaken_card_type":
		diag.append("FAIL 第1轮选择后 h 未弹第2轮选框 wait=%s" % String(wi2_h.get("input_type", &"")))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if aid2 != aid:
		diag.append("FAIL 第2轮 action_id 变化 %s -> %s" % [String(aid), String(aid2)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	if not (_action_state(h, aid) == "waiting_input" and _action_state(c1, aid) == "waiting_input" and _action_state(c2, aid) == "waiting_input"):
		diag.append("FAIL 第2轮三端状态不一致 h=%s c1=%s c2=%s" % [_action_state(h, aid), _action_state(c1, aid), _action_state(c2, aid)])
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	diag.append("第1轮选择后: 第2轮弹窗 aid不变 三端waiting_input")
	# ④ 第2轮 host 选种类 -> resolve_action_input 广播 -> 完成
	var pick2: StringName = _current_awaken_pick(h)
	if pick2 == &"":
		await _free3(h, c1, c2)
		return "识破轮选项为空"
	h._on_awaken_selection_completed(pick2)
	await _pump(3)
	var relay2: Dictionary = {"action_id": String(aid), "data": {"chosen_card_def_id": String(pick2)}}
	await _relay_ri3(h, c1, c2, relay2, 10)
	# ⑤ 三端都完成：无 wait / 无 pending / 觉醒动作 completed / 手牌三端一致
	var errs: Array = []
	var wt_h: StringName = _wait_info(h).get("input_type", &"")
	var wt_c1: StringName = _wait_info(c1).get("input_type", &"")
	var wt_c2: StringName = _wait_info(c2).get("input_type", &"")
	if not (wt_h == &"" and wt_c1 == &"" and wt_c2 == &""):
		errs.append("结算后 wait 残留 h=%s c1=%s c2=%s" % [String(wt_h), String(wt_c1), String(wt_c2)])
	if not (_pending_count(h) == 0 and _pending_count(c1) == 0 and _pending_count(c2) == 0):
		errs.append("结算后 pending 残留 h=%d c1=%d c2=%d" % [_pending_count(h), _pending_count(c1), _pending_count(c2)])
	var st_h: String = _action_state(h, aid)
	var st_c1: String = _action_state(c1, aid)
	var st_c2: String = _action_state(c2, aid)
	if not ((st_h == "completed" or st_h == "gone") and (st_c1 == "completed" or st_c1 == "gone") and (st_c2 == "completed" or st_c2 == "gone")):
		errs.append("觉醒动作未完成 h=%s c1=%s c2=%s" % [st_h, st_c1, st_c2])
	var hand_after: int = _hand_size(h, &"player")
	if hand_after <= hand_before:
		errs.append("player 手牌应增长（-觉醒+4获得） before=%d after=%d" % [hand_before, hand_after])
	if not (_hand_size(h, &"player") == _hand_size(c1, &"player") and _hand_size(c1, &"player") == _hand_size(c2, &"player")):
		errs.append("player 手牌三端不同步 h=%d c1=%d c2=%d" % [_hand_size(h, &"player"), _hand_size(c1, &"player"), _hand_size(c2, &"player")])
	diag.append("结算后: wait空 pending=0/0/0 觉醒completed hand=%d 三端一致" % hand_after)
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	print("DIAG: " + " | ".join(PackedStringArray(diag)))
	await _free3(h, c1, c2)
	return true


## 主场景②：三端打出觉醒牌 -> 预判轮弹窗 -> host 取消（_awaken_skip_to_top）
## -> resolve_action_input 广播 -> 三轮跳过弃牌堆选取仅抽牌堆顶，三端都完成一致。
func test_awaken_cancel_pvp3_sync() -> Variant:
	var h = await _build(24002, &"player")
	var c1 = await _build(24002, &"enemy")
	var c2 = await _build(24002, &"third")
	if h == null or c1 == null or c2 == null:
		return "三端建局失败"
	var setup: Dictionary = await _setup_awaken_3(h, c1, c2)
	if not setup.get("ok", false):
		await _free3(h, c1, c2)
		return String(setup.get("message", "setup失败"))
	var awaken_id: String = String(setup.get("awaken_id", ""))
	var hand_before: int = _hand_size(h, &"player")
	var diag: Array = []
	await _exec3(h, c1, c2, "play_action_card", {"player_id": &"player", "card_instance_id": StringName(awaken_id)})
	var wi_h: Dictionary = _wait_info(h)
	var aid: StringName = StringName(wi_h.get("action_id", &""))
	if String(wi_h.get("input_type", &"")) != &"select_awaken_card_type" or aid == &"":
		diag.append("FAIL h 未弹觉醒选框 wait=%s" % String(wi_h.get("input_type", &"")))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	diag.append("发动后: wait=select_awaken_card_type aid=%s" % String(aid))
	# ① 第1轮 host 取消（真实 UI 路径 _on_awaken_selection_cancelled -> resolve_action_input 广播）
	h._on_awaken_selection_cancelled()
	await _pump(3)
	var relay_cancel1: Dictionary = {"action_id": String(aid), "data": {"_awaken_skip_to_top": true}}
	await _relay_ri3(h, c1, c2, relay_cancel1, 4)
	# ② 第2轮再次弹窗（同 action_id）-> 再取消
	var wi2_h: Dictionary = _wait_info(h)
	if String(wi2_h.get("input_type", &"")) != &"select_awaken_card_type":
		diag.append("FAIL 第1轮取消后 h 未弹第2轮选框 wait=%s" % String(wi2_h.get("input_type", &"")))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	h._on_awaken_selection_cancelled()
	await _pump(3)
	var relay_cancel2: Dictionary = {"action_id": String(aid), "data": {"_awaken_skip_to_top": true}}
	await _relay_ri3(h, c1, c2, relay_cancel2, 10)
	# ③ 三端都完成：无 wait / 无 pending / 觉醒 completed / 手牌三端一致且净+1（-觉醒+2抽牌）
	var errs: Array = []
	var wt_h: StringName = _wait_info(h).get("input_type", &"")
	var wt_c1: StringName = _wait_info(c1).get("input_type", &"")
	var wt_c2: StringName = _wait_info(c2).get("input_type", &"")
	if not (wt_h == &"" and wt_c1 == &"" and wt_c2 == &""):
		errs.append("结算后 wait 残留 h=%s c1=%s c2=%s" % [String(wt_h), String(wt_c1), String(wt_c2)])
	var st_h: String = _action_state(h, aid)
	var st_c1: String = _action_state(c1, aid)
	var st_c2: String = _action_state(c2, aid)
	if not ((st_h == "completed" or st_h == "gone") and (st_c1 == "completed" or st_c1 == "gone") and (st_c2 == "completed" or st_c2 == "gone")):
		errs.append("觉醒动作未完成 h=%s c1=%s c2=%s" % [st_h, st_c1, st_c2])
	var hand_after: int = _hand_size(h, &"player")
	if hand_after - hand_before != 1:
		errs.append("取消路径 player 手牌净变化应+1（-觉醒+2抽牌） got=%d" % (hand_after - hand_before))
	if not (_hand_size(h, &"player") == _hand_size(c1, &"player") and _hand_size(c1, &"player") == _hand_size(c2, &"player")):
		errs.append("player 手牌三端不同步 h=%d c1=%d c2=%d" % [_hand_size(h, &"player"), _hand_size(c1, &"player"), _hand_size(c2, &"player")])
	diag.append("结算后: wait空 觉醒completed hand=%d 三端一致" % hand_after)
	if errs.size() > 0:
		diag.append("FAIL: " + " | ".join(PackedStringArray(errs)))
		await _free3(h, c1, c2)
		return " | ".join(PackedStringArray(diag))
	print("DIAG: " + " | ".join(PackedStringArray(diag)))
	await _free3(h, c1, c2)
	return true


func _collect_tests() -> Array:
	return [
		{"name": "awaken_confirm_pvp3_sync", "fn": test_awaken_confirm_pvp3_sync},
		{"name": "awaken_cancel_pvp3_sync", "fn": test_awaken_cancel_pvp3_sync},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
