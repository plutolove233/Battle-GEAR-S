## EffectRegistry.gd — 登记当前场上有效的效果
##
## EffectRegistry 维护两个核心字典：
##   effects_by_hook —— 按 hook 分组的被动/静态效果绑定列表
##   active_effects_by_source —— 按来源牌分组的主动效果绑定列表
## 当牌进入/离开区域时，通过 register_card / unregister_card / refresh_card 更新注册。
## 数据结构来源于规则表 Effect全牌表.xlsx "核心执行框架" 第3行。
extends RefCounted
class_name EffectRegistry

## Preloaded references for cross-file custom types
const _GameContext = preload("res://scripts/runtime/GameContext.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _CardEffect = preload("res://scripts/effect_core/CardEffect.gd")
const _EffectBinding = preload("res://scripts/effect_core/EffectBinding.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")

## 依赖注入：GameContext 容器
var context = null

## 按 hook 分组的被动/静态效果绑定：{ StringName => Array[EffectBinding] }
var effects_by_hook: Dictionary = {}

## 按来源牌实例ID分组的主动效果绑定：{ StringName => Array[EffectBinding] }
var active_effects_by_source: Dictionary = {}


## 注册一张牌的所有效果
func register_card(card) -> void:
	if card == null or card.def == null:
		return
	for effect in card.def.effects:
		if not _should_register(card, effect):
			continue
		var binding = _EffectBinding.new(card, effect)
		# 被动和静态效果按 hook 分组
		if effect.mode == _EffectConst.MODE_PASSIVE or effect.mode == _EffectConst.MODE_STATIC:
			if not effects_by_hook.has(effect.hook):
				effects_by_hook[effect.hook] = []
			effects_by_hook[effect.hook].append(binding)
		# 主动效果按来源牌分组
		if effect.mode == _EffectConst.MODE_ACTIVE:
			if not active_effects_by_source.has(card.instance_id):
				active_effects_by_source[card.instance_id] = []
			active_effects_by_source[card.instance_id].append(binding)


## 注销一张牌的所有效果
func unregister_card(card) -> void:
	if card == null:
		return
	# 从 effects_by_hook 中移除
	for hook_key in effects_by_hook.keys():
		var bindings: Array = effects_by_hook[hook_key]
		bindings = bindings.filter(func(b) -> bool:
			return b.source_card != card
		)
		if bindings.is_empty():
			effects_by_hook.erase(hook_key)
		else:
			effects_by_hook[hook_key] = bindings
	# 从 active_effects_by_source 中移除
	active_effects_by_source.erase(card.instance_id)


## 刷新一张牌的效果注册（先注销再注册）
func refresh_card(card) -> void:
	unregister_card(card)
	register_card(card)


## 获取指定 hook 的所有被动/静态效果绑定
func get_bindings_by_hook(hook: StringName) -> Array:
	if effects_by_hook.has(hook):
		return effects_by_hook[hook]
	return []


## 获取指定来源牌的指定主动效果绑定
func get_active_effect(source_instance_id: StringName, effect_id: StringName):
	if not active_effects_by_source.has(source_instance_id):
		return null
	var bindings: Array = active_effects_by_source[source_instance_id]
	for binding in bindings:
		if binding.effect.effect_id == effect_id:
			return binding
	return null


## 获取所有主动效果绑定（用于 UI 技能栏显示）
func get_all_active_bindings() -> Array:
	var result: Array = []
	for source_id: StringName in active_effects_by_source:
		for binding in active_effects_by_source[source_id]:
			result.append(binding)
	return result


## 判断一张牌的某个效果是否应该注册
## 只有牌在效果生效区域（装备槽、武器槽、事件槽、驾驶员槽）时才注册
## 手牌中的行动牌/装备牌不自动注册——它们只能通过"打出"后快照解析
func _should_register(card, effect) -> bool:
	if card == null:
		return false
	# 被禁用的牌不注册效果
	if card.disabled:
		return false
	# 行动牌在手牌中不自动注册——它们只能通过"打出"后快照解析
	# 否则 fire_hook 会自动触发手牌中的行动牌效果（如猛击+4、防御+5），
	# 导致玩家未选择就自动执行，且与快照解析重复执行
	if card.zone in [&"action_hand", &"equipment_hand"]:
		return false
	# 场上持续效果自动注册
	var active_zones: Array[StringName] = [
		&"equipment_slot",
		&"weapon_slot",
		&"event_slot",
		&"pilot_slot",
		&"reserve_slot",
	]
	return card.zone in active_zones
