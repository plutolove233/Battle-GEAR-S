extends RefCounted
class_name CampaignState

const DataRegistry = preload("res://scripts/data/data_registry.gd")

var registry: DataRegistry
var selected_faction: String = ""
var selected_pilot: Dictionary = {}
var selected_equipment: Array[String] = []
var last_result: Dictionary = {}
var initialized: bool = false

func initialize(data_registry: DataRegistry) -> Dictionary:
	_clear_state()
	if data_registry == null:
		return {"ok": false, "message": "registry is unavailable"}
	var campaign := data_registry.get_tutorial_campaign()
	if campaign.is_empty():
		return {"ok": false, "message": "campaign data is unavailable"}
	registry = data_registry
	selected_faction = campaign.get("default_faction", "联邦")
	var pilots: Array = campaign.get("pilots", [])
	selected_pilot = pilots[0].duplicate(true) if pilots.size() > 0 else {}
	selected_equipment = []
	last_result = {}
	initialized = true
	return {"ok": true, "message": "campaign_initialized"}

func list_available_pilots() -> Array:
	if not initialized:
		return []
	return registry.get_tutorial_campaign().get("pilots", [])

func list_available_equipment() -> Array:
	var result: Array = []
	if not initialized:
		return result
	for item in registry.list_parts():
		result.append(item)
	for item in registry.list_weapons():
		result.append(item)
	return result


## 从 N 稀有度装备池中随机抽取指定数量的装备（至少含 min_weapons 张武器牌）
## 返回选中的装备字典数组，每项含 id, name, rarity, slot 等原始 JSON 字段
func generate_random_equipment_selection(count: int = 4, min_weapons: int = 1) -> Array:
	var result: Array = []
	if not initialized or registry == null:
		return result

	# 收集 N 稀有度零件和武器
	var n_parts: Array = []
	var n_weapons: Array = []
	for item in registry.list_parts():
		if typeof(item) == TYPE_DICTIONARY and String(item.get("rarity", "")) == "N":
			n_parts.append(item)
	for item in registry.list_weapons():
		if typeof(item) == TYPE_DICTIONARY and String(item.get("rarity", "")) == "N":
			n_weapons.append(item)

	# 先随机选至少 min_weapons 张武器
	var selected_ids: Array[String] = []
	var weapon_count: int = mini(min_weapons, n_weapons.size())
	n_weapons = _shuffle_and_copy(n_weapons)
	for i in range(weapon_count):
		var item: Dictionary = n_weapons[i]
		var id: String = String(item.get("id", ""))
		if id != "":
			result.append(item)
			selected_ids.append(id)

	# 从剩余 N 稀有度装备（零件+武器）中补齐
	var remaining: Array = []
	for item in n_parts:
		var id: String = String(item.get("id", ""))
		if not id in selected_ids:
			remaining.append(item)
	for i in range(weapon_count, n_weapons.size()):
		var item: Dictionary = n_weapons[i]
		var id: String = String(item.get("id", ""))
		if not id in selected_ids:
			remaining.append(item)

	remaining = _shuffle_and_copy(remaining)
	var need: int = count - result.size()
	for i in range(mini(need, remaining.size())):
		result.append(remaining[i])

	return result


## Fisher-Yates 洗牌并返回副本
func _shuffle_and_copy(arr: Array) -> Array:
	var copy: Array = arr.duplicate(true)
	for i in range(copy.size() - 1, 0, -1):
		var j: int = randi() % (i + 1)
		var tmp = copy[i]
		copy[i] = copy[j]
		copy[j] = tmp
	return copy

func select_faction(faction: String) -> Dictionary:
	if not initialized:
		return _not_initialized()
	if faction.strip_edges() == "":
		return {"ok": false, "message": "faction is empty"}
	selected_faction = faction
	return {"ok": true, "message": "faction_selected"}

func select_pilot(pilot_id: String) -> Dictionary:
	if not initialized:
		return _not_initialized()
	for pilot in list_available_pilots():
		if pilot.get("id", "") == pilot_id:
			selected_pilot = pilot.duplicate(true)
			return {"ok": true, "message": "pilot_selected"}
	return {"ok": false, "message": "pilot is unavailable"}

func select_equipment(equipment_ids: Array[String]) -> Dictionary:
	if not initialized:
		return _not_initialized()
	for id in equipment_ids:
		if registry.get_equipment_part(id).is_empty() and registry.get_weapon(id).is_empty():
			return {"ok": false, "message": "equipment is unavailable: %s" % id}
	selected_equipment = equipment_ids.duplicate()
	return {"ok": true, "message": "equipment_selected"}

func build_tutorial_context() -> Dictionary:
	if not initialized:
		return {
			"ok": false,
			"message": "campaign is not initialized",
			"faction": "",
			"pilot": {},
			"equipment_ids": [],
		}
	return {
		"ok": true,
		"message": "tutorial_context_built",
		"faction": selected_faction,
		"pilot": selected_pilot.duplicate(true),
		"equipment_ids": selected_equipment.duplicate(),
	}

func record_battle_result(result: Dictionary) -> Dictionary:
	if not initialized:
		return _not_initialized()
	last_result = result.duplicate(true)
	return {"ok": true, "message": "battle_result_recorded"}

func _clear_state() -> void:
	registry = null
	selected_faction = ""
	selected_pilot = {}
	selected_equipment = []
	last_result = {}
	initialized = false

func _not_initialized() -> Dictionary:
	return {"ok": false, "message": "campaign is not initialized"}
