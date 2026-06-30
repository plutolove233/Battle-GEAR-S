# ═══════════════════════════════════════════
# 批次K：SR稀有度机师效果（pilot_011-028）
# ═══════════════════════════════════════════

	# ── pilot_011 迪恩：2张当作疾行/反击+对应加成 ──
	# 效果01a：当作疾行
	var pilot_011_effect_01a := CardEffect.new()
	pilot_011_effect_01a.effect_id = &"pilot_011_effect_01a"
	pilot_011_effect_01a.display_name = "迪恩-当作疾行"
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

	# 效果01b：当作反击
	var pilot_011_effect_01b := CardEffect.new()
	pilot_011_effect_01b.effect_id = &"pilot_011_effect_01b"
	pilot_011_effect_01b.display_name = "迪恩-当作反击"
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

	# 效果02：疾行回复4动力 / 反击威力+3
	var pilot_011_effect_02 := CardEffect.new()
	pilot_011_effect_02.effect_id = &"pilot_011_effect_02"
	pilot_011_effect_02.display_name = "迪恩-疾行回4动/反击+3威"
	pilot_011_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_011_effect_02.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	pilot_011_effect_02.priority = 80
	pilot_011_effect_02.once_per_turn_key = &""
	pilot_011_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_011_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_effect_02.costs = []
	pilot_011_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_011_effect_02",
			"text": "我方使用对应牌时：疾行使我方回复4动力，反击发出的攻击威力+3。",
		}},
	]
	pilot_011_effect_02.description = "我方使用对应牌时：疾行使我方回复4动力，反击发出的攻击威力+3。"
	effects[pilot_011_effect_02.effect_id] = pilot_011_effect_02

	# pilot_011 原始ID路由器
	var pilot_011_router := CardEffect.new()
	pilot_011_router.effect_id = &"pilot_011_effect_01"
	pilot_011_router.display_name = "迪恩-当作疾行/反击"
	pilot_011_router.mode = _EffectConst.MODE_ACTIVE
	pilot_011_router.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_011_router.priority = 100
	pilot_011_router.once_per_turn_key = &"pilot_011_effect_01"
	pilot_011_router.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_011_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_011_router.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_011_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_011_effect_01",
			"text": "每回合1次，可以将2张行动牌当作疾行/反击之一使用，之后抽1张行动牌。",
		}},
	]
	pilot_011_router.description = "每回合1次，可以将2张行动牌当作疾行/反击之一使用，之后抽1张行动牌。"
	effects[pilot_011_router.effect_id] = pilot_011_router

	# ── pilot_012 玛丽尔：攻击偷牌+动力-3+命中抽1回3动 ──
	var pilot_012_effect_01 := CardEffect.new()
	pilot_012_effect_01.effect_id = &"pilot_012_effect_01"
	pilot_012_effect_01.display_name = "玛丽尔-攻偷牌动-3"
	pilot_012_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_012_effect_01.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_012_effect_01.priority = 80
	pilot_012_effect_01.once_per_turn_key = &"pilot_012_effect_01"
	pilot_012_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_012_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_012_effect_01.costs = []
	pilot_012_effect_01.actions = [
		{"type": &"STEAL_ACTION_CARD", "params": {"from_target": true, "count": 1}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": -3, "target": &"target", "duration": &"THIS_TURN"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_012_effect_01",
			"text": "每回合1次，对其他机甲发动攻击时，可获得目标的1张行动牌并使目标当前动力-3，若攻击命中则我方可抽1张行动牌并回复3动力。",
		}},
	]
	pilot_012_effect_01.description = "每回合1次，对其他机甲发动攻击时，可获得目标的1张行动牌并使目标当前动力-3，若攻击命中则我方可抽1张行动牌并回复3动力。"
	effects[pilot_012_effect_01.effect_id] = pilot_012_effect_01

	# ── pilot_013 巴托洛夫：不受攻击外伤害+攻时双方-4+伤害+3 ──
	# 效果01：不受到攻击产生伤害外的任何其他伤害
	var pilot_013_effect_01 := CardEffect.new()
	pilot_013_effect_01.effect_id = &"pilot_013_effect_01"
	pilot_013_effect_01.display_name = "巴托洛夫-仅受攻击伤害"
	pilot_013_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_013_effect_01.hook = _EffectConst.HOOK_OWNER_TAKE_DAMAGE
	pilot_013_effect_01.priority = 80
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

	# 效果02：攻时双方动力和护甲-4+命中伤害+3
	var pilot_013_effect_02 := CardEffect.new()
	pilot_013_effect_02.effect_id = &"pilot_013_effect_02"
	pilot_013_effect_02.display_name = "巴托洛夫-攻时双方-4"
	pilot_013_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_013_effect_02.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_013_effect_02.priority = 80
	pilot_013_effect_02.once_per_turn_key = &"pilot_013_effect_02"
	pilot_013_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_013_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_013_effect_02.costs = []
	pilot_013_effect_02.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": -4, "duration": &"UNTIL_NEXT_OWNER_TURN"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": -4, "duration": &"UNTIL_NEXT_OWNER_TURN"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_013_effect_02",
			"text": "每回合1次，我方发动攻击时，可以使我方和攻击目标动力和护甲-4（持续到下个我方回合开始），命中产生的伤害+3。",
		}},
	]
	pilot_013_effect_02.description = "每回合1次，我方发动攻击时，可以使我方和攻击目标动力和护甲-4（持续到下个我方回合开始），命中产生的伤害+3。"
	effects[pilot_013_effect_02.effect_id] = pilot_013_effect_02

	# ── pilot_014 亚伦：选机师牌行动上限+2 ──
	var pilot_014_effect_01 := CardEffect.new()
	pilot_014_effect_01.effect_id = &"pilot_014_effect_01"
	pilot_014_effect_01.display_name = "亚伦-机师上限+2"
	pilot_014_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_014_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_014_effect_01.priority = 100
	pilot_014_effect_01.once_per_turn_key = &"pilot_014_effect_01"
	pilot_014_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_014_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_014_effect_01.costs = []
	pilot_014_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_014_effect_01",
			"text": "我方回合2次，可以选择场上1张机师牌，使其行动牌上限+2（效果持续至下个我方回合开始）。",
		}},
	]
	pilot_014_effect_01.description = "我方回合2次，可以选择场上1张机师牌，使其行动牌上限+2（效果持续至下个我方回合开始）。"
	effects[pilot_014_effect_01.effect_id] = pilot_014_effect_01

	# ── pilot_015 诺拉：手牌0时攻击牌视为进攻+全部当作进攻/防御 ──
	# 效果01：手牌为0时攻击牌视为进攻/迎击视为防御
	var pilot_015_effect_01 := CardEffect.new()
	pilot_015_effect_01.effect_id = &"pilot_015_effect_01"
	pilot_015_effect_01.display_name = "诺拉-空手牌视为进攻防御"
	pilot_015_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_015_effect_01.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	pilot_015_effect_01.priority = 80
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

	# 效果02a：全部当作进攻
	var pilot_015_effect_02a := CardEffect.new()
	pilot_015_effect_02a.effect_id = &"pilot_015_effect_02a"
	pilot_015_effect_02a.display_name = "诺拉-全部当进攻"
	pilot_015_effect_02a.mode = _EffectConst.MODE_ACTIVE
	pilot_015_effect_02a.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_015_effect_02a.priority = 100
	pilot_015_effect_02a.once_per_turn_key = &"pilot_015_effect_02"
	pilot_015_effect_02a.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_015_effect_02a.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_015_effect_02a.costs = []
	pilot_015_effect_02a.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"进攻"}},
	]
	pilot_015_effect_02a.description = "每回合1次，可以将全部行动牌（至少1张）视为进攻使用。"
	effects[pilot_015_effect_02a.effect_id] = pilot_015_effect_02a

	# 效果02b：全部当作防御
	var pilot_015_effect_02b := CardEffect.new()
	pilot_015_effect_02b.effect_id = &"pilot_015_effect_02b"
	pilot_015_effect_02b.display_name = "诺拉-全部当防御"
	pilot_015_effect_02b.mode = _EffectConst.MODE_ACTIVE
	pilot_015_effect_02b.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_015_effect_02b.priority = 100
	pilot_015_effect_02b.once_per_turn_key = &"pilot_015_effect_02"
	pilot_015_effect_02b.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_015_effect_02b.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_015_effect_02b.costs = []
	pilot_015_effect_02b.actions = [
		{"type": &"TREAT_CARD_AS_NAMED_TYPE", "params": {"named_type": &"防御"}},
	]
	pilot_015_effect_02b.description = "每回合1次，可以将全部行动牌（至少1张）视为防御使用。"
	effects[pilot_015_effect_02b.effect_id] = pilot_015_effect_02b

	# pilot_015 效果02原始ID路由器
	var pilot_015_effect_02_router := CardEffect.new()
	pilot_015_effect_02_router.effect_id = &"pilot_015_effect_02"
	pilot_015_effect_02_router.display_name = "诺拉-全部当进攻/防御"
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

	# ── pilot_016 默多克：展示1张+另外2张视为该牌 ──
	var pilot_016_effect_01 := CardEffect.new()
	pilot_016_effect_01.effect_id = &"pilot_016_effect_01"
	pilot_016_effect_01.display_name = "默多克-展示1视为2"
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

	# ── pilot_017 伏特：2张当作强袭/猛击/破甲+对应加成 ──
	# 效果01a：当作强袭
	var pilot_017_effect_01a := CardEffect.new()
	pilot_017_effect_01a.effect_id = &"pilot_017_effect_01a"
	pilot_017_effect_01a.display_name = "伏特-当作强袭"
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

	# 效果01b：当作猛击
	var pilot_017_effect_01b := CardEffect.new()
	pilot_017_effect_01b.effect_id = &"pilot_017_effect_01b"
	pilot_017_effect_01b.display_name = "伏特-当作猛击"
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

	# 效果01c：当作破甲
	var pilot_017_effect_01c := CardEffect.new()
	pilot_017_effect_01c.effect_id = &"pilot_017_effect_01c"
	pilot_017_effect_01c.display_name = "伏特-当作破甲"
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

	# 效果02：强袭回4动/猛击+3威/破甲命中+2损伤
	var pilot_017_effect_02 := CardEffect.new()
	pilot_017_effect_02.effect_id = &"pilot_017_effect_02"
	pilot_017_effect_02.display_name = "伏特-强袭回4动/猛击+3威/破甲+2损"
	pilot_017_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_017_effect_02.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_017_effect_02.priority = 80
	pilot_017_effect_02.once_per_turn_key = &""
	pilot_017_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_017_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_effect_02.costs = []
	pilot_017_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_017_effect_02",
			"text": "我方使用对应牌时：强袭使我方回复4动力，猛击使本次攻击威力+3，破甲命中后产生损伤+2。",
		}},
	]
	pilot_017_effect_02.description = "我方使用对应牌时：强袭使我方回复4动力，猛击使本次攻击威力+3，破甲命中后产生损伤+2。"
	effects[pilot_017_effect_02.effect_id] = pilot_017_effect_02

	# pilot_017 原始ID路由器
	var pilot_017_router := CardEffect.new()
	pilot_017_router.effect_id = &"pilot_017_effect_01"
	pilot_017_router.display_name = "伏特-当作强袭/猛击/破甲"
	pilot_017_router.mode = _EffectConst.MODE_ACTIVE
	pilot_017_router.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_017_router.priority = 100
	pilot_017_router.once_per_turn_key = &"pilot_017_effect_01"
	pilot_017_router.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_017_router.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_017_router.costs = [
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	]
	pilot_017_router.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_017_effect_01",
			"text": "每回合1次，可以将2张行动牌当作强袭/猛击/破甲之一使用。",
		}},
	]
	pilot_017_router.description = "每回合1次，可以将2张行动牌当作强袭/猛击/破甲之一使用。"
	effects[pilot_017_router.effect_id] = pilot_017_router

	# ── pilot_018 苔丝：被攻击抽2+迎击弃攻方牌 ──
	var pilot_018_effect_01 := CardEffect.new()
	pilot_018_effect_01.effect_id = &"pilot_018_effect_01"
	pilot_018_effect_01.display_name = "苔丝-被攻抽2+迎击弃攻"
	pilot_018_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_018_effect_01.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	pilot_018_effect_01.priority = 80
	pilot_018_effect_01.once_per_turn_key = &"pilot_018_effect_01"
	pilot_018_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
	]
	pilot_018_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_018_effect_01.costs = []
	pilot_018_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_018_effect_01",
			"text": "每回合1次，被攻击时，可立即抽2张行动牌，若我方通过使用迎击牌响应了此攻击，则弃置攻击方的3张行动牌或1张设置损伤≥2的装备牌。",
		}},
	]
	pilot_018_effect_01.description = "每回合1次，被攻击时，可立即抽2张行动牌，若我方通过使用迎击牌响应了此攻击，则弃置攻击方的3张行动牌或1张设置损伤≥2的装备牌。"
	effects[pilot_018_effect_01.effect_id] = pilot_018_effect_01

	# ── pilot_019 肯耳忒：弃X张弃他方X+1张+清空则3伤害 ──
	var pilot_019_effect_01 := CardEffect.new()
	pilot_019_effect_01.effect_id = &"pilot_019_effect_01"
	pilot_019_effect_01.display_name = "肯耳忒-弃X弃他X+1"
	pilot_019_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_019_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_019_effect_01.priority = 100
	pilot_019_effect_01.once_per_turn_key = &"pilot_019_effect_01"
	pilot_019_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_019_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 5}]
	pilot_019_effect_01.costs = []
	pilot_019_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_019_effect_01",
			"text": "我方回合2次，通过弃置X张行动牌（X最低为1），弃置1台其他机甲X+1张行动牌，若因此清空该机甲所持行动牌（其原本行动牌至少有1张），则可对其造成3伤害。",
		}},
	]
	pilot_019_effect_01.description = "我方回合2次，通过弃置X张行动牌（X最低为1），弃置1台其他机甲X+1张行动牌，若因此清空该机甲所持行动牌（其原本行动牌至少有1张），则可对其造成3伤害。"
	effects[pilot_019_effect_01.effect_id] = pilot_019_effect_01

	# ── pilot_020 肯德：弃任意张+弃置数阈值加成 ──
	# 效果01：弃置任意张行动牌
	var pilot_020_effect_01 := CardEffect.new()
	pilot_020_effect_01.effect_id = &"pilot_020_effect_01"
	pilot_020_effect_01.display_name = "肯德-弃任意张行动"
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

	# 效果02：弃置>1张 → 护甲+2动力+3
	var pilot_020_effect_02 := CardEffect.new()
	pilot_020_effect_02.effect_id = &"pilot_020_effect_02"
	pilot_020_effect_02.display_name = "肯德-弃>1护甲+2动+3"
	pilot_020_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_02.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_020_effect_02.priority = 80
	pilot_020_effect_02.once_per_turn_key = &""
	pilot_020_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"行动牌"},
		{"op": &"VARIABLE_ABOVE", "variable_name": &"pilot_020_discard_count", "threshold": 1},
	]
	pilot_020_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_02.costs = []
	pilot_020_effect_02.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 2, "duration": &"THIS_TURN"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 3, "duration": &"THIS_TURN"}},
	]
	pilot_020_effect_02.description = "大于1：当前回合我方护甲+2，动力+3。"
	effects[pilot_020_effect_02.effect_id] = pilot_020_effect_02

	# 效果03：弃置>3张 → 威力+2范围+1
	var pilot_020_effect_03 := CardEffect.new()
	pilot_020_effect_03.effect_id = &"pilot_020_effect_03"
	pilot_020_effect_03.display_name = "肯德-弃>3威+2范+1"
	pilot_020_effect_03.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_03.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	pilot_020_effect_03.priority = 80
	pilot_020_effect_03.once_per_turn_key = &""
	pilot_020_effect_03.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"VARIABLE_ABOVE", "variable_name": &"pilot_020_discard_count", "threshold": 3},
	]
	pilot_020_effect_03.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_03.costs = []
	pilot_020_effect_03.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 2}},
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 1}},
	]
	pilot_020_effect_03.description = "大于3：当前回合攻击时，威力+2，范围+1。"
	effects[pilot_020_effect_03.effect_id] = pilot_020_effect_03

	# 效果04：弃置>5张 → 回合结束后抽弃置数行动牌
	var pilot_020_effect_04 := CardEffect.new()
	pilot_020_effect_04.effect_id = &"pilot_020_effect_04"
	pilot_020_effect_04.display_name = "肯德-弃>5回后抽牌"
	pilot_020_effect_04.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_04.hook = _EffectConst.HOOK_TURN_END
	pilot_020_effect_04.priority = 80
	pilot_020_effect_04.once_per_turn_key = &""
	pilot_020_effect_04.conditions = [
		{"op": &"VARIABLE_ABOVE", "variable_name": &"pilot_020_discard_count", "threshold": 5},
	]
	pilot_020_effect_04.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_04.costs = []
	pilot_020_effect_04.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_020_effect_04",
			"text": "大于5：当前回合结束后抽取被弃置数量的行动牌。",
		}},
	]
	pilot_020_effect_04.description = "大于5：当前回合结束后抽取被弃置数量的行动牌。"
	effects[pilot_020_effect_04.effect_id] = pilot_020_effect_04

	# 效果05：弃置计数追踪
	var pilot_020_effect_05 := CardEffect.new()
	pilot_020_effect_05.effect_id = &"pilot_020_effect_05"
	pilot_020_effect_05.display_name = "肯德-弃置计数"
	pilot_020_effect_05.mode = _EffectConst.MODE_PASSIVE
	pilot_020_effect_05.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_020_effect_05.priority = 90
	pilot_020_effect_05.once_per_turn_key = &""
	pilot_020_effect_05.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"行动牌"},
	]
	pilot_020_effect_05.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_020_effect_05.costs = []
	pilot_020_effect_05.actions = [
		{"type": &"INCREMENT_VARIABLE", "params": {"variable_name": &"pilot_020_discard_count", "delta": 1}},
	]
	pilot_020_effect_05.description = "每个回合我方行动牌被弃置一定数目，可获得对应效果。"
	effects[pilot_020_effect_05.effect_id] = pilot_020_effect_05

	# ── pilot_021 塔莉娅：抽3交其他机甲+他用后抽2 ──
	var pilot_021_effect_01 := CardEffect.new()
	pilot_021_effect_01.effect_id = &"pilot_021_effect_01"
	pilot_021_effect_01.display_name = "塔莉娅-抽3交4格内"
	pilot_021_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_021_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_021_effect_01.priority = 100
	pilot_021_effect_01.once_per_turn_key = &"pilot_021_effect_01"
	pilot_021_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_021_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_021_effect_01.costs = []
	pilot_021_effect_01.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 3}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_021_effect_01",
			"text": "我方回合1次，可以抽3张行动牌，之后可以给予4格范围内的其他机甲其中的1张牌（每台机甲最多给1张），剩余的牌本回合无法使用。",
		}},
	]
	pilot_021_effect_01.description = "我方回合1次，可以抽3张行动牌，之后可以给予4格范围内的其他机甲其中的1张牌（每台机甲最多给1张），剩余的牌本回合无法使用。"
	effects[pilot_021_effect_01.effect_id] = pilot_021_effect_01

	var pilot_021_effect_02 := CardEffect.new()
	pilot_021_effect_02.effect_id = &"pilot_021_effect_02"
	pilot_021_effect_02.display_name = "塔莉娅-他用后抽2"
	pilot_021_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_021_effect_02.hook = _EffectConst.HOOK_CARD_PLAYED
	pilot_021_effect_02.priority = 80
	pilot_021_effect_02.once_per_turn_key = &""
	pilot_021_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"从我方处获得"},
	]
	pilot_021_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_021_effect_02.costs = []
	pilot_021_effect_02.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
	]
	pilot_021_effect_02.description = "其他机甲使用从我方处获得的行动牌后，我方抽2张行动牌。"
	effects[pilot_021_effect_02.effect_id] = pilot_021_effect_02

	# ── pilot_022 提比里安：本局1次1.5倍威+范围+3+锁定 ──
	var pilot_022_effect_01 := CardEffect.new()
	pilot_022_effect_01.effect_id = &"pilot_022_effect_01"
	pilot_022_effect_01.display_name = "提比里安-1.5倍威+3范锁定"
	pilot_022_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_022_effect_01.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_022_effect_01.priority = 80
	pilot_022_effect_01.once_per_turn_key = &"pilot_022_effect_01_per_game"
	pilot_022_effect_01.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_022_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_022_effect_01.costs = []
	pilot_022_effect_01.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"multiplier": 1.5, "round_down": true}},
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 3}},
		{"type": &"APPLY_OR_CHECK_LOCKED", "params": {"mode": &"apply"}},
	]
	pilot_022_effect_01.description = "本局游戏1次，发动攻击时，可以使该攻击的初始威力变成武器牌面记述威力的1.5倍(向下取整)，范围+3，施加锁定效果。"
	effects[pilot_022_effect_01.effect_id] = pilot_022_effect_01

	# ── pilot_023 坎得：1张当作维修+维修加成 ──
	var pilot_023_effect_01 := CardEffect.new()
	pilot_023_effect_01.effect_id = &"pilot_023_effect_01"
	pilot_023_effect_01.display_name = "坎得-当作维修"
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

	var pilot_023_effect_02 := CardEffect.new()
	pilot_023_effect_02.effect_id = &"pilot_023_effect_02"
	pilot_023_effect_02.display_name = "坎得-维修额外-2损+4格"
	pilot_023_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_023_effect_02.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_023_effect_02.priority = 80
	pilot_023_effect_02.once_per_turn_key = &""
	pilot_023_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"维修"},
	]
	pilot_023_effect_02.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 4}]
	pilot_023_effect_02.costs = []
	pilot_023_effect_02.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount": 2}},
	]
	pilot_023_effect_02.description = "我方使用的维修获得以下效果：额外移去2损伤，可以对相邻4格的其他机甲使用。"
	effects[pilot_023_effect_02.effect_id] = pilot_023_effect_02

	# ── pilot_024 琳：1张当作维修+4格内他方请求维修 ──
	var pilot_024_effect_01 := CardEffect.new()
	pilot_024_effect_01.effect_id = &"pilot_024_effect_01"
	pilot_024_effect_01.display_name = "琳-当作维修"
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

	var pilot_024_effect_02 := CardEffect.new()
	pilot_024_effect_02.effect_id = &"pilot_024_effect_02"
	pilot_024_effect_02.display_name = "琳-他方请求维修"
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
	pilot_024_effect_02.description = "在4格范围内的其他机甲可以在其回合内1次，使我方可以对其使用1次无距离限制的维修，之后其与我方各抽1张行动牌。"
	effects[pilot_024_effect_02.effect_id] = pilot_024_effect_02

	# ── pilot_025 约书亚：攻或被攻选择+抽装备设置/设置备用装备 ──
	# 效果01：攻击或被攻击时选择其一
	var pilot_025_effect_01 := CardEffect.new()
	pilot_025_effect_01.effect_id = &"pilot_025_effect_01"
	pilot_025_effect_01.display_name = "约书亚-攻或被攻选择"
	pilot_025_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_025_effect_01.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_025_effect_01.priority = 80
	pilot_025_effect_01.once_per_turn_key = &"pilot_025_effect_01"
	pilot_025_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_025_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_025_effect_01.costs = []
	pilot_025_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_025_effect_01",
			"text": "每回合1次，我方攻击或被攻击时，可以选择其一：",
		}},
	]
	pilot_025_effect_01.description = "每回合1次，我方攻击或被攻击时，可以选择其一："
	effects[pilot_025_effect_01.effect_id] = pilot_025_effect_01

	# 效果02：立即抽1张装备牌设置到区域上
	var pilot_025_effect_02 := CardEffect.new()
	pilot_025_effect_02.effect_id = &"pilot_025_effect_02"
	pilot_025_effect_02.display_name = "约书亚-抽装设置"
	pilot_025_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_025_effect_02.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_025_effect_02.priority = 85
	pilot_025_effect_02.once_per_turn_key = &"pilot_025_effect_01"
	pilot_025_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_025_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_025_effect_02.costs = []
	pilot_025_effect_02.actions = [
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1, "must_set_or_discard": true}},
	]
	pilot_025_effect_02.description = "立即抽1张装备牌设置到区域上（否则立即弃置）。"
	effects[pilot_025_effect_02.effect_id] = pilot_025_effect_02

	# 效果03：立即设置1张备用区装备牌
	var pilot_025_effect_03 := CardEffect.new()
	pilot_025_effect_03.effect_id = &"pilot_025_effect_03"
	pilot_025_effect_03.display_name = "约书亚-设置备用装"
	pilot_025_effect_03.mode = _EffectConst.MODE_PASSIVE
	pilot_025_effect_03.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_025_effect_03.priority = 85
	pilot_025_effect_03.once_per_turn_key = &"pilot_025_effect_01"
	pilot_025_effect_03.conditions = [{"op": &"ALWAYS"}]
	pilot_025_effect_03.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_025_effect_03.costs = []
	pilot_025_effect_03.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_025_effect_03",
			"text": "立即设置1张处于于备用区的装备牌。",
		}},
	]
	pilot_025_effect_03.description = "立即设置1张处于于备用区的装备牌。"
	effects[pilot_025_effect_03.effect_id] = pilot_025_effect_03

	# ── pilot_026 伊万：1张当作设陷+4次机会+陷阱不设损伤 ──
	# 效果01：当作设陷
	var pilot_026_effect_01 := CardEffect.new()
	pilot_026_effect_01.effect_id = &"pilot_026_effect_01"
	pilot_026_effect_01.display_name = "伊万-当作设陷"
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

	# 效果02：设陷共有4次机会
	var pilot_026_effect_02 := CardEffect.new()
	pilot_026_effect_02.effect_id = &"pilot_026_effect_02"
	pilot_026_effect_02.display_name = "伊万-设陷4次机会"
	pilot_026_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_026_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_026_effect_02.priority = 80
	pilot_026_effect_02.once_per_turn_key = &""
	pilot_026_effect_02.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"设陷"},
	]
	pilot_026_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_026_effect_02.costs = []
	pilot_026_effect_02.actions = [
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"trap_chances", "value": 4, "duration": &"THIS_TURN"}},
	]
	pilot_026_effect_02.description = "我方使用的设陷共有4次机会设置陷阱。"
	effects[pilot_026_effect_02.effect_id] = pilot_026_effect_02

	# 效果03：陷阱对我方仅伤害不设损伤
	var pilot_026_effect_03 := CardEffect.new()
	pilot_026_effect_03.effect_id = &"pilot_026_effect_03"
	pilot_026_effect_03.display_name = "伊万-陷阱不设损伤"
	pilot_026_effect_03.mode = _EffectConst.MODE_PASSIVE
	pilot_026_effect_03.hook = _EffectConst.HOOK_BEFORE_DAMAGE_TOKEN_PLACED
	pilot_026_effect_03.priority = 80
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

	# ── pilot_027 维罗妮卡：范围内获金分半+给2金使其用1牌 ──
	# 效果01：4+X范围内他方获金我方获半
	var pilot_027_effect_01 := CardEffect.new()
	pilot_027_effect_01.effect_id = &"pilot_027_effect_01"
	pilot_027_effect_01.display_name = "维罗妮卡-获金分半"
	pilot_027_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_027_effect_01.hook = _EffectConst.HOOK_OTHER_MECH_GAIN_GOLD
	pilot_027_effect_01.priority = 80
	pilot_027_effect_01.once_per_turn_key = &""
	pilot_027_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_027_effect_01.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 4, "variable_name": &"pilot_027_X"}]
	pilot_027_effect_01.costs = []
	pilot_027_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_027_effect_01",
			"text": "4+X格范围内的其他机甲获得金币时（X初始为0，我方每次给予其他机甲金币会使X数值+1），我方获得其中的一半金币（向下取整）。",
		}},
	]
	pilot_027_effect_01.description = "4+X格范围内的其他机甲获得金币时（X初始为0，我方每次给予其他机甲金币会使X数值+1），我方获得其中的一半金币（向下取整）。"
	effects[pilot_027_effect_01.effect_id] = pilot_027_effect_01

	# 效果02：给予4+X范围内他方2金使其用1牌
	var pilot_027_effect_02 := CardEffect.new()
	pilot_027_effect_02.effect_id = &"pilot_027_effect_02"
	pilot_027_effect_02.display_name = "维罗妮卡-给2金使其用1牌"
	pilot_027_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_027_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_027_effect_02.priority = 100
	pilot_027_effect_02.once_per_turn_key = &"pilot_027_effect_02"
	pilot_027_effect_02.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_027_effect_02.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 4, "variable_name": &"pilot_027_X"}]
	pilot_027_effect_02.costs = []
	pilot_027_effect_02.actions = [
		{"type": &"SPEND_GOLD", "params": {"amount": 2, "give_to_target": true}},
		{"type": &"INCREMENT_VARIABLE", "params": {"variable_name": &"pilot_027_X", "delta": 1}},
		{"type": &"FORCE_MECH_ACTION", "params": {"action_type": &"use_action_card"}},
	]
	pilot_027_effect_02.description = "我方回合1次，给予4+X格范围内的任意其他机甲2金币，之后使其可以依次使用1张行动牌。"
	effects[pilot_027_effect_02.effect_id] = pilot_027_effect_02

	# ── pilot_028 乌尔：宣言类型+使用/弃置宣言牌获之抽1 ──
	var pilot_028_effect_01 := CardEffect.new()
	pilot_028_effect_01.effect_id = &"pilot_028_effect_01"
	pilot_028_effect_01.display_name = "乌尔-宣言获牌抽1"
	pilot_028_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_028_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_028_effect_01.priority = 80
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
	pilot_028_effect_01.description = "每个回合开始时，可以宣言1种行动牌类型(攻击，迎击，辅助)，若在本回合使用/弃置了宣言类型的行动牌，则我方之后获得之并抽1张行动牌。"
	effects[pilot_028_effect_01.effect_id] = pilot_028_effect_01

# ═══════════════════════════════════════════
# 批次J：SSR稀有度机师效果（pilot_001-010）
# ═══════════════════════════════════════════

	# ── pilot_001 阿克罗姆：首张行动牌效果生效2次 ──
	var pilot_001_effect_01 := CardEffect.new()
	pilot_001_effect_01.effect_id = &"pilot_001_effect_01"
	pilot_001_effect_01.display_name = "阿克罗姆-首牌生效2次"
	pilot_001_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_001_effect_01.hook = _EffectConst.HOOK_ACTION_CARD_PLAYED
	pilot_001_effect_01.priority = 80
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
	pilot_001_effect_01.description = "每回合第1张使用的行动牌，该效果可以生效2次（2次独立结算，第1次效果结算完成后，若条件满足则第2次效果立即生效）。"
	effects[pilot_001_effect_01.effect_id] = pilot_001_effect_01

	# ── pilot_002 莱比尔：联邦阵营全队加成+取消/恢复 ──
	# 效果01：联邦机师获得交牌当作进攻/防御+抽2
	var pilot_002_effect_01 := CardEffect.new()
	pilot_002_effect_01.effect_id = &"pilot_002_effect_01"
	pilot_002_effect_01.display_name = "莱比尔-联邦交牌当攻防"
	pilot_002_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_002_effect_01.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_002_effect_01.priority = 80
	pilot_002_effect_01.once_per_turn_key = &""
	pilot_002_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_002_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_002_effect_01.costs = []
	pilot_002_effect_01.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"联邦",
			"target_type": &"pilot",
			"effect_id": &"pilot_002_federal_transfer",
		}},
	]
	pilot_002_effect_01.description = "场上所有联邦阵营的机师牌获得：可以将任意张行动牌交给5格范围内1台其他机甲并当作进攻或防御使用，之后抽2张行动牌。"
	effects[pilot_002_effect_01.effect_id] = pilot_002_effect_01

	# 效果02：联邦机甲框架护甲+4
	var pilot_002_effect_02 := CardEffect.new()
	pilot_002_effect_02.effect_id = &"pilot_002_effect_02"
	pilot_002_effect_02.display_name = "莱比尔-联邦护甲+4"
	pilot_002_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_002_effect_02.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_002_effect_02.priority = 85
	pilot_002_effect_02.once_per_turn_key = &""
	pilot_002_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_002_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_002_effect_02.costs = []
	pilot_002_effect_02.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"联邦",
			"target_type": &"mech_frame",
			"effect_id": &"pilot_002_federal_armor",
		}},
	]
	pilot_002_effect_02.description = "场上所有联邦阵营的机甲框架获得：机甲护甲+4。"
	effects[pilot_002_effect_02.effect_id] = pilot_002_effect_02

	# 效果03：取消或恢复1台机甲获得上述效果
	var pilot_002_effect_03 := CardEffect.new()
	pilot_002_effect_03.effect_id = &"pilot_002_effect_03"
	pilot_002_effect_03.display_name = "莱比尔-取消/恢复效"
	pilot_002_effect_03.mode = _EffectConst.MODE_ACTIVE
	pilot_002_effect_03.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_002_effect_03.priority = 100
	pilot_002_effect_03.once_per_turn_key = &"pilot_002_effect_03"
	pilot_002_effect_03.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_002_effect_03.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH"}]
	pilot_002_effect_03.costs = []
	pilot_002_effect_03.actions = [
		{"type": &"TOGGLE_EFFECT_ON_MECH", "params": {
			"effect_id": &"pilot_002_effect_01",
			"toggle": &"toggle",
		}},
	]
	pilot_002_effect_03.description = "我方回合1次，取消或恢复1台机甲获得上述效果。"
	effects[pilot_002_effect_03.effect_id] = pilot_002_effect_03

	# ── pilot_003 瑟尔基尔：正面朝上放入牌堆+跳过正面朝上牌 ──
	# 效果01：正面朝上随机放入行动牌堆
	var pilot_003_effect_01 := CardEffect.new()
	pilot_003_effect_01.effect_id = &"pilot_003_effect_01"
	pilot_003_effect_01.display_name = "瑟尔基尔-正面放入牌堆"
	pilot_003_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_003_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_003_effect_01.priority = 100
	pilot_003_effect_01.once_per_turn_key = &"pilot_003_effect_01"
	pilot_003_effect_01.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_003_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_003_effect_01.costs = []
	pilot_003_effect_01.actions = [
		{"type": &"PLACE_CARD_IN_DECK_FACE_UP", "params": {}},
	]
	pilot_003_effect_01.description = "我方回合1次，将任意张行动牌正面朝上随机放入行动牌堆，并可以选择其中1张放置在牌堆顶，当这些牌离开牌堆时立即由我方使用，若无法使用则改为弃置该牌并使我方抽2张行动牌。"
	effects[pilot_003_effect_01.effect_id] = pilot_003_effect_01

	# 效果02：跳过正面朝上的牌抽牌数+1
	var pilot_003_effect_02 := CardEffect.new()
	pilot_003_effect_02.effect_id = &"pilot_003_effect_02"
	pilot_003_effect_02.display_name = "瑟尔基尔-跳过正面牌+1"
	pilot_003_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_003_effect_02.hook = _EffectConst.HOOK_ACTION_CARD_DRAWN
	pilot_003_effect_02.priority = 80
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

	# ── pilot_004 玛沙：护甲转动力+消耗6动抽1装 ──
	# 效果01：护甲转化为动力+每2点抽1行动
	var pilot_004_effect_01 := CardEffect.new()
	pilot_004_effect_01.effect_id = &"pilot_004_effect_01"
	pilot_004_effect_01.display_name = "玛沙-护甲转动抽牌"
	pilot_004_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_004_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_004_effect_01.priority = 80
	pilot_004_effect_01.once_per_turn_key = &""
	pilot_004_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_004_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_004_effect_01.costs = []
	pilot_004_effect_01.actions = [
		{"type": &"CONVERT_ARMOR_TO_POWER", "params": {"draw_per": 2, "draw_type": &"action", "restore_next_turn": true}},
	]
	pilot_004_effect_01.description = "每个回合开始时，可以将任意数值的护甲转化为动力，每转化2点可立即抽1张行动牌，下个我方回合即将开始时护甲回复。"
	effects[pilot_004_effect_01.effect_id] = pilot_004_effect_01

	# 效果02：消耗6动力抽1装备牌
	var pilot_004_effect_02 := CardEffect.new()
	pilot_004_effect_02.effect_id = &"pilot_004_effect_02"
	pilot_004_effect_02.display_name = "玛沙-耗6动抽1装"
	pilot_004_effect_02.mode = _EffectConst.MODE_ACTIVE
	pilot_004_effect_02.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_004_effect_02.priority = 100
	pilot_004_effect_02.once_per_turn_key = &"pilot_004_effect_02"
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

	# ── pilot_005 肯特：帝国阵营全队加成+取消/恢复 ──
	# 效果01：帝国机师获得攻/被攻耗4动弃2行动
	var pilot_005_effect_01 := CardEffect.new()
	pilot_005_effect_01.effect_id = &"pilot_005_effect_01"
	pilot_005_effect_01.display_name = "肯特-帝国攻被攻弃2"
	pilot_005_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_005_effect_01.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_005_effect_01.priority = 80
	pilot_005_effect_01.once_per_turn_key = &""
	pilot_005_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_005_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_005_effect_01.costs = []
	pilot_005_effect_01.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"帝国",
			"target_type": &"pilot",
			"effect_id": &"pilot_005_imperial_discard",
		}},
	]
	pilot_005_effect_01.description = "场上所有帝国阵营的机师牌获得：攻击或被攻击时可以消耗4动力，弃置目标或攻击方2张行动牌。"
	effects[pilot_005_effect_01.effect_id] = pilot_005_effect_01

	# 效果02：帝国机甲框架动力+4
	var pilot_005_effect_02 := CardEffect.new()
	pilot_005_effect_02.effect_id = &"pilot_005_effect_02"
	pilot_005_effect_02.display_name = "肯特-帝国动力+4"
	pilot_005_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_005_effect_02.hook = _EffectConst.HOOK_GAME_STARTED
	pilot_005_effect_02.priority = 85
	pilot_005_effect_02.once_per_turn_key = &""
	pilot_005_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_005_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_005_effect_02.costs = []
	pilot_005_effect_02.actions = [
		{"type": &"GRANT_EFFECT_TO_FACTION", "params": {
			"faction": &"帝国",
			"target_type": &"mech_frame",
			"effect_id": &"pilot_005_imperial_power",
		}},
	]
	pilot_005_effect_02.description = "场上所有帝国阵营的机甲框架获得：机甲动力+4。"
	effects[pilot_005_effect_02.effect_id] = pilot_005_effect_02

	# 效果03：取消或恢复1台机甲获得上述效果
	var pilot_005_effect_03 := CardEffect.new()
	pilot_005_effect_03.effect_id = &"pilot_005_effect_03"
	pilot_005_effect_03.display_name = "肯特-取消/恢复效"
	pilot_005_effect_03.mode = _EffectConst.MODE_ACTIVE
	pilot_005_effect_03.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_005_effect_03.priority = 100
	pilot_005_effect_03.once_per_turn_key = &"pilot_005_effect_03"
	pilot_005_effect_03.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	pilot_005_effect_03.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH"}]
	pilot_005_effect_03.costs = []
	pilot_005_effect_03.actions = [
		{"type": &"TOGGLE_EFFECT_ON_MECH", "params": {
			"effect_id": &"pilot_005_effect_01",
			"toggle": &"toggle",
		}},
	]
	pilot_005_effect_03.description = "我方回合1次，取消或恢复1台机甲获得上述效果。"
	effects[pilot_005_effect_03.effect_id] = pilot_005_effect_03

	# ── pilot_006 里昂：轮开始选目标+攻时选他方强攻或4伤害 ──
	# 效果01：轮开始选目标+被攻时攻方抽1
	var pilot_006_effect_01 := CardEffect.new()
	pilot_006_effect_01.effect_id = &"pilot_006_effect_01"
	pilot_006_effect_01.display_name = "里昂-轮选目标攻方抽1"
	pilot_006_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_006_effect_01.hook = _EffectConst.HOOK_ROUND_START
	pilot_006_effect_01.priority = 100
	pilot_006_effect_01.once_per_turn_key = &""
	pilot_006_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_006_effect_01.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH"}]
	pilot_006_effect_01.costs = []
	pilot_006_effect_01.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_006_effect_01",
			"text": "每轮开始时，选择1台其他机甲为目标，本轮中目标被攻击时，攻击方抽1张行动牌，若抽到是攻击牌，之后对该目标使用此牌不计回合攻击数。",
		}},
	]
	pilot_006_effect_01.description = "每轮开始时，选择1台其他机甲为目标，本轮中目标被攻击时，攻击方抽1张行动牌，若抽到是攻击牌，之后对该目标使用此牌不计回合攻击数。"
	effects[pilot_006_effect_01.effect_id] = pilot_006_effect_01

	# 效果02：攻时选5格内他方使用攻牌或4伤害
	var pilot_006_effect_02 := CardEffect.new()
	pilot_006_effect_02.effect_id = &"pilot_006_effect_02"
	pilot_006_effect_02.display_name = "里昂-攻时他方强攻或4伤"
	pilot_006_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_006_effect_02.hook = _EffectConst.HOOK_ATTACK_DECLARED
	pilot_006_effect_02.priority = 80
	pilot_006_effect_02.once_per_turn_key = &"pilot_006_effect_02"
	pilot_006_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_006_effect_02.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 5}]
	pilot_006_effect_02.costs = []
	pilot_006_effect_02.actions = [
		{"type": &"FORCE_MECH_ACTION", "params": {"action_type": &"attack"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_006_effect_02",
			"text": "每回合1次，我方攻击时，选择1台5格范围内的其他机甲，其选择立即使用1张攻击牌，或受到4伤害。",
		}},
	]
	pilot_006_effect_02.description = "每回合1次，我方攻击时，选择1台5格范围内的其他机甲，其选择立即使用1张攻击牌，或受到4伤害。"
	effects[pilot_006_effect_02.effect_id] = pilot_006_effect_02

	# ── pilot_007 珀修斯：获攻击牌立即用+展示目标缺类型弃牌 ──
	# 效果01：指定我方为目标的攻击牌结算后获得并使用
	var pilot_007_effect_01 := CardEffect.new()
	pilot_007_effect_01.effect_id = &"pilot_007_effect_01"
	pilot_007_effect_01.display_name = "珀修斯-获攻牌立即用"
	pilot_007_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_007_effect_01.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	pilot_007_effect_01.priority = 80
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

	# 效果02：使用攻击牌时展示目标手牌+缺类型弃牌
	var pilot_007_effect_02 := CardEffect.new()
	pilot_007_effect_02.effect_id = &"pilot_007_effect_02"
	pilot_007_effect_02.display_name = "珀修斯-展示缺类型弃"
	pilot_007_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_007_effect_02.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_007_effect_02.priority = 80
	pilot_007_effect_02.once_per_turn_key = &"pilot_007_effect_02"
	pilot_007_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_007_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_007_effect_02.costs = []
	pilot_007_effect_02.actions = [
		{"type": &"REVEAL_OR_PEEK_CARD", "params": {"mode": &"reveal_hand"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_007_effect_02",
			"text": "每回合1次，我方使用攻击牌时，可以展示目标所持行动牌，其中每缺少1种类型(攻击，迎击，辅助)，便可弃置其中1张牌。",
		}},
	]
	pilot_007_effect_02.description = "每回合1次，我方使用攻击牌时，可以展示目标所持行动牌，其中每缺少1种类型(攻击，迎击，辅助)，便可弃置其中1张牌。"
	effects[pilot_007_effect_02.effect_id] = pilot_007_effect_02

	# ── pilot_008 安德洛美达：维修获之X+1+回复改伤害+移除改设置损伤 ──
	# 效果01：维修被使用/弃置后获得+X+1
	var pilot_008_effect_01 := CardEffect.new()
	pilot_008_effect_01.effect_id = &"pilot_008_effect_01"
	pilot_008_effect_01.display_name = "安德洛美达-维修获X+1"
	pilot_008_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_008_effect_01.hook = _EffectConst.HOOK_CARD_DISCARDED
	pilot_008_effect_01.priority = 80
	pilot_008_effect_01.once_per_turn_key = &"pilot_008_effect_01"
	pilot_008_effect_01.conditions = [
		{"op": &"PAYLOAD_CARD_HAS_TAG", "tag": &"维修"},
	]
	pilot_008_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_008_effect_01.costs = []
	pilot_008_effect_01.actions = [
		{"type": &"INCREMENT_VARIABLE", "params": {"variable_name": &"pilot_008_X", "delta": 1}},
	]
	pilot_008_effect_01.description = "每回合1次，维修被使用或弃置后，我方获得之，并使X数值+1（X初始为0）。"
	effects[pilot_008_effect_01.effect_id] = pilot_008_effect_01

	# 效果02：5+X范围内回复生命改为受到等量伤害
	var pilot_008_effect_02 := CardEffect.new()
	pilot_008_effect_02.effect_id = &"pilot_008_effect_02"
	pilot_008_effect_02.display_name = "安德洛美达-回复改伤害"
	pilot_008_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_008_effect_02.hook = _EffectConst.HOOK_BEFORE_HEAL
	pilot_008_effect_02.priority = 80
	pilot_008_effect_02.once_per_turn_key = &"pilot_008_effect_02"
	pilot_008_effect_02.conditions = [{"op": &"ALWAYS"}]
	pilot_008_effect_02.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 5, "variable_name": &"pilot_008_X"}]
	pilot_008_effect_02.costs = []
	pilot_008_effect_02.actions = [
		{"type": &"REDIRECT_HEAL_TO_DAMAGE", "params": {}},
	]
	pilot_008_effect_02.description = "每回合1次，5+X格范围内的机甲即将回复生命时，可将效果改为受到等量伤害。"
	effects[pilot_008_effect_02.effect_id] = pilot_008_effect_02

	# 效果03：5+X范围内移除损伤改为设置等量损伤
	var pilot_008_effect_03 := CardEffect.new()
	pilot_008_effect_03.effect_id = &"pilot_008_effect_03"
	pilot_008_effect_03.display_name = "安德洛美达-移除改设损"
	pilot_008_effect_03.mode = _EffectConst.MODE_PASSIVE
	pilot_008_effect_03.hook = _EffectConst.HOOK_BEFORE_REMOVE_DAMAGE_TOKENS
	pilot_008_effect_03.priority = 80
	pilot_008_effect_03.once_per_turn_key = &"pilot_008_effect_03"
	pilot_008_effect_03.conditions = [{"op": &"ALWAYS"}]
	pilot_008_effect_03.target_rules = [{"rule": &"CHOOSE_MECH_IN_VARIABLE_RANGE", "base_range": 5, "variable_name": &"pilot_008_X"}]
	pilot_008_effect_03.costs = []
	pilot_008_effect_03.actions = [
		{"type": &"REDIRECT_REMOVE_TO_PLACE_TOKENS", "params": {"owner_chooses_slot": true}},
	]
	pilot_008_effect_03.description = "每回合1次，5+X格范围内的机甲即将移除损伤时，可将效果改为设置等量损伤（位置由我方指定）。"
	effects[pilot_008_effect_03.effect_id] = pilot_008_effect_03

	# ── pilot_009 美杜莎：弃1记录类型+展示同类型+使用或弃置 ──
	var pilot_009_effect_01 := CardEffect.new()
	pilot_009_effect_01.effect_id = &"pilot_009_effect_01"
	pilot_009_effect_01.display_name = "美杜莎-弃1展示同类型"
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
		{"type": &"REVEAL_OR_PEEK_CARD", "params": {"mode": &"reveal_matching_type"}},
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_009_effect_01",
			"text": "我方回合1次，可以弃置1张行动牌并记录其类型(攻击，迎击，辅助)，之后选择1台5格范围内的其他机甲展示其持有的和记录类型相同的所有行动牌，这回合我方可以使用这些牌或立即全部弃置。",
		}},
	]
	pilot_009_effect_01.description = "我方回合1次，可以弃置1张行动牌并记录其类型(攻击，迎击，辅助)，之后选择1台5格范围内的其他机甲展示其持有的和记录类型相同的所有行动牌，这回合我方可以使用这些牌或立即全部弃置。"
	effects[pilot_009_effect_01.effect_id] = pilot_009_effect_01

	# ── pilot_010 刻托：互换上限攻击数+抽牌+攻牌视作强袭/闪击/预判 ──
	# 效果01：回合开始互换行动牌上限与攻击数+抽牌
	var pilot_010_effect_01 := CardEffect.new()
	pilot_010_effect_01.effect_id = &"pilot_010_effect_01"
	pilot_010_effect_01.display_name = "刻托-互换上限攻数"
	pilot_010_effect_01.mode = _EffectConst.MODE_PASSIVE
	pilot_010_effect_01.hook = _EffectConst.HOOK_TURN_START
	pilot_010_effect_01.priority = 80
	pilot_010_effect_01.once_per_turn_key = &""
	pilot_010_effect_01.conditions = [{"op": &"ALWAYS"}]
	pilot_010_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_010_effect_01.costs = []
	pilot_010_effect_01.actions = [
		{"type": &"SWAP_HAND_LIMIT_AND_ATTACK_COUNT", "params": {}},
	]
	pilot_010_effect_01.description = "我方回合开始时，可以使我方行动牌上限与回合攻击数互换数值，之后抽取当前行动牌上限张行动牌。"
	effects[pilot_010_effect_01.effect_id] = pilot_010_effect_01

	# 效果02：第1张攻牌视作强袭/第2张视作闪击/第3张视作预判
	var pilot_010_effect_02 := CardEffect.new()
	pilot_010_effect_02.effect_id = &"pilot_010_effect_02"
	pilot_010_effect_02.display_name = "刻托-攻牌视作强袭闪击预判"
	pilot_010_effect_02.mode = _EffectConst.MODE_PASSIVE
	pilot_010_effect_02.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	pilot_010_effect_02.priority = 80
	pilot_010_effect_02.once_per_turn_key = &""
	pilot_010_effect_02.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
	]
	pilot_010_effect_02.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_010_effect_02.costs = []
	pilot_010_effect_02.actions = [
		{"type": &"CUSTOM_EFFECT_CHECK_TEXT", "params": {
			"effect_id": &"pilot_010_effect_02",
			"text": "每个回合内，我方使用的第一张攻击牌视作强袭，第二张攻击牌视作闪击，第三张攻击牌视作预判。",
		}},
	]
	pilot_010_effect_02.description = "每个回合内，我方使用的第一张攻击牌视作强袭，第二张攻击牌视作闪击，第三张攻击牌视作预判。"
	effects[pilot_010_effect_02.effect_id] = pilot_010_effect_02
