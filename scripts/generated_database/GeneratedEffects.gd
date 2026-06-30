## GeneratedEffects.gd — 卡牌效果定义生成器
##
## 分批实现效果：
## 批次1：基础行动牌效果（5个）
## 批次2：基础装备效果（12个）
## 批次3：事件牌效果
## 批次4：行动牌效果（攻击类，9个）
## 批次5：行动牌效果（迎击类，7个）
## 批次6：行动牌效果（辅助类，18个）
## 批次7：装备效果（N稀有度零件 001-023）
## 后续批次在迭代中逐步添加。
##
## 所有效果遵循统一执行链：
## Service → Hook → EffectEngine → ConditionChecker → TargetChecker → CostChecker → AtomicActionResolver → GameActions
class_name GeneratedEffects
extends RefCounted

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const GeneratedPilotEffects = preload("res://scripts/generated_database/GeneratedPilotEffects.gd")


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
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 5, "duration": &"THIS_TURN"}},
	]
	gain_power.description = "本回合使机甲动力+5。"
	effects[gain_power.effect_id] = gain_power

	# ── 推进牌效果：主阶段打出时动力+5（本回合） ──
	var gain_power_this_turn := CardEffect.new()
	gain_power_this_turn.effect_id = &"gain_power_5_this_turn"
	gain_power_this_turn.display_name = "推进"
	gain_power_this_turn.mode = _EffectConst.MODE_PASSIVE
	gain_power_this_turn.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	gain_power_this_turn.priority = 100
	gain_power_this_turn.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	gain_power_this_turn.target_rules = [{"rule": &"NO_TARGET"}]
	gain_power_this_turn.costs = []
	gain_power_this_turn.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 5, "duration": &"THIS_TURN"}},
	]
	gain_power_this_turn.description = "本回合使机甲动力+5。"
	effects[gain_power_this_turn.effect_id] = gain_power_this_turn

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

	# ═══════════════════════════════════════════
	# 批次3：事件牌效果
	# ═══════════════════════════════════════════

	# ── 增援（选择抽2张行动牌）：主动效果，玩家选择 ──
	var event_reinforce_draw_actions := CardEffect.new()
	event_reinforce_draw_actions.effect_id = &"event_reinforce_draw_actions"
	event_reinforce_draw_actions.display_name = "增援：抽2张行动牌"
	event_reinforce_draw_actions.mode = _EffectConst.MODE_ACTIVE
	event_reinforce_draw_actions.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	event_reinforce_draw_actions.priority = 100
	event_reinforce_draw_actions.once_per_turn_key = &"event_reinforce_choice"
	event_reinforce_draw_actions.conditions = [{"op": &"ALWAYS"}]
	event_reinforce_draw_actions.target_rules = [{"rule": &"NO_TARGET"}]
	event_reinforce_draw_actions.costs = []
	event_reinforce_draw_actions.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
	]
	event_reinforce_draw_actions.description = "选择抽2张行动牌。"
	effects[event_reinforce_draw_actions.effect_id] = event_reinforce_draw_actions

	# ── 增援（选择抽1张装备牌）：主动效果，玩家选择 ──
	var event_reinforce_draw_equipment := CardEffect.new()
	event_reinforce_draw_equipment.effect_id = &"event_reinforce_draw_equipment"
	event_reinforce_draw_equipment.display_name = "增援：抽1张装备牌"
	event_reinforce_draw_equipment.mode = _EffectConst.MODE_ACTIVE
	event_reinforce_draw_equipment.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	event_reinforce_draw_equipment.priority = 100
	event_reinforce_draw_equipment.once_per_turn_key = &"event_reinforce_choice"
	event_reinforce_draw_equipment.conditions = [{"op": &"ALWAYS"}]
	event_reinforce_draw_equipment.target_rules = [{"rule": &"NO_TARGET"}]
	event_reinforce_draw_equipment.costs = []
	event_reinforce_draw_equipment.actions = [
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
	]
	event_reinforce_draw_equipment.description = "选择抽1张装备牌。"
	effects[event_reinforce_draw_equipment.effect_id] = event_reinforce_draw_equipment

	# ═══════════════════════════════════════════
	# 批次4：行动牌效果（攻击类）
	# ═══════════════════════════════════════════

	# ── 进攻（基础攻击）：打出攻击牌时触发攻击声明 ──
	var basic_attack_single := CardEffect.new()
	basic_attack_single.effect_id = &"basic_attack_single"
	basic_attack_single.display_name = "进攻"
	basic_attack_single.mode = _EffectConst.MODE_PASSIVE
	basic_attack_single.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	basic_attack_single.priority = 110
	basic_attack_single.conditions = [{"op": &"ALWAYS"}]
	basic_attack_single.target_rules = [{"rule": &"NO_TARGET"}]
	basic_attack_single.costs = []
	basic_attack_single.actions = [{"type": &"START_ATTACK_DECLARE_ATTACK"}]
	basic_attack_single.description = "选择1把武器对1台范围内的机甲发动攻击。"
	effects[basic_attack_single.effect_id] = basic_attack_single

	# ── 强袭移动：攻击响应窗口后、结算前，攻击方可用当前动力移动 ──
	var move_current_power_after_response_before_resolution := CardEffect.new()
	move_current_power_after_response_before_resolution.effect_id = &"move_current_power_after_response_before_resolution"
	move_current_power_after_response_before_resolution.display_name = "强袭移动"
	move_current_power_after_response_before_resolution.mode = _EffectConst.MODE_PASSIVE
	move_current_power_after_response_before_resolution.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	move_current_power_after_response_before_resolution.priority = 95
	move_current_power_after_response_before_resolution.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	move_current_power_after_response_before_resolution.target_rules = [{"rule": &"NO_TARGET"}]
	move_current_power_after_response_before_resolution.costs = []
	move_current_power_after_response_before_resolution.actions = [{"type": &"MOVE_MECH", "params": {"use_current_power": true}}]
	move_current_power_after_response_before_resolution.description = "可以在目标响应后用当前的动力进行移动，之后再结算本次攻击。"
	effects[move_current_power_after_response_before_resolution.effect_id] = move_current_power_after_response_before_resolution

	# ── 猛击+4：攻击修正窗口中，本次攻击威力+4 ──
	var attack_power_plus_4_this_attack := CardEffect.new()
	attack_power_plus_4_this_attack.effect_id = &"attack_power_plus_4_this_attack"
	attack_power_plus_4_this_attack.display_name = "猛击+4"
	attack_power_plus_4_this_attack.mode = _EffectConst.MODE_PASSIVE
	attack_power_plus_4_this_attack.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	attack_power_plus_4_this_attack.priority = 90
	attack_power_plus_4_this_attack.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	attack_power_plus_4_this_attack.target_rules = [{"rule": &"NO_TARGET"}]
	attack_power_plus_4_this_attack.costs = []
	attack_power_plus_4_this_attack.actions = [{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 4, "duration": "THIS_ATTACK"}}]
	attack_power_plus_4_this_attack.description = "使本次攻击威力+4。"
	effects[attack_power_plus_4_this_attack.effect_id] = attack_power_plus_4_this_attack

	# ── 破甲+2损伤：攻击命中时额外增加2枚损伤 ──
	# P2-1: 不直接 PLACE_DAMAGE_TOKENS（会绕过统一的损伤放置方判断和逐枚放置UI）
	# 改为写入 attack_context["extra_markers"]+=2，最终 markers = markers + extra_markers
	var on_hit_add_2_damage_markers := CardEffect.new()
	on_hit_add_2_damage_markers.effect_id = &"on_hit_add_2_damage_markers"
	on_hit_add_2_damage_markers.display_name = "破甲+2损伤"
	on_hit_add_2_damage_markers.mode = _EffectConst.MODE_PASSIVE
	on_hit_add_2_damage_markers.hook = _EffectConst.HOOK_ATTACK_HIT
	on_hit_add_2_damage_markers.priority = 100
	on_hit_add_2_damage_markers.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	on_hit_add_2_damage_markers.target_rules = [{"rule": &"NO_TARGET"}]
	on_hit_add_2_damage_markers.costs = []
	on_hit_add_2_damage_markers.actions = [{"type": &"PLACE_DAMAGE_TOKENS", "params": {"amount": 2, "target_id": "$payload.target_id", "extra_markers_only": true}}]
	on_hit_add_2_damage_markers.description = "若本次攻击命中则可额外设置2枚损伤。"
	effects[on_hit_add_2_damage_markers.effect_id] = on_hit_add_2_damage_markers

	# ── 双连攻击：打出攻击牌时，可选择1~2个目标 ──
	var attack_one_weapon_one_or_two_targets := CardEffect.new()
	attack_one_weapon_one_or_two_targets.effect_id = &"attack_one_weapon_one_or_two_targets"
	attack_one_weapon_one_or_two_targets.display_name = "双连攻击"
	attack_one_weapon_one_or_two_targets.mode = _EffectConst.MODE_PASSIVE
	attack_one_weapon_one_or_two_targets.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	attack_one_weapon_one_or_two_targets.priority = 110
	attack_one_weapon_one_or_two_targets.conditions = [{"op": &"ALWAYS"}]
	attack_one_weapon_one_or_two_targets.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH"}]
	attack_one_weapon_one_or_two_targets.costs = []
	attack_one_weapon_one_or_two_targets.actions = [{"type": &"START_ATTACK_DECLARE_ATTACK", "params": {"max_targets": 2}}]
	attack_one_weapon_one_or_two_targets.description = "选择1把武器对1~2台范围内的机甲发动攻击。"
	effects[attack_one_weapon_one_or_two_targets.effect_id] = attack_one_weapon_one_or_two_targets

	# ── 闪击再攻：攻击结算后，弃1行动牌可重复同一攻击 ──
	var discard_action_repeat_same_attack := CardEffect.new()
	discard_action_repeat_same_attack.effect_id = &"discard_action_repeat_same_attack"
	discard_action_repeat_same_attack.display_name = "闪击再攻"
	discard_action_repeat_same_attack.mode = _EffectConst.MODE_PASSIVE
	discard_action_repeat_same_attack.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	discard_action_repeat_same_attack.priority = 100
	discard_action_repeat_same_attack.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	discard_action_repeat_same_attack.target_rules = [{"rule": &"NO_TARGET"}]
	discard_action_repeat_same_attack.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true}]
	discard_action_repeat_same_attack.actions = [{"type": &"START_ATTACK_DECLARE_ATTACK", "params": {"repeat_last_attack": true}}]
	discard_action_repeat_same_attack.description = "该攻击结算后，可以弃置1张行动牌，选择相同的武器对相同的目标再次发动攻击。"
	effects[discard_action_repeat_same_attack.effect_id] = discard_action_repeat_same_attack

	# ── 预判锁定：攻击命中时对目标施加锁定效果 ──
	var apply_lock_effect_to_target := CardEffect.new()
	apply_lock_effect_to_target.effect_id = &"apply_lock_effect_to_target"
	apply_lock_effect_to_target.display_name = "预判锁定"
	apply_lock_effect_to_target.mode = _EffectConst.MODE_PASSIVE
	apply_lock_effect_to_target.hook = _EffectConst.HOOK_ATTACK_HIT
	apply_lock_effect_to_target.priority = 100
	apply_lock_effect_to_target.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	apply_lock_effect_to_target.target_rules = [{"rule": &"NO_TARGET"}]
	apply_lock_effect_to_target.costs = []
	apply_lock_effect_to_target.actions = [{"type": &"APPLY_OR_CHECK_LOCKED", "params": {"apply": true, "target_id": "$payload.target_id"}}]
	apply_lock_effect_to_target.description = "对目标施加锁定效果。"
	effects[apply_lock_effect_to_target.effect_id] = apply_lock_effect_to_target

	# ── 弃置目标行动牌：攻击命中时弃置目标1张行动牌 ──
	var discard_target_action_card_1 := CardEffect.new()
	discard_target_action_card_1.effect_id = &"discard_target_action_card_1"
	discard_target_action_card_1.display_name = "弃置目标行动牌"
	discard_target_action_card_1.mode = _EffectConst.MODE_PASSIVE
	discard_target_action_card_1.hook = _EffectConst.HOOK_ATTACK_HIT
	discard_target_action_card_1.priority = 95
	discard_target_action_card_1.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	discard_target_action_card_1.target_rules = [{"rule": &"NO_TARGET"}]
	discard_target_action_card_1.costs = []
	discard_target_action_card_1.actions = [{"type": &"STEAL_ACTION_CARD", "params": {"from_target": true, "count": 1, "discard": true, "target_id": "$payload.target_id"}}]
	discard_target_action_card_1.description = "可以弃置目标1张行动牌。"
	effects[discard_target_action_card_1.effect_id] = discard_target_action_card_1

	# ── 不可无效：此牌发动的攻击不会被无效 ──
	var attack_cannot_be_nullified := CardEffect.new()
	attack_cannot_be_nullified.effect_id = &"attack_cannot_be_nullified"
	attack_cannot_be_nullified.display_name = "不可无效"
	attack_cannot_be_nullified.mode = _EffectConst.MODE_PASSIVE
	attack_cannot_be_nullified.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	attack_cannot_be_nullified.priority = 105
	attack_cannot_be_nullified.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	attack_cannot_be_nullified.target_rules = [{"rule": &"NO_TARGET"}]
	attack_cannot_be_nullified.costs = []
	attack_cannot_be_nullified.actions = [{"type": &"SET_ATTACK_UNNEGATABLE"}]
	attack_cannot_be_nullified.description = "此牌发动的攻击不会被无效。"
	effects[attack_cannot_be_nullified.effect_id] = attack_cannot_be_nullified

	# ═══════════════════════════════════════════
	# 批次5：行动牌效果（迎击类）
	# ═══════════════════════════════════════════

	# ── 防御+5护甲：攻击响应窗口中，被攻击方护甲+5 ──
	var defend_armor_bonus_5 := CardEffect.new()
	defend_armor_bonus_5.effect_id = &"defend_armor_bonus_5"
	defend_armor_bonus_5.display_name = "防御+5护甲"
	defend_armor_bonus_5.mode = _EffectConst.MODE_PASSIVE
	defend_armor_bonus_5.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	defend_armor_bonus_5.priority = 100
	defend_armor_bonus_5.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	defend_armor_bonus_5.target_rules = [{"rule": &"NO_TARGET"}]
	defend_armor_bonus_5.costs = []
	defend_armor_bonus_5.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 5, "duration": "THIS_ATTACK"}},
	]
	defend_armor_bonus_5.description = "响应对我方的攻击，在本次攻击结算前使机甲护甲+5。"
	effects[defend_armor_bonus_5.effect_id] = defend_armor_bonus_5

	# ── 减少1损伤：伤害修正窗口中，被攻击方损伤-1 ──
	var reduce_attack_damage_marker_1 := CardEffect.new()
	reduce_attack_damage_marker_1.effect_id = &"reduce_attack_damage_marker_1"
	reduce_attack_damage_marker_1.display_name = "减少1损伤"
	reduce_attack_damage_marker_1.mode = _EffectConst.MODE_PASSIVE
	reduce_attack_damage_marker_1.hook = _EffectConst.HOOK_DAMAGE_MODIFIER_WINDOW
	reduce_attack_damage_marker_1.priority = 90
	reduce_attack_damage_marker_1.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	reduce_attack_damage_marker_1.target_rules = [{"rule": &"NO_TARGET"}]
	reduce_attack_damage_marker_1.costs = []
	reduce_attack_damage_marker_1.actions = [
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": -1}},
	]
	reduce_attack_damage_marker_1.description = "减少该攻击产生的1损伤。"
	effects[reduce_attack_damage_marker_1.effect_id] = reduce_attack_damage_marker_1

	# ── 反击：攻击结算后，被攻击方可发动攻击 ──
	var counterattack_after_resolution := CardEffect.new()
	counterattack_after_resolution.effect_id = &"counterattack_after_resolution"
	counterattack_after_resolution.display_name = "反击"
	counterattack_after_resolution.mode = _EffectConst.MODE_PASSIVE
	counterattack_after_resolution.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	counterattack_after_resolution.priority = 100
	counterattack_after_resolution.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	counterattack_after_resolution.target_rules = [{"rule": &"NO_TARGET"}]
	counterattack_after_resolution.costs = []
	counterattack_after_resolution.actions = [
		{"type": &"START_ATTACK_DECLARE_ATTACK"},
	]
	counterattack_after_resolution.description = "该攻击结算后，可以选择1把武器对1台攻击范围内的机甲发动攻击。"
	effects[counterattack_after_resolution.effect_id] = counterattack_after_resolution

	# ── 疾行：攻击响应窗口中，被攻击方可全力移动 ──
	var evade_full_power := CardEffect.new()
	evade_full_power.effect_id = &"evade_full_power"
	evade_full_power.display_name = "疾行"
	evade_full_power.mode = _EffectConst.MODE_PASSIVE
	evade_full_power.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	evade_full_power.priority = 100
	evade_full_power.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	evade_full_power.target_rules = [{"rule": &"NO_TARGET"}]
	evade_full_power.costs = []
	evade_full_power.actions = [
		{"type": &"MOVE_MECH", "params": {"use_current_power": true}},
	]
	evade_full_power.description = "响应对我方的攻击，可以用当前的动力进行移动。"
	effects[evade_full_power.effect_id] = evade_full_power

	# ── 识破无效：攻击响应窗口中，被攻击方直接无效攻击 ──
	# P2-2: 包含 APPLY_OR_CHECK_LOCKED(ignore_lock=true)，使识破无视锁定状态
	var nullify_attack := CardEffect.new()
	nullify_attack.effect_id = &"nullify_attack"
	nullify_attack.display_name = "识破无效"
	nullify_attack.mode = _EffectConst.MODE_PASSIVE
	nullify_attack.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	nullify_attack.priority = 80
	nullify_attack.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	nullify_attack.target_rules = [{"rule": &"NO_TARGET"}]
	nullify_attack.costs = []
	nullify_attack.actions = [
		{"type": &"APPLY_OR_CHECK_LOCKED", "params": {"ignore_lock": true}},
		{"type": &"NEGATE_ATTACK"},
	]
	nullify_attack.description = "响应对我方的攻击，直接无效该攻击。此牌不受锁定影响。"
	effects[nullify_attack.effect_id] = nullify_attack

	# ── 获得攻击方行动牌：攻击响应窗口中，被攻击方偷1张行动牌 ──
	var gain_attacker_action_card_1 := CardEffect.new()
	gain_attacker_action_card_1.effect_id = &"gain_attacker_action_card_1"
	gain_attacker_action_card_1.display_name = "获得攻击方行动牌"
	gain_attacker_action_card_1.mode = _EffectConst.MODE_PASSIVE
	gain_attacker_action_card_1.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	gain_attacker_action_card_1.priority = 85
	gain_attacker_action_card_1.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	gain_attacker_action_card_1.target_rules = [{"rule": &"NO_TARGET"}]
	gain_attacker_action_card_1.costs = []
	gain_attacker_action_card_1.actions = [
		{"type": &"STEAL_ACTION_CARD", "params": {"from_attacker": true, "count": 1}},
	]
	gain_attacker_action_card_1.description = "获得攻击方的1张行动牌。"
	effects[gain_attacker_action_card_1.effect_id] = gain_attacker_action_card_1

	# ── 无视锁定：打出攻击牌时不受锁定影响 ──
	var ignore_lock_when_played := CardEffect.new()
	ignore_lock_when_played.effect_id = &"ignore_lock_when_played"
	ignore_lock_when_played.display_name = "无视锁定"
	ignore_lock_when_played.mode = _EffectConst.MODE_PASSIVE
	ignore_lock_when_played.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	ignore_lock_when_played.priority = 80
	ignore_lock_when_played.conditions = [{"op": &"ALWAYS"}]
	ignore_lock_when_played.target_rules = [{"rule": &"NO_TARGET"}]
	ignore_lock_when_played.costs = []
	ignore_lock_when_played.actions = [
		{"type": &"APPLY_OR_CHECK_LOCKED", "params": {"ignore_lock": true}},
	]
	ignore_lock_when_played.description = "打出此牌不受锁定影响。"
	effects[ignore_lock_when_played.effect_id] = ignore_lock_when_played

	# ═══════════════════════════════════════════
	# 批次6：行动牌效果（辅助类）
	# ═══════════════════════════════════════════

	# ── 维修选择：主阶段二选一（回复2HP 或 移除2损伤）──
	var repair_choose_one := CardEffect.new()
	repair_choose_one.effect_id = &"repair_choose_one"
	repair_choose_one.display_name = "维修"
	repair_choose_one.mode = _EffectConst.MODE_PASSIVE
	repair_choose_one.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	repair_choose_one.priority = 100
	repair_choose_one.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	repair_choose_one.target_rules = [{"rule": &"NO_TARGET"}]
	repair_choose_one.costs = []
	repair_choose_one.actions = [
		{
			"type": &"CHOOSE_ONE",
			"params": {
				"options": [
					{"effect_id": &"repair_heal_life_2", "label": "回复2点生命"},
					{"effect_id": &"repair_remove_damage_2", "label": "移除2枚损伤"},
				]
			}
		},
	]
	repair_choose_one.description = "回复机甲2点生命或移除2枚损伤。"
	effects[repair_choose_one.effect_id] = repair_choose_one

	# ── 维修回复2HP：被 CHOOSE_ONE 引用的子效果 ──
	var repair_heal_life_2 := CardEffect.new()
	repair_heal_life_2.effect_id = &"repair_heal_life_2"
	repair_heal_life_2.display_name = "维修回复2HP"
	repair_heal_life_2.mode = _EffectConst.MODE_PASSIVE
	repair_heal_life_2.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	repair_heal_life_2.priority = 100
	repair_heal_life_2.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	repair_heal_life_2.target_rules = [{"rule": &"NO_TARGET"}]
	repair_heal_life_2.costs = []
	repair_heal_life_2.actions = [
		{"type": &"HEAL_HP", "params": {"amount": 2}},
	]
	repair_heal_life_2.description = "回复机甲2点生命。"
	effects[repair_heal_life_2.effect_id] = repair_heal_life_2

	# ── 维修移除2损伤：主阶段移除2枚损伤 ──
	var repair_remove_damage_2 := CardEffect.new()
	repair_remove_damage_2.effect_id = &"repair_remove_damage_2"
	repair_remove_damage_2.display_name = "维修移除2损伤"
	repair_remove_damage_2.mode = _EffectConst.MODE_PASSIVE
	repair_remove_damage_2.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	repair_remove_damage_2.priority = 100
	repair_remove_damage_2.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	repair_remove_damage_2.target_rules = [{"rule": &"NO_TARGET"}]
	repair_remove_damage_2.costs = []
	repair_remove_damage_2.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount": 2}},
	]
	repair_remove_damage_2.description = "移除2枚损伤。"
	effects[repair_remove_damage_2.effect_id] = repair_remove_damage_2

	# ── 可对相邻机甲使用：主阶段可对相邻机甲使用 ──
	var can_target_adjacent_mecha := CardEffect.new()
	can_target_adjacent_mecha.effect_id = &"can_target_adjacent_mecha"
	can_target_adjacent_mecha.display_name = "可对相邻机甲使用"
	can_target_adjacent_mecha.mode = _EffectConst.MODE_PASSIVE
	can_target_adjacent_mecha.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	can_target_adjacent_mecha.priority = 90
	can_target_adjacent_mecha.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	can_target_adjacent_mecha.target_rules = [{"rule": &"TARGET_IS_ADJACENT"}]
	can_target_adjacent_mecha.costs = []
	can_target_adjacent_mecha.actions = []
	can_target_adjacent_mecha.description = "也可对1格范围内的其他机甲使用。"
	effects[can_target_adjacent_mecha.effect_id] = can_target_adjacent_mecha

	# ── 聚能+4威力：主阶段选择我方武器，下次攻击威力+4 ──
	# P2-3: 改为 APPLY_ENERGY_TO_WEAPON（两步效果）：
	# 1. 主阶段执行 APPLY_ENERGY_TO_WEAPON → 在武器 MechStatus 上标记 next_attack_power_buff: 4
	# 2. 下次攻击 MODIFIER_WINDOW 时，consume_next_attack_power_buff 检查并执行 MODIFY_ATTACK_POWER
	var next_attack_power_plus_4_selected_weapon := CardEffect.new()
	next_attack_power_plus_4_selected_weapon.effect_id = &"next_attack_power_plus_4_selected_weapon"
	next_attack_power_plus_4_selected_weapon.display_name = "聚能+4威力"
	next_attack_power_plus_4_selected_weapon.mode = _EffectConst.MODE_PASSIVE
	next_attack_power_plus_4_selected_weapon.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	next_attack_power_plus_4_selected_weapon.priority = 100
	next_attack_power_plus_4_selected_weapon.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	next_attack_power_plus_4_selected_weapon.target_rules = [{"rule": &"CHOOSE_OWN_WEAPON"}]
	next_attack_power_plus_4_selected_weapon.costs = []
	next_attack_power_plus_4_selected_weapon.actions = [
		{"type": &"APPLY_ENERGY_TO_WEAPON", "params": {"delta": 4}},
	]
	next_attack_power_plus_4_selected_weapon.description = "本回合内选择我方1把武器使其下次发动的攻击威力+4。"
	effects[next_attack_power_plus_4_selected_weapon.effect_id] = next_attack_power_plus_4_selected_weapon

	# ── 可与迎击牌一同打出：打出攻击牌时允许与迎击牌组合 ──
	var can_play_with_reaction_card := CardEffect.new()
	can_play_with_reaction_card.effect_id = &"can_play_with_reaction_card"
	can_play_with_reaction_card.display_name = "可与迎击牌一同打出"
	can_play_with_reaction_card.mode = _EffectConst.MODE_PASSIVE
	can_play_with_reaction_card.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	can_play_with_reaction_card.priority = 80
	can_play_with_reaction_card.conditions = [{"op": &"ALWAYS"}]
	can_play_with_reaction_card.target_rules = [{"rule": &"NO_TARGET"}]
	can_play_with_reaction_card.costs = []
	can_play_with_reaction_card.actions = [
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"play_with_reaction", "duration": &"THIS_TURN"}},
	]
	can_play_with_reaction_card.description = "此牌也可以与迎击牌一同打出。"
	effects[can_play_with_reaction_card.effect_id] = can_play_with_reaction_card

	# ── 掩护-5威力：攻击修正窗口中，使攻击威力-5 ──
	# P2-3/P0-5: 掩护牌走独立流程（submit_cover），不再用 ATTACK_DECLARED 自动触发
	# 改为 HOOK_ATTACK_MODIFIER_WINDOW，由 _resolve_card_effects_snapshot("cover_card", ...) 解析
	var cover_reduce_attack_power_5 := CardEffect.new()
	cover_reduce_attack_power_5.effect_id = &"cover_reduce_attack_power_5"
	cover_reduce_attack_power_5.display_name = "掩护-5威力"
	cover_reduce_attack_power_5.mode = _EffectConst.MODE_PASSIVE
	cover_reduce_attack_power_5.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	cover_reduce_attack_power_5.priority = 90
	cover_reduce_attack_power_5.conditions = [{"op": &"ALLY_IN_WEAPON_RANGE_IS_TARGET"}]
	cover_reduce_attack_power_5.target_rules = [{"rule": &"NO_TARGET"}]
	cover_reduce_attack_power_5.costs = []
	cover_reduce_attack_power_5.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": -5, "duration": "THIS_ATTACK"}},
	]
	cover_reduce_attack_power_5.description = "已设置武器的范围内存在机甲被攻击时可以打出，使该攻击威力-5。"
	effects[cover_reduce_attack_power_5.effect_id] = cover_reduce_attack_power_5

	# ── 设陷2次机会：主阶段本回合有2次陷阱机会 ──
	var trap_two_chances_this_turn := CardEffect.new()
	trap_two_chances_this_turn.effect_id = &"trap_two_chances_this_turn"
	trap_two_chances_this_turn.display_name = "设陷2次机会"
	trap_two_chances_this_turn.mode = _EffectConst.MODE_PASSIVE
	trap_two_chances_this_turn.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	trap_two_chances_this_turn.priority = 100
	trap_two_chances_this_turn.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	trap_two_chances_this_turn.target_rules = [{"rule": &"NO_TARGET"}]
	trap_two_chances_this_turn.costs = []
	trap_two_chances_this_turn.actions = [
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"trap_chances", "value": 2, "duration": &"THIS_TURN"}},
	]
	trap_two_chances_this_turn.description = "本回合有2次机会。"
	effects[trap_two_chances_this_turn.effect_id] = trap_two_chances_this_turn

	# ── 离开格子设陷阱：机甲离开格子时在该格设陷阱 ──
	var set_trap_when_leaving_cell := CardEffect.new()
	set_trap_when_leaving_cell.effect_id = &"set_trap_when_leaving_cell"
	set_trap_when_leaving_cell.display_name = "离开格子设陷阱"
	set_trap_when_leaving_cell.mode = _EffectConst.MODE_PASSIVE
	set_trap_when_leaving_cell.hook = _EffectConst.HOOK_MECH_LEAVING_CELL
	set_trap_when_leaving_cell.priority = 100
	set_trap_when_leaving_cell.conditions = [{"op": &"ALWAYS"}]
	set_trap_when_leaving_cell.target_rules = [{"rule": &"CHOOSE_MAP_CELL_IN_WEAPON_RANGE"}]
	set_trap_when_leaving_cell.costs = []
	set_trap_when_leaving_cell.actions = [
		{"type": &"PLACE_TRAP_MARKER", "params": {"cell_pos": &"$payload.leaving_cell_pos"}},
	]
	set_trap_when_leaving_cell.description = "当机甲离开某格子时可以在该格子上设置1枚陷阱。"
	effects[set_trap_when_leaving_cell.effect_id] = set_trap_when_leaving_cell

	# ── 联合：攻击结算后选择其他机甲使其可攻击 ──
	var allow_other_mecha_attack_after_your_attack := CardEffect.new()
	allow_other_mecha_attack_after_your_attack.effect_id = &"allow_other_mecha_attack_after_your_attack"
	allow_other_mecha_attack_after_your_attack.display_name = "联合"
	allow_other_mecha_attack_after_your_attack.mode = _EffectConst.MODE_PASSIVE
	allow_other_mecha_attack_after_your_attack.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	allow_other_mecha_attack_after_your_attack.priority = 100
	allow_other_mecha_attack_after_your_attack.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	allow_other_mecha_attack_after_your_attack.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 5}]
	allow_other_mecha_attack_after_your_attack.costs = []
	allow_other_mecha_attack_after_your_attack.actions = [
		{"type": &"FORCE_MECH_ACTION", "params": {"action_type": &"attack"}},
	]
	allow_other_mecha_attack_after_your_attack.description = "选择其他1台机甲，本回合其在你发动攻击结算完成后也可以打出1张攻击牌。"
	effects[allow_other_mecha_attack_after_your_attack.effect_id] = allow_other_mecha_attack_after_your_attack

	# ── 弃置抽1行动牌：主动效果，弃置此牌抽1张行动牌 ──
	var discard_self_draw_action_1 := CardEffect.new()
	discard_self_draw_action_1.effect_id = &"discard_self_draw_action_1"
	discard_self_draw_action_1.display_name = "弃置抽1行动牌"
	discard_self_draw_action_1.mode = _EffectConst.MODE_ACTIVE
	discard_self_draw_action_1.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	discard_self_draw_action_1.priority = 100
	discard_self_draw_action_1.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	discard_self_draw_action_1.target_rules = [{"rule": &"NO_TARGET"}]
	discard_self_draw_action_1.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	discard_self_draw_action_1.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	discard_self_draw_action_1.description = "也可以弃置此牌，然后抽1张行动牌。"
	effects[discard_self_draw_action_1.effect_id] = discard_self_draw_action_1

	# ── 回收：主动效果，从装备弃牌堆随机抽1张 ──
	var draw_random_equipment_from_discard := CardEffect.new()
	draw_random_equipment_from_discard.effect_id = &"draw_random_equipment_from_discard"
	draw_random_equipment_from_discard.display_name = "回收"
	draw_random_equipment_from_discard.mode = _EffectConst.MODE_ACTIVE
	draw_random_equipment_from_discard.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	draw_random_equipment_from_discard.priority = 100
	draw_random_equipment_from_discard.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	draw_random_equipment_from_discard.target_rules = [{"rule": &"NO_TARGET"}]
	draw_random_equipment_from_discard.costs = []
	draw_random_equipment_from_discard.actions = [
		{"type": &"RANDOM_DRAW_FROM_DISCARD_OR_DECK", "params": {"type": &"equipment", "count": 1}},
	]
	draw_random_equipment_from_discard.description = "从装备弃牌堆里随机抽1张牌。"
	effects[draw_random_equipment_from_discard.effect_id] = draw_random_equipment_from_discard

	# ── 回忆：主动效果，从行动弃牌堆随机抽2张 ──
	var draw_random_action_2_from_discard := CardEffect.new()
	draw_random_action_2_from_discard.effect_id = &"draw_random_action_2_from_discard"
	draw_random_action_2_from_discard.display_name = "回忆"
	draw_random_action_2_from_discard.mode = _EffectConst.MODE_ACTIVE
	draw_random_action_2_from_discard.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	draw_random_action_2_from_discard.priority = 100
	draw_random_action_2_from_discard.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	draw_random_action_2_from_discard.target_rules = [{"rule": &"NO_TARGET"}]
	draw_random_action_2_from_discard.costs = []
	draw_random_action_2_from_discard.actions = [
		{"type": &"RANDOM_DRAW_FROM_DISCARD_OR_DECK", "params": {"type": &"action", "count": 2}},
	]
	draw_random_action_2_from_discard.description = "从行动弃牌堆里随机抽2张牌。"
	effects[draw_random_action_2_from_discard.effect_id] = draw_random_action_2_from_discard

	# ── 折扣：主动效果，本回合2次以原价购买装备 ──
	var buy_equipment_at_face_value_twice := CardEffect.new()
	buy_equipment_at_face_value_twice.effect_id = &"buy_equipment_at_face_value_twice"
	buy_equipment_at_face_value_twice.display_name = "折扣"
	buy_equipment_at_face_value_twice.mode = _EffectConst.MODE_ACTIVE
	buy_equipment_at_face_value_twice.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	buy_equipment_at_face_value_twice.priority = 100
	buy_equipment_at_face_value_twice.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	buy_equipment_at_face_value_twice.target_rules = [{"rule": &"NO_TARGET"}]
	buy_equipment_at_face_value_twice.costs = []
	buy_equipment_at_face_value_twice.actions = [
		{"type": &"SHOP_BUY_MODIFIER", "params": {"face_value": true, "uses": 2}},
	]
	buy_equipment_at_face_value_twice.description = "本回合有2次机会，可以在商店中以原价购买装备牌。"
	effects[buy_equipment_at_face_value_twice.effect_id] = buy_equipment_at_face_value_twice

	# ── 补给：主动效果，抽2张行动牌与1张装备牌 ──
	var draw_action_2_equipment_1 := CardEffect.new()
	draw_action_2_equipment_1.effect_id = &"draw_action_2_equipment_1"
	draw_action_2_equipment_1.display_name = "补给"
	draw_action_2_equipment_1.mode = _EffectConst.MODE_ACTIVE
	draw_action_2_equipment_1.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	draw_action_2_equipment_1.priority = 100
	draw_action_2_equipment_1.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	draw_action_2_equipment_1.target_rules = [{"rule": &"NO_TARGET"}]
	draw_action_2_equipment_1.costs = []
	draw_action_2_equipment_1.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
	]
	draw_action_2_equipment_1.description = "抽2张行动牌与1张装备牌。"
	effects[draw_action_2_equipment_1.effect_id] = draw_action_2_equipment_1

	# ── 锁定不可响应：主阶段打出时指定敌方机甲使其不能响应 ──
	# P2-3: hook从HOOK_ATTACK_CARD_PLAYED改为HOOK_OWNER_MAIN_PHASE
	# 锁定是辅助牌，主阶段打出不应挂在ATTACK_CARD_PLAYED
	# 状态只禁止响应来源玩家发动的攻击（检查attack_context["attack_source_player_id"]与状态的source_player_id匹配）
	var target_cannot_react_to_your_attacks := CardEffect.new()
	target_cannot_react_to_your_attacks.effect_id = &"target_cannot_react_to_your_attacks"
	target_cannot_react_to_your_attacks.display_name = "锁定不可响应"
	target_cannot_react_to_your_attacks.mode = _EffectConst.MODE_PASSIVE
	target_cannot_react_to_your_attacks.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	target_cannot_react_to_your_attacks.priority = 95
	target_cannot_react_to_your_attacks.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	target_cannot_react_to_your_attacks.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE", "range": 5}]
	target_cannot_react_to_your_attacks.costs = []
	target_cannot_react_to_your_attacks.actions = [
		{"type": &"APPLY_CANNOT_RESPOND", "params": {"duration": &"THIS_TURN"}},
	]
	target_cannot_react_to_your_attacks.description = "指定其他1台机甲，本回合其不能响应你发动的攻击。"
	effects[target_cannot_react_to_your_attacks.effect_id] = target_cannot_react_to_your_attacks

	# ── 命中后结束锁定：攻击命中后移除不可响应状态 ──
	var lock_effect_ends_after_target_hit := CardEffect.new()
	lock_effect_ends_after_target_hit.effect_id = &"lock_effect_ends_after_target_hit"
	lock_effect_ends_after_target_hit.display_name = "命中后结束锁定"
	lock_effect_ends_after_target_hit.mode = _EffectConst.MODE_PASSIVE
	lock_effect_ends_after_target_hit.hook = _EffectConst.HOOK_ATTACK_HIT
	lock_effect_ends_after_target_hit.priority = 100
	lock_effect_ends_after_target_hit.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"PAYLOAD_ATTACK_HIT"},
	]
	lock_effect_ends_after_target_hit.target_rules = [{"rule": &"NO_TARGET"}]
	lock_effect_ends_after_target_hit.costs = []
	lock_effect_ends_after_target_hit.actions = [
		{"type": &"REMOVE_STATUS", "params": {"status_type": &"cannot_respond", "target_id": "$payload.target_id"}},
	]
	lock_effect_ends_after_target_hit.description = "该目标机甲被攻击命中后结束以上效果。"
	effects[lock_effect_ends_after_target_hit.effect_id] = lock_effect_ends_after_target_hit

	# ── 觉醒获得预判识破：主动效果，从弃牌堆获得预判与识破 ──
	var gain_prediction_and_insight_from_action_discard := CardEffect.new()
	gain_prediction_and_insight_from_action_discard.effect_id = &"gain_prediction_and_insight_from_action_discard"
	gain_prediction_and_insight_from_action_discard.display_name = "觉醒获得预判识破"
	gain_prediction_and_insight_from_action_discard.mode = _EffectConst.MODE_ACTIVE
	gain_prediction_and_insight_from_action_discard.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	gain_prediction_and_insight_from_action_discard.priority = 100
	gain_prediction_and_insight_from_action_discard.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	gain_prediction_and_insight_from_action_discard.target_rules = [{"rule": &"NO_TARGET"}]
	gain_prediction_and_insight_from_action_discard.costs = []
	gain_prediction_and_insight_from_action_discard.actions = [
		{"type": &"GAIN_SPECIFIC_CARD", "params": {"card_ids": [&"action_006_闪击", &"action_012_识破"]}},
	]
	gain_prediction_and_insight_from_action_discard.description = "从行动弃牌堆里获得预判与识破各1张。"
	effects[gain_prediction_and_insight_from_action_discard.effect_id] = gain_prediction_and_insight_from_action_discard

	# ── 觉醒替代缺失：主动效果，缺少的牌用指定获得+抽牌替代 ──
	var replace_missing_named_action_and_draw := CardEffect.new()
	replace_missing_named_action_and_draw.effect_id = &"replace_missing_named_action_and_draw"
	replace_missing_named_action_and_draw.display_name = "觉醒替代缺失"
	replace_missing_named_action_and_draw.mode = _EffectConst.MODE_ACTIVE
	replace_missing_named_action_and_draw.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	replace_missing_named_action_and_draw.priority = 95
	replace_missing_named_action_and_draw.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	replace_missing_named_action_and_draw.target_rules = [{"rule": &"NO_TARGET"}]
	replace_missing_named_action_and_draw.costs = []
	replace_missing_named_action_and_draw.actions = [
		{"type": &"GAIN_SPECIFIC_CARD", "params": {"fallback_to_choice": true, "draw_per_missing": 1}},
	]
	replace_missing_named_action_and_draw.description = "弃牌堆每缺少以上记述的1种行动牌，则可以从弃牌堆里指定获得1张行动牌，并抽1张行动牌。"
	effects[replace_missing_named_action_and_draw.effect_id] = replace_missing_named_action_and_draw

	# ═══════════════════════════════════════════
	# 批次7：装备效果（N稀有度零件 001-023）
	# ═══════════════════════════════════════════

	# ── equipment_effect_001：此牌设置在区域中依然可以卖出 ──
	var equipment_effect_001 := CardEffect.new()
	equipment_effect_001.effect_id = &"equipment_effect_001"
	equipment_effect_001.display_name = "可卖出已设置装备"
	equipment_effect_001.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_001.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_001.priority = 100
	equipment_effect_001.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_001.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_001.costs = []
	equipment_effect_001.actions = [
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"can_sell_equipped", "duration": &"PERMANENT"}},
	]
	equipment_effect_001.description = "此牌设置在区域中依然可以卖出。"
	effects[equipment_effect_001.effect_id] = equipment_effect_001

	# ── equipment_effect_002：其他区域每设置有1张名称带有联邦的装备牌则此牌护甲+1 ──
	var equipment_effect_002 := CardEffect.new()
	equipment_effect_002.effect_id = &"equipment_effect_002"
	equipment_effect_002.display_name = "联邦联动护甲+1"
	equipment_effect_002.mode = _EffectConst.MODE_STATIC
	equipment_effect_002.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_002.priority = 60
	equipment_effect_002.conditions = [{"op": &"COUNT_EQUIPMENT_WITH_NAME_CONTAINS", "substring": &"联邦", "min_count": 1}]
	equipment_effect_002.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_002.costs = []
	equipment_effect_002.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 1, "per_matching_equipment": true, "substring": &"联邦", "duration": &"PERMANENT"}},
	]
	equipment_effect_002.description = "其他区域每设置有1张名称带有联邦的装备牌则此牌护甲+1。"
	effects[equipment_effect_002.effect_id] = equipment_effect_002

	# ── equipment_effect_003：此牌从区域中弃置时可移除此牌原先所在区域内的所有损伤 ──
	var equipment_effect_003 := CardEffect.new()
	equipment_effect_003.effect_id = &"equipment_effect_003"
	equipment_effect_003.display_name = "弃置清除区域损伤"
	equipment_effect_003.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_003.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	equipment_effect_003.priority = 100
	equipment_effect_003.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_003.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_003.costs = []
	equipment_effect_003.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount": -1, "all_in_slot": true}},
	]
	equipment_effect_003.description = "此牌从区域中弃置时可移除此牌原先所在区域内的所有损伤。"
	effects[equipment_effect_003.effect_id] = equipment_effect_003

	# ── equipment_effect_004：将要在其他名称带有联邦的装备牌上设置损伤时，可以将损伤移至此牌所在区域 ──
	var equipment_effect_004 := CardEffect.new()
	equipment_effect_004.effect_id = &"equipment_effect_004"
	equipment_effect_004.display_name = "联邦损伤转移"
	equipment_effect_004.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_004.hook = _EffectConst.HOOK_BEFORE_DAMAGE_TOKEN_PLACED
	equipment_effect_004.priority = 80
	equipment_effect_004.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_004.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_004.costs = []
	equipment_effect_004.actions = [
		{"type": &"REDIRECT_DAMAGE_TOKENS", "params": {"redirect_to_self_slot": true}},
	]
	equipment_effect_004.description = "将要在其他名称带有联邦的装备牌上设置损伤时，可以将损伤移至此牌所在区域。"
	effects[equipment_effect_004.effect_id] = equipment_effect_004

	# ── equipment_effect_005：此牌从区域中弃置时可立即抽1张装备牌并设置到区域上 ──
	var equipment_effect_005 := CardEffect.new()
	equipment_effect_005.effect_id = &"equipment_effect_005"
	equipment_effect_005.display_name = "弃置抽装备设置"
	equipment_effect_005.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_005.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	equipment_effect_005.priority = 100
	equipment_effect_005.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_005.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_005.costs = []
	equipment_effect_005.actions = [
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1, "must_set_or_discard": true}},
	]
	equipment_effect_005.description = "此牌从区域中弃置时可立即抽1张装备牌并设置到区域上。"
	effects[equipment_effect_005.effect_id] = equipment_effect_005

	# ── equipment_effect_006：机甲被指定为攻击目标时，可在当前回合动力+2 ──
	var equipment_effect_006 := CardEffect.new()
	equipment_effect_006.effect_id = &"equipment_effect_006"
	equipment_effect_006.display_name = "被攻击时动力+2"
	equipment_effect_006.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_006.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_006.priority = 100
	equipment_effect_006.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_006.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_006.costs = []
	equipment_effect_006.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": &"THIS_TURN"}},
	]
	equipment_effect_006.description = "机甲被指定为攻击目标时，可在当前回合动力+2。"
	effects[equipment_effect_006.effect_id] = equipment_effect_006

	# ── equipment_effect_007：机甲被攻击命中时，可以弃置此牌，之后可最多减少此次攻击产生的2损伤 ──
	var equipment_effect_007 := CardEffect.new()
	equipment_effect_007.effect_id = &"equipment_effect_007"
	equipment_effect_007.display_name = "被命中弃置减2损伤"
	equipment_effect_007.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_007.hook = _EffectConst.HOOK_MECH_HIT_BY_ATTACK
	equipment_effect_007.priority = 90
	equipment_effect_007.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_007.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_007.costs = [{"cost_type": &"DISCARD_EQUIPMENT_CARD", "count": 1}]
	equipment_effect_007.actions = [
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": -2}},
	]
	equipment_effect_007.description = "机甲被攻击命中时，可以弃置此牌，之后可最多减少此次攻击产生的2损伤。"
	effects[equipment_effect_007.effect_id] = equipment_effect_007

	# ── equipment_effect_008：其他区域每设置有1张名称带有帝国的装备牌则此牌动力+1 ──
	var equipment_effect_008 := CardEffect.new()
	equipment_effect_008.effect_id = &"equipment_effect_008"
	equipment_effect_008.display_name = "帝国联动动力+1"
	equipment_effect_008.mode = _EffectConst.MODE_STATIC
	equipment_effect_008.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_008.priority = 60
	equipment_effect_008.conditions = [{"op": &"COUNT_EQUIPMENT_WITH_NAME_CONTAINS", "substring": &"帝国", "min_count": 1}]
	equipment_effect_008.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_008.costs = []
	equipment_effect_008.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 1, "per_matching_equipment": true, "substring": &"帝国", "duration": &"PERMANENT"}},
	]
	equipment_effect_008.description = "其他区域每设置有1张名称带有帝国的装备牌则此牌动力+1。"
	effects[equipment_effect_008.effect_id] = equipment_effect_008

	# ── equipment_effect_009：机甲被指定为攻击目标时，可在当前回合动力+3，之后护甲-2 ──
	var equipment_effect_009 := CardEffect.new()
	equipment_effect_009.effect_id = &"equipment_effect_009"
	equipment_effect_009.display_name = "被攻击时动力+3护甲-2"
	equipment_effect_009.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_009.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_009.priority = 100
	equipment_effect_009.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_009.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_009.costs = []
	equipment_effect_009.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 3, "duration": &"THIS_TURN"}},
		{"type": &"MODIFY_ARMOR", "params": {"delta": -2, "duration": &"THIS_TURN"}},
	]
	equipment_effect_009.description = "机甲被指定为攻击目标时，可在当前回合动力+3，之后护甲-2。"
	effects[equipment_effect_009.effect_id] = equipment_effect_009

	# ── equipment_effect_010：机甲发动攻击结算后，回复2动力 ──
	var equipment_effect_010 := CardEffect.new()
	equipment_effect_010.effect_id = &"equipment_effect_010"
	equipment_effect_010.display_name = "攻击结算后回复2动力"
	equipment_effect_010.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_010.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	equipment_effect_010.priority = 100
	equipment_effect_010.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	equipment_effect_010.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_010.costs = []
	equipment_effect_010.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	]
	equipment_effect_010.description = "机甲发动攻击结算后，回复2动力。"
	effects[equipment_effect_010.effect_id] = equipment_effect_010

	# ── equipment_effect_011：机甲发动攻击结算后，回复1动力 ──
	var equipment_effect_011 := CardEffect.new()
	equipment_effect_011.effect_id = &"equipment_effect_011"
	equipment_effect_011.display_name = "攻击结算后回复1动力"
	equipment_effect_011.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_011.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	equipment_effect_011.priority = 100
	equipment_effect_011.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	equipment_effect_011.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_011.costs = []
	equipment_effect_011.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	]
	equipment_effect_011.description = "机甲发动攻击结算后，回复1动力。"
	effects[equipment_effect_011.effect_id] = equipment_effect_011

	# ── equipment_effect_012：每回合1次，机甲在当前回合内累积移动过8个格子，可回复2动力 ──
	var equipment_effect_012 := CardEffect.new()
	equipment_effect_012.effect_id = &"equipment_effect_012"
	equipment_effect_012.display_name = "移动8格回复2动力"
	equipment_effect_012.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_012.hook = _EffectConst.HOOK_MECH_MOVED
	equipment_effect_012.priority = 100
	equipment_effect_012.conditions = [{"op": &"MOVED_DISTANCE_THIS_TURN_ABOVE", "threshold": 8}]
	equipment_effect_012.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_012.costs = []
	equipment_effect_012.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	]
	equipment_effect_012.once_per_turn_key = &"equipment_effect_012"
	equipment_effect_012.description = "每回合1次，机甲在当前回合内累积移动过8个格子，可回复2动力。"
	effects[equipment_effect_012.effect_id] = equipment_effect_012

	# ── equipment_effect_013：每回合1次，机甲在当前回合内累积移动过8个格子，可回复1动力 ──
	var equipment_effect_013 := CardEffect.new()
	equipment_effect_013.effect_id = &"equipment_effect_013"
	equipment_effect_013.display_name = "移动8格回复1动力"
	equipment_effect_013.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_013.hook = _EffectConst.HOOK_MECH_MOVED
	equipment_effect_013.priority = 100
	equipment_effect_013.conditions = [{"op": &"MOVED_DISTANCE_THIS_TURN_ABOVE", "threshold": 8}]
	equipment_effect_013.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_013.costs = []
	equipment_effect_013.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	]
	equipment_effect_013.once_per_turn_key = &"equipment_effect_013"
	equipment_effect_013.description = "每回合1次，机甲在当前回合内累积移动过8个格子，可回复1动力。"
	effects[equipment_effect_013.effect_id] = equipment_effect_013

	# ── equipment_effect_014：损伤不会影响此牌所在区域提供的护甲 ──
	var equipment_effect_014 := CardEffect.new()
	equipment_effect_014.effect_id = &"equipment_effect_014"
	equipment_effect_014.display_name = "损伤不影响护甲"
	equipment_effect_014.mode = _EffectConst.MODE_STATIC
	equipment_effect_014.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_014.priority = 50
	equipment_effect_014.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_014.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_014.costs = []
	equipment_effect_014.actions = [
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"ignore_damage_token_armor_penalty", "duration": &"PERMANENT"}},
	]
	equipment_effect_014.description = "损伤不会影响此牌所在区域提供的护甲。"
	effects[equipment_effect_014.effect_id] = equipment_effect_014

	# ── equipment_effect_015：机甲被指定为攻击目标时，可弃置2张行动牌，当前回合护甲+4 ──
	var equipment_effect_015 := CardEffect.new()
	equipment_effect_015.effect_id = &"equipment_effect_015"
	equipment_effect_015.display_name = "被攻击弃2行动牌护甲+4"
	equipment_effect_015.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_015.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_015.priority = 100
	equipment_effect_015.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_015.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_015.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 2}]
	equipment_effect_015.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 4, "duration": &"THIS_TURN"}},
	]
	equipment_effect_015.description = "机甲被指定为攻击目标时，可弃置2张行动牌，当前回合护甲+4。"
	effects[equipment_effect_015.effect_id] = equipment_effect_015

	# ── equipment_effect_016：此牌上设置的损伤≥1时，动力+1 ──
	var equipment_effect_016 := CardEffect.new()
	equipment_effect_016.effect_id = &"equipment_effect_016"
	equipment_effect_016.display_name = "损伤≥1时动力+1"
	equipment_effect_016.mode = _EffectConst.MODE_STATIC
	equipment_effect_016.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_016.priority = 55
	equipment_effect_016.conditions = [{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 1}]
	equipment_effect_016.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_016.costs = []
	equipment_effect_016.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 1, "duration": &"PERMANENT"}},
	]
	equipment_effect_016.description = "此牌上设置的损伤≥1时，动力+1。"
	effects[equipment_effect_016.effect_id] = equipment_effect_016

	# ── equipment_effect_017：每我方回合1次，可以消耗4动力抽1张行动牌 ──
	var equipment_effect_017 := CardEffect.new()
	equipment_effect_017.effect_id = &"equipment_effect_017"
	equipment_effect_017.display_name = "消耗4动力抽1行动牌"
	equipment_effect_017.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_017.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_017.priority = 100
	equipment_effect_017.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_017.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_017.costs = [{"cost_type": &"SPEND_POWER", "amount": 4}]
	equipment_effect_017.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	equipment_effect_017.once_per_turn_key = &"equipment_effect_017"
	equipment_effect_017.description = "每我方回合1次，可以消耗4动力抽1张行动牌。"
	effects[equipment_effect_017.effect_id] = equipment_effect_017

	# ── equipment_effect_018：机甲被指定为攻击目标时，可弃置2张行动牌，当前回合动力+5 ──
	var equipment_effect_018 := CardEffect.new()
	equipment_effect_018.effect_id = &"equipment_effect_018"
	equipment_effect_018.display_name = "被攻击弃2行动牌动力+5"
	equipment_effect_018.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_018.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_018.priority = 100
	equipment_effect_018.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_018.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_018.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 2}]
	equipment_effect_018.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 5, "duration": &"THIS_TURN"}},
	]
	equipment_effect_018.description = "机甲被指定为攻击目标时，可弃置2张行动牌，当前回合动力+5。"
	effects[equipment_effect_018.effect_id] = equipment_effect_018

	# ── equipment_effect_019：其他区域设置的装备牌会因即将设置的损伤而弃置时，可以将最多2损伤转移至此牌所在区域 ──
	var equipment_effect_019 := CardEffect.new()
	equipment_effect_019.effect_id = &"equipment_effect_019"
	equipment_effect_019.display_name = "损伤转移至本区域最多2"
	equipment_effect_019.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_019.hook = _EffectConst.HOOK_BEFORE_DAMAGE_TOKEN_PLACED
	equipment_effect_019.priority = 80
	equipment_effect_019.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_019.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_019.costs = []
	equipment_effect_019.actions = [
		{"type": &"REDIRECT_DAMAGE_TOKENS", "params": {"max_redirect": 2, "redirect_to_self_slot": true}},
	]
	equipment_effect_019.description = "其他区域设置的装备牌会因即将设置的损伤而弃置时，可以将最多2损伤转移至此牌所在区域。"
	effects[equipment_effect_019.effect_id] = equipment_effect_019

	# ── equipment_effect_020：机甲发动的攻击命中后，回复3动力 ──
	var equipment_effect_020 := CardEffect.new()
	equipment_effect_020.effect_id = &"equipment_effect_020"
	equipment_effect_020.display_name = "攻击命中后回复3动力"
	equipment_effect_020.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_020.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_020.priority = 100
	equipment_effect_020.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_020.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_020.costs = []
	equipment_effect_020.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 3}},
	]
	equipment_effect_020.description = "机甲发动的攻击命中后，回复3动力。"
	effects[equipment_effect_020.effect_id] = equipment_effect_020

	# ── equipment_effect_021：此牌上设置的损伤≥2时，动力+1 ──
	var equipment_effect_021 := CardEffect.new()
	equipment_effect_021.effect_id = &"equipment_effect_021"
	equipment_effect_021.display_name = "损伤≥2时动力+1"
	equipment_effect_021.mode = _EffectConst.MODE_STATIC
	equipment_effect_021.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_021.priority = 55
	equipment_effect_021.conditions = [{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 2}]
	equipment_effect_021.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_021.costs = []
	equipment_effect_021.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 1, "duration": &"PERMANENT"}},
	]
	equipment_effect_021.description = "此牌上设置的损伤≥2时，动力+1。"
	effects[equipment_effect_021.effect_id] = equipment_effect_021

	# ── equipment_effect_022：使用远程武器发动攻击时，该攻击范围+1 ──
	var equipment_effect_022 := CardEffect.new()
	equipment_effect_022.effect_id = &"equipment_effect_022"
	equipment_effect_022.display_name = "远程武器攻击范围+1"
	equipment_effect_022.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_022.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_022.priority = 90
	equipment_effect_022.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}, {"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"}]
	equipment_effect_022.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_022.costs = []
	equipment_effect_022.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 1, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_022.description = "使用远程武器发动攻击时，该攻击范围+1。"
	effects[equipment_effect_022.effect_id] = equipment_effect_022

	# ── equipment_effect_023：无效果 ──
	var equipment_effect_023 := CardEffect.new()
	equipment_effect_023.effect_id = &"equipment_effect_023"
	equipment_effect_023.display_name = "无效果"
	equipment_effect_023.mode = _EffectConst.MODE_STATIC
	equipment_effect_023.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_023.priority = 50
	equipment_effect_023.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_023.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_023.costs = []
	equipment_effect_023.actions = []
	equipment_effect_023.description = "无效果。"
	effects[equipment_effect_023.effect_id] = equipment_effect_023

	# ═══════════════════════════════════════════
	# 批次9：装备效果（SSR零件+武器 085-129）
	# ═══════════════════════════════════════════

	# ── 085：此牌也可以当作威力20，范围6的远程武器使用。 ──
	var equipment_effect_085 := CardEffect.new()
	equipment_effect_085.effect_id = &"equipment_effect_085"
	equipment_effect_085.display_name = "可当作远程武器"
	equipment_effect_085.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_085.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_085.priority = 100
	equipment_effect_085.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_085.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_085.costs = []
	equipment_effect_085.actions = [
		{"type": &"SET_WEAPON_STATS", "params": {"might": 20, "range": 6, "weapon_kind": &"远程"}},
	]
	equipment_effect_085.description = "此牌也可以当作威力20，范围6的远程武器使用。"
	effects[equipment_effect_085.effect_id] = equipment_effect_085

	# ── 086：使用此牌发动攻击需要消耗当前所有动力(不为0)，且直到下个我方回合开始无法回复。 ──
	var equipment_effect_086 := CardEffect.new()
	equipment_effect_086.effect_id = &"equipment_effect_086"
	equipment_effect_086.display_name = "消耗所有动力攻击"
	equipment_effect_086.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_086.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	equipment_effect_086.priority = 80
	equipment_effect_086.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_086.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_086.costs = [{"cost_type": &"SPEND_ALL_POWER"}]
	equipment_effect_086.actions = [
		{"type": &"ADD_STATUS", "params": {"status_type": &"no_power_restore", "duration": &"UNTIL_NEXT_OWNER_TURN"}},
	]
	equipment_effect_086.description = "使用此牌发动攻击需要消耗当前所有动力(不为0)，且直到下个我方回合开始无法回复。"
	effects[equipment_effect_086.effect_id] = equipment_effect_086

	# ── 087：发动攻击命中时，可以设置2损伤到此牌上，之后抽3张行动牌，回复3动力。 ──
	var equipment_effect_087 := CardEffect.new()
	equipment_effect_087.effect_id = &"equipment_effect_087"
	equipment_effect_087.display_name = "命中自损抽牌回动力"
	equipment_effect_087.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_087.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_087.priority = 100
	equipment_effect_087.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_087.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_087.costs = []
	equipment_effect_087.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
		{"type": &"DRAW_ACTION", "params": {"count": 3}},
		{"type": &"RESTORE_POWER", "params": {"amount": 3}},
	]
	equipment_effect_087.description = "发动攻击命中时，可以设置2损伤到此牌上，之后抽3张行动牌，回复3动力。"
	effects[equipment_effect_087.effect_id] = equipment_effect_087

	# ── 088：每回合1次，机甲在当前回合内消耗了8动力，可无视动力移动2格。 ──
	var equipment_effect_088 := CardEffect.new()
	equipment_effect_088.effect_id = &"equipment_effect_088"
	equipment_effect_088.display_name = "耗8动力免费移动2格"
	equipment_effect_088.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_088.hook = _EffectConst.HOOK_TURN_END
	equipment_effect_088.priority = 100
	equipment_effect_088.conditions = [{"op": &"POWER_SPENT_THIS_TURN_ABOVE", "threshold": 8}]
	equipment_effect_088.once_per_turn_key = &"equipment_effect_088"
	equipment_effect_088.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_088.costs = []
	equipment_effect_088.actions = [
		{"type": &"MOVE_WITHOUT_POWER", "params": {"cells": 2}},
	]
	equipment_effect_088.description = "每回合1次，机甲在当前回合内消耗了8动力，可无视动力移动2格。"
	effects[equipment_effect_088.effect_id] = equipment_effect_088

	# ── 089：对此牌使用聚能时，本回合额外使此牌范围+1。 ──
	var equipment_effect_089 := CardEffect.new()
	equipment_effect_089.effect_id = &"equipment_effect_089"
	equipment_effect_089.display_name = "聚能范围+1"
	equipment_effect_089.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_089.hook = _EffectConst.HOOK_ENERGY_APPLIED_TO_WEAPON
	equipment_effect_089.priority = 100
	equipment_effect_089.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_089.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_089.costs = []
	equipment_effect_089.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 1, "duration": &"THIS_TURN"}},
	]
	equipment_effect_089.description = "对此牌使用聚能时，本回合额外使此牌范围+1。"
	effects[equipment_effect_089.effect_id] = equipment_effect_089

	# ── 090：机甲被名称带有光束的武器攻击时，可弃置1张攻击行动牌响应，使该攻击威力-5。 ──
	var equipment_effect_090 := CardEffect.new()
	equipment_effect_090.effect_id = &"equipment_effect_090"
	equipment_effect_090.display_name = "对光束武器威力-5"
	equipment_effect_090.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_090.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	equipment_effect_090.priority = 90
	equipment_effect_090.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"光束"},
	]
	equipment_effect_090.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_090.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "card_type_filter": &"攻击"}]
	equipment_effect_090.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": -5, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_090.description = "机甲被名称带有光束的武器攻击时，可弃置1张攻击行动牌响应，使该攻击威力-5。"
	effects[equipment_effect_090.effect_id] = equipment_effect_090

	# ── 091：对此牌使用聚能时，本回合额外使此牌威力+3。 ──
	var equipment_effect_091 := CardEffect.new()
	equipment_effect_091.effect_id = &"equipment_effect_091"
	equipment_effect_091.display_name = "聚能威力+3"
	equipment_effect_091.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_091.hook = _EffectConst.HOOK_ENERGY_APPLIED_TO_WEAPON
	equipment_effect_091.priority = 100
	equipment_effect_091.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_091.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_091.costs = []
	equipment_effect_091.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": &"THIS_TURN"}},
	]
	equipment_effect_091.description = "对此牌使用聚能时，本回合额外使此牌威力+3。"
	effects[equipment_effect_091.effect_id] = equipment_effect_091

	# ── 092：机甲被名称带有热能的武器攻击时，可弃置1张攻击行动牌响应该攻击，使该攻击威力-5。 ──
	var equipment_effect_092 := CardEffect.new()
	equipment_effect_092.effect_id = &"equipment_effect_092"
	equipment_effect_092.display_name = "对热能武器威力-5"
	equipment_effect_092.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_092.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	equipment_effect_092.priority = 90
	equipment_effect_092.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"热能"},
	]
	equipment_effect_092.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_092.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "card_type_filter": &"攻击"}]
	equipment_effect_092.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": -5, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_092.description = "机甲被名称带有热能的武器攻击时，可弃置1张攻击行动牌响应该攻击，使该攻击威力-5。"
	effects[equipment_effect_092.effect_id] = equipment_effect_092

	# ── 093：此牌发动的攻击命中后可额外设置2损伤。 ──
	var equipment_effect_093 := CardEffect.new()
	equipment_effect_093.effect_id = &"equipment_effect_093"
	equipment_effect_093.display_name = "命中额外2损伤"
	equipment_effect_093.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_093.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_093.priority = 100
	equipment_effect_093.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_093.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_093.costs = []
	equipment_effect_093.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"amount": 2}},
	]
	equipment_effect_093.description = "此牌发动的攻击命中后可额外设置2损伤。"
	effects[equipment_effect_093.effect_id] = equipment_effect_093

	# ── 094：可以使此牌威力-5，范围+2。 ──
	var equipment_effect_094 := CardEffect.new()
	equipment_effect_094.effect_id = &"equipment_effect_094"
	equipment_effect_094.display_name = "威力-5范围+2"
	equipment_effect_094.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_094.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_094.priority = 100
	equipment_effect_094.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_094.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_094.costs = []
	equipment_effect_094.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": -5, "duration": &"THIS_ATTACK"}},
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 2, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_094.description = "可以使此牌威力-5，范围+2。"
	effects[equipment_effect_094.effect_id] = equipment_effect_094

	# ── 095：此牌发动的攻击命中后可弃置攻击目标2张行动牌。 ──
	var equipment_effect_095 := CardEffect.new()
	equipment_effect_095.effect_id = &"equipment_effect_095"
	equipment_effect_095.display_name = "命中弃置目标2行动牌"
	equipment_effect_095.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_095.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_095.priority = 100
	equipment_effect_095.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_095.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_095.costs = []
	equipment_effect_095.actions = [
		{"type": &"DISCARD_ACTION_CARD", "params": {"from_target": true, "count": 2}},
	]
	equipment_effect_095.description = "此牌发动的攻击命中后可弃置攻击目标2张行动牌。"
	effects[equipment_effect_095.effect_id] = equipment_effect_095

	# ── 096：此牌发动的攻击产生的损伤如果全部放置于同一区域，则可以额外设置2损伤在该区域上。 ──
	var equipment_effect_096 := CardEffect.new()
	equipment_effect_096.effect_id = &"equipment_effect_096"
	equipment_effect_096.display_name = "同区域额外2损伤"
	equipment_effect_096.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_096.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_096.priority = 100
	equipment_effect_096.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"DAMAGE_TOKENS_ALL_IN_SAME_SLOT"}]
	equipment_effect_096.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_096.costs = []
	equipment_effect_096.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"amount": 2}},
	]
	equipment_effect_096.description = "此牌发动的攻击产生的损伤如果全部放置于同一区域，则可以额外设置2损伤在该区域上。"
	effects[equipment_effect_096.effect_id] = equipment_effect_096

	# ── 097：此牌发动的攻击命中后可额外设置1枚损伤。 ──
	var equipment_effect_097 := CardEffect.new()
	equipment_effect_097.effect_id = &"equipment_effect_097"
	equipment_effect_097.display_name = "命中额外1损伤"
	equipment_effect_097.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_097.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_097.priority = 100
	equipment_effect_097.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_097.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_097.costs = []
	equipment_effect_097.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"amount": 1}},
	]
	equipment_effect_097.description = "此牌发动的攻击命中后可额外设置1枚损伤。"
	effects[equipment_effect_097.effect_id] = equipment_effect_097

	# ── 098：此牌发动的攻击没有命中，则设置2损伤在此牌上。 ──
	var equipment_effect_098 := CardEffect.new()
	equipment_effect_098.effect_id = &"equipment_effect_098"
	equipment_effect_098.display_name = "未命中自损2"
	equipment_effect_098.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_098.hook = _EffectConst.HOOK_ATTACK_MISS
	equipment_effect_098.priority = 100
	equipment_effect_098.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_098.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_098.costs = []
	equipment_effect_098.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
	]
	equipment_effect_098.description = "此牌发动的攻击没有命中，则设置2损伤在此牌上。"
	effects[equipment_effect_098.effect_id] = equipment_effect_098

	# ── 099：此牌发动的攻击命中后，可对该攻击目标施加锁定效果，此效果将持续到目标下一次被攻击命中时结束，且在效果持续期间，此牌不能攻击。 ──
	var equipment_effect_099 := CardEffect.new()
	equipment_effect_099.effect_id = &"equipment_effect_099"
	equipment_effect_099.display_name = "命中锁定目标+自身不可攻击"
	equipment_effect_099.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_099.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_099.priority = 100
	equipment_effect_099.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_099.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_099.costs = []
	equipment_effect_099.actions = [
		{"type": &"APPLY_OR_CHECK_LOCKED", "params": {"apply": true, "until_hit": true}},
		{"type": &"ADD_STATUS", "params": {"status_type": &"cannot_attack", "duration": &"UNTIL_TARGET_HIT"}},
	]
	equipment_effect_099.description = "此牌发动的攻击命中后，可对该攻击目标施加锁定效果，此效果将持续到目标下一次被攻击命中时结束，且在效果持续期间，此牌不能攻击。"
	effects[equipment_effect_099.effect_id] = equipment_effect_099

	# ── 100：此牌发动的攻击命中后，在此牌上设置1损伤。 ──
	var equipment_effect_100 := CardEffect.new()
	equipment_effect_100.effect_id = &"equipment_effect_100"
	equipment_effect_100.display_name = "命中自损1"
	equipment_effect_100.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_100.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_100.priority = 100
	equipment_effect_100.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_100.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_100.costs = []
	equipment_effect_100.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
	]
	equipment_effect_100.description = "此牌发动的攻击命中后，在此牌上设置1损伤。"
	effects[equipment_effect_100.effect_id] = equipment_effect_100

	# ── 101：此牌攻击时，可以使威力+3，攻击结算后在此牌上设置1损伤。 ──
	var equipment_effect_101 := CardEffect.new()
	equipment_effect_101.effect_id = &"equipment_effect_101"
	equipment_effect_101.display_name = "威力+3结算后自损1"
	equipment_effect_101.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_101.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_101.priority = 100
	equipment_effect_101.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_101.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_101.costs = []
	equipment_effect_101.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": &"THIS_ATTACK"}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT_AFTER_RESOLVE", "params": {"amount": 1}},
	]
	equipment_effect_101.description = "此牌攻击时，可以使威力+3，攻击结算后在此牌上设置1损伤。"
	effects[equipment_effect_101.effect_id] = equipment_effect_101

	# ── 102：此牌攻击时，可以使范围+2，攻击结算后在此牌上设置1损伤。 ──
	var equipment_effect_102 := CardEffect.new()
	equipment_effect_102.effect_id = &"equipment_effect_102"
	equipment_effect_102.display_name = "范围+2结算后自损1"
	equipment_effect_102.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_102.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_102.priority = 100
	equipment_effect_102.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_102.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_102.costs = []
	equipment_effect_102.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 2, "duration": &"THIS_ATTACK"}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT_AFTER_RESOLVE", "params": {"amount": 1}},
	]
	equipment_effect_102.description = "此牌攻击时，可以使范围+2，攻击结算后在此牌上设置1损伤。"
	effects[equipment_effect_102.effect_id] = equipment_effect_102

	# ── 103：需要额外消耗2动力才能使用此牌攻击。 ──
	var equipment_effect_103 := CardEffect.new()
	equipment_effect_103.effect_id = &"equipment_effect_103"
	equipment_effect_103.display_name = "额外消耗2动力攻击"
	equipment_effect_103.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_103.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	equipment_effect_103.priority = 80
	equipment_effect_103.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_103.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_103.costs = [{"cost_type": &"SPEND_POWER", "amount": 2}]
	equipment_effect_103.actions = []
	equipment_effect_103.description = "需要额外消耗2动力才能使用此牌攻击。"
	effects[equipment_effect_103.effect_id] = equipment_effect_103

	# ── 104：此牌攻击时，可以再消耗4动力使此次攻击威力+3。 ──
	var equipment_effect_104 := CardEffect.new()
	equipment_effect_104.effect_id = &"equipment_effect_104"
	equipment_effect_104.display_name = "消耗4动力威力+3"
	equipment_effect_104.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_104.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_104.priority = 100
	equipment_effect_104.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_104.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_104.costs = [{"cost_type": &"SPEND_POWER", "amount": 4}]
	equipment_effect_104.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_104.description = "此牌攻击时，可以再消耗4动力使此次攻击威力+3。"
	effects[equipment_effect_104.effect_id] = equipment_effect_104

	# ── 105：此牌每发动过1次攻击，威力-4。 ──
	var equipment_effect_105 := CardEffect.new()
	equipment_effect_105.effect_id = &"equipment_effect_105"
	equipment_effect_105.display_name = "每攻击1次威力-4"
	equipment_effect_105.mode = _EffectConst.MODE_STATIC
	equipment_effect_105.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_105.priority = 50
	equipment_effect_105.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_105.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_105.costs = []
	equipment_effect_105.actions = [
		{"type": &"MODIFY_WEAPON_POWER_PER_ATTACK", "params": {"delta_per_attack": -4}},
	]
	equipment_effect_105.description = "此牌每发动过1次攻击，威力-4。"
	effects[equipment_effect_105.effect_id] = equipment_effect_105

	# ── 106：我方回合未使用此牌攻击则在回合结束时回复4威力。 ──
	var equipment_effect_106 := CardEffect.new()
	equipment_effect_106.effect_id = &"equipment_effect_106"
	equipment_effect_106.display_name = "未攻击回复4威力"
	equipment_effect_106.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_106.hook = _EffectConst.HOOK_TURN_END
	equipment_effect_106.priority = 100
	equipment_effect_106.conditions = [{"op": &"WEAPON_NOT_USED_THIS_TURN"}]
	equipment_effect_106.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_106.costs = []
	equipment_effect_106.actions = [
		{"type": &"RESTORE_WEAPON_POWER", "params": {"amount": 4}},
	]
	equipment_effect_106.description = "我方回合未使用此牌攻击则在回合结束时回复4威力。"
	effects[equipment_effect_106.effect_id] = equipment_effect_106

	# ── 107：对此牌使用聚能时也可回复4威力。 ──
	var equipment_effect_107 := CardEffect.new()
	equipment_effect_107.effect_id = &"equipment_effect_107"
	equipment_effect_107.display_name = "聚能回复4威力"
	equipment_effect_107.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_107.hook = _EffectConst.HOOK_ENERGY_APPLIED_TO_WEAPON
	equipment_effect_107.priority = 100
	equipment_effect_107.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_107.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_107.costs = []
	equipment_effect_107.actions = [
		{"type": &"RESTORE_WEAPON_POWER", "params": {"amount": 4}},
	]
	equipment_effect_107.description = "对此牌使用聚能时也可回复4威力。"
	effects[equipment_effect_107.effect_id] = equipment_effect_107

	# ── 108：机甲被名称带有光束的武器攻击时，可弃置1张攻击牌响应该攻击，使该攻击威力-5。 ──
	var equipment_effect_108 := CardEffect.new()
	equipment_effect_108.effect_id = &"equipment_effect_108"
	equipment_effect_108.display_name = "对光束武器威力-5"
	equipment_effect_108.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_108.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	equipment_effect_108.priority = 90
	equipment_effect_108.conditions = [
		{"op": &"SOURCE_OWNER_IS_TARGET"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"光束"},
	]
	equipment_effect_108.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_108.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "card_type_filter": &"攻击"}]
	equipment_effect_108.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": -5, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_108.description = "机甲被名称带有光束的武器攻击时，可弃置1张攻击牌响应该攻击，使该攻击威力-5。"
	effects[equipment_effect_108.effect_id] = equipment_effect_108

	# ── 109：此牌发动的攻击命中后，倘若攻击目标与机甲当前位置相邻，则可额外设置2损伤。 ──
	var equipment_effect_109 := CardEffect.new()
	equipment_effect_109.effect_id = &"equipment_effect_109"
	equipment_effect_109.display_name = "相邻目标额外2损伤"
	equipment_effect_109.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_109.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_109.priority = 100
	equipment_effect_109.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"TARGET_IS_ADJACENT_TO_SOURCE"}]
	equipment_effect_109.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_109.costs = []
	equipment_effect_109.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"amount": 2}},
	]
	equipment_effect_109.description = "此牌发动的攻击命中后，倘若攻击目标与机甲当前位置相邻，则可额外设置2损伤。"
	effects[equipment_effect_109.effect_id] = equipment_effect_109

	# ── 110：此牌发动的攻击命中后可额外设置1损伤。 ──
	var equipment_effect_110 := CardEffect.new()
	equipment_effect_110.effect_id = &"equipment_effect_110"
	equipment_effect_110.display_name = "命中额外1损伤"
	equipment_effect_110.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_110.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_110.priority = 100
	equipment_effect_110.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_110.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_110.costs = []
	equipment_effect_110.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"amount": 1}},
	]
	equipment_effect_110.description = "此牌发动的攻击命中后可额外设置1损伤。"
	effects[equipment_effect_110.effect_id] = equipment_effect_110

	# ── 111：此牌发动攻击指定目标时，可以使目标当前动力-2，之后若目标机甲动力为0，则攻击命中可额外设置2损伤。 ──
	var equipment_effect_111 := CardEffect.new()
	equipment_effect_111.effect_id = &"equipment_effect_111"
	equipment_effect_111.display_name = "指定目标动力-2+零动力额外2损伤"
	equipment_effect_111.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_111.hook = _EffectConst.HOOK_ATTACK_DECLARED
	equipment_effect_111.priority = 100
	equipment_effect_111.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_111.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_111.costs = []
	equipment_effect_111.actions = [
		{"type": &"MODIFY_TARGET_POWER", "params": {"delta": -2}},
		{"type": &"CONDITIONAL_PLACE_DAMAGE_TOKENS", "params": {"condition": &"TARGET_POWER_IS_ZERO", "amount": 2, "trigger_hook": &"ON_ATTACK_HIT"}},
	]
	equipment_effect_111.description = "此牌发动攻击指定目标时，可以使目标当前动力-2，之后若目标机甲动力为0，则攻击命中可额外设置2损伤。"
	effects[equipment_effect_111.effect_id] = equipment_effect_111

	# ── 112：此牌每设置有1损伤，则威力-2。 ──
	var equipment_effect_112 := CardEffect.new()
	equipment_effect_112.effect_id = &"equipment_effect_112"
	equipment_effect_112.display_name = "每1损伤威力-2"
	equipment_effect_112.mode = _EffectConst.MODE_STATIC
	equipment_effect_112.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_112.priority = 50
	equipment_effect_112.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_112.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_112.costs = []
	equipment_effect_112.actions = [
		{"type": &"MODIFY_WEAPON_POWER_PER_DAMAGE_TOKEN", "params": {"delta_per_token": -2}},
	]
	equipment_effect_112.description = "此牌每设置有1损伤，则威力-2。"
	effects[equipment_effect_112.effect_id] = equipment_effect_112

	# ── 113：此牌攻击时，可以在此牌上设置1损伤，回复全部威力，并使威力+2。 ──
	var equipment_effect_113 := CardEffect.new()
	equipment_effect_113.effect_id = &"equipment_effect_113"
	equipment_effect_113.display_name = "自损1回复全威力+2"
	equipment_effect_113.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_113.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_113.priority = 100
	equipment_effect_113.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_113.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_113.costs = []
	equipment_effect_113.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
		{"type": &"RESTORE_WEAPON_POWER_FULL", "params": {}},
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 2, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_113.description = "此牌攻击时，可以在此牌上设置1损伤，回复全部威力，并使威力+2。"
	effects[equipment_effect_113.effect_id] = equipment_effect_113

	# ── 114：此牌攻击命中时，可以在此牌上设置2损伤，之后可额外设置3损伤。 ──
	var equipment_effect_114 := CardEffect.new()
	equipment_effect_114.effect_id = &"equipment_effect_114"
	equipment_effect_114.display_name = "命中自损2额外3损伤"
	equipment_effect_114.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_114.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_114.priority = 100
	equipment_effect_114.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_114.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_114.costs = []
	equipment_effect_114.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"amount": 3}},
	]
	equipment_effect_114.description = "此牌攻击命中时，可以在此牌上设置2损伤，之后可额外设置3损伤。"
	effects[equipment_effect_114.effect_id] = equipment_effect_114

	# ── 115：此牌发动攻击时，随机弃置我方1张行动牌，若此即将被弃置的牌是我方的最后一张牌，则此次攻击威力+3。 ──
	var equipment_effect_115 := CardEffect.new()
	equipment_effect_115.effect_id = &"equipment_effect_115"
	equipment_effect_115.display_name = "随机弃1牌末牌威力+3"
	equipment_effect_115.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_115.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_115.priority = 100
	equipment_effect_115.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_115.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_115.costs = []
	equipment_effect_115.actions = [
		{"type": &"RANDOM_DISCARD_ACTION_CARD", "params": {"count": 1}},
		{"type": &"CONDITIONAL_MODIFY_ATTACK_POWER", "params": {"condition": &"DISCARDED_WAS_LAST_ACTION_CARD", "delta": 3, "duration": &"THIS_ATTACK"}},
	]
	equipment_effect_115.description = "此牌发动攻击时，随机弃置我方1张行动牌，若此即将被弃置的牌是我方的最后一张牌，则此次攻击威力+3。"
	effects[equipment_effect_115.effect_id] = equipment_effect_115

	# ── 116：此牌发动攻击后，直到下个我方回合结束不能再使用此牌发动攻击。 ──
	var equipment_effect_116 := CardEffect.new()
	equipment_effect_116.effect_id = &"equipment_effect_116"
	equipment_effect_116.display_name = "攻击后本牌不可攻击"
	equipment_effect_116.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_116.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	equipment_effect_116.priority = 100
	equipment_effect_116.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_116.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_116.costs = []
	equipment_effect_116.actions = [
		{"type": &"ADD_STATUS", "params": {"status_type": &"cannot_attack", "duration": &"UNTIL_NEXT_OWNER_TURN_END"}},
	]
	equipment_effect_116.description = "此牌发动攻击后，直到下个我方回合结束不能再使用此牌发动攻击。"
	effects[equipment_effect_116.effect_id] = equipment_effect_116

	# ── 117：对此牌使用聚能后允许再次发动攻击。 ──
	var equipment_effect_117 := CardEffect.new()
	equipment_effect_117.effect_id = &"equipment_effect_117"
	equipment_effect_117.display_name = "聚能后再攻击"
	equipment_effect_117.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_117.hook = _EffectConst.HOOK_ENERGY_APPLIED_TO_WEAPON
	equipment_effect_117.priority = 100
	equipment_effect_117.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_117.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_117.costs = []
	equipment_effect_117.actions = [
		{"type": &"REMOVE_STATUS", "params": {"status_type": &"cannot_attack"}},
	]
	equipment_effect_117.description = "对此牌使用聚能后允许再次发动攻击。"
	effects[equipment_effect_117.effect_id] = equipment_effect_117

	# ── 118：可以将攻击或陷阱产生的损伤移至此牌上。 ──
	var equipment_effect_118 := CardEffect.new()
	equipment_effect_118.effect_id = &"equipment_effect_118"
	equipment_effect_118.display_name = "损伤转移至此牌"
	equipment_effect_118.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_118.hook = _EffectConst.HOOK_BEFORE_DAMAGE_TOKEN_PLACED
	equipment_effect_118.priority = 90
	equipment_effect_118.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_118.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_118.costs = []
	equipment_effect_118.actions = [
		{"type": &"REDIRECT_DAMAGE_TOKENS_TO_SLOT", "params": {}},
	]
	equipment_effect_118.description = "可以将攻击或陷阱产生的损伤移至此牌上。"
	effects[equipment_effect_118.effect_id] = equipment_effect_118

	# ── 119：此牌发动攻击结算后会被设置1损伤。 ──
	var equipment_effect_119 := CardEffect.new()
	equipment_effect_119.effect_id = &"equipment_effect_119"
	equipment_effect_119.display_name = "攻击结算后自损1"
	equipment_effect_119.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_119.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	equipment_effect_119.priority = 100
	equipment_effect_119.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_119.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_119.costs = []
	equipment_effect_119.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
	]
	equipment_effect_119.description = "此牌发动攻击结算后会被设置1损伤。"
	effects[equipment_effect_119.effect_id] = equipment_effect_119

	# ── 120：可直接使用此牌发动攻击(不需要攻击牌)。 ──
	var equipment_effect_120 := CardEffect.new()
	equipment_effect_120.effect_id = &"equipment_effect_120"
	equipment_effect_120.display_name = "无需攻击牌直接攻击"
	equipment_effect_120.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_120.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_120.priority = 100
	equipment_effect_120.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_120.target_rules = [{"rule": &"CHOOSE_ENEMY_MECH_IN_RANGE"}]
	equipment_effect_120.costs = []
	equipment_effect_120.actions = [
		{"type": &"START_ATTACK_DECLARE_ATTACK", "params": {"no_attack_card_needed": true}},
	]
	equipment_effect_120.description = "可直接使用此牌发动攻击(不需要攻击牌)。"
	effects[equipment_effect_120.effect_id] = equipment_effect_120

	# ── 121：每我方回合1次，可以将1张行动牌当作维修打出，之后在此牌上设置2损伤。 ──
	var equipment_effect_121 := CardEffect.new()
	equipment_effect_121.effect_id = &"equipment_effect_121"
	equipment_effect_121.display_name = "行动牌当维修+自损2"
	equipment_effect_121.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_121.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_121.priority = 100
	equipment_effect_121.once_per_turn_key = &"equipment_effect_121"
	equipment_effect_121.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_121.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_121.costs = []
	equipment_effect_121.actions = [
		{"type": &"PLAY_ACTION_AS_REPAIR", "params": {}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
	]
	equipment_effect_121.description = "每我方回合1次，可以将1张行动牌当作维修打出，之后在此牌上设置2损伤。"
	effects[equipment_effect_121.effect_id] = equipment_effect_121

	# ── 122：我方回合或打出迎击牌时，可以使机甲在本回合动力+4，之后在此牌上设置1损伤。 ──
	var equipment_effect_122 := CardEffect.new()
	equipment_effect_122.effect_id = &"equipment_effect_122"
	equipment_effect_122.display_name = "动力+4自损1"
	equipment_effect_122.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_122.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_122.priority = 100
	equipment_effect_122.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_122.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_122.costs = []
	equipment_effect_122.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 4, "duration": &"THIS_TURN"}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
	]
	equipment_effect_122.description = "我方回合或打出迎击牌时，可以使机甲在本回合动力+4，之后在此牌上设置1损伤。"
	effects[equipment_effect_122.effect_id] = equipment_effect_122

	# ── 123：以上效果每回合只能使用1次。 ──
	var equipment_effect_123 := CardEffect.new()
	equipment_effect_123.effect_id = &"equipment_effect_123"
	equipment_effect_123.display_name = "每回合1次限制"
	equipment_effect_123.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_123.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	equipment_effect_123.priority = 100
	equipment_effect_123.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_123.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_123.costs = []
	equipment_effect_123.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 4, "duration": &"THIS_TURN"}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
	]
	equipment_effect_123.once_per_turn_key = &"equipment_effect_122"
	equipment_effect_123.description = "以上效果每回合只能使用1次。"
	effects[equipment_effect_123.effect_id] = equipment_effect_123

	# ── 124：可以在此牌攻击范围内的格子上设置1陷阱，之后在此牌上设置1损伤。 ──
	var equipment_effect_124 := CardEffect.new()
	equipment_effect_124.effect_id = &"equipment_effect_124"
	equipment_effect_124.display_name = "设置陷阱+自损1"
	equipment_effect_124.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_124.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_124.priority = 100
	equipment_effect_124.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_124.target_rules = [{"rule": &"CHOOSE_MAP_CELL_IN_WEAPON_RANGE"}]
	equipment_effect_124.costs = []
	equipment_effect_124.actions = [
		{"type": &"PLACE_TRAP_MARKER", "params": {}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
	]
	equipment_effect_124.description = "可以在此牌攻击范围内的格子上设置1陷阱，之后在此牌上设置1损伤。"
	effects[equipment_effect_124.effect_id] = equipment_effect_124

	# ── 125：每我方回合1次，可以将1张行动牌当作维修打出或是弃置2张行动牌再抽2张行动牌，之后在此牌上设置2损伤。 ──
	var equipment_effect_125 := CardEffect.new()
	equipment_effect_125.effect_id = &"equipment_effect_125"
	equipment_effect_125.display_name = "维修或弃2抽2+自损2"
	equipment_effect_125.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_125.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_125.priority = 100
	equipment_effect_125.once_per_turn_key = &"equipment_effect_125"
	equipment_effect_125.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_125.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_125.costs = []
	equipment_effect_125.actions = [
		{"type": &"CHOICE", "params": {"options": [
			{"type": &"PLAY_ACTION_AS_REPAIR", "params": {}},
			{"type": &"DISCARD_AND_DRAW_ACTION", "params": {"discard_count": 2, "draw_count": 2}},
		]}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
	]
	equipment_effect_125.description = "每我方回合1次，可以将1张行动牌当作维修打出或是弃置2张行动牌再抽2张行动牌，之后在此牌上设置2损伤。"
	effects[equipment_effect_125.effect_id] = equipment_effect_125

	# ── 126：此牌攻击结算后会被设置1损伤。 ──
	var equipment_effect_126 := CardEffect.new()
	equipment_effect_126.effect_id = &"equipment_effect_126"
	equipment_effect_126.display_name = "攻击结算后自损1"
	equipment_effect_126.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_126.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	equipment_effect_126.priority = 100
	equipment_effect_126.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_126.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_126.costs = []
	equipment_effect_126.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
	]
	equipment_effect_126.description = "此牌攻击结算后会被设置1损伤。"
	effects[equipment_effect_126.effect_id] = equipment_effect_126

	# ── 127：可以在此牌范围内的2个格子上各设置1陷阱，之后在此牌上设置1损伤。 ──
	var equipment_effect_127 := CardEffect.new()
	equipment_effect_127.effect_id = &"equipment_effect_127"
	equipment_effect_127.display_name = "设置2陷阱+自损1"
	equipment_effect_127.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_127.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_127.priority = 100
	equipment_effect_127.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_127.target_rules = [{"rule": &"CHOOSE_MAP_CELL_IN_WEAPON_RANGE"}]
	equipment_effect_127.costs = []
	equipment_effect_127.actions = [
		{"type": &"PLACE_TRAP_MARKER", "params": {"count": 2}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 1}},
	]
	equipment_effect_127.description = "可以在此牌范围内的2个格子上各设置1陷阱，之后在此牌上设置1损伤。"
	effects[equipment_effect_127.effect_id] = equipment_effect_127

	# ── 128：可以将此牌的威力变为机甲当前护甲数值*2，范围变为当前动力数值。 ──
	var equipment_effect_128 := CardEffect.new()
	equipment_effect_128.effect_id = &"equipment_effect_128"
	equipment_effect_128.display_name = "威力=护甲*2范围=动力"
	equipment_effect_128.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_128.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_128.priority = 100
	equipment_effect_128.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_128.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_128.costs = []
	equipment_effect_128.actions = [
		{"type": &"SET_WEAPON_STATS_FROM_MECH", "params": {"might_formula": &"armor_times_2", "range_formula": &"current_power"}},
	]
	equipment_effect_128.description = "可以将此牌的威力变为机甲当前护甲数值*2，范围变为当前动力数值。"
	effects[equipment_effect_128.effect_id] = equipment_effect_128

	# ── 129：此牌发动攻击结算完成后，弃置机甲所有正面朝上的部件装备牌。 ──
	var equipment_effect_129 := CardEffect.new()
	equipment_effect_129.effect_id = &"equipment_effect_129"
	equipment_effect_129.display_name = "攻击后弃置所有部件"
	equipment_effect_129.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_129.hook = _EffectConst.HOOK_ATTACK_RESOLVED
	equipment_effect_129.priority = 100
	equipment_effect_129.conditions = [{"op": &"ATTACK_SOURCE_IS_SELF"}]
	equipment_effect_129.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_129.costs = []
	equipment_effect_129.actions = [
		{"type": &"DISCARD_ALL_FACE_UP_PART_EQUIPMENT", "params": {}},
	]
	equipment_effect_129.description = "此牌发动攻击结算完成后，弃置机甲所有正面朝上的部件装备牌。"
	effects[equipment_effect_129.effect_id] = equipment_effect_129


# ═══════════════════════════════════════════
	# 批次8：装备效果（R/SR稀有度零件 024-084）
	# ═══════════════════════════════════════════

	# ── 024：每我方回合1次，可以弃置1张行动牌，回复1动力。 ──
	var equipment_effect_024 := CardEffect.new()
	equipment_effect_024.effect_id = &"equipment_effect_024"
	equipment_effect_024.display_name = "弃1行动牌回复1动力"
	equipment_effect_024.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_024.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_024.priority = 100
	equipment_effect_024.once_per_turn_key = &"equipment_effect_024"
	equipment_effect_024.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_024.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_024.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_024.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	]
	equipment_effect_024.description = "每我方回合1次，可以弃置1张行动牌，回复1动力。"
	effects[equipment_effect_024.effect_id] = equipment_effect_024

	# ── 025：使用远程武器发动攻击时，可以弃置1张行动牌，使威力+2。 ──
	var equipment_effect_025 := CardEffect.new()
	equipment_effect_025.effect_id = &"equipment_effect_025"
	equipment_effect_025.display_name = "远程武器弃1牌威力+2"
	equipment_effect_025.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_025.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_025.priority = 90
	equipment_effect_025.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	equipment_effect_025.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_025.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_025.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 2, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_025.description = "使用远程武器发动攻击时，可以弃置1张行动牌，使威力+2。"
	effects[equipment_effect_025.effect_id] = equipment_effect_025

	# ── 026：打出攻击牌时，可立即移动到相邻的1个格子上。 ──
	var equipment_effect_026 := CardEffect.new()
	equipment_effect_026.effect_id = &"equipment_effect_026"
	equipment_effect_026.display_name = "打出攻击牌移动1格"
	equipment_effect_026.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_026.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	equipment_effect_026.priority = 100
	equipment_effect_026.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	equipment_effect_026.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_026.costs = []
	equipment_effect_026.actions = [
		{"type": &"MOVE_MECH", "params": {"cells": 1, "adjacent": true}},
	]
	equipment_effect_026.description = "打出攻击牌时，可立即移动到相邻的1个格子上。"
	effects[equipment_effect_026.effect_id] = equipment_effect_026

	# ── 027：打出迎击牌时，可立即移动到相邻的1个格子上。 ──
	var equipment_effect_027 := CardEffect.new()
	equipment_effect_027.effect_id = &"equipment_effect_027"
	equipment_effect_027.display_name = "打出迎击牌移动1格"
	equipment_effect_027.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_027.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	equipment_effect_027.priority = 100
	equipment_effect_027.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_027.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_027.costs = []
	equipment_effect_027.actions = [
		{"type": &"MOVE_MECH", "params": {"cells": 1, "adjacent": true}},
	]
	equipment_effect_027.description = "打出迎击牌时，可立即移动到相邻的1个格子上。"
	effects[equipment_effect_027.effect_id] = equipment_effect_027

	# ── 028：可以将发动攻击武器的范围-2(不会低于1)，然后威力+3，类型变为近战武器(以上效果不适用于近战武器)。 ──
	var equipment_effect_028 := CardEffect.new()
	equipment_effect_028.effect_id = &"equipment_effect_028"
	equipment_effect_028.display_name = "范围-2威力+3变近战"
	equipment_effect_028.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_028.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_028.priority = 90
	equipment_effect_028.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	equipment_effect_028.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_028.costs = []
	equipment_effect_028.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "min": 1, "duration": "THIS_ATTACK"}},
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
		{"type": &"CHANGE_WEAPON_KIND", "params": {"weapon_kind": &"近战", "duration": "THIS_ATTACK"}},
	]
	equipment_effect_028.description = "可以将发动攻击武器的范围-2(不会低于1)，然后威力+3，类型变为近战武器(以上效果不适用于近战武器)。"
	effects[equipment_effect_028.effect_id] = equipment_effect_028

	# ── 029：打出迎击牌时，当前回合护甲+2。 ──
	var equipment_effect_029 := CardEffect.new()
	equipment_effect_029.effect_id = &"equipment_effect_029"
	equipment_effect_029.display_name = "打出迎击牌护甲+2"
	equipment_effect_029.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_029.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	equipment_effect_029.priority = 100
	equipment_effect_029.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_029.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_029.costs = []
	equipment_effect_029.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 2, "duration": "THIS_TURN"}},
	]
	equipment_effect_029.description = "打出迎击牌时，当前回合护甲+2。"
	effects[equipment_effect_029.effect_id] = equipment_effect_029

	# ── 030：使用近战武器发动攻击时，可以弃置1张行动牌，使威力+2。 ──
	var equipment_effect_030 := CardEffect.new()
	equipment_effect_030.effect_id = &"equipment_effect_030"
	equipment_effect_030.display_name = "近战武器弃1牌威力+2"
	equipment_effect_030.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_030.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_030.priority = 90
	equipment_effect_030.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
	]
	equipment_effect_030.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_030.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_030.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 2, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_030.description = "使用近战武器发动攻击时，可以弃置1张行动牌，使威力+2。"
	effects[equipment_effect_030.effect_id] = equipment_effect_030

	# ── 031：此牌因损伤而从区域中弃置时可移除机甲其他区域内最多2损伤。 ──
	var equipment_effect_031 := CardEffect.new()
	equipment_effect_031.effect_id = &"equipment_effect_031"
	equipment_effect_031.display_name = "因损伤弃置移除2损伤"
	equipment_effect_031.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_031.hook = _EffectConst.HOOK_EQUIPMENT_BROKEN_BY_DAMAGE
	equipment_effect_031.priority = 100
	equipment_effect_031.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_031.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_031.costs = []
	equipment_effect_031.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount": 2, "from_other_slots": true}},
	]
	equipment_effect_031.description = "此牌因损伤而从区域中弃置时可移除机甲其他区域内最多2损伤。"
	effects[equipment_effect_031.effect_id] = equipment_effect_031

	# ── 032：此牌设置到区域中时可以抽1张行动牌。 ──
	var equipment_effect_032 := CardEffect.new()
	equipment_effect_032.effect_id = &"equipment_effect_032"
	equipment_effect_032.display_name = "设置时抽1行动牌"
	equipment_effect_032.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_032.hook = _EffectConst.HOOK_EQUIPMENT_SET
	equipment_effect_032.priority = 100
	equipment_effect_032.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_032.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_032.costs = []
	equipment_effect_032.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	equipment_effect_032.description = "此牌设置到区域中时可以抽1张行动牌。"
	effects[equipment_effect_032.effect_id] = equipment_effect_032

	# ── 033：此牌因损伤而从区域中弃置时可以抽2张行动牌。 ──
	var equipment_effect_033 := CardEffect.new()
	equipment_effect_033.effect_id = &"equipment_effect_033"
	equipment_effect_033.display_name = "因损伤弃置抽2行动牌"
	equipment_effect_033.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_033.hook = _EffectConst.HOOK_EQUIPMENT_BROKEN_BY_DAMAGE
	equipment_effect_033.priority = 100
	equipment_effect_033.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_033.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_033.costs = []
	equipment_effect_033.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
	]
	equipment_effect_033.description = "此牌因损伤而从区域中弃置时可以抽2张行动牌。"
	effects[equipment_effect_033.effect_id] = equipment_effect_033

	# ── 034：打出迎击牌响应攻击时，可以使该攻击威力-5，之后设置2损伤在此牌上。 ──
	var equipment_effect_034 := CardEffect.new()
	equipment_effect_034.effect_id = &"equipment_effect_034"
	equipment_effect_034.display_name = "迎击威力-5自损2"
	equipment_effect_034.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_034.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	equipment_effect_034.priority = 90
	equipment_effect_034.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_034.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_034.costs = []
	equipment_effect_034.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": -5, "duration": "THIS_ATTACK"}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
	]
	equipment_effect_034.description = "打出迎击牌响应攻击时，可以使该攻击威力-5，之后设置2损伤在此牌上。"
	effects[equipment_effect_034.effect_id] = equipment_effect_034

	# ── 035：使用名称带有光束的近战武器攻击时，威力+3。 ──
	var equipment_effect_035 := CardEffect.new()
	equipment_effect_035.effect_id = &"equipment_effect_035"
	equipment_effect_035.display_name = "光束近战武器威力+3"
	equipment_effect_035.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_035.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_035.priority = 90
	equipment_effect_035.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"光束"},
	]
	equipment_effect_035.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_035.costs = []
	equipment_effect_035.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_035.description = "使用名称带有光束的近战武器攻击时，威力+3。"
	effects[equipment_effect_035.effect_id] = equipment_effect_035

	# ── 036：使用名称带有光束的远程武器攻击时，威力+3。 ──
	var equipment_effect_036 := CardEffect.new()
	equipment_effect_036.effect_id = &"equipment_effect_036"
	equipment_effect_036.display_name = "光束远程武器威力+3"
	equipment_effect_036.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_036.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_036.priority = 90
	equipment_effect_036.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"光束"},
	]
	equipment_effect_036.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_036.costs = []
	equipment_effect_036.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_036.description = "使用名称带有光束的远程武器攻击时，威力+3。"
	effects[equipment_effect_036.effect_id] = equipment_effect_036

	# ── 037：机甲被指定为攻击目标时，可在当前回合动力+3。 ──
	var equipment_effect_037 := CardEffect.new()
	equipment_effect_037.effect_id = &"equipment_effect_037"
	equipment_effect_037.display_name = "被攻击时动力+3"
	equipment_effect_037.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_037.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_037.priority = 100
	equipment_effect_037.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_037.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_037.costs = []
	equipment_effect_037.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 3, "duration": &"THIS_TURN"}},
	]
	equipment_effect_037.description = "机甲被指定为攻击目标时，可在当前回合动力+3。"
	effects[equipment_effect_037.effect_id] = equipment_effect_037

	# ── 038：机甲被攻击命中时，可以设置2损伤在此牌上，之后可最多减少此次攻击产生的3损伤。 ──
	var equipment_effect_038 := CardEffect.new()
	equipment_effect_038.effect_id = &"equipment_effect_038"
	equipment_effect_038.display_name = "被命中自损2减3损伤"
	equipment_effect_038.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_038.hook = _EffectConst.HOOK_MECH_HIT_BY_ATTACK
	equipment_effect_038.priority = 90
	equipment_effect_038.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_038.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_038.costs = []
	equipment_effect_038.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": -3}},
	]
	equipment_effect_038.description = "机甲被攻击命中时，可以设置2损伤在此牌上，之后可最多减少此次攻击产生的3损伤。"
	effects[equipment_effect_038.effect_id] = equipment_effect_038

	# ── 039：每回合1次，可以消耗2*n数量的金币(n为整数)，当前回合动力+n，此效果可以在打出迎击牌时使用。 ──
	var equipment_effect_039 := CardEffect.new()
	equipment_effect_039.effect_id = &"equipment_effect_039"
	equipment_effect_039.display_name = "消耗金币动力+n"
	equipment_effect_039.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_039.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_039.priority = 100
	equipment_effect_039.once_per_turn_key = &"equipment_effect_039"
	equipment_effect_039.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_039.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_039.costs = [{"cost_type": &"SPEND_GOLD_VARIABLE", "formula": &"2*n"}]
	equipment_effect_039.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta_formula": &"n", "duration": &"THIS_TURN"}},
	]
	equipment_effect_039.description = "每回合1次，可以消耗2*n数量的金币(n为整数)，当前回合动力+n，此效果可以在打出迎击牌时使用。"
	effects[equipment_effect_039.effect_id] = equipment_effect_039

	# ── 039b：消耗金币动力+n（迎击牌触发） ──
	var equipment_effect_039b := CardEffect.new()
	equipment_effect_039b.effect_id = &"equipment_effect_039b"
	equipment_effect_039b.display_name = "消耗金币动力+n(迎击)"
	equipment_effect_039b.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_039b.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	equipment_effect_039b.priority = 100
	equipment_effect_039b.once_per_turn_key = &"equipment_effect_039"
	equipment_effect_039b.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_039b.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_039b.costs = [{"cost_type": &"SPEND_GOLD_VARIABLE", "formula": &"2*n"}]
	equipment_effect_039b.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta_formula": &"n", "duration": &"THIS_TURN"}},
	]
	equipment_effect_039b.description = "每回合1次，可以消耗2*n数量的金币(n为整数)，当前回合动力+n，此效果可以在打出迎击牌时使用。"
	effects[equipment_effect_039b.effect_id] = equipment_effect_039b

	# ── 040：使用名称带有热能的远程武器攻击时，威力+3。 ──
	var equipment_effect_040 := CardEffect.new()
	equipment_effect_040.effect_id = &"equipment_effect_040"
	equipment_effect_040.display_name = "热能远程武器威力+3"
	equipment_effect_040.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_040.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_040.priority = 90
	equipment_effect_040.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"热能"},
	]
	equipment_effect_040.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_040.costs = []
	equipment_effect_040.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_040.description = "使用名称带有热能的远程武器攻击时，威力+3。"
	effects[equipment_effect_040.effect_id] = equipment_effect_040

	# ── 041：使用名称带有热能的近战武器攻击时，威力+3。 ──
	var equipment_effect_041 := CardEffect.new()
	equipment_effect_041.effect_id = &"equipment_effect_041"
	equipment_effect_041.display_name = "热能近战武器威力+3"
	equipment_effect_041.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_041.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_041.priority = 90
	equipment_effect_041.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"热能"},
	]
	equipment_effect_041.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_041.costs = []
	equipment_effect_041.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_041.description = "使用名称带有热能的近战武器攻击时，威力+3。"
	effects[equipment_effect_041.effect_id] = equipment_effect_041

	# ── 042：每回合1次，机甲在当前回合内消耗了8动力，可回复2动力。 ──
	var equipment_effect_042 := CardEffect.new()
	equipment_effect_042.effect_id = &"equipment_effect_042"
	equipment_effect_042.display_name = "耗8动力回复2动力"
	equipment_effect_042.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_042.hook = _EffectConst.HOOK_TURN_END
	equipment_effect_042.priority = 100
	equipment_effect_042.conditions = [{"op": &"POWER_SPENT_THIS_TURN_ABOVE", "threshold": 8}]
	equipment_effect_042.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_042.costs = []
	equipment_effect_042.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	]
	equipment_effect_042.once_per_turn_key = &"equipment_effect_042"
	equipment_effect_042.description = "每回合1次，机甲在当前回合内消耗了8动力，可回复2动力。"
	effects[equipment_effect_042.effect_id] = equipment_effect_042

	# ── 043：每回合1次，机甲在当前回合内消耗了8动力，可回复1动力。 ──
	var equipment_effect_043 := CardEffect.new()
	equipment_effect_043.effect_id = &"equipment_effect_043"
	equipment_effect_043.display_name = "耗8动力回复1动力"
	equipment_effect_043.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_043.hook = _EffectConst.HOOK_TURN_END
	equipment_effect_043.priority = 100
	equipment_effect_043.conditions = [{"op": &"POWER_SPENT_THIS_TURN_ABOVE", "threshold": 8}]
	equipment_effect_043.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_043.costs = []
	equipment_effect_043.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	]
	equipment_effect_043.once_per_turn_key = &"equipment_effect_043"
	equipment_effect_043.description = "每回合1次，机甲在当前回合内消耗了8动力，可回复1动力。"
	effects[equipment_effect_043.effect_id] = equipment_effect_043

	# ── 044：损伤不会影响此牌所在区域提供的护甲，除非此牌上设置的损伤≥2。 ──
	var equipment_effect_044 := CardEffect.new()
	equipment_effect_044.effect_id = &"equipment_effect_044"
	equipment_effect_044.display_name = "损伤不影响护甲(除非≥2)"
	equipment_effect_044.mode = _EffectConst.MODE_STATIC
	equipment_effect_044.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_044.priority = 50
	equipment_effect_044.conditions = [{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 2, "inverted": true}]
	equipment_effect_044.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_044.costs = []
	equipment_effect_044.actions = [
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"ignore_damage_token_armor_penalty", "duration": &"PERMANENT"}},
	]
	equipment_effect_044.description = "损伤不会影响此牌所在区域提供的护甲，除非此牌上设置的损伤≥2。"
	effects[equipment_effect_044.effect_id] = equipment_effect_044

	# ── 045：机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合护甲+5。 ──
	var equipment_effect_045 := CardEffect.new()
	equipment_effect_045.effect_id = &"equipment_effect_045"
	equipment_effect_045.display_name = "被攻击弃2牌护甲+5"
	equipment_effect_045.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_045.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_045.priority = 100
	equipment_effect_045.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_045.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_045.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 2}]
	equipment_effect_045.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 5, "duration": &"THIS_TURN"}},
	]
	equipment_effect_045.description = "机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合护甲+5。"
	effects[equipment_effect_045.effect_id] = equipment_effect_045

	# ── 046：此牌上设置有损伤≥2时，动力+2。 ──
	var equipment_effect_046 := CardEffect.new()
	equipment_effect_046.effect_id = &"equipment_effect_046"
	equipment_effect_046.display_name = "损伤≥2时动力+2"
	equipment_effect_046.mode = _EffectConst.MODE_STATIC
	equipment_effect_046.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_046.priority = 55
	equipment_effect_046.conditions = [{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 2}]
	equipment_effect_046.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_046.costs = []
	equipment_effect_046.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": "PERMANENT"}},
	]
	equipment_effect_046.description = "此牌上设置有损伤≥2时，动力+2。"
	effects[equipment_effect_046.effect_id] = equipment_effect_046

	# ── 047：每我方回合2次，可以消耗4动力抽1张行动牌。 ──
	var equipment_effect_047 := CardEffect.new()
	equipment_effect_047.effect_id = &"equipment_effect_047"
	equipment_effect_047.display_name = "消耗4动力抽1行动牌(2次)"
	equipment_effect_047.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_047.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_047.priority = 100
	equipment_effect_047.once_per_turn_key = &"equipment_effect_047"
	equipment_effect_047.once_per_turn_max = 2
	equipment_effect_047.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_047.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_047.costs = [{"cost_type": &"SPEND_POWER", "amount": 4}]
	equipment_effect_047.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	]
	equipment_effect_047.description = "每我方回合2次，可以消耗4动力抽1张行动牌。"
	effects[equipment_effect_047.effect_id] = equipment_effect_047

	# ── 048：机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合动力+6。 ──
	var equipment_effect_048 := CardEffect.new()
	equipment_effect_048.effect_id = &"equipment_effect_048"
	equipment_effect_048.display_name = "被攻击弃2牌动力+6"
	equipment_effect_048.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_048.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_048.priority = 100
	equipment_effect_048.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_048.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_048.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 2}]
	equipment_effect_048.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 6, "duration": &"THIS_TURN"}},
	]
	equipment_effect_048.description = "机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合动力+6。"
	effects[equipment_effect_048.effect_id] = equipment_effect_048

	# ── 049：我方回合，可以将区域内的此牌弃置，之后移除机甲区域上原先设置于此牌上损伤数量的损伤。 ──
	var equipment_effect_049 := CardEffect.new()
	equipment_effect_049.effect_id = &"equipment_effect_049"
	equipment_effect_049.display_name = "主动弃置移除等量损伤"
	equipment_effect_049.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_049.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_049.priority = 100
	equipment_effect_049.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_049.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_049.costs = [{"cost_type": &"DISCARD_EQUIPMENT_CARD", "count": 1}]
	equipment_effect_049.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount_formula": &"source_card_damage_tokens", "from_other_slots": true}},
	]
	equipment_effect_049.description = "我方回合，可以将区域内的此牌弃置，之后移除机甲区域上原先设置于此牌上损伤数量的损伤。"
	effects[equipment_effect_049.effect_id] = equipment_effect_049

	# ── 050：机甲发动的攻击命中后，回复4动力。 ──
	var equipment_effect_050 := CardEffect.new()
	equipment_effect_050.effect_id = &"equipment_effect_050"
	equipment_effect_050.display_name = "攻击命中后回复4动力"
	equipment_effect_050.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_050.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_050.priority = 100
	equipment_effect_050.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_050.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_050.costs = []
	equipment_effect_050.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 4}},
	]
	equipment_effect_050.description = "机甲发动的攻击命中后，回复4动力。"
	effects[equipment_effect_050.effect_id] = equipment_effect_050

	# ── 051：此牌上设置的损伤≥2时，动力+2。 ──
	var equipment_effect_051 := CardEffect.new()
	equipment_effect_051.effect_id = &"equipment_effect_051"
	equipment_effect_051.display_name = "损伤≥2时动力+2"
	equipment_effect_051.mode = _EffectConst.MODE_STATIC
	equipment_effect_051.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_051.priority = 55
	equipment_effect_051.conditions = [{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 2}]
	equipment_effect_051.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_051.costs = []
	equipment_effect_051.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": "PERMANENT"}},
	]
	equipment_effect_051.description = "此牌上设置的损伤≥2时，动力+2。"
	effects[equipment_effect_051.effect_id] = equipment_effect_051

	# ── 052：此牌上设置的损伤≥3时，动力+2。 ──
	var equipment_effect_052 := CardEffect.new()
	equipment_effect_052.effect_id = &"equipment_effect_052"
	equipment_effect_052.display_name = "损伤≥3时动力+2"
	equipment_effect_052.mode = _EffectConst.MODE_STATIC
	equipment_effect_052.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_052.priority = 55
	equipment_effect_052.conditions = [{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 3}]
	equipment_effect_052.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_052.costs = []
	equipment_effect_052.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": "PERMANENT"}},
	]
	equipment_effect_052.description = "此牌上设置的损伤≥3时，动力+2。"
	effects[equipment_effect_052.effect_id] = equipment_effect_052

	# ── 053：使用远程武器发动攻击时，攻击范围+2。 ──
	var equipment_effect_053 := CardEffect.new()
	equipment_effect_053.effect_id = &"equipment_effect_053"
	equipment_effect_053.display_name = "远程武器攻击范围+2"
	equipment_effect_053.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_053.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_053.priority = 90
	equipment_effect_053.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	equipment_effect_053.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_053.costs = []
	equipment_effect_053.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 2, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_053.description = "使用远程武器发动攻击时，攻击范围+2。"
	effects[equipment_effect_053.effect_id] = equipment_effect_053

	# ── 054：此牌从区域中弃置时可获得2金币。 ──
	var equipment_effect_054 := CardEffect.new()
	equipment_effect_054.effect_id = &"equipment_effect_054"
	equipment_effect_054.display_name = "弃置获得2金币"
	equipment_effect_054.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_054.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	equipment_effect_054.priority = 100
	equipment_effect_054.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_054.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_054.costs = []
	equipment_effect_054.actions = [
		{"type": &"GAIN_GOLD", "params": {"amount": 2}},
	]
	equipment_effect_054.description = "此牌从区域中弃置时可获得2金币。"
	effects[equipment_effect_054.effect_id] = equipment_effect_054

	# ── 055：每我方回合1次，可以弃置1张行动牌，回复2动力。 ──
	var equipment_effect_055 := CardEffect.new()
	equipment_effect_055.effect_id = &"equipment_effect_055"
	equipment_effect_055.display_name = "弃1行动牌回复2动力"
	equipment_effect_055.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_055.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_055.priority = 100
	equipment_effect_055.once_per_turn_key = &"equipment_effect_055"
	equipment_effect_055.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_055.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_055.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_055.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	]
	equipment_effect_055.description = "每我方回合1次，可以弃置1张行动牌，回复2动力。"
	effects[equipment_effect_055.effect_id] = equipment_effect_055

	# ── 056：使用远程武器发动攻击时，可以弃置1张行动牌，使威力+3。 ──
	var equipment_effect_056 := CardEffect.new()
	equipment_effect_056.effect_id = &"equipment_effect_056"
	equipment_effect_056.display_name = "远程武器弃1牌威力+3"
	equipment_effect_056.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_056.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_056.priority = 90
	equipment_effect_056.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	equipment_effect_056.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_056.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_056.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_056.description = "使用远程武器发动攻击时，可以弃置1张行动牌，使威力+3。"
	effects[equipment_effect_056.effect_id] = equipment_effect_056

	# ── 057：打出攻击牌时，可立即移动到相邻的1个格子上，之后回复1动力。 ──
	var equipment_effect_057 := CardEffect.new()
	equipment_effect_057.effect_id = &"equipment_effect_057"
	equipment_effect_057.display_name = "打出攻击牌移动1格回复1动力"
	equipment_effect_057.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_057.hook = _EffectConst.HOOK_ATTACK_CARD_PLAYED
	equipment_effect_057.priority = 100
	equipment_effect_057.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	equipment_effect_057.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_057.costs = []
	equipment_effect_057.actions = [
		{"type": &"MOVE_MECH", "params": {"cells": 1, "adjacent": true}},
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	]
	equipment_effect_057.description = "打出攻击牌时，可立即移动到相邻的1个格子上，之后回复1动力。"
	effects[equipment_effect_057.effect_id] = equipment_effect_057

	# ── 058：打出迎击牌时，本回合动力可立即+2，之后移动到相邻的1个格子上。 ──
	var equipment_effect_058 := CardEffect.new()
	equipment_effect_058.effect_id = &"equipment_effect_058"
	equipment_effect_058.display_name = "打出迎击牌动力+2移动1格"
	equipment_effect_058.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_058.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	equipment_effect_058.priority = 100
	equipment_effect_058.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_058.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_058.costs = []
	equipment_effect_058.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": &"THIS_TURN"}},
		{"type": &"MOVE_MECH", "params": {"cells": 1, "adjacent": true}},
	]
	equipment_effect_058.description = "打出迎击牌时，本回合动力可立即+2，之后移动到相邻的1个格子上。"
	effects[equipment_effect_058.effect_id] = equipment_effect_058

	# ── 059：可以将发动攻击武器的范围-2(不会低于1)，然后威力+4，类型变为近战武器(以上效果不适用于近战武器)。 ──
	var equipment_effect_059 := CardEffect.new()
	equipment_effect_059.effect_id = &"equipment_effect_059"
	equipment_effect_059.display_name = "范围-2威力+4变近战"
	equipment_effect_059.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_059.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_059.priority = 90
	equipment_effect_059.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	equipment_effect_059.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_059.costs = []
	equipment_effect_059.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "min": 1, "duration": "THIS_ATTACK"}},
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 4, "duration": "THIS_ATTACK"}},
		{"type": &"CHANGE_WEAPON_KIND", "params": {"weapon_kind": &"近战", "duration": "THIS_ATTACK"}},
	]
	equipment_effect_059.description = "可以将发动攻击武器的范围-2(不会低于1)，然后威力+4，类型变为近战武器(以上效果不适用于近战武器)。"
	effects[equipment_effect_059.effect_id] = equipment_effect_059

	# ── 060：打出迎击牌时，当前回合护甲+2，动力+2。 ──
	var equipment_effect_060 := CardEffect.new()
	equipment_effect_060.effect_id = &"equipment_effect_060"
	equipment_effect_060.display_name = "打出迎击牌护甲+2动力+2"
	equipment_effect_060.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_060.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	equipment_effect_060.priority = 100
	equipment_effect_060.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_060.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_060.costs = []
	equipment_effect_060.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 2, "duration": "THIS_TURN"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": &"THIS_TURN"}},
	]
	equipment_effect_060.description = "打出迎击牌时，当前回合护甲+2，动力+2。"
	effects[equipment_effect_060.effect_id] = equipment_effect_060

	# ── 061：使用近战武器发动攻击时，可以弃置1张行动牌，使威力+2，之后可以选择攻击目标区域最多1张牌效果无效直到本回合结束。 ──
	var equipment_effect_061 := CardEffect.new()
	equipment_effect_061.effect_id = &"equipment_effect_061"
	equipment_effect_061.display_name = "近战弃1牌威力+2+无效1牌"
	equipment_effect_061.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_061.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_061.priority = 90
	equipment_effect_061.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
	]
	equipment_effect_061.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_061.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_061.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 2, "duration": "THIS_ATTACK"}},
		{"type": &"DISABLE_TARGET_SLOT_EFFECT", "params": {"max_cards": 1, "duration": &"THIS_TURN"}},
	]
	equipment_effect_061.description = "使用近战武器发动攻击时，可以弃置1张行动牌，使威力+2，之后可以选择攻击目标区域最多1张牌效果无效直到本回合结束。"
	effects[equipment_effect_061.effect_id] = equipment_effect_061

	# ── 062：此牌从区域中弃置时可使机甲回复3动力，之后可以用当前所有动力进行移动。 ──
	var equipment_effect_062 := CardEffect.new()
	equipment_effect_062.effect_id = &"equipment_effect_062"
	equipment_effect_062.display_name = "弃置回复3动力+移动"
	equipment_effect_062.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_062.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	equipment_effect_062.priority = 100
	equipment_effect_062.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_062.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_062.costs = []
	equipment_effect_062.actions = [
		{"type": &"RESTORE_POWER", "params": {"amount": 3}},
		{"type": &"MOVE_MECH", "params": {"use_current_power": true}},
	]
	equipment_effect_062.description = "此牌从区域中弃置时可使机甲回复3动力，之后可以用当前所有动力进行移动。"
	effects[equipment_effect_062.effect_id] = equipment_effect_062

	# ── 063：此牌因损伤而从区域中弃置时可以抽1张装备牌，立即设置或者卖出。 ──
	var equipment_effect_063 := CardEffect.new()
	equipment_effect_063.effect_id = &"equipment_effect_063"
	equipment_effect_063.display_name = "因损伤弃置抽1装备"
	equipment_effect_063.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_063.hook = _EffectConst.HOOK_EQUIPMENT_BROKEN_BY_DAMAGE
	equipment_effect_063.priority = 100
	equipment_effect_063.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_063.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_063.costs = []
	equipment_effect_063.actions = [
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1, "must_set_or_sell": true}},
	]
	equipment_effect_063.description = "此牌因损伤而从区域中弃置时可以抽1张装备牌，立即设置或者卖出。"
	effects[equipment_effect_063.effect_id] = equipment_effect_063

	# ── 064：机甲每设置有1张名称带有联邦的装备牌则此牌护甲+1。 ──
	var equipment_effect_064 := CardEffect.new()
	equipment_effect_064.effect_id = &"equipment_effect_064"
	equipment_effect_064.display_name = "联邦联动护甲+1(含自身)"
	equipment_effect_064.mode = _EffectConst.MODE_STATIC
	equipment_effect_064.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_064.priority = 60
	equipment_effect_064.conditions = [{"op": &"COUNT_EQUIPMENT_WITH_NAME_CONTAINS", "substring": &"联邦", "min_count": 1}]
	equipment_effect_064.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_064.costs = []
	equipment_effect_064.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 1, "per_matching_equipment": true, "substring": &"联邦", "include_self": true, "duration": "PERMANENT"}},
	]
	equipment_effect_064.description = "机甲每设置有1张名称带有联邦的装备牌则此牌护甲+1。"
	effects[equipment_effect_064.effect_id] = equipment_effect_064

	# ── 065：机甲被指定为攻击目标时，可以弃置1张行动牌响应此攻击，使该攻击威力-5，之后设置2损伤在此牌上。 ──
	var equipment_effect_065 := CardEffect.new()
	equipment_effect_065.effect_id = &"equipment_effect_065"
	equipment_effect_065.display_name = "被攻击弃1牌威力-5自损2"
	equipment_effect_065.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_065.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_065.priority = 90
	equipment_effect_065.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_065.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_065.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_065.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": -5, "duration": "THIS_ATTACK"}},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
	]
	equipment_effect_065.description = "机甲被指定为攻击目标时，可以弃置1张行动牌响应此攻击，使该攻击威力-5，之后设置2损伤在此牌上。"
	effects[equipment_effect_065.effect_id] = equipment_effect_065

	# ── 066：使用名称带有光束的武器攻击时，可以弃置1张行动牌，使威力+3。 ──
	var equipment_effect_066 := CardEffect.new()
	equipment_effect_066.effect_id = &"equipment_effect_066"
	equipment_effect_066.display_name = "光束武器弃1牌威力+3"
	equipment_effect_066.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_066.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_066.priority = 90
	equipment_effect_066.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"光束"},
	]
	equipment_effect_066.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_066.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_066.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_066.description = "使用名称带有光束的武器攻击时，可以弃置1张行动牌，使威力+3。"
	effects[equipment_effect_066.effect_id] = equipment_effect_066

	# ── 067：每我方回合1次，可以弃置1张行动牌，之后抽1张行动牌或回复2动力。 ──
	var equipment_effect_067 := CardEffect.new()
	equipment_effect_067.effect_id = &"equipment_effect_067"
	equipment_effect_067.display_name = "弃1牌抽1牌或回复2动力"
	equipment_effect_067.mode = _EffectConst.MODE_ACTIVE
	equipment_effect_067.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_067.priority = 100
	equipment_effect_067.once_per_turn_key = &"equipment_effect_067"
	equipment_effect_067.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_067.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_067.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_067.actions = [
		{"type": &"CHOICE", "params": {"options": [
			{"type": &"DRAW_ACTION", "params": {"count": 1}},
			{"type": &"RESTORE_POWER", "params": {"amount": 2}},
		]}},
	]
	equipment_effect_067.description = "每我方回合1次，可以弃置1张行动牌，之后抽1张行动牌或回复2动力。"
	effects[equipment_effect_067.effect_id] = equipment_effect_067

	# ── 068：机甲每设置有1张名称带有帝国的装备牌则此牌动力+1。 ──
	var equipment_effect_068 := CardEffect.new()
	equipment_effect_068.effect_id = &"equipment_effect_068"
	equipment_effect_068.display_name = "帝国联动动力+1(含自身)"
	equipment_effect_068.mode = _EffectConst.MODE_STATIC
	equipment_effect_068.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_068.priority = 60
	equipment_effect_068.conditions = [{"op": &"COUNT_EQUIPMENT_WITH_NAME_CONTAINS", "substring": &"帝国", "min_count": 1}]
	equipment_effect_068.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_068.costs = []
	equipment_effect_068.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 1, "per_matching_equipment": true, "substring": &"帝国", "include_self": true, "duration": "PERMANENT"}},
	]
	equipment_effect_068.description = "机甲每设置有1张名称带有帝国的装备牌则此牌动力+1。"
	effects[equipment_effect_068.effect_id] = equipment_effect_068

	# ── 069：每回合1次，可以消耗2*n数量的金币(n为整数)，之后移动n个格子(无视动力)，此效果也可以在打出迎击牌时使用。 ──
	var equipment_effect_069 := CardEffect.new()
	equipment_effect_069.effect_id = &"equipment_effect_069"
	equipment_effect_069.display_name = "消耗金币移动n格"
	equipment_effect_069.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_069.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_069.priority = 100
	equipment_effect_069.once_per_turn_key = &"equipment_effect_069"
	equipment_effect_069.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_069.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_069.costs = [{"cost_type": &"SPEND_GOLD_VARIABLE", "formula": &"2*n"}]
	equipment_effect_069.actions = [
		{"type": &"MOVE_WITHOUT_POWER", "params": {"cells_formula": &"n"}},
	]
	equipment_effect_069.description = "每回合1次，可以消耗2*n数量的金币(n为整数)，之后移动n个格子(无视动力)，此效果也可以在打出迎击牌时使用。"
	effects[equipment_effect_069.effect_id] = equipment_effect_069

	# ── 069b：消耗金币移动n格（迎击牌触发） ──
	var equipment_effect_069b := CardEffect.new()
	equipment_effect_069b.effect_id = &"equipment_effect_069b"
	equipment_effect_069b.display_name = "消耗金币移动n格(迎击)"
	equipment_effect_069b.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_069b.hook = _EffectConst.HOOK_REACTION_CARD_PLAYED
	equipment_effect_069b.priority = 100
	equipment_effect_069b.once_per_turn_key = &"equipment_effect_069"
	equipment_effect_069b.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_069b.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_069b.costs = [{"cost_type": &"SPEND_GOLD_VARIABLE", "formula": &"2*n"}]
	equipment_effect_069b.actions = [
		{"type": &"MOVE_WITHOUT_POWER", "params": {"cells_formula": &"n"}},
	]
	equipment_effect_069b.description = "每回合1次，可以消耗2*n数量的金币(n为整数)，之后移动n个格子(无视动力)，此效果也可以在打出迎击牌时使用。"
	effects[equipment_effect_069b.effect_id] = equipment_effect_069b

	# ── 070：使用名称带有热能的武器攻击时，可以弃置1张行动牌，使威力+3。 ──
	var equipment_effect_070 := CardEffect.new()
	equipment_effect_070.effect_id = &"equipment_effect_070"
	equipment_effect_070.display_name = "热能武器弃1牌威力+3"
	equipment_effect_070.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_070.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_070.priority = 90
	equipment_effect_070.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": &"热能"},
	]
	equipment_effect_070.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_070.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 1}]
	equipment_effect_070.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_070.description = "使用名称带有热能的武器攻击时，可以弃置1张行动牌，使威力+3。"
	effects[equipment_effect_070.effect_id] = equipment_effect_070

	# ── 071：机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合护甲+5，动力+2。 ──
	var equipment_effect_071 := CardEffect.new()
	equipment_effect_071.effect_id = &"equipment_effect_071"
	equipment_effect_071.display_name = "被攻击弃2牌护甲+5动力+2"
	equipment_effect_071.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_071.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_071.priority = 100
	equipment_effect_071.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_071.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_071.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 2}]
	equipment_effect_071.actions = [
		{"type": &"MODIFY_ARMOR", "params": {"delta": 5, "duration": &"THIS_TURN"}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": &"THIS_TURN"}},
	]
	equipment_effect_071.description = "机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合护甲+5，动力+2。"
	effects[equipment_effect_071.effect_id] = equipment_effect_071

	# ── 072：此牌上设置有≥2枚损伤时，动力+2。 ──
	var equipment_effect_072 := CardEffect.new()
	equipment_effect_072.effect_id = &"equipment_effect_072"
	equipment_effect_072.display_name = "损伤≥2时动力+2"
	equipment_effect_072.mode = _EffectConst.MODE_STATIC
	equipment_effect_072.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_072.priority = 55
	equipment_effect_072.conditions = [{"op": &"SELF_DAMAGE_TOKENS_ABOVE", "threshold": 2}]
	equipment_effect_072.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_072.costs = []
	equipment_effect_072.actions = [
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 2, "duration": "PERMANENT"}},
	]
	equipment_effect_072.description = "此牌上设置有≥2枚损伤时，动力+2。"
	effects[equipment_effect_072.effect_id] = equipment_effect_072

	# ── 073：可以将发动攻击武器的范围-2(不会低于1)，然后威力+4，类型变为近战武器。 ──
	var equipment_effect_073 := CardEffect.new()
	equipment_effect_073.effect_id = &"equipment_effect_073"
	equipment_effect_073.display_name = "范围-2威力+4变近战(通用)"
	equipment_effect_073.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_073.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_073.priority = 90
	equipment_effect_073.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"远程"},
	]
	equipment_effect_073.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_073.costs = []
	equipment_effect_073.actions = [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "min": 1, "duration": "THIS_ATTACK"}},
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 4, "duration": "THIS_ATTACK"}},
		{"type": &"CHANGE_WEAPON_KIND", "params": {"weapon_kind": &"近战", "duration": "THIS_ATTACK"}},
	]
	equipment_effect_073.description = "可以将发动攻击武器的范围-2(不会低于1)，然后威力+4，类型变为近战武器。"
	effects[equipment_effect_073.effect_id] = equipment_effect_073

	# ── 074：机甲被指定为攻击目标时，可弃置2张行动牌，立即抽1张行动牌(若是迎击牌可以立即响应该攻击)，并使当前回合动力+3。 ──
	var equipment_effect_074 := CardEffect.new()
	equipment_effect_074.effect_id = &"equipment_effect_074"
	equipment_effect_074.display_name = "被攻击弃2牌抽1牌+动力+3"
	equipment_effect_074.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_074.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_074.priority = 100
	equipment_effect_074.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_074.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_074.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 2}]
	equipment_effect_074.actions = [
		{"type": &"DRAW_ACTION", "params": {"count": 1, "can_play_as_reaction": true}},
		{"type": &"MODIFY_MECH_POWER", "params": {"delta": 3, "duration": &"THIS_TURN"}},
	]
	equipment_effect_074.description = "机甲被指定为攻击目标时，可弃置2张行动牌，立即抽1张行动牌(若是迎击牌可以立即响应该攻击)，并使当前回合动力+3。"
	effects[equipment_effect_074.effect_id] = equipment_effect_074

	# ── 075：使用近战武器发动攻击时，可以弃置2张行动牌，使威力+3，之后可以选择攻击目标区域最多2张牌效果无效直到本回合结束。 ──
	var equipment_effect_075 := CardEffect.new()
	equipment_effect_075.effect_id = &"equipment_effect_075"
	equipment_effect_075.display_name = "近战弃2牌威力+3+无效2牌"
	equipment_effect_075.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_075.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_075.priority = 90
	equipment_effect_075.conditions = [
		{"op": &"SOURCE_OWNER_IS_ATTACKER"},
		{"op": &"EQUIPPED_WEAPON_KIND", "weapon_kind": &"近战"},
	]
	equipment_effect_075.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_075.costs = [{"cost_type": &"DISCARD_ACTION_CARD", "count": 2}]
	equipment_effect_075.actions = [
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 3, "duration": "THIS_ATTACK"}},
		{"type": &"DISABLE_TARGET_SLOT_EFFECT", "params": {"max_cards": 2, "duration": &"THIS_TURN"}},
	]
	equipment_effect_075.description = "使用近战武器发动攻击时，可以弃置2张行动牌，使威力+3，之后可以选择攻击目标区域最多2张牌效果无效直到本回合结束。"
	effects[equipment_effect_075.effect_id] = equipment_effect_075

	# ── 076：此牌从区域中弃置时可移除机甲其他区域内最多2损伤。 ──
	var equipment_effect_076 := CardEffect.new()
	equipment_effect_076.effect_id = &"equipment_effect_076"
	equipment_effect_076.display_name = "弃置移除其他区域2损伤"
	equipment_effect_076.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_076.hook = _EffectConst.HOOK_EQUIPMENT_DISCARDED_FROM_SLOT
	equipment_effect_076.priority = 100
	equipment_effect_076.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_076.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_076.costs = []
	equipment_effect_076.actions = [
		{"type": &"REMOVE_DAMAGE_TOKENS", "params": {"amount": 2, "from_other_slots": true}},
	]
	equipment_effect_076.description = "此牌从区域中弃置时可移除机甲其他区域内最多2损伤。"
	effects[equipment_effect_076.effect_id] = equipment_effect_076

	# ── 077：场上所有机甲的所有区域中名称带有联邦的装备牌将额外提供1护甲。 ──
	var equipment_effect_077 := CardEffect.new()
	equipment_effect_077.effect_id = &"equipment_effect_077"
	equipment_effect_077.display_name = "联邦装备全局+1护甲"
	equipment_effect_077.mode = _EffectConst.MODE_STATIC
	equipment_effect_077.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_077.priority = 70
	equipment_effect_077.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_077.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_077.costs = []
	equipment_effect_077.actions = [
		{"type": &"GLOBAL_ARMOR_BONUS_FOR_NAME_CONTAINS", "params": {"substring": &"联邦", "delta": 1}},
	]
	equipment_effect_077.description = "场上所有机甲的所有区域中名称带有联邦的装备牌将额外提供1护甲。"
	effects[equipment_effect_077.effect_id] = equipment_effect_077

	# ── 078：机甲被指定为攻击目标时，可以直接无效该攻击，之后设置5损伤到此牌上。 ──
	var equipment_effect_078 := CardEffect.new()
	equipment_effect_078.effect_id = &"equipment_effect_078"
	equipment_effect_078.display_name = "无效攻击+自损5"
	equipment_effect_078.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_078.hook = _EffectConst.HOOK_MECH_TARGETED_BY_ATTACK
	equipment_effect_078.priority = 80
	equipment_effect_078.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_078.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_078.costs = []
	equipment_effect_078.actions = [
		{"type": &"NEGATE_ATTACK"},
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 5}},
	]
	equipment_effect_078.description = "机甲被指定为攻击目标时，可以直接无效该攻击，之后设置5损伤到此牌上。"
	effects[equipment_effect_078.effect_id] = equipment_effect_078

	# ── 079：发动攻击时，可以设置2损伤到此牌上，使本次攻击威力+4。 ──
	var equipment_effect_079 := CardEffect.new()
	equipment_effect_079.effect_id = &"equipment_effect_079"
	equipment_effect_079.display_name = "自损2威力+4"
	equipment_effect_079.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_079.hook = _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
	equipment_effect_079.priority = 100
	equipment_effect_079.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}]
	equipment_effect_079.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_079.costs = []
	equipment_effect_079.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
		{"type": &"MODIFY_ATTACK_POWER", "params": {"delta": 4, "duration": "THIS_ATTACK"}},
	]
	equipment_effect_079.description = "发动攻击时，可以设置2损伤到此牌上，使本次攻击威力+4。"
	effects[equipment_effect_079.effect_id] = equipment_effect_079

	# ── 080：发动攻击命中时，可以设置3损伤到此牌上，之后本回合的可攻击次数+1。 ──
	var equipment_effect_080 := CardEffect.new()
	equipment_effect_080.effect_id = &"equipment_effect_080"
	equipment_effect_080.display_name = "命中自损3+攻击次数+1"
	equipment_effect_080.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_080.hook = _EffectConst.HOOK_ATTACK_HIT
	equipment_effect_080.priority = 100
	equipment_effect_080.conditions = [{"op": &"SOURCE_OWNER_IS_ATTACKER"}, {"op": &"PAYLOAD_ATTACK_HIT"}]
	equipment_effect_080.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_080.costs = []
	equipment_effect_080.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 3}},
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"extra_attack_count", "value": 1, "duration": &"THIS_TURN"}},
	]
	equipment_effect_080.description = "发动攻击命中时，可以设置3损伤到此牌上，之后本回合的可攻击次数+1。"
	effects[equipment_effect_080.effect_id] = equipment_effect_080

	# ── 081：响应对我方的攻击，可以设置2损伤到此牌上，机甲可立即移动2个格子。 ──
	var equipment_effect_081 := CardEffect.new()
	equipment_effect_081.effect_id = &"equipment_effect_081"
	equipment_effect_081.display_name = "被攻击自损2移动2格"
	equipment_effect_081.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_081.hook = _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW
	equipment_effect_081.priority = 90
	equipment_effect_081.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_081.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_081.costs = []
	equipment_effect_081.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 2}},
		{"type": &"MOVE_WITHOUT_POWER", "params": {"cells": 2}},
	]
	equipment_effect_081.description = "响应对我方的攻击，可以设置2损伤到此牌上，机甲可立即移动2个格子。"
	effects[equipment_effect_081.effect_id] = equipment_effect_081

	# ── 082：发动此效果后，可以立即继续发动此效果。 ──
	var equipment_effect_082 := CardEffect.new()
	equipment_effect_082.effect_id = &"equipment_effect_082"
	equipment_effect_082.display_name = "可重复发动"
	equipment_effect_082.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_082.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	equipment_effect_082.priority = 100
	equipment_effect_082.conditions = [{"op": &"IS_OWNER_MAIN_PHASE"}]
	equipment_effect_082.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_082.costs = []
	equipment_effect_082.actions = [
		{"type": &"ADD_RULE_MODIFIER", "params": {"rule": &"can_repeat_effect", "duration": &"THIS_ACTION"}},
	]
	equipment_effect_082.description = "发动此效果后，可以立即继续发动此效果。"
	effects[equipment_effect_082.effect_id] = equipment_effect_082

	# ── 083：机甲被攻击命中时，可以设置3损伤到此牌上，之后可最多减少此次攻击产生的5损伤。 ──
	var equipment_effect_083 := CardEffect.new()
	equipment_effect_083.effect_id = &"equipment_effect_083"
	equipment_effect_083.display_name = "被命中自损3减5损伤"
	equipment_effect_083.mode = _EffectConst.MODE_PASSIVE
	equipment_effect_083.hook = _EffectConst.HOOK_MECH_HIT_BY_ATTACK
	equipment_effect_083.priority = 90
	equipment_effect_083.conditions = [{"op": &"SOURCE_OWNER_IS_TARGET"}]
	equipment_effect_083.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_083.costs = []
	equipment_effect_083.actions = [
		{"type": &"PLACE_DAMAGE_TOKENS_ON_SLOT", "params": {"amount": 3}},
		{"type": &"MODIFY_DAMAGE_TOKENS", "params": {"delta": -5}},
	]
	equipment_effect_083.description = "机甲被攻击命中时，可以设置3损伤到此牌上，之后可最多减少此次攻击产生的5损伤。"
	effects[equipment_effect_083.effect_id] = equipment_effect_083

	# ── 084：场上所有机甲的所有区域中名称带有帝国的装备牌将额外提供1动力。 ──
	var equipment_effect_084 := CardEffect.new()
	equipment_effect_084.effect_id = &"equipment_effect_084"
	equipment_effect_084.display_name = "帝国装备全局+1动力"
	equipment_effect_084.mode = _EffectConst.MODE_STATIC
	equipment_effect_084.hook = _EffectConst.HOOK_STAT_RECALCULATE
	equipment_effect_084.priority = 70
	equipment_effect_084.conditions = [{"op": &"ALWAYS"}]
	equipment_effect_084.target_rules = [{"rule": &"NO_TARGET"}]
	equipment_effect_084.costs = []
	equipment_effect_084.actions = [
		{"type": &"GLOBAL_POWER_BONUS_FOR_NAME_CONTAINS", "params": {"substring": &"帝国", "delta": 1}},
	]
	equipment_effect_084.description = "场上所有机甲的所有区域中名称带有帝国的装备牌将额外提供1动力。"
	effects[equipment_effect_084.effect_id] = equipment_effect_084

	# ═══════════════════════════════════════════
	# 机师牌效果（由 GeneratedPilotEffects 合入）
	# ═══════════════════════════════════════════
	var pilot_effects := GeneratedPilotEffects.build_pilot_effects()
	for key in pilot_effects:
		effects[key] = pilot_effects[key]

	return effects
