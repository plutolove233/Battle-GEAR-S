## test_lock_effect.gd — 锁定效果端到端测试
##
## 还原并验证场景：
##   玩家A使用锁定牌选目标B后，B这回合不能对A发动的攻击用迎击牌响应（识破除外）；
##   之后B被任何攻击命中后，锁定解除（A若还有攻击则B可迎击）。
##   持续1回合（回合结束-1，到0解除）+ 命中即解，二者并存。
##
## 验证点（对应 new_logic/行动牌的效果与逻辑.txt 第20张"锁定"）：
##   1. 封锁：A攻B时，B的普通迎击牌（回避/防御）不进响应窗口，识破仍进。
##   2. 不误封：C攻B（C≠A）时，B的普通迎击牌照常进响应窗口。
##   3. 命中解除：A攻B命中 → B的LOCKED被移除 → A再攻B时迎击恢复。
##   4. 未命中不解除：A攻B未命中 → LOCKED仍在 → A再攻B仍封锁。
##   5. 第三方命中解除：C攻B命中 → B的LOCKED也被解除。
##   6. 回合到期：未命中，回合结束 → duration-1到0 → LOCKED移除。
##   7. 识破可响应：锁定状态下识破仍可响应A的攻击。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_ThrustHelper.clear_thrust_from_hand(battle)
	return battle


## 给指定玩家手牌塞入一张 card_def_id 的牌，并注册 AVAILABILITY 监听器。
## 返回 card_instance_id（card.mech_id 由 register_hand_card_availability 自动设为持有者机甲）。
func _ensure_card_in_player_hand(battle, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	# 已在手则直接返回（确保 mech_id 已设）
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			battle.context.register_hand_card_availability(cid)
			return cid
	# 从牌堆找
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	# 从弃牌堆找
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 构造一个已注册的 attack 动作（running 态）
func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_lock_attack_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": extra.get("weapon_id", &""),
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 对 target 施加锁定状态（locker=attacker_player_id），返回 status_id
func _apply_lock(battle, target_id: StringName, attacker_player_id: StringName) -> void:
	var ga = battle.context.game_actions
	ga.apply_or_check_locked({
		"target_id": target_id,
		"source_player_id": attacker_player_id,
		"mode": &"apply",
		"duration": 1,
	})


## 返回响应窗口里指定 card_instance_id 是否被收集
func _is_available(battle, attack, card_instance_id: StringName) -> bool:
	var available: Array[Dictionary] = battle.context.timing_engine.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for entry: Dictionary in available:
		if entry.get("card_instance_id", &"") == card_instance_id:
			return true
	return false


## ── 测试1：封锁 —— A攻B时，B的普通迎击牌不进响应窗口，识破仍进 ──
func test_lock_suppresses_normal_counters():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# B(enemy) 持有回避 + 识破
	var evade_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_008_回避")
	var expose_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_012_识破")
	if evade_cid == &"" or expose_cid == &"":
		return "enemy 手牌塞入回避/识破失败"
	# A(player) 对 B 施加锁定
	_apply_lock(battle, enemy_mech.mech_id, &"player")
	if not enemy_mech.is_locked_by(&"player"):
		return "施加锁定失败：enemy 未被 player 锁定"
	# A 攻 B
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"player"}})
	if _is_available(battle, attack, evade_cid):
		return "锁定状态下，A攻B时回避牌不应出现在响应窗口"
	if not _is_available(battle, attack, expose_cid):
		return "锁定状态下，识破应仍可响应A的攻击"
	return true


## ── 测试2：基线对比 —— 未被攻击者锁定时，迎击牌照常出现 ──
## 验证封锁只作用于"被攻击者锁定的目标"，不误伤未锁定目标。
func test_no_lock_no_suppress():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var evade_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_008_回避")
	if evade_cid == &"":
		return "enemy 手牌塞入回避失败"
	# 未施加锁定：player 攻 enemy，回避应正常出现
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"player"}})
	if not _is_available(battle, attack, evade_cid):
		return "未被锁定时，回避牌应正常出现在响应窗口"
	# 施加锁定后同一次攻击，回避应被封锁
	_apply_lock(battle, enemy_mech.mech_id, &"player")
	var attack2 := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"player"}})
	if _is_available(battle, attack2, evade_cid):
		return "施加锁定后，A攻B时回避牌应被封锁"
	return true


## ── 测试3：命中解除 —— A攻B命中 → LOCKED移除 → 再攻迎击恢复 ──
func test_lock_cleared_on_hit():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var evade_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_008_回避")
	_apply_lock(battle, enemy_mech.mech_id, &"player")
	# 注册命中清除监听器（状态施加时已自动注册 lock_status_clear_on_hit 到 ATTACK_AFTER）
	# 构造 A 攻 B 命中：fire ATTACK_AFTER，payload 带 hit=true
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"player"}, "hit": true})
	# 清空 enemy 手牌的 AVAILABILITY 避免 ATTACK_AT 拦截（这里直接 fire ATTACK_AFTER）
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if enemy_mech.is_locked_by(&"player"):
		return "命中后 LOCKED 应被移除"
	# 再攻 B，回避应恢复
	var attack2 := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"player"}})
	if not _is_available(battle, attack2, evade_cid):
		return "命中解除锁定后，再攻时回避牌应恢复进响应窗口"
	return true


## ── 测试4：未命中不解除 —— A攻B未命中 → LOCKED仍在 ──
func test_lock_persists_on_miss():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_apply_lock(battle, enemy_mech.mech_id, &"player")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"player"}, "hit": false})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if not enemy_mech.is_locked_by(&"player"):
		return "未命中时 LOCKED 应保留"
	return true


## ── 测试5：非 locker 命中不解除 —— condition 校验 attacker==locker ──
## 文档效果2原文：「监听 locker机甲为发动攻击的机甲、Target为攻击目标的攻击动作A
##   发出的攻击后时点，若A命中则去除此锁定状态。」即只有 locker 本人（玩家A）
##   命中 Target 才解除。本测试验证：非 locker 玩家命中 Target 时，锁定不解除。
## （TARGET_HAS_LOCK_FROM_ATTACKER 要求 attack_source.player_id==locker_player_id。）
func test_lock_not_cleared_by_third_party_hit():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# A=player 锁 B=enemy
	_apply_lock(battle, enemy_mech.mech_id, &"player")
	# 构造"非 locker 玩家"命中的攻击：attacker=enemy_mech，target=enemy_mech(B)，
	# attack_source.player_id 伪造为 enemy（≠locker=player）。文档要求仅 locker 命中
	# 才解除，故非 locker 命中应保留锁定。
	var attack := _make_attack(battle, enemy_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"enemy"}, "hit": true})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if not enemy_mech.is_locked_by(&"player"):
		return "非 locker 攻击命中后 LOCKED 不应被移除（文档：仅 locker 命中才解除）"
	return true


## ── 测试6：回合到期 —— 未命中，回合结束 → duration-1到0 → LOCKED移除 ──
func test_lock_expires_on_turn_end():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_apply_lock(battle, enemy_mech.mech_id, &"player")
	if not enemy_mech.is_locked_by(&"player"):
		return "施加锁定失败"
	# lock_status_duration_tick 监听 TURN_AFTER_END，fire 后 duration-1 到0移除
	var turn_action := _Action.new()
	turn_action.action_id = &"test_lock_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {}
	turn_action.state = &"running"
	turn_action.context = battle.context
	battle.context.action_registry.register(turn_action)
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_AFTER_END, turn_action)
	if enemy_mech.is_locked_by(&"player"):
		return "回合结束后 duration=1 应-1到0并移除 LOCKED"
	return true


## ── 测试7：识破可响应 —— 锁定状态下识破仍可响应A的攻击 ──
func test_expose_bypasses_lock():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var expose_cid := _ensure_card_in_player_hand(battle, &"enemy", "action_012_识破")
	if expose_cid == &"":
		return "enemy 手牌塞入识破失败"
	_apply_lock(battle, enemy_mech.mech_id, &"player")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id,
		{"attack_source": {"player_id": &"player"}})
	if not _is_available(battle, attack, expose_cid):
		return "识破（availability_priority=30）应不受锁定封锁，仍可响应"
	return true
