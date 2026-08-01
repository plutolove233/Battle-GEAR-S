## test_armor_this_turn_fix.gd - P0-A: THIS_TURN 护甲+X 生效验证
##
## 根因：GameActions.modify_armor 把 THIS_TURN 护甲写成 ARMOR_MODIFIER 状态存入 mech.statuses，
## 但 MechState.get_armor() 不遍历 statuses -> 护甲不变 -> attack_action._step_calculate_damage
## 用 get_armor() 算伤害时护甲没变 -> 不减伤。影响 014/020/038/062/080/104 等牌。
##
## 修复：get_armor() 末尾累加 ARMOR_MODIFIER 状态 delta（排除 THIS_ATTACK，避免与 attack record
## temporary_armor_bonus 双计）。回末 _clean_this_turn_durations 移除 THIS_TURN 状态后自动还原。
##
## 验证点：
##   1. modify_armor THIS_TURN +4 后 get_armor() 增加 4（修复前为死状态，不计）
##   2. modify_armor THIS_ATTACK +5 不计入 get_armor（避免双计，由 attack record 单独处理）
##   3. 回末清理 THIS_TURN 后 get_armor() 还原
##   4. 真实攻击：目标带 THIS_TURN +4 护甲，伤害恰为 max(0, might - (base_armor+4))，
##      即比无加成少 4（证明 get_armor 被攻击伤害路径消费）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")


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


## 清空玩家行动手牌（注销监听器），避免敌方攻击时弹出响应窗口拦截
func _clear_player_hand(battle: BattleState) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	if player == null:
		return
	for cid: StringName in player.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	player.action_hand.clear()


## 给敌方一张攻击牌（优先 action_001_进攻，否则任意 攻击 牌）
func _ensure_attack_card_in_enemy_hand(battle: BattleState) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return &""
	# 优先指定进攻牌
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == "action_001_进攻":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == "action_001_进攻":
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	# 回退：任意 攻击 牌
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


func _set_enemy_first_weapon_might(enemy_mech, might: int) -> void:
	if not enemy_mech.base_weapons.is_empty():
		enemy_mech.base_weapons[0]["might"] = might
	var w1_slot = enemy_mech.slots.get(&"weapon_1") if enemy_mech.slots.has(&"weapon_1") else null
	if w1_slot != null and w1_slot.equipped_card != null and w1_slot.equipped_card.def != null:
		w1_slot.equipped_card.def.might = might


## 驱动 attack 损伤设置完成（damage_change 暂停在 place_damage_tokens）
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> Dictionary:
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


## ①②③ get_armor 直接验证：THIS_TURN 计入 / THIS_ATTACK 不双计 / 回末还原
func test_armor_this_turn_in_get_armor():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "找不到玩家机甲"
	var base_armor: int = int(player_mech.get_armor())

	# ① THIS_TURN +4 应计入 get_armor（修复前为死状态）
	battle.context.game_actions.modify_armor({
		"mech_id": player_mech.mech_id, "delta": 4, "duration": &"THIS_TURN"})
	if int(player_mech.get_armor()) != base_armor + 4:
		return "THIS_TURN +4 应计入 get_armor: 期望 %d, 实际 %d" % [base_armor + 4, int(player_mech.get_armor())]

	# ② THIS_ATTACK +5 不应计入 get_armor（避免与 attack record temporary_armor_bonus 双计）
	battle.context.game_actions.modify_armor({
		"mech_id": player_mech.mech_id, "delta": 5, "duration": &"THIS_ATTACK"})
	if int(player_mech.get_armor()) != base_armor + 4:
		return "THIS_ATTACK +5 不应计入 get_armor（避免双计）: 期望 %d, 实际 %d" % [base_armor + 4, int(player_mech.get_armor())]

	# ③ 回末清理 THIS_TURN 后护甲还原
	battle.context.turn_service._clean_this_turn_durations()
	if int(player_mech.get_armor()) != base_armor:
		return "回末清理 THIS_TURN 后 get_armor 应还原为 %d, 实际 %d" % [base_armor, int(player_mech.get_armor())]
	return true


## ④ 真实攻击：目标带 THIS_TURN +4 护甲，伤害恰为 max(0, might-(base_armor+4))，比无加成少 4
func test_armor_this_turn_reduces_attack_damage():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	# 敌我相邻，确保在武器范围内
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}

	var base_armor: int = int(player_mech.get_armor())
	# 选使 base 与 base+4 都不触底、HP 不致死的威力（教学机甲无装备，base_armor 仅框架槽位和）
	var might: int = base_armor + 12
	_set_enemy_first_weapon_might(enemy_mech, might)
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "敌方无机甲武器"
	var weapon_id: StringName = weapon_ids[0]
	var attack_card_id: StringName = _ensure_attack_card_in_enemy_hand(battle)
	if attack_card_id == &"":
		return "敌方无攻击牌可用"

	# 清玩家手牌（教学机甲无装备 -> 无 AVAILABILITY 监听器），避免响应窗口拦截
	_clear_player_hand(battle)
	battle.context.action_ui_bridge.context = battle.context

	# 给玩家加 THIS_TURN +4 护甲（模拟 effect_015 等已在本回合发动）
	battle.context.game_actions.modify_armor({
		"mech_id": player_mech.mech_id, "delta": 4, "duration": &"THIS_TURN"})
	if int(player_mech.get_armor()) != base_armor + 4:
		return "加成后 get_armor 应=%d, 实际 %d" % [base_armor + 4, int(player_mech.get_armor())]

	var player_hp_before: int = player_mech.current_hp
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起: %s" % str(atk_result)
	await _pump_frames(3)

	var expected_with: int = max(0, might - (base_armor + 4))
	var expected_without: int = max(0, might - base_armor)

	var attack = battle.context.action_registry.get_action(attack_id)
	var damage: int = -1
	if attack != null:
		damage = int(attack.record.get("damage", -1))
		_drive_damage_placement(battle, attack_id)
	await _pump_frames(2)
	if damage < 0:
		damage = player_hp_before - player_mech.current_hp

	if damage != expected_with:
		return "THIS_TURN +4 护甲下伤害应=%d (might %d - (armor %d + 4))，实际 %d（+4 护甲未在攻击路径生效？）" % [expected_with, might, base_armor, damage]
	# +4 必须实际减伤：未触底时基线 - 加成 恰为 4
	if expected_without - expected_with != 4:
		return "基线伤害 %d 与加成伤害 %d 差值应=4（+4 护甲未生效）" % [expected_without, expected_with]
	return true
