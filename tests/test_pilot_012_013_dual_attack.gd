extends RefCounted

## test_pilot_012_013_dual_attack.gd - 玛丽尔(p012)/巴托洛夫(p013)真双连全链不阻塞验证
##
## 已有 fork 测试（flag 继承）用手造 attack+fire_timing 模拟 fork；本文件走真实
## use_action_card(双连) -> 主攻击 PRE 效果弹窗 -> fork1/fork2 依次走完的全链路，
## 验证弹窗族（共享槽竞争/父子链接同类场景）不造成死锁：
##   p012 玛丽尔：主攻 ATTACK_PRE e01 确认窗（偷牌+减动力+写 flag）->
##     每个 fork ATTACK_AFTER e02 确认窗（flag 继承：抽1+回3动力）-> 损伤放置。
##   p013 巴托洛夫：主攻 ATTACK_PRE e02a 确认窗（自身+目标护甲/动力上限/动力-4+写 flag）->
##     每个 fork ATTACK_AFTER e02b 命中伤害+3（flag 继承，自动）-> 损伤放置。
##
## 布局（PvP 双人类，同 049 fork 测试）：player(2,2) 双连打 [enemy1(3,2), enemy2(3,1)]，
## 双方手牌清空（无偷牌 UI / 无 ATTACK_AT 响应窗口干扰）。
##
## 数值注意：max_power 是派生存储字段（get_total_power() 随槽位损伤下降，fork 掉血后
## 损伤标记会压低目标动力上限）——动力类断言须在 fork 掉血前（e01/e02a 确认后立即）做。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
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
	battle.rng_seed = 90013
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura），避免跨测试泄漏
func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


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


## 通用开局：设机师、清地形、清双方手牌（注销监听）、塞双连、机甲就位。
## 返回填充 player_mech/enemy1/enemy2/dual_id/weapon_id/gs 的 s；失败返回 {"err": ...}。
func _setup_dual(battle, pilot_def_id: String) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy1_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy1_mech == null:
		return {"err": "找不到玩家/敌方机甲"}
	var pilot_card = _make_instance(gs, cdb, pilot_def_id, &"player")
	if pilot_card == null:
		return {"err": "缺 %s 数据" % pilot_def_id}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	battle.context.action_ui_bridge.context = battle.context
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 3, "r": 1}, enemy1_mech)
	player_mech.position = {"q": 2, "r": 2}
	enemy1_mech.position = {"q": 3, "r": 2}
	enemy2_mech.position = {"q": 3, "r": 1}
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	for pid in [&"player", &"enemy"]:
		var p = gs.players.get(pid)
		if p == null:
			continue
		for cid: StringName in p.action_hand.duplicate():
			battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.clear()
	var dual = _make_instance(gs, cdb, "action_005_双连", &"player")
	if dual == null:
		return {"err": "缺 action_005_双连 数据"}
	dual.zone = &"action_hand"
	gs.players.get(&"player").action_hand.append(dual.instance_id)
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return {"err": "玩家机甲无武器"}
	return {
		"gs": gs,
		"player_mech": player_mech,
		"enemy1": enemy1_mech,
		"enemy2": enemy2_mech,
		"dual_id": dual.instance_id,
		"weapon_id": weapon_ids[0],
	}


## 创建第 2 台敌方机甲（空装白板）。槽位 base_* 从教程敌方机甲镜像，
## 否则 get_total_power()/get_armor() 重算为 0（max_power 是派生存储字段）。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary, frame_mech) -> MechState:
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
		if frame_mech != null and frame_mech.slots.has(slot_id):
			s.base_armor = frame_mech.slots[slot_id].base_armor
			s.base_power = frame_mech.slots[slot_id].base_power
			s.base_durability = frame_mech.slots[slot_id].base_durability
		m.slots[slot_id] = s
	m.max_power = m.get_total_power()
	m.power = m.max_power
	gs.mechs[m.mech_id] = m
	return m


func _find_main_attack(battle) -> StringName:
	var ar = battle.context.action_registry
	for aid in ar.get_active_ids():
		var a = ar.get_action(aid)
		if a and a.action_type == &"attack" and not bool(a.record.get("_is_fork", false)):
			return aid
	return &""


func _find_pending_fork(battle, main_attack) -> StringName:
	var ar = battle.context.action_registry
	for fid: StringName in main_attack.pending_effect_action_ids:
		var sub = ar.get_action(fid)
		if sub != null and sub.action_type == &"attack":
			return fid
	return &""


## 驱动攻击内损伤放置子动作完成（同 049 fork 测试）
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


## 驱动一个 fork 走完：e02 CHOOSE_ONE 确认（可选）+ 损伤放置。
## confirm_after=true 时对挂起的效果弹窗回 chosen_option_index=0；false 时遇弹窗报错。
func _drive_fork(battle, fork_id: StringName, confirm_after: bool) -> String:
	var te = battle.context.timing_engine
	var ar = battle.context.action_registry
	var guard: int = 0
	while guard < 24:
		guard += 1
		var fork = ar.get_action(fork_id)
		if fork == null or fork.state == &"completed" or fork.state == &"cancelled":
			return ""
		if te.has_pending_effect(fork_id):
			# e02 命中奖励 CHOOSE_ONE（效果动作挂起，pending 键=fork id）
			if not confirm_after:
				return "fork %s 挂起于弹窗（未预期，confirm_after=false）" % String(fork_id)
			te.resume_pending_effect(fork_id, {"chosen_option_index": 0})
			await _pump_frames(6)
			continue
		if fork.state == &"waiting_effect_action":
			var dp: Dictionary = _drive_damage_placement(battle, fork_id)
			if not dp.get("ok", false):
				return str(dp.get("msg", "损伤驱动失败"))
			await _pump_frames(5)
			continue
		if fork.state == &"waiting_timing":
			return "fork %s 挂起于时点（未预期响应窗口？）" % String(fork_id)
		await _pump_frames(3)
	var fork_final = ar.get_action(fork_id)
	return "fork %s 驱动超时 state=%s" % [String(fork_id), String(fork_final.state if fork_final != null else &"gone")]


## 发动双连并驱动主攻击到 PRE 弹窗挂起。返回 {"err":...} 或 {"main_id":...}。
func _start_dual_and_reach_pre(battle, s: Dictionary) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	battle.execute_use_action_card(&"player", s["dual_id"])
	var main_id := _find_main_attack(battle)
	if main_id == &"":
		return {"err": "找不到主攻击动作"}
	ae.continue_action(main_id, {"weapon_id": s["weapon_id"]})
	ae.continue_action(main_id, {"target_ids": [s["enemy1"].mech_id, s["enemy2"].mech_id]})
	await _pump_frames(3)
	var main_attack = ar.get_action(main_id)
	if main_attack == null or main_attack.state != &"waiting_timing":
		return {"err": "主攻击应挂起于 PRE 效果确认窗，实=%s" % ("gone" if main_attack == null else String(main_attack.state))}
	return {"main_id": main_id}


# ═══════════════════════════════════════════
# p012 玛丽尔：双连全链（PRE e01 确认 -> 2 fork AFTER e02 确认 -> 完成）
# ═══════════════════════════════════════════
func test_p012_dual_full_chain_no_deadlock() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup_dual(battle, "pilot_012_玛丽尔")
	if s.has("err"):
		return s["err"]
	var gs = s["gs"]
	var player_mech = s["player_mech"]
	var enemy1 = s["enemy1"]
	var enemy2 = s["enemy2"]
	# 双方手牌已清空：e01 偷牌分支 CONDITIONAL 跳过，动力-3 生效
	enemy1.power = 10
	enemy1.max_power = 10
	player_mech.power = 4
	player_mech.max_power = 10
	var e1_power0: int = enemy1.power
	var e2_power0: int = enemy2.power
	var e1_hp0: int = enemy1.current_hp
	var e2_hp0: int = enemy2.current_hp
	var hand_before: int = gs.players.get(&"player").action_hand.size()

	var start := await _start_dual_and_reach_pre(battle, s)
	if start.has("err"):
		return start["err"]
	var main_id: StringName = start["main_id"]
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var te = battle.context.timing_engine

	# ── 主攻击 PRE：p012 e01 确认窗（挂起主攻击）──
	te.resume_pending_effect(main_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	var main_attack = ar.get_action(main_id)
	if main_attack == null:
		return "e01 确认后主攻击不应消失"
	if not bool(main_attack.record.get("_effect_flags", {}).get("pilot_012_effect_01_fired", {}).get("value", false)):
		return "e01 确认后应写 flag 到主攻击 record"
	if String(main_attack.state) != &"waiting_effect_action":
		return "主攻击应在 e01 后等待 fork，实=%s" % String(main_attack.state)
	# e01 生效（fork 掉血压低上限前）：两台敌机当前动力各-3（不降上限）
	if enemy1.power != e1_power0 - 3:
		return "e01 应使 enemy1 动力-3（%d->%d）实=%d" % [e1_power0, e1_power0 - 3, enemy1.power]
	if enemy2.power != e2_power0 - 3:
		return "e01 应使 enemy2 动力-3（%d->%d）实=%d" % [e2_power0, e2_power0 - 3, enemy2.power]

	# ── fork1 / fork2：AFTER e02 确认（抽1+回3）+ 损伤放置 ──
	for i in range(2):
		main_attack = ar.get_action(main_id)
		if main_attack == null:
			return "fork%d 前主攻击不应消失" % (i + 1)
		var fork_id := _find_pending_fork(battle, main_attack)
		if fork_id == &"":
			return "未派生 fork%d" % (i + 1)
		var ferr := await _drive_fork(battle, fork_id, true)
		if ferr != "":
			return "fork%d 驱动失败：%s" % [(i + 1), ferr]
		# 通知主攻击派生下一 fork / 完成
		ae.notify_effect_action_completed(fork_id, main_id)
		await _pump_frames(5)

	# ── 主攻击整体完成（不死锁）──
	var main_final = ar.get_action(main_id)
	if main_final != null and String(main_final.state) != &"completed":
		return "主攻击应完成，实=%s" % String(main_final.state)
	# e02 生效：2 次命中奖励 -> 抽2 + 动力 4+6=10（玩家是攻击方不受损伤影响）
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after != hand_before + 1:
		return "双连弃1出1+e02 抽2 -> 手牌应净+1，前=%d 后=%d" % [hand_before, hand_after]
	if player_mech.power != 10:
		return "e02 两回合计+6动力（4->10）实=%d" % player_mech.power
	# 两台敌机均掉血
	if enemy1.current_hp >= e1_hp0:
		return "enemy1 应掉血 实=%d（前=%d）" % [enemy1.current_hp, e1_hp0]
	if enemy2.current_hp >= e2_hp0:
		return "enemy2 应掉血 实=%d（前=%d）" % [enemy2.current_hp, e2_hp0]
	print("P012-DUAL-OK 全链完成 e01动力-3×2 e02抽2回6 主攻完成")
	return true


# ═══════════════════════════════════════════
# p013 巴托洛夫：双连全链（PRE e02a 确认 -> 2 fork AFTER e02b +3 -> 完成）
# ═══════════════════════════════════════════
func test_p013_dual_full_chain_no_deadlock() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup_dual(battle, "pilot_013_巴托洛夫")
	if s.has("err"):
		return s["err"]
	var gs = s["gs"]
	var player_mech = s["player_mech"]
	var enemy1 = s["enemy1"]
	var enemy2 = s["enemy2"]
	# 满动力基准（e02a 双降上限+当前，各-4）
	player_mech.power = player_mech.max_power
	enemy1.power = enemy1.max_power
	var p_max0: int = player_mech.max_power
	var p_power0: int = player_mech.power
	var e1_max0: int = enemy1.max_power
	var e1_power0: int = enemy1.power
	var e2_max0: int = enemy2.max_power
	var e2_power0: int = enemy2.power
	var e1_hp0: int = enemy1.current_hp
	var e2_hp0: int = enemy2.current_hp

	var start := await _start_dual_and_reach_pre(battle, s)
	if start.has("err"):
		return start["err"]
	var main_id: StringName = start["main_id"]
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var te = battle.context.timing_engine

	# ── 主攻击 PRE：p013 e02a 确认窗（挂起主攻击）──
	te.resume_pending_effect(main_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	var main_attack = ar.get_action(main_id)
	if main_attack == null:
		return "e02a 确认后主攻击不应消失"
	if not bool(main_attack.record.get("_effect_flags", {}).get("pilot_013_effect_02_fired", {}).get("value", false)):
		return "e02a 确认后应写 flag 到主攻击 record"
	if String(main_attack.state) != &"waiting_effect_action":
		return "主攻击应在 e02a 后等待 fork，实=%s" % String(main_attack.state)
	# e02a 生效（fork 掉血压低上限前）：自身+全部目标 动力上限/当前动力各-4（clamp）
	if player_mech.power != p_power0 - 4 or player_mech.max_power != p_max0 - 4:
		return "e02a 应使自身动力/上限-4，实=%d/%d（前=%d/%d）" % [player_mech.power, player_mech.max_power, p_power0, p_max0]
	if enemy1.power != e1_power0 - 4 or enemy1.max_power != e1_max0 - 4:
		return "e02a 应使 enemy1 动力/上限-4，实=%d/%d（前=%d/%d）" % [enemy1.power, enemy1.max_power, e1_power0, e1_max0]
	if enemy2.power != e2_power0 - 4 or enemy2.max_power != e2_max0 - 4:
		return "e02a 应使 enemy2 动力/上限-4，实=%d/%d（前=%d/%d）" % [enemy2.power, enemy2.max_power, e2_power0, e2_max0]
	# fork 伤害期望值快照：威力 - 减益后护甲 + e02b 3（fork 各自结算前目标无损伤标记）
	var weapon_might: int = int(main_attack.record.get("weapon_might", 0))
	var e1_expected: int = max(0, weapon_might - enemy1.get_armor()) + 3
	var e2_expected: int = max(0, weapon_might - enemy2.get_armor()) + 3

	# ── fork1 / fork2：AFTER e02b +3（自动无弹窗）+ 损伤放置 ──
	var fork_damages: Array = []
	for i in range(2):
		main_attack = ar.get_action(main_id)
		if main_attack == null:
			return "fork%d 前主攻击不应消失" % (i + 1)
		var fork_id := _find_pending_fork(battle, main_attack)
		if fork_id == &"":
			return "未派生 fork%d" % (i + 1)
		var fork_ref = ar.get_action(fork_id)
		var ferr := await _drive_fork(battle, fork_id, false)
		if ferr != "":
			return "fork%d 驱动失败：%s" % [(i + 1), ferr]
		fork_damages.append(int(fork_ref.record.get("damage", 0)))
		ae.notify_effect_action_completed(fork_id, main_id)
		await _pump_frames(5)

	# ── 主攻击整体完成（不死锁）──
	var main_final = ar.get_action(main_id)
	if main_final != null and String(main_final.state) != &"completed":
		return "主攻击应完成，实=%s" % String(main_final.state)
	# e02b 生效：每个 fork 的 record.damage = max(0, 威力-护甲) + 3（flag 继承）
	if fork_damages.size() != 2:
		return "应有两个 fork，实=%d" % fork_damages.size()
	if int(fork_damages[0]) != e1_expected:
		return "fork1(enemy1) damage 应=%d（威力%d-护甲+3）实=%d" % [e1_expected, weapon_might, int(fork_damages[0])]
	if int(fork_damages[1]) != e2_expected:
		return "fork2(enemy2) damage 应=%d（威力%d-护甲+3）实=%d" % [e2_expected, weapon_might, int(fork_damages[1])]
	# 两台敌机均掉血（e02b +3 参与结算）
	if enemy1.current_hp >= e1_hp0:
		return "enemy1 应掉血 实=%d（前=%d）" % [enemy1.current_hp, e1_hp0]
	if enemy2.current_hp >= e2_hp0:
		return "enemy2 应掉血 实=%d（前=%d）" % [enemy2.current_hp, e2_hp0]
	print("P013-DUAL-OK 全链完成 e02a 动力-4×3 e02b +3 damages=%s 主攻完成" % str(fork_damages))
	return true
