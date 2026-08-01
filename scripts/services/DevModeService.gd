## DevModeService.gd — 开发者模式服务
##
## 提供开发者模式的卡牌和属性修改功能。
class_name DevModeService
extends RefCounted

var context = null  # type: GameContext

## 卡牌定义缓存（从 CardDatabase 获取）
var _action_card_ids: Array[StringName] = []
var _equipment_part_ids: Array[StringName] = []
var _equipment_weapon_ids: Array[StringName] = []
var _event_card_ids: Array[StringName] = []
var _pilot_card_ids: Array[StringName] = []
var _mech_frame_ids: Array[StringName] = []


func _init(game_context = null) -> void:
	context = game_context
	if context != null:
		_load_card_ids()


## 加载所有卡牌定义ID
func _load_card_ids() -> void:
	if context == null or context.card_database == null:
		return

	# 获取所有行动牌
	_action_card_ids.clear()
	_equipment_part_ids.clear()
	_equipment_weapon_ids.clear()
	_event_card_ids.clear()
	_pilot_card_ids.clear()
	_mech_frame_ids.clear()

	# 从 DataRegistry 获取卡牌ID列表
	if context.game_state != null:
		var gs = context.game_state
		# 遍历已加载的卡牌定义
		for card_id in gs.cards:
			var card = gs.cards[card_id]
			if card != null and card.def != null:
				var kind = card.def.card_kind
				if kind == &"action":
					if not card_id in _action_card_ids:
						_action_card_ids.append(card_id)
				elif kind == &"equipment":
					var eq_def = card.def as EquipmentCardDef
					if eq_def != null:
						if eq_def.equipment_kind == &"PART":
							if not card_id in _equipment_part_ids:
								_equipment_part_ids.append(card_id)
						elif eq_def.equipment_kind == &"WEAPON":
							if not card_id in _equipment_weapon_ids:
								_equipment_weapon_ids.append(card_id)
				elif kind == &"event":
					if not card_id in _event_card_ids:
						_event_card_ids.append(card_id)
				elif kind == &"pilot":
					if not card_id in _pilot_card_ids:
						_pilot_card_ids.append(card_id)
				elif kind == &"mech_frame":
					if not card_id in _mech_frame_ids:
						_mech_frame_ids.append(card_id)


## 重新加载卡牌定义（从 CardDatabase 重新获取）
func reload_card_definitions() -> void:
	if context == null or context.card_database == null:
		return

	_action_card_ids.clear()
	_equipment_part_ids.clear()
	_equipment_weapon_ids.clear()
	_event_card_ids.clear()
	_pilot_card_ids.clear()
	_mech_frame_ids.clear()

	# 从 CardDatabase 加载（通过查找所有已定义的卡牌）
	var db = context.card_database
	# 尝试从 DataRegistry 获取
	if context.data_registry != null:
		var reg = context.data_registry
		for id in reg.action_cards:
			_action_card_ids.append(StringName(id))
		for id in reg.equipment_parts:
			_equipment_part_ids.append(StringName(id))
		for id in reg.equipment_weapons:
			_equipment_weapon_ids.append(StringName(id))
		for id in reg.event_cards:
			_event_card_ids.append(StringName(id))
		for id in reg.pilot_cards:
			_pilot_card_ids.append(StringName(id))
		for id in reg.mech_frames:
			_mech_frame_ids.append(StringName(id))


## 获取所有行动牌ID
func get_action_card_ids() -> Array[StringName]:
	return _action_card_ids.duplicate()


## 获取所有装备部件ID
func get_equipment_part_ids() -> Array[StringName]:
	return _equipment_part_ids.duplicate()


## 获取所有装备武器ID
func get_equipment_weapon_ids() -> Array[StringName]:
	return _equipment_weapon_ids.duplicate()


## 获取所有事件牌ID
func get_event_card_ids() -> Array[StringName]:
	return _event_card_ids.duplicate()


## 获取所有机师牌ID
func get_pilot_card_ids() -> Array[StringName]:
	return _pilot_card_ids.duplicate()


## 获取所有机甲框架ID
func get_mech_frame_ids() -> Array[StringName]:
	return _mech_frame_ids.duplicate()


## 获取所有卡牌名称（用于显示）
func get_card_display_name(card_id: StringName) -> String:
	var gs = context.game_state
	var card = gs.cards.get(card_id)
	if card != null and card.def != null:
		return String(card.def.display_name)
	return String(card_id)


## 获取卡牌类型
func get_card_kind(card_id: StringName) -> StringName:
	var gs = context.game_state
	var card = gs.cards.get(card_id)
	if card != null and card.def != null:
		return card.def.card_kind
	return &""


## ── 行动牌操作 ──


## 为玩家添加一张行动牌（到手牌）
func add_action_card_to_player(player_id: StringName, card_def_id: StringName) -> StringName:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""

	# 创建卡牌实例
	var instance_id = _create_card_instance(card_def_id, &"action_hand")
	if instance_id == &"":
		return &""

	# 添加到玩家手牌
	player.action_hand.append(instance_id)
	var card = gs.cards.get(instance_id)
	if card != null:
		card.zone = &"action_hand"
		card.owner_player_id = player_id

	return instance_id


## 弃置玩家的一张行动牌
func discard_action_card_from_player(player_id: StringName, card_instance_id: StringName) -> bool:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return false

	if card_instance_id in player.action_hand:
		player.action_hand.erase(card_instance_id)
		# 移到弃牌堆
		var card = gs.cards.get(card_instance_id)
		if card != null:
			card.zone = &"action_discard"
			if gs.deck_state != null:
				gs.deck_state.action_discard_pile.append(card_instance_id)
		return true
	return false


## 弃置玩家的所有行动牌
func discard_all_action_cards_from_player(player_id: StringName) -> int:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return 0

	var count = 0
	while not player.action_hand.is_empty():
		var card_id = player.action_hand[0]
		if discard_action_card_from_player(player_id, card_id):
			count += 1
	return count


## 获取玩家所有行动牌
func get_player_action_cards(player_id: StringName) -> Array[StringName]:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return []
	return player.action_hand.duplicate()


## 获取所有玩家ID
func get_all_player_ids() -> Array[StringName]:
	var gs = context.game_state
	var result: Array[StringName] = []
	for pid in gs.players:
		result.append(pid)
	return result


## ── 装备牌操作 ──


## 为玩家添加一张装备牌（不设置到槽位）
func add_equipment_card_to_player(player_id: StringName, card_def_id: StringName) -> StringName:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""

	# 创建卡牌实例
	var instance_id = _create_card_instance(card_def_id, &"equipment_hand")
	if instance_id == &"":
		return &""

	# 添加到玩家装备手牌
	player.equipment_hand.append(instance_id)
	var card = gs.cards.get(instance_id)
	if card != null:
		card.zone = &"equipment_hand"
		card.owner_player_id = player_id

	return instance_id


## 将装备牌设置到机甲槽位
func set_equipment_card_to_slot(player_id: StringName, card_instance_id: StringName, slot_id: StringName) -> bool:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return false

	if not mech.slots.has(slot_id):
		return false

	# 调用 GameState 方法设置槽位
	gs.set_card_to_slot(card_instance_id, mech.mech_id, slot_id)
	return true


## 弃置玩家的一张装备牌（从手牌或槽位）
func discard_equipment_card_from_player(player_id: StringName, card_instance_id: StringName) -> bool:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return false

	# 从手牌中移除
	if card_instance_id in player.equipment_hand:
		player.equipment_hand.erase(card_instance_id)
		var card = gs.cards.get(card_instance_id)
		if card != null:
			card.zone = &"equipment_discard"
			if gs.deck_state != null:
				gs.deck_state.equipment_discard_pile.append(card_instance_id)
		return true

	# 从槽位中移除
	var mech = gs.get_mech_for_player(player_id)
	if mech != null:
		for sid in mech.slots:
			var slot = mech.slots[sid]
			if slot.equipped_card != null and slot.equipped_card.instance_id == card_instance_id:
				slot.equipped_card = null
				var card = gs.cards.get(card_instance_id)
				if card != null:
					card.zone = &"equipment_discard"
					card.slot_id = &""
					card.mech_id = &""
					if gs.deck_state != null:
						gs.deck_state.equipment_discard_pile.append(card_instance_id)
				return true

	return false


## 获取玩家所有装备牌（包括手牌和槽位）
func get_player_equipment_cards(player_id: StringName) -> Array[Dictionary]:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return []

	var result: Array[Dictionary] = []

	# 手牌
	for card_id in player.equipment_hand:
		var card = gs.cards.get(card_id)
		if card != null:
			result.append({
				"instance_id": card_id,
				"def_id": card.def.card_id if card.def != null else &"",
				"display_name": card.def.display_name if card.def != null else "",
				"zone": "hand"
			})

	# 槽位
	var mech = gs.get_mech_for_player(player_id)
	if mech != null:
		for slot_id in mech.slots:
			var slot = mech.slots[slot_id]
			if slot.equipped_card != null:
				var card = slot.equipped_card
				result.append({
					"instance_id": card.instance_id,
					"def_id": card.def.card_id if card.def != null else &"",
					"display_name": card.def.display_name if card.def != null else "",
					"zone": "slot",
					"slot_id": slot_id
				})

	return result


## 获取机甲所有槽位ID
func get_mech_slot_ids(player_id: StringName) -> Array[StringName]:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return []

	var result: Array[StringName] = []
	for sid in mech.slots:
		result.append(sid)
	return result


## ── 区域损伤操作 ──


## 在机甲槽位上增加区域损伤
func add_region_damage(player_id: StringName, slot_id: StringName, amount: int = 1) -> bool:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return false

	if not mech.slots.has(slot_id):
		return false

	var slot = mech.slots[slot_id]
	# 双计 region + 装备卡 damage_tokens（与 DamageTokenService 一致），并同步派生动力上限
	slot.region_damage_tokens += amount
	if slot.equipped_card != null:
		slot.equipped_card.damage_tokens += amount
	mech.recalc_power_limits()
	return true


## 在机甲槽位上减少区域损伤
func remove_region_damage(player_id: StringName, slot_id: StringName, amount: int = 1) -> bool:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return false

	if not mech.slots.has(slot_id):
		return false

	var slot = mech.slots[slot_id]
	slot.region_damage_tokens = max(0, slot.region_damage_tokens - amount)
	if slot.equipped_card != null:
		slot.equipped_card.damage_tokens = max(0, slot.equipped_card.damage_tokens - amount)
	mech.recalc_power_limits()
	return true


## 获取机甲槽位区域损伤
func get_region_damage(player_id: StringName, slot_id: StringName) -> int:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return 0

	if not mech.slots.has(slot_id):
		return 0

	return mech.slots[slot_id].region_damage_tokens


## ── 玩家属性修改 ──


## 修改玩家金币
func modify_player_gold(player_id: StringName, amount: int) -> int:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return -1

	player.gold = max(0, player.gold + amount)
	return player.gold


## 修改机甲生命值
func modify_mech_hp(player_id: StringName, amount: int) -> int:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return -1

	mech.current_hp = clamp(mech.current_hp + amount, 0, mech.max_hp)
	return mech.current_hp


## 设置机甲生命值
func set_mech_hp(player_id: StringName, value: int) -> int:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return -1

	mech.current_hp = clamp(value, 0, mech.max_hp)
	return mech.current_hp


## 修改机甲动力
func modify_mech_power(player_id: StringName, amount: int) -> int:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return -1

	mech.power = clamp(mech.power + amount, 0, mech.max_power)
	return mech.power


## 设置机甲动力
func set_mech_power(player_id: StringName, value: int) -> int:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return -1

	mech.power = clamp(value, 0, mech.max_power)
	return mech.power


## 修改机甲护甲（通过修改所有部件槽的有效护甲）
func modify_mech_armor(player_id: StringName, amount: int) -> int:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return -1

	# 通过修改基础护甲实现（暂时无法直接修改有效护甲，因为它是计算出来的）
	# 这里我们直接修改current_hp来模拟护甲效果
	return mech.get_armor()


## 获取机甲信息
func get_mech_info(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return {}

	var player = gs.players.get(player_id)
	return {
		"mech_id": mech.mech_id,
		"current_hp": mech.current_hp,
		"max_hp": mech.max_hp,
		"power": mech.power,
		"max_power": mech.max_power,
		"armor": mech.get_armor(),
		"gold": player.gold if player != null else 0,
		"attack_count": mech.attack_count_this_turn,
		"max_attacks": mech.max_attacks_per_turn,
		"destroyed": mech.destroyed
	}


## ── 内部方法 ──


## 根据定义ID创建卡牌实例
func _create_card_instance(card_def_id: StringName, zone: StringName) -> StringName:
	var gs = context.game_state

	# 获取卡牌定义
	var card_def = null
	if context.card_database != null:
		card_def = context.card_database.get_card(card_def_id)

	if card_def == null:
		# 尝试从 DataRegistry 直接创建
		if context.data_registry != null:
			var reg = context.data_registry
			var data = reg.action_cards.get(card_def_id, {})
			if data.is_empty():
				data = reg.equipment_parts.get(card_def_id, {})
			if data.is_empty():
				data = reg.equipment_weapons.get(card_def_id, {})
			if data.is_empty():
				data = reg.event_cards.get(card_def_id, {})
			if data.is_empty():
				data = reg.pilot_cards.get(card_def_id, {})
			# 使用数据创建基本定义（简化版本）
			# 这里只返回空，因为完整实现需要通过 CardDatabaseLoader
			pass

	# 如果没有定义，创建一个虚拟卡牌
	var instance_id = gs.next_id("dev_card")
	var card = CardInstance.new(instance_id, card_def)
	card.zone = zone
	gs.cards[instance_id] = card
	return instance_id
