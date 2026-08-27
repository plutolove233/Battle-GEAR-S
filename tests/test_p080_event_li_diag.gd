## test_p080_event_li_diag.gd - 诊断：墨尘移至EVENT标记(2次生效) + 李e2拦截 + 敌袭instant牌
##
## 复现用户 PvP3 报告（引擎级单端）：
##   1. 事件标记两次生效，instant 牌（敌袭）效果应即时生效两次；
##   2. 李 e2 应能拦截两次设置（取消不消耗本局1次）；
##   3. 敌袭结算后应弃置离场，不应留在事件区。
extends RefCounted

const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _new_battle() -> BattleState:
	var registry := preload("res://scripts/data/data_registry.gd").new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90091
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	battle.context.action_ui_bridge.context = battle.context
	return battle


func _setup_pilot(battle, owner_id: StringName, def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var pdef = cdb.get_card(StringName(def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


func _make_all_cells_normal(gs) -> void:
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"


func _adjacent_cell(gs, from_hex: Dictionary) -> Dictionary:
	for n: Dictionary in _HexGrid.neighbors(from_hex):
		var cell_id: String = "%d,%d" % [int(n.q), int(n.r)]
		if not gs.map_state.cells.has(StringName(cell_id)):
			continue
		var occupied: bool = false
		for mid: StringName in gs.mechs:
			var m = gs.mechs[mid]
			if m != null and not m.destroyed and int(m.position.get("q", 0)) == int(n.q) and int(m.position.get("r", 0)) == int(n.r):
				occupied = true
				break
		if occupied:
			continue
		return {"q": int(n.q), "r": int(n.r), "cell_id": cell_id}
	return {}


func _take_event_instance(gs, card_def_id: StringName, exclude: StringName = &"") -> StringName:
	for cid: StringName in gs.deck_state.event_deck:
		if cid == exclude:
			continue
		var card = gs.cards.get(cid)
		if card != null and card.def != null and card.def.card_id == card_def_id:
			return cid
	return &""


func _stack_event_deck_top(gs, cids: Array) -> void:
	for cid in cids:
		gs.deck_state.event_deck.erase(cid)
	for i in range(cids.size() - 1, -1, -1):
		gs.deck_state.event_deck.insert(0, cids[i])


func _event_slot_card(gs, mech):
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null:
		return null
	return slot.equipped_card


func _fire_effect(battle, pilot_card, mech, player_id: StringName, effect_id: StringName):
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": effect_id,
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": effect_id,
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if String(a.record.get("effect_id", &"")) == String(effect_id) and a.state != &"completed" and a.state != &"cancelled":
			return a
	return null


func _live_actions(battle, atype: StringName) -> Array:
	var out: Array = []
	for a in battle.context.action_registry.get_actions_by_type(atype):
		if a.state != &"completed" and a.state != &"cancelled":
			out.append(a)
	return out


func _diag_line(tag: String, battle, d: Array) -> void:
	var ar = battle.context.action_registry
	var parts: Array = []
	for at in [&"effect_fire", &"set_event_card", &"damage_change", &"basic_move"]:
		for a in _live_actions(battle, at):
			var rec_info: String = ""
			if String(at) == "effect_fire":
				rec_info = String(a.record.get("effect_id", &""))
			if String(at) == "set_event_card":
				var pend: Dictionary = battle.context.timing_engine._pending_effect.get(a.action_id, {})
				rec_info = "phase=%s step=%d/%s state=%s" % [String(pend.get("phase", &"-")), a.current_step_index, String(a.current_step_phase), String(a.state)]
			parts.append("%s[%s]%s" % [String(at), String(a.action_id), rec_info])
	d.append("%s: %s" % [tag, " | ".join(PackedStringArray(parts))])


## 主诊断：完整驱动到链路结束（或卡死），逐步记录
func test_diag_move_event_with_li() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mo = _setup_pilot(battle, &"player", "pilot_080_墨尘")
	if mo == null:
		return "缺 墨尘"
	var li = _setup_pilot(battle, &"enemy", "pilot_051_李")
	if li == null:
		return "缺 李"
	var gs = mo.gs
	var te = battle.context.timing_engine
	var ae = battle.context.action_engine
	var dts = battle.context.damage_token_service
	_place_mech(battle, mo.mech.mech_id, 2, 2)
	_place_mech(battle, li.mech.mech_id, 10, 10)
	_make_all_cells_normal(gs)
	var adj: Dictionary = _adjacent_cell(gs, {"q": 2, "r": 2})
	if adj.is_empty():
		return "无相邻空格"
	gs.map_state.add_marker(&"diag_event_mk", int(adj.q), int(adj.r), &"EVENT")
	# 堆顶放2张敌袭（instant，两 次生效各抽1张）
	var c1 := _take_event_instance(gs, &"event_002")
	var c2 := _take_event_instance(gs, &"event_002", c1)
	if c1 == &"" or c2 == &"" or c1 == c2:
		return "事件牌堆敌袭不足2张"
	_stack_event_deck_top(gs, [c1, c2])
	var deck_before: int = gs.deck_state.event_deck.size()
	var d: Array = []
	var errs_unknown: Array = []

	# ① 触发墨尘 -> 选格 -> 移至
	var ef = await _fire_effect(battle, mo.card, mo.mech, &"player", &"pilot_080_effect_01")
	if ef == null:
		return "墨尘未挂起选格"
	te.resume_pending_effect(ef.action_id, {"selected_cell_id": String(adj.cell_id)})
	await _pump_frames(4)
	te.resume_pending_effect(ef.action_id, {"chosen_option_index": 1})
	await _pump_frames(4)
	_diag_line("移至后", battle, d)

	# ② 驱动循环：依次应答 李拦截(cancel) / 敌袭CHOOSE_ONE(选1=设2损伤) / 损伤放置
	var intercept_count: int = 0
	var raid_choice_count: int = 0
	var seen_sets: Dictionary = {}
	var seen_dmgs: Array = []
	var guard: int = 0
	while guard < 120:
		guard += 1
		for a in battle.context.action_registry.get_actions_by_type(&"set_event_card"):
			if not seen_sets.has(a.action_id):
				seen_sets[a.action_id] = {
					"cid": String(a.record.get("card_instance_id", &"")),
					"mech": String(a.record.get("mech_id", &"")),
				}
		for a in battle.context.action_registry.get_actions_by_type(&"damage_change"):
			if not seen_dmgs.any(func(x): return x["id"] == String(a.action_id)):
				seen_dmgs.append({"id": String(a.action_id), "mech_ids": str(a.record.get("mech_ids", [])), "value": a.record.get("value", 0), "state": String(a.state)})
		var progressed: bool = false
		# 损伤放置自动应答
		for a in _live_actions(battle, &"damage_change"):
			if a.state == &"waiting_input":
				var amount: int = int(a.record.get("value", 0))
				var mech_ids: Array = a.record.get("mech_ids", [])
				if dts != null and amount > 0:
					for mid: StringName in mech_ids:
						dts.place_damage_tokens({"mech_id": mid, "count": amount})
				ae.continue_action(a.action_id, {"auto_placed": true})
				progressed = true
				break
		if progressed:
			await _pump_frames(2)
			continue
		# set_event_card 挂起应答
		var susp: Array = []
		for a in _live_actions(battle, &"set_event_card"):
			if a.state == &"waiting_timing" or a.state == &"waiting_input":
				var pend: Dictionary = te._pending_effect.get(a.action_id, {})
				if not pend.is_empty():
					susp.append({"a": a, "phase": String(pend.get("phase", &""))})
		if not susp.is_empty():
			var s0: Dictionary = susp[0]
			var phase: String = s0["phase"]
			var a0 = s0["a"]
			if phase == "pilot_051_intercept":
				intercept_count += 1
				te.resume_pending_effect(a0.action_id, {"cancelled": true})
			elif phase == "pre_actions_target":
				raid_choice_count += 1
				te.resume_pending_effect(a0.action_id, {"chosen_option_index": 1})
			else:
				errs_unknown.append("未知挂起phase=%s" % phase)
				break
			progressed = true
		if progressed:
			await _pump_frames(3)
			continue
		# effect_fire 是否已完成
		if _live_actions(battle, &"effect_fire").is_empty():
			break
		await _pump_frames(2)

	# ③ 结果断言
	_diag_line("结束", battle, d)
	var errs: Array = []
	if _live_actions(battle, &"effect_fire").size() > 0:
		errs.append("墨尘effect_fire未完成（链卡死）")
	if _live_actions(battle, &"set_event_card").size() > 0:
		errs.append("set_event_card未完成（残留挂起）")
	if intercept_count != 2:
		errs.append("李拦截窗应弹2次 实=%d" % intercept_count)
	if raid_choice_count != 2:
		errs.append("敌袭选择窗应弹2次 实=%d" % raid_choice_count)
	if gs.deck_state.event_deck.size() != deck_before - 2:
		errs.append("事件牌堆应少2 实=%d->%d" % [deck_before, gs.deck_state.event_deck.size()])
	var slot_card = _event_slot_card(gs, mo.mech)
	if slot_card != null:
		errs.append("敌袭(instant)结算后应离场，槽残留=%s" % String(slot_card.instance_id))
	var ca = gs.get_card(c1)
	var cb = gs.get_card(c2)
	if ca != null and ca.zone != &"removed":
		errs.append("第1张敌袭应removed 实=%s" % String(ca.zone))
	if cb != null and cb.zone != &"removed":
		errs.append("第2张敌袭应removed 实=%s" % String(cb.zone))
	# 选1分支=设置2损伤×2次 => 玩家机甲损伤token共+4（设置损伤是放token不是扣HP）
	var tokens_total: int = 0
	for sid: StringName in mo.mech.slots:
		var sl = mo.mech.slots[sid]
		if sl != null:
			tokens_total += int(sl.region_damage_tokens)
			if sl.equipped_card != null:
				tokens_total += int(sl.equipped_card.damage_tokens)
	if tokens_total < 4:
		errs.append("敌袭2次应共放4损伤token 实=%d" % tokens_total)
	if not errs_unknown.is_empty():
		errs.append_array(errs_unknown)
	if errs.size() > 0:
		errs.append_array(d)
		return " | ".join(PackedStringArray(errs))
	return true


func _collect_tests() -> Array:
	return [
		{"name": "diag_move_event_with_li", "fn": test_diag_move_event_with_li},
	]


func run_tests() -> Dictionary:
	var results: Dictionary = {}
	for t in _collect_tests():
		var r: Variant = await t["fn"].call()
		results[t["name"]] = r
	return results
