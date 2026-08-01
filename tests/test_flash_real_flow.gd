## test_flash_real_flow.gd — 闪击效果2 真实打出流程回归
##
## 现有 test_action_card_effects.gd 的闪击测试用 _make_attack + _register_listen + fire_timing
## 直接构造，绕过了 use_action_card → attack A 效果动作的真实注册链路。本测试走真实流程：
##   battle.execute_use_action_card(player, 闪击牌) → use_action_card 动作 → flash_effect1(DIRECT)
##   → 创建 attack A 效果动作 → 注册 flash_effect2(LISTEN, bind_to_sub) 到 attack A 的 ATTACK_SETTLE
## 验证：ATTACK_SETTLE fire 时 flash_effect2 被触发、_pending_effect 被挂起、弹窗信号被发出。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


## 把指定 card_def_id 的牌塞入玩家手牌，返回 card_instance_id
func _ensure_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	# 弃牌堆
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


## 驱动 attack 的损伤设置效果动作完成（apply_damage 改为效果动作等待后必需）。
## attack 在 apply_damage 步发起 damage_change 效果动作并 waiting_sub_action 等待。
## damage_change 因 place_damage_tokens 暂停（人类执行者）。本 helper 同步驱动：
##   ① 找到 damage_change 效果动作 ② 放置损伤 ③ continue 注入 auto_placed 让其完成
##   ④ 手动同步通知 attack 恢复（deferred 在测试同步模式不 flush）
## 循环处理多个待完成效果动作，直到 attack 不再 waiting_sub_action。
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	# 循环驱动所有 pending 效果动作（hp_change 同步完成无需驱动；damage_change 需驱动）
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		# 找到未完成的 damage_change 效果动作
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id == &"":
			# 没有等待输入的 damage_change，可能效果动作都已完成但 deferred 未 flush，手动通知
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			continue
		var dc = ar.get_action(dc_id)
		var amount: int = int(dc.record.get("value", 0))
		var mech_ids: Array = dc.record.get("mech_ids", [])
		# 放置损伤（仿 ActionUIBridge._auto_place_damage_tokens）
		if dts != null and amount > 0:
			for mech_id: StringName in mech_ids:
				dts.place_damage_tokens({"mech_id": mech_id, "count": amount})
		# continue damage_change 注入 auto_placed，让其跳过 place_damage_tokens 完成结算
		ae.continue_action(dc_id, {"auto_placed": true})
		# damage_change 完成靠 call_deferred 通知 attack；测试同步模式手动同步通知
		ae.notify_effect_action_completed(dc_id, attack_id)
	return {"ok": true}



## 闪击：真实打出 → 选武器 → 选目标 → attack A 走到 ATTACK_SETTLE → flash_effect2 应被触发挂起
func test_flash_real_play_registers_and_fires_effect2():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"

	# 给玩家塞2张行动牌（闪击要弃1张，且 HAS_ACTION_CARD_IN_HAND 需手牌≥1）
	var flash_id = _ensure_card_in_hand(battle, "action_006_闪击")
	if flash_id == &"":
		return "牌堆/弃牌堆中找不到 闪击"
	var fodder1 = _ensure_card_in_hand(battle, "action_001_进攻")
	var fodder2 = _ensure_card_in_hand(battle, "action_001_进攻")
	if fodder1 == &"" or fodder2 == &"":
		return "无法塞入足够行动牌"

	# 玩家须有武器（教程机甲基础武器）
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]

	# 让目标在射程内：把敌方放到玩家相邻格
	enemy_mech.position = {"q": 3, "r": 2}

	# 清空敌方手牌中的迎击牌，避免 ATTACK_AT 响应窗口拦截
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	# 监听 TimingEngine 弹窗信号（可选弃牌弹窗）
	# 用 Array 当盒子收集 inputs（GDScript lambda 按值捕获 bool 局部变量，直接赋值外层看不到）
	var seen_inputs: Array = []
	battle.context.timing_engine.action_needs_input.connect(
		func(action_id, input_type, input_params):
			seen_inputs.append(String(input_type))
	)

	# 真实打出闪击牌
	var result: Dictionary = battle.execute_use_action_card(&"player", flash_id)
	# use_action_card 应暂停在 waiting_sub_action（等 attack A 选武器）
	var uc_state = result.get("state", &"")
	if uc_state != &"waiting_effect_action":
		return "use_action_card 应暂停在 waiting_sub_action（等 attack A），实际 state=%s" % String(uc_state)

	# 找到 attack A 效果动作
	var attack_a = null
	var attack_a_id: StringName = &""
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a_id = aid
			attack_a = a
			break
	if attack_a_id == &"" or attack_a == null:
		return "找不到 attack A 效果动作"

	# 检查①：flash_effect2 是否被注册为 attack A 的 ATTACK_SETTLE 临时监听器
	# （真实打出流程：use_action_card 的 _register_pending_listen_effects 应把 flash_effect2
	#   绑到 attack A 效果动作的 action_id。这是此前 bug 的断点——监听器没绑上就永远不会触发。）
	var settle_listeners: Array = battle.context.timing_engine.temporary_listeners.get(_TimingConst.ATTACK_SETTLE, [])
	var has_flash2_listener := false
	for entry: Dictionary in settle_listeners:
		if String(entry.get("action_id", &"")) == String(attack_a_id):
			var eff = entry.get("effect")
			if eff and String(eff.effect_id) == &"flash_effect2":
				has_flash2_listener = true
				break
	if not has_flash2_listener:
		return "flash_effect2 未注册到 attack A 的 ATTACK_SETTLE 临时监听器（真实流程注册链路断裂）"

	# 驱动 attack A 选武器：continue_action 注入 weapon_id
	var weapon_result: Dictionary = battle.context.action_engine.continue_action(attack_a_id, {"weapon_id": weapon_id})
	# 选完武器应卡在 select_target（或已完成若 target 预填）
	var st = weapon_result.get("state", &"")

	# 若卡在 select_attack_target，注入 target_id 继续
	if String(st) == &"waiting_input":
		var target_result: Dictionary = battle.context.action_engine.continue_action(attack_a_id, {"target_id": enemy_mech.mech_id})
		st = target_result.get("state", &"")

	# 选完目标后 attack A 进入 apply_damage 步：发起 hp_change/damage_change 效果动作并
	# waiting_sub_action 等待。damage_change（markers>0）会弹 place_damage_tokens UI。
	# 改动后 attack 必须等所有损伤设置完毕（damage_change 完成）才进 ATTACK_SETTLE，
	# 否则闪击 effect2 弹窗会与损伤设置 UI 重叠（用户报告的 bug）。测试同步驱动损伤设置完成。
	var drive_ret: Dictionary = _drive_damage_placement(battle, attack_a_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "损伤设置驱动失败")

	# attack A 现在应跑到 ATTACK_SETTLE → flash_effect2 触发 → _pending_effect 挂起 → waiting_timing
	# （ATTACK_SETTLE 是 attack 第8步 fire 在 settle handler 前）
	if not battle.context.timing_engine._pending_effect.has(attack_a_id):
		return "ATTACK_SETTLE fire 后 flash_effect2 未挂起 _pending_effect（attack state=%s）" % String(attack_a.state)
	# attack A 应停在 waiting_timing（_request_optional_discard 置位，等玩家选弃牌）
	if String(attack_a.state) != &"waiting_timing":
		return "flash_effect2 触发后 attack A 应停在 waiting_timing，实际 state=%s" % String(attack_a.state)
	# 弹窗信号应已发出（_request_optional_discard emit action_needs_input select_discard_cards）
	# 弹窗信号应已发出（_request_optional_discard emit action_needs_input select_discard_cards）
	var saw_select_discard: bool = seen_inputs.has("select_discard_cards")
	if not saw_select_discard:
		return "未发出 select_discard_cards 弹窗信号（收到的 inputs: %s）" % str(seen_inputs)
	return true


## 闪击：选牌续跑后应再发动一次攻击 B（用攻击A的武器，目标由玩家在武器范围内选择）
func test_flash_real_resume_triggers_second_attack():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var flash_id = _ensure_card_in_hand(battle, "action_006_闪击")
	var fodder1 = _ensure_card_in_hand(battle, "action_001_进攻")
	if flash_id == &"" or fodder1 == &"":
		return "无法塞入闪击/弃牌"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]
	enemy_mech.position = {"q": 3, "r": 2}
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	battle.execute_use_action_card(&"player", flash_id)

	var attack_a_id: StringName = &""
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a_id = aid
			break
	if attack_a_id == &"":
		return "找不到 attack A"

	battle.context.action_engine.continue_action(attack_a_id, {"weapon_id": weapon_id})
	battle.context.action_engine.continue_action(attack_a_id, {"target_id": enemy_mech.mech_id})

	# 选完目标后 attack A 在 apply_damage 等 damage_change 效果动作（损伤设置）完成。
	# 同步驱动损伤设置，attack A 才进 ATTACK_SETTLE 触发 flash_effect2 挂起。
	var drive_ret2: Dictionary = _drive_damage_placement(battle, attack_a_id)
	if not drive_ret2.get("ok", false):
		return drive_ret2.get("msg", "attack A 损伤设置驱动失败")

	if not battle.context.timing_engine._pending_effect.has(attack_a_id):
		return "flash_effect2 应挂起 _pending_effect"

	# attack A 命中后记下敌方 HP（attack A 的伤害在 ATTACK_SETTLE 之前已结算）
	var enemy_hp_before_b: int = enemy_mech.current_hp if enemy_mech else -1
	if enemy_hp_before_b < 0:
		return "无法读取敌方 HP"

	# 玩家选 fodder1 弃牌续跑（触发 attack B：用攻击A的武器，目标在武器范围内由玩家选择）
	battle.context.timing_engine.resume_pending_effect(attack_a_id, {"selected_action_card_ids": [fodder1]})

	# fodder1 应被弃置
	if gs.players.get(&"player").action_hand.has(fodder1):
		return "续跑后应弃掉选中的牌"

	# attack B 作为 attack A 的效果子动作创建：用攻击A的武器（已预填），目标待玩家选择。
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var attack_a = ar.get_action(attack_a_id)
	# attack A 应停在 waiting_effect_action（等 attack B），而非已推进到 cleanup
	if String(attack_a.state) != &"waiting_effect_action":
		return "attack A 应等待 attack B 完成（waiting_effect_action），实际 state=%s" % String(attack_a.state)
	var attack_b_id: StringName = &""
	for aid: StringName in attack_a.pending_effect_action_ids:
		var sub = ar.get_action(aid)
		if sub != null and sub.action_type == &"attack":
			attack_b_id = aid
			break
	if attack_b_id == &"":
		return "续跑后应创建 attack B 效果子动作"
	var attack_b = ar.get_action(attack_b_id)
	# attack B 应停在 select_attack_target（目标待玩家在武器范围内选择）
	if String(attack_b.state) != &"waiting_input":
		return "attack B 应停在 waiting_input（选目标），实际 state=%s" % String(attack_b.state)
	# attack B 应已预填武器（与攻击A相同），无须再选武器
	if String(attack_b.record.get("weapon_id", &"")) != String(weapon_id):
		return "attack B 应预填攻击A的武器，实际 weapon_id=%s" % String(attack_b.record.get("weapon_id", &""))

	# 玩家选敌方为 attack B 的目标（可在武器范围内任选，此处仍选攻击A的目标）
	ae.continue_action(attack_b_id, {"target_id": enemy_mech.mech_id})

	# 驱动 attack B 的损伤设置
	var drive_ret_b: Dictionary = _drive_damage_placement(battle, attack_b_id)
	if not drive_ret_b.get("ok", false):
		return drive_ret_b.get("msg", "attack B 损伤设置驱动失败")

	# attack B 命中并造成伤害，敌方 HP 应再次下降
	var enemy_hp_after_b: int = enemy_mech.current_hp if enemy_mech else -1
	if enemy_hp_after_b >= enemy_hp_before_b:
		return "attack B 应对敌方造成伤害（HP 应下降），前=%d 后=%d" % [enemy_hp_before_b, enemy_hp_after_b]
	return true


## 闪击第二次攻击可选择不同目标：attack A 打 enemy1，attack B 选择范围内另一个机甲 enemy2
func test_flash_second_attack_chooses_different_target():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.mechs.get(&"enemy_mech")  # enemy1（攻击A的目标）
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"

	# 创建第3个机甲 enemy2（敌方阵营），放在玩家武器范围内、与 enemy1 不同的格子
	var enemy2_mech := _MechState.new()
	enemy2_mech.mech_id = &"enemy2_mech"
	enemy2_mech.owner_player_id = &"enemy"
	enemy2_mech.max_hp = 25
	enemy2_mech.current_hp = 25
	enemy2_mech.position = {"q": 2, "r": 3}  # 玩家(2,2)相邻格，武器范围2内
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var s := _MechSlotState.new()
		s.slot_id = slot_id
		s.slot_kind = &"PART"
		enemy2_mech.slots[slot_id] = s
	gs.mechs[enemy2_mech.mech_id] = enemy2_mech

	var flash_id = _ensure_card_in_hand(battle, "action_006_闪击")
	var fodder1 = _ensure_card_in_hand(battle, "action_001_进攻")
	if flash_id == &"" or fodder1 == &"":
		return "无法塞入闪击/弃牌"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	var weapon_id = weapon_ids[0]
	# enemy1 放在玩家武器范围内
	enemy_mech.position = {"q": 3, "r": 2}
	# 清空敌方手牌（避免 ATTACK_AT 响应窗口拦截 attack A 与 attack B）
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()

	var enemy1_hp_before_a: int = enemy_mech.current_hp
	var enemy2_hp_before_a: int = enemy2_mech.current_hp

	# 真实打出闪击 -> attack A，选武器，选目标=enemy1
	battle.execute_use_action_card(&"player", flash_id)
	var attack_a_id: StringName = &""
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a_id = aid
			break
	if attack_a_id == &"":
		return "找不到 attack A"
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	ae.continue_action(attack_a_id, {"weapon_id": weapon_id})
	ae.continue_action(attack_a_id, {"target_id": enemy_mech.mech_id})
	# 驱动 attack A 损伤设置 -> ATTACK_SETTLE 触发 flash_effect2
	var drive_ret_a: Dictionary = _drive_damage_placement(battle, attack_a_id)
	if not drive_ret_a.get("ok", false):
		return drive_ret_a.get("msg", "attack A 损伤设置驱动失败")
	if not battle.context.timing_engine._pending_effect.has(attack_a_id):
		return "flash_effect2 应挂起 _pending_effect"

	# attack A 应命中 enemy1（HP下降），enemy2 不受影响
	var enemy1_hp_after_a: int = enemy_mech.current_hp
	var enemy2_hp_after_a: int = enemy2_mech.current_hp
	if enemy1_hp_after_a >= enemy1_hp_before_a:
		return "attack A 应对 enemy1 造成伤害，前=%d 后=%d" % [enemy1_hp_before_a, enemy1_hp_after_a]
	if enemy2_hp_after_a != enemy2_hp_before_a:
		return "attack A 不应影响 enemy2"

	# 玩家选 fodder1 弃牌续跑 -> attack B（用攻击A的武器，目标待选）
	battle.context.timing_engine.resume_pending_effect(attack_a_id, {"selected_action_card_ids": [fodder1]})

	# 找到 attack B
	var attack_a = ar.get_action(attack_a_id)
	var attack_b_id: StringName = &""
	for aid: StringName in attack_a.pending_effect_action_ids:
		var sub = ar.get_action(aid)
		if sub != null and sub.action_type == &"attack":
			attack_b_id = aid
			break
	if attack_b_id == &"":
		return "续跑后应创建 attack B"
	var attack_b = ar.get_action(attack_b_id)
	if String(attack_b.state) != &"waiting_input":
		return "attack B 应停在 waiting_input（选目标），实际 state=%s" % String(attack_b.state)

	# 玩家选 enemy2 为 attack B 的目标（与攻击A的 enemy1 不同）
	ae.continue_action(attack_b_id, {"target_id": enemy2_mech.mech_id})
	# 驱动 attack B 损伤设置
	var drive_ret_b: Dictionary = _drive_damage_placement(battle, attack_b_id)
	if not drive_ret_b.get("ok", false):
		return drive_ret_b.get("msg", "attack B 损伤设置驱动失败")

	# attack B 应命中 enemy2（HP下降），enemy1 不再受攻击B影响
	var enemy1_hp_after_b: int = enemy_mech.current_hp
	var enemy2_hp_after_b: int = enemy2_mech.current_hp
	if enemy2_hp_after_b >= enemy2_hp_after_a:
		return "attack B 应对 enemy2 造成伤害（选择了不同目标），前=%d 后=%d" % [enemy2_hp_after_a, enemy2_hp_after_b]
	if enemy1_hp_after_b != enemy1_hp_after_a:
		return "attack B 目标是 enemy2，不应再次伤害 enemy1，前=%d 后=%d" % [enemy1_hp_after_a, enemy1_hp_after_b]
	return true
