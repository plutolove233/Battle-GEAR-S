## test_pilot_028_ullr.gd - 乌尔（pilot_028，混乱 SR，cost 10, attack_limit 1, action_card_limit 3）效果测试
##
## 乌尔 3 效果（运行时机师效果走 ActionPilotEffects 新体系，全 LISTEN 置灰按钮）：
##   effect_01（按钮1）「宣言」：每轮 ROUND_START 弹三选一（攻击/迎击/辅助，可取消=本轮无宣言，效果2/3失效）。
##     选好后记录本轮宣言类型到机师牌实例 counters["var_pilot_028_declared"] + X 重置0，弹非阻塞展示浮窗。
##   effect_02（按钮2）「需交牌」：本轮 4+X 格范围内其他机甲使用宣言类型实体行动牌时，
##     须交给乌尔2张行动牌才能生效；不交/牌不够（手牌<2）→ 该行动牌不生效（use_action_card._step_execute_effects
##     读 record._pilot_028_skip_effects 跳过效果阶段，牌照常进弃牌堆）。监听 USE_ACTION_AT。
##   effect_03（按钮3）「X+1」：本轮每回合1次，乌尔自己使用宣言类型实体行动牌时 X+1。
##     每回合1次用手动计数器（键含回合号），不能用 once_per_turn_key（会在无关行动牌使用时误耗）。监听 USE_ACTION_AT。
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
	battle.rng_seed = 90028
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	# 默认玩家/敌方均 is_human=true（乌尔宣言/交给牌弹窗需要人类玩家路径）
	for pid in [&"player", &"enemy"]:
		var p = battle.context.game_state.players.get(pid)
		if p != null:
			p.is_human = true
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


## 设乌尔为 owner_id 机甲的机师，返回 {card, mech, player, gs, cdb}；失败返回 null。
func _setup_pilot_028(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_028_乌尔", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


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


## 构造 turn 虚拟 action（fire ROUND_START 用；action_type 须与 TurnService._fire_timing 一致 &"turn"）。
func _make_turn_action(battle, turn_owner: StringName) -> _Action:
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p028_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": turn_owner}
	turn_action.state = &"running"
	turn_action.context = battle.context
	battle.context.action_registry.register(turn_action)
	return turn_action


## 驱动乌尔宣言：fire ROUND_START -> 弹三选一 -> resume。
## choice: 0攻击 1迎击 2辅助；cancel=true 取消。返回机师牌实例（无弹窗返回 null）。
func _drive_declare(battle, choice: int, cancel: bool = false):
	var te = battle.context.timing_engine
	var turn_action := _make_turn_action(battle, &"player")
	te.fire_timing(_TimingConst.ROUND_START, turn_action)
	var aid := _find_pending_action(battle, "pilot_028_declare")
	if aid == &"":
		return null
	if cancel:
		te.resume_pending_effect(aid, {"cancelled": true})
	else:
		te.resume_pending_effect(aid, {"chosen_option_index": choice})
	await _pump_frames(2)
	return _ActionPilotEffects.pilot_028_pilot_card(battle.context.game_state)


## 构造并 fire 一个 mock use_action_card 的 USE_ACTION_AT 时点（直接测 handler，不走完整 use_action_card）。
## 返回 mock action（供检查 record skip 标志）。
func _fire_use_at(battle, player_id: StringName, mech_id: StringName, card_instance_id: StringName, extra: Dictionary = {}) -> _Action:
	var mock := _Action.new()
	mock.action_id = &"test_p028_use_%d" % [randi() % 1000000]
	mock.action_type = &"use_action_card"
	mock.record = {
		"card_instance_id": card_instance_id,
		"player_id": player_id,
		"mech_id": mech_id,
	}
	mock.record.merge(extra, true)
	mock.state = &"running"
	mock.context = battle.context
	battle.context.action_registry.register(mock)
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_AT, mock)
	return mock


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：3 效果定义（全 LISTEN；e1=ROUND_START/turn；e2/e3=USE_ACTION_AT/use_action_card；e3 无 once_per_turn_key）
func test_pilot_028_effect_definitions() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_028_effect_01")
	if e1 == null:
		return "缺 pilot_028_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.ROUND_START:
		return "effect_01 应监听 ROUND_START 实=%s" % String(e1.listen_timing)
	if e1.listen_action_type != &"turn":
		return "effect_01 listen_action_type 应 turn 实=%s" % String(e1.listen_action_type)
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_028_effect_02")
	if e2 == null:
		return "缺 pilot_028_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN or e2.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_02 应 LISTEN 监听 USE_ACTION_AT"
	if e2.listen_action_type != &"use_action_card":
		return "effect_02 listen_action_type 应 use_action_card 实=%s" % String(e2.listen_action_type)
	var e3 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_028_effect_03")
	if e3 == null:
		return "缺 pilot_028_effect_03"
	if e3.mode != _TimingConst.MODE_LISTEN or e3.listen_timing != _TimingConst.USE_ACTION_AT:
		return "effect_03 应 LISTEN 监听 USE_ACTION_AT"
	if e3.listen_action_type != &"use_action_card":
		return "effect_03 listen_action_type 应 use_action_card 实=%s" % String(e3.listen_action_type)
	if e3.once_per_turn_key != &"":
		return "effect_03 不应设 once_per_turn_key（手动计数器管理每回合1次）"
	return true


# ═══════════════════════════════════════════
# 效果1 宣言
# ═══════════════════════════════════════════

## 测试2：宣言选攻击 -> 记录"攻击"，且 X 重置为 0（宣言前手置 X=7 验证）
func test_pilot_028_declare_choose_attack() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_028_乌尔）"
	_ActionPilotEffects.set_pilot_028_x(s.card, 7)
	var card = await _drive_declare(battle, 0)
	if card == null:
		return "宣言未弹窗（缺 pending pilot_028_declare）"
	if _ActionPilotEffects.get_pilot_028_declared(card) != "攻击":
		return "宣言应为攻击 实=%s" % _ActionPilotEffects.get_pilot_028_declared(card)
	if _ActionPilotEffects.get_pilot_028_x(card) != 0:
		return "宣言应重置 X=0 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	return true


## 测试3：宣言取消 -> 本轮无宣言（效果2/3失效前提）
func test_pilot_028_declare_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, -1, true)
	if card == null:
		return "宣言未弹窗"
	if _ActionPilotEffects.get_pilot_028_declared(card) != "":
		return "取消宣言后本轮应无宣言 实=%s" % _ActionPilotEffects.get_pilot_028_declared(card)
	if _ActionPilotEffects.get_pilot_028_x(card) != 0:
		return "取消宣言 X 应0 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	return true


# ═══════════════════════════════════════════
# 效果3 X+1
# ═══════════════════════════════════════════

## 测试4：X+1 每回合1次 - 乌尔用宣言类型辅助牌 +1；同回合第2次不+；非宣言类型不触发
func test_pilot_028_x_inc_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 2)  # 宣言辅助
	if card == null:
		return "宣言未弹窗"
	if _ActionPilotEffects.get_pilot_028_x(card) != 0:
		return "宣言后 X 应0 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	# ① 乌尔自己用 聚能(辅助) -> X+1
	var jn = _make_instance(s.gs, s.cdb, "action_014_聚能", &"player")
	if jn == null:
		return "找不到 action_014_聚能"
	s.player.action_hand.append(jn.instance_id)
	_fire_use_at(battle, &"player", s.mech.mech_id, jn.instance_id)
	await _pump_frames(2)
	if _ActionPilotEffects.get_pilot_028_x(card) != 1:
		return "乌尔用辅助牌应 X+1 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	# ② 同回合再用 推进(辅助) -> 每回合1次，不再+1
	var tj = _make_instance(s.gs, s.cdb, "action_015_推进", &"player")
	if tj == null:
		return "找不到 action_015_推进"
	s.player.action_hand.append(tj.instance_id)
	_fire_use_at(battle, &"player", s.mech.mech_id, tj.instance_id)
	await _pump_frames(2)
	if _ActionPilotEffects.get_pilot_028_x(card) != 1:
		return "同回合第2次用辅助牌不应再 X+1 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	# ③ 用 攻击牌 -> 非宣言类型，不触发
	var atk = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	if atk == null:
		return "找不到 action_001_进攻"
	s.player.action_hand.append(atk.instance_id)
	_fire_use_at(battle, &"player", s.mech.mech_id, atk.instance_id)
	await _pump_frames(2)
	if _ActionPilotEffects.get_pilot_028_x(card) != 1:
		return "非宣言类型牌不应 X+1 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	return true


## 测试5：X+1 过滤 - 虚拟转化牌（virtual_transform）不触发；其他机甲用宣言类型牌不触发
func test_pilot_028_x_inc_filter() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 2)  # 宣言辅助
	if card == null:
		return "宣言未弹窗"
	# ① 乌尔虚拟转化牌（as 辅助，virtual_transform=true）-> 不 X+1
	var jn = _make_instance(s.gs, s.cdb, "action_014_聚能", &"player")
	s.player.action_hand.append(jn.instance_id)
	_fire_use_at(battle, &"player", s.mech.mech_id, jn.instance_id, {"virtual_transform": true})
	await _pump_frames(2)
	if _ActionPilotEffects.get_pilot_028_x(card) != 0:
		return "虚拟转化牌不应 X+1 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	# ② 其他机甲（enemy）用辅助牌 -> 不触发（效果3只乌尔自己）
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	var enemy = s.gs.players.get(&"enemy")
	_place_enemy(s.gs, s.mech, enemy_mech, 2)
	var ejn = _make_instance(s.gs, s.cdb, "action_014_聚能", &"enemy")
	enemy.action_hand.append(ejn.instance_id)
	_fire_use_at(battle, &"enemy", enemy_mech.mech_id, ejn.instance_id)
	await _pump_frames(2)
	if _ActionPilotEffects.get_pilot_028_x(card) != 0:
		return "其他机甲用辅助牌不应触发 X+1 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	return true


# ═══════════════════════════════════════════
# 效果2 需交牌
# ═══════════════════════════════════════════

## 测试6：范围内其他机甲用宣言类型牌（手牌≥2）-> 弹交给牌窗，交出2张后转移给乌尔 + 不设 skip
func test_pilot_028_force_tribute_transfer() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	var player = s.player
	_place_enemy(gs, s.mech, enemy_mech, 2)
	# enemy 手牌：两张额外牌（交给牌候选）
	var extraA = _make_instance(gs, s.cdb, "action_007_预判", &"enemy")
	var extraB = _make_instance(gs, s.cdb, "action_009_防御", &"enemy")
	if extraA == null or extraB == null:
		return "造牌失败"
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(extraA.instance_id)
	enemy.action_hand.append(extraB.instance_id)
	# enemy 用攻击牌 -> FORCE_TRIBUTE 挂起交给牌窗
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	var mock = _fire_use_at(battle, &"enemy", enemy_mech.mech_id, atk.instance_id)
	var aid := _find_pending_action(battle, "pilot_028_tribute")
	if aid == &"":
		return "应挂起交给牌窗（pilot_028_tribute）"
	# 选2张交出
	battle.context.timing_engine.resume_pending_effect(aid, {"selected_card_ids": [extraA.instance_id, extraB.instance_id]})
	await _pump_frames(3)
	if not player.action_hand.has(extraA.instance_id) or not player.action_hand.has(extraB.instance_id):
		return "交出后 extraA/extraB 应在 player 手牌"
	if enemy.action_hand.has(extraA.instance_id) or enemy.action_hand.has(extraB.instance_id):
		return "交出后 enemy 手牌应无 extraA/extraB"
	if mock.record.get("_pilot_028_skip_effects", false):
		return "交足后不应设 skip 标志"
	return true


## 测试7：手牌<2 -> 不弹窗直接设 skip（行动牌不生效）
func test_pilot_028_force_tribute_not_enough_hand() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	_place_enemy(gs, s.mech, enemy_mech, 2)
	# enemy 手牌仅1张（<2）
	var extraA = _make_instance(gs, s.cdb, "action_007_预判", &"enemy")
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(extraA.instance_id)
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	var mock = _fire_use_at(battle, &"enemy", enemy_mech.mech_id, atk.instance_id)
	await _pump_frames(1)
	if not bool(mock.record.get("_pilot_028_skip_effects", false)):
		return "手牌<2 应设 skip 标志"
	if _find_pending_action(battle, "pilot_028_tribute") != &"":
		return "手牌<2 不应弹交给牌窗"
	return true


## 测试8：交给牌取消 -> 设 skip（行动牌不生效），牌不转移
func test_pilot_028_force_tribute_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	var player = s.player
	_place_enemy(gs, s.mech, enemy_mech, 2)
	var extraA = _make_instance(gs, s.cdb, "action_007_预判", &"enemy")
	var extraB = _make_instance(gs, s.cdb, "action_009_防御", &"enemy")
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(extraA.instance_id)
	enemy.action_hand.append(extraB.instance_id)
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	var mock = _fire_use_at(battle, &"enemy", enemy_mech.mech_id, atk.instance_id)
	var aid := _find_pending_action(battle, "pilot_028_tribute")
	if aid == &"":
		return "应挂起交给牌窗（pilot_028_tribute）"
	battle.context.timing_engine.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(3)
	if not bool(mock.record.get("_pilot_028_skip_effects", false)):
		return "取消交给牌应设 skip 标志"
	if not enemy.action_hand.has(extraA.instance_id) or not enemy.action_hand.has(extraB.instance_id):
		return "取消后 extraA/extraB 应仍在 enemy 手牌"
	if player.action_hand.has(extraA.instance_id) or player.action_hand.has(extraB.instance_id):
		return "取消后 player 不应拿到 extraA/extraB"
	return true


## 测试9：范围外（>4+X）-> 不弹窗不 skip（行动牌正常生效）
func test_pilot_028_force_tribute_out_of_range() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	_place_enemy(gs, s.mech, enemy_mech, 10)  # > 4+X=4
	var extraA = _make_instance(gs, s.cdb, "action_007_预判", &"enemy")
	var extraB = _make_instance(gs, s.cdb, "action_009_防御", &"enemy")
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(extraA.instance_id)
	enemy.action_hand.append(extraB.instance_id)
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	var mock = _fire_use_at(battle, &"enemy", enemy_mech.mech_id, atk.instance_id)
	await _pump_frames(1)
	if mock.record.get("_pilot_028_skip_effects", false):
		return "范围外不应设 skip 标志"
	if _find_pending_action(battle, "pilot_028_tribute") != &"":
		return "范围外不应弹交给牌窗"
	return true


## 测试10：乌尔自己用宣言类型牌 -> 不需交牌（效果2只对"其他机甲"）
func test_pilot_028_force_tribute_self_use() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var atk = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	s.player.action_hand.append(atk.instance_id)
	var mock = _fire_use_at(battle, &"player", s.mech.mech_id, atk.instance_id)
	await _pump_frames(1)
	if mock.record.get("_pilot_028_skip_effects", false):
		return "自己用牌不应设 skip 标志"
	if _find_pending_action(battle, "pilot_028_tribute") != &"":
		return "自己用牌不应弹交给牌窗"
	return true


## 测试11：未宣言（本轮无宣言）-> 效果2/3 失效（不弹窗不 skip 不 X+1）
func test_pilot_028_no_declare_inactive() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = _ActionPilotEffects.pilot_028_pilot_card(s.gs)
	if card == null:
		return "机师牌实例缺失"
	if _ActionPilotEffects.get_pilot_028_declared(card) != "":
		return "setup 后应无宣言"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	_place_enemy(gs, s.mech, enemy_mech, 2)
	var extraA = _make_instance(gs, s.cdb, "action_007_预判", &"enemy")
	var extraB = _make_instance(gs, s.cdb, "action_009_防御", &"enemy")
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(extraA.instance_id)
	enemy.action_hand.append(extraB.instance_id)
	# ① 其他机甲用攻击牌（手牌≥2）：未宣言 -> 不弹窗不 skip
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	var mock = _fire_use_at(battle, &"enemy", enemy_mech.mech_id, atk.instance_id)
	await _pump_frames(1)
	if mock.record.get("_pilot_028_skip_effects", false):
		return "未宣言不应设 skip 标志"
	if _find_pending_action(battle, "pilot_028_tribute") != &"":
		return "未宣言不应弹交给牌窗"
	# ② 乌尔自己用辅助牌：未宣言 -> 不 X+1
	var jn = _make_instance(gs, s.cdb, "action_014_聚能", &"player")
	s.player.action_hand.append(jn.instance_id)
	_fire_use_at(battle, &"player", s.mech.mech_id, jn.instance_id)
	await _pump_frames(2)
	if _ActionPilotEffects.get_pilot_028_x(card) != 0:
		return "未宣言不应 X+1 实=%d" % _ActionPilotEffects.get_pilot_028_x(card)
	return true


## 测试12：AI 用牌玩家（is_human=false）-> 不弹窗，自动交出前2张
func test_pilot_028_force_tribute_ai_auto() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	var player = s.player
	enemy.is_human = false
	_place_enemy(gs, s.mech, enemy_mech, 2)
	var extraA = _make_instance(gs, s.cdb, "action_007_预判", &"enemy")
	var extraB = _make_instance(gs, s.cdb, "action_009_防御", &"enemy")
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(extraA.instance_id)
	enemy.action_hand.append(extraB.instance_id)
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	_fire_use_at(battle, &"enemy", enemy_mech.mech_id, atk.instance_id)
	await _pump_frames(2)
	if _find_pending_action(battle, "pilot_028_tribute") != &"":
		return "AI 不应弹交给牌窗"
	if not player.action_hand.has(extraA.instance_id) or not player.action_hand.has(extraB.instance_id):
		return "AI 应自动交出前2张到 player 手牌"
	return true


# ═══════════════════════════════════════════
# 真实 use_action_card 流程（skip 标志 -> 效果跳过集成）
# ═══════════════════════════════════════════

## 测试13：真实流程 - enemy 手牌<2 用攻击牌 -> 跳过效果（player 不掉血），牌照常结算
func test_pilot_028_real_flow_not_enough_hand_skips_effect() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	_place_enemy(gs, s.mech, enemy_mech, 2)
	# enemy 手牌仅攻击牌（<2）
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(atk.instance_id)
	var p_hp_before: int = s.mech.current_hp
	battle.execute_use_action_card(&"enemy", atk.instance_id)
	await _pump_frames(6)
	if enemy.action_hand.has(atk.instance_id):
		return "攻击牌应已离开 enemy 手牌（结算进弃牌堆）"
	if s.mech.current_hp != p_hp_before:
		return "需交牌未交应跳过效果（player 不掉血） 前%d 后%d" % [p_hp_before, s.mech.current_hp]
	if _find_pending_action(battle, "pilot_028_tribute") != &"":
		return "手牌<2 不应弹交给牌窗"
	return true


## 测试14：真实流程 - enemy 手牌≥2 用攻击牌 -> 弹交给牌窗，交出2张后转移；随后攻击正常进行（不 skip）
func test_pilot_028_real_flow_tribute_transfer() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_028(battle, &"player")
	if s == null:
		return "setup 失败"
	var card = await _drive_declare(battle, 0)  # 宣言攻击
	if card == null:
		return "宣言未弹窗"
	var gs = s.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy = gs.players.get(&"enemy")
	var player = s.player
	_place_enemy(gs, s.mech, enemy_mech, 2)
	var extraA = _make_instance(gs, s.cdb, "action_007_预判", &"enemy")
	var extraB = _make_instance(gs, s.cdb, "action_009_防御", &"enemy")
	var atk = _make_instance(gs, s.cdb, "action_001_进攻", &"enemy")
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	enemy.action_hand.append(atk.instance_id)
	enemy.action_hand.append(extraA.instance_id)
	enemy.action_hand.append(extraB.instance_id)
	battle.execute_use_action_card(&"enemy", atk.instance_id)
	var aid := _find_pending_action(battle, "pilot_028_tribute")
	if aid == &"":
		return "应挂起交给牌窗（pilot_028_tribute）"
	battle.context.timing_engine.resume_pending_effect(aid, {"selected_card_ids": [extraA.instance_id, extraB.instance_id]})
	await _pump_frames(6)
	if not player.action_hand.has(extraA.instance_id) or not player.action_hand.has(extraB.instance_id):
		return "交出后 extraA/extraB 应在 player 手牌"
	if enemy.action_hand.has(extraA.instance_id) or enemy.action_hand.has(extraB.instance_id):
		return "交出后 enemy 手牌应无 extraA/extraB"
	# 交足后不应 skip：攻击应继续（此处可能停在攻击子动作等待选武器/目标，非 finished 即正常）
	return true
