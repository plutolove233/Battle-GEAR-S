extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const CampaignState = preload("res://scripts/campaign/campaign_state.gd")

func _new_campaign() -> CampaignState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var campaign := CampaignState.new()
	campaign.initialize(registry)
	return campaign

func test_initial_campaign_selects_default_pilot() -> bool:
	var campaign := _new_campaign()
	return campaign.selected_faction == "联邦" and campaign.selected_pilot.get("name") == "克劳德"

func test_initialize_rejects_null_registry() -> bool:
	var campaign := CampaignState.new()
	var result := campaign.initialize(null)
	return not result.ok and not campaign.initialized

func test_initialize_rejects_unloaded_registry() -> bool:
	var campaign := CampaignState.new()
	var result := campaign.initialize(DataRegistry.new())
	return not result.ok and not campaign.initialized

func test_select_faction_rejects_empty_name() -> bool:
	var campaign := _new_campaign()
	var result := campaign.select_faction("   ")
	return not result.ok and campaign.selected_faction == "联邦"

func test_select_pilot_rejects_unavailable_pilot() -> bool:
	var campaign := _new_campaign()
	var result := campaign.select_pilot("missing_pilot")
	return not result.ok and campaign.selected_pilot.get("name") == "克劳德"

func test_select_equipment_records_loadout() -> bool:
	var campaign := _new_campaign()
	var result := campaign.select_equipment(["weapon_001_光束军刀", "part_001_量产装_头部"])
	return result.ok and campaign.selected_equipment.size() == 2

func test_select_equipment_rejects_unavailable_item() -> bool:
	var campaign := _new_campaign()
	var result := campaign.select_equipment(["missing_equipment"])
	return not result.ok and campaign.selected_equipment.is_empty()

func test_select_equipment_copies_input_ids() -> bool:
	var campaign := _new_campaign()
	var equipment_ids: Array[String] = ["weapon_001_光束军刀"]
	var result := campaign.select_equipment(equipment_ids)
	equipment_ids.append("part_001_量产装_头部")
	return result.ok and campaign.selected_equipment.size() == 1

func test_build_tutorial_context_contains_selected_loadout() -> bool:
	var campaign := _new_campaign()
	campaign.select_equipment(["weapon_001_光束军刀"])
	var context := campaign.build_tutorial_context()
	return context.pilot.name == "克劳德" and context.equipment_ids.has("weapon_001_光束军刀")

func test_record_battle_result_copies_input_result() -> bool:
	var campaign := _new_campaign()
	var battle_result := {"winner": "player", "rewards": {"gold": 50}}
	var result := campaign.record_battle_result(battle_result)
	battle_result.rewards.gold = 0
	return result.ok and campaign.last_result.rewards.gold == 50

func test_uninitialized_methods_fail_safely() -> bool:
	var campaign := CampaignState.new()
	var faction_result := campaign.select_faction("联邦")
	var pilot_result := campaign.select_pilot("pilot_001_克劳德")
	var equipment_result := campaign.select_equipment(["weapon_001_光束军刀"])
	var context := campaign.build_tutorial_context()
	var record_result := campaign.record_battle_result({"winner": "player"})
	return campaign.list_available_pilots().is_empty() \
		and campaign.list_available_equipment().is_empty() \
		and not faction_result.ok \
		and not pilot_result.ok \
		and not equipment_result.ok \
		and not context.ok \
		and context.pilot.is_empty() \
		and context.equipment_ids.is_empty() \
		and not record_result.ok \
		and campaign.last_result.is_empty()
