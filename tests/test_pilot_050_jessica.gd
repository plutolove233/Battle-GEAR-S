## test_pilot_050_jessica.gd - 杰西卡 pilot_050 动力税 + 受伤X+1弃牌 测试
##
## 权威文本：
##   效果1「其他机甲在我方4+X格范围内每消耗2动力，可以使该机甲和我方各受到2伤害（X初始为0）。」
##   效果2「每回合1次，我方受到伤害后，可以使X+1，并弃置我方和4+X格范围内的1台其他机甲各2张行动牌。」
##
## 拆解（2 按钮被动，全部通用机制组装，不新增原子动作、不与机师ID绑定）：
##   - effect_01 动力税·移动消耗（按钮1）：LISTEN BASIC_MOVE_AT（basic_move step② 扣动力后、
##     step③ 移位前触发 -> 先消耗再移动，范围判定用消耗时位置；single_move 逐格 fork -> 逐格中断）。
##   - effect_01b 动力税·非移动消耗（隐藏，merge 到按钮1）：LISTEN power_spent 虚拟时点
##     （GameActions.spend_power 统一通知全部非移动消耗；reason=BASIC_MOVE 除外防双计；
##     玛丽尔/巴托洛夫减动力走 modify_mech_power 不经 spend_power 天然不计）。
##   - 两效果共用 POWER_SPEND_TAX：范围内其他机甲每累计消耗2点 -> 弹确认窗（消耗时阻塞）；
##     确认 -> 两次独立 hp_change（先该机甲后我方，来源均为我方，顺序结算）；
##     确认/拒绝都清这2点（余数留存）；一次消耗N点=floor(N/2)次询问串行。
##     累计存 counters["power_tax_accum_<mech_id>"]，X 存 counters["var_pilot_050_x"]。
##   - effect_02 受伤X+1弃牌（按钮2）：LISTEN HP_CHANGE_SETTLE（我方实际掉血），每回合1次
##     （取消不消耗）。确认 -> mark + X+1（先于范围计算）-> 按新X选范围内其他机甲
##     （无候选=仅X+1跳过弃牌）-> 先我方后目标各弃2张（chooser均为我方；目标牌牌背
##     hide_card_info；手牌<=2直接全选不弹窗）。
##
## 覆盖（PvP 双人类）：
##   1. 效果定义形状 + 监听器注册（BASIC_MOVE_AT/power_spent/HP_CHANGE_SETTLE）+ 旧定义已删
##   2. e1 移动耗2（范围内）-> 弹窗阻塞 -> 确认 -> 双方各-2
##   3. e1 拒绝 -> 不扣血 + 累计清零（后续耗1不再触发）
##   4. e1 耗1不触发累计1；再耗1触发；拒绝清零后再耗1仍不触发
##   5. e1 一次耗3 -> 1次弹窗，余1留存
##   6. e1 5格外不弹；X=1 -> 5格内弹（X扩范围）
##   7. e1 免费移动不计 + 我方自己消耗不计
##   8. e1 非移动消耗经 power_spent 事件触发（spend_power reason!=BASIC_MOVE）；
##      reason=BASIC_MOVE 不触发（防双计）
##   9. e1 顺序结算：双方都剩2生命 -> 确认 -> 目标先死（双方均毁）
##   10. e2 确认全流程：X+1 -> 选目标 -> 双方各弹多选弃2（手牌3+3）
##   11. e2 取消 -> X不变 + 次数未消耗（再受伤可再触发）
##   12. e2 范围内无其他机甲 -> 仅 X+1 跳过弃牌
##   13. e2 手牌<=2 -> 直接全选不弹窗（我方2张全弃、目标1张全弃）
##   14. e2 每回合1次用满 -> 再受伤不弹
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GeneratedPilotEffects = preload("res://scripts/generated_database/GeneratedPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	# PvP 双人类玩家：同种子 + 地图特征 + enemy 人类
	battle.rng_seed = 90050
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
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


## 设杰西卡为 owner_id 机甲的机师（set_pilot 注册全部 LISTEN 永久监听器）；失败返回 null
func _setup_jessica(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return null
	var card = _make_instance(gs, cdb, "pilot_050_杰西卡", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"mech": mech, "pilot_card": card, "gs": gs, "cdb": cdb, "te": battle.context.timing_engine}


## 构造 basic_move 动作（fire BASIC_MOVE_AT 用），已注册进 action_registry。
## cost=本次消耗动力；free=免费移动（不实际消耗）。
func _make_move(battle, mover_mech_id: StringName, cost: int, free: bool = false) -> _Action:
	var mv := _Action.new()
	mv.action_id = &"test_p050_mv_%d" % [randi() % 1000000]
	mv.action_type = &"basic_move"
	mv.record = {"mech_id": mover_mech_id, "power_cost": cost, "free_move": free}
	mv.state = &"running"
	mv.context = battle.context
	battle.context.action_registry.register(mv)
	return mv


## 构造 hp_change 动作（fire HP_CHANGE_SETTLE 用，e2 触发源）
func _make_hp_change(battle, mech_ids: Array, value: int) -> _Action:
	var hp_act := _Action.new()
	hp_act.action_id = &"test_p050_hp_%d" % [randi() % 1000000]
	hp_act.action_type = &"hp_change"
	hp_act.record = {"mech_ids": mech_ids, "value": value, "method": &"decrease"}
	hp_act.state = &"running"
	hp_act.context = battle.context
	battle.context.action_registry.register(hp_act)
	return hp_act


## 清空双方初始行动手牌（开局各4张），保证发牌数即手牌数
func _clear_hands(s) -> void:
	for pid in [&"player", &"enemy"]:
		var p = s.gs.players.get(pid)
		if p != null:
			p.action_hand.clear()


## 给玩家 n 张行动牌（真实实例进手牌），返回 instance_id 数组
func _give_action_cards(s, pid: StringName, n: int) -> Array:
	var ids: Array = []
	for i in n:
		var c = _make_instance(s.gs, s.cdb, "action_001_进攻", pid)
		if c == null:
			return ids
		s.gs.players.get(pid).action_hand.append(c.instance_id)
		ids.append(c.instance_id)
	return ids


## 排干所有挂起弹窗（一律取消；e1 测试里用于消掉 e2 因我方自伤弹出的确认窗）
func _drain_pending(tek) -> int:
	var n: int = 0
	while tek._pending_effect.size() > 0 and n < 8:
		var keys: Array = tek._pending_effect.keys()
		tek.resume_pending_effect(keys[keys.size() - 1], {"cancelled": true})
		n += 1
		await _pump_frames(2)
	return n


## 读杰西卡 X（card.counters["var_pilot_050_x"]）
func _get_x(s) -> int:
	if s.pilot_card.counters == null:
		return 0
	return int(s.pilot_card.counters.get("var_pilot_050_x", 0))


## 读某机甲的动力税累计（card.counters["power_tax_accum_<mech_id>"]）
func _get_accum(s, mech_id: StringName) -> int:
	if s.pilot_card.counters == null:
		return 0
	return int(s.pilot_card.counters.get("power_tax_accum_%s" % String(mech_id), 0))


# ═══════════════════════════════════════════
# 定义与注册
# ═══════════════════════════════════════════

## 测试1：三个效果定义形状 + set_pilot 注册 + 旧定义已删
func test_pilot_050_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_050_effect_01")
	if e1 == null:
		return "缺 pilot_050_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "e1 mode 应 LISTEN"
	if e1.listen_timing != _TimingConst.BASIC_MOVE_AT:
		return "e1 listen_timing 应 BASIC_MOVE_AT，实=%s" % String(e1.listen_timing)
	if e1.listen_action_type != &"basic_move":
		return "e1 listen_action_type 应 basic_move"
	var e1_acts = e1.actions
	if e1_acts.size() != 1 or String(e1_acts[0].get("type", &"")) != "POWER_SPEND_TAX":
		return "e1 actions 应 [POWER_SPEND_TAX]"
	var e1_p: Dictionary = e1_acts[0].get("params", {})
	if int(e1_p.get("base_range", 0)) != 4 or int(e1_p.get("damage", 0)) != 2 or int(e1_p.get("threshold", 0)) != 2:
		return "e1 参数应 base_range=4 damage=2 threshold=2，实=%s" % str(e1_p)
	if String(e1_p.get("counter_key", &"")) != "pilot_050_x":
		return "e1 counter_key 应 pilot_050_x"

	var e1b = effects.get(&"pilot_050_effect_01b")
	if e1b == null:
		return "缺 pilot_050_effect_01b"
	if e1b.listen_timing != _TimingConst.POWER_SPENT:
		return "e1b listen_timing 应 power_spent，实=%s" % String(e1b.listen_timing)
	if e1b.listen_action_type != &"":
		return "e1b listen_action_type 应空（任意宿主动作）"
	if not bool(e1b.hide_button):
		return "e1b 应 hide_button=true"
	if int(e1b.merge_desc_into_index) != 1:
		return "e1b merge_desc_into_index 应 1"

	var e2 = effects.get(&"pilot_050_effect_02")
	if e2 == null:
		return "缺 pilot_050_effect_02"
	if e2.listen_timing != _TimingConst.HP_CHANGE_SETTLE:
		return "e2 listen_timing 应 HP_CHANGE_SETTLE"
	if e2.listen_action_type != &"hp_change":
		return "e2 listen_action_type 应 hp_change"
	if String(e2.once_per_turn_key) != "pilot_050_effect_02":
		return "e2 once_per_turn_key 应 pilot_050_effect_02"
	var e2_ops: Array = []
	for c in e2.conditions:
		e2_ops.append(String(c.get("op", &"")))
	for need in ["HP_CHANGE_TARGET_IS_SELF", "HP_CHANGE_LIVE_METHOD_IS", "HP_CHANGE_AMOUNT_ABOVE"]:
		if not e2_ops.has(need):
			return "e2 应含条件 %s: %s" % [need, str(e2_ops)]
	var e2_acts = e2.actions
	if e2_acts.size() != 1 or String(e2_acts[0].get("type", &"")) != "POWER_TAX_TRIBUTE":
		return "e2 actions 应 [POWER_TAX_TRIBUTE]"

	# 旧 CardEffect 定义已删（迁移至 ActionPilotEffects）
	if _GeneratedPilotEffects.build_pilot_effects().has(&"pilot_050_effect_01"):
		return "旧 GeneratedPilotEffects 不应再有 pilot_050_effect_01"

	# set_pilot 注册三个监听器
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_050_杰西卡 或 effect_ids 未含 e1b）"
	var te = s.te
	var found := {"e1": false, "e1b": false, "e2": false}
	for entry in te.permanent_listeners.get(_TimingConst.BASIC_MOVE_AT, []):
		var eff = entry.get("effect", null)
		if eff != null and String(eff.effect_id) == "pilot_050_effect_01":
			found["e1"] = true
	for entry in te.permanent_listeners.get(&"power_spent", []):
		var eff = entry.get("effect", null)
		if eff != null and String(eff.effect_id) == "pilot_050_effect_01b":
			found["e1b"] = true
	for entry in te.permanent_listeners.get(_TimingConst.HP_CHANGE_SETTLE, []):
		var eff = entry.get("effect", null)
		if eff != null and String(eff.effect_id) == "pilot_050_effect_02":
			found["e2"] = true
	if not (found["e1"] and found["e1b"] and found["e2"]):
		return "监听器注册不全：%s" % str(found)
	return true


# ═══════════════════════════════════════════
# 效果1 动力税
# ═══════════════════════════════════════════

## 测试2：范围内移动耗2 -> 弹窗阻塞 -> 确认 -> 该机甲与我方各-2
func test_pilot_050_e1_move_confirm_damage() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 7, "r": 0}  # 距离2 <= 4
	var t_hp0: int = enemy_mech.current_hp
	var o_hp0: int = s.mech.current_hp
	var mv := _make_move(battle, enemy_mech.mech_id, 2)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv)
	if mv.state != &"waiting_timing":
		return "范围内耗2应弹窗阻塞，state=%s" % String(mv.state)
	s.te.resume_pending_effect(mv.action_id, {"chosen_option_index": 0})
	await _pump_frames(4)
	# e2 因我方自伤弹确认窗 -> 取消排干
	await _drain_pending(s.te)
	await _pump_frames(8)
	if enemy_mech.current_hp != t_hp0 - 2:
		return "确认后该机甲应-2（%d->%d）" % [t_hp0, enemy_mech.current_hp]
	if s.mech.current_hp != o_hp0 - 2:
		return "确认后我方应-2（%d->%d）" % [o_hp0, s.mech.current_hp]
	if _get_accum(s, enemy_mech.mech_id) != 0:
		return "确认后累计应清0，实=%d" % _get_accum(s, enemy_mech.mech_id)
	return true


## 测试3：拒绝 -> 不扣血 + 累计清零（后续耗1不再触发）
func test_pilot_050_e1_move_decline_clears() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var t_hp0: int = enemy_mech.current_hp
	var o_hp0: int = s.mech.current_hp
	var mv := _make_move(battle, enemy_mech.mech_id, 2)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv)
	if mv.state != &"waiting_timing":
		return "耗2应弹窗"
	s.te.resume_pending_effect(mv.action_id, {"cancelled": true})
	await _pump_frames(6)
	if enemy_mech.current_hp != t_hp0 or s.mech.current_hp != o_hp0:
		return "拒绝不应扣血（%d/%d 实 %d/%d）" % [t_hp0, o_hp0, enemy_mech.current_hp, s.mech.current_hp]
	if _get_accum(s, enemy_mech.mech_id) != 0:
		return "拒绝后累计应清0（无论是否发动），实=%d" % _get_accum(s, enemy_mech.mech_id)
	# 清零后再耗1 -> 不触发
	var mv2 := _make_move(battle, enemy_mech.mech_id, 1)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv2)
	await _pump_frames(4)
	if mv2.state == &"waiting_timing":
		return "拒绝清零后再耗1不应弹窗"
	if _get_accum(s, enemy_mech.mech_id) != 1:
		return "再耗1后累计应1，实=%d" % _get_accum(s, enemy_mech.mech_id)
	return true


## 测试4：耗1不触发累计1；再耗1触发（跨动作累计）
func test_pilot_050_e1_accumulate_across_actions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var mv1 := _make_move(battle, enemy_mech.mech_id, 1)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv1)
	await _pump_frames(4)
	if mv1.state == &"waiting_timing":
		return "耗1不应弹窗"
	if _get_accum(s, enemy_mech.mech_id) != 1:
		return "耗1后累计应1，实=%d" % _get_accum(s, enemy_mech.mech_id)
	var mv2 := _make_move(battle, enemy_mech.mech_id, 1)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv2)
	if mv2.state != &"waiting_timing":
		return "累计2应弹窗（state=%s）" % String(mv2.state)
	s.te.resume_pending_effect(mv2.action_id, {"cancelled": true})
	await _pump_frames(4)
	if _get_accum(s, enemy_mech.mech_id) != 0:
		return "触发后累计应清0，实=%d" % _get_accum(s, enemy_mech.mech_id)
	return true


## 测试5：一次耗3 -> 1次弹窗，余1留存
func test_pilot_050_e1_triple_spend_remainder() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var mv := _make_move(battle, enemy_mech.mech_id, 3)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv)
	if mv.state != &"waiting_timing":
		return "耗3应弹1次窗（state=%s）" % String(mv.state)
	var ctx: Dictionary = mv.record.get("_power_tax_ctx", {})
	if int(ctx.get("prompts_left", 0)) != 1:
		return "耗3应只问1次（prompts_left=1），实=%s" % str(ctx.get("prompts_left"))
	s.te.resume_pending_effect(mv.action_id, {"cancelled": true})
	await _pump_frames(4)
	if _get_accum(s, enemy_mech.mech_id) != 1:
		return "耗3触发1次后余1，实=%d" % _get_accum(s, enemy_mech.mech_id)
	return true


## 测试6：5格外（X=0）不弹；X=1 -> 5格内弹（X扩范围）
func test_pilot_050_e1_range_x_expansion() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 10, "r": 0}  # 距离5 > 4
	var mv := _make_move(battle, enemy_mech.mech_id, 2)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv)
	await _pump_frames(4)
	if mv.state == &"waiting_timing":
		return "5格外（X=0）不应弹窗"
	if _get_accum(s, enemy_mech.mech_id) != 0:
		return "范围外消耗不应累计，实=%d" % _get_accum(s, enemy_mech.mech_id)
	# X=1：范围 4+1=5 -> 触发
	s.pilot_card.counters["var_pilot_050_x"] = 1
	var mv2 := _make_move(battle, enemy_mech.mech_id, 2)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv2)
	if mv2.state != &"waiting_timing":
		return "X=1 时5格内应弹窗（state=%s）" % String(mv2.state)
	s.te.resume_pending_effect(mv2.action_id, {"cancelled": true})
	await _pump_frames(4)
	return true


## 测试7：免费移动不计 + 我方自己消耗不计
func test_pilot_050_e1_free_move_and_self() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	# 免费移动（free_move=true 未实际消耗）
	var mv_free := _make_move(battle, enemy_mech.mech_id, 1, true)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv_free)
	await _pump_frames(4)
	if mv_free.state == &"waiting_timing":
		return "免费移动不应弹窗"
	if _get_accum(s, enemy_mech.mech_id) != 0:
		return "免费移动不应累计，实=%d" % _get_accum(s, enemy_mech.mech_id)
	# 我方自己消耗
	var mv_self := _make_move(battle, s.mech.mech_id, 2)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv_self)
	await _pump_frames(4)
	if mv_self.state == &"waiting_timing":
		return "我方自己消耗不应弹窗"
	return true


## 测试8：非移动消耗经 power_spent 事件触发；reason=BASIC_MOVE 不触发（防双计）
func test_pilot_050_e1_power_spent_event() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	var t_hp0: int = enemy_mech.current_hp
	enemy_mech.power = 10  # spend_power 有余额校验
	# 宿主动作（装备效果等非移动消耗的宿主）：手动设为当前执行步骤动作
	var host := _Action.new()
	host.action_id = &"test_p050_host_%d" % [randi() % 1000000]
	host.action_type = &"stat_modify"
	host.record = {"mech_id": enemy_mech.mech_id}
	host.state = &"running"
	host.context = battle.context
	battle.context.action_registry.register(host)
	battle.context.action_engine.current_step_action = host
	battle.context.game_actions.spend_power({"mech_id": enemy_mech.mech_id, "amount": 2, "reason": &"EFFECT_COST"})
	battle.context.action_engine.current_step_action = null
	if host.state != &"waiting_timing":
		return "非移动消耗2应经 power_spent 事件弹窗（state=%s）" % String(host.state)
	s.te.resume_pending_effect(host.action_id, {"chosen_option_index": 0})
	await _pump_frames(4)
	await _drain_pending(s.te)
	await _pump_frames(6)
	if enemy_mech.current_hp != t_hp0 - 2:
		return "确认后该机甲应-2（%d->%d）" % [t_hp0, enemy_mech.current_hp]
	# reason=BASIC_MOVE：spend_power 不通知（移动由 BASIC_MOVE_AT 监听），不双计
	var host2 := _Action.new()
	host2.action_id = &"test_p050_host2_%d" % [randi() % 1000000]
	host2.action_type = &"stat_modify"
	host2.record = {"mech_id": enemy_mech.mech_id}
	host2.state = &"running"
	host2.context = battle.context
	battle.context.action_registry.register(host2)
	battle.context.action_engine.current_step_action = host2
	battle.context.game_actions.spend_power({"mech_id": enemy_mech.mech_id, "amount": 2, "reason": &"BASIC_MOVE"})
	battle.context.action_engine.current_step_action = null
	if host2.state == &"waiting_timing":
		return "reason=BASIC_MOVE 不应经 power_spent 触发（防双计）"
	return true


## 测试9：顺序结算：双方都剩2生命 -> 确认 -> 该机甲先死，战斗结束我方胜利
## （规格：对方先死我方胜利；胜利判定后引擎拦截后续动作，第二次自伤不执行属正确行为）
func test_pilot_050_e1_sequential_death() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	enemy_mech.current_hp = 2
	s.mech.current_hp = 2
	var mv := _make_move(battle, enemy_mech.mech_id, 2)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AT, mv)
	if mv.state != &"waiting_timing":
		return "耗2应弹窗"
	s.te.resume_pending_effect(mv.action_id, {"chosen_option_index": 0})
	await _pump_frames(4)
	await _drain_pending(s.te)
	await _pump_frames(8)
	if not enemy_mech.destroyed:
		return "该机甲剩2生命应被毁（先结算），hp=%d" % enemy_mech.current_hp
	if s.mech.destroyed or s.mech.current_hp != 2:
		return "对方先死战斗即结束，我方不应再受伤（hp=%d destroyed=%s）" % [s.mech.current_hp, str(s.mech.destroyed)]
	if s.gs.phase != &"battle_over":
		return "对方先死战斗应结束，phase=%s" % String(s.gs.phase)
	var victory: Dictionary = battle.context.victory_service.check_victory()
	if String(victory.get("winner", &"")) != "player":
		return "对方先死应判我方胜利，实=%s" % str(victory)
	return true


# ═══════════════════════════════════════════
# 效果2 受伤X+1弃牌
# ═══════════════════════════════════════════

## 测试10：确认全流程：X+1 -> 选目标 -> 双方各弹多选弃2（手牌3+3）
func test_pilot_050_e2_confirm_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}  # X+1后范围5内
	_clear_hands(s)
	var my_cards := _give_action_cards(s, &"player", 3)
	var foe_cards := _give_action_cards(s, &"enemy", 3)
	if my_cards.size() != 3 or foe_cards.size() != 3:
		return "发牌失败"
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 3)
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "我方受伤应弹确认窗（state=%s）" % String(hp_act.state)
	# 确认 -> X+1 -> 选目标
	s.te.resume_pending_effect(hp_act.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	if _get_x(s) != 1:
		return "确认后 X 应+1=1，实=%d" % _get_x(s)
	if hp_act.state != &"waiting_timing":
		return "确认后应挂起选目标（state=%s）" % String(hp_act.state)
	s.te.resume_pending_effect(hp_act.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(3)
	# 我方弃2（手牌3 -> 弹多选窗，必选2）
	if hp_act.state != &"waiting_timing":
		return "应挂起我方弃牌选择（state=%s）" % String(hp_act.state)
	s.te.resume_pending_effect(hp_act.action_id, {"selected_card_ids": [my_cards[0], my_cards[1]]})
	await _pump_frames(4)
	# 目标弃2（手牌3 -> 弹多选窗，chooser 仍为我方）
	if hp_act.state != &"waiting_timing":
		return "应挂起目标弃牌选择（state=%s）" % String(hp_act.state)
	s.te.resume_pending_effect(hp_act.action_id, {"selected_card_ids": [foe_cards[0], foe_cards[2]]})
	await _pump_frames(8)
	var my_hand = s.gs.players.get(&"player").action_hand
	var foe_hand = s.gs.players.get(&"enemy").action_hand
	if my_hand.size() != 1 or String(my_hand[0]) != String(my_cards[2]):
		return "我方应剩1张（%s），实=%s" % [String(my_cards[2]), str(my_hand)]
	if foe_hand.size() != 1 or String(foe_hand[0]) != String(foe_cards[1]):
		return "目标应剩1张（%s），实=%s" % [String(foe_cards[1]), str(foe_hand)]
	if s.te.is_once_per_turn_key_available(&"pilot_050_effect_02", s.pilot_card.instance_id):
		return "确认发动后每回合1次应已用满"
	return true


## 测试11：取消 -> X不变 + 次数未消耗（再受伤可再触发）
func test_pilot_050_e2_cancel_keeps_quota() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 3)
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "我方受伤应弹确认窗"
	s.te.resume_pending_effect(hp_act.action_id, {"cancelled": true})
	await _pump_frames(6)
	if _get_x(s) != 0:
		return "取消后 X 不应变，实=%d" % _get_x(s)
	if not s.te.is_once_per_turn_key_available(&"pilot_050_effect_02", s.pilot_card.instance_id):
		return "取消不应消耗每回合1次"
	# 再受伤 -> 仍可触发
	var hp2 := _make_hp_change(battle, [s.mech.mech_id], 2)
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp2)
	if hp2.state != &"waiting_timing":
		return "取消后再受伤应再弹（次数未消耗）"
	s.te.resume_pending_effect(hp2.action_id, {"cancelled": true})
	await _pump_frames(4)
	return true


## 测试12：范围内无其他机甲 -> 仅 X+1 跳过弃牌
func test_pilot_050_e2_no_candidates_x_only() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 12, "r": 0}  # 距离7 > 4+1（X+1后范围5）
	_clear_hands(s)
	var my_cards := _give_action_cards(s, &"player", 3)
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 3)
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "我方受伤应弹确认窗"
	s.te.resume_pending_effect(hp_act.action_id, {"chosen_option_index": 0})
	await _pump_frames(8)
	if _get_x(s) != 1:
		return "无候选仍应 X+1=1，实=%d" % _get_x(s)
	if hp_act.state == &"waiting_timing":
		return "无候选不应再弹（选目标/弃牌整段跳过）"
	if s.gs.players.get(&"player").action_hand.size() != my_cards.size():
		return "无候选不应弃我方牌"
	if s.te.is_once_per_turn_key_available(&"pilot_050_effect_02", s.pilot_card.instance_id):
		return "确认发动（仅X+1）后次数应已用满"
	return true


## 测试13：手牌<=2 -> 直接全选不弹窗（我方2张全弃、目标1张全弃）
func test_pilot_050_e2_auto_all_when_le2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	_clear_hands(s)
	_give_action_cards(s, &"player", 2)
	_give_action_cards(s, &"enemy", 1)
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 3)
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "我方受伤应弹确认窗"
	s.te.resume_pending_effect(hp_act.action_id, {"chosen_option_index": 0})
	await _pump_frames(3)
	s.te.resume_pending_effect(hp_act.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(10)
	if _get_x(s) != 1:
		return "X 应+1=1，实=%d" % _get_x(s)
	if s.gs.players.get(&"player").action_hand.size() != 0:
		return "我方2张应全弃不弹窗，实=%d" % s.gs.players.get(&"player").action_hand.size()
	if s.gs.players.get(&"enemy").action_hand.size() != 0:
		return "目标1张应全弃不弹窗，实=%d" % s.gs.players.get(&"enemy").action_hand.size()
	return true


## 测试14：每回合1次用满 -> 再受伤不弹
func test_pilot_050_e2_once_per_turn_gate() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_jessica(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	s.mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 12, "r": 0}  # 无候选：仅X+1，流程最短
	var hp_act := _make_hp_change(battle, [s.mech.mech_id], 3)
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp_act)
	if hp_act.state != &"waiting_timing":
		return "首次受伤应弹确认窗"
	s.te.resume_pending_effect(hp_act.action_id, {"chosen_option_index": 0})
	await _pump_frames(8)
	if _get_x(s) != 1:
		return "首次确认 X 应=1"
	# 同回合再受伤 -> 已用满，不弹
	var hp2 := _make_hp_change(battle, [s.mech.mech_id], 2)
	s.te.fire_timing(_TimingConst.HP_CHANGE_SETTLE, hp2)
	await _pump_frames(4)
	if hp2.state == &"waiting_timing":
		return "每回合1次用满后不应再弹"
	if _get_x(s) != 1:
		return "未发动 X 不应变，实=%d" % _get_x(s)
	return true
