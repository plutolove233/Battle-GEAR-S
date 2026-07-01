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


## 模拟对玩家武器打出聚能：在攻击方机甲上叠加 NEXT_ATTACK_POWER_buff 状态
## （即 APPLY_ENERGY_TO_WEAPON 的产物），可叠加多次。
func _apply_charge(battle: BattleState, player_id: StringName, weapon_id: StringName, delta: int = 4) -> void:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(player_id)
	mech.statuses.append({
		"status_id": gs.next_id("status"),
		"type": &"NEXT_ATTACK_POWER_BUFF",
		"weapon_id": weapon_id,
		"delta": delta,
		"consume_on_next_attack": true,
		"duration": &"THIS_TURN",
		"source_card_id": &"",
	})


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


## 聚能：本回合对所选武器叠加 NEXT_ATTACK_POWER_BUFF，该武器下次攻击结算时威力+N。
## 可叠加，每次使用都累加；结算后状态结束（本回合内）。
func test_charge_adds_four_power_to_next_attack():
	var setup := _prepare_player_attack(&"action_001_进攻")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var attack_context: Dictionary = battle.context.game_state.attacks.get(setup["attack_id"], {})
	var base_power: int = int(attack_context.get("power", 0))
	var base_damage: int = max(0, base_power - setup["enemy_mech"].get_armor())
	# 对该武器打出一次聚能（+4）
	_apply_charge(battle, &"player", setup["player_mech"].get_weapon_ids()[0], 4)
	var result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	if not result.get("ok", false):
		return "attack did not resolve"
	if result.get("damage", -1) != base_damage + 4:
		return "聚能 should add 4 power to the next attack; expected %s damage, got %s" % [base_damage + 4, result.get("damage", null)]
	# 结算后该武器的 聚能 状态应已被消耗（disabled）
	for status in setup["player_mech"].statuses:
		if status.get("type", &"") == &"NEXT_ATTACK_POWER_BUFF" and status.get("weapon_id", &"") == setup["player_mech"].get_weapon_ids()[0]:
			if not bool(status.get("disabled", false)):
				return "聚能 status should be consumed after the attack resolves"
	return true


## 聚能可叠加：连用两次应使威力累加 +8。
func test_charge_stacks_repeated_uses():
	var setup := _prepare_player_attack(&"action_001_进攻")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var attack_context: Dictionary = battle.context.game_state.attacks.get(setup["attack_id"], {})
	var base_power: int = int(attack_context.get("power", 0))
	var base_damage: int = max(0, base_power - setup["enemy_mech"].get_armor())
	var weapon_id: StringName = setup["player_mech"].get_weapon_ids()[0]
	_apply_charge(battle, &"player", weapon_id, 4)
	_apply_charge(battle, &"player", weapon_id, 4)
	var result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	if not result.get("ok", false):
		return "attack did not resolve"
	if result.get("damage", -1) != base_damage + 8:
		return "聚能 should stack across uses; expected %s damage, got %s" % [base_damage + 8, result.get("damage", null)]
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
			gs.deck_state.action_discard_pile,
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


func test_evade_response_uses_half_power_budget():
	var setup := _prepare_player_attack(&"action_001_进攻")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var enemy_mech = setup["enemy_mech"]
	# 给防守方(敌方)充足动力以便检验"半动力"预算
	enemy_mech.power = 6
	var evade_card_id := _give_action_card(battle, &"enemy", &"action_008_回避")
	var submit_result: Dictionary = battle.context.attack_service.submit_response(setup["attack_id"], evade_card_id, {})
	if not submit_result.get("ok", false):
		return "failed to submit 回避 response: %s" % submit_result.get("message", "")
	var attack_context: Dictionary = battle.context.game_state.attacks.get(setup["attack_id"], {})
	if not bool(attack_context.get("response_has_movement", false)):
		return "回避 should expose a response movement step"
	# 战斗开始时 attack1 处于"等待迎击移动"状态而非已结算
	if battle.context.game_state.attacks.has(setup["attack_id"]) == false:
		return "回避 should keep attack1 unresolved until movement completes"
	# 回避使用半动力: floor(6 * 0.5) = 3
	if abs(battle._compute_evade_power_budget(enemy_mech, attack_context) - 3) > 0:
		return "回避 budget should be floor(power/2)=3, got %s" % battle._compute_evade_power_budget(enemy_mech, attack_context)
	return true


func test_evade_movement_out_of_range_makes_attack_miss():
	var setup := _prepare_player_attack(&"action_001_进攻")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var gs = battle.context.game_state
	var enemy_mech = setup["enemy_mech"]
	var player_mech = setup["player_mech"]
	# 攻击者(玩家)位于 (0,0)，敌人置于相邻。使用射程1的近战武器。
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.power = 6  # 预算 floor(6/2)=3，足够远离一格
	var evade_card_id := _give_action_card(battle, &"enemy", &"action_008_回避")
	# 走 BattleState 流程：提交迎击(产生移动阶段) → 执行移动到 (3,0) 远离 → 结算
	battle.context.attack_service.submit_response(setup["attack_id"], evade_card_id, {})
	# BattleState.current_attack_id 由 begin_attack 设置；这里直接走服务层，手动同步
	battle.current_attack_id = setup["attack_id"]
	# 攻击1仍挂起，等待移动
	if not gs.attacks.has(setup["attack_id"]):
		return "attack1 should remain pending before evade movement"
	# 执行移动到 (3,0)：超出近战射程1
	var resolve_result: Dictionary = battle.execute_evade_movement({"q": 3, "r": 0})
	if not resolve_result.get("ok", true):
		return "execute_evade_movement failed: %s" % resolve_result.get("message", "")
	if bool(resolve_result.get("hit", true)):
		return "attack1 should miss after 回避 moves out of weapon range, got hit=%s" % resolve_result.get("hit", null)
	# 攻击上下文应已清理
	if gs.attacks.has(setup["attack_id"]):
		return "attack1 context should be cleaned up after resolution"
	return true


func test_counterattack_pending_targets_original_attacker():
	var setup := _prepare_player_attack(&"action_001_进攻")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var gs = battle.context.game_state
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	# 敌方(防守方)打出反击
	var counter_card_id := _give_action_card(battle, &"enemy", &"action_010_反击")
	battle.context.attack_service.submit_response(setup["attack_id"], counter_card_id, {})
	# 反击含移动 → 先结算(无移动)取pending。直接 resolve 取 pending_after_resolve
	var attack_context: Dictionary = gs.attacks.get(setup["attack_id"], {})
	# 反击的 counterattack_after_resolution 在 RESOLVED 时生成 pending，这里手动 resolve
	var resolve_result: Dictionary = battle.context.attack_service.resolve_attack(setup["attack_id"])
	var pending: Dictionary = battle.get_counterattack_pending(resolve_result, &"enemy")
	if pending.is_empty():
		return "反击 should create a COUNTERATTACK pending action for the defender"
	# pending 目标应为原攻击者(玩家机甲)
	if String(pending.get("target_id", &"")) != String(player_mech.mech_id):
		return "反击 attack2 should target the original attacker, got %s" % pending.get("target_id", null)
	# pending 反击方应为防守方(敌方机甲)
	if String(pending.get("source_mech_id", &"")) != String(enemy_mech.mech_id):
		return "反击 attack2 source should be the defender mech, got %s" % pending.get("source_mech_id", null)
	return true


## 锁定：辅助牌打出后给目标施加 LOCKED 状态（来源=打出者）；
## 该玩家攻击命中目标后解除锁定；锁定持续到回合结束。
func test_lock_card_applies_locked_and_clears_on_hit():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 2}
	player_mech.attack_count_this_turn = 0
	gs.players[&"enemy"].action_hand.clear()
	# 辅助牌打出要求主阶段
	gs.phase = &"MAIN"

	# 玩家打出锁定，指定敌方机甲
	var lock_card_id := _give_action_card(battle, &"player", &"action_023_锁定")
	var play_result: Dictionary = battle.context.card_play_service.play_action_card(
		&"player", lock_card_id, {"target_mech_id": enemy_mech.mech_id}
	)
	if not play_result.get("ok", false):
		return "锁定 should play successfully, got: %s" % play_result
	if not enemy_mech.has_status(&"LOCKED"):
		return "锁定 should apply LOCKED status to the target"
	# 锁定来源应为玩家
	var locked_by_player: bool = false
	for status in enemy_mech.statuses:
		if String(status.get("type", &"")) == "LOCKED" and String(status.get("source_player_id", &"")) == "player":
			locked_by_player = true
	if not locked_by_player:
		return "LOCKED status should be sourced by the player who played 锁定"

	# 玩家发动攻击并结算（命中）→ 锁定应解除
	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_001_进攻")
	var declare_result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, enemy_mech.mech_id, weapon_id, attack_card_id
	)
	if not declare_result.get("ok", false):
		return "failed to declare attack: %s" % declare_result.get("message", "")
	var resolve_result: Dictionary = battle.context.attack_service.resolve_attack(declare_result["attack_id"])
	if not resolve_result.get("hit", false):
		return "attack should hit"
	if enemy_mech.has_status(&"LOCKED"):
		return "LOCKED should be removed after the target is hit by the attacker"
	return true


## 锁定只解除"来源玩家"施加的锁定：第三方攻击命中不应解除他人施加的锁定。
func test_lock_only_clears_when_attacker_is_source():
	var battle := _new_battle()
	_equip_weapon(battle, &"enemy", &"weapon_001_光束军刀")
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 2}
	player_mech.position = {"q": 4, "r": 2}
	enemy_mech.attack_count_this_turn = 0
	gs.players[&"enemy"].action_hand.clear()

	# 直接在敌方身上施加"来源=玩家"的锁定状态
	enemy_mech.statuses.append({
		"status_id": gs.next_id("status"),
		"type": &"LOCKED",
		"duration": &"THIS_TURN",
		"source_card_id": &"",
		"source_player_id": &"player",
	})

	# 敌方（非锁定来源）攻击玩家命中 —— 不应解除玩家施加在敌方身上的锁定
	var enemy_weapon_id: StringName = enemy_mech.get_weapon_ids()[0]
	var enemy_attack_card := _give_action_card(battle, &"enemy", &"action_001_进攻")
	var enemy_declare: Dictionary = battle.context.attack_service.declare_attack(
		enemy_mech.mech_id, player_mech.mech_id, enemy_weapon_id, enemy_attack_card
	)
	if not enemy_declare.get("ok", false):
		return "enemy attack should declare: %s" % enemy_declare.get("message", "")
	battle.context.attack_service.resolve_attack(enemy_declare["attack_id"])
	# 玩家施加在敌方身上的锁定应仍然存在（攻击来源是敌方而非玩家，不应被解除）
	if not enemy_mech.has_status(&"LOCKED"):
		return "LOCKED from player should NOT be cleared by an attack from a different source"
	return true


func test_counterattack_free_attack_needs_no_attack_card():
	var setup := _prepare_player_attack(&"action_001_进攻")
	if setup.has("error"):
		return setup["error"]
	var battle: BattleState = setup["battle"]
	var gs = battle.context.game_state
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	# 双方相邻，敌方能反击命中玩家
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.power = 6
	# 敌方需要武器才能反击
	_equip_weapon(battle, &"enemy", &"weapon_001_光束军刀")
	if enemy_mech.get_weapon_ids().is_empty():
		return "enemy should have a weapon equipped for counterattack"
	# 敌方打出反击并停留原地完成移动
	var counter_card_id := _give_action_card(battle, &"enemy", &"action_010_反击")
	battle.context.attack_service.submit_response(setup["attack_id"], counter_card_id, {})
	battle.current_attack_id = setup["attack_id"]
	# 停留原地完成迎击移动 → 结算 attack1
	var resolve_result: Dictionary = battle.execute_evade_movement(enemy_mech.position.duplicate())
	if not resolve_result.get("ok", true):
		return "execute_evade_movement failed: %s" % resolve_result.get("message", "")
	var pending: Dictionary = battle.get_counterattack_pending(resolve_result, &"enemy")
	if pending.is_empty():
		return "反击 should produce a counterattack pending after attack1 resolves"
	# 发动反击 attack2（无需攻击牌，attack_card_id 为空）
	var enemy_hand_before: int = gs.players[&"player"].action_hand.size()
	var atk2: Dictionary = battle.begin_pending_counterattack(pending)
	if not atk2.get("ok", false):
		return "反击 attack2 (free attack) should begin without an attack card: %s" % atk2.get("message", "")
	# 反击不消耗玩家攻击牌（自由攻击）
	if gs.players[&"player"].action_hand.size() != enemy_hand_before:
		return "反击 attack2 should not consume an attack card"
	return true


## 强袭：走 BattleState.begin_attack 完整流程（玩家攻击→AI带移动迎击），
## 必须返回 ok:true 的 awaiting_assault_movement，否则 app_root 会因
## `if not result.get("ok", false)` 判定失败而放弃攻击，强袭追击效果无法发动。
func test_assault_begin_attack_returns_awaiting_with_ok_flag():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 敌方相邻、有回避牌、有足够动力先行远离一格
	enemy_mech.position = {"q": 1, "r": 0}
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.power = 6
	player_mech.attack_count_this_turn = 0
	gs.players[&"enemy"].action_hand.clear()
	_give_action_card(battle, &"enemy", &"action_008_回避")

	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var attack_card_id := _give_action_card(battle, &"player", &"action_002_强袭")
	var result: Dictionary = battle.begin_attack(&"player", &"enemy", weapon_id, attack_card_id)
	if not result.get("ok", false):
		return "强袭 begin_attack 必须返回 ok:true，否则 app_root 会放弃整次攻击，got: %s" % result
	if result.get("state", "") != "awaiting_assault_movement":
		return "强袭应在 AI 迎击移动完成后进入 awaiting_assault_movement，got state=%s" % result.get("state", null)
	if String(result.get("attack_id", &"")) == "":
		return "awaiting_assault_movement 应携带 attack_id"
	# 攻击上下文应仍存在，等待强袭移动结算
	if not gs.attacks.has(result["attack_id"]):
		return "强袭攻击上下文应保持挂起，等待攻击方移动结算"
	return true


## 强袭：攻击方用当前动力移动（含原地停留）追赶后再结算，应正常命中并弃置强袭牌。
func test_assault_movement_then_resolves_and_discards():
	var battle := _new_battle()
	_equip_weapon(battle, &"player", &"weapon_001_光束军刀")
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 敌方位于玩家射程2边缘(2,0)；清空敌方手牌使其不迎击、不移动，
	# 强袭仍触发"目标响应结算后用当前动力移动、再结算攻击"的追击阶段。
	enemy_mech.position = {"q": 2, "r": 0}
	player_mech.position = {"q": 0, "r": 0}
	player_mech.power = 6
	player_mech.attack_count_this_turn = 0
	gs.players[&"enemy"].action_hand.clear()

	var weapon_id: StringName = player_mech.get_weapon_ids()[0]
	var assault_card_id := _give_action_card(battle, &"player", &"action_002_强袭")
	var begin_result: Dictionary = battle.begin_attack(&"player", &"enemy", weapon_id, assault_card_id)
	if begin_result.get("state", "") != "awaiting_assault_movement":
		return "前置条件失败：未进入 awaiting_assault_movement，got %s" % begin_result

	# 停留原地结算（光束军刀射程2，敌方未移动仍在射程内）
	var stay_hex: Dictionary = player_mech.position
	var resolve_result: Dictionary = battle.execute_assault_movement(stay_hex)
	if not resolve_result.get("ok", false):
		return "强袭移动后应成功结算，got: %s" % resolve_result
	if not resolve_result.get("hit", false):
		return "强袭追击结算应命中，got hit=%s" % resolve_result.get("hit", null)
	# 强袭牌应在攻击结算后进入弃牌堆（所有效果结算后才弃牌）
	var assault_card = gs.get_card(assault_card_id)
	if assault_card == null or String(assault_card.zone) != "discard":
		return "强袭牌应在攻击结算后进入弃牌堆，zone=%s" % (assault_card.zone if assault_card else "null")
	return true

