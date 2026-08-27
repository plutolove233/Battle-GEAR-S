## test_pvp_lockstep_attack_combo.gd - PvP 锁步「闪击+反击+联合」三效果组合同步验证
##
## 用户裁定优先级（ATTACK_SETTLE 上）：反击额外攻击=30、联合连携攻击=20、闪击再次攻击=10。
## 本测试在 PvP 双 app_root（host=player, client=enemy）下用真实网络 op 全链驱动一次攻击
## 同时挂三效果：P 打出闪击发起攻击A，E 用反击响应（counter_effect2 创建反击攻击B），
## E 身上有联合状态（unite=P，unite_status_attack 弹联合窗选进攻牌打出联合攻击C），
## P 闪击效果2 弃1张进攻牌再攻击（闪击攻击D）。
##
## 全部走 _net_exec/_apply_remote_input 的网络 op（play_action_card/ui_confirmed/
## respond_attack/resume_effect/damage_place/ui_cancelled），模拟真实双端输入交换，
## 断言：全链完成后双端无孤儿动作、HP/位置/手牌/牌堆/弃牌堆一致、联合状态清除、
## 闪击弃牌已弃、反击/联合牌已打出弃置。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")


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


func _build_pvp_app_root(seed_val: int, local_pid: StringName):
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		return null
	app_root.game_mode = &"PVP"
	app_root.local_player_id = local_pid
	app_root.is_network_client = (String(local_pid) == &"enemy")
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = seed_val
	var r = app_root.battle.start_tutorial(app_root.registry)
	if not app_root._status_ok(r):
		return null
	var ep = app_root.battle.context.game_state.players.get(&"enemy")
	if ep != null:
		ep.is_human = true
	app_root.battle.start_turn(&"player")
	app_root._show_battle()
	await _pump(2)
	return app_root


const _BattleState = preload("res://scripts/battle/battle_state.gd")


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


## 双端 dev_add 同一张牌，返回 instance_id（双端计数器同序 => 同 id）
func _dev_add_card_both(host, client, op: StringName, target: StringName, card_id: String) -> StringName:
	host._apply_dev_edit(op, {"target": target, "card_id": card_id})
	client._apply_dev_edit(op, {"target": target, "card_id": card_id})
	await _pump(2)
	var hplayer = host.battle.context.game_state.players.get(target)
	var cplayer = client.battle.context.game_state.players.get(target)
	if hplayer == null or cplayer == null:
		return &""
	var hhand: Array = hplayer.action_hand if String(op) == &"add_action_card" else hplayer.equipment_hand
	var chand: Array = cplayer.action_hand if String(op) == &"add_action_card" else cplayer.equipment_hand
	if hhand.is_empty() or chand.is_empty():
		return &""
	var hid: StringName = hhand[hhand.size() - 1]
	var cid: StringName = chand[chand.size() - 1]
	if hid != cid:
		return &""
	return hid


## host 发 op + 手动喂 client（模拟 host 广播 -> client 应用）
func _exec2(h, c, op: String, data: Dictionary, frames: int = 3) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c._apply_remote_input(op, data)
	await _pump(frames)


## 双端对 target 施加联合状态（unite=unite_mech；同 test_unite_pvp_parallel._apply_unite_both）
func _apply_unite_both(host, client, target_mech_id: StringName, unite_mech_id: StringName, source_pid: StringName) -> void:
	for app in [host, client]:
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
## 0825 改版：驱动从「host 等待槽派生 op 广播双端」改为「各端按自身等待槽独立应答」：
## SETTLE 优先级链（反击30/联合20/闪击10）的 deferred 续跑在双端交错顺序不同，
## 动作计数器会发散（实测 host action_22=hp_change / client action_22=discard_card），
## 按 host 槽位广播的未定向 op（ui_confirmed 的 placed:true / damage_place）会错投递
## 到落后端当时持有槽位的其它动作（攻击D host-7/client-9 失步根因：placed:true 错投
## 到闪击再攻击的 select_target + 2 枚 stray damage_place 使 client 敌机甲护甲-2）。
## 各端自驱 = 真实双人局模型：每个玩家只点自己屏幕上的窗，动作各自在本端结算。
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


## 通用组合驱动（各端自驱版）：每轮泵帧后依次独立应答 host / client 各自的等待输入，
## 直到双端无进行中动作。cfg: {player_weapon, enemy_weapon, player_mech, enemy_mech, fodder, unite_atk}
## 覆盖 input 类型：select_weapon / select_attack_target / respond_attack(pass) /
## place_damage_tokens / select_unite_attack_card / select_discard_cards(闪击optional) /
## select_thrust_cards(推进多选取消) / select_move_target(取消)。
func _combo_drive(h, c, cfg: Dictionary) -> String:
	var guard: int = 0
	while guard < 150:
		guard += 1
		await _pump(2)
		var h_act: int = h.battle.context.action_registry.get_active_count()
		var c_act: int = c.battle.context.action_registry.get_active_count()
		if h_act == 0 and c_act == 0:
			return ""
		# ── 引擎级挂起（响应窗口时点 / TimingEngine 待决效果）：各端引擎都持有同一挂起，
		# 同一 op 必须广播双端（per-end 只应答本端会让对端永久挂起）。动作 id 取持有窗口
		# 槽一端的值（这些窗口挂在早段创建的动作上，双端 id 一致，广播安全）。
		# 覆盖：respond_attack / select_unite_attack_card / select_thrust_cards /
		# select_discard_cards（闪击 optional 弃牌）。
		var bw: Dictionary = {}
		var bw_app = null
		var bw_it: StringName = &""
		for pair0 in [[h, true], [c, false]]:
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
					await _exec2(h, c, "respond_attack", {"action_id": bw_aid, "pass": true})
				else:
					for pid2: StringName in rw_eligible:
						await _exec2(h, c, "respond_attack", {"action_id": bw_aid, "pass": true, "player_id": String(pid2)})
			elif bw_it == &"select_unite_attack_card":
				await _exec2(h, c, "resume_effect", {"action_id": bw_aid, "data": {"selected_card_id": cfg["unite_atk"]}})
			elif bw_it == &"select_thrust_cards":
				# 推进多选窗（E 初始手牌可能含推进牌，打出迎击牌时按规则弹出）：取消不打
				await _exec2(h, c, "resume_effect", {"action_id": bw_aid, "data": {"cancelled": true}})
			else:
				# 闪击 optional 弃牌（count=1）：弃 fodder（同 optional 分支的 selected_action_card_ids）
				await _exec2(h, c, "resume_effect", {"action_id": bw_aid, "data": {"selected_action_card_ids": [cfg["fodder"]]}})
			continue
		# ── 其余输入类型（select_weapon / select_attack_target / place_damage_tokens /
		# select_move_target）：各端动作独立挂 need_input，per-end 自驱安全。
		var answered: bool = false
		for pair in [[h, true], [c, false]]:
			var app = pair[0]
			if _wait_input_type(app) == &"":
				continue
			var err: String = await _answer_one_end(app, pair[1], cfg)
			if err != "":
				return "驱动失败(%s): %s" % ["host" if pair[1] else "client", err]
			answered = true
		if not answered:
			# 双端均无等待输入但有进行中动作：deferred 链推进中，泵帧等待（guard 兜底）
			continue
	# 诊断：列出双端挂起动作（type/state/record 摘要）
	var diag: Array = []
	for pair2 in [[&"H", h], [&"C", c]]:
		for aid3: StringName in pair2[1].battle.context.action_registry.get_active_ids():
			var a3 = pair2[1].battle.context.action_registry.get_action(aid3)
			if a3 != null:
				diag.append("%s:%s(%s)%s r=%s" % [String(pair2[0]), String(a3.action_id), String(a3.action_type), String(a3.state), str(a3.record).substr(0, 160)])
	return "驱动 guard 耗尽：h_act=%d c_act=%d pend=%s" % [
		h.battle.context.action_registry.get_active_count(),
		c.battle.context.action_registry.get_active_count(),
		str(diag)]


# ═══════════════════════════════════════════
# 测试：闪击+反击+联合 三效果 PvP 锁步全链
# ═══════════════════════════════════════════

func test_lockstep_triple_effect_combo_sync() -> Variant:
	var seed_val := 2026
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host)
		await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	var cg = client.battle.context.game_state
	hg.active_player_id = &"player"
	cg.active_player_id = &"player"
	var player_mech = hg.get_mech_for_player(&"player")
	var enemy_mech = hg.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		await _free_app_root(host)
		await _free_app_root(client)
		return "机甲缺失"
	# 敌我相邻（双端同设）
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	cg.get_mech_for_player(&"player").position = {"q": 5, "r": 0}
	cg.get_mech_for_player(&"enemy").position = {"q": 6, "r": 0}
	# E 动力清零（反击 counter_effect1 半动力移动 X=0：请求选格后取消结束）
	enemy_mech.power = 0
	cg.get_mech_for_player(&"enemy").power = 0
	var pw_ids: Array[StringName] = player_mech.get_weapon_ids()
	var ew_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if pw_ids.is_empty() or ew_ids.is_empty():
		await _free_app_root(host)
		await _free_app_root(client)
		return "机甲无武器"

	# P 手牌：闪击 + 进攻（fodder 弃牌用 + 留牌断言用）
	var flash_id: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"player", "action_006_闪击")
	var fodder1: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"player", "action_001_进攻")
	var fodder2: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"player", "action_001_进攻")
	# E 手牌：反击 + 进攻（联合连携用）
	var counter_id: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"enemy", "action_010_反击")
	var unite_atk_id: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"enemy", "action_001_进攻")
	if flash_id == &"" or fodder1 == &"" or fodder2 == &"" or counter_id == &"" or unite_atk_id == &"":
		await _free_app_root(host)
		await _free_app_root(client)
		return "双端加牌失败 flash=%s f1=%s f2=%s counter=%s unite=%s" % [String(flash_id), String(fodder1), String(fodder2), String(counter_id), String(unite_atk_id)]

	# E 施加联合状态（unite=P：P 攻击结算时 E 可联合攻击，双端同参数）
	_apply_unite_both(host, client, enemy_mech.mech_id, player_mech.mech_id, &"player")

	# ── P 打出闪击 -> 攻击A ──
	await _exec2(host, client, "play_action_card", {"player_id": &"player", "card_instance_id": flash_id})
	if _wait_input_type(host) != &"select_weapon":
		await _free_app_root(host)
		await _free_app_root(client)
		return "打出闪击后 host 未暂停 select_weapon: %s" % String(_wait_input_type(host))
	if _wait_input_type(client) != &"select_weapon":
		await _free_app_root(host)
		await _free_app_root(client)
		return "打出闪击后 client 未暂停 select_weapon: %s" % String(_wait_input_type(client))

	# ── 选武器 -> 选目标 E -> 响应窗口 ──
	await _exec2(host, client, "ui_confirmed", {"data": {"weapon_id": pw_ids[0]}})
	if _wait_input_type(host) != &"select_attack_target":
		await _free_app_root(host)
		await _free_app_root(client)
		return "选武器后 host 未暂停 select_attack_target: %s" % String(_wait_input_type(host))
	await _exec2(host, client, "ui_confirmed", {"data": {"target_id": enemy_mech.mech_id}})
	if _wait_input_type(host) != &"respond_attack":
		await _free_app_root(host)
		await _free_app_root(client)
		return "选目标后 host 未暂停 respond_attack: %s" % String(_wait_input_type(host))

	# ── E(client) 响应窗口打出反击（counter_availability 是 AVAILABILITY 效果）──
	var resp_aid: StringName = _wait_action_id(host)
	await _exec2(host, client, "respond_attack", {"action_id": resp_aid, "card_instance_id": counter_id, "effect_id": "counter_availability", "pass": false})
	# 反击打出后 counter_effect1 移动循环（power=0 首次仍请求选格）-> 由通用驱动取消

	# ── 其余全链通用驱动（反击移动取消/损伤/反击攻击B/联合弹窗/闪弃牌/再攻击D/联合攻击C）──
	var cfg := {
		"player_weapon": pw_ids[0],
		"enemy_weapon": ew_ids[0],
		"player_mech": player_mech.mech_id,
		"enemy_mech": enemy_mech.mech_id,
		"fodder": fodder1,
		"unite_atk": unite_atk_id,
	}
	var drive_err: String = await _combo_drive(host, client, cfg)
	if drive_err != "":
		await _free_app_root(host)
		await _free_app_root(client)
		return "组合驱动失败: %s" % drive_err
	await _pump(6)

	# ═══ 终态断言 ═══
	# 1) 双端无孤儿动作
	var h_active: int = host.battle.context.action_registry.get_active_count()
	var c_active: int = client.battle.context.action_registry.get_active_count()
	if h_active != 0 or c_active != 0:
		await _free_app_root(host)
		await _free_app_root(client)
		return "孤儿动作 host=%d client=%d" % [h_active, c_active]
	# 2) 双端 HP/位置一致
	for pid: StringName in [&"player", &"enemy"]:
		var hm = hg.get_mech_for_player(pid)
		var cm = cg.get_mech_for_player(pid)
		if hm.current_hp != cm.current_hp:
			await _free_app_root(host)
			await _free_app_root(client)
			return "%s HP 不一致 host=%d client=%d" % [String(pid), hm.current_hp, cm.current_hp]
		if hm.position != cm.position:
			await _free_app_root(host)
			await _free_app_root(client)
			return "%s 位置不一致 host=%s client=%s" % [String(pid), str(hm.position), str(cm.position)]
	# 3) 双端手牌一致
	if hg.players.get(&"player").action_hand != cg.players.get(&"player").action_hand:
		await _free_app_root(host)
		await _free_app_root(client)
		return "player 手牌不一致 host=%s client=%s" % [str(hg.players.get(&"player").action_hand), str(cg.players.get(&"player").action_hand)]
	if hg.players.get(&"enemy").action_hand != cg.players.get(&"enemy").action_hand:
		await _free_app_root(host)
		await _free_app_root(client)
		return "enemy 手牌不一致 host=%s client=%s" % [str(hg.players.get(&"enemy").action_hand), str(cg.players.get(&"enemy").action_hand)]
	# 4) 双端牌堆/弃牌堆一致
	if hg.deck_state.action_deck != cg.deck_state.action_deck:
		await _free_app_root(host)
		await _free_app_root(client)
		return "行动牌堆不一致"
	if hg.deck_state.action_discard_pile != cg.deck_state.action_discard_pile:
		await _free_app_root(host)
		await _free_app_root(client)
		return "行动弃牌堆不一致"
	# 5) 关键行为断言（以 host 为准，client 由一致性覆盖）
	# 联合状态清除（联合攻击C 结算 REMOVE_STATUS）
	var e_status_unite: bool = false
	for s: Dictionary in enemy_mech.statuses:
		if s.get("type", &"") == &"UNITE":
			e_status_unite = true
			break
	if e_status_unite:
		await _free_app_root(host)
		await _free_app_root(client)
		return "联合攻击C 结算后联合状态应被清除"
	# 闪击弃牌已弃、fodder2 保留
	if hg.players.get(&"player").action_hand.has(fodder1):
		await _free_app_root(host)
		await _free_app_root(client)
		return "闪击弃牌 fodder1 应已弃置"
	if not hg.players.get(&"player").action_hand.has(fodder2):
		await _free_app_root(host)
		await _free_app_root(client)
		return "fodder2 不应被误弃"
	# 反击牌/联合进攻牌已打出（不在手牌）
	if hg.players.get(&"enemy").action_hand.has(counter_id):
		await _free_app_root(host)
		await _free_app_root(client)
		return "反击牌应已打出弃置"
	if hg.players.get(&"enemy").action_hand.has(unite_atk_id):
		await _free_app_root(host)
		await _free_app_root(client)
		return "联合进攻牌应已打出弃置"
	# 闪击牌本身已弃置（打出链完成）
	var h_flash_card = hg.get_card(flash_id)
	if h_flash_card != null and String(h_flash_card.zone) == &"temp_zone":
		await _free_app_root(host)
		await _free_app_root(client)
		return "闪击牌不应滞留临时区"
	await _free_app_root(host)
	await _free_app_root(client)
	return true
