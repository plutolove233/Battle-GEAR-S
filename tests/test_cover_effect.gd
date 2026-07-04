extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")


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


## 测试：掩护牌减少攻击威力5点
func test_cover_reduces_attack_power_by_5():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	_equip_weapon(battle, &"enemy", &"weapon_001_光束军刀")

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	# 相邻位置
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.attack_count_this_turn = 0

	# 给防守方(敌方)一张掩护牌
	var cover_card_id := _give_action_card(battle, &"enemy", &"action_016_掩护")

	# 玩家声明攻击
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, enemy_mech.mech_id, weapon_id, attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare attack: %s" % declare_result.get("message", "")

	var attack_id: StringName = declare_result.get("attack_id", &"")

	# 防守方提交掩护
	var cover_result: Dictionary = battle.context.attack_service.submit_cover(
		attack_id, cover_card_id, &"enemy"
	)
	if not cover_result.get("ok", false):
		return "failed to submit cover: %s" % cover_result.get("message", "")

	# 结算攻击，检查威力是否被减少5
	var resolve_result: Dictionary = battle.context.attack_service.resolve_attack(attack_id)
	if not resolve_result.get("ok", false):
		return "failed to resolve attack: %s" % resolve_result.get("message", "")

	# 光束军刀威力10，掩护-5，实际威力5
	# 敌方护甲约3-4，伤害应该比无掩护时少5
	var damage_with_cover: int = resolve_result.get("damage", 0)

	# 对比：无掩护时的伤害
	var battle2 := _new_battle()
	_equip_weapon(battle2, &"player", &"weapon_001_光束军刀")
	_equip_weapon(battle2, &"enemy", &"weapon_001_光束军刀")
	var gs2 = battle2.context.game_state
	var player_mech2 = gs2.get_mech_for_player(&"player")
	var enemy_mech2 = gs2.get_mech_for_player(&"enemy")
	player_mech2.position = {"q": 0, "r": 0}
	enemy_mech2.position = {"q": 1, "r": 0}
	player_mech2.attack_count_this_turn = 0
	var weapon_id2: StringName = player_mech2.get_weapon_ids()[0]
	var attack_card_id2 := _give_action_card(battle2, &"player", &"action_001_进攻")
	var declare_result2: Dictionary = battle2.context.attack_service.declare_attack(
		player_mech2.mech_id, enemy_mech2.mech_id, weapon_id2, attack_card_id2
	)
	var resolve_result2: Dictionary = battle2.context.attack_service.resolve_attack(declare_result2.get("attack_id", &""))
	var damage_without_cover: int = resolve_result2.get("damage", 0)

	# 掩护应该使伤害减少5（或至少减少，因为威力-5）
	if damage_with_cover >= damage_without_cover:
		return "cover should reduce damage: with_cover=%d without_cover=%d" % [damage_with_cover, damage_without_cover]

	return true


## 测试：攻击者不能对自己发动的攻击使用掩护
func test_attacker_cannot_use_cover_on_own_attack():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	_equip_weapon(battle, &"enemy", &"weapon_001_光束军刀")

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.attack_count_this_turn = 0

	# 给攻击方(玩家)一张掩护牌
	var cover_card_id := _give_action_card(battle, &"player", &"action_016_掩护")

	# 玩家声明攻击
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, enemy_mech.mech_id, weapon_id, attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare attack: %s" % declare_result.get("message", "")

	var attack_id: StringName = declare_result.get("attack_id", &"")

	# 攻击者尝试对自己发动的攻击使用掩护 → 应该失败
	var cover_result: Dictionary = battle.context.attack_service.submit_cover(
		attack_id, cover_card_id, &"player"
	)
	if cover_result.get("ok", false):
		return "attacker should NOT be able to use cover on their own attack"

	return true


## 测试：掩护牌不受锁定状态影响
func test_cover_ignores_locked_status():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	_equip_weapon(battle, &"enemy", &"weapon_001_光束军刀")

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.attack_count_this_turn = 0

	# 给防守方(敌方)一张掩护牌
	var cover_card_id := _give_action_card(battle, &"enemy", &"action_016_掩护")

	# 对敌方施加锁定状态（来源为攻击方玩家）
	enemy_mech.statuses.append({
		"type": &"LOCKED",
		"source_player_id": &"player",
		"duration": &"THIS_TURN",
	})

	# 玩家声明攻击
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, enemy_mech.mech_id, weapon_id, attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare attack: %s" % declare_result.get("message", "")

	var attack_id: StringName = declare_result.get("attack_id", &"")

	# 被锁定的防守方使用掩护 → 应该成功（掩护不受锁定影响）
	var cover_result: Dictionary = battle.context.attack_service.submit_cover(
		attack_id, cover_card_id, &"enemy"
	)
	if not cover_result.get("ok", false):
		return "cover should be usable even when locked: %s" % cover_result.get("message", "")

	return true


## 测试：被攻击方可以使用掩护（1v1中目标方也可以掩护）
func test_target_player_can_use_cover():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	_equip_weapon(battle, &"enemy", &"weapon_001_光束军刀")

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.attack_count_this_turn = 0

	# 给防守方(敌方)一张掩护牌
	var cover_card_id := _give_action_card(battle, &"enemy", &"action_016_掩护")

	# 玩家声明攻击
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, enemy_mech.mech_id, weapon_id, attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare attack: %s" % declare_result.get("message", "")

	var attack_id: StringName = declare_result.get("attack_id", &"")

	# 被攻击方(敌方)使用掩护 → 应该成功
	var cover_result: Dictionary = battle.context.attack_service.submit_cover(
		attack_id, cover_card_id, &"enemy"
	)
	if not cover_result.get("ok", false):
		return "target player should be able to use cover: %s" % cover_result.get("message", "")

	return true
