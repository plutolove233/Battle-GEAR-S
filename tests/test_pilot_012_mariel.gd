## test_pilot_012_mariel.gd - 玛丽尔（pilot_012）效果测试
##
## 玛丽尔 1 按钮（被动融合）：effect_01(ATTACK_PRE 夺牌压制) + effect_02(ATTACK_AFTER 命中奖励)。
##   effect_01：每玩家回合1次，攻击时可选发动--对每个机甲目标偷1张行动牌(暗牌选)并使其当前动力-3。
##             发动后 SET_ACTION_RECORD_FLAG 写 flag(pilot_012_effect_01_fired) 到 attack.record._effect_flags。
##   effect_02：LISTEN ATTACK_AFTER。flag 已设 + 命中时，逐命中目标可选抽1张行动牌并回复3动力。
##             不用 requires_effect（查同 action_id，双连 fork 子动作 id 不同致失效），改靠 flag
##             （fork 深拷贝 record 继承）判定 e01 是否发动 + 命中。
##
## 关键修复点（本测试覆盖）：
##   1. SET_ACTION_RECORD_FLAG 真写 flag（曾为 no-op）。
##   2. e02 条件/目标规则读 flag（fork 深拷贝继承）-> 双连每个 fork AFTER 都能触发命中奖励。
##   3. e02 去掉 requires_effect（同 action_id 检查在 fork 上失效）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90012
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura），避免跨测试泄漏
func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


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


## 设玛丽尔为 owner_id 机甲的机师，返回 {mech, enemy_mech, pilot_card, gs, cdb}；失败返回 null。
func _setup_mariel(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_012_玛丽尔", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


## 构造 attack action（fire ATTACK_PRE/AFTER 用）
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p012_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 给 player 补 N 张行动牌（从牌堆顶抽）
func _give_player_action_cards(battle, count: int) -> Array:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var out: Array = []
	for i in range(count):
		if gs.deck_state.action_deck.is_empty():
			break
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		player.action_hand.append(cid)
		var c = gs.get_card(cid)
		if c != null:
			c.zone = &"action_hand"
			c.owner_player_id = &"player"
		out.append(cid)
	return out


## 确保 enemy 行动手牌至少 count 张（供偷牌/减动力测试）
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


## 清空 enemy 行动手牌（移回牌堆底，测试无牌目标用）
func _clear_enemy_action_hand(battle) -> void:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 创建第 2 台敌方机甲（敌方阵营），放在指定位置，6 部件槽（无装备，护甲=0）。
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary) -> MechState:
	var gs = battle.context.game_state
	var m := _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = &"enemy"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = pos
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		m.slots[slot_id] = s
	gs.mechs[m.mech_id] = m
	return m


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN ATTACK_PRE priority30，optional CHOOSE_ONE，SET_ACTION_RECORD_FLAG）
func test_pilot_012_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_012_effect_01")
	if e == null:
		return "缺 pilot_012_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_01 listen_timing 应 ATTACK_PRE"
	if int(e.priority) != 30:
		return "effect_01 priority 应 30 实=%d" % int(e.priority)
	if e.listen_action_type != &"attack":
		return "effect_01 listen_action_type 应 attack"
	if e.once_per_turn_key != &"pilot_012_effect_01":
		return "effect_01 once_per_turn_key 应 pilot_012_effect_01"
	if int(e.once_per_turn_max) != 1:
		return "effect_01 once_per_turn_max 应 1"
	# conditions: SELF_MECH_IS_ATTACKER + ATTACK_HAS_OTHER_MECH_TARGET
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "effect_01 应含 SELF_MECH_IS_ATTACKER"
	if not ops.has("ATTACK_HAS_OTHER_MECH_TARGET"):
		return "effect_01 应含 ATTACK_HAS_OTHER_MECH_TARGET"
	# target rule: ALL_CURRENT_ATTACK_MECH_TARGETS
	if String(e.target_rules[0].get("rule", &"")) != "ALL_CURRENT_ATTACK_MECH_TARGETS":
		return "effect_01 target_rule 应 ALL_CURRENT_ATTACK_MECH_TARGETS"
	# actions: [CHOOSE_ONE(optional, 1 option)]，option 内 FOR_EACH_TARGET + SET_ACTION_RECORD_FLAG
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 actions 应 [CHOOSE_ONE]"
	if not bool(acts[0].get("params", {}).get("optional", false)):
		return "effect_01 CHOOSE_ONE 应 optional=true"
	var options = acts[0].get("params", {}).get("options", [])
	if options.size() != 1:
		return "effect_01 CHOOSE_ONE options 应1个 实=%d" % options.size()
	var opt_actions: Array = options[0].get("actions", [])
	# 末尾应是 SET_ACTION_RECORD_FLAG(flag=pilot_012_effect_01_fired)
	var last = opt_actions[opt_actions.size() - 1]
	if String(last.get("type", &"")) != "SET_ACTION_RECORD_FLAG":
		return "effect_01 option 末尾应 SET_ACTION_RECORD_FLAG 实=%s" % String(last.get("type", &""))
	if String(last.get("params", {}).get("flag", &"")) != "pilot_012_effect_01_fired":
		return "SET_ACTION_RECORD_FLAG flag 应 pilot_012_effect_01_fired"
	# 含 FOR_EACH_TARGET（偷牌+减动力）
	var has_fet := false
	for a in opt_actions:
		if String(a.get("type", &"")) == "FOR_EACH_TARGET":
			has_fet = true
			var inner: Array = a.get("params", {}).get("actions", [])
			var has_steal := false
			var has_power := false
			for ia in inner:
				var ia_type: String = String(ia.get("type", &""))
				if ia_type == "EXECUTE_STEAL":
					has_steal = true
				if ia_type == "MODIFY_MECH_POWER" and int(ia.get("params", {}).get("delta", 0)) == -3:
					has_power = true
				# EXECUTE_STEAL 嵌套在 CONDITIONAL_ACTIONS.if_true_actions 内（有牌才偷）
				if ia_type == "CONDITIONAL_ACTIONS":
					for cta in ia.get("params", {}).get("if_true_actions", []):
						if String(cta.get("type", &"")) == "EXECUTE_STEAL":
							has_steal = true
			if not has_steal:
				return "FOR_EACH_TARGET 应含 EXECUTE_STEAL（含 CONDITIONAL 嵌套）"
			if not has_power:
				return "FOR_EACH_TARGET 应含 MODIFY_MECH_POWER delta=-3"
	if not has_fet:
		return "effect_01 option 应含 FOR_EACH_TARGET"
	return true


## 测试2：effect_02 定义正确（LISTEN ATTACK_AFTER，无 requires_effect，flag 条件+目标规则）
func test_pilot_012_effect_02_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_012_effect_02")
	if e == null:
		return "缺 pilot_012_effect_02"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_02 listen_timing 应 ATTACK_AFTER"
	if int(e.priority) != 10:
		return "effect_02 priority 应 10 实=%d" % int(e.priority)
	# 关键：不应有 requires_effect（双连 fork 子动作 id 不同 -> 失效）
	if e.requires_effect != &"":
		return "effect_02 不应有 requires_effect（fork 失效根因）实=%s" % String(e.requires_effect)
	# once_per_turn_key 应为空（命中奖励每个 fork AFTER 都可触发，不限额）
	if e.once_per_turn_key != &"":
		return "effect_02 不应有 once_per_turn_key（每命中目标可触发）"
	# conditions: SELF_MECH_IS_ATTACKER + RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT(flag)
	var ops2: Array = []
	for c in e.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("SELF_MECH_IS_ATTACKER"):
		return "effect_02 应含 SELF_MECH_IS_ATTACKER"
	if not ops2.has("RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT"):
		return "effect_02 应含 RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT"
	var hit_cond = null
	for c in e.conditions:
		if String(c.get("op", &"")) == "RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT":
			hit_cond = c
	if String(hit_cond.get("params", {}).get("flag", &"")) != "pilot_012_effect_01_fired":
		return "RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT flag 应 pilot_012_effect_01_fired"
	# target rule: ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG(flag)
	if String(e.target_rules[0].get("rule", &"")) != "ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG":
		return "effect_02 target_rule 应 ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG"
	if String(e.target_rules[0].get("params", {}).get("flag", &"")) != "pilot_012_effect_01_fired":
		return "effect_02 target_rule flag 应 pilot_012_effect_01_fired"
	# actions: FOR_EACH_TARGET -> inner CHOOSE_ONE(optional) -> EXECUTE_GAIN_CARD + RESTORE_POWER(3)
	var acts2 = e.actions
	if acts2.size() != 1 or String(acts2[0].get("type", &"")) != "FOR_EACH_TARGET":
		return "effect_02 actions 应 [FOR_EACH_TARGET]"
	var inner2: Array = acts2[0].get("params", {}).get("actions", [])
	if inner2.size() != 1 or String(inner2[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_02 FOR_EACH_TARGET inner 应 [CHOOSE_ONE]"
	if not bool(inner2[0].get("params", {}).get("optional", false)):
		return "effect_02 inner CHOOSE_ONE 应 optional=true（逐命中目标可选）"
	var opt2: Array = inner2[0].get("params", {}).get("options", [])
	if opt2.size() != 1:
		return "effect_02 inner CHOOSE_ONE options 应1个"
	var reward_actions: Array = opt2[0].get("actions", [])
	var has_gain := false
	var has_restore := false
	for ra in reward_actions:
		if String(ra.get("type", &"")) == "EXECUTE_GAIN_CARD" and int(ra.get("params", {}).get("count", 0)) == 1:
			has_gain = true
		if String(ra.get("type", &"")) == "RESTORE_POWER" and int(ra.get("params", {}).get("amount", 0)) == 3:
			has_restore = true
	if not has_gain:
		return "effect_02 命中奖励应含 EXECUTE_GAIN_CARD count=1"
	if not has_restore:
		return "effect_02 命中奖励应含 RESTORE_POWER amount=3"
	return true


# ═══════════════════════════════════════════
# effect_01 行为测试
# ═══════════════════════════════════════════

## 测试3：e01 单目标偷牌+减动力+写 flag
func test_pilot_012_e01_steal_and_drain_single_target() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_012_玛丽尔）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# enemy 需至少1张行动牌供偷
	var err = _ensure_enemy_action_hand(gs, 1)
	if err != null:
		return err
	enemy_mech.power = 10
	enemy_mech.max_power = 10
	var enemy_hand_before: int = enemy_player.action_hand.size()
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var stolen_cid: StringName = enemy_player.action_hand[0]

	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# e01 optional CHOOSE_ONE 应挂起
	if attack.state != &"waiting_timing":
		return "e01 应在 ATTACK_PRE 挂起 CHOOSE_ONE，state=%s" % String(attack.state)
	# resume 选 option 0（偷牌+减动力）
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# EXECUTE_STEAL 应弹 select_discard_cards（玩家选 enemy 暗牌）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"select_discard_cards":
		return "e01 偷牌应弹 select_discard_cards，wait=%s" % str(wait_info.get("input_type", &""))
	var input_params: Dictionary = wait_info.get("input_params", {})
	# 弃牌对象应为 enemy（被偷方）
	if String(input_params.get("discard_player_id", &"")) != "enemy":
		return "偷牌对象应为 enemy 实=%s" % String(input_params.get("discard_player_id", &""))
	# 玩家选 enemy 手牌第1张
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": [stolen_cid]})
	await _pump_frames(12)

	# 验证：enemy 手牌-1，player 手牌+1
	if enemy_player.action_hand.has(stolen_cid):
		return "偷取后牌仍在 enemy 手牌"
	if not gs.players.get(&"player").action_hand.has(stolen_cid):
		return "偷取后牌未到 player 手牌"
	if enemy_player.action_hand.size() != enemy_hand_before - 1:
		return "enemy 手牌应-1 前=%d 后=%d" % [enemy_hand_before, enemy_player.action_hand.size()]
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 1:
		return "player 手牌应+1 前=%d 后=%d" % [player_hand_before, gs.players.get(&"player").action_hand.size()]
	# 验证：enemy 当前动力-3（clamp[0,max]，保留 temp_power，不降上限）
	if enemy_mech.power != 7:
		return "enemy 当前动力应-3（10->7）实=%d" % enemy_mech.power
	if enemy_mech.max_power != 10:
		return "enemy max_power 不应降 实=%d" % enemy_mech.max_power
	# 验证：flag 已写入 attack.record._effect_flags
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	var entry: Dictionary = flags.get("pilot_012_effect_01_fired", {})
	if not bool(entry.get("value", false)):
		return "SET_ACTION_RECORD_FLAG 应写 flag pilot_012_effect_01_fired.value=true 实=%s" % str(flags)
	return true


## 测试4：e01 无牌目标只减动力不偷牌（CONDITIONAL TARGET_HAS_ACTION_CARD 跳过偷牌）
func test_pilot_012_e01_no_card_target_drain_only() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# enemy 手牌清空（无牌可偷）
	_clear_enemy_action_hand(battle)
	enemy_mech.power = 10
	enemy_mech.max_power = 10

	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "e01 应挂起 CHOOSE_ONE"
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	# 无牌目标不应弹偷牌 UI（CONDITIONAL 跳过 EXECUTE_STEAL），直接减动力+写 flag
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) == &"select_discard_cards":
		return "无牌目标不应弹偷牌 select_discard_cards"
	# 验证：动力-3，flag 已写
	if enemy_mech.power != 7:
		return "无牌目标仍应减动力3（10->7）实=%d" % enemy_mech.power
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if not bool(flags.get("pilot_012_effect_01_fired", {}).get("value", false)):
		return "无牌目标仍应写 flag（e01 已发动）"
	return true


## 测试5：e01 取消发动 -> 不偷/不减/不写 flag + once_per_turn 未消耗
func test_pilot_012_e01_cancel_no_flag_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_ensure_enemy_action_hand(gs, 1)
	enemy_mech.power = 10

	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "e01 应挂起 CHOOSE_ONE"
	# 取消发动
	te.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(3)
	# 不写 flag
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if bool(flags.get("pilot_012_effect_01_fired", {}).get("value", false)):
		return "取消发动不应写 flag"
	# 动力不变
	if enemy_mech.power != 10:
		return "取消发动不应减动力 实=%d" % enemy_mech.power
	# once_per_turn 未消耗：第2次攻击 PRE 应仍触发 e01（挂起 CHOOSE_ONE）
	var attack2 := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack2)
	if attack2.state != &"waiting_timing":
		return "取消后 once_per_turn 未消耗，第2次攻击 e01 应仍挂起 实=%s" % String(attack2.state)
	return true


## 测试6：e01 每玩家回合1次 -- 同回合第2次攻击 e01 不触发
func test_pilot_012_e01_once_per_turn_second_attack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 第1次：无牌目标（避免偷牌 UI），e01 发动消耗额度
	_clear_enemy_action_hand(battle)
	enemy_mech.power = 10
	var attack1 := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack1)
	te.resume_pending_effect(attack1.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	if not bool(attack1.record.get("_effect_flags", {}).get("pilot_012_effect_01_fired", {}).get("value", false)):
		return "前置错误：第1次 e01 应写 flag"
	# 第2次（同回合）：e01 应因 once_per_turn 已用满而跳过（不挂起）
	var attack2 := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack2)
	if attack2.state == &"waiting_timing":
		return "同回合第2次攻击 e01 应因 once_per_turn 已用满而跳过（不挂起）"
	# 第2次不应写 flag（e01 未发动）
	if bool(attack2.record.get("_effect_flags", {}).get("pilot_012_effect_01_fired", {}).get("value", false)):
		return "第2次 e01 未发动不应写 flag"
	return true


# ═══════════════════════════════════════════
# effect_02 行为测试
# ═══════════════════════════════════════════

## 测试7：e02 命中奖励 -- flag 已设 + 命中 -> 抽1+回3
func test_pilot_012_e02_hit_reward_draw_restore() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 确保牌堆有牌可抽
	_give_player_action_cards(battle, 0)
	mech.power = 2
	mech.max_power = 10
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()

	# 构造已命中 + e01 已发动(flag) 的攻击
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["hit"] = true
	attack.record["_effect_flags"] = {"pilot_012_effect_01_fired": {"value": true, "data": {}}}
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	# e02 inner CHOOSE_ONE(optional) 应挂起（_run_flat_inline 设 waiting_effect_action）
	if attack.state != &"waiting_effect_action":
		return "e02 应在 ATTACK_AFTER 挂起 inner CHOOSE_ONE，state=%s" % String(attack.state)
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	# 验证：player 手牌+1（抽1），mech 动力+3（回复3）
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 1:
		return "命中奖励应抽1张 前=%d 后=%d" % [player_hand_before, gs.players.get(&"player").action_hand.size()]
	if mech.power != 5:
		return "命中奖励应回复3动力（2->5）实=%d" % mech.power
	return true


## 测试8：e02 无 flag（e01 未发动）-> 不触发
func test_pilot_012_e02_no_trigger_without_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	mech.power = 2
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()

	# 命中但无 flag（e01 未发动/被取消）
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["hit"] = true
	# 不设 _effect_flags
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if attack.state == &"waiting_timing":
		return "无 flag 时 e02 不应触发（不挂起 CHOOSE_ONE）"
	if gs.players.get(&"player").action_hand.size() != player_hand_before:
		return "无 flag 时不应抽牌"
	if mech.power != 2:
		return "无 flag 时不应回复动力 实=%d" % mech.power
	return true


## 测试9：e02 flag 已设但未命中 -> 不触发
func test_pilot_012_e02_no_trigger_on_miss() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	mech.power = 2
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()

	# flag 已设但 hit=false（未命中）
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	attack.record["hit"] = false
	attack.record["_effect_flags"] = {"pilot_012_effect_01_fired": {"value": true, "data": {}}}
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if attack.state == &"waiting_timing":
		return "未命中时 e02 不应触发（RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT 失败）"
	if gs.players.get(&"player").action_hand.size() != player_hand_before:
		return "未命中时不应抽牌"
	if mech.power != 2:
		return "未命中时不应回复动力 实=%d" % mech.power
	return true


# ═══════════════════════════════════════════
# 双连 fork flag 继承测试（核心修复点）
# ═══════════════════════════════════════════

## 测试10：e01 在主攻击 PRE 写 flag -> fork 深拷贝 record 继承 flag -> fork AFTER 触发 e02 命中奖励
## 模拟双连 fork 机制：主攻击只发 PRE（e01 在此写 flag），fork 子动作深拷贝 record 走 AT->AFTER->SETTLE。
func test_pilot_012_flag_inherited_to_fork_e02_fires() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_mariel(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 第2台敌方机甲（fork 的目标）
	var enemy2_mech := _create_second_enemy(battle, &"enemy2_mech_p012", {"q": 2, "r": 3})
	battle.context.action_ui_bridge.context = battle.context
	# 主攻击目标 enemy_mech 无牌（避免偷牌 UI），e01 发动写 flag 到主攻击 record
	_clear_enemy_action_hand(battle)
	enemy_mech.power = 10
	mech.power = 2
	mech.max_power = 10
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()

	# ── 主攻击 PRE：e01 发动写 flag ──
	var main_attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, main_attack)
	te.resume_pending_effect(main_attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	if not bool(main_attack.record.get("_effect_flags", {}).get("pilot_012_effect_01_fired", {}).get("value", false)):
		return "前置错误：主攻击 e01 应写 flag"
	# once_per_turn 已消耗（e01 在主攻击 PRE 发动）

	# ── 模拟 fork：深拷贝主攻击 record（仿 attack_action._create_fork_sub_action 的 record.duplicate(true)）──
	var fork_attack := _Action.new()
	fork_attack.action_id = &"test_p012_fork_%d" % [randi() % 1000000]
	fork_attack.action_type = &"attack"
	fork_attack.record = main_attack.record.duplicate(true)  # 深拷贝继承 flag
	# fork 改打 enemy2，命中
	fork_attack.record["target_id"] = enemy2_mech.mech_id
	fork_attack.record["hit"] = true
	fork_attack.state = &"running"
	fork_attack.context = battle.context
	fork_attack.source = {"mech_id": mech.mech_id, "player_id": &"player"}
	battle.context.action_registry.register(fork_attack)

	# ── fork AFTER：e02 应因 flag 继承而触发命中奖励 ──
	te.fire_timing(_TimingConst.ATTACK_AFTER, fork_attack)
	if fork_attack.state != &"waiting_effect_action":
		return "fork AFTER 应触发 e02（flag 深拷贝继承），state=%s" % String(fork_attack.state)
	te.resume_pending_effect(fork_attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(5)
	# 验证：player 抽1+回3（e02 在 fork AFTER 触发，证明 flag 继承生效）
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 1:
		return "fork AFTER 命中奖励应抽1张 前=%d 后=%d" % [player_hand_before, gs.players.get(&"player").action_hand.size()]
	if mech.power != 5:
		return "fork AFTER 命中奖励应回复3动力（2->5）实=%d" % mech.power
	# fork 的 flag 应仍存在（深拷贝独立于主攻击）
	if not bool(fork_attack.record.get("_effect_flags", {}).get("pilot_012_effect_01_fired", {}).get("value", false)):
		return "fork record 应继承 flag（深拷贝）"
	return true
