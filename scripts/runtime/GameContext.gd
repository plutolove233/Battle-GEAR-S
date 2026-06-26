## GameContext.gd — 依赖注入容器
##
## GameContext 替代 Autoload，持有所有运行时对象的引用。
## 所有 Service 通过 context 引用访问其他系统。
## 由 BattleState 创建和初始化，传入 DataRegistry。
class_name GameContext
extends RefCounted

const _GameState = preload("res://scripts/runtime/GameState.gd")
const _EffectRegistry = preload("res://scripts/effect_core/EffectRegistry.gd")
const _EffectEngine = preload("res://scripts/effect_core/EffectEngine.gd")
const _GameActions = preload("res://scripts/effect_core/GameActions.gd")
const _CardDatabase = preload("res://scripts/generated_database/CardDatabase.gd")
const _MapState = preload("res://scripts/runtime/MapState.gd")
const _DeckState = preload("res://scripts/runtime/DeckState.gd")
const _ShopState = preload("res://scripts/runtime/ShopState.gd")
const _TurnService = preload("res://scripts/services/TurnService.gd")
const _AttackService = preload("res://scripts/services/AttackService.gd")
const _CardPlayService = preload("res://scripts/services/CardPlayService.gd")
const _CardSetService = preload("res://scripts/services/CardSetService.gd")
const _DeckService = preload("res://scripts/services/DeckService.gd")
const _MapService = preload("res://scripts/services/MapService.gd")
const _DamageTokenService = preload("res://scripts/services/DamageTokenService.gd")
const _EquipmentBreakService = preload("res://scripts/services/EquipmentBreakService.gd")
const _EventTimerService = preload("res://scripts/services/EventTimerService.gd")
const _VictoryService = preload("res://scripts/services/VictoryService.gd")
const _GameSetupService = preload("res://scripts/services/GameSetupService.gd")
const _GameFlowService = preload("res://scripts/services/GameFlowService.gd")
const _RoundService = preload("res://scripts/services/RoundService.gd")
const _PlayerActionService = preload("res://scripts/services/PlayerActionService.gd")
const _AttackRuleChecker = preload("res://scripts/services/AttackRuleChecker.gd")
const _ShopService = preload("res://scripts/services/ShopService.gd")
const _MarkerService = preload("res://scripts/services/MarkerService.gd")
const _DeckBuildService = preload("res://scripts/services/DeckBuildService.gd")

## ── 核心系统 ──
var game_state = null
var effect_registry = null
var effect_engine = null
var game_actions = null
var card_database = null

## ── 数据加载器 ──
var registry = null  # 原有 JSON 加载器

## ── 服务层 ──
var turn_service = null
var attack_service = null
var card_play_service = null
var card_set_service = null
var deck_service = null
var map_service = null
var damage_token_service = null
var equipment_break_service = null
var event_timer_service = null
var victory_service = null
var game_setup_service = null
var game_flow_service = null
var round_service = null
var player_action_service = null
var attack_rule_checker = null
var shop_service = null
var marker_service = null
var deck_build_service = null

## 是否已初始化
var _initialized: bool = false


## 初始化所有系统
func initialize(data_registry) -> void:
	# 1. 创建核心状态
	game_state = _GameState.new()
	game_state.map_state = _MapState.new()
	game_state.deck_state = _DeckState.new()
	game_state.shop_state = _ShopState.new()

	# 2. 创建卡牌数据库
	card_database = _CardDatabase.new()
	card_database.load_all(data_registry)

	# 3. 创建效果核心系统
	effect_registry = _EffectRegistry.new()
	effect_registry.context = self

	effect_engine = _EffectEngine.new()
	effect_engine.context = self

	game_actions = _GameActions.new()
	game_actions.context = self

	# 4. 创建服务层
	turn_service = _TurnService.new()
	turn_service.context = self

	attack_service = _AttackService.new()
	attack_service.context = self

	card_play_service = _CardPlayService.new()
	card_play_service.context = self

	card_set_service = _CardSetService.new()
	card_set_service.context = self

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

	game_flow_service = _GameFlowService.new()
	game_flow_service.context = self

	# 5. 新增服务层
	round_service = _RoundService.new()
	round_service.context = self

	player_action_service = _PlayerActionService.new()
	player_action_service.context = self

	attack_rule_checker = _AttackRuleChecker.new()
	attack_rule_checker.context = self

	shop_service = _ShopService.new()
	shop_service.context = self

	marker_service = _MarkerService.new()
	marker_service.context = self

	deck_build_service = _DeckBuildService.new()
	deck_build_service.context = self

	# 6. 保存 DataRegistry 引用
	registry = data_registry

	_initialized = true
