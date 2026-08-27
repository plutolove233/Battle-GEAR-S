## test_pilot_053_yalin.gd - 亚林（pilot_053，秩序 R）效果测试
##
## 亚林 1 个被动按钮（双时点 LISTEN，描述合并到按钮1）：
##   effect_01（显示按钮1）监听 SET_EQUIP_AT（我方区域正面设置装备牌）
##   effect_01b（hide_button 合并描述）监听 DISCARD_AFTER（我方机甲正面装备被弃置，
##     含敌方回合损伤损坏弃置）
##   每回合2次共享额度：确认发动才计次（MARK_EFFECT_ONCE_PER_TURN_USED），取消不计。
##   发动效果：抽2张行动牌 + 行动牌上限+1（立即生效、下个我方回合开始到期清除）。
##
## 通用机制（后续可复用，纯通用组件组装）：
##   · 双监听共享额度：EFFECT_ONCE_PER_TURN_AVAILABLE(key,max2) 条件 + 发动分支显式
##     MARK_EFFECT_ONCE_PER_TURN_USED；effect 级不设 once_per_turn_key（避免取消分支
##     auto-mark 误计次）
##   · CHOOSE_ONE optional:true 确认弹窗（可取消不计次）
##   · 两个通用来源条件：SET_EQUIP_INCLUDES_OWNER_FACE_UP（设置触发）/
##     DISCARD_INCLUDES_OWNER_FACE_UP_EQUIPMENT（弃置触发）
##   · APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS（行动牌上限+1 立即生效、下个我方回合
##     开始到期清除，可叠加，平行布鲁克攻击数机制）
##
## 关键覆盖点：
##   1. 双效果定义正确（LISTEN 时点/条件/共享额度 key/无 effect 级 key/动作链）。
##   2. 设置触发 -> 确认 -> 抽2行动 + 行动牌上限+1。
##   3. 设置触发 -> 取消 -> 不抽不计数，可再触发。
##   4. 弃置触发（真实 discard_card 弃我方机甲正面装备）-> 确认 -> 抽2 + 上限+1。
##   5. 每回合2次用满 -> 第3次触发被跳过。
##   6. 下个我方回合开始 -> 上限加成到期清除 + 额度重置（可再次触发）。
##   7. PVP3 多人类玩家通用：third 玩家触发按玩家隔离（抽牌只动 third 的）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90053
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


## 设亚林为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, player}
func _setup_yalin(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_053_亚林", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb, "player": gs.players.get(owner_id)}


## 创建独立玩家 third + 机甲（PVP3 多人），返回机甲；null 失败
func _create_third_player(battle) -> _MechState:
	var gs = battle.context.game_state
	var p = _PlayerState.new()
	p.player_id = &"third"
	p.gold = 15
	p.is_human = true
	gs.players[&"third"] = p
	var m := _MechState.new()
	m.mech_id = &"third_mech"
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = {"q": 6, "r": 2}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿", &"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2", &"event", &"pilot"]:
		var sl := _MechSlotState.new()
		sl.slot_id = slot_id
		sl.slot_kind = &"PART"
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m
	return m


## 把一张装备牌放进 owner 的装备手牌，返回实例 id
func _put_equip_in_hand(battle, pid: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"equipment_hand"
	gs.players.get(pid).equipment_hand.append(card.instance_id)
	return card.instance_id


## 走真实 set_equipment 动作给 mech 的 slot 设置装备（fire SET_EQUIP_AT 触发亚林 e1）。
## 返回挂起的 set_equipment action（waiting_timing）；无挂起返回 null。
func _fire_set_equipment(battle, mech, pid: StringName, equip_id: StringName, slot_id: StringName):
	battle.context.game_state.active_player_id = pid
	battle.context.action_service.execute(&"set_equipment", {
		"card_id": equip_id,
		"mech_id": mech.mech_id,
		"slot_id": slot_id,
		"player_id": pid,
		"source": {"player_id": pid, "mech_id": mech.mech_id},
	})
	await _pump_frames(8)
	for a in battle.context.action_registry.get_actions_by_type(&"set_equipment"):
		if a.state == &"waiting_timing":
			return a
	return null


## resume CHOOSE_ONE 确认（chosen_option_index 0=发动 1=取消）
func _resume_choose(battle, act, option_index: int) -> void:
	battle.context.timing_engine.resume_pending_effect(act.action_id, {"chosen_option_index": option_index})
	await _pump_frames(12)


## 把装备直接手动放到 mech 槽上（正面朝上，模拟已设置的区域装备），供弃置触发用
func _mount_equip_face_up(battle, mech, pid: StringName, def_id: String, slot_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var equip = _make_instance(gs, battle.context.card_database, def_id, pid)
	if equip == null:
		return &""
	equip.zone = &"equipment_slot"
	equip.mech_id = mech.mech_id
	equip.slot_id = slot_id
	equip.face_down = false
	mech.slots.get(slot_id).equipped_card = equip
	return equip.instance_id


## 走真实 discard_card 动作弃置指定牌（fire DISCARD_AFTER 触发亚林 e1b）。
## 返回挂起的 discard_card action（waiting_timing）；无挂起返回 null。
func _fire_discard(battle, pid: StringName, card_ids: Array):
	battle.context.game_state.active_player_id = pid
	battle.context.action_service.execute(&"discard_card", {
		"card_ids": card_ids,
		"player_id": pid,
		"executor": &"system_default",
		"reason": &"pilot_053_test",
		"source": {"player_id": String(pid)},
	})
	await _pump_frames(8)
	for a in battle.context.action_registry.get_actions_by_type(&"discard_card"):
		if a.state == &"waiting_timing":
			return a
	return null


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


func _hand_limit(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_card_limit


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：双效果定义正确（LISTEN 时点/条件/共享额度/动作链/无 effect 级 key）
func test_pilot_053_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	# effect_01：设置触发（显示按钮1）
	var e1 = effects.get(&"pilot_053_effect_01")
	if e1 == null:
		return "缺 pilot_053_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.SET_EQUIP_AT:
		return "effect_01 应监听 SET_EQUIP_AT 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "set_equipment":
		return "effect_01 listen_action_type 应 set_equipment"
	if e1.hide_button:
		return "effect_01 应是显示按钮（1显示按钮模式）"
	if e1.once_per_turn_key != &"":
		return "effect_01 不应设 effect 级 once_per_turn_key（走显式 MARK 计次）"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["SET_EQUIP_INCLUDES_OWNER_FACE_UP", "EFFECT_ONCE_PER_TURN_AVAILABLE"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	for c in e1.conditions:
		if String(c.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			var c_p = c.get("params", {})
			if String(c_p.get("once_per_turn_key", &"")) != "pilot_053_effect_01" or int(c_p.get("once_per_turn_max", 0)) != 2:
				return "effect_01 额度应为 pilot_053_effect_01 max=2（每回合2次）"
	var e1_acts = e1.actions
	if e1_acts.size() != 1 or String(e1_acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 动作0 应 CHOOSE_ONE（确认弹窗）"
	var co_params = e1_acts[0].get("params", {})
	if not bool(co_params.get("optional", false)):
		return "effect_01 CHOOSE_ONE 应 optional=true（可取消不计次）"
	var opts: Array = co_params.get("options", [])
	if opts.size() != 2:
		return "effect_01 应2个分支 实=%d" % opts.size()
	var opt0_types: Array = []
	for a in opts[0].get("actions", []):
		opt0_types.append(String(a.get("type", &"")))
	if opt0_types != ["MARK_EFFECT_ONCE_PER_TURN_USED", "EXECUTE_GAIN_CARD", "APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS"]:
		return "effect_01 发动分支动作应为 [MARK, EXECUTE_GAIN_CARD, APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS] 实=%s" % str(opt0_types)
	var mark_params: Dictionary = opts[0].get("actions", [])[0].get("params", {})
	if String(mark_params.get("once_per_turn_key", &"")) != "pilot_053_effect_01":
		return "effect_01 MARK 额度 key 应 pilot_053_effect_01"
	var eg_p: Dictionary = opts[0].get("actions", [])[1].get("params", {})
	if String(eg_p.get("from_zone", &"")) != "action_deck" or String(eg_p.get("card_kind", &"")) != "action" or int(eg_p.get("count", 0)) != 2:
		return "effect_01 应抽2张行动牌(action_deck)"
	var bn_p: Dictionary = opts[0].get("actions", [])[2].get("params", {})
	if int(bn_p.get("stacks", 0)) != 1:
		return "effect_01 行动牌上限加成应为 stacks=1"
	if String(opts[1].get("label", &"")) != "取消" or opts[1].get("actions", []) != []:
		return "effect_01 取消分支应为空（不计次）"

	# effect_01b：弃置触发（隐藏，描述合并到按钮1）
	var e1b = effects.get(&"pilot_053_effect_01b")
	if e1b == null:
		return "缺 pilot_053_effect_01b"
	if e1b.mode != _TimingConst.MODE_LISTEN:
		return "effect_01b mode 应 MODE_LISTEN"
	if e1b.listen_timing != _TimingConst.DISCARD_AFTER:
		return "effect_01b 应监听 DISCARD_AFTER 实=%s" % String(e1b.listen_timing)
	if String(e1b.listen_action_type) != "discard_card":
		return "effect_01b listen_action_type 应 discard_card"
	if not e1b.hide_button:
		return "effect_01b 应 hide_button（合并到按钮1）"
	if int(e1b.merge_desc_into_index) != 1:
		return "effect_01b merge_desc_into_index 应 1（并入 effect_01 按钮）"
	var e1b_ops: Array = []
	for c in e1b.conditions:
		e1b_ops.append(String(c.get("op", &"")))
	for need in ["DISCARD_INCLUDES_OWNER_FACE_UP_EQUIPMENT", "EFFECT_ONCE_PER_TURN_AVAILABLE"]:
		if not e1b_ops.has(need):
			return "effect_01b 应含条件 %s" % need
	for c in e1b.conditions:
		if String(c.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			var cb_p = c.get("params", {})
			if String(cb_p.get("once_per_turn_key", &"")) != "pilot_053_effect_01" or int(cb_p.get("once_per_turn_max", 0)) != 2:
				return "effect_01b 额度 key/max 应与 effect_01 相同（共享每回合2次）"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：设置触发 -> 确认 -> 抽2行动 + 行动牌上限+1
func test_pilot_053_set_equip_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yalin(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var head_id: StringName = _put_equip_in_hand(battle, &"player", "part_001_量产装_头部")
	if head_id == &"":
		return "头部装备设置失败"
	var hand_before: int = _action_hand_size(battle, &"player")
	var limit_before: int = _hand_limit(battle, &"player")
	var set_action = await _fire_set_equipment(battle, s.mech, &"player", head_id, &"头部")
	if set_action == null:
		return "set_equipment 未挂起（亚林 e1 应弹 CHOOSE_ONE 确认）"
	# 确认发动 -> 抽2 + 上限+1
	await _resume_choose(battle, set_action, 0)
	if _action_hand_size(battle, &"player") != hand_before + 2:
		return "确认后行动手牌应+2 实变=%d" % (_action_hand_size(battle, &"player") - hand_before)
	if _hand_limit(battle, &"player") != limit_before + 1:
		return "确认后行动牌上限应+1（%d -> %d）" % [limit_before, _hand_limit(battle, &"player")]
	return true


## 测试3：设置触发 -> 取消 -> 不抽不计数，可再触发
func test_pilot_053_set_equip_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yalin(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var head_id: StringName = _put_equip_in_hand(battle, &"player", "part_001_量产装_头部")
	if head_id == &"":
		return "头部装备设置失败"
	var hand_before: int = _action_hand_size(battle, &"player")
	var limit_before: int = _hand_limit(battle, &"player")
	var set_action = await _fire_set_equipment(battle, s.mech, &"player", head_id, &"头部")
	if set_action == null:
		return "set_equipment 未挂起"
	# 取消 -> 不抽不计数
	await _resume_choose(battle, set_action, 1)
	if _action_hand_size(battle, &"player") != hand_before:
		return "取消不应抽牌"
	if _hand_limit(battle, &"player") != limit_before:
		return "取消不应改行动牌上限"
	# 次数未消耗：再设置另一张装备 -> 仍触发
	var torso_id: StringName = _put_equip_in_hand(battle, &"player", "part_002_量产装_躯干")
	if torso_id == &"":
		return "躯干装备设置失败"
	var set_action2 = await _fire_set_equipment(battle, s.mech, &"player", torso_id, &"躯干")
	if set_action2 == null:
		return "取消后应可再触发（次数未消耗）"
	await _resume_choose(battle, set_action2, 0)
	if _action_hand_size(battle, &"player") != hand_before + 2:
		return "再次确认后行动手牌应+2 实变=%d" % (_action_hand_size(battle, &"player") - hand_before)
	return true


## 测试4：弃置触发（真实 discard 我方机甲正面装备）-> 确认 -> 抽2 + 上限+1
func test_pilot_053_discard_equip_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yalin(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var equip_id: StringName = _mount_equip_face_up(battle, s.mech, &"player", "part_001_量产装_头部", &"头部")
	if equip_id == &"":
		return "正面装备挂载失败"
	var hand_before: int = _action_hand_size(battle, &"player")
	var limit_before: int = _hand_limit(battle, &"player")
	var dc = await _fire_discard(battle, &"player", [equip_id])
	if dc == null:
		return "discard_card 未挂起（亚林 e1b 应弹 CHOOSE_ONE 确认）"
	# 确认发动 -> 抽2 + 上限+1
	await _resume_choose(battle, dc, 0)
	if _action_hand_size(battle, &"player") != hand_before + 2:
		return "确认后行动手牌应+2 实变=%d" % (_action_hand_size(battle, &"player") - hand_before)
	if _hand_limit(battle, &"player") != limit_before + 1:
		return "确认后行动牌上限应+1"
	return true


## 测试5：每回合2次用满 -> 第3次触发被跳过
func test_pilot_053_once_per_turn_max_2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yalin(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 第一次：设置头部 -> 确认
	var head_id: StringName = _put_equip_in_hand(battle, &"player", "part_001_量产装_头部")
	var set1 = await _fire_set_equipment(battle, s.mech, &"player", head_id, &"头部")
	if set1 == null:
		return "第1次未挂起"
	await _resume_choose(battle, set1, 0)
	# 第二次：设置躯干 -> 确认
	var torso_id: StringName = _put_equip_in_hand(battle, &"player", "part_002_量产装_躯干")
	var set2 = await _fire_set_equipment(battle, s.mech, &"player", torso_id, &"躯干")
	if set2 == null:
		return "第2次未挂起"
	await _resume_choose(battle, set2, 0)
	# 第三次：弃置正面装备（触发 e1b）-> 额度用满，跳过不弹窗
	var equip_id: StringName = _mount_equip_face_up(battle, s.mech, &"player", "part_003_量产装_右臂", &"右臂")
	if equip_id == &"":
		return "正面装备挂载失败"
	var hand_before: int = _action_hand_size(battle, &"player")
	var limit_before: int = _hand_limit(battle, &"player")
	var dc = await _fire_discard(battle, &"player", [equip_id])
	if dc != null:
		return "第3次不应挂起（每回合2次已用满）"
	if _action_hand_size(battle, &"player") != hand_before:
		return "第3次跳过不应再抽牌"
	if _hand_limit(battle, &"player") != limit_before:
		return "第3次跳过不应改上限"
	return true


## 测试6：下个我方回合开始 -> 上限加成到期清除 + 额度重置（可再次触发）
func test_pilot_053_hand_bonus_clears_next_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_yalin(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var head_id: StringName = _put_equip_in_hand(battle, &"player", "part_001_量产装_头部")
	if head_id == &"":
		return "头部装备设置失败"
	var limit_base: int = _hand_limit(battle, &"player")
	# 确认发动 -> 上限+1
	var set1 = await _fire_set_equipment(battle, s.mech, &"player", head_id, &"头部")
	if set1 == null:
		return "第1次未挂起"
	await _resume_choose(battle, set1, 0)
	if _hand_limit(battle, &"player") != limit_base + 1:
		return "发动后上限应+1（%d -> %d）" % [limit_base, _hand_limit(battle, &"player")]
	# 下个我方回合开始 -> 上限加成到期清除
	battle.context.turn_service.start_turn(&"player")
	await _pump_frames(4)
	if _hand_limit(battle, &"player") != limit_base:
		return "下个我方回合开始上限加成应清除（%d -> %d）" % [limit_base, _hand_limit(battle, &"player")]
	# 额度重置：新回合再设置一张 -> 仍触发
	var torso_id: StringName = _put_equip_in_hand(battle, &"player", "part_002_量产装_躯干")
	var set2 = await _fire_set_equipment(battle, s.mech, &"player", torso_id, &"躯干")
	if set2 == null:
		return "新回合额度应重置（可再次触发）"
	await _resume_choose(battle, set2, 0)
	if _hand_limit(battle, &"player") != limit_base + 1:
		return "新回合确认后上限应再次+1"
	return true


## 测试7：PVP3 多人类玩家通用——third 玩家触发按玩家隔离（抽牌/上限只动 third 的）
func test_pilot_053_owner_isolation_pvp3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_yalin(battle, &"third")
	if s.is_empty():
		return "third setup 失败（亚林设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	var head_id: StringName = _put_equip_in_hand(battle, &"third", "part_001_量产装_头部")
	if head_id == &"":
		return "third 头部装备设置失败"
	var third_hand_before: int = _action_hand_size(battle, &"third")
	var player_hand_before: int = _action_hand_size(battle, &"player")
	var third_limit_before: int = _hand_limit(battle, &"third")
	var player_limit_before: int = _hand_limit(battle, &"player")
	# third 设置装备 -> 触发亚林 e1 -> 确认
	var set_action = await _fire_set_equipment(battle, s.mech, &"third", head_id, &"头部")
	if set_action == null:
		return "third 设置未挂起"
	await _resume_choose(battle, set_action, 0)
	if _action_hand_size(battle, &"third") != third_hand_before + 2:
		return "third 确认后行动手牌应+2 实变=%d" % (_action_hand_size(battle, &"third") - third_hand_before)
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "third 触发不应影响 player 行动手牌"
	if _hand_limit(battle, &"third") != third_limit_before + 1:
		return "third 确认后行动牌上限应+1"
	if _hand_limit(battle, &"player") != player_limit_before:
		return "third 触发不应影响 player 行动牌上限"
	return true
