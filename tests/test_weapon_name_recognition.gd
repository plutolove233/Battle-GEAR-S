extends RefCounted

## 武器名称/类型识别测试（问题2修复验证）
##
## 白马右臂 effect_036：使用名称带"光束"的近战武器攻击时，威力+3。
## 修复前：攻击 record 只存 weapon_id，无 weapon_name -> ConditionChecker 的
##   WEAPON_NAME_CONTAINS 读 payload.weapon_name 永远为空 -> effect_036/037/042/043
##   (白马臂/赤枭臂) 及 068/073 (圣牛臂/雄鹰臂) 等读武器名的效果从不触发
##   (条件 AND，名称失败则整个效果不发动，"名称和类型都识别不到"的表象)。
## 修复后：attack_action._get_weapon_stats 返回 weapon_name(display_name)，
##   _step_select_weapon 写入 record，ATTACK_BEFORE 起 payload 含 weapon_name，
##   WEAPON_NAME_CONTAINS 正确识别光束/热能。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


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


## 把指定 card_def_id 的装备牌塞入玩家装备手牌，返回卡牌实例ID
func _ensure_equipment_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.equipment_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.equipment_deck.size()):
		var cid: StringName = gs.deck_state.equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			return cid
	for i in range(gs.deck_state.advanced_equipment_deck.size()):
		var cid: StringName = gs.deck_state.advanced_equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.advanced_equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			return cid
	return &""


## 把指定 card_def_id 的行动牌塞入玩家行动手牌，返回卡牌实例ID
func _ensure_action_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
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
	return &""


func _pump_frames(n: int) -> void:
	for i in range(n):
		await Engine.get_main_loop().process_frame


## 主测试：装备光束军刀(近战光束) + 白马右臂(effect_036) -> 攻击时 weapon_name 被识别，
## effect_036 触发 extra_might +3。修复前 weapon_name 为空、extra_might=0。
func test_beam_weapon_name_recognized_for_whitemane_arm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到机甲"

	# 装备光束军刀（近战 + 名称含"光束"）到 weapon_1
	var weapon_id := _ensure_equipment_in_hand(battle, "weapon_001_光束军刀")
	if weapon_id == &"":
		return "找不到光束军刀装备牌"
	var wres: Dictionary = battle.context.card_set_service.set_equipment(&"player", weapon_id, &"weapon_1")
	if not wres.get("ok", false):
		return "装备光束军刀失败: %s" % String(wres.get("message", ""))
	await _pump_frames(3)

	# 装备白马右臂（effect_036：光束近战武器攻击威力+3）
	var arm_id := _ensure_equipment_in_hand(battle, "part_051_联邦的白马_右臂")
	if arm_id == &"":
		return "找不到白马右臂装备牌"
	var ares: Dictionary = battle.context.card_set_service.set_equipment(&"player", arm_id, &"右臂")
	if not ares.get("ok", false):
		return "装备白马右臂失败: %s" % String(ares.get("message", ""))
	await _pump_frames(3)

	# 敌方放入射程内（相邻格）+ 清空迎击牌，避免 ATTACK_AT 响应窗口拦截
	enemy_mech.position = {"q": 3, "r": 2}
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	# 打出基础攻击牌 -> use_action_card -> 创建 attack A -> select_weapon 暂停
	var card_id := _ensure_action_card_in_hand(battle, "action_001_进攻")
	if card_id == &"":
		return "找不到进攻牌"
	battle.execute_use_action_card(&"player", card_id)

	# 找到 attack A 效果动作
	var attack_a = null
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a = a
			break
	if attack_a == null:
		return "attack A 未创建"

	# 选武器：光束军刀。select_weapon 重跑写入 weapon_name/effective_weapon_type，
	# fire ATTACK_BEFORE -> effect_036(SELF_MECH_IS_ATTACKER + 近战 + 光束) 触发 +3
	battle.context.action_engine.continue_action(attack_a.action_id, {"weapon_id": weapon_id})

	# 断言1：record.weapon_name 含"光束"（修复前为空字符串）
	var weapon_name: String = String(attack_a.record.get("weapon_name", &""))
	if weapon_name.find("光束") < 0:
		return "weapon_name 应含'光束'，实际: '%s'（weapon_name 未写入 record）" % weapon_name

	# 断言2：effective_weapon_type = 近战（类型识别）
	var eff_type: String = String(attack_a.record.get("effective_weapon_type", &""))
	if eff_type != "近战":
		return "effective_weapon_type 应='近战'，实际: '%s'" % eff_type

	# 断言3：effect_036 触发，extra_might >= 3（光束+近战+自身攻击条件全满足）
	var extra_might: int = int(attack_a.record.get("extra_might", 0))
	if extra_might < 3:
		return "effect_036 应使 extra_might>=3，实际: %d（WEAPON_NAME_CONTAINS 仍未识别或条件未通过）" % extra_might

	return true


## 反向测试：非光束武器（破甲狼爪 weapon_003，近战但名称不含光束）不应触发 effect_036。
## 验证 WEAPON_NAME_CONTAINS 是真子串匹配，而非永远 true。
func test_non_beam_weapon_does_not_trigger_whitemane_arm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到机甲"

	# 装备破甲狼爪（近战，名称不含"光束"）
	var weapon_id := _ensure_equipment_in_hand(battle, "weapon_003_破甲狼爪")
	if weapon_id == &"":
		return "找不到破甲狼爪装备牌"
	var wres: Dictionary = battle.context.card_set_service.set_equipment(&"player", weapon_id, &"weapon_1")
	if not wres.get("ok", false):
		return "装备破甲狼爪失败: %s" % String(wres.get("message", ""))
	await _pump_frames(3)

	# 装备白马右臂（effect_036）
	var arm_id := _ensure_equipment_in_hand(battle, "part_051_联邦的白马_右臂")
	if arm_id == &"":
		return "找不到白马右臂装备牌"
	var ares: Dictionary = battle.context.card_set_service.set_equipment(&"player", arm_id, &"右臂")
	if not ares.get("ok", false):
		return "装备白马右臂失败: %s" % String(ares.get("message", ""))
	await _pump_frames(3)

	enemy_mech.position = {"q": 3, "r": 2}
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var card_id := _ensure_action_card_in_hand(battle, "action_001_进攻")
	if card_id == &"":
		return "找不到进攻牌"
	battle.execute_use_action_card(&"player", card_id)

	var attack_a = null
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a = a
			break
	if attack_a == null:
		return "attack A 未创建"

	battle.context.action_engine.continue_action(attack_a.action_id, {"weapon_id": weapon_id})

	# weapon_name 应为"破甲狼爪"（不含光束），effect_036 不应触发
	var weapon_name: String = String(attack_a.record.get("weapon_name", &""))
	if weapon_name.find("光束") >= 0:
		return "破甲狼爪 weapon_name 不应含'光束'，实际: '%s'" % weapon_name
	var extra_might: int = int(attack_a.record.get("extra_might", 0))
	if extra_might >= 3:
		return "非光束武器不应触发 effect_036，extra_might 应<3，实际: %d" % extra_might

	return true
