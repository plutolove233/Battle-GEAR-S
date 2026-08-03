## test_energy_charge_might.gd - 聚能威力加成真实流程验证
##
## 修复前：聚能状态效果1（energy_status_might）用 value_multiplier_by_stacks 表达"威力+4*X"，
## 但 ActionService._extract_stat_mod_params 只读 params.value(=0)，value_multiplier_by_stacks
## 从未被解析 -> stat_modify 动作 _step_execute_mod 见 value==0 提前返回 -> 聚能永不加威力。
## 修复后：_extract_stat_mod_params 检测到 value_multiplier_by_stacks 时，按 payload.binding_context
## 定位的状态层数算出 value = multiplier * stacks，写入 record，extra_might 正确增加。
##
## 验证点：
##   1. 聚能后用该武器攻击，attack.record.extra_might == 4，伤害含 +4（基础武器/装备牌武器通用）
##   2. 攻击结算后 ENERGY_CHARGE 状态被清除（effect2 在 ATTACK_SETTLE 触发 remove_all）
##   3. 叠加2层聚能 -> extra_might == 8（value_multiplier_by_stacks 读 stacks=2）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


## 推进若干帧，使 call_deferred 排入的恢复调用执行（动作父子链恢复靠 deferred）
func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


## 把指定 card_def_id 的牌塞入玩家手牌，返回 card_instance_id
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
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 打出聚能并选指定武器，施加 ENERGY_CHARGE。返回是否成功。
func _play_energy_charge(battle: BattleState, weapon_id: StringName) -> bool:
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	var card_id := _ensure_card_in_hand(battle, "action_014_聚能")
	if card_id == &"":
		return false
	battle.context.action_ui_bridge.context = battle.context
	battle.execute_use_action_card(&"player", card_id)
	var bridge = battle.context.action_ui_bridge
	var w = bridge.get_waiting_action_info() if bridge else {}
	if w.get("input_type", &"") != &"select_weapon_for_charge":
		return false
	bridge.on_ui_confirmed({"selected_weapon_id": weapon_id})
	return true


## 驱动 attack 的损伤设置效果动作完成（damage_change 暂停在 place_damage_tokens）。
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 15:
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
			# 暂存的是已完成但 deferred 未 flush 的效果动作（如聚能 stat_modify）：通知完成以推进
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			await _pump_frames(1)
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


## 统计一台机甲所有槽位上的损伤标记总数
func _count_damage_tokens(mech) -> int:
	if mech == null:
		return 0
	var total: int = 0
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null:
			total += int(slot.region_damage_tokens)
	return total


## 找到当前活跃的 attack 动作
func _find_attack(battle: BattleState):
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			return a
	return null


## ── 聚能：选武器施加状态 -> 用该武器攻击 -> extra_might=4 / 伤害含+4 / 结算后清除 ──
func test_energy_charge_adds_might_and_clears():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"

	# 敌方放到玩家相邻格（在基础武器射程1内），清空敌方手牌避免 ATTACK_AT 响应窗口
	var pp = player_mech.position
	enemy_mech.position = {"q": int(pp["q"]) + 1, "r": int(pp["r"])}
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无可用武器"
	var weapon_id = weapon_ids[0]
	print("[ENERGY-MIGHT] 测试武器 = ", String(weapon_id), "（基础武器=", String(weapon_id).begins_with("frame_base_weapon_"), "）")

	# ① 打出聚能，选该武器
	if not _play_energy_charge(battle, weapon_id):
		return "聚能未挂起 select_weapon_for_charge 或施加失败"
	await _pump_frames(2)

	# ② ENERGY_CHARGE 状态已施加到该武器（stacks=1）
	var stacks := 0
	for s: Dictionary in player_mech.statuses:
		if s.get("type", &"") == &"ENERGY_CHARGE" and s.get("weapon_id", &"") == weapon_id:
			stacks = int(s.get("stacks", 1))
			break
	if stacks != 1:
		return "聚能状态应 stacks=1，实际: %d（statuses=%s）" % [stacks, str(player_mech.statuses)]

	# ③ 用该武器发起攻击（weapon_id+target_id 预填，敌方无响应牌 -> 一路跑到 apply_damage）
	var enemy_hp_before: int = enemy_mech.current_hp
	var enemy_armor: int = int(enemy_mech.get_armor())
	battle.execute_attack_action(&"player", &"enemy", weapon_id, &"")
	await _pump_frames(5)

	var attack_a = _find_attack(battle)
	if attack_a == null:
		return "攻击动作未创建或已完成（找不到 attack A）"

	# ④ extra_might 必须为 4（聚能状态效果1 在 ATTACK_BEFORE 触发并写入）
	var extra_might: int = int(attack_a.record.get("extra_might", 0))
	if extra_might != 4:
		return "聚能应写 extra_might=4，实际: %d（value_multiplier_by_stacks 未解析或监听器未触发）" % extra_might

	# ⑤ calculate_damage 必须把 extra_might 计入伤害
	var weapon_might: int = int(attack_a.record.get("weapon_might", 0))
	var expected_damage: int = max(0, weapon_might + 4 - enemy_armor)
	var damage: int = int(attack_a.record.get("damage", -1))
	if damage != expected_damage:
		return "聚能 damage 应=%d (weapon_might %d + extra_might 4 - armor %d)，实际: %d" % [expected_damage, weapon_might, enemy_armor, damage]

	# ⑥ 驱动损伤设置完成 -> ATTACK_SETTLE fire -> 聚能状态效果2 清除
	var drive_ret: Dictionary = await _drive_damage_placement(battle, attack_a.action_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "损伤设置驱动失败")
	await _pump_frames(5)

	# ⑦ 攻击结算后 ENERGY_CHARGE 应被清除（effect2 在 ATTACK_SETTLE remove_all）
	var still_has := false
	for s: Dictionary in player_mech.statuses:
		if s.get("type", &"") == &"ENERGY_CHARGE" and s.get("weapon_id", &"") == weapon_id:
			still_has = true
			break
	if still_has:
		return "攻击结算后 ENERGY_CHARGE 应被清除，仍存在（statuses=%s）" % str(player_mech.statuses)
	return true


## ── 聚能叠加：同一武器打2张聚能 -> stacks=2 -> 攻击 extra_might=8 ──
func test_energy_charge_stacks_double_might():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"

	var pp = player_mech.position
	enemy_mech.position = {"q": int(pp["q"]) + 1, "r": int(pp["r"])}
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无可用武器"
	var weapon_id = weapon_ids[0]

	# 打出第一张聚能
	if not _play_energy_charge(battle, weapon_id):
		return "第一张聚能施加失败"
	await _pump_frames(2)
	# 打出第二张聚能（同一武器，stacks 应叠加为 2）
	if not _play_energy_charge(battle, weapon_id):
		return "第二张聚能施加失败"
	await _pump_frames(2)

	var stacks := 0
	for s: Dictionary in player_mech.statuses:
		if s.get("type", &"") == &"ENERGY_CHARGE" and s.get("weapon_id", &"") == weapon_id:
			stacks = int(s.get("stacks", 1))
			break
	if stacks != 2:
		return "叠加后 ENERGY_CHARGE 应 stacks=2，实际: %d" % stacks

	# 用该武器攻击 -> extra_might = 4 * 2 = 8
	battle.execute_attack_action(&"player", &"enemy", weapon_id, &"")
	await _pump_frames(5)
	var attack_a = _find_attack(battle)
	if attack_a == null:
		return "攻击动作未创建或已完成（找不到 attack A）"
	var extra_might: int = int(attack_a.record.get("extra_might", 0))
	if extra_might != 8:
		return "叠加2层聚能应 extra_might=8（4*2），实际: %d" % extra_might
	# 清理：驱动损伤设置到完成，避免残留 pending 影响后续测试
	await _drive_damage_placement(battle, attack_a.action_id)
	return true


## 统计某武器上的聚能状态层数（按 weapon_id 匹配）
func _energy_stacks_for_weapon(mech, weapon_id: StringName) -> int:
	if mech == null:
		return 0
	for s: Dictionary in mech.statuses:
		if s.get("type", &"") == &"ENERGY_CHARGE" and s.get("weapon_id", &"") == weapon_id:
			return int(s.get("stacks", 1))
	return 0


## ── 逐武器清除：聚能武器X+武器Y，用X攻击后只清X，Y保留 ──
## 验证 Bug A 修复：原 REMOVE_STATUS remove_all 会清该机甲所有武器的聚能。
func test_energy_charge_clears_only_attacking_weapon():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"
	var pp = player_mech.position
	enemy_mech.position = {"q": int(pp["q"]) + 1, "r": int(pp["r"])}
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.size() < 2:
		return "需要2把武器验证逐武器清除，实际: %d（%s）" % [weapon_ids.size(), str(weapon_ids)]
	var wid_a: StringName = weapon_ids[0]
	var wid_b: StringName = weapon_ids[1]

	# 直接对两把武器施加聚能（apply_energy_to_weapon 会注册状态监听器）
	battle.context.game_actions.apply_energy_to_weapon({"mech_id": player_mech.mech_id, "weapon_id": wid_a, "delta": 4})
	battle.context.game_actions.apply_energy_to_weapon({"mech_id": player_mech.mech_id, "weapon_id": wid_b, "delta": 4})
	await _pump_frames(2)
	if _energy_stacks_for_weapon(player_mech, wid_a) != 1 or _energy_stacks_for_weapon(player_mech, wid_b) != 1:
		return "施加后两把武器应各 stacks=1，实际 a=%d b=%d" % [_energy_stacks_for_weapon(player_mech, wid_a), _energy_stacks_for_weapon(player_mech, wid_b)]

	# 用 wid_a 攻击
	battle.execute_attack_action(&"player", &"enemy", wid_a, &"")
	await _pump_frames(5)
	var attack_a = _find_attack(battle)
	if attack_a == null:
		return "攻击动作未创建或已完成"
	var drive_ret: Dictionary = await _drive_damage_placement(battle, attack_a.action_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "损伤设置驱动失败")
	await _pump_frames(5)

	# wid_a 的聚能应清除，wid_b 的应保留
	if _energy_stacks_for_weapon(player_mech, wid_a) != 0:
		return "攻击武器A的聚能应被清除，仍存在 stacks=%d" % _energy_stacks_for_weapon(player_mech, wid_a)
	if _energy_stacks_for_weapon(player_mech, wid_b) != 1:
		return "未攻击武器B的聚能应保留 stacks=1，实际: %d（误清了其他武器）" % _energy_stacks_for_weapon(player_mech, wid_b)
	return true


## ── 回合末清除：聚能后结束持有者回合 -> 聚能状态全部移除 ──
func test_energy_charge_clears_on_turn_end():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "找不到玩家机甲"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无可用武器"
	var weapon_id = weapon_ids[0]

	# 施加聚能
	battle.context.game_actions.apply_energy_to_weapon({"mech_id": player_mech.mech_id, "weapon_id": weapon_id, "delta": 4})
	await _pump_frames(2)
	if _energy_stacks_for_weapon(player_mech, weapon_id) != 1:
		return "施加后聚能应 stacks=1，实际: %d" % _energy_stacks_for_weapon(player_mech, weapon_id)

	# 结束玩家回合 -> _clean_this_turn_durations 清除 THIS_TURN 聚能
	gs.active_player_id = &"player"
	battle.context.turn_service.end_turn(&"player")
	await _pump_frames(3)

	if _energy_stacks_for_weapon(player_mech, weapon_id) != 0:
		return "回合末聚能应被清除，仍存在 stacks=%d" % _energy_stacks_for_weapon(player_mech, weapon_id)
	return true
