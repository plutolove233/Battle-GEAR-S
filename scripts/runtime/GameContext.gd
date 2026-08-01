## GameContext.gd — 依赖注入容器
##
## GameContext 替代 Autoload，持有所有运行时对象的引用。
## 新系统为唯一入口，旧服务降级为内部辅助。
## 所有对外操作通过 action_service.execute() 统一调度。
class_name GameContext
extends RefCounted

const _GameState = preload("res://scripts/runtime/GameState.gd")
const _GameActions = preload("res://scripts/effect_core/GameActions.gd")
const _CardDatabase = preload("res://scripts/generated_database/CardDatabase.gd")
const _MapState = preload("res://scripts/runtime/MapState.gd")
const _DeckState = preload("res://scripts/runtime/DeckState.gd")
const _ShopState = preload("res://scripts/runtime/ShopState.gd")

## ── 新动作系统（主入口） ──
const _ActionEngine = preload("res://scripts/action_core/ActionEngine.gd")
const _ActionRegistry = preload("res://scripts/action_core/ActionRegistry.gd")
const _TimingEngine = preload("res://scripts/action_core/TimingEngine.gd")
const _ActionService = preload("res://scripts/action_core/ActionService.gd")
const _ActionUIBridge = preload("res://scripts/action_core/ActionUIBridge.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")

## AI 决策大脑（AI 玩家回合/响应决策）
const _AIController = preload("res://scripts/ai/ai_controller.gd")

## 保留的辅助服务
const _DeckService = preload("res://scripts/services/DeckService.gd")
const _MapService = preload("res://scripts/services/MapService.gd")
const _DamageTokenService = preload("res://scripts/services/DamageTokenService.gd")
const _EquipmentBreakService = preload("res://scripts/services/EquipmentBreakService.gd")
const _EventTimerService = preload("res://scripts/services/EventTimerService.gd")
const _VictoryService = preload("res://scripts/services/VictoryService.gd")
const _GameSetupService = preload("res://scripts/services/GameSetupService.gd")
const _RoundService = preload("res://scripts/services/RoundService.gd")
const _ShopService = preload("res://scripts/services/ShopService.gd")
const _MarkerService = preload("res://scripts/services/MarkerService.gd")
const _DeckBuildService = preload("res://scripts/services/DeckBuildService.gd")
const _TurnService = preload("res://scripts/services/TurnService.gd")
const _CardSetService = preload("res://scripts/services/CardSetService.gd")

## ── 兼容层：旧效果引擎（待重写后删除） ──
const _EffectEngine = preload("res://scripts/effect_core/EffectEngine.gd")
const _EffectRegistry = preload("res://scripts/effect_core/EffectRegistry.gd")

## 核心系统
var game_state = null
var game_actions = null
var card_database = null
var effect_engine = null
var effect_registry = null

## 同步随机源（PvP 锁步：双端同种子，保证执行相同输入产出相同状态）。
## 所有游戏逻辑随机必须走 context.rng，不得用全局 randi()/Array.shuffle()。
var rng: RandomNumberGenerator = null

## ── 数据加载器 ──
var registry = null  # 原有 JSON 加载器

## ── 新动作系统（主入口） ──
var action_engine = null
var action_registry = null
var timing_engine = null
var action_service = null
var action_ui_bridge = null

## ── AI 决策 ──
var ai_controller = null

## ── 保留的辅助服务 ──
var turn_service = null
var deck_service = null
var map_service = null
var damage_token_service = null
var equipment_break_service = null
var event_timer_service = null
var victory_service = null
var game_setup_service = null
var round_service = null
var shop_service = null
var marker_service = null
var deck_build_service = null
var card_set_service = null

## 是否已初始化
var _initialized: bool = false

## 逐格移动动画开关：仅 UI 模式（app_root _connect_action_signals）置 true。
## single_move 逐格 basic_move 完成后每格暂停 50ms 让棋盘逐格重绘（避免瞬移）。
## 测试模式不置位 -> 保持同步执行（不暂停），测试断言移动结果不受动画影响。
## PvP 双端都置位，双端各自按相同延迟 resume，不改状态、无锁步发散风险。
var move_animation_enabled: bool = false


## 初始化所有系统
func initialize(data_registry) -> void:
	# 0. 同步随机源（必须在建牌堆/任何随机前就绪）
	rng = RandomNumberGenerator.new()
	# 1. 创建核心状态
	game_state = _GameState.new()
	game_state.map_state = _MapState.new()
	game_state.deck_state = _DeckState.new()
	game_state.shop_state = _ShopState.new()

	# 2. 创建卡牌数据库
	card_database = _CardDatabase.new()
	card_database.load_all(data_registry)

	# 3. 创建原子操作层（被action_defs handler内部调用）
	game_actions = _GameActions.new()
	game_actions.context = self

	# 3.5 创建旧效果系统（用于兼容）
	effect_engine = _EffectEngine.new()
	effect_engine.context = self

	effect_registry = _EffectRegistry.new()
	effect_registry.context = self

	# 4. 创建新动作系统（主入口）
	action_engine = _ActionEngine.new()
	action_engine.context = self

	action_registry = _ActionRegistry.new()
	action_registry.context = self

	timing_engine = _TimingEngine.new()
	timing_engine.context = self

	action_service = _ActionService.new()
	action_service.context = self
	action_service.init_factories()

	action_ui_bridge = _ActionUIBridge.new()
	action_ui_bridge.context = self
	action_ui_bridge.setup()

	# 4.5 创建 AI 决策大脑
	ai_controller = _AIController.new()
	ai_controller.context = self

	# 5. 创建保留的辅助服务
	turn_service = _TurnService.new()
	turn_service.context = self

	deck_service = _DeckService.new()
	deck_service.context = self

	map_service = _MapService.new()
	map_service.context = self

	damage_token_service = _DamageTokenService.new()
	damage_token_service.context = self

	equipment_break_service = _EquipmentBreakService.new()
	equipment_break_service.context = self

	event_timer_service = _EventTimerService.new()
	event_timer_service.context = self

	victory_service = _VictoryService.new()
	victory_service.context = self

	game_setup_service = _GameSetupService.new()
	game_setup_service.context = self

	round_service = _RoundService.new()
	round_service.context = self

	shop_service = _ShopService.new()
	shop_service.context = self

	marker_service = _MarkerService.new()
	marker_service.context = self

	deck_build_service = _DeckBuildService.new()
	deck_build_service.context = self

	card_set_service = _CardSetService.new()
	card_set_service.context = self

	# 6. 注册永久监听器（状态效果等）
	_register_permanent_listeners()

	# 7. 保存 DataRegistry 引用
	registry = data_registry

	_initialized = true


## 设置同步随机种子（PvP 锁步：双端必须在 start_tutorial 前设同一种子）
func set_rng_seed(seed_value: int) -> void:
	if rng == null:
		rng = RandomNumberGenerator.new()
	rng.seed = seed_value


## 同步洗牌（Fisher-Yates，走 context.rng）。
## Array.shuffle() 用全局 RNG，锁步下双端会分叉，故所有游戏逻辑洗牌必须走此方法。
func synced_shuffle(arr: Array) -> Array:
	if rng == null:
		rng = RandomNumberGenerator.new()
	var n := arr.size()
	for i in range(n - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
	return arr


## 同步随机整数 [from, to] 含两端
func synced_randi_range(from: int, to: int) -> int:
	if rng == null:
		rng = RandomNumberGenerator.new()
	return rng.randi_range(from, to)


## 注册永久监听器到TimingEngine
## 状态效果（聚能/联合/锁定/折扣）改为按需注册临时监听器，
## 在施加状态时注册、移除状态时注销，不再作为永久监听器。
func _register_permanent_listeners() -> void:
	# 状态效果不再作为永久监听器注册
	# 它们将在 add_status 时按需注册为临时监听器，
	# 在 remove_status 时自动注销
	pass


## ── 手牌 AVAILABILITY 效果注册 ──


## 当行动牌进入手牌时，注册其 AVAILABILITY 效果为临时监听器
## 同时确保 card.mech_id / owner_player_id 已正确指向持有者机甲，
## 否则 AVAIL_RESPOND_ATTACK 的可用条件（target_id == card.mech_id）将永远不成立，
## 导致被攻击时响应窗口不弹出。
func register_hand_card_availability(card_instance_id: StringName) -> void:
	var card = game_state.get_card(card_instance_id)
	if card == null or card.def == null:
		return
	# 行动牌才注册（装备牌不走 AVAILABILITY 响应窗口）
	if card.def.card_kind != &"action":
		return
	# 确定持有者玩家：优先用 card.owner_player_id；
	# 退回通过 card.mech_id 反查；
	# 再退回扫描所有玩家 action_hand（TurnService.draw_from_deck 抽出的牌
	# owner_player_id 与 mech_id 均为空，必须靠手牌数组定位持有者，
	# 否则提前 return 导致迎击牌的响应窗口监听器永不注册——被攻击时无响应）。
	var player_id: StringName = card.owner_player_id
	if player_id == &"" and card.mech_id != &"":
		var holder_player = game_state.get_player_for_mech(card.mech_id)
		player_id = holder_player.player_id if holder_player != null else &""
	if player_id == &"":
		player_id = _find_player_holding_card(card_instance_id)
	if player_id == &"":
		return
	var holder_mech = game_state.get_mech_for_player(player_id)
	if holder_mech == null:
		return
	# 写入 mech_id / owner_player_id，供 AVAIL_RESPOND_ATTACK 精确匹配被攻击目标
	card.owner_player_id = player_id
	card.mech_id = holder_mech.mech_id
	var card_mappings: Array = GeneratedActionEffects.get_effects_for_card(card.def.card_id)
	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()
	for mapping in card_mappings:
		var effect_id: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
		var effect: ActionEffect = all_effects.get(effect_id)
		if effect and effect.mode == "AVAILABILITY":
			# AVAILABILITY效果需要监听特定时点（如ATTACK_AT）
			var timing: StringName = effect.listen_timing if effect.listen_timing != &"" else _TimingConst.ATTACK_AT
			timing_engine.register_availability_listener(
				timing,
				&"",  # 不绑定到特定action_id
				effect,
				card_instance_id
			)
		elif effect and effect.mode == "LISTEN" and effect.permanent_while_in_hand and effect.listen_timing != &"":
			# 手牌期永久监听器（如推进 effect2：持有者使用迎击牌时触发）。
			# 绑定 card_instance_id 供离开手牌时 unregister_listeners_for_card 注销。
			timing_engine.register_permanent_listener(effect.listen_timing, effect, {
				"card_instance_id": card_instance_id,
				"player_id": player_id,
				"mech_id": holder_mech.mech_id,
			})


## 当行动牌离开手牌时，注销其 AVAILABILITY 效果
func unregister_hand_card_availability(card_instance_id: StringName) -> void:
	if timing_engine != null:
		timing_engine.unregister_listeners_for_card(card_instance_id)


## 批量注册玩家手牌中的所有 AVAILABILITY 效果
func register_all_hand_availability(player_id: StringName) -> void:
	var player = game_state.players.get(player_id)
	if player == null:
		return
	for card_id: StringName in player.action_hand:
		register_hand_card_availability(card_id)


## 通过扫描所有玩家的 action_hand 定位持有该牌的玩家
## 用于 owner_player_id / mech_id 均未设置的抽牌路径（TurnService.draw_from_deck）
func _find_player_holding_card(card_instance_id: StringName) -> StringName:
	for pid: StringName in game_state.players:
		var player = game_state.players.get(pid)
		if player != null and player.action_hand.has(card_instance_id):
			return pid
	return &""


## ── 兼容属性（逐步废弃，过渡期使用） ──
## （card_set_service 已移至保留辅助服务区域）
