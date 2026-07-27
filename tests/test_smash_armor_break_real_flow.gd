## test_smash_armor_break_real_flow.gd - 猛击/破甲 真实打出流程还原
##
## 现有 test_action_card_effects.gd 的猛击/破甲测试用 _make_attack + _register_listen + fire_timing
## 直接构造，绕过了 use_action_card -> attack A 的真实注册链路与时点翻转后的步骤执行顺序，测不出
## 真实流程里的两类问题：
##   1. 猛击 effect2（bind_to_sub, LISTEN ATTACK_BEFORE, MODIFY_ATTACK_MIGHT +4）是否在真实流程里
##      被注册到 attack A、ATTACK_BEFORE fire 时触发、extra_might 是否被 _step_calculate_damage 计入伤害。
##   2. 破甲 effect2（bind_to_sub, LISTEN ATTACK_AFTER + ATTACK_HIT, MODIFY_ATTACK_MARKERS +2）写
##      extra_markers 的时点是否在 _step_calculate_damage 读取之前——时点翻转后步骤改为
##      「handler 先执行 -> 再 fire timing」，而 calculate_damage 的 timing 正是 ATTACK_AFTER，
##      即 handler 读 extra_markers(=0) 在前、fire 触发破甲写 extra_markers=2 在后，+2 失效。
##
## 本测试走真实流程：battle.execute_use_action_card -> use_action_card 动作 -> DIRECT effect1
##   -> 创建 attack A 效果动作 -> _register_pending_listen_effects 把 effect2 绑到 attack A
##   -> 选武器 -> 选目标 -> 结算，断言最终伤害/损伤含加成。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


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
# 仿 test_flash_real_flow.gd 的 _drive_damage_placement：找 damage_change -> 放置损伤 ->
#  continue 注入 auto_placed -> 手动同步通知 attack 恢复（deferred 在测试同步模式不 flush）。
func _drive_damage_placement(battle: BattleState, attack_id: StringName) -> Dictionary:
	var ae = battle.context.action_engine
	var ar = battle.context.action_registry
	var dts = battle.context.damage_token_service
	var attack = ar.get_action(attack_id)
	if attack == null:
		return {"ok": false, "msg": "找不到 attack %s" % String(attack_id)}
	var guard: int = 0
	while attack.state == &"waiting_effect_action" and guard < 10:
		guard += 1
		var pending: Array = attack.pending_effect_action_ids.duplicate()
		if pending.is_empty():
			break
		var dc_id: StringName = &""
		for cid: StringName in pending:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change" and sub.state == &"waiting_input":
				dc_id = cid
				break
		if dc_id == &"":
			for cid: StringName in pending:
				ae.notify_effect_action_completed(cid, attack_id)
			continue
		var dc = ar.get_action(dc_id)
		var amount: int = int(dc.record.get("value", 0))
		var mech_ids: Array = dc.record.get("mech_ids", [])
		if dts != null and amount > 0:
			for mech_id: StringName in mech_ids:
				dts.place_damage_tokens({"mech_id": mech_id, "count": amount})
		ae.continue_action(dc_id, {"auto_placed": true})
		ae.notify_effect_action_completed(dc_id, attack_id)
	return {"ok": true}


## 真实打出一张攻击牌，驱动到选完目标。返回 attack A 对象引用（停在其 apply_damage 的
## waiting_effect_action，calculate_damage 已跑完，record 含 extra_might/extra_markers/damage/markers）。
func _play_attack_card_through_target(battle: BattleState, card_def_id: String) -> Variant:
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return null
	# 敌方放入射程内（与 test_flash_real_flow 相同的相邻格）
	enemy_mech.position = {"q": 3, "r": 2}
	# 清空敌方手牌迎击牌，避免 ATTACK_AT 响应窗口拦截
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()
	# 塞入目标牌
	var card_id = _ensure_card_in_hand(battle, card_def_id)
	if card_id == &"":
		return null
	# 武器
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return null
	var weapon_id = weapon_ids[0]
	# 真实打出
	battle.execute_use_action_card(&"player", card_id)
	# 找到 attack A 效果动作
	var attack_a = null
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a = a
			break
	if attack_a == null:
		return null
	# 选武器（attack A 从 select_weapon need_input 恢复，fire ATTACK_BEFORE -> 猛击 effect2）
	battle.context.action_engine.continue_action(attack_a.action_id, {"weapon_id": weapon_id})
	# 选目标（随后跑到 calculate_damage -> ATTACK_AFTER -> apply_damage 暂停）
	battle.context.action_engine.continue_action(attack_a.action_id, {"target_id": enemy_mech.mech_id})
	return attack_a


## 统计一台机甲所有槽位上的损伤标记总数（region_damage_tokens）
func _count_damage_tokens(mech) -> int:
	if mech == null:
		return 0
	var total: int = 0
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot != null:
			total += int(slot.region_damage_tokens)
	return total


## ── 猛击：真实打出 -> effect2 在 ATTACK_BEFORE 写 extra_might=4 -> 伤害含 +4 ──
func test_smash_real_flow_adds_might():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到敌方机甲"
	var enemy_hp_before: int = enemy_mech.current_hp
	var enemy_armor: int = int(enemy_mech.get_armor())

	var attack_a = _play_attack_card_through_target(battle, "action_003_猛击")
	if attack_a == null:
		return "无法驱动猛击到选目标后（attack A 未创建/未推进）"

	# ① extra_might 必须为 4（effect2 在 ATTACK_BEFORE 触发并写入）
	var extra_might: int = int(attack_a.record.get("extra_might", 0))
	if extra_might != 4:
		return "猛击应写 extra_might=4，实际: %d（effect2 未注册到 attack A 或 ATTACK_BEFORE 未触发）" % extra_might

	# ② calculate_damage 必须把 extra_might 计入伤害
	var weapon_might: int = int(attack_a.record.get("weapon_might", 0))
	var expected_damage: int = max(0, weapon_might + 4 - enemy_armor)
	var damage: int = int(attack_a.record.get("damage", -1))
	if damage != expected_damage:
		return "猛击 damage 应=%d (weapon_might %d + extra_might 4 - armor %d)，实际: %d" % [expected_damage, weapon_might, enemy_armor, damage]

	# ③ 实际扣血 == damage（hp_change 在 apply_damage 同步执行）
	var hp_after_target: int = enemy_mech.current_hp
	if enemy_hp_before - hp_after_target != damage:
		return "敌方 HP 应下降 %d，实际下降 %d" % [damage, enemy_hp_before - hp_after_target]

	# ④ 驱动损伤设置完成，验证攻击完整结算（markers 与放置损伤数一致）
	var drive_ret: Dictionary = _drive_damage_placement(battle, attack_a.action_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "损伤设置驱动失败")
	return true


## ── 破甲：真实打出 -> 命中 -> effect2 在 ATTACK_AFTER 写 extra_markers=2 -> 损伤含 +2 ──
func test_armor_break_real_flow_adds_markers():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到敌方机甲"
	var enemy_tokens_before: int = _count_damage_tokens(enemy_mech)

	var attack_a = _play_attack_card_through_target(battle, "action_004_破甲")
	if attack_a == null:
		return "无法驱动破甲到选目标后（attack A 未创建/未推进）"

	# 必须命中（破甲 effect2 条件 ATTACK_HIT）
	var hit: bool = bool(attack_a.record.get("hit", false))
	if not hit:
		return "破甲应命中目标以触发 +2 损伤，hit=%s" % str(hit)

	# ① extra_markers 必须为 2（effect2 在 ATTACK_AFTER 触发并写入）
	var extra_markers: int = int(attack_a.record.get("extra_markers", 0))
	if extra_markers != 2:
		return "破甲应写 extra_markers=2，实际: %d（effect2 未注册到 attack A 或 ATTACK_AFTER 未触发或 ATTACK_HIT 条件失败）" % extra_markers

	# ② calculate_damage 必须把 extra_markers 计入 markers
	#    时点翻转后 _step_calculate_damage 的 handler 先于 ATTACK_AFTER fire 执行，
	#    即 handler 读 extra_markers(=0) 在前、fire 触发破甲写 extra_markers=2 在后 -> +2 失效。
	var weapon_might: int = int(attack_a.record.get("weapon_might", 0))
	var base_markers: int = int(weapon_might / 5)
	var expected_markers: int = base_markers + 2
	var markers: int = int(attack_a.record.get("markers", -1))
	if markers != expected_markers:
		return "破甲 markers 应=%d (base %d + extra_markers 2)，实际: %d —— extra_markers=%d 已写入但未被 calculate_damage 计入（时点翻转：handler 读早于 ATTACK_AFTER fire 写）" % [expected_markers, base_markers, markers, extra_markers]

	# ③ 驱动损伤设置完成，验证实际放置损伤数 == markers
	var drive_ret: Dictionary = _drive_damage_placement(battle, attack_a.action_id)
	if not drive_ret.get("ok", false):
		return drive_ret.get("msg", "损伤设置驱动失败")
	var tokens_placed: int = _count_damage_tokens(enemy_mech) - enemy_tokens_before
	if tokens_placed != expected_markers:
		return "破甲应放置 %d 枚损伤，实际放置 %d 枚" % [expected_markers, tokens_placed]
	return true


## ── 猛击（preset weapon/target）：weapon 预填时 attack A 不在 select_weapon 暂停，
## 会一路同步跑过 step1 ATTACK_BEFORE -- 此时 smash_effect2（bind_to_sub）尚未注册
## （它在 _step_execute_effects 的 DIRECT 效果执行后才注册），导致 extra_might 永不写入。
## 本用例还原该潜在场景，供确认是否是用户观察到的"猛击没有加威力"。
func test_smash_preset_weapon_adds_might():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "找不到玩家/敌方机甲"
	enemy_mech.position = {"q": 3, "r": 2}
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()
	var card_id = _ensure_card_in_hand(battle, "action_003_猛击")
	if card_id == &"":
		return "找不到猛击牌"
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	# 预填 weapon_id + target_id：模拟不走选武器 UI 的入口
	battle.execute_use_action_card(&"player", card_id, {
		"weapon_id": weapon_ids[0],
		"target_id": enemy_mech.mech_id,
	})
	# 找到 attack A
	var attack_a = null
	for aid in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and a.action_type == &"attack":
			attack_a = a
			break
	if attack_a == null:
		return "preset weapon 下未找到 attack A（可能已同步完成）"
	var extra_might: int = int(attack_a.record.get("extra_might", 0))
	if extra_might != 4:
		return "preset weapon 下猛击 extra_might 应=4，实际: %d（smash_effect2 注册晚于 ATTACK_BEFORE fire，监听器漏注册）" % extra_might
	# 清理：驱动损伤设置到完成，避免残留 pending 效果动作影响后续测试
	_drive_damage_placement(battle, attack_a.action_id)
	return true
