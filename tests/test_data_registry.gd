extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")

class PartialFailureRegistry:
	extends DataRegistry

	func _read_json(path: String):
		if path == DataRegistry.PATHS["action_cards"]:
			return [{"id": "action_stub", "name": "Stub Action"}]
		last_error = "%s does not exist" % path
		return null

func test_loads_action_card_by_id() -> bool:
	var registry := DataRegistry.new()
	var result := registry.load_all()
	if not result.ok:
		return result.message
	var card := registry.get_action_card("action_001_进攻")
	return card.get("name") == "进攻" and card.get("effect_ids") == ["basic_attack"]

func test_missing_id_returns_empty_dictionary() -> bool:
	var registry := DataRegistry.new()
	var result := registry.load_all()
	if not result.ok:
		return result.message
	return registry.get_weapon("missing_weapon").is_empty()

func test_tutorial_battle_config_is_available() -> bool:
	var registry := DataRegistry.new()
	var result := registry.load_all()
	if not result.ok:
		return result.message
	var config := registry.get_tutorial_battle()
	return config.get("id") == "battle_001_tutorial" and config.get("turn_limit") == 12

func test_returned_action_card_does_not_mutate_registry_copy() -> bool:
	var registry := DataRegistry.new()
	var result := registry.load_all()
	if not result.ok:
		return result.message
	var card := registry.get_action_card("action_001_进攻")
	card["name"] = "Mutated"
	return registry.get_action_card("action_001_进攻").get("name") == "进攻"

func test_list_action_cards_returns_copied_rows() -> bool:
	var registry := DataRegistry.new()
	var result := registry.load_all()
	if not result.ok:
		return result.message
	var cards := registry.list_action_cards()
	var id := String(cards[0].get("id", ""))
	cards[0]["name"] = "Mutated"
	return registry.get_action_card(id).get("name") != "Mutated"

func test_failed_load_keeps_existing_registry_data() -> bool:
	var registry := PartialFailureRegistry.new()
	registry.action_cards = {"existing_action": {"id": "existing_action", "name": "Existing Action"}}
	var result := registry.load_all()
	if result.ok:
		return false
	return result.message == "%s does not exist" % DataRegistry.PATHS["event_cards"] \
		and registry.get_action_card("existing_action").get("name") == "Existing Action"
