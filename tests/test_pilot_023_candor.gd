## test_pilot_023_candor.gd - 坎得（pilot_023，秩序 SR）效果测试
##
## 坎得 2 按钮：
##   effect_01（主动 DIRECT 按钮1，每我方回合2次）「当作维修」：将1张行动牌当作维修使用。
##     复用维修机械臂 effect_130 模式：列出持有者全部行动牌选1（CHOOSE_MANY_CARDS
##     OWNER_ACTION_HAND），选中牌 EXECUTE_USE_ACTION_CARD virtual_transform 当作维修打出
##     （不耗攻击次数/不受类型限制）。按钮条件：主阶段 + 手牌≥1行动牌 + 场上有维修目标
##     （REPAIR_HAS_VALID_TARGET，目标范围读 repair_boost，坎得 range=4）。
##   effect_02（LISTEN 按钮2 置灰+悬停，不注册 listener）「维修增强」：我方使用的维修
##     获得增强——由通用机制 REPAIR_BOOST（def.repair_boost 字段）实现：
##       · 维修目标范围变 4 格（TargetChecker/ConditionChecker/app_root 读 range=4）；
##       · 维修额外移去2损伤：选"移除损伤"时合并（2+2=移除4）；选"回复生命"时先回复，
##         之后额外移除2（带 TARGET_HAS_DAMAGE 条件，无损伤不生效，不弹空移除框）。
##     该机制对所有维修来源生效（维修牌/效果1转化/维修机械臂），测试验证维修牌+效果1。
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
	battle.rng_seed = 90023
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


## 设坎得为 owner_id 机甲的机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_023(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_023_坎得", owner_id)
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


## 机甲满血 + 清空所有区域/装备牌损伤（范围隔离：只让远处目标非满状态）
func _set_mech_full(mech) -> void:
	mech.current_hp = mech.max_hp
	if mech.slots == null:
		return
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot == null:
			continue
		slot.region_damage_tokens = 0
		if slot.equipped_card != null:
			slot.equipped_card.damage_tokens = 0


## 给机甲某已装备槽设 N 损伤，返回 slot_id
func _set_damage_on_slot(mech, amount: int) -> StringName:
	if mech.slots == null:
		return &""
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null and slot.equipped_card != null:
			slot.region_damage_tokens = amount
			return sid
	# 兜底：任意槽
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null:
			slot.region_damage_tokens = amount
			return sid
	return &""


## 统计机甲某槽的损伤
func _slot_damage(mech, slot_id: StringName) -> int:
	if mech.slots == null or not mech.slots.has(slot_id):
		return 0
	return int(mech.slots[slot_id].region_damage_tokens)


## 触发坎得 effect_01（DIRECT 按钮），返回挂起的 effect_fire action（或 null）
func _fire_pilot_023_effect1(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_023_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_023_effect_01",
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


## 效果1 CHOOSE_MANY_CARDS 选行动牌确认
func _resume_select_action_card(battle, ef_action, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef_action.action_id, {"selected_card_ids": selected})
	await _pump_frames(8)


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：effect_01 定义（MODE_DIRECT, once_per_turn_max=2, 三条件, 转化行动牌当作维修）
func test_pilot_023_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_023_effect_01")
	if e == null:
		return "缺 pilot_023_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e.mode)
	if e.once_per_turn_key != &"pilot_023_effect_01":
		return "once_per_turn_key 应 pilot_023_effect_01"
	if int(e.once_per_turn_max) != 2:
		return "once_per_turn_max 应 2（我方回合2次）"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND", "REPAIR_HAS_VALID_TARGET"]:
		if not ops.has(need):
			return "应含条件 %s" % need
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "actions 应 [CHOOSE_MANY_CARDS]"
	var cm = acts[0].get("params", {})
	if cm.get("source", &"") != &"OWNER_ACTION_HAND":
		return "CHOOSE_MANY_CARDS source 应 OWNER_ACTION_HAND"
	if int(cm.get("min_count", 0)) != 1 or int(cm.get("max_count", 0)) != 1:
		return "CHOOSE_MANY_CARDS min/max 应1"
	if bool(cm.get("discard_selected", true)):
		return "discard_selected 应 false（原牌由 use_action_card 结算弃置）"
	var pca: Array = cm.get("per_card_actions", [])
	if pca.size() != 1 or String(pca[0].get("type", &"")) != "EXECUTE_USE_ACTION_CARD":
		return "per_card_actions 应 [EXECUTE_USE_ACTION_CARD]"
	var ua = pca[0].get("params", {})
	if ua.get("as_card_def_id", &"") != &"action_013_维修":
		return "应转化当作 action_013_维修"
	if not bool(ua.get("virtual_transform", false)):
		return "virtual_transform 应 true"
	if not bool(ua.get("consume_original_card", false)):
		return "consume_original_card 应 true"
	return true


## 测试2：effect_02 定义（MODE_LISTEN 被动按钮2）
func test_pilot_023_effect_02_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_023_effect_02")
	if e == null:
		return "缺 pilot_023_effect_02"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN（按钮2置灰）实=%s" % String(e.mode)
	return true


# ═══════════════════════════════════════════
# REPAIR_BOOST 通用机制
# ═══════════════════════════════════════════

## 测试3：repair_boost 数据 + helper（set_pilot 坎得 → extra_removal 2 / range 4；无机师 → 空）
func test_pilot_023_repair_boost_helper() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	# 未设坎得 → 空 boost / range 1
	if not _ActionPilotEffects.get_repair_boost(gs, &"player_mech").is_empty():
		return "无机师时 get_repair_boost 应空"
	if _ActionPilotEffects.get_repair_range(gs, &"player_mech") != 1:
		return "无机师时 get_repair_range 应1"
	# 设坎得
	var s = _setup_pilot_023(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_023_坎得）"
	var boost: Dictionary = _ActionPilotEffects.get_repair_boost(gs, s.mech.mech_id)
	if int(boost.get("extra_removal", 0)) != 2:
		return "extra_removal 应2"
	if int(boost.get("range", 1)) != 4:
		return "range 应4"
	if _ActionPilotEffects.get_repair_range(gs, s.mech.mech_id) != 4:
		return "get_repair_range 应4"
	# JSON 数据加载到 CardDef
	var pdef = s.card.def
	if pdef == null or not "repair_boost" in pdef:
		return "PilotCardDef 应含 repair_boost 字段"
	var pbo = pdef.repair_boost
	if int(pbo.get("extra_removal", 0)) != 2 or int(pbo.get("range", 1)) != 4:
		return "repair_boost 数据应 {extra_removal:2, range:4}"
	return true


## 测试4：坎得在场时维修目标范围扩到4格（REPAIR_HAS_VALID_TARGET + can_trigger_active_effect）
## 玩家自身满血无损伤（隔离自身），远处敌机（4格内/外）为唯一维修目标。
func test_pilot_023_repair_target_range_4() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_023(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	# 玩家自身满血无损伤（隔离自身，避免自身恒为目标）
	_set_mech_full(mech)
	battle.context.action_ui_bridge.context = battle.context
	# 补1张行动牌（HAS_ACTION_CARD_IN_HAND 条件）
	var card := _add_action_card(battle, &"player", "action_001_进攻")
	if card == &"":
		return "补行动牌失败"
	# 找 effect_01 permanent listener（bind_ctx）
	var te = battle.context.timing_engine
	var eff_01 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_023_effect_01")
	var bind_ctx: Dictionary = {}
	var found: bool = false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			if entry is Dictionary and entry.get("effect") != null and String(entry.effect.effect_id) == "pilot_023_effect_01":
				bind_ctx = entry.get("binding_context", {})
				found = true
				break
		if found:
			break
	if not found:
		return "effect_01 应已注册 permanent listener（pilot_023_effect_01 虚拟时点）"
	# 敌机移到4格（玩家 (2,2) → 敌 (6,2)，hex 距离 4）+ 掉血
	enemy_mech.position = {"q": 6, "r": 2}
	enemy_mech.current_hp = max(1, enemy_mech.current_hp - 3)
	if not te.can_trigger_active_effect(eff_01, bind_ctx):
		return "4格目标应视为有效维修目标（坎得 range=4）"
	# 敌机移到5格 → 超出范围 → 条件失败（按钮置灰）
	enemy_mech.position = {"q": 7, "r": 2}
	if te.can_trigger_active_effect(eff_01, bind_ctx):
		return "5格目标不应视为有效（坎得 range=4 上限）"
	return true


# ═══════════════════════════════════════════
# 效果1 行为（当作维修）
# ═══════════════════════════════════════════

## 测试5：效果1全流程 - 满血有损伤4 → 自动选"移除损伤"合并移除4（2+2）
func test_pilot_023_effect1_transform_remove4() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_023(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var player = gs.players.get(&"player")
	battle.context.action_ui_bridge.context = battle.context
	_set_mech_full(mech)  # 满血（隔离回复分支）
	var dmg_slot := _set_damage_on_slot(mech, 4)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var transform_card := _add_action_card(battle, &"player", "action_001_进攻")
	if transform_card == &"":
		return "补行动牌失败"
	# 触发 → CHOOSE_MANY_CARDS 挂起
	var ef = await _fire_pilot_023_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹行动牌多选窗）"
	var bridge = battle.context.action_ui_bridge
	var w0: Dictionary = bridge.get_waiting_action_info()
	if String(w0.get("input_type", &"")) != "select_thrust_cards":
		return "应弹 select_thrust_cards，实际 %s" % String(w0.get("input_type", &""))
	# 选行动牌 → use_action_card 挂起维修目标选择
	await _resume_select_action_card(battle, ef, [transform_card])
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_repair_target":
		return "应弹 select_repair_target，实际 %s" % String(w1.get("input_type", &""))
	# 选自身 → 满血有损伤 → CHOOSE_ONE 自动选"移除损伤"（boost 合并 value=4）→ place_damage_tokens
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "place_damage_tokens":
		return "满血有损伤应自动选移除并挂起 place_damage_tokens，实际 %s" % String(w2.get("input_type", &""))
	# 移除4个损伤
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 4})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(6)
	if _slot_damage(mech, dmg_slot) != 0:
		return "移除4损伤未生效（boost 合并2+2=4），剩余 %d" % _slot_damage(mech, dmg_slot)
	# 转化素材牌应被当作维修消耗（zone=discard）
	var tc = gs.get_card(transform_card)
	if tc == null or String(tc.zone) != "discard":
		return "转化素材牌应进弃牌堆，zone=%s" % (String(tc.zone) if tc != null else "?")
	return true


## 测试6：效果1全流程 - HP不满+有损伤2 → 弹二选一选"回复生命" → HP+4 且额外移除2
func test_pilot_023_effect1_heal_then_extra_remove() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_023(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var player = gs.players.get(&"player")
	battle.context.action_ui_bridge.context = battle.context
	# HP 不满 + 有损伤2
	var hp_before: int = mech.current_hp
	mech.current_hp = max(1, mech.current_hp - 5)
	var hp_target: int = mech.current_hp
	var dmg_slot := _set_damage_on_slot(mech, 2)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var transform_card := _add_action_card(battle, &"player", "action_001_进攻")
	if transform_card == &"":
		return "补行动牌失败"
	var ef = await _fire_pilot_023_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	var bridge = battle.context.action_ui_bridge
	await _resume_select_action_card(battle, ef, [transform_card])
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_repair_target":
		return "应弹 select_repair_target，实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	# HP 不满 + 有损伤 → 两选项均可用 → 弹二选一
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "choose_one_effect":
		return "应弹 choose_one_effect，实际 %s" % String(w2.get("input_type", &""))
	bridge.on_ui_confirmed({"chosen_option_index": 0, "chosen_effect_id": "option_0"})
	await _pump_frames(4)
	# 回复4 → 之后额外移除2（带 TARGET_HAS_DAMAGE 条件，有损伤 → 执行）→ place_damage_tokens
	var w3: Dictionary = bridge.get_waiting_action_info()
	if String(w3.get("input_type", &"")) != "place_damage_tokens":
		return "回复后应额外移除2并挂起 place_damage_tokens，实际 %s" % String(w3.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(6)
	if mech.current_hp != hp_target + 4:
		return "回复4生命未生效：期望 %d，实际 %d" % [hp_target + 4, mech.current_hp]
	if _slot_damage(mech, dmg_slot) != 0:
		return "额外移除2未生效，剩余 %d" % _slot_damage(mech, dmg_slot)
	return true


## 测试7：效果1全流程 - HP不满+无损伤 → 只"回复生命"可用 → 自动回复，无损伤不弹空移除框
func test_pilot_023_effect1_heal_no_damage_no_empty_removal() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_023(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	var hp_before: int = mech.current_hp
	mech.current_hp = max(1, mech.current_hp - 5)
	var hp_target: int = mech.current_hp
	_set_mech_full(mech)  # 无损伤（但满血会覆盖掉血！）
	# 上面 _set_mech_full 会回满 HP，改为只清损伤不清 HP
	mech.current_hp = hp_target
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null:
			slot.region_damage_tokens = 0
			if slot.equipped_card != null:
				slot.equipped_card.damage_tokens = 0
	var transform_card := _add_action_card(battle, &"player", "action_001_进攻")
	if transform_card == &"":
		return "补行动牌失败"
	var ef = await _fire_pilot_023_effect1(battle, s.card, mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	var bridge = battle.context.action_ui_bridge
	await _resume_select_action_card(battle, ef, [transform_card])
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_repair_target":
		return "应弹 select_repair_target，实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	# 无损伤 → 只有回复可用 → 自动选回复 → 回复后额外移除因无损伤被跳过（不弹空移除框）
	var w2: Dictionary = bridge.get_waiting_action_info()
	if not w2.is_empty():
		return "无损伤应自动选回复并直接完成（不应挂起 %s）" % String(w2.get("input_type", &""))
	if mech.current_hp != hp_target + 4:
		return "回复4生命未生效：期望 %d，实际 %d" % [hp_target + 4, mech.current_hp]
	return true


## 测试8：效果1每回合2次 - 第1次移除、第2次回复、第3次触发被 once_per_turn_max=2 拦截
func test_pilot_023_effect1_twice_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_023(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	# HP 不满 + 有损伤4（第1次选移除，第2次选回复）
	mech.current_hp = max(1, mech.current_hp - 5)
	var dmg_slot := _set_damage_on_slot(mech, 4)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	# 3张行动牌（2次消耗 + 第3次触发仍需满足 HAS_ACTION_CARD 条件）
	var tc1 := _add_action_card(battle, &"player", "action_001_进攻")
	var tc2 := _add_action_card(battle, &"player", "action_001_进攻")
	var tc3 := _add_action_card(battle, &"player", "action_001_进攻")
	if tc1 == &"" or tc2 == &"" or tc3 == &"":
		return "补行动牌失败"
	# 第1次：HP 不满 + 有损伤4 → 弹二选一，显式选"移除损伤"(option_1) → 合并移除4
	var ef1 = await _fire_pilot_023_effect1(battle, s.card, mech, &"player")
	if ef1 == null:
		return "第1次 effect_fire 未挂起"
	var bridge = battle.context.action_ui_bridge
	await _resume_select_action_card(battle, ef1, [tc1])
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "choose_one_effect":
		return "第1次应弹 choose_one_effect（HP不满+有损伤），实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"chosen_option_index": 1, "chosen_effect_id": "option_1"})
	await _pump_frames(4)
	var w1b: Dictionary = bridge.get_waiting_action_info()
	if String(w1b.get("input_type", &"")) != "place_damage_tokens":
		return "第1次选移除后应挂起 place_damage_tokens，实际 %s" % String(w1b.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 4})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(6)
	if _slot_damage(mech, dmg_slot) != 0:
		return "第1次移除4未生效，剩余 %d" % _slot_damage(mech, dmg_slot)
	# 第2次：HP 仍不满 + 无损伤 → 自动选回复
	var ef2 = await _fire_pilot_023_effect1(battle, s.card, mech, &"player")
	if ef2 == null:
		return "第2次 effect_fire 未挂起（每回合2次，第2次应仍可用）"
	await _resume_select_action_card(battle, ef2, [tc2])
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(6)
	var w2: Dictionary = bridge.get_waiting_action_info()
	if not w2.is_empty():
		return "第2次应自动选回复并完成，不应挂起 %s" % String(w2.get("input_type", &""))
	# 第3次：once_per_turn 用满 → effect_fire 不挂起（按钮禁用）
	var ef3 = await _fire_pilot_023_effect1(battle, s.card, mech, &"player")
	if ef3 != null:
		return "第3次 effect_fire 应因 once_per_turn_max=2 用满而跳过（不挂起）"
	return true


# ═══════════════════════════════════════════
# REPAIR_BOOST 对全部维修来源生效（通用性）
# ═══════════════════════════════════════════

## 测试9：坎得在场时，维修牌直接使用也受 boost（移除2 → 合并移除4）
func test_pilot_023_boost_applies_to_repair_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_023(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	_set_mech_full(mech)  # 满血（只测移除分支）
	var dmg_slot := _set_damage_on_slot(mech, 5)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var repair_id := _add_action_card(battle, &"player", "action_013_维修")
	if repair_id == &"":
		return "找不到维修牌"
	var bridge = battle.context.action_ui_bridge
	battle.execute_use_action_card(&"player", repair_id)
	await _pump_frames(3)
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "select_repair_target":
		return "应挂起 select_repair_target，实际 %s" % String(w1.get("input_type", &""))
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	# 满血有损伤 → 自动选移除（boost value=4）→ place_damage_tokens
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "place_damage_tokens":
		return "维修牌应受 boost 自动移除4并挂起 place_damage_tokens，实际 %s" % String(w2.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 4})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(6)
	if _slot_damage(mech, dmg_slot) != 1:
		return "维修牌应额外移除2（合并4），剩余应为1，实际 %d" % _slot_damage(mech, dmg_slot)
	return true


## 测试10：无坎得（默认无机师）时，维修牌只移除2（无 boost）
func test_pilot_023_no_boost_without_kande() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	# 未设机师 → 无 boost
	if not _ActionPilotEffects.get_repair_boost(gs, mech.mech_id).is_empty():
		return "前置错误：未设坎得应无 repair_boost"
	_set_mech_full(mech)
	var dmg_slot := _set_damage_on_slot(mech, 3)
	if dmg_slot == &"":
		return "找不到可设损伤槽位"
	var repair_id := _add_action_card(battle, &"player", "action_013_维修")
	if repair_id == &"":
		return "找不到维修牌"
	var bridge = battle.context.action_ui_bridge
	battle.execute_use_action_card(&"player", repair_id)
	await _pump_frames(3)
	bridge.on_ui_confirmed({"target_id": mech.mech_id})
	await _pump_frames(4)
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "place_damage_tokens":
		return "应挂起 place_damage_tokens，实际 %s" % String(w2.get("input_type", &""))
	battle.context.game_actions.remove_damage_tokens({"mech_id": mech.mech_id, "slot_id": dmg_slot, "amount": 2})
	bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(6)
	if _slot_damage(mech, dmg_slot) != 1:
		return "无坎得维修应只移除2，剩余应为1，实际 %d" % _slot_damage(mech, dmg_slot)
	return true
