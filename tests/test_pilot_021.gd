## test_pilot_021.gd - 提比里安（pilot_021）效果测试
##
## 提比里安 2 按钮：
##   effect_01（主动 DIRECT）「弃甲铸威」：我方回合1次，弃置1张武器装备牌（实体，设置/未设置/
##     备用区都算，虚拟武器天然排除），该武器牌面威力每5点 → 本回合下次攻击威力+3。
##     威力加成存 PILOT_022_POWER_BONUS 状态（stacks=加成点数，duration=1），由状态监听器在
##     下次我方攻击 ATTACK_PRE 注入 extra_might 后移除（用完即清）；回合结束兜底清除。
##   effect_02（被动 LISTEN ATTACK_PRE priority40）「本局1次·火力爆发」：
##     我方攻击时弹窗询问；确认后初始威力=攻击武器原本威力×1.5(向下取整，delta=floor(原威力/2)
##     累加 extra_might)、范围+3、对所有攻击目标施加 LOCKED(duration 1 预判式)、
##     写 counters["pilot_021_effect_02_used"] 本局仅一次。
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
	battle.rng_seed = 90022
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


## 设提比里安为 owner_id 机甲的机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_021(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_021_提比里安", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 给 owner_id 玩家装备手牌加一把武器牌（def_id），返回实例 id
func _add_weapon_to_equipment_hand(battle, def_id: String, owner_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, owner_id)
	if card == null:
		return &""
	card.zone = &"equipment_hand"
	gs.players.get(owner_id).equipment_hand.append(card.instance_id)
	return card.instance_id


## 触发提比里安 effect_01（DIRECT 按钮），返回挂起的 effect_fire action（或 null）
func _fire_pilot_021_effect1(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_021_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_021_effect_01",
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


## resume effect_01 多选窗：选中武器牌
func _resume_select_weapon(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(10)


## resume effect_01 取消
func _resume_cancel(battle, ef_action) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"cancelled": true})
	await _pump_frames(6)


## 构造 attack action（fire ATTACK_PRE 用）。weapon_id 用于 effect_02 原本威力计算。
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName, weapon_id: StringName = &"") -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p022_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	if weapon_id != &"":
		attack.record["weapon_id"] = weapon_id
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 找机甲上的 PILOT_022_POWER_BONUS 状态（无则返回 {}）
func _find_p022_bonus(gs, mech_id: StringName) -> Dictionary:
	var m = gs.mechs.get(mech_id)
	if m == null:
		return {}
	for s: Dictionary in m.statuses:
		if String(s.get("type", &"")) == "PILOT_022_POWER_BONUS":
			return s
	return {}


## 统计机甲上 LOCKED 状态数
func _count_locked(gs, mech_id: StringName) -> int:
	var m = gs.mechs.get(mech_id)
	if m == null:
		return 0
	return m.statuses.filter(func(s): return String(s.get("type", &"")) == "LOCKED").size()


# ═══════════════════════════════════════════
# effect_01 定义
# ═══════════════════════════════════════════

## 测试1：effect_01 定义（MODE_DIRECT, once_per_turn_max=1, 双条件, 弃武器+加成动作链）
func test_pilot_021_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_021_effect_01")
	if e == null:
		return "缺 pilot_021_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e.mode)
	if e.once_per_turn_key != &"pilot_021_effect_01":
		return "once_per_turn_key 应 pilot_021_effect_01"
	if int(e.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("IS_OWNER_MAIN_PHASE"):
		return "应含 IS_OWNER_MAIN_PHASE"
	if not ops.has("OWNER_HAS_WEAPON_EQUIPMENT_CARD"):
		return "应含 OWNER_HAS_WEAPON_EQUIPMENT_CARD"
	var acts = e.actions
	if acts.size() != 3:
		return "actions 应3步 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "actions[0] 应 CHOOSE_MANY_CARDS"
	var cm = acts[0].get("params", {})
	if cm.get("source", &"") != &"OWNER_WEAPON_EQUIPMENT_CARDS":
		return "CHOOSE_MANY_CARDS source 应 OWNER_WEAPON_EQUIPMENT_CARDS"
	if int(cm.get("min_count", 0)) != 1 or int(cm.get("max_count", 0)) != 1:
		return "CHOOSE_MANY_CARDS min/max 应1"
	if cm.get("store_result_key", &"") != &"pilot_021_weapon":
		return "store_result_key 应 pilot_021_weapon"
	if String(acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "actions[1] 应 EXECUTE_DISCARD"
	if acts[1].get("params", {}).get("card_ids", &"") != "$runtime.pilot_021_weapon":
		return "EXECUTE_DISCARD card_ids 应 $runtime.pilot_021_weapon"
	if String(acts[2].get("type", &"")) != "PILOT_022_APPLY_POWER_BONUS":
		return "actions[2] 应 PILOT_022_APPLY_POWER_BONUS"
	return true


# ═══════════════════════════════════════════
# effect_02 定义
# ═══════════════════════════════════════════

## 测试2：effect_02 定义（MODE_LISTEN ATTACK_PRE priority40, 双条件, 弹窗+威力/范围/锁定/标记）
func test_pilot_021_effect_02_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_021_effect_02")
	if e == null:
		return "缺 pilot_021_effect_02"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_PRE:
		return "effect_02 listen_timing 应 ATTACK_PRE"
	if int(e.priority) != 40:
		return "effect_02 priority 应 40 实=%d" % int(e.priority)
	if e.listen_action_type != &"attack":
		return "listen_action_type 应 attack"
	var ops2: Array = []
	for c in e.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("SELF_MECH_IS_ATTACKER"):
		return "应含 SELF_MECH_IS_ATTACKER"
	if not ops2.has("PILOT_022_NOT_USED_THIS_GAME"):
		return "应含 PILOT_022_NOT_USED_THIS_GAME"
	if String(e.target_rules[0].get("rule", &"")) != "ALL_CURRENT_ATTACK_MECH_TARGETS":
		return "target_rule 应 ALL_CURRENT_ATTACK_MECH_TARGETS"
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "actions 应 [CHOOSE_ONE]"
	if not bool(acts[0].get("params", {}).get("optional", false)):
		return "CHOOSE_ONE 应 optional=true"
	var options: Array = acts[0].get("params", {}).get("options", [])
	if options.size() != 1:
		return "options 应1个 实=%d" % options.size()
	var oa: Array = options[0].get("actions", [])
	if String(oa[0].get("type", &"")) != "PILOT_022_MULTIPLY_ATTACK_MIGHT":
		return "option[0] 应 PILOT_022_MULTIPLY_ATTACK_MIGHT"
	if String(oa[1].get("type", &"")) != "MODIFY_ATTACK_RANGE" or int(oa[1].get("params", {}).get("delta", 0)) != 3:
		return "option[1] 应 MODIFY_ATTACK_RANGE delta=3"
	var fet = oa[2]
	if String(fet.get("type", &"")) != "FOR_EACH_TARGET":
		return "option[2] 应 FOR_EACH_TARGET"
	if fet.get("params", {}).get("targets", &"") != "$selected_targets":
		return "FOR_EACH_TARGET targets 应 $selected_targets"
	var inner: Array = fet.get("params", {}).get("actions", [])
	if String(inner[0].get("type", &"")) != "ADD_STATUS":
		return "FOR_EACH_TARGET inner 应 ADD_STATUS"
	var st_params = inner[0].get("params", {})
	if st_params.get("status_type", &"") != &"LOCKED" or int(st_params.get("duration", 0)) != 1:
		return "ADD_STATUS 应 LOCKED duration 1"
	if st_params.get("target_id", &"") != "$current_target.mech_id":
		return "ADD_STATUS target_id 应 $current_target.mech_id"
	if String(oa[3].get("type", &"")) != "PILOT_022_MARK_USED":
		return "option[3] 应 PILOT_022_MARK_USED"
	return true


# ═══════════════════════════════════════════
# effect_01 行为
# ═══════════════════════════════════════════

## 测试3：e01 弃武器(威力12) → 加成6 状态 + 武器弃置 + once_per_turn 消耗
func test_pilot_021_e01_discard_weapon_apply_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_021_提比里安）"
	var gs = s.gs
	var mech = s.mech
	var player = gs.players.get(&"player")
	battle.context.action_ui_bridge.context = battle.context
	# 装备手牌加武器 weapon_001_光束军刀（might=12 → 12/5=2 → bonus=6）
	var weapon_cid := _add_weapon_to_equipment_hand(battle, "weapon_001_光束军刀", &"player")
	if weapon_cid == &"":
		return "装备手牌加武器失败"
	# 触发按钮 → CHOOSE_MANY_CARDS 挂起
	var ef = await _fire_pilot_021_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹武器多选窗）"
	# 选武器确认
	await _resume_select_weapon(battle, ef, [weapon_cid])
	# 验证：武器已从装备手牌移除并弃置
	if player.equipment_hand.has(weapon_cid):
		return "弃甲铸威后武器仍应在装备手牌"
	var wcard = gs.get_card(weapon_cid)
	if wcard == null or String(wcard.zone) != "discard":
		return "弃甲铸威后武器应入弃牌堆 zone=%s" % str(wcard.zone if wcard else "?")
	# 验证：PILOT_022_POWER_BONUS 状态 stacks=6
	var st = _find_p022_bonus(gs, mech.mech_id)
	if st.is_empty():
		return "应留下 PILOT_022_POWER_BONUS 状态"
	if int(st.get("stacks", 0)) != 6:
		return "加成 stacks 应6（威力12/5=2 *3）实=%d" % int(st.get("stacks", 0))
	if int(st.get("duration", 0)) != 1:
		return "加成 duration 应1"
	return true


## 测试4：e01 取消 → 不弃牌/不加成/once_per_turn 未消耗
func test_pilot_021_e01_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var player = gs.players.get(&"player")
	battle.context.action_ui_bridge.context = battle.context
	var weapon_cid := _add_weapon_to_equipment_hand(battle, "weapon_001_光束军刀", &"player")
	var ef = await _fire_pilot_021_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_cancel(battle, ef)
	# 不弃牌
	if not player.equipment_hand.has(weapon_cid):
		return "取消后武器应仍在装备手牌"
	# 不加成状态
	if not _find_p022_bonus(gs, mech.mech_id).is_empty():
		return "取消后不应留加成状态"
	# once_per_turn 未消耗：再次触发应仍挂起
	var ef2 = await _fire_pilot_021_effect1(battle, s.card, mech, &"player")
	if ef2 == null:
		return "取消后 once_per_turn 未消耗，第2次触发应仍挂起"
	return true


## 测试5：e01 无武器装备牌 → OWNER_HAS_WEAPON_EQUIPMENT_CARD 条件失败，按钮不弹窗
func test_pilot_021_e01_no_weapon_button_disabled() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	# player 无装备手牌武器 + 机甲无已设置 WEAPON（默认空槽基础武器为 frame_base_weapon，非实体牌）
	var ef = await _fire_pilot_021_effect1(battle, s.card, mech, &"player")
	if ef != null:
		return "无武器装备牌时按钮不应弹窗（effect_fire 不应挂起）"
	if not _find_p022_bonus(gs, mech.mech_id).is_empty():
		return "无武器时不应加成"
	return true


## 测试6：加成在下次攻击 ATTACK_PRE 注入 extra_might 后移除（用完即清）
func test_pilot_021_e01_bonus_applies_then_clears() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 施加加成（武器威力12 → bonus 6）
	var weapon_cid := _add_weapon_to_equipment_hand(battle, "weapon_001_光束军刀", &"player")
	var ef = await _fire_pilot_021_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_select_weapon(battle, ef, [weapon_cid])
	var st = _find_p022_bonus(gs, mech.mech_id)
	if st.is_empty() or int(st.get("stacks", 0)) != 6:
		return "前置错误：应已施加 stacks=6"
	# 预标记 effect_02 已用，隔离火力爆发弹窗干扰
	s.card.counters["pilot_021_effect_02_used"] = true
	# 我方攻击 ATTACK_PRE → 加成监听器注入 extra_might +=6 并移除状态
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", &"frame_base_weapon_1")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(5)
	if attack.state == &"waiting_timing" or attack.state == &"waiting_effect_action":
		return "加成注入不应挂起攻击，state=%s" % String(attack.state)
	if int(attack.record.get("extra_might", 0)) != 6:
		return "加成应注入 extra_might=6 实=%d" % int(attack.record.get("extra_might", 0))
	# 用完即清：状态已移除
	if not _find_p022_bonus(gs, mech.mech_id).is_empty():
		return "加成注入后状态应移除（用完即清）"
	return true


## 测试7：加成回合结束（TURN_AFTER_END）兜底清除
func test_pilot_021_e01_bonus_cleared_on_turn_end() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	var weapon_cid := _add_weapon_to_equipment_hand(battle, "weapon_001_光束军刀", &"player")
	var ef = await _fire_pilot_021_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	await _resume_select_weapon(battle, ef, [weapon_cid])
	if _find_p022_bonus(gs, mech.mech_id).is_empty():
		return "前置错误：应已施加加成"
	# 结束回合（player 的 TURN_AFTER_END）→ DECREMENT_STATUS_DURATION 清除
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p022_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": &"player"}
	turn_action.state = &"running"
	turn_action.context = battle.context
	battle.context.action_registry.register(turn_action)
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_AFTER_END, turn_action)
	await _pump_frames(5)
	if not _find_p022_bonus(gs, mech.mech_id).is_empty():
		return "回合结束应清除加成状态（回合结束失效）"
	return true


# ═══════════════════════════════════════════
# effect_02 行为
# ═══════════════════════════════════════════

## 测试8：e02 确认发动 → 威力×1.5(基础武器10→delta5) + 范围+3 + 目标锁定 + 本局标记
func test_pilot_021_e02_fire_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 我方攻击（基础武器1 原本威力10）
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", &"frame_base_weapon_1")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# e02 optional CHOOSE_ONE 应挂起
	if attack.state != &"waiting_timing":
		return "e02 应在 ATTACK_PRE 挂起 CHOOSE_ONE，state=%s" % String(attack.state)
	# 确认发动
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	# 威力：原本10 → 1.5倍=15 → delta=5 累加 extra_might
	if int(attack.record.get("extra_might", 0)) != 5:
		return "extra_might 应5（10/2）实=%d" % int(attack.record.get("extra_might", 0))
	# 范围+3
	if int(attack.record.get("extra_range", 0)) != 3:
		return "extra_range 应3 实=%d" % int(attack.record.get("extra_range", 0))
	# 目标锁定（预判式 duration 1）
	if _count_locked(gs, enemy_mech.mech_id) != 1:
		return "目标应被施加1个 LOCKED"
	# 本局标记
	if not bool(s.card.counters.get("pilot_021_effect_02_used", false)):
		return "应写 counters[pilot_021_effect_02_used]=true"
	return true


## 测试9：e02 取消发动 → 无威力/范围/锁定/标记
func test_pilot_021_e02_cancel_no_effect() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", &"frame_base_weapon_1")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "e02 应挂起 CHOOSE_ONE"
	te.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(5)
	if int(attack.record.get("extra_might", 0)) != 0:
		return "取消后 extra_might 应0"
	if int(attack.record.get("extra_range", 0)) != 0:
		return "取消后 extra_range 应0"
	if _count_locked(gs, enemy_mech.mech_id) != 0:
		return "取消后不应施加锁定"
	if bool(s.card.counters.get("pilot_021_effect_02_used", false)):
		return "取消后不应写本局标记"
	return true


## 测试10：e02 本局1次 -- 第2次攻击不再触发（PILOT_022_NOT_USED_THIS_GAME）
func test_pilot_021_e02_second_attack_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	# 第1次：确认发动，标记已用
	var attack1 := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", &"frame_base_weapon_1")
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack1)
	if attack1.state != &"waiting_timing":
		return "第1次应挂起 CHOOSE_ONE"
	te.resume_pending_effect(attack1.action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	if not bool(s.card.counters.get("pilot_021_effect_02_used", false)):
		return "前置错误：第1次应已标记"
	# 第2次攻击：e02 因本局已用而跳过（不挂起、无威力加成）
	var attack2 := _make_attack(battle, mech.mech_id, enemy_mech.mech_id, &"player", &"frame_base_weapon_1")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack2)
	if attack2.state == &"waiting_timing":
		return "第2次攻击 e02 应因本局已用而跳过（不挂起）"
	if int(attack2.record.get("extra_might", 0)) != 0:
		return "第2次攻击不应有威力加成"
	if int(attack2.record.get("extra_range", 0)) != 0:
		return "第2次攻击不应有范围加成"
	return true


## 测试11：e02 对多目标攻击 → 所有目标都被锁定
func test_pilot_021_e02_multi_target_lock_all() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_021(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 第2台敌方机甲（双连多目标场景）
	var _MechState = preload("res://scripts/runtime/MechState.gd")
	var _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
	var enemy2 := _MechState.new()
	enemy2.mech_id = &"enemy2_mech_p022"
	enemy2.owner_player_id = &"enemy"
	enemy2.max_hp = 25
	enemy2.current_hp = 25
	enemy2.max_power = 10
	enemy2.power = 10
	enemy2.position = {"q": 2, "r": 3}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s2 := _MechSlotState.new()
		s2.slot_id = slot_id
		s2.slot_kind = &"PART"
		enemy2.slots[slot_id] = s2
	gs.mechs[enemy2.mech_id] = enemy2
	battle.context.action_ui_bridge.context = battle.context
	# 多目标攻击（target_ids 两目标）
	var attack := _Action.new()
	attack.action_id = &"test_p022_multi_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": mech.mech_id, "target_ids": [enemy_mech.mech_id, enemy2.mech_id], "weapon_id": &"frame_base_weapon_1"}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": mech.mech_id, "player_id": &"player"}
	battle.context.action_registry.register(attack)
	var te = battle.context.timing_engine
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if attack.state != &"waiting_timing":
		return "e02 应挂起 CHOOSE_ONE（多目标）"
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(8)
	if _count_locked(gs, enemy_mech.mech_id) != 1:
		return "目标1应被锁定"
	if _count_locked(gs, enemy2.mech_id) != 1:
		return "目标2应被锁定"
	return true
