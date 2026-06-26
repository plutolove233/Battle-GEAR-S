## AtomicActionResolver.gd — 原子动作分发器
##
## 将效果动作字典转换为 GameActions 方法调用。
## 从 Effect全牌表.xlsx "Resolver完整代码" 适配而来。
## 所有 GameContext 引用替代了原设计的 Autoload 单例。
extends RefCounted
class_name AtomicActionResolver


## 解析单个动作字典，分发到 GameActions 对应方法
static func resolve(binding: EffectBinding, payload: Dictionary, action: Dictionary, context: GameContext) -> void:
	if context == null or context.game_actions == null:
		push_error("AtomicActionResolver: context 或 game_actions 未初始化")
		return

	var action_type: StringName = action.get("type", &"")
	var params: Dictionary = _resolve_params(action.get("params", {}), binding, payload)

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
