## CardDatabaseLoader.gd — 从 DataRegistry 加载 JSON 并转换为 CardDef 对象
##
## 负责将 DataRegistry 中的原始 Dictionary 数据转换为类型化的 CardDef 实例。
## JSON 字段名与 CardDef 属性名不一致时在此处做映射（如 damage→might）。
class_name CardDatabaseLoader
extends RefCounted

## 卡牌→效果映射：card_id → [effect_id, ...]（用于后续效果绑定）
var _effect_ids_map: Dictionary = {}


## 从 DataRegistry 加载所有卡牌，返回 { card_id: CardDef }
func load_from_registry(registry: DataRegistry) -> Dictionary:
	var result: Dictionary = {}
	_effect_ids_map.clear()

	# 加载装备部件
	for id in registry.equipment_parts:
		var data: Dictionary = registry.equipment_parts[id]
		var def := _load_equipment_part(data)
		result[def.card_id] = def

	# 加载装备武器
	for id in registry.equipment_weapons:
		var data: Dictionary = registry.equipment_weapons[id]
		var def := _load_equipment_weapon(data)
		result[def.card_id] = def

	# 加载行动牌
	for id in registry.action_cards:
		var data: Dictionary = registry.action_cards[id]
		var def := _load_action_card(data)
		result[def.card_id] = def

	# 加载事件牌
	for id in registry.event_cards:
		var data: Dictionary = registry.event_cards[id]
		var def := _load_event_card(data)
		result[def.card_id] = def

	# 加载飞行员牌
	for id in registry.pilot_cards:
		var data: Dictionary = registry.pilot_cards[id]
		var def := _load_pilot_card(data)
		result[def.card_id] = def

	# 加载机甲框架
	for id in registry.mech_frames:
		var data: Dictionary = registry.mech_frames[id]
		var def := _load_mech_frame(data)
		result[def.card_id] = def

	return result


## 获取卡牌→效果映射（load_from_registry 调用后可用）
func get_effect_ids_map() -> Dictionary:
	return _effect_ids_map


## ── 装备部件：JSON → EquipmentCardDef ──
## JSON 字段：id, category, set_name, slot, rarity, count, effect_text, armor, power, durability, cost, effect_ids
func _load_equipment_part(data: Dictionary) -> EquipmentCardDef:
	var def := EquipmentCardDef.new()
	# 基类 CardDef 字段
	def.card_id = StringName(data.get("id", ""))
	# 部件 JSON 没有 name 字段，用 set_name + slot 组合作为显示名
	var raw_name: String = String(data.get("name", ""))
	if raw_name == "":
		raw_name = "%s %s" % [String(data.get("set_name", "")), String(data.get("slot", ""))]
	def.display_name = raw_name if raw_name != "" else String(data.get("id", ""))
	def.card_kind = &"equipment"
	def.rarity = String(data.get("rarity", "N"))
	def.count = int(data.get("count", 1))
	def.effect_text = String(data.get("effect_text", ""))
	# 装备大类
	def.equipment_kind = &"PART"
	# 部件属性
	def.slot = StringName(data.get("slot", ""))
	def.set_name = String(data.get("set_name", ""))
	def.armor = int(data.get("armor", 0))
	def.power = int(data.get("power", 0))
	def.durability = int(data.get("durability", 0))
	def.cost = int(data.get("cost", 0))
	# 记录效果 ID
	_record_effect_ids(def.card_id, data)
	return def


## ── 装备武器：JSON → EquipmentCardDef ──
## JSON 字段：id, name, weapon_type, slot, rarity, count, effect_text, damage, range, durability, cost, effect_ids
## 字段映射：damage → might, range → range_value, weapon_type → weapon_kind
func _load_equipment_weapon(data: Dictionary) -> EquipmentCardDef:
	var def := EquipmentCardDef.new()
	# 基类 CardDef 字段
	def.card_id = StringName(data.get("id", ""))
	def.display_name = String(data.get("name", data.get("id", "")))
	def.card_kind = &"equipment"
	def.rarity = String(data.get("rarity", "N"))
	def.count = int(data.get("count", 1))
	def.effect_text = String(data.get("effect_text", ""))
	# 装备大类
	def.equipment_kind = &"WEAPON"
	# 武器槽位（新 JSON 包含 slot 字段，如 "武器"）
	def.slot = StringName(data.get("slot", &"武器"))
	# 武器属性（字段名映射）
	def.might = int(data.get("damage", 0))           # JSON damage → CardDef might
	def.range_value = int(data.get("range", 0))       # JSON range → CardDef range_value
	def.weapon_kind = StringName(data.get("weapon_type", ""))  # JSON weapon_type → CardDef weapon_kind
	# 武器标签（用于槽位兼容性检查和效果条件判断）
	def.tags.append(&"武器")
	if def.weapon_kind == &"近战":
		def.tags.append(&"近战")
	elif def.weapon_kind == &"远程":
		def.tags.append(&"远程")
	elif def.weapon_kind == &"特殊":
		def.tags.append(&"特殊")
	# 通用属性
	def.durability = int(data.get("durability", 0))
	def.cost = int(data.get("cost", 0))
	# 记录效果 ID
	_record_effect_ids(def.card_id, data)
	return def


## ── 行动牌：JSON → ActionCardDef ──
## JSON 字段：id, name, type, rarity, count, effect_text, effect_ids
## 字段映射：type → action_type
func _load_action_card(data: Dictionary) -> ActionCardDef:
	var def := ActionCardDef.new()
	# 基类 CardDef 字段
	def.card_id = StringName(data.get("id", ""))
	def.display_name = String(data.get("name", data.get("id", "")))
	def.card_kind = &"action"
	def.rarity = String(data.get("rarity", "N"))
	def.count = int(data.get("count", 1))
	def.effect_text = String(data.get("effect_text", ""))
	# 行动类型（字段名映射）
	def.action_type = StringName(data.get("type", ""))
	# 记录效果 ID
	_record_effect_ids(def.card_id, data)
	return def


## ── 事件牌：JSON → EventCardDef ──
## JSON 字段：id, name, delay, tone, rarity, count, timing, effect_text, effect_ids
func _load_event_card(data: Dictionary) -> EventCardDef:
	var def := EventCardDef.new()
	# 基类 CardDef 字段
	def.card_id = StringName(data.get("id", ""))
	def.display_name = String(data.get("name", data.get("id", "")))
	def.card_kind = &"event"
	def.rarity = String(data.get("rarity", "N"))
	def.count = int(data.get("count", 1))
	def.effect_text = String(data.get("effect_text", ""))
	# 事件牌属性
	def.delay = int(data.get("delay", 0))
	def.tone = String(data.get("tone", ""))
	def.timing = String(data.get("timing", ""))
	# 记录效果 ID
	_record_effect_ids(def.card_id, data)
	return def


## ── 机甲框架：JSON → MechFrameDef ──
## JSON 字段：id, name, faction, life, effect_text, base_slots, base_weapons
## base_weapons 中：damage → might, range → range_value, weapon_type → weapon_kind
func _load_mech_frame(data: Dictionary) -> MechFrameDef:
	var def := MechFrameDef.new()
	# 基类 CardDef 字段
	def.card_id = StringName(data.get("id", ""))
	def.display_name = String(data.get("name", data.get("id", "")))
	def.card_kind = &"mech_frame"
	def.rarity = String(data.get("rarity", "N"))
	def.count = int(data.get("count", 1))
	def.effect_text = String(data.get("effect_text", ""))
	# 机甲框架属性
	def.faction = String(data.get("faction", ""))
	def.life = int(data.get("life", 25))
	# 基础槽位：直接复制 Dictionary（结构已匹配）
	var raw_slots = data.get("base_slots", {})
	if typeof(raw_slots) == TYPE_DICTIONARY:
		def.base_slots = raw_slots.duplicate(true)
	# 基础武器：映射 damage→might, range→range_value, weapon_type→weapon_kind
	var raw_weapons = data.get("base_weapons", [])
	if typeof(raw_weapons) == TYPE_ARRAY:
		for weapon_data in raw_weapons:
			if typeof(weapon_data) != TYPE_DICTIONARY:
				continue
			var weapon_dict: Dictionary = {}
			weapon_dict["name"] = String(weapon_data.get("name", ""))
			weapon_dict["weapon_kind"] = StringName(weapon_data.get("weapon_type", ""))
			weapon_dict["might"] = int(weapon_data.get("damage", 0))        # JSON damage → might
			weapon_dict["range_value"] = int(weapon_data.get("range", 0))    # JSON range → range_value
			def.base_weapons.append(weapon_dict)
	# 记录效果 ID
	_record_effect_ids(def.card_id, data)
	return def


## ── 飞行员牌：JSON → PilotCardDef ──
## JSON 字段：id, name, rarity, count, faction, attack_limit, action_card_limit, cost, effect_text, effect_ids
func _load_pilot_card(data: Dictionary) -> PilotCardDef:
	var def := PilotCardDef.new()
	# 基类 CardDef 字段
	def.card_id = StringName(data.get("id", ""))
	def.display_name = String(data.get("name", data.get("id", "")))
	def.card_kind = &"pilot"
	def.rarity = String(data.get("rarity", "N"))
	def.count = int(data.get("count", 1))
	def.effect_text = String(data.get("effect_text", ""))
	# 飞行员属性
	def.attack_limit = int(data.get("attack_limit", 1))
	def.action_card_limit = int(data.get("action_card_limit", 5))
	def.faction = String(data.get("faction", ""))
	def.cost = int(data.get("cost", 0))
	# 记录效果 ID
	_record_effect_ids(def.card_id, data)
	return def


## ── 内部：记录卡牌的 effect_ids 用于后续效果绑定 ──
## 支持数组格式：effect_ids: ["effect_a", "effect_b"]
func _record_effect_ids(card_id: StringName, data: Dictionary) -> void:
	var ids = data.get("effect_ids", [])
	if typeof(ids) == TYPE_ARRAY:
		var valid_ids: Array[StringName] = []
		for eid in ids:
			if eid != "" and eid != null:
				valid_ids.append(StringName(eid))
		if valid_ids.size() > 0:
			_effect_ids_map[card_id] = valid_ids
