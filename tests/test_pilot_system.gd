extends RefCounted

## 机师牌系统测试（infra 2.2/2.3）
## 验证 set_pilot：数值联动（attack_limit/action_card_limit -> PlayerState/MechState）、
## pilot 槽放牌、换机师注销旧 listener。

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _UseActionCardAction = preload("res://scripts/action_defs/use_action_card_action.gd")
const _CampaignState = preload("res://scripts/campaign/campaign_state.gd")
const _DevModeService = preload("res://scripts/services/DevModeService.gd")


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


## 建一张机师牌实例并登记到 gs.cards
func _make_pilot_instance(gs, cdb, card_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 测试1：set_pilot 数值联动--pilot_002 莱比尔 action_card_limit=4（非默认5）
func test_set_pilot_links_pilot_002_limits() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return "找不到 pilot_002_莱比尔 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	# pilot_002: attack_limit=1, action_card_limit=4
	if player.action_card_limit != 4:
		return "PlayerState.action_card_limit 应=4(莱比尔) 实=%d" % player.action_card_limit
	if player.attack_limit != 1:
		return "PlayerState.attack_limit 应=1 实=%d" % player.attack_limit
	if player_mech.max_attacks_per_turn != 1:
		return "MechState.max_attacks_per_turn 应=1 实=%d" % player_mech.max_attacks_per_turn
	# pilot 槽放牌
	var slot = player_mech.slots.get(&"pilot")
	if slot == null or slot.equipped_card != card:
		return "pilot 槽应放置机师牌实例"
	if card.zone != &"pilot_slot" or card.slot_id != &"pilot":
		return "机师牌 zone/slot_id 应为 pilot_slot/pilot，实=%s/%s" % [String(card.zone), String(card.slot_id)]
	return true


## 测试2：set_pilot 数值联动--pilot_010 刻托 attack_limit=3 action_card_limit=1（均非默认）
func test_set_pilot_links_pilot_010_limits() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_010_刻托", &"player")
	if card == null:
		return "找不到 pilot_010_刻托 定义（确认 JSON card_id 命名）"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	# pilot_010: attack_limit=3, action_card_limit=1
	if player.attack_limit != 3:
		return "PlayerState.attack_limit 应=3(刻托) 实=%d" % player.attack_limit
	if player.action_card_limit != 1:
		return "PlayerState.action_card_limit 应=1(刻托) 实=%d" % player.action_card_limit
	if player_mech.max_attacks_per_turn != 3:
		return "MechState.max_attacks_per_turn 应=3 实=%d" % player_mech.max_attacks_per_turn
	return true


## 测试3：unset_pilot 清空 pilot 槽 + 注销 listener
func test_unset_pilot_clears_slot() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return "找不到 pilot_002_莱比尔 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var slot = player_mech.slots.get(&"pilot")
	if slot == null or slot.equipped_card != card:
		return "set_pilot 后 pilot 槽应有牌"
	# 注销
	battle.context.game_setup_service.unset_pilot(player_mech.mech_id)
	if slot.equipped_card != null:
		return "unset_pilot 后 pilot 槽应清空"
	if card.zone != &"" or card.slot_id != &"":
		return "unset_pilot 后牌 zone/slot_id 应清空"
	return true


## 测试4：换机师--set pilot A -> unset -> set pilot B，数值随新机师变
func test_swap_pilot_updates_limits() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card_a = _make_pilot_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card_a == null:
		return "找不到 pilot_002_莱比尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card_a)
	var player = gs.players.get(&"player")
	if player.action_card_limit != 4:
		return "莱比尔 action_card_limit 应=4 实=%d" % player.action_card_limit
	# 换成刻托
	battle.context.game_setup_service.unset_pilot(player_mech.mech_id)
	var card_b = _make_pilot_instance(gs, cdb, "pilot_010_刻托", &"player")
	if card_b == null:
		return "找不到 pilot_010_刻托"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card_b)
	if player.attack_limit != 3:
		return "换刻托后 attack_limit 应=3 实=%d" % player.attack_limit
	if player.action_card_limit != 1:
		return "换刻托后 action_card_limit 应=1 实=%d" % player.action_card_limit
	if player_mech.max_attacks_per_turn != 3:
		return "换刻托后 max_attacks_per_turn 应=3 实=%d" % player_mech.max_attacks_per_turn
	# 旧牌不在槽
	var slot = player_mech.slots.get(&"pilot")
	if slot.equipped_card != card_b:
		return "换机师后 pilot 槽应是新牌"
	return true


## 测试5：pilot_010 互换语义--互换上限/攻击数 + 设剩余攻击数 + 抽上限+1
## 直接调 game_actions.swap 验证语义（不依赖 CHOOSE_ONE 弹窗）
func test_swap_pilot_010_semantics() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_010_刻托", &"player")
	if card == null:
		return "找不到 pilot_010_刻托"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	# pilot_010 初始: action_card_limit=1, attack_limit=3
	if player.action_card_limit != 1 or player.attack_limit != 3 or player_mech.max_attacks_per_turn != 3:
		return "set_pilot 后应 hand=1/attack=3，实=%d/%d/%d" % [player.action_card_limit, player.attack_limit, player_mech.max_attacks_per_turn]
	var hand_before = player.action_hand.size()
	# 互换
	battle.context.game_actions.swap_hand_limit_and_attack_count({"player_id": &"player", "mech_id": player_mech.mech_id, "source_card_id": card.instance_id})
	# 互换后: action_card_limit=3, attack_limit=1, max_attacks=1, attack_count=0
	if player.action_card_limit != 3:
		return "互换后 action_card_limit 应=3 实=%d" % player.action_card_limit
	if player.attack_limit != 1 or player_mech.max_attacks_per_turn != 1:
		return "互换后 attack_limit/max_attacks 应=1 实=%d/%d" % [player.attack_limit, player_mech.max_attacks_per_turn]
	if player_mech.attack_count_this_turn != 0:
		return "互换后 attack_count_this_turn 应=0(剩余=新上限) 实=%d" % player_mech.attack_count_this_turn
	# 抽 新上限+1 = 4 张
	if player.action_hand.size() != hand_before + 4:
		return "互换后应抽4张(上限3+1)，实增=%d" % (player.action_hand.size() - hand_before)
	return true


## 测试6：set_pilot 后 pilot_010_effect_01 注册到 TURN_START（验证注册流程 + effect 定义）
func test_pilot_010_effect_registers_on_set() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_010_刻托", &"player")
	if card == null:
		return "找不到 pilot_010_刻托"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var te = battle.context.timing_engine
	var listeners: Array = te.permanent_listeners.get(_TimingConst.TURN_START, [])
	var found := false
	for entry in listeners:
		var eff = entry.get("effect")
		if eff != null and eff.effect_id == &"pilot_010_effect_01":
			var bc: Dictionary = entry.get("binding_context", {})
			if String(bc.get("card_instance_id", &"")) == String(card.instance_id) \
					and String(bc.get("slot_id", &"")) == "pilot":
				found = true
				break
	if not found:
		return "pilot_010_effect_01 应注册到 TURN_START（binding_context.card_instance_id + slot_id=pilot 匹配）"
	# unset 后应注销
	battle.context.game_setup_service.unset_pilot(player_mech.mech_id)
	listeners = te.permanent_listeners.get(_TimingConst.TURN_START, [])
	for entry in listeners:
		var eff = entry.get("effect")
		if eff != null and eff.effect_id == &"pilot_010_effect_01":
			var bc: Dictionary = entry.get("binding_context", {})
			if String(bc.get("card_instance_id", &"")) == String(card.instance_id):
				return "unset_pilot 后该 listener 应注销"
	return true


## 测试7：pilot_010 effect_03--第4张攻击牌禁止（计数器 helper）
func test_pilot_010_effect_03_blocks_4th() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_010_刻托", &"player")
	if card == null:
		return "找不到 pilot_010_刻托"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var slot = player_mech.slots.get(&"pilot")
	var pcard = slot.equipped_card
	var turn: int = gs.turn_number
	# 0张：可用
	if not _ActionPilotEffects.can_pilot_010_use_physical_attack_card(gs, player_mech.mech_id):
		return "0张时应可用"
	# 用3张
	for i in 3:
		_ActionPilotEffects.increment_pilot_010_attack_card_uses(pcard, turn)
	# 第4张：禁止
	if _ActionPilotEffects.can_pilot_010_use_physical_attack_card(gs, player_mech.mech_id):
		return "3张后第4张应禁止"
	# 新回合重置（turn_number+1，新 key=0）
	gs.turn_number = turn + 1
	if not _ActionPilotEffects.can_pilot_010_use_physical_attack_card(gs, player_mech.mech_id):
		return "新回合应重置为可用"
	return true


## 测试8：pilot_010 effect_02--第1/2/3张攻击牌视为强袭/闪击/预判（REPLACE 动作）
func test_pilot_010_effect_02_sequence() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_010_刻托", &"player")
	if card == null:
		return "找不到 pilot_010_刻托"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var slot = player_mech.slots.get(&"pilot")
	var pcard = slot.equipped_card
	var ga = battle.context.game_actions
	# 第1张 -> 强袭
	var mock1 = _Action.new()
	mock1.record = {}
	ga.replace_used_action_effect_by_sequence({"source_card_id": pcard.instance_id}, {}, mock1)
	if String(mock1.record.get("as_card_def_id", &"")) != "action_002_强袭":
		return "第1张应视为强袭，实=%s" % String(mock1.record.get("as_card_def_id", &""))
	# 第2张 -> 闪击
	var mock2 = _Action.new()
	mock2.record = {}
	ga.replace_used_action_effect_by_sequence({"source_card_id": pcard.instance_id}, {}, mock2)
	if String(mock2.record.get("as_card_def_id", &"")) != "action_006_闪击":
		return "第2张应视为闪击，实=%s" % String(mock2.record.get("as_card_def_id", &""))
	# 第3张 -> 预判
	var mock3 = _Action.new()
	mock3.record = {}
	ga.replace_used_action_effect_by_sequence({"source_card_id": pcard.instance_id}, {}, mock3)
	if String(mock3.record.get("as_card_def_id", &"")) != "action_007_预判":
		return "第3张应视为预判，实=%s" % String(mock3.record.get("as_card_def_id", &""))
	# counter=3
	if _ActionPilotEffects.get_pilot_010_attack_card_uses(pcard, gs.turn_number) != 3:
		return "3张后计数应=3，实=%d" % _ActionPilotEffects.get_pilot_010_attack_card_uses(pcard, gs.turn_number)
	# 第4张 effect_03 拦截：can_pilot_010 应 false
	if _ActionPilotEffects.can_pilot_010_use_physical_attack_card(gs, player_mech.mech_id):
		return "3张后第4张应被 effect_03 禁止"
	return true


## 测试9：pilot_004 装甲转能机制--POWER_CAP_MODIFIER(动力上限+补满) + ARMOR_MODIFIER + clear
func test_pilot_004_armor_to_power_mechanism() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_004_玛沙", &"player")
	if card == null:
		return "找不到 pilot_004_玛沙"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	var max_before: int = player_mech.max_power
	var power_before: int = player_mech.power
	var armor_before: int = player_mech.get_armor()
	# 动力 +6（cap_bonus：上限+6 + 补满）
	ga.modify_mech_power({"mech_id": player_mech.mech_id, "delta": 6, "mode": &"cap_bonus", "duration": &"UNTIL_NEXT_OWNER_TURN", "runtime_tag": &"pilot_004_power_conversion", "source_card_id": card.instance_id})
	if player_mech.max_power != max_before + 6:
		return "动力上限应+6 实=%d（before=%d）" % [player_mech.max_power, max_before]
	if player_mech.power != power_before + 6:
		return "动力应补满+6 实=%d（before=%d）" % [player_mech.power, power_before]
	# 护甲 -6
	ga.modify_armor({"mech_id": player_mech.mech_id, "delta": -6, "duration": &"UNTIL_NEXT_OWNER_TURN", "runtime_tag": &"pilot_004_armor_conversion", "source_card_id": card.instance_id})
	if player_mech.get_armor() != armor_before - 6:
		return "护甲应-6 实=%d（before=%d）" % [player_mech.get_armor(), armor_before]
	# 清除转换层
	ga.clear_source_stat_modifiers({"mech_id": player_mech.mech_id, "source_card_id": card.instance_id, "runtime_tags": [&"pilot_004_armor_conversion", &"pilot_004_power_conversion"]})
	if player_mech.max_power != max_before:
		return "清除后动力上限应恢复 实=%d（应=%d）" % [player_mech.max_power, max_before]
	if player_mech.get_armor() != armor_before:
		return "清除后护甲应恢复 实=%d（应=%d）" % [player_mech.get_armor(), armor_before]
	# POWER_CAP_MODIFIER 状态清除
	for s in player_mech.statuses:
		if String(s.get("type", &"")) == "POWER_CAP_MODIFIER":
			return "清除后应无 POWER_CAP_MODIFIER 状态"
	return true


## 测试10：pilot_004 effect_03--SET_ATTACK_DEFENSE_STAT_SOURCE 写 attack record override
func test_pilot_004_effect_03_defense_override() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_004_玛沙", &"player")
	if card == null:
		return "找不到 pilot_004_玛沙"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var ga = battle.context.game_actions
	# mock attack action（target=enemy）
	var mock_attack = _Action.new()
	mock_attack.record = {"target_id": enemy_mech.mech_id}
	ga.set_attack_defense_stat_source({"target_id": enemy_mech.mech_id, "stat_source": &"current_power"}, {"target_id": enemy_mech.mech_id}, mock_attack)
	var override: Dictionary = mock_attack.record.get("defense_stat_override", {})
	if String(override.get(enemy_mech.mech_id, &"")) != "current_power":
		return "defense_stat_override[target] 应=current_power 实=%s" % String(override.get(enemy_mech.mech_id, &""))
	# 验证 pilot_004 effect_03a/03b 注册到 ATTACK_PRE
	var te = battle.context.timing_engine
	var listeners: Array = te.permanent_listeners.get(_TimingConst.ATTACK_PRE, [])
	var found_03a := false
	var found_03b := false
	for entry in listeners:
		var eff = entry.get("effect")
		if eff != null and String(eff.effect_id) == "pilot_004_effect_03a":
			found_03a = true
		if eff != null and String(eff.effect_id) == "pilot_004_effect_03b":
			found_03b = true
	if not found_03a or not found_03b:
		return "pilot_004 effect_03a/03b 应注册到 ATTACK_PRE（a=%s b=%s）" % [str(found_03a), str(found_03b)]
	return true


## 测试11：pilot_005 effect_02 派生值--帝国机甲动力+4（阵营光环，实时重算）
func test_pilot_005_empire_aura_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var max_before: int = player_mech.max_power
	var card = _make_pilot_instance(gs, cdb, "pilot_005_肯特", &"player")
	if card == null:
		return "找不到 pilot_005_肯特"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# pilot_005 帝国光环：player_mech pilot 是帝国（肯特），动力+4
	if _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech) != 4:
		return "帝国光环动力应+4 实=%d" % _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech)
	if player_mech.max_power != max_before + 4:
		return "max_power 应+4（recalc）实=%d（before=%d）" % [player_mech.max_power, max_before]
	# 非帝国机甲（enemy 无机师或非帝国）不应获得
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech != null:
		# enemy 没 set_pilot，pilot 槽空，faction 空，bonus=0
		if _ActionPilotEffects.get_pilot_005_empire_power_bonus(enemy_mech) != 0:
			return "非帝国机甲不应获得光环"
	# unset 后光环消失
	battle.context.game_setup_service.unset_pilot(player_mech.mech_id)
	if _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech) != 0:
		return "unset 后光环应消失"
	return true


## 测试12：pilot_005 effect_03--toggle 切换光环（取消/恢复）
func test_pilot_005_effect_03_toggle() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_005_肯特", &"player")
	if card == null:
		return "找不到 pilot_005_肯特"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 初始光环 +4
	if _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech) != 4:
		return "初始光环应+4 实=%d" % _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech)
	# toggle off
	_ActionPilotEffects.toggle_aura_target(card.instance_id, player_mech.mech_id)
	if _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech) != 0:
		return "toggle off 后光环应消失 实=%d" % _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech)
	# toggle on（恢复）
	_ActionPilotEffects.toggle_aura_target(card.instance_id, player_mech.mech_id)
	if _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech) != 4:
		return "toggle on 后光环应恢复 实=%d" % _ActionPilotEffects.get_pilot_005_empire_power_bonus(player_mech)
	return true


## 测试13：pilot_005 effect_01 授予--帝国机甲注册 granted ATTACK_PRE + 弃对侧2牌
func test_pilot_005_effect_01_grant_and_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_005_肯特", &"player")
	if card == null:
		return "找不到 pilot_005_肯特"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 1. granted listener 注册到 ATTACK_PRE（mech_id=player_mech，帝国）
	var te = battle.context.timing_engine
	var listeners: Array = te.permanent_listeners.get(_TimingConst.ATTACK_PRE, [])
	var found_granted := false
	for entry in listeners:
		var eff = entry.get("effect")
		if eff != null and String(eff.effect_id) == "pilot_005_granted_suppression":
			var bc: Dictionary = entry.get("binding_context", {})
			if String(bc.get("mech_id", &"")) == String(player_mech.mech_id):
				found_granted = true
				break
	if not found_granted:
		return "pilot_005_granted_suppression 应注册到 ATTACK_PRE（mech_id=player_mech）"
	# 2. 弃对侧2牌（player 攻击 enemy -> 弃 enemy 2张）
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	# 给 enemy 补行动牌确保有2张可弃
	while enemy_player.action_hand.size() < 2 and gs.deck_state.action_deck.size() > 0:
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		enemy_player.action_hand.append(cid)
	var hand_before: int = enemy_player.action_hand.size()
	if hand_before < 2:
		return "enemy 行动手牌不足2张，无法测弃牌"
	var mock_attack = _Action.new()
	mock_attack.record = {}
	var payload: Dictionary = {"binding_context": {"mech_id": player_mech.mech_id}, "attacker_id": player_mech.mech_id, "target_id": enemy_mech.mech_id}
	battle.context.game_actions.pilot_005_discard_opposing({}, payload, mock_attack)
	if enemy_player.action_hand.size() != hand_before - 2:
		return "应弃 enemy 2张 实减=%d" % (hand_before - enemy_player.action_hand.size())
	# 3. unset_pilot 后 granted listener 注销
	battle.context.game_setup_service.unset_pilot(player_mech.mech_id)
	listeners = te.permanent_listeners.get(_TimingConst.ATTACK_PRE, [])
	for entry in listeners:
		var eff = entry.get("effect")
		if eff != null and String(eff.effect_id) == "pilot_005_granted_suppression":
			var bc: Dictionary = entry.get("binding_context", {})
			if String(bc.get("card_instance_id", &"")) == String(card.instance_id):
				return "unset_pilot 后 granted listener 应注销"
	return true


## 测试14：pilot_002 effect_02 派生值（联邦护甲+4）+ effect_03 toggle + effect_03 注册
func test_pilot_002_federation_aura_and_toggle() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return "找不到 pilot_002_莱比尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 联邦光环护甲+4
	if _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech) != 4:
		return "联邦光环护甲应+4 实=%d" % _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech)
	# toggle off
	_ActionPilotEffects.toggle_aura_target(card.instance_id, player_mech.mech_id)
	if _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech) != 0:
		return "toggle off 后护甲光环应消失 实=%d" % _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech)
	# toggle on
	_ActionPilotEffects.toggle_aura_target(card.instance_id, player_mech.mech_id)
	if _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech) != 4:
		return "toggle on 后护甲光环应恢复 实=%d" % _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech)
	# effect_03 注册（DIRECT 虚拟时点 pilot_002_effect_03）
	var te = battle.context.timing_engine
	var found_e3 := false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			var eff = entry.get("effect")
			if eff != null and String(eff.effect_id) == "pilot_002_effect_03":
				found_e3 = true
				break
		if found_e3:
			break
	if not found_e3:
		return "pilot_002 effect_03 应注册（DIRECT 虚拟时点）"
	return true


## 测试15：pilot_008 回收维修 + X 变量（绑 card_instance_id, max5）
func test_pilot_008_recover_repair_and_x() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_008_安德洛美达", &"player")
	if card == null:
		return "找不到 pilot_008_安德洛美达"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	var ga = battle.context.game_actions
	var payload: Dictionary = {"binding_context": {"player_id": &"player", "card_instance_id": card.instance_id}}
	# 给弃牌堆加一张维修
	var repair = _make_pilot_instance(gs, cdb, "action_013_维修", &"player")
	if repair == null:
		return "找不到 action_013_维修"
	repair.zone = &"discard"
	gs.deck_state.action_discard_pile.append(repair.instance_id)
	var hand_before: int = player.action_hand.size()
	ga.pilot_008_recover_repair({}, payload)
	if player.action_hand.size() != hand_before + 1:
		return "应回收1张维修到手牌 实增=%d" % (player.action_hand.size() - hand_before)
	if not player.action_hand.has(repair.instance_id):
		return "维修应在手牌"
	if _ActionPilotEffects.get_pilot_008_x(card) != 1:
		return "X 应=1 实=%d" % _ActionPilotEffects.get_pilot_008_x(card)
	# X max5：再回收4次
	for i in 4:
		var r = _make_pilot_instance(gs, cdb, "action_013_维修", &"player")
		r.zone = &"discard"
		gs.deck_state.action_discard_pile.append(r.instance_id)
		ga.pilot_008_recover_repair({}, payload)
	if _ActionPilotEffects.get_pilot_008_x(card) != 5:
		return "X 应=5(max) 实=%d" % _ActionPilotEffects.get_pilot_008_x(card)
	# 再回收 X 保持5
	var r6 = _make_pilot_instance(gs, cdb, "action_013_维修", &"player")
	r6.zone = &"discard"
	gs.deck_state.action_discard_pile.append(r6.instance_id)
	ga.pilot_008_recover_repair({}, payload)
	if _ActionPilotEffects.get_pilot_008_x(card) != 5:
		return "X 应保持5 实=%d" % _ActionPilotEffects.get_pilot_008_x(card)
	return true


## 测试16：pilot_006 悬赏标记 + 抽牌挂 passive_attack_bonus 标记
func test_pilot_006_bounty_and_tag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_pilot_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 标记悬赏目标
	_ActionPilotEffects.set_pilot_006_mark(card.instance_id, enemy_mech.mech_id, 0)
	if _ActionPilotEffects.get_pilot_006_mark(card.instance_id) != enemy_mech.mech_id:
		return "悬赏标记应=enemy_mech"
	# DRAW_ACTION_AND_TAG_IF_ATTACK：攻击方抽1
	var player = gs.players.get(&"player")
	var hand_before: int = player.action_hand.size()
	var ga = battle.context.game_actions
	ga.draw_action_and_tag_if_attack({}, {"attacker_id": player_mech.mech_id, "binding_context": {"card_instance_id": card.instance_id}})
	if player.action_hand.size() != hand_before + 1:
		return "应抽1张 实增=%d" % (player.action_hand.size() - hand_before)
	# 抽到的牌若攻击牌应挂 passive_attack_bonus
	var drawn_cid: StringName = player.action_hand[-1]
	var drawn_card = gs.get_card(drawn_cid)
	if drawn_card != null and drawn_card.def != null and String(drawn_card.def.action_type) == "攻击":
		if not bool(drawn_card.counters.get("passive_attack_bonus", false)):
			return "抽到攻击牌应挂 passive_attack_bonus 标记"
	# clear mark
	_ActionPilotEffects.clear_pilot_006_mark(card.instance_id)
	if _ActionPilotEffects.get_pilot_006_mark(card.instance_id) != &"":
		return "clear 后悬赏标记应空"
	return true


## 测试17：pilot_007 反夺攻击牌（CLAIM_RESOLVED_ATTACK_SOURCE_CARD 改归属 + claimed 标记）
func test_pilot_007_claim_attack_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_007_珀修斯", &"player")
	if card == null:
		return "找不到 pilot_007_珀修斯"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	# 建一张攻击牌作为 attack_card_id（模拟攻击来源牌，在 temp_zone）
	var attack_card = _make_pilot_instance(gs, cdb, "action_001_进攻", &"enemy")
	if attack_card == null:
		return "找不到 action_001_进攻"
	attack_card.zone = &"temp_zone"
	var hand_before: int = player.action_hand.size()
	var ga = battle.context.game_actions
	ga.claim_resolved_attack_source_card({}, {"binding_context": {"player_id": &"player"}, "attack_card_id": attack_card.instance_id})
	if player.action_hand.size() != hand_before + 1:
		return "应夺1张到手牌 实增=%d" % (player.action_hand.size() - hand_before)
	if not player.action_hand.has(attack_card.instance_id):
		return "攻击牌应在 player 手牌"
	if String(attack_card.owner_player_id) != "player":
		return "攻击牌归属应=player"
	if not bool(attack_card.counters.get("claimed_by_pilot_007", false)):
		return "应有 claimed_by_pilot_007 标记"
	return true


## 测试18：pilot_009 临时卡牌控制（GRANT_TEMP_CARD_CONTROL + 非排他 + 换下即解）
func test_pilot_009_temp_card_control() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_pilot_instance(gs, cdb, "pilot_009_美杜莎", &"player")
	if card == null:
		return "找不到 pilot_009_美杜莎"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# player 控制目标 enemy 的攻击牌
	ga.grant_temp_card_control({"card_type": &"攻击"}, {"binding_context": {"player_id": &"player", "card_instance_id": card.instance_id}, "target_id": enemy_mech.mech_id})
	if not _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "player 应控制 enemy 的攻击牌"
	# 非排他：enemy 也可控制（双方各自 grant）
	ga.grant_temp_card_control({"card_type": &"攻击"}, {"binding_context": {"player_id": &"enemy", "card_instance_id": card.instance_id}, "target_id": enemy_mech.mech_id})
	if not _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"enemy"):
		return "enemy 也应能控制（非排他）"
	# 换下即解：clear source
	_ActionPilotEffects.clear_pilot_009_control_for_source(card.instance_id)
	if _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "换下后 player 控制应解除"
	if _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"enemy"):
		return "换下后 enemy 控制应解除"
	return true


## 测试19：pilot_009 使用受控牌--use_action_card validate 支持 controller
## 美杜莎用目标受控攻击牌：未 grant 拒绝；grant 后通过（mech_id=美杜莎 executor）
func test_pilot_009_use_controlled_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	var card = _make_pilot_instance(gs, cdb, "pilot_009_美杜莎", &"player")
	if card == null:
		return "找不到 pilot_009_美杜莎"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# 给 enemy 一张攻击牌
	var enemy_attack = _make_pilot_instance(gs, cdb, "action_001_进攻", &"enemy")
	if enemy_attack == null:
		return "找不到 action_001_进攻"
	enemy_player.action_hand.append(enemy_attack.instance_id)
	# 无权使用：未 grant，美杜莎用 enemy 攻击牌应拒
	var act1 = _UseActionCardAction.new()
	act1.context = battle.context
	act1.record = {"card_instance_id": enemy_attack.instance_id, "player_id": &"player", "mech_id": player_mech.mech_id}
	act1.source = {}
	var r1 = act1._step_validate_card(act1)
	if not r1.has("error"):
		return "未 grant 控制时应拒绝受控使用"
	# grant 攻击控制
	ga.grant_temp_card_control({"card_type": &"攻击"}, {"binding_context": {"player_id": &"player", "card_instance_id": card.instance_id}, "target_id": enemy_mech.mech_id})
	# 受控使用：validate 应通过
	var act2 = _UseActionCardAction.new()
	act2.context = battle.context
	act2.record = {"card_instance_id": enemy_attack.instance_id, "player_id": &"player", "mech_id": player_mech.mech_id}
	act2.source = {}
	var r2 = act2._step_validate_card(act2)
	if r2.has("error"):
		_ActionPilotEffects.clear_pilot_009_control_for_source(card.instance_id)
		return "grant 后受控使用应通过 validate，实=%s" % String(r2["error"])
	# mech_id 应=美杜莎（executor），非目标
	if String(r2.get("mech_id", &"")) != String(player_mech.mech_id):
		_ActionPilotEffects.clear_pilot_009_control_for_source(card.instance_id)
		return "受控使用 mech_id 应=美杜莎 实=%s" % String(r2.get("mech_id", &""))
	_ActionPilotEffects.clear_pilot_009_control_for_source(card.instance_id)
	return true


## 测试20：pilot_009 立即弃置全弃--PILOT_009_DISCARD_ALL_CONTROLLED_TYPE
## 控制建立后立即弃置目标当前全部该类型牌；持续光环保留（控制仍 active）
func test_pilot_009_immediate_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	var card = _make_pilot_instance(gs, cdb, "pilot_009_美杜莎", &"player")
	if card == null:
		return "找不到 pilot_009_美杜莎"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# grant 攻击控制
	ga.grant_temp_card_control({"card_type": &"攻击"}, {"binding_context": {"player_id": &"player", "card_instance_id": card.instance_id}, "target_id": enemy_mech.mech_id})
	# 清空 enemy 手牌后给 3 张攻击牌
	enemy_player.action_hand.clear()
	var atks: Array = []
	for i in 3:
		var a = _make_pilot_instance(gs, cdb, "action_001_进攻", &"enemy")
		if a == null:
			return "找不到 action_001_进攻"
		enemy_player.action_hand.append(a.instance_id)
		atks.append(a)
	# 立即弃置全弃
	ga.pilot_009_discard_all_controlled_type({"card_type": &"攻击"}, {"target_id": enemy_mech.mech_id})
	# 3 张攻击牌应全部进弃牌堆
	for a in atks:
		if enemy_player.action_hand.has(a.instance_id):
			return "攻击牌 %s 应被弃置" % String(a.instance_id)
		if not gs.deck_state.action_discard_pile.has(a.instance_id):
			return "攻击牌 %s 应在弃牌堆" % String(a.instance_id)
	# 控制仍保留（持续光环，立即弃置不清控制）
	if not _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "立即弃置后控制应保留（持续光环）"
	_ActionPilotEffects.clear_pilot_009_control_for_source(card.instance_id)
	return true


## 测试21：pilot_007 类型破绽--PILOT_007_TYPE_FLAW 算X弃抽
## 场景A：enemy 3张攻击牌（present={攻击}，X=2，弃3抽3）
## 场景B：enemy 2攻击+1迎击（present={攻击,迎击}，X=1，弃2抽2）
func test_pilot_007_type_flaw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_007_珀修斯", &"player")
	if card == null:
		return "找不到 pilot_007_珀修斯"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# 场景A：enemy 3张攻击 -> X=2 弃3抽3
	enemy_player.action_hand.clear()
	for i in 3:
		var a = _make_pilot_instance(gs, cdb, "action_001_进攻", &"enemy")
		if a == null:
			return "找不到 action_001_进攻"
		enemy_player.action_hand.append(a.instance_id)
	var p_hand_a: int = player.action_hand.size()
	ga.pilot_007_type_flaw({}, {"attacker_id": player_mech.mech_id, "target_id": enemy_mech.mech_id})
	if enemy_player.action_hand.size() != 0:
		return "场景A enemy 应全弃3张 实剩=%d" % enemy_player.action_hand.size()
	if player.action_hand.size() != p_hand_a + 3:
		return "场景A player 应抽3 实增=%d" % (player.action_hand.size() - p_hand_a)
	# 场景B：enemy 2攻击+1迎击 -> X=1 弃2抽2（剩1张）
	enemy_player.action_hand.clear()
	for i in 2:
		var a = _make_pilot_instance(gs, cdb, "action_001_进攻", &"enemy")
		enemy_player.action_hand.append(a.instance_id)
	var evade = _make_pilot_instance(gs, cdb, "action_008_回避", &"enemy")
	if evade == null:
		return "找不到 action_008_回避"
	enemy_player.action_hand.append(evade.instance_id)
	var p_hand_b: int = player.action_hand.size()
	ga.pilot_007_type_flaw({}, {"attacker_id": player_mech.mech_id, "target_id": enemy_mech.mech_id})
	if enemy_player.action_hand.size() != 1:
		return "场景B enemy 应剩1张(弃2) 实剩=%d" % enemy_player.action_hand.size()
	if player.action_hand.size() != p_hand_b + 2:
		return "场景B player 应抽2 实增=%d" % (player.action_hand.size() - p_hand_b)
	return true


## 测试22：pilot_006 战后逼迫回落4伤害--_pilot_006_fallback_damage 直接调
func test_pilot_006_fallback_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_pilot_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var hp_before: int = enemy_mech.current_hp
	var mock_action = _Action.new()
	mock_action.action_id = &"test_p006_fallback"
	mock_action.record = {}
	battle.context.timing_engine._pilot_006_fallback_damage(enemy_mech.mech_id, mock_action)
	if enemy_mech.current_hp != hp_before - 4:
		return "回落应造成4伤害 实HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	return true


## 测试23：pilot_006 战后逼迫--无攻击牌时回落4伤害（被选机甲=player 人类）
func test_pilot_006_force_use_no_card_fallback() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	player.action_hand.clear()
	var hp_before: int = player_mech.current_hp
	var mock_action = _Action.new()
	mock_action.action_id = &"test_p006_nocard"
	mock_action.record = {}
	var effects = _ActionPilotEffects.build_pilot_effects()
	var p006e3 = effects.get(&"pilot_006_effect_03")
	var act_def: Dictionary = {"type": &"PILOT_006_FORCE_USE_ATTACK", "params": {"target_mech_id": String(player_mech.mech_id)}}
	var payload: Dictionary = {"target_id": player_mech.mech_id}
	var paused: bool = battle.context.timing_engine._handle_pilot_006_force_use_attack(act_def, p006e3, payload, mock_action)
	if paused:
		return "无攻击牌应不挂起（回落4伤害）"
	if player_mech.current_hp != hp_before - 4:
		return "无攻击牌应回落4伤害 实HP=%d（before=%d）" % [player_mech.current_hp, hp_before]
	return true


## 测试24：pilot_006 战后逼迫--有攻击牌时挂起弹窗（被选机甲=player 人类）
func test_pilot_006_force_use_with_card_suspend() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	player.action_hand.clear()
	var atk = _make_pilot_instance(gs, cdb, "action_001_进攻", &"player")
	if atk == null:
		return "找不到 action_001_进攻"
	player.action_hand.append(atk.instance_id)
	var mock_action = _Action.new()
	mock_action.action_id = &"test_p006_withcard"
	mock_action.record = {}
	var effects = _ActionPilotEffects.build_pilot_effects()
	var p006e3 = effects.get(&"pilot_006_effect_03")
	var act_def: Dictionary = {"type": &"PILOT_006_FORCE_USE_ATTACK", "params": {"target_mech_id": String(player_mech.mech_id)}}
	var payload: Dictionary = {"target_id": player_mech.mech_id}
	var paused: bool = battle.context.timing_engine._handle_pilot_006_force_use_attack(act_def, p006e3, payload, mock_action)
	if not paused:
		return "有攻击牌应挂起弹窗"
	if mock_action.state != &"waiting_timing":
		return "应设 waiting_timing 实=%s" % String(mock_action.state)
	var te = battle.context.timing_engine
	if not te._pending_effect.has(mock_action.action_id):
		return "_pending_effect 应有记录"
	return true


## 测试25：pilot_002 授予机制 + GRANT_TRANSFER_BATCH_AS_NAMED_TYPE 权限登记
## 莱比尔 set_pilot 后向联邦机师授予 DIRECT 进攻 + AVAILABILITY 防御 listener；
## GRANT_TRANSFER_BATCH_AS_NAMED_TYPE 登记批次权限到 ActionPilotEffects._pilot_002_batches。
func test_pilot_002_grant_and_batch_register() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_pilot_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return "找不到 pilot_002_莱比尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 1. granted DIRECT 进攻 listener 注册到虚拟时点 pilot_002_granted_transfer_attack
	var te = battle.context.timing_engine
	var found_attack := false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			var eff = entry.get("effect")
			if eff != null and String(eff.effect_id) == "pilot_002_granted_transfer_attack":
				var bc: Dictionary = entry.get("binding_context", {})
				if String(bc.get("mech_id", &"")) == String(player_mech.mech_id) and String(bc.get("card_instance_id", &"")) == String(card.instance_id):
					found_attack = true
					break
		if found_attack:
			break
	if not found_attack:
		return "pilot_002_granted_transfer_attack 应注册到联邦机甲 player_mech"
	# 2. unset_pilot 后 granted listener 注销 + 批次权限清除
	battle.context.game_setup_service.unset_pilot(player_mech.mech_id)
	for timing2: StringName in te.permanent_listeners:
		for entry2 in te.permanent_listeners[timing2]:
			var eff2 = entry2.get("effect")
			if eff2 != null and String(eff2.effect_id) == "pilot_002_granted_transfer_attack":
				var bc2: Dictionary = entry2.get("binding_context", {})
				if String(bc2.get("card_instance_id", &"")) == String(card.instance_id):
					return "unset_pilot 后 granted listener 应注销"
	# 3. GRANT_TRANSFER_BATCH_AS_NAMED_TYPE atomic 登记批次权限
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 建两张行动牌作为批次
	var b1 = _make_pilot_instance(gs, cdb, "action_001_进攻", &"player")
	var b2 = _make_pilot_instance(gs, cdb, "action_001_进攻", &"player")
	if b1 == null or b2 == null:
		return "找不到 action_001_进攻"
	var batch_ids: Array = [b1.instance_id, b2.instance_id]
	var ga = battle.context.game_actions
	var payload: Dictionary = {"binding_context": {"card_instance_id": card.instance_id}, "target_id": enemy_mech.mech_id, "action_id": &"test_p002_action"}
	ga.pilot_002_grant_transfer_batch({"target_mech_id": enemy_mech.mech_id, "batch_card_ids": batch_ids, "named_type": &"进攻"}, payload)
	# 批次权限应登记到 _pilot_002_batches
	var found_batch := false
	for bid in _ActionPilotEffects._pilot_002_batches:
		var b: Dictionary = _ActionPilotEffects._pilot_002_batches[bid]
		if String(b.get("target_mech", &"")) == String(enemy_mech.mech_id) and String(b.get("named_type", &"")) == "进攻" and int(b.get("card_ids", []).size()) == 2:
			found_batch = true
			# 批次牌应标记 pilot_002_batch
			var c1 = gs.get_card(b1.instance_id)
			if c1 == null or String(c1.counters.get("pilot_002_batch", &"")) == &"":
				return "批次牌应标记 pilot_002_batch"
			break
	if not found_batch:
		return "GRANT_TRANSFER_BATCH_AS_NAMED_TYPE 应登记批次权限到 _pilot_002_batches"
	# 4. 莱比尔离场清除批次权限
	_ActionPilotEffects.clear_pilot_002_batches_for_source(card.instance_id)
	if _ActionPilotEffects._pilot_002_batches.size() > 0:
		return "莱比尔离场后批次权限应清除"
	return true


## 测试26：pilot_002 批次使用机制--登记批次 + 注册使用 listener + discard_batch 丢弃+保留虚拟牌
func test_pilot_002_batch_use_mechanism() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	var card = _make_pilot_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return "找不到 pilot_002_莱比尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# 给 enemy 3张行动牌（批次牌）
	enemy_player.action_hand.clear()
	var batch_cards: Array = []
	for i in 3:
		var c = _make_pilot_instance(gs, cdb, "action_001_进攻", &"enemy")
		if c == null:
			return "找不到 action_001_进攻"
		enemy_player.action_hand.append(c.instance_id)
		batch_cards.append(c.instance_id)
	# 登记批次（target=enemy, named_type=进攻）
	var payload: Dictionary = {"binding_context": {"card_instance_id": card.instance_id}, "target_id": enemy_mech.mech_id, "action_id": &"test_p002_bu"}
	ga.pilot_002_grant_transfer_batch({"target_mech_id": enemy_mech.mech_id, "batch_card_ids": batch_cards, "named_type": &"进攻"}, payload)
	# 1. 批次使用 listener 注册到 enemy_mech（含 batch_id）
	var te = battle.context.timing_engine
	var found_bu := false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			var eff = entry.get("effect")
			if eff != null and String(eff.effect_id) == "pilot_002_batch_use_attack":
				var bc: Dictionary = entry.get("binding_context", {})
				if String(bc.get("mech_id", &"")) == String(enemy_mech.mech_id) and bc.has("batch_id"):
					found_bu = true
					break
		if found_bu:
			break
	if not found_bu:
		return "pilot_002_batch_use_attack 应注册到 enemy_mech（含 batch_id）"
	# 2. pilot_002_discard_batch 丢弃批次（保留首张作虚拟牌）
	var batch_id: String = ""
	for bid in _ActionPilotEffects._pilot_002_batches:
		batch_id = bid
		break
	var virtual_cid: StringName = ga.pilot_002_discard_batch({}, {"binding_context": {"batch_id": batch_id}})
	if String(virtual_cid) != String(batch_cards[0]):
		return "应保留首张作虚拟牌 实=%s 期望=%s" % [String(virtual_cid), String(batch_cards[0])]
	# 虚拟牌仍在 enemy 手牌，其余2张进弃牌堆
	if not enemy_player.action_hand.has(virtual_cid):
		return "虚拟牌应在 enemy 手牌"
	if enemy_player.action_hand.size() != 1:
		return "enemy 手牌应剩1张(虚拟) 实=%d" % enemy_player.action_hand.size()
	# 3. 批次标记已用
	var batch: Dictionary = _ActionPilotEffects.get_pilot_002_batch(batch_id)
	if not bool(batch.get("used", false)):
		return "批次应标记已用"
	_ActionPilotEffects.clear_pilot_002_batches_for_source(card.instance_id)
	return true


## 测试27：pilot_003 公开埋牌 + 跳过正面牌
## effect_01 插入正面牌到牌堆；effect_03 skip 开启后抽牌跳过正面牌且+1
func test_pilot_003_insert_and_skip() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_003_瑟尔基尔", &"player")
	if card == null:
		return "找不到 pilot_003_瑟尔基尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# 1. 插入1张正面牌
	var insert_card = _make_pilot_instance(gs, cdb, "action_001_进攻", &"player")
	if insert_card == null:
		return "找不到 action_001_进攻"
	player.action_hand.append(insert_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": card.instance_id, "mech_id": player_mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [insert_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [insert_card.instance_id]}, payload)
	if not gs.deck_state.action_deck.has(insert_card.instance_id):
		return "正面牌应在行动牌堆"
	var c = gs.get_card(insert_card.instance_id)
	if c == null or not bool(c.counters.get("face_up_in_deck", false)):
		return "牌应标记 face_up_in_deck"
	# 2. effect_03 skip 开启
	ga.toggle_pilot_003_skip({"enable": true}, {"binding_context": {"card_instance_id": card.instance_id, "player_id": &"player"}})
	if not _ActionPilotEffects.is_pilot_003_skip_active(&"player"):
		return "skip 应开启"
	# 3. 抽牌（count=1，skip+1=2，跳过正面牌）
	# 确保牌堆有背面牌（tutorial 初始牌堆应足够）
	if gs.deck_state.action_deck.size() < 3:
		return "牌堆不足测试"
	var hand_before: int = player.action_hand.size()
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003"})
	# 正面牌应仍在牌堆（被跳过）
	if not gs.deck_state.action_deck.has(insert_card.instance_id):
		return "正面牌应仍在牌堆（被跳过）"
	# 应抽2张（1+1）
	if player.action_hand.size() != hand_before + 2:
		return "应抽2张(1+1skip) 实增=%d" % (player.action_hand.size() - hand_before)
	# 4. unset 后 skip 清除
	_ActionPilotEffects.clear_pilot_003_skip_for_source(card.instance_id)
	if _ActionPilotEffects.is_pilot_003_skip_active(&"player"):
		return "清除后 skip 应关闭"
	return true


## 测试28：开局机师选择流程--generate_random_pilot_selection + select_pilot_with_cost
func test_pilot_selection_with_cost() -> Variant:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		return "registry 加载失败"
	var cs := _CampaignState.new()
	cs.initialize(registry)
	# 1. generate_random_pilot_selection(3)
	var selection: Array = cs.generate_random_pilot_selection(3)
	if selection.size() != 3:
		return "应返回3张机师 实=%d" % selection.size()
	# 2. select_pilot_with_cost
	var first_pilot_id: String = String(selection[0].get("id", ""))
	var cost: int = int(selection[0].get("cost", 0))
	var gold_before: int = cs.available_gold
	var result: Dictionary = cs.select_pilot_with_cost(first_pilot_id)
	if not result.get("ok", false):
		return "选择机师应成功 实=%s" % String(result.get("message", ""))
	if cs.available_gold != gold_before - cost:
		return "金币应扣%d 实=%d（before=%d）" % [cost, cs.available_gold, gold_before]
	if String(cs.selected_pilot.get("id", "")) != first_pilot_id:
		return "selected_pilot 应=选择的机师"
	# 3. 金币不足时拒绝
	cs.available_gold = 0
	var result2: Dictionary = cs.select_pilot_with_cost(first_pilot_id)
	if result2.get("ok", false):
		return "金币不足时应拒绝"
	return true


## 测试29：dev 换机师 + 修改数值（change_pilot 走 set_pilot/unset_pilot + modify_player_limits）
func test_dev_change_pilot_and_limits() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var dev := _DevModeService.new()
	dev.context = battle.context
	# 1. change_pilot 到 pilot_010 刻托
	var result: Dictionary = dev.change_pilot(&"player", &"pilot_010_刻托")
	if not result.get("ok", false):
		return "change_pilot 应成功 实=%s" % String(result.get("message", ""))
	if player.attack_limit != 3 or player_mech.max_attacks_per_turn != 3:
		return "刻托 attack_limit/max_attacks 应=3 实=%d/%d" % [player.attack_limit, player_mech.max_attacks_per_turn]
	# 2. change_pilot 到 pilot_002 莱比尔（换机师）
	var result2: Dictionary = dev.change_pilot(&"player", &"pilot_002_莱比尔")
	if not result2.get("ok", false):
		return "换机师应成功"
	if player.action_card_limit != 4:
		return "莱比尔 action_card_limit 应=4 实=%d" % player.action_card_limit
	# 3. modify_player_limits
	var result3: Dictionary = dev.modify_player_limits(&"player", 2, 3, 10)
	if not result3.get("ok", false):
		return "modify_player_limits 应成功"
	if player.attack_limit != 2 or player.action_card_limit != 3 or player.gold != 10:
		return "修改后 attack/action/gold 应=2/3/10 实=%d/%d/%d" % [player.attack_limit, player.action_card_limit, player.gold]
	if player_mech.max_attacks_per_turn != 2:
		return "max_attacks_per_turn 应=2 实=%d" % player_mech.max_attacks_per_turn
	return true


## 测试30：pilot_003 effect_02 离堆拦截（不可用防御牌）→ 公开弃置 + 瑟尔基尔拥有者抽1
## 拆解场景c：正面"防御"在无攻击响应窗口时被抽。断言：防御不创建响应、牌公开进弃牌堆、
## P1额外抽1、正面/metadata清除、原抽牌者仍补足抽数。
func test_pilot_003_effect02_unusable_fallback() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return "enemy 玩家不存在"
	var card = _make_pilot_instance(gs, cdb, "pilot_003_瑟尔基尔", &"player")
	if card == null:
		return "找不到 pilot_003_瑟尔基尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# 1. 插入1张正面"防御"（含 AVAILABILITY → 离堆时不可主动使用）
	var face_card = _make_pilot_instance(gs, cdb, "action_009_防御", &"player")
	if face_card == null:
		return "找不到 action_009_防御"
	player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": card.instance_id, "mech_id": player_mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	if not gs.deck_state.action_deck.has(face_card.instance_id) or gs.deck_state.action_deck[0] != face_card.instance_id:
		return "正面牌应位于牌堆顶"
	# 2. enemy 抽1 → 离堆拦截
	var enemy_hand_before: int = enemy.action_hand.size()
	var p1_hand_before: int = player.action_hand.size()
	ga.draw_action_cards({"player_id": &"enemy", "count": 1, "reason": &"test_p003e2"})
	var face_c = gs.get_card(face_card.instance_id)
	# 3. 断言
	# 正面牌未进 enemy 手牌
	if enemy.action_hand.has(face_card.instance_id):
		return "正面牌不应进入 enemy 手牌"
	# 正面牌已离开行动牌堆
	if gs.deck_state.action_deck.has(face_card.instance_id):
		return "正面牌应已离开行动牌堆"
	# 正面/metadata 清除
	if face_c != null and (bool(face_c.counters.get("face_up_in_deck", false)) or bool(face_c.counters.get("pilot_003_face_up_leave_use", false))):
		return "正面/metadata 标记应清除"
	# 牌应进入行动弃牌堆（弃置动作同步完成；若在临时区说明弃置链挂起）
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id) and (face_c == null or face_c.zone != &"discard"):
		return "正面牌应公开进入弃牌堆（zone=%s）" % (String(face_c.zone) if face_c else "null")
	# P1 应抽1补偿（不可用回退）
	if player.action_hand.size() != p1_hand_before + 1:
		return "P1 应抽1补偿 实增=%d" % (player.action_hand.size() - p1_hand_before)
	# enemy 应仍补足抽数（拦截牌不计入已抽数量）
	if enemy.action_hand.size() != enemy_hand_before + 1:
		return "enemy 应仍抽到1张背面牌 实增=%d" % (enemy.action_hand.size() - enemy_hand_before)
	return true


## 测试31：pilot_003 effect_02 离堆拦截（可用攻击牌）→ 瑟尔基尔拥有者立即使用（passive 攻击）
## 拆解场景b：正面"进攻"被 enemy 抽走，P1 有合法武器与目标。断言：牌不进入 enemy 手牌、
## 存在强制使用 use_action_card 动作（暂停等武器选择）、passive 不消耗攻击数、原抽牌者补足抽数。
func test_pilot_003_effect02_usable_attack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	if enemy_mech == null or enemy == null:
		return "enemy 不存在"
	# 拉近距离：player(2,2)，enemy 移近到(4,2) 距离2，基础武器光束手枪 range4 可命中
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_pilot_instance(gs, cdb, "pilot_003_瑟尔基尔", &"player")
	if card == null:
		return "找不到 pilot_003_瑟尔基尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var ga = battle.context.game_actions
	# 1. 插入1张正面"进攻"（纯 DIRECT → 可主动使用）
	var face_card = _make_pilot_instance(gs, cdb, "action_001_进攻", &"player")
	if face_card == null:
		return "找不到 action_001_进攻"
	player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": card.instance_id, "mech_id": player_mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	# 2. enemy 抽1 → 离堆拦截 → P1 强制使用（attack 暂停在 select_weapon）
	var enemy_hand_before: int = enemy.action_hand.size()
	var attack_count_before: int = player_mech.attack_count_this_turn
	ga.draw_action_cards({"player_id": &"enemy", "count": 1, "reason": &"test_p003e2"})
	# 3. 断言
	if enemy.action_hand.has(face_card.instance_id):
		return "正面牌不应进入 enemy 手牌"
	# 强制使用 use_action_card 动作应存在于 registry（暂停等武器/目标选择）
	var forced_use_found := false
	for ua in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if ua.record.get("card_instance_id", &"") == face_card.instance_id:
			forced_use_found = true
			break
	if not forced_use_found:
		return "应存在强制使用 use_action_card 动作（card=%s）" % String(face_card.instance_id)
	# passive 攻击不消耗攻击数
	if player_mech.attack_count_this_turn != attack_count_before:
		return "强制使用攻击牌不应消耗攻击数 实=%d" % player_mech.attack_count_this_turn
	# 正面/metadata 清除（立即使用路径）
	var face_c = gs.get_card(face_card.instance_id)
	if face_c == null or bool(face_c.counters.get("face_up_in_deck", false)):
		return "正面标记应清除（强制使用路径）"
	# enemy 应仍补足抽数
	if enemy.action_hand.size() != enemy_hand_before + 1:
		return "enemy 应仍抽到1张背面牌 实增=%d" % (enemy.action_hand.size() - enemy_hand_before)
	return true
