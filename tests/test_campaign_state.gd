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

func test_select_equipment_records_loadout() -> bool:
	var campaign := _new_campaign()
	var result := campaign.select_equipment(["weapon_001_光束军刀", "part_001_量产装_头部"])
	return result.ok and campaign.selected_equipment.size() == 2

func test_build_tutorial_context_contains_selected_loadout() -> bool:
	var campaign := _new_campaign()
	campaign.select_equipment(["weapon_001_光束军刀"])
	var context := campaign.build_tutorial_context()
	return context.pilot.name == "克劳德" and context.equipment_ids.has("weapon_001_光束军刀")
