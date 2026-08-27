## test_pvp3_lockstep_sync.gd - 3人PvP 锁步操作同步验证（阶段7）
##
## 3端对等跑引擎（host=player, client1=enemy, client2=third），同种子 start_pvp3 =>
## 相同初始状态。host 调 _net_exec（本地执行+广播，测试无网络故广播 no-op）发 input，
## 手动把同一 op/data 喂给两个 client 的 _apply_remote_input，断言3端 game_state 关键字段一致。
##
## 覆盖：初始确定性 / 移动 / 结束回合(轮转 player->enemy) / 攻击全流程(选武器+选目标+迎击pass+损伤)。
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


func _free3(h, c1, c2) -> void:
	await _free_app_root(h)
	await _free_app_root(c1)
	await _free_app_root(c2)


## 同种子建 PVP3 局（start_pvp3 -> start_turn(player) -> _show_battle 连信号）。
## local_pid 决定本窗口视角（player=host / enemy,third=client）。3端同 seed => 相同牌堆/初始状态。
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
	# 3玩家均 human（PvP）
	var gs = app_root.battle.context.game_state
	for pid: StringName in gs.players:
		gs.players[pid].is_human = true
	app_root.battle.start_turn(&"player")
	app_root._show_battle()  # _connect_action_signals 连到真实 context
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
	# 校验3端 instance_id 一致
	var c1hand: Array = c1.battle.context.game_state.players.get(target).action_hand if String(op) == &"add_action_card" else c1.battle.context.game_state.players.get(target).equipment_hand
	var c2hand: Array = c2.battle.context.game_state.players.get(target).action_hand if String(op) == &"add_action_card" else c2.battle.context.game_state.players.get(target).equipment_hand
	if c1hand.is_empty() or c2hand.is_empty():
		return &""
	if c1hand[c1hand.size() - 1] != hid or c2hand[c2hand.size() - 1] != hid:
		return &""
	return hid


## host 发 op + 手动喂2个 client（模拟星型中继：host 广播给所有 client）
func _exec3(h, c1, c2, op: String, data: Dictionary, frames: int = 3) -> void:
	h._net_exec(op, data)
	await _pump(frames)
	c1._apply_remote_input(op, data)
	c2._apply_remote_input(op, data)
	await _pump(frames)


# ═══════════════════════════════════════════
# 3端同种子 => 初始状态完全一致（3机甲 HP/位置/牌堆）
# ═══════════════════════════════════════════
func test_pvp3_lockstep_identical_initial_state() -> Variant:
	var seed_val := 777
	var host = await _build_pvp3_app_root(seed_val, &"player")
	var client1 = await _build_pvp3_app_root(seed_val, &"enemy")
	var client2 = await _build_pvp3_app_root(seed_val, &"third")
	if host == null or client1 == null or client2 == null:
		await _free3(host, client1, client2)
		return "建局失败"
	var hg = host.battle.context.game_state
	var cg1 = client1.battle.context.game_state
	var cg2 = client2.battle.context.game_state
	for pid: StringName in [&"player", &"enemy", &"third"]:
		var hm = hg.get_mech_for_player(pid)
		var cm1 = cg1.get_mech_for_player(pid)
		var cm2 = cg2.get_mech_for_player(pid)
		if hm.current_hp != cm1.current_hp or hm.current_hp != cm2.current_hp:
			await _free3(host, client1, client2)
			return "%s 机甲 HP 不一致 h=%d c1=%d c2=%d" % [String(pid), hm.current_hp, cm1.current_hp, cm2.current_hp]
		if hm.position != cm1.position or hm.position != cm2.position:
			await _free3(host, client1, client2)
			return "%s 机甲位置不一致" % String(pid)
	# 同种子洗牌 => 行动牌堆顺序一致（instance_id 同序生成）
	if hg.deck_state.action_deck != cg1.deck_state.action_deck or hg.deck_state.action_deck != cg2.deck_state.action_deck:
		await _free3(host, client1, client2)
		return "行动牌堆顺序不一致（种子确定性失败）"
	await _free3(host, client1, client2)
	return true


# ═══════════════════════════════════════════
# move op：player 移动，3端位置一致
# ═══════════════════════════════════════════
func test_pvp3_lockstep_move_sync() -> Variant:
	var seed_val := 111
	var host = await _build_pvp3_app_root(seed_val, &"player")
	var client1 = await _build_pvp3_app_root(seed_val, &"enemy")
	var client2 = await _build_pvp3_app_root(seed_val, &"third")
	if host == null or client1 == null or client2 == null:
		await _free3(host, client1, client2)
		return "建局失败"
	var hg = host.battle.context.game_state
	var pm = hg.get_mech_for_player(&"player")
	var pos: Dictionary = pm.position
	var cells: Dictionary = hg.map_state.cells if hg.map_state else {}
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(pos, pm.power, cells)
	if reachable.is_empty():
		await _free3(host, client1, client2)
		return "无可达移动格（power=%d）" % pm.power
	var target: Dictionary = reachable[0]
	var tq := int(target.get("q", 0))
	var tr := int(target.get("r", 0))
	await _exec3(host, client1, client2, "move", {"player_id": &"player", "q": tq, "r": tr})
	var hpos: Dictionary = host.battle.context.game_state.get_mech_for_player(&"player").position
	var c1pos: Dictionary = client1.battle.context.game_state.get_mech_for_player(&"player").position
	var c2pos: Dictionary = client2.battle.context.game_state.get_mech_for_player(&"player").position
	if hpos != c1pos or hpos != c2pos:
		await _free3(host, client1, client2)
		return "移动后 player 位置3端不一致 h=%s c1=%s c2=%s" % [str(hpos), str(c1pos), str(c2pos)]
	if int(hpos.get("q", -1)) == int(pos.get("q", -2)) and int(hpos.get("r", -1)) == int(pos.get("r", -2)):
		await _free3(host, client1, client2)
		return "未实际移动"
	await _free3(host, client1, client2)
	return true


# ═══════════════════════════════════════════
# end_turn op：player 结束 -> 轮转到 enemy，3端 active 一致
# ═══════════════════════════════════════════
func test_pvp3_lockstep_end_turn_sync() -> Variant:
	var seed_val := 444
	var host = await _build_pvp3_app_root(seed_val, &"player")
	var client1 = await _build_pvp3_app_root(seed_val, &"enemy")
	var client2 = await _build_pvp3_app_root(seed_val, &"third")
	if host == null or client1 == null or client2 == null:
		await _free3(host, client1, client2)
		return "建局失败"
	await _exec3(host, client1, client2, "end_turn", {"player_id": &"player"}, 4)
	# 手牌超限时流程第5步弹弃牌阻塞窗：选前 N 张（排除保护牌）广播续跑后流程才完成流转
	var dw: Dictionary = host.battle.context.action_ui_bridge.get_waiting_action_info()
	if String(dw.get("input_type", &"")) == &"select_discard_cards":
		var dw_p: int = int(dw.get("input_params", {}).get("count", 0))
		var dw_excl: Array = dw.get("input_params", {}).get("exclude_card_ids", [])
		var dw_hand: Array = host.battle.context.game_state.players.get(&"player").action_hand
		var pick: Array = []
		for cid in dw_hand:
			if pick.size() >= dw_p:
				break
			if dw_excl.has(cid):
				continue
			pick.append(String(cid))
		await _exec3(host, client1, client2, "resume_turn_discard", {
			"action_id": String(dw.get("action_id", &"")),
			"card_ids": pick,
		}, 4)
		await _pump(4)
	var hg2 = host.battle.context.game_state
	var cg1_2 = client1.battle.context.game_state
	var cg2_2 = client2.battle.context.game_state
	if hg2.active_player_id != cg1_2.active_player_id or hg2.active_player_id != cg2_2.active_player_id:
		await _free3(host, client1, client2)
		return "结束后行动方3端不一致 h=%s c1=%s c2=%s" % [String(hg2.active_player_id), String(cg1_2.active_player_id), String(cg2_2.active_player_id)]
	# 3人轮转 player->enemy（非 player->enemy 的2人式）
	if hg2.active_player_id != &"enemy":
		await _free3(host, client1, client2)
		return "结束后未轮转到 enemy active=%s" % String(hg2.active_player_id)
	if hg2.turn_number != cg1_2.turn_number or hg2.turn_number != cg2_2.turn_number:
		await _free3(host, client1, client2)
		return "turn_number 3端不一致 h=%d c1=%d c2=%d" % [hg2.turn_number, cg1_2.turn_number, cg2_2.turn_number]
	await _free3(host, client1, client2)
	return true


# ═══════════════════════════════════════════
# 回合末弃牌含维修 -> 安德洛美达 effect_01b 跨端回收（_net_end_turn 走 deck_service.discard_cards 发时点）
# ═══════════════════════════════════════════
func test_pvp3_lockstep_end_turn_discard_repair_recover() -> Variant:
	var seed_val := 8888
	var host = await _build_pvp3_app_root(seed_val, &"player")
	var client1 = await _build_pvp3_app_root(seed_val, &"enemy")
	var client2 = await _build_pvp3_app_root(seed_val, &"third")
	if host == null or client1 == null or client2 == null:
		await _free3(host, client1, client2)
		return "建局失败"
	# 3端都给 player 设安德洛美达（dev change_pilot，3端同序生成同 instance_id）
	for ar in [host, client1, client2]:
		ar._apply_dev_edit(&"change_pilot", {"target": &"player", "pilot_def_id": "pilot_008_安德洛美达"})
	await _pump(2)
	# 3端都给 player 手牌塞 1维修 + 1强袭（dev add_action_card）
	var repair_id := await _dev_add_card_3(host, client1, client2, &"add_action_card", &"player", "action_013_维修")
	var assault_id := await _dev_add_card_3(host, client1, client2, &"add_action_card", &"player", "action_002_强袭")
	if repair_id == &"" or assault_id == &"":
		await _free3(host, client1, client2)
		return "dev 加牌失败 repair=%s assault=%s" % [String(repair_id), String(assault_id)]
	# 把 player.action_card_limit 调到 0 -> 手牌2张超限，end_turn 必弃2张含维修
	# （用 dev modify_player_limits，3端一致）
	for ar in [host, client1, client2]:
		ar._apply_dev_edit(&"modify_player_limits", {"target": &"player", "action_card_limit": 0})
	await _pump(2)
	# end_turn（无预选）-> 流程第5步超限弹弃牌阻塞窗 -> resume_turn_discard op 弃 [维修, 强袭]
	# -> deck_service.discard_cards 发 DISCARD_SETTLE -> effect_01b 回收维修 -> 续跑流转下家
	await _exec3(host, client1, client2, "end_turn", {"player_id": &"player"}, 4)
	# host 读等待窗动作 id（3端锁步一致），广播选牌续跑
	var dw: Dictionary = host.battle.context.action_ui_bridge.get_waiting_action_info()
	if String(dw.get("input_type", &"")) != &"select_discard_cards":
		await _free3(host, client1, client2)
		return "回合末超限应弹弃牌阻塞窗，实际: %s" % String(dw.get("input_type", &""))
	await _exec3(host, client1, client2, "resume_turn_discard", {
		"action_id": String(dw.get("action_id", &"")),
		"card_ids": [String(repair_id), String(assault_id)],
	}, 4)
	await _pump(6)
	# 3端安德洛美达(player)手牌都应含维修 + X=1
	for ar_name in [["host", host], ["client1", client1], ["client2", client2]]:
		var ar_obj = ar_name[1]
		var p = ar_obj.battle.context.game_state.players.get(&"player")
		if p == null or not p.action_hand.has(repair_id):
			await _free3(host, client1, client2)
			return "%s 安德洛美达未回收维修（手牌=%s）" % [ar_name[0], str(p.action_hand if p else null)]
	# X=1（3端一致）
	var h_pilot = host.battle.context.game_state.get_mech_for_player(&"player").slots.get(&"pilot").equipped_card
	var hx: int = int(h_pilot.counters.get("var_X", 0)) if h_pilot != null else -1
	if hx != 1:
		await _free3(host, client1, client2)
		return "host 安德洛美达 X 应=1 实=%d" % hx
	await _free3(host, client1, client2)
	return true


# ═══════════════════════════════════════════
# 攻击全流程：player 攻击 enemy，3端 enemy HP 一致下降
# ═══════════════════════════════════════════
func _drain_damage_placement_3(h, c1, c2, target_mech_id: StringName) -> String:
	for _i in 20:
		var ht: StringName = _wait_input_type(h)
		if ht != &"place_damage_tokens":
			break
		var hwi: Dictionary = h.battle.context.action_ui_bridge.get_waiting_action_info()
		var amount: int = int(hwi.get("input_params", {}).get("amount", 0))
		var slots: Array = h.battle.context.damage_token_service.get_valid_damage_slots(target_mech_id)
		if slots.is_empty():
			return "无可用损伤槽位（amount=%d）" % amount
		for j in amount:
			var slot_id: StringName = slots[j % slots.size()]
			await _exec3(h, c1, c2, "damage_place", {"slot_id": slot_id, "target_mech_id": target_mech_id}, 2)
		await _exec3(h, c1, c2, "ui_confirmed", {"data": {"placed": true}}, 4)
	return ""


func test_pvp3_lockstep_attack_flow_sync() -> Variant:
	var seed_val := 555
	var host = await _build_pvp3_app_root(seed_val, &"player")
	var client1 = await _build_pvp3_app_root(seed_val, &"enemy")
	var client2 = await _build_pvp3_app_root(seed_val, &"third")
	if host == null or client1 == null or client2 == null:
		await _free3(host, client1, client2)
		return "建局失败"
	var hg = host.battle.context.game_state
	hg.active_player_id = &"player"
	client1.battle.context.game_state.active_player_id = &"player"
	client2.battle.context.game_state.active_player_id = &"player"
	var pm = hg.get_mech_for_player(&"player")
	var em = hg.get_mech_for_player(&"enemy")
	if pm == null or em == null:
		await _free3(host, client1, client2)
		return "机甲缺失"
	# 敌我相邻
	pm.position = {"q": 5, "r": 0}
	em.position = {"q": 6, "r": 0}
	client1.battle.context.game_state.get_mech_for_player(&"player").position = {"q": 5, "r": 0}
	client1.battle.context.game_state.get_mech_for_player(&"enemy").position = {"q": 6, "r": 0}
	client2.battle.context.game_state.get_mech_for_player(&"player").position = {"q": 5, "r": 0}
	client2.battle.context.game_state.get_mech_for_player(&"enemy").position = {"q": 6, "r": 0}
	var weapon_ids: Array[StringName] = pm.get_weapon_ids()
	if weapon_ids.is_empty():
		await _free3(host, client1, client2)
		return "玩家无机甲武器"
	var weapon_id: StringName = weapon_ids[0]
	var enemy_hp_before: int = em.current_hp

	var attack_cid: StringName = await _dev_add_card_3(host, client1, client2, &"add_action_card", &"player", "action_001_进攻")
	if attack_cid == &"":
		await _free3(host, client1, client2)
		return "3端加进攻牌失败或 instance_id 不同步"

	# ① 打攻击牌 -> 3端暂停在 select_weapon
	await _exec3(host, client1, client2, "play_action_card", {"player_id": &"player", "card_instance_id": attack_cid})
	if _wait_input_type(host) != &"select_weapon":
		await _free3(host, client1, client2)
		return "host 打攻击牌后未暂停在 select_weapon: %s" % String(_wait_input_type(host))
	if _wait_input_type(client1) != &"select_weapon" or _wait_input_type(client2) != &"select_weapon":
		await _free3(host, client1, client2)
		return "client 打攻击牌后未暂停在 select_weapon c1=%s c2=%s" % [String(_wait_input_type(client1)), String(_wait_input_type(client2))]

	# ② 选武器 -> 3端暂停在 select_attack_target
	await _exec3(host, client1, client2, "ui_confirmed", {"data": {"weapon_id": weapon_id}})
	if _wait_input_type(host) != &"select_attack_target":
		await _free3(host, client1, client2)
		return "选武器后 host 未暂停在 select_attack_target: %s" % String(_wait_input_type(host))

	# ③ 选目标(enemy_mech) -> 3端暂停在 respond_attack
	await _exec3(host, client1, client2, "ui_confirmed", {"data": {"target_id": em.mech_id}})
	if _wait_input_type(host) != &"respond_attack":
		await _free3(host, client1, client2)
		return "选目标后 host 未暂停在 respond_attack: %s" % String(_wait_input_type(host))

	# ④ 迎击响应 pass -> 命中 -> 损伤放置
	var resp_action_id: StringName = _wait_action_id(host)
	await _exec3(host, client1, client2, "respond_attack", {"action_id": resp_action_id, "pass": true})

	# ⑤ 排空损伤放置
	var drain_err: String = await _drain_damage_placement_3(host, client1, client2, em.mech_id)
	if drain_err != "":
		await _free3(host, client1, client2)
		return "损伤放置排空失败: %s" % drain_err
	await _pump(4)

	# ⑥ 攻击动作3端完成、enemy HP 3端一致下降
	var h_active: int = host.battle.context.action_registry.get_active_count()
	var c1_active: int = client1.battle.context.action_registry.get_active_count()
	var c2_active: int = client2.battle.context.action_registry.get_active_count()
	if h_active != 0 or c1_active != 0 or c2_active != 0:
		await _free3(host, client1, client2)
		return "攻击未完成 h=%d c1=%d c2=%d" % [h_active, c1_active, c2_active]
	var h_hp: int = host.battle.context.game_state.get_mech_for_player(&"enemy").current_hp
	var c1_hp: int = client1.battle.context.game_state.get_mech_for_player(&"enemy").current_hp
	var c2_hp: int = client2.battle.context.game_state.get_mech_for_player(&"enemy").current_hp
	if h_hp != c1_hp or h_hp != c2_hp:
		await _free3(host, client1, client2)
		return "攻击后 enemy HP 3端不一致 h=%d c1=%d c2=%d" % [h_hp, c1_hp, c2_hp]
	if h_hp >= enemy_hp_before:
		await _free3(host, client1, client2)
		return "攻击后 enemy HP 未下降 before=%d after=%d" % [enemy_hp_before, h_hp]
	await _free3(host, client1, client2)
	return true
