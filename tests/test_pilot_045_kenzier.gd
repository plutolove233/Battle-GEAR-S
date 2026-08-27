## test_pilot_045_kenzier.gd - 肯兹尔（pilot_045，帝国 R）效果测试
##
## 肯兹尔 1 个效果按钮（主动 DIRECT）「遗弃回收」：
##   我方回合1次，可以弃置4格范围内所有其他机甲随机3张行动牌，之后获得被弃置牌中的
##   所有攻击牌，本回合攻击数+1，我方也将受到3伤害（来源我方）。
##
## 实现拆解（全通用机制组装，不新增原子动作，复用=整段复制改参数）：
##   1. effect_01（按钮，DIRECT 主动）我方主阶段 + 每回合1次（EFFECT_ONCE_PER_TURN_AVAILABLE
##      max=1）+ 4格范围内有其他存活机甲（HAS_OTHER_MECH_IN_HEX_RANGE range=4）才可点。
##   2. CHOOSE_ONE 确认弹窗（optional，取消不计次），「发动」分支内含全部执行步骤：
##      MARK 计次 -> FOR_EACH_TARGET 逐目标（目标源 targets={"range":4,"include_self":false}
##      通用范围扫描，不分敌我）：RANDOM_DISCARD_ACTION_CARD 随机弃3张行动牌（不足3全弃），
##      经 capture_store_key/capture_attack_only 捕获其中攻击牌 -> EXECUTE_GAIN_CARD 统一获取
##      攻击牌 -> MODIFY_ATTACK_COUNT 本回合攻击数+1 -> EXECUTE_HP_CHANGE 自身-3伤害。
##   3. 基础设施（通用可复用，非 pilot 专属）：_resolve_fet_targets 支持 range 字典目标源 +
##      RANDOM_DISCARD_ACTION_CARD 支持 capture_store_key/capture_attack_only 捕获被弃牌。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90045
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


## 设肯兹尔为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_kenzier(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_045_肯兹尔", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 创建独立玩家 third + 机甲（PVP3 多人），位置(6,2)，距 player(2,2) 轴向距离4（范围上限）
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


## 清空玩家行动手牌
func _clear_action_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		p.action_hand.erase(cid)


## 给玩家行动手牌加一张行动牌（mech_id 挂到所属机甲），返回实例 id
func _add_action_to_hand(battle, pid: StringName, def_id: String, mech_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"action_hand"
	card.mech_id = mech_id
	gs.players.get(pid).action_hand.append(card.instance_id)
	return card.instance_id


func _hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


## 该牌是否为攻击牌（cid 是实例 id，经 gs.cards 解析实例再取 def；卡 def card_kind=action 且 action_type=攻击）
func _is_attack_card(battle, cid: StringName) -> bool:
	var inst = battle.context.game_state.cards.get(cid)
	var def = inst.def if inst != null else null
	return def != null and def.card_kind == &"action" and def.action_type == &"攻击"


## 触发肯兹尔 DIRECT 按钮（effect_01）。弹窗挂起返回 effect_fire action；条件不满足/直接完成返回 null。
func _fire_pilot_045(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_045_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_045_effect_01",
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


## resume 首层二选一（选分支）：chosen_option_index 0=发动 1=取消
func _resume_choose(battle, ef_action, option_index: int) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"chosen_option_index": option_index})
	await _pump_frames(30)


## resume 取消首层二选一（取消不计次）
func _resume_choose_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(30)


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（DIRECT 主动、条件链、CHOOSE_ONE 确认、发动分支动作链、单效果无 effect_02）
func test_p045_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	if effects.has(&"pilot_045_effect_02"):
		return "不应存在 pilot_045_effect_02（新效果只有1个按钮）"
	var e1 = effects.get(&"pilot_045_effect_01")
	if e1 == null:
		return "缺 pilot_045_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	var conds: Array = []
	for c in e1.conditions:
		conds.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "EFFECT_ONCE_PER_TURN_AVAILABLE", "HAS_OTHER_MECH_IN_HEX_RANGE"]:
		if not conds.has(need):
			return "effect_01 应含条件 %s" % need
	for c in e1.conditions:
		if String(c.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			var cp = c.get("params", {})
			if String(cp.get("once_per_turn_key", &"")) != "pilot_045_effect_01" or int(cp.get("once_per_turn_max", 0)) != 1:
				return "额度应为 pilot_045_effect_01 max=1（我方回合1次）"
		if String(c.get("op", &"")) == "HAS_OTHER_MECH_IN_HEX_RANGE":
			if int(c.get("params", {}).get("range", 0)) != 4:
				return "范围条件应为 range=4（4格内）"
	var acts = e1.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 动作0 应 CHOOSE_ONE（确认弹窗）"
	var co = acts[0].get("params", {})
	if not bool(co.get("optional", false)):
		return "CHOOSE_ONE 应 optional=true（可取消不计次）"
	var opts: Array = co.get("options", [])
	if opts.size() != 2:
		return "应2个分支 实=%d" % opts.size()
	# 分支0：发动
	var opt0: Dictionary = opts[0]
	if String(opt0.get("label", &"")) != "发动":
		return "分支0 label 应 发动"
	var opt0_types: Array = []
	for a in opt0.get("actions", []):
		opt0_types.append(String(a.get("type", &"")))
	if opt0_types != ["MARK_EFFECT_ONCE_PER_TURN_USED", "FOR_EACH_TARGET", "EXECUTE_GAIN_CARD", "MODIFY_ATTACK_COUNT", "EXECUTE_HP_CHANGE"]:
		return "发动分支动作应 [计次,逐目标,获取攻牌,攻击数+1,自伤3] 实=%s" % str(opt0_types)
	# 计次
	if String(opt0.get("actions", [])[0].get("params", {}).get("once_per_turn_key", &"")) != "pilot_045_effect_01":
		return "计次 once_per_turn_key 应 pilot_045_effect_01"
	# FOR_EACH_TARGET：范围扫描目标源 + 逐目标随机弃3捕获攻击牌
	var fet = opt0.get("actions", [])[1].get("params", {})
	var fet_targets = fet.get("targets", {})
	if int(fet_targets.get("range", 0)) != 4 or bool(fet_targets.get("include_self", true)):
		return "FOR_EACH_TARGET 目标源应 range=4 include_self=false（4格内所有其他机甲）"
	var fet_inner: Array = fet.get("actions", [])
	if fet_inner.size() != 1 or String(fet_inner[0].get("type", &"")) != "RANDOM_DISCARD_ACTION_CARD":
		return "FOR_EACH_TARGET 内动作应 RANDOM_DISCARD_ACTION_CARD"
	var rdc = fet_inner[0].get("params", {})
	if int(rdc.get("count", 0)) != 3:
		return "随机弃牌 count 应3 实=%d" % int(rdc.get("count", 0))
	if String(rdc.get("owner_id", &"")) != "$current_target.mech_id":
		return "随机弃牌 owner_id 应 $current_target.mech_id（逐目标弃目标机甲手牌）"
	if String(rdc.get("capture_store_key", &"")) != "pilot_045_captured_attacks":
		return "随机弃牌应捕获到 pilot_045_captured_attacks"
	if not bool(rdc.get("capture_attack_only", false)):
		return "随机弃牌应 capture_attack_only=true（只捕获攻击牌）"
	# 获取攻牌
	var gain = opt0.get("actions", [])[2].get("params", {})
	if String(gain.get("card_ids", &"")) != "$runtime.pilot_045_captured_attacks":
		return "获取应引用捕获的攻击牌"
	var gain_mechs: Array = gain.get("mech_ids", [])
	if gain_mechs.size() != 1 or String(gain_mechs[0]) != "$binding_context.mech_id":
		return "获取应发给持有者机甲"
	# 攻击数+1
	var atk = opt0.get("actions", [])[3].get("params", {})
	if int(atk.get("delta", 0)) != 1 or String(atk.get("duration", &"")) != "THIS_TURN":
		return "攻击数应 delta=1 THIS_TURN"
	# 自伤3
	var hp = opt0.get("actions", [])[4].get("params", {})
	if int(hp.get("value", 0)) != 3 or String(hp.get("method", &"")) != "decrease":
		return "自伤应 value=3 method=decrease"
	if String(hp.get("source_mech_id", &"")) != "$binding_context.mech_id":
		return "自伤来源应是我方"
	# 分支1：取消
	var opt1: Dictionary = opts[1]
	if String(opt1.get("label", &"")) != "取消" or not opt1.get("actions", []).is_empty():
		return "分支1 应 取消 且无动作"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：完整流程——范围内 enemy 有 2攻击+1迎击，发动后弃3张、获得攻击牌、攻击数+1、自身-3HP
func test_p045_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenzier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到 enemy 机甲"
	enemy_mech.position = {"q": 3, "r": 3}  # 距 player(2,2) 距离1，范围内
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var e1 = _add_action_to_hand(battle, &"enemy", "action_001_进攻", enemy_mech.mech_id)
	var e2 = _add_action_to_hand(battle, &"enemy", "action_002_强袭", enemy_mech.mech_id)
	var e3 = _add_action_to_hand(battle, &"enemy", "action_009_防御", enemy_mech.mech_id)
	if e1 == &"" or e2 == &"" or e3 == &"":
		return "enemy 行动牌设置失败"
	if not _is_attack_card(battle, e1) or not _is_attack_card(battle, e2) or _is_attack_card(battle, e3):
		return "测试牌类型不符（应2攻击1迎击）"
	var hp_before: int = player_mech.current_hp
	var atk_before: int = player_mech.max_attacks_per_turn

	var ef = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起确认弹窗"
	await _resume_choose(battle, ef, 0)

	# enemy 手牌 3-3=0（随机弃3张，全弃）
	if _hand_size(battle, &"enemy") != 0:
		return "enemy 应被弃3张（3张全弃）实=%d" % _hand_size(battle, &"enemy")
	# 攻击牌 e1/e2 应进我方手牌
	var p_hand: Array = gs.players.get(&"player").action_hand
	if not p_hand.has(e1) or not p_hand.has(e2):
		return "我方应获得被弃的攻击牌（缺 %s/%s）" % [String(e1), String(e2)]
	# 迎击牌 e3 不应进我方手牌，应在 enemy 弃牌堆
	if p_hand.has(e3):
		return "迎击牌不应被我方获得"
	if not gs.deck_state.action_discard_pile.has(e3):
		return "迎击牌应留在 enemy 弃牌堆"
	# 攻击牌应从弃牌堆移走（转移到我方手牌）
	if gs.deck_state.action_discard_pile.has(e1) or gs.deck_state.action_discard_pile.has(e2):
		return "攻击牌应移出弃牌堆进我方手牌"
	# 攻击数+1
	if player_mech.max_attacks_per_turn != atk_before + 1:
		return "本回合攻击数应+1 前=%d 后=%d" % [atk_before, player_mech.max_attacks_per_turn]
	# 自身-3HP
	if player_mech.current_hp != hp_before - 3:
		return "自身应受3伤害 前=%d 后=%d" % [hp_before, player_mech.current_hp]
	return true


## 测试3：不足3张全弃——enemy 只有 2 张（1攻击1迎击）也全弃，攻击牌照获
func test_p045_less_than_3_all_discarded() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenzier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 3}
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var e1 = _add_action_to_hand(battle, &"enemy", "action_001_进攻", enemy_mech.mech_id)
	var e2 = _add_action_to_hand(battle, &"enemy", "action_009_防御", enemy_mech.mech_id)
	if e1 == &"" or e2 == &"":
		return "enemy 行动牌设置失败"

	var ef = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起确认弹窗"
	await _resume_choose(battle, ef, 0)

	if _hand_size(battle, &"enemy") != 0:
		return "不足3张应全弃 实=%d" % _hand_size(battle, &"enemy")
	var p_hand: Array = gs.players.get(&"player").action_hand
	if not p_hand.has(e1):
		return "应获得被弃的攻击牌 e1"
	if p_hand.has(e2):
		return "迎击牌不应被获得"
	if not gs.deck_state.action_discard_pile.has(e2):
		return "迎击牌应留在 enemy 弃牌堆"
	if player_mech.current_hp >= 25:
		return "HP 应因自伤下降"
	return true


## 测试4：取消确认弹窗 -> 不计次、不弃牌、不获得、不加攻击数、不扣血，可再次触发
func test_p045_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenzier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 3}
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var e1 = _add_action_to_hand(battle, &"enemy", "action_001_进攻", enemy_mech.mech_id)
	var e2 = _add_action_to_hand(battle, &"enemy", "action_002_强袭", enemy_mech.mech_id)
	var hp_before: int = player_mech.current_hp
	var atk_before: int = player_mech.max_attacks_per_turn

	var ef = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起确认弹窗"
	await _resume_choose_cancel(battle, ef)

	if _hand_size(battle, &"enemy") != 2:
		return "取消不应弃牌 实=%d" % _hand_size(battle, &"enemy")
	if not gs.players.get(&"player").action_hand.is_empty():
		return "取消不应获得牌"
	if player_mech.current_hp != hp_before:
		return "取消不应扣血"
	if player_mech.max_attacks_per_turn != atk_before:
		return "取消不应加攻击数"
	# 次数未消耗：可再次触发
	var ef2 = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef2 == null:
		return "取消后应可再次触发"
	await _resume_choose_cancel(battle, ef2)
	return true


## 测试5：4格范围内无其他机甲 -> 按钮置灰（不挂起、无任何副作用）
func test_p045_no_target_in_range() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenzier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	# enemy 保持 tutorial 默认位置 (20,-6)，距 player(2,2) 很远，范围内无其他机甲
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	var hp_before: int = player_mech.current_hp
	var atk_before: int = player_mech.max_attacks_per_turn

	var ef = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef != null:
		return "范围内无目标不应挂起（按钮应置灰）"
	await _pump_frames(6)
	if _hand_size(battle, &"enemy") != 0:
		return "不应有弃牌"
	if player_mech.current_hp != hp_before:
		return "不应扣血"
	if player_mech.max_attacks_per_turn != atk_before:
		return "不应加攻击数"
	return true


## 测试6：每回合1次用满 -> 第2次触发被跳过（不挂起、无副作用）
func test_p045_once_per_turn_max() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_kenzier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 3}
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	_add_action_to_hand(battle, &"enemy", "action_001_进攻", enemy_mech.mech_id)
	_add_action_to_hand(battle, &"enemy", "action_002_强袭", enemy_mech.mech_id)
	_add_action_to_hand(battle, &"enemy", "action_003_猛击", enemy_mech.mech_id)
	# 第1次：正常发动
	var ef1 = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef1 == null:
		return "第1次应挂起"
	await _resume_choose(battle, ef1, 0)
	# 第2次：额度用满 -> 不挂起
	var ef2 = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef2 != null:
		return "第2次不应挂起（每回合1次用满）"
	var hp_after: int = player_mech.current_hp
	var atk_after: int = player_mech.max_attacks_per_turn
	await _pump_frames(6)
	if player_mech.current_hp != hp_after:
		return "第2次跳过不应再扣血"
	if player_mech.max_attacks_per_turn != atk_after:
		return "第2次跳过不应再加攻击数"
	return true


## 测试7：PVP3 多人——enemy(1) 与 third(4) 都在范围内，逐目标弃牌、攻击牌累计进我方手牌
func test_p045_pvp3_multi_target() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_kenzier(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 3}  # 距离1
	# third(6,2) 距 player(2,2) 轴向距离4（范围内）
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	_clear_action_hand(battle, &"third")
	var atk_before: int = player_mech.max_attacks_per_turn
	# enemy：1攻击1迎击；third：1攻击1迎击
	var e1 = _add_action_to_hand(battle, &"enemy", "action_001_进攻", enemy_mech.mech_id)
	var e2 = _add_action_to_hand(battle, &"enemy", "action_009_防御", enemy_mech.mech_id)
	var t1 = _add_action_to_hand(battle, &"third", "action_002_强袭", third_mech.mech_id)
	var t2 = _add_action_to_hand(battle, &"third", "action_010_反击", third_mech.mech_id)
	if e1 == &"" or e2 == &"" or t1 == &"" or t2 == &"":
		return "行动牌设置失败"

	var ef = await _fire_pilot_045(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起确认弹窗"
	await _resume_choose(battle, ef, 0)

	# 两目标各被弃（enemy 2张、third 2张）
	if _hand_size(battle, &"enemy") != 0:
		return "enemy 应被弃2张 实=%d" % _hand_size(battle, &"enemy")
	if _hand_size(battle, &"third") != 0:
		return "third 应被弃2张 实=%d" % _hand_size(battle, &"third")
	# 攻击牌 e1/t1 累计进我方手牌；迎击牌 e2/t2 各留目标弃牌堆
	var p_hand: Array = gs.players.get(&"player").action_hand
	if not p_hand.has(e1) or not p_hand.has(t1):
		return "我方应获得两个目标的攻击牌"
	if p_hand.has(e2) or p_hand.has(t2):
		return "迎击牌不应被获得"
	if not gs.deck_state.action_discard_pile.has(e2) or not gs.deck_state.action_discard_pile.has(t2):
		return "迎击牌应留在各自目标弃牌堆"
	if player_mech.max_attacks_per_turn != atk_before + 1:
		return "攻击数应+1（多目标也只+1）前=%d 后=%d" % [atk_before, player_mech.max_attacks_per_turn]
	if player_mech.current_hp >= 25:
		return "HP 应因自伤下降（多目标也只扣一次）"
	return true
