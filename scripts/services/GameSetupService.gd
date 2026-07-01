## GameSetupService.gd — 游戏初始化服务
##
## 负责创建教学战斗的完整初始状态：
## 玩家/敌方 PlayerState + MechState + CardInstance + 地图 + 牌堆
class_name GameSetupService
extends RefCounted

var context = null  # type: GameContext

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")


## 初始化教学战斗
## 从 DataRegistry 读取教学战役配置，构建完整游戏状态
func setup_tutorial_battle(data_registry: DataRegistry) -> Dictionary:
	var gs: GameState = context.game_state
	gs.reset_all()

	# ── 1. 读取教学战役配置 ──
	var battle_config: Dictionary = data_registry.get_tutorial_battle()
	if battle_config.is_empty():
		return {"ok": false, "message": "未找到教学战役配置"}

	# ── 2. 创建双方玩家 ──
	var player: PlayerState = _create_player(&"player", 15)
	var enemy: PlayerState = _create_player(&"enemy", 15)
	gs.players[player.player_id] = player
	gs.players[enemy.player_id] = enemy

	# ── 3. 创建双方机甲 ──
	var player_frame_id: String = battle_config.get("player_frame_id", "frame_001_基础框架")
	var enemy_frame_id: String = battle_config.get("enemy_frame_id", "frame_002_原始框架")

	var player_mech: MechState = _create_mech_from_frame(
		&"player_mech", &"player", player_frame_id, data_registry
	)
	var enemy_mech: MechState = _create_mech_from_frame(
		&"enemy_mech", &"enemy", enemy_frame_id, data_registry
	)
	gs.mechs[player_mech.mech_id] = player_mech
	gs.mechs[enemy_mech.mech_id] = enemy_mech

	# ── 4. 设置初始位置 ──
	var player_start: Dictionary = battle_config.get("player_start", {"q": 2, "r": 2})
	var enemy_start: Dictionary = battle_config.get("enemy_start", {"q": 20, "r": -6})
	player_mech.position = {"q": int(player_start.get("q", 2)), "r": int(player_start.get("r", 2))}
	enemy_mech.position = {"q": int(enemy_start.get("q", 20)), "r": int(enemy_start.get("r", 2))}

	# ── 5. 生成地图 ──
	var map_cols: int = int(battle_config.get("map", {}).get("cols", 24))
	var map_rows: int = int(battle_config.get("map", {}).get("rows", 8))
	var map_blocked: Array = battle_config.get("map", {}).get("blocked", [])
	var cells: Array[Dictionary] = _HexGrid.generate_rectangle(map_cols, map_rows, map_blocked)
	for cell: Dictionary in cells:
		gs.map_state.add_cell(int(cell.q), int(cell.r), &"NORMAL")

	# ── 6. 构建牌堆 ──
	context.deck_build_service.build_all_decks_from_card_database()

	# ── 7. 注册所有已装备卡牌的效果 ──
	_register_equipped_effects(player_mech)
	_register_equipped_effects(enemy_mech)

	# ── 8. 记录回合上限 ──
	gs.temp_values["turn_limit"] = int(battle_config.get("turn_limit", 12))

	gs.write_log(&"game_setup", {"battle_id": battle_config.get("id", "")})
	return {"ok": true, "message": "initialized"}


## ── 内部方法 ──


## 创建玩家状态
func _create_player(pid: StringName, gold: int) -> PlayerState:
	var p: PlayerState = PlayerState.new()
	p.player_id = pid
	p.gold = gold
	return p


## 从框架定义创建机甲，包含所有槽位和基础武器
func _create_mech_from_frame(mech_id: StringName, owner_id: StringName, frame_id: String, data_registry: DataRegistry) -> MechState:
	var mech: MechState = MechState.new()
	mech.mech_id = mech_id
	mech.owner_player_id = owner_id

	# 获取框架定义
	var frame_data: Dictionary = data_registry.get_mech_frame(frame_id)
	var frame_def: MechFrameDef = MechFrameDef.new()
	frame_def.card_id = StringName(frame_data.get("id", frame_id))
	frame_def.display_name = frame_data.get("name", "")
	frame_def.card_kind = &"mech_frame"
	frame_def.faction = frame_data.get("faction", "")
	frame_def.life = int(frame_data.get("life", 25))
	frame_def.base_slots = frame_data.get("base_slots", {})
	var _raw_weapons: Array = frame_data.get("base_weapons", [])
	var _weapons: Array[Dictionary] = []
	for w: Dictionary in _raw_weapons:
		_weapons.append(w)
	frame_def.base_weapons = _weapons

	mech.frame_def = frame_def
	mech.max_hp = frame_def.life
	mech.current_hp = frame_def.life

	# ── 创建6个部件槽位 ──
	var body_slot_ids: Array[StringName] = [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]
	for slot_id: StringName in body_slot_ids:
		var slot: MechSlotState = MechSlotState.new()
		slot.slot_id = slot_id
		slot.slot_kind = &"PART"
		# 从框架定义读取基础属性
		var slot_data: Dictionary = frame_def.base_slots.get(String(slot_id), {})
		slot.base_armor = int(slot_data.get("armor", 0))
		slot.base_power = int(slot_data.get("power", 0))
		slot.base_durability = int(slot_data.get("durability", 0))
		mech.slots[slot_id] = slot

	# ── 创建2个武器槽位 ──
	for i: int in range(2):
		var weapon_slot_id: StringName = StringName("weapon_%d" % [i + 1])
		var w_slot: MechSlotState = MechSlotState.new()
		w_slot.slot_id = weapon_slot_id
		w_slot.slot_kind = &"WEAPON"
		mech.slots[weapon_slot_id] = w_slot

		# 如果有基础武器，创建 CardInstance 并装备
		if i < frame_def.base_weapons.size():
			var weapon_def_data: Dictionary = frame_def.base_weapons[i]
			# 基础武器可能没有 id 字段（仅有 name），生成一个框架内唯一的 id
			var weapon_id: String = weapon_def_data.get("id", "")
			if weapon_id == "":
				weapon_id = "%s_base_weapon_%d" % [frame_id, i + 1]
			# 为基础武器构建 EquipmentCardDef，确保攻击系统可读取威力/射程
			var weapon_def: EquipmentCardDef = EquipmentCardDef.new()
			weapon_def.card_id = StringName(weapon_id)
			weapon_def.display_name = weapon_def_data.get("name", "基础武器")
			weapon_def.card_kind = &"equipment"
			weapon_def.equipment_kind = &"WEAPON"
			weapon_def.might = int(weapon_def_data.get("damage", 0))
			weapon_def.range_value = int(weapon_def_data.get("range", 1))
			weapon_def.weapon_kind = StringName(weapon_def_data.get("weapon_type", ""))
			weapon_def.durability = 999  # 基础武器不可损坏
			var card_instance: CardInstance = _create_card_instance(
				StringName(weapon_id), owner_id, mech_id, &"equipment_slot", weapon_slot_id
			)
			card_instance.def = weapon_def
			context.game_state.cards[card_instance.instance_id] = card_instance
			w_slot.equipped_card = card_instance

	# ── 创建2个备用槽位 ──
	for i: int in range(2):
		var reserve_slot_id: StringName = StringName("reserve_%d" % [i + 1])
		var r_slot: MechSlotState = MechSlotState.new()
		r_slot.slot_id = reserve_slot_id
		r_slot.slot_kind = &"RESERVE"
		mech.slots[reserve_slot_id] = r_slot

	# ── 创建1个事件槽位 ──
	var event_slot: MechSlotState = MechSlotState.new()
	event_slot.slot_id = &"event"
	event_slot.slot_kind = &"EVENT"
	mech.slots[&"event"] = event_slot

	# ── 创建1个机师槽位 ──
	var pilot_slot: MechSlotState = MechSlotState.new()
	pilot_slot.slot_id = &"pilot"
	pilot_slot.slot_kind = &"PILOT"
	mech.slots[&"pilot"] = pilot_slot

	# ── 计算初始动力 ──
	mech.max_power = mech.get_total_power()
	mech.power = mech.max_power

	return mech


## 创建卡牌实例
func _create_card_instance(card_id: StringName, owner_id: StringName, mech_id: StringName, zone: StringName, slot_id: StringName) -> CardInstance:
	var gs: GameState = context.game_state
	var instance_id: StringName = gs.next_id("card")
	var card: CardInstance = CardInstance.new(instance_id, null)
	card.owner_player_id = owner_id
	card.mech_id = mech_id
	card.zone = zone
	card.slot_id = slot_id
	return card


## 注册已装备卡牌的效果到 EffectRegistry
func _register_equipped_effects(mech: MechState) -> void:
	if context.effect_registry == null:
		return
	for slot_id: StringName in mech.slots:
		var slot: MechSlotState = mech.slots[slot_id]
		if slot.equipped_card != null:
			context.effect_registry.register_card(slot.equipped_card)
