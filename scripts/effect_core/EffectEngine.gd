## EffectEngine.gd — Hook 分发与主动效果入口
##
## EffectEngine 是效果系统的调度中心：
##   fire_hook —— 将 hook 事件入队并按优先级处理
##   use_active_effect —— 玩家主动使用效果的入口
## 内部通过 ConditionChecker / TargetChecker / CostChecker 三重校验后，
## 交由 AtomicActionResolver 逐个执行动作。
## 数据结构来源于规则表 Effect全牌表.xlsx "核心执行框架" 第4行。
extends RefCounted
class_name EffectEngine

## Preloaded references for cross-file custom types
const _GameContext = preload("res://scripts/runtime/GameContext.gd")
const _EffectBinding = preload("res://scripts/effect_core/EffectBinding.gd")
const _CardEffect = preload("res://scripts/effect_core/CardEffect.gd")
const _ConditionChecker = preload("res://scripts/effect_core/ConditionChecker.gd")
const _TargetChecker = preload("res://scripts/effect_core/TargetChecker.gd")
const _CostChecker = preload("res://scripts/effect_core/CostChecker.gd")
const _AtomicActionResolver = preload("res://scripts/effect_core/AtomicActionResolver.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")

## 依赖注入：GameContext 容器
var context = null

## Hook 事件队列：[{ hook: StringName, payload: Dictionary }]
var hook_queue: Array[Dictionary] = []

## 是否正在处理队列（防止递归重入）
var processing: bool = false

## ── 信号 ──
signal hook_fired(hook: StringName, payload: Dictionary)
signal effect_resolved(binding, payload: Dictionary)
signal effect_failed(binding, payload: Dictionary, reason: String)


## 触发 hook：将事件入队，然后处理队列
func fire_hook(hook: StringName, payload: Dictionary) -> void:
	hook_queue.append({ "hook": hook, "payload": payload })
	hook_fired.emit(hook, payload)
	_process_queue()


## 玩家主动使用效果
## source_instance_id: 来源牌实例ID
## effect_id: 效果ID
## input_payload: 玩家提供的输入参数
## 返回: 是否成功使用
func use_active_effect(source_instance_id: StringName, effect_id: StringName, input_payload: Dictionary) -> bool:
	if context == null or context.effect_registry == null:
		push_error("EffectEngine: context 或 effect_registry 未初始化")
		return false
	var binding = context.effect_registry.get_active_effect(source_instance_id, effect_id)
	if binding == null:
		push_warning("EffectEngine: 找不到主动效果 source=%s effect=%s" % [source_instance_id, effect_id])
		return false
	var payload := input_payload.duplicate(true)
	payload["manual"] = true
	payload["source_instance_id"] = source_instance_id
	payload["effect_id"] = effect_id
	return _try_resolve_binding(binding, payload, true)


## 处理 hook 队列（串行，防止递归）
func _process_queue() -> void:
	if processing:
		return
	processing = true
	while not hook_queue.is_empty():
		var entry: Dictionary = hook_queue.pop_front()
		var hook: StringName = entry["hook"]
		var payload: Dictionary = entry["payload"]
		_dispatch_hook(hook, payload)
	processing = false


## 分发 hook 到所有注册的被动/静态效果
## P0-0: 添加诊断日志
func _dispatch_hook(hook: StringName, payload: Dictionary) -> void:
	if context == null or context.effect_registry == null:
		return
	var bindings: Array = context.effect_registry.get_bindings_by_hook(hook)
	# 按优先级排序（数值越小越先执行）
	bindings.sort_custom(func(a, b) -> bool:
		return a.effect.priority < b.effect.priority
	)
	# P0-0: 诊断日志
	if bindings.size() > 0:
		var binding_info: String = ""
		for b in bindings:
			if b.effect:
				binding_info += "%s(src=%s) " % [String(b.effect.effect_id), String(b.source_card.instance_id) if b.source_card else "?"]
		print("[EffectEngine] hook=%s bindings=%d: %s" % [String(hook), bindings.size(), binding_info])
	for binding in bindings:
		_try_resolve_binding(binding, payload, false)


## 尝试结算一个效果绑定
## is_manual: 是否为玩家主动使用
## 返回: 是否成功结算
func _try_resolve_binding(binding, payload: Dictionary, is_manual: bool) -> bool:
	if context == null:
		push_error("EffectEngine: context 未初始化")
		return false
	var effect = binding.effect

	# 1. 主动效果在自动触发时跳过
	if not is_manual and effect.mode == _EffectConst.MODE_ACTIVE:
		return false

	# 2. 每回合次数检查
	if effect.once_per_turn_key != &"":
		var player_id: StringName = binding.get_owner_player_id()
		var key: String = "%s_%s" % [player_id, effect.once_per_turn_key]
		if context.game_state != null:
			var player_state = context.game_state.players.get(player_id)
			var used: int = player_state.once_per_turn_used.get(key, 0) if player_state != null else 0
			if used >= effect.once_per_turn_max:
				return false

	# 3. 条件检查
	if not _ConditionChecker.check_all(binding, payload, effect.conditions):
		return false

	# 4. 目标检查
	if not _TargetChecker.check_all(binding, payload, effect.target_rules):
		return false

	# 5. 费用检查
	if not _CostChecker.can_pay_all(binding, payload, effect.costs, context):
		return false

	# 6. 支付费用
	_CostChecker.pay_all(binding, payload, effect.costs, context)

	# 7. 逐个执行动作
	for action in effect.actions:
		_AtomicActionResolver.resolve(binding, payload, action, context)

	# 8. 标记每回合效果使用次数
	if effect.once_per_turn_key != &"":
		var player_id: StringName = binding.get_owner_player_id()
		var key: String = "%s_%s" % [player_id, effect.once_per_turn_key]
		if context.game_state != null:
			var player_state = context.game_state.players.get(player_id)
			if player_state != null:
				var prev: int = player_state.once_per_turn_used.get(key, 0)
				player_state.once_per_turn_used[key] = prev + 1

	effect_resolved.emit(binding, payload)
	return true
