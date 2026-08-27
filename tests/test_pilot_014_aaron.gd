## test_pilot_014_aaron.gd - 亚伦（pilot_014）效果测试
##
## 亚伦 1 按钮（DIRECT 主动）：
##   effect_01（机师行动上限+2）：我方回合2次（once_per_turn_max=2），点击按钮 ->
##   弹窗列场上所有机师牌(含自己+所有玩家)+当前行动牌上限，选1张确定 -> 使其行动牌上限+2。
##   可取消不计次数（optional，取消路径不 mark once_per_turn）。
##   状态 UNTIL_NEXT_OWNER_TURN 到下个亚伦回合开始扣回；目标/来源机师牌离场或机甲被毁扣回；
##   刻托交换翻转 current_field（+2 跟随变攻击数+2）。多次施加独立 status。
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
	battle.rng_seed = 90014
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


## 给指定机甲设机师牌，返回机师牌实例
func _set_pilot_on_mech(battle, owner_id: StringName, mech, pilot_def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, pilot_def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return card


## 触发亚伦 effect_01（DIRECT 按钮），返回挂起的 effect_fire action（或 null）
func _fire_pilot_014(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_014_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_014_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## resume 选机师牌施加 +2
func _resume_grant(battle, ef_action, target_pilot_inst: StringName, target_pid: StringName, target_mid: StringName) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {
		"pilot_014_target_pilot": target_pilot_inst,
		"pilot_014_player_id": target_pid,
		"pilot_014_mech_id": target_mid,
	})
	await _pump_frames(5)


## resume 取消
func _resume_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(4)


## 统计某玩家 statuses 中 pilot_014 +2 数量
func _count_p014_on_player(gs, pid: StringName) -> int:
	var p = gs.players.get(pid)
	if p == null:
		return 0
	return p.statuses.filter(func(s): return String(s.get("type", &"")) == "pilot_014_action_limit_bonus").size()


## 统计某机甲 statuses 中 pilot_014 +2 数量
func _count_p014_on_mech(gs, mid: StringName) -> int:
	var m = gs.mechs.get(mid)
	if m == null:
		return 0
	return m.statuses.filter(func(s): return String(s.get("type", &"")) == "pilot_014_action_limit_bonus").size()


## 设亚伦(player)+刻托(enemy)，返回 {aaron_card, aaron_mech, ketuo_card, ketuo_mech, gs}
func _setup_aaron_vs_ketuo(battle):
	var gs = battle.context.game_state
	var aaron_mech = gs.get_mech_for_player(&"player")
	var ketuo_mech = gs.get_mech_for_player(&"enemy")
	if aaron_mech == null or ketuo_mech == null:
		return null
	var aaron_card = _set_pilot_on_mech(battle, &"player", aaron_mech, "pilot_014_亚伦")
	var ketuo_card = _set_pilot_on_mech(battle, &"enemy", ketuo_mech, "pilot_010_刻托")
	if aaron_card == null or ketuo_card == null:
		return null
	battle.context.action_ui_bridge.context = battle.context
	return {"aaron_card": aaron_card, "aaron_mech": aaron_mech, "ketuo_card": ketuo_card, "ketuo_mech": ketuo_mech, "gs": gs}


# ═══════════════════════════════════════════
# effect_01 定义
# ═══════════════════════════════════════════

## 测试1：effect_01 定义（MODE_DIRECT, once_per_turn_max=2, IS_OWNER_MAIN_PHASE, PILOT_014 action）
func test_pilot_014_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_014_effect_01")
	if e == null:
		return "缺 pilot_014_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "mode 应 MODE_DIRECT 实=%s" % String(e.mode)
	if int(e.once_per_turn_max) != 2:
		return "once_per_turn_max 应 2 实=%d" % int(e.once_per_turn_max)
	if e.once_per_turn_key != &"pilot_014_effect_01":
		return "once_per_turn_key 错误"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("IS_OWNER_MAIN_PHASE"):
		return "应含 IS_OWNER_MAIN_PHASE"
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "PILOT_014_SELECT_TARGET_PILOT_AND_GRANT":
		return "actions 应 [PILOT_014_SELECT_TARGET_PILOT_AND_GRANT]"
	if not bool(acts[0].get("params", {}).get("optional", false)):
		return "PILOT_014 应 optional=true（取消不计次数）"
	return true


# ═══════════════════════════════════════════
# 施加 +2
# ═══════════════════════════════════════════

## 测试2：亚伦对自己施加 +2（action_card_limit 5->7）
func test_pilot_014_grant_to_self() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var aaron_mech = gs.get_mech_for_player(&"player")
	var aaron_card = _set_pilot_on_mech(battle, &"player", aaron_mech, "pilot_014_亚伦")
	if aaron_card == null:
		return "setup 亚伦失败"
	battle.context.action_ui_bridge.context = battle.context
	var lim_before: int = gs.players.get(&"player").action_card_limit
	var ef = await _fire_pilot_014(battle, aaron_card, aaron_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹选机师牌窗）"
	await _resume_grant(battle, ef, aaron_card.instance_id, &"player", aaron_mech.mech_id)
	var player = gs.players.get(&"player")
	if player.action_card_limit != lim_before + 2:
		return "对自己+2 应 %d->%d，实=%d" % [lim_before, lim_before + 2, player.action_card_limit]
	if _count_p014_on_player(gs, &"player") != 1:
		return "应留下1个 +2 status"
	return true


## 测试3：亚伦对敌方刻托施加 +2（刻托 action_card_limit 1->3）
func test_pilot_014_grant_to_enemy_ketuo() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aaron_vs_ketuo(battle)
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim_before: int = enemy.action_card_limit  # 刻托=1
	var ef = await _fire_pilot_014(battle, s.aaron_card, s.aaron_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_grant(battle, ef, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim_before + 2:
		return "对刻托+2 应 %d->%d，实=%d" % [lim_before, lim_before + 2, enemy.action_card_limit]
	if _count_p014_on_player(gs, &"enemy") != 1:
		return "敌方应留下1个 +2 status"
	# status 绑定的来源应是亚伦
	var st = enemy.statuses.filter(func(x): return String(x.get("type", &"")) == "pilot_014_action_limit_bonus")[0]
	if String(st.get("source_pilot_instance", &"")) != String(s.aaron_card.instance_id):
		return "status source_pilot_instance 应=亚伦"
	if String(st.get("target_pilot_instance", &"")) != String(s.ketuo_card.instance_id):
		return "status target_pilot_instance 应=刻托"
	if String(st.get("duration_owner_id", &"")) != &"player":
		return "duration_owner_id 应=亚伦拥有者(player)"
	return true


# ═══════════════════════════════════════════
# 每回合2次 / 取消不计
# ═══════════════════════════════════════════

## 测试4：2次独立施加（对自己2次 -> +4），第3次用满不挂起
func test_pilot_014_twice_independent() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var aaron_mech = gs.get_mech_for_player(&"player")
	var aaron_card = _set_pilot_on_mech(battle, &"player", aaron_mech, "pilot_014_亚伦")
	if aaron_card == null:
		return "setup 亚伦失败"
	battle.context.action_ui_bridge.context = battle.context
	var lim0: int = gs.players.get(&"player").action_card_limit
	# 第1次
	var ef1 = await _fire_pilot_014(battle, aaron_card, aaron_mech, &"player")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_grant(battle, ef1, aaron_card.instance_id, &"player", aaron_mech.mech_id)
	if gs.players.get(&"player").action_card_limit != lim0 + 2:
		return "第1次后应 %d，实=%d" % [lim0 + 2, gs.players.get(&"player").action_card_limit]
	# 第2次
	var ef2 = await _fire_pilot_014(battle, aaron_card, aaron_mech, &"player")
	if ef2 == null:
		return "第2次未挂起（once_per_turn_max=2 应允许）"
	await _resume_grant(battle, ef2, aaron_card.instance_id, &"player", aaron_mech.mech_id)
	if gs.players.get(&"player").action_card_limit != lim0 + 4:
		return "第2次后应 %d（2个独立+2），实=%d" % [lim0 + 4, gs.players.get(&"player").action_card_limit]
	if _count_p014_on_player(gs, &"player") != 2:
		return "应留下2个独立 +2 status"
	# 第3次：用满，_execute_effect 跳过，effect_fire 不挂起
	var ef3 = await _fire_pilot_014(battle, aaron_card, aaron_mech, &"player")
	if ef3 != null:
		return "第3次应用满不挂起（once_per_turn_max=2）"
	if gs.players.get(&"player").action_card_limit != lim0 + 4:
		return "第3次不应再加，实=%d" % gs.players.get(&"player").action_card_limit
	return true


## 测试5：取消不计次数（取消后仍可2次）
func test_pilot_014_cancel_no_count() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var aaron_mech = gs.get_mech_for_player(&"player")
	var aaron_card = _set_pilot_on_mech(battle, &"player", aaron_mech, "pilot_014_亚伦")
	if aaron_card == null:
		return "setup 亚伦失败"
	battle.context.action_ui_bridge.context = battle.context
	var lim0: int = gs.players.get(&"player").action_card_limit
	# 取消1次
	var ef1 = await _fire_pilot_014(battle, aaron_card, aaron_mech, &"player")
	if ef1 == null:
		return "取消前未挂起"
	await _resume_cancel(battle, ef1)
	if gs.players.get(&"player").action_card_limit != lim0:
		return "取消后 action_card_limit 应不变 实=%d" % gs.players.get(&"player").action_card_limit
	if _count_p014_on_player(gs, &"player") != 0:
		return "取消后不应留 status"
	# 取消后仍可2次
	var ef2 = await _fire_pilot_014(battle, aaron_card, aaron_mech, &"player")
	if ef2 == null:
		return "取消后第1次应可挂起"
	await _resume_grant(battle, ef2, aaron_card.instance_id, &"player", aaron_mech.mech_id)
	var ef3 = await _fire_pilot_014(battle, aaron_card, aaron_mech, &"player")
	if ef3 == null:
		return "取消后第2次应可挂起"
	await _resume_grant(battle, ef3, aaron_card.instance_id, &"player", aaron_mech.mech_id)
	if gs.players.get(&"player").action_card_limit != lim0 + 4:
		return "取消后2次应 +4 实=%d" % gs.players.get(&"player").action_card_limit
	return true


# ═══════════════════════════════════════════
# 到期恢复
# ═══════════════════════════════════════════

## 测试6：到期恢复（下个亚伦回合开始 _clean_until_next_owner_turn 扣回）
func test_pilot_014_expiry_next_owner_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aaron_vs_ketuo(battle)
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim_before: int = enemy.action_card_limit  # 刻托=1
	var ef = await _fire_pilot_014(battle, s.aaron_card, s.aaron_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_grant(battle, ef, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim_before + 2:
		return "施加后应 %d 实=%d" % [lim_before + 2, enemy.action_card_limit]
	# 下个亚伦(player)回合开始 -> _clean_until_next_owner_turn(player)
	battle.context.turn_service._clean_until_next_owner_turn(&"player")
	if enemy.action_card_limit != lim_before:
		return "到期应扣回 %d 实=%d" % [lim_before, enemy.action_card_limit]
	if _count_p014_on_player(gs, &"enemy") != 0:
		return "到期后 status 应清空"
	return true


# ═══════════════════════════════════════════
# 刻托交换跟随
# ═══════════════════════════════════════════

## 测试7：刻托交换翻转 +2（action_card_limit 侧 -> max_attacks_per_turn 侧）
func test_pilot_014_ketuo_swap_follow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aaron_vs_ketuo(battle)
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	# 刻托 base: action_card_limit=1, max_attacks_per_turn=3
	var lim0: int = enemy.action_card_limit  # 1
	var atk0: int = s.ketuo_mech.max_attacks_per_turn  # 3
	# 亚伦对刻托 +2：action_card_limit 1->3，status 在 enemy.player.statuses
	var ef = await _fire_pilot_014(battle, s.aaron_card, s.aaron_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_grant(battle, ef, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim0 + 2:
		return "+2 后 action_card_limit 应 %d 实=%d" % [lim0 + 2, enemy.action_card_limit]
	if _count_p014_on_player(gs, &"enemy") != 1 or _count_p014_on_mech(gs, s.ketuo_mech.mech_id) != 0:
		return "+2 status 应在 player.statuses"
	# 刻托交换：互换生效值 + 翻转 status 到 mech.statuses
	battle.context.game_actions.swap_hand_limit_and_attack_count({
		"player_id": &"enemy", "mech_id": s.ketuo_mech.mech_id})
	# 交换后：新 action_card_limit=旧 max_attacks=3；新 max_attacks=旧 action_card_limit(1+2=3，含+2)
	if enemy.action_card_limit != atk0:
		return "交换后 action_card_limit 应=旧max_attacks %d 实=%d" % [atk0, enemy.action_card_limit]
	if s.ketuo_mech.max_attacks_per_turn != lim0 + 2:
		return "交换后 max_attacks 应=旧action_card_limit(含+2) %d 实=%d" % [lim0 + 2, s.ketuo_mech.max_attacks_per_turn]
	if _count_p014_on_player(gs, &"enemy") != 0 or _count_p014_on_mech(gs, s.ketuo_mech.mech_id) != 1:
		return "交换后 +2 status 应翻转到 mech.statuses"
	var st = s.ketuo_mech.statuses.filter(func(x): return String(x.get("type", &"")) == "pilot_014_action_limit_bonus")[0]
	if String(st.get("current_field", &"")) != "max_attacks_per_turn":
		return "交换后 current_field 应=max_attacks_per_turn"
	# 到期（下个亚伦回合）按 current_field 扣回 max_attacks。
	# swap 后 max_attacks 持「原 action_card_limit 语义」=lim0+2，扣回 delta=2 -> lim0。
	battle.context.turn_service._clean_until_next_owner_turn(&"player")
	if s.ketuo_mech.max_attacks_per_turn != lim0:
		return "到期扣回 max_attacks 应=%d 实=%d" % [lim0, s.ketuo_mech.max_attacks_per_turn]
	if enemy.attack_limit != lim0:
		return "到期后 attack_limit 应同步=%d 实=%d" % [lim0, enemy.attack_limit]
	if _count_p014_on_mech(gs, s.ketuo_mech.mech_id) != 0:
		return "到期后 status 应清空"
	return true


# ═══════════════════════════════════════════
# 离场清理
# ═══════════════════════════════════════════

## 测试8：目标机师牌换下 -> 其 +2 扣回
func test_pilot_014_target_leave_cleanup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aaron_vs_ketuo(battle)
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim0: int = enemy.action_card_limit  # 1
	var ef = await _fire_pilot_014(battle, s.aaron_card, s.aaron_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_grant(battle, ef, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim0 + 2:
		return "施加后应 %d 实=%d" % [lim0 + 2, enemy.action_card_limit]
	# 刻托（目标）换下
	battle.context.game_setup_service.unset_pilot(s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim0:
		return "目标离场应扣回 %d 实=%d" % [lim0, enemy.action_card_limit]
	if _count_p014_on_player(gs, &"enemy") != 0:
		return "目标离场后 status 应清空"
	return true


## 测试9：亚伦（来源）换下 -> 其施加的全部 +2 扣回
func test_pilot_014_source_leave_cleanup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aaron_vs_ketuo(battle)
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim0: int = enemy.action_card_limit  # 1
	# 亚伦对刻托施加2次（+4）
	var ef1 = await _fire_pilot_014(battle, s.aaron_card, s.aaron_mech, &"player")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_grant(battle, ef1, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	var ef2 = await _fire_pilot_014(battle, s.aaron_card, s.aaron_mech, &"player")
	if ef2 == null:
		return "第2次未挂起"
	await _resume_grant(battle, ef2, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim0 + 4:
		return "2次后应 %d 实=%d" % [lim0 + 4, enemy.action_card_limit]
	# 亚伦（来源）换下 -> 其施加的全部 +2 扣回
	battle.context.game_setup_service.unset_pilot(s.aaron_mech.mech_id)
	if enemy.action_card_limit != lim0:
		return "来源离场应扣回全部 %d 实=%d" % [lim0, enemy.action_card_limit]
	if _count_p014_on_player(gs, &"enemy") != 0:
		return "来源离场后 status 应清空"
	return true


## 测试10：机甲被毁 -> 其机师牌绑定的 +2 扣回
func test_pilot_014_mech_destroyed_cleanup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_aaron_vs_ketuo(battle)
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var enemy = gs.players.get(&"enemy")
	var lim0: int = enemy.action_card_limit  # 1
	var ef = await _fire_pilot_014(battle, s.aaron_card, s.aaron_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_grant(battle, ef, s.ketuo_card.instance_id, &"enemy", s.ketuo_mech.mech_id)
	if enemy.action_card_limit != lim0 + 2:
		return "施加后应 %d 实=%d" % [lim0 + 2, enemy.action_card_limit]
	# 刻托机甲被毁
	battle.context.game_actions.destroy_mech({"mech_id": s.ketuo_mech.mech_id})
	if enemy.action_card_limit != lim0:
		return "机甲被毁应扣回 %d 实=%d" % [lim0, enemy.action_card_limit]
	if _count_p014_on_player(gs, &"enemy") != 0:
		return "机甲被毁后 status 应清空"
	return true
