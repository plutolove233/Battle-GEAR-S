## BattleState.gd — 战斗状态管理器
##
## BattleState 是 app_root 与底层游戏系统之间的桥梁。
## 公共接口保持与旧版兼容，内部委托给 GameContext/Service 体系。
## 统一攻击流程：声明 → 迎击窗口 → 结算 → 损伤放置
extends RefCounted
class_name BattleState

const HexGrid = preload("res://scripts/battle/hex_grid.gd")
const BattleMath = preload("res://scripts/battle/battle_math.gd")
const DataRegistry = preload("res://scripts/data/data_registry.gd")

# Preloaded class references for type checks and constructors
const _GameContext = preload("res://scripts/runtime/GameContext.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _CardDef = preload("res://scripts/card_defs/CardDef.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")
const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _GameState = preload("res://scripts/runtime/GameState.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")

## GameContext：新的依赖注入容器
var context = null

## 战前选择的装备 ID 列表（由 app_root 在 start_tutorial 前设置）
var pre_selected_equipment: Array[String] = []

## 兼容字段：供 app_root 和 BattleBoard 读取
var map_tiles: Array[Dictionary] = []
var turn_number: int = 1
var active_side: String = "player"
var log: Array[Dictionary] = []
var units: Dictionary = {}

## DataRegistry 引用（兼容旧接口）
var registry = null

## 攻击是否等待响应（迎击窗口）
var awaiting_response: bool = false
var current_attack_id: StringName = &""

## 敌方回合阶段状态（app_root 需要读取）
var enemy_turn_phase: String = ""  # "", "awaiting_response", "awaiting_damage_placement", "done"


## ── 初始化 ──


func start_tutorial(data_registry) -> Dictionary:
	registry = data_registry

	# 创建 GameContext 并初始化所有系统
	context = _GameContext.new()
	context.initialize(data_registry)

	# 通过 GameSetupService 创建完整游戏状态
	var setup_result: Dictionary = context.game_setup_service.setup_tutorial_battle(data_registry)
	if not setup_result.get("ok", false):
		return setup_result

	# 同步兼容字段
	_sync_compat_fields()

	# 注意：build_decks_from_config 已在 GameSetupService.setup_tutorial_battle 中调用，
	# 此处不再重复调用以避免牌堆被清空重建导致卡牌实例丢失 def
	var battle_config: Dictionary = data_registry.get_tutorial_battle()

	# 将教学配置中的初始装备放入装备手牌
	_setup_starting_equipment(battle_config)

	# 自动装备预选装备到玩家机甲
	for equipment_id: String in pre_selected_equipment:
		var equip_result: Dictionary = set_equipment("player", equipment_id)
		if not equip_result.get("ok", false):
			log.append(BattleMath.make_log("预选装备未设置", {"equipment": equipment_id, "reason": String(equip_result.get("message", ""))}))

	# 敌方自动装备所有装备牌
	_auto_equip_enemy()

	# 抽初始行动牌
	_draw_starting_action_cards(battle_config)

	# 同步一次
	_sync_compat_fields()

	log.append(BattleMath.make_log("战斗开始", {"battle": battle_config.get("name", "")}))
	return {"ok": true, "message": "started"}


## ── 回合操作 ──


func start_turn(side: String) -> Dictionary:
	if not context or not context.game_state.players.has(StringName(side)):
		return {"ok": false, "message": "invalid side: %s" % side}

	var result: Dictionary = context.turn_service.start_turn(StringName(side))
	_sync_compat_fields()
	return result


func move_unit(side: String, target: Dictionary) -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}
	var mech = context.game_state.get_mech_for_player(StringName(side))
	if not mech:
		return {"ok": false, "message": "mech not found for side: %s" % side}

	var result: Dictionary = context.map_service.move_mech_to_hex(mech.mech_id, target)
	_sync_compat_fields()
	return result


## ── 统一攻击流程 ──


## 开始攻击（声明阶段）
## 返回结果中包含下一步需要的信息：
## - "state": "awaiting_response" → 需要迎击响应
## - "state": "resolved" → 直接结算完毕
## - "state": "failed" → 攻击失败
func begin_attack(attacker_side: StringName, defender_side: StringName, weapon_id: StringName, attack_card_id: StringName) -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}

	var attacker_mech = context.game_state.get_mech_for_player(attacker_side)
	var defender_mech = context.game_state.get_mech_for_player(defender_side)
	if not attacker_mech or not defender_mech:
		return {"ok": false, "message": "invalid side"}

	# 发动攻击声明
	var result: Dictionary = context.attack_service.declare_attack(
		attacker_mech.mech_id, defender_mech.mech_id, weapon_id, attack_card_id
	)

	if not result.get("ok", false):
		return result

	# 如果进入迎击窗口
	if result.get("state", "") == "awaiting_response":
		awaiting_response = true
		current_attack_id = result.get("attack_id", &"")

		# 如果防守方是 AI，自动处理迎击
		if defender_side == &"enemy":
			_ai_decide_response(current_attack_id)
			# AI 已处理，直接结算
			var resolve_result = _resolve_and_get_placement()
			resolve_result["state"] = "resolved"
			return resolve_result
		else:
			# 防守方是玩家，需要玩家选择迎击
			result["state"] = "awaiting_player_response"
			result["defender_player_id"] = defender_side
			return result

	_sync_compat_fields()
	return result


## 处理迎击响应
## response_card_id 为空表示跳过迎击
func handle_response(attack_id: StringName, response_card_id: StringName = &"") -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}

	if response_card_id != &"":
		context.attack_service.submit_response(attack_id, response_card_id, {})

	# 迎击处理完毕，结算攻击
	var resolve_result = _resolve_and_get_placement()
	resolve_result["state"] = "resolved"
	return resolve_result


## 结算攻击并返回损伤放置信息
func _resolve_and_get_placement() -> Dictionary:
	if current_attack_id == &"":
		return {"ok": false, "message": "no active attack"}

	var result: Dictionary = context.attack_service.resolve_attack(current_attack_id)
	awaiting_response = false
	current_attack_id = &""
	_sync_compat_fields()
	return result


## 自动放置损伤标记（AI模式）
func auto_place_damage_tokens(mech_id: StringName, token_count: int, source_attack_id: StringName = &"") -> void:
	if not context or token_count <= 0:
		return
	context.damage_token_service.place_damage_tokens({
		"mech_id": mech_id,
		"count": token_count,
		"source_attack_id": source_attack_id,
	})
	_sync_compat_fields()


## ── 敌方回合（多步式） ──


## 开始敌方回合
## 返回: {"state": "awaiting_player_response"} / {"state": "awaiting_damage_placement"} / {"state": "done"}
func start_enemy_turn() -> Dictionary:
	if not context:
		return {"state": "done"}

	enemy_turn_phase = "started"
	context.turn_service.start_turn(&"enemy")
	_sync_compat_fields()

	# 简化AI：尝试攻击，失败则移动
	var enemy_mech = context.game_state.get_mech_for_player(&"enemy")
	var player_mech = context.game_state.get_mech_for_player(&"player")

	if not enemy_mech or not player_mech:
		return finish_enemy_turn()

	# AI: 移动向玩家
	if enemy_mech.power > 0:
		var step: Dictionary = _find_first_step_toward(
			enemy_mech.position, player_mech.position, enemy_mech.power
		)
		if HexGrid.distance(enemy_mech.position, step) > 0:
			move_unit("enemy", step)

	# AI: 尝试攻击
	var attack_result = _ai_try_attack()
	if attack_result.get("state", "") == "awaiting_player_response":
		# 需要玩家迎击
		enemy_turn_phase = "awaiting_response"
		return attack_result

	if attack_result.get("hit", false) and attack_result.get("markers", 0) > 0:
		# 攻击命中，需要损伤放置
		var chooser: StringName = attack_result.get("chooser_player_id", &"")
		if chooser == &"player":
			enemy_turn_phase = "awaiting_damage_placement"
			attack_result["state"] = "awaiting_damage_placement"
			return attack_result
		else:
			# AI 自动放置
			auto_place_damage_tokens(
				attack_result.get("target_mech_id_for_tokens", &""),
				attack_result.get("markers", 0)
			)

	return finish_enemy_turn()


## 敌方回合继续（玩家迎击或损伤放置后）
func continue_enemy_turn_after_response(resolve_result: Dictionary) -> Dictionary:
	if resolve_result.get("hit", false) and resolve_result.get("markers", 0) > 0:
		var chooser: StringName = resolve_result.get("chooser_player_id", &"")
		if chooser == &"player":
			enemy_turn_phase = "awaiting_damage_placement"
			resolve_result["state"] = "awaiting_damage_placement"
			return resolve_result
		else:
			auto_place_damage_tokens(
				resolve_result.get("target_mech_id_for_tokens", &""),
				resolve_result.get("markers", 0)
			)

	return finish_enemy_turn()


## 完成敌方回合
func finish_enemy_turn() -> Dictionary:
	enemy_turn_phase = "done"
	context.turn_service.end_turn(&"enemy")
	_sync_compat_fields()

	# 检查胜负
	if get_result().state != "active":
		return {"state": "battle_over"}

	# 开始玩家回合
	start_turn("player")
	return {"state": "done"}


## AI 迎击决策
func _ai_decide_response(attack_id: StringName) -> void:
	if not context:
		return

	var gs = context.game_state
	var attack_context: Dictionary = gs.attacks.get(attack_id, {})
	if attack_context.is_empty():
		return

	# 找到防守方（AI方）的迎击牌
	var target_id: StringName = attack_context.get("target_id", &"")
	var defender_player = gs.get_player_for_mech(target_id)
	if not defender_player:
		return

	# 查找手牌中的迎击牌
	for card_id: StringName in defender_player.action_hand:
		var card = gs.cards.get(card_id)
		if card and card.def is _ActionCardDef and card.def.action_type == &"迎击":
			# AI 简单策略：有迎击牌就使用第一张
			context.attack_service.submit_response(attack_id, card_id, {})
			return

	# 没有迎击牌或选择不使用，跳过
	# （不调用 submit_response，表示不迎击）


## AI 尝试攻击
func _ai_try_attack() -> Dictionary:
	var gs = context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_player = gs.players.get(&"enemy")

	if not enemy_mech or not player_mech or not enemy_player:
		return {"ok": false}

	if not enemy_mech.can_attack():
		return {"ok": false}

	# 查找攻击牌
	var attack_card_id: StringName = &""
	for card_id: StringName in enemy_player.action_hand:
		var card = gs.cards.get(card_id)
		if card and card.def is _ActionCardDef and card.def.action_type == &"攻击":
			attack_card_id = card_id
			break

	if attack_card_id == &"":
		return {"ok": false}

	# 查找武器
	var weapon_ids: Array[StringName] = enemy_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return {"ok": false}

	# 使用第一把武器
	var weapon_id: StringName = weapon_ids[0]

	# 检查射程
	var weapon_card = gs.get_card(weapon_id)
	var weapon_range: int = 1
	if weapon_card and weapon_card.def:
		weapon_range = weapon_card.def.range_value
	var map_cells: Dictionary = gs.map_state.cells if gs.map_state else {}
	if not _RangeCalculator.is_in_weapon_range(enemy_mech.position, player_mech.position, weapon_range, map_cells):
		return {"ok": false}

	# 声明攻击
	return begin_attack(&"enemy", &"player", weapon_id, attack_card_id)


## ── 旧版兼容攻击接口 ──


func attack(attacker_side: String, defender_side: String, weapon_index: int) -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}

	var attacker_mech = context.game_state.get_mech_for_player(StringName(attacker_side))
	var defender_mech = context.game_state.get_mech_for_player(StringName(defender_side))
	if not attacker_mech or not defender_mech:
		return {"ok": false, "message": "invalid side"}

	# 获取武器 ID
	var weapon_ids: Array[StringName] = attacker_mech.get_weapon_ids()
	if weapon_index < 0 or weapon_index >= weapon_ids.size():
		return {"ok": false, "message": "weapon index invalid"}

	# 需要一张攻击牌——简化处理：查找手牌中第一张攻击牌
	var attack_card_id: StringName = &""
	var player = context.game_state.players.get(StringName(attacker_side))
	if player:
		for card_id: StringName in player.action_hand:
			var card = context.game_state.cards.get(card_id)
			if card and card.def is _ActionCardDef and card.def.action_type == &"攻击":
				attack_card_id = card_id
				break
	if attack_card_id == &"":
		return {"ok": false, "message": "no attack card in hand"}

	# 使用统一攻击流程
	return begin_attack(StringName(attacker_side), StringName(defender_side), weapon_ids[weapon_index], attack_card_id)


## 提交迎击响应
func submit_response(response_card_id: StringName, payload: Dictionary = {}) -> Dictionary:
	return handle_response(current_attack_id, response_card_id)


## 跳过迎击
func pass_response() -> Dictionary:
	return handle_response(current_attack_id, &"")


## ── 装备操作 ──


func set_equipment(side: String, equipment_id: String) -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}
	var player = context.game_state.players.get(StringName(side))
	var mech = context.game_state.get_mech_for_player(StringName(side))
	if not player or not mech:
		return {"ok": false, "message": "invalid side"}

	# 在装备手牌中查找卡牌实例
	var card_instance_id: StringName = &""
	for cid: StringName in player.equipment_hand:
		var hand_card = context.game_state.cards.get(cid)
		if hand_card and hand_card.def and String(hand_card.def.card_id) == equipment_id:
			card_instance_id = cid
			break
	if card_instance_id == &"":
		return {"ok": false, "message": "equipment not in hand"}

	# 确定槽位
	var slot_id: StringName = &""
	var card = context.game_state.cards.get(card_instance_id)
	if card and card.def is _EquipmentCardDef:
		var eq_def = card.def
		if eq_def.equipment_kind == &"PART":
			slot_id = eq_def.slot
		elif eq_def.equipment_kind == &"WEAPON":
			# 找空武器槽
			for ws_id: StringName in [&"weapon_1", &"weapon_2"]:
				if mech.slots.has(ws_id) and not mech.slots[ws_id].equipped_card:
					slot_id = ws_id
					break
			if slot_id == &"":
				slot_id = &"weapon_1"  # 替换第一个武器槽

	if slot_id == &"":
		return {"ok": false, "message": "no valid slot"}

	var result: Dictionary = context.card_set_service.set_equipment(
		StringName(side), card_instance_id, slot_id
	)
	_sync_compat_fields()
	return result


func sell_equipment(side: String, equipment_id: String) -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}
	var player = context.game_state.players.get(StringName(side))
	if not player:
		return {"ok": false, "message": "invalid side"}

	var card_instance_id: StringName = &""
	for cid: StringName in player.equipment_hand:
		var hand_card = context.game_state.cards.get(cid)
		if hand_card and hand_card.def and String(hand_card.def.card_id) == equipment_id:
			card_instance_id = cid
			break
	if card_instance_id == &"":
		return {"ok": false, "message": "equipment not in hand"}

	var result: Dictionary = context.card_set_service.sell_equipment(StringName(side), card_instance_id)
	_sync_compat_fields()
	return result


## ── 回合结束 ──


func end_player_turn() -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}

	# 结束玩家回合
	context.turn_service.end_turn(&"player")
	_sync_compat_fields()

	# 检查胜负
	if get_result().state != "active":
		return {"ok": true, "message": "player_turn_ended_battle_over"}

	# 不再在这里直接运行敌方回合
	# 改为由 app_root 调用 start_enemy_turn() 以支持多步交互
	return {"ok": true, "message": "player_turn_ended"}


## 旧的同步敌方回合（保留兼容，但不再被 app_root 直接调用）
func run_enemy_turn() -> Dictionary:
	if not context:
		return {"ok": false, "message": "battle not started"}

	context.turn_service.start_turn(&"enemy")
	_sync_compat_fields()

	# 简化AI：尝试攻击，失败则移动
	var attack_result: Dictionary = attack("enemy", "player", 0)
	if not attack_result.get("ok", false):
		# 移动向玩家
		var enemy_mech = context.game_state.get_mech_for_player(&"enemy")
		var player_mech = context.game_state.get_mech_for_player(&"player")
		if enemy_mech and player_mech and enemy_mech.power > 0:
			var step: Dictionary = _find_first_step_toward(
				enemy_mech.position, player_mech.position, enemy_mech.power
			)
			if HexGrid.distance(enemy_mech.position, step) > 0:
				move_unit("enemy", step)

	context.turn_service.end_turn(&"enemy")
	_sync_compat_fields()
	return {"ok": true, "message": "enemy_turn_done"}


## ── 胜负判定 ──


func get_result() -> Dictionary:
	if not context or context.game_state.mechs.is_empty():
		return {"state": "inactive", "reason": "battle is not started"}
	return context.victory_service.check_victory()


## ── 兼容层：从 GameState 同步到旧版 units 字典 ──


func _sync_compat_fields() -> void:
	if not context:
		return
	var gs = context.game_state

	# 同步回合信息
	turn_number = gs.turn_number
	active_side = String(gs.active_player_id)
	log = gs.log.duplicate(true)

	# 同步地图
	map_tiles.clear()
	for cell_key: String in gs.map_state.cells:
		var cell = gs.map_state.cells[cell_key]
		map_tiles.append({"q": cell.q, "r": cell.r})

	# 从 MechState 构建兼容的 units 字典
	units.clear()
	for player_id: StringName in gs.players:
		var mech = gs.get_mech_for_player(player_id)
		if not mech:
			continue
		var player = gs.players[player_id]

		# 构建武器列表（兼容旧格式）
		var weapons: Array = []
		for slot_id: StringName in [&"weapon_1", &"weapon_2"]:
			if mech.slots.has(slot_id) and mech.slots[slot_id].equipped_card:
				var w_card = mech.slots[slot_id].equipped_card
				if w_card.def is _EquipmentCardDef:
					weapons.append({
						"name": w_card.def.display_name,
						"weapon_type": String(w_card.def.weapon_kind),
						"damage": w_card.def.might,
						"range": w_card.def.range_value,
					})

		# 构建损伤标记
		var damage_markers: Dictionary = {}
		for slot_id: StringName in mech.slots:
			var slot = mech.slots[slot_id]
			if slot.region_damage_tokens > 0:
				damage_markers[String(slot_id)] = slot.region_damage_tokens

		# 构建装备手牌（card_id列表）
		var equip_hand: Array = []
		for cid: StringName in player.equipment_hand:
			var card = gs.cards.get(cid)
			if card and card.def:
				equip_hand.append(String(card.def.card_id))

		# 构建行动牌手牌
		var action_hand: Array = []
		for cid: StringName in player.action_hand:
			var card = gs.cards.get(cid)
			if card and card.def:
				action_hand.append(String(card.def.card_id))

		units[String(player_id)] = {
			"side": String(player_id),
			"frame_id": String(mech.frame_def.card_id) if mech.frame_def else "",
			"name": mech.frame_def.display_name if mech.frame_def else String(player_id),
			"position": mech.position.duplicate(),
			"life": mech.current_hp,
			"max_life": mech.max_hp,
			"armor": mech.get_armor(),
			"power": mech.power,
			"max_power": mech.max_power,
			"gold": player.gold,
			"hand": action_hand,
			"equipment_hand": equip_hand,
			"weapons": weapons,
			"damage_markers": damage_markers,
		}


## ── 内部方法 ──


## 设置初始装备手牌
## 优先将 pre_selected_equipment 中的卡牌分给玩家，剩余牌再平分给双方
func _setup_starting_equipment(_battle_config: Dictionary) -> void:
	var player = context.game_state.players.get(&"player")
	var enemy = context.game_state.players.get(&"enemy")
	var deck_state = context.game_state.deck_state

	# ── 第一轮：将匹配 pre_selected_equipment 的卡牌优先分给玩家 ──
	var assigned: Array[StringName] = []
	for card_id: StringName in deck_state.equipment_deck:
		var card = context.game_state.cards.get(card_id)
		if card and card.def and String(card.def.card_id) in pre_selected_equipment:
			card.owner_player_id = &"player"
			card.zone = &"equipment_hand"
			player.equipment_hand.append(card_id)
			assigned.append(card_id)
	# 从牌堆中移除已分配的卡牌
	for cid: StringName in assigned:
		deck_state.equipment_deck.erase(cid)

	# ── 第二轮：剩余牌平分给双方 ──
	var half_size: int = deck_state.equipment_deck.size() / 2

	# 玩家：抽取前半部分
	if player:
		for i: int in range(half_size):
			if deck_state.equipment_deck.is_empty():
				break
			var card_id: StringName = deck_state.equipment_deck.pop_front() as StringName
			var card = context.game_state.cards.get(card_id)
			if card:
				card.owner_player_id = &"player"
				card.zone = &"equipment_hand"
			player.equipment_hand.append(card_id)

	# 敌方：抽取剩余
	if enemy:
		while deck_state.equipment_deck.size() > 0:
			var card_id: StringName = deck_state.equipment_deck.pop_front() as StringName
			var card = context.game_state.cards.get(card_id)
			if card:
				card.owner_player_id = &"enemy"
				card.zone = &"equipment_hand"
			enemy.equipment_hand.append(card_id)


## 抽初始行动牌
## 从行动牌堆中抽取卡牌到双方手牌（而非重复创建）
func _draw_starting_action_cards(_battle_config: Dictionary) -> Dictionary:
	var player = context.game_state.players.get(&"player")
	var enemy = context.game_state.players.get(&"enemy")
	var deck_state = context.game_state.deck_state

	# 玩家：从行动牌堆抽4张
	if player:
		for i: int in range(mini(4, deck_state.action_deck.size())):
			var card_id: StringName = deck_state.action_deck.pop_front() as StringName
			var card = context.game_state.cards.get(card_id)
			if card:
				card.owner_player_id = &"player"
				card.zone = &"action_hand"
			player.action_hand.append(card_id)

	# 敌方：从行动牌堆抽4张
	if enemy:
		for i: int in range(mini(4, deck_state.action_deck.size())):
			var card_id: StringName = deck_state.action_deck.pop_front() as StringName
			var card = context.game_state.cards.get(card_id)
			if card:
				card.owner_player_id = &"enemy"
				card.zone = &"action_hand"
			enemy.action_hand.append(card_id)

	return {"ok": true, "message": "starting_cards_drawn"}


## 敌方自动装备：将装备手牌中的卡牌自动设置到对应槽位
func _auto_equip_enemy() -> void:
	var enemy = context.game_state.players.get(&"enemy")
	var mech = context.game_state.get_mech_for_player(&"enemy")
	if not enemy or not mech:
		return

	# 复制一份列表，因为遍历过程中会修改原数组
	var cards_to_equip: Array[StringName] = enemy.equipment_hand.duplicate()
	for card_id: StringName in cards_to_equip:
		var card = context.game_state.cards.get(card_id)
		if not card or not card.def:
			continue
		var slot_id: StringName = &""
		if card.def is _EquipmentCardDef:
			var eq_def = card.def
			if eq_def.equipment_kind == &"PART":
				slot_id = eq_def.slot
			elif eq_def.equipment_kind == &"WEAPON":
				for ws_id: StringName in [&"weapon_1", &"weapon_2"]:
					if mech.slots.has(ws_id) and not mech.slots[ws_id].equipped_card:
						slot_id = ws_id
						break
				if slot_id == &"":
					slot_id = &"weapon_1"
		if slot_id != &"":
			context.card_set_service.set_equipment(&"enemy", card_id, slot_id)


## BFS 寻路：找到从 origin 向 target 的第一步
func _find_first_step_toward(origin: Dictionary, target: Dictionary, available_power: int) -> Dictionary:
	if available_power <= 0:
		return origin.duplicate()
	var origin_key: String = HexGrid.key(origin)
	var target_key: String = HexGrid.key(target)
	if origin_key == target_key:
		return origin.duplicate()

	var traversable: Dictionary = {}
	for tile: Dictionary in map_tiles:
		traversable[HexGrid.key(tile)] = tile.duplicate()

	if not traversable.has(origin_key) or not traversable.has(target_key):
		return origin.duplicate()

	var frontier: Array[Dictionary] = [origin.duplicate()]
	var came_from: Dictionary = {origin_key: ""}
	var index: int = 0

	while index < frontier.size():
		var current: Dictionary = frontier[index]
		index += 1
		var current_key: String = HexGrid.key(current)
		if current_key == target_key:
			break
		for neighbor: Dictionary in HexGrid.neighbors(current):
			var neighbor_key: String = HexGrid.key(neighbor)
			if not traversable.has(neighbor_key) or came_from.has(neighbor_key):
				continue
			came_from[neighbor_key] = current_key
			frontier.append(neighbor.duplicate())

	if not came_from.has(target_key):
		return origin.duplicate()

	var step_key: String = target_key
	var previous_key: String = String(came_from[step_key])
	while previous_key != origin_key:
		step_key = previous_key
		previous_key = String(came_from[step_key])

	return traversable.get(step_key, origin).duplicate()
