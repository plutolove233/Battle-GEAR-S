extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const CardInstance = preload("res://scripts/runtime/CardInstance.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


func _give_action_card(battle: BattleState, player_id: StringName, card_def_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var card_def = battle.context.card_database.get_card(card_def_id)
	var instance_id: StringName = gs.next_id("test_action")
	var card := CardInstance.new(instance_id, card_def)
	card.owner_player_id = player_id
	card.zone = &"action_hand"
	gs.cards[instance_id] = card
	gs.players[player_id].action_hand.append(instance_id)
	return instance_id


func _equip_weapon(battle: BattleState, player_id: StringName, weapon_def_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(player_id)
	var weapon_def = battle.context.card_database.get_card(weapon_def_id)
	var instance_id: StringName = gs.next_id("test_weapon")
	var card := CardInstance.new(instance_id, weapon_def)
	card.owner_player_id = player_id
	card.mech_id = mech.mech_id
	card.zone = &"weapon_slot"
	card.slot_id = &"weapon_1"
	gs.cards[instance_id] = card
	if battle.context.effect_registry and mech.slots[&"weapon_1"].equipped_card:
		battle.context.effect_registry.unregister_card(mech.slots[&"weapon_1"].equipped_card)
	mech.slots[&"weapon_1"].equipped_card = card
	if battle.context.effect_registry:
		battle.context.effect_registry.register_card(card)
	return instance_id


func _prepare_player_attack(card_def_id: StringName, weapon_def_id: StringName = &"weapon_001_光束军刀") -> Dictionary:
	var battle := _new_battle()
	_equip_weapon(battle, &"player", weapon_def_id)

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	gs.players[&"enemy"].action_hand.clear()
	enemy_mech.position = {"q": 3, "r": 2}
	player_mech.attack_count_this_turn = 0

	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", card_def_id)
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id,
		enemy_mech.mech_id,
		weapon_id,
		attack_card_id
	)
	if not declare_result.get("ok", false):
		return {"error": "failed to declare attack: %s" % declare_result.get("message", "")}

	return {
		"battle": battle,
		"attack_id": declare_result.get("attack_id", &""),
		"player_mech": player_mech,
		"enemy_mech": enemy_mech,
	}


func test_bash_adds_four_power_to_attack():
	var setup := _prepare_player_attack(&"action_003_猛击")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var attack_context: Dictionary = battle.context.game_state.attacks.get(setup["attack_id"], {})
	var expected_damage: int = max(0, int(attack_context.get("power", 0)) + 4 - setup["enemy_mech"].get_armor())
	var result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	if not result.get("ok", false):
		return "attack did not resolve"
	if result.get("damage", -1) != expected_damage:
		return "猛击 should add 4 power to this attack; expected %s damage, got %s" % [expected_damage, result.get("damage", null)]
	return true


func test_bash_with_twisting_steel_whip_resolves_and_discards_target_actions():
	var setup := _prepare_player_attack(&"action_003_猛击", &"weapon_005_扭转钢鞭")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var gs = battle.context.game_state
	_give_action_card(battle, &"enemy", &"action_008_回避")
	_give_action_card(battle, &"enemy", &"action_011_疾行")
	var enemy_hand_before: int = gs.players[&"enemy"].action_hand.size()

	var result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	if not result.get("ok", false):
		return "扭转钢鞭+猛击 attack did not resolve: %s" % result
	if gs.players[&"enemy"].action_hand.size() != enemy_hand_before - 2:
		return "扭转钢鞭 should discard 2 target action cards on hit, before=%s after=%s" % [
			enemy_hand_before,
			gs.players[&"enemy"].action_hand.size(),
		]
	return true


func test_armor_break_adds_two_damage_markers_on_hit():
	var setup := _prepare_player_attack(&"action_004_破甲")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	if result.get("markers", -1) != 4:
		return "破甲 should add 2 markers to the base 2 markers, got %s" % result.get("markers", null)
	return true


func test_blitz_creates_repeat_attack_pending_action():
	var setup := _prepare_player_attack(&"action_006_闪击")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	_give_action_card(battle, &"player", &"action_001_进攻")
	var result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	var pending: Array = result.get("pending_actions", [])
	if pending.is_empty():
		return "闪击 should create a pending repeat attack option"
	if pending[0].get("type", &"") != &"FLASH_ATTACK":
		return "expected FLASH_ATTACK pending action, got %s" % pending[0].get("type", null)
	return true


func test_assault_waits_for_attacker_movement_after_response_window():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 2}
	player_mech.attack_count_this_turn = 0

	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_002_强袭")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id,
		enemy_mech.mech_id,
		weapon_id,
		attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare 强袭: %s" % declare_result.get("message", "")
	var result: Dictionary = battle._check_assault_movement(declare_result.get("attack_id", &""), player_mech.mech_id)
	if result.get("state", "") != "awaiting_assault_movement":
		return "强袭 should wait for attacker movement after response window, got %s" % result.get("state", null)
	return true


func test_prediction_locks_target_discards_action_and_cannot_be_nullified():
	var setup := _prepare_player_attack(&"action_007_预判")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var gs = battle.context.game_state
	var enemy_mech = setup["enemy_mech"]
	_give_action_card(battle, &"enemy", &"action_008_回避")
	var enemy_hand_before: int = gs.players[&"enemy"].action_hand.size()

	var attack_context: Dictionary = gs.attacks.get(setup["attack_id"], {})
	if not bool(attack_context.get("unnegatable", false)):
		return "预判 should make the attack unnegatable when declared"

	var result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	if not result.get("hit", false):
		return "预判 attack should hit in this setup"
	if not enemy_mech.has_status(&"LOCKED"):
		return "预判 should apply LOCKED to the target on hit"
	if gs.players[&"enemy"].action_hand.size() != enemy_hand_before - 1:
		return "预判 should discard one target action card, before=%s hand=%s discard=%s" % [
			enemy_hand_before,
			gs.players[&"enemy"].action_hand,
			gs.deck_state.discard_pile,
		]
	return true


func test_rush_response_uses_full_current_power_for_movement():
	var setup := _prepare_player_attack(&"action_001_进攻")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var rush_card_id := _give_action_card(battle, &"enemy", &"action_011_疾行")
	var result: Dictionary = battle.context.attack_service.submit_response(setup["attack_id"], rush_card_id, {})
	if not result.get("ok", false):
		return "failed to submit 疾行 response: %s" % result.get("message", "")
	if not result.get("has_movement", false):
		return "疾行 should expose a response movement step"
	var attack_context: Dictionary = battle.context.game_state.attacks.get(setup["attack_id"], {})
	if not bool(attack_context.get("response_use_current_power", false)):
		return "疾行 should use current full power, not half power"
	return true
