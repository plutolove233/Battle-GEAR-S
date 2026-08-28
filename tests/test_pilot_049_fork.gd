extends RefCounted

## test_pilot_049_fork.gd - 杰狞(pilot_049)在场时双连 fork 攻击阻塞复现
##
## Bug4：双连 fork 攻击经常阻塞，卡在损伤放置阶段（与杰狞在场有关）。
## 最可能触发场景：敌方机甲持有杰狞，玩家用双连打第三方目标（距敌方杰狞 4 格内）
## → fork 的 hp_change 触发杰狞伤害转移 CHOOSE_ONE 弹窗 → 验证恢复后 fork 是否继续
## 走 damage_change 损伤放置并完成。
##
## 布局：
##   player(2,2) ── 双连打 [enemy2, enemy1]
##   enemy1(3,2) = 敌方杰狞持有者
##   enemy2(3,3) = 第三方（距 enemy1 杰狞 1 格，fork1 目标 → 触发转移弹窗）
##   fork2 打 enemy1 = 杰狞自己被攻击（target==绑定机甲，不触发转移）

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	# PvP 双人类玩家：同种子 + 地图特征 + enemy 人类（Bug4 实机场景；AI 会自动决策弹窗干扰复现）
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


## 给指定机甲设杰狞（set_pilot 注册 LISTEN 永久监听器）。
## 成功返回 Dictionary {"card": 卡实例}；失败返回 {"err": 错误串}。
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


## 把指定 card_def_id 的行动牌塞入玩家手牌
func _ensure_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
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


## 创建第 2 台敌方机甲
func _create_second_enemy(battle: BattleState, mech_id: StringName, pos: Dictionary) -> MechState:
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


## 找到主攻击动作（use_action_card 的 attack 类型子动作）
func _find_main_attack(battle: BattleState) -> StringName:
	var ar = battle.context.action_registry
	for aid in ar.get_active_ids():
		var a = ar.get_action(aid)
		if a and a.action_type == &"attack":
			return aid
	return &""


## 找到主攻击当前 pending 的复制攻击（attack 类型子动作）id
func _find_pending_fork(battle: BattleState, main_attack) -> StringName:
	var ar = battle.context.action_registry
	for fid: StringName in main_attack.pending_effect_action_ids:
		var sub = ar.get_action(fid)
		if sub != null and sub.action_type == &"attack":
			return fid
	return &""


## 找到 fork 攻击 pending 里指定类型的子动作 id（state 匹配可选）
func _find_pending_sub(battle: BattleState, fork, sub_type: StringName, want_state: StringName) -> StringName:
	var ar = battle.context.action_registry
	for cid: StringName in fork.pending_effect_action_ids:
		var sub = ar.get_action(cid)
		if sub != null and sub.action_type == sub_type:
			if want_state == &"" or sub.state == want_state:
				return cid
	return &""


## 驱动 fork 攻击的损伤放置子动作完成（同步通知）
func _drive_damage_placement(battle: BattleState, attack_id: StringName, verbose: bool = false) -> Dictionary:
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
		if verbose:
			print("  [驱动损伤] %s amount=%d mechs=%s" % [String(dc_id), amount, str(mech_ids)])
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)
	return {"ok": true}


## 通用驱动：处理 fork 内的 hp_change 杰狞转移弹窗 + damage_change 损伤放置，
## 使 fork 走完剩余步骤。verbose 时打印每步状态供诊断。
func _drive_fork_with_jiening(battle: BattleState, fork_id: StringName, verbose: bool = false) -> String:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var te = battle.context.timing_engine
	var fork = ar.get_action(fork_id)
	if fork == null:
		return "fork 不存在 %s" % String(fork_id)
	# 通用转移注入后（GameSetupService 为每机甲注册 transfer_attack_target），fork 的 ATTACK_AT
	# 可能弹转移目标窗口（相邻友方在攻击范围即可转移，规则书第33行）。本测试聚焦杰狞伤害转移
	# （hp_change），pass 放弃攻击目标转移权，让 fork 继续到 ATTACK_AFTER（杰狞受伤 -> 伤害转移弹窗）。
	var _pass_sel: Array[Dictionary] = []
	while String(fork.state) == &"waiting_timing" and fork.record.get("has_response_window", false):
		te.handle_response_selection(fork_id, _pass_sel, &"enemy")
		var _awt = Engine.get_main_loop() as SceneTree
		if _awt != null:
			await _awt.process_frame
		fork = ar.get_action(fork_id)
		if fork == null:
			return "fork pass 转移窗口后消失"
	var steps: Array = []
	# 记录当前 fork 步骤：确认 hp_change 挂起 → resume；再驱动 damage_change
	var hp_id := _find_pending_sub(battle, fork, &"hp_change", &"waiting_timing")
	if hp_id != &"":
		var hp = ar.get_action(hp_id)
		steps.append("hp_change 挂起于杰狞转移弹窗 state=%s" % String(hp.state))
		# 确认转移（chosen_option_index=0 为第一个选项=转移）
		te.resume_pending_effect(hp_id, {"chosen_option_index": 0})
		if verbose:
			print("  [转移] resume %s -> 确认转移" % String(hp_id))
		# 等 hp_change 走完（HP_CHANGE_AFTER 扣血 + SETTLE 计数）并通知 fork
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			for _i in 10:
				await tree.process_frame
		var hp_after = ar.get_action(hp_id)
		steps.append("hp_change 恢复后 state=%s value=%d mechs=%s" % [
			String(hp_after.state if hp_after != null else &"gone"),
			int(hp.record.get("value", 0)) if hp != null else -1,
			str(hp.record.get("mech_ids", [])) if hp != null else &"",
		])
	# fork 在 hp_change 完成后可能继续派生 damage_change（或已完成/等待）
	var ret: Dictionary = _drive_damage_placement(battle, fork_id, verbose)
	if not ret.get("ok", false):
		return str(ret.get("msg", "损伤放置驱动失败"))
	fork = ar.get_action(fork_id)
	var _fs: String = &"gone" if fork == null else String(fork.state)
	var _fc: int = -1 if fork == null else fork.current_step_index
	steps.append("fork 最终 state=%s csi=%d" % [_fs, _fc])
	return " | ".join(steps)


## 读杰狞受伤计数 X
func _get_x_from_card(card) -> int:
	if card == null:
		return -1
	var counters = card.counters
	if counters == null:
		return 0
	return int(counters.get("var_pilot_049_x", 0))


# ═══════════════════════════════════════════
# Bug4 复现：敌方杰狞在场 + 双连打第三方（距杰狞 4 格内）
# ═══════════════════════════════════════════
func test_p049_fork_enemy_jiening_transfer() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy1_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy1_mech == null:
		return "找不到玩家/敌方机甲"
	# 敌方杰狞（持有者 = enemy1）
	var setup_ret := _setup_jiening_on_mech(battle, enemy1_mech.mech_id, &"enemy")
	if setup_ret.has("err"):
		return setup_ret["err"]
	battle.context.action_ui_bridge.context = battle.context
	# 第 2 台敌方机甲（第三方，fork1 目标）
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 3, "r": 1})
	player_mech.position = {"q": 2, "r": 2}
	enemy1_mech.position = {"q": 3, "r": 2}
	enemy2_mech.position = {"q": 3, "r": 1}
	# 清空地形 + 敌方迎击牌（避免 ATTACK_AT 响应窗口干扰 fork 驱动）
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var dual_id = _ensure_card_in_hand(battle, "action_005_双连")
	if dual_id == &"":
		return "牌堆/弃牌堆中找不到 双连"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]
	var enemy2_hp_before: int = enemy2_mech.current_hp
	var enemy1_hp_before: int = enemy1_mech.current_hp
	# 诊断：范围判定（多目标校验用 BFS）
	for tid in [enemy2_mech.mech_id, enemy1_mech.mech_id]:
		var tm = gs.mechs.get(tid)
		var in_rng: bool = _RangeCalculator.is_in_weapon_range(player_mech.position, tm.position, 2, gs.map_state.cells)
		print("P049FORK-RANGE %s pos=%s vs player %s in_range=%s" % [String(tid), str(tm.position), str(player_mech.position), str(in_rng)])

	battle.execute_use_action_card(&"player", dual_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a_id := _find_main_attack(battle)
	if attack_a_id == &"":
		return "找不到主攻击动作"
	var attack_a = ar.get_action(attack_a_id)
	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	# 目标顺序：enemy2 先（fork1，距杰狞 1 格 → 触发转移弹窗），enemy1 后（fork2）
	ae.continue_action(attack_a_id, {"target_ids": [enemy2_mech.mech_id, enemy1_mech.mech_id]})

	if String(attack_a.state) != &"waiting_effect_action":
		print("P049FORK-STATUS main_attack state=%s csi=%d record=%s" % [String(attack_a.state), attack_a.current_step_index, str(attack_a.record)])
		return "主攻击应在 fork 后暂停 waiting_effect_action，实际 state=%s" % String(attack_a.state)

	# ── fork1 = enemy2（第三方）──
	var fork1_id := _find_pending_fork(battle, attack_a)
	if fork1_id == &"":
		return "未派生 fork1"
	var fork1 = ar.get_action(fork1_id)
	if String(fork1.record.get("target_id", &"")) != String(enemy2_mech.mech_id):
		return "fork1 目标应为 enemy2，实际=%s" % String(fork1.record.get("target_id", &""))
	# 通用转移注入后 fork1 ATTACK_AT 弹转移目标窗口（杰狞 enemy1 相邻 enemy2 且在 player 范围），
	# pass 放弃转移让 fork1 继续到 ATTACK_AFTER（杰狞受伤 -> hp_change 挂起于伤害转移弹窗）。
	var _f1_pass: Array[Dictionary] = []
	while String(fork1.state) == &"waiting_timing" and fork1.record.get("has_response_window", false):
		battle.context.timing_engine.handle_response_selection(fork1_id, _f1_pass, &"enemy")
		var _f1wt = Engine.get_main_loop() as SceneTree
		if _f1wt != null:
			await _f1wt.process_frame
		fork1 = ar.get_action(fork1_id)
	# fork1 应已创建 hp_change 并因杰狞转移弹窗挂起（waiting_timing）
	var fork1_hp := _find_pending_sub(battle, fork1, &"hp_change", &"waiting_timing")
	if fork1_hp == &"":
		return "fork1 的 hp_change 未挂起于杰狞转移弹窗（state=%s pending=%s）——Bug4 未按预期复现" % [String(fork1.state), str(fork1.pending_effect_action_ids)]

	# 驱动 fork1：确认转移 → 损伤放置 → 完成 → 通知主攻击派生 fork2
	var diag1: String = await _drive_fork_with_jiening(battle, fork1_id, true)
	# enemy2 应受伤害（或转移后杰狞 enemy1 受伤）
	ae.notify_effect_action_completed(fork1_id, attack_a_id)
	var main_after1 = ar.get_action(attack_a_id)
	if main_after1 == null:
		return "fork1 完成后主攻击消失（不应整体完成，还有 fork2）：diag1=%s" % diag1
	var fork2_id := _find_pending_fork(battle, main_after1)
	if fork2_id == &"":
		return "fork1 完成后应派生 fork2：diag1=%s" % diag1
	var fork2 = ar.get_action(fork2_id)
	if String(fork2.record.get("target_id", &"")) != String(enemy1_mech.mech_id):
		return "fork2 目标应为 enemy1，实际=%s" % String(fork2.record.get("target_id", &""))

	# ── fork2 = enemy1（杰狞自己被攻击，不触发转移）──
	var diag2: String = await _drive_fork_with_jiening(battle, fork2_id, true)
	ae.notify_effect_action_completed(fork2_id, attack_a_id)

	# 主攻击应整体完成
	var main_final = ar.get_action(attack_a_id)
	if main_final != null and main_final.state != &"completed":
		return "主攻击应在 fork2 完成后完成，state=%s diag1=%s diag2=%s" % [String(main_final.state), diag1, diag2]
	print("P049-FORK-OK diag1=[%s] diag2=[%s]" % [diag1, diag2])
	return true


# ═══════════════════════════════════════════
# Bug4 复现：玩家杰狞（X=1）+ 双连打 2 台（攻击方加伤路径）
# ═══════════════════════════════════════════
func test_p049_fork_player_jiening_boost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy1_mech = gs.mechs.get(&"enemy_mech")
	if player_mech == null or enemy1_mech == null:
		return "找不到玩家/敌方机甲"
	# 玩家杰狞 + 受伤计数 X=1
	var setup_ret := _setup_jiening_on_mech(battle, player_mech.mech_id, &"player")
	if setup_ret.has("err"):
		return setup_ret["err"]
	var jiening_card = setup_ret["card"]
	jiening_card.counters = {"var_pilot_049_x": 1}
	battle.context.action_ui_bridge.context = battle.context
	# 第 2 台敌方机甲（fork2 目标）
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech", {"q": 3, "r": 1})
	var enemy1_hp_before: int = enemy1_mech.current_hp
	var enemy2_hp_before: int = enemy2_mech.current_hp
	player_mech.position = {"q": 2, "r": 2}
	enemy1_mech.position = {"q": 3, "r": 2}
	enemy2_mech.position = {"q": 3, "r": 1}
	# 清空地形 + 敌方迎击牌（避免 ATTACK_AT 响应窗口干扰）
	for key in gs.map_state.cells:
		gs.map_state.cells[key].terrain = &"NORMAL"
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var dual_id = _ensure_card_in_hand(battle, "action_005_双连")
	if dual_id == &"":
		return "牌堆/弃牌堆中找不到 双连"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]

	battle.execute_use_action_card(&"player", dual_id)
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a_id := _find_main_attack(battle)
	if attack_a_id == &"":
		return "找不到主攻击动作"
	var attack_a = ar.get_action(attack_a_id)
	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	# fork1=enemy1（先，杰狞加伤），fork2=enemy2（X 已清零）
	ae.continue_action(attack_a_id, {"target_ids": [enemy1_mech.mech_id, enemy2_mech.mech_id]})

	if String(attack_a.state) != &"waiting_effect_action":
		return "主攻击应在 fork 后暂停 waiting_effect_action，实际 state=%s" % String(attack_a.state)

	# ── fork1 = enemy1（杰狞 X=1 加伤 +4）──
	var fork1_id := _find_pending_fork(battle, attack_a)
	if fork1_id == &"":
		return "未派生 fork1"
	var fork1 = ar.get_action(fork1_id)
	if String(fork1.record.get("target_id", &"")) != String(enemy1_mech.mech_id):
		return "fork1 目标应为 enemy1，实际=%s" % String(fork1.record.get("target_id", &""))
	var diag1: String = await _drive_fork_with_jiening(battle, fork1_id, true)
	# effect_01 不应触发（杰狞自己造成的伤害，record.source 修复后来源=绑定机甲）
	if diag1.find("转移弹窗") != -1:
		return "杰狞自己攻击不应触发转移弹窗，diag1=%s" % diag1
	# effect_02 加伤：hp_change 初始 value=5（10-敌方护甲5），+4*X → 回写 fork1.record.damage=9，X 清零
	var fork1_damage: int = int(fork1.record.get("damage", 0))
	if fork1_damage != 9:
		return "fork1 record.damage 应回写=5+4=9，实=%d：diag1=%s" % [fork1_damage, diag1]
	if _get_x_from_card(jiening_card) != 0:
		return "加成后 X 应清零=0，实=%d：diag1=%s" % [_get_x_from_card(jiening_card), diag1]
	if enemy1_mech.current_hp != enemy1_hp_before - 9:
		return "enemy1 应掉血 5+4=9（HP %d->%d），实=%d：diag1=%s" % [enemy1_hp_before, enemy1_hp_before - 9, enemy1_mech.current_hp, diag1]
	ae.notify_effect_action_completed(fork1_id, attack_a_id)
	var main_after1 = ar.get_action(attack_a_id)
	if main_after1 == null:
		return "fork1 完成后主攻击消失（应还有 fork2）：diag1=%s" % diag1
	var fork2_id := _find_pending_fork(battle, main_after1)
	if fork2_id == &"":
		return "fork1 完成后应派生 fork2：diag1=%s" % diag1
	var fork2 = ar.get_action(fork2_id)
	if String(fork2.record.get("target_id", &"")) != String(enemy2_mech.mech_id):
		return "fork2 目标应为 enemy2，实际=%s" % String(fork2.record.get("target_id", &""))

	# ── fork2 = enemy2（X 已清零，不加伤）──
	var diag2: String = await _drive_fork_with_jiening(battle, fork2_id, true)
	if diag2.find("转移弹窗") != -1:
		return "fork2 不应触发转移弹窗，diag2=%s" % diag2
	if enemy2_mech.current_hp != enemy2_hp_before - 10:
		return "enemy2 应掉血 10（X=0 不加伤，HP %d->%d），实=%d：diag2=%s" % [enemy2_hp_before, enemy2_hp_before - 10, enemy2_mech.current_hp, diag2]
	ae.notify_effect_action_completed(fork2_id, attack_a_id)
	var main_final = ar.get_action(attack_a_id)
	if main_final != null and main_final.state != &"completed":
		return "主攻击应在 fork2 完成后完成，state=%s diag1=%s diag2=%s" % [String(main_final.state), diag1, diag2]
	print("P049-FORK-BOOST-OK diag1=[%s] diag2=[%s] X=%d enemy1_hp=%d enemy2_hp=%d" % [diag1, diag2, _get_x_from_card(jiening_card), enemy1_mech.current_hp, enemy2_mech.current_hp])
	return true
