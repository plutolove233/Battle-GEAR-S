## test_pilot_025_joshua.gd - 约书亚（pilot_025，秩序 SR，cost 9）效果测试
##
## 约书亚 1 按钮（被动置灰）：2 个隐藏 LISTEN 合并（effect_01 建按钮，effect_02 hover 描述合并）。
##   effect_01 我方攻击时（ATTACK_PRE priority 40，SELF_MECH_IS_ATTACKER）：
##       optional CHOOSE_ONE 二选一（可取消=不发动）：
##       1a 立即抽1张装备牌设置到区域（否则弃置）-- 复用 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET
##          （_handle_draw_equipment_pseudo 内联；设置走 set_equipment，即时使用 hook 自动生效）。
##       1b 立即设置1张备用区装备牌 + 抽2张行动牌 -- PILOT_025_SELECT_RESERVE_AND_SET
##          （选备用牌->选目标槽->移除备用区设入->set_equipment 子动作->抽2，_seq 串行）。
##          条件 SELF_MECH_HAS_RESERVE_EQUIPMENT（无备用装备时此选项过滤不可用）。
##   effect_02 我方被攻击时（ATTACK_PRE priority 10，SELF_MECH_IS_ATTACK_TARGET）：同 effect_01 的 CHOOSE_ONE。
##   无每回合1次限制（权威：用户口述，无每回合1次）。
##
## 关键覆盖点：
##   1. effect_01/02 定义（LISTEN ATTACK_PRE priority 40/10 + SELF_MECH_IS_ATTACKER/TARGET +
##      CHOOSE_ONE optional 二选一 + 无 once_per_turn）。
##   2. 我方攻击触发 effect_01 弹 CHOOSE_ONE；取消=无事发生。
##   3. 被攻击触发 effect_02 弹 CHOOSE_ONE；取消=无事发生。
##   4. 1a 抽装备+设置（reserve_1，face_down 不触发即时使用）。
##   5. 1b 选备用装备->选目标槽(头部)->设置+抽2张行动牌。
##   6. 无每回合1次：两次攻击都触发。
##   7. SELF_MECH_HAS_RESERVE_EQUIPMENT 过滤：无备用装备时 1b 选项不可用（只剩 1a）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")


# ═══════════════════════════════════════════
# 通用辅助
# ═══════════════════════════════════════════

func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90025
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


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


## 设约书亚为 owner_id 机甲的机师，返回 {mech, enemy_mech, player, gs, cdb}；失败返回 null。
func _setup_joshua(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_025_约书亚", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {
		"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb,
		"enemy_mech": gs.get_mech_for_player(&"enemy"),
	}


## 构造 attack action（fire ATTACK_PRE 用）。attacker_pid 是攻击方玩家。
func _make_attack(battle, attacker_id: StringName, target_id: StringName, attacker_pid: StringName) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p025_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id}
	attack.state = &"running"
	attack.context = battle.context
	attack.source = {"mech_id": attacker_id, "player_id": attacker_pid}
	battle.context.action_registry.register(attack)
	return attack


## 在 mech 的指定备用区槽放置1张装备牌（face_down）。返回 CardInstance；失败返回 null。
func _put_card_in_reserve(gs, cdb, mech, card_def_id: String, reserve_slot: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = mech.owner_player_id
	card.mech_id = mech.mech_id
	card.zone = &"equipment_slot"
	card.slot_id = reserve_slot
	card.face_down = true
	gs.cards[inst_id] = card
	var slot = mech.slots.get(reserve_slot)
	if slot == null:
		slot = _MechSlotState.new()
		slot.slot_id = reserve_slot
		mech.slots[reserve_slot] = slot
	slot.equipped_card = card
	return card


## 连接 timing_engine.action_needs_input 信号，返回捕获数组（lambda 捕获 Array 引用，append 可见）。
func _capture_popups(te) -> Array:
	var captured := []
	te.action_needs_input.connect(
		func(_aid: StringName, itype: StringName, iparams: Dictionary) -> void:
			captured.append({"type": String(itype), "params": iparams})
	)
	return captured


## 取捕获数组里最后一个弹窗的 input_type（无则空串）。
func _last_popup_type(captured: Array) -> String:
	if captured.is_empty():
		return ""
	var last = captured[captured.size() - 1]
	return String(last.get("type", ""))


## 递归收集 actions 列表里所有 action type（含 CHOOSE_ONE 分支内嵌套）
func _collect_act_types(actions: Array) -> Array:
	var out: Array = []
	for a in actions:
		var t = String(a.get("type", &""))
		out.append(t)
		if t == "CHOOSE_ONE":
			var opts = a.get("params", {}).get("options", [])
			for opt in opts:
				out += _collect_act_types(opt.get("actions", []))
	return out


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：effect_01/02 定义正确
func test_pilot_025_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	# effect_01 我方攻击时
	var e1 = effects.get(&"pilot_025_effect_01")
	if e1 == null:
		return "缺 pilot_025_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "e1 mode 应 LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.ATTACK_PRE:
		return "e1 listen_timing 应 ATTACK_PRE"
	if int(e1.priority) != 40:
		return "e1 priority 应 40 实=%d" % int(e1.priority)
	if e1.listen_action_type != &"attack":
		return "e1 listen_action_type 应 attack"
	# 无每回合1次
	if e1.once_per_turn_key != &"":
		return "e1 不应有 once_per_turn_key 实=%s" % String(e1.once_per_turn_key)
	# condition SELF_MECH_IS_ATTACKER
	var ops1: Array = []
	for c in e1.conditions:
		ops1.append(String(c.get("op", &"")))
	if not ops1.has("SELF_MECH_IS_ATTACKER"):
		return "e1 应含 SELF_MECH_IS_ATTACKER"
	# actions[0] = CHOOSE_ONE optional 二选一
	var a1 = e1.actions[0] if not e1.actions.is_empty() else {}
	if String(a1.get("type", &"")) != "CHOOSE_ONE":
		return "e1 actions[0] 应 CHOOSE_ONE 实=%s" % String(a1.get("type", &""))
	var p1: Dictionary = a1.get("params", {})
	if not bool(p1.get("optional", false)):
		return "e1 CHOOSE_ONE 应 optional=true"
	var opts1: Array = p1.get("options", [])
	if opts1.size() != 2:
		return "e1 应有2个选项 实=%d" % opts1.size()
	# 选项0 = 1a 抽装备设置
	var opt0: Dictionary = opts1[0]
	if String(opt0.get("actions", [{}])[0].get("type", &"")) != "DRAW_EQUIPMENT_AND_IMMEDIATELY_SET":
		return "e1 选项0 应 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET"
	# 选项1 = 1b 备用装备设置+抽2，带 SELF_MECH_HAS_RESERVE_EQUIPMENT 条件
	var opt1: Dictionary = opts1[1]
	if String(opt1.get("actions", [{}])[0].get("type", &"")) != "PILOT_025_SELECT_RESERVE_AND_SET":
		return "e1 选项1 应 PILOT_025_SELECT_RESERVE_AND_SET"
	var opt1_conds = opt1.get("condition", [])
	if opt1_conds is Dictionary:
		opt1_conds = [opt1_conds]
	var opt1_ops: Array = []
	for c in opt1_conds:
		opt1_ops.append(String(c.get("op", &"")))
	if not opt1_ops.has("SELF_MECH_HAS_RESERVE_EQUIPMENT"):
		return "e1 选项1 应含 SELF_MECH_HAS_RESERVE_EQUIPMENT 条件"

	# effect_02 我方被攻击时
	var e2 = effects.get(&"pilot_025_effect_02")
	if e2 == null:
		return "缺 pilot_025_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "e2 mode 应 LISTEN 实=%s" % String(e2.mode)
	if e2.listen_timing != _TimingConst.ATTACK_PRE:
		return "e2 listen_timing 应 ATTACK_PRE"
	if int(e2.priority) != 10:
		return "e2 priority 应 10 实=%d" % int(e2.priority)
	if e2.once_per_turn_key != &"":
		return "e2 不应有 once_per_turn_key"
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("SELF_MECH_IS_ATTACK_TARGET"):
		return "e2 应含 SELF_MECH_IS_ATTACK_TARGET"
	# e2 也用独立 CHOOSE_ONE 深拷贝（避免与 e1 共享引用）
	var a2 = e2.actions[0] if not e2.actions.is_empty() else {}
	if String(a2.get("type", &"")) != "CHOOSE_ONE":
		return "e2 actions[0] 应 CHOOSE_ONE"
	var p2: Dictionary = a2.get("params", {})
	if not bool(p2.get("optional", false)):
		return "e2 CHOOSE_ONE 应 optional=true"
	if p2.get("options", []).size() != 2:
		return "e2 应有2个选项"
	# 收集所有内嵌 action type
	var act_types1: Array = _collect_act_types(e1.actions)
	if not act_types1.has("DRAW_EQUIPMENT_AND_IMMEDIATELY_SET"):
		return "e1 内嵌应含 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET"
	if not act_types1.has("PILOT_025_SELECT_RESERVE_AND_SET"):
		return "e1 内嵌应含 PILOT_025_SELECT_RESERVE_AND_SET"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：我方攻击触发 effect_01 弹 CHOOSE_ONE；取消=无事发生
func test_pilot_025_own_attack_choose_one_cancel() -> Variant:
	var battle = _new_battle()
	var s = _setup_joshua(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	var captured = _capture_popups(te)
	var equip_before = s.player.equipment_hand.size()
	var action_before = s.player.action_hand.size()
	var attack = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# 应弹 CHOOSE_ONE（约书亚攻击时二选一）
	if _last_popup_type(captured) != "choose_one_effect":
		return "我方攻击应弹 choose_one_effect，实=%s" % _last_popup_type(captured)
	# 取消=无事发生
	te.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(2)
	if s.player.equipment_hand.size() != equip_before:
		return "取消后装备手牌应不变 实=%d（前=%d）" % [s.player.equipment_hand.size(), equip_before]
	if s.player.action_hand.size() != action_before:
		return "取消后行动手牌应不变 实=%d（前=%d）" % [s.player.action_hand.size(), action_before]
	return true


## 测试3：被攻击触发 effect_02 弹 CHOOSE_ONE；取消=无事发生
func test_pilot_025_being_attacked_choose_one_cancel() -> Variant:
	var battle = _new_battle()
	var s = _setup_joshua(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	var captured = _capture_popups(te)
	var equip_before = s.player.equipment_hand.size()
	# 敌方攻击约书亚机甲（被攻击）
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, &"enemy")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if _last_popup_type(captured) != "choose_one_effect":
		return "被攻击应弹 choose_one_effect，实=%s" % _last_popup_type(captured)
	te.resume_pending_effect(attack.action_id, {"cancelled": true})
	await _pump_frames(2)
	if s.player.equipment_hand.size() != equip_before:
		return "取消后装备手牌应不变"
	return true


## 测试4：1a 抽1张装备牌立即设置（设到 reserve_1，face_down 不触发即时使用）
func test_pilot_025_option_1a_draw_and_set() -> Variant:
	var battle = _new_battle()
	var s = _setup_joshua(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var te = battle.context.timing_engine
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	var captured = _capture_popups(te)
	var equip_before = s.player.equipment_hand.size()
	var attack = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if _last_popup_type(captured) != "choose_one_effect":
		return "应弹 choose_one_effect，实=%s" % _last_popup_type(captured)
	# 选 1a（选项0：抽装备立即设置）
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 0})
	await _pump_frames(2)
	# 应弹 immediate_set_equipment（已抽到装备牌）
	if _last_popup_type(captured) != "immediate_set_equipment":
		return "1a 应弹 immediate_set_equipment，实=%s" % _last_popup_type(captured)
	var last_params: Dictionary = captured[captured.size() - 1]["params"]
	var drawn_id: StringName = last_params.get("drawn_card_id", &"")
	if drawn_id == &"":
		return "1a 应已抽到装备牌（drawn_card_id 非空）"
	# 装备手牌应+1（抽到的牌）
	if s.player.equipment_hand.size() - equip_before != 1:
		return "1a 抽装备后手牌应+1 实=%d（前=%d）" % [s.player.equipment_hand.size(), equip_before]
	# 确认 reserve_1 在合法槽内（任意装备都能设到备用区）
	var valid_slots: Array = last_params.get("valid_slots", [])
	if not valid_slots.has(&"reserve_1"):
		return "1a reserve_1 应在合法槽内 实=%s" % str(valid_slots)
	# 设置到 reserve_1（face_down，不触发即时使用，无弃旧牌）
	te.resume_pending_effect(attack.action_id, {"chosen_slot_id": &"reserve_1"})
	await _pump_frames(3)
	# reserve_1 应已设置该装备牌
	var r1 = player_mech.slots.get(&"reserve_1")
	if r1 == null or r1.equipped_card == null:
		return "1a 设置后 reserve_1 应有装备牌"
	if r1.equipped_card.instance_id != drawn_id:
		return "1a reserve_1 应为抽到的装备牌"
	# 装备手牌应回到原值（牌已从手牌移到槽位）
	if s.player.equipment_hand.size() != equip_before:
		return "1a 设置后装备手牌应回到原值 实=%d（前=%d）" % [s.player.equipment_hand.size(), equip_before]
	return true


## 测试5：1b 选备用装备->选目标槽->设置+抽2张行动牌
func test_pilot_025_option_1b_reserve_set_draw2() -> Variant:
	var battle = _new_battle()
	var s = _setup_joshua(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var te = battle.context.timing_engine
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	# 在 reserve_1 放1张头部部件（无效果，避免即时使用干扰）
	var reserve_card = _put_card_in_reserve(gs, cdb, player_mech, "part_001_量产装_头部", &"reserve_1")
	if reserve_card == null:
		return "缺 part_001_量产装_头部"
	var captured = _capture_popups(te)
	var action_before = s.player.action_hand.size()
	var attack = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if _last_popup_type(captured) != "choose_one_effect":
		return "应弹 choose_one_effect，实=%s" % _last_popup_type(captured)
	# 有备用装备时应有2个选项（1a + 1b）
	var co_params: Dictionary = captured[captured.size() - 1]["params"]
	if co_params.get("options", []).size() != 2:
		return "有备用装备时应有2选项 实=%d" % co_params.get("options", []).size()
	# 选 1b（选项1：设置备用区装备+抽2）
	te.resume_pending_effect(attack.action_id, {"chosen_option_index": 1})
	await _pump_frames(2)
	# 应弹 reserve_select（选备用区装备）
	if _last_popup_type(captured) != "pilot_025_reserve_select":
		return "1b 应弹 pilot_025_reserve_select，实=%s" % _last_popup_type(captured)
	# 选该备用装备牌
	te.resume_pending_effect(attack.action_id, {"selected_card_id": reserve_card.instance_id})
	await _pump_frames(2)
	# 应弹 slot_select（选目标区域）
	if _last_popup_type(captured) != "pilot_025_slot_select":
		return "1b 选备用装备后应弹 pilot_025_slot_select，实=%s" % _last_popup_type(captured)
	var slot_params: Dictionary = captured[captured.size() - 1]["params"]
	var slot_valid: Array = slot_params.get("valid_slots", [])
	# 头部部件可设到头部槽
	if not slot_valid.has(&"头部"):
		return "1b 头部应在合法槽内 实=%s" % str(slot_valid)
	# 设置到头部（空槽，无弃旧牌，part_001 无效果不触发即时使用）
	te.resume_pending_effect(attack.action_id, {"chosen_slot_id": &"头部"})
	await _pump_frames(4)
	# 头部应已设置该备用装备牌
	var head_slot = player_mech.slots.get(&"头部")
	if head_slot == null or head_slot.equipped_card == null:
		return "1b 设置后头部应有装备牌"
	if head_slot.equipped_card.instance_id != reserve_card.instance_id:
		return "1b 头部应为原备用区装备牌"
	# reserve_1 应已清空（牌已移走）
	var r1 = player_mech.slots.get(&"reserve_1")
	if r1 != null and r1.equipped_card != null:
		return "1b 设置后 reserve_1 应已清空"
	# 应抽2张行动牌
	if s.player.action_hand.size() - action_before != 2:
		return "1b 应抽2张行动牌 实=%d（前=%d）" % [s.player.action_hand.size(), action_before]
	return true


## 测试6：无每回合1次限制 -- 两次攻击都触发
func test_pilot_025_no_once_per_turn_triggers_twice() -> Variant:
	var battle = _new_battle()
	var s = _setup_joshua(battle, &"player")
	if s == null:
		return "setup 失败"
	var te = battle.context.timing_engine
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	var captured = _capture_popups(te)
	# 第1次攻击
	var attack1 = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack1)
	if _last_popup_type(captured) != "choose_one_effect":
		return "第1次攻击应弹 choose_one_effect，实=%s" % _last_popup_type(captured)
	te.resume_pending_effect(attack1.action_id, {"cancelled": true})
	await _pump_frames(2)
	# 第2次攻击（不应被每回合1次阻止）
	var attack2 = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack2)
	if _last_popup_type(captured) != "choose_one_effect":
		return "第2次攻击应再次弹 choose_one_effect（无每回合1次），实=%s" % _last_popup_type(captured)
	te.resume_pending_effect(attack2.action_id, {"cancelled": true})
	return true


## 测试7：无备用装备时 1b 选项被过滤（SELF_MECH_HAS_RESERVE_EQUIPMENT）
func test_pilot_025_option_1b_filtered_no_reserve() -> Variant:
	var battle = _new_battle()
	var s = _setup_joshua(battle, &"player")
	if s == null:
		return "setup 失败"
	var te = battle.context.timing_engine
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	var captured = _capture_popups(te)
	# 无备用装备（默认开局无装备）
	var attack = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, &"player")
	te.fire_timing(_TimingConst.ATTACK_PRE, attack)
	if _last_popup_type(captured) != "choose_one_effect":
		return "应弹 choose_one_effect，实=%s" % _last_popup_type(captured)
	var co_params: Dictionary = captured[captured.size() - 1]["params"]
	var opts: Array = co_params.get("options", [])
	# 无备用装备时 1b 被过滤，只剩 1a（1个选项）
	if opts.size() != 1:
		return "无备用装备时应只剩1a选项（1b过滤）实=%d" % opts.size()
	if String(opts[0].get("label", "")).find("抽1张装备") < 0:
		return "剩余选项应为1a（抽1张装备牌立即设置）实=%s" % String(opts[0].get("label", ""))
	te.resume_pending_effect(attack.action_id, {"cancelled": true})
	return true
