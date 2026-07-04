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


## 测试：玩家攻击 → AI反击 → AI的反击附加攻击应该产生 pending
func test_ai_counterattack_creates_pending():
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
	enemy_mech.power = 6
	gs.players[&"enemy"].action_hand.clear()

	# 玩家攻击
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, enemy_mech.mech_id, weapon_id, attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare attack: %s" % declare_result.get("message", "")

	# AI用反击响应
	var counter_card_id := _give_action_card(battle, &"enemy", &"action_010_反击")
	battle.context.attack_service.submit_response(declare_result.get("attack_id", &""), counter_card_id, {})
	battle.current_attack_id = declare_result.get("attack_id", &"")

	# AI停留原地完成迎击移动
	var resolve_result: Dictionary = battle.execute_evade_movement(enemy_mech.position.duplicate())
	if not resolve_result.get("ok", true):
		return "execute_evade_movement failed: %s" % resolve_result.get("message", "")

	# 应该有AI的反击pending
	var pending: Dictionary = battle.get_counterattack_pending(resolve_result, &"enemy")
	if pending.is_empty():
		return "AI counterattack should create COUNTERATTACK pending"
	if pending.get("source_player_id", &"") != &"enemy":
		return "pending source should be enemy, got %s" % pending.get("source_player_id", null)
	if pending.get("target_id", &"") != player_mech.mech_id:
		return "pending target should be player mech, got %s" % pending.get("target_id", null)

	return true


## 测试：玩家作为防守方反击后，玩家反击附加攻击应该产生 pending
func test_player_counterattack_creates_pending():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	_equip_weapon(battle, &"enemy", &"weapon_001_光束军刀")

	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	# 相邻位置
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.power = 6
	player_mech.attack_count_this_turn = 0
	enemy_mech.attack_count_this_turn = 0
	gs.players[&"player"].action_hand.clear()

	# 玩家用反击响应敌方的攻击
	var counter_card_id := _give_action_card(battle, &"player", &"action_010_反击")
	# 模拟敌方攻击声明
	var enemy_weapon_id: StringName = enemy_mech.get_weapon_ids()[0]
	var enemy_attack_card_id := _give_action_card(battle, &"enemy", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		enemy_mech.mech_id, player_mech.mech_id, enemy_weapon_id, enemy_attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare enemy attack: %s" % declare_result.get("message", "")

	# 玩家用反击响应
	battle.context.attack_service.submit_response(declare_result.get("attack_id", &""), counter_card_id, {})
	battle.current_attack_id = declare_result.get("attack_id", &"")

	# 玩家停留原地完成迎击移动
	var resolve_result: Dictionary = battle.execute_evade_movement(player_mech.position.duplicate())
	if not resolve_result.get("ok", true):
		return "execute_evade_movement failed: %s" % resolve_result.get("message", "")

	# 应该有玩家的反击pending
	var pending: Dictionary = battle.get_counterattack_pending(resolve_result, &"player")
	if pending.is_empty():
		return "Player counterattack should create COUNTERATTACK pending"
	if pending.get("source_player_id", &"") != &"player":
		return "pending source should be player, got %s" % pending.get("source_player_id", null)
	if pending.get("target_id", &"") != enemy_mech.mech_id:
		return "pending target should be enemy mech, got %s" % pending.get("target_id", null)

	return true


## 测试：反击附加攻击可以正常结算
## 场景：玩家攻击 → AI用反击响应 → attack1结算后AI获得反击pending → AI反击玩家 → 玩家不响应 → attack2结算
func test_counterattack_pending_can_execute():
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
	enemy_mech.power = 6
	player_mech.power = 6
	gs.players[&"player"].action_hand.clear()  # 玩家无手牌，无法响应attack2

	# 玩家攻击
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, enemy_mech.mech_id, weapon_id, attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare attack: %s" % declare_result.get("message", "")

	# AI用反击响应
	var counter_card_id := _give_action_card(battle, &"enemy", &"action_010_反击")
	battle.context.attack_service.submit_response(declare_result.get("attack_id", &""), counter_card_id, {})
	battle.current_attack_id = declare_result.get("attack_id", &"")

	# AI停留原地完成迎击移动 → 结算 attack1
	var resolve_result: Dictionary = battle.execute_evade_movement(enemy_mech.position.duplicate())
	if not resolve_result.get("ok", true):
		return "execute_evade_movement failed: %s" % resolve_result.get("message", "")

	# 取AI的反击pending
	var pending: Dictionary = battle.get_counterattack_pending(resolve_result, &"enemy")
	if pending.is_empty():
		return "should have AI counterattack pending"

	# 执行反击附加攻击 attack2（防守方是player，AI会自动响应）
	var atk2: Dictionary = battle.begin_pending_counterattack(pending)
	# 攻击方是enemy，防守方是player，玩家无手牌，AI会自动响应并返回resolved
	if atk2.get("state", "") != "resolved":
		return "counterattack should auto-resolve for player defender without response, got state: %s" % atk2.get("state", "")
	if not atk2.get("hit", false):
		return "counterattack attack2 should hit"

	return true
