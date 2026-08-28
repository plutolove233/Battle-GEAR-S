## test_pilot_004_marsha.gd - 玛沙（pilot_004）专项逻辑测试
##
## 验证重做后的 3 效果：
##   effect_01a 装甲转能：TURN_START 转化 N 护甲->动力(cap_bonus 补满+上限) + 每3点抽2张
##   effect_01b 护甲恢复：TURN_BEFORE_START 清除转换层（护甲/动力恢复原值）
##   effect_02 动力穿透：ATTACK_PRE 攻守合并 CHOOSE_ONE 确认 -> SPEND_POWER3 + SET防御override
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 12345
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	return battle


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


func _setup_masha(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_004_玛沙", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


## 构造 turn action（fire TURN_START/TURN_BEFORE_START 用；action_type 须与
## TurnService._fire_timing 的虚拟 action 一致 &"turn"，否则 listen_action_type 过滤跳过）
func _make_turn_action(battle, turn_owner: StringName) -> _Action:
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p004_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": turn_owner}
	turn_action.state = &"running"
	turn_action.context = battle.context
	battle.context.action_registry.register(turn_action)
	return turn_action


# ═══════════════════════════════════════════
# effect_01a 装甲转能
# ═══════════════════════════════════════════

## 测试1：转化 N=3 -> armor-3 + power+3(cap_bonus 补满) + max_power+3 + 抽2张
func test_effect01a_convert_3_armor_to_power_and_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_masha(battle, &"player")
	if s == null:
		return "找不到 pilot_004_玛沙"
	var te = battle.context.timing_engine
	var mech = s.mech
	var armor_before: int = mech.get_armor()
	var power_before: int = mech.power
	var max_power_before: int = mech.max_power
	var hand_before: int = s.player.action_hand.size()
	if armor_before < 3:
		return "测试前置：玛沙护甲应>=3 实=%d" % armor_before
	# fire TURN_START -> effect_01a CHOOSE_ONE(optional) 挂起
	var turn_action := _make_turn_action(battle, &"player")
	te.fire_timing(_TimingConst.TURN_START, turn_action)
	if turn_action.state != &"waiting_timing":
		return "effect_01a 应在 TURN_START 挂起 CHOOSE_ONE，state=%s" % String(turn_action.state)
	# resume CHOOSE_ONE: 选 option 0 (将护甲转化为动力) -> CHOOSE_INTEGER 挂起
	te.resume_pending_effect(turn_action.action_id, {"chosen_option_index": 0})
	if turn_action.state != &"waiting_timing":
		return "CHOOSE_ONE 确认后应挂起 CHOOSE_INTEGER，state=%s" % String(turn_action.state)
	# resume CHOOSE_INTEGER: n=3
	te.resume_pending_effect(turn_action.action_id, {"chosen_value": 3})
	# 验证：armor-3, power+3(cap_bonus 补满), max_power+3, draw 2
	if mech.get_armor() != armor_before - 3:
		return "护甲应-3 实=%d（before=%d）" % [mech.get_armor(), armor_before]
	if mech.power != power_before + 3:
		return "动力应+3（补满）实=%d（before=%d）" % [mech.power, power_before]
	if mech.max_power != max_power_before + 3:
		return "动力上限应+3 实=%d（before=%d）" % [mech.max_power, max_power_before]
	if s.player.action_hand.size() != hand_before + 2:
		return "应抽2张行动牌 实=%d（before=%d）" % [s.player.action_hand.size(), hand_before]
	return true


## 测试2：转化 N=0（确认0）-> 不转化（armor/power/draw 不变）
func test_effect01a_convert_0_no_change() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_masha(battle, &"player")
	if s == null:
		return "找不到 pilot_004_玛沙"
	var te = battle.context.timing_engine
	var mech = s.mech
	var armor_before: int = mech.get_armor()
	var power_before: int = mech.power
	var hand_before: int = s.player.action_hand.size()
	var turn_action := _make_turn_action(battle, &"player")
	te.fire_timing(_TimingConst.TURN_START, turn_action)
	if turn_action.state != &"waiting_timing":
		return "effect_01a 应挂起 CHOOSE_ONE"
	te.resume_pending_effect(turn_action.action_id, {"chosen_option_index": 0})
	te.resume_pending_effect(turn_action.action_id, {"chosen_value": 0})
	# N=0：不转化
	if mech.get_armor() != armor_before:
		return "N=0 护甲应变 实=%d（before=%d）" % [mech.get_armor(), armor_before]
	if mech.power != power_before:
		return "N=0 动力应变 实=%d（before=%d）" % [mech.power, power_before]
	if s.player.action_hand.size() != hand_before:
		return "N=0 不应抽牌"
	return true


# ═══════════════════════════════════════════
# effect_01b 护甲恢复
# ═══════════════════════════════════════════

## 测试3：转化后下个我方回合 TURN_BEFORE_START -> 恢复原值
func test_effect01b_restore_after_conversion() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_masha(battle, &"player")
	if s == null:
		return "找不到 pilot_004_玛沙"
	var te = battle.context.timing_engine
	var mech = s.mech
	var armor_before: int = mech.get_armor()
	var power_before: int = mech.power
	var max_power_before: int = mech.max_power
	if armor_before < 3:
		return "测试前置：玛沙护甲应>=3"
	# 先转化 N=3
	var turn1 := _make_turn_action(battle, &"player")
	te.fire_timing(_TimingConst.TURN_START, turn1)
	te.resume_pending_effect(turn1.action_id, {"chosen_option_index": 0})
	te.resume_pending_effect(turn1.action_id, {"chosen_value": 3})
	if mech.get_armor() != armor_before - 3:
		return "转化后护甲应-3 实=%d" % mech.get_armor()
	# fire TURN_BEFORE_START（我方回合）-> effect_01b 清除转换层
	s.gs.active_player_id = &"player"
	var turn2 := _make_turn_action(battle, &"player")
	te.fire_timing(_TimingConst.TURN_BEFORE_START, turn2)
	# 验证恢复
	if mech.get_armor() != armor_before:
		return "恢复后护甲应回原值 实=%d（before=%d）" % [mech.get_armor(), armor_before]
	if mech.power != power_before:
		return "恢复后动力应回原值 实=%d（before=%d）" % [mech.power, power_before]
	if mech.max_power != max_power_before:
		return "恢复后动力上限应回原值 实=%d（before=%d）" % [mech.max_power, max_power_before]
	return true


# ═══════════════════════════════════════════
# effect_02 动力穿透
# ═══════════════════════════════════════════

## 测试4：玛沙攻击时消耗3动力 + 防御override[target]=current_power
func test_effect02_attacker_power_pierce() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_masha(battle, &"player")
	if s == null:
		return "找不到 pilot_004_玛沙"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if mech.power < 3:
		return "测试前置：玛沙动力应>=3 实=%d" % mech.power
	var power_before: int = mech.power
	# 构造 attack action（玛沙攻击敌人）
	var attack := _Action.new()
	attack.action_id = &"test_p004_atk_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": mech.mech_id, "target_id": enemy_mech.mech_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": mech.mech_id, "player_id": &"player"}
	battle.context.action_registry.register(attack)
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "effect_02 应在 ATTACK_PRE 挂起 CHOOSE_ONE 确认，state=%s" % String(attack.state)
	var pend: Dictionary = te._pending_effect.get(attack.action_id, {})
	var pend_eff = pend.get("effect", null)
	if pend_eff == null or String(pend_eff.effect_id) != "pilot_004_effect_02":
		return "挂起 effect 应为 pilot_004_effect_02 实=%s" % String(pend_eff.effect_id if pend_eff != null else "null")
	# resume CHOOSE_ONE: 确认消耗3动力（option 0）
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	# 验证：power-3 + defense_stat_override[target]=current_power
	if mech.power != power_before - 3:
		return "玛沙动力应-3 实=%d（before=%d）" % [mech.power, power_before]
	var override: Dictionary = attack.record.get("defense_stat_override", {})
	if String(override.get(enemy_mech.mech_id, &"")) != "current_power":
		return "defense_stat_override[target] 应=current_power 实=%s" % String(override.get(enemy_mech.mech_id, &""))
	return true


## 测试5：玛沙被攻击时消耗3动力 + 防御override[自身]=current_power
func test_effect02_defender_power_pierce() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_masha(battle, &"player")
	if s == null:
		return "找不到 pilot_004_玛沙"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if mech.power < 3:
		return "测试前置：玛沙动力应>=3 实=%d" % mech.power
	var power_before: int = mech.power
	# 构造 attack action（敌人攻击玛沙）
	var attack := _Action.new()
	attack.action_id = &"test_p004_def_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": enemy_mech.mech_id, "target_id": mech.mech_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": enemy_mech.mech_id, "player_id": &"enemy"}
	battle.context.action_registry.register(attack)
	# ATTACK_PRE 不开响应窗口，effect_02 直接挂起（无须模拟窗口关闭补跑）
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "effect_02 应在 ATTACK_PRE（被攻击）挂起 CHOOSE_ONE，state=%s" % String(attack.state)
	# resume CHOOSE_ONE: 确认消耗3动力
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	# 验证：power-3 + defense_stat_override[玛沙]=current_power
	if mech.power != power_before - 3:
		return "玛沙动力应-3 实=%d（before=%d）" % [mech.power, power_before]
	var override: Dictionary = attack.record.get("defense_stat_override", {})
	if String(override.get(mech.mech_id, &"")) != "current_power":
		return "defense_stat_override[玛沙] 应=current_power 实=%s" % String(override.get(mech.mech_id, &""))
	return true


## 测试6：玛沙动力<3 时 effect_02 不触发
func test_effect02_low_power_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_masha(battle, &"player")
	if s == null:
		return "找不到 pilot_004_玛沙"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 把动力降到 <3
	mech.power = 2
	var attack := _Action.new()
	attack.action_id = &"test_p004_low_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": mech.mech_id, "target_id": enemy_mech.mech_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": mech.mech_id, "player_id": &"player"}
	battle.context.action_registry.register(attack)
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# 动力<3：effect_02 条件 OWNER_POWER_ABOVE_OR_EQUAL(3) 不满足，不应挂起其 CHOOSE_ONE。
	# ATTACK_PRE 可能有 tutorial 机甲的其他监听器挂起，故不检查 attack.state，
	# 而检查 effect_02 未进 _pending_effect + defense_stat_override 未被写。
	var pend: Dictionary = te._pending_effect.get(attack.action_id, {})
	var pend_eff = pend.get("effect", null)
	if pend_eff != null and String(pend_eff.effect_id) == "pilot_004_effect_02":
		return "动力<3 时 effect_02 不应触发挂起"
	var override: Dictionary = attack.record.get("defense_stat_override", {})
	if not override.is_empty():
		return "动力<3 时不应写 defense_stat_override"
	return true


# ═══════════════════════════════════════════
# effect_01a 跨玩家回合抽牌归属（1A 修复验证）
# ═══════════════════════════════════════════

## 测试7：玛沙在敌方回合转化，抽牌进玛沙拥有者手牌（非当前回合玩家）
## 1A 修复前：EXECUTE_GAIN_CARD 无显式 player_id，_resolve_atomic_params 注入 parent_action
## （虚拟 turn action）的 source.player_id=当前回合玩家，致敌方回合转化抽牌进敌方手牌。
## 修复后：player_id 显式绑 $binding_context.player_id=玛沙拥有者。
func test_effect01a_enemy_turn_draw_to_owner() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_masha(battle, &"player")  # 玛沙拥有者=player
	if s == null:
		return "找不到 pilot_004_玛沙"
	var te = battle.context.timing_engine
	var mech = s.mech
	var armor_before: int = mech.get_armor()
	if armor_before < 3:
		return "测试前置：玛沙护甲应>=3 实=%d" % armor_before
	var enemy_player = s.gs.players.get(&"enemy")
	var player_hand_before: int = s.player.action_hand.size()
	var enemy_hand_before: int = enemy_player.action_hand.size() if enemy_player != null else -1
	# 敌方回合 fire TURN_START（turn_owner=enemy），玛沙（owner=player）应触发转化
	var turn_action := _make_turn_action(battle, &"enemy")
	te.fire_timing(_TimingConst.TURN_START, turn_action)
	if turn_action.state != &"waiting_timing":
		return "effect_01a 应在敌方回合 TURN_START 仍触发挂起，state=%s" % String(turn_action.state)
	te.resume_pending_effect(turn_action.action_id, {"chosen_option_index": 0})
	te.resume_pending_effect(turn_action.action_id, {"chosen_value": 3})
	# 验证：抽牌进玛沙拥有者（player）手牌，而非当前回合玩家（enemy）
	if s.player.action_hand.size() != player_hand_before + 2:
		return "玛沙拥有者(player)应+2张 实=%d（before=%d）" % [s.player.action_hand.size(), player_hand_before]
	if enemy_player != null and enemy_player.action_hand.size() != enemy_hand_before:
		return "当前回合玩家(enemy)不应抽牌 实=%d（before=%d）" % [enemy_player.action_hand.size(), enemy_hand_before]
	return true
