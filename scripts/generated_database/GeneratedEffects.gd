## GeneratedEffects.gd — 卡牌效果定义生成器
##
## 分批实现效果：
## 批次1：基础行动牌效果（5个）
## 批次2：基础装备效果（12个）
## 后续批次在迭代中逐步添加。
##
## 所有效果遵循统一执行链：
## Service → Hook → EffectEngine → ConditionChecker → TargetChecker → CostChecker → AtomicActionResolver → GameActions
class_name GeneratedEffects
extends RefCounted

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 构建所有效果定义，返回 { effect_id: CardEffect }
static func build_all_effects() -> Dictionary:
	var effects: Dictionary = {}

	# ═══════════════════════════════════════════
	# 批次1：基础行动牌效果
	# ═══════════════════════════════════════════

	# ── 进攻：打出攻击牌时触发攻击声明 ──
	var basic_attack := CardEffect.new()
	basic_attack.effect_id = &"basic_attack"
	basic_attack.display_name = "进攻"
	basic_attack.mode = _EffectConst.MODE_PASSIVE
	basic_attack.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	basic_attack.priority = 110
	basic_attack.conditions = [{"op": &"ALWAYS"}]
	basic_attack.target_rules = [{"rule": &"NO_TARGET"}]
	basic_attack.costs = []
	basic_attack.actions = [{"type": &"START_ATTACK_DECLARE_ATTACK"}]
	basic_attack.description = "选择1把武器对1台范围内的机甲发动攻击。"
	effects[basic_attack.effect_id] = basic_attack

	# ── 回避：攻击响应窗口中，被攻击方可移动 ──
	var evade_half_power := CardEffect.new()
	evade_half_power.effect_id = &"evade_half_power"
	evade_half_power.display_name = "回避"
	evade_half_power.mode = _EffectConst.MODE_PASSIVE
	evade_half_power.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	evade_half_power.priority = 100
	evade_half_power.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	evade_half_power.target_rules = [{"rule": &"NO_TARGET"}]
	evade_half_power.costs = []
	evade_half_power.actions = [{"type": &"MOVE_MECH", "params": {"power_fraction": 0.5}}]
	evade_half_power.description = "响应对我方的攻击，可以用当前1/2的动力（向下取整）进行移动。"
	effects[evade_half_power.effect_id] = evade_half_power

	# ── 防御：攻击响应窗口中，被攻击方护甲+5 ──
	var defend_armor_bonus := CardEffect.new()
	defend_armor_bonus.effect_id = &"defend_armor_bonus"
	defend_armor_bonus.display_name = "防御"
	defend_armor_bonus.mode = _EffectConst.MODE_PASSIVE
	defend_armor_bonus.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	defend_armor_bonus.priority = 100
	defend_armor_bonus.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	defend_armor_bonus.target_rules = [{"rule": &"NO_TARGET"}]
	defend_armor_bonus.costs = []
	defend_armor_bonus.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 5, "duration": "THIS_ATTACK"}},
	]
	defend_armor_bonus.description = "响应对我方的攻击，在本次攻击结算前使机甲护甲+5。"
	effects[defend_armor_bonus.effect_id] = defend_armor_bonus

	# ── 维修：主阶段移除2枚损伤+回复2HP ──
	var repair_markers := CardEffect.new()
	repair_markers.effect_id = &"repair_markers"
	repair_markers.display_name = "维修"
	repair_markers.mode = _EffectConst.MODE_PASSIVE
	repair_markers.hook = _EffectConst.HOOK_MAIN_PHASE_START
	repair_markers.priority = 100
	repair_markers.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	repair_markers.target_rules = [{"rule": &"NO_TARGET"}]
	repair_markers.costs = []
	repair_markers.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount": 2}},
		{"type": &"HEAL_HP", "params": {"amount": 2}},
	]
	repair_markers.description = "移除2枚损伤标记并回复2点生命。"
	effects[repair_markers.effect_id] = repair_markers

	# ── 推进：主阶段动力+5 ──
	var gain_power := CardEffect.new()
	gain_power.effect_id = &"gain_power_5"
	gain_power.display_name = "推进"
	gain_power.mode = _EffectConst.MODE_PASSIVE
	gain_power.hook = _EffectConst.HOOK_MAIN_PHASE_START
	gain_power.priority = 100
	gain_power.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	gain_power.target_rules = [{"rule": &"NO_TARGET"}]
	gain_power.costs = []
	gain_power.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 5}},
	]
	gain_power.description = "本回合使机甲动力+5。"
	effects[gain_power.effect_id] = gain_power

	# ═══════════════════════════════════════════
	# 批次2：基础装备效果
	# ═══════════════════════════════════════════

	# ── 量产装头部：护甲+2 ──
	var part_head_armor := CardEffect.new()
	part_head_armor.effect_id = &"part_head_armor_2"
	part_head_armor.display_name = "头部护甲+2"
	part_head_armor.mode = _EffectConst.MODE_STATIC
	part_head_armor.hook = _EffectConst.HOOK_STAT_RECALCULATE
	part_head_armor.priority = 50
	part_head_armor.conditions = [{"op": &"ALWAYS"}]
	part_head_armor.target_rules = [{"rule": &"NO_TARGET"}]
	part_head_armor.costs = []
	part_head_armor.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 2, "duration": "PERMANENT"}},
	]
	part_head_armor.description = "头部装备提供护甲+2。"
	effects[part_head_armor.effect_id] = part_head_armor

	# ── 量产装躯干：护甲+3，动力+1 ──
	var part_torso_armor_power := CardEffect.new()
	part_torso_armor_power.effect_id = &"part_torso_armor_3_power_1"
	part_torso_armor_power.display_name = "躯干护甲+3动力+1"
	part_torso_armor_power.mode = _EffectConst.MODE_STATIC
	part_torso_armor_power.hook = _EffectConst.HOOK_STAT_RECALCULATE
	part_torso_armor_power.priority = 50
	part_torso_armor_power.conditions = [{"op": &"ALWAYS"}]
	part_torso_armor_power.target_rules = [{"rule": &"NO_TARGET"}]
	part_torso_armor_power.costs = []
	part_torso_armor_power.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 3, "duration": "PERMANENT"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 1, "duration": "PERMANENT"}},
	]
	part_torso_armor_power.description = "躯干装备提供护甲+3、动力+1。"
	effects[part_torso_armor_power.effect_id] = part_torso_armor_power

	# ── 量产装腿部：动力+2 ──
	var part_legs_power := CardEffect.new()
	part_legs_power.effect_id = &"part_legs_power_2"
	part_legs_power.display_name = "腿部动力+2"
	part_legs_power.mode = _EffectConst.MODE_STATIC
	part_legs_power.hook = _EffectConst.HOOK_STAT_RECALCULATE
	part_legs_power.priority = 50
	part_legs_power.conditions = [{"op": &"ALWAYS"}]
	part_legs_power.target_rules = [{"rule": &"NO_TARGET"}]
	part_legs_power.costs = []
	part_legs_power.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": "PERMANENT"}},
	]
	part_legs_power.description = "腿部装备提供动力+2。"
	effects[part_legs_power.effect_id] = part_legs_power

	# ── 量产装臂部：护甲+1，动力+1 ──
	var part_arms_armor_power := CardEffect.new()
	part_arms_armor_power.effect_id = &"part_arms_armor_1_power_1"
	part_arms_armor_power.display_name = "臂部护甲+1动力+1"
	part_arms_armor_power.mode = _EffectConst.MODE_STATIC
	part_arms_armor_power.hook = _EffectConst.HOOK_STAT_RECALCULATE
	part_arms_armor_power.priority = 50
	part_arms_armor_power.conditions = [{"op": &"ALWAYS"}]
	part_arms_armor_power.target_rules = [{"rule": &"NO_TARGET"}]
	part_arms_armor_power.costs = []
	part_arms_armor_power.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 1, "duration": "PERMANENT"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 1, "duration": "PERMANENT"}},
	]
	part_arms_armor_power.description = "臂部装备提供护甲+1、动力+1。"
	effects[part_arms_armor_power.effect_id] = part_arms_armor_power

	# ── 光束军刀（近战武器）：攻击修正窗口中，近战武器威力+0（基础效果占位） ──
	var weapon_saber_base := CardEffect.new()
	weapon_saber_base.effect_id = &"weapon_saber_base"
	weapon_saber_base.display_name = "光束军刀"
	weapon_saber_base.mode = _EffectConst.MODE_PASSIVE
	weapon_saber_base.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	weapon_saber_base.priority = 100
	weapon_saber_base.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
	]
	weapon_saber_base.target_rules = [{"rule": &"NO_TARGET"}]
	weapon_saber_base.costs = []
	weapon_saber_base.actions = []
	weapon_saber_base.description = "光束军刀基础效果。"
	effects[weapon_saber_base.effect_id] = weapon_saber_base

	# ── 光束步枪（远程武器）：攻击修正窗口中，远程武器射程+0（基础效果占位） ──
	var weapon_rifle_base := CardEffect.new()
	weapon_rifle_base.effect_id = &"weapon_rifle_base"
	weapon_rifle_base.display_name = "光束步枪"
	weapon_rifle_base.mode = _EffectConst.MODE_PASSIVE
	weapon_rifle_base.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	weapon_rifle_base.priority = 100
	weapon_rifle_base.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	weapon_rifle_base.target_rules = [{"rule": &"NO_TARGET"}]
	weapon_rifle_base.costs = []
	weapon_rifle_base.actions = []
	weapon_rifle_base.description = "光束步枪基础效果。"
	effects[weapon_rifle_base.effect_id] = weapon_rifle_base

	# ── 远程武器射程+1：被动效果，攻击修正窗口触发 ──
	var passive_range_plus_1 := CardEffect.new()
	passive_range_plus_1.effect_id = &"passive_range_plus_1"
	passive_range_plus_1.display_name = "射程+1"
	passive_range_plus_1.mode = _EffectConst.MODE_PASSIVE
	passive_range_plus_1.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	passive_range_plus_1.priority = 90
	passive_range_plus_1.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	passive_range_plus_1.target_rules = [{"rule": &"NO_TARGET"}]
	passive_range_plus_1.costs = []
	passive_range_plus_1.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 1, "duration": "THIS_ATTACK"}},
	]
	passive_range_plus_1.description = "远程武器攻击时射程+1。"
	effects[passive_range_plus_1.effect_id] = passive_range_plus_1

	# ── 近战武器威力+2：被动效果 ──
	var passive_might_plus_2 := CardEffect.new()
	passive_might_plus_2.effect_id = &"passive_might_plus_2"
	passive_might_plus_2.display_name = "威力+2"
	passive_might_plus_2.mode = _EffectConst.MODE_PASSIVE
	passive_might_plus_2.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	passive_might_plus_2.priority = 90
	passive_might_plus_2.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
	]
	passive_might_plus_2.target_rules = [{"rule": &"NO_TARGET"}]
	passive_might_plus_2.costs = []
	passive_might_plus_2.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 2, "duration": "THIS_ATTACK"}},
	]
	passive_might_plus_2.description = "近战武器攻击时威力+2。"
	effects[passive_might_plus_2.effect_id] = passive_might_plus_2

	# ── 回合开始抽1张额外行动牌 ──
	var passive_draw_extra_action := CardEffect.new()
	passive_draw_extra_action.effect_id = &"passive_draw_extra_action"
	passive_draw_extra_action.display_name = "额外抽牌"
	passive_draw_extra_action.mode = _EffectConst.MODE_PASSIVE
	passive_draw_extra_action.hook = _EffectConst.HOOK_TURN_START
	passive_draw_extra_action.priority = 80
	passive_draw_extra_action.conditions = [{"op": &"ALWAYS"}]
	passive_draw_extra_action.target_rules = [{"rule": &"NO_TARGET"}]
	passive_draw_extra_action.costs = []
	passive_draw_extra_action.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	passive_draw_extra_action.description = "每回合开始额外抽1张行动牌。"
	effects[passive_draw_extra_action.effect_id] = passive_draw_extra_action

	# ── 被攻击时伤害-2：被动防御效果 ──
	var passive_damage_reduce_2 := CardEffect.new()
	passive_damage_reduce_2.effect_id = &"passive_damage_reduce_2"
	passive_damage_reduce_2.display_name = "伤害减免2"
	passive_damage_reduce_2.mode = _EffectConst.MODE_PASSIVE
	passive_damage_reduce_2.hook = _EffectConst.HOOK_DAMAGE_DEALT
	passive_damage_reduce_2.priority = 80
	passive_damage_reduce_2.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	passive_damage_reduce_2.target_rules = [{"rule": &"NO_TARGET"}]
	passive_damage_reduce_2.costs = []
	passive_damage_reduce_2.actions = [
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": -2}},
	]
	passive_damage_reduce_2.description = "被攻击时受到的伤害-2。"
	effects[passive_damage_reduce_2.effect_id] = passive_damage_reduce_2

	# ── 装备被破坏时回复3HP ──
	var passive_heal_on_break := CardEffect.new()
	passive_heal_on_break.effect_id = &"passive_heal_on_break"
	passive_heal_on_break.display_name = "破坏回复"
	passive_heal_on_break.mode = _EffectConst.MODE_PASSIVE
	passive_heal_on_break.hook = _EffectConst.HOOK_EQUIPMENT_BROKEN
	passive_heal_on_break.priority = 100
	passive_heal_on_break.conditions = [{"op": &"ALWAYS"}]
	passive_heal_on_break.target_rules = [{"rule": &"NO_TARGET"}]
	passive_heal_on_break.costs = []
	passive_heal_on_break.actions = [
		{"type": &"HEAL_HP", "params": {"amount": 3}},
	]
	passive_heal_on_break.description = "装备被破坏时回复3点生命。"
	effects[passive_heal_on_break.effect_id] = passive_heal_on_break

	return effects
