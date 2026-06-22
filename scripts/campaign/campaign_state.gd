extends RefCounted
class_name CampaignState

const DataRegistry = preload("res://scripts/data/data_registry.gd")

var registry: DataRegistry
var selected_faction: String = ""
var selected_pilot: Dictionary = {}
var selected_equipment: Array[String] = []
var last_result: Dictionary = {}

func initialize(data_registry: DataRegistry) -> void:
	registry = data_registry
	var campaign := registry.get_tutorial_campaign()
	selected_faction = campaign.get("default_faction", "联邦")
	var pilots: Array = campaign.get("pilots", [])
	selected_pilot = pilots[0].duplicate(true) if pilots.size() > 0 else {}
	selected_equipment = []
	last_result = {}

func list_available_pilots() -> Array:
	return registry.get_tutorial_campaign().get("pilots", [])

func list_available_equipment() -> Array:
	var result: Array = []
	for item in registry.list_parts():
		result.append(item)
	for item in registry.list_weapons():
		result.append(item)
	return result

func select_faction(faction: String) -> Dictionary:
	if faction.strip_edges() == "":
		return {"ok": false, "message": "faction is empty"}
	selected_faction = faction
	return {"ok": true, "message": "faction_selected"}

func select_pilot(pilot_id: String) -> Dictionary:
	for pilot in list_available_pilots():
		if pilot.get("id", "") == pilot_id:
			selected_pilot = pilot.duplicate(true)
			return {"ok": true, "message": "pilot_selected"}
	return {"ok": false, "message": "pilot is unavailable"}

func select_equipment(equipment_ids: Array[String]) -> Dictionary:
	for id in equipment_ids:
		if registry.get_equipment_part(id).is_empty() and registry.get_weapon(id).is_empty():
			return {"ok": false, "message": "equipment is unavailable: %s" % id}
	selected_equipment = equipment_ids.duplicate()
	return {"ok": true, "message": "equipment_selected"}

func build_tutorial_context() -> Dictionary:
	return {
		"faction": selected_faction,
		"pilot": selected_pilot.duplicate(true),
		"equipment_ids": selected_equipment.duplicate(),
	}

func record_battle_result(result: Dictionary) -> void:
	last_result = result.duplicate(true)
