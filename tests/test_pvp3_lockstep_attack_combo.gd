## test_pvp3_lockstep_attack_combo.gd - 3人PvP 锁步「闪击+反击+联合」三效果组合同步验证
##
## 与 test_pvp_lockstep_attack_combo（双端版）同场景，扩展到 3 端对等引擎
## （host=player, client1=enemy, client2=third）：P 打出闪击发起攻击A，E 用反击响应，
## E 身上有联合状态（unite=P），P 闪击效果2 弃1张进攻牌再攻击。
## third 无牌无状态，仅作为锁步同步端验证（引擎对每条网络 op 的处理三端一致）。
##
## 覆盖用户裁定的 ATTACK_SETTLE 优先级（反击30/联合20/闪击10）在 3 端网络 op
## 全链驱动下的同步性：无孤儿动作、3端 HP/位置/手牌/牌堆一致、联合状态清除。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")


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


func _free3(h, c1, c2) -> void:
	await _free_app_root(h)
	await _free_app_root(c1)
	await _free_app_root(c2)


## 同种子建 PVP3 局（同 test_pvp3_lockstep_sync._build_pvp3_app_root）
func _build_pvp3_app_root(seed_val: int, local_pid: StringName):
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


func _wait_input_type(app_root) -> StringName:
	if app_root.battle == null or app_root.battle.context == null or app_root.battle.context.action_ui_bridge == null:
		return &""
	var wi: Dictionary = app_root.battle.context.action_ui_bridge.get_waiting_action_info()
	return wi.get("input_type", &"")


func _wait_action_id(app_root) -> StringName:
	if app_root.battle == null or app_root.battle.context == null or app_root.battle.context.action_ui_bridge == null:
		return &""
	var wi: Dictionary = app_root.battle.context.action_ui_bridge.get_waiting_action_info()
	return wi.get("action_id", &"")


## 3端 dev_add 同一张牌，返回 instance_id（3端计数器同序 => 同 id）
func _dev_add_card_3(h, c1, c2, op: StringName, target: StringName, card_id: String) -> StringName:
	h._apply_dev_edit(op, {"target": target, "card_id": card_id})
	c1._apply_dev_edit(op, {"target": target, "card_id": card_id})
	c2._apply_dev_edit(op, {"target": target, "card_id": card_id})
	await _pump(2)
	var hplayer = h.battle.context.game_state.players.get(target)
	if hplayer == null:
		return &""
	var hhand: Array = hplayer.action_hand if String(op) == &"add_action_card" else hplayer.equipment_hand
	if hhand.is_empty():
		return &""
	var hid: StringName = hhand[hhand.size() - 1]
	var c1hand: Array = c1.battle.context.game_state.players.get(target).action_hand if String(op) == &"add_action_card" else c1.battle.context.game_state.players.get(target).equipment_hand
	var c2hand: Array = c2.battle.context.game_state.players.get(target).action_hand if String(op) == &"add_action_card" else c2.battle.context.game_state.players.get(target).equipment_hand
	if c1hand.is_empty() or c2hand.is_empty():
		return &""
	if c1hand[c1hand.size() - 1] != hid or c2hand[c2hand.size() - 1] != hid:
		return &""
	return hid


## host 发 op + 手动喂2个 client（星型中继）
func _exec3(h, c1, c2, op: String, data: Dictionary, frames: int = 3) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c1._apply_remote_input(op, data)
	c2._apply_remote_input(op, data)
	await _pump(frames)


## 3端对 target 施加联合状态
func _apply_unite_3(app_roots: Array, target_mech_id: StringName, unite_mech_id: StringName, source_pid: StringName) -> void:
	for app in app_roots:
		app.battle.context.game_actions.add_status({
			"target_id": target_mech_id,
			"status": {
				"type": &"UNITE",
				"duration": &"UNTIL_TURN_END",
				"unite": unite_mech_id,
				"source_player_id": source_pid,
			},
		})


## 在单端应用一个 op（host 走 _net_exec，client 走 _apply_remote_input）。
## 0825 改版（同双端版 _combo_drive 的失步根因修复）：SETTLE 优先级链（反击30/联合20/
## 闪击10）的 deferred 续跑在各端交错顺序不同，动作计数器会发散，按 host 槽位广播的
## 未定向 op（ui_confirmed/damage_place）会错投递到落后端持有槽位的其它挂起动作。
## 各端自驱 = 真实多人局模型：每个玩家只点自己屏幕上的窗，动作各自在本端结算。
func _apply_one(app, is_host: bool, op: String, data: Dictionary) -> void:
	if is_host:
		app._net_exec(op, data)
	else:
		app._apply_remote_input(op, data)


## 应答单端当前等待输入（op 只在本端应用；返回错误串，空=成功/未知类型不处理）
func _answer_one_end(app, is_host: bool, cfg: Dictionary) -> String:
	var wi: Dictionary = app.battle.context.action_ui_bridge.get_waiting_action_info()
	var it: StringName = wi.get("input_type", &"")
	var aid: StringName = wi.get("action_id", &"")
	var params: Dictionary = wi.get("input_params", {})
	if it == &"select_weapon":
		var attacker: StringName = params.get("attacker_id", &"")
		var wid: StringName = cfg["enemy_weapon"] if String(attacker) == String(cfg["enemy_mech"]) else cfg["player_weapon"]
		_apply_one(app, is_host, "ui_confirmed", {"data": {"weapon_id": wid}})
	elif it == &"select_attack_target":
		var attacker: StringName = params.get("attacker_id", &"")
		var tid: StringName = cfg["player_mech"] if String(attacker) == String(cfg["enemy_mech"]) else cfg["enemy_mech"]
		_apply_one(app, is_host, "ui_confirmed", {"data": {"target_id": tid}})
	elif it == &"place_damage_tokens":
		# 损伤放置：用本端自己的合法槽位表逐枚放置，再按本端动作 id 精确恢复
		# （damage_placement_done 按 id 路由，不依赖共享槽与跨端动作 id 一致）
		var amount: int = int(params.get("amount", 0))
		var mech_ids: Array = params.get("mech_ids", [])
		var target_mech: StringName = mech_ids[0] if not mech_ids.is_empty() else &""
		if amount > 0 and target_mech != &"":
			var slots: Array = app.battle.context.damage_token_service.get_valid_damage_slots(target_mech)
			if slots.is_empty():
				return "无可用损伤槽位（amount=%d target=%s）" % [amount, String(target_mech)]
			for j in amount:
				_apply_one(app, is_host, "damage_place", {"slot_id": slots[j % slots.size()], "target_mech_id": target_mech})
				await _pump(1)
		_apply_one(app, is_host, "damage_placement_done", {"action_id": aid})
		await _pump(2)
	elif it == &"select_move_target":
		_apply_one(app, is_host, "ui_cancelled", {})
	return ""


## 通用组合驱动（各端自驱版，同双端版）：每轮泵帧后依次独立应答 3 端各自的等待输入
func _combo_drive_3(h, c1, c2, cfg: Dictionary) -> String:
	var guard: int = 0
	while guard < 150:
		guard += 1
		await _pump(2)
		var h_act: int = h.battle.context.action_registry.get_active_count()
		var c1_act: int = c1.battle.context.action_registry.get_active_count()
		var c2_act: int = c2.battle.context.action_registry.get_active_count()
		if h_act == 0 and c1_act == 0 and c2_act == 0:
			return ""
		# ── 引擎级挂起（响应窗口时点 / TimingEngine 待决效果）：各端引擎都持有同一挂起，
		# 同一 op 必须广播 3 端（per-end 只应答本端会让对端永久挂起）。动作 id 取持有窗口
		# 槽一端的值（这些窗口挂在早段创建的动作上，各端 id 一致，广播安全）。
		# 覆盖：respond_attack / select_unite_attack_card / select_thrust_cards /
		# select_discard_cards（闪击 optional 弃牌）。
		var bw: Dictionary = {}
		var bw_app = null
		var bw_it: StringName = &""
		for pair0 in [[h, true], [c1, false], [c2, false]]:
			var t0: StringName = _wait_input_type(pair0[0])
			if t0 == &"respond_attack" or t0 == &"select_unite_attack_card" or t0 == &"select_thrust_cards" or t0 == &"select_discard_cards":
				bw_app = pair0[0]
				bw_it = t0
				bw = pair0[0].battle.context.action_ui_bridge.get_waiting_action_info()
				break
		if bw_app != null:
			var bw_aid: StringName = bw.get("action_id", &"")
			if bw_it == &"respond_attack":
				# 响应窗口 pass：按持槽端 registry 记录的 eligible 玩家逐个 pass（全 pass 才关窗）
				var rw_atk = bw_app.battle.context.action_registry.get_action(bw_aid)
				var rw_eligible: Array = rw_atk.record.get("_response_eligible_players", []) if rw_atk != null else []
				if rw_eligible.is_empty():
					await _exec3(h, c1, c2, "respond_attack", {"action_id": bw_aid, "pass": true})
				else:
					for pid2: StringName in rw_eligible:
						await _exec3(h, c1, c2, "respond_attack", {"action_id": bw_aid, "pass": true, "player_id": String(pid2)})
			elif bw_it == &"select_unite_attack_card":
				await _exec3(h, c1, c2, "resume_effect", {"action_id": bw_aid, "data": {"selected_card_id": cfg["unite_atk"]}})
			elif bw_it == &"select_thrust_cards":
				# 推进多选窗（E 初始手牌可能含推进牌，打出迎击牌时按规则弹出）：取消不打
				await _exec3(h, c1, c2, "resume_effect", {"action_id": bw_aid, "data": {"cancelled": true}})
			else:
				# 闪击 optional 弃牌（count=1）：弃 fodder
				await _exec3(h, c1, c2, "resume_effect", {"action_id": bw_aid, "data": {"selected_action_card_ids": [cfg["fodder"]]}})
			continue
		# ── 其余输入类型：各端动作独立挂 need_input，per-end 自驱安全。
		var answered: bool = false
		for pair in [[h, true], [c1, false], [c2, false]]:
			var app = pair[0]
			if _wait_input_type(app) == &"":
				continue
			var err: String = await _answer_one_end(app, pair[1], cfg)
			if err != "":
				return "驱动失败(%s): %s" % ["host" if pair[1] else "client", err]
			answered = true
		if not answered:
			# 各端均无等待输入但有进行中动作：deferred 链推进中，泵帧等待（guard 兜底）
			continue
	var diag: Array = []
	for label_and_app in [["H", h], ["C1", c1], ["C2", c2]]:
		var app = label_and_app[1]
		for aid3: StringName in app.battle.context.action_registry.get_active_ids():
			var a3 = app.battle.context.action_registry.get_action(aid3)
			if a3 != null:
				diag.append("%s:%s(%s)%s" % [String(label_and_app[0]), String(a3.action_id), String(a3.action_type), String(a3.state)])
	return "驱动 guard 耗尽：h=%d c1=%d c2=%d pend=%s" % [
		h.battle.context.action_registry.get_active_count(),
		c1.battle.context.action_registry.get_active_count(),
		c2.battle.context.action_registry.get_active_count(),
		str(diag)]


# ═══════════════════════════════════════════
# 测试：闪击+反击+联合 三效果 3端锁步全链
# ═══════════════════════════════════════════

func test_pvp3_lockstep_triple_effect_combo_sync() -> Variant:
	var seed_val := 2026
	var host = await _build_pvp3_app_root(seed_val, &"player")
	var client1 = await _build_pvp3_app_root(seed_val, &"enemy")
	var client2 = await _build_pvp3_app_root(seed_val, &"third")
	if host == null or client1 == null or client2 == null:
		await _free3(host, client1, client2)
		return "建局失败"
	var hg = host.battle.context.game_state
	var g1 = client1.battle.context.game_state
	var g2 = client2.battle.context.game_state
	hg.active_player_id = &"player"
	g1.active_player_id = &"player"
	g2.active_player_id = &"player"
	var player_mech = hg.get_mech_for_player(&"player")
	var enemy_mech = hg.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		await _free3(host, client1, client2)
		return "机甲缺失"
	# 敌我相邻（3端同设；third 位置保持 start_pvp3 默认）
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	g1.get_mech_for_player(&"player").position = {"q": 5, "r": 0}
	g1.get_mech_for_player(&"enemy").position = {"q": 6, "r": 0}
	g2.get_mech_for_player(&"player").position = {"q": 5, "r": 0}
	g2.get_mech_for_player(&"enemy").position = {"q": 6, "r": 0}
	# E 动力清零（反击移动 X=0：请求选格后取消）
	enemy_mech.power = 0
	g1.get_mech_for_player(&"enemy").power = 0
	g2.get_mech_for_player(&"enemy").power = 0
	var pw_ids: Array[StringName] = player_mech.get_weapon_ids()
	var ew_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if pw_ids.is_empty() or ew_ids.is_empty():
		await _free3(host, client1, client2)
		return "机甲无武器"

	# P 手牌：闪击 + 进攻×2；E 手牌：反击 + 进攻（联合用）
	var flash_id: StringName = await _dev_add_card_3(host, client1, client2, &"add_action_card", &"player", "action_006_闪击")
	var fodder1: StringName = await _dev_add_card_3(host, client1, client2, &"add_action_card", &"player", "action_001_进攻")
	var fodder2: StringName = await _dev_add_card_3(host, client1, client2, &"add_action_card", &"player", "action_001_进攻")
	var counter_id: StringName = await _dev_add_card_3(host, client1, client2, &"add_action_card", &"enemy", "action_010_反击")
	var unite_atk_id: StringName = await _dev_add_card_3(host, client1, client2, &"add_action_card", &"enemy", "action_001_进攻")
	if flash_id == &"" or fodder1 == &"" or fodder2 == &"" or counter_id == &"" or unite_atk_id == &"":
		await _free3(host, client1, client2)
		return "3端加牌失败 flash=%s f1=%s f2=%s counter=%s unite=%s" % [String(flash_id), String(fodder1), String(fodder2), String(counter_id), String(unite_atk_id)]

	# E 施加联合状态（unite=P，3端同参数）
	_apply_unite_3([host, client1, client2], enemy_mech.mech_id, player_mech.mech_id, &"player")

	# ── P 打出闪击 -> 攻击A ──
	await _exec3(host, client1, client2, "play_action_card", {"player_id": &"player", "card_instance_id": flash_id})
	if _wait_input_type(host) != &"select_weapon":
		await _free3(host, client1, client2)
		return "打出闪击后 host 未暂停 select_weapon: %s" % String(_wait_input_type(host))
	# ── 选武器 -> 选目标 E -> 响应窗口 ──
	await _exec3(host, client1, client2, "ui_confirmed", {"data": {"weapon_id": pw_ids[0]}})
	if _wait_input_type(host) != &"select_attack_target":
		await _free3(host, client1, client2)
		return "选武器后 host 未暂停 select_attack_target: %s" % String(_wait_input_type(host))
	await _exec3(host, client1, client2, "ui_confirmed", {"data": {"target_id": enemy_mech.mech_id}})
	if _wait_input_type(host) != &"respond_attack":
		await _free3(host, client1, client2)
		return "选目标后 host 未暂停 respond_attack: %s" % String(_wait_input_type(host))

	# ── E(client1) 响应窗口打出反击 ──
	var resp_aid: StringName = _wait_action_id(host)
	await _exec3(host, client1, client2, "respond_attack", {"action_id": resp_aid, "card_instance_id": counter_id, "effect_id": "counter_availability", "pass": false})

	# ── 其余全链通用驱动 ──
	var cfg := {
		"player_weapon": pw_ids[0],
		"enemy_weapon": ew_ids[0],
		"player_mech": player_mech.mech_id,
		"enemy_mech": enemy_mech.mech_id,
		"fodder": fodder1,
		"unite_atk": unite_atk_id,
	}
	var drive_err: String = await _combo_drive_3(host, client1, client2, cfg)
	if drive_err != "":
		await _free3(host, client1, client2)
		return "组合驱动失败: %s" % drive_err
	await _pump(6)

	# ═══ 终态断言 ═══
	# 1) 3端无孤儿动作
	for label_and_app in [["host", host], ["client1", client1], ["client2", client2]]:
		var act: int = label_and_app[1].battle.context.action_registry.get_active_count()
		if act != 0:
			await _free3(host, client1, client2)
			return "%s 有 %d 个孤儿动作" % [String(label_and_app[0]), act]
	# 2) 3端 HP/位置一致（全部玩家）
	for pid: StringName in hg.players:
		var hm = hg.get_mech_for_player(pid)
		var m1 = g1.get_mech_for_player(pid)
		var m2 = g2.get_mech_for_player(pid)
		if hm == null or m1 == null or m2 == null:
			await _free3(host, client1, client2)
			return "%s 机甲缺失" % String(pid)
		if hm.current_hp != m1.current_hp or hm.current_hp != m2.current_hp:
			await _free3(host, client1, client2)
			return "%s HP 3端不一致 h=%d c1=%d c2=%d" % [String(pid), hm.current_hp, m1.current_hp, m2.current_hp]
		if hm.position != m1.position or hm.position != m2.position:
			await _free3(host, client1, client2)
			return "%s 位置 3端不一致" % String(pid)
	# 3) 3端手牌一致
	for pid: StringName in hg.players:
		if hg.players.get(pid).action_hand != g1.players.get(pid).action_hand \
				or hg.players.get(pid).action_hand != g2.players.get(pid).action_hand:
			await _free3(host, client1, client2)
			return "%s 手牌 3端不一致" % String(pid)
	# 4) 3端牌堆/弃牌堆一致
	if hg.deck_state.action_deck != g1.deck_state.action_deck or hg.deck_state.action_deck != g2.deck_state.action_deck:
		await _free3(host, client1, client2)
		return "行动牌堆 3端不一致"
	if hg.deck_state.action_discard_pile != g1.deck_state.action_discard_pile or hg.deck_state.action_discard_pile != g2.deck_state.action_discard_pile:
		await _free3(host, client1, client2)
		return "行动弃牌堆 3端不一致"
	# 5) 行为断言（host 为准）：联合状态清除 / 闪弃牌已弃 / 反击与联合牌已打出
	var e_status_unite: bool = false
	for s: Dictionary in enemy_mech.statuses:
		if s.get("type", &"") == &"UNITE":
			e_status_unite = true
			break
	if e_status_unite:
		await _free3(host, client1, client2)
		return "联合攻击C 结算后联合状态应被清除"
	if hg.players.get(&"player").action_hand.has(fodder1):
		await _free3(host, client1, client2)
		return "闪击弃牌 fodder1 应已弃置"
	if not hg.players.get(&"player").action_hand.has(fodder2):
		await _free3(host, client1, client2)
		return "fodder2 不应被误弃"
	if hg.players.get(&"enemy").action_hand.has(counter_id) or hg.players.get(&"enemy").action_hand.has(unite_atk_id):
		await _free3(host, client1, client2)
		return "反击/联合进攻牌应已打出弃置"
	await _free3(host, client1, client2)
	return true
