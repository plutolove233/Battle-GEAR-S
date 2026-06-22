extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")

func test_loads_action_card_by_id() -> bool:
	var registry := DataRegistry.new()
	var result := registry.load_all()
	if not result.ok:
		return result.message
	var card := registry.get_action_card("action_001_进攻")
	return card.get("name") == "进攻" and card.get("effect_id") == "basic_attack"

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
