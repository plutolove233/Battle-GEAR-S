extends RefCounted
class_name DataRegistry

const PATHS := {
	"action_cards": "res://data/cards/action_cards.json",
	"event_cards": "res://data/cards/event_cards.json",
	"equipment_parts": "res://data/cards/equipment_parts.json",
	"equipment_weapons": "res://data/cards/equipment_weapons.json",
	"pilot_cards": "res://data/cards/pilot_cards.json",
	"mech_frames": "res://data/mechs/mech_frames.json",
	"history_nodes": "res://data/lore/history_nodes.json",
	"tutorial_campaign": "res://data/campaign/tutorial_campaign.json",
}

var action_cards: Dictionary = {}
var event_cards: Dictionary = {}
var equipment_parts: Dictionary = {}
var equipment_weapons: Dictionary = {}
var pilot_cards: Dictionary = {}
var mech_frames: Dictionary = {}
var history_nodes: Dictionary = {}
var tutorial_campaign: Dictionary = {}
var last_error: String = ""

func load_all() -> Dictionary:
	last_error = ""
	var loaded_action_cards := _load_array_by_id(PATHS.action_cards)
	if last_error != "":
		return {"ok": false, "message": last_error}
	var loaded_event_cards := _load_array_by_id(PATHS.event_cards)
	if last_error != "":
		return {"ok": false, "message": last_error}
	var loaded_equipment_parts := _load_array_by_id(PATHS.equipment_parts)
	if last_error != "":
		return {"ok": false, "message": last_error}
	var loaded_equipment_weapons := _load_array_by_id(PATHS.equipment_weapons)
	if last_error != "":
		return {"ok": false, "message": last_error}
	var loaded_pilot_cards := _load_array_by_id(PATHS.pilot_cards)
	if last_error != "":
		return {"ok": false, "message": last_error}
	var loaded_mech_frames := _load_array_by_id(PATHS.mech_frames)
	if last_error != "":
		return {"ok": false, "message": last_error}
	var loaded_history_nodes := _load_array_by_id(PATHS.history_nodes)
	if last_error != "":
		return {"ok": false, "message": last_error}
	var loaded_tutorial_campaign := _load_dictionary(PATHS.tutorial_campaign)
	if last_error != "":
		return {"ok": false, "message": last_error}
	action_cards = loaded_action_cards
	event_cards = loaded_event_cards
	equipment_parts = loaded_equipment_parts
	equipment_weapons = loaded_equipment_weapons
	pilot_cards = loaded_pilot_cards
	mech_frames = loaded_mech_frames
	history_nodes = loaded_history_nodes
	tutorial_campaign = loaded_tutorial_campaign
	return {"ok": true, "message": "loaded"}

func get_action_card(id: String) -> Dictionary:
	return _copy_dictionary(action_cards.get(id, {}))

func get_event_card(id: String) -> Dictionary:
	return _copy_dictionary(event_cards.get(id, {}))

func get_equipment_part(id: String) -> Dictionary:
	return _copy_dictionary(equipment_parts.get(id, {}))

func get_weapon(id: String) -> Dictionary:
	return _copy_dictionary(equipment_weapons.get(id, {}))

func get_pilot_card(id: String) -> Dictionary:
	return _copy_dictionary(pilot_cards.get(id, {}))

func get_mech_frame(id: String) -> Dictionary:
	return _copy_dictionary(mech_frames.get(id, {}))

func get_history_node(id: String) -> Dictionary:
	return _copy_dictionary(history_nodes.get(id, {}))

func get_tutorial_campaign() -> Dictionary:
	return _copy_dictionary(tutorial_campaign)

func get_tutorial_battle() -> Dictionary:
	return _copy_dictionary(tutorial_campaign.get("tutorial_battle", {}))

func list_action_cards() -> Array:
	return _copy_dictionary_rows(action_cards.values())

func list_parts() -> Array:
	return _copy_dictionary_rows(equipment_parts.values())

func list_weapons() -> Array:
	return _copy_dictionary_rows(equipment_weapons.values())

func list_pilot_cards() -> Array:
	return _copy_dictionary_rows(pilot_cards.values())

func list_available_equipment() -> Array:
	var result: Array = []
	for row in equipment_parts.values():
		result.append(_copy_dictionary(row))
	for row in equipment_weapons.values():
		result.append(_copy_dictionary(row))
	return result

func _load_array_by_id(path: String) -> Dictionary:
	var rows = _read_json(path)
	if last_error != "":
		return {}
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
	if last_error != "":
		return {}
	if typeof(value) != TYPE_DICTIONARY:
		last_error = "%s must contain a JSON object" % path
		return {}
	return value

func _copy_dictionary(value: Dictionary) -> Dictionary:
	return value.duplicate(true)

func _copy_dictionary_rows(rows: Array) -> Array:
	var copies: Array = []
	for row in rows:
		copies.append(_copy_dictionary(row))
	return copies

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
