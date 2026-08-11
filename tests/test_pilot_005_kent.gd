## test_pilot_005_kent.gd - 肯特（pilot_005）专项逻辑测试
##
## 验证重做后的 3 效果 + EX 授予：
##   effect_01 帝国压制光环：授予装帝国机师牌的机甲 EX 压制能力（ATTACK_PRE 弃对侧2张行动牌）
##   effect_02 帝国机甲动力+4：帝国框架机甲动力+4（派生值实时重算，见 test_pilot_system.test11）
##   effect_03 取消/恢复加成：选其他机甲 toggle off/on 肯特加成（注册见 test_pilot_system.test12）
##   granted 帝国压制：攻击/被攻击时消耗4动力，使用方选弃对侧2张行动牌（不足2弃全部）
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


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


func _setup_kent(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_005_肯特", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


## 构造 attack action（fire ATTACK_PRE 用，仿 test_pilot_004_masha）
func _make_attack_action(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p005_atk_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 确保 player 行动手牌充足（用于被弃方补牌）
func _ensure_enemy_action_hand(gs, count: int) -> Variant:
	var enemy_player = gs.players.get(&"enemy")
	while enemy_player.action_hand.size() < count and gs.deck_state.action_deck.size() > 0:
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		enemy_player.action_hand.append(cid)
		var dc = gs.get_card(cid)
		if dc != null:
			dc.zone = &"action_hand"
			dc.owner_player_id = &"enemy"
	if enemy_player.action_hand.size() < count:
		return "enemy 行动手牌不足%d张" % count
	return null


# ═══════════════════════════════════════════
# granted 帝国压制：攻击时弃对侧2张
# ═══════════════════════════════════════════

## 测试1：肯特持有者攻击 -> ATTACK_PRE granted 弹确认 -> 弃对侧(目标)2张行动牌 + power-4
func test_granted_attacker_discard_2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kent(battle, &"player")
	if s == null:
		return "找不到 pilot_005_肯特"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	# 确保 player 动力>=4（扣4后仍>=0）
	mech.power = 8
	var power_before: int = mech.power
	var err = _ensure_enemy_action_hand(gs, 2)
	if err != null:
		return err
	var hand_before: int = enemy_player.action_hand.size()
	battle.context.action_ui_bridge.context = battle.context
	# 构造 attack（肯特持有者攻击 enemy）
	var attack := _make_attack_action(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "granted 应在 ATTACK_PRE 挂起 CHOOSE_ONE，state=%s" % String(attack.state)
	# 确认挂起的是 pilot_005_granted_suppression
	var pend: Dictionary = te._pending_effect.get(attack.action_id, {})
	var pend_eff = pend.get("effect", null)
	if pend_eff == null or String(pend_eff.effect_id) != "pilot_005_granted_suppression":
		return "挂起 effect 应为 pilot_005_granted_suppression 实=%s" % String(pend_eff.effect_id if pend_eff != null else "null")
	# resume 确认（option 0 = 消耗4动力弃对侧2张）
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# power 应-4
	if mech.power != power_before - 4:
		return "player 动力应-4 实=%d（before=%d）" % [mech.power, power_before]
	# 应弹 select_discard_cards（弃对侧=enemy 2张暗牌）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"select_discard_cards":
		return "确认后应弹 select_discard_cards，wait=%s" % str(wait_info)
	var input_params: Dictionary = wait_info.get("input_params", {})
	var discard_pid: StringName = input_params.get("discard_player_id", &"")
	if String(discard_pid) != "enemy":
		return "弃牌对象应为 enemy（对侧=目标），实际 %s" % String(discard_pid)
	# 选 enemy 手牌前2张弃置
	var chosen: Array = enemy_player.action_hand.slice(0, 2)
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": chosen})
	await _pump_frames(3)
	# 验证 enemy 手牌-2
	if enemy_player.action_hand.size() != hand_before - 2:
		return "enemy 手牌应-2 前=%d 后=%d" % [hand_before, enemy_player.action_hand.size()]
	return true


## 测试2：肯特持有者被攻击 -> ATTACK_PRE granted 弹确认 -> 弃对侧(攻击方)2张行动牌 + power-4
func test_granted_defender_discard_2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kent(battle, &"player")
	if s == null:
		return "找不到 pilot_005_肯特"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	mech.power = 8
	var power_before: int = mech.power
	var err = _ensure_enemy_action_hand(gs, 2)
	if err != null:
		return err
	var hand_before: int = enemy_player.action_hand.size()
	battle.context.action_ui_bridge.context = battle.context
	# 构造 attack（enemy 攻击肯特持有者 -> 对侧=攻击方=enemy）
	var attack := _make_attack_action(battle, enemy_mech.mech_id, mech.mech_id, &"enemy")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "granted 应在 ATTACK_PRE（被攻击）挂起 CHOOSE_ONE，state=%s" % String(attack.state)
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	if mech.power != power_before - 4:
		return "player 动力应-4 实=%d（before=%d）" % [mech.power, power_before]
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"select_discard_cards":
		return "确认后应弹 select_discard_cards，wait=%s" % str(wait_info)
	var input_params: Dictionary = wait_info.get("input_params", {})
	var discard_pid: StringName = input_params.get("discard_player_id", &"")
	# 对侧=攻击方=enemy（source_mech=player_mech==target_id -> opposing=attacker_id=enemy_mech -> enemy 玩家）
	if String(discard_pid) != "enemy":
		return "弃牌对象应为 enemy（对侧=攻击方），实际 %s" % String(discard_pid)
	var chosen: Array = enemy_player.action_hand.slice(0, 2)
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": chosen})
	await _pump_frames(3)
	if enemy_player.action_hand.size() != hand_before - 2:
		return "enemy 手牌应-2 前=%d 后=%d" % [hand_before, enemy_player.action_hand.size()]
	return true


## 测试3：肯特持有者动力<4 时 granted 不触发（条件 OWNER_POWER_ABOVE_OR_EQUAL(4) 不满足）
func test_granted_low_power_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kent(battle, &"player")
	if s == null:
		return "找不到 pilot_005_肯特"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	mech.power = 3  # <4
	var attack := _make_attack_action(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# 动力<4：granted 条件不满足，不应挂起其 CHOOSE_ONE
	var pend: Dictionary = te._pending_effect.get(attack.action_id, {})
	var pend_eff = pend.get("effect", null)
	if pend_eff != null and String(pend_eff.effect_id) == "pilot_005_granted_suppression":
		return "动力<4 时 granted 不应触发挂起"
	return true


## 测试4：对侧手牌不足2张 -> 弃全部（裁定歧义1：触发效果非成本，不足2弃全部）
func test_granted_insufficient_hand_discard_all() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kent(battle, &"player")
	if s == null:
		return "找不到 pilot_005_肯特"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	mech.power = 8
	# enemy 手牌只留1张（其余移回牌库）
	while enemy_player.action_hand.size() > 1:
		var cid: StringName = enemy_player.action_hand.pop_back()
		gs.deck_state.action_deck.push_front(cid)
	if enemy_player.action_hand.size() == 0:
		# 补1张
		var err = _ensure_enemy_action_hand(gs, 1)
		if err != null:
			return err
	var hand_before: int = enemy_player.action_hand.size()
	if hand_before > 1:
		return "测试前置：enemy 手牌应<=1 实=%d" % hand_before
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack_action(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "granted 应在 ATTACK_PRE 挂起（手牌1张仍触发，>0）state=%s" % String(attack.state)
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"select_discard_cards":
		return "确认后应弹 select_discard_cards，wait=%s" % str(wait_info)
	# 不足2弃全部：选剩余全部手牌
	var chosen: Array = enemy_player.action_hand.duplicate()
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": chosen})
	await _pump_frames(3)
	if enemy_player.action_hand.size() != 0:
		return "enemy 手牌应全弃（不足2弃全部）前=%d 后=%d" % [hand_before, enemy_player.action_hand.size()]
	return true


## 测试5：CHOOSE_ONE 取消（optional）-> 不消耗动力不弃牌
func test_granted_cancel_no_cost_no_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kent(battle, &"player")
	if s == null:
		return "找不到 pilot_005_肯特"
	var gs = s.gs
	var te = battle.context.timing_engine
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	mech.power = 8
	var power_before: int = mech.power
	var err = _ensure_enemy_action_hand(gs, 2)
	if err != null:
		return err
	var hand_before: int = enemy_player.action_hand.size()
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack_action(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "granted 应在 ATTACK_PRE 挂起 CHOOSE_ONE，state=%s" % String(attack.state)
	# 取消（chosen_option_index = -1）
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": -1})
	await _pump_frames(3)
	# 不消耗动力、不弃牌
	if mech.power != power_before:
		return "取消后不应消耗动力 实=%d（before=%d）" % [mech.power, power_before]
	if enemy_player.action_hand.size() != hand_before:
		return "取消后不应弃牌 前=%d 后=%d" % [hand_before, enemy_player.action_hand.size()]
	return true


## 测试6：换肯特后帝国框架机甲 max_power 实际+4（派生光环同步上限，非仅 breakdown 显示）
## 修复前：get_pilot_005_empire_power_bonus 实时算+4 但 max_power（存储字段）未 recalc，
## 详情合计显示+4 实际上限/数值没加。修复：set_pilot 后 _recalc_power_for_faction_frames(帝国)。
func test_kent_empire_frame_max_power_synced() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	# static _pilot_aura 跨测试残留（前序 test set_pilot 肯特未 unset）：清残留肯特 aura，确保基线干净。
	for _src_inst in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(_src_inst)
	# 清残留后 recalc 帝国框架机甲上限（max_power 是存储字段，unregister 不自动 recalc）
	for _mid in gs.mechs:
		var _m = gs.mechs[_mid]
		if _m != null and _m.get("frame_def") != null and String(_m.frame_def.faction) == "帝国":
			_m.recalc_power_limits()
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 不存在"
	var enemy_max_before: int = enemy_mech.max_power
	var card = _make_instance(gs, cdb, "pilot_005_肯特", &"player")
	if card == null:
		return "找不到 pilot_005_肯特"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 帝国框架机甲(enemy_mech=frame_002_原始框架=帝国) max_power 应实际+4
	if enemy_mech.max_power != enemy_max_before + 4:
		return "帝国框架机甲 max_power 应+4 实=%d（before=%d）" % [enemy_mech.max_power, enemy_max_before]
	# effect_03 toggle off（走 GameActions.toggle_aura_target，含 recalc）后 max_power 应回归
	var ga = battle.context.game_actions
	ga.toggle_aura_target({"toggle": &"off"}, {"target_id": enemy_mech.mech_id, "binding_context": {"card_instance_id": card.instance_id}})
	if enemy_mech.max_power != enemy_max_before:
		return "toggle off 后 max_power 应回归 实=%d（before=%d）" % [enemy_mech.max_power, enemy_max_before]
	# toggle on 后恢复
	ga.toggle_aura_target({"toggle": &"on"}, {"target_id": enemy_mech.mech_id, "binding_context": {"card_instance_id": card.instance_id}})
	if enemy_mech.max_power != enemy_max_before + 4:
		return "toggle on 后 max_power 应恢复+4 实=%d" % enemy_mech.max_power
	# unset 后回归
	battle.context.game_setup_service.unset_pilot(player_mech.mech_id)
	if enemy_mech.max_power != enemy_max_before:
		return "unset 后 max_power 应回归 实=%d（before=%d）" % [enemy_mech.max_power, enemy_max_before]
	return true
