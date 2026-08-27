## GameState.gd — 游戏全局运行时状态
##
## GameState 是所有运行时数据的顶层容器，由 GameContext 持有。
## 所有 Service 通过 GameContext.game_state 访问和修改游戏状态。
class_name GameState
extends RefCounted

const _MapState = preload("res://scripts/runtime/MapState.gd")
const _DeckState = preload("res://scripts/runtime/DeckState.gd")
const _ShopState = preload("res://scripts/runtime/ShopState.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")

## 玩家状态：player_id → PlayerState
var players: Dictionary = {}

## 机甲状态：mech_id → MechState
var mechs: Dictionary = {}

## 卡牌实例：instance_id → CardInstance
var cards: Dictionary = {}

## 攻击上下文：attack_id → Dictionary
var attacks: Dictionary = {}

## 损伤上下文：damage_context_id → Dictionary
var damage_contexts: Dictionary = {}

## 地图状态
var map_state = null

## 牌堆状态
var deck_state = null

## 商店状态
var shop_state = null

## 规则修正列表（来自效果的规则改写）
var rule_modifiers: Array[Dictionary] = []

## 临时值存储（骰子结果等，效果间传递数据）
var temp_values: Dictionary = {}

## 当前正在处理的攻击 ID
var current_attack_id: StringName = &""

## 当前损伤上下文 ID
var current_damage_context_id: StringName = &""

## 待处理的自定义效果
var pending_custom_effects: Array[Dictionary] = []

## 琳 pilot_024 RE 维修窗口（存在即激活）：{"lin_mech_id", "requester_mech_id", "action_id"}
## 请求方点击 RE 后琳确认即打开；维修完成/取消时关闭并恢复请求方回合。PvP 锁步各端一致。
var pilot_024_repair_window: Dictionary = {}

## 通用攻击窗口（铠威等「攻击被响应→结算后抽1并立即再攻」效果的通用状态，非空即激活）：
## {"owner_player_id", "owner_mech_id"}。窗口期间该机甲只允许发动攻击（含攻击牌/攻击类主动效果/投掷式飞弹），
## 不依赖回合攻击次数；窗口发动的攻击不消耗攻击次数。PvP 锁步各端确定性一致，无需网络同步。
var attack_window: Dictionary = {}

## 攻击窗口待处理触发队列：已结算完成、等待提示玩家「抽1张并立即再攻」的触发列表，
## 每项 {"player_id", "mech_id"}。窗口激活时新的触发暂留队列，窗口关闭后逐条处理（双连/递归串行）。
var attack_window_queue: Array[Dictionary] = []

## 当前待玩家确认的攻击窗口触发（非空即等待确认）：{"player_id", "mech_id"}。
## 由 app_root 弹「抽1张行动牌并立即发动1次攻击/取消」确认窗；确认后经 attack_window_confirm op 双端执行。
var attack_window_pending_prompt: Dictionary = {}

## 铠厉「被响应→抽装备→逐张设置/弃置获金」通用链状态（responded_equip_chain_* helpers，不绑机师）：
## 待处理触发队列（攻击已结算、等待弹确认）：[{player_id, mech_id}]。
## 链激活期间新触发暂留队列，链结束后逐条弹确认（递归/双连串行）。
var responded_equip_queue: Array[Dictionary] = []

## 当前待玩家确认的初始确认（非空即等待确认）：{"player_id", "mech_id"}。
## 由 app_root 弹「是否抽2装备并逐张设置/弃置获金」确认窗；确认后经 responded_equip_confirm op 双端执行。
var responded_equip_pending_confirm: Dictionary = {}

## 活动链（非空即激活）：{"owner_player_id", "owner_mech_id", "card_ids": [...], "index": int}。
## 抽到的装备牌按 index 逐张处理：选槽=set_equipment 标准设置；弃置获金=discard_card + gain_gold(cost)。
var responded_equip_chain: Dictionary = {}

## 铠德「被响应→三选一」通用队列状态（pilot_060_* helpers，不绑机师）：
## 待处理触发队列（攻击已结算、等待弹三选一）：[{player_id, mech_id}]。
## 链激活期间新触发暂留队列，处理完当前弹窗后逐条弹（递归/双连串行）。
var pilot_060_queue: Array[Dictionary] = []

## 当前待玩家选择的三选一触发（非空即等待选择）：{"player_id", "mech_id"}。
## 由 app_root 弹「抽2张行动牌/回复3动力/获得4金币」（底部「取消」=放弃）；
## 确认后经 pilot_060_choice op 双端执行 pilot_060_choose。
var pilot_060_pending_choice: Dictionary = {}

## 回合数（0 = 尚未开始任何回合；首次 start_turn("player") 递增到 1 = 第一回合）
var turn_number: int = 0

## 当前行动玩家 ID
var active_player_id: StringName = &""

## 当前阶段
## &"TURN_START" / &"MAIN" / &"ATTACK" / &"RESPONSE_WINDOW" / &"TURN_END"
var phase: StringName = &""

## 游戏日志
var log: Array[Dictionary] = []

## ID 计数器
var _next_id_counter: int = 0


## ── ID 生成 ──


## 生成全局唯一 ID
func next_id(prefix: String) -> StringName:
	_next_id_counter += 1
	return StringName("%s_%d" % [prefix, _next_id_counter])


## ── 查询方法 ──


## 重置所有运行时状态
func reset_all() -> void:
	players.clear()
	mechs.clear()
	cards.clear()
	attacks.clear()
	damage_contexts.clear()
	map_state = _MapState.new()
	deck_state = _DeckState.new()
	shop_state = _ShopState.new()
	rule_modifiers.clear()
	temp_values.clear()
	current_attack_id = &""
	current_damage_context_id = &""
	pending_custom_effects.clear()
	turn_number = 0
	active_player_id = &""
	phase = &""
	log.clear()
	_next_id_counter = 0


## 获取玩家控制的机甲
func get_mech_for_player(player_id: StringName):
	for mech in mechs.values():
		if mech.owner_player_id == player_id:
			return mech
	return null


## 获取机甲所属的玩家
func get_player_for_mech(mech_id: StringName):
	var mech = mechs.get(mech_id)
	if mech:
		return players.get(mech.owner_player_id)
	return null


## 获取对方的 player_id
func get_opponent_player_id(player_id: StringName) -> StringName:
	for pid: StringName in players:
		if pid != player_id:
			return pid
	return &""


## 获取对方的机甲
func get_opponent_mech(player_id: StringName):
	var opp_id: StringName = get_opponent_player_id(player_id)
	if opp_id:
		return get_mech_for_player(opp_id)
	return null


## 3人 PvP 固定回合顺序（player->enemy->third 循环）。
## 2人时 third 不在 players 中会被跳过，故 get_next_player_id 对 2人同样兼容。
const PVP3_TURN_ORDER: Array[StringName] = [&"player", &"enemy", &"third"]


## 判断玩家是否仍存活（机甲未摧毁且 HP>0）。3人淘汰制用。
func is_player_alive(player_id: StringName) -> bool:
	var mech = get_mech_for_player(player_id)
	if mech == null:
		return false
	return (not mech.destroyed) and mech.current_hp > 0


## 3人轮转：按 PVP3_TURN_ORDER 取 player_id 之后的下一个存活玩家。
## 跳过已淘汰（机甲 destroyed/HP<=0）的玩家；全淘汰返回 &""。
## 兼容 2人：顺序中的 third 若不在 players 自动跳过，2人 enemy<->player 仍正确。
func get_next_player_id(player_id: StringName) -> StringName:
	var order: Array[StringName] = PVP3_TURN_ORDER
	var idx: int = order.find(player_id)
	if idx < 0:
		# 不在固定顺序中：回退到第一个非己存活玩家（2人兼容路径）
		for pid: StringName in players:
			if pid != player_id and is_player_alive(pid):
				return pid
		return &""
	var n: int = order.size()
	for i in range(1, n + 1):
		var cand: StringName = order[(idx + i) % n]
		if players.has(cand) and is_player_alive(cand):
			return cand
	return &""  # 全员淘汰


## 存活玩家数（3人胜利判定：<=1 即结束）。通用，2人时返回 0/1/2。
func alive_player_count() -> int:
	var count: int = 0
	for pid: StringName in players:
		if is_player_alive(pid):
			count += 1
	return count


## 获取机甲最大动力
func get_max_power(mech_id: StringName) -> int:
	var mech = mechs.get(mech_id)
	if mech:
		return mech.max_power
	return 0


## 添加状态效果到目标
func add_status_to_target(target_id: StringName, status: Dictionary) -> void:
	if mechs.has(target_id):
		mechs[target_id].add_status(status)
	elif players.has(target_id):
		players[target_id].statuses.append(status)


## 检查目标是否有指定状态
func has_status(target_id: StringName, status_type: StringName) -> bool:
	if mechs.has(target_id):
		return mechs[target_id].has_status(status_type)
	if players.has(target_id):
		return players[target_id].statuses.any(func(s: Dictionary) -> bool: return s.get("type", &"") == status_type)
	return false


## 从目标移除指定类型的状态，返回被移除的状态列表
func remove_status_from_target(target_id: StringName, status_id: StringName = &"", status_type: StringName = &"", source_card_id: StringName = &"") -> Array:
	var removed: Array = []
	if mechs.has(target_id):
		var mech = mechs[target_id]
		if status_id != &"":
			removed = mech.statuses.filter(func(s: Dictionary) -> bool: return s.get("status_id", &"") == status_id)
			mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool: return s.get("status_id", &"") != status_id)
		elif status_type != &"":
			# source_card_id 指定时只移除该来源施加的状态（泰格 pilot_040 弃装解锁：
			# 不误删目标身上其他来源的 LOCKED，如拘束钩爪/预判/其他机师）。
			if source_card_id != &"":
				var src_str: String = String(source_card_id)
				removed = mech.statuses.filter(func(s: Dictionary) -> bool: return s.get("type", &"") == status_type and String(s.get("source_card_id", &"")) == src_str)
				mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool: return not (s.get("type", &"") == status_type and String(s.get("source_card_id", &"")) == src_str))
			else:
				removed = mech.statuses.filter(func(s: Dictionary) -> bool: return s.get("type", &"") == status_type)
				mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool: return s.get("type", &"") != status_type)
	elif players.has(target_id):
		var player = players[target_id]
		if status_id != &"":
			removed = player.statuses.filter(func(s: Dictionary) -> bool: return s.get("status_id", &"") == status_id)
			player.statuses = player.statuses.filter(func(s: Dictionary) -> bool: return s.get("status_id", &"") != status_id)
		elif status_type != &"":
			if source_card_id != &"":
				var src_str2: String = String(source_card_id)
				removed = player.statuses.filter(func(s: Dictionary) -> bool: return s.get("type", &"") == status_type and String(s.get("source_card_id", &"")) == src_str2)
				player.statuses = player.statuses.filter(func(s: Dictionary) -> bool: return not (s.get("type", &"") == status_type and String(s.get("source_card_id", &"")) == src_str2))
			else:
				removed = player.statuses.filter(func(s: Dictionary) -> bool: return s.get("type", &"") == status_type)
				player.statuses = player.statuses.filter(func(s: Dictionary) -> bool: return s.get("type", &"") != status_type)
	return removed


## 摧毁机甲
func destroy_mech(mech_id: StringName, source: String) -> void:
	if mechs.has(mech_id):
		mechs[mech_id].destroyed = true
		mechs[mech_id].current_hp = 0
		log.append({"event": "mech_destroyed", "mech_id": mech_id, "source": source})


## 写入日志
func write_log(event_type: StringName, data: Dictionary = {}) -> void:
	var entry: Dictionary = {"event": event_type}
	entry.merge(data)
	log.append(entry)


## 获取指定卡牌实例
func get_card(instance_id: StringName):
	return cards.get(instance_id)


## ── 卡牌区域操作 ──


## 从所有区域中移除一张卡牌（手牌、牌堆、槽位等）
func remove_card_from_all_zones(card_id: StringName) -> void:
	var card = cards.get(card_id)
	if card == null:
		return

	# 从玩家手牌中移除
	for player_id: StringName in players:
		var player = players[player_id]
		player.action_hand.erase(card_id)
		player.equipment_hand.erase(card_id)

	# 从牌堆中移除
	if deck_state != null:
		deck_state.action_deck.erase(card_id)
		deck_state.equipment_deck.erase(card_id)
		deck_state.advanced_equipment_deck.erase(card_id)
		deck_state.pilot_deck.erase(card_id)
		deck_state.event_deck.erase(card_id)
		deck_state.action_discard_pile.erase(card_id)
		deck_state.equipment_discard_pile.erase(card_id)

	# 从机甲槽位中移除
	for mech_id: StringName in mechs:
		var mech = mechs[mech_id]
		for slot_id: StringName in mech.slots:
			var slot = mech.slots[slot_id]
			if slot.equipped_card != null and slot.equipped_card.instance_id == card_id:
				slot.equipped_card = null


## 将卡牌移到玩家手牌
func move_card_to_player_hand(player_id: StringName, card_id: StringName) -> void:
	var player = players.get(player_id)
	var card = cards.get(card_id)
	if player == null or card == null:
		return

	remove_card_from_all_zones(card_id)

	if card.def != null:
		if card.def.card_kind == &"action":
			player.action_hand.append(card_id)
			card.zone = &"action_hand"
		elif card.def.card_kind == &"equipment":
			player.equipment_hand.append(card_id)
			card.zone = &"equipment_hand"
		else:
			player.action_hand.append(card_id)
			card.zone = &"action_hand"
	else:
		player.action_hand.append(card_id)
		card.zone = &"action_hand"

	card.owner_player_id = player_id


## 将卡牌移到虚空区（虚拟牌打完后移除）
func move_card_to_void(card_id: StringName) -> void:
	var card = cards.get(card_id)
	if card:
		remove_card_from_all_zones(card_id)
		card.zone = &"void"
		card.slot_id = &""
		card.mech_id = &""


## ── 损伤相关 ──


## 玩家选择损伤槽位（当前简化为默认选择）
func ask_player_choose_damage_slot(_chooser_player_id: StringName, target_mech_id: StringName, _prefer_part_slot: bool = false) -> StringName:
	var mech = mechs.get(target_mech_id)
	if mech == null:
		return &""
	# 默认策略：优先有装备的部件槽 → 武器槽 → 空槽
	var candidates: Array[StringName] = []
	# 部件槽
	var part_slots: Array[StringName] = [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]
	for slot_id: StringName in part_slots:
		if mech.slots.has(slot_id) and mech.slots[slot_id].equipped_card != null:
			candidates.append(slot_id)
	# 武器槽
	for slot_id: StringName in [&"weapon_1", &"weapon_2"]:
		if mech.slots.has(slot_id) and mech.slots[slot_id].equipped_card != null:
			candidates.append(slot_id)
	# 空部件槽
	for slot_id: StringName in part_slots:
		if mech.slots.has(slot_id) and mech.slots[slot_id].equipped_card == null:
			candidates.append(slot_id)
	# 其他空槽
	for slot_id: StringName in mech.slots:
		if not slot_id in candidates and mech.slots[slot_id].equipped_card == null:
			candidates.append(slot_id)

	if candidates.is_empty():
		return &"躯干"  # 兜底
	return candidates[0]


## 在指定槽位放置一枚损伤标记
func place_one_damage_token(mech_id: StringName, slot_id: StringName) -> void:
	var mech = mechs.get(mech_id)
	if mech == null or not mech.slots.has(slot_id):
		return
	var slot = mech.slots[slot_id]
	# 损伤真正设置在区域上（region_damage_tokens，装备弃置后仍保留；get_effective_armor 只减 region）。
	# 装备牌同时记一份 damage_tokens 用于耐久损坏判定（is_equipment_broken）。
	# 与 DamageTokenService.place_one_token_at_slot 一致（region + card 双计）。
	# 此前仅加到 card 不加 region，致转移/固定置损伤路径下卡损坏弃置后区域损伤丢失。
	slot.region_damage_tokens += 1
	if slot.equipped_card != null:
		slot.equipped_card.damage_tokens += 1
	# 损伤变化后重算动力上限（effect_016/021/048 派生动力随损伤变，max_power 需同步）
	mech.recalc_power_limits()
	# 记录逐枚放置 slot 到临时日志，供 damage_change_action._step_settle 回写父 attack
	# 的 damage_placement_log（effect_101 同区 / effect_119 非同区判定）。
	# 仅在 damage_change 期间记录（guard flag），避免 effect_101 自身追加的 +2 损伤
	# （在 ATTACK_SETTLE，damage_change 已结算）污染日志。所有放置路径
	# （人类逐点/自动/转移/固定/effect 追加）最终都汇聚到此函数，故集中记录。
	if bool(temp_values.get("logging_damage_placement", false)):
		if not temp_values.has("last_damage_placement_log"):
			temp_values["last_damage_placement_log"] = []
		temp_values["last_damage_placement_log"].append(String(slot_id))


## ── 光环系统 ──


## 为目标启用光环
func enable_aura_for_target(aura_id: StringName, target_id: StringName) -> void:
	if mechs.has(target_id):
		var mech = mechs[target_id]
		mech.statuses.append({
			"status_id": aura_id,
			"type": &"AURA",
			"aura_id": aura_id,
			"enabled": true,
		})


## 为目标禁用光环
func disable_aura_for_target(aura_id: StringName, target_id: StringName) -> void:
	if mechs.has(target_id):
		var mech = mechs[target_id]
		mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
			return not (s.get("type", &"") == &"AURA" and s.get("aura_id", &"") == aura_id)
		)


## ── 设置卡牌到槽位 ──


## 将卡牌设置到机甲槽位
func set_card_to_slot(card_id: StringName, mech_id: StringName, slot_id: StringName, face_down: bool = false) -> void:
	var card = cards.get(card_id)
	var mech = mechs.get(mech_id)
	if card == null or mech == null:
		return
	if not mech.slots.has(slot_id):
		return

	# 从当前位置移除
	remove_card_from_all_zones(card_id)

	# 设置新位置
	card.zone = &"equipment_slot"
	card.slot_id = slot_id
	card.mech_id = mech_id
	card.face_down = face_down

	# 如果目标槽位已有旧装备，先弃置
	var slot = mech.slots[slot_id]
	if slot.equipped_card != null:
		var old_card = slot.equipped_card
		old_card.zone = &"discard"
		old_card.slot_id = &""
		old_card.mech_id = &""
		if deck_state != null:
			deck_state.equipment_discard_pile.append(old_card.instance_id)

	# 装备新卡
	slot.equipped_card = card
