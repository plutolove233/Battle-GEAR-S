## test_pilot_037_cyanne.gd - 青瞳（pilot_037）效果测试
##
## 青瞳 1 按钮（被动窥心夺牌）：effect_01（LISTEN ATTACK_PRE priority10）。
##   每玩家回合2次（按座位计回合），被攻击时查看攻击方所持行动牌，明牌选1张获得（不可取消）；
##   偷牌结算后若我方行动手牌数 > 攻击方行动手牌数（等于不算），本次攻击威力-4。
##
## 关键机制（本测试覆盖）：
##   1. 次数限制用通用「额度」件：条件 EFFECT_ONCE_PER_TURN_AVAILABLE（max=2）+ 动作
##      MARK_EFFECT_ONCE_PER_TURN_USED（触发即消耗1次）。不在 ActionEffect 上设 once_per_turn_key
##      ——EXECUTE_STEAL 子动作挂起时 _execute_effect 提前 return 不 mark；额度机制 mark 独立于挂起，
##      同步/挂起路径都恰好 mark 1 次（布鲁克 pilot_030 同款通用件，与机师无关）。
##   2. 明牌偷牌：EXECUTE_STEAL from_attacker=true + face_up=true（UI 显示攻击方牌面）
##      + no_cancel=true（强制获得，无取消键）；攻击方无行动牌则 steal 空转跳过不弹窗。
##   3. 偷后比较：顶层 CONDITIONAL_ACTIONS（TimingEngine 支持）→ OWNER_ACTION_HAND_GREATER_THAN_MECH
##      条件（我方 > 攻击方）→ MODIFY_ATTACK_MIGHT delta=-4 写 attack.record.extra_might。
##   4. 双连多目标算同一攻击只触发1次（listener 每次 ATTACK_PRE fire 只跑一次动作链）。
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
	battle.rng_seed = 90037
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


## 设青瞳为 owner_id 机甲的机师，返回 {card, mech, player, gs, cdb}；失败返回 null。
func _setup_qingtong(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_037_青瞳", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


## 构造 attack action（fire ATTACK_PRE 用）：attacker 攻 target。target_ids 含自身（模拟单目标攻击）。
func _make_attack(battle, attacker_id: StringName, target_id: StringName, target_ids: Array) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p037_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id, "target_ids": target_ids}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": &"enemy"}
	battle.context.action_registry.register(attack)
	return attack


## 给 player 手牌补到指定牌面（清空后按 ids 填入），供手牌数对比测试。
func _set_player_action_hand(gs, ids: Array) -> void:
	var player = gs.players.get(&"player")
	player.action_hand.clear()
	for cid in ids:
		player.action_hand.append(cid)


## 给 enemy 手牌补 count 张（从牌堆顶抽），返回牌 id 列表。
func _ensure_enemy_action_hand(gs, count: int) -> Array:
	var enemy_player = gs.players.get(&"enemy")
	var out: Array = []
	for i in range(count):
		if gs.deck_state.action_deck.is_empty():
			break
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		enemy_player.action_hand.append(cid)
		var dc = gs.get_card(cid)
		if dc != null:
			dc.zone = &"action_hand"
			dc.owner_player_id = &"enemy"
		out.append(cid)
	return out


## 清空 enemy 行动手牌（移回牌堆底，测试无牌目标用）
func _clear_enemy_action_hand(battle) -> void:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return
	for cid in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 读取当前等待输入信息（UI 路由等待），无则返回 {}
func _get_wait(battle) -> Dictionary:
	return battle.context.action_ui_bridge.get_waiting_action_info()


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN ATTACK_PRE priority10，无 effect 级 once_per_turn_key，
## 条件含 SELF_MECH_IS_AMONG_ATTACK_TARGETS + EFFECT_ONCE_PER_TURN_AVAILABLE(max=2)，
## 动作链 [MARK_EFFECT_ONCE_PER_TURN_USED, EXECUTE_STEAL(明牌+不可取消), CONDITIONAL_ACTIONS(-4)]）
func test_pilot_037_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_037_effect_01")
	if e == null:
		return "缺 pilot_037_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_01 listen_timing 应 ATTACK_PRE"
	if int(e.priority) != 10:
		return "effect_01 priority 应 10 实=%d" % int(e.priority)
	if e.listen_action_type != &"attack":
		return "effect_01 listen_action_type 应 attack"
	# 关键：不用 effect 级 once_per_turn_key（改用通用额度件，避免挂起路径不 mark / 同步路径重复 mark）
	if e.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（额度走 EFFECT_ONCE_PER_TURN_AVAILABLE + MARK 通用件）"
	# conditions
	var ops: Array = []
	var eoa = null
	for c in e.conditions:
		var op: StringName = c.get("op", &"")
		ops.append(String(op))
		if op == &"EFFECT_ONCE_PER_TURN_AVAILABLE":
			eoa = c
	if not ops.has("SELF_MECH_IS_AMONG_ATTACK_TARGETS"):
		return "effect_01 应含 SELF_MECH_IS_AMONG_ATTACK_TARGETS"
	if eoa == null:
		return "effect_01 应含 EFFECT_ONCE_PER_TURN_AVAILABLE"
	if int(eoa.get("params", {}).get("once_per_turn_max", 0)) != 2:
		return "EFFECT_ONCE_PER_TURN_AVAILABLE once_per_turn_max 应 2 实=%d" % int(eoa.get("params", {}).get("once_per_turn_max", 0))
	if String(eoa.get("params", {}).get("once_per_turn_key", &"")) != "pilot_037_effect_01":
		return "EFFECT_ONCE_PER_TURN_AVAILABLE once_per_turn_key 应 pilot_037_effect_01"
	# target rule: NO_TARGET
	if e.target_rules.is_empty() or String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 target_rule 应 NO_TARGET"
	# actions: [MARK, EXECUTE_STEAL, CONDITIONAL_ACTIONS]
	var acts = e.actions
	if acts.size() != 3:
		return "effect_01 actions 应 3 个 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "MARK_EFFECT_ONCE_PER_TURN_USED":
		return "effect_01 actions[0] 应 MARK_EFFECT_ONCE_PER_TURN_USED 实=%s" % String(acts[0].get("type", &""))
	if String(acts[0].get("params", {}).get("once_per_turn_key", &"")) != "pilot_037_effect_01":
		return "MARK once_per_turn_key 应 pilot_037_effect_01"
	# EXECUTE_STEAL
	if String(acts[1].get("type", &"")) != "EXECUTE_STEAL":
		return "effect_01 actions[1] 应 EXECUTE_STEAL 实=%s" % String(acts[1].get("type", &""))
	var steal_p: Dictionary = acts[1].get("params", {})
	if not bool(steal_p.get("from_attacker", false)):
		return "EXECUTE_STEAL 应 from_attacker=true"
	if String(steal_p.get("to_target_id", &"")) != "$binding_context.mech_id":
		return "EXECUTE_STEAL to_target_id 应 $binding_context.mech_id"
	if String(steal_p.get("chooser_id", &"")) != "$binding_context.player_id":
		return "EXECUTE_STEAL chooser_id 应 $binding_context.player_id"
	if int(steal_p.get("count", 0)) != 1:
		return "EXECUTE_STEAL count 应 1"
	if not bool(steal_p.get("choose", false)):
		return "EXECUTE_STEAL 应 choose=true"
	if not bool(steal_p.get("face_up", false)):
		return "EXECUTE_STEAL 应 face_up=true（明牌显示攻击方手牌）"
	if not bool(steal_p.get("no_cancel", false)):
		return "EXECUTE_STEAL 应 no_cancel=true（强制获得不可取消）"
	if bool(steal_p.get("optional", true)):
		return "EXECUTE_STEAL 应 optional=false（强制发动）"
	if String(steal_p.get("card_kind", &"")) != "ACTION":
		return "EXECUTE_STEAL card_kind 应 ACTION"
	# CONDITIONAL_ACTIONS
	if String(acts[2].get("type", &"")) != "CONDITIONAL_ACTIONS":
		return "effect_01 actions[2] 应 CONDITIONAL_ACTIONS 实=%s" % String(acts[2].get("type", &""))
	var ca_p: Dictionary = acts[2].get("params", {})
	var conds: Array = ca_p.get("conditions", [])
	if conds.is_empty() or String(conds[0].get("op", &"")) != "OWNER_ACTION_HAND_GREATER_THAN_MECH":
		return "CONDITIONAL_ACTIONS condition 应 OWNER_ACTION_HAND_GREATER_THAN_MECH"
	if String(conds[0].get("params", {}).get("mech_id", &"")) != "$payload.attacker_id":
		return "OWNER_ACTION_HAND_GREATER_THAN_MECH mech_id 应 $payload.attacker_id（攻击方）"
	var if_true: Array = ca_p.get("if_true_actions", [])
	if if_true.is_empty() or String(if_true[0].get("type", &"")) != "MODIFY_ATTACK_MIGHT":
		return "CONDITIONAL_ACTIONS if_true 应 MODIFY_ATTACK_MIGHT"
	if int(if_true[0].get("params", {}).get("delta", 0)) != -4:
		return "MODIFY_ATTACK_MIGHT delta 应 -4 实=%d" % int(if_true[0].get("params", {}).get("delta", 0))
	if not ca_p.get("if_false_actions", []).is_empty():
		return "CONDITIONAL_ACTIONS if_false 应空"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：攻击方有牌 -> ATTACK_PRE 弹明牌偷牌窗（face_up/no_cancel/executor/来源方校验），
## 确认后偷1张；我方手牌>攻击方 -> 本次攻击威力-4（extra_might=-4）。
func test_pilot_037_steal_face_up_no_cancel_penalty() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_qingtong(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_037_青瞳）"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 我方手牌空，攻击方1张牌 -> 偷后 我方1 > 攻击方0 -> 减威力
	# 注意：tutorial 初始给双方各抽4张行动牌，须先清 enemy 手牌使"攻击方仅1张"前提成立。
	_set_player_action_hand(gs, [])
	_clear_enemy_action_hand(battle)
	var enemy_cards := _ensure_enemy_action_hand(gs, 1)
	if enemy_cards.is_empty():
		return "enemy 行动手牌补牌失败"
	var enemy_hand_before: int = enemy_player.action_hand.size()

	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, [mech.mech_id])
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# 应弹明牌偷牌窗
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "select_discard_cards":
		return "有牌时 ATTACK_PRE 应弹 select_discard_cards 偷牌窗，wait=%s" % str(wait_info.get("input_type", &""))
	var input_params: Dictionary = wait_info.get("input_params", {})
	# 偷牌来源=攻击方（enemy），执行者=青瞳玩家（player），明牌+不可取消
	if String(input_params.get("discard_player_id", &"")) != "enemy":
		return "偷牌来源方应 enemy 实=%s" % String(input_params.get("discard_player_id", &""))
	if String(input_params.get("executor", &"")) != "player":
		return "偷牌执行者应 player 实=%s" % String(input_params.get("executor", &""))
	if not bool(input_params.get("face_up", false)):
		return "偷牌窗应 face_up=true（明牌显示攻击方手牌）"
	if not bool(input_params.get("no_cancel", false)):
		return "偷牌窗应 no_cancel=true（不可取消）"
	if int(input_params.get("count", 0)) != 1:
		return "偷牌 count 应 1"
	# 确认偷攻击方手牌第1张
	var stolen_cid: StringName = enemy_cards[0]
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": [stolen_cid]})
	await _pump_frames(12)
	# 偷牌成功
	if enemy_player.action_hand.has(stolen_cid):
		return "偷取后牌仍在攻击方手牌"
	if not gs.players.get(&"player").action_hand.has(stolen_cid):
		return "偷取后牌未到青瞳玩家手牌"
	if enemy_player.action_hand.size() != enemy_hand_before - 1:
		return "攻击方手牌应-1 前=%d 后=%d" % [enemy_hand_before, enemy_player.action_hand.size()]
	# 我方(1) > 攻击方(0) -> 本次攻击威力-4
	if int(attack.record.get("extra_might", 0)) != -4:
		return "偷后我方>攻击方应 extra_might=-4 实=%d" % int(attack.record.get("extra_might", 0))
	return true


## 测试3：偷牌后手牌数相等（我方0+1=1 vs 攻击方2-1=1）-> 不减威力（严格大于才算）。
func test_pilot_037_equal_hand_no_penalty() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_qingtong(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 我方0张，攻击方2张 -> 偷1后 1 vs 1 相等 -> 不减威力
	_set_player_action_hand(gs, [])
	var enemy_cards := _ensure_enemy_action_hand(gs, 2)
	if enemy_cards.size() < 2:
		return "enemy 行动手牌补牌不足2张"
	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, [mech.mech_id])
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "select_discard_cards":
		return "有牌时应弹偷牌窗"
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": [enemy_cards[0]]})
	await _pump_frames(12)
	if int(attack.record.get("extra_might", 0)) != 0:
		return "手牌数相等不应减威力 extra_might 应0 实=%d" % int(attack.record.get("extra_might", 0))
	return true


## 测试4：攻击方无牌 -> 不弹偷牌窗，无偷牌，但本次触发仍消耗1次额度（MARK 在动作[0]先执行）。
func test_pilot_037_no_card_skip_popup_consumes_quota() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_qingtong(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	battle.context.action_ui_bridge.context = battle.context
	_clear_enemy_action_hand(battle)

	var attack := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, [mech.mech_id])
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# 无牌不应弹偷牌窗
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) == "select_discard_cards":
		return "无牌攻击方不应弹偷牌窗"
	if gs.players.get(&"player").action_hand.size() != player_hand_before:
		return "无牌攻击方不应产生偷牌（青瞳手牌变化）"
	if not enemy_player.action_hand.is_empty():
		return "无牌攻击方不应产生偷牌（攻击方手牌变化）"
	# 本次触发仍消耗1次额度（MARK_EFFECT_ONCE_PER_TURN_USED 先于 EXECUTE_STEAL 执行）
	var cid: StringName = s.card.instance_id
	if not te.is_once_per_turn_key_available(&"pilot_037_effect_01", cid, 2):
		return "无牌触发后额度应消耗1次（剩余1次可用）"
	return true


## 测试5：每玩家回合2次 -- 同回合第1、2次攻击触发偷牌，第3次攻击因额度用满不触发（不弹窗不偷牌）。
func test_pilot_037_once_per_turn_max2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_qingtong(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var enemy_player = gs.players.get(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var cid: StringName = s.card.instance_id
	var te = battle.context.timing_engine
	if not te.is_once_per_turn_key_available(&"pilot_037_effect_01", cid, 2):
		return "前置错误：初始额度应可用"
	# ── 第1次：有牌 -> 偷牌触发（额度1）──
	# 注意：tutorial 初始给双方各抽4张行动牌（player 手牌含掩护等 ATTACK_PRE 监听卡），
	# 须清 player/enemy 手牌，避免掩护窗抢占偷牌窗、以及"攻击方仅1张"前提不成立。
	_set_player_action_hand(gs, [])
	_clear_enemy_action_hand(battle)
	_ensure_enemy_action_hand(gs, 1)
	var atk1 := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, [mech.mech_id])
	te.fire_timing(_TimingConst.ATTACK_PRE, atk1)
	await _pump_frames(3)
	if String(_get_wait(battle).get("input_type", &"")) != "select_discard_cards":
		return "第1次攻击应弹偷牌窗"
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": [enemy_player.action_hand[0]]})
	await _pump_frames(12)
	if not te.is_once_per_turn_key_available(&"pilot_037_effect_01", cid, 2):
		return "第1次触发后额度应剩1次可用"
	# ── 第2次：有牌 -> 偷牌触发（额度2/2 满）──
	_clear_enemy_action_hand(battle)
	_ensure_enemy_action_hand(gs, 1)
	var atk2 := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, [mech.mech_id])
	te.fire_timing(_TimingConst.ATTACK_PRE, atk2)
	await _pump_frames(3)
	if String(_get_wait(battle).get("input_type", &"")) != "select_discard_cards":
		return "第2次攻击应弹偷牌窗"
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": [enemy_player.action_hand[0]]})
	await _pump_frames(12)
	if te.is_once_per_turn_key_available(&"pilot_037_effect_01", cid, 2):
		return "第2次触发后额度应已用满"
	# ── 第3次：有牌但额度用满 -> 效果跳过（条件 EFFECT_ONCE_PER_TURN_AVAILABLE 失败）──
	_clear_enemy_action_hand(battle)
	var atk3_cards := _ensure_enemy_action_hand(gs, 1)
	if atk3_cards.is_empty():
		return "第3次前置：enemy 补牌失败"
	var enemy_hand_before3: int = enemy_player.action_hand.size()
	var atk3 := _make_attack(battle, enemy_mech.mech_id, mech.mech_id, [mech.mech_id])
	te.fire_timing(_TimingConst.ATTACK_PRE, atk3)
	await _pump_frames(3)
	if String(_get_wait(battle).get("input_type", &"")) == "select_discard_cards":
		return "第3次攻击额度用满不应弹偷牌窗"
	if enemy_player.action_hand.size() != enemy_hand_before3:
		return "第3次攻击不应偷牌（攻击方手牌应不变）"
	if int(atk3.record.get("extra_might", 0)) != 0:
		return "第3次攻击不应触发减威力"
	return true


## 测试6：双连多目标算同一攻击只触发1次 -- ATTACK_PRE 对含青瞳的多目标攻击只弹1次偷牌窗。
func test_pilot_037_multi_target_single_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_qingtong(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 双连：攻击同时指向 enemy 自己和青瞳（enemy 自攻+青瞳）——含青瞳即触发；只触发1次
	_ensure_enemy_action_hand(gs, 1)
	var atk := _make_attack(battle, enemy_mech.mech_id, enemy_mech.mech_id, [mech.mech_id, enemy_mech.mech_id])
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, atk)
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "select_discard_cards":
		return "含青瞳的多目标攻击应弹偷牌窗"
	# 确认偷牌后无第二个偷牌窗（只触发1次，额度1）
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": [gs.players.get(&"enemy").action_hand[0]]})
	await _pump_frames(12)
	var wait2: Dictionary = _get_wait(battle)
	if String(wait2.get("input_type", &"")) == "select_discard_cards":
		return "双连同一攻击不应触发第二次偷牌窗"
	return true
