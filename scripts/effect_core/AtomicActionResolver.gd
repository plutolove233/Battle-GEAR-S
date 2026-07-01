## AtomicActionResolver.gd — 原子动作分发器
##
## 将效果动作字典转换为 GameActions 方法调用。
## 从 Effect全牌表.xlsx "Resolver完整代码" 适配而来。
## 所有 GameContext 引用替代了原设计的 Autoload 单例。
extends RefCounted
class_name AtomicActionResolver


## 解析单个动作字典，分发到 GameActions 对应方法
## P0-0: 添加诊断日志
static func resolve(binding: EffectBinding, payload: Dictionary, action: Dictionary, context: GameContext) -> void:
	if context == null or context.game_actions == null:
		push_error("AtomicActionResolver: context 或 game_actions 未初始化")
		return

	var action_type: StringName = action.get("type", &"")
	var params: Dictionary = _resolve_params(action.get("params", {}), binding, payload)

	# P0-0: 诊断日志
	print("[AtomicActionResolver] action=%s params=%s" % [String(action_type), JSON.stringify(params).left(120)])

	match action_type:
		# ── 攻击相关 ──
		&"START_ATTACK_DECLARE_ATTACK":
			context.game_actions.start_attack_declare_attack(params)

		&"MODIFY_ATTACK_POWER":
			context.game_actions.modify_attack_power(params)

		&"MODIFY_ATTACK_RANGE":
			context.game_actions.modify_attack_range(params)

		&"NEGATE_ATTACK":
			context.game_actions.negate_attack(params)

		&"SET_ATTACK_UNNEGATABLE":
			context.game_actions.set_attack_unnegatable(params)

		&"APPLY_CANNOT_RESPOND":
			context.game_actions.apply_cannot_respond(params)

		&"APPLY_OR_CHECK_LOCKED":
			context.game_actions.apply_or_check_locked(params)

		&"OPEN_OR_USE_RESPONSE":
			context.game_actions.open_or_use_response(params)

		&"CONSUME_NEXT_ATTACK_POWER_BUFF":
			context.game_actions.consume_next_attack_power_buff(params)

		# ── 属性修改 ──
		&"MODIFY_ARMOR":
			context.game_actions.modify_armor(params)

		&"MODIFY_MECH_POWER":
			context.game_actions.modify_mech_power(params)

		&"SPEND_POWER":
			context.game_actions.spend_power(params)

		&"RESTORE_POWER":
			context.game_actions.restore_power(params)

		&"RESTORE_WEAPON_POWER":
			context.game_actions.restore_weapon_power(params)

		# ── 抽牌/获得 ──
		&"DRAW_ACTION":
			context.game_actions.draw_action_cards(params)

		&"DRAW_EQUIPMENT":
			context.game_actions.draw_equipment_cards(params)

		&"GAIN_SPECIFIC_CARD":
			context.game_actions.gain_specific_card(params)

		&"RANDOM_DRAW_FROM_DISCARD_OR_DECK":
			context.game_actions.random_draw_from_discard_or_deck(params)

		&"TRANSFER_ACTION_CARDS":
			context.game_actions.transfer_action_cards(params)

		&"GAIN_GOLD":
			context.game_actions.gain_gold(params)

		&"SPEND_GOLD":
			context.game_actions.spend_gold(params)

		&"SHOP_BUY_MODIFIER":
			context.game_actions.shop_buy_modifier(params)

		# ── 伤害/损伤 ──
		&"DEAL_DAMAGE":
			context.game_actions.deal_damage(params)

		&"PLACE_DAMAGE_TOKENS":
			context.game_actions.place_damage_tokens(params)

		&"MODIFY_DAMAGE_TOKENS":
			context.game_actions.modify_damage_tokens(params)

		&"REMOVE_DAMAGE_TOKENS":
			context.game_actions.remove_damage_tokens(params)

		&"REDIRECT_DAMAGE_TOKENS":
			context.game_actions.redirect_damage_tokens(params)

		&"HEAL_HP":
			context.game_actions.heal_hp(params)

		# ── 移动/设置 ──
		&"MOVE_MECH":
			context.game_actions.move_mech(params)

		&"SET_CARD_TO_SLOT":
			context.game_actions.set_card_to_slot(params)

		&"PLACE_OR_TRIGGER_TRAP":
			context.game_actions.place_or_trigger_trap(params)

		# ── 弃牌/破坏 ──
		&"DISCARD_CARD":
			context.game_actions.discard_card(params)

		&"DISCARD_ACTION_CARD":
			context.game_actions.discard_action_card(params)

		&"DESTROY_CARD":
			context.game_actions.destroy_card(params)

		&"PLAY_AS_CARD":
			context.game_actions.play_as_card(params)

		# ── 状态 ──
		&"ADD_STATUS":
			context.game_actions.add_status(params)

		&"REMOVE_STATUS":
			context.game_actions.remove_status(params)

		&"ADD_RULE_MODIFIER":
			context.game_actions.add_rule_modifier(params)

		# ── 事件/计时 ──
		&"REDUCE_EVENT_TIMER":
			context.game_actions.reduce_event_timer(params)

		&"SET_EVENT_TIMER":
			context.game_actions.set_event_timer(params)

		&"TRACK_EVENT_PROGRESS":
			context.game_actions.track_event_progress(params)

		# ── 其他 ──
		&"REVEAL_OR_PEEK_CARD":
			context.game_actions.reveal_or_peek_card(params)

		&"ROLL_D6":
			context.game_actions.roll_d6(params)

		&"TOGGLE_AURA_TARGET":
			context.game_actions.toggle_aura_target(params)

		&"CUSTOM_EFFECT_CHECK_TEXT":
			context.game_actions.custom_effect_check_text(params)

		# ── 新增动作（批次3原语扩展） ──
		&"APPLY_ENERGY_TO_WEAPON":
			context.game_actions.apply_energy_to_weapon(params)

		&"STEAL_ACTION_CARD":
			context.game_actions.steal_action_card(params)

		&"RANDOM_DISCARD_ACTION_CARD":
			context.game_actions.random_discard_action_card(params)

		&"PLACE_TRAP_MARKER":
			context.game_actions.place_trap_marker(params)

		&"CONVERT_WEAPON_KIND":
			context.game_actions.convert_weapon_kind(params)

		# ── 新增动作（阶段1原语扩展：280+效果支持） ──
		&"PLACE_DAMAGE_TOKENS_ON_SLOT":
			context.game_actions.place_damage_tokens_on_slot(params)

		&"PLAY_CARD_AS_TYPE":
			context.game_actions.play_card_as_type(params)

		&"MODIFY_ACTION_HAND_LIMIT":
			context.game_actions.modify_action_hand_limit(params)

		&"MODIFY_ATTACK_COUNT":
			context.game_actions.modify_attack_count(params)

		&"INCREMENT_VARIABLE":
			context.game_actions.increment_variable(params)

		&"CHOOSE_ONE":
			context.game_actions.choose_one(params)

		&"FORCE_MECH_ACTION":
			context.game_actions.force_mech_action(params)

		&"TREAT_CARD_AS_NAMED_TYPE":
			context.game_actions.treat_card_as_named_type(params)

		&"GRANT_EFFECT_TO_FACTION":
			context.game_actions.grant_effect_to_faction(params)

		&"TOGGLE_EFFECT_ON_MECH":
			context.game_actions.toggle_effect_on_mech(params)

		&"NEGATE_EQUIPMENT_EFFECT":
			context.game_actions.negate_equipment_effect(params)

		&"MOVE_WITHOUT_POWER":
			context.game_actions.move_without_power(params)

		&"MODIFY_WEAPON_POWER":
			context.game_actions.modify_weapon_power(params)

		&"SET_WEAPON_STATS":
			context.game_actions.set_weapon_stats(params)

		&"CONVERT_ARMOR_TO_POWER":
			context.game_actions.convert_armor_to_power(params)

		&"REDIRECT_HEAL_TO_DAMAGE":
			context.game_actions.redirect_heal_to_damage(params)

		&"REDIRECT_REMOVE_TO_PLACE_TOKENS":
			context.game_actions.redirect_remove_to_place_tokens(params)

		&"MODIFY_NEXT_DAMAGE_DEALT":
			context.game_actions.modify_next_damage_dealt(params)

		&"ADD_WEAPON_TAG":
			context.game_actions.add_weapon_tag(params)

		&"DECLARE_CARD_TYPE":
			context.game_actions.declare_card_type(params)

		&"DRAW_ADVANCED_EQUIPMENT":
			context.game_actions.draw_advanced_equipment(params)

		&"PLACE_CARD_IN_DECK_FACE_UP":
			context.game_actions.place_card_in_deck_face_up(params)

		# ── 新增动作（阶段4机师效果支持） ──
		&"SWAP_HAND_LIMIT_AND_ATTACK_COUNT":
			context.game_actions.swap_hand_limit_and_attack_count(params)

		_:
			push_error("AtomicActionResolver: 未知原子动作 %s" % action_type)


## 解析动作参数中的变量引用
## 支持: $payload.xxx, $source.card_instance_id, $source.mech_id, $source.owner_player_id
static func _resolve_params(raw_params: Dictionary, binding: EffectBinding, payload: Dictionary) -> Dictionary:
	var result: Dictionary = {}

	for key in raw_params.keys():
		result[key] = _resolve_value(raw_params[key], binding, payload)

	# 自动注入来源信息（如果参数中未指定）
	if not result.has("source_card_id"):
		result["source_card_id"] = binding.get_source_instance_id()
	if not result.has("source_mech_id"):
		result["source_mech_id"] = binding.get_source_mech_id()
	if not result.has("player_id"):
		result["player_id"] = binding.get_owner_player_id()
	# 自动注入玩家选择的对象（装备牌/行动牌均可指定对象）
	# 武器：优先 selected_weapon_id，再 weapon_id
	if not result.has("weapon_id"):
		var sel_weapon = payload.get("selected_weapon_id", payload.get("weapon_id", &""))
		if sel_weapon != null and String(sel_weapon) != "":
			result["weapon_id"] = sel_weapon
	# 目标机甲：优先 target_id / target_mech_id；未指定时默认以我方机甲为对象
	if not result.has("target_id"):
		var sel_target = payload.get("target_id", payload.get("target_mech_id", &""))
		if sel_target != null and String(sel_target) != "":
			result["target_id"] = sel_target
		else:
			result["target_id"] = binding.get_source_mech_id()

	return result


## 递归解析参数值中的变量引用
static func _resolve_value(value, binding: EffectBinding, payload):
	# 数组：逐项解析
	if typeof(value) == TYPE_ARRAY:
		var arr: Array = []
		for v in value:
			arr.append(_resolve_value(v, binding, payload))
		return arr

	# 字典：递归解析
	if typeof(value) == TYPE_DICTIONARY:
		return _resolve_params(value, binding, payload)

	# 非字符串：直接返回
	if typeof(value) != TYPE_STRING:
		return value

	var s: String = String(value)

	# $payload.xxx → 从 hook payload 中取值
	if s.begins_with("$payload."):
		var key: String = s.replace("$payload.", "")
		return payload.get(key)

	# $source.card_instance_id → 效果来源牌的 instance_id
	if s == "$source.card_instance_id":
		return binding.get_source_instance_id()

	# $source.mech_id → 效果来源牌所属机甲
	if s == "$source.mech_id":
		return binding.get_source_mech_id()

	# $source.owner_player_id → 效果来源牌的拥有者
	if s == "$source.owner_player_id":
		return binding.get_owner_player_id()

	# 无匹配：原样返回
	return value


## 检查动作列表中是否有需要玩家选择弃置目标的弃牌动作
## 返回空字典表示不需要选择，返回 {"needs": "discard_select", ...} 表示需要暂停等待玩家输入
static func check_needs_discard_select(binding: EffectBinding, payload: Dictionary, actions: Array[Dictionary], context: GameContext) -> Dictionary:
	for action: Dictionary in actions:
		var action_type: StringName = action.get("type", &"")
		if action_type != &"DISCARD_ACTION_CARD" and action_type != &"STEAL_ACTION_CARD":
			continue

		var params: Dictionary = _resolve_params(action.get("params", {}), binding, payload)
		var count: int = int(params.get("count", 1))
		if count <= 0:
			continue

		# 如果已指定具体牌ID，无需选择
		if params.get("card_id", &"") != &"" or params.get("selected_action_card_id", &"") != &"":
			continue

		# 如果 payload 中已提供选择的牌ID列表，无需再选
		var selected_ids: Array = payload.get("selected_action_card_ids", [])
		if selected_ids.size() >= count:
			continue

		# 确定弃牌对象的玩家 ID
		var discard_player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
		var executor_player_id: StringName = binding.get_owner_player_id()

		# 解析 from_target
		if bool(params.get("from_target", false)):
			var target_id: StringName = params.get("target_id", &"")
			if target_id == &"" and context.game_state.current_attack_id != &"":
				var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
				target_id = attack.get("target_id", &"")
			var target_player = context.game_state.get_player_for_mech(target_id)
			if target_player:
				discard_player_id = target_player.player_id

		# 解析 from_attacker
		if bool(params.get("from_attacker", false)):
			var attacker_id: StringName = params.get("attacker_id", &"")
			if attacker_id == &"" and context.game_state.current_attack_id != &"":
				var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
				attacker_id = attack.get("attacker_id", &"")
			var attacker_player = context.game_state.get_player_for_mech(attacker_id)
			if attacker_player:
				discard_player_id = attacker_player.player_id

		if discard_player_id == &"":
			continue

		# 明牌判断：弃自己的牌为明牌，弃对手的牌为暗牌（除非对手手牌已明牌）
		var face_up: bool = (discard_player_id == executor_player_id)
		if not face_up:
			var discard_player_state = context.game_state.players.get(discard_player_id)
			if discard_player_state != null and discard_player_state.hand_revealed:
				face_up = true

		var player_state = context.game_state.players.get(discard_player_id)
		if player_state == null:
			continue
		if player_state.action_hand.size() < count:
			continue

		return {
			"needs": &"discard_select",
			"discard_player_id": discard_player_id,
			"count": count,
			"face_up": face_up,
			"card_type_filter": params.get("card_type_filter", &""),
		}

	return {}
