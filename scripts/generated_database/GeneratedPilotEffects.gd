## GeneratedPilotEffects.gd — 机师牌效果定义生成器
##
## 包含全部 121 个机师牌效果定义，分4批实装：
## 批次M：N稀有度机师（pilot_059-088，33效果）
## 批次L：R稀有度机师（pilot_029-058，38效果）
## 批次K：SR稀有度机师（pilot_011-028，28效果）
## 批次J：SSR稀有度机师（pilot_001-010，22效果）
##
## 所有效果遵循统一执行链：
## Service → Hook → EffectEngine → ConditionChecker → TargetChecker → CostChecker → AtomicActionResolver → GameActions
class_name GeneratedPilotEffects
extends RefCounted

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 构建所有机师效果定义，返回 { effect_id: CardEffect }
static func build_pilot_effects() -> Dictionary:
	var effects: Dictionary = {}

	# ═══════════════════════════════════════════
	# 批次M：N稀有度机师效果（pilot_059-088）
	# ═══════════════════════════════════════════

	# ── pilot_059 薇尔：损伤数分支选择 ──
	# 效果1a：损伤低于4 → 获得3金币
	var pilot_059_effect_01a := CardEffect.new()
	pilot_059_effect_01a.effect_id = &"pilot_059_effect_01a"
	pilot_059_effect_01a.display_name = "薇尔-损伤低获金"
	pilot_059_effect_01a.mode = _EffectConst.MODE_ACTIVE
	pilot_059_effect_01a.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_059_effect_01a.priority = 100
	pilot_059_effect_01a.once_per_turn_key = &"pilot_059_effect_01"
	pilot_059_effect_01a.conditions = [
		{"op": &"SELF_DAMAGE_TOKENS_BELOW", "threshold": 4},
		{"op": &"IS_OWNER_MAIN_PHASE"},
	]
	pilot_059_effect_01a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_059_effect_01a.costs = []
	pilot_059_effect_01a.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 3}},
	]
	pilot_059_effect_01a.description = "我方回合开始时，若机甲损伤数低于4则可以获得3金币。"
	effects[pilot_059_effect_01a.effect_id] = pilot_059_effect_01a

	# 效果1b：损伤等于4 → 视为使用1张补给
	var pilot_059_effect_01b := CardEffect.new()
	pilot_059_effect_01b.effect_id = &"pilot_059_effect_01b"
	pilot_059_effect_01b.display_name = "薇尔-损伤等视为补给"
	pilot_059_effect_01b.mode = _EffectConst.MODE_ACTIVE
	pilot_059_effect_01b.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_059_effect_01b.priority = 100
	pilot_059_effect_01b.once_per_turn_key = &"pilot_059_effect_01"
	pilot_059_effect_01b.conditions = [
		{"op": &"SELF_DAMAGE_TOKENS_EQUALS", "threshold": 4},
		{"op": &"IS_OWNER_MAIN_PHASE"},
	]
	pilot_059_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_059_effect_01b.costs = []
	pilot_059_effect_01b.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"补给"}},
	]
	pilot_059_effect_01b.description = "我方回合开始时，若机甲损伤数等于4则可以视为使用1张补给。"
	effects[pilot_059_effect_01b.effect_id] = pilot_059_effect_01b

	# 效果1c：损伤高于4 → 移去最多2损伤
	var pilot_059_effect_01c := CardEffect.new()
	pilot_059_effect_01c.effect_id = &"pilot_059_effect_01c"
	pilot_059_effect_01c.display_name = "薇尔-损伤高移去2损伤"
	pilot_059_effect_01c.mode = _EffectConst.MODE_ACTIVE
	pilot_059_effect_01c.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_059_effect_01c.priority = 100
	pilot_059_effect_01c.once_per_turn_key = &"pilot_059_effect_01"
	pilot_059_effect_01c.conditions = [
		{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 4},
		{"op": &"IS_OWNER_MAIN_PHASE"},
	]
	pilot_059_effect_01c.target_rules = [{"rule": &"CHOOSE_OWN_SLOT"}]
	pilot_059_effect_01c.costs = []
	pilot_059_effect_01c.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount": 2}},
	]
	pilot_059_effect_01c.description = "我方回合开始时，若机甲损伤数大于4则可以移去最多2损伤。"
	effects[pilot_059_effect_01c.effect_id] = pilot_059_effect_01c

	# ── pilot_060 铠德：攻击未命中选择其一 ──
	# 效果01a：抽2张行动牌
	var pilot_060_effect_01a := CardEffect.new()
	pilot_060_effect_01a.effect_id = &"pilot_060_effect_01a"
	pilot_060_effect_01a.display_name = "铠德-未命中抽2"
	pilot_060_effect_01a.mode = _EffectConst.MODE_PASSIVE
	pilot_060_effect_01a.hook = _EffectConst.HOOK_ATTACK_MISS
	pilot_060_effect_01a.priority = 90
	pilot_060_effect_01a.once_per_turn_key = &"pilot_060_effect_01"
	pilot_060_effect_01a.conditions = [
		{"op": &"PAYLOAD_ATTACK_MISS"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_060_effect_01a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_060_effect_01a.costs = []
	pilot_060_effect_01a.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
	]
	pilot_060_effect_01a.description = "若发动的攻击没有命中，则可以选择抽2张行动牌。"
	effects[pilot_060_effect_01a.effect_id] = pilot_060_effect_01a

	# 效果01b：回复3动力
	var pilot_060_effect_01b := CardEffect.new()
	pilot_060_effect_01b.effect_id = &"pilot_060_effect_01b"
	pilot_060_effect_01b.display_name = "铠德-未命中回3动力"
	pilot_060_effect_01b.mode = _EffectConst.MODE_PASSIVE
	pilot_060_effect_01b.hook = _EffectConst.HOOK_ATTACK_MISS
	pilot_060_effect_01b.priority = 90
	pilot_060_effect_01b.once_per_turn_key = &"pilot_060_effect_01"
	pilot_060_effect_01b.conditions = [
		{"op": &"PAYLOAD_ATTACK_MISS"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_060_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_060_effect_01b.costs = []
	pilot_060_effect_01b.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 3}},
	]
	pilot_060_effect_01b.description = "若发动的攻击没有命中，则可以选择回复3动力。"
	effects[pilot_060_effect_01b.effect_id] = pilot_060_effect_01b

	# 效果01c：获得4金币
	var pilot_060_effect_01c := CardEffect.new()
	pilot_060_effect_01c.effect_id = &"pilot_060_effect_01c"
	pilot_060_effect_01c.display_name = "铠德-未命中获4金"
	pilot_060_effect_01c.mode = _EffectConst.MODE_PASSIVE
	pilot_060_effect_01c.hook = _EffectConst.HOOK_ATTACK_MISS
	pilot_060_effect_01c.priority = 90
	pilot_060_effect_01c.once_per_turn_key = &"pilot_060_effect_01"
	pilot_060_effect_01c.conditions = [
		{"op": &"PAYLOAD_ATTACK_MISS"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_060_effect_01c.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_060_effect_01c.costs = []
	pilot_060_effect_01c.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 4}},
	]
	pilot_060_effect_01c.description = "若发动的攻击没有命中，则可以选择获得4金币。"
	effects[pilot_060_effect_01c.effect_id] = pilot_060_effect_01c

	# ── pilot_061 艾希：额外抽牌后交给其他机甲 ──
	var pilot_061_effect_01 := CardEffect.new()
	pilot_061_effect_01.effect_id = &"pilot_061_effect_01"
	pilot_061_effect_01.display_name = "艾希-抽2交其他机甲"
	pilot_061_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_061_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_061_effect_01.priority = 90
	pilot_061_effect_01.once_per_turn_key = &""
	pilot_061_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_061_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 3}]
	pilot_061_effect_01.costs = []
	pilot_061_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
		{"type": &"TRANSFER_ACTION_CARDS", "params": {"count": 2, "range": 3}},
	]
	pilot_061_effect_01.description = "我方回合开始时，额外抽2张行动牌，之后可以将我方最多2张行动牌交给3格范围内的其他机甲。"
	effects[pilot_061_effect_01.effect_id] = pilot_061_effect_01

	# ── pilot_062 洛尔恩：2张当作掩护使用 ──
	var pilot_062_effect_01 := CardEffect.new()
	pilot_062_effect_01.effect_id = &"pilot_062_effect_01"
	pilot_062_effect_01.display_name = "洛尔恩-当作掩护"
	pilot_062_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_062_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_062_effect_01.priority = 100
	pilot_062_effect_01.once_per_turn_key = &"pilot_062_effect_01"
	pilot_062_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_062_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_062_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_062_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"掩护"}},
	]
	pilot_062_effect_01.description = "每回合1次，可以将2张行动牌当作掩护使用。"
	effects[pilot_062_effect_01.effect_id] = pilot_062_effect_01

	# pilot_062效果02：掩护消除额外效果并视为进攻
	var pilot_062_effect_02 := CardEffect.new()
	pilot_062_effect_02.effect_id = &"pilot_062_effect_02"
	pilot_062_effect_02.display_name = "洛尔恩-掩护视为进攻"
	pilot_062_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_062_effect_02.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	pilot_062_effect_02.priority = 80
	pilot_062_effect_02.once_per_turn_key = &""
	pilot_062_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"掩护"},
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_062_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_062_effect_02.costs = []
	pilot_062_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_062_effect_02",
			"text": "我方使用的掩护获得以下效果：消除该攻击的额外效果，视为进攻。",
		}},
	]
	pilot_062_effect_02.description = "我方使用的掩护获得以下效果：消除该攻击的额外效果，视为进攻。"
	effects[pilot_062_effect_02.effect_id] = pilot_062_effect_02

	# ── pilot_063 布彻尔：1张当作进攻使用 ──
	var pilot_063_effect_01 := CardEffect.new()
	pilot_063_effect_01.effect_id = &"pilot_063_effect_01"
	pilot_063_effect_01.display_name = "布彻尔-当作进攻"
	pilot_063_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_063_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_063_effect_01.priority = 100
	pilot_063_effect_01.once_per_turn_key = &"pilot_063_effect_01"
	pilot_063_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_063_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_063_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_063_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"进攻"}},
	]
	pilot_063_effect_01.description = "每回合1次，可以将1张行动牌当作进攻使用。"
	effects[pilot_063_effect_01.effect_id] = pilot_063_effect_01

	# pilot_063效果02：进攻被响应则抽2/未被响应则弃置1
	var pilot_063_effect_02 := CardEffect.new()
	pilot_063_effect_02.effect_id = &"pilot_063_effect_02"
	pilot_063_effect_02.display_name = "布彻尔-进攻加成"
	pilot_063_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_063_effect_02.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	pilot_063_effect_02.priority = 80
	pilot_063_effect_02.once_per_turn_key = &""
	pilot_063_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_063_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_063_effect_02.costs = []
	pilot_063_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_063_effect_02",
			"text": "本次攻击被响应则抽2张行动牌，未被响应则弃置目标1张行动牌。",
		}},
	]
	pilot_063_effect_02.description = "我方使用的进攻获得以下效果：本次攻击被响应则抽2张行动牌，未被响应则弃置目标1张行动牌。"
	effects[pilot_063_effect_02.effect_id] = pilot_063_effect_02

	# ── pilot_064 柏格：弃置装备牌获金抽牌 ──
	var pilot_064_effect_01 := CardEffect.new()
	pilot_064_effect_01.effect_id = &"pilot_064_effect_01"
	pilot_064_effect_01.display_name = "柏格-弃装获金抽装"
	pilot_064_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_064_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_064_effect_01.priority = 100
	pilot_064_effect_01.once_per_turn_key = &"pilot_064_effect_01"
	pilot_064_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_064_effect_01.target_rules = [{"rule": &"CHOOSE_OWN_EQUIPMENT_IN_SLOT"}]
	pilot_064_effect_01.costs = [
		{"cost_type": &"DISCARD_EQUIPMENT_CARD", "count": 1},
	]
	pilot_064_effect_01.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 2}},
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_064_weapon_bonus",
			"text": "若弃置的是武器牌则再抽1张行动牌。",
		}},
	]
	pilot_064_effect_01.description = "我方回合1次，可以弃置1张未设置的装备牌，获得2金币并抽1张装备牌，若弃置的是武器牌则可再抽1张行动牌。"
	effects[pilot_064_effect_01.effect_id] = pilot_064_effect_01

	# ── pilot_065 柔嘉：牌堆顶翻看（CUSTOM） ──
	var pilot_065_effect_01 := CardEffect.new()
	pilot_065_effect_01.effect_id = &"pilot_065_effect_01"
	pilot_065_effect_01.display_name = "柔嘉-牌堆顶翻看"
	pilot_065_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_065_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_065_effect_01.priority = 100
	pilot_065_effect_01.once_per_turn_key = &"pilot_065_effect_01"
	pilot_065_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_065_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_065_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_065_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_065_effect_01",
			"text": "3格范围内的机甲抽取行动牌前，我方可以弃置1张行动牌，翻开行动牌堆顶3张牌，弃置其中的任意牌，剩下的放回牌堆顶。",
		}},
	]
	pilot_065_effect_01.description = "每回合1次，3格范围内的机甲抽取行动牌前，我方可以弃置1张行动牌，翻开行动牌堆顶3张牌，弃置其中的任意牌，剩下的放回牌堆顶。"
	effects[pilot_065_effect_01.effect_id] = pilot_065_effect_01

	# ── pilot_066 骇客：移动后查看+条件回复 ──
	var pilot_066_effect_01 := CardEffect.new()
	pilot_066_effect_01.effect_id = &"pilot_066_effect_01"
	pilot_066_effect_01.display_name = "骇客-移动查看加成"
	pilot_066_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_066_effect_01.hook = _EffectConst.HOOK_MECH_MOVED
	pilot_066_effect_01.priority = 90
	pilot_066_effect_01.once_per_turn_key = &"pilot_066_effect_01"  # 每回合2次
	pilot_066_effect_01.conditions = [
		{"op": &"MOVED_DISTANCE_THIS_TURN_ABOVE", "threshold": 1},
	]
	pilot_066_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 3}]
	pilot_066_effect_01.costs = []
	pilot_066_effect_01.actions = [
		{"type": &"REVEAL_OR_PEEK_CARD", "params": {"mode": &"peek"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_066_effect_01",
			"text": "移动后可以查看3格范围内1台其他机甲的1张随机行动牌。若该牌是攻击牌，我方回复2动力，本回合攻击次数+1。",
		}},
	]
	pilot_066_effect_01.description = "我方回合2次，移动后可以查看3格范围内1台其他机甲的1张随机行动牌。若该牌是攻击牌，我方回复2动力，本回合攻击次数+1。"
	effects[pilot_066_effect_01.effect_id] = pilot_066_effect_01

	# ── pilot_067 丹：2张当作双连使用+双连加成 ──
	var pilot_067_effect_01 := CardEffect.new()
	pilot_067_effect_01.effect_id = &"pilot_067_effect_01"
	pilot_067_effect_01.display_name = "丹-当作双连"
	pilot_067_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_067_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_067_effect_01.priority = 100
	pilot_067_effect_01.once_per_turn_key = &"pilot_067_effect_01"
	pilot_067_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_067_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_067_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_067_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"双连"}},
	]
	pilot_067_effect_01.description = "每回合1次，可以将2张行动牌当作双连使用。"
	effects[pilot_067_effect_01.effect_id] = pilot_067_effect_01

	# ── pilot_068 冰魄：迎击时攻击范围-2+未命中抽2 ──
	var pilot_068_effect_01 := CardEffect.new()
	pilot_068_effect_01.effect_id = &"pilot_068_effect_01"
	pilot_068_effect_01.display_name = "冰魄-迎击范围-2"
	pilot_068_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_068_effect_01.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	pilot_068_effect_01.priority = 80
	pilot_068_effect_01.once_per_turn_key = &"pilot_068_effect_01"
	pilot_068_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_068_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_068_effect_01.costs = []
	pilot_068_effect_01.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "duration": &"THIS_ATTACK"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_068_miss_draw",
			"text": "若该攻击没有命中，我方抽2张行动牌。",
		}},
	]
	pilot_068_effect_01.description = "每回合1次，我方响应攻击使用迎击牌时，可以使该攻击范围-2。若该攻击没有命中，我方抽2张行动牌。"
	effects[pilot_068_effect_01.effect_id] = pilot_068_effect_01

	# ── pilot_069 影刹：未攻击+4/未移动+2 ──
	# 效果01a：回合结束未攻击 → 下次攻击威力+4
	var pilot_069_effect_01a := CardEffect.new()
	pilot_069_effect_01a.effect_id = &"pilot_069_effect_01a"
	pilot_069_effect_01a.display_name = "影刹-未攻+4威力"
	pilot_069_effect_01a.mode = _EffectConst.MODE_PASSIVE
	pilot_069_effect_01a.hook = _EffectConst.HOOK_TURN_END
	pilot_069_effect_01a.priority = 90
	pilot_069_effect_01a.once_per_turn_key = &"pilot_069_effect_01"
	pilot_069_effect_01a.conditions = [
		{"op": &"ATTACK_COUNT_BELOW", "max_count": 1},
	]
	pilot_069_effect_01a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_069_effect_01a.costs = []
	pilot_069_effect_01a.actions = [
		{"type": &"MODIFY_NEXT_DAMAGE_DEALT", "params": {"delta": 4}},
	]
	pilot_069_effect_01a.description = "每个我方回合结束时，若本回合未发动攻击，则下次攻击威力+4。"
	effects[pilot_069_effect_01a.effect_id] = pilot_069_effect_01a

	# 效果01b：回合结束未移动 → 下次攻击范围+2
	var pilot_069_effect_01b := CardEffect.new()
	pilot_069_effect_01b.effect_id = &"pilot_069_effect_01b"
	pilot_069_effect_01b.display_name = "影刹-未移+2范围"
	pilot_069_effect_01b.mode = _EffectConst.MODE_PASSIVE
	pilot_069_effect_01b.hook = _EffectConst.HOOK_TURN_END
	pilot_069_effect_01b.priority = 90
	pilot_069_effect_01b.once_per_turn_key = &"pilot_069_effect_01"
	pilot_069_effect_01b.conditions = [
		{"op": &"ALWAYS"},  # 未移动条件需要通过 moved_cells_this_turn == 0 判断
	]
	pilot_069_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_069_effect_01b.costs = []
	pilot_069_effect_01b.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_069_no_move_bonus",
			"text": "若本回合未移动，下次攻击范围+2。上述效果无法累加。",
		}},
	]
	pilot_069_effect_01b.description = "每个我方回合结束时，若本回合未移动，则下次攻击范围+2。上述效果无法累加。"
	effects[pilot_069_effect_01b.effect_id] = pilot_069_effect_01b

	# ── pilot_070 烈火：攻击命中抽3 ──
	var pilot_070_effect_01 := CardEffect.new()
	pilot_070_effect_01.effect_id = &"pilot_070_effect_01"
	pilot_070_effect_01.display_name = "烈火-命中抽3"
	pilot_070_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_070_effect_01.hook = _EffectConst.HOOK_ATTACK_HIT
	pilot_070_effect_01.priority = 90
	pilot_070_effect_01.once_per_turn_key = &""
	pilot_070_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"PAYLOAD_ATTACK_HIT"},
	]
	pilot_070_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_070_effect_01.costs = []
	pilot_070_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 3}},
	]
	pilot_070_effect_01.description = "若发动的攻击命中，则可以抽3张行动牌。"
	effects[pilot_070_effect_01.effect_id] = pilot_070_effect_01

	# ── pilot_071 弥雅：回合后选机甲抽3弃1 ──
	var pilot_071_effect_01 := CardEffect.new()
	pilot_071_effect_01.effect_id = &"pilot_071_effect_01"
	pilot_071_effect_01.display_name = "弥雅-选机甲抽3弃1"
	pilot_071_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_071_effect_01.hook = _EffectConst.HOOK_TURN_END
	pilot_071_effect_01.priority = 100
	pilot_071_effect_01.once_per_turn_key = &""
	pilot_071_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_071_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 3}]
	pilot_071_effect_01.costs = []
	pilot_071_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 3}},
		{"type": &"DISCARD_ACTION_CARD", "params": {"count": 1}},
	]
	pilot_071_effect_01.description = "每个我方回合结束后，可以选择1台3格范围内的机甲使其抽3张行动牌，之后其再弃置1张牌。"
	effects[pilot_071_effect_01.effect_id] = pilot_071_effect_01

	# ── pilot_072 卡修：使用各类型回复动力 ──
	# 辅助牌 → 回复4动力
	var pilot_072_effect_01a := CardEffect.new()
	pilot_072_effect_01a.effect_id = &"pilot_072_effect_01a"
	pilot_072_effect_01a.display_name = "卡修-辅助回4动"
	pilot_072_effect_01a.mode = _EffectConst.MODE_PASSIVE
	pilot_072_effect_01a.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_072_effect_01a.priority = 80
	pilot_072_effect_01a.once_per_turn_key = &"pilot_072_support_restore"
	pilot_072_effect_01a.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"辅助"},
	]
	pilot_072_effect_01a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_072_effect_01a.costs = []
	pilot_072_effect_01a.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 4}},
	]
	pilot_072_effect_01a.description = "使用辅助牌时，回复4动力。"
	effects[pilot_072_effect_01a.effect_id] = pilot_072_effect_01a

	# 攻击牌 → 回复4动力
	var pilot_072_effect_01b := CardEffect.new()
	pilot_072_effect_01b.effect_id = &"pilot_072_effect_01b"
	pilot_072_effect_01b.display_name = "卡修-攻击回4动"
	pilot_072_effect_01b.mode = _EffectConst.MODE_PASSIVE
	pilot_072_effect_01b.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_072_effect_01b.priority = 80
	pilot_072_effect_01b.once_per_turn_key = &"pilot_072_attack_restore"
	pilot_072_effect_01b.conditions = [{"op": &"ALWAYS"}]
	pilot_072_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_072_effect_01b.costs = []
	pilot_072_effect_01b.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 4}},
	]
	pilot_072_effect_01b.description = "使用攻击牌时，回复4动力。"
	effects[pilot_072_effect_01b.effect_id] = pilot_072_effect_01b

	# 迎击牌 → 回复5动力
	var pilot_072_effect_01c := CardEffect.new()
	pilot_072_effect_01c.effect_id = &"pilot_072_effect_01c"
	pilot_072_effect_01c.display_name = "卡修-迎击回5动"
	pilot_072_effect_01c.mode = _EffectConst.MODE_PASSIVE
	pilot_072_effect_01c.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	pilot_072_effect_01c.priority = 80
	pilot_072_effect_01c.once_per_turn_key = &"pilot_072_counter_restore"
	pilot_072_effect_01c.conditions = [{"op": &"ALWAYS"}]
	pilot_072_effect_01c.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_072_effect_01c.costs = []
	pilot_072_effect_01c.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 5}},
	]
	pilot_072_effect_01c.description = "使用迎击牌时，回复5动力。"
	effects[pilot_072_effect_01c.effect_id] = pilot_072_effect_01c

	# ── pilot_073 法尔科：弃2行动抽1高级装备 ──
	var pilot_073_effect_01 := CardEffect.new()
	pilot_073_effect_01.effect_id = &"pilot_073_effect_01"
	pilot_073_effect_01.display_name = "法尔科-弃2抽高级装"
	pilot_073_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_073_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_073_effect_01.priority = 100
	pilot_073_effect_01.once_per_turn_key = &"pilot_073_effect_01"
	pilot_073_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_073_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_073_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_073_effect_01.actions = [
		{"type": &"DRAW_ADVANCED_EQUIPMENT", "params": {"count": 1}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_073_face_down_reserve",
			"text": "抽1张高级装备牌背面朝上置于备用区，直到下个我方回合结束不能主动设置与卖出。",
		}},
	]
	pilot_073_effect_01.description = "我方回合1次，可以弃置2张行动牌，之后抽取1张高级装备牌背面朝上置于备用区。"
	effects[pilot_073_effect_01.effect_id] = pilot_073_effect_01

	# ── pilot_074 泰特：近战弃1+3威力/其他机甲获得 ──
	var pilot_074_effect_01 := CardEffect.new()
	pilot_074_effect_01.effect_id = &"pilot_074_effect_01"
	pilot_074_effect_01.display_name = "泰特-近战弃1+3威"
	pilot_074_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_074_effect_01.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_074_effect_01.priority = 90
	pilot_074_effect_01.once_per_turn_key = &"pilot_074_effect_01"
	pilot_074_effect_01.conditions = [
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
	]
	pilot_074_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_074_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_074_effect_01.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3}},
	]
	pilot_074_effect_01.description = "使用近战武器攻击时，可以弃置1张行动牌使威力+3。"
	effects[pilot_074_effect_01.effect_id] = pilot_074_effect_01

	# pilot_074效果02：其他机甲回合开始弃1行动获得此效果
	var pilot_074_effect_02 := CardEffect.new()
	pilot_074_effect_02.effect_id = &"pilot_074_effect_02"
	pilot_074_effect_02.display_name = "泰特-他方获效"
	pilot_074_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_074_effect_02.hook = _EffectConst.HOOK_OTHER_MECH_TURN_START
	pilot_074_effect_02.priority = 90
	pilot_074_effect_02.once_per_turn_key = &""
	pilot_074_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_074_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_074_effect_02.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_074_effect_02.actions = [
		{"type": &"TOGGLE_EFFECT_ON_MECH", "params": {
			"effect_id": &"pilot_074_effect_01",
			"toggle": &"restore",
		}},
	]
	pilot_074_effect_02.description = "其他机甲回合开始时，可以通过弃置1张行动牌使该机甲在当前回合内获得近战威力+3效果。"
	effects[pilot_074_effect_02.effect_id] = pilot_074_effect_02

	# ── pilot_075 肯尼斯：弃牌选择抽1或+3威力 ──
	var pilot_075_effect_01 := CardEffect.new()
	pilot_075_effect_01.effect_id = &"pilot_075_effect_01"
	pilot_075_effect_01.display_name = "肯尼斯-弃1行动"
	pilot_075_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_075_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_075_effect_01.priority = 100
	pilot_075_effect_01.once_per_turn_key = &"pilot_075_effect_01"
	pilot_075_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_075_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_075_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_075_effect_01.actions = []
	pilot_075_effect_01.description = "我方回合1次，可以弃置1张行动牌。"
	effects[pilot_075_effect_01.effect_id] = pilot_075_effect_01

	# pilot_075效果02：行动牌被弃置时选择加成
	var pilot_075_effect_02 := CardEffect.new()
	pilot_075_effect_02.effect_id = &"pilot_075_effect_02"
	pilot_075_effect_02.display_name = "肯尼斯-弃置加成"
	pilot_075_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_075_effect_02.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_075_effect_02.priority = 80
	pilot_075_effect_02.once_per_turn_key = &""
	pilot_075_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"行动牌"},
	]
	pilot_075_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_075_effect_02.costs = []
	pilot_075_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_075_effect_02",
			"text": "每次我方行动牌被弃置，可以选择抽1张行动牌或使本回合下一次攻击威力+3。若弃置的是辅助牌，则两个效果都执行。",
		}},
	]
	pilot_075_effect_02.description = "每次我方行动牌被弃置，可以选择抽1张行动牌或使本回合下一次攻击威力+3。若弃置的是辅助牌，则两个效果都执行。"
	effects[pilot_075_effect_02.effect_id] = pilot_075_effect_02

	# ── pilot_076 疾风：获得迎击牌/获得攻击牌 ──
	var pilot_076_effect_01 := CardEffect.new()
	pilot_076_effect_01.effect_id = &"pilot_076_effect_01"
	pilot_076_effect_01.display_name = "疾风-获响应牌"
	pilot_076_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_076_effect_01.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	pilot_076_effect_01.priority = 80
	pilot_076_effect_01.once_per_turn_key = &""
	pilot_076_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_076_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_076_effect_01.costs = []
	pilot_076_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_076_effect_01",
			"text": "我方发动的攻击被迎击牌响应后，可以获得该迎击牌。用迎击牌响应攻击牌发动的攻击后，可以获得该攻击牌。",
		}},
	]
	pilot_076_effect_01.description = "我方发动的攻击被迎击牌响应后，可以获得该迎击牌。用迎击牌响应攻击牌发动的攻击后，可以获得该攻击牌。"
	effects[pilot_076_effect_01.effect_id] = pilot_076_effect_01

	# ── pilot_077 维奥拉：当作推进+推进加成 ──
	var pilot_077_effect_01 := CardEffect.new()
	pilot_077_effect_01.effect_id = &"pilot_077_effect_01"
	pilot_077_effect_01.display_name = "维奥拉-当作推进"
	pilot_077_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_077_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_077_effect_01.priority = 100
	pilot_077_effect_01.once_per_turn_key = &"pilot_077_effect_01"
	pilot_077_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_077_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_077_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_077_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"推进"}},
	]
	pilot_077_effect_01.description = "每回合1次，可以将1张行动牌当作推进使用。"
	effects[pilot_077_effect_01.effect_id] = pilot_077_effect_01

	# pilot_077效果02：推进下次攻击+2威力+可对2格范围机甲使用
	var pilot_077_effect_02 := CardEffect.new()
	pilot_077_effect_02.effect_id = &"pilot_077_effect_02"
	pilot_077_effect_02.display_name = "维奥拉-推进+2威"
	pilot_077_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_077_effect_02.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_077_effect_02.priority = 80
	pilot_077_effect_02.once_per_turn_key = &""
	pilot_077_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"推进"},
	]
	pilot_077_effect_02.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 2}]
	pilot_077_effect_02.costs = []
	pilot_077_effect_02.actions = [
		{"type": &"MODIFY_NEXT_DAMAGE_DEALT", "params": {"delta": 2}},
	]
	pilot_077_effect_02.description = "我方使用的推进获得以下效果：本回合下次攻击威力+2。可以对2格范围内的其他机甲使用。"
	effects[pilot_077_effect_02.effect_id] = pilot_077_effect_02

	# ── pilot_078 芮贝卡：范围内受伤弃1回复2+抽1 ──
	var pilot_078_effect_01 := CardEffect.new()
	pilot_078_effect_01.effect_id = &"pilot_078_effect_01"
	pilot_078_effect_01.display_name = "芮贝卡-受伤回复"
	pilot_078_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_078_effect_01.hook = _EffectConst.HOOK_OWNER_TAKE_DAMAGE
	pilot_078_effect_01.priority = 80
	pilot_078_effect_01.once_per_turn_key = &"pilot_078_effect_01"
	pilot_078_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_078_effect_01.target_rules = [{"rule": &"TARGET_IN_RANGE", "range": 3}]
	pilot_078_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_078_effect_01.actions = [
		{"type": &"HEAL_HP", "params": {"amount": 2}},
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	pilot_078_effect_01.description = "每回合2次，3格范围内的机甲受到伤害后，可以弃置1张行动牌，使其回复2生命并抽1张行动牌。"
	effects[pilot_078_effect_01.effect_id] = pilot_078_effect_01

	# ── pilot_079 莉诺：原价购买商店装备 ──
	var pilot_079_effect_01 := CardEffect.new()
	pilot_079_effect_01.effect_id = &"pilot_079_effect_01"
	pilot_079_effect_01.display_name = "莉诺-原价购买"
	pilot_079_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_079_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_079_effect_01.priority = 100
	pilot_079_effect_01.once_per_turn_key = &"pilot_079_effect_01"
	pilot_079_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_079_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_079_effect_01.costs = []
	pilot_079_effect_01.actions = [
		{"type": &"SHOP_BUY_MODIFIER", "params": {"scope": &"ORIGINAL_PRICE"}},
	]
	pilot_079_effect_01.description = "我方回合2次，可以用原价购买商店里的1张装备牌。"
	effects[pilot_079_effect_01.effect_id] = pilot_079_effect_01

	# ── pilot_080 墨尘：地图标记交互（CUSTOM） ──
	var pilot_080_effect_01 := CardEffect.new()
	pilot_080_effect_01.effect_id = &"pilot_080_effect_01"
	pilot_080_effect_01.display_name = "墨尘-标记交互"
	pilot_080_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_080_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_080_effect_01.priority = 100
	pilot_080_effect_01.once_per_turn_key = &""
	pilot_080_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_080_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_080_effect_01.costs = []
	pilot_080_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_080_effect_01",
			"text": "我方回合中，若机甲相邻的格子上存在标记，则可以移去该标记；或立即移至该格子上，之后该标记生效后可以使该效果再生效1次。",
		}},
	]
	pilot_080_effect_01.description = "我方回合中，若机甲相邻的格子上存在标记，则可以移去该标记；或立即移至该格子上，之后该标记生效后可以使该效果再生效1次。"
	effects[pilot_080_effect_01.effect_id] = pilot_080_effect_01

	# ── pilot_081 汀兰：绿格子光环（CUSTOM） ──
	# 效果01：绿格子1动力+周围变绿
	var pilot_081_effect_01 := CardEffect.new()
	pilot_081_effect_01.effect_id = &"pilot_081_effect_01"
	pilot_081_effect_01.display_name = "汀兰-绿格子光环"
	pilot_081_effect_01.mode = _EffectConst.MODE_STATIC
	pilot_081_effect_01.hook = _EffectConst.HOOK_STAT_RECALCULATE
	pilot_081_effect_01.priority = 70
	pilot_081_effect_01.once_per_turn_key = &""
	pilot_081_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_081_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_081_effect_01.costs = []
	pilot_081_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_081_effect_01",
			"text": "绿格子对我方仅消耗1动力。我方所在的格子与周围相邻的所有格子（红格子除外）视为绿格子。",
		}},
	]
	pilot_081_effect_01.description = "绿格子对我方仅消耗1动力。我方所在的格子与周围相邻的所有格子（红格子除外）视为绿格子。"
	effects[pilot_081_effect_01.effect_id] = pilot_081_effect_01

	# 效果02：绿格上回复2+获2金
	var pilot_081_effect_02 := CardEffect.new()
	pilot_081_effect_02.effect_id = &"pilot_081_effect_02"
	pilot_081_effect_02.display_name = "汀兰-绿格回2获2金"
	pilot_081_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_081_effect_02.hook = _EffectConst.HOOK_OTHER_MECH_TURN_START
	pilot_081_effect_02.priority = 80
	pilot_081_effect_02.once_per_turn_key = &""
	pilot_081_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_081_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_081_effect_02.costs = []
	pilot_081_effect_02.actions = [
		{"type": &"HEAL_HP", "params": {"amount": 2}},
		{"type": &"GAIN_GOLD", "params": {"amount": 2}},
	]
	pilot_081_effect_02.description = "处在绿格子上的机甲在其回合内1次，我方可以使其回复2点生命，获得2金币。"
	effects[pilot_081_effect_02.effect_id] = pilot_081_effect_02

	# ── pilot_082 温斯顿：交牌+攻击次数+当作3类型 ──
	# 效果01：交牌+下回合攻击数+1
	var pilot_082_effect_01 := CardEffect.new()
	pilot_082_effect_01.effect_id = &"pilot_082_effect_01"
	pilot_082_effect_01.display_name = "温斯顿-交牌攻击+1"
	pilot_082_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_082_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_082_effect_01.priority = 100
	pilot_082_effect_01.once_per_turn_key = &"pilot_082_effect_01"
	pilot_082_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_082_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 3}]
	pilot_082_effect_01.costs = []
	pilot_082_effect_01.actions = [
		{"type": &"TRANSFER_ACTION_CARDS", "params": {"count": 0}},  # 任意张
		{"type": &"MODIFY_ATTACK_COUNT", "params": {"delta": 1, "duration": &"NEXT_TURN"}},
	]
	pilot_082_effect_01.description = "我方回合1次，可以将任意张行动牌交给3格内的1台其他机甲，令其下回合的攻击次数+1。"
	effects[pilot_082_effect_01.effect_id] = pilot_082_effect_01

	# 效果02：攻击牌当作掩护/维修/推进（3个共享once_per_turn_key的选择）
	var pilot_082_effect_02a := CardEffect.new()
	pilot_082_effect_02a.effect_id = &"pilot_082_effect_02a"
	pilot_082_effect_02a.display_name = "温斯顿-当作掩护"
	pilot_082_effect_02a.mode = _EffectConst.MODE_ACTIVE
	pilot_082_effect_02a.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_082_effect_02a.priority = 100
	pilot_082_effect_02a.once_per_turn_key = &"pilot_082_effect_02"
	pilot_082_effect_02a.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_082_effect_02a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_082_effect_02a.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_082_effect_02a.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"掩护"}},
	]
	pilot_082_effect_02a.description = "我方可以把攻击牌当作掩护使用。"
	effects[pilot_082_effect_02a.effect_id] = pilot_082_effect_02a

	var pilot_082_effect_02b := CardEffect.new()
	pilot_082_effect_02b.effect_id = &"pilot_082_effect_02b"
	pilot_082_effect_02b.display_name = "温斯顿-当作维修"
	pilot_082_effect_02b.mode = _EffectConst.MODE_ACTIVE
	pilot_082_effect_02b.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_082_effect_02b.priority = 100
	pilot_082_effect_02b.once_per_turn_key = &"pilot_082_effect_02"
	pilot_082_effect_02b.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_082_effect_02b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_082_effect_02b.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_082_effect_02b.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"维修"}},
	]
	pilot_082_effect_02b.description = "我方可以把攻击牌当作维修使用。"
	effects[pilot_082_effect_02b.effect_id] = pilot_082_effect_02b

	var pilot_082_effect_02c := CardEffect.new()
	pilot_082_effect_02c.effect_id = &"pilot_082_effect_02c"
	pilot_082_effect_02c.display_name = "温斯顿-当作推进"
	pilot_082_effect_02c.mode = _EffectConst.MODE_ACTIVE
	pilot_082_effect_02c.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_082_effect_02c.priority = 100
	pilot_082_effect_02c.once_per_turn_key = &"pilot_082_effect_02"
	pilot_082_effect_02c.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_082_effect_02c.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_082_effect_02c.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_082_effect_02c.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"推进"}},
	]
	pilot_082_effect_02c.description = "我方可以把攻击牌当作推进使用。"
	effects[pilot_082_effect_02c.effect_id] = pilot_082_effect_02c

	# ── pilot_083 瓦恩：武器修改+他方获效 ──
	var pilot_083_effect_01 := CardEffect.new()
	pilot_083_effect_01.effect_id = &"pilot_083_effect_01"
	pilot_083_effect_01.display_name = "瓦恩-武器修改"
	pilot_083_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_083_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_083_effect_01.priority = 100
	pilot_083_effect_01.once_per_turn_key = &"pilot_083_effect_01"
	pilot_083_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_083_effect_01.target_rules = [{"rule": &"CHOOSE_OWN_WEAPON"}]
	pilot_083_effect_01.costs = []
	pilot_083_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_083_effect_01",
			"text": "每回合1次，可以将1把武器名称加上热能或光束，类型转变为近战或远程武器，并使威力+3或范围+1（持续到当前回合结束）。",
		}},
	]
	pilot_083_effect_01.description = "每回合1次，可以将1把武器名称加上热能或光束，类型转变为近战或远程武器，并使威力+3或范围+1。"
	effects[pilot_083_effect_01.effect_id] = pilot_083_effect_01

	var pilot_083_effect_02 := CardEffect.new()
	pilot_083_effect_02.effect_id = &"pilot_083_effect_02"
	pilot_083_effect_02.display_name = "瓦恩-他方获效"
	pilot_083_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_083_effect_02.hook = _EffectConst.HOOK_OTHER_MECH_TURN_START
	pilot_083_effect_02.priority = 90
	pilot_083_effect_02.once_per_turn_key = &""
	pilot_083_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_083_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_083_effect_02.costs = [
		{"cost_type": &"SPEND_GOLD", "amount": 2},
	]
	pilot_083_effect_02.actions = [
		{"type": &"TOGGLE_EFFECT_ON_MECH", "params": {
			"effect_id": &"pilot_083_effect_01",
			"toggle": &"restore",
		}},
	]
	pilot_083_effect_02.description = "在3格内的其他机甲可以在其回合内，消耗2金币使我方可以对其使用上述所有效果。"
	effects[pilot_083_effect_02.effect_id] = pilot_083_effect_02

	# ── pilot_084 莎菲雅：2张当作联合+抽2 ──
	var pilot_084_effect_01 := CardEffect.new()
	pilot_084_effect_01.effect_id = &"pilot_084_effect_01"
	pilot_084_effect_01.display_name = "莎菲雅-当作联合抽2"
	pilot_084_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_084_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_084_effect_01.priority = 100
	pilot_084_effect_01.once_per_turn_key = &"pilot_084_effect_01"
	pilot_084_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_084_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_084_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_084_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"联合"}},
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
	]
	pilot_084_effect_01.description = "我方回合2次，可以将2张行动牌当作联合使用，之后抽2张行动牌。"
	effects[pilot_084_effect_01.effect_id] = pilot_084_effect_01

	# pilot_084效果02：其他机甲因联合使用攻击牌后获3金
	var pilot_084_effect_02 := CardEffect.new()
	pilot_084_effect_02.effect_id = &"pilot_084_effect_02"
	pilot_084_effect_02.display_name = "莎菲雅-联合获3金"
	pilot_084_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_084_effect_02.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	pilot_084_effect_02.priority = 80
	pilot_084_effect_02.once_per_turn_key = &""
	pilot_084_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"联合"},
	]
	pilot_084_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_084_effect_02.costs = []
	pilot_084_effect_02.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 3}},
	]
	pilot_084_effect_02.description = "其他机甲因联合的效果使用攻击牌后，我方获得3金币。"
	effects[pilot_084_effect_02.effect_id] = pilot_084_effect_02

	# ── pilot_085 莽克：装备弃置获金 ──
	# 效果01a：自身装备弃置获4金
	var pilot_085_effect_01a := CardEffect.new()
	pilot_085_effect_01a.effect_id = &"pilot_085_effect_01a"
	pilot_085_effect_01a.display_name = "莽克-自装弃获4金"
	pilot_085_effect_01a.mode = _EffectConst.MODE_PASSIVE
	pilot_085_effect_01a.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	pilot_085_effect_01a.priority = 80
	pilot_085_effect_01a.once_per_turn_key = &""
	pilot_085_effect_01a.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},  # 这里用来判断"自身" — 需要payload判断
	]
	pilot_085_effect_01a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_085_effect_01a.costs = []
	pilot_085_effect_01a.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 4}},
	]
	pilot_085_effect_01a.description = "机甲上正面设置的装备牌弃置时，可立即获得4金币。"
	effects[pilot_085_effect_01a.effect_id] = pilot_085_effect_01a

	# 效果01b：其他机甲装备弃置获3金
	var pilot_085_effect_01b := CardEffect.new()
	pilot_085_effect_01b.effect_id = &"pilot_085_effect_01b"
	pilot_085_effect_01b.display_name = "莽克-他装弃获3金"
	pilot_085_effect_01b.mode = _EffectConst.MODE_PASSIVE
	pilot_085_effect_01b.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	pilot_085_effect_01b.priority = 80
	pilot_085_effect_01b.once_per_turn_key = &""
	pilot_085_effect_01b.conditions = [
		{"op": &"ALWAYS"},
	]
	pilot_085_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_085_effect_01b.costs = []
	pilot_085_effect_01b.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 3}},
	]
	pilot_085_effect_01b.description = "场上其他机甲上正面设置的装备牌弃置时，可立即获得3金币。"
	effects[pilot_085_effect_01b.effect_id] = pilot_085_effect_01b

	# ── pilot_086 獠鼠：攻击骰子分支 ──
	var pilot_086_effect_01 := CardEffect.new()
	pilot_086_effect_01.effect_id = &"pilot_086_effect_01"
	pilot_086_effect_01.display_name = "獠鼠-骰子攻击"
	pilot_086_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_086_effect_01.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_086_effect_01.priority = 80
	pilot_086_effect_01.once_per_turn_key = &""
	pilot_086_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_086_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_086_effect_01.costs = []
	pilot_086_effect_01.actions = [
		{"type": &"ROLL_D6", "params": {"store_key": &"pilot_086_dice_result"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_086_effect_01",
			"text": "指定目标发动攻击时，可以投掷1个骰子：1：我方机甲设置1损伤；2~3：弃置目标1张行动牌；4~5：我方抽2张行动牌；6：对目标施加锁定效果。",
		}},
	]
	pilot_086_effect_01.description = "指定目标发动攻击时，可以投掷1个骰子：1：我方机甲设置1损伤；2~3：弃置目标1张行动牌；4~5：我方抽2张行动牌；6：对目标施加锁定效果。"
	effects[pilot_086_effect_01.effect_id] = pilot_086_effect_01

	# ── pilot_087 塔妮拉：交牌获金+使用后各抽1 ──
	var pilot_087_effect_01 := CardEffect.new()
	pilot_087_effect_01.effect_id = &"pilot_087_effect_01"
	pilot_087_effect_01.display_name = "塔妮拉-交牌获2金"
	pilot_087_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_087_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_087_effect_01.priority = 100
	pilot_087_effect_01.once_per_turn_key = &"pilot_087_effect_01"
	pilot_087_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_087_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 3}]
	pilot_087_effect_01.costs = []
	pilot_087_effect_01.actions = [
		{"type": &"TRANSFER_ACTION_CARDS", "params": {"count": 1}},
		{"type": &"GAIN_GOLD", "params": {"amount": 2}},
	]
	pilot_087_effect_01.description = "我方回合2次，可以将1张行动牌交给1台3格范围内的其他机甲，之后我方获得2金币。"
	effects[pilot_087_effect_01.effect_id] = pilot_087_effect_01

	var pilot_087_effect_02 := CardEffect.new()
	pilot_087_effect_02.effect_id = &"pilot_087_effect_02"
	pilot_087_effect_02.display_name = "塔妮拉-他用后各抽1"
	pilot_087_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_087_effect_02.hook = _EffectConst.HOOK_CARD_PLAYED
	pilot_087_effect_02.priority = 80
	pilot_087_effect_02.once_per_turn_key = &""
	pilot_087_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"从我方处获得"},
	]
	pilot_087_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_087_effect_02.costs = []
	pilot_087_effect_02.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	pilot_087_effect_02.description = "其他机甲使用从我方处获得的行动牌后，该机甲和我方各抽1张行动牌。"
	effects[pilot_087_effect_02.effect_id] = pilot_087_effect_02

	# ── pilot_088 征服：宣言+展示+弃置 ──
	var pilot_088_effect_01 := CardEffect.new()
	pilot_088_effect_01.effect_id = &"pilot_088_effect_01"
	pilot_088_effect_01.display_name = "征服-宣言弃置"
	pilot_088_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_088_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_088_effect_01.priority = 100
	pilot_088_effect_01.once_per_turn_key = &"pilot_088_effect_01"
	pilot_088_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_088_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 3}]
	pilot_088_effect_01.costs = []
	pilot_088_effect_01.actions = [
		{"type": &"DECLARE_CARD_TYPE", "params": {}},
		{"type": &"REVEAL_OR_PEEK_CARD", "params": {"mode": &"peek"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_088_effect_01",
			"text": "我方回合1次，可以宣言1种行动牌类型，并展示3格范围内1台其他机甲的1张随机行动牌。若该牌类型与宣言相同，则弃置该机甲其余未展示的牌；否则弃置该展示的牌。",
		}},
	]
	pilot_088_effect_01.description = "我方回合1次，可以宣言1种行动牌类型，并展示3格范围内1台其他机甲的1张随机行动牌。若该牌类型与宣言相同，则弃置其余牌；否则弃置该牌。"
	effects[pilot_088_effect_01.effect_id] = pilot_088_effect_01

	# ═══════════════════════════════════════════
	# 批次L：R稀有度机师效果（pilot_029-058）
	# ═══════════════════════════════════════════

	# ── pilot_029 远程武器范围+1 + 当作聚能 ──
	var pilot_029_effect_01 := CardEffect.new()
	pilot_029_effect_01.effect_id = &"pilot_029_effect_01"
	pilot_029_effect_01.display_name = "远程范围+1"
	pilot_029_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_029_effect_01.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_029_effect_01.priority = 90
	pilot_029_effect_01.once_per_turn_key = &""
	pilot_029_effect_01.conditions = [
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_029_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_029_effect_01.costs = []
	pilot_029_effect_01.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 1}},
	]
	pilot_029_effect_01.description = "使用远程武器攻击时，范围+1。"
	effects[pilot_029_effect_01.effect_id] = pilot_029_effect_01

	var pilot_029_effect_02 := CardEffect.new()
	pilot_029_effect_02.effect_id = &"pilot_029_effect_02"
	pilot_029_effect_02.display_name = "当作聚能"
	pilot_029_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_029_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_029_effect_02.priority = 100
	pilot_029_effect_02.once_per_turn_key = &"pilot_029_effect_02"
	pilot_029_effect_02.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_029_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_029_effect_02.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_029_effect_02.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"聚能"}},
	]
	pilot_029_effect_02.description = "每回合1次，可以将1张行动牌当作聚能使用。"
	effects[pilot_029_effect_02.effect_id] = pilot_029_effect_02

	# ── pilot_030 当作防御 + 使用后抽1+攻击数+1 ──
	var pilot_030_effect_01 := CardEffect.new()
	pilot_030_effect_01.effect_id = &"pilot_030_effect_01"
	pilot_030_effect_01.display_name = "当作防御"
	pilot_030_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_030_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_030_effect_01.priority = 100
	pilot_030_effect_01.once_per_turn_key = &"pilot_030_effect_01"
	pilot_030_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_030_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_030_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_030_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"防御"}},
	]
	pilot_030_effect_01.description = "每回合1次，可以将1张行动牌当作防御使用。"
	effects[pilot_030_effect_01.effect_id] = pilot_030_effect_01

	var pilot_030_effect_02 := CardEffect.new()
	pilot_030_effect_02.effect_id = &"pilot_030_effect_02"
	pilot_030_effect_02.display_name = "防御后抽1+攻击+1"
	pilot_030_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_030_effect_02.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	pilot_030_effect_02.priority = 80
	pilot_030_effect_02.once_per_turn_key = &""
	pilot_030_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"防御"},
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_030_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_030_effect_02.costs = []
	pilot_030_effect_02.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
		{"type": &"MODIFY_ATTACK_COUNT", "params": {"delta": 1, "duration": &"NEXT_OWNER_TURN"}},
	]
	pilot_030_effect_02.description = "我方使用防御后，可以抽1张行动牌，并且下一个我方回合的攻击数+1。"
	effects[pilot_030_effect_02.effect_id] = pilot_030_effect_02

	# ── pilot_031 交牌+抽牌+护甲 ──
	var pilot_031_effect_01 := CardEffect.new()
	pilot_031_effect_01.effect_id = &"pilot_031_effect_01"
	pilot_031_effect_01.display_name = "交牌抽牌护甲"
	pilot_031_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_031_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_031_effect_01.priority = 100
	pilot_031_effect_01.once_per_turn_key = &"pilot_031_effect_01"
	pilot_031_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_031_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_031_effect_01.costs = []
	pilot_031_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_031_effect_01",
			"text": "我方回合1次，可以将任意张行动牌交给4格范围内1台其他机甲，每给出2张牌，之后我方和该机甲可以各抽1张行动牌，护甲+1（持续到下个我方回合开始）。",
		}},
	]
	pilot_031_effect_01.description = "我方回合1次，可以将任意张行动牌交给4格范围内1台其他机甲，每给出2张牌，之后我方和该机甲可以各抽1张行动牌，护甲+1。"
	effects[pilot_031_effect_01.effect_id] = pilot_031_effect_01

	# ── pilot_032 弃1行动牌上限+2 ──
	var pilot_032_effect_01 := CardEffect.new()
	pilot_032_effect_01.effect_id = &"pilot_032_effect_01"
	pilot_032_effect_01.display_name = "弃1行动上限+2"
	pilot_032_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_032_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_032_effect_01.priority = 100
	pilot_032_effect_01.once_per_turn_key = &"pilot_032_effect_01"
	pilot_032_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_032_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_032_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_032_effect_01.actions = [
		{"type": &"MODIFY_ACTION_HAND_LIMIT", "params": {"delta": 2, "duration": &"NEXT_OWNER_TURN"}},
	]
	pilot_032_effect_01.description = "我方回合1次，可以弃置1张行动牌使行动牌上限+2(持续到下个我方回合开始)。"
	effects[pilot_032_effect_01.effect_id] = pilot_032_effect_01

	# ── pilot_033 弃装备抽装备 + 本局1次弃2抽高级 ──
	var pilot_033_effect_01 := CardEffect.new()
	pilot_033_effect_01.effect_id = &"pilot_033_effect_01"
	pilot_033_effect_01.display_name = "弃装抽装"
	pilot_033_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_033_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_033_effect_01.priority = 100
	pilot_033_effect_01.once_per_turn_key = &"pilot_033_effect_01"
	pilot_033_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_033_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_033_effect_01.costs = [
		{"cost_type": &"DISCARD_EQUIPMENT_CARD", "count": 1},
	]
	pilot_033_effect_01.actions = [
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
	]
	pilot_033_effect_01.description = "我方回合1次，可以弃置1张装备牌，之后抽1张装备牌。"
	effects[pilot_033_effect_01.effect_id] = pilot_033_effect_01

	var pilot_033_effect_02 := CardEffect.new()
	pilot_033_effect_02.effect_id = &"pilot_033_effect_02"
	pilot_033_effect_02.display_name = "弃2装抽高级"
	pilot_033_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_033_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_033_effect_02.priority = 100
	pilot_033_effect_02.once_per_turn_key = &"pilot_033_effect_02_per_game"
	pilot_033_effect_02.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_033_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_033_effect_02.costs = [
		{"cost_type": &"DISCARD_EQUIPMENT_CARD", "count": 2},
	]
	pilot_033_effect_02.actions = [
		{"type": &"DRAW_ADVANCED_EQUIPMENT", "params": {"count": 1}},
	]
	pilot_033_effect_02.description = "本局游戏1次，可以弃置2张装备牌，之后抽1张高级装备牌。"
	effects[pilot_033_effect_02.effect_id] = pilot_033_effect_02

	# ── pilot_034 未伤害攻击损伤-1 + 记录伤害机甲+命中加成 ──
	var pilot_034_effect_01 := CardEffect.new()
	pilot_034_effect_01.effect_id = &"pilot_034_effect_01"
	pilot_034_effect_01.display_name = "未伤害攻击损伤-1"
	pilot_034_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_034_effect_01.hook = _EffectConst.HOOK_DAMAGE_MODIFIER_WINDOW
	pilot_034_effect_01.priority = 80
	pilot_034_effect_01.once_per_turn_key = &""
	pilot_034_effect_01.conditions = [
		{"op": &"ATTACK_DEALT_NO_HP_DAMAGE"},
	]
	pilot_034_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_034_effect_01.costs = []
	pilot_034_effect_01.actions = [
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": -1}},
	]
	pilot_034_effect_01.description = "未对我方造成伤害的攻击产生的损伤-1。"
	effects[pilot_034_effect_01.effect_id] = pilot_034_effect_01

	var pilot_034_effect_02 := CardEffect.new()
	pilot_034_effect_02.effect_id = &"pilot_034_effect_02"
	pilot_034_effect_02.display_name = "记录伤害+命中加3"
	pilot_034_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_034_effect_02.hook = _EffectConst.HOOK_ATTACK_HIT
	pilot_034_effect_02.priority = 80
	pilot_034_effect_02.once_per_turn_key = &""
	pilot_034_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_034_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_034_effect_02.costs = []
	pilot_034_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_034_effect_02",
			"text": "记录对我方造成过伤害的其他机甲，当我方对其攻击命中时，可额外造成3伤害，并回复我方3生命。",
		}},
	]
	pilot_034_effect_02.description = "记录对我方造成过伤害的其他机甲，当我方对其攻击命中时，可额外造成3伤害，并回复我方3生命。"
	effects[pilot_034_effect_02.effect_id] = pilot_034_effect_02

	# ── pilot_035 轮开始选机甲+抽牌跟踪 ──
	var pilot_035_effect_01 := CardEffect.new()
	pilot_035_effect_01.effect_id = &"pilot_035_effect_01"
	pilot_035_effect_01.display_name = "选机甲跟踪抽牌"
	pilot_035_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_035_effect_01.hook = _EffectConst.HOOK_ROUND_START
	pilot_035_effect_01.priority = 100
	pilot_035_effect_01.once_per_turn_key = &""
	pilot_035_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_035_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH"}]
	pilot_035_effect_01.costs = []
	pilot_035_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_035_effect_01",
			"text": "每轮开始时，选择1台其他机甲，本轮中该机甲每次抽取行动牌时，我方可抽1张行动牌。",
		}},
	]
	pilot_035_effect_01.description = "每轮开始时，选择1台其他机甲，本轮中该机甲每次抽取行动牌时，我方可抽1张行动牌。"
	effects[pilot_035_effect_01.effect_id] = pilot_035_effect_01

	# ── pilot_036 消耗2金抽1 + 弃2行动获3金 ──
	var pilot_036_effect_01 := CardEffect.new()
	pilot_036_effect_01.effect_id = &"pilot_036_effect_01"
	pilot_036_effect_01.display_name = "消耗2金抽1"
	pilot_036_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_036_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_036_effect_01.priority = 100
	pilot_036_effect_01.once_per_turn_key = &"pilot_036_effect_01"
	pilot_036_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_036_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_036_effect_01.costs = [
		{"cost_type": &"SPEND_GOLD", "amount": 2},
	]
	pilot_036_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	pilot_036_effect_01.description = "我方回合2次，可以消耗2金币抽1张行动牌。"
	effects[pilot_036_effect_01.effect_id] = pilot_036_effect_01

	var pilot_036_effect_02 := CardEffect.new()
	pilot_036_effect_02.effect_id = &"pilot_036_effect_02"
	pilot_036_effect_02.display_name = "弃2行动获3金"
	pilot_036_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_036_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_036_effect_02.priority = 100
	pilot_036_effect_02.once_per_turn_key = &"pilot_036_effect_02"
	pilot_036_effect_02.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_036_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_036_effect_02.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_036_effect_02.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 3}},
	]
	pilot_036_effect_02.description = "我方回合1次，可以弃置2张行动牌获得3金币。"
	effects[pilot_036_effect_02.effect_id] = pilot_036_effect_02

	# ── pilot_037 被攻击查看+偷牌+手牌多攻击-5 ──
	var pilot_037_effect_01 := CardEffect.new()
	pilot_037_effect_01.effect_id = &"pilot_037_effect_01"
	pilot_037_effect_01.display_name = "被攻查看偷牌"
	pilot_037_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_037_effect_01.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	pilot_037_effect_01.priority = 80
	pilot_037_effect_01.once_per_turn_key = &"pilot_037_effect_01"
	pilot_037_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_037_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_037_effect_01.costs = []
	pilot_037_effect_01.actions = [
		{"type": &"REVEAL_OR_PEEK_CARD", "params": {"mode": &"peek"}},
		{"type": &"STEAL_ACTION_CARD", "params": {"count": 1}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_037_hand_penalty",
			"text": "若之后我方所持行动牌数大于攻击方，则该攻击威力-5。",
		}},
	]
	pilot_037_effect_01.description = "每回合2次，查看对我方发动攻击的机甲的所持行动牌，并选择获得其中1张，若之后我方所持行动牌数大于攻击方，则该攻击威力-5。"
	effects[pilot_037_effect_01.effect_id] = pilot_037_effect_01

	# ── pilot_038 选2台机甲抽1回3动 ──
	var pilot_038_effect_01 := CardEffect.new()
	pilot_038_effect_01.effect_id = &"pilot_038_effect_01"
	pilot_038_effect_01.display_name = "选2台抽1回3动"
	pilot_038_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_038_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_038_effect_01.priority = 100
	pilot_038_effect_01.once_per_turn_key = &"pilot_038_effect_01"
	pilot_038_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_038_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_038_effect_01.costs = []
	pilot_038_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
		{"type": &"RESTORE_POWER", "params": {"amount": 3}},
	]
	pilot_038_effect_01.description = "我方回合1次，可以选择最多2台4格范围内的机甲，使其抽1张行动牌，回复3动力。"
	effects[pilot_038_effect_01.effect_id] = pilot_038_effect_01

	# ── pilot_039 攻击未命中抽1+再攻 ──
	var pilot_039_effect_01 := CardEffect.new()
	pilot_039_effect_01.effect_id = &"pilot_039_effect_01"
	pilot_039_effect_01.display_name = "未命中抽1再攻"
	pilot_039_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_039_effect_01.hook = _EffectConst.HOOK_ATTACK_MISS
	pilot_039_effect_01.priority = 80
	pilot_039_effect_01.once_per_turn_key = &""
	pilot_039_effect_01.conditions = [
		{"op": &"PAYLOAD_ATTACK_MISS"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_039_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_039_effect_01.costs = []
	pilot_039_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
		{"type": &"MODIFY_ATTACK_COUNT", "params": {"delta": 1}},
	]
	pilot_039_effect_01.description = "若发动的攻击没有命中，则可以抽1张行动牌，之后再发动1次攻击。"
	effects[pilot_039_effect_01.effect_id] = pilot_039_effect_01

	# ── pilot_040 近战弃1锁定 ──
	var pilot_040_effect_01 := CardEffect.new()
	pilot_040_effect_01.effect_id = &"pilot_040_effect_01"
	pilot_040_effect_01.display_name = "近战弃1锁定"
	pilot_040_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_040_effect_01.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_040_effect_01.priority = 90
	pilot_040_effect_01.once_per_turn_key = &"pilot_040_effect_01"
	pilot_040_effect_01.conditions = [
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_040_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_040_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_040_effect_01.actions = [
		{"type": &"APPLY_OR_CHECK_LOCKED", "params": {"mode": &"apply"}},
	]
	pilot_040_effect_01.description = "每回合1次，使用近战武器攻击时，可弃置1张行动牌对目标施加锁定效果。"
	effects[pilot_040_effect_01.effect_id] = pilot_040_effect_01

	# ── pilot_041 花费3金抽2行动 ──
	var pilot_041_effect_01 := CardEffect.new()
	pilot_041_effect_01.effect_id = &"pilot_041_effect_01"
	pilot_041_effect_01.display_name = "花费3金抽2"
	pilot_041_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_041_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_041_effect_01.priority = 100
	pilot_041_effect_01.once_per_turn_key = &"pilot_041_effect_01"
	pilot_041_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_041_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_041_effect_01.costs = [
		{"cost_type": &"SPEND_GOLD", "amount": 3},
	]
	pilot_041_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
	]
	pilot_041_effect_01.description = "我方回合1次，可以花费3金币抽2张行动牌。"
	effects[pilot_041_effect_01.effect_id] = pilot_041_effect_01

	# ── pilot_042 弃牌后抽1 + 弃所有抽1 ──
	var pilot_042_effect_01 := CardEffect.new()
	pilot_042_effect_01.effect_id = &"pilot_042_effect_01"
	pilot_042_effect_01.display_name = "弃牌后抽1+弃所有抽1"
	pilot_042_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_042_effect_01.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_042_effect_01.priority = 80
	pilot_042_effect_01.once_per_turn_key = &""
	pilot_042_effect_01.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"行动牌"},
	]
	pilot_042_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_042_effect_01.costs = []
	pilot_042_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_042_discard_all",
			"text": "我方回合2次，可以弃置所有行动牌，之后再抽1张行动牌。",
		}},
	]
	pilot_042_effect_01.description = "每次弃置行动牌后，可以抽1张行动牌。我方回合2次，可以弃置所有行动牌，之后再抽1张行动牌。"
	effects[pilot_042_effect_01.effect_id] = pilot_042_effect_01

	# ── pilot_043 抽牌前宣言+匹配再抽1 ──
	var pilot_043_effect_01 := CardEffect.new()
	pilot_043_effect_01.effect_id = &"pilot_043_effect_01"
	pilot_043_effect_01.display_name = "宣言匹配抽1"
	pilot_043_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_043_effect_01.hook = _EffectConst.HOOK_ACTION_CARD_DRAWN
	pilot_043_effect_01.priority = 80
	pilot_043_effect_01.once_per_turn_key = &""
	pilot_043_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_043_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_043_effect_01.costs = []
	pilot_043_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_043_effect_01",
			"text": "即将抽取行动牌时，可以宣言1种行动牌类型(攻击，迎击，辅助)，若之后抽到的牌中存在宣言类型，则可以再抽1张行动牌。",
		}},
	]
	pilot_043_effect_01.description = "即将抽取行动牌时，可以宣言1种行动牌类型，若之后抽到的牌中存在宣言类型，则可以再抽1张行动牌。"
	effects[pilot_043_effect_01.effect_id] = pilot_043_effect_01

	# ── pilot_044 损伤数X抽X弃X-1 ──
	var pilot_044_effect_01 := CardEffect.new()
	pilot_044_effect_01.effect_id = &"pilot_044_effect_01"
	pilot_044_effect_01.display_name = "损伤X抽X弃X-1"
	pilot_044_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_044_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_044_effect_01.priority = 80
	pilot_044_effect_01.once_per_turn_key = &""
	pilot_044_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_044_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_044_effect_01.costs = []
	pilot_044_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_044_effect_01",
			"text": "每个我方回合开始时与回合结束后，记录机甲所有区域的损伤数为X，之后抽X张行动牌，再弃置X-1（最低为0）张行动牌。",
		}},
	]
	pilot_044_effect_01.description = "每个我方回合开始时与回合结束后，记录机甲所有区域的损伤数为X，之后抽X张行动牌，再弃置X-1张行动牌。"
	effects[pilot_044_effect_01.effect_id] = pilot_044_effect_01

	# ── pilot_045 弃3行动获攻牌 + 每2次4伤害 ──
	var pilot_045_effect_01 := CardEffect.new()
	pilot_045_effect_01.effect_id = &"pilot_045_effect_01"
	pilot_045_effect_01.display_name = "弃3获攻牌"
	pilot_045_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_045_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_045_effect_01.priority = 100
	pilot_045_effect_01.once_per_turn_key = &"pilot_045_effect_01"
	pilot_045_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_045_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_045_effect_01.costs = []
	pilot_045_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_045_effect_01",
			"text": "我方回合1次，可以弃置4格范围内所有其他机甲3张行动牌，之后获得被弃置牌中的所有攻击牌。",
		}},
	]
	pilot_045_effect_01.description = "我方回合1次，可以弃置4格范围内所有其他机甲3张行动牌，之后获得被弃置牌中的所有攻击牌。"
	effects[pilot_045_effect_01.effect_id] = pilot_045_effect_01

	var pilot_045_effect_02 := CardEffect.new()
	pilot_045_effect_02.effect_id = &"pilot_045_effect_02"
	pilot_045_effect_02.display_name = "每2次4伤害"
	pilot_045_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_045_effect_02.hook = _EffectConst.HOOK_TURN_END
	pilot_045_effect_02.priority = 80
	pilot_045_effect_02.once_per_turn_key = &""
	pilot_045_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_045_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_045_effect_02.costs = []
	pilot_045_effect_02.actions = [
		{"type": &"INCREMENT_VARIABLE", "params": {"variable_name": &"pilot_045_activation_count", "delta": 1}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_045_effect_02",
			"text": "上述效果每发动2次，我方将受到4伤害。",
		}},
	]
	pilot_045_effect_02.description = "上述效果每发动2次，我方将受到4伤害。"
	effects[pilot_045_effect_02.effect_id] = pilot_045_effect_02

	# ── pilot_046 查看隐藏装备+获取 ──
	var pilot_046_effect_01 := CardEffect.new()
	pilot_046_effect_01.effect_id = &"pilot_046_effect_01"
	pilot_046_effect_01.display_name = "查看获取隐藏装"
	pilot_046_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_046_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_046_effect_01.priority = 100
	pilot_046_effect_01.once_per_turn_key = &"pilot_046_effect_01"
	pilot_046_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_046_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_046_effect_01.costs = []
	pilot_046_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_046_effect_01",
			"text": "我方可以无条件查看商店和其他机甲备用区域内的隐藏装备牌。我方回合1次，可以消耗隐藏装备牌其上记述的金币获得该牌，之后将其背面朝上置于我方或其他机甲的备用区域上。",
		}},
	]
	pilot_046_effect_01.description = "我方可以无条件查看隐藏装备牌。我方回合1次，可以消耗其金币获得该牌。"
	effects[pilot_046_effect_01.effect_id] = pilot_046_effect_01

	# ── pilot_047 攻击时强制或交牌 ──
	var pilot_047_effect_01 := CardEffect.new()
	pilot_047_effect_01.effect_id = &"pilot_047_effect_01"
	pilot_047_effect_01.display_name = "攻击强制或交牌"
	pilot_047_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_047_effect_01.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_047_effect_01.priority = 80
	pilot_047_effect_01.once_per_turn_key = &"pilot_047_effect_01"
	pilot_047_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_047_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_047_effect_01.costs = []
	pilot_047_effect_01.actions = [
		{"type": &"FORCE_MECH_ACTION", "params": {"action_type": &"attack"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_047_alternative",
			"text": "选择1台4格范围内的其他机甲，其选择立即使用1张攻击牌，或必须交给我方2张行动牌，若数量不足则每少1张将受到2伤害。",
		}},
	]
	pilot_047_effect_01.description = "每回合1次，我方攻击时，选择1台4格范围内的其他机甲，其选择立即使用1张攻击牌，或必须交给我方2张行动牌。"
	effects[pilot_047_effect_01.effect_id] = pilot_047_effect_01

	# ── pilot_048 攻击损伤+1+优先决定 ──
	var pilot_048_effect_01 := CardEffect.new()
	pilot_048_effect_01.effect_id = &"pilot_048_effect_01"
	pilot_048_effect_01.display_name = "攻击损伤+1+优先"
	pilot_048_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_048_effect_01.hook = _EffectConst.HOOK_ATTACK_HIT
	pilot_048_effect_01.priority = 80
	pilot_048_effect_01.once_per_turn_key = &""
	pilot_048_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"PAYLOAD_ATTACK_HIT"},
	]
	pilot_048_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_048_effect_01.costs = []
	pilot_048_effect_01.actions = [
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": 1}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_048_priority",
			"text": "我方攻击造成的损伤必须由我方优先决定设置的位置。",
		}},
	]
	pilot_048_effect_01.description = "我方攻击造成的损伤+1。我方攻击造成的损伤必须由我方优先决定设置的位置。"
	effects[pilot_048_effect_01.effect_id] = pilot_048_effect_01

	# ── pilot_049 帝国机甲伤害转移 + 受伤后下次+X ──
	var pilot_049_effect_01 := CardEffect.new()
	pilot_049_effect_01.effect_id = &"pilot_049_effect_01"
	pilot_049_effect_01.display_name = "帝国伤害转移"
	pilot_049_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_049_effect_01.hook = _EffectConst.HOOK_OWNER_TAKE_DAMAGE
	pilot_049_effect_01.priority = 80
	pilot_049_effect_01.once_per_turn_key = &""
	pilot_049_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_049_effect_01.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 4}]
	pilot_049_effect_01.costs = []
	pilot_049_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_049_effect_01",
			"text": "4格范围内其他的机师或机甲框架阵营为帝国的机甲即将受到伤害时，可以将该伤害转移由我方承受。",
		}},
	]
	pilot_049_effect_01.description = "4格范围内帝国阵营机甲即将受到伤害时，可以将该伤害转移由我方承受。"
	effects[pilot_049_effect_01.effect_id] = pilot_049_effect_01

	var pilot_049_effect_02 := CardEffect.new()
	pilot_049_effect_02.effect_id = &"pilot_049_effect_02"
	pilot_049_effect_02.display_name = "受伤后下次+X"
	pilot_049_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_049_effect_02.hook = _EffectConst.HOOK_OWNER_TAKE_DAMAGE
	pilot_049_effect_02.priority = 85
	pilot_049_effect_02.once_per_turn_key = &""
	pilot_049_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_049_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_049_effect_02.costs = []
	pilot_049_effect_02.actions = [
		{"type": &"MODIFY_NEXT_DAMAGE_DEALT", "params": {"delta": 0}},
	]
	pilot_049_effect_02.description = "我方受到X伤害后，使下次我方造成的伤害+X（不可叠加）。"
	effects[pilot_049_effect_02.effect_id] = pilot_049_effect_02

	# ── pilot_050 4+X范围耗2动1伤害 + 受伤X+1弃牌 ──
	var pilot_050_effect_01 := CardEffect.new()
	pilot_050_effect_01.effect_id = &"pilot_050_effect_01"
	pilot_050_effect_01.display_name = "范围耗动伤害"
	pilot_050_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_050_effect_01.hook = _EffectConst.HOOK_TURN_END
	pilot_050_effect_01.priority = 80
	pilot_050_effect_01.once_per_turn_key = &""
	pilot_050_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_050_effect_01.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 4, "variable_name": &"pilot_050_X"}]
	pilot_050_effect_01.costs = []
	pilot_050_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_050_effect_01",
			"text": "4+X格范围内的其他机甲每消耗2动力，可以使我方和该机甲各受到1伤害（X初始为0）。",
		}},
	]
	pilot_050_effect_01.description = "4+X格范围内的其他机甲每消耗2动力，可以使我方和该机甲各受到1伤害。"
	effects[pilot_050_effect_01.effect_id] = pilot_050_effect_01

	var pilot_050_effect_02 := CardEffect.new()
	pilot_050_effect_02.effect_id = &"pilot_050_effect_02"
	pilot_050_effect_02.display_name = "受伤X+1弃牌"
	pilot_050_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_050_effect_02.hook = _EffectConst.HOOK_OWNER_TAKE_DAMAGE
	pilot_050_effect_02.priority = 85
	pilot_050_effect_02.once_per_turn_key = &"pilot_050_effect_02"
	pilot_050_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_050_effect_02.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 4, "variable_name": &"pilot_050_X"}]
	pilot_050_effect_02.costs = []
	pilot_050_effect_02.actions = [
		{"type": &"INCREMENT_VARIABLE", "params": {"variable_name": &"pilot_050_X", "delta": 1}},
		{"type": &"DISCARD_ACTION_CARD", "params": {"count": 2}},
	]
	pilot_050_effect_02.description = "每回合1次，我方受到伤害后X的数值+1，之后可以弃置我方和4+X格范围内的1台其他机甲各2张行动牌。"
	effects[pilot_050_effect_02.effect_id] = pilot_050_effect_02

	# ── pilot_051 失去事件牌抽1 + 本局1次取消事件 ──
	var pilot_051_effect_01 := CardEffect.new()
	pilot_051_effect_01.effect_id = &"pilot_051_effect_01"
	pilot_051_effect_01.display_name = "失去事件抽1"
	pilot_051_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_051_effect_01.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_051_effect_01.priority = 80
	pilot_051_effect_01.once_per_turn_key = &"pilot_051_effect_01"
	pilot_051_effect_01.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"事件"},
	]
	pilot_051_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_051_effect_01.costs = []
	pilot_051_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	pilot_051_effect_01.description = "每回合1次，失去事件牌后可以立即抽1张事件牌设置到区域上。"
	effects[pilot_051_effect_01.effect_id] = pilot_051_effect_01

	var pilot_051_effect_02 := CardEffect.new()
	pilot_051_effect_02.effect_id = &"pilot_051_effect_02"
	pilot_051_effect_02.display_name = "本局1次取消事件"
	pilot_051_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_051_effect_02.hook = _EffectConst.HOOK_EVENT_SET
	pilot_051_effect_02.priority = 100
	pilot_051_effect_02.once_per_turn_key = &"pilot_051_effect_02_per_game"
	pilot_051_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_051_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_051_effect_02.costs = []
	pilot_051_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_051_effect_02",
			"text": "本局游戏1次，当1张事件牌被设置时，可以立即取消其效果，并弃置或设置到我方区域。",
		}},
	]
	pilot_051_effect_02.description = "本局游戏1次，当1张事件牌被设置时，可以立即取消其效果，并弃置或设置到我方区域。"
	effects[pilot_051_effect_02.effect_id] = pilot_051_effect_02

	# ── pilot_052 弃1行动抽1装备 ──
	var pilot_052_effect_01 := CardEffect.new()
	pilot_052_effect_01.effect_id = &"pilot_052_effect_01"
	pilot_052_effect_01.display_name = "弃1行动抽1装"
	pilot_052_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_052_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_052_effect_01.priority = 100
	pilot_052_effect_01.once_per_turn_key = &"pilot_052_effect_01"
	pilot_052_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_052_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_052_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_052_effect_01.actions = [
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
	]
	pilot_052_effect_01.description = "我方回合2次，可以弃置1张行动牌，之后抽1张装备牌。"
	effects[pilot_052_effect_01.effect_id] = pilot_052_effect_01

	# ── pilot_053 装备设置/弃置抽2+上限+1 ──
	var pilot_053_effect_01 := CardEffect.new()
	pilot_053_effect_01.effect_id = &"pilot_053_effect_01"
	pilot_053_effect_01.display_name = "装备变抽2+限+1"
	pilot_053_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_053_effect_01.hook = _EffectConst.HOOK_EQUIPMENT_SET
	pilot_053_effect_01.priority = 80
	pilot_053_effect_01.once_per_turn_key = &""
	pilot_053_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_053_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_053_effect_01.costs = []
	pilot_053_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
		{"type": &"MODIFY_ACTION_HAND_LIMIT", "params": {"delta": 1, "duration": &"NEXT_OWNER_TURN"}},
	]
	pilot_053_effect_01.description = "每回合1次，我方区域每次有正面朝上的装备牌被设置/弃置，立即抽2张行动牌，直到下个我方回合开始行动牌上限+1。"
	effects[pilot_053_effect_01.effect_id] = pilot_053_effect_01

	# ── pilot_054 购买后获3金或抽1 ──
	var pilot_054_effect_01 := CardEffect.new()
	pilot_054_effect_01.effect_id = &"pilot_054_effect_01"
	pilot_054_effect_01.display_name = "购买后获金或抽"
	pilot_054_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_054_effect_01.hook = _EffectConst.HOOK_SHOP_CARD_BOUGHT
	pilot_054_effect_01.priority = 80
	pilot_054_effect_01.once_per_turn_key = &"pilot_054_effect_01"
	pilot_054_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_054_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_054_effect_01.costs = []
	pilot_054_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_054_effect_01",
			"text": "我方回合2次，从商店购买装备牌后可以获得3金币或抽1张行动牌。若购买的是隐藏装备牌，则两个效果都可以执行。",
		}},
	]
	pilot_054_effect_01.description = "我方回合2次，从商店购买装备牌后可以获得3金币或抽1张行动牌。若购买的是隐藏装备牌，则两个效果都可以执行。"
	effects[pilot_054_effect_01.effect_id] = pilot_054_effect_01

	# ── pilot_055 卖出价格×2 ──
	var pilot_055_effect_01 := CardEffect.new()
	pilot_055_effect_01.effect_id = &"pilot_055_effect_01"
	pilot_055_effect_01.display_name = "卖出价格×2"
	pilot_055_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_055_effect_01.hook = _EffectConst.HOOK_EQUIPMENT_SOLD
	pilot_055_effect_01.priority = 80
	pilot_055_effect_01.once_per_turn_key = &"pilot_055_effect_01"
	pilot_055_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_055_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_055_effect_01.costs = []
	pilot_055_effect_01.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 0}},
	]
	pilot_055_effect_01.description = "每回合1次，卖出装备牌获得的金币×2。"
	effects[pilot_055_effect_01.effect_id] = pilot_055_effect_01

	# ── pilot_056 攻击未命中抽装备+他方获效 ──
	var pilot_056_effect_01 := CardEffect.new()
	pilot_056_effect_01.effect_id = &"pilot_056_effect_01"
	pilot_056_effect_01.display_name = "未命中抽装或获金"
	pilot_056_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_056_effect_01.hook = _EffectConst.HOOK_ATTACK_MISS
	pilot_056_effect_01.priority = 80
	pilot_056_effect_01.once_per_turn_key = &""
	pilot_056_effect_01.conditions = [
		{"op": &"PAYLOAD_ATTACK_MISS"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_056_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_056_effect_01.costs = []
	pilot_056_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_056_effect_01",
			"text": "若发动的攻击没有命中，则可以抽1张装备牌，之后设置到区域上，否则获得牌面记述数量的金币并立即弃置。",
		}},
	]
	pilot_056_effect_01.description = "若发动的攻击没有命中，则可以抽1张装备牌设置到区域上，否则获得牌面记述数量的金币并立即弃置。"
	effects[pilot_056_effect_01.effect_id] = pilot_056_effect_01

	var pilot_056_effect_02 := CardEffect.new()
	pilot_056_effect_02.effect_id = &"pilot_056_effect_02"
	pilot_056_effect_02.display_name = "他方获此效"
	pilot_056_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_056_effect_02.hook = _EffectConst.HOOK_OTHER_MECH_TURN_START
	pilot_056_effect_02.priority = 80
	pilot_056_effect_02.once_per_turn_key = &""
	pilot_056_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_056_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_056_effect_02.costs = [
		{"cost_type": &"SPEND_GOLD", "amount": 2},
	]
	pilot_056_effect_02.actions = [
		{"type": &"TOGGLE_EFFECT_ON_MECH", "params": {
			"effect_id": &"pilot_056_effect_01",
			"toggle": &"restore",
		}},
	]
	pilot_056_effect_02.description = "其他机甲回合开始时，可以通过消耗2金币使该机甲在当前回合内获得以上效果。"
	effects[pilot_056_effect_02.effect_id] = pilot_056_effect_02

	# ── pilot_057 当作设陷 + 弃牌移陷阱 ──
	var pilot_057_effect_01 := CardEffect.new()
	pilot_057_effect_01.effect_id = &"pilot_057_effect_01"
	pilot_057_effect_01.display_name = "当作设陷"
	pilot_057_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_057_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_057_effect_01.priority = 100
	pilot_057_effect_01.once_per_turn_key = &"pilot_057_effect_01"
	pilot_057_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_057_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_057_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_057_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"设陷"}},
	]
	pilot_057_effect_01.description = "每回合1次，可以将1张行动牌当作设陷使用。"
	effects[pilot_057_effect_01.effect_id] = pilot_057_effect_01

	var pilot_057_effect_02 := CardEffect.new()
	pilot_057_effect_02.effect_id = &"pilot_057_effect_02"
	pilot_057_effect_02.display_name = "弃牌移陷阱"
	pilot_057_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_057_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_057_effect_02.priority = 100
	pilot_057_effect_02.once_per_turn_key = &""
	pilot_057_effect_02.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_057_effect_02.target_rules = [{"rule": &"CHOOSE_MAP_CELL_IN_WEAPON_RANGE"}]
	pilot_057_effect_02.costs = [
		{"cost_type": &"DISCARD_VARIABLE_ACTION_CARDS"},
	]
	pilot_057_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_057_effect_02",
			"text": "我方回合中，可以通过弃置任意张行动牌，选择4格范围内的1个陷阱，每弃置1张牌就可使该陷阱移动4格。",
		}},
	]
	pilot_057_effect_02.description = "我方回合中，可以通过弃置任意张行动牌，选择4格范围内的1个陷阱，每弃置1张牌就可使该陷阱移动4格。"
	effects[pilot_057_effect_02.effect_id] = pilot_057_effect_02

	# ── pilot_058 展示行动牌+按类型加成 ──
	var pilot_058_effect_01 := CardEffect.new()
	pilot_058_effect_01.effect_id = &"pilot_058_effect_01"
	pilot_058_effect_01.display_name = "展示牌型加成"
	pilot_058_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_058_effect_01.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_058_effect_01.priority = 90
	pilot_058_effect_01.once_per_turn_key = &""
	pilot_058_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_058_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_058_effect_01.costs = []
	pilot_058_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_058_effect_01",
			"text": "发动攻击时可以展示所持任意张行动牌，其中每包含1种类型(攻击，迎击，辅助)，则本次攻击威力+2；若展示的行动牌包含3种类型，则本次攻击范围+2。",
		}},
	]
	pilot_058_effect_01.description = "发动攻击时可以展示所持行动牌，每包含1种类型则威力+2；若包含3种类型则范围+2。"
	effects[pilot_058_effect_01.effect_id] = pilot_058_effect_01


	# ═══════════════════════════════════════════
	# 效果路由器：将 JSON 中的原始 effect_id 映射到分解后的子效果
	# 对于拆分为多个子效果(01a/01b/01c等)的情况，注册原始ID为路由器效果
	# ═══════════════════════════════════════════

	# pilot_059 原始ID路由器
	var pilot_059_router := CardEffect.new()
	pilot_059_router.effect_id = &"pilot_059_effect_01"
	pilot_059_router.display_name = "薇尔-损伤分支选择"
	pilot_059_router.mode = _EffectConst.MODE_ACTIVE
	pilot_059_router.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_059_router.priority = 100
	pilot_059_router.once_per_turn_key = &"pilot_059_effect_01"
	pilot_059_router.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_059_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_059_router.costs = []
	pilot_059_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_059_effect_01",
			"text": "我方回合开始时，若机甲损伤数低于4则可以获得3金币/等于4则可以视为使用1张补给/大于4则可以移去最多2损伤。",
		}},
	]
	pilot_059_router.description = "我方回合开始时，若机甲损伤数低于4则可以获得3金币/等于4则可以视为使用1张补给/大于4则可以移去最多2损伤。"
	effects[pilot_059_router.effect_id] = pilot_059_router

	# pilot_060 原始ID路由器
	var pilot_060_router := CardEffect.new()
	pilot_060_router.effect_id = &"pilot_060_effect_01"
	pilot_060_router.display_name = "铠德-未命中选择"
	pilot_060_router.mode = _EffectConst.MODE_PASSIVE
	pilot_060_router.hook = _EffectConst.HOOK_ATTACK_MISS
	pilot_060_router.priority = 90
	pilot_060_router.once_per_turn_key = &"pilot_060_effect_01"
	pilot_060_router.conditions = [
		{"op": &"PAYLOAD_ATTACK_MISS"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_060_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_060_router.costs = []
	pilot_060_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_060_effect_01",
			"text": "若发动的攻击没有命中，则可以选择其一：抽2张行动牌/回复3动力/获得4金币。",
		}},
	]
	pilot_060_router.description = "若发动的攻击没有命中，则可以选择其一：抽2张行动牌/回复3动力/获得4金币。"
	effects[pilot_060_router.effect_id] = pilot_060_router

	# pilot_069 原始ID路由器
	var pilot_069_router := CardEffect.new()
	pilot_069_router.effect_id = &"pilot_069_effect_01"
	pilot_069_router.display_name = "影刹-未攻未移加成"
	pilot_069_router.mode = _EffectConst.MODE_PASSIVE
	pilot_069_router.hook = _EffectConst.HOOK_TURN_END
	pilot_069_router.priority = 90
	pilot_069_router.once_per_turn_key = &"pilot_069_effect_01"
	pilot_069_router.conditions = [{"op": &"ALWAYS"}]
	pilot_069_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_069_router.costs = []
	pilot_069_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_069_effect_01",
			"text": "每个我方回合结束时，若本回合未发动攻击，则下次攻击威力+4；若本回合未移动，则下次攻击范围+2。上述效果无法累加。",
		}},
	]
	pilot_069_router.description = "每个我方回合结束时，若本回合未发动攻击，则下次攻击威力+4；若本回合未移动，则下次攻击范围+2。"
	effects[pilot_069_router.effect_id] = pilot_069_router

	# pilot_072 原始ID路由器
	var pilot_072_router := CardEffect.new()
	pilot_072_router.effect_id = &"pilot_072_effect_01"
	pilot_072_router.display_name = "卡修-牌型回复动力"
	pilot_072_router.mode = _EffectConst.MODE_PASSIVE
	pilot_072_router.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_072_router.priority = 80
	pilot_072_router.once_per_turn_key = &""
	pilot_072_router.conditions = [{"op": &"ALWAYS"}]
	pilot_072_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_072_router.costs = []
	pilot_072_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_072_effect_01",
			"text": "每个效果每回合1次：使用辅助牌时，回复4动力；使用攻击牌时，回复4动力；使用迎击牌时，回复5动力。",
		}},
	]
	pilot_072_router.description = "每个效果每回合1次：使用辅助牌时，回复4动力；使用攻击牌时，回复4动力；使用迎击牌时，回复5动力。"
	effects[pilot_072_router.effect_id] = pilot_072_router

	# pilot_082 效果02原始ID路由器
	var pilot_082_effect_02_router := CardEffect.new()
	pilot_082_effect_02_router.effect_id = &"pilot_082_effect_02"
	pilot_082_effect_02_router.display_name = "温斯顿-攻当3类型"
	pilot_082_effect_02_router.mode = _EffectConst.MODE_ACTIVE
	pilot_082_effect_02_router.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_082_effect_02_router.priority = 100
	pilot_082_effect_02_router.once_per_turn_key = &"pilot_082_effect_02"
	pilot_082_effect_02_router.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_082_effect_02_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_082_effect_02_router.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_082_effect_02_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_082_effect_02",
			"text": "我方可以把攻击牌当作掩护/维修/推进之一使用。",
		}},
	]
	pilot_082_effect_02_router.description = "我方可以把攻击牌当作掩护/维修/推进之一使用。"
	effects[pilot_082_effect_02_router.effect_id] = pilot_082_effect_02_router

	# pilot_085 原始ID路由器
	var pilot_085_router := CardEffect.new()
	pilot_085_router.effect_id = &"pilot_085_effect_01"
	pilot_085_router.display_name = "莽克-装弃获金"
	pilot_085_router.mode = _EffectConst.MODE_PASSIVE
	pilot_085_router.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	pilot_085_router.priority = 80
	pilot_085_router.once_per_turn_key = &""
	pilot_085_router.conditions = [{"op": &"ALWAYS"}]
	pilot_085_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_085_router.costs = []
	pilot_085_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_085_effect_01",
			"text": "机甲上正面设置的装备牌弃置时，可立即获得4金币。场上其他机甲上正面设置的装备牌弃置时，可立即获得3金币。",
		}},
	]
	pilot_085_router.description = "机甲上正面设置的装备牌弃置时，可立即获得4金币。场上其他机甲上正面设置的装备牌弃置时，可立即获得3金币。"
	effects[pilot_085_router.effect_id] = pilot_085_router


# ═══════════════════════════════════════════
	# 批次K：SR稀有度机师效果（pilot_011-028）
	# ═══════════════════════════════════════════

	# ── pilot_011 迪恩：当作疾行/反击 + 使用时加成 ──
	# 效果01：每回合1次，可以将2张行动牌当作疾行/反击之一使用，之后抽1张行动牌
	var pilot_011_effect_01a := CardEffect.new()
	pilot_011_effect_01a.effect_id = &"pilot_011_effect_01a"
	pilot_011_effect_01a.display_name = "当作疾行"
	pilot_011_effect_01a.mode = _EffectConst.MODE_ACTIVE
	pilot_011_effect_01a.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_011_effect_01a.priority = 100
	pilot_011_effect_01a.once_per_turn_key = &"pilot_011_effect_01"
	pilot_011_effect_01a.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_011_effect_01a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_effect_01a.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_011_effect_01a.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"疾行"}},
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	pilot_011_effect_01a.description = "每回合1次，可以将2张行动牌当作疾行使用，之后抽1张行动牌。"
	effects[pilot_011_effect_01a.effect_id] = pilot_011_effect_01a

	var pilot_011_effect_01b := CardEffect.new()
	pilot_011_effect_01b.effect_id = &"pilot_011_effect_01b"
	pilot_011_effect_01b.display_name = "当作反击"
	pilot_011_effect_01b.mode = _EffectConst.MODE_ACTIVE
	pilot_011_effect_01b.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_011_effect_01b.priority = 100
	pilot_011_effect_01b.once_per_turn_key = &"pilot_011_effect_01"
	pilot_011_effect_01b.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_011_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_effect_01b.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_011_effect_01b.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"反击"}},
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	pilot_011_effect_01b.description = "每回合1次，可以将2张行动牌当作反击使用，之后抽1张行动牌。"
	effects[pilot_011_effect_01b.effect_id] = pilot_011_effect_01b

	# 效果02：我方使用对应牌时的加成 — 疾行回复4动力
	var pilot_011_effect_02a := CardEffect.new()
	pilot_011_effect_02a.effect_id = &"pilot_011_effect_02a"
	pilot_011_effect_02a.display_name = "疾行回复动力"
	pilot_011_effect_02a.mode = _EffectConst.MODE_PASSIVE
	pilot_011_effect_02a.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_011_effect_02a.priority = 80
	pilot_011_effect_02a.once_per_turn_key = &""
	pilot_011_effect_02a.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"疾行"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_011_effect_02a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_effect_02a.costs = []
	pilot_011_effect_02a.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 4}},
	]
	pilot_011_effect_02a.description = "我方使用疾行使我方回复4动力。"
	effects[pilot_011_effect_02a.effect_id] = pilot_011_effect_02a

	# 效果02：反击威力+3
	var pilot_011_effect_02b := CardEffect.new()
	pilot_011_effect_02b.effect_id = &"pilot_011_effect_02b"
	pilot_011_effect_02b.display_name = "反击威力+3"
	pilot_011_effect_02b.mode = _EffectConst.MODE_PASSIVE
	pilot_011_effect_02b.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_011_effect_02b.priority = 90
	pilot_011_effect_02b.once_per_turn_key = &""
	pilot_011_effect_02b.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"反击"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_011_effect_02b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_effect_02b.costs = []
	pilot_011_effect_02b.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3}},
	]
	pilot_011_effect_02b.description = "反击发出的攻击威力+3。"
	effects[pilot_011_effect_02b.effect_id] = pilot_011_effect_02b

	# ── pilot_012 玛丽尔：攻击时偷牌+扣动力，命中抽牌+回动力 ──
	var pilot_012_effect_01 := CardEffect.new()
	pilot_012_effect_01.effect_id = &"pilot_012_effect_01"
	pilot_012_effect_01.display_name = "攻击偷牌扣动力"
	pilot_012_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_012_effect_01.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_012_effect_01.priority = 90
	pilot_012_effect_01.once_per_turn_key = &"pilot_012_effect_01"
	pilot_012_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_012_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_012_effect_01.costs = []
	pilot_012_effect_01.actions = [
		{"type": &"STEAL_ACTION_CARD", "params": {"count": 1}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": -3, "target": &"target", "duration": &"THIS_TURN"}},
	]
	pilot_012_effect_01.description = "每回合1次，对其他机甲发动攻击时，可获得目标的1张行动牌并使目标当前动力-3。"
	effects[pilot_012_effect_01.effect_id] = pilot_012_effect_01

	# 命中时抽1+回3动力（需要单独效果跟踪命中）
	var pilot_012_effect_01b := CardEffect.new()
	pilot_012_effect_01b.effect_id = &"pilot_012_effect_01b"
	pilot_012_effect_01b.display_name = "命中抽牌回动力"
	pilot_012_effect_01b.mode = _EffectConst.MODE_PASSIVE
	pilot_012_effect_01b.hook = _EffectConst.HOOK_ATTACK_HIT
	pilot_012_effect_01b.priority = 80
	pilot_012_effect_01b.once_per_turn_key = &"pilot_012_effect_01b"
	pilot_012_effect_01b.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_012_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_012_effect_01b.costs = []
	pilot_012_effect_01b.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
		{"type": &"RESTORE_POWER", "params": {"amount": 3}},
	]
	pilot_012_effect_01b.description = "若攻击命中则我方可抽1张行动牌并回复3动力。"
	effects[pilot_012_effect_01b.effect_id] = pilot_012_effect_01b

	# ── pilot_013 巴托洛夫：免疫攻击外伤害 + 攻击时双方护甲动力-4命中+3 ──
	var pilot_013_effect_01 := CardEffect.new()
	pilot_013_effect_01.effect_id = &"pilot_013_effect_01"
	pilot_013_effect_01.display_name = "免疫攻击外伤害"
	pilot_013_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_013_effect_01.hook = _EffectConst.HOOK_OWNER_TAKE_DAMAGE
	pilot_013_effect_01.priority = 90
	pilot_013_effect_01.once_per_turn_key = &""
	pilot_013_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_013_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_013_effect_01.costs = []
	pilot_013_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_013_effect_01",
			"text": "我方不会受到攻击产生伤害外的任何其他伤害。",
		}},
	]
	pilot_013_effect_01.description = "我方不会受到攻击产生伤害外的任何其他伤害。"
	effects[pilot_013_effect_01.effect_id] = pilot_013_effect_01

	var pilot_013_effect_02 := CardEffect.new()
	pilot_013_effect_02.effect_id = &"pilot_013_effect_02"
	pilot_013_effect_02.display_name = "攻击双方减益+命中伤害+3"
	pilot_013_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_013_effect_02.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_013_effect_02.priority = 80
	pilot_013_effect_02.once_per_turn_key = &"pilot_013_effect_02"
	pilot_013_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_013_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_013_effect_02.costs = []
	pilot_013_effect_02.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": -4, "duration": &"NEXT_OWNER_TURN"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": -4, "duration": &"NEXT_OWNER_TURN"}},
		{"type": &"ADD_STATUS", "params": {"status_type": &"ARMOR_MODIFIER", "value": -4, "target": &"target", "duration": &"NEXT_OWNER_TURN"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": -4, "target": &"target", "duration": &"NEXT_OWNER_TURN"}},
		{"type": &"MODIFY_NEXT_DAMAGE_DEALT", "params": {"delta": 3}},
	]
	pilot_013_effect_02.description = "每回合1次，我方发动攻击时，使我方和攻击目标动力和护甲-4（持续到下个我方回合开始），命中产生的伤害+3。"
	effects[pilot_013_effect_02.effect_id] = pilot_013_effect_02

	# ── pilot_014 亚伦：选择机师牌，行动牌上限+2 ──
	var pilot_014_effect_01 := CardEffect.new()
	pilot_014_effect_01.effect_id = &"pilot_014_effect_01"
	pilot_014_effect_01.display_name = "机师行动上限+2"
	pilot_014_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_014_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_014_effect_01.priority = 100
	pilot_014_effect_01.once_per_turn_key = &"pilot_014_effect_01"
	pilot_014_effect_01.once_per_turn_max = 2
	pilot_014_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_014_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_014_effect_01.costs = []
	pilot_014_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_014_effect_01",
			"text": "我方回合2次，可以选择场上1张机师牌，使其行动牌上限+2（效果持续至下个我方回合开始）。",
		}},
	]
	pilot_014_effect_01.description = "我方回合2次，可以选择场上1张机师牌，使其行动牌上限+2（效果持续至下个我方回合开始）。"
	effects[pilot_014_effect_01.effect_id] = pilot_014_effect_01

	# ── pilot_015 诺拉：空手时攻击牌视为进攻/迎击牌视为防御 + 全部牌视为进攻/防御 ──
	var pilot_015_effect_01 := CardEffect.new()
	pilot_015_effect_01.effect_id = &"pilot_015_effect_01"
	pilot_015_effect_01.display_name = "空手类型转换"
	pilot_015_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_015_effect_01.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_015_effect_01.priority = 90
	pilot_015_effect_01.once_per_turn_key = &""
	pilot_015_effect_01.conditions = [
		{"op": &"OWNER_ACTION_HAND_EMPTY"},
	]
	pilot_015_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_015_effect_01.costs = []
	pilot_015_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_015_effect_01",
			"text": "我方所持行动牌数为0时，指定我方为攻击目标的攻击牌全部视为进攻，并还原威力为牌面记述的数值；响应我方攻击的迎击牌全部视为防御。",
		}},
	]
	pilot_015_effect_01.description = "我方所持行动牌数为0时，指定我方为攻击目标的攻击牌全部视为进攻，并还原威力为牌面记述的数值；响应我方攻击的迎击牌全部视为防御。"
	effects[pilot_015_effect_01.effect_id] = pilot_015_effect_01

	# 效果02：每回合1次，将全部行动牌视为进攻/防御之一使用
	var pilot_015_effect_02a := CardEffect.new()
	pilot_015_effect_02a.effect_id = &"pilot_015_effect_02a"
	pilot_015_effect_02a.display_name = "全部当进攻"
	pilot_015_effect_02a.mode = _EffectConst.MODE_ACTIVE
	pilot_015_effect_02a.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_015_effect_02a.priority = 100
	pilot_015_effect_02a.once_per_turn_key = &"pilot_015_effect_02"
	pilot_015_effect_02a.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_015_effect_02a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_015_effect_02a.costs = []
	pilot_015_effect_02a.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_015_effect_02a",
			"text": "每回合1次，可以将全部行动牌（至少1张）视为进攻使用。",
		}},
	]
	pilot_015_effect_02a.description = "每回合1次，可以将全部行动牌（至少1张）视为进攻使用。"
	effects[pilot_015_effect_02a.effect_id] = pilot_015_effect_02a

	var pilot_015_effect_02b := CardEffect.new()
	pilot_015_effect_02b.effect_id = &"pilot_015_effect_02b"
	pilot_015_effect_02b.display_name = "全部当防御"
	pilot_015_effect_02b.mode = _EffectConst.MODE_ACTIVE
	pilot_015_effect_02b.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_015_effect_02b.priority = 100
	pilot_015_effect_02b.once_per_turn_key = &"pilot_015_effect_02"
	pilot_015_effect_02b.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_015_effect_02b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_015_effect_02b.costs = []
	pilot_015_effect_02b.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_015_effect_02b",
			"text": "每回合1次，可以将全部行动牌（至少1张）视为防御使用。",
		}},
	]
	pilot_015_effect_02b.description = "每回合1次，可以将全部行动牌（至少1张）视为防御使用。"
	effects[pilot_015_effect_02b.effect_id] = pilot_015_effect_02b

	# ── pilot_016 默多克：展示1张+2张视为该牌 ──
	var pilot_016_effect_01 := CardEffect.new()
	pilot_016_effect_01.effect_id = &"pilot_016_effect_01"
	pilot_016_effect_01.display_name = "展示1+2张视为该牌"
	pilot_016_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_016_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_016_effect_01.priority = 100
	pilot_016_effect_01.once_per_turn_key = &"pilot_016_effect_01"
	pilot_016_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_016_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_016_effect_01.costs = []
	pilot_016_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_016_effect_01",
			"text": "每回合1次，可以展示持有的1张行动牌，之后将另外2张行动牌视为该展示的牌使用。",
		}},
	]
	pilot_016_effect_01.description = "每回合1次，可以展示持有的1张行动牌，之后将另外2张行动牌视为该展示的牌使用。"
	effects[pilot_016_effect_01.effect_id] = pilot_016_effect_01

	# ── pilot_017 伏特：当作强袭/猛击/破甲 + 使用时加成 ──
	# 效果01：每回合1次，将2张行动牌当作强袭/猛击/破甲之一使用
	var pilot_017_effect_01a := CardEffect.new()
	pilot_017_effect_01a.effect_id = &"pilot_017_effect_01a"
	pilot_017_effect_01a.display_name = "当作强袭"
	pilot_017_effect_01a.mode = _EffectConst.MODE_ACTIVE
	pilot_017_effect_01a.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_017_effect_01a.priority = 100
	pilot_017_effect_01a.once_per_turn_key = &"pilot_017_effect_01"
	pilot_017_effect_01a.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_017_effect_01a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_01a.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_017_effect_01a.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"强袭"}},
	]
	pilot_017_effect_01a.description = "每回合1次，可以将2张行动牌当作强袭使用。"
	effects[pilot_017_effect_01a.effect_id] = pilot_017_effect_01a

	var pilot_017_effect_01b := CardEffect.new()
	pilot_017_effect_01b.effect_id = &"pilot_017_effect_01b"
	pilot_017_effect_01b.display_name = "当作猛击"
	pilot_017_effect_01b.mode = _EffectConst.MODE_ACTIVE
	pilot_017_effect_01b.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_017_effect_01b.priority = 100
	pilot_017_effect_01b.once_per_turn_key = &"pilot_017_effect_01"
	pilot_017_effect_01b.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_017_effect_01b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_01b.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_017_effect_01b.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"猛击"}},
	]
	pilot_017_effect_01b.description = "每回合1次，可以将2张行动牌当作猛击使用。"
	effects[pilot_017_effect_01b.effect_id] = pilot_017_effect_01b

	var pilot_017_effect_01c := CardEffect.new()
	pilot_017_effect_01c.effect_id = &"pilot_017_effect_01c"
	pilot_017_effect_01c.display_name = "当作破甲"
	pilot_017_effect_01c.mode = _EffectConst.MODE_ACTIVE
	pilot_017_effect_01c.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_017_effect_01c.priority = 100
	pilot_017_effect_01c.once_per_turn_key = &"pilot_017_effect_01"
	pilot_017_effect_01c.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_017_effect_01c.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_01c.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_017_effect_01c.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"破甲"}},
	]
	pilot_017_effect_01c.description = "每回合1次，可以将2张行动牌当作破甲使用。"
	effects[pilot_017_effect_01c.effect_id] = pilot_017_effect_01c

	# 效果02：使用对应牌时的加成 — 强袭回复4动力
	var pilot_017_effect_02a := CardEffect.new()
	pilot_017_effect_02a.effect_id = &"pilot_017_effect_02a"
	pilot_017_effect_02a.display_name = "强袭回复动力"
	pilot_017_effect_02a.mode = _EffectConst.MODE_PASSIVE
	pilot_017_effect_02a.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_017_effect_02a.priority = 80
	pilot_017_effect_02a.once_per_turn_key = &""
	pilot_017_effect_02a.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"强袭"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_017_effect_02a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_02a.costs = []
	pilot_017_effect_02a.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 4}},
	]
	pilot_017_effect_02a.description = "强袭使我方回复4动力。"
	effects[pilot_017_effect_02a.effect_id] = pilot_017_effect_02a

	# 猛击威力+3
	var pilot_017_effect_02b := CardEffect.new()
	pilot_017_effect_02b.effect_id = &"pilot_017_effect_02b"
	pilot_017_effect_02b.display_name = "猛击威力+3"
	pilot_017_effect_02b.mode = _EffectConst.MODE_PASSIVE
	pilot_017_effect_02b.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_017_effect_02b.priority = 90
	pilot_017_effect_02b.once_per_turn_key = &""
	pilot_017_effect_02b.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"猛击"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_017_effect_02b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_02b.costs = []
	pilot_017_effect_02b.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3}},
	]
	pilot_017_effect_02b.description = "猛击使本次攻击威力+3。"
	effects[pilot_017_effect_02b.effect_id] = pilot_017_effect_02b

	# 破甲命中后损伤+2
	var pilot_017_effect_02c := CardEffect.new()
	pilot_017_effect_02c.effect_id = &"pilot_017_effect_02c"
	pilot_017_effect_02c.display_name = "破甲命中损伤+2"
	pilot_017_effect_02c.mode = _EffectConst.MODE_PASSIVE
	pilot_017_effect_02c.hook = _EffectConst.HOOK_AFTER_DAMAGE_TOKEN_PLACED
	pilot_017_effect_02c.priority = 80
	pilot_017_effect_02c.once_per_turn_key = &""
	pilot_017_effect_02c.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"破甲"},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_017_effect_02c.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_02c.costs = []
	pilot_017_effect_02c.actions = [
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": 2}},
	]
	pilot_017_effect_02c.description = "破甲命中后产生损伤+2。"
	effects[pilot_017_effect_02c.effect_id] = pilot_017_effect_02c

	# ── pilot_018 苔丝：被攻击时抽2张，迎击后弃攻击方牌 ──
	var pilot_018_effect_01 := CardEffect.new()
	pilot_018_effect_01.effect_id = &"pilot_018_effect_01"
	pilot_018_effect_01.display_name = "被攻抽牌+迎击弃牌"
	pilot_018_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_018_effect_01.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	pilot_018_effect_01.priority = 90
	pilot_018_effect_01.once_per_turn_key = &"pilot_018_effect_01"
	pilot_018_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_018_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_018_effect_01.costs = []
	pilot_018_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_018_effect_01_counter",
			"text": "若我方通过使用迎击牌响应了此攻击，则弃置攻击方的3张行动牌或1张设置损伤≥2的装备牌。",
		}},
	]
	pilot_018_effect_01.description = "每回合1次，被攻击时，可立即抽2张行动牌，若迎击则弃攻击方的3张行动牌或1张损伤≥2装备牌。"
	effects[pilot_018_effect_01.effect_id] = pilot_018_effect_01

	# ── pilot_019 肯耳忒：弃X张→对手弃X+1张→清空则3伤害 ──
	var pilot_019_effect_01 := CardEffect.new()
	pilot_019_effect_01.effect_id = &"pilot_019_effect_01"
	pilot_019_effect_01.display_name = "弃牌连锁伤害"
	pilot_019_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_019_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_019_effect_01.priority = 100
	pilot_019_effect_01.once_per_turn_key = &"pilot_019_effect_01"
	pilot_019_effect_01.once_per_turn_max = 2
	pilot_019_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_019_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_019_effect_01.costs = []
	pilot_019_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_019_effect_01",
			"text": "我方回合2次，通过弃置X张行动牌（X最低为1），弃置1台其他机甲X+1张行动牌，若因此清空该机甲所持行动牌（其原本行动牌至少有1张），则可对其造成3伤害。",
		}},
	]
	pilot_019_effect_01.description = "我方回合2次，弃X张行动牌→对手弃X+1张→清空则3伤害。"
	effects[pilot_019_effect_01.effect_id] = pilot_019_effect_01

	# ── pilot_020 肯德：弃牌+阈值分级效果 ──
	# 效果01：主动弃牌（每回合1次）
	var pilot_020_effect_01 := CardEffect.new()
	pilot_020_effect_01.effect_id = &"pilot_020_effect_01"
	pilot_020_effect_01.display_name = "弃任意行动牌"
	pilot_020_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_020_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_020_effect_01.priority = 100
	pilot_020_effect_01.once_per_turn_key = &"pilot_020_effect_01"
	pilot_020_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_020_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_01.costs = []
	pilot_020_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_020_effect_01",
			"text": "我方回合1次，可以弃置任意张行动牌。",
		}},
	]
	pilot_020_effect_01.description = "我方回合1次，可以弃置任意张行动牌。"
	effects[pilot_020_effect_01.effect_id] = pilot_020_effect_01

	# 效果02：弃牌>1时，护甲+2动力+3
	var pilot_020_effect_02 := CardEffect.new()
	pilot_020_effect_02.effect_id = &"pilot_020_effect_02"
	pilot_020_effect_02.display_name = "弃牌>1护甲+2动力+3"
	pilot_020_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_02.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_020_effect_02.priority = 80
	pilot_020_effect_02.once_per_turn_key = &""
	pilot_020_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_020_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_02.costs = []
	pilot_020_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_020_effect_02",
			"text": "每个回合我方行动牌被弃置大于1时，当前回合我方护甲+2，动力+3。",
		}},
	]
	pilot_020_effect_02.description = "弃牌>1时，当前回合护甲+2，动力+3。"
	effects[pilot_020_effect_02.effect_id] = pilot_020_effect_02

	# 效果03：弃牌>3时，攻击威力+2范围+1
	var pilot_020_effect_03 := CardEffect.new()
	pilot_020_effect_03.effect_id = &"pilot_020_effect_03"
	pilot_020_effect_03.display_name = "弃牌>3威力+2范围+1"
	pilot_020_effect_03.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_03.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_020_effect_03.priority = 70
	pilot_020_effect_03.once_per_turn_key = &""
	pilot_020_effect_03.conditions = [{"op": &"ALWAYS"}]
	pilot_020_effect_03.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_03.costs = []
	pilot_020_effect_03.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_020_effect_03",
			"text": "每个回合我方行动牌被弃置大于3时，当前回合攻击时，威力+2，范围+1。",
		}},
	]
	pilot_020_effect_03.description = "弃牌>3时，当前回合攻击威力+2，范围+1。"
	effects[pilot_020_effect_03.effect_id] = pilot_020_effect_03

	# 效果04：弃牌>5时，回合结束抽被弃置数量
	var pilot_020_effect_04 := CardEffect.new()
	pilot_020_effect_04.effect_id = &"pilot_020_effect_04"
	pilot_020_effect_04.display_name = "弃牌>5回合结束抽牌"
	pilot_020_effect_04.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_04.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_020_effect_04.priority = 60
	pilot_020_effect_04.once_per_turn_key = &""
	pilot_020_effect_04.conditions = [{"op": &"ALWAYS"}]
	pilot_020_effect_04.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_04.costs = []
	pilot_020_effect_04.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_020_effect_04",
			"text": "每个回合我方行动牌被弃置大于5时，当前回合结束后抽取被弃置数量的行动牌。",
		}},
	]
	pilot_020_effect_04.description = "弃牌>5时，回合结束后抽被弃置数量的行动牌。"
	effects[pilot_020_effect_04.effect_id] = pilot_020_effect_04

	# 效果05：综合路由器（描述完整效果）
	var pilot_020_effect_05 := CardEffect.new()
	pilot_020_effect_05.effect_id = &"pilot_020_effect_05"
	pilot_020_effect_05.display_name = "肯德-弃牌阈值分级"
	pilot_020_effect_05.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_05.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_020_effect_05.priority = 90
	pilot_020_effect_05.once_per_turn_key = &""
	pilot_020_effect_05.conditions = [{"op": &"ALWAYS"}]
	pilot_020_effect_05.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_05.costs = []
	pilot_020_effect_05.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_020_effect_05",
			"text": "每个回合我方行动牌被弃置一定数目，可获得对应效果：大于1：当前回合我方护甲+2，动力+3；大于3：当前回合攻击时，威力+2，范围+1；大于5：当前回合结束后抽取被弃置数量的行动牌。",
		}},
	]
	pilot_020_effect_05.description = "弃牌分级：>1护甲+2动力+3；>3威力+2范围+1；>5回合结束抽牌。"
	effects[pilot_020_effect_05.effect_id] = pilot_020_effect_05

	# ── pilot_021 塔莉娅：抽3分配+使用后抽2 ──
	var pilot_021_effect_01 := CardEffect.new()
	pilot_021_effect_01.effect_id = &"pilot_021_effect_01"
	pilot_021_effect_01.display_name = "抽3分配"
	pilot_021_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_021_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_021_effect_01.priority = 100
	pilot_021_effect_01.once_per_turn_key = &"pilot_021_effect_01"
	pilot_021_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_021_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_021_effect_01.costs = []
	pilot_021_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_021_effect_01",
			"text": "我方回合1次，可以抽3张行动牌，之后可以给予4格范围内的其他机甲其中的1张牌（每台机甲最多给1张），剩余的牌本回合无法使用。",
		}},
	]
	pilot_021_effect_01.description = "我方回合1次，抽3张行动牌，给予范围内其他机甲1张，剩余本回合无法使用。"
	effects[pilot_021_effect_01.effect_id] = pilot_021_effect_01

	# 效果02：其他机甲使用从我方获得的行动牌后，我方抽2张
	var pilot_021_effect_02 := CardEffect.new()
	pilot_021_effect_02.effect_id = &"pilot_021_effect_02"
	pilot_021_effect_02.display_name = "对方用牌后抽2"
	pilot_021_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_021_effect_02.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_021_effect_02.priority = 80
	pilot_021_effect_02.once_per_turn_key = &""
	pilot_021_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_021_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_021_effect_02.costs = []
	pilot_021_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_021_effect_02",
			"text": "其他机甲使用从我方处获得的行动牌后，我方抽2张行动牌。",
		}},
	]
	pilot_021_effect_02.description = "其他机甲使用从我方处获得的行动牌后，我方抽2张行动牌。"
	effects[pilot_021_effect_02.effect_id] = pilot_021_effect_02

	# ── pilot_022 提比里安：本局游戏1次，攻击威力1.5倍+范围+3+锁定 ──
	var pilot_022_effect_01 := CardEffect.new()
	pilot_022_effect_01.effect_id = &"pilot_022_effect_01"
	pilot_022_effect_01.display_name = "本局1次威力1.5倍+范围+3+锁定"
	pilot_022_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_022_effect_01.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_022_effect_01.priority = 90
	pilot_022_effect_01.once_per_turn_key = &"pilot_022_effect_01_game"
	pilot_022_effect_01.once_per_turn_max = 1
	pilot_022_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_022_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_022_effect_01.costs = []
	pilot_022_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_022_effect_01",
			"text": "本局游戏1次，发动攻击时，可以使该攻击的初始威力变成武器牌面记述威力的1.5倍(向下取整)，范围+3，施加锁定效果。",
		}},
	]
	pilot_022_effect_01.description = "本局游戏1次，攻击威力1.5倍(向下取整)+范围+3+锁定。"
	effects[pilot_022_effect_01.effect_id] = pilot_022_effect_01

	# ── pilot_023 坎得：当作维修 + 维修额外移2损伤+相邻可用 ──
	var pilot_023_effect_01 := CardEffect.new()
	pilot_023_effect_01.effect_id = &"pilot_023_effect_01"
	pilot_023_effect_01.display_name = "当作维修"
	pilot_023_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_023_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_023_effect_01.priority = 100
	pilot_023_effect_01.once_per_turn_key = &"pilot_023_effect_01"
	pilot_023_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_023_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_023_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_023_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"维修"}},
	]
	pilot_023_effect_01.description = "每回合1次，可以将1张行动牌当作维修使用。"
	effects[pilot_023_effect_01.effect_id] = pilot_023_effect_01

	# 效果02：维修时额外移2损伤+可对相邻4格其他机甲使用
	var pilot_023_effect_02 := CardEffect.new()
	pilot_023_effect_02.effect_id = &"pilot_023_effect_02"
	pilot_023_effect_02.display_name = "维修增强+相邻可用"
	pilot_023_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_023_effect_02.hook = _EffectConst.HOOK_BEFORE_REMOVE_DAMAGE_TOKENS
	pilot_023_effect_02.priority = 80
	pilot_023_effect_02.once_per_turn_key = &""
	pilot_023_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"维修"},
	]
	pilot_023_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_023_effect_02.costs = []
	pilot_023_effect_02.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"count": 2}},
	]
	pilot_023_effect_02.description = "我方使用的维修获得：额外移去2损伤，可以对相邻4格的其他机甲使用。"
	effects[pilot_023_effect_02.effect_id] = pilot_023_effect_02

	# ── pilot_024 琳：当作维修 + 远程维修交互 ──
	var pilot_024_effect_01 := CardEffect.new()
	pilot_024_effect_01.effect_id = &"pilot_024_effect_01"
	pilot_024_effect_01.display_name = "当作维修"
	pilot_024_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_024_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_024_effect_01.priority = 100
	pilot_024_effect_01.once_per_turn_key = &"pilot_024_effect_01"
	pilot_024_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_024_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_024_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_024_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"维修"}},
	]
	pilot_024_effect_01.description = "每回合1次，可以将1张行动牌当作维修使用。"
	effects[pilot_024_effect_01.effect_id] = pilot_024_effect_01

	# 效果02：4格范围内其他机甲可在其回合让我方对其远程维修
	var pilot_024_effect_02 := CardEffect.new()
	pilot_024_effect_02.effect_id = &"pilot_024_effect_02"
	pilot_024_effect_02.display_name = "远程维修交互"
	pilot_024_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_024_effect_02.hook = _EffectConst.HOOK_OTHER_MECH_TURN_START
	pilot_024_effect_02.priority = 80
	pilot_024_effect_02.once_per_turn_key = &""
	pilot_024_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_024_effect_02.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_024_effect_02.costs = []
	pilot_024_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_024_effect_02",
			"text": "在4格范围内的其他机甲可以在其回合内1次，使我方可以对其使用1次无距离限制的维修，之后其与我方各抽1张行动牌。",
		}},
	]
	pilot_024_effect_02.description = "4格范围内其他机甲可让我方对其远程维修，之后各抽1张行动牌。"
	effects[pilot_024_effect_02.effect_id] = pilot_024_effect_02

	# ── pilot_025 约书亚：攻击或被攻时选择抽装备+设置 ──
	# 效果01：每回合1次，攻击或被攻击时选其一
	var pilot_025_effect_01 := CardEffect.new()
	pilot_025_effect_01.effect_id = &"pilot_025_effect_01"
	pilot_025_effect_01.display_name = "攻防抽装备设置"
	pilot_025_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_025_effect_01.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_025_effect_01.priority = 90
	pilot_025_effect_01.once_per_turn_key = &"pilot_025_effect_01"
	pilot_025_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_025_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_025_effect_01.costs = []
	pilot_025_effect_01.actions = [
		{"type": &"CHOOSE_ONE", "params": {
			"options": [
				{
					"label": &"抽1装备设置",
					"actions": [
						{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
						{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
							"effect_id": &"pilot_025_set_or_discard",
							"text": "立即抽1张装备牌设置到区域上（否则立即弃置）。",
						}},
					],
				},
				{
					"label": &"设置备用区装备",
					"actions": [
						{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
							"effect_id": &"pilot_025_set_reserve",
							"text": "立即设置1张处于备用区的装备牌。",
						}},
					],
				},
			],
		}},
	]
	pilot_025_effect_01.description = "每回合1次，我方攻击或被攻击时，可以选择其一：抽1装备设置或设置备用区装备。"
	effects[pilot_025_effect_01.effect_id] = pilot_025_effect_01

	# 效果02：被攻击时也触发
	var pilot_025_effect_02 := CardEffect.new()
	pilot_025_effect_02.effect_id = &"pilot_025_effect_02"
	pilot_025_effect_02.display_name = "被攻抽装备设置"
	pilot_025_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_025_effect_02.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	pilot_025_effect_02.priority = 90
	pilot_025_effect_02.once_per_turn_key = &"pilot_025_effect_01"
	pilot_025_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_025_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_025_effect_02.costs = []
	pilot_025_effect_02.actions = [
		{"type": &"CHOOSE_ONE", "params": {
			"options": [
				{
					"label": &"抽1装备设置",
					"actions": [
						{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
						{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
							"effect_id": &"pilot_025_set_or_discard",
							"text": "立即抽1张装备牌设置到区域上（否则立即弃置）。",
						}},
					],
				},
				{
					"label": &"设置备用区装备",
					"actions": [
						{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
							"effect_id": &"pilot_025_set_reserve",
							"text": "立即设置1张处于备用区的装备牌。",
						}},
					],
				},
			],
		}},
	]
	pilot_025_effect_02.description = "每回合1次，被攻击时，可以选择其一：抽1装备设置或设置备用区装备。"
	effects[pilot_025_effect_02.effect_id] = pilot_025_effect_02

	# 效果03：综合路由器
	var pilot_025_effect_03 := CardEffect.new()
	pilot_025_effect_03.effect_id = &"pilot_025_effect_03"
	pilot_025_effect_03.display_name = "约书亚-攻防装备设置"
	pilot_025_effect_03.mode = _EffectConst.MODE_PASSIVE
	pilot_025_effect_03.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_025_effect_03.priority = 100
	pilot_025_effect_03.once_per_turn_key = &""
	pilot_025_effect_03.conditions = [{"op": &"ALWAYS"}]
	pilot_025_effect_03.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_025_effect_03.costs = []
	pilot_025_effect_03.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_025_effect_03",
			"text": "每回合1次，我方攻击或被攻击时，可以选择其一：立即抽1张装备牌设置到区域上（否则立即弃置）；立即设置1张处于于备用区的装备牌。",
		}},
	]
	pilot_025_effect_03.description = "每回合1次，攻击或被攻击时选其一：抽1装备设置/设置备用区装备。"
	effects[pilot_025_effect_03.effect_id] = pilot_025_effect_03

	# ── pilot_026 伊万：当作设陷+4次陷阱+陷阱改伤害 ──
	var pilot_026_effect_01 := CardEffect.new()
	pilot_026_effect_01.effect_id = &"pilot_026_effect_01"
	pilot_026_effect_01.display_name = "当作设陷"
	pilot_026_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_026_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_026_effect_01.priority = 100
	pilot_026_effect_01.once_per_turn_key = &"pilot_026_effect_01"
	pilot_026_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_026_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_026_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_026_effect_01.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"设陷"}},
	]
	pilot_026_effect_01.description = "每回合1次，可以将1张行动牌当作设陷使用。"
	effects[pilot_026_effect_01.effect_id] = pilot_026_effect_01

	# 效果02：设陷共4次机会设置陷阱
	var pilot_026_effect_02 := CardEffect.new()
	pilot_026_effect_02.effect_id = &"pilot_026_effect_02"
	pilot_026_effect_02.display_name = "4次设陷"
	pilot_026_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_026_effect_02.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_026_effect_02.priority = 80
	pilot_026_effect_02.once_per_turn_key = &""
	pilot_026_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"设陷"},
	]
	pilot_026_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_026_effect_02.costs = []
	pilot_026_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_026_effect_02",
			"text": "我方使用的设陷共有4次机会设置陷阱。",
		}},
	]
	pilot_026_effect_02.description = "我方使用的设陷共有4次机会设置陷阱。"
	effects[pilot_026_effect_02.effect_id] = pilot_026_effect_02

	# 效果03：陷阱对我方仅造成伤害，不设置损伤
	var pilot_026_effect_03 := CardEffect.new()
	pilot_026_effect_03.effect_id = &"pilot_026_effect_03"
	pilot_026_effect_03.display_name = "陷阱改伤害"
	pilot_026_effect_03.mode = _EffectConst.MODE_PASSIVE
	pilot_026_effect_03.hook = _EffectConst.HOOK_BEFORE_DAMAGE_TOKEN_PLACED
	pilot_026_effect_03.priority = 90
	pilot_026_effect_03.once_per_turn_key = &""
	pilot_026_effect_03.conditions = [{"op": &"ALWAYS"}]
	pilot_026_effect_03.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_026_effect_03.costs = []
	pilot_026_effect_03.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_026_effect_03",
			"text": "陷阱对我方仅会造成伤害，不会设置损伤。",
		}},
	]
	pilot_026_effect_03.description = "陷阱对我方仅会造成伤害，不会设置损伤。"
	effects[pilot_026_effect_03.effect_id] = pilot_026_effect_03

	# ── pilot_027 维罗妮卡：金币分半+给金2+使用行动牌 ──
	# 效果01：4+X格范围内其他机甲获金时我方获一半
	var pilot_027_effect_01 := CardEffect.new()
	pilot_027_effect_01.effect_id = &"pilot_027_effect_01"
	pilot_027_effect_01.display_name = "获金分半"
	pilot_027_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_027_effect_01.hook = _EffectConst.HOOK_OTHER_MECH_GAIN_GOLD
	pilot_027_effect_01.priority = 80
	pilot_027_effect_01.once_per_turn_key = &""
	pilot_027_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_027_effect_01.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 4, "variable_name": &"pilot_027_x"}]
	pilot_027_effect_01.costs = []
	pilot_027_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_027_effect_01",
			"text": "4+X格范围内的其他机甲获得金币时（X初始为0，我方每次给予其他机甲金币会使X数值+1），我方获得其中的一半金币（向下取整）。",
		}},
	]
	pilot_027_effect_01.description = "4+X格范围内其他机甲获金时我方获一半(X初始0,给金+1)。"
	effects[pilot_027_effect_01.effect_id] = pilot_027_effect_01

	# 效果02：每回合1次，给4+X格范围其他机甲2金+使其使用1张行动牌
	var pilot_027_effect_02 := CardEffect.new()
	pilot_027_effect_02.effect_id = &"pilot_027_effect_02"
	pilot_027_effect_02.display_name = "给金2+使用行动牌"
	pilot_027_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_027_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_027_effect_02.priority = 100
	pilot_027_effect_02.once_per_turn_key = &"pilot_027_effect_02"
	pilot_027_effect_02.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_027_effect_02.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 4, "variable_name": &"pilot_027_x"}]
	pilot_027_effect_02.costs = [
		{"cost_type": &"SPEND_GOLD", "amount": 2},
	]
	pilot_027_effect_02.actions = [
		{"type": &"INCREMENT_VARIABLE", "params": {"variable_name": &"pilot_027_x", "delta": 1}},
		{"type": &"FORCE_MECH_ACTION", "params": {"action": &"use_one_action_card"}},
	]
	pilot_027_effect_02.description = "每回合1次，给予4+X格范围内其他机甲2金币，使其使用1张行动牌。"
	effects[pilot_027_effect_02.effect_id] = pilot_027_effect_02

	# ── pilot_028 乌尔：宣言类型+获得/弃置宣言牌后抽1 ──
	var pilot_028_effect_01 := CardEffect.new()
	pilot_028_effect_01.effect_id = &"pilot_028_effect_01"
	pilot_028_effect_01.display_name = "宣言+获得宣言牌"
	pilot_028_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_028_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_028_effect_01.priority = 90
	pilot_028_effect_01.once_per_turn_key = &""
	pilot_028_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_028_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_028_effect_01.costs = []
	pilot_028_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_028_effect_01",
			"text": "每个回合开始时，可以宣言1种行动牌类型(攻击，迎击，辅助)，若在本回合使用/弃置了宣言类型的行动牌，则我方之后获得之并抽1张行动牌。",
		}},
	]
	pilot_028_effect_01.description = "每回合开始宣言1种类型，使用/弃置宣言牌后获得之并抽1张。"
	effects[pilot_028_effect_01.effect_id] = pilot_028_effect_01


	# ═══════════════════════════════════════════
	# 批次K路由器：将 JSON 中的原始 effect_id 映射到分解后的子效果
	# ═══════════════════════════════════════════

	# pilot_011 效果01原始ID路由器
	var pilot_011_effect_01_router := CardEffect.new()
	pilot_011_effect_01_router.effect_id = &"pilot_011_effect_01"
	pilot_011_effect_01_router.display_name = "迪恩-当作疾行/反击"
	pilot_011_effect_01_router.mode = _EffectConst.MODE_ACTIVE
	pilot_011_effect_01_router.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_011_effect_01_router.priority = 100
	pilot_011_effect_01_router.once_per_turn_key = &"pilot_011_effect_01"
	pilot_011_effect_01_router.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_011_effect_01_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_effect_01_router.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_011_effect_01_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_011_effect_01",
			"text": "每回合1次，可以将2张行动牌当作疾行/反击之一使用，之后抽1张行动牌。",
		}},
	]
	pilot_011_effect_01_router.description = "每回合1次，可以将2张行动牌当作疾行/反击之一使用，之后抽1张行动牌。"
	effects[pilot_011_effect_01_router.effect_id] = pilot_011_effect_01_router

	# pilot_011 效果02路由器
	var pilot_011_effect_02_router := CardEffect.new()
	pilot_011_effect_02_router.effect_id = &"pilot_011_effect_02"
	pilot_011_effect_02_router.display_name = "迪恩-使用加成"
	pilot_011_effect_02_router.mode = _EffectConst.MODE_PASSIVE
	pilot_011_effect_02_router.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_011_effect_02_router.priority = 80
	pilot_011_effect_02_router.once_per_turn_key = &""
	pilot_011_effect_02_router.conditions = [{"op": &"ALWAYS"}]
	pilot_011_effect_02_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_effect_02_router.costs = []
	pilot_011_effect_02_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_011_effect_02",
			"text": "我方使用对应牌时：疾行使我方回复4动力，反击发出的攻击威力+3。",
		}},
	]
	pilot_011_effect_02_router.description = "我方使用对应牌时：疾行使我方回复4动力，反击发出的攻击威力+3。"
	effects[pilot_011_effect_02_router.effect_id] = pilot_011_effect_02_router

	# pilot_012 效果01路由器（合并攻击时和命中时两个子效果）
	var pilot_012_effect_01_router := CardEffect.new()
	pilot_012_effect_01_router.effect_id = &"pilot_012_effect_01"
	pilot_012_effect_01_router.display_name = "玛丽尔-攻击偷牌扣动力"
	pilot_012_effect_01_router.mode = _EffectConst.MODE_PASSIVE
	pilot_012_effect_01_router.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_012_effect_01_router.priority = 90
	pilot_012_effect_01_router.once_per_turn_key = &"pilot_012_effect_01"
	pilot_012_effect_01_router.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	pilot_012_effect_01_router.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_012_effect_01_router.costs = []
	pilot_012_effect_01_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_012_effect_01",
			"text": "每回合1次，对其他机甲发动攻击时，可获得目标的1张行动牌并使目标当前动力-3，若攻击命中则我方可抽1张行动牌并回复3动力。",
		}},
	]
	pilot_012_effect_01_router.description = "每回合1次，对其他机甲发动攻击时，可获得目标的1张行动牌并使目标当前动力-3，若攻击命中则我方可抽1张行动牌并回复3动力。"
	effects[pilot_012_effect_01_router.effect_id] = pilot_012_effect_01_router

	# pilot_015 效果02路由器
	var pilot_015_effect_02_router := CardEffect.new()
	pilot_015_effect_02_router.effect_id = &"pilot_015_effect_02"
	pilot_015_effect_02_router.display_name = "诺拉-全部视为进攻/防御"
	pilot_015_effect_02_router.mode = _EffectConst.MODE_ACTIVE
	pilot_015_effect_02_router.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_015_effect_02_router.priority = 100
	pilot_015_effect_02_router.once_per_turn_key = &"pilot_015_effect_02"
	pilot_015_effect_02_router.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_015_effect_02_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_015_effect_02_router.costs = []
	pilot_015_effect_02_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_015_effect_02",
			"text": "每回合1次，可以将全部行动牌（至少1张）视为进攻/防御之一使用。",
		}},
	]
	pilot_015_effect_02_router.description = "每回合1次，可以将全部行动牌（至少1张）视为进攻/防御之一使用。"
	effects[pilot_015_effect_02_router.effect_id] = pilot_015_effect_02_router

	# pilot_017 效果01路由器
	var pilot_017_effect_01_router := CardEffect.new()
	pilot_017_effect_01_router.effect_id = &"pilot_017_effect_01"
	pilot_017_effect_01_router.display_name = "伏特-当作强袭/猛击/破甲"
	pilot_017_effect_01_router.mode = _EffectConst.MODE_ACTIVE
	pilot_017_effect_01_router.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_017_effect_01_router.priority = 100
	pilot_017_effect_01_router.once_per_turn_key = &"pilot_017_effect_01"
	pilot_017_effect_01_router.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_017_effect_01_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_01_router.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_017_effect_01_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_017_effect_01",
			"text": "每回合1次，可以将2张行动牌当作强袭/猛击/破甲之一使用。",
		}},
	]
	pilot_017_effect_01_router.description = "每回合1次，可以将2张行动牌当作强袭/猛击/破甲之一使用。"
	effects[pilot_017_effect_01_router.effect_id] = pilot_017_effect_01_router

	# pilot_017 效果02路由器
	var pilot_017_effect_02_router := CardEffect.new()
	pilot_017_effect_02_router.effect_id = &"pilot_017_effect_02"
	pilot_017_effect_02_router.display_name = "伏特-使用加成"
	pilot_017_effect_02_router.mode = _EffectConst.MODE_PASSIVE
	pilot_017_effect_02_router.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_017_effect_02_router.priority = 80
	pilot_017_effect_02_router.once_per_turn_key = &""
	pilot_017_effect_02_router.conditions = [{"op": &"ALWAYS"}]
	pilot_017_effect_02_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_02_router.costs = []
	pilot_017_effect_02_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_017_effect_02",
			"text": "我方使用对应牌时：强袭使我方回复4动力，猛击使本次攻击威力+3，破甲命中后产生损伤+2。",
		}},
	]
	pilot_017_effect_02_router.description = "我方使用对应牌时：强袭回复4动力，猛击威力+3，破甲命中损伤+2。"
	effects[pilot_017_effect_02_router.effect_id] = pilot_017_effect_02_router
	# ═══════════════════════════════════════════
		# 批次J：SSR稀有度机师效果（pilot_001-010）将在下一迭代中添加
	# ═══════════════════════════════════════════

	# ── pilot_001 阿克罗姆：第1张行动牌效果生效2次 ──
	var pilot_001_effect_01 := CardEffect.new()
	pilot_001_effect_01.effect_id = &"pilot_001_effect_01"
	pilot_001_effect_01.display_name = "首牌双效"
	pilot_001_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_001_effect_01.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_001_effect_01.priority = 90
	pilot_001_effect_01.once_per_turn_key = &""
	pilot_001_effect_01.conditions = [
		{"op": &"IS_FIRST_ATTACK_THIS_TURN"},
	]
	pilot_001_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_001_effect_01.costs = []
	pilot_001_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_001_effect_01",
			"text": "每回合第1张使用的行动牌，该效果可以生效2次（2次独立结算，第1次效果结算完成后，若条件满足则第2次效果立即生效）。",
		}},
	]
	pilot_001_effect_01.description = "每回合第1张使用的行动牌，该效果可以生效2次。"
	effects[pilot_001_effect_01.effect_id] = pilot_001_effect_01

	# ── pilot_002 莱比尔：联邦光环(交牌+护甲+4) + 取消/恢复 ──
	# 效果01：联邦机师获得交牌+抽2效果
	var pilot_002_effect_01 := CardEffect.new()
	pilot_002_effect_01.effect_id = &"pilot_002_effect_01"
	pilot_002_effect_01.display_name = "联邦交牌光环"
	pilot_002_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_002_effect_01.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_002_effect_01.priority = 100
	pilot_002_effect_01.once_per_turn_key = &""
	pilot_002_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_002_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_002_effect_01.costs = []
	pilot_002_effect_01.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"联邦",
			"granted_effect_id": &"pilot_002_aura_transfer_draw",
		}},
	]
	pilot_002_effect_01.description = "场上所有联邦阵营的机师牌获得：可以将任意张行动牌交给5格范围内1台其他机甲并当作进攻或防御使用，之后抽2张行动牌。"
	effects[pilot_002_effect_01.effect_id] = pilot_002_effect_01

	# 效果02：联邦机甲护甲+4
	var pilot_002_effect_02 := CardEffect.new()
	pilot_002_effect_02.effect_id = &"pilot_002_effect_02"
	pilot_002_effect_02.display_name = "联邦护甲+4光环"
	pilot_002_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_002_effect_02.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_002_effect_02.priority = 99
	pilot_002_effect_02.once_per_turn_key = &""
	pilot_002_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_002_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_002_effect_02.costs = []
	pilot_002_effect_02.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"联邦",
			"granted_effect_id": &"pilot_002_aura_armor",
		}},
	]
	pilot_002_effect_02.description = "场上所有联邦阵营的机甲框架获得：机甲护甲+4。"
	effects[pilot_002_effect_02.effect_id] = pilot_002_effect_02

	# 效果03：每回合1次，取消或恢复1台机甲获得上述效果
	var pilot_002_effect_03 := CardEffect.new()
	pilot_002_effect_03.effect_id = &"pilot_002_effect_03"
	pilot_002_effect_03.display_name = "取消/恢复光环"
	pilot_002_effect_03.mode = _EffectConst.MODE_ACTIVE
	pilot_002_effect_03.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_002_effect_03.priority = 100
	pilot_002_effect_03.once_per_turn_key = &"pilot_002_effect_03"
	pilot_002_effect_03.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_002_effect_03.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_002_effect_03.costs = []
	pilot_002_effect_03.actions = [
		{"type": &"TOGGLE_EFFECT_ON_MECH", "params": {
			"effect_ids": [&"pilot_002_aura_transfer_draw", &"pilot_002_aura_armor"],
		}},
	]
	pilot_002_effect_03.description = "我方回合1次，取消或恢复1台机甲获得上述效果。"
	effects[pilot_002_effect_03.effect_id] = pilot_002_effect_03

	# ── pilot_003 瑟尔基尔：正面朝上放牌堆+跳过抽牌+1 ──
	var pilot_003_effect_01 := CardEffect.new()
	pilot_003_effect_01.effect_id = &"pilot_003_effect_01"
	pilot_003_effect_01.display_name = "正面朝上放牌堆"
	pilot_003_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_003_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_003_effect_01.priority = 100
	pilot_003_effect_01.once_per_turn_key = &"pilot_003_effect_01"
	pilot_003_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_003_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_003_effect_01.costs = []
	pilot_003_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_003_effect_01",
			"text": "我方回合1次，将任意张行动牌正面朝上随机放入行动牌堆，并可以选择其中1张放置在牌堆顶，当这些牌离开牌堆时立即由我方使用，若无法使用则改为弃置该牌并使我方抽2张行动牌。",
		}},
	]
	pilot_003_effect_01.description = "我方回合1次，将行动牌正面朝上放入牌堆，离开时自动使用或弃置抽2。"
	effects[pilot_003_effect_01.effect_id] = pilot_003_effect_01

	var pilot_003_effect_02 := CardEffect.new()
	pilot_003_effect_02.effect_id = &"pilot_003_effect_02"
	pilot_003_effect_02.display_name = "跳过正面牌抽+1"
	pilot_003_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_003_effect_02.hook = _EffectConst.HOOK_ACTION_CARD_DRAWN
	pilot_003_effect_02.priority = 90
	pilot_003_effect_02.once_per_turn_key = &""
	pilot_003_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_003_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_003_effect_02.costs = []
	pilot_003_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_003_effect_02",
			"text": "我方每次抽取行动牌时可以跳过牌堆正面朝上的牌，若如此做，则此次抽牌数+1。",
		}},
	]
	pilot_003_effect_02.description = "我方每次抽取行动牌时可以跳过牌堆正面朝上的牌，若如此做，则此次抽牌数+1。"
	effects[pilot_003_effect_02.effect_id] = pilot_003_effect_02

	# ── pilot_004 玛沙：护甲转动力+抽牌 + 消耗6动力抽装备 ──
	var pilot_004_effect_01 := CardEffect.new()
	pilot_004_effect_01.effect_id = &"pilot_004_effect_01"
	pilot_004_effect_01.display_name = "护甲转动力+抽牌"
	pilot_004_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_004_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_004_effect_01.priority = 90
	pilot_004_effect_01.once_per_turn_key = &""
	pilot_004_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_004_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_004_effect_01.costs = []
	pilot_004_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_004_effect_01",
			"text": "每个回合开始时，可以将任意数值的护甲转化为动力，每转化2点可立即抽1张行动牌，下个我方回合即将开始时护甲回复。",
		}},
	]
	pilot_004_effect_01.description = "每回合开始时，可以将护甲转化为动力，每2点抽1张行动牌，下回合回复。"
	effects[pilot_004_effect_01.effect_id] = pilot_004_effect_01

	var pilot_004_effect_02 := CardEffect.new()
	pilot_004_effect_02.effect_id = &"pilot_004_effect_02"
	pilot_004_effect_02.display_name = "消耗6动力抽装备"
	pilot_004_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_004_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_004_effect_02.priority = 100
	pilot_004_effect_02.once_per_turn_key = &"pilot_004_effect_02"
	pilot_004_effect_02.once_per_turn_max = 2
	pilot_004_effect_02.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_004_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_004_effect_02.costs = [
		{"cost_type": &"SPEND_POWER", "amount": 6},
	]
	pilot_004_effect_02.actions = [
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
	]
	pilot_004_effect_02.description = "我方回合2次，可以消耗6动力抽1张装备牌。"
	effects[pilot_004_effect_02.effect_id] = pilot_004_effect_02

	# ── pilot_005 肯特：帝国光环(攻防弃牌+动力+4) + 取消/恢复 ──
	var pilot_005_effect_01 := CardEffect.new()
	pilot_005_effect_01.effect_id = &"pilot_005_effect_01"
	pilot_005_effect_01.display_name = "帝国攻防弃牌光环"
	pilot_005_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_005_effect_01.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_005_effect_01.priority = 100
	pilot_005_effect_01.once_per_turn_key = &""
	pilot_005_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_005_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_005_effect_01.costs = []
	pilot_005_effect_01.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"帝国",
			"granted_effect_id": &"pilot_005_aura_discard",
		}},
	]
	pilot_005_effect_01.description = "场上所有帝国阵营的机师牌获得：攻击或被攻击时可以消耗4动力，弃置目标或攻击方2张行动牌。"
	effects[pilot_005_effect_01.effect_id] = pilot_005_effect_01

	var pilot_005_effect_02 := CardEffect.new()
	pilot_005_effect_02.effect_id = &"pilot_005_effect_02"
	pilot_005_effect_02.display_name = "帝国动力+4光环"
	pilot_005_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_005_effect_02.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_005_effect_02.priority = 99
	pilot_005_effect_02.once_per_turn_key = &""
	pilot_005_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_005_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_005_effect_02.costs = []
	pilot_005_effect_02.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"帝国",
			"granted_effect_id": &"pilot_005_aura_power",
		}},
	]
	pilot_005_effect_02.description = "场上所有帝国阵营的机甲框架获得：机甲动力+4。"
	effects[pilot_005_effect_02.effect_id] = pilot_005_effect_02

	var pilot_005_effect_03 := CardEffect.new()
	pilot_005_effect_03.effect_id = &"pilot_005_effect_03"
	pilot_005_effect_03.display_name = "取消/恢复光环"
	pilot_005_effect_03.mode = _EffectConst.MODE_ACTIVE
	pilot_005_effect_03.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_005_effect_03.priority = 100
	pilot_005_effect_03.once_per_turn_key = &"pilot_005_effect_03"
	pilot_005_effect_03.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_005_effect_03.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_005_effect_03.costs = []
	pilot_005_effect_03.actions = [
		{"type": &"TOGGLE_EFFECT_ON_MECH", "params": {
			"effect_ids": [&"pilot_005_aura_discard", &"pilot_005_aura_power"],
		}},
	]
	pilot_005_effect_03.description = "我方回合1次，取消或恢复1台机甲获得上述效果。"
	effects[pilot_005_effect_03.effect_id] = pilot_005_effect_03

	# ── pilot_006 里昂：每轮选目标+攻击时抽牌+强攻/伤害 ──
	var pilot_006_effect_01 := CardEffect.new()
	pilot_006_effect_01.effect_id = &"pilot_006_effect_01"
	pilot_006_effect_01.display_name = "每轮选目标+攻击抽牌"
	pilot_006_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_006_effect_01.hook = _EffectConst.HOOK_ROUND_START
	pilot_006_effect_01.priority = 90
	pilot_006_effect_01.once_per_turn_key = &""
	pilot_006_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_006_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_006_effect_01.costs = []
	pilot_006_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_006_effect_01",
			"text": "每轮开始时，选择1台其他机甲为目标，本轮中目标被攻击时，攻击方抽1张行动牌，若抽到是攻击牌，之后对该目标使用此牌不计回合攻击数。",
		}},
	]
	pilot_006_effect_01.description = "每轮开始选1台其他机甲为目标，目标被攻击时攻击方抽1牌，若为攻击牌则不计攻击数使用。"
	effects[pilot_006_effect_01.effect_id] = pilot_006_effect_01

	var pilot_006_effect_02 := CardEffect.new()
	pilot_006_effect_02.effect_id = &"pilot_006_effect_02"
	pilot_006_effect_02.display_name = "强攻或4伤害"
	pilot_006_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_006_effect_02.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_006_effect_02.priority = 80
	pilot_006_effect_02.once_per_turn_key = &"pilot_006_effect_02"
	pilot_006_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_006_effect_02.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 5}]
	pilot_006_effect_02.costs = []
	pilot_006_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_006_effect_02",
			"text": "每回合1次，我方攻击时，选择1台5格范围内的其他机甲，其选择立即使用1张攻击牌，或受到4伤害。",
		}},
	]
	pilot_006_effect_02.description = "每回合1次，我方攻击时，选择5格内其他机甲，其使用1张攻击牌或受4伤害。"
	effects[pilot_006_effect_02.effect_id] = pilot_006_effect_02

	# ── pilot_007 珀修斯：获得攻击牌+展示弃牌 ──
	var pilot_007_effect_01 := CardEffect.new()
	pilot_007_effect_01.effect_id = &"pilot_007_effect_01"
	pilot_007_effect_01.display_name = "获得攻击牌"
	pilot_007_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_007_effect_01.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	pilot_007_effect_01.priority = 90
	pilot_007_effect_01.once_per_turn_key = &"pilot_007_effect_01"
	pilot_007_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_007_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_007_effect_01.costs = []
	pilot_007_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_007_effect_01",
			"text": "每回合1次，指定我方为目标的攻击牌结算后，可以获得该攻击牌并立即使用。",
		}},
	]
	pilot_007_effect_01.description = "每回合1次，指定我方为目标的攻击牌结算后，可以获得该攻击牌并立即使用。"
	effects[pilot_007_effect_01.effect_id] = pilot_007_effect_01

	var pilot_007_effect_02 := CardEffect.new()
	pilot_007_effect_02.effect_id = &"pilot_007_effect_02"
	pilot_007_effect_02.display_name = "展示弃牌"
	pilot_007_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_007_effect_02.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_007_effect_02.priority = 80
	pilot_007_effect_02.once_per_turn_key = &"pilot_007_effect_02"
	pilot_007_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_007_effect_02.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 99}]
	pilot_007_effect_02.costs = []
	pilot_007_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_007_effect_02",
			"text": "每回合1次，我方使用攻击牌时，可以展示目标所持行动牌，其中每缺少1种类型(攻击，迎击，辅助)，便可弃置其中1张牌。",
		}},
	]
	pilot_007_effect_02.description = "每回合1次，攻击时展示目标行动牌，每缺少1种类型弃1张。"
	effects[pilot_007_effect_02.effect_id] = pilot_007_effect_02

	# ── pilot_008 安德洛美达：维修获得+X变量+回血改伤害+移损伤改设损伤 ──
	var pilot_008_effect_01 := CardEffect.new()
	pilot_008_effect_01.effect_id = &"pilot_008_effect_01"
	pilot_008_effect_01.display_name = "维修获得+X+1"
	pilot_008_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_008_effect_01.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_008_effect_01.priority = 90
	pilot_008_effect_01.once_per_turn_key = &"pilot_008_effect_01"
	pilot_008_effect_01.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"维修"},
	]
	pilot_008_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_008_effect_01.costs = []
	pilot_008_effect_01.actions = [
		{"type": &"GAIN_SPECIFIC_CARD", "params": {"from": &"discard", "tag": &"维修"}},
		{"type": &"INCREMENT_VARIABLE", "params": {"variable_name": &"pilot_008_x", "delta": 1}},
	]
	pilot_008_effect_01.description = "每回合1次，维修被使用或弃置后，我方获得之，并使X数值+1（X初始为0）。"
	effects[pilot_008_effect_01.effect_id] = pilot_008_effect_01

	var pilot_008_effect_02 := CardEffect.new()
	pilot_008_effect_02.effect_id = &"pilot_008_effect_02"
	pilot_008_effect_02.display_name = "回血改伤害"
	pilot_008_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_008_effect_02.hook = _EffectConst.HOOK_BEFORE_HEAL
	pilot_008_effect_02.priority = 90
	pilot_008_effect_02.once_per_turn_key = &"pilot_008_effect_02"
	pilot_008_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_008_effect_02.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 5, "variable_name": &"pilot_008_x"}]
	pilot_008_effect_02.costs = []
	pilot_008_effect_02.actions = [
		{"type": &"REDIRECT_HEAL_TO_DAMAGE", "params": {}},
	]
	pilot_008_effect_02.description = "每回合1次，5+X格范围内的机甲即将回复生命时，可将效果改为受到等量伤害。"
	effects[pilot_008_effect_02.effect_id] = pilot_008_effect_02

	var pilot_008_effect_03 := CardEffect.new()
	pilot_008_effect_03.effect_id = &"pilot_008_effect_03"
	pilot_008_effect_03.display_name = "移损伤改设损伤"
	pilot_008_effect_03.mode = _EffectConst.MODE_ACTIVE
	pilot_008_effect_03.hook = _EffectConst.HOOK_BEFORE_REMOVE_DAMAGE_TOKENS
	pilot_008_effect_03.priority = 90
	pilot_008_effect_03.once_per_turn_key = &"pilot_008_effect_03"
	pilot_008_effect_03.conditions = [{"op": &"ALWAYS"}]
	pilot_008_effect_03.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 5, "variable_name": &"pilot_008_x"}]
	pilot_008_effect_03.costs = []
	pilot_008_effect_03.actions = [
		{"type": &"REDIRECT_REMOVE_TO_PLACE_TOKENS", "params": {}},
	]
	pilot_008_effect_03.description = "每回合1次，5+X格范围内的机甲即将移除损伤时，可将效果改为设置等量损伤（位置由我方指定）。"
	effects[pilot_008_effect_03.effect_id] = pilot_008_effect_03

	# ── pilot_009 美杜莎：弃牌记录类型+展示+使用/弃置 ──
	var pilot_009_effect_01 := CardEffect.new()
	pilot_009_effect_01.effect_id = &"pilot_009_effect_01"
	pilot_009_effect_01.display_name = "弃牌记录+展示使用"
	pilot_009_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_009_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_009_effect_01.priority = 100
	pilot_009_effect_01.once_per_turn_key = &"pilot_009_effect_01"
	pilot_009_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_009_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 5}]
	pilot_009_effect_01.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	]
	pilot_009_effect_01.actions = [
		{"type": &"DECLARE_CARD_TYPE", "params": {}},
		{"type": &"REVEAL_OR_PEEK_CARD", "params": {"mode": &"reveal", "target": &"enemy_action_hand", "filter_by_type": &"declared"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_009_effect_01",
			"text": "我方回合1次，可以弃置1张行动牌并记录其类型(攻击，迎击，辅助)，之后选择1台5格范围内的其他机甲展示其持有的和记录类型相同的所有行动牌，这回合我方可以使用这些牌或立即全部弃置。",
		}},
	]
	pilot_009_effect_01.description = "我方回合1次，弃1牌记录类型，展示目标同类型牌，使用或全部弃置。"
	effects[pilot_009_effect_01.effect_id] = pilot_009_effect_01

	# ── pilot_010 刻托：互换上限攻击数 + 攻击牌类型递进 ──
	var pilot_010_effect_01 := CardEffect.new()
	pilot_010_effect_01.effect_id = &"pilot_010_effect_01"
	pilot_010_effect_01.display_name = "互换上限攻击数"
	pilot_010_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_010_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_010_effect_01.priority = 90
	pilot_010_effect_01.once_per_turn_key = &""
	pilot_010_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_010_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_010_effect_01.costs = []
	pilot_010_effect_01.actions = [
		{"type": &"SWAP_HAND_LIMIT_AND_ATTACK_COUNT", "params": {}},
	]
	pilot_010_effect_01.description = "我方回合开始时，可以使我方行动牌上限与回合攻击数互换数值，之后抽取当前行动牌上限张行动牌。"
	effects[pilot_010_effect_01.effect_id] = pilot_010_effect_01

	# 效果02：第1张攻击牌视作强袭
	var pilot_010_effect_02a := CardEffect.new()
	pilot_010_effect_02a.effect_id = &"pilot_010_effect_02a"
	pilot_010_effect_02a.display_name = "第1攻=强袭"
	pilot_010_effect_02a.mode = _EffectConst.MODE_PASSIVE
	pilot_010_effect_02a.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_010_effect_02a.priority = 90
	pilot_010_effect_02a.once_per_turn_key = &""
	pilot_010_effect_02a.conditions = [
		{"op": &"ATTACK_COUNT_EQUALS", "count": 1},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_010_effect_02a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_010_effect_02a.costs = []
	pilot_010_effect_02a.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"强袭"}},
	]
	pilot_010_effect_02a.description = "每个回合内，我方使用的第一张攻击牌视作强袭。"
	effects[pilot_010_effect_02a.effect_id] = pilot_010_effect_02a

	# 第2张攻击牌视作闪击
	var pilot_010_effect_02b := CardEffect.new()
	pilot_010_effect_02b.effect_id = &"pilot_010_effect_02b"
	pilot_010_effect_02b.display_name = "第2攻=闪击"
	pilot_010_effect_02b.mode = _EffectConst.MODE_PASSIVE
	pilot_010_effect_02b.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_010_effect_02b.priority = 80
	pilot_010_effect_02b.once_per_turn_key = &""
	pilot_010_effect_02b.conditions = [
		{"op": &"ATTACK_COUNT_EQUALS", "count": 2},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_010_effect_02b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_010_effect_02b.costs = []
	pilot_010_effect_02b.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"闪击"}},
	]
	pilot_010_effect_02b.description = "每个回合内，我方使用的第二张攻击牌视作闪击。"
	effects[pilot_010_effect_02b.effect_id] = pilot_010_effect_02b

	# 第3张攻击牌视作预判
	var pilot_010_effect_02c := CardEffect.new()
	pilot_010_effect_02c.effect_id = &"pilot_010_effect_02c"
	pilot_010_effect_02c.display_name = "第3攻=预判"
	pilot_010_effect_02c.mode = _EffectConst.MODE_PASSIVE
	pilot_010_effect_02c.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_010_effect_02c.priority = 70
	pilot_010_effect_02c.once_per_turn_key = &""
	pilot_010_effect_02c.conditions = [
		{"op": &"ATTACK_COUNT_EQUALS", "count": 3},
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_010_effect_02c.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_010_effect_02c.costs = []
	pilot_010_effect_02c.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"预判"}},
	]
	pilot_010_effect_02c.description = "每个回合内，我方使用的第三张攻击牌视作预判。"
	effects[pilot_010_effect_02c.effect_id] = pilot_010_effect_02c

	# pilot_010 效果02路由器
	var pilot_010_effect_02_router := CardEffect.new()
	pilot_010_effect_02_router.effect_id = &"pilot_010_effect_02"
	pilot_010_effect_02_router.display_name = "刻托-攻击牌类型递进"
	pilot_010_effect_02_router.mode = _EffectConst.MODE_PASSIVE
	pilot_010_effect_02_router.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_010_effect_02_router.priority = 90
	pilot_010_effect_02_router.once_per_turn_key = &""
	pilot_010_effect_02_router.conditions = [{"op": &"ALWAYS"}]
	pilot_010_effect_02_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_010_effect_02_router.costs = []
	pilot_010_effect_02_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_010_effect_02",
			"text": "每个回合内，我方使用的第一张攻击牌视作强袭，第二张攻击牌视作闪击，第三张攻击牌视作预判。",
		}},
	]
	pilot_010_effect_02_router.description = "每个回合内，我方使用的第一张攻击牌视作强袭，第二张攻击牌视作闪击，第三张攻击牌视作预判。"
	effects[pilot_010_effect_02_router.effect_id] = pilot_010_effect_02_router

	return effects
