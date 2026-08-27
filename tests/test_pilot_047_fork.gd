extends RefCounted

## test_pilot_047_fork.gd - 里欧娜(pilot_047)战后威逼×双连 fork 死锁修复验证（Bug2）
##
## 场景：玩家里欧娜双连打 [enemy1, enemy2]（enemy 人类，PvP 布局同 049 fork 测试）。
## fork1(enemy1) 结算 ATTACK_SETTLE 触发战后威逼 -> enemy1 选「立即使用1张攻击牌」->
## resume 阶段顶层 execute(use_action_card)（敌方被动进攻玩家机甲）。
##
## 修复前：use_action_card 无父子链接 -> 效果链立即结束 -> fork1 完成 -> fork2 派生
## -> fork2 的 ATTACK_AT 响应窗口覆盖 ActionUIBridge 共享等待槽 -> use_action_card 的
## 选武器/选目标弹窗孤儿化 -> 整链死锁（双连阻塞）。
## 修复后：_link_spawned_use_action_as_child 强制父子链接（parent_action_id +
## pending_effect_action_ids + waiting_effect_action），fork1 等 use_action_card 完成
## 才继续，fork2 才派生。
##
## 布局：
##   player(2,2) 里欧娜 ── 双连打 [enemy1, enemy2]
##   enemy1(3,2) = 威逼目标（被动使用进攻牌打回 player）
##   enemy2(3,1) = fork2 目标

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	# PvP 双人类玩家：同种子 + 地图特征 + enemy 人类（威逼二选一路由到人类被选机甲）
	battle.rng_seed = 90047
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


## 清空指定玩家行动手牌（先注销监听器避免残留 AVAILABILITY 响应窗）
func _clear_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	p.action_hand.clear()


## 设里欧娜为 player 机甲机师
func _setup_leona(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return {"err": "找不到玩家机甲"}
	var card = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	if card == null:
		return {"err": "缺 pilot_047_里欧娜 数据"}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card}


## 创建第 2 台敌方机甲
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


## 找指定动作 pending 里的复制攻击（attack 类型子动作）
func _find_pending_fork(battle, parent) -> StringName:
	var ar = battle.context.action_registry
	for fid: StringName in parent.pending_effect_action_ids:
		var sub = ar.get_action(fid)
		if sub != null and sub.action_type == &"attack":
			return fid
	return &""


## 找指定动作 pending 里指定类型的子动作 id
func _find_pending_sub(battle, parent, sub_type: StringName, want_state: StringName) -> StringName:
	var ar = battle.context.action_registry
	for cid: StringName in parent.pending_effect_action_ids:
		var sub = ar.get_action(cid)
		if sub != null and sub.action_type == sub_type:
			if want_state == &"" or sub.state == want_state:
				return cid
	return &""


## 驱动攻击的损伤放置子动作完成（同步通知；玩家/人类目标的损伤面板同样适用）
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


## 找全局 attack 动作中 pending 于输入态（选武器/选目标）且非 fork 的最新一个
func _find_attack_waiting_input(battle) -> StringName:
	var ar = battle.context.action_registry
	var found: StringName = &""
	for aid in ar.get_active_ids():
		var a = ar.get_action(aid)
		if a and a.action_type == &"attack" and a.state == &"waiting_input":
			found = aid
	return found


# ═══════════════════════════════════════════
# Bug2：双连 fork × 里欧娜战后威逼「立即使用攻击牌」不死锁
# ═══════════════════════════════════════════
func test_p047_fork_force_use_attack_no_deadlock() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy1_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy1_mech == null:
		return "找不到玩家/敌方机甲"
	var setup_ret := _setup_leona(battle)
	if setup_ret.has("err"):
		return setup_ret["err"]
	battle.context.action_ui_bridge.context = battle.context
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 3, "r": 1})
	player_mech.position = {"q": 2, "r": 2}
	enemy1_mech.position = {"q": 3, "r": 2}
	enemy2_mech.position = {"q": 3, "r": 1}
	# 清地形（避免随机红/绿格干扰射程 BFS）
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	# 双方手牌清空（注销监听器，避免 ATTACK_AT 响应窗干扰），再各放必需牌
	_clear_hand(battle, &"player")
	_clear_hand(battle, &"enemy")
	var dual = _make_instance(gs, cdb, "action_005_双连", &"player")
	if dual == null:
		return "缺 action_005_双连 数据"
	dual.zone = &"action_hand"
	gs.players.get(&"player").action_hand.append(dual.instance_id)
	var enemy_atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	if enemy_atk == null:
		return "缺 action_001_进攻 数据"
	enemy_atk.zone = &"action_hand"
	gs.players.get(&"enemy").action_hand.append(enemy_atk.instance_id)

	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var enemy_weapon_ids = enemy1_mech.get_weapon_ids()
	if enemy_weapon_ids.is_empty():
		return "敌方机甲无武器"

	battle.execute_use_action_card(&"player", dual.instance_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var te = battle.context.timing_engine
	var main_id := _find_main_attack(battle)
	if main_id == &"":
		return "找不到主攻击动作"
	var main_attack = ar.get_action(main_id)
	ae.continue_action(main_id, {"weapon_id": weapon_ids[0]})
	# fork1=enemy1（威逼目标），fork2=enemy2
	ae.continue_action(main_id, {"target_ids": [enemy1_mech.mech_id, enemy2_mech.mech_id]})
	if String(main_attack.state) != &"waiting_effect_action":
		return "主攻击应在 fork 后暂停 waiting_effect_action，实=%s" % String(main_attack.state)
	var fork1_id := _find_pending_fork(battle, main_attack)
	if fork1_id == &"":
		return "未派生 fork1"
	var fork1 = ar.get_action(fork1_id)

	# ── fork1：损伤放置 -> SETTLE 威逼确认窗 ──
	var dp_ret: Dictionary = _drive_damage_placement(battle, fork1_id)
	if not dp_ret.get("ok", false):
		return str(dp_ret.get("msg", "fork1 损伤驱动失败"))
	await _pump_frames(3)
	fork1 = ar.get_action(fork1_id)
	if fork1 == null or fork1.state != &"waiting_timing":
		return "fork1 应挂起于 SETTLE 威逼确认窗，实=%s" % ("gone" if fork1 == null else String(fork1.state))
	# 确认发动 -> 选 enemy1 为威逼目标 -> 二选一选「立即使用1张攻击牌」
	te.resume_pending_effect(fork1_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	te.resume_pending_effect(fork1_id, {"target_id": enemy1_mech.mech_id})
	await _pump_frames(3)
	fork1 = ar.get_action(fork1_id)
	if fork1 == null or fork1.state != &"waiting_timing":
		return "选机甲后应挂起二选一弹窗，实=%s" % ("gone" if fork1 == null else String(fork1.state))
	te.resume_pending_effect(fork1_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	var pend: Dictionary = te._pending_effect.get(fork1_id, {})
	if String(pend.get("phase", &"")) != "pilot_047_force_use_attack":
		return "应挂起选攻击牌窗 pilot_047_force_use_attack，实=%s" % String(pend.get("phase", &""))

	# ── resume 选牌：顶层 execute(use_action_card) + 强制父子链接（Bug2 修复点）──
	te.resume_pending_effect(fork1_id, {"selected_card_id": enemy_atk.instance_id})
	await _pump_frames(3)

	# 断言①：use_action_card 已创建且被链接为 fork1 的子动作
	var uc_id: StringName = &""
	for aid in ar.get_active_ids():
		var a = ar.get_action(aid)
		if a and a.action_type == &"use_action_card" \
				and StringName(a.record.get("card_instance_id", &"")) == enemy_atk.instance_id:
			uc_id = aid
	if uc_id == &"":
		return "resume 后未创建 use_action_card 动作"
	var uc = ar.get_action(uc_id)
	if uc.parent_action_id != fork1_id:
		return "use_action_card 应链接 parent=fork1，实=%s" % String(uc.parent_action_id)
	fork1 = ar.get_action(fork1_id)
	if fork1 == null or not fork1.pending_effect_action_ids.has(uc_id):
		return "fork1 pending 应含 use_action_card，实=%s" % str(fork1.pending_effect_action_ids)
	if String(fork1.state) != &"waiting_effect_action":
		return "fork1 应等待 use_action_card（waiting_effect_action），实=%s" % String(fork1.state)
	# 断言②：fork2 未派生（主攻击仍在等 fork1，不与 use_action_card 竞争共享槽）
	var main_mid = ar.get_action(main_id)
	if main_mid == null:
		return "主攻击不应提前消失"
	var premature_fork := _find_pending_fork(battle, main_mid)
	if premature_fork != &"" and premature_fork != fork1_id:
		return "use_action_card 挂起期间不应派生 fork2，实=%s" % String(premature_fork)

	# ── 驱动被动进攻（敌方 use_action_card -> attack 子动作）走完 ──
	var forced_attack_id := _find_attack_waiting_input(battle)
	if forced_attack_id == &"":
		return "被动进攻 attack 未挂起等待选武器"
	ae.continue_action(forced_attack_id, {"weapon_id": enemy_weapon_ids[0]})
	await _pump_frames(3)
	forced_attack_id = _find_attack_waiting_input(battle)
	if forced_attack_id == &"":
		return "被动进攻 attack 未挂起等待选目标"
	ae.continue_action(forced_attack_id, {"target_ids": [player_mech.mech_id]})
	await _pump_frames(3)
	# 被动进攻对玩家机甲结算：驱动损伤放置（人类目标面板）
	var forced = ar.get_action(forced_attack_id)
	if forced == null:
		return "被动进攻动作消失"
	var dp2: Dictionary = _drive_damage_placement(battle, forced_attack_id)
	if not dp2.get("ok", false):
		return str(dp2.get("msg", "被动进攻损伤驱动失败"))
	await _pump_frames(6)

	# 断言③：use_action_card 完成 -> fork1 完成 -> fork2 派生（链自动续跑）
	uc = ar.get_action(uc_id)
	if uc != null and String(uc.state) != &"completed":
		return "被动进攻后 use_action_card 应完成，实=%s" % String(uc.state)
	fork1 = ar.get_action(fork1_id)
	if fork1 != null and String(fork1.state) != &"completed":
		return "use_action_card 完成后 fork1 应完成，实=%s" % String(fork1.state)
	var main_after = ar.get_action(main_id)
	if main_after == null:
		return "fork1 完成后主攻击不应消失"
	var fork2_id := _find_pending_fork(battle, main_after)
	if fork2_id == &"":
		return "fork1 完成后应派生 fork2（死锁未修复？）"
	var fork2 = ar.get_action(fork2_id)
	if String(fork2.record.get("target_id", &"")) != String(enemy2_mech.mech_id):
		return "fork2 目标应为 enemy2，实=%s" % String(fork2.record.get("target_id", &""))

	# ── fork2：损伤放置 -> SETTLE 威逼确认窗（这次取消）──
	var dp3: Dictionary = _drive_damage_placement(battle, fork2_id)
	if not dp3.get("ok", false):
		return str(dp3.get("msg", "fork2 损伤驱动失败"))
	await _pump_frames(3)
	fork2 = ar.get_action(fork2_id)
	if fork2 != null and fork2.state == &"waiting_timing":
		te.resume_pending_effect(fork2_id, {"cancelled": true})
		await _pump_frames(6)
	# 主攻击整体完成
	var main_final = ar.get_action(main_id)
	if main_final != null and String(main_final.state) != &"completed":
		return "主攻击应在 fork2 完成后完成，实=%s" % String(main_final.state)
	# 敌方进攻牌已消耗（离开手牌）
	if gs.players.get(&"enemy").action_hand.has(enemy_atk.instance_id):
		return "敌方被动使用的进攻牌应离开手牌"
	print("P047-FORK-OK 被动进攻完成、fork2 派生并走完、主攻击完成")
	return true
