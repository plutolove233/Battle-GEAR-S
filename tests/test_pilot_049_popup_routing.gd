extends RefCounted

## test_pilot_049_popup_routing.gd - 杰狞(pilot_049)并发弹窗精确路由验证（Bug1）
##
## 场景：双连 fork 攻击中 _step_apply_damage 先后创建 hp_change（杰狞转移 CHOOSE_ONE
## 挂起 waiting_timing）与 damage_change（损伤放置挂起 waiting_input）。
## 修复前：ActionUIBridge._waiting_action_id 单槽被后到的损伤放置覆盖 -> 确认转移弹窗
## 时 app_root._on_choice_made 读槽得 damage_change -> 输入丢错动作 -> hp_change 永久
## 挂起 -> 攻击不结算。
## 修复后：effect_choice 弹窗捕获 params.action_id，确认/取消走 _net_exec("resume_effect")
## -> bridge.resolve_effect_input(action_id, data) 精确路由（仅槽仍指向本动作才清槽，
## 直连 resume_pending_effect）。
##
## 本文件在并发挂起状态下直接调用 bridge.resolve_effect_input 验证：
##   1. 确认转移：hp_change 恢复完成（转移生效）、damage_change 不受影响仍挂起、
##      共享槽不被误清（仍指向 damage_change）。
##   2. 取消转移：hp_change 恢复完成（不转移，原目标扣血）、damage_change 不受影响。
##
## 布局（同 test_pilot_049_fork）：player(2,2) 双连打 [enemy2(3,1), enemy1(3,2)]；
## enemy1 持杰狞，fork1 打 enemy2（距杰狞1格 -> 触发转移弹窗）。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	# PvP 双人类玩家：enemy 人类（转移弹窗二选一路由到人类）
	battle.rng_seed = 90049
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	return battle


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 把指定 card_def_id 的行动牌塞入玩家手牌
func _ensure_card_in_hand(battle, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


## 设杰狞为指定机甲机师
func _setup_jiening_on_mech(battle, mech_id: StringName, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.mechs.get(mech_id)
	if mech == null:
		return {"err": "找不到机甲 %s" % String(mech_id)}
	var card = _make_instance(gs, cdb, "pilot_049_杰狞", owner_id)
	if card == null:
		return {"err": "缺 pilot_049_杰狞 数据"}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card}


func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary) -> MechState:
	var gs = battle.context.game_state
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = &"enemy"
	m.max_hp = 40
	m.current_hp = 40
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		m.slots[slot_id] = s
	gs.mechs[m.mech_id] = m
	return m


func _find_main_attack(battle) -> StringName:
	var ar = battle.context.action_registry
	for aid in ar.get_active_ids():
		var a = ar.get_action(aid)
		if a and a.action_type == &"attack" and not bool(a.record.get("_is_fork", false)):
			return aid
	return &""


func _find_pending_fork(battle, parent) -> StringName:
	var ar = battle.context.action_registry
	for fid: StringName in parent.pending_effect_action_ids:
		var sub = ar.get_action(fid)
		if sub != null and sub.action_type == &"attack":
			return fid
	return &""


func _find_pending_sub(battle, parent, sub_type: StringName, want_state: StringName) -> StringName:
	var ar = battle.context.action_registry
	for cid: StringName in parent.pending_effect_action_ids:
		var sub = ar.get_action(cid)
		if sub != null and sub.action_type == sub_type:
			if want_state == &"" or sub.state == want_state:
				return cid
	return &""


## 驱动损伤放置子动作完成（同 049 fork 测试：预放损伤 + continue + 通知）
func _drive_damage_placement(battle, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id == &"":
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			continue
		var dc = ar.get_action(dc_id)
		var amount: int = int(dc.record.get("value", 0))
		var mech_ids: Array = dc.record.get("mech_ids", [])
		if dts != null and amount > 0:
			for mech_id: StringName in mech_ids:
				dts.place_damage_tokens({"mech_id": mech_id, "count": amount})
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)
	return {"ok": true}


## 建立并发挂起状态：fork1 内 hp_change（转移弹窗 waiting_timing）+ damage_change
## （损伤放置 waiting_input）同时挂起。返回错误串或空串。
func _reach_concurrent_suspend(battle, s: Dictionary) -> String:
	var gs = battle.context.game_state
	var player_mech = s["player_mech"]
	var enemy1_mech = s["enemy1_mech"]
	var enemy2_mech = s["enemy2_mech"]
	var dual_id: StringName = s["dual_id"]
	battle.execute_use_action_card(&"player", dual_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var main_id := _find_main_attack(battle)
	if main_id == &"":
		return "找不到主攻击动作"
	var main_attack = ar.get_action(main_id)
	ae.continue_action(main_id, {"weapon_id": s["weapon_id"]})
	ae.continue_action(main_id, {"target_ids": [enemy2_mech.mech_id, enemy1_mech.mech_id]})
	if String(main_attack.state) != &"waiting_effect_action":
		return "主攻击应在 fork 后暂停，实=%s" % String(main_attack.state)
	var fork1_id := _find_pending_fork(battle, main_attack)
	if fork1_id == &"":
		return "未派生 fork1"
	s["main_id"] = main_id
	s["fork1_id"] = fork1_id
	var fork1 = ar.get_action(fork1_id)
	var hp_id := _find_pending_sub(battle, fork1, &"hp_change", &"waiting_timing")
	if hp_id == &"":
		return "hp_change 未挂起于杰狞转移弹窗（state=%s pending=%s）" % [String(fork1.state), str(fork1.pending_effect_action_ids)]
	s["hp_id"] = hp_id
	# damage_change 应同处挂起（并发前置条件）
	var dc_id := _find_pending_sub(battle, fork1, &"damage_change", &"waiting_input")
	if dc_id == &"":
		return "damage_change 未同时挂起（pending=%s）" % str(fork1.pending_effect_action_ids)
	s["dc_id"] = dc_id
	return ""


func _setup_common(battle) -> Dictionary:
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy1_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy1_mech == null:
		return {}
	var ret := _setup_jiening_on_mech(battle, enemy1_mech.mech_id, &"enemy")
	if ret.has("err"):
		return {"err": ret["err"]}
	battle.context.action_ui_bridge.context = battle.context
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 3, "r": 1})
	player_mech.position = {"q": 2, "r": 2}
	enemy1_mech.position = {"q": 3, "r": 2}
	enemy2_mech.position = {"q": 3, "r": 1}
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()
	var dual_id = _ensure_card_in_hand(battle, "action_005_双连")
	if dual_id == &"":
		return {"err": "找不到 双连"}
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return {"err": "玩家机甲无武器"}
	return {
		"player_mech": player_mech, "enemy1_mech": enemy1_mech, "enemy2_mech": enemy2_mech,
		"dual_id": dual_id, "weapon_id": weapon_ids[0],
	}


# ═══════════════════════════════════════════
# Bug1-确认路径：转移弹窗确认精确路由（不丢输入、不误伤并发损伤放置）
# ═══════════════════════════════════════════
func test_p049_concurrent_transfer_confirm_precise_routing() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup_common(battle)
	if s.has("err"):
		return s["err"]
	var enemy1_mech = s["enemy1_mech"]
	var enemy2_mech = s["enemy2_mech"]
	var err := _reach_concurrent_suspend(battle, s)
	if err != "":
		return err
	var bridge = battle.context.action_ui_bridge
	var ar = battle.context.action_registry
	var hp_id: StringName = s["hp_id"]
	var dc_id: StringName = s["dc_id"]
	var fork1_id: StringName = s["fork1_id"]

	# 前置断言：转移弹窗与损伤放置并发等待不丢失（排队语义：先到者占槽，
	# 后到的损伤放置进排队表等待恢复。旧"后到覆盖"语义下面板被抢槽丢失即 Bug1）
	var slot: Dictionary = bridge.get_waiting_action_info()
	var queued: Array = bridge.get_queued_waiting_action_ids()
	if not queued.has(String(dc_id)):
		return "损伤放置应在排队表等待恢复（并发不丢失），queued=%s slot=%s" % [str(queued), String(slot.get("action_id", &""))]

	var enemy1_hp_before: int = enemy1_mech.current_hp
	var enemy2_hp_before: int = enemy2_mech.current_hp

	# 修复路径：确认转移 -> 精确路由恢复 hp_change
	bridge.resolve_effect_input(hp_id, {"chosen_option_index": 0})
	await _pump_frames(10)

	# hp_change 恢复完成且转移生效（杰狞承受伤害：enemy1 扣血、enemy2 不扣）
	var hp_after = ar.get_action(hp_id)
	if hp_after != null and String(hp_after.state) != &"completed":
		return "确认转移后 hp_change 应完成，实=%s" % String(hp_after.state)
	if enemy1_mech.current_hp >= enemy1_hp_before:
		return "转移应使杰狞持有者(enemy1)扣血（前%d 后%d）" % [enemy1_hp_before, enemy1_mech.current_hp]
	if enemy2_mech.current_hp != enemy2_hp_before:
		return "转移后原目标(enemy2)不应扣血（前%d 后%d）" % [enemy2_hp_before, enemy2_mech.current_hp]
	# damage_change 不受影响仍挂起
	var dc_after = ar.get_action(dc_id)
	if dc_after == null or String(dc_after.state) != &"waiting_input":
		return "damage_change 应不受确认转移影响仍挂起，实=%s" % ("gone" if dc_after == null else String(dc_after.state))
	# 转移弹窗解决后不残留（槽不再指向 hp_change），损伤放置仍在排队等待恢复
	var slot2: Dictionary = bridge.get_waiting_action_info()
	if String(slot2.get("action_id", &"")) == String(hp_id):
		return "转移弹窗解决后槽不应仍指向 hp_change"
	if not bridge.get_queued_waiting_action_ids().has(String(dc_id)):
		return "损伤放置应仍在排队等待恢复，queued=%s" % str(bridge.get_queued_waiting_action_ids())

	# 损伤放置正常驱动 -> fork1 完成（全链不卡死）
	var dp_ret: Dictionary = _drive_damage_placement(battle, fork1_id)
	if not dp_ret.get("ok", false):
		return str(dp_ret.get("msg", "损伤放置驱动失败"))
	var fork1 = ar.get_action(fork1_id)
	if fork1 != null and String(fork1.state) != &"completed":
		return "损伤放置完成后 fork1 应完成，实=%s" % String(fork1.state)
	print("P049-ROUTING-CONFIRM-OK 转移生效=%d 杰狞扣血（%d->%d）" % [enemy1_hp_before - enemy1_mech.current_hp, enemy1_hp_before, enemy1_mech.current_hp])
	return true


# ═══════════════════════════════════════════
# Bug1-取消路径：转移弹窗取消精确路由（hp_change 完成不转移，损伤放置不受影响）
# ═══════════════════════════════════════════
func test_p049_concurrent_transfer_cancel_precise_routing() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup_common(battle)
	if s.has("err"):
		return s["err"]
	var enemy1_mech = s["enemy1_mech"]
	var enemy2_mech = s["enemy2_mech"]
	var err := _reach_concurrent_suspend(battle, s)
	if err != "":
		return err
	var bridge = battle.context.action_ui_bridge
	var ar = battle.context.action_registry
	var hp_id: StringName = s["hp_id"]
	var dc_id: StringName = s["dc_id"]
	var fork1_id: StringName = s["fork1_id"]

	var enemy1_hp_before: int = enemy1_mech.current_hp
	var enemy2_hp_before: int = enemy2_mech.current_hp

	# 修复路径：取消转移 -> 精确路由恢复 hp_change（不转移）
	bridge.resolve_effect_input(hp_id, {"cancelled": true})
	await _pump_frames(10)

	var hp_after = ar.get_action(hp_id)
	if hp_after != null and String(hp_after.state) != &"completed":
		return "取消转移后 hp_change 应完成，实=%s" % String(hp_after.state)
	if enemy1_mech.current_hp != enemy1_hp_before:
		return "取消转移杰狞持有者(enemy1)不应扣血（前%d 后%d）" % [enemy1_hp_before, enemy1_mech.current_hp]
	if enemy2_mech.current_hp >= enemy2_hp_before:
		return "取消转移原目标(enemy2)应正常扣血（前%d 后%d）" % [enemy2_hp_before, enemy2_mech.current_hp]
	var dc_after = ar.get_action(dc_id)
	if dc_after == null or String(dc_after.state) != &"waiting_input":
		return "damage_change 应不受取消影响仍挂起，实=%s" % ("gone" if dc_after == null else String(dc_after.state))
	# 转移弹窗解决后不残留，损伤放置仍在排队等待恢复（不被取消路径误伤）
	var slot2: Dictionary = bridge.get_waiting_action_info()
	if String(slot2.get("action_id", &"")) == String(hp_id):
		return "转移弹窗解决后槽不应仍指向 hp_change"
	if not bridge.get_queued_waiting_action_ids().has(String(dc_id)):
		return "损伤放置应仍在排队等待恢复，queued=%s" % str(bridge.get_queued_waiting_action_ids())

	# 损伤放置正常驱动 -> fork1 完成
	var dp_ret: Dictionary = _drive_damage_placement(battle, fork1_id)
	if not dp_ret.get("ok", false):
		return str(dp_ret.get("msg", "损伤放置驱动失败"))
	var fork1 = ar.get_action(fork1_id)
	if fork1 != null and String(fork1.state) != &"completed":
		return "损伤放置完成后 fork1 应完成，实=%s" % String(fork1.state)
	print("P049-ROUTING-CANCEL-OK hp_change 完成、损伤放置不受影响、fork1 完成")
	return true
