## test_sniper_range_fix.gd - P0-B: 狙击装·头部「远程武器范围+X」生效验证
##
## 根因：effect_022/055 用 LISTEN ATTACK_BEFORE -> MODIFY_ATTACK_RANGE 写 attack record extra_range，
## 但①攻击预检查 app_root._get_weapon_range 仅用基础 range_value 判「是否有可攻击目标」，
##   ②目标高亮用 input_params.weapon_range（基础值，不含 extra_range），玩家选不到 +X 格目标。
## 修复：effect_022/055 改派生值占位（不注册 listener），新增 get_passive_weapon_range_bonus，
##   在 _get_weapon_range（预检查）与 attack_action._step_select_weapon（存入 record["weapon_range"]，
##   命中/选目标校验/高亮自动含之）调用。
##
## 验证点：
##   1. 装备 031(+1)/073(+2) 后 get_passive_weapon_range_bonus：远程返回 1/2，近战返回 0
##   2. 装备 031 + 远程 range=1 基础武器，attack.record["weapon_range"]==2（狙击加成已存入）
##   3. 距离 2 的目标能命中（hit==true），证明有效射程=2
##   4. 无狙击头时距离 2 目标超出 range=1，攻击被取消/未命中（证明 +1 确实生效）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")


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


## 装备头部牌到玩家头部槽（set_equipment 后推进帧让动作完成）
func _equip_head(battle: BattleState, card_def_id: String) -> bool:
	var head_id: StringName = _ensure_equipment_in_hand(battle, card_def_id)
	if head_id == &"":
		return false
	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", head_id, &"头部")
	if not result.get("ok", false):
		return false
	await _pump_frames(3)
	return true


## 给敌方一张攻击牌（用于清空/确保敌方手牌可控；本测试主要清空敌方手牌避免响应窗口）
func _clear_enemy_hand(battle: BattleState) -> void:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return
	for cid: StringName in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	enemy.action_hand.clear()


## 给玩家一张攻击牌
func _ensure_attack_card_in_hand(battle: BattleState) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == "action_001_进攻":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == "action_001_进攻":
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


## 驱动 attack 损伤设置完成（damage_change 暂停在 place_damage_tokens）
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> void:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return
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


## ① 装备 031(+1)/073(+2) 后 helper 返回正确值
func test_sniper_head_range_bonus_helper():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var mech = battle.context.game_state.get_mech_for_player(&"player")
	if mech == null:
		return "找不到玩家机甲"

	# 装备前：无加成
	if _GenEquipEffects.get_passive_weapon_range_bonus(mech, &"远程") != 0:
		return "装备前远程范围加成应为 0"

	# 装备 031 狙击装·头部（effect_022 +1）
	if not await _equip_head(battle, "part_031_狙击装_头部"):
		return "装备 031 失败"
	if _GenEquipEffects.get_passive_weapon_range_bonus(mech, &"远程") != 1:
		return "031 装备后远程范围加成应为 1，实际 %d" % _GenEquipEffects.get_passive_weapon_range_bonus(mech, &"远程")
	if _GenEquipEffects.get_passive_weapon_range_bonus(mech, &"近战") != 0:
		return "031 近战武器不应有范围加成"

	# 换装 073 狙击影装·头部（effect_055 +2）
	if not await _equip_head(battle, "part_073_狙击影装_头部"):
		return "装备 073 失败"
	if _GenEquipEffects.get_passive_weapon_range_bonus(mech, &"远程") != 2:
		return "073 装备后远程范围加成应为 2，实际 %d" % _GenEquipEffects.get_passive_weapon_range_bonus(mech, &"远程")
	return true


## ②③④ 装备 031 + 远程 range=1 武器，距离 2 目标能命中；无头则不能
func test_sniper_head_attack_hits_distance2():
	# ── 有狙击头：range=1 远程 + 031(+1) -> 有效射程 2，距离 2 目标命中 ──
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	if not await _equip_head(battle, "part_031_狙击装_头部"):
		return "装备 031 失败"
	# 远程 range=1 基础武器
	player_mech.set_base_weapon({"name": "test_ranged", "might": 10, "range_value": 1, "weapon_kind": &"远程"})
	# 距离 2（(5,0)->(7,0) 六边距 2，NORMAL 地形 BFS 代价 2）
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 7, "r": 0}
	_clear_enemy_hand(battle)
	battle.context.action_ui_bridge.context = battle.context
	var attack_card_id: StringName = _ensure_attack_card_in_hand(battle)
	if attack_card_id == &"":
		return "玩家无攻击牌"
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]

	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", weapon_id, attack_card_id)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "有狙击头：攻击未发起: %s" % str(atk_result)
	await _pump_frames(3)
	var attack = battle.context.action_registry.get_action(attack_id)
	if attack == null:
		return "有狙击头：攻击动作消失（可能被取消）"
	# ② record["weapon_range"] 应为 2（基础 1 + 狙击 1）
	var wr: int = int(attack.record.get("weapon_range", -1))
	if wr != 2:
		return "有狙击头：weapon_range 应=2（基础1+狙击1），实际 %d" % wr
	# ③ 距离 2 目标应命中
	var hit: bool = bool(attack.record.get("hit", false))
	if not hit:
		return "有狙击头：距离 2 目标应命中（有效射程 2），hit=false"
	# 清理损伤设置
	_drive_damage_placement(battle, attack_id)

	# ── 无狙击头：range=1 远程，距离 2 目标超出射程，攻击应被取消/未命中 ──
	var battle2 := _new_battle()
	if battle2 == null or battle2.context == null:
		return "battle2 初始化失败"
	var gs2 = battle2.context.game_state
	var pm2 = gs2.get_mech_for_player(&"player")
	var em2 = gs2.get_mech_for_player(&"enemy")
	if pm2 == null or em2 == null:
		return "battle2 机甲缺失"
	# 不装狙击头
	pm2.set_base_weapon({"name": "test_ranged", "might": 10, "range_value": 1, "weapon_kind": &"远程"})
	pm2.position = {"q": 5, "r": 0}
	em2.position = {"q": 7, "r": 0}
	# 清空敌方手牌
	var en2 = gs2.players.get(&"enemy")
	if en2 != null:
		for cid: StringName in en2.action_hand.duplicate():
			battle2.context.timing_engine.unregister_listeners_for_card(cid)
		en2.action_hand.clear()
	battle2.context.action_ui_bridge.context = battle2.context
	var atk2_card: StringName = _ensure_attack_card_in_hand(battle2)
	if atk2_card == &"":
		return "battle2 玩家无攻击牌"
	var wid2: StringName = pm2.get_weapon_ids()[0]
	var atk2_result: Dictionary = battle2.execute_attack_action(&"player", &"enemy", wid2, atk2_card)
	var atk2_id: StringName = atk2_result.get("action_id", &"") if atk2_result is Dictionary else &""
	await _pump_frames(3)
	var attack2 = battle2.context.action_registry.get_action(atk2_id) if atk2_id != &"" else null
	# ④ 无狙击头：距离 2 超出 range 1 -> 攻击被取消(preset_target_out_of_range)或未命中
	var hit2: bool = false
	if attack2 != null:
		hit2 = bool(attack2.record.get("hit", false))
		_drive_damage_placement(battle2, atk2_id)
	if hit2:
		return "无狙击头：距离 2 目标不应命中（range=1），但 hit=true（狙击加成未生效？）"
	return true
