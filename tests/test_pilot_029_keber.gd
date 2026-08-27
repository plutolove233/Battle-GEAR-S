## test_pilot_029_keber.gd - 克劳德（pilot_029，联邦 R，cost 6, attack_limit 1, action_card_limit 4）效果测试
##
## 克劳德 2 按钮：
##   effect_01（按钮1 置灰+悬停，被动）「远程武器范围+1」：本机甲使用远程武器攻击时攻击范围+1。
##     通用机制 passive_weapon_range_bonus（def 字段，仿 REPAIR_BOOST）：实时重算于
##     GeneratedEquipmentEffects.get_passive_weapon_range_bonus（读 pilot 槽机师牌 def 字段），
##     不注册 listener（is_pilot_derived_effect 跳过），换机师/禁用即时失效。
##   effect_02（按钮2 主动 DIRECT，每回合1次）「当作聚能」：我方回合1次，选1张行动牌当作聚能使用。
##     流程（选行动牌在前）：optional 弃牌窗选1张行动牌（可取消不计次数）→ cost 移入临时区 →
##     EXECUTE_EFFECT_FIRE 执行标准聚能（energy_direct，GameSetupService 随克劳德注册为永久监听器，
##     不渲染第3按钮）→ CHOOSE_OWN_WEAPON 选武器施加聚能 → DISCARD_TEMP_ZONE_CARDS 临时区行动牌入弃牌堆。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90029
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


## 设克劳德为 owner_id 机甲的机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_029(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_029_克劳德", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 给 owner_id 玩家行动手牌加一张行动牌（从 action_deck 找或直接构造），返回实例 id
func _add_action_card(battle, owner_id: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player = gs.players.get(owner_id)
	# 先在 action_deck 找同名牌
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c != null and c.def != null and String(c.def.card_id) == def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = owner_id
			return cid
	# 找不到则构造新实例
	var card = _make_instance(gs, cdb, def_id, owner_id)
	if card == null:
		return &""
	card.zone = &"action_hand"
	player.action_hand.append(card.instance_id)
	return card.instance_id


## 克劳德 effect_02 的 binding_context（供 can_trigger_active_effect 使用）
func _pilot_029_bind_ctx(pilot_card, mech, pid: StringName) -> Dictionary:
	return {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": pid,
		"slot_id": &"pilot",
		"card_def_id": pilot_card.def.card_id,
	}


## 在 _pending_effect 中找 effect_id 匹配的挂起效果 action id；无返回 &""。
func _find_pending_effect_action(battle, effect_id: StringName) -> StringName:
	var pending: Dictionary = battle.context.timing_engine._pending_effect
	for aid: StringName in pending:
		var e = pending[aid].get("effect")
		if e != null and e.effect_id == effect_id:
			return aid
	return &""


## 触发克劳德 effect_02（DIRECT 按钮）：fire effect_fire，返回 waiting_timing 的 effect_fire 动作。
func _fire_pilot_029_effect2(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_029_effect_02",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_029_effect_02",
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


## 检查机甲 statuses 中是否对指定武器有 ENERGY_CHARGE，返回 stacks（无则 -1）。
func _energy_stacks_on(mech, weapon_id: StringName) -> int:
	for st in mech.statuses:
		if st.get("type", &"") == &"ENERGY_CHARGE" and String(st.get("weapon_id", &"")) == String(weapon_id):
			return int(st.get("stacks", 0))
	return -1


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：2 效果定义（e1=派生占位 LISTEN；e2=DIRECT once_per_turn + 三条件 + 迪恩式转化链复用标准聚能）
func test_pilot_029_effect_definitions() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_029_effect_01")
	if e1 == null:
		return "缺 pilot_029_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN（派生占位）实=%s" % String(e1.mode)
	if not _ActionPilotEffects.is_pilot_derived_effect(&"pilot_029_effect_01"):
		return "effect_01 应在 is_pilot_derived_effect（不注册 listener 实时重算）"
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_029_effect_02")
	if e2 == null:
		return "缺 pilot_029_effect_02"
	if e2.mode != _TimingConst.MODE_DIRECT:
		return "effect_02 mode 应 MODE_DIRECT 实=%s" % String(e2.mode)
	if e2.once_per_turn_key != &"pilot_029_effect_02":
		return "once_per_turn_key 应 pilot_029_effect_02"
	var ops: Array = []
	for c in e2.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND", "OWNER_MECH_HAS_CHARGEABLE_WEAPON"]:
		if not ops.has(need):
			return "effect_02 应含条件 %s" % need
	# cost：optional 弃1张行动牌移临时区（迪恩式）
	var costs: Array = e2.costs
	if costs.size() != 1:
		return "effect_02 应1个 cost"
	var c0: Dictionary = costs[0]
	if c0.get("cost_type", &"") != &"DISCARD_ACTION_CARD" or int(c0.get("count", 0)) != 1:
		return "cost 应 DISCARD_ACTION_CARD count=1"
	if not bool(c0.get("optional", false)):
		return "cost optional 应 true（可取消不计次数）"
	if not bool(c0.get("params", {}).get("to_temp_zone", false)):
		return "cost to_temp_zone 应 true（迪恩式移临时区）"
	# actions：EXECUTE_EFFECT_FIRE energy_direct + DISCARD_TEMP_ZONE_CARDS
	var acts: Array = e2.actions
	if acts.size() != 2:
		return "effect_02 actions 应2个"
	if String(acts[0].get("type", &"")) != "EXECUTE_EFFECT_FIRE":
		return "actions[0] 应 EXECUTE_EFFECT_FIRE"
	if acts[0].get("params", {}).get("effect_id", &"") != &"energy_direct":
		return "EXECUTE_EFFECT_FIRE 应指向标准 energy_direct 实=%s" % String(acts[0].get("params", {}).get("effect_id", &""))
	if String(acts[1].get("type", &"")) != "DISCARD_TEMP_ZONE_CARDS":
		return "actions[1] 应 DISCARD_TEMP_ZONE_CARDS"
	# 隐藏效果应已删除（完全复用标准聚能）
	if _ActionPilotEffects.build_pilot_effects().has(&"pilot_029_energy_exec"):
		return "隐藏效果 pilot_029_energy_exec 应已删除"
	return true


## 测试2：data 层 - 克劳德 def 带 passive_weapon_range_bonus=1（两份 JSON 一致）
func test_pilot_029_data_field() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var cdb = battle.context.card_database
	var pdef = cdb.get_card(&"pilot_029_克劳德")
	if pdef == null:
		return "缺 pilot_029_克劳德 def"
	if int(pdef.passive_weapon_range_bonus) != 1:
		return "克劳德 passive_weapon_range_bonus 应1 实=%s" % str(pdef.passive_weapon_range_bonus)
	return true


## 测试3：效果1 被动范围+1 - 通用 helper 读 pilot 槽机师牌 def 字段；换人/禁用/非远程即时失效
func test_pilot_029_passive_range_bonus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_029(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_029_克劳德）"
	var mech = s.mech
	if _ActionPilotEffects.get_pilot_passive_weapon_range_bonus(mech) != 1:
		return "get_pilot_passive_weapon_range_bonus 应1"
	if _GenEquipEffects.get_passive_weapon_range_bonus(mech, "远程") != 1:
		return "远程武器范围+1 应生效"
	if _GenEquipEffects.get_passive_weapon_range_bonus(mech, "近战") != 0:
		return "近战武器不应加范围"
	# 禁用机师牌 → 失效
	var pilot_slot = mech.slots.get(&"pilot")
	pilot_slot.equipped_card.disabled = true
	if _ActionPilotEffects.get_pilot_passive_weapon_range_bonus(mech) != 0:
		return "禁用机师牌应失效"
	pilot_slot.equipped_card.disabled = false
	# 无机师牌 → 0
	pilot_slot.equipped_card = null
	if _ActionPilotEffects.get_pilot_passive_weapon_range_bonus(mech) != 0:
		return "无机师牌应0"
	return true


## 测试4：effect_02 全流程 - 选行动牌(移temp区) → 标准聚能选武器(施加ENERGY_CHARGE) → 行动牌入弃牌堆 + 每回合1次消耗
func test_pilot_029_effect2_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	battle.context.action_ui_bridge.context = battle.context
	var s = _setup_pilot_029(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var transform_card := _add_action_card(battle, &"player", "action_001_进攻")
	if transform_card == &"":
		return "补行动牌失败"
	var ef = await _fire_pilot_029_effect2(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹行动牌单选窗）"
	var te = battle.context.timing_engine
	# ① optional 弃牌窗（选1张行动牌当作聚能）
	var aid := _find_pending_effect_action(battle, &"pilot_029_effect_02")
	if aid == &"":
		return "应挂起可选弃牌窗（pilot_029_effect_02）"
	te.resume_pending_effect(aid, {"selected_action_card_ids": [transform_card]})
	await _pump_frames(5)
	# ② 标准聚能选武器窗（energy_direct 子动作）
	var wid_aid := _find_pending_effect_action(battle, &"energy_direct")
	if wid_aid == &"":
		return "应挂起聚能选武器窗（energy_direct）"
	var weapon_ids: Array = mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "机甲无可用武器"
	te.resume_pending_effect(wid_aid, {"selected_weapon_id": weapon_ids[0]})
	await _pump_frames(6)
	# ③ 聚能状态施加到所选武器（stacks=1）
	if _energy_stacks_on(mech, weapon_ids[0]) != 1:
		return "应施加 ENERGY_CHARGE stacks=1 到武器 %s" % String(weapon_ids[0])
	# ④ 当作聚能的行动牌 → temp_zone → 弃牌堆
	var tc = gs.get_card(transform_card)
	if tc == null or String(tc.zone) != "discard":
		return "当作聚能的行动牌应进弃牌堆 zone=%s" % (String(tc.zone) if tc != null else "?")
	# ⑤ 每回合1次已消耗
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_029_effect_02")
	var bind_ctx := _pilot_029_bind_ctx(s.card, mech, &"player")
	if te.can_trigger_active_effect(e2, bind_ctx):
		return "使用后每回合1次应已消耗（can_trigger 应 false）"
	return true


## 测试5：effect_02 取消 - 不弃牌、不施加聚能、每回合1次不消耗
func test_pilot_029_effect2_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	battle.context.action_ui_bridge.context = battle.context
	var s = _setup_pilot_029(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var player = gs.players.get(&"player")
	var transform_card := _add_action_card(battle, &"player", "action_001_进攻")
	if transform_card == &"":
		return "补行动牌失败"
	var ef = await _fire_pilot_029_effect2(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	var aid := _find_pending_effect_action(battle, &"pilot_029_effect_02")
	if aid == &"":
		return "应挂起可选弃牌窗"
	battle.context.timing_engine.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(5)
	# 取消 → 行动牌仍在手牌
	if not player.action_hand.has(transform_card):
		return "取消后行动牌应仍在手牌"
	# 无聚能施加
	if not mech.statuses.is_empty():
		for st in mech.statuses:
			if st.get("type", &"") == &"ENERGY_CHARGE":
				return "取消后不应有聚能状态"
	# 每回合1次不消耗
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_029_effect_02")
	var bind_ctx := _pilot_029_bind_ctx(s.card, mech, &"player")
	if not battle.context.timing_engine.can_trigger_active_effect(e2, bind_ctx):
		return "取消后每回合1次不应消耗（can_trigger 应 true）"
	return true


## 测试6：标准聚能 energy_direct 注册 - 随克劳德注册为永久监听器（含真实 mech/player binding）
func test_pilot_029_energy_direct_registered() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var te = battle.context.timing_engine
	# 未设机师时无 energy_direct 注册
	if te.permanent_listeners.has(&"energy_direct"):
		return "未设克劳德时不应有 energy_direct 监听器"
	var s = _setup_pilot_029(battle, &"player")
	if s == null:
		return "setup 失败"
	if not te.permanent_listeners.has(&"energy_direct"):
		return "设克劳德后 energy_direct 应注册为永久监听器"
	var found := false
	var bind_mech: StringName = &""
	for entry: Dictionary in te.permanent_listeners[&"energy_direct"]:
		var effect = entry.get("effect")
		if effect != null and String(effect.effect_id) == "energy_direct":
			found = true
			bind_mech = entry.get("binding_context", {}).get("mech_id", &"")
			break
	if not found:
		return "energy_direct listener 未找到"
	if bind_mech != s.mech.mech_id:
		return "energy_direct binding.mech_id 应为克劳德机甲 %s 实=%s" % [String(s.mech.mech_id), String(bind_mech)]
	return true
