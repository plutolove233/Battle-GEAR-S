## test_pilot_047_leona.gd — 里欧娜 pilot_047 战后威逼交牌（ATTACK_SETTLE 阻塞式二选一）
##
## 权威文本：「我方攻击结算后，可以选择1台4格范围内的其他机甲，其选择立即使用1张攻击牌，
## 否则必须交给我方3张行动牌，若数量不足则每少1张该机甲将受到2伤害。」
##
## 拆解：
##   - LISTEN ATTACK_SETTLE priority 30（先于闪击/反击，同 pilot_006 e3）+ confirm_before_target
##     先弹确认窗（可取消，无每回合次数限制）→ force_select 选目标（4格内其他机甲）。
##   - 二选一（CHOOSE_ONE chooser_mech_id 路由到被选机甲，不可取消）：
##       「立即使用1张攻击牌」（MECH_HAS_USABLE_ATTACK_CARD 置灰）→ PILOT_047_FORCE_USE_ATTACK
##         → 被选机甲选1张攻击牌（unite_attack_select no_cancel）被动使用。
##       「交给我方3张行动牌」→ PILOT_047_FORCE_HANDOVER：手牌>3 弹交给牌窗（thrust_select
##         min=max=3 no_cancel）；手牌≤3 不弹窗直接全部交出；差额 每少1张*2 直接扣 HP。
##
## 覆盖（PvP 双人类）：
##   - 无攻击牌 + 手牌不足 → 全交 + 差额伤害
##   - 无攻击牌 + 手牌>3 → 弹交给牌窗 → 交3张无伤害
##   - 确认窗取消 → 不触发
##   - 空手 → 满额6伤害
##   - 有攻击牌 → 二选一 → 选「立即使用攻击牌」→ 挂起选牌窗
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


## 清空全部 pilot 静态状态（避免污染后续测试文件）
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
func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p047_%d" % [randi() % 1000000]
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


## 清空地图全部格子地形为 NORMAL（避免随机 GREEN/RED 干扰武器射程 BFS）
func _clear_map_terrain(battle) -> void:
	var ms = battle.context.game_state.map_state
	if ms == null:
		return
	for key in ms.cells:
		ms.cells[key].terrain = &"NORMAL"


## 让 enemy 手牌仅含给定牌实例列表（清空教程初始手牌后加入）
func _set_enemy_hand(enemy, card_ids: Array) -> void:
	enemy.action_hand.clear()
	for cid in card_ids:
		enemy.action_hand.append(cid)


## ── 里欧娜 e1：enemy 无攻击牌 + 手牌2张(≤3) → 自动选「交牌」→ 全交2张 + 差额1张*2=2伤害 ──
func test_pilot_047_effect01_no_attack_handover_shortfall_damage() -> Variant:
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
	var card = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	if card == null:
		return "找不到 pilot_047_里欧娜"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	# 非攻击牌（维修=辅助 / 回避=迎击），无可用攻击牌 → option0 置灰
	var c1 = _make_instance(gs, cdb, "action_013_维修", &"enemy")
	var c2 = _make_instance(gs, cdb, "action_008_回避", &"enemy")
	_set_enemy_hand(enemy, [c1.instance_id, c2.instance_id])
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	if attack.state != &"waiting_timing":
		return "应挂起确认弹窗 state=%s" % String(attack.state)
	# 先确认发动再选机甲
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# 无攻击牌 → 自动选「交牌」→ 手牌2≤3 → 全交2张 + 差额1张*2伤害
	if enemy.action_hand.size() != 0:
		return "应全交2张行动牌，enemy 手牌剩余 %d" % enemy.action_hand.size()
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 2:
		return "player 应收到2张行动牌，手牌 %d（before=%d）" % [gs.players.get(&"player").action_hand.size(), player_hand_before]
	if enemy_mech.current_hp != hp_before - 2:
		return "差额1张应受2伤害 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	_clear_all_pilot_static()
	return true


## ── 里欧娜 e1：enemy 无攻击牌 + 手牌5张(>3) → 弹交给牌窗 → 交3张 → 无伤害 ──
func test_pilot_047_effect01_handover_exact3_popup() -> Variant:
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
	var card = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	if card == null:
		return "找不到 pilot_047_里欧娜"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	var hand_ids: Array = []
	for i in range(5):
		var c = _make_instance(gs, cdb, "action_013_维修", &"enemy")
		hand_ids.append(c.instance_id)
	_set_enemy_hand(enemy, hand_ids)
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# 手牌5>3 → 挂起交给牌窗
	var pending: Dictionary = battle.context.timing_engine._pending_effect.get(attack.action_id, {})
	if String(pending.get("phase", &"")) != "pilot_047_force_handover":
		return "应挂起交给牌窗 pilot_047_force_handover，实=%s" % String(pending.get("phase", &""))
	# 交前3张
	var give3: Array = []
	for i in range(3):
		give3.append(hand_ids[i])
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"selected_card_ids": give3})
	if enemy.action_hand.size() != 2:
		return "enemy 应剩2张，实=%d" % enemy.action_hand.size()
	if gs.players.get(&"player").action_hand.size() != player_hand_before + 3:
		return "player 应收到3张，手牌 %d（before=%d）" % [gs.players.get(&"player").action_hand.size(), player_hand_before]
	if enemy_mech.current_hp != hp_before:
		return "交足3张不应受伤 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	_clear_all_pilot_static()
	return true


## ── 里欧娜 e1：确认窗取消 → 不触发（不交牌不受伤）──
func test_pilot_047_effect01_confirm_cancel_no_effect() -> Variant:
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
	var card = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	if card == null:
		return "找不到 pilot_047_里欧娜"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	_set_enemy_hand(enemy, [])
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	# 取消确认窗
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"cancelled": true})
	if enemy.action_hand.size() != 0:
		return "取消后不应有交牌"
	if gs.players.get(&"player").action_hand.size() != player_hand_before:
		return "取消后 player 手牌不应变化"
	if enemy_mech.current_hp != hp_before:
		return "取消后不应受伤 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	_clear_all_pilot_static()
	return true


## ── 里欧娜 e1：enemy 空手 → 自动选「交牌」→ 交0张 + 差额3张*2=6伤害 ──
func test_pilot_047_effect01_empty_hand_full_damage() -> Variant:
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
	var card = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	if card == null:
		return "找不到 pilot_047_里欧娜"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	_set_enemy_hand(enemy, [])
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var hp_before: int = enemy_mech.current_hp
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# 空手 → 全交0张 + 差额3张*2=6伤害
	if gs.players.get(&"player").action_hand.size() != player_hand_before:
		return "空手不应有牌转移"
	if enemy_mech.current_hp != hp_before - 6:
		return "空手应受6伤害 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	_clear_all_pilot_static()
	return true


## ── 里欧娜 e1：enemy 有可用攻击牌 → 二选一 → 选「立即使用攻击牌」→ 挂起选牌窗 ──
func test_pilot_047_effect01_choose_use_attack_suspend() -> Variant:
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
	var card = _make_instance(gs, cdb, "pilot_047_里欧娜", &"player")
	if card == null:
		return "找不到 pilot_047_里欧娜"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var enemy = gs.players.get(&"enemy")
	var atk = _make_instance(gs, cdb, "action_001_进攻", &"enemy")
	if atk == null:
		return "找不到 action_001_进攻"
	_set_enemy_hand(enemy, [atk.instance_id])
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	# 先确认发动再选机甲
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# 有攻击牌+武器射程覆盖 → 两 option 可用 → 挂起二选一
	if attack.state != &"waiting_timing":
		return "选机甲后应挂起二选一弹窗 state=%s" % String(attack.state)
	var pend1: Dictionary = battle.context.timing_engine._pending_effect.get(attack.action_id, {})
	if String(pend1.get("phase", &"")) != "pre_actions_target":
		return "应挂起二选一 pre_actions_target，实=%s" % String(pend1.get("phase", &""))
	# 选「立即使用1张攻击牌」（option index 0）
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	var pending: Dictionary = battle.context.timing_engine._pending_effect.get(attack.action_id, {})
	if String(pending.get("phase", &"")) != "pilot_047_force_use_attack":
		return "选攻击牌后应挂起 pilot_047_force_use_attack，实=%s" % String(pending.get("phase", &""))
	_clear_all_pilot_static()
	return true
