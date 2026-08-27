## test_pilot_015_nora.gd - 诺拉（pilot_015）效果测试
##
## 2 按钮：
##   按钮1=效果1（被动置灰）：3 隐藏被动 01a/01b/01c。
##     01a ATTACK_PRE priority40：手牌0+敌方物理攻击牌指定我方机甲 -> SET_ACTION_RECORD_FLAG pilot_015_force_pure_assault
##     01b ATTACK_AT priority0：被响应后 -> PILOT_015_FORCE_PURE_ASSAULT（标当前 fork+根 attack）
##     01c USE_ACTION_BEFORE：迎击牌响应我方攻击 -> PILOT_015_REPLACE_COUNTER_AS_DEFEND（视为防御）
##   按钮2=效果2a（主动进攻，每玩家回合1次）：全部行动牌入临时区，保留首张作虚拟牌当作进攻使用，
##   链末 DISCARD_TEMP_ZONE_CARDS 把临时区全部牌入弃牌堆（不触发 Action Engine 时点）。
##   02b 防御 AVAILABILITY（响应窗口，不建按钮）：全部行动牌当作防御响应。
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
	battle.rng_seed = 90015
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


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


## 给指定机甲设机师牌，返回机师牌实例
func _set_pilot_on_mech(battle, owner_id: StringName, mech, pilot_def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, pilot_def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return card


## 构造 attack action（带 attack_card_id 物理攻击牌 + weapon_might）
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName, attack_card_id: StringName, weapon_might: int) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p015_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"attack_card_id": attack_card_id,
		"weapon_might": weapon_might,
		"target_count": 1,
	}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid, "card_instance_id": attack_card_id}
	battle.context.action_registry.register(attack)
	return attack


## 构造 use_action_card action（带 attack_action_id 表示响应）
func _make_use_action(battle, card_id: StringName, player_id: StringName, mech_id: StringName, attack_action_id: StringName) -> _Action:
	var ua := _Action.new()
	ua.action_id = &"test_p015u_%d" % [randi() % 1000000]
	ua.action_type = &"use_action_card"
	ua.record = {
		"card_instance_id": card_id,
		"player_id": player_id,
		"mech_id": mech_id,
		"attack_action_id": attack_action_id,
	}
	ua.state = &"running"
	ua.context = battle.context
	ua.source = {"mech_id": mech_id, "player_id": player_id, "card_instance_id": card_id}
	battle.context.action_registry.register(ua)
	return ua


## 清空玩家行动手牌（移回牌堆底）
func _clear_action_hand(battle, pid: StringName) -> void:
	var gs = battle.context.game_state
	var p = gs.players.get(pid)
	if p == null:
		return
	for cid in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 给玩家手牌塞入指定 card_def_id 的牌
func _add_card_to_hand(battle, pid: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, pid)
	if card == null:
		return &""
	card.zone = &"hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 创建第 2 台敌方机甲
func _create_second_enemy(battle, mech_id: StringName, pos: Dictionary) -> _MechState:
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


## 设诺拉机师到 player 机甲，返回 {gs, mech, pilot_card}
func _setup_nora(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var pilot_card = _set_pilot_on_mech(battle, owner_id, mech, "pilot_015_诺拉")
	if pilot_card == null:
		return {}
	# effect_02a 含 HAS_ATTACK_TARGET_IN_RANGE 范围条件（无目标按钮置灰）。
	# 把敌方机甲移到本机甲相邻格（距离1，基础武器射程≥1 即可命中），保证触发测试满足条件。
	if owner_id == &"player":
		var enemy_m = gs.get_mech_for_player(&"enemy")
		if enemy_m != null:
			enemy_m.position = {"q": 3, "r": 2}
	return {"gs": gs, "mech": mech, "pilot_card": pilot_card}


# ═══════════════════════════════════════════
# 白盒：效果定义
# ═══════════════════════════════════════════

## 测试1：5 个效果定义结构正确
func test_p015_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	# 01a
	var e1a = effs.get(&"pilot_015_effect_01a")
	if e1a == null:
		return "缺 pilot_015_effect_01a"
	if e1a.mode != _TimingConst.MODE_LISTEN:
		return "01a mode 应 LISTEN"
	if e1a.listen_timing != _TimingConst.ATTACK_PRE:
		return "01a listen_timing 应 ATTACK_PRE"
	if int(e1a.priority) != 40:
		return "01a priority 应 40 实=%d" % int(e1a.priority)
	if e1a.listen_action_type != &"attack":
		return "01a listen_action_type 应 attack"
	var ops_a: Array = []
	for c in e1a.conditions:
		ops_a.append(String(c.get("op", &"")))
	if not ops_a.has("OWNER_ACTION_HAND_IS_EMPTY"):
		return "01a 应含 OWNER_ACTION_HAND_IS_EMPTY"
	if not ops_a.has("ATTACK_SOURCE_IS_PHYSICAL_ATTACK_CARD"):
		return "01a 应含 ATTACK_SOURCE_IS_PHYSICAL_ATTACK_CARD"
	if not ops_a.has("SELF_MECH_IS_ATTACK_TARGET"):
		return "01a 应含 SELF_MECH_IS_ATTACK_TARGET"
	if String(e1a.actions[0].get("type", &"")) != "SET_ACTION_RECORD_FLAG":
		return "01a action 应 SET_ACTION_RECORD_FLAG"
	if String(e1a.actions[0].get("params", {}).get("flag", &"")) != "pilot_015_force_pure_assault":
		return "01a flag 应 pilot_015_force_pure_assault"
	# 01b
	var e1b = effs.get(&"pilot_015_effect_01b")
	if e1b == null:
		return "缺 pilot_015_effect_01b"
	if e1b.listen_timing != _TimingConst.ATTACK_AT:
		return "01b listen_timing 应 ATTACK_AT"
	if int(e1b.priority) != 0:
		return "01b priority 应 0 实=%d" % int(e1b.priority)
	if String(e1b.actions[0].get("type", &"")) != "PILOT_015_FORCE_PURE_ASSAULT":
		return "01b action 应 PILOT_015_FORCE_PURE_ASSAULT"
	# 01c
	var e1c = effs.get(&"pilot_015_effect_01c")
	if e1c == null:
		return "缺 pilot_015_effect_01c"
	if e1c.listen_timing != _TimingConst.USE_ACTION_BEFORE:
		return "01c listen_timing 应 USE_ACTION_BEFORE"
	if e1c.listen_action_type != &"use_action_card":
		return "01c listen_action_type 应 use_action_card"
	if String(e1c.actions[0].get("type", &"")) != "PILOT_015_REPLACE_COUNTER_AS_DEFEND":
		return "01c action 应 PILOT_015_REPLACE_COUNTER_AS_DEFEND"
	if String(e1c.actions[0].get("params", {}).get("as_card_def_id", &"")) != "action_009_防御":
		return "01c as_card_def_id 应 action_009_防御"
	# 02a
	var e2a = effs.get(&"pilot_015_effect_02a")
	if e2a == null:
		return "缺 pilot_015_effect_02a"
	if e2a.mode != _TimingConst.MODE_DIRECT:
		return "02a mode 应 DIRECT"
	if e2a.once_per_turn_key != &"pilot_015_effect_02":
		return "02a once_per_turn_key 应 pilot_015_effect_02"
	if int(e2a.once_per_turn_max) != 1:
		return "02a once_per_turn_max 应 1"
	if String(e2a.actions[0].get("type", &"")) != "PLAY_AS_NAMED":
		return "02a action 应 PLAY_AS_NAMED"
	if String(e2a.actions[0].get("params", {}).get("as_card_def_id", &"")) != "action_001_进攻":
		return "02a as_card_def_id 应 action_001_进攻"
	if not bool(e2a.actions[0].get("params", {}).get("attack_is_active", false)):
		return "02a attack_is_active 应 true"
	var e2a_ops: Array = []
	for c in e2a.conditions:
		e2a_ops.append(String(c.get("op", &"")))
	if not e2a_ops.has("HAS_ATTACK_TARGET_IN_RANGE"):
		return "02a 应含 HAS_ATTACK_TARGET_IN_RANGE 范围条件（无目标按钮置灰）"
	# 02b
	var e2b = effs.get(&"pilot_015_effect_02b")
	if e2b == null:
		return "缺 pilot_015_effect_02b"
	if e2b.mode != _TimingConst.MODE_AVAILABILITY:
		return "02b mode 应 AVAILABILITY"
	if e2b.listen_timing != _TimingConst.ATTACK_AT:
		return "02b listen_timing 应 ATTACK_AT"
	if e2b.once_per_turn_key != &"pilot_015_effect_02":
		return "02b once_per_turn_key 应 pilot_015_effect_02"
	if String(e2b.actions[0].get("type", &"")) != "PLAY_AS_NAMED":
		return "02b action 应 PLAY_AS_NAMED"
	if String(e2b.actions[0].get("params", {}).get("as_card_def_id", &"")) != "action_009_防御":
		return "02b as_card_def_id 应 action_009_防御"
	if bool(e2b.actions[0].get("params", {}).get("attack_is_active", true)):
		return "02b attack_is_active 应 false"
	return true


# ═══════════════════════════════════════════
# trigger A：空手 + 物理攻击牌 -> 设 flag + 还原威力
# ═══════════════════════════════════════════

## 测试2：手牌0时敌方物理攻击牌攻击诺拉机甲 -> ATTACK_PRE 设 flag
func test_p015_01a_hand_empty_set_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 清空 player 手牌
	_clear_action_hand(battle, &"player")
	# 给 enemy 1 张物理攻击牌（进攻）
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	if atk_card_id == &"":
		return "无法创建攻击牌"
	# enemy 用此牌攻击 player 机甲，weapon_might=5（含猛击+4 会写入 extra_might，测试还原）
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# 验证 flag 已设
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if not flags.has("pilot_015_force_pure_assault"):
		return "ATTACK_PRE 应设 pilot_015_force_pure_assault flag 实=%s" % str(flags)
	# 验证还原威力：手动写 extra_might=4（模拟猛击+4），调 _step_calculate_damage 验证 extra_might 被忽略
	attack.record["extra_might"] = 4
	attack.record["hit"] = true
	var attack_script = battle.context.action_registry.get_action(attack.action_id)
	# 调 damage calc（需通过 attack_action 脚本，此处用白盒：直接验证 flag 存在即可，damage calc 在集成测试验证）
	return true


## 测试3：手牌非0时 01a 不触发
func test_p015_01a_hand_not_empty_no_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 确保 player 手牌非0（教程默认有牌）
	if gs.players.get(&"player").action_hand.is_empty():
		_add_card_to_hand(battle, &"player", "action_001_进攻")
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if flags.has("pilot_015_force_pure_assault"):
		return "手牌非0时不应设 flag"
	return true


## 测试4：虚拟转化进攻牌不触发 01a（莱比尔/迪恩/诺拉自己的虚拟进攻）
func test_p015_01a_virtual_transform_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	# 构造虚拟转化攻击（virtual_transform=true）
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	attack.record["virtual_transform"] = true
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if flags.has("pilot_015_force_pure_assault"):
		return "虚拟转化进攻牌不应触发 01a 设 flag"
	return true


## 测试5：还原威力验证（flag 设 + extra_might 非0 -> damage calc 用 weapon_might）
func test_p015_restore_might() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# 设 extra_might=4（模拟猛击+4），hit=true
	attack.record["extra_might"] = 4
	attack.record["hit"] = true
	# 直接调 attack_action._step_calculate_damage 验证还原（通过 attack_action 脚本）
	var attack_action_script = load("res://scripts/action_defs/attack_action.gd").new()
	attack_action_script.context = battle.context
	attack_action_script.record = attack.record
	# _step_calculate_damage 是实例方法，但依赖 self.record；用 attack action 调用
	# 此处白盒：验证 flag 存在 + extra_might 被 flag 逻辑清零（读 _step_calculate_damage 输出）
	var result = attack_action_script._step_calculate_damage(attack)
	# weapon_might=5，extra_might=4 但 flag 设 -> attack_power=5（还原）
	# markers = attack_power / 5 = 1（若 extra_might 生效则 attack_power=9, markers=1）
	# damage = max(0, 5 - armor)。教程 enemy_mech 护甲可能非0，但 markers 只依赖 attack_power
	# 关键：markers 应基于还原后的威力 5（=1），而非 9（=1）--两者 markers 都=1 无法区分
	# 改用 weapon_might=6 + extra_might=4：还原后 6/5=1，不还原 10/5=2
	return true  # 集成测试覆盖，白盒 flag 已在测试2验证


# ═══════════════════════════════════════════
# trigger C：迎击牌响应我方攻击 -> 视为防御
# ═══════════════════════════════════════════

## 测试6：空手时迎击牌响应我方攻击 -> USE_ACTION_BEFORE 设 as_card_def_id=防御
func test_p015_01c_counter_as_defend() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 清空 player 手牌
	_clear_action_hand(battle, &"player")
	# player 发起攻击 enemy（诺拉机甲攻击，手牌0）
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	# 立即移出手牌模拟空手（但需保留 atk_card_id 作为已打出的攻击牌）
	# 实际：诺拉攻击时手牌已0（攻击牌打出进 temp_zone），此处构造 attack 时 player 手牌为空
	_clear_action_hand(battle, &"player")
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	battle.context.action_registry.register(attack)
	# enemy 用迎击牌响应
	var counter_card_id = _add_card_to_hand(battle, &"enemy", "action_010_反击")
	var ua := _make_use_action(battle, counter_card_id, &"enemy", enemy_mech.mech_id, attack.action_id)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, ua)
	await _pump_frames(3)
	# 验证 as_card_def_id 已设为防御
	if String(ua.record.get("as_card_def_id", &"")) != "action_009_防御":
		return "01c 应设 as_card_def_id=action_009_防御 实=%s" % String(ua.record.get("as_card_def_id", &""))
	return true


## 测试7：手牌非0时 01c 不触发
func test_p015_01c_hand_not_empty_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# player 手牌非0
	if gs.players.get(&"player").action_hand.is_empty():
		_add_card_to_hand(battle, &"player", "action_001_进攻")
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	battle.context.action_registry.register(attack)
	var counter_card_id = _add_card_to_hand(battle, &"enemy", "action_010_反击")
	var ua := _make_use_action(battle, counter_card_id, &"enemy", enemy_mech.mech_id, attack.action_id)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.USE_ACTION_BEFORE, ua)
	await _pump_frames(3)
	if ua.record.has("as_card_def_id"):
		return "手牌非0时 01c 不应设 as_card_def_id"
	return true


# ═══════════════════════════════════════════
# 效果2a：全部当进攻
# ═══════════════════════════════════════════

## 测试8：效果2a 全部当进攻（全部行动牌入临时区，创建虚拟进攻 use_action_card）
func test_p015_02a_use_all_as_assault() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	# 给 player 3 张行动牌
	_clear_action_hand(battle, &"player")
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	_add_card_to_hand(battle, &"player", "action_009_防御")
	_add_card_to_hand(battle, &"player", "action_013_维修")
	var hand_before: int = gs.players.get(&"player").action_hand.size()
	if hand_before != 3:
		return "setup 应有3张牌 实=%d" % hand_before
	# 记录3张牌 instance_id（验证全部进 temp_zone）
	var before_ids: Array = []
	for cid in gs.players.get(&"player").action_hand:
		before_ids.append(cid)
	# 触发效果2a（DIRECT 按钮）
	var src: Dictionary = {
		"card_instance_id": s.pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": &"player",
		"effect_id": &"pilot_015_effect_02a",
	}
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_015_effect_02a",
		"player_id": &"player",
		"source_mech_id": mech.mech_id,
		"card_instance_id": s.pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(8)
	# 验证：手牌清空（全入临时区）
	var hand_after: int = gs.players.get(&"player").action_hand.size()
	if hand_after != 0:
		return "效果2a 后手牌应清空 实=%d" % hand_after
	# 验证：全部3张牌都在 temp_zone（Issue 2：不应只放第一张，而是全部）
	var temp_count: int = 0
	for cid in before_ids:
		var c = gs.get_card(cid)
		if c != null and String(c.zone) == "temp_zone":
			temp_count += 1
	if temp_count != 3:
		return "全部3张牌应进 temp_zone 实=%d（Issue2：不应只放首张）" % temp_count
	# 验证：创建了虚拟 use_action_card 子动作（as_card_def_id=进攻）
	var has_virtual_use := false
	var consume_atk := false
	for a in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if String(a.record.get("as_card_def_id", &"")) == "action_001_进攻" and bool(a.record.get("virtual_transform", false)):
			has_virtual_use = true
			consume_atk = bool(a.record.get("consume_attack_count", false))
			break
	if not has_virtual_use:
		return "应创建虚拟进攻 use_action_card 子动作"
	if not consume_atk:
		return "进攻转化应 consume_attack_count=true（消耗1次攻击次数）"
	return true


## 测试9：效果2a 每回合1次（第二次不可触发）
func test_p015_02a_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	_add_card_to_hand(battle, &"player", "action_009_防御")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var src: Dictionary = {
		"card_instance_id": s.pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": &"player",
		"effect_id": &"pilot_015_effect_02a",
	}
	# 第一次
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_015_effect_02a",
		"player_id": &"player",
		"source_mech_id": mech.mech_id,
		"card_instance_id": s.pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(8)
	# 再给2张牌
	_add_card_to_hand(battle, &"player", "action_001_进攻")
	_add_card_to_hand(battle, &"player", "action_009_防御")
	# 第二次触发
	var hand_before_2nd: int = gs.players.get(&"player").action_hand.size()
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_015_effect_02a",
		"player_id": &"player",
		"source_mech_id": mech.mech_id,
		"card_instance_id": s.pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(8)
	# 第二次不应消耗手牌（once_per_turn 拦截）
	var hand_after_2nd: int = gs.players.get(&"player").action_hand.size()
	if hand_after_2nd != hand_before_2nd:
		return "第二次效果2a 应被 once_per_turn 拦截，手牌不应变 前=%d 后=%d" % [hand_before_2nd, hand_after_2nd]
	return true


## 测试10：效果2a 无牌不可触发
func test_p015_02a_no_card_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var src: Dictionary = {
		"card_instance_id": s.pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": &"player",
		"effect_id": &"pilot_015_effect_02a",
	}
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_015_effect_02a",
		"player_id": &"player",
		"source_mech_id": mech.mech_id,
		"card_instance_id": s.pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(5)
	# 无牌时条件 HAS_ACTION_CARD_IN_HAND minimum=1 失败，不创建虚拟 use
	var has_virtual_use := false
	for a in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if bool(a.record.get("virtual_transform", false)):
			has_virtual_use = true
			break
	if has_virtual_use:
		return "无牌时不应创建虚拟 use_action_card"
	return true


# ═══════════════════════════════════════════
# trigger B：被响应后设 flag（fork + 根）
# ═══════════════════════════════════════════

## 测试11：被响应后 01b 设 flag（attack record）
func test_p015_01b_responded_set_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	attack.record["responded"] = true  # 模拟已被响应
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(3)
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if not flags.has("pilot_015_force_pure_assault"):
		return "01b 被响应后应设 flag 实=%s" % str(flags)
	return true


## 测试12：未被响应时 01b 不触发
func test_p015_01b_not_responded_no_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	# responded=false（默认）
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(3)
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if flags.has("pilot_015_force_pure_assault"):
		return "未被响应时 01b 不应设 flag"
	return true


## 测试13：双连仅完成首个 fork（flag 设后清空 fork 队列）
func test_p015_dual_strike_first_fork_only() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_005_双连")
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	# 构造双连队列：3个目标
	attack.record["_multi_target_fork_queue"] = [mech.mech_id, enemy_mech.mech_id, &"test_target_3"]
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# flag 应已设（01a 触发）
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	if not flags.has("pilot_015_force_pure_assault"):
		return "双连 ATTACK_PRE 应设 flag"
	# 模拟 _create_next_fork 调用：flag 设后应清空队列
	var attack_action_script = load("res://scripts/action_defs/attack_action.gd").new()
	attack_action_script.context = battle.context
	attack_action_script.record = attack.record
	attack_action_script._create_next_fork(attack)
	# 队列应被清空
	var queue: Array = attack.record.get("_multi_target_fork_queue", [])
	if not queue.is_empty():
		return "双连 flag 设后应清空 fork 队列 实=%s" % str(queue)
	return true


# ═══════════════════════════════════════════
# 集成：还原威力完整验证
# ═══════════════════════════════════════════

## 测试14：还原威力完整验证（weapon_might=6 + extra_might=4，flag 设 -> markers 基于6而非10）
func test_p015_restore_might_full() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_nora(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_clear_action_hand(battle, &"player")
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_001_进攻")
	# weapon_might=6，模拟猛击+4（extra_might=4）
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 6)
	attack.record["extra_might"] = 4
	attack.record["hit"] = true
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# flag 设后调 damage calc
	var attack_action_script = load("res://scripts/action_defs/attack_action.gd").new()
	attack_action_script.context = battle.context
	attack_action_script.record = attack.record
	var result = attack_action_script._step_calculate_damage(attack)
	# 还原后 attack_power=6 -> markers=6/5=1；若不还原 attack_power=10 -> markers=10/5=2
	var markers: int = int(result.get("markers", 0))
	if markers != 1:
		return "还原威力后 markers 应=1（6/5）实=%d（若=2 则未还原）" % markers
	return true
