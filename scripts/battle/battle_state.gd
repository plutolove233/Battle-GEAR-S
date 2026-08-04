## BattleState.gd — 战斗状态管理器
##
## BattleState 是 app_root 与底层游戏系统之间的桥梁。
## 所有攻击/移动/行动牌操作通过 ActionService → TimingEngine 统一调度。
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
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")

## GameContext：依赖注入容器
var context = null

## 战前选择的装备 ID 列表（由 app_root 在 start_tutorial 前设置）
var pre_selected_equipment: Array[String] = []

## PvP 锁步同步随机种子（由 app_root 在 start_tutorial 前设置）。
## <0 表示用默认随机种子（PvE 单进程）；>=0 则双端用同一种子建局，保证牌堆顺序一致。
## 战斗 RNG 种子。>=0 则 start_tutorial 调 set_rng_seed 使 context.rng 确定。默认 12345
## 保证测试可复现（避免 RandomNumberGenerator.new() 自动随机化导致 flaky：起始手牌发到
## 敌方手里会使 _ensure_*_in_hand 搜不到牌、AI 迎击选择不确定等）。app_root vs-AI 建局
## 显式设 randi() 保持每局随机；PvP 双端设同一共享种子。
var rng_seed: int = 12345

## 是否在地图上配置 PvP 地图特征（绿/红格子 + 标记点 + 初始标记）。
## 由 app_root 在 start_tutorial 前设置；教学/测试不设（默认 false），仅 PvP 设 true。
## 传给 GameSetupService.setup_tutorial_battle(pvp_map_features=...)。
var pvp_map_features: bool = false

## 兼容字段：供 app_root 和 BattleBoard 读取
var map_tiles: Array[Dictionary] = []
var turn_number: int = 0
var active_side: String = "player"
var log: Array[Dictionary] = []
var units: Dictionary = {}

## DataRegistry 引用（兼容旧接口）
var registry = null


## ── 初始化 ──


func start_tutorial(data_registry) -> Dictionary:
	registry = data_registry

	# 创建 GameContext 并初始化所有系统
	context = _GameContext.new()
	context.initialize(data_registry)
	# PvP 锁步：用共享种子建局，双端牌堆顺序一致
	if rng_seed >= 0:
		context.set_rng_seed(rng_seed)

	# 通过 GameSetupService 创建完整游戏状态
	var setup_result: Dictionary = context.game_setup_service.setup_tutorial_battle(data_registry, pvp_map_features)
	if not setup_result.get("ok", false):
		return setup_result
	# 注入 game_state 供全场光环 helper（effect_080/086）查询所有机甲
	_GenEquipEffects.set_aura_game_state(context.game_state)

	# 同步兼容字段
	_sync_compat_fields()

	# 注意：build_all_decks_from_card_database 已在 GameSetupService.setup_tutorial_battle 中调用，
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

	# 初始化商店：开局自动从装备牌堆抽取填充3普通+1高级+1隐藏槽位，
	# 否则商店开局全空、玩家必须先点"重置/刷新"才有货。
	# 牌堆已在 setup_tutorial_battle 中建好，起始装备也已分配完毕，此处抽牌不冲突。
	if context and context.shop_service:
		context.shop_service.initialize_shop()

	# 注册手牌中的 AVAILABILITY 效果到 TimingEngine（原游离代码归位）
	if context:
		for pid: StringName in context.game_state.players:
			context.register_all_hand_availability(pid)

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
	# 回合守卫：当回合已开始（active_player_id 非空）时，仅允许当前回合方移动，
	# 防止敌方回合玩家通过 move_unit 随意移动（bug1）。
	# 战斗初始化后尚未 start_turn（active_player_id 为空）时放行，兼容 setup/测试。
	# AI 在敌方回合 move_unit("enemy") 放行；迎击移动走 action 系统的 single_move，不经此入口。
	if context.game_state and context.game_state.active_player_id != &"" and context.game_state.active_player_id != StringName(side):
		return {"ok": false, "message": "非己方回合，无法移动"}
	var mech = context.game_state.get_mech_for_player(StringName(side))
	if not mech:
		return {"ok": false, "message": "mech not found for side: %s" % side}

	var target_hex := {"q": int(target.get("q", 0)), "r": int(target.get("r", 0))}
	# 可达性预检：动力不足/不可通行/被占/点击自身 时不启动 single_move。
	# 否则 _step_select_target 会因 find_optimal_path 返回空而转入 select_move_target
	# 需求输入，弹出绿色可达范围（良性 bug，但不可达点击无意义不应出现）。
	if context.map_service != null:
		var pre_path: Array = context.map_service.find_optimal_path(mech.mech_id, target_hex, mech.power)
		if pre_path.is_empty():
			return {"ok": false, "message": "目标格不可达（动力不足/不可通行/被占据）"}

	# 走单次移动动作：选终点 -> find_optimal_path -> 逐格执行基础移动动作，
	# 每格发出 BASIC_MOVE_BEFORE/AT/AFTER/SETTLE 时点，effect_017/050 等监听
	# BASIC_MOVE_AFTER 的装备效果可在逐格移动动力耗尽时触发（文档"消耗动力后若没动力剩余"）。
	# 旧实现直接 move_mech_to_hex 跳格，绕过动作链致 BASIC_MOVE_AFTER 从不发出。
	var target_cell_str := "%d,%d" % [int(target.get("q", 0)), int(target.get("r", 0))]
	var mv_result: Dictionary = context.action_service.execute(&"single_move", {
		"mech_id": mech.mech_id,
		"target_cell": target_cell_str,
		"player_id": StringName(side),
		"available_power": mech.power,
	})
	_sync_compat_fields()
	# single_move 返回 {state:...}（无 ok）；非 error 即视为移动已开始（可能因 effect_017
	# 挂起 waiting_timing，弹窗后续由 ActionUIBridge 处理）。
	var mv_ok: bool = String(mv_result.get("state", &"")) != &"error"
	return {"ok": mv_ok, "state": mv_result.get("state", &""), "message": String(mv_result.get("message", ""))}


## ── 动作系统入口 ──


## 执行攻击动作（薄封装：委托给新动作系统 ActionService.execute(&"attack", ...)）
## 注意：玩家与 AI 攻击现已统一走 execute_use_action_card → use_action_card 动作 → attack 子动作，
## 经 use_action_card 才会发出 USE_ACTION_* 时点（消息日志据此显示"使用了 XX 攻击牌"）。
## 本方法仅保留备查/测试，AI 不再经此入口。
func execute_attack_action(attacker_side: StringName, defender_side: StringName, weapon_id: StringName, attack_card_id: StringName) -> Dictionary:
	if not context or not context.action_service:
		return {"ok": false, "message": "动作系统未初始化"}

	var attacker_mech = context.game_state.get_mech_for_player(attacker_side)
	var defender_mech = context.game_state.get_mech_for_player(defender_side)
	if not attacker_mech or not defender_mech:
		return {"ok": false, "message": "无效的攻击方/防守方"}

	var result: Dictionary = context.action_service.execute(&"attack", {
		"attacker_id": attacker_mech.mech_id,
		"target_id": defender_mech.mech_id,
		"weapon_id": weapon_id,
		"attack_card_id": attack_card_id,
		"player_id": attacker_side,
	})

	_sync_compat_fields()
	return result


## 执行移动动作
## 通过 ActionService 创建并执行 SingleMoveAction。
func execute_move_action(side: String, target: Dictionary) -> Dictionary:
	if not context or not context.action_service:
		return {"ok": false, "message": "动作系统未初始化"}
	var mech = context.game_state.get_mech_for_player(StringName(side))
	if not mech:
		return {"ok": false, "message": "mech not found for side: %s" % side}

	var result: Dictionary = context.action_service.execute(&"single_move", {
		"mech_id": mech.mech_id,
		"target_cell": target,
		"available_power": mech.power,
		"player_id": StringName(side),
	})
	_sync_compat_fields()
	return result


## 执行使用行动牌动作
## 通过 ActionService 创建并执行 UseActionCardAction。
func execute_use_action_card(side: StringName, card_id: StringName, payload: Dictionary = {}) -> Dictionary:
	if not context or not context.action_service:
		return {"ok": false, "message": "动作系统未初始化"}

	var params: Dictionary = {
		"player_id": side,
		"card_instance_id": card_id,
	}
	params.merge(payload, true)

	var result: Dictionary = context.action_service.execute(&"use_action_card", params)
	_sync_compat_fields()
	return result


## 执行设置装备动作
## 通过 ActionService 创建并执行 SetEquipmentAction。
func execute_set_equipment_action(side: String, card_instance_id: StringName, slot_id: StringName) -> Dictionary:
	if not context or not context.action_service:
		return {"ok": false, "message": "动作系统未初始化"}
	var mech = context.game_state.get_mech_for_player(StringName(side))
	if not mech:
		return {"ok": false, "message": "mech not found for side: %s" % side}

	var result: Dictionary = context.action_service.execute(&"set_equipment", {
		"card_id": card_instance_id,
		"mech_id": mech.mech_id,
		"slot_id": slot_id,
		"player_id": StringName(side),
	})
	_sync_compat_fields()
	return result


## 继续等待输入的动作
## UI 提供输入后调用此方法继续执行。
func continue_action(action_id: StringName, input_data: Dictionary) -> Dictionary:
	if not context or not context.action_service:
		return {"ok": false, "message": "动作系统未初始化"}
	var result: Dictionary = context.action_service.continue_action(action_id, input_data)
	_sync_compat_fields()
	return result


## 取消动作
func cancel_action(action_id: StringName) -> void:
	if context and context.action_service:
		context.action_service.cancel_action(action_id)


## 获取 TimingEngine 的可用响应牌
## 供 ResponsePanel 使用，列出所有 AVAILABILITY 模式的效果牌。
func get_available_response_cards(action_id: StringName) -> Array[Dictionary]:
	if not context or not context.timing_engine or not context.action_registry:
		return []
	var action = context.action_registry.get_action(action_id)
	if action == null:
		return []
	var available: Array = context.timing_engine.get_available_cards(_TimingConst.ATTACK_AT, action)
	var result: Array[Dictionary] = []
	for effect in available:
		var card_instance_id: StringName = effect.source.get("card_instance_id", &"") if effect.source else &""
		var card = context.game_state.get_card(card_instance_id) if card_instance_id != &"" and context.game_state != null else null
		result.append({
			"effect_id": effect.effect_id,
			"card_instance_id": card_instance_id,
			"display_name": effect.display_name,
			"card_name": card.def.display_name if card and card.def else String(effect.effect_id),
			"availability_priority": effect.availability_priority,
			"effect": effect,
		})
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


## ── 敌方回合（新系统） ──


## 开始敌方回合
## 返回: {"state": "waiting_timing"} / {"state": "waiting_input"} / {"state": "waiting_effect_action"}
##       / {"state": "ai_done"} / {"state": "battle_over"}
## AI 决策由 AIController.on_turn_start 驱动；动作暂停时返回 waiting_* 由 app_root 信号驱动续跑。
func start_enemy_turn() -> Dictionary:
	if not context:
		return {"state": "ai_done"}
	if context.ai_controller == null:
		return {"state": "ai_done"}
	var result: Dictionary = context.ai_controller.on_turn_start(&"enemy")
	_sync_compat_fields()
	return result


## 完成敌方回合
func finish_enemy_turn() -> Dictionary:
	context.turn_service.end_turn(&"enemy")
	_sync_compat_fields()

	# 检查胜负
	if get_result().state != "active":
		return {"state": "battle_over"}

	# 开始玩家回合
	start_turn("player")
	return {"state": "done"}


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

	# 同步地图（地形在一场战斗中不变，仅在格数变化时重建，
	# 避免每次 _refresh_battle 都 clear+append 192 格字典造成卡顿）
	if map_tiles.size() != gs.map_state.cells.size():
		map_tiles.clear()
		for cell_key: String in gs.map_state.cells:
			var cell = gs.map_state.cells[cell_key]
			map_tiles.append({"q": cell.q, "r": cell.r, "terrain": String(cell.terrain)})

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

		# 构建联合状态信息（Target UI 显示：哪些机甲与本机甲联合）
		# unite 字段 = 发起联合的机甲（unite机甲），显示其机甲名供 Target 玩家知晓。
		var unite_statuses: Array = []
		for s: Dictionary in mech.statuses:
			if s.get("type", &"") == &"UNITE":
				var u_mid: StringName = s.get("unite", &"")
				var u_mech = gs.mechs.get(u_mid) if u_mid != &"" else null
				var u_name: String = u_mech.frame_def.display_name if (u_mech != null and u_mech.frame_def != null) else String(u_mid)
				unite_statuses.append(u_name)

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
			"unite_statuses": unite_statuses,
		}


## ── 内部方法 ──


## 设置初始装备手牌
## 玩家选中的装备优先从牌堆分配；敌方从 N 稀有度装备中随机选等量装备
## 剩余装备留在牌堆中供商店/抽牌使用
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

	# ── 第二轮：为敌方随机选等量 N 稀有度装备 ──
	var player_equip_count: int = player.equipment_hand.size()
	var enemy_assigned: int = 0
	var i: int = 0
	while enemy_assigned < player_equip_count and i < deck_state.equipment_deck.size():
		var card_id: StringName = deck_state.equipment_deck[i]
		var card = context.game_state.cards.get(card_id)
		if card and card.def and String(card.def.rarity) == "N":
			card.owner_player_id = &"enemy"
			card.zone = &"equipment_hand"
			enemy.equipment_hand.append(card_id)
			deck_state.equipment_deck.erase(card_id)
			enemy_assigned += 1
			# 不递增 i，因为 erase 导致后续元素前移
		else:
			i += 1


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
## （已迁移至 AIController._find_first_step_toward，battle_state 不再持有 AI 旧实现）
