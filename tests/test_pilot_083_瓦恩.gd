## test_pilot_083_瓦恩.gd - 瓦恩（pilot_083，秩序 N，cost 2）效果测试
##
## 2 个效果按钮 + RE 请求：
##   effect_01（DIRECT 主动，按钮1）「武器修改」：每回合1次，将场上1把武器名称附加热能/光束、
##     类型转变近战/远程、威力+3或范围+1（三横排每行可独立多选，取消不计次数；持续到下个我方回合结束）。
##     两阶段：① 场上武器单选（choose_one_effect）→ ② 三横排选项（pilot_083_options）→ 施加。
##   effect_02（LISTEN 被动展示按钮，按钮2，置灰+悬停，不注册监听器）。
##   pilot_083_re_request（DIRECT RE 请求，hide_button，独立注册虚拟时点）：3格内机甲在其回合内
##     请求瓦恩对其武器使用武器修改（每台机甲每回合1次）。点击即消耗请求方次数（持有者拒绝也不刷新）；
##     接受请求不消耗瓦恩 effect_01 的每回合1次（独立资源）。
##   施加存武器 counters["pilot_083_apps"]：名称后缀累积去重/类型最新覆盖/威力射程叠加。
##   过期：瓦恩持有者玩家「下个我方回合结束」清 applied_turn < 当前轮；ROUND_START 清孤儿（换下/毁）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90083
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


## 设瓦恩为 owner_id 机甲机师，返回 {card, mech, gs, cdb}；失败返回 null。
func _setup_pilot_083(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_083_瓦恩", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 给某机甲武器槽装备实体武器（直接设槽，镜像 _set_equipment_legacy，不注册装备效果）。
## 返回武器卡实例；失败返回 null。
func _equip_weapon(battle, mech_id: StringName, def_id: String, slot_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.mechs.get(mech_id)
	if mech == null or mech.slots == null or not mech.slots.has(slot_id):
		return null
	var card = _make_instance(gs, cdb, def_id, mech.owner_player_id)
	if card == null:
		return null
	var slot = mech.slots[slot_id]
	if slot == null:
		return null
	slot.equipped_card = card
	card.zone = &"equipped"
	card.slot_id = slot_id
	card.mech_id = mech.mech_id
	return card


## pos 的任一相邻格（odd-q 真邻居，避免偏移坑）
func _adjacent_cell_to(pos: Dictionary) -> Dictionary:
	return _HexGrid.neighbors(pos)[0]


## 触发瓦恩 effect_01（owner 模式，按钮1），返回挂起的 effect_fire action（或 null）。
func _fire_pilot_083_owner(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_083_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.game_state.turn_number = 1
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_083_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.record.get("_waiting_for_p083_weapon_select", false):
			return a
	return null


## 触发瓦恩 RE 请求（mode=re，请求方点击 RE），返回挂起的 effect_fire action（或 null）。
func _fire_pilot_083_re(battle, holder_pilot_card, requester_mech, requester_pid: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": holder_pilot_card.instance_id,
		"mech_id": requester_mech.mech_id,
		"player_id": requester_pid,
		"effect_id": &"pilot_083_re_request",
	}
	battle.context.game_state.active_player_id = requester_pid
	battle.context.game_state.phase = &"MAIN"
	battle.context.game_state.turn_number = 1
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_083_re_request",
		"player_id": requester_pid,
		"source_mech_id": requester_mech.mech_id,
		"mech_id": requester_mech.mech_id,
		"card_instance_id": holder_pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.record.get("_waiting_for_p083_weapon_select", false):
			return a
	return null


## 设置 RE 标准场景：瓦恩(player,2,2) 为持有者；enemy 移到相邻格（3格内）+ 装备1把武器。
func _setup_re_scenario(battle):
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return null
	var gs = s.gs
	var holder_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	enemy_mech.position = _adjacent_cell_to(holder_mech.position)
	var enemy_weapon = _equip_weapon(battle, enemy_mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	if enemy_weapon == null:
		return null
	return {"holder_card": s.card, "holder_mech": holder_mech, "requester_mech": enemy_mech,
		"enemy_weapon": enemy_weapon, "gs": gs, "bridge": battle.context.action_ui_bridge}


# ═══════════════════════════════════════════
# 定义 + helpers
# ═══════════════════════════════════════════

## 测试1：effect_01/effect_02/re_request 定义
func test_pilot_083_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_083_effect_01")
	if e1 == null:
		return "缺 pilot_083_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 DIRECT（主动按钮1），实=%s" % String(e1.mode)
	if e1.display_name == "" or e1.description == "":
		return "effect_01 应有 display_name/description"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	if not e1_ops.has("IS_OWNER_MAIN_PHASE") or not e1_ops.has("HAS_FIELD_WEAPON") \
			or not e1_ops.has("EFFECT_ONCE_PER_TURN_AVAILABLE"):
		return "effect_01 应含 IS_OWNER_MAIN_PHASE/HAS_FIELD_WEAPON/EFFECT_ONCE_PER_TURN_AVAILABLE 条件"
	if e1.actions.size() != 1 or String(e1.actions[0].get("type", &"")) != "PILOT_083_MODIFY_FLOW":
		return "effect_01 actions 应 [PILOT_083_MODIFY_FLOW(mode=owner)]"
	var e2 = effects.get(&"pilot_083_effect_02")
	if e2 == null or e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 应 LISTEN（被动展示按钮）"
	if e2.listen_timing != &"":
		return "effect_02 listen_timing 应空（RE 由 equipment_panel 动态渲染，不注册监听器）"
	var re = effects.get(&"pilot_083_re_request")
	if re == null or re.mode != _TimingConst.MODE_DIRECT:
		return "pilot_083_re_request 应 DIRECT"
	if not re.hide_button:
		return "re_request 应 hide_button（RE 按钮在请求方处渲染，不建卡上按钮）"
	var re_ops: Array = []
	for c in re.conditions:
		re_ops.append(String(c.get("op", &"")))
	if not re_ops.has("PILOT_083_RE_AVAILABLE"):
		return "re_request 应含条件 PILOT_083_RE_AVAILABLE"
	var re_acts: Array = re.actions
	if re_acts.size() != 2:
		return "re_request actions 应 [PILOT_083_RE_MARK_USED, PILOT_083_MODIFY_FLOW(mode=re)]"
	if String(re_acts[0].get("type", &"")) != "PILOT_083_RE_MARK_USED" \
			or String(re_acts[1].get("type", &"")) != "PILOT_083_MODIFY_FLOW":
		return "re_request actions 类型不符"
	if String(re_acts[1].get("params", {}).get("mode", "")) != "re":
		return "re_request 第二个动作 mode 应 re"
	return true


## 测试2：helpers（find_holders/find_covering_holders/find_holder_for_pilot_instance/re_used/
## list_weapon_options/get_pilot_083_weapon_apps/apply_to_weapon/expire/has_field_weapon）
func test_pilot_083_helpers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	# 无机师+无实体武器时
	if not _ActionPilotEffects.pilot_083_find_holders(gs).is_empty():
		return "无机师时 find_holders 应空"
	if not _ActionPilotEffects.pilot_083_has_field_weapon(gs):
		return "基础武器应算场武器（含基础武器）：初始应 has_field_weapon=true"
	var opts_initial: Array = _ActionPilotEffects.pilot_083_list_weapon_options(gs, &"")
	if opts_initial.size() != 3:
		return "基础武器应出现在武器修改候选（player2+enemy1=3），实=%d" % opts_initial.size()
	if not String(opts_initial[0].get("weapon_key", "")).begins_with("base:"):
		return "初始候选应为基础武器键 base:<mech_id>:<slot>，实=%s" % String(opts_initial[0].get("weapon_key", ""))
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_083_瓦恩）"
	var holder_mech = s.mech
	var holders: Array = _ActionPilotEffects.pilot_083_find_holders(gs)
	if holders.size() != 1 or StringName(holders[0]) != holder_mech.mech_id:
		return "设瓦恩后 find_holders 应返回持有者机甲"
	# find_holder_for_pilot_instance
	var found_mid: StringName = _ActionPilotEffects.pilot_083_find_holder_for_pilot_instance(gs, s.card.instance_id)
	if found_mid != holder_mech.mech_id:
		return "find_holder_for_pilot_instance 应返回持有者机甲"
	if _ActionPilotEffects.pilot_083_find_holder_for_pilot_instance(gs, &"nonexistent") != &"":
		return "未知实例应返回空"
	# covering：持有者自身被排除（瓦恩持有者不能自己请求自己，含自身时旧 bug）
	var cov_self: Array = _ActionPilotEffects.pilot_083_find_covering_holders(gs, holder_mech.mech_id)
	if not cov_self.is_empty():
		return "持有者自身应被排除（不能自己请求自己），实=%s" % str(cov_self)
	# covering：3格内的机甲被覆盖
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 3, "r": 2}  # (2,2)->(3,2) 距离1
	var cov_enemy: Array = _ActionPilotEffects.pilot_083_find_covering_holders(gs, enemy_mech.mech_id)
	if cov_enemy.is_empty():
		return "距离1机甲应被持有者覆盖"
	# 4格外的机甲不被覆盖（地图直线距离）：(2,2)->(6,2) 距离4
	enemy_mech.position = {"q": 6, "r": 2}
	if not _ActionPilotEffects.pilot_083_find_covering_holders(gs, enemy_mech.mech_id).is_empty():
		return "距离4机甲不应被覆盖（3格范围）"
	# re_used / mark_used：计数存请求方玩家 once_per_turn_used
	if _ActionPilotEffects.pilot_083_re_used_this_turn(gs, enemy_mech.mech_id):
		return "未请求过 re_used 应 false"
	_ActionPilotEffects.pilot_083_re_mark_used(gs, enemy_mech.mech_id)
	if not _ActionPilotEffects.pilot_083_re_used_this_turn(gs, enemy_mech.mech_id):
		return "标记后 re_used 应 true"
	# 实体武器装入后 has_field_weapon / list_weapon_options 应含它
	_ActionPilotEffects.pilot_083_re_mark_used(gs, enemy_mech.mech_id)  # 幂等
	# 给 player 装备实体武器到 weapon_1
	var player_weapon = _equip_weapon(battle, holder_mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	if player_weapon == null:
		return "给 player 装备武器失败（缺 weapon_001_光束军刀 或 weapon_1 槽）"
	if not _ActionPilotEffects.pilot_083_has_field_weapon(gs):
		return "实体武器装备后 has_field_weapon 应 true"
	var opts_all: Array = _ActionPilotEffects.pilot_083_list_weapon_options(gs, &"")
	# player: 实体1 + 基础(weapon_2 空)1；enemy: 基础1 → 共3
	if opts_all.size() != 3:
		return "全场武器候选应3把（player 实体1+基础1，enemy 基础1），实=%d" % opts_all.size()
	var first_opt: Dictionary = opts_all[0]
	if String(first_opt.get("weapon_key", "")) != "card:%s" % String(player_weapon.instance_id):
		return "weapon_key 应为 card:<instance_id>，实=%s" % String(first_opt.get("weapon_key", ""))
	if bool(first_opt.get("is_virtual", true)):
		return "实体武器 is_virtual 应 false"
	# 请求方限定：player 实体1 + 基础(weapon_2 空)1 → 共2
	var opts_player: Array = _ActionPilotEffects.pilot_083_list_weapon_options(gs, holder_mech.mech_id)
	if opts_player.size() != 2:
		return "请求方限定候选应 player 实体1+基础1=2把，实=%d" % opts_player.size()
	# apply_to_weapon + get_pilot_083_weapon_apps 聚合
	var app1: Dictionary = {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0}
	_ActionPilotEffects.pilot_083_apply_to_weapon(player_weapon, &"player", 1, app1)
	var agg: Dictionary = _ActionPilotEffects.get_pilot_083_weapon_apps(player_weapon)
	if int(agg["might_bonus"]) != 3 or int(agg["range_bonus"]) != 0:
		return "聚合 might_bonus 应3 range_bonus 应0"
	if agg["suffixes"].size() != 1 or agg["suffixes"][0] != "热能":
		return "聚合 suffixes 应含'热能'"
	if StringName(agg["type_override"]) != &"远程":
		return "聚合 type_override 应 远程"
	# 第二次施加：光束+range1 + type 近战（最新覆盖）+ 数值叠加 + 后缀去重累积
	var app2: Dictionary = {"name_suffix": "光束", "type_override": &"近战", "might": 3, "range": 1}
	_ActionPilotEffects.pilot_083_apply_to_weapon(player_weapon, &"player", 1, app2)
	var agg2: Dictionary = _ActionPilotEffects.get_pilot_083_weapon_apps(player_weapon)
	if int(agg2["might_bonus"]) != 6 or int(agg2["range_bonus"]) != 1:
		return "二次施加后 might_bonus 应6 range_bonus 应1（叠加），实=%d/%d" % [int(agg2["might_bonus"]), int(agg2["range_bonus"])]
	if agg2["suffixes"].size() != 2:
		return "二次施加后缀应累积为2个（去重），实=%d" % agg2["suffixes"].size()
	if StringName(agg2["type_override"]) != &"近战":
		return "type_override 应取最新（近战），实=%s" % String(StringName(agg2["type_override"]))
	# 过期：applied_turn=1，turn=1 不删，turn=2 删（下个我方回合结束）
	_ActionPilotEffects.pilot_083_expire_apps_for_turn(gs, &"player", 1)
	if _ActionPilotEffects.get_pilot_083_weapon_apps(player_weapon)["suffixes"].size() != 2:
		return "同轮 TURN_AFTER_END 不应过期（applied_turn<turn 才删）"
	_ActionPilotEffects.pilot_083_expire_apps_for_turn(gs, &"player", 2)
	if not _ActionPilotEffects.get_pilot_083_weapon_apps(player_weapon)["suffixes"].is_empty():
		return "下轮 TURN_AFTER_END 应清除该玩家施加"
	return true


## 测试3：get_effective_weapon_stats 接入瓦恩修正（名称附加/类型覆盖/威力射程叠加）
func test_pilot_083_effective_stats() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var weapon = _equip_weapon(battle, s.mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	if weapon == null:
		return "装备武器失败"
	var _GEE = _ActionPilotEffects._get_gen_equip_effects()
	var base: Dictionary = _GEE.get_effective_weapon_stats(weapon)
	if int(base.get("might", 0)) != 12 or int(base.get("range_value", 0)) != 2:
		return "武器基准威力应12 射程应2，实=%d/%d" % [int(base.get("might", 0)), int(base.get("range_value", 0))]
	if String(base.get("weapon_kind", "")) != "近战":
		return "武器基准类型应近战"
	# 施加 热能+远程+might3
	_ActionPilotEffects.pilot_083_apply_to_weapon(weapon, &"player", 1, {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0})
	var after: Dictionary = _GEE.get_effective_weapon_stats(weapon)
	if int(after.get("might", 0)) != 15:
		return "威力应+3=15，实=%d" % int(after.get("might", 0))
	if int(after.get("range_value", 0)) != 2:
		return "射程不应变（未选 range），实=%d" % int(after.get("range_value", 0))
	if String(after.get("weapon_kind", "")) != "远程":
		return "类型应覆盖为远程，实=%s" % String(after.get("weapon_kind", ""))
	if String(after.get("weapon_name", "")).find("光束军刀·热能") < 0:
		return "名称应附加·热能，实=%s" % String(after.get("weapon_name", ""))
	if int(after.get("pilot_083_might_bonus", 0)) != 3:
		return "pilot_083_might_bonus 应3（诺拉还原用），实=%d" % int(after.get("pilot_083_might_bonus", 0))
	return true


# ═══════════════════════════════════════════
# 效果1（owner 主动）
# ═══════════════════════════════════════════

## 测试4：effect_01 两阶段流程——武器单选 → 三横排选项 → 施加；取消不计次数
func test_pilot_083_owner_apply() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	var weapon = _equip_weapon(battle, s.mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	if weapon == null:
		return "装备武器失败"
	var ef = await _fire_pilot_083_owner(battle, s.card, s.mech, &"player")
	if ef == null:
		return "effect_01 应挂起 phase1 武器选择（未挂起）"
	# phase1：choose_one_effect，选项=全场武器（1把），路由到持有者 player
	var w1: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "choose_one_effect":
		return "phase1 应弹 choose_one_effect，实际 %s" % String(w1.get("input_type", &""))
	var ip1: Dictionary = w1.get("input_params", {})
	if String(ip1.get("player_id", &"")) != "player":
		return "phase1 应路由到持有者 player，实际 %s" % String(ip1.get("player_id", &""))
	var opts1: Array = ip1.get("options", [])
	# player 实体1+基础1，enemy 基础1 → 共3
	if opts1.size() != 3:
		return "phase1 武器候选应3把（player 实体1+基础1+enemy 基础1），实=%d" % opts1.size()
	if String(opts1[0].get("effect_id", &"")) != "card:%s" % String(weapon.instance_id):
		return "phase1 候选 effect_id 应作 weapon_key"
	# 选中武器 → phase2 三横排选项
	var weapon_key: String = "card:%s" % String(weapon.instance_id)
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"chosen_effect_id": weapon_key})
	await _pump_frames(3)
	var w2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "pilot_083_options":
		return "phase2 应弹 pilot_083_options，实际 %s" % String(w2.get("input_type", &""))
	var ip2: Dictionary = w2.get("input_params", {})
	if String(ip2.get("player_id", &"")) != "player":
		return "phase2 应路由到持有者 player，实际 %s" % String(ip2.get("player_id", &""))
	if String(ip2.get("weapon_name", "")).find("光束军刀") < 0:
		return "phase2 应显示所选武器名，实=%s" % String(ip2.get("weapon_name", ""))
	# 确认打包状态 → 施加
	var opts: Dictionary = {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0}
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"options": opts})
	await _pump_frames(8)
	var _GEE = _ActionPilotEffects._get_gen_equip_effects()
	var st: Dictionary = _GEE.get_effective_weapon_stats(weapon)
	if int(st.get("might", 0)) != 15:
		return "施加后威力应15，实=%d" % int(st.get("might", 0))
	if String(st.get("weapon_kind", "")) != "远程":
		return "施加后类型应远程，实=%s" % String(st.get("weapon_kind", ""))
	if ef.state != &"completed":
		return "effect_01 动作应完成，实际 %s" % String(ef.state)
	# owner 模式：最终应用才标记每回合1次已用
	if battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_083_effect_01", s.card.instance_id, 1):
		return "最终应用后 effect_01 每回合1次应已用"
	return true


## 测试5：effect_01 取消——phase1 取消 / phase2 取消 均不施加、不计次数
func test_pilot_083_owner_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	var weapon = _equip_weapon(battle, s.mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	if weapon == null:
		return "装备武器失败"
	var _GEE = _ActionPilotEffects._get_gen_equip_effects()
	# ── phase1 取消 ──
	var ef1 = await _fire_pilot_083_owner(battle, s.card, s.mech, &"player")
	if ef1 == null:
		return "effect_01 第一次应挂起 phase1"
	battle.context.timing_engine.resume_pending_effect(ef1.action_id, {"cancelled": true})
	await _pump_frames(6)
	var st1: Dictionary = _GEE.get_effective_weapon_stats(weapon)
	if int(st1.get("might", 0)) != 12:
		return "phase1 取消不应施加（威力应仍12）"
	if not _ActionPilotEffects.get_pilot_083_weapon_apps(weapon)["suffixes"].is_empty():
		return "phase1 取消不应写入 apps"
	if not battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_083_effect_01", s.card.instance_id, 1):
		return "phase1 取消不应消耗每回合1次"
	if ef1.state != &"completed":
		return "取消后 effect_01 动作应完成，实际 %s" % String(ef1.state)
	# ── phase2 取消 ──
	var ef2 = await _fire_pilot_083_owner(battle, s.card, s.mech, &"player")
	if ef2 == null:
		return "第二次应仍可触发（第一次取消未消耗）"
	var w: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(w.get("input_type", &"")) != "choose_one_effect":
		return "第二次 phase1 应弹 choose_one_effect"
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"chosen_effect_id": "card:%s" % String(weapon.instance_id)})
	await _pump_frames(3)
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"cancelled": true})
	await _pump_frames(6)
	var st2: Dictionary = _GEE.get_effective_weapon_stats(weapon)
	if int(st2.get("might", 0)) != 12:
		return "phase2 取消不应施加（威力应仍12）"
	if not battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_083_effect_01", s.card.instance_id, 1):
		return "phase2 取消不应消耗每回合1次"
	return true


## 测试6：effect_01 数值叠加+名称后缀累积（同一武器多次施加）
func test_pilot_083_stacking() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	var weapon = _equip_weapon(battle, s.mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	if weapon == null:
		return "装备武器失败"
	var _GEE = _ActionPilotEffects._get_gen_equip_effects()
	# 第一次：热能+might3
	var ef1 = await _fire_pilot_083_owner(battle, s.card, s.mech, &"player")
	if ef1 == null:
		return "第一次应挂起"
	battle.context.timing_engine.resume_pending_effect(ef1.action_id, {"chosen_effect_id": "card:%s" % String(weapon.instance_id)})
	await _pump_frames(3)
	battle.context.timing_engine.resume_pending_effect(ef1.action_id, {"options": {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0}})
	await _pump_frames(8)
	# 每回合1次已用——清除以模拟下回合（TURN_START 也会清 _once_per_turn_used？实际是 TimingEngine 字典）
	# 直接清 TimingEngine._once_per_turn_used 对应键模拟下回合
	var ekey: String = "%s:pilot_083_effect_01" % String(s.card.instance_id)
	battle.context.timing_engine._once_per_turn_used.erase(ekey)
	# 第二次：光束+range1
	var ef2 = await _fire_pilot_083_owner(battle, s.card, s.mech, &"player")
	if ef2 == null:
		return "第二次应可触发（清额度后）"
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"chosen_effect_id": "card:%s" % String(weapon.instance_id)})
	await _pump_frames(3)
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"options": {"name_suffix": "光束", "type_override": &"近战", "might": 3, "range": 1}})
	await _pump_frames(8)
	var st: Dictionary = _GEE.get_effective_weapon_stats(weapon)
	if int(st.get("might", 0)) != 18:
		return "两次施加威力应叠加12+3+3=18，实=%d" % int(st.get("might", 0))
	if int(st.get("range_value", 0)) != 3:
		return "射程应叠加2+1=3，实=%d" % int(st.get("range_value", 0))
	if String(st.get("weapon_kind", "")) != "近战":
		return "类型应取最新施加（近战），实=%s" % String(st.get("weapon_kind", ""))
	if String(st.get("weapon_name", "")).find("光束军刀·热能·光束") < 0:
		return "名称后缀应累积去重·热能·光束，实=%s" % String(st.get("weapon_name", ""))
	return true


# ═══════════════════════════════════════════
# RE 请求
# ═══════════════════════════════════════════

## 测试7：RE 请求 → 持有者接受 → 施加到请求方武器；不消耗瓦恩 effect_01 次数；RE 已消耗
func test_pilot_083_re_accept() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var sc = _setup_re_scenario(battle)
	if sc == null:
		return "setup 失败"
	var gs = sc.gs
	var bridge = sc.bridge
	var req = sc.requester_mech
	var enemy_weapon = sc.enemy_weapon
	var _GEE = _ActionPilotEffects._get_gen_equip_effects()
	var re_action = await _fire_pilot_083_re(battle, sc.holder_card, req, req.owner_player_id)
	if re_action == null:
		return "RE 请求应挂起 phase1（未挂起）"
	# 点击即消耗请求方次数
	if not _ActionPilotEffects.pilot_083_re_used_this_turn(gs, req.mech_id):
		return "RE 点击后应已标记使用（点击即消耗）"
	# phase1：choose_one_effect，路由到持有者 player；选项=请求方武器（enemy 的 weapon_1）
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "choose_one_effect":
		return "RE phase1 应弹 choose_one_effect，实际 %s" % String(w1.get("input_type", &""))
	var ip1: Dictionary = w1.get("input_params", {})
	if String(ip1.get("player_id", &"")) != "player":
		return "RE phase1 应路由到持有者 player，实际 %s" % String(ip1.get("player_id", &""))
	var opts1: Array = ip1.get("options", [])
	if opts1.size() != 1:
		return "RE phase1 武器候选应只有请求方武器（1把），实=%d" % opts1.size()
	if String(opts1[0].get("mech_id", &"")) != String(req.mech_id):
		return "RE 武器候选应属于请求方机甲"
	# 接受：选武器 → 三横排确认
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"chosen_effect_id": "card:%s" % String(enemy_weapon.instance_id)})
	await _pump_frames(3)
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "pilot_083_options":
		return "RE phase2 应弹 pilot_083_options，实际 %s" % String(w2.get("input_type", &""))
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"options": {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0}})
	await _pump_frames(8)
	var st: Dictionary = _GEE.get_effective_weapon_stats(enemy_weapon)
	if int(st.get("might", 0)) != 15:
		return "RE 接受后请求方武器威力应+3=15，实=%d" % int(st.get("might", 0))
	if String(st.get("weapon_kind", "")) != "远程":
		return "RE 接受后请求方武器类型应远程，实=%s" % String(st.get("weapon_kind", ""))
	if re_action.state != &"completed":
		return "RE 动作应完成，实际 %s" % String(re_action.state)
	# 接受请求不消耗瓦恩 effect_01 每回合1次（独立资源）
	if not battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_083_effect_01", sc.holder_card.instance_id, 1):
		return "RE 接受请求不应消耗瓦恩 effect_01 每回合1次"
	return true


## 测试8：RE 请求 → 持有者拒绝 → 不施加；RE 仍已消耗；本回合不可再请求
func test_pilot_083_re_refuse_consumed() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var sc = _setup_re_scenario(battle)
	if sc == null:
		return "setup 失败"
	var gs = sc.gs
	var bridge = sc.bridge
	var req = sc.requester_mech
	var _GEE = _ActionPilotEffects._get_gen_equip_effects()
	var re_action = await _fire_pilot_083_re(battle, sc.holder_card, req, req.owner_player_id)
	if re_action == null:
		return "RE 请求应挂起 phase1"
	# 持有者拒绝（phase1 取消）
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"cancelled": true})
	await _pump_frames(6)
	if not _ActionPilotEffects.get_pilot_083_weapon_apps(sc.enemy_weapon)["suffixes"].is_empty():
		return "RE 拒绝不应施加"
	if re_action.state != &"completed":
		return "RE 拒绝后动作应完成，实际 %s" % String(re_action.state)
	if not _ActionPilotEffects.pilot_083_re_used_this_turn(gs, req.mech_id):
		return "RE 拒绝不应刷新请求方次数（点击即消耗）"
	# 再次请求条件不可用（本回合已用）
	var te = battle.context.timing_engine
	var re_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_083_re_request")
	var req_bind: Dictionary = {
		"card_instance_id": sc.holder_card.instance_id,
		"mech_id": req.mech_id,
		"player_id": req.owner_player_id,
		"slot_id": &"pilot",
		"card_def_id": &"pilot_083_瓦恩",
	}
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "RE 拒绝后本回合不应可再次请求"
	return true


## 测试9：RE 条件 PILOT_083_RE_AVAILABLE（己方回合/3格内/未用）
func test_pilot_083_re_available_condition() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var holder = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	battle.context.action_ui_bridge.context = battle.context
	_equip_weapon(battle, enemy_mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	enemy_mech.position = _adjacent_cell_to(holder.position)  # 3格内
	gs.turn_number = 1
	var te = battle.context.timing_engine
	var re_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_083_re_request")
	var req_bind: Dictionary = {
		"card_instance_id": s.card.instance_id,
		"mech_id": enemy_mech.mech_id,
		"player_id": &"enemy",
		"slot_id": &"pilot",
		"card_def_id": &"pilot_083_瓦恩",
	}
	# 己方回合 + 3格内 + 未用 -> 可用
	gs.active_player_id = &"enemy"
	gs.phase = &"MAIN"
	if not te.can_trigger_active_effect(re_eff, req_bind):
		return "己方回合+3格内+未用应可请求"
	# 非己方回合 -> 不可用
	gs.active_player_id = &"player"
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "非己方回合不应可请求"
	# 回己方回合；本回合已请求过 -> 不可用
	gs.active_player_id = &"enemy"
	_ActionPilotEffects.pilot_083_re_mark_used(gs, enemy_mech.mech_id)
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "本回合已请求过不应可请求"
	# 清标记；移出3格 -> 不可用
	gs.players.get(&"enemy").once_per_turn_used.clear()
	enemy_mech.position = {"q": 6, "r": 2}  # 距离4
	if te.can_trigger_active_effect(re_eff, req_bind):
		return "移出3格不应可请求"
	# 持有者自身请求自己 -> 不可用（瓦恩不能自己请求自己，exclude_self）
	var self_bind: Dictionary = {
		"card_instance_id": s.card.instance_id,
		"mech_id": holder.mech_id,
		"player_id": &"player",
		"slot_id": &"pilot",
		"card_def_id": &"pilot_083_瓦恩",
	}
	_equip_weapon(battle, holder.mech_id, "weapon_001_光束军刀", "weapon_1")
	if te.can_trigger_active_effect(re_eff, self_bind):
		return "持有者自身不应可自我请求（排除自身）"
	return true


# ═══════════════════════════════════════════
# 过期清理
# ═══════════════════════════════════════════

## 测试10：TURN_AFTER_END 下个我方回合结束过期 + ROUND_START 孤儿清理
func test_pilot_083_expiry() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var weapon = _equip_weapon(battle, s.mech.mech_id, "weapon_001_光束军刀", "weapon_1")
	if weapon == null:
		return "装备武器失败"
	# 本测关注过期时序：调高行动牌上限避免回合末超限弹弃牌阻塞窗（挂起会中断清理步骤）
	gs.players.get(&"player").action_card_limit = 99
	var _GEE = _ActionPilotEffects._get_gen_equip_effects()
	# 施加（turn=1）
	_ActionPilotEffects.pilot_083_apply_to_weapon(weapon, &"player", 1, {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0})
	# 先手回合：start_turn(player) turn=1 → ROUND_START(孤儿清理，player 仍持有) + 施加
	battle.context.turn_service.start_turn(&"player")
	if int(_GEE.get_effective_weapon_stats(weapon).get("might", 0)) != 15:
		return "施加后威力应15"
	# player 回合结束（turn=1）：applied_turn(1) < 1 false → 保留
	battle.context.turn_service.end_turn(&"player")
	if int(_GEE.get_effective_weapon_stats(weapon).get("might", 0)) != 15:
		return "施加轮 player 回合结束不应过期（持续到下个我方回合结束）"
	# enemy 回合：start_turn(enemy) 不增 turn；end_turn(enemy) 只清 enemy 施加
	battle.context.turn_service.start_turn(&"enemy")
	battle.context.turn_service.end_turn(&"enemy")
	if int(_GEE.get_effective_weapon_stats(weapon).get("might", 0)) != 15:
		return "enemy 回合结束不应过期 player 的施加"
	# 下一轮 player：start_turn(player) turn=2 → ROUND_START(孤儿清理，仍持有→保留)
	battle.context.turn_service.start_turn(&"player")
	if int(_GEE.get_effective_weapon_stats(weapon).get("might", 0)) != 15:
		return "第二轮开始仍应生效（下个我方回合结束才过期）"
	# player 下个回合结束（turn=2）：applied_turn(1) < 2 true → 清除
	battle.context.turn_service.end_turn(&"player")
	if int(_GEE.get_effective_weapon_stats(weapon).get("might", 0)) != 12:
		return "下个我方回合结束应清除瓦恩施加（威力应回12），实=%d" % int(_GEE.get_effective_weapon_stats(weapon).get("might", 0))
	# ── 孤儿清理：换下瓦恩后 ROUND_START 清除 ──
	_ActionPilotEffects.pilot_083_apply_to_weapon(weapon, &"player", 2, {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0})
	# 换下瓦恩（pilot 槽清空）
	var pilot_slot = s.mech.slots.get(&"pilot")
	if pilot_slot == null:
		return "pilot 槽不存在"
	var old_card = pilot_slot.equipped_card
	pilot_slot.equipped_card = null
	if not _ActionPilotEffects.pilot_083_find_holders(gs).is_empty():
		return "换下瓦恩后 find_holders 应空"
	# enemy 回合结束 → player 回合开始（turn=3 ROUND_START）应清孤儿
	battle.context.turn_service.end_turn(&"enemy")
	battle.context.turn_service.start_turn(&"player")
	if not _ActionPilotEffects.get_pilot_083_weapon_apps(weapon)["suffixes"].is_empty():
		return "ROUND_START 应清除 owner 无瓦恩持有者的孤儿施加"
	return true


# ═══════════════════════════════════════════
# 基础武器（无卡牌实例，施加存机甲 pilot_083_base_apps）
# ═══════════════════════════════════════════

## 测试11：基础武器修改——派生统计（威力/射程/类型/名称）/叠加/过期
func test_pilot_083_base_weapon_apply() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	var base0: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, 0)
	if int(base0.get("might", 0)) != 10 or int(base0.get("range_value", 0)) != 2:
		return "基础武器基准威力应10 射程应2，实=%d/%d" % [int(base0.get("might", 0)), int(base0.get("range_value", 0))]
	# 施加 热能+远程+might3
	_ActionPilotEffects.pilot_083_apply_to_base_weapon(mech, 0, &"player", 1, {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0})
	var after: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, 0)
	if int(after.get("might", 0)) != 13:
		return "基础武器威力应+3=13，实=%d" % int(after.get("might", 0))
	if int(after.get("range_value", 0)) != 2:
		return "基础武器射程不应变（未选 range），实=%d" % int(after.get("range_value", 0))
	if String(after.get("weapon_kind", "")) != "远程":
		return "基础武器类型应覆盖为远程，实=%s" % String(after.get("weapon_kind", ""))
	if String(after.get("weapon_name", "")).find("·热能") < 0:
		return "基础武器名称应附加·热能，实=%s" % String(after.get("weapon_name", ""))
	# 再施加 光束+range1+type近战（最新覆盖，数值叠加）
	_ActionPilotEffects.pilot_083_apply_to_base_weapon(mech, 0, &"player", 1, {"name_suffix": "光束", "type_override": &"近战", "might": 3, "range": 1})
	var after2: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, 0)
	if int(after2.get("might", 0)) != 16 or int(after2.get("range_value", 0)) != 3:
		return "二次施加基础武器威力应16 射程应3（叠加），实=%d/%d" % [int(after2.get("might", 0)), int(after2.get("range_value", 0))]
	if String(after2.get("weapon_kind", "")) != "近战":
		return "基础武器类型应取最新（近战），实=%s" % String(after2.get("weapon_kind", ""))
	if String(after2.get("weapon_name", "")).find("·热能·光束") < 0:
		return "基础武器后缀应累积去重·热能·光束，实=%s" % String(after2.get("weapon_name", ""))
	# 过期：applied_turn=1，同轮保留、下轮清
	_ActionPilotEffects.pilot_083_expire_apps_for_turn(gs, &"player", 1)
	if int(_ActionPilotEffects.get_base_weapon_effective_stats(mech, 0).get("might", 0)) != 16:
		return "同轮 TURN_AFTER_END 不应过期基础武器施加"
	_ActionPilotEffects.pilot_083_expire_apps_for_turn(gs, &"player", 2)
	var after_exp: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, 0)
	if int(after_exp.get("might", 0)) != 10 or int(after_exp.get("range_value", 0)) != 2:
		return "下轮 TURN_AFTER_END 应清除基础武器施加，实=%d/%d" % [int(after_exp.get("might", 0)), int(after_exp.get("range_value", 0))]
	return true


## 测试12：RE 请求基础武器-only 机甲——候选含其基础武器；接受后施加到基础武器（不碰实体卡牌）
func test_pilot_083_base_re() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_083(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var bridge = battle.context.action_ui_bridge
	bridge.context = battle.context
	var holder_mech = s.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = _adjacent_cell_to(holder_mech.position)  # 3格内
	# enemy 无实体武器（基础武器-only）
	var re_action = await _fire_pilot_083_re(battle, s.card, enemy_mech, enemy_mech.owner_player_id)
	if re_action == null:
		return "RE 请求应挂起 phase1"
	var w1: Dictionary = bridge.get_waiting_action_info()
	if String(w1.get("input_type", &"")) != "choose_one_effect":
		return "RE phase1 应弹 choose_one_effect，实际 %s" % String(w1.get("input_type", &""))
	var ip1: Dictionary = w1.get("input_params", {})
	var opts1: Array = ip1.get("options", [])
	if opts1.size() != 1:
		return "基础武器-only 请求方候选应只有其基础武器（1把），实=%d" % opts1.size()
	var base_key: String = String(opts1[0].get("effect_id", &""))
	if not base_key.begins_with("base:enemy_mech:"):
		return "候选应为 base:enemy_mech:<slot>，实=%s" % base_key
	# 接受：选基础武器 → 三横排确认
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"chosen_effect_id": base_key})
	await _pump_frames(3)
	var w2: Dictionary = bridge.get_waiting_action_info()
	if String(w2.get("input_type", &"")) != "pilot_083_options":
		return "RE phase2 应弹 pilot_083_options，实际 %s" % String(w2.get("input_type", &""))
	battle.context.timing_engine.resume_pending_effect(re_action.action_id, {"options": {"name_suffix": "热能", "type_override": &"远程", "might": 3, "range": 0}})
	await _pump_frames(8)
	var st: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(enemy_mech, 0)
	if int(st.get("might", 0)) != 14:
		return "RE 接受后请求方基础武器威力应+3=14，实=%d" % int(st.get("might", 0))
	if String(st.get("weapon_kind", "")) != "远程":
		return "RE 接受后请求方基础武器类型应远程，实=%s" % String(st.get("weapon_kind", ""))
	return true
