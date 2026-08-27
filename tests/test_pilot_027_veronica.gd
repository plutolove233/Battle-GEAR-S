## test_pilot_027_veronica.gd - 维罗妮卡（pilot_027，混乱 SR，cost 10, attack_limit 1, action_card_limit 5）效果测试
##
## 维罗妮卡 3 效果（运行时机师效果走 ActionPilotEffects 新体系）：
##   effect_01（LISTEN 按钮1 置灰+悬停）「获金分半」：4+X格范围内其他机甲获得非我方给予的金币时，
##     我方获得其中一半（向下取整，剩下留给该机甲）。监听 GameActions.gain_gold 虚拟action
##     fire 的 GAIN_GOLD_AFTER（payload: gainer_player_id/gainer_mech_id/amount/from_player_id）。
##     判定（gainer≠自己/非我方给予/距离≤4+X/amount>0）在 handler PILOT_027_SPLIT_GOLD 内做，
##     满足则直接增减双方玩家金币字段（不走 gain_gold，避免维罗妮卡获金再 fire 时点 -> 递归再分半）。
##   effect_02（LISTEN 按钮2 置灰+悬停，每回合1次）「给予金币X+1」：我方给予其他机甲金币时 X+1。
##     监听 GIVE_GOLD_AFTER（gain_gold 带 from_player_id≠gainer 时 fire）；X 存本机师牌实例
##     counters["var_pilot_027_x"]，换机师不转移。
##   effect_03（DIRECT 按钮3，每回合2次）「给予金币并使用行动牌」：主阶段，选4+X格内1台其他机甲，
##     给至少2金（至多当前金币，+5/-5 stepper），之后可使其立即使用1张可用行动牌
##     （攻击+辅助，排除迎击；攻击牌需该机甲武器射程内有目标）。多阶段状态机见 handler
##     PILOT_027_GIFT_AND_USE：target_select → choose_integer → 给金+X+1+mark次数 → ask_use → card_select。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90027
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


## 设维罗妮卡为 owner_id 机甲的机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_027(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_027_维罗妮卡", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 把 enemy 移到距 player_mech 恰好 d 格（轴向向右）
func _place_enemy(gs, player_mech, enemy_mech, d: int) -> void:
	enemy_mech.position = {"q": int(player_mech.position.get("q", 0)) + d, "r": int(player_mech.position.get("r", 0))}


## 在 _pending_effect 中找 phase 匹配的挂起 effect 动作 id；无返回 &""。
func _find_pending_action(battle, phase: String) -> StringName:
	var pending: Dictionary = battle.context.timing_engine._pending_effect
	for aid: StringName in pending:
		if String(pending[aid].get("phase", &"")) == phase:
			return aid
	return &""


## 触发维罗妮卡效果3（DIRECT 按钮），等待挂起到 pilot_027_target_select，返回挂起动作 id；失败返回 null。
func _fire_effect3_wait_target(battle, pilot_card, mech, player_id: StringName) -> Variant:
	battle.context.action_ui_bridge.context = battle.context
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_027_effect_03",
	}
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_027_effect_03",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	var guard: int = 0
	while guard < 30:
		guard += 1
		await _pump_frames(1)
		var aid := _find_pending_action(battle, "pilot_027_target_select")
		if aid != &"":
			return aid
	return null


## 效果3「给金+（若有询问则按 ask_use 选择）」走完一轮。ask_use=true 选"是"（之后外部还需 resume 选牌）。
## ask_use=false 选"否"或目标无可用牌直接结束。返回 true=正常走完。
func _drive_effect3_give_gold(battle, action_id: StringName, target: StringName, amount: int, ask_use: bool) -> bool:
	var te = battle.context.timing_engine
	te.resume_pending_effect(action_id, {"target_id": target})
	await _pump_frames(2)
	te.resume_pending_effect(action_id, {"chosen_value": amount})
	await _pump_frames(3)
	var ask_aid := _find_pending_action(battle, "pilot_027_ask_use")
	if ask_aid != &"":
		te.resume_pending_effect(action_id, {"chosen_option_index": 1 if not ask_use else 0})
		await _pump_frames(3)
	return true


## 取效果3 listener 的 binding_context（can_trigger_active_effect 检查用）；无返回 {}。
func _get_effect3_bind(battle, card) -> Dictionary:
	var te = battle.context.timing_engine
	var cid: StringName = card.instance_id
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			if entry is Dictionary and entry.get("effect") != null \
					and String(entry.effect.effect_id) == "pilot_027_effect_03" \
					and String(entry.get("binding_context", {}).get("card_instance_id", &"")) == String(cid):
				return entry.get("binding_context", {})
	return {}


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：effect_01/02/03 定义
func test_pilot_027_effect_definitions() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_027_effect_01")
	if e1 == null:
		return "缺 pilot_027_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.GAIN_GOLD_AFTER:
		return "effect_01 应监听 GAIN_GOLD_AFTER 实=%s" % String(e1.listen_timing)
	if e1.listen_action_type != &"gold":
		return "effect_01 listen_action_type 应 gold 实=%s" % String(e1.listen_action_type)
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_027_effect_02")
	if e2 == null:
		return "缺 pilot_027_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN or e2.listen_timing != _TimingConst.GIVE_GOLD_AFTER:
		return "effect_02 应 LISTEN 监听 GIVE_GOLD_AFTER"
	if e2.listen_action_type != &"gold":
		return "effect_02 listen_action_type 应 gold 实=%s" % String(e2.listen_action_type)
	if e2.once_per_turn_key != &"pilot_027_effect_02":
		return "effect_02 once_per_turn_key 应 pilot_027_effect_02"
	if int(e2.once_per_turn_max) != 1:
		return "effect_02 once_per_turn_max 应 1（每回合1次）"
	var e3 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_027_effect_03")
	if e3 == null:
		return "缺 pilot_027_effect_03"
	if e3.mode != _TimingConst.MODE_DIRECT:
		return "effect_03 mode 应 MODE_DIRECT 实=%s" % String(e3.mode)
	if e3.once_per_turn_key != &"pilot_027_effect_03":
		return "effect_03 once_per_turn_key 应 pilot_027_effect_03"
	if int(e3.once_per_turn_max) != 2:
		return "effect_03 once_per_turn_max 应 2（每回合2次）"
	if not e3.costs.is_empty():
		return "effect_03 costs 应为空（SPEND_GOLD 会与给金金额双扣，金额由 handler 一次扣）"
	var ops: Array = []
	for c in e3.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "GOLD_ABOVE", "HAS_OTHER_MECH_IN_VARIABLE_RANGE"]:
		if not ops.has(need):
			return "effect_03 应含条件 %s" % need
	return true


## 测试2：效果1获金分半 - 范围内非我方给予分半 / 范围外不分 / 我方给予不分
func test_pilot_027_effect1_split_gold() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_027(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_027_维罗妮卡）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 0:
		return "X 初始应0"
	# ① 范围内（距离2 ≤ 4+X=4）非我方给予 -> 分半
	_place_enemy(gs, mech, enemy_mech, 2)
	var p_before: int = player.gold
	var e_before: int = enemy.gold
	battle.context.game_actions.gain_gold({"player_id": &"enemy", "amount": 10})
	await _pump_frames(3)
	if enemy.gold != e_before + 5:
		return "分半后 enemy 应只保留一半（+5） 前%d 后%d" % [e_before, enemy.gold]
	if player.gold != p_before + 5:
		return "分半后 player 应获得一半（+5） 前%d 后%d" % [p_before, player.gold]
	# ② 范围外（距离18 > 4）-> 不分半
	_place_enemy(gs, mech, enemy_mech, 18)
	p_before = player.gold
	e_before = enemy.gold
	battle.context.game_actions.gain_gold({"player_id": &"enemy", "amount": 4})
	await _pump_frames(3)
	if enemy.gold != e_before + 4:
		return "范围外 enemy 应全额获得（+4） 前%d 后%d" % [e_before, enemy.gold]
	if player.gold != p_before:
		return "范围外 player 不应分半（+0） 前%d 后%d" % [p_before, player.gold]
	# ③ 我方给予（from=player）-> 效果1跳过（非我方给予互斥），但效果2触发 X+1
	_place_enemy(gs, mech, enemy_mech, 2)
	p_before = player.gold
	e_before = enemy.gold
	battle.context.game_actions.gain_gold({"player_id": &"enemy", "amount": 6, "from_player_id": &"player"})
	await _pump_frames(3)
	if enemy.gold != e_before + 6:
		return "我方给予 enemy 应全额获得（+6） 前%d 后%d" % [e_before, enemy.gold]
	if player.gold != p_before:
		return "我方给予时 player 不应再分半（效果1互斥） 前%d 后%d" % [p_before, player.gold]
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 1:
		return "我方给予应触发效果2 X+1 实=%d" % _ActionPilotEffects.get_pilot_027_x(s.card)
	return true


## 测试3：效果2 X+1 每回合1次 - 第1次+1，同回合再给不+，无 from 不触发
func test_pilot_027_effect2_x_inc_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_027(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# enemy 移远（隔离效果1分半，只测效果2）
	_place_enemy(gs, mech, enemy_mech, 18)
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 0:
		return "X 初始应0"
	battle.context.game_actions.gain_gold({"player_id": &"enemy", "amount": 5, "from_player_id": &"player"})
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 1:
		return "第1次给金应 X+1 实=%d" % _ActionPilotEffects.get_pilot_027_x(s.card)
	# 同回合第2次：每回合1次 mark，X 不再+1
	battle.context.game_actions.gain_gold({"player_id": &"enemy", "amount": 5, "from_player_id": &"player"})
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 1:
		return "同回合第2次给金不应再 X+1（每回合1次） 实=%d" % _ActionPilotEffects.get_pilot_027_x(s.card)
	# 无 from（目标自己获得）-> GIVE 时点不 fire -> X 不变
	battle.context.game_actions.gain_gold({"player_id": &"enemy", "amount": 3})
	await _pump_frames(3)
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 1:
		return "无来源获金不应触发 X+1 实=%d" % _ActionPilotEffects.get_pilot_027_x(s.card)
	return true


## 测试4：效果3给金全流程 - 选目标+输金额-> 给金扣自己+给目标+X+1（无可用牌则不弹询问直接结束）
func test_pilot_027_effect3_give_gold_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_027(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	_place_enemy(gs, mech, enemy_mech, 2)
	# 清空 enemy 行动手牌（无可用牌 -> 给金后不弹询问）
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	var p_before: int = player.gold
	var e_before: int = enemy.gold
	var action_id = await _fire_effect3_wait_target(battle, s.card, mech, &"player")
	if action_id == null:
		return "效果3未挂起到 target_select"
	var te = battle.context.timing_engine
	te.resume_pending_effect(action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(2)
	te.resume_pending_effect(action_id, {"chosen_value": 5})
	await _pump_frames(4)
	if player.gold != p_before - 5:
		return "效果3应扣维罗妮卡5金 前%d 后%d" % [p_before, player.gold]
	if enemy.gold != e_before + 5:
		return "效果3应给目标5金 前%d 后%d" % [e_before, enemy.gold]
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 1:
		return "效果3给金应触发效果2 X+1 实=%d" % _ActionPilotEffects.get_pilot_027_x(s.card)
	# 无可用牌 -> 不应弹 ask_use
	var ask_aid := _find_pending_action(battle, "pilot_027_ask_use")
	if ask_aid != &"":
		return "目标无可用行动牌不应弹 ask_use 询问"
	return true


## 测试5：效果3询问+目标使用攻击牌（第⑤阶段 use_action_card 发起，牌离开目标手牌）
func test_pilot_027_effect3_ask_use_attack_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_027(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	_place_enemy(gs, mech, enemy_mech, 1)
	# 给 enemy 一张攻击牌
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	if atk == null:
		return "找不到 action_001_进攻"
	enemy.action_hand.append(atk.instance_id)
	var action_id = await _fire_effect3_wait_target(battle, s.card, mech, &"player")
	if action_id == null:
		return "效果3未挂起到 target_select"
	var te = battle.context.timing_engine
	te.resume_pending_effect(action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(2)
	te.resume_pending_effect(action_id, {"chosen_value": 5})
	await _pump_frames(3)
	# 有可用攻击牌 -> 应弹 ask_use 询问
	var ask_aid := _find_pending_action(battle, "pilot_027_ask_use")
	if ask_aid == &"":
		return "目标有可用攻击牌应弹 ask_use 询问"
	# 选"是，立即使用"
	te.resume_pending_effect(action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	var cs_aid := _find_pending_action(battle, "pilot_027_card_select")
	if cs_aid == &"":
		return "选使用后应挂起 card_select 选牌"
	# 目标选该攻击牌 -> use_action_card 发起（被动使用，不计攻击数）
	te.resume_pending_effect(action_id, {"selected_card_id": atk.instance_id})
	await _pump_frames(6)
	# 攻击牌应离开 enemy 手牌（进 temp_zone/discard，即已被使用发起）
	if enemy.action_hand.has(atk.instance_id):
		return "目标使用攻击牌后牌应离开手牌"
	return true


## 测试6：效果3选目标取消 - 不给金不消耗次数
func test_pilot_027_effect3_cancel_target() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_027(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	_place_enemy(gs, mech, enemy_mech, 2)
	var p_before: int = player.gold
	var action_id = await _fire_effect3_wait_target(battle, s.card, mech, &"player")
	if action_id == null:
		return "效果3未挂起到 target_select"
	battle.context.timing_engine.resume_pending_effect(action_id, {"cancelled": true})
	await _pump_frames(3)
	if player.gold != p_before:
		return "取消选目标不应扣金币 前%d 后%d" % [p_before, player.gold]
	if _ActionPilotEffects.get_pilot_027_x(s.card) != 0:
		return "取消选目标不应触发 X+1"
	# 次数未消耗：第1次仍可用（每回合2次第1次）
	var te = battle.context.timing_engine
	var e3 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_027_effect_03")
	var bind := _get_effect3_bind(battle, s.card)
	if bind.is_empty():
		return "效果3应已注册 permanent listener"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	if not te.can_trigger_active_effect(e3, bind):
		return "取消选目标不应消耗每回合次数（仍可用）"
	return true


## 测试7：效果3每回合2次 - 2次用满后不可再触发（给金才消耗，取消不消耗）
func test_pilot_027_effect3_once_per_turn_max2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_027(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	_place_enemy(gs, mech, enemy_mech, 2)
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	var te = battle.context.timing_engine
	var e3 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_027_effect_03")
	var bind := _get_effect3_bind(battle, s.card)
	if bind.is_empty():
		return "效果3应已注册 permanent listener"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	if not te.can_trigger_active_effect(e3, bind):
		return "第1次使用前应可用"
	# 第1次（给金5，无可用牌 -> 结束）
	var aid1 = await _fire_effect3_wait_target(battle, s.card, mech, &"player")
	if aid1 == null:
		return "第1次未挂起到 target_select"
	await _drive_effect3_give_gold(battle, aid1, enemy_mech.mech_id, 5, false)
	if not te.can_trigger_active_effect(e3, bind):
		return "第1次后应还可使用（每回合2次用掉1次）"
	# 第2次
	var aid2 = await _fire_effect3_wait_target(battle, s.card, mech, &"player")
	if aid2 == null:
		return "第2次未挂起到 target_select"
	await _drive_effect3_give_gold(battle, aid2, enemy_mech.mech_id, 5, false)
	if te.can_trigger_active_effect(e3, bind):
		return "第2次用满后应不可再使用（每回合2次）"
	return true


## 测试8（回归）：金币标记获金应走 gain_gold 时点 -> 维罗妮卡范围内分半。
## 修复前 MarkerService._trigger_gold_marker 直接 player.gold += 绕过 gain_gold，
## GAIN_GOLD_AFTER 不 fire，维罗妮卡效果1监听不到金币标记来源的获金。
func test_pilot_027_effect1_split_gold_marker() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_027(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_027_维罗妮卡）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	# enemy 在范围内（距离2 ≤ 4+X）
	_place_enemy(gs, mech, enemy_mech, 2)
	var p_before: int = player.gold
	var e_before: int = enemy.gold
	# enemy 触发金币标记（MarkerService.trigger_marker 全路径，roll 走 context.rng）
	var result: Dictionary = battle.context.marker_service.trigger_marker(enemy_mech.mech_id, {"type": &"GOLD", "marker_id": &"m_test", "q": 0, "r": 0})
	var gained: int = int(result.get("gold_gained", 0))
	if gained <= 0:
		return "金币标记应产出 >0 金币，实=%d" % gained
	await _pump_frames(3)
	var half: int = int(floor(gained / 2.0))
	if enemy.gold != e_before + gained - half:
		return "金币标记后 enemy 应被分半保留 %d（前%d 获%d 实增%d）" % [gained - half, e_before, gained, enemy.gold - e_before]
	if player.gold != p_before + half:
		return "金币标记后 player 应分走一半 %d（前%d 实增%d）" % [half, p_before, player.gold - p_before]
	# 范围外（距离18）金币标记 -> 不分半
	_place_enemy(gs, mech, enemy_mech, 18)
	p_before = player.gold
	e_before = enemy.gold
	result = battle.context.marker_service.trigger_marker(enemy_mech.mech_id, {"type": &"GOLD", "marker_id": &"m_test2", "q": 18, "r": 0})
	gained = int(result.get("gold_gained", 0))
	await _pump_frames(3)
	if player.gold != p_before:
		return "范围外金币标记 player 不应分半（前%d 后%d）" % [p_before, player.gold]
	if enemy.gold != e_before + gained:
		return "范围外金币标记 enemy 应全额获得（前%d 获%d 实增%d）" % [e_before, gained, enemy.gold - e_before]
	return true
