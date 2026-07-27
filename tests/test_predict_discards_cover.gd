## test_predict_discards_cover.gd - 预判弃掉对方掩护使其不触发
##
## 验证问题1+3：预判效果2(优先级30, ATTACK_PRE)先于掩护效果1(优先级10, ATTACK_PRE)执行。
## 预判弃置对方手牌中的掩护后，掩护虽已被收集进 ATTACK_PRE 监听器列表，但因离开手牌
## 不再触发（_listener_card_still_active 校验跳过；CHOOSE_MANY_CARDS 也不会再列出该掩护）。
##
## 用例A：预判弃掉掩护 -> 掩护多选窗不弹出、掩护进弃牌堆。
## 用例B（对照）：预判弃掉其他牌 -> 掩护仍在手 -> 掩护多选窗弹出。
extends RefCounted

const _PredictTest = preload("res://tests/test_expose_predict_scenarios.gd")


## 追踪所有 action_needs_input 的 input_type，用于判断掩护多选窗(select_thrust_cards)是否弹出。
## 在 driver.attach 之后连接（driver 只断开 ActionUIBridge，不断开本 tracker）。
func _track_input_types(context, seen: Array) -> void:
	var tracker := func(_aid: StringName, itype: StringName, _params: Dictionary) -> void:
		seen.append(String(itype))
	context.action_engine.action_needs_input.connect(tracker)
	if context.timing_engine != null:
		context.timing_engine.action_needs_input.connect(tracker)


# ════════════════════════════════════════════════════════════
## 用例A：预判弃掉对方掩护 -> 掩护不再触发
# ════════════════════════════════════════════════════════════
func test_predict_discards_cover_skips_cover_effect():
	var h := _PredictTest.new()
	var battle := h._new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")    # A = 目标 = 掩护持有者
	var mech_b = gs.get_mech_for_player(&"enemy")     # B = 预判使用者 = 攻击方
	var _ep = gs.players.get(&"enemy")
	if _ep != null:
		_ep.is_human = true
	h._place(battle, mech_a.mech_id, 10, 0)
	h._place(battle, mech_b.mech_id, 11, 0)
	mech_a.power = 6
	mech_b.power = 6

	# A 手牌：掩护 + 进攻（非迎击，避免响应窗口干扰）
	h._clear_action_hand(battle, &"player")
	var cover_cid := h._ensure_card_in_hand(battle, &"player", "action_016_掩护")
	if cover_cid == &"":
		return "A 找不到掩护"
	var filler_cid := h._ensure_card_in_hand(battle, &"player", "action_001_进攻")
	if filler_cid == &"":
		return "A 找不到进攻(填充牌)"
	# B 手牌：预判（清手牌避免其他牌干扰）
	h._clear_action_hand(battle, &"enemy")
	var predict_cid := h._ensure_card_in_hand(battle, &"enemy", "action_007_预判")
	if predict_cid == &"":
		return "B 找不到预判"
	var b_weapon: StringName = mech_b.get_weapon_ids()[0]

	var seen_types := []
	var driver := _PredictTest.InputDriver.new()
	driver.weapon_for = func(_aid): return b_weapon
	driver.target_for = func(_aid, _p): return mech_a.mech_id
	driver.discard_for = func(_aid, p):
		# 预判 effect2 弃 A 的牌：选掩护弃掉（验证掩护被弃后不再触发）
		var pid: StringName = p.get("discard_player_id", &"")
		if String(pid) == &"player":
			return [cover_cid]
		return []
	driver.response_for = func(_aid): return []
	driver.move_cell_for = func(_aid, _p): return ""
	driver.damage_for = func(_aid, _p): return {"auto_placed": true}
	driver.frame_cb = Callable(h, "_frame")
	driver.attach(battle.context)
	_track_input_types(battle.context, seen_types)

	# B 打预判攻 A
	battle.execute_use_action_card(&"enemy", predict_cid)
	await driver.drain()

	# 1) 掩护多选窗不应弹出（cover_e1 因掩护离开手牌被跳过）
	if seen_types.has("select_thrust_cards"):
		return "掩护已被预判弃掉，不应再弹掩护多选窗(select_thrust_cards)"
	# 2) 掩护牌应在弃牌堆（被预判弃置）
	if not gs.deck_state.action_discard_pile.has(cover_cid):
		return "掩护应被预判弃置进弃牌堆"
	var cover_card = gs.get_card(cover_cid)
	if cover_card == null or cover_card.zone != &"discard":
		return "掩护 zone 应为 discard，实际 %s" % str(cover_card.zone if cover_card else "null")
	# 3) 掩护不在 A 手牌
	if gs.players.get(&"player").action_hand.has(cover_cid):
		return "掩护应已离开 A 手牌"
	# 4) 攻击应完成
	if battle.context.action_registry.get_active_count() != 0:
		return "预判攻击未完成，残留动作"
	return true


# ════════════════════════════════════════════════════════════
## 用例B（对照）：预判弃掉其他牌 -> 掩护仍在手 -> 掩护多选窗弹出
# ════════════════════════════════════════════════════════════
func test_predict_discards_other_card_cover_triggers():
	var h := _PredictTest.new()
	var battle := h._new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")
	var mech_b = gs.get_mech_for_player(&"enemy")
	var _ep = gs.players.get(&"enemy")
	if _ep != null:
		_ep.is_human = true
	h._place(battle, mech_a.mech_id, 10, 0)
	h._place(battle, mech_b.mech_id, 11, 0)
	mech_a.power = 6
	mech_b.power = 6

	h._clear_action_hand(battle, &"player")
	var cover_cid := h._ensure_card_in_hand(battle, &"player", "action_016_掩护")
	if cover_cid == &"":
		return "A 找不到掩护"
	var filler_cid := h._ensure_card_in_hand(battle, &"player", "action_001_进攻")
	if filler_cid == &"":
		return "A 找不到进攻(填充牌)"
	h._clear_action_hand(battle, &"enemy")
	var predict_cid := h._ensure_card_in_hand(battle, &"enemy", "action_007_预判")
	if predict_cid == &"":
		return "B 找不到预判"
	var b_weapon: StringName = mech_b.get_weapon_ids()[0]

	var seen_types := []
	var driver := _PredictTest.InputDriver.new()
	driver.weapon_for = func(_aid): return b_weapon
	driver.target_for = func(_aid, _p): return mech_a.mech_id
	driver.discard_for = func(_aid, p):
		# 预判 effect2 弃 A 的牌：选进攻弃掉，保留掩护（对照：掩护应仍触发）
		var pid: StringName = p.get("discard_player_id", &"")
		if String(pid) == &"player":
			return [filler_cid]
		return []
	# 掩护多选窗弹出时：不使用掩护（返回空选 -> resume_pending_effect 走空选不弃置）
	# InputDriver._resolve 对 select_thrust_cards 默认返回 {"auto":true}，choose_many 阶段读
	# selected_card_ids=[] -> 不使用掩护、不弃置，攻击继续。
	driver.response_for = func(_aid): return []
	driver.move_cell_for = func(_aid, _p): return ""
	driver.damage_for = func(_aid, _p): return {"auto_placed": true}
	driver.frame_cb = Callable(h, "_frame")
	driver.attach(battle.context)
	_track_input_types(battle.context, seen_types)

	battle.execute_use_action_card(&"enemy", predict_cid)
	await driver.drain()

	# 1) 掩护仍在手 -> cover_e1 应弹掩护多选窗
	if not seen_types.has("select_thrust_cards"):
		return "掩护仍在手，应弹掩护多选窗(select_thrust_cards)"
	# 2) 掩护未被使用，仍在 A 手牌
	if not gs.players.get(&"player").action_hand.has(cover_cid):
		return "掩护未被预判弃置，应仍在 A 手牌"
	# 3) 攻击应完成
	if battle.context.action_registry.get_active_count() != 0:
		return "预判攻击未完成，残留动作"
	return true
