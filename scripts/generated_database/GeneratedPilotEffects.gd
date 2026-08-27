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
	pilot_059_effect_01a.description = "我方回合开始时，可以移除或设置我方1损伤，之后若机甲损伤数低于4则可以获得3金币。"
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
	pilot_059_effect_01b.description = "我方回合开始时，可以移除或设置我方1损伤，之后若机甲损伤数等于4则可以视为使用出1张补给。"
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
	pilot_059_effect_01c.description = "我方回合开始时，可以移除或设置我方1损伤，之后若机甲损伤数大于4则可以移除我方最多2损伤。"
	effects[pilot_059_effect_01c.effect_id] = pilot_059_effect_01c



	# ── pilot_061 艾希：已重做，见 ActionPilotEffects.gd ──

	# ── pilot_062 洛尔恩：已重做，见 ActionPilotEffects.gd（转化掩护 COVER_WINDOW_EXTRA + 掩护加成）──

	# ── pilot_063 布彻尔：已重做，见 ActionPilotEffects.gd ──

	# ── pilot_064 柏格：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 弃装获金抽装（DIRECT 主动按钮）：弃置未设置的装备牌 -> +2金币 + 抽1张装备牌，
	# 若弃置的是武器则再抽2张行动牌。旧 MODE_ACTIVE stub 已移除，由新体系定义。

	# ── pilot_065 银雪：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 旧 MODE_ACTIVE 占位 stub 已移除：窥牌拦截开关（effect_01 DIRECT）+ GAIN_CARD_BEFORE
	# 窥牌拦截（effect_02 LISTEN，隐藏，描述合并按钮1）由新体系定义，走 SET_CARD_COUNTER /
	# CARD_COUNTER_IS / PEEK_DECK_TOP_AND_DISCARD 通用模块。

	# ── pilot_066 骇客：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 移动后查看+类型加成（开关按钮 effect_01 DIRECT + BASIC_MOVE_AFTER 窥牌 effect_02 LISTEN 隐藏）
	# 由新体系定义，走 SET_CARD_COUNTER / CARD_COUNTER_IS / OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE /
	# EFFECT_ONCE_PER_TURN_AVAILABLE / VIEW_RANDOM_OTHER_HAND_CARDS 通用模块。旧 MODE_PASSIVE 实现已移除。

	# ── pilot_067 丹：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 效果1「每回合1次，可以将1张行动牌当作双连使用」（DIRECT 主动按钮）+ 效果2「我方使用的双连
	# 若指定了2个目标，则威力+3，命中额外产生1损伤」（LISTEN 被动）由新体系定义，走
	# CHOOSE_MANY_CARDS / MOVE_ACTION_CARDS_TO_TEMP_ZONE / PLAY_AS_NAMED / MODIFY_ATTACK_MIGHT /
	# MODIFY_ATTACK_MARKERS(fork_persist) / ATTACK_IS_NAMED_CARD / ATTACK_TARGET_COUNT_AT_LEAST
	# 通用模块。旧 MODE_ACTIVE（误消耗2张）实现已移除。

	# ── pilot_068 冰魄：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 效果「我方使用迎击牌响应攻击时，该攻击范围-2（不会低于1）。若该攻击没有命中，我方抽2张行动牌。」
	# 由新体系拆为 2 个 LISTEN 效果（按钮1 + 隐藏合并描述）：
	#   effect_01（USE_ACTION_AT）：迎击响应时先于迎击牌效果前 MODIFY_ATTACK_RANGE -2(min 1) +
	#     SET_ACTION_RECORD_FLAG；effect_02（ATTACK_AFTER）：flag 已设 + PAYLOAD_ATTACK_MISS 时
	#     EXECUTE_GAIN_CARD 抽2。旧 MODE_PASSIVE（CUSTOM_EFFECT_CHECK_TEXT 假动作）实现已移除。

	# ── pilot_069 影刹：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 效果「每个我方回合结束时，若本回合未发动攻击，则下次攻击威力+3；若本回合移动未超过4格，
	# 则下次攻击范围+1。上述效果可叠加。」由新体系拆为 3 个 LISTEN 效果（按钮1 + 两个隐藏合并描述）：
	#   effect_01（TURN_END）：通用 ACCUMULATE_NEXT_ATTACK_BONUS 读机甲 has_attacked_this_turn /
	#     cells_moved_this_turn 累加两张牌计数器（pilot_069_next_might/next_range，跨回合叠加）；
	#   effect_02（ATTACK_BEFORE）：通用 APPLY_NEXT_ATTACK_BONUS 读计数器写 attack.record 的
	#     extra_might/extra_range（选目标前生效、双连 fork 深拷贝继承）；effect_03（ATTACK_SETTLE）：
	#     SET_CARD_COUNTER 置 0（攻击完全结算后消失，取消攻击保留）。
	# 旧 MODE_PASSIVE（01a MODIFY_NEXT_DAMAGE_DEALT/01b CUSTOM_EFFECT_CHECK_TEXT 假动作）实现已移除。

	# ── pilot_070 烈火：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 效果「若发动的攻击命中，则可以抽3张行动牌（这些牌本回合不占行动牌上限）。」
	# 由新体系定义为 1 个 LISTEN 效果（按钮1，build_attack_hit_draw_and_tag_effect 通用模块）：
	#   effect_01（ATTACK_AFTER / attack）：SELF_MECH_IS_ATTACKER + PAYLOAD_ATTACK_HIT 时
	#     EXECUTE_GAIN_CARD 抽3 行动牌，_tag_on_draw 给抽到的牌打"燃"标签（本回合不占行动牌上限，
	#     弃超上限牌时排除；回合结束后由 TurnService 步骤7.1 清标签）。
	# 旧 MODE_PASSIVE（HOOK_ATTACK_HIT + SOURCE_OWNER_IS_ATTACKER，新引擎不可用的旧条件）实现已移除。

	# ── pilot_071 弥雅：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 效果「每个我方回合结束后，可以选择1台3格范围内的机甲（包括我方）使其抽3张行动牌，
	# 之后其再弃置1张牌。」由新体系定义为 1 个 LISTEN 效果（按钮1，build_turn_end_choose_mech_draw_discard_effect
	# 通用模块）：TURN_AFTER_END + IS_OWNER_TURN 时 CHOOSE_MANY_MECHS 选1台3格内机甲（含自己、可取消）
	# + EXECUTE_GAIN_CARD 抽3（mech_ids 反查目标玩家）+ EXECUTE_DISCARD 被选玩家必弃1（空手跳过）。
	# 旧 MODE_ACTIVE（HOOK_TURN_END + CHOOSE_ENEMY_MECH_IN_RANGE + 非法 DISCARD_ACTION_CARD）实现已移除。

	# ── pilot_072 卡修：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 效果「每个效果每回合1次：使用攻击牌时，回复5动力；使用迎击牌时，回复4动力；使用辅助牌时，回复3动力。」
	# 由新体系拆为 3 个 LISTEN 效果（按钮1 + 两个隐藏合并描述），共用通用模块
	# build_use_action_type_restore_power_effect：USE_ACTION_AT + USED_CARD_OWNER_IS_SELF +
	#   USED_CARD_TYPE_IS（攻击/迎击/辅助）+ RESTORE_POWER（method=restore）。每分支各自
	#   once_per_turn_key（pilot_072_attack/counter/support_restore），每回合各1次互不影响。
	# 旧 MODE_PASSIVE（HOOK_ACTION_CARD_PLAYED 等旧条件）实现已移除。

	# ── pilot_073 法尔科：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	# 效果「我方回合1次，可以弃置2张行动牌，之后抽取1张高级装备牌，并背面朝上置于我方或其他机甲
	# 的备用区，直到下个我方回合开始后，该高级装备牌不能主动设置与卖出。」由新体系定义为 1 个
	# DIRECT 效果（按钮1，build_discard_draw_advanced_equip_set_reserve_effect 通用模块）：
	#   CHOOSE_MANY_CARDS 弃2行动（可取消）→ EXECUTE_DISCARD → EXECUTE_GAIN_CARD 抽1高级装备
	#   （_tag_on_draw 打"禁"标签 + _draw_result_sink 回写抽到的牌）→ 新 act_type
	#   CHOOSE_RESERVE_SLOT_AND_SET_EQUIP（TimingEngine 弹备用区选择，仅显示占位不翻牌，
	#   效果驱动设置绕过主动设置/卖出拦截）。"禁"标签在持有者下个我方回合开始后由 TurnService
	#   （TURN_AFTER_START）清除。旧 MODE_ACTIVE（HOOK_OWNER_MAIN_PHASE + DRAW_ADVANCED_EQUIPMENT
	#   + 假 CUSTOM_EFFECT_CHECK_TEXT，无备用区选择/无背面设置/无禁用）实现已移除。

	# ── pilot_074 泰特：近战弃1+3威力/授予他机（已迁移到新 Action 体系）──
	# 旧 MODE_PASSIVE（HOOK_ATTACK_MODIFIER_WINDOW + EQUIPPED_WEAPON_KIND + DISCARD_ACTION_CARD cost +
	# MODIFY_ATTACK_POWER / HOOK_OTHER_MECH_TURN_START + TOGGLE_EFFECT_ON_MECH）实现已移除，
	# 新实现见 ActionPilotEffects.build_pilot_effects() pilot_074 段（DIRECT 按钮1/2 +
	# 隐藏 LISTEN apply/consume/turnend/expire + "近战弃牌威力"通用模块）。

	# ── pilot_075 肯尼斯：弃1行动牌3次/弃置加成（已迁移到新 Action 体系）──
	# 旧 MODE_ACTIVE(HOOK_OWNER_MAIN_PHASE) + MODE_PASSIVE(HOOK_CARD_DISCARDED +
	# CUSTOM_EFFECT_CHECK_TEXT) 实现已移除，新实现见
	# ActionPilotEffects.build_pilot_effects() pilot_075 段：
	#   · pilot_075_effect_01（DIRECT 按钮1，我方回合3次弃1行动牌，显式 MARK 计次）
	#   · pilot_075_effect_02（LISTEN DISCARD_AFTER 按钮2，弃置行动牌后弹窗抽1/威力+2，含辅助牌自动双效果）
	#   · 隐藏 effect_02_auto/_apply/_consume/_turnend（含辅助牌自动执行 / ATTACK_BEFORE 应用 / ATTACK_SETTLE 消耗 / TURN_AFTER_END 清空）
	#   · 待发威力走来源牌实例计数器 var_p075_next_might（INCREMENT_VARIABLE/APPLY_NEXT_ATTACK_BONUS/SET_CARD_COUNTER，
	#     零新增原子动作，与效果绑定不绑机师）

	# ── pilot_076 疾风：已迁至 ActionPilotEffects.build_pilot_effects()（新 Action 体系）──
	# 旧 MODE_PASSIVE (HOOK_ATTACK_RESOLVED + CUSTOM_EFFECT_CHECK_TEXT) 占位实现已移除，
	# 新实现见 ActionPilotEffects pilot_076 段：effect_01 (LISTEN USE_ACTION_BEFORE 强制消耗动力
	# + COUNTER_POWER_DRAIN_TARGET) + effect_02 (隐藏 LISTEN USE_ACTION_SETTLE 自动 CLAIM 获牌
	# + COUNTER_CLAIM_TRIGGERED)。通用件不绑机师，复用珀修斯 pilot_007 CLAIM 弃牌堆回收。

	# ── pilot_077 维奥拉（已迁移至新 Action 系统：ActionPilotEffects.build_attack_settle_draw_discard_reattack_effect）──

	# ── pilot_078 芮贝卡（已迁移至新 Action 系统：ActionPilotEffects.build_injury_heal_draw_effect）──

	# ── pilot_079 莉诺：原价购买商店装备（已迁移至新 Action 体系）──
	# 新实现见 ActionPilotEffects.build_pilot_effects() pilot_079 段 + 通用
	#   build_face_value_buy_effect 模块（LISTEN TURN_START 重置计数器 + 商店弹窗独立
	#   "原价购买"选项 + ShopService 购买消耗），不再使用废弃的 SHOP_BUY_MODIFIER。
	# 原旧版 SHOP_BUY_MODIFIER 实现已移除。

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

	# ── pilot_081 汀兰：已迁移至 ActionPilotEffects（新动作引擎，绿格光环按需派生 + RE 请求回复） ──

	# ── pilot_082 温斯顿：已迁移至 ActionPilotEffects（新动作引擎，交牌+联标签+当作3类型） ──

	# ── pilot_083 瓦恩：已迁移至 ActionPilotEffects（新动作引擎，武器修改两阶段流程 + RE 请求） ──

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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 2}},
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

	# ── pilot_086 獠鼠：已迁移到新系统 ActionPilotEffects.pilot_086_effect_01 ──

	# ── pilot_087 塔妮拉：已迁移至新 Action Engine（ActionPilotEffects.build_pilot_effects）──
	#   见 ActionPilotEffects.p087e1（DIRECT 交牌获2金，每我方回合2次，仿 pilot_082 模式：
	#   target_rule CHOOSE_OTHER_MECH + TARGET_IN_RANGE:3 → CHOOSE_MANY_CARDS 选1张我方手牌
	#   no_cancel:true → post_actions TRANSFER_ACTION_CARDS 打"交"标签 + GAIN_GOLD amount:2）。
	#   效果2 p087e2（LISTEN 置灰+悬停）：实际逻辑在 discard_card_action._step_transfer_to_pile
	#   挂钩，由 pilot_087_trigger_jiao_draw 触发双方各抽1。"交"标签生命周期由
	#   GameActions.transfer_action_cards / steal_action_card 挂钩打标签，discard 挂钩清标签；
	#   GameSetupService._on_pilot_unset 清塔妮拉名下全部"交"标签。

	# ── pilot_088 征服：已迁移到 ActionPilotEffects.p088e1（DIRECT 主动按钮+入口骨架；
	#   完整选机甲/选类型/展示/弃置流程在 ActionPilotEffects.gd 第二步实现）──

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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1}},
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
			"text": "我方回合1次，可以将任意张行动牌交给4格范围内1台其他机甲，每给出2张牌，之后我方和该机甲可以各抽1张行动牌，护甲+2（持续到下个我方回合开始）。",
		}},
	]
	pilot_031_effect_01.description = "我方回合1次，可以将任意张行动牌交给4格范围内1台其他机甲，每给出2张牌，之后我方和该机甲可以各抽1张行动牌，护甲+2。"
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
	pilot_032_effect_01.description = "我方回合1次，可以选择场上1张机师牌，弃置1张行动牌，使其行动牌上限+2（效果持续到下个我方回合开始）。"
	effects[pilot_032_effect_01.effect_id] = pilot_032_effect_01

	# ── pilot_036 菲丽丝：已迁移至 ActionPilotEffects.gd（新 ActionEffect 体系）──
	# 效果01「消耗2金币抽1」（我方回合2次）+ 效果02「弃2行动获4金」（我方回合1次）
	# 见 ActionPilotEffects.build_pilot_effects() 的 pilot_036 实现。

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

	# ── pilot_038 奥黛尔：已迁移至 ActionPilotEffects.gd（新 ActionEffect 体系）──
	# 效果01「战术协同」（我方回合1次）：选择最多2台4格范围内机甲（含我方）抽2张行动牌+回复3动力。
	# 通用机制组装（CHOOSE_MANY_MECHS 多选机甲 + 显式 MARK 计次 + FOR_EACH_TARGET 逐目标）。
	# 见 ActionPilotEffects.build_pilot_effects() 的 pilot_038 实现。

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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1}},
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

	# ── pilot_041 盖奇特：已迁移至 ActionPilotEffects.gd（新 ActionEffect 体系）──
	# 效果01「花费3金抽2」（我方回合1次）：DIRECT 主动按钮，金币≥3 才可点（GOLD_ABOVE threshold=2），
	# 动作链 SPEND_GOLD(3) -> EXECUTE_GAIN_CARD(action_deck,2)。
	# 见 ActionPilotEffects.build_pilot_effects() 的 pilot_041 实现。

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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1}},
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

	# ── pilot_044 损伤数X抽X+1弃X ──
	var pilot_044_effect_01 := CardEffect.new()
	pilot_044_effect_01.effect_id = &"pilot_044_effect_01"
	pilot_044_effect_01.display_name = "损伤X抽X+1弃X"
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
			"text": "每个我方回合开始时与回合结束后，记录机甲所有区域的损伤数为X，之后抽X+1张行动牌，再弃置X张行动牌。",
		}},
	]
	pilot_044_effect_01.description = "每个我方回合开始时与回合结束后，记录机甲所有区域的损伤数为X，之后抽X+1张行动牌，再弃置X张行动牌。"
	effects[pilot_044_effect_01.effect_id] = pilot_044_effect_01

	# ── pilot_045 遗弃回收（旧 CardEffect 已迁移到 ActionPilotEffects.gd 的 ActionEffect）──
	# 旧实现：弃3行动获攻牌 + 每2次4伤害（MODE_ACTIVE CHOOSE_ENEMY_MECH_IN_RANGE + MODE_PASSIVE 回合末计数）。
	# 新实现（ActionPilotEffects.pilot_045_effect_01）：CHOOSE_ONE 确认 + FOR_EACH_TARGET(range 扫描目标源)
	#   + RANDOM_DISCARD_ACTION_CARD 捕获攻击牌 + EXECUTE_GAIN_CARD + MODIFY_ATTACK_COUNT + EXECUTE_HP_CHANGE，
	#   全部通用机制组装，不再依赖本遗留模块。如需复用请复制 ActionPilotEffects.gd 中整段定义改参数。

	# ── pilot_046 查看获取隐藏装（旧 CardEffect 已迁移到 ActionPilotEffects.gd 的 ActionEffect）──
	# 旧实现：CUSTOM_EFFECT_CHECK_TEXT 占位（无实际效果）。
	# 新实现（ActionPilotEffects.pilot_046_effect_01）：通用 HIDDEN_VIEW_AND_ACQUIRE act_type，
	#   查看商店隐藏高级装备 + 其他玩家备用区白板（打开面板即 known_to 标记商店隐藏牌），
	#   我方回合1次消耗牌面金币获取该牌，背面朝上置于任意机甲备用区。完整实现见
	#   ActionPilotEffects.gd 与 TimingEngine._handle_hidden_view_and_acquire / resume 阶段。

	# ── pilot_047 里欧娜：迁移至 ActionPilotEffects.gd（LISTEN ATTACK_SETTLE 阻塞式）──
	# 重做后效果：我方攻击结算后，可以选择1台4格范围内的其他机甲，其选择立即使用1张攻击牌，
	# 否则必须交给我方3张行动牌，若数量不足则每少1张该机甲将受到2伤害。
	# 旧实现（HOOK_ATTACK_DECLARED + FORCE_MECH_ACTION，不符合新版 action engine）已删除，
	# 完整实现见 ActionPilotEffects.gd pilot_047_effect_01 + TimingEngine PILOT_047_* handler。

	# ── pilot_048 赤牙：迁移至 ActionPilotEffects.gd（LISTEN ATTACK_AFTER 通用机制组装）──
	# 重做后效果：我方攻击造成的损伤+1（MODIFY_ATTACK_MARKERS）。我方发动的攻击即使被目标响应，
	# 也依然由我方来决定损伤设置的位置（SET_ACTION_RECORD_FLAG 通用flag + attack_action 第⑦步读取）。
	# 旧实现（HOOK_ATTACK_HIT + MODIFY_DAMAGE_TOKENS + 只写文字的 CUSTOM_EFFECT_CHECK_TEXT，
	# 不符合新版 action engine、损伤放置决定逻辑缺失）已删除，
	# 完整实现见 ActionPilotEffects.gd pilot_048_effect_01。

	# ── pilot_049 杰狞（伤害转移 + 受伤加伤）已迁移至 ActionPilotEffects.gd ──
	# 重做后效果（杰狞 pilot_049）：
	#   效果1 伤害转移：LISTEN(HP_CHANGE_BEFORE priority -1)，4格范围内其他机甲即将受到伤害时
	#     弹确认将该伤害转移由我方承受（REDIRECT_HP_CHANGE_TARGET 改 hp_change mech_ids，只转HP伤害）。
	#   效果2 受伤加伤：LISTEN(HP_CHANGE_BEFORE)，我方造成伤害时按受伤计数 X 加伤 +4*X 并清零
	#     （MODIFY_HP_CHANGE_VALUE_BY_VARIABLE）；隐藏效果02b LISTEN(HP_CHANGE_SETTLE) 每受1次伤 X+1。
	# 旧实现（HOOK_OWNER_TAKE_DAMAGE + CUSTOM_EFFECT_CHECK_TEXT + MODIFY_NEXT_DAMAGE_DEALT delta 0，
	# 阵营限定帝国、只写文字不实际转移/加伤，不符合新版 action engine）已删除，
	# 完整实现见 ActionPilotEffects.gd pilot_049_effect_01/02/02b。

	# ── pilot_050 杰西卡（动力税 + 受伤X+1弃牌）已迁移至 ActionPilotEffects.gd ──
	# 重做后效果（杰西卡 pilot_050）：
	#   效果1 动力税：e01 LISTEN(BASIC_MOVE_AT) 移动消耗 + e01b LISTEN(power_spent 虚拟时点)
	#     非移动消耗（GameActions.spend_power 统一通知，reason=BASIC_MOVE 除外防双计）。
	#     4+X格内其他机甲每累计消耗2动力弹确认，确认 -> 两次独立 hp_change（先该机甲后我方），
	#     确认/拒绝都清这2点累计，一次消耗N点=floor(N/2)次询问串行（POWER_SPEND_TAX 通用机制）。
	#   效果2 受伤X+1弃牌：LISTEN(HP_CHANGE_SETTLE) 我方实际掉血，每回合1次（取消不消耗），
	#     确认 -> X+1（先于范围计算）-> 按新X选范围内其他机甲（无候选仅X+1）-> 我方/目标
	#     各弃2张行动牌（chooser均为我方，目标牌牌背；≤2张直接全选）（POWER_TAX_TRIBUTE 状态机）。
	# 旧实现（HOOK_TURN_END + CUSTOM_EFFECT_CHECK_TEXT 各受到1伤害只写文字不实际结算 /
	# HOOK_OWNER_TAKE_DAMAGE + INCREMENT_VARIABLE pilot_050_X 与新 counter 命名不一致，
	# 不符合新版 action engine）已删除，完整实现见 ActionPilotEffects.gd
	# pilot_050_effect_01/01b/02。

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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1}},
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

	# ── pilot_052 萨伊（弃1行动抽1装备）已迁移至 ActionPilotEffects.gd ──
	# 重做后效果（萨伊 pilot_052）：
	#   我方回合2次（once_per_turn_max=2）主动 DIRECT 按钮：点击弹"选1张行动牌"窗
	#     （OWNER_ACTION_HAND 必选1张、可取消不计次数），弃置所选行动牌后抽1张装备牌。
	# 旧实现（MODE_ACTIVE + DISCARD_ACTION_CARD 费用只写1次/回合、费用弃牌无单选UI）已删除，
	# 完整实现见 ActionPilotEffects.gd pilot_052_effect_01。

	# ── pilot_053 亚林（装备设置/弃置抽2+上限+1）已迁移至 ActionPilotEffects.gd ──
	# 重做后效果（亚林 pilot_053，每回合2次，被动双监听共享额度）：
	#   我方区域有正面朝上的装备牌被设置（SET_EQUIP_AT）或弃置（DISCARD_AFTER，含敌方回合
	#   损伤损坏弃置）时，弹确认窗（可取消不计次），确认后抽2张行动牌、行动牌上限+1
	#   （立即生效，下个我方回合开始到期清除，可叠加）。
	# 旧实现（只监听设置、无每回合次数、MODIFY_ACTION_HAND_LIMIT NEXT_OWNER_TURN 上限永久
	#   泄漏不恢复、无确认弹窗）已删除，完整实现见 ActionPilotEffects.gd pilot_053_effect_01/01b。

	# ── pilot_054 购买后获金/抽牌（已迁移）──
	# 旧实现（只监听未触发的 HOOK_SHOP_CARD_BOUGHT、无确认弹窗、无高级装备判定）已删除，
	# 完整实现见 ActionPilotEffects.gd pilot_054_effect_01（监听通用时点 SHOP_BUY_AFTER）。

	# ── pilot_055 卖出翻倍（已迁移至 ActionPilotEffects.gd）──
	# 旧实现（监听无触发点的 HOOK_EQUIPMENT_SOLD、GAIN_GOLD amount=0，未实现×2）已删除，
	# 完整实现见 ActionPilotEffects.gd pilot_055_effect_01（LISTEN 监听 DISCARD_BEFORE，
	# 条件=卖出reason+归属自己+每回合1次，确认弹窗后补发1倍卖价+高级3金）。

	# pilot_056 铠厉 已迁移至 ActionPilotEffects.gd（新 ActionEffect 体系）。
	# 效果01「被响应→抽2装备→逐张设置/弃置获金」：被动 LISTEN ATTACK_SETTLE，条件=我方为攻击方且本次攻击被响应，
	# 调度到攻击动作完全结算后弹确认，确认后抽2张装备牌，逐张弹「立即设置/弃置获金(cost)」面板。
	# 通用链式模块（responded_equip_chain_*，不绑机师）见 ActionPilotEffects.gd。

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
	pilot_059_router.description = "我方回合开始时，可以移除或设置我方1损伤，之后若机甲损伤数低于4则可以获得3金币/等于4则可以视为使用出1张补给/大于4则可以移除我方最多2损伤。"
	effects[pilot_059_router.effect_id] = pilot_059_router



	# pilot_069 已迁移（effect_id 由新体系 pilot_069_effect_01/02/03 承担），旧路由定义移除。

	# pilot_072 已迁移（effect_id 由新体系 pilot_072_effect_01a/01b/01c 承担），旧路由定义移除。

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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1}},
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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1}},
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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1}},
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

	# ── pilot_015 诺拉：已迁移至 ActionPilotEffects.gd（新 ActionEffect 体系）──

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

	# ── pilot_018 苔丝：已迁移至 ActionPilotEffects.gd（新 ActionEffect 体系）──

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
						{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1}},
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
						{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1}},
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
	# 注：机师效果运行时走 ActionPilotEffects（新体系），此处 legacy 定义仅保持数据一致。
	var pilot_026_effect_01 := CardEffect.new()
	pilot_026_effect_01.effect_id = &"pilot_026_effect_01"
	pilot_026_effect_01.display_name = "当作设陷"
	pilot_026_effect_01.mode = _EffectConst.MODE_ACTIVE
	pilot_026_effect_01.hook = _EffectConst.HOOK_OWNER_MAIN_PHASE
	pilot_026_effect_01.priority = 100
	pilot_026_effect_01.once_per_turn_key = &"pilot_026_effect_01"
	pilot_026_effect_01.conditions = [
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"ATTACK_COUNT_ABOVE", "params": {"threshold": 0}},
	]
	pilot_026_effect_01.target_rules = [{"rule": &"NO_TARGET"}]
	pilot_026_effect_01.costs = [
		{"cost_type": &"SPEND_ATTACK_CHANCE"},
	]
	pilot_026_effect_01.actions = [
		{"type": &"ADD_STATUS", "params": {"status_type": &"SET_TRAP", "stacks": 2}},
	]
	pilot_026_effect_01.description = "每回合1次，消耗1点当前回合攻击数，视为使用出1张设陷。"
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

	# ── pilot_028 乌尔：已重做为宣言/需交牌/X+1（见 ActionPilotEffects.pilot_028_*），旧效果移除 ──


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

	# pilot_015 已迁移至 ActionPilotEffects.gd（新 ActionEffect 体系）

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
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 1}},
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
