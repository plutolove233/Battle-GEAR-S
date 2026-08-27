## test_pilot_077_viola.gd - 维奥拉（pilot_077）效果测试
##
## 权威文本：「在3格范围内的机甲（包括我方）发动攻击结算后，我方抽1张行动牌；之后每回合1次，
## 可以弃置2张行动牌使该机甲再立即发动1次攻击。」
##
## 唯一1个按钮（effect_01）：被动 LISTEN ATTACK_SETTLE（通用件，不绑机师）。
## 通用状态机 ATTACK_SETTLE_DRAW_REATTACK（TimingEngine，仿 INJURY_HEAL_DRAW）：
##   ① 范围内（base_range=3，含自身/我方）攻击结算 -> 我方抽1张行动牌（强制，无次数限制）；
##   ② 每回合1次：手牌>=2 弹多选窗（thrust_select min=max=2，可取消）-> 确认弃2张行动牌
##      -> 给攻击方开凯威攻击窗口（attack_window_open，攻击次数豁免，可中途取消）；取消不计次数。
##
## 关键覆盖点：
##   1. 攻击方==效果所属机甲（含自身）范围内结算 -> 抽1 + 弹弃牌窗 -> 确认弃2张 -> 窗口开给攻击方。
##   2. 取消弃牌窗 -> 不弃牌、不消耗次数（同回合第二次仍弹窗）、不开窗口（抽牌仍发生）。
##   3. 每回合1次：同回合第二次范围内结算 -> 只抽1（无弃牌窗、无窗口）。
##   4. 范围外（distance>3）结算 -> 不触发（不抽、不弹窗、不开窗口）。
##   5. 手牌不足2 -> 抽1但无弃牌窗（无窗口）。
##   6. 攻击方=其他机甲（敌方）范围内结算 -> 效果持有者抽1+弃牌，窗口开给攻击方。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _frame() -> void:
	var ml := Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


func _pump_frames(n: int) -> void:
	for i in range(n):
		await _frame()


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
	return battle


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


## 设维奥拉为玩家机甲的机师，返回 {pilot_card, mech, gs, cdb}；失败返回 {}
func _setup_viola(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_077_维奥拉", &"player")
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 构造一个已注册的 attack 动作（running 态），返回 action
func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p077_%d" % [randi() % 1000000]
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


## 清空地图全部格子地形为 NORMAL（避免随机 GREEN/RED 干扰）
func _clear_map_terrain(battle) -> void:
	var ms = battle.context.game_state.map_state
	if ms == null:
		return
	for key in ms.cells:
		ms.cells[key].terrain = &"NORMAL"


## 清空玩家行动手牌（含注销监听，避免残留）
func _clear_player_hand(battle, pid: StringName) -> void:
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return
	for cid: StringName in p.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		p.action_hand.erase(cid)


## 给玩家加入 n 张行动牌实例，返回实例 id 数组
func _add_action_cards(battle, pid: StringName, n: int) -> Array:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player = gs.players.get(pid)
	var out: Array = []
	for i in range(n):
		var c = _make_instance(gs, cdb, "action_013_维修", pid)
		if c == null:
			break
		c.zone = &"action_hand"
		player.action_hand.append(c.instance_id)
		out.append(c.instance_id)
	return out


func _hand_size(battle, pid: StringName) -> int:
	var p = battle.context.game_state.players.get(pid)
	return p.action_hand.size() if p != null else 0


func _discard_pile_size(battle) -> int:
	return battle.context.game_state.deck_state.action_discard_pile.size()


func _in_discard_pile(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


## 读挂起的弃牌窗 phase（空=未挂起弃牌窗）
func _pending_discard_phase(battle, action_id: StringName) -> StringName:
	var pe: Dictionary = battle.context.timing_engine._pending_effect.get(action_id, {})
	return pe.get("phase", &"")


## 触发 ATTACK_SETTLE 并推进若干帧（让抽牌子动作 + 串行链落地）
func _fire_settle_and_pump(battle, attack, frames: int = 18) -> void:
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	await _pump_frames(frames)


# ═══════════════════════════════════════════════
# 测试用例
# ═══════════════════════════════════════════════

## 0. 效果定义：LISTEN ATTACK_SETTLE / 范围内条件 / 无效果级 once（抽牌无条件）/ 状态机动作参数
func test_077_effect_definition() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup := _setup_viola(battle)
	if setup.is_empty():
		return "找不到 pilot_077_维奥拉"
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var e1 = all_effects.get(&"pilot_077_effect_01")
	if e1 == null:
		return "缺 pilot_077_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if int(e1.priority) != 10:
		return "effect_01 priority 应 10 实=%d" % int(e1.priority)
	if String(e1.listen_timing) != String(_TimingConst.ATTACK_SETTLE):
		return "effect_01 listen_timing 应 ATTACK_SETTLE 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "attack":
		return "effect_01 listen_action_type 应 attack 实=%s" % String(e1.listen_action_type)
	# 效果级不得设 once（否则本回合第二次结算整个效果被 once_per_turn_used_up 跳过，含强制抽牌）
	if String(e1.once_per_turn_key) != "":
		return "effect_01 效果级不应设 once_per_turn_key 实=%s" % String(e1.once_per_turn_key)
	# 条件：范围内（含自身）
	var cond_ok := false
	for c in e1.conditions:
		var cdict: Dictionary = c if c is Dictionary else {}
		if String(cdict.get("op", &"")) == "ATTACK_ATTACKER_WITHIN_RANGE_INCLUDING_SELF":
			if int(cdict.get("params", {}).get("base_range", 0)) == 3:
				cond_ok = true
	if not cond_ok:
		return "effect_01 应含范围内(base_range=3)条件"
	# 目标规则 NO_TARGET
	if e1.target_rules.is_empty() or String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rules 应 NO_TARGET"
	# 状态机动作参数
	if e1.actions.is_empty():
		return "effect_01 缺 actions"
	var a0: Dictionary = e1.actions[0]
	if String(a0.get("type", &"")) != "ATTACK_SETTLE_DRAW_REATTACK":
		return "effect_01 action type 应 ATTACK_SETTLE_DRAW_REATTACK 实=%s" % String(a0.get("type", &""))
	if int(a0.get("params", {}).get("draw_count", 0)) != 1:
		return "draw_count 应 1"
	if int(a0.get("params", {}).get("discard_count", 0)) != 2:
		return "discard_count 应 2"
	if String(a0.get("params", {}).get("once_per_turn_key", &"")) != "pilot_077_effect_01":
		return "动作 params 应带 once_per_turn_key"
	return true


## 1. 攻击方==效果所属机甲（含自身）范围内结算：抽1 + 弃牌窗 -> 确认弃2张 -> 窗口开给攻击方（我方）
func test_077_self_attack_draw_discard_open_window() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var setup := _setup_viola(battle)
	if setup.is_empty():
		return "找不到 pilot_077_维奥拉"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 2, "r": 0}
	_clear_map_terrain(battle)
	_clear_player_hand(battle, &"player")
	var hand := _add_action_cards(battle, &"player", 4)
	if hand.size() < 4:
		return "手牌构造失败"
	var hand_before: int = _hand_size(battle, &"player")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	await _fire_settle_and_pump(battle, attack)
	# 抽1（强制）
	if _hand_size(battle, &"player") != hand_before + 1:
		return "应抽1张行动牌 hand=%d/%d" % [_hand_size(battle, &"player"), hand_before + 1]
	# 每回合1次弃牌窗挂起
	if _pending_discard_phase(battle, attack.action_id) != &"attack_settle_draw_reattack_discard":
		return "应挂起弃牌窗 phase=%s" % String(_pending_discard_phase(battle, attack.action_id))
	# 确认弃2张
	var discard_ids := [hand[0], hand[1]]
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"selected_card_ids": discard_ids})
	await _pump_frames(30)
	# 弃牌入弃牌堆
	for cid in discard_ids:
		if not _in_discard_pile(battle, cid):
			return "应弃置 %s" % String(cid)
	# 攻击窗口打开给攻击方（我方）
	if not _ActionPilotEffects.attack_window_active_for_player(gs, &"player"):
		return "应给玩家开攻击窗口 win=%s" % str(gs.attack_window)
	if not _ActionPilotEffects.attack_window_active_for_mech(gs, player_mech.mech_id):
		return "窗口应归属玩家机甲"
	return true


## 2. 取消弃牌窗：不弃牌、不消耗次数（同回合第二次仍弹窗）、不开窗口（抽牌仍发生）
func test_077_cancel_discard_no_mark_no_window() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var setup := _setup_viola(battle)
	if setup.is_empty():
		return "找不到 pilot_077_维奥拉"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 2, "r": 0}
	_clear_map_terrain(battle)
	_clear_player_hand(battle, &"player")
	var hand := _add_action_cards(battle, &"player", 3)
	if hand.size() < 3:
		return "手牌构造失败"
	var hand_before: int = _hand_size(battle, &"player")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	await _fire_settle_and_pump(battle, attack)
	if _hand_size(battle, &"player") != hand_before + 1:
		return "应抽1张行动牌"
	if _pending_discard_phase(battle, attack.action_id) != &"attack_settle_draw_reattack_discard":
		return "应挂起弃牌窗"
	var before_pile: int = _discard_pile_size(battle)
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(20)
	if _discard_pile_size(battle) != before_pile:
		return "取消不应弃牌"
	if _ActionPilotEffects.attack_window_active(gs):
		return "取消不应开攻击窗口"
	# 次数未消耗：同回合第二次范围内结算仍弹弃牌窗
	var attack2 := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	await _fire_settle_and_pump(battle, attack2)
	if _pending_discard_phase(battle, attack2.action_id) != &"attack_settle_draw_reattack_discard":
		return "取消不应消耗次数（第二次应仍弹窗）"
	return true


## 3. 每回合1次：确认使用后，同回合第二次范围内结算只抽1（无弃牌窗、无窗口）
func test_077_once_per_turn_draw_only_on_second() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var setup := _setup_viola(battle)
	if setup.is_empty():
		return "找不到 pilot_077_维奥拉"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 2, "r": 0}
	_clear_map_terrain(battle)
	_clear_player_hand(battle, &"player")
	var hand := _add_action_cards(battle, &"player", 4)
	if hand.size() < 4:
		return "手牌构造失败"
	# 第一次：确认弃2张 -> 开窗口
	var attack1 := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	await _fire_settle_and_pump(battle, attack1)
	if _pending_discard_phase(battle, attack1.action_id) != &"attack_settle_draw_reattack_discard":
		return "第一次应弹弃牌窗"
	battle.context.timing_engine.resume_pending_effect(attack1.action_id, {"selected_card_ids": [hand[0], hand[1]]})
	await _pump_frames(30)
	if not _ActionPilotEffects.attack_window_active(gs):
		return "第一次应开窗口"
	# 清掉窗口，模拟玩家用完/关闭后再触发第二次
	gs.attack_window = {}
	var hand2_before: int = _hand_size(battle, &"player")
	var attack2 := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	await _fire_settle_and_pump(battle, attack2)
	if _hand_size(battle, &"player") != hand2_before + 1:
		return "第二次仍应抽1张"
	if _pending_discard_phase(battle, attack2.action_id) != &"":
		return "第二次不应弹弃牌窗"
	await _pump_frames(10)
	if _ActionPilotEffects.attack_window_active(gs):
		return "第二次不应开窗口"
	return true


## 4. 范围外（distance>3）结算：不触发（不抽、不弹窗、不开窗口）
func test_077_out_of_range_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var setup := _setup_viola(battle)
	if setup.is_empty():
		return "找不到 pilot_077_维奥拉"
	gs.active_player_id = &"enemy"
	gs.phase = &"MAIN"
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 5, "r": 0}
	_clear_map_terrain(battle)
	_clear_player_hand(battle, &"player")
	_add_action_cards(battle, &"player", 2)
	var hand_before: int = _hand_size(battle, &"player")
	# 攻击方=敌方机甲（距效果持有者5格，超出 base_range=3）——不触发（含自身/己方都在3格内才触发）
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"distance": 5})
	await _fire_settle_and_pump(battle, attack)
	if _hand_size(battle, &"player") != hand_before:
		return "范围外不应抽牌"
	if _pending_discard_phase(battle, attack.action_id) != &"":
		return "范围外不应弹弃牌窗"
	if _ActionPilotEffects.attack_window_active(gs):
		return "范围外不应开窗口"
	return true


## 5. 手牌不足2：抽1但无弃牌窗（无窗口）
func test_077_hand_less_than_two_draw_only() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var setup := _setup_viola(battle)
	if setup.is_empty():
		return "找不到 pilot_077_维奥拉"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 2, "r": 0}
	_clear_map_terrain(battle)
	_clear_player_hand(battle, &"player")
	# 手牌0张：结算抽1后仍<2张 -> 无弃牌窗
	var hand_before: int = _hand_size(battle, &"player")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"distance": 2})
	await _fire_settle_and_pump(battle, attack)
	if _hand_size(battle, &"player") != hand_before + 1:
		return "应抽1张行动牌"
	if _pending_discard_phase(battle, attack.action_id) != &"":
		return "手牌不足2不应弹弃牌窗"
	if _ActionPilotEffects.attack_window_active(gs):
		return "手牌不足2不应开窗口"
	return true


## 6. 攻击方=其他机甲（敌方）范围内结算：效果持有者抽1+弃牌，窗口开给攻击方
func test_077_enemy_attack_in_range_draws_for_owner_window_for_enemy() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var setup := _setup_viola(battle)
	if setup.is_empty():
		return "找不到 pilot_077_维奥拉"
	gs.active_player_id = &"enemy"
	gs.phase = &"MAIN"
	player_mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 1, "r": 0}
	_clear_map_terrain(battle)
	_clear_player_hand(battle, &"player")
	var hand := _add_action_cards(battle, &"player", 3)
	if hand.size() < 3:
		return "手牌构造失败"
	var hand_before: int = _hand_size(battle, &"player")
	# 敌方攻击玩家（攻击方=enemy 机甲，距离1 在效果持有者3格内）
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"distance": 1})
	await _fire_settle_and_pump(battle, attack)
	if _hand_size(battle, &"player") != hand_before + 1:
		return "应给效果持有者抽1张"
	if _pending_discard_phase(battle, attack.action_id) != &"attack_settle_draw_reattack_discard":
		return "应挂起弃牌窗"
	# 效果持有者（玩家）确认弃2张
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"selected_card_ids": [hand[0], hand[1]]})
	await _pump_frames(30)
	if not _ActionPilotEffects.attack_window_active_for_player(gs, &"enemy"):
		return "窗口应开给攻击方（enemy）"
	if not _ActionPilotEffects.attack_window_active_for_mech(gs, enemy_mech.mech_id):
		return "窗口应归属攻击方机甲"
	return true
