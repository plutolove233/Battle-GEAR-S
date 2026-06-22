extends RefCounted
class_name DataRegistry

const PATHS := {
	"action_cards": "res://data/cards/action_cards.json",
	"event_cards": "res://data/cards/event_cards.json",
	"equipment_parts": "res://data/cards/equipment_parts.json",
	"equipment_weapons": "res://data/cards/equipment_weapons.json",
	"mech_frames": "res://data/mechs/mech_frames.json",
	"history_nodes": "res://data/lore/history_nodes.json",
	"tutorial_campaign": "res://data/campaign/tutorial_campaign.json",
}

var action_cards: Dictionary = {}
var event_cards: Dictionary = {}
var equipment_parts: Dictionary = {}
var equipment_weapons: Dictionary = {}
var mech_frames: Dictionary = {}
var history_nodes: Dictionary = {}
var tutorial_campaign: Dictionary = {}
var last_error: String = ""

func load_all() -> Dictionary:
	last_error = ""
	action_cards = _load_array_by_id(PATHS.action_cards)
	event_cards = _load_array_by_id(PATHS.event_cards)
	equipment_parts = _load_array_by_id(PATHS.equipment_parts)
	equipment_weapons = _load_array_by_id(PATHS.equipment_weapons)
	mech_frames = _load_array_by_id(PATHS.mech_frames)
	history_nodes = _load_array_by_id(PATHS.history_nodes)
	tutorial_campaign = _load_dictionary(PATHS.tutorial_campaign)
	if last_error != "":
		return {"ok": false, "message": last_error}
	return {"ok": true, "message": "loaded"}

func get_action_card(id: String) -> Dictionary:
	return action_cards.get(id, {})

func get_event_card(id: String) -> Dictionary:
	return event_cards.get(id, {})

func get_equipment_part(id: String) -> Dictionary:
	return equipment_parts.get(id, {})

func get_weapon(id: String) -> Dictionary:
	return equipment_weapons.get(id, {})

func get_mech_frame(id: String) -> Dictionary:
	return mech_frames.get(id, {})

func get_history_node(id: String) -> Dictionary:
	return history_nodes.get(id, {})

func get_tutorial_campaign() -> Dictionary:
	return tutorial_campaign.duplicate(true)

func get_tutorial_battle() -> Dictionary:
	return tutorial_campaign.get("tutorial_battle", {}).duplicate(true)

func list_action_cards() -> Array:
	return action_cards.values()

func list_parts() -> Array:
	return equipment_parts.values()

func list_weapons() -> Array:
	return equipment_weapons.values()

func _load_array_by_id(path: String) -> Dictionary:
	var rows = _read_json(path)
	if typeof(rows) != TYPE_ARRAY:
		last_error = "%s must contain a JSON array" % path
		return {}
	var result: Dictionary = {}
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			last_error = "%s contains a non-object row" % path
			return {}
		var id := String(row.get("id", ""))
		if id == "":
			last_error = "%s contains a row without id" % path
			return {}
		if result.has(id):
			last_error = "%s contains duplicate id %s" % [path, id]
			return {}
		result[id] = row
	return result

func _load_dictionary(path: String) -> Dictionary:
	var value = _read_json(path)
	if typeof(value) != TYPE_DICTIONARY:
		last_error = "%s must contain a JSON object" % path
		return {}
	return value

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		last_error = "%s does not exist" % path
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "%s could not be opened" % path
		return null
	var text := file.get_as_text()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		last_error = "%s is not valid JSON" % path
	return parsed
