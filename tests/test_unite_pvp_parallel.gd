## test_unite_pvp_parallel.gd - 联合攻击 PvP 并行结算验证
##
## 复现用户报告的 PvP 串行 bug：联合弹窗确认后，攻击牌A 应立即弃置、攻击牌B 进临时区，
## 不等攻击B 结算。单进程动作引擎已验证并行（test_unite_parallel_settlement），
## 本测试在 PvP 双 app_root（host=player, client=enemy）下复现/验证。
##
## 场景：player(unite机甲) 打 attack牌A 攻 enemy(Target) -> ATTACK_SETTLE 联合弹窗
##   路由给 Target=enemy=client -> client 选 attack牌B -> resume_effect 双端应用 ->
##   断言：攻击牌A 双端弃置、攻击牌B 双端进临时区、attackB 双端等待 select_weapon。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")


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


## 双端对 Target 施加联合状态（unite=unite_mech）
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


func _drain_damage_placement(host, client, target_mech_id: StringName) -> String:
	for _i in 20:
		var ht: StringName = _wait_input_type(host)
		if ht != &"place_damage_tokens":
			break
		var hwi: Dictionary = host.battle.context.action_ui_bridge.get_waiting_action_info()
		var amount: int = int(hwi.get("input_params", {}).get("amount", 0))
		var slots: Array = host.battle.context.damage_token_service.get_valid_damage_slots(target_mech_id)
		if slots.is_empty():
			return "无可用损伤槽位（amount=%d）" % amount
		for j in amount:
			var slot_id: StringName = slots[j % slots.size()]
			host._net_exec("damage_place", {"slot_id": slot_id, "target_mech_id": target_mech_id})
			client._apply_remote_input("damage_place", {"slot_id": slot_id, "target_mech_id": target_mech_id})
			await _pump(2)
		host._net_exec("ui_confirmed", {"data": {"placed": true}})
		client._apply_remote_input("ui_confirmed", {"data": {"placed": true}})
		await _pump(4)
	return ""


## ═══════════════════════════════════════════
## 测试：PvP 联合攻击并行结算
## ═══════════════════════════════════════════
func test_unite_pvp_parallel_settlement() -> Variant:
	var seed_val := 777
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	var cg = client.battle.context.game_state
	hg.active_player_id = &"player"
	cg.active_player_id = &"player"
	var player_mech = hg.get_mech_for_player(&"player")
	var enemy_mech = hg.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		await _free_app_root(host); await _free_app_root(client)
		return "机甲缺失"
	# 敌我相邻
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	cg.get_mech_for_player(&"player").position = {"q": 5, "r": 0}
	cg.get_mech_for_player(&"enemy").position = {"q": 6, "r": 0}
	var weapon_ids: Array[StringName] = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		await _free_app_root(host); await _free_app_root(client)
		return "玩家无机甲武器"
	var weapon_id: StringName = weapon_ids[0]

	# card A：player(unite机甲) 的攻击牌；card B：enemy(Target) 的攻击牌（联合诱导打出）
	var card_a: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"player", "action_001_进攻")
	if card_a == &"":
		await _free_app_root(host); await _free_app_root(client)
		return "双端加 player 进攻牌失败或 id 不同步"
	var card_b: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"enemy", "action_001_进攻")
	if card_b == &"":
		await _free_app_root(host); await _free_app_root(client)
		return "双端加 enemy 进攻牌失败或 id 不同步"

	# 施加联合状态：Target=enemy_mech，unite=player_mech（双端）
	_apply_unite_both(host, client, enemy_mech.mech_id, player_mech.mech_id, &"player")

	# ① player 打攻击牌 A -> 双端 select_weapon
	host._net_exec("play_action_card", {"player_id": &"player", "card_instance_id": card_a})
	await _pump(3)
	client._apply_remote_input("play_action_card", {"player_id": &"player", "card_instance_id": card_a})
	await _pump(3)
	if _wait_input_type(host) != &"select_weapon" or _wait_input_type(client) != &"select_weapon":
		await _free_app_root(host); await _free_app_root(client)
		return "打攻击牌后未暂停 select_weapon (host=%s client=%s)" % [String(_wait_input_type(host)), String(_wait_input_type(client))]

	# ② 选武器 -> select_attack_target
	host._net_exec("ui_confirmed", {"data": {"weapon_id": weapon_id}})
	await _pump(3)
	client._apply_remote_input("ui_confirmed", {"data": {"weapon_id": weapon_id}})
	await _pump(3)

	# ③ 选目标(enemy_mech) -> respond_attack（Target=enemy=client 路由）
	host._net_exec("ui_confirmed", {"data": {"target_id": enemy_mech.mech_id}})
	await _pump(3)
	client._apply_remote_input("ui_confirmed", {"data": {"target_id": enemy_mech.mech_id}})
	await _pump(3)

	# ④ 响应窗口 pass（若有）
	if _wait_input_type(host) == &"respond_attack" or _wait_input_type(client) == &"respond_attack":
		var resp_aid: StringName = _wait_action_id(host)
		# 响应窗口路由给 Target=enemy=client，由 client 发起 pass
		client._net_exec("respond_attack", {"action_id": resp_aid, "pass": true})
		await _pump(3)
		host._apply_remote_input("respond_attack", {"action_id": resp_aid, "pass": true})
		await _pump(3)

	# ⑤ 损伤放置（attacker=player=host 放损伤到 enemy）
	var drain_err: String = await _drain_damage_placement(host, client, enemy_mech.mech_id)
	if drain_err != "":
		await _free_app_root(host); await _free_app_root(client)
		return "损伤放置排空失败: %s" % drain_err
	await _pump(4)

	# ⑥ ATTACK_SETTLE -> 联合弹窗 select_unite_attack_card，路由给 Target=enemy=client
	var host_w = _wait_input_type(host)
	var client_w = _wait_input_type(client)
	if host_w != &"select_unite_attack_card" and client_w != &"select_unite_attack_card":
		# 诊断
		await _free_app_root(host); await _free_app_root(client)
		return "未到联合弹窗（host=%s client=%s）" % [String(host_w), String(client_w)]
	# 联合弹窗 action_id = attackA 的 action_id（双端一致）
	var unite_aid: StringName = _wait_action_id(host)
	if unite_aid == &"":
		unite_aid = _wait_action_id(client)
	# client(Target) 选 card_b，发起 resume_effect；host 应用远端
	client._net_exec("resume_effect", {"action_id": unite_aid, "data": {"selected_card_id": card_b}})
	await _pump(3)
	host._apply_remote_input("resume_effect", {"action_id": unite_aid, "data": {"selected_card_id": card_b}})
	await _pump(6)

	# ═══ 关键断言（并行）═══
	# 1) 攻击牌 A 双端弃置（不在临时区）
	var h_card_a = hg.get_card(card_a)
	var c_card_a = cg.get_card(card_a)
	if h_card_a == null or c_card_a == null:
		await _free_app_root(host); await _free_app_root(client)
		return "card_a 实例丢失"
	if String(h_card_a.zone) == &"temp_zone" or String(c_card_a.zone) == &"temp_zone":
		await _free_app_root(host); await _free_app_root(client)
		return "BUG：攻击牌A 仍在临时区（应并行弃置）。host_zone=%s client_zone=%s" % [String(h_card_a.zone), String(c_card_a.zone)]
	if String(h_card_a.zone) != &"discard" or String(c_card_a.zone) != &"discard":
		await _free_app_root(host); await _free_app_root(client)
		return "攻击牌A 应已弃置。host_zone=%s client_zone=%s" % [String(h_card_a.zone), String(c_card_a.zone)]

	# 2) 攻击牌 B 双端在临时区（attackB 未结算）
	var h_card_b = hg.get_card(card_b)
	var c_card_b = cg.get_card(card_b)
	if h_card_b == null or c_card_b == null:
		await _free_app_root(host); await _free_app_root(client)
		return "card_b 实例丢失"
	if String(h_card_b.zone) != &"temp_zone" or String(c_card_b.zone) != &"temp_zone":
		await _free_app_root(host); await _free_app_root(client)
		return "攻击牌B 应在临时区（attackB 未结算）。host_zone=%s client_zone=%s" % [String(h_card_b.zone), String(c_card_b.zone)]

	# 3) attackB 双端等待 select_weapon（联合诱导的新攻击已创建，独立于 attackA）
	if _wait_input_type(host) != &"select_weapon" or _wait_input_type(client) != &"select_weapon":
		await _free_app_root(host); await _free_app_root(client)
		return "attackB 应双端等待 select_weapon（host=%s client=%s）" % [String(_wait_input_type(host)), String(_wait_input_type(client))]

	# 清理：取消 attackB 链
	host._net_exec("ui_cancelled", {})
	client._apply_remote_input("ui_cancelled", {})
	await _pump(4)
	await _free_app_root(host)
	await _free_app_root(client)
	return true
