## test_pilot_017_volt.gd - 伏特（pilot_017）效果测试
##
## 2 按钮：
##   按钮1=效果1（主动 DIRECT，每玩家回合1次）：选2张行动牌入 temp_zone，
##     CHOOSE_ONE 三选一当作 强袭/猛击/破甲 之一使用（复用 PILOT_015_USE_ALL_AS_NAMED，
##     attack_is_active=true 消耗1次攻击次数，链末 DISCARD_TEMP_ZONE_CARDS 入弃牌堆）。
##   按钮2=效果2a（被动 LISTEN 置灰，描述含猛击/破甲/强袭3段）：
##     02a ATTACK_BEFORE 猛击+3威（MODIFY_ATTACK_MIGHT，被诺拉纯进攻清 extra_might 自动排除）；
##     02b ATTACK_AFTER 命中 破甲+2损（MODIFY_ATTACK_MARKERS，显式 ATTACK_RECORD_FLAG_NOT_SET 排除诺拉）；
##     02c ATTACK_SETTLE 强袭回4动（RESTORE_POWER，显式 ATTACK_RECORD_FLAG_NOT_SET 排除诺拉）。
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
	battle.rng_seed = 90017
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
	attack.action_id = &"test_p017_%d" % [randi() % 1000000]
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


func _add_card_to_hand(battle, pid: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, pid)
	if card == null:
		return &""
	card.zone = &"hand"
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


## 设伏特机师到 owner 机甲，返回 {gs, mech, pilot_card}
func _setup_volt(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var pilot_card = _set_pilot_on_mech(battle, owner_id, mech, "pilot_017_伏特")
	if pilot_card == null:
		return {}
	return {"gs": gs, "mech": mech, "pilot_card": pilot_card}


# ═══════════════════════════════════════════
# 白盒：效果定义
# ═══════════════════════════════════════════

## 测试1：效果定义正确
func test_p017_definitions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var effs = _ActionPilotEffects.build_pilot_effects()
	# effect_01
	var e1 = effs.get(&"pilot_017_effect_01")
	if e1 == null:
		return "缺 pilot_017_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 DIRECT 实=%s" % String(e1.mode)
	if e1.once_per_turn_key != &"pilot_017_effect_01":
		return "effect_01 once_per_turn_key 应 pilot_017_effect_01"
	if e1.once_per_turn_max != 1:
		return "effect_01 once_per_turn_max 应 1"
	# CHOOSE_ONE 三选一（optional=true 可取消=不发动，无消耗）
	var act0 = e1.actions[0]
	if String(act0.get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 action[0] 应 CHOOSE_ONE"
	if not bool(act0.get("params", {}).get("optional", false)):
		return "effect_01 CHOOSE_ONE 应 optional=true（可取消不消耗）"
	var opts = act0.get("params", {}).get("options", [])
	if opts.size() != 3:
		return "CHOOSE_ONE 应3选项 实=%d" % opts.size()
	# 各分支：CHOOSE_MANY_CARDS(选2张燃料) + MOVE_ACTION_CARDS_TO_TEMP_ZONE +
	#   PLAY_AS_NAMED(as=强袭/猛击/破甲, attack_is_active=true) + DISCARD_TEMP_ZONE_CARDS
	var as_ids = ["action_002_强袭", "action_003_猛击", "action_004_破甲"]
	for i in 3:
		var br = opts[i].get("actions", [])
		if br.is_empty():
			return "分支%d actions 不应为空" % i
		if String(br[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
			return "分支%d action[0] 应 CHOOSE_MANY_CARDS" % i
		var cm = br[0].get("params", {})
		if int(cm.get("min_count", 0)) != 2 or int(cm.get("max_count", 0)) != 2:
			return "分支%d CHOOSE_MANY_CARDS 应 min=max=2 实=%d/%d" % [i, int(cm.get("min_count", 0)), int(cm.get("max_count", 0))]
		if String(cm.get("source", &"")) != "OWNER_ACTION_HAND":
			return "分支%d CHOOSE_MANY_CARDS source 应 OWNER_ACTION_HAND" % i
		if String(br[1].get("type", &"")) != "MOVE_ACTION_CARDS_TO_TEMP_ZONE":
			return "分支%d action[1] 应 MOVE_ACTION_CARDS_TO_TEMP_ZONE" % i
		var found := false
		for a in br:
			if String(a.get("type", &"")) == "PLAY_AS_NAMED":
				if String(a.get("params", {}).get("as_card_def_id", &"")) != as_ids[i]:
					return "分支%d as_card_def_id 应 %s 实=%s" % [i, as_ids[i], String(a.get("params", {}).get("as_card_def_id", &""))]
				if not bool(a.get("params", {}).get("attack_is_active", false)):
					return "分支%d attack_is_active 应 true" % i
				found = true
		if not found:
			return "分支%d 应含 PLAY_AS_NAMED" % i
		if String(br[br.size() - 1].get("type", &"")) != "DISCARD_TEMP_ZONE_CARDS":
			return "分支%d 末尾应 DISCARD_TEMP_ZONE_CARDS" % i
	# 条件应含 HAS_ATTACK_TARGET_IN_RANGE（无目标按钮置灰）+ ATTACK_COUNT_ABOVE
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	if not e1_ops.has("HAS_ATTACK_TARGET_IN_RANGE"):
		return "effect_01 应含 HAS_ATTACK_TARGET_IN_RANGE"
	if not e1_ops.has("ATTACK_COUNT_ABOVE"):
		return "effect_01 应含 ATTACK_COUNT_ABOVE"
	if not e1.costs.is_empty():
		return "effect_01 应无 cost（布鲁克式选牌动作流程，选牌可取消不消耗）"
	# effect_02a 猛击+3威
	var e2a = effs.get(&"pilot_017_effect_02a")
	if e2a == null:
		return "缺 pilot_017_effect_02a"
	if e2a.mode != _TimingConst.MODE_LISTEN:
		return "02a mode 应 LISTEN"
	if e2a.listen_timing != _TimingConst.ATTACK_BEFORE:
		return "02a listen_timing 应 ATTACK_BEFORE"
	if int(e2a.actions[0].get("params", {}).get("delta", 0)) != 3:
		return "02a delta 应 3"
	# effect_02b 破甲+2损
	var e2b = effs.get(&"pilot_017_effect_02b")
	if e2b == null:
		return "缺 pilot_017_effect_02b"
	if e2b.listen_timing != _TimingConst.ATTACK_AFTER:
		return "02b listen_timing 应 ATTACK_AFTER"
	if int(e2b.actions[0].get("params", {}).get("delta", 0)) != 2:
		return "02b delta 应 2"
	# effect_02c 强袭回4动
	var e2c = effs.get(&"pilot_017_effect_02c")
	if e2c == null:
		return "缺 pilot_017_effect_02c"
	if e2c.listen_timing != _TimingConst.ATTACK_SETTLE:
		return "02c listen_timing 应 ATTACK_SETTLE"
	if int(e2c.actions[0].get("params", {}).get("amount", 0)) != 4:
		return "02c amount 应 4"
	return true


# ═══════════════════════════════════════════
# 效果2a：猛击+3威
# ═══════════════════════════════════════════

## 测试2：伏特用实体猛击牌攻击 -> ATTACK_BEFORE extra_might+3
func test_p017_02a_smash_might_plus3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_003_猛击")
	if atk_card_id == &"":
		return "无法创建猛击牌"
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_BEFORE, attack)
	await _pump_frames(5)
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != 3:
		return "猛击+3威 extra_might 应 3 实=%d" % extra_might
	return true


## 测试3：非猛击牌（进攻）不触发 02a
func test_p017_02a_non_smash_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_BEFORE, attack)
	await _pump_frames(5)
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != 0:
		return "非猛击牌不应触发02a extra_might 实=%d" % extra_might
	return true


## 测试4：转化虚拟猛击牌（virtual_as_def_id=猛击）触发 02a
func test_p017_02a_virtual_smash_identified() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 创建1张进攻牌，标注 virtual_as_def_id=猛击（模拟效果1转化后的虚拟牌）
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var atk_card = gs.get_card(atk_card_id)
	if atk_card == null:
		return "无法创建攻击牌"
	atk_card.counters["virtual_as_def_id"] = &"action_003_猛击"
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_BEFORE, attack)
	await _pump_frames(5)
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != 3:
		return "转化虚拟猛击牌应触发02a extra_might 应 3 实=%d" % extra_might
	return true


## 测试5：非伏特攻击（enemy 用猛击牌攻击伏特）不触发 02a（SELF_MECH_IS_ATTACKER）
func test_p017_02a_not_self_attacker_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# enemy 用猛击牌攻击 player（伏特是 target，非 attacker）
	var atk_card_id = _add_card_to_hand(battle, &"enemy", "action_003_猛击")
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, &"enemy", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_BEFORE, attack)
	await _pump_frames(5)
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != 0:
		return "非伏特攻击不应触发02a extra_might 实=%d" % extra_might
	return true


# ═══════════════════════════════════════════
# 效果2b：破甲命中+2损
# ═══════════════════════════════════════════

## 测试6：伏特用实体破甲牌命中 -> ATTACK_AFTER extra_markers+2
func test_p017_02b_armor_break_markers_plus2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_004_破甲")
	if atk_card_id == &"":
		return "无法创建破甲牌"
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	attack.record["hit"] = true  # 命中
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	var extra_markers: int = int(attack.record.get("extra_markers", 0))
	if extra_markers != 2:
		return "破甲命中+2损 extra_markers 应 2 实=%d" % extra_markers
	return true


## 测试7：破甲未命中不触发 02b
func test_p017_02b_miss_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_004_破甲")
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	attack.record["hit"] = false  # 未命中
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	var extra_markers: int = int(attack.record.get("extra_markers", 0))
	if extra_markers != 0:
		return "破甲未命中不应触发02b extra_markers 实=%d" % extra_markers
	return true


## 测试8：诺拉纯进攻 flag 时 02b 不触发（ATTACK_RECORD_FLAG_NOT_SET）
func test_p017_02b_nora_flag_excludes() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_004_破甲")
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	attack.record["hit"] = true
	# 设诺拉纯进攻 flag
	attack.record["_effect_flags"] = {"pilot_015_force_pure_assault": {"value": true}}
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	var extra_markers: int = int(attack.record.get("extra_markers", 0))
	if extra_markers != 0:
		return "诺拉flag时破甲+2损不应触发 extra_markers 实=%d" % extra_markers
	return true


# ═══════════════════════════════════════════
# 效果2c：强袭回4动
# ═══════════════════════════════════════════

## 测试9：伏特用实体强袭牌攻击结算后 -> 回4动力
func test_p017_02c_assault_restore_power() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 设 power 较低，便于验证 +4
	mech.power = 2
	mech.max_power = 10
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_002_强袭")
	if atk_card_id == &"":
		return "无法创建强袭牌"
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(6)
	if mech.power != 6:
		return "强袭回4动 power 应 6（2+4）实=%d" % mech.power
	return true


## 测试10：诺拉纯进攻 flag 时 02c 不触发
func test_p017_02c_nora_flag_excludes() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	mech.power = 2
	mech.max_power = 10
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_002_强袭")
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	attack.record["_effect_flags"] = {"pilot_015_force_pure_assault": {"value": true}}
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(6)
	if mech.power != 2:
		return "诺拉flag时强袭回4动不应触发 power 应 2 实=%d" % mech.power
	return true


## 测试11：非强袭牌不触发 02c
func test_p017_02c_non_assault_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_volt(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	mech.power = 2
	mech.max_power = 10
	var atk_card_id = _add_card_to_hand(battle, &"player", "action_001_进攻")
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", atk_card_id, 5)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(6)
	if mech.power != 2:
		return "非强袭牌不应触发02c power 应 2 实=%d" % mech.power
	return true
