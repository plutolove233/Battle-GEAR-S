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
	# enemy 移到 5 格内（player(2,2)，enemy(4,2) 距离2）
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	# enemy 手牌清空 → 无攻击牌 → 二选一只有"4伤害"
	var enemy = gs.players.get(&"enemy")
	enemy.action_hand.clear()
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	# enemy 无攻击牌 → 自动选4伤害，HP-4；不应挂起弹窗
	if enemy_mech.current_hp != hp_before - 4:
		return "无攻击牌应自动回落4伤害 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	if attack.state == &"waiting_timing":
		return "无攻击牌不应挂起二选一弹窗"
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
	enemy_mech.position = {"q": 4, "r": 2}
	var card = _make_instance(gs, cdb, "pilot_006_里昂", &"player")
	if card == null:
		return "找不到 pilot_006_里昂"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	# enemy 手牌放1张攻击牌 → 二选一两选项都可用 → 挂起弹窗
	var atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	if atk == null:
		return "找不到 action_001_进攻"
	enemy.action_hand.append(atk.instance_id)
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	# 应挂起二选一弹窗（_pending_effect 记录）
	if attack.state != &"waiting_timing":
		return "有攻击牌应挂起二选一弹窗，state=%s" % String(attack.state)
	if not battle.context.timing_engine._pending_effect.has(attack.action_id):
		return "_pending_effect 应有 pilot_006 二选一挂起记录"
	var pending: Dictionary = battle.context.timing_engine._pending_effect[attack.action_id]
	var pend_eff = pending.get("effect")
	if pend_eff == null or String(pend_eff.effect_id) != "pilot_006_effect_03":
		return "挂起的 effect 应为 pilot_006_effect_03，实=%s" % String(pend_eff.effect_id if pend_eff != null else "null")
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
	enemy_mech.position = {"q": 4, "r": 2}
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
	if attack.state != &"waiting_timing":
		return "应挂起二选一弹窗"
	# 选"立即使用1张攻击牌"（option index 0）
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	# 应挂起 select_pilot_006_attack_card（被选机甲=enemy 手牌有攻击牌）
	var pending: Dictionary = battle.context.timing_engine._pending_effect.get(attack.action_id, {})
	if String(pending.get("phase", &"")) != "pilot_006_force_use_attack":
		return "选攻击牌后应挂起 pilot_006_force_use_attack，实=%s" % String(pending.get("phase", &""))
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
	if enemy.action_hand.size() != 0:
		return "类型破绽应弃3张 实剩=%d" % enemy.action_hand.size()
	if player.action_hand.size() != p_hand_before + 3:
		return "类型破绽应抽3 实增=%d" % (player.action_hand.size() - p_hand_before)
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


## ── pilot_009 DIRECT 蛇发支配：触发链核心（target 弹窗路由 + reveal 挂起）──
## 拆解场景a前置：P1 美杜莎主阶段、范围5内有目标 → DIRECT 触发 → 目标选择弹窗（归属 P1）
## → resume 选目标 → reveal(show_cards) 子动作挂起。支付→grant 链由机制层测试覆盖。
func test_pilot_009_effect01_direct_trigger_target_reveal() -> Variant:
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
	# P1 手牌有攻击牌（支付前置条件 HAS_ACTION_CARD_IN_HAND + HAS_ACTION_CARD_TYPE_IN_HAND）
	player.action_hand.clear()
	var pay_atk = _make_instance(gs, cdb, "action_001_进攻", &"player")
	player.action_hand.append(pay_atk.instance_id)
	var fire := _Action.new()
	fire.action_id = &"test_p009_trigger"
	fire.action_type = &"effect_fire"
	fire.record = {"effect_id": &"pilot_009_effect_01", "card_instance_id": card.instance_id, "player_id": &"player", "source_mech_id": player_mech.mech_id}
	fire.state = &"running"
	fire.context = battle.context
	battle.context.action_registry.register(fire)
	battle.context.timing_engine._execute_effect_by_id(&"pilot_009_effect_01", fire.record, fire)
	# 目标选择挂起（CHOOSE_OTHER_MECH：payload 无 target_id），弹窗归属 P1（人类）
	if fire.state != &"waiting_timing":
		return "应挂起目标选择，state=%s" % String(fire.state)
	if not battle.context.timing_engine._pending_effect.has(fire.action_id):
		return "_pending_effect 应有目标选择挂起记录"
	# resume 选目标 → reveal(show_cards) 子动作挂起（EXECUTE_SHOW_CARD 前置于类型 CHOOSE_ONE）
	battle.context.timing_engine.resume_pending_effect(fire.action_id, {"target_id": enemy_mech.mech_id})
	if fire.pending_effect_action_ids.is_empty():
		return "选目标后应创建 reveal 子动作（show_cards）"
	# reveal 子动作存在且挂起（waiting_input show_cards）
	var reveal_found := false
	for sub_id in fire.pending_effect_action_ids:
		var sub = battle.context.action_registry.get_action(sub_id)
		if sub != null and sub.action_type == &"show_card":
			reveal_found = true
			break
	if not reveal_found:
		return "应创建 show_card 子动作（reveal 目标手牌）"
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
