## test_pilot_integration.gd — 机师牌效果集成测试（触发链 + 换机师隔离）· PvP 双人类玩家
##
## 与 test_pilot_system.gd（机制层单测：直接调 game_actions/_handle）不同，本文件用
## fire_timing + _execute_effect_by_id 驱动已注册的 pilot LISTEN/DIRECT effect 走完整
## 触发链（条件→目标→挂起→恢复），验证注册→触发→弹窗→结果 全链路。
##
## 专注 PvP 双人类玩家模式：_new_battle 复用 start_tutorial 但设 enemy.is_human=true
## + rng_seed + pvp_map_features（与 app_root._start_pvp_host 一致）。逻辑按 player_id 通用路由。
##
## 覆盖：
##   - pilot_006 e3 战后逼迫完整链（ATTACK_SETTLE → 二选一 → 4伤害 / 选攻击牌）
##   - pilot_007 e2 类型破绽 ATTACK_PRE 触发链（含非实体牌不触发）
##   - pilot_009 DIRECT 蛇发支配触发链（target 弹窗路由 + reveal 挂起）
##   - 换机师隔离：旧 listener 注销 + 各机师变量（pilot_002 批次/pilot_003 skip/pilot_009 控制）清除
##
## 注意：每个测试结束清理 pilot 静态，避免污染后续测试文件（weapon_135 等抽牌数受
## _pilot_003_skip 影响）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _DevModeService = preload("res://scripts/services/DevModeService.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	# PvP 双人类玩家：同种子 + 地图特征 + enemy 人类（与 app_root._start_pvp_host 一致）
	battle.rng_seed = 12345
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	_clear_all_pilot_static()
	return battle


## 清空全部 pilot 静态状态（_pilot_006_marks/_pilot_009_control/_pilot_002_batches/_pilot_003_skip）
func _clear_all_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_006_marks.keys():
		_ActionPilotEffects.clear_pilot_006_mark(src)
	var ctl_sources: Array = []
	for target in _ActionPilotEffects._pilot_009_control.keys():
		var types: Dictionary = _ActionPilotEffects._pilot_009_control[target]
		for ct in types.keys():
			ctl_sources.append(types[ct].get("source_pilot", &""))
	for s in ctl_sources:
		_ActionPilotEffects.clear_pilot_009_control_for_source(s)
	var b_sources: Array = []
	for bid in _ActionPilotEffects._pilot_002_batches.keys():
		b_sources.append(_ActionPilotEffects._pilot_002_batches[bid].get("grant_source", &""))
	for s in b_sources:
		_ActionPilotEffects.clear_pilot_002_batches_for_source(s)
	for src in _ActionPilotEffects._pilot_003_skip.keys():
		_ActionPilotEffects.clear_pilot_003_skip_for_source(src)


## 建一张牌实例并登记到 gs.cards（card_def_id 带_名字后缀）
func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 构造一个已注册的 attack 动作（running 态），返回 action
## extra 会合并进 record（如 source_pos/target_pos/distance/attack_card_id）
func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_integ_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 推进若干帧，让 call_deferred 排入的子动作恢复/续跑 flush
func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


## 清空地图全部格子地形为 NORMAL（避免 pvp_map_features 随机 GREEN/RED 干扰武器射程 BFS）
func _clear_map_terrain(battle) -> void:
	var ms = battle.context.game_state.map_state
	if ms == null:
		return
	for key in ms.cells:
		ms.cells[key].terrain = &"NORMAL"


## ── pilot_006 e3 战后逼迫：完整触发链（enemy 无攻击牌 → 自动回落4伤害）──
## 拆解场景f操作A：被选机甲直接受4伤害。断言：effect 触发 → 二选一只有"4伤害"可用
## → 自动选 → enemy HP-4。验证 fire_timing 驱动注册的 LISTEN effect 全链。
func test_pilot_006_effect03_full_chain_auto_fallback() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	enemy_mech.position = {"q": 4, "r": 2}
	_clear_map_terrain(battle)
	var card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	enemy.action_hand.clear()
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	# 阻塞式 priority 30：effect_03 在 ATTACK_SETTLE 先于闪击/反击挂起
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	if attack.state != &"waiting_timing":
		return "effect_03 应挂起确认弹窗 state=%s" % String(attack.state)
	# 先确认发动（confirm_before_target 通用机制，里昂可取消）再选机甲
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# enemy 无攻击牌 -> CHOOSE_ONE 仅剩"4伤害" -> 自动选 -> HP-4
	if enemy_mech.current_hp != hp_before - 4:
		return "无攻击牌应回落4伤害 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	_clear_all_pilot_static()
	return true


## ── pilot_006 e3 完整链：enemy 有攻击牌 → 二选一挂起 → 选4伤害 ──
## 拆解场景e/f：被选机甲有攻击牌时弹二选一；选"受到4伤害"分支生效。
func test_pilot_006_effect03_full_chain_choose_4damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	enemy_mech.position = {"q": 4, "r": 2}
	_clear_map_terrain(battle)
	var card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	var atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	if atk == null:
		return "找不到 action_001_进攻"
	enemy.action_hand.append(atk.instance_id)
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	if attack.state != &"waiting_timing":
		return "effect_03 应挂起确认弹窗 state=%s" % String(attack.state)
	# 先确认发动（里昂可取消）再选机甲
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# enemy 有攻击牌+武器射程覆盖 -> 两 option 可用 -> 挂起二选一
	if attack.state != &"waiting_timing":
		return "选机甲后应挂起二选一弹窗 state=%s" % String(attack.state)
	if not battle.context.timing_engine._pending_effect.has(attack.action_id):
		return "_pending_effect 应有二选一挂起记录"
	# 选"受到4伤害"（option index 1）
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 1})
	if enemy_mech.current_hp != hp_before - 4:
		return "选4伤害后应 HP-4 实=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	_clear_all_pilot_static()
	return true


## ── pilot_006 e3 完整链：enemy 有攻击牌 → 选"立即使用攻击牌" → 挂起选牌 ──
## 拆解场景e：M2 选"立即使用攻击牌"，PILOT_006_FORCE_USE_ATTACK 挂起 select 窗。
func test_pilot_006_effect03_choose_attack_card_suspend() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	enemy_mech.position = {"q": 4, "r": 2}
	_clear_map_terrain(battle)
	var card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	var atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	if atk == null:
		return "找不到 action_001_进攻"
	enemy.action_hand.append(atk.instance_id)
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	# 先确认发动（里昂可取消）再选机甲
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# 选"立即使用1张攻击牌"（option index 0）
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	# 应挂起 select_pilot_006_attack_card（被选机甲=enemy 手牌有攻击牌）
	var pending: Dictionary = battle.context.timing_engine._pending_effect.get(attack.action_id, {})
	if String(pending.get("phase", &"")) != "pilot_006_force_use_attack":
		return "选攻击牌后应挂起 pilot_006_force_use_attack，实=%s" % String(pending.get("phase", &""))
	_clear_all_pilot_static()
	return true


## ── pilot_006 e2 狩猎追击：主攻击与闪击/反击额外攻击的 ATTACK_PRE 都应抽牌 ──
## 里昂标记 enemy_mech 后，每次 ATTACK_PRE（主攻击A 与 额外攻击B）都应让攻击方抽1张。
## 复现问题4A：闪击/反击额外攻击打标记目标不抽牌。
func test_pilot_006_effect02_main_and_sub_attack_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	enemy_mech.position = {"q": 4, "r": 2}
	_clear_map_terrain(battle)
	var card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# 标记 enemy_mech 为本轮狩猎目标
	_ActionPilotEffects.set_pilot_006_mark(card.instance_id, enemy_mech.mech_id, gs)
	# 保证牌堆非空
	if gs.deck_state.action_deck.is_empty():
		return "行动牌堆为空，无法测试抽牌"
	var player = gs.players.get(&"player")
	var hand_before: int = player.action_hand.size()
	# ── 主攻击A：ATTACK_PRE 触发 e2 抽1张 ──
	var attack_a := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack_a)
	# effect_02 直接自动抽牌（无确认弹窗）
	if player.action_hand.size() != hand_before + 1:
		return "主攻击A的ATTACK_PRE应抽1张 实=%d（before=%d）" % [player.action_hand.size(), hand_before]
	# ── 额外攻击B（闪击/反击 spawn 的子攻击）：同样ATTACK_PRE应再抽1张 ──
	var hand_after_a: int = player.action_hand.size()
	var attack_b := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack_b)
	# effect_02 直接自动抽牌（无确认弹窗）
	if player.action_hand.size() != hand_after_a + 1:
		return "额外攻击B的ATTACK_PRE应再抽1张 实=%d（after_a=%d）" % [player.action_hand.size(), hand_after_a]
	_clear_all_pilot_static()
	return true


## ── pilot_007 e2 类型破绽：ATTACK_PRE 触发链 ──
## 拆解场景d：P1 珀修斯用真实攻击牌攻击 P2；P2 手牌缺类（X>0）→ 弃 X+1 抽 X+1。
## 通过 fire_timing(ATTACK_PRE) 驱动注册的 LISTEN effect。
func test_pilot_007_effect02_attack_pre_chain() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var card = _make_instance(gs, cdb, "pilot_007_珀修斯", &"player")
	if card == null:
		return "找不到 pilot_007_珀修斯"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	# 攻击来源实体攻击牌（action_001_进攻 实例）
	var src_atk = _make_instance(gs, cdb, "action_001_进攻", &"player")
	if src_atk == null:
		return "找不到 action_001_进攻"
	# enemy 手牌：3张攻击 → 只有{攻击}1类 → X=2 → 弃3抽3
	enemy.action_hand.clear()
	for i in 3:
		var a = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
		if a == null:
			return "找不到 action_001_进攻"
		enemy.action_hand.append(a.instance_id)
	var p_hand_before: int = player.action_hand.size()
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {
		"attack_card_id": src_atk.instance_id,
	})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# enemy 3张攻击（1类）→ X=2 → 弃3抽3
	if attack.state != &"waiting_timing":
		return "effect_02 CHOOSE_ONE 应挂起，state=%s" % String(attack.state)
	# 确认「查看并弃置目标行动牌」
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# 应弹 select_discard_cards（弃 enemy 明牌，count=3，无取消键）
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait_info.get("input_type", &"")) != &"select_discard_cards":
		return "确认后应弹 select_discard_cards，wait=%s" % str(wait_info)
	var input_params: Dictionary = wait_info.get("input_params", {})
	if int(input_params.get("count", 0)) != 3:
		return "弃牌 count 应=3(X+1) 实=%d" % int(input_params.get("count", 0))
	if String(input_params.get("discard_player_id", &"")) != "enemy":
		return "弃牌对象应为 enemy 实=%s" % String(input_params.get("discard_player_id", &""))
	if not bool(input_params.get("no_cancel", false)):
		return "no_cancel 应为 true（强制弃牌无取消键）"
	# 选 enemy 全部3张弃置
	var chosen: Array = enemy.action_hand.slice(0, 3)
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": chosen})
	await _pump_frames(4)
	# enemy 3张全弃 -> 0；player 抽 X+1=3
	if enemy.action_hand.size() != 0:
		return "类型破绽应弃3张 实剩=%d" % enemy.action_hand.size()
	if player.action_hand.size() != p_hand_before + 3:
		return "类型破绽应抽3 实增=%d" % (player.action_hand.size() - p_hand_before)
	_clear_all_pilot_static()
	return true


## 创建一台归 owner_id 玩家所有的机甲（6 部件槽，无装备，护甲=0），返回 MechState。
func _create_owned_mech(battle, mech_id: StringName, owner_id: StringName, pos: Dictionary):
	var gs = battle.context.game_state
	var m = _MechState.new()
	m.mech_id = mech_id
	m.owner_player_id = owner_id
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


## 为指定玩家创建 PlayerState 并登记（player2 多目标测试用）
func _create_player(battle, player_id: StringName) -> void:
	var gs = battle.context.game_state
	if gs.players.has(player_id):
		return
	var p := _PlayerState.new()
	p.player_id = player_id
	p.is_human = true
	gs.players[player_id] = p


## ── pilot_007 e2 双连多目标：按目标选择顺序逐个执行 ──
## 珀修斯攻击同时命中2台机甲（目标1=enemy 3张攻击牌 X=2；目标2=player2 攻击+迎击+辅助 X=0）。
## FOR_EACH_TARGET 串行逐目标：先目标1（弹弃3张窗）→确认→再目标2（弹弃1张窗）→确认→珀修斯抽3+1=4。
func test_pilot_007_effect02_multi_target_per_target_order() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var card = _make_instance(gs, cdb, "pilot_007_珀修斯", &"player")
	if card == null:
		return "找不到 pilot_007_珀修斯"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var src_atk = _make_instance(gs, cdb, "action_001_进攻", &"player")
	if src_atk == null:
		return "找不到 action_001_进攻"
	# 第2台目标机甲：归 player2 所有（不同手牌来源，验证逐目标路由）
	_create_player(battle, &"player2")
	var target2_mech = _create_owned_mech(battle, &"p007_target2", &"player2", {"q": 2, "r": 3})
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	var player2 = gs.players.get(&"player2")
	# 目标1(enemy)：3张攻击 -> 只有{攻击}1类 -> X=2 -> 弃3抽3
	enemy.action_hand.clear()
	for i in 3:
		var a = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
		enemy.action_hand.append(a.instance_id)
	# 目标2(player2)：攻击+迎击+辅助 3类齐 -> X=0 -> 弃1抽1
	player2.action_hand.clear()
	for cid_name in [&"action_001_进攻", &"action_010_反击", &"action_022_补给"]:
		var c = _make_instance(gs, cdb, String(cid_name), &"player2")
		if c == null:
			return "找不到 %s" % String(cid_name)
		player2.action_hand.append(c.instance_id)
	var p_hand_before: int = player.action_hand.size()
	# 攻击：目标1在前（选择顺序）
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {
		"attack_card_id": src_atk.instance_id,
		"target_ids": [enemy_mech.mech_id, target2_mech.mech_id],
		"target_count": 2,
	})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "effect_02 CHOOSE_ONE 应挂起，state=%s" % String(attack.state)
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	# ── 目标1：弹 enemy 弃3张窗 ──
	var wait1: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait1.get("input_type", &"")) != &"select_discard_cards":
		return "目标1应弹 select_discard_cards，wait=%s" % str(wait1.get("input_type", &""))
	var p1: Dictionary = wait1.get("input_params", {})
	if int(p1.get("count", 0)) != 3:
		return "目标1 弃牌 count 应=3 实=%d" % int(p1.get("count", 0))
	if String(p1.get("discard_player_id", &"")) != "enemy":
		return "目标1 弃牌对象应 enemy 实=%s" % String(p1.get("discard_player_id", &""))
	if String(p1.get("executor", &"")) != "player":
		return "目标1 弃牌执行者应 player(珀修斯) 实=%s" % String(p1.get("executor", &""))
	if not bool(p1.get("face_up", false)):
		return "目标1 应明牌选弃 face_up=true"
	if not bool(p1.get("no_cancel", false)):
		return "目标1 应 no_cancel=true"
	# 确认目标1弃 enemy 3张（全弃）
	var discard1: Array = enemy.action_hand.slice(0, 3)
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": discard1})
	await _pump_frames(8)
	if not enemy.action_hand.is_empty():
		return "目标1 应弃3张（enemy 手牌应空）实剩=%d" % enemy.action_hand.size()
	# ── 目标2：再弹 player2 弃1张窗（逐目标串行，确认目标1后才轮到目标2）──
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_discard_cards":
		return "目标1确认后应轮到目标2弹窗，wait=%s" % str(wait2.get("input_type", &""))
	var p2: Dictionary = wait2.get("input_params", {})
	if int(p2.get("count", 0)) != 1:
		return "目标2 弃牌 count 应=1(X=0) 实=%d" % int(p2.get("count", 0))
	if String(p2.get("discard_player_id", &"")) != "player2":
		return "目标2 弃牌对象应 player2 实=%s" % String(p2.get("discard_player_id", &""))
	var discard2_cid: StringName = player2.action_hand[0]
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": [discard2_cid]})
	await _pump_frames(12)
	# 目标2弃1：player2 手牌 3->2
	if player2.action_hand.size() != 2:
		return "目标2 应弃1张（player2 手牌应剩2）实=%d" % player2.action_hand.size()
	# 珀修斯共抽 3+1=4
	if player.action_hand.size() != p_hand_before + 4:
		return "双连逐目标应共抽4(3+1) 前=%d 后=%d" % [p_hand_before, player.action_hand.size()]
	_clear_all_pilot_static()
	return true


## ── pilot_007 e2 条件不满足：攻击来源非实体牌（武器 DIRECT）→ 不触发 ──
## 拆解场景c前置B：攻击来源为武器 DIRECT（无 attack_card_id）→ effect_02 不弹窗。
func test_pilot_007_effect02_skip_when_no_physical_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var card = _make_instance(gs, cdb, "pilot_007_珀修斯", &"player")
	if card == null:
		return "找不到 pilot_007_珀修斯"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	enemy.action_hand.clear()
	for i in 3:
		var a = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
		enemy.action_hand.append(a.instance_id)
	var p_hand_before: int = gs.players.get(&"player").action_hand.size()
	# 无 attack_card_id（武器 DIRECT 攻击）→ ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD 不满足
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if enemy.action_hand.size() != 3:
		return "非实体牌攻击不应触发类型破绽 实剩=%d" % enemy.action_hand.size()
	if gs.players.get(&"player").action_hand.size() != p_hand_before:
		return "非实体牌攻击不应抽牌 实增=%d" % (gs.players.get(&"player").action_hand.size() - p_hand_before)
	_clear_all_pilot_static()
	return true


## ── pilot_009 DIRECT 蛇发支配：使用路径（弃1记录类型 → 授予目标控制）──
## P1 美杜莎主阶段、范围5内有目标 → DIRECT 触发 → 目标选择 → 弹窗①弃1自己攻击牌(记录类型)
## → 弹窗②选“使用” → 授予目标攻击牌控制（非排他，本回合有效；目标手牌不弃）。
func test_pilot_009_effect01_use_path_grants_control() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_009_美杜莎", &"player")
	if card == null:
		return "找不到 pilot_009_美杜莎"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	# P1 手牌有攻击牌（支付）+ 敌方手牌有攻击牌（受控目标）
	player.action_hand.clear()
	var pay_atk = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(pay_atk.instance_id)
	enemy.action_hand.clear()
	var enemy_atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	enemy.action_hand.append(enemy_atk.instance_id)
	var fire := _Action.new()
	fire.action_id = &"test_p009_use"
	fire.action_type = &"effect_fire"
	fire.record = {"effect_id": &"pilot_009_effect_01", "card_instance_id": card.instance_id, "player_id": &"player", "source_mech_id": player_mech.mech_id}
	fire.state = &"running"
	fire.context = battle.context
	battle.context.action_registry.register(fire)
	battle.context.timing_engine._execute_effect_by_id(&"pilot_009_effect_01", fire.record, fire)
	# ① 目标选择挂起（CHOOSE_OTHER_MECH，弹窗归属 P1 人类）
	if fire.state != &"waiting_timing":
		return "应挂起目标选择，state=%s" % String(fire.state)
	if not battle.context.timing_engine._pending_effect.has(fire.action_id):
		return "_pending_effect 应有目标选择挂起记录"
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"target_id": enemy_mech.mech_id})
	# ② 弹窗① 支付挂起（pilot_009_pay 阶段）
	if fire.state != &"waiting_timing":
		return "选目标后应挂起支付选择，state=%s" % String(fire.state)
	var pend = battle.context.timing_engine._pending_effect.get(fire.action_id, {})
	if String(pend.get("phase", "")) != "pilot_009_pay":
		return "应处于 pilot_009_pay 阶段，phase=%s" % String(pend.get("phase", ""))
	# 弃1攻击牌支付（记录类型=攻击）
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"selected_action_card_ids": [pay_atk.instance_id]})
	if player.action_hand.has(pay_atk.instance_id):
		return "支付后应弃置选定牌"
	if fire.state != &"waiting_timing":
		return "支付后应挂起二选一，state=%s" % String(fire.state)
	# ③ 弹窗② 选“使用”(index 0) → 授予控制
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"chosen_option_index": 0})
	if not _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "选使用后应授予目标攻击牌控制"
	if not enemy.action_hand.has(enemy_atk.instance_id):
		return "使用路径不应弃置目标手牌"
	_clear_all_pilot_static()
	return true


## ── pilot_009 DIRECT 蛇发支配：立即弃置路径（弃1记录类型 → 弃目标该类型全部牌）──
## 弹窗②选“立即弃置” → 弃目标当前全部攻击牌（不授控制，后续新牌不管）。
func test_pilot_009_effect01_immediate_discard_path() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_009_美杜莎", &"player")
	if card == null:
		return "找不到 pilot_009_美杜莎"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	player.action_hand.clear()
	var pay_atk = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(pay_atk.instance_id)
	enemy.action_hand.clear()
	var enemy_atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	enemy.action_hand.append(enemy_atk.instance_id)
	var fire := _Action.new()
	fire.action_id = &"test_p009_discard"
	fire.action_type = &"effect_fire"
	fire.record = {"effect_id": &"pilot_009_effect_01", "card_instance_id": card.instance_id, "player_id": &"player", "source_mech_id": player_mech.mech_id}
	fire.state = &"running"
	fire.context = battle.context
	battle.context.action_registry.register(fire)
	battle.context.timing_engine._execute_effect_by_id(&"pilot_009_effect_01", fire.record, fire)
	if fire.state != &"waiting_timing":
		return "应挂起目标选择，state=%s" % String(fire.state)
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"target_id": enemy_mech.mech_id})
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"selected_action_card_ids": [pay_atk.instance_id]})
	if fire.state != &"waiting_timing":
		return "支付后应挂起二选一，state=%s" % String(fire.state)
	# ③ 选“立即弃置”(index 1) → 弃目标全部攻击牌
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"chosen_option_index": 1})
	if enemy.action_hand.has(enemy_atk.instance_id):
		return "立即弃置后应弃置目标全部攻击牌"
	if _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "立即弃置路径不应授予控制"
	if not gs.deck_state.action_discard_pile.has(enemy_atk.instance_id):
		return "目标牌应进入行动牌弃牌堆"
	_clear_all_pilot_static()
	return true


## ── pilot_009 DIRECT 取消目标选择：不消耗、不建立控制 ──
## 拆解场景d：目标选择后取消 → 无 reveal/支付/control。
func test_pilot_009_effect01_cancel_target() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_009_美杜莎", &"player")
	if card == null:
		return "找不到 pilot_009_美杜莎"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	player.action_hand.clear()
	var pay_atk = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(pay_atk.instance_id)
	var fire := _Action.new()
	fire.action_id = &"test_p009_cancel"
	fire.action_type = &"effect_fire"
	fire.record = {"effect_id": &"pilot_009_effect_01", "card_instance_id": card.instance_id, "player_id": &"player", "source_mech_id": player_mech.mech_id}
	fire.state = &"running"
	fire.context = battle.context
	battle.context.action_registry.register(fire)
	battle.context.timing_engine._execute_effect_by_id(&"pilot_009_effect_01", fire.record, fire)
	if fire.state != &"waiting_timing":
		return "应挂起目标选择"
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"cancelled": true})
	# 取消后：无控制、无支付、无 reveal 子动作
	if _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "取消后不应建立控制"
	if not player.action_hand.has(pay_atk.instance_id):
		return "取消后不应支付弃牌"
	if not fire.pending_effect_action_ids.is_empty():
		return "取消后不应创建 reveal 子动作"
	_clear_all_pilot_static()
	return true


## ── 换机师隔离：旧 listener 注销 + 各机师变量清除 ──
## set pilot_006 里昂 → ATTACK_SETTLE 注册 effect_03 → dev change_pilot → 旧 listener 注销。
func test_swap_pilot_unregisters_old_listener() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "机甲缺失"
	var dev := _DevModeService.new()
	dev.context = battle.context
	var card6 = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card6)
	var te = battle.context.timing_engine
	var found_06 := false
	for entry in te.permanent_listeners.get(_TimingConst.ATTACK_SETTLE, []):
		var eff = entry.get("effect")
		if eff != null and String(eff.effect_id) == "pilot_006_effect_03":
			found_06 = true
	if not found_06:
		return "pilot_006_effect_03 应注册到 ATTACK_SETTLE"
	var result: Dictionary = dev.change_pilot(&"player", &"pilot_010_刻托")
	if not result.get("ok", false):
		return "change_pilot 应成功 实=%s" % String(result.get("message", ""))
	for entry in te.permanent_listeners.get(_TimingConst.ATTACK_SETTLE, []):
		var eff = entry.get("effect")
		if eff != null and String(eff.effect_id) == "pilot_006_effect_03":
			return "换机师后 pilot_006_effect_03 应注销"
	_clear_all_pilot_static()
	return true


## ── 换机师隔离：pilot_009 美杜莎换下 → 控制立即解除（裁定歧义5）──
func test_swap_pilot_clears_pilot_009_control() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var dev := _DevModeService.new()
	dev.context = battle.context
	var card9 = _make_instance(gs, cdb, "pilot_009_美杜莎", &"player")
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card9)
	# 用美杜莎实例作 source 建立控制（真实来源）
	_ActionPilotEffects.grant_temp_card_control(enemy_mech.mech_id, &"攻击", &"player", card9.instance_id)
	if not _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "前置：控制应建立"
	var result: Dictionary = dev.change_pilot(&"player", &"pilot_010_刻托")
	if not result.get("ok", false):
		return "change_pilot 应成功"
	if _ActionPilotEffects.is_card_type_controlled_by(enemy_mech.mech_id, &"攻击", &"player"):
		return "换机师后 pilot_009 控制应解除"
	_clear_all_pilot_static()
	return true


## ── 换机师隔离：pilot_003 瑟尔基尔换下 → skip 清除 ──
func test_swap_pilot_clears_pilot_003_skip() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "机甲缺失"
	var dev := _DevModeService.new()
	dev.context = battle.context
	var card3 = _make_instance(gs, cdb, "pilot_003_瑟尔基尔", &"player")
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card3)
	# 用瑟尔基尔实例作 source 开启 skip
	_ActionPilotEffects.toggle_pilot_003_skip(card3.instance_id, &"player", true)
	if not _ActionPilotEffects.is_pilot_003_skip_active(&"player"):
		return "前置：skip 应开启"
	var result: Dictionary = dev.change_pilot(&"player", &"pilot_010_刻托")
	if not result.get("ok", false):
		return "change_pilot 应成功"
	if _ActionPilotEffects.is_pilot_003_skip_active(&"player"):
		return "换机师后 pilot_003 skip 应清除"
	_clear_all_pilot_static()
	return true


## ── pilot_003 effect_03 复选框：SET_PILOT_003_SKIP_PLAYERS 整组覆盖 + 多玩家抽牌行为 ──
## 裁定权威"重要补充"：勾选多个玩家 → 被勾选者抽牌跳过正面牌；自己勾选且将抽到正面牌时
## 抽牌数+1。验证：勾选 [player, enemy] → 双方抽牌都跳过正面牌；改勾选只留 enemy → player 恢复正常。
func test_pilot_003_checkbox_multiplayer_skip() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var card3 = _make_instance(gs, cdb, "pilot_003_瑟尔基尔", &"player")
	if card3 == null:
		return "找不到 pilot_003_瑟尔基尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card3)
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	var ga = battle.context.game_actions
	# 插入1张正面牌（瑟尔基尔 effect_01 逻辑）到牌堆顶
	var face_card = _make_instance(gs, cdb, "action_001_进攻", &"player")
	if face_card == null:
		return "找不到 action_001_进攻"
	player.action_hand.append(face_card.instance_id)
	var payload3: Dictionary = {"binding_context": {"card_instance_id": card3.instance_id, "mech_id": player_mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload3)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	if gs.deck_state.action_deck[0] != face_card.instance_id:
		return "正面牌应位于牌堆顶"
	# 复选框勾选 [player, enemy]
	var bind3: Dictionary = {"binding_context": {"card_instance_id": card3.instance_id, "player_id": &"player"}}
	ga.set_pilot_003_skip_players({"player_ids": ["player", "enemy"]}, bind3)
	# player 抽1 → skip+1=抽2，跳过正面牌（正面牌仍在牌堆）
	var p_hand_before: int = player.action_hand.size()
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_checkbox"})
	if not gs.deck_state.action_deck.has(face_card.instance_id):
		return "勾选后 player 抽牌应跳过正面牌（正面牌仍在牌堆）"
	if player.action_hand.size() != p_hand_before + 2:
		return "player 勾选应抽2（1+1）实增=%d" % (player.action_hand.size() - p_hand_before)
	# 改勾选只留 enemy → player 恢复正常（抽1不+1）。
	# 先把牌堆顶正面牌移出牌堆（否则 player 抽牌会触发 effect_02 离堆拦截 + 拥有者补偿抽1，
	# 使手牌 +2，非本测试目标），确保断言只反映 +1 增益。
	gs.deck_state.action_deck.erase(face_card.instance_id)
	ga.set_pilot_003_skip_players({"player_ids": ["enemy"]}, bind3)
	var p_hand_before2: int = player.action_hand.size()
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_checkbox2"})
	# player 未勾选 → 正常抽1（不 +1）
	if player.action_hand.size() != p_hand_before2 + 1:
		return "player 未勾选应抽1 实增=%d" % (player.action_hand.size() - p_hand_before2)
	# enemy 勾选 → enemy 抽牌跳过正面牌（把正面牌放回牌堆顶再测）
	gs.deck_state.action_deck.push_front(face_card.instance_id)
	var enemy_hand_before: int = enemy.action_hand.size()
	ga.draw_action_cards({"player_id": &"enemy", "count": 1, "reason": &"test_p003_checkbox3"})
	if not gs.deck_state.action_deck.has(face_card.instance_id):
		return "enemy 勾选后抽牌应跳过正面牌"
	if enemy.action_hand.size() != enemy_hand_before + 1:
		return "enemy 勾选应抽1（+1 仅瑟尔基尔自己有效）实增=%d" % (enemy.action_hand.size() - enemy_hand_before)
	_clear_all_pilot_static()
	return true


## ── 换机师隔离：pilot_002 莱比尔换下 → 批次权限全清（裁定歧义4）──
func test_swap_pilot_clears_pilot_002_batches() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var dev := _DevModeService.new()
	dev.context = battle.context
	var card2 = _make_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card2)
	var b1 = _make_instance(gs, cdb, "action_001_进攻", &"player")
	_ActionPilotEffects.register_pilot_002_batch("test_batch_swap", enemy_mech.mech_id, [b1.instance_id], &"进攻", card2.instance_id)
	var found_batch := false
	for bid in _ActionPilotEffects._pilot_002_batches:
		if String(_ActionPilotEffects._pilot_002_batches[bid].get("grant_source", &"")) == String(card2.instance_id):
			found_batch = true
	if not found_batch:
		return "前置：批次应登记"
	var result: Dictionary = dev.change_pilot(&"player", &"pilot_010_刻托")
	if not result.get("ok", false):
		return "change_pilot 应成功"
	for bid in _ActionPilotEffects._pilot_002_batches:
		if String(_ActionPilotEffects._pilot_002_batches[bid].get("grant_source", &"")) == String(card2.instance_id):
			return "换机师后 pilot_002 批次应全清"
	_clear_all_pilot_static()
	return true


## ── pilot_012 e1 夺牌压制：enemy 无行动牌 -> CONDITIONAL if_false 不偷，只减本身动力3 ──
## ATTACK_PRE 触发 CHOOSE_ONE optional -> 选执行 -> FOR_EACH_TARGET(enemy):
##   TARGET_HAS_ACTION_CARD=0 -> if_false 跳过偷 -> MODIFY_MECH_POWER current -3 clamp[0,max]。
func test_pilot_012_effect01_power_drain_no_cards() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_012_玛丽尔", &"player")
	if card == null:
		return "找不到 pilot_012_玛丽尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	enemy.action_hand.clear()  # 无行动牌 -> CONDITIONAL if_false
	var own_before: int = enemy_mech.get_own_power()
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "effect_01 CHOOSE_ONE 应挂起 waiting_timing，state=%s" % String(attack.state)
	# 选"执行"（option index 0）
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	var own_after: int = enemy_mech.get_own_power()
	if own_after != max(0, own_before - 3):
		return "enemy 本身动力应-3 clamp0 实=%d before=%d" % [own_after, own_before]
	if not enemy.action_hand.is_empty():
		return "enemy 无牌不应获得牌"
	_clear_all_pilot_static()
	return true


## ── pilot_012 e1 夺牌压制：enemy 有行动牌 -> 偷1张 + 减本身动力3 ──
## CONDITIONAL if_true -> EXECUTE_STEAL（暗牌选牌 UI）-> 提交选牌 -> MODIFY_MECH_POWER。
func test_pilot_012_effect01_steal_and_power_drain() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_012_玛丽尔", &"player")
	if card == null:
		return "找不到 pilot_012_玛丽尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	enemy.action_hand.clear()
	var atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	if atk == null:
		return "找不到 action_001_进攻"
	enemy.action_hand.append(atk.instance_id)
	var player = gs.players.get(&"player")
	var own_before: int = enemy_mech.get_own_power()
	var player_hand_before: int = player.action_hand.size()
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "effect_01 CHOOSE_ONE 应挂起，state=%s" % String(attack.state)
	# 选执行 -> FOR_EACH_TARGET(enemy): if_true EXECUTE_STEAL 挂起暗牌选牌
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	# EXECUTE_STEAL 应挂起 select_discard_cards（enemy 手牌对 player 暗牌）
	var bridge = battle.context.action_ui_bridge
	bridge.on_ui_confirmed({"determined_card_ids": [atk.instance_id]})
	# steal 完成 -> parent notify call_deferred -> 下一帧 _after_sub_action_finished 续跑 flat（MODIFY_MECH_POWER）
	await (Engine.get_main_loop() as SceneTree).process_frame
	# 偷牌：enemy 手牌-1，player 手牌+1
	if enemy.action_hand.size() != 0:
		return "偷牌后 enemy 手牌应空，实=%d" % enemy.action_hand.size()
	if player.action_hand.size() != player_hand_before + 1:
		return "偷牌后 player 手牌应+1 实=%d before=%d" % [player.action_hand.size(), player_hand_before]
	if not player.action_hand.has(atk.instance_id):
		return "偷来的牌应在 player 手牌中"
	# 动力-3
	var own_after: int = enemy_mech.get_own_power()
	if own_after != max(0, own_before - 3):
		return "enemy 本身动力应-3 clamp0 实=%d before=%d" % [own_after, own_before]
	_clear_all_pilot_static()
	return true


## ── pilot_012 e2 命中奖励：e1 已发动 + 攻击命中 -> 逐目标 CHOOSE_ONE -> 抽1张+回3动力 ──
## e1 已有独立测试（effect01_power_drain_no_cards / steal_and_power_drain）。本测试聚焦 e2：
## 用 attack.record._effect_flags 模拟 e1 已发动（SET_ACTION_RECORD_FLAG 写 flag，e2 据此判定），
## fire ATTACK_AFTER 验证 e2 命中奖励（RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT + FOR_EACH_TARGET inner CHOOSE_ONE 串行弹窗）。
## 注：真实流程 attack 在 ATTACK_PRE/ATTACK_AFTER 步骤间不 completed，flag 保留；测试简化 attack
## 无 steps，若 fire ATTACK_PRE+resume 会触发 continue_action cleanup 清标记+注销 action，故直接模拟 flag。
func test_pilot_012_effect02_hit_reward() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_012_玛丽尔", &"player")
	if card == null:
		return "找不到 pilot_012_玛丽尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	# hit=true -> ATTACK_AFTER payload.hit=true -> e2 命中条件通过
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2, "hit": true})
	# 模拟 e1 已发动（SET_ACTION_RECORD_FLAG 写 flag 到 attack.record._effect_flags，e2 据此判定）
	attack.record["_effect_flags"] = {"pilot_012_effect_01_fired": {"value": true, "data": {}}}
	var player_hand_before: int = player.action_hand.size()
	player_mech.adjust_own_power(-99)  # 降到0，确保回3动力可观测
	if player_mech.get_own_power() != 0:
		return "player 动力应已降至0，实=%d" % player_mech.get_own_power()
	# ATTACK_AFTER -> e2 命中奖励（FOR_EACH_TARGET inner CHOOSE_ONE 串行弹窗）
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if attack.state != &"waiting_effect_action":
		return "e2 命中奖励应挂起 waiting_effect_action，state=%s" % String(attack.state)
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	# 验证：抽1张行动牌 + 回3动力
	if player.action_hand.size() != player_hand_before + 1:
		return "命中奖励应抽1张行动牌，before=%d after=%d" % [player_hand_before, player.action_hand.size()]
	if player_mech.get_own_power() != 3:
		return "命中奖励应回3动力（0+3），实=%d" % player_mech.get_own_power()
	_clear_all_pilot_static()
	return true


## ── pilot_012 e2 取消跳过：命中奖励弹窗取消 -> 不抽牌不回动力 ──
func test_pilot_012_effect02_cancel_skip() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_012_玛丽尔", &"player")
	if card == null:
		return "找不到 pilot_012_玛丽尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2, "hit": true})
	# 模拟 e1 已发动（flag，e2 据此判定）
	attack.record["_effect_flags"] = {"pilot_012_effect_01_fired": {"value": true, "data": {}}}
	var player_hand_before: int = player.action_hand.size()
	player_mech.adjust_own_power(-99)
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if attack.state != &"waiting_effect_action":
		return "e2 命中奖励应挂起，state=%s" % String(attack.state)
	# 取消命中奖励（per-target 取消 -> 跳过该目标，不抽牌不回动力）
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"cancelled": true})
	if player.action_hand.size() != player_hand_before:
		return "取消命中奖励不应抽牌，before=%d after=%d" % [player_hand_before, player.action_hand.size()]
	if player_mech.get_own_power() != 0:
		return "取消命中奖励不应回动力，实=%d" % player_mech.get_own_power()
	_clear_all_pilot_static()
	return true


## ── pilot_012 e2 flag 拦截：e1 未发动（无 flag）时 e2 不触发 ──
## 真实流程：effect_01 在 ATTACK_PRE 发动后才写 flag（SET_ACTION_RECORD_FLAG）；若玩家取消 e1（不夺牌），
## flag 未写，e2 的 RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT 条件失败 -> 不触发命中奖励。
func test_pilot_012_effect02_flag_gate() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_012_玛丽尔", &"player")
	if card == null:
		return "找不到 pilot_012_玛丽尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var player = gs.players.get(&"player")
	var player_hand_before: int = player.action_hand.size()
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2, "hit": true})
	# 不设 _effect_flags（e1 未发动/被取消）-> e2 flag 条件失败 -> 不触发（即使命中）
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if attack.state == &"waiting_effect_action":
		return "e1 未发动（无 flag）时 e2 不应触发（RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT 应拦截），state=%s" % String(attack.state)
	if player.action_hand.size() != player_hand_before:
		return "e2 未触发不应抽牌"
	_clear_all_pilot_static()
	return true
