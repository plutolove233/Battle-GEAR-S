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
