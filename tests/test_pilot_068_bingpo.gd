## test_pilot_068_bingpo.gd - 冰魄（pilot_068）效果测试
##
## 冰魄 1 按钮（被动融合）：effect_01(USE_ACTION_AT 迎击范围压制) + effect_02(ATTACK_AFTER 未命中抽牌)。
##   权威效果：「我方使用迎击牌响应攻击时，该攻击范围-2（不会低于1）。若该攻击没有命中，我方抽2张行动牌。」
##   effect_01：LISTEN USE_ACTION_AT。我方（USED_CARD_OWNER_IS_SELF）在响应窗口使用迎击牌
##              （USED_COUNTER_CARD）且绑定原攻击（USED_ACTION_HAS_LINKED_ATTACK）时，先于迎击牌
##              自身效果执行（USE_ACTION_AT 早于 execute_effects 步），MODIFY_ATTACK_RANGE 把该攻击
##              范围-2（min_value 钳制不低于1），并 SET_ACTION_RECORD_FLAG 写 flag 到该 attack.record。
##              被动自动、无每回合限制、无弹窗。
##   effect_02：LISTEN ATTACK_AFTER。attack.record._effect_flags 含 flag（e01 发动过，fork 深拷贝继承）
##              + 该攻击未命中（payload.miss=true）时，我方 EXECUTE_GAIN_CARD 抽2张行动牌。
##              hide_button + merge_desc_into_index=1，描述合并到按钮1 hover（共1个按钮）。
##
## 关键扩展点（本测试覆盖）：
##   1. MODIFY_ATTACK_RANGE 增加 attack_action_id 回退（use_action_card 上下文定位原 attack），
##      仿 MODIFY_ATTACK_MIGHT（effect_035 范式）。
##   2. e01 写 flag -> e02 读 flag 判定 e01 是否发动（不用 requires_effect，fork 兼容）。
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
	battle.rng_seed = 90068
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
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


## 设冰魄为 owner_id 机甲的机师，返回 {mech, enemy_mech, pilot_card, gs, cdb}；失败返回 null。
func _setup_bingpo(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_068_冰魄", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	var enemy_mech = gs.get_mech_for_player(&"enemy") if owner_id == &"player" else gs.get_mech_for_player(&"player")
	return {"card": card, "mech": mech, "enemy_mech": enemy_mech, "gs": gs, "cdb": cdb}


## 把指定 card_def_id 的行动牌塞入玩家手牌，返回卡牌实例ID；失败返回空串。
func _ensure_action_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &"player"
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &"player"
			return cid
	return &""


## 构造 attack action（fire USE_ACTION_AT/ATTACK_AFTER 用）。record 带 weapon_range 供范围钳制断言。
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName, weapon_range: int = 3) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p068_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id, "weapon_range": weapon_range, "extra_range": 0}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 构造 use_action_card action（迎击响应）：record 绑定 card + 原 attack_action_id。
func _make_uac(battle, card_id: StringName, attack_id: StringName, player_id: StringName, mech_id: StringName) -> _Action:
	var uac := _Action.new()
	uac.action_id = &"test_p068_uac_%d" % [randi() % 1000000]
	uac.action_type = &"use_action_card"
	uac.record = {"card_instance_id": card_id, "attack_action_id": attack_id, "player_id": player_id}
	uac.state = &"running"
	uac.context = battle.context
	uac.source = {"player_id": player_id, "mech_id": mech_id, "card_instance_id": card_id}
	battle.context.action_registry.register(uac)
	return uac


## 清空玩家行动手牌（移回牌堆底，抽牌断言用）
func _clear_player_action_hand(battle) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	if player == null:
		return
	for cid in player.action_hand.duplicate():
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN USE_ACTION_AT，条件三连，MODIFY_ATTACK_RANGE -2 min1 + flag）
func test_pilot_068_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_068_effect_01")
	if e == null:
		return "缺 pilot_068_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_01 listen_timing 应 USE_ACTION_AT"
	if e.listen_action_type != &"use_action_card":
		return "effect_01 listen_action_type 应 use_action_card"
	if e.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（无每回合限制）实=%s" % String(e.once_per_turn_key)
	# 条件：USED_CARD_OWNER_IS_SELF + USED_COUNTER_CARD + USED_ACTION_HAS_LINKED_ATTACK
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	for want in [&"USED_CARD_OWNER_IS_SELF", &"USED_COUNTER_CARD", &"USED_ACTION_HAS_LINKED_ATTACK"]:
		if not ops.has(String(want)):
			return "effect_01 应含条件 %s，实际 ops=%s" % [String(want), str(ops)]
	# actions: [MODIFY_ATTACK_RANGE(delta=-2, min_value=1), SET_ACTION_RECORD_FLAG(flag)]
	var acts = e.actions
	if acts.size() != 2:
		return "effect_01 actions 应2个（MODIFY_ATTACK_RANGE + SET_ACTION_RECORD_FLAG）实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "MODIFY_ATTACK_RANGE":
		return "effect_01 actions[0] 应 MODIFY_ATTACK_RANGE"
	if int(acts[0].get("params", {}).get("delta", 0)) != -2:
		return "MODIFY_ATTACK_RANGE delta 应 -2"
	if int(acts[0].get("params", {}).get("min_value", 0)) != 1:
		return "MODIFY_ATTACK_RANGE min_value 应 1（不低于1）"
	if String(acts[1].get("type", &"")) != "SET_ACTION_RECORD_FLAG":
		return "effect_01 actions[1] 应 SET_ACTION_RECORD_FLAG"
	if String(acts[1].get("params", {}).get("flag", &"")) != "pilot_068_range_reduced":
		return "SET_ACTION_RECORD_FLAG flag 应 pilot_068_range_reduced"
	return true


## 测试2：effect_02 定义正确（LISTEN ATTACK_AFTER，hide_button + merge_desc_into_index=1，flag+miss 条件，抽2）
func test_pilot_068_effect_02_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_068_effect_02")
	if e == null:
		return "缺 pilot_068_effect_02"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_02 listen_timing 应 ATTACK_AFTER"
	if not bool(e.hide_button):
		return "effect_02 应 hide_button=true（与按钮1合并，冰魄只1个按钮）"
	if int(e.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1"
	if e.once_per_turn_key != &"":
		return "effect_02 不应有 once_per_turn_key"
	# 条件：ATTACK_RECORD_FLAG_IS_SET(flag) + PAYLOAD_ATTACK_MISS
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("ATTACK_RECORD_FLAG_IS_SET"):
		return "effect_02 应含 ATTACK_RECORD_FLAG_IS_SET"
	if not ops.has("PAYLOAD_ATTACK_MISS"):
		return "effect_02 应含 PAYLOAD_ATTACK_MISS"
	for c in e.conditions:
		if String(c.get("op", &"")) == "ATTACK_RECORD_FLAG_IS_SET":
			if String(c.get("params", {}).get("flag", &"")) != "pilot_068_range_reduced":
				return "ATTACK_RECORD_FLAG_IS_SET flag 应 pilot_068_range_reduced"
	# actions: [EXECUTE_GAIN_CARD count=2 from action_deck]
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_02 actions 应 [EXECUTE_GAIN_CARD]"
	if int(acts[0].get("params", {}).get("count", 0)) != 2:
		return "effect_02 应抽2张 实=%d" % int(acts[0].get("params", {}).get("count", 0))
	if String(acts[0].get("params", {}).get("from_zone", &"")) != "action_deck":
		return "effect_02 应抽行动牌（from_zone=action_deck）"
	return true


## 测试3：e01 我方迎击响应 -> 攻击范围-2（写 extra_range）+ flag 已写（被动自动不挂起）
func test_pilot_068_e01_counter_reduce_range_and_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bingpo(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_068_冰魄）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context
	# 玩家手牌迎击牌（反击，action_type=迎击）
	var counter_id: StringName = _ensure_action_card_in_hand(battle, "action_010_反击")
	if counter_id == &"":
		return "找不到反击牌"
	var counter_card = gs.get_card(counter_id)
	counter_card.owner_player_id = &"player"
	counter_card.mech_id = mech.mech_id
	# mock attack（敌方攻击玩家，基础范围3）+ mock use_action_card（玩家迎击，绑定 attack）
	var mock_attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", 3)
	var mock_uac := _make_uac(battle, counter_id, mock_attack.action_id, &"player", mech.mech_id)
	# fire USE_ACTION_AT -> e01 被动自动执行（无 CHOOSE_ONE，不挂起）
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, mock_uac)
	await _pump_frames(3)
	# 断言1：mock attack extra_range -2（MODIFY_ATTACK_RANGE 经 attack_action_id 定位原 attack）
	if int(mock_attack.record.get("extra_range", 0)) != -2:
		return "e01 应使攻击范围-2，实际 extra_range=%d" % int(mock_attack.record.get("extra_range", 0))
	# 断言2：flag 已写（e02 判定用）
	var flags: Dictionary = mock_attack.record.get("_effect_flags", {})
	if not bool(flags.get("pilot_068_range_reduced", {}).get("value", false)):
		return "e01 应写 flag pilot_068_range_reduced 实=%s" % str(flags)
	return true


## 测试4：e01 范围钳制——基础范围1时 -2 后仍不低于1（extra_range 钳制为0）
func test_pilot_068_e01_clamp_min_range() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bingpo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	var counter_id: StringName = _ensure_action_card_in_hand(battle, "action_010_反击")
	if counter_id == &"":
		return "找不到反击牌"
	var counter_card = gs.get_card(counter_id)
	counter_card.owner_player_id = &"player"
	counter_card.mech_id = mech.mech_id
	# 基础范围1：-2 后有效范围钳制为1（extra_range = 1 - 1 = 0）
	var mock_attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", 1)
	var mock_uac := _make_uac(battle, counter_id, mock_attack.action_id, &"player", mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, mock_uac)
	await _pump_frames(3)
	if int(mock_attack.record.get("extra_range", 0)) != 0:
		return "基础范围1时 extra_range 应钳制为0（有效范围1）实=%d" % int(mock_attack.record.get("extra_range", 0))
	return true


## 测试5：e01 非迎击牌不触发（USED_COUNTER_CARD 拦截）——无范围修正、无 flag
func test_pilot_068_e01_not_counter_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bingpo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	# 非迎击牌（攻击牌 进攻）
	var atk_id: StringName = _ensure_action_card_in_hand(battle, "action_001_进攻")
	if atk_id == &"":
		return "找不到进攻牌"
	var atk_card = gs.get_card(atk_id)
	atk_card.owner_player_id = &"player"
	atk_card.mech_id = mech.mech_id
	var mock_attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", 3)
	var mock_uac := _make_uac(battle, atk_id, mock_attack.action_id, &"player", mech.mech_id)
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, mock_uac)
	await _pump_frames(3)
	if int(mock_attack.record.get("extra_range", 0)) != 0:
		return "非迎击牌不应修正范围，实际 extra_range=%d" % int(mock_attack.record.get("extra_range", 0))
	if mock_attack.record.has("_effect_flags"):
		return "非迎击牌不应写 flag"
	return true


## 测试6：e02 未命中抽2（flag 已设 + miss=true -> 我方抽2张行动牌）
func test_pilot_068_e02_miss_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bingpo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_action_hand(battle)
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	# 构造已设 flag + 未命中 的攻击
	var mock_attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", 3)
	mock_attack.record["miss"] = true
	mock_attack.record["_effect_flags"] = {"pilot_068_range_reduced": {"value": true, "data": {}}}
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(5)
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 2:
		return "e02 未命中应抽2张行动牌 前=%d 后=%d" % [player_hand_before, gs.players.get(&"player").action_hand.size()]
	return true


## 测试7：e02 命中不抽（flag 已设但 hit=true）
func test_pilot_068_e02_hit_no_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bingpo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	_clear_player_action_hand(battle)
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var mock_attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", 3)
	mock_attack.record["hit"] = true
	mock_attack.record["miss"] = false
	mock_attack.record["_effect_flags"] = {"pilot_068_range_reduced": {"value": true, "data": {}}}
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(5)
	if gs.players.get(&"player").action_hand.size() != player_hand_before:
		return "命中时不应抽牌 前=%d 后=%d" % [player_hand_before, gs.players.get(&"player").action_hand.size()]
	return true


## 测试8：e02 无 flag 不抽（未命中但 e01 未发动）
func test_pilot_068_e02_no_flag_no_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bingpo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	_clear_player_action_hand(battle)
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var mock_attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", 3)
	mock_attack.record["miss"] = true
	# 不设 _effect_flags
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(5)
	if gs.players.get(&"player").action_hand.size() != player_hand_before:
		return "无 flag 时不应抽牌（e01 未发动）前=%d 后=%d" % [player_hand_before, gs.players.get(&"player").action_hand.size()]
	return true


## 测试9：全链路——迎击减范围+写flag，随后攻击未命中 -> 抽2
func test_pilot_068_full_chain_reduce_then_miss_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_bingpo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = s.enemy_mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_action_hand(battle)
	var counter_id: StringName = _ensure_action_card_in_hand(battle, "action_010_反击")
	if counter_id == &"":
		return "找不到反击牌"
	var counter_card = gs.get_card(counter_id)
	counter_card.owner_player_id = &"player"
	counter_card.mech_id = mech.mech_id
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var mock_attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", 3)
	var mock_uac := _make_uac(battle, counter_id, mock_attack.action_id, &"player", mech.mech_id)
	# ① 迎击响应 -> e01 减范围+写 flag
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, mock_uac)
	await _pump_frames(3)
	if int(mock_attack.record.get("extra_range", 0)) != -2:
		return "全链路①：范围应-2 实=%d" % int(mock_attack.record.get("extra_range", 0))
	# ② 模拟 check_hit 未命中 -> e02 抽2
	mock_attack.record["miss"] = true
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(5)
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 2:
		return "全链路②：未命中应抽2 前=%d 后=%d" % [player_hand_before, gs.players.get(&"player").action_hand.size()]
	return true
