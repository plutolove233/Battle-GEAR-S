extends Control

const _DataRegistry = preload("res://scripts/data/data_registry.gd")
const _CampaignState = preload("res://scripts/campaign/campaign_state.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _BattleMessageLog = preload("res://scripts/ui/battle_message_log.gd")
const _EnemyInfoPopup = preload("res://scripts/ui/enemy_info_popup.gd")
const _AttackFlowController = preload("res://scripts/ui/attack_flow_controller.gd")
const _WeaponPickerPanel = preload("res://scripts/ui/weapon_picker_panel.gd")
const _DamagePlacementPanel = preload("res://scripts/ui/damage_placement_panel.gd")
const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")
const _DiscardSelectPanel = preload("res://scripts/ui/discard_select_panel.gd")
const _DeckInfoPopup = preload("res://scripts/ui/deck_info_popup.gd")

var registry = null  # type: DataRegistry
var campaign = null  # type: CampaignState
var battle = null  # type: BattleState
var selected_equipment: Dictionary = {}
var current_selection_cards: Array = []
var current_screen: Control
var status_label: Label
var battle_summary_label: Label
var battle_board = null  # type: BattleBoard
var hand_panel = null  # type: HandPanel
var equipment_panel = null  # type: EquipmentPanel
var skill_bar = null  # type: SkillBar
var response_panel = null  # type: ResponsePanel
var message_log = null  # type: BattleMessageLog
var enemy_info_popup = null  # type: EnemyInfoPopup

## 攻击流程控制器
var attack_flow: RefCounted = null  # type: AttackFlowController
## 武器选择面板
var weapon_picker_panel = null  # type: WeaponPickerPanel
## 损伤放置面板
var damage_placement_panel = null  # type: DamagePlacementPanel
## 效果选择面板（维修等二选一卡牌）
var choice_panel = null  # type: ChoicePanel
## 取消攻击按钮
var cancel_attack_button = null  # type: Button
## 辅助牌目标选择状态：正在选择目标的辅助牌ID
var _support_target_select_card_id: StringName = &""
## 辅助牌武器选择状态：正在选择武器的辅助牌ID（如聚能）
var _support_weapon_select_card_id: StringName = &""
## 辅助牌效果选择状态：正在选择效果的辅助牌ID
var _choice_select_card_id: StringName = &""
## 弃牌选择面板
var discard_select_panel = null  # type: DiscardSelectPanel
## 牌堆信息弹窗
var deck_info_popup = null  # type: DeckInfoPopup
## 弃牌选择状态：正在弃牌的辅助牌ID
var _discard_select_card_id: StringName = &""
## 弃牌选择状态：弃牌信息
var _discard_select_pending: Dictionary = {}
## 武器槽位选择状态：正在选择替换哪个武器槽的装备牌ID
var _weapon_slot_select_card_id: StringName = &""
## 维修目标选择状态：正在选择维修目标的维修牌ID
var _repair_target_select_card_id: StringName = &""
## 维修已选目标机甲ID（打出时注入 payload，空表示默认以自身机甲为目标）
var _repair_selected_target_mech_id: StringName = &""
## 迎击移动状态：正在进行回避/疾行/反击的移动选格（玩家为防守方时）
var _evade_movement_active: bool = false
## 强袭移动状态：玩家(攻击方)正在用当前动力选格移动（强袭效果）
var _assault_movement_active: bool = false
## 反击状态：玩家正在选择是否发动反击（attack2）
var _counterattack_prompt_active: bool = false
## 反击状态：玩家正在选择反击武器（attack2）
var _counterattack_weapon_select_active: bool = false
## 反击状态：玩家正在选择反击目标机甲（attack2，选定武器后选范围内1台机甲）
var _counterattack_target_select_active: bool = false
## 反击已选武器 instance_id（attack2 目标选择阶段使用）
var _counterattack_weapon_id: StringName = &""
## 当前待处理的反击 pending（attack2）
var _counterattack_pending: Dictionary = {}
## 反击上下文：反击发生在哪一方的回合 ("player"/"enemy")
var _counterattack_turn: String = ""
## AI反击(玩家回合)状态：等待玩家对 attack2 进行迎击
var _ai_counterattack_active: bool = false
## 玩家回合内最近一次攻击(attack1)的结算结果，用于在其损伤放置完成后触发AI反击
var _last_player_attack_result: Dictionary = {}

func _ready() -> void:
	_load_app_state()

func _load_app_state() -> void:
	registry = _DataRegistry.new()
	var load_result = registry.load_all()
	if not _status_ok(load_result):
		_show_error("资料载入失败: %s" % _status_message(load_result))
		return
	campaign = _CampaignState.new()
	var init_result = campaign.initialize(registry)
	if not _status_ok(init_result):
		_show_error("战役初始化失败: %s" % _status_message(init_result))
		return
	selected_equipment = {}
	_show_main_menu()

# ═══════════════════════════════════════════
# 主菜单
# ═══════════════════════════════════════════

func _show_main_menu() -> void:
	var layout := _begin_screen("机斗战甲")
	_add_button(layout, "新战役", Callable(self, "_show_loadout"))
	_add_button(layout, "图鉴", Callable(self, "_show_collection"))
	_add_button(layout, "退出", Callable(self, "_quit_app"))

# ═══════════════════════════════════════════
# 出击准备
# ═══════════════════════════════════════════

func _show_loadout() -> void:
	# 随机抽取4张装备（至少1张武器）
	current_selection_cards = campaign.generate_random_equipment_selection(4, 1)
	selected_equipment.clear()
	_render_loadout_screen()

func _render_loadout_screen() -> void:
	var layout := _begin_screen("出击准备")
	var pilot: Dictionary = campaign.selected_pilot
	_add_text(layout, "机师: %s" % String(pilot.get("name", "克劳德")))
	_add_text(layout, "从以下装备中选择（随机4张，至少1张武器）:")
	for item in current_selection_cards:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var id := String(item.get("id", ""))
		if id == "":
			continue
		var checkbox := CheckBox.new()
		checkbox.text = _equipment_label(item)
		checkbox.button_pressed = bool(selected_equipment.get(id, false))
		checkbox.toggled.connect(Callable(self, "_on_equipment_toggled").bind(id))
		layout.add_child(checkbox)
	_add_button(layout, "重新随机", Callable(self, "_reroll_selection"))
	_add_button(layout, "开始教学战斗", Callable(self, "_start_tutorial_battle"))
	_add_button(layout, "返回", Callable(self, "_show_main_menu"))

func _reroll_selection() -> void:
	current_selection_cards = campaign.generate_random_equipment_selection(4, 1)
	selected_equipment.clear()
	_render_loadout_screen()

func _start_tutorial_battle() -> void:
	var ids: Array[String] = []
	for id in selected_equipment.keys():
		if bool(selected_equipment[id]):
			ids.append(String(id))
	var selection_result = campaign.select_equipment(ids)
	if not _status_ok(selection_result):
		_show_status("装备选择失败: %s" % _status_message(selection_result))
		return
	var context = campaign.build_tutorial_context()
	if not _status_ok(context):
		_show_status("战役上下文失败: %s" % _status_message(context))
		return
	battle = _BattleState.new()
	battle.pre_selected_equipment = ids
	var start_result = battle.start_tutorial(registry)
	if not _status_ok(start_result):
		_show_status("战斗启动失败: %s" % _status_message(start_result))
		return
	var turn_result = battle.start_turn("player")
	if not _status_ok(turn_result):
		battle.log.append({"message": "玩家回合启动失败", "details": {"reason": _status_message(turn_result)}})
	_show_battle()

# ═══════════════════════════════════════════
# 战斗界面 — 左右分区布局
# ═══════════════════════════════════════════

func _show_battle() -> void:
	var layout := _begin_screen("教学战斗")

	# ── 状态栏 ──
	battle_summary_label = Label.new()
	battle_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(battle_summary_label)

	# ── 主区域：左边地图 + 右边信息面板 ──
	var main_hbox := HBoxContainer.new()
	main_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hbox.add_theme_constant_override("separation", 4)
	layout.add_child(main_hbox)

	# 左侧：地图
	battle_board = BattleBoard.new()
	battle_board.custom_minimum_size = Vector2(0, 0)
	battle_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	battle_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	battle_board.hex_clicked.connect(Callable(self, "_on_battle_hex_clicked"))
	main_hbox.add_child(battle_board)

	# 右侧：装备面板 + 技能栏 + 消息日志
	var right_panel := VBoxContainer.new()
	right_panel.custom_minimum_size = Vector2(280, 0)
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hbox.add_child(right_panel)

	equipment_panel = EquipmentPanel.new()
	equipment_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	equipment_panel.custom_minimum_size = Vector2(0, 200)
	right_panel.add_child(equipment_panel)

	skill_bar = SkillBar.new()
	skill_bar.active_effect_clicked.connect(Callable(self, "_on_active_effect_clicked"))
	right_panel.add_child(skill_bar)

	# 消息日志（右侧面板底部，占据剩余空间）
	message_log = _BattleMessageLog.new()
	message_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_panel.add_child(message_log)

	# ── 手牌区 ──
	hand_panel = HandPanel.new()
	hand_panel.action_card_clicked.connect(Callable(self, "_on_action_card_clicked"))
	hand_panel.equipment_card_clicked.connect(Callable(self, "_on_equipment_card_clicked"))
	layout.add_child(hand_panel)

	# ── 操作栏 ──
	var action_bar := HBoxContainer.new()
	action_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_child(action_bar)
	_add_button(action_bar, "结束回合", Callable(self, "_end_player_turn"))
	_add_button(action_bar, "敌方信息", Callable(self, "_on_enemy_info_clicked"))
	_add_button(action_bar, "牌堆信息", Callable(self, "_on_deck_info_clicked"))
	_add_button(action_bar, "返回主菜单", Callable(self, "_show_main_menu"))

	# ── 取消攻击按钮（初始隐藏）──
	cancel_attack_button = Button.new()
	cancel_attack_button.text = "取消攻击"
	cancel_attack_button.custom_minimum_size = Vector2(140, 32)
	cancel_attack_button.visible = false
	cancel_attack_button.pressed.connect(Callable(self, "_on_cancel_attack"))
	layout.add_child(cancel_attack_button)

	# ── 敌方信息弹窗（初始隐藏）──
	enemy_info_popup = _EnemyInfoPopup.new()
	add_child(enemy_info_popup)

	# ── 牌堆信息弹窗（初始隐藏）──
	deck_info_popup = _DeckInfoPopup.new()
	add_child(deck_info_popup)
	# ── 迎击面板（初始隐藏）──
	response_panel = ResponsePanel.new()
	response_panel.response_selected.connect(Callable(self, "_on_response_selected"))
	response_panel.response_passed.connect(Callable(self, "_on_response_passed"))
	response_panel.visible = false
	layout.add_child(response_panel)

	# ── 武器选择面板（初始隐藏）──
	weapon_picker_panel = _WeaponPickerPanel.new()
	weapon_picker_panel.weapon_selected.connect(Callable(self, "_on_weapon_selected"))
	weapon_picker_panel.selection_cancelled.connect(Callable(self, "_on_weapon_selection_cancelled"))
	weapon_picker_panel.visible = false
	layout.add_child(weapon_picker_panel)

	# ── 损伤放置面板（初始隐藏）──
	damage_placement_panel = _DamagePlacementPanel.new()
	damage_placement_panel.placement_completed.connect(Callable(self, "_on_damage_placement_completed"))
	damage_placement_panel.visible = false
	layout.add_child(damage_placement_panel)

	# ── 效果选择面板（初始隐藏）──
	var _ChoicePanel = preload("res://scripts/ui/choice_panel.gd")
	choice_panel = _ChoicePanel.new()
	choice_panel.choice_made.connect(Callable(self, "_on_choice_made"))
	choice_panel.choice_cancelled.connect(Callable(self, "_on_choice_cancelled"))
	choice_panel.visible = false
	layout.add_child(choice_panel)

	# ── 弃牌选择面板（初始隐藏）──
	discard_select_panel = _DiscardSelectPanel.new()
	discard_select_panel.selection_completed.connect(Callable(self, "_on_discard_selection_completed"))
	discard_select_panel.visible = false
	layout.add_child(discard_select_panel)

	# ── 连接 EffectEngine hook 信号 ──
	if battle.context and battle.context.effect_engine:
		battle.context.effect_engine.hook_fired.connect(Callable(self, "_on_hook_fired"))

	# 初始化攻击流程控制器
	attack_flow = _AttackFlowController.new()

	# 初始配置消息日志（追赶历史日志）
	if message_log and battle.context:
		message_log.configure(battle.context)

	_refresh_battle()

# ═══════════════════════════════════════════
# 战斗交互
# ═══════════════════════════════════════════

	## 点击地图格子
func _on_battle_hex_clicked(hex: Dictionary) -> void:
	if battle == null:
		return

	# 如果在迎击移动模式（回避/疾行/反击），执行移动后结算原攻击
	if _evade_movement_active:
		_execute_evade_movement(hex)
		return

	# 如果在强袭移动模式（玩家为攻击方，强袭效果），执行移动后结算原攻击
	if _assault_movement_active:
		_execute_assault_movement(hex)
		return

	# 如果在反击目标选择模式（玩家反击 attack2），选择该位置上的机甲
	if _counterattack_target_select_active:
		_select_counterattack_target(hex)
		return

	# 如果在辅助牌目标选择模式，选择该位置上的机甲
	if _support_target_select_card_id != &"":
		_select_support_target(hex)
		return

	# 如果在维修目标选择模式，选择该位置上的机甲（自身或1格范围内）
	if _repair_target_select_card_id != &"":
		_select_repair_target(hex)
		return

	# 如果在攻击目标选择模式，尝试攻击该位置上的机甲
	if attack_flow.current_state == _AttackFlowController.SELECT_TARGET:
		_try_attack_target(hex)
		return

	# 否则尝试移动
	var result = battle.move_unit("player", hex)
	SessionLogger.log_call("app_root", "move_unit", {"player": "player", "hex": hex}, result)
	if not _status_ok(result):
		battle.log.append({"message": "无法移动", "details": {"reason": _status_message(result)}})
	_refresh_battle()

	## 点击行动牌
func _on_action_card_clicked(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	if not card or not card.def:
		return

	# 判断行动牌类型
	var action_type: String = String(card.def.action_type)
	match action_type:
		"攻击":
			_enter_attack_mode(card_id)
		"迎击":
			battle.log.append({"message": "迎击牌在响应窗口自动使用", "details": {}})
		"辅助":
			# 检查是否为掩护牌（不能主动打出）
			if _is_cover_card(card):
				battle.log.append({"message": "掩护牌只能在响应窗口中使用", "details": {}})
				_refresh_battle()
				return
			# 检查是否有二选一效果（如维修）
			if _is_repair_card(card):
				_handle_repair_play(card_id)
			elif _support_card_has_choose_one(card):
				_enter_choice_select(card_id)
			# 检查是否需要选择武器（如聚能）
			elif _support_card_needs_weapon(card):
				_enter_support_weapon_select(card_id)
			# 检查是否需要选择目标
			elif _support_card_needs_target(card):
				_enter_support_target_select(card_id)
			else:
				_play_action_card(card_id)

## 点击装备牌
func _on_equipment_card_clicked(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	if not card or not card.def:
		return

	# 自动选择槽位并设置装备
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	if not player or not mech:
		return

	var slot_id: StringName = &""
	if card.def.equipment_kind == &"PART":
		slot_id = card.def.slot
	elif card.def.equipment_kind == &"WEAPON":
		# 查找空武器槽
		for ws_id: StringName in [&"weapon_1", &"weapon_2"]:
			if mech.slots.has(ws_id) and not mech.slots[ws_id].equipped_card:
				slot_id = ws_id
				break
		# 两个武器槽都有装备，让玩家选择替换哪个
		if slot_id == &"":
			_enter_weapon_slot_select(card_id)
			return

	if slot_id == &"":
		battle.log.append({"message": "无可用槽位", "details": {}})
		_refresh_battle()
		return

	_do_set_equipment(card_id, slot_id)

## 进入武器槽位选择模式（两个武器槽都有装备时）
func _enter_weapon_slot_select(card_id: StringName) -> void:
	_weapon_slot_select_card_id = card_id
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if not mech:
		return
	# 显示当前两个武器槽的装备，让玩家选择替换哪个
	var weapon_ids: Array[StringName] = mech.get_weapon_ids()
	weapon_picker_panel.configure(battle.context, weapon_ids, "── 选择要替换的武器 ──")
	weapon_picker_panel.visible = true
	battle.log.append({"message": "选择要替换的武器槽", "details": {}})
	_show_cancel_button(true)
	_refresh_battle()


## 武器槽位选择回调（复用 weapon_selected 信号，但此时是选择替换哪个槽）
func _on_weapon_slot_selected_for_equipment(weapon_id: StringName) -> void:
	weapon_picker_panel.visible = false
	_show_cancel_button(false)
	var card_id: StringName = _weapon_slot_select_card_id
	_weapon_slot_select_card_id = &""
	if card_id == &"":
		_refresh_battle()
		return
	# 找到选中武器所在的槽位
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if not mech:
		_refresh_battle()
		return
	var target_slot_id: StringName = &""
	for slot_id: StringName in [&"weapon_1", &"weapon_2"]:
		if mech.slots.has(slot_id) and mech.slots[slot_id].equipped_card:
			if mech.slots[slot_id].equipped_card.instance_id == weapon_id:
				target_slot_id = slot_id
				break
	if target_slot_id == &"":
		battle.log.append({"message": "未找到对应武器槽", "details": {}})
		_refresh_battle()
		return
	_do_set_equipment(card_id, target_slot_id)


## 实际执行装备设置
func _do_set_equipment(card_id: StringName, slot_id: StringName) -> void:
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", card_id, slot_id)
	SessionLogger.log_call("app_root", "set_equipment", {"player": "player", "card_id": String(card_id), "slot_id": String(slot_id)}, result)
	if result.get("ok", false):
		battle.log.append({"message": "装备了 %s" % (card.def.display_name if card and card.def else String(card_id)), "details": {}})
	else:
		battle.log.append({"message": "装备失败: %s" % String(result.get("message", "")), "details": {}})
	_refresh_battle()


## 点击主动效果按钮
func _on_active_effect_clicked(effect_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var bindings = battle.context.effect_registry.get_all_active_bindings()
	for binding in bindings:
		if binding.effect.effect_id == effect_id:
			var success: bool = battle.context.effect_engine.use_active_effect(
				binding.get_source_instance_id(), effect_id, {}
			)
			SessionLogger.log_call("app_root", "use_active_effect", {"effect_id": String(effect_id)}, success)
			if success:
				battle.log.append({"message": "使用了技能: %s" % binding.effect.display_name, "details": {}})
			else:
				battle.log.append({"message": "技能使用失败", "details": {}})
			break
	_refresh_battle()

## 结束玩家回合
func _end_player_turn() -> void:
	if battle == null:
		return
	_cancel_attack_mode()

	# 回合结束时，若行动牌超过上限，由玩家选择弃置哪些牌
	if battle.context and battle.context.game_state:
		var player = battle.context.game_state.players.get(&"player")
		if player != null and player.action_hand.size() > player.action_card_limit:
			var excess: int = player.action_hand.size() - player.action_card_limit
			_show_discard_select_panel_for_pending({
				"reason": &"END_TURN_HAND_LIMIT",
				"discard_player_id": &"player",
				"count": excess,
				"face_up": true,
				"card_type_filter": &"",
			})
			return

	_finish_player_turn()


## 实际执行结束回合流程（弃牌选择完成后调用）
func _finish_player_turn() -> void:
	var result = battle.end_player_turn()
	SessionLogger.log_call("app_root", "end_player_turn", {}, result)
	if not _status_ok(result):
		battle.log.append({"message": "结束回合失败", "details": {"reason": _status_message(result)}})
	_refresh_battle()
	_finish_battle_if_needed()
	if get_result_state() != "active":
		return

	# 开始敌方回合（多步式）
	_start_enemy_turn_flow()

## 敌方回合流程
func _start_enemy_turn_flow() -> void:
	var result = battle.start_enemy_turn()

	match result.get("state", ""):
		"awaiting_player_response":
			# 敌方攻击了我方，需要玩家选择迎击
			_show_response_panel(result)
		"awaiting_damage_placement":
			# 需要玩家选择损伤放置
			_show_damage_placement(result)
		"done", "battle_over":
			_refresh_battle()
			_finish_battle_if_needed()
		_:
			_refresh_battle()
			_finish_battle_if_needed()

## 迎击选择
func _on_response_selected(card_id: StringName) -> void:
	if battle == null:
		return

	# AI反击(attack2)的迎击响应：玩家正在对 AI 发动的反击进行迎击
	if _ai_counterattack_active:
		var ai_result = battle.handle_response(battle.current_attack_id, card_id)
		response_panel.visible = false
		_ai_counterattack_active = false
		_handle_ai_counterattack_resolved(ai_result)
		return

	# 提交迎击
	var result = battle.handle_response(battle.current_attack_id, card_id)
	response_panel.visible = false

	# 回避/疾行/反击：迎击后需要先移动再结算
	if result.get("state", "") == "awaiting_evade_movement":
		_enter_evade_movement_mode()
		return

	# 无需移动 → 结算结果已就绪，检查反击或继续敌方回合
	_after_enemy_attack_resolved(result)

## 跳过迎击
func _on_response_passed() -> void:
	if battle == null:
		return

	# AI反击(attack2)的迎击跳过
	if _ai_counterattack_active:
		var ai_result = battle.handle_response(battle.current_attack_id, &"")
		response_panel.visible = false
		_ai_counterattack_active = false
		_handle_ai_counterattack_resolved(ai_result)
		return

	# 跳过迎击
	var result = battle.handle_response(battle.current_attack_id, &"")
	response_panel.visible = false

	if result.get("state", "") == "awaiting_evade_movement":
		_enter_evade_movement_mode()
		return

	_after_enemy_attack_resolved(result)

## 迎击/跳过后继续敌方回合
func _continue_enemy_turn_after_response(resolve_result: Dictionary) -> void:
	var result = battle.continue_enemy_turn_after_response(resolve_result)

	match result.get("state", ""):
		"awaiting_damage_placement":
			_show_damage_placement(result)
		"done", "battle_over":
			_refresh_battle()
			_finish_battle_if_needed()
		_:
			_refresh_battle()
			_finish_battle_if_needed()


# ═══════════════════════════════════════════
# 迎击移动（回避/疾行/反击）与反击(attack2)
# ═══════════════════════════════════════════

## 进入迎击移动模式：高亮可达格子，等待玩家点击
func _enter_evade_movement_mode() -> void:
	_evade_movement_active = true
	var gs = battle.context.game_state
	var attack_context: Dictionary = gs.attacks.get(battle.current_attack_id, {})
	var target_id: StringName = attack_context.get("target_id", &"")
	var target_mech = gs.mechs.get(target_id)
	if target_mech == null:
		_evade_movement_active = false
		return
	var budget: int = battle.get_evade_movement_budget()
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(
		target_mech.position, budget, gs.map_state.cells
	)
	# 允许停留原地（也算移动完成）
	reachable.append({"q": int(target_mech.position.get("q", 0)), "r": int(target_mech.position.get("r", 0))})
	if battle_board:
		battle_board.highlight_hexes(reachable)
	battle.log.append({"message": "迎击移动：使用 %d 动力选择移动目标格（可点击原地停留）" % budget, "details": {}})
	_show_cancel_button(true)
	_refresh_battle()


## 玩家在迎击移动模式下点击格子
func _execute_evade_movement(hex: Dictionary) -> void:
	var resolve_result: Dictionary = battle.execute_evade_movement(hex)
	if battle_board:
		battle_board.clear_highlight()
	_show_cancel_button(false)
	if not resolve_result.get("ok", true):
		# 移动失败 → 保持移动模式让玩家重选
		battle.log.append({"message": "无法移动到该格：%s" % String(resolve_result.get("message", "")), "details": {}})
		_enter_evade_movement_mode()
		return
	_evade_movement_active = false
	# P1-1: 迎击移动完成后，检查是否需要强袭移动
	if resolve_result.get("state", "") == "awaiting_assault_movement":
		_enter_assault_movement_mode()
		return
	_after_enemy_attack_resolved(resolve_result)


## 进入强袭移动模式：高亮当前动力可达格子，等待玩家点击
## 强袭效果在目标响应结算完成后发动：攻击方用当前动力移动，之后再结算本次攻击。
func _enter_assault_movement_mode() -> void:
	_assault_movement_active = true
	var gs = battle.context.game_state
	var attack_context: Dictionary = gs.attacks.get(battle.current_attack_id, {})
	var attacker_id: StringName = attack_context.get("attacker_id", &"")
	var attacker_mech = gs.mechs.get(attacker_id)
	if attacker_mech == null:
		_assault_movement_active = false
		return
	var budget: int = battle.get_assault_movement_budget()
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(
		attacker_mech.position, budget, gs.map_state.cells
	)
	# 允许停留原地（也算移动完成）
	reachable.append({"q": int(attacker_mech.position.get("q", 0)), "r": int(attacker_mech.position.get("r", 0))})
	if battle_board:
		battle_board.highlight_hexes(reachable)
	battle.log.append({"message": "强袭移动：使用 %d 动力选择移动目标格（可点击原地停留）" % budget, "details": {}})
	_show_cancel_button(true)
	_refresh_battle()


## 玩家在强袭移动模式下点击格子
func _execute_assault_movement(hex: Dictionary) -> void:
	var resolve_result: Dictionary = battle.execute_assault_movement(hex)
	if battle_board:
		battle_board.clear_highlight()
	if not resolve_result.get("ok", true):
		# 移动失败 → 保持移动模式让玩家重选
		_show_cancel_button(true)
		battle.log.append({"message": "无法移动到该格：%s" % String(resolve_result.get("message", "")), "details": {}})
		_enter_assault_movement_mode()
		return
	_show_cancel_button(false)
	_assault_movement_active = false
	_last_player_attack_result = resolve_result
	_handle_attack_result(resolve_result)
	# 若需玩家放置损伤，面板会处理；否则直接检查AI反击
	if not damage_placement_panel.visible:
		_maybe_trigger_ai_counterattack(resolve_result)
	_finish_battle_if_needed()


## 敌方攻击（攻击1）结算完成后的统一处理：检查玩家反击(attack2)，否则继续敌方回合
func _after_enemy_attack_resolved(resolve_result: Dictionary) -> void:
	# 检查玩家是否可发动反击(attack2)
	var pending: Dictionary = battle.get_counterattack_pending(resolve_result, &"player")
	if not pending.is_empty():
		_counterattack_pending = pending
		_counterattack_turn = "enemy"
		_prompt_player_counterattack()
		return
	# 无反击 → 走标准敌方回合延续（损伤放置/结束）
	_continue_enemy_turn_after_response(resolve_result)


## 询问玩家是否发动反击(attack2)
func _prompt_player_counterattack() -> void:
	if choice_panel == null:
		# 无选择面板则直接跳过
		_skip_player_counterattack()
		return
	_counterattack_prompt_active = true
	var options: Array[Dictionary] = [
		{"label": "发动反击", "effect_id": &"__counterattack_yes__"},
		{"label": "不发动", "effect_id": &"__counterattack_no__"},
	]
	choice_panel.configure(options)
	choice_panel.visible = true
	_refresh_battle()


## 玩家选择不发动反击 → 继续原攻击1的结算延续
func _skip_player_counterattack() -> void:
	_counterattack_prompt_active = false
	_counterattack_pending = {}
	# 攻击1本身没有 pending（反击是其唯一 pending），继续敌方回合
	# 以空命中结果延续，让标准流程处理损伤放置/结束
	_continue_enemy_turn_after_response({"hit": false, "markers": 0})


## 玩家确认发动反击 → 选择武器
func _begin_player_counterattack() -> void:
	_counterattack_prompt_active = false
	var gs = battle.context.game_state
	var source_mech_id: StringName = _counterattack_pending.get("source_mech_id", &"")
	var source_mech = gs.mechs.get(source_mech_id)
	if source_mech == null:
		_skip_player_counterattack()
		return
	var weapon_ids: Array[StringName] = source_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		battle.log.append({"message": "无机甲武器可用，无法发动反击", "details": {}})
		_skip_player_counterattack()
		return
	_counterattack_weapon_select_active = true
	if weapon_ids.size() == 1:
		_on_counterattack_weapon_selected(weapon_ids[0])
	else:
		weapon_picker_panel.configure(battle.context, weapon_ids, "── 反击：选择武器 ──")
		weapon_picker_panel.visible = true
	_refresh_battle()


## 反击武器选择完成 → 进入反击目标选择（选择范围内1台其他机甲）
func _on_counterattack_weapon_selected(weapon_id: StringName) -> void:
	_counterattack_weapon_select_active = false
	weapon_picker_panel.visible = false
	_counterattack_weapon_id = weapon_id
	_enter_counterattack_target_select()


## 进入反击目标选择模式：高亮反击方武器范围内除自身外的所有机甲
func _enter_counterattack_target_select() -> void:
	var gs = battle.context.game_state
	var source_mech_id: StringName = _counterattack_pending.get("source_mech_id", &"")
	var source_mech = gs.mechs.get(source_mech_id)
	if source_mech == null:
		_skip_player_counterattack()
		return
	var weapon_card = gs.get_card(_counterattack_weapon_id)
	var weapon_range: int = 1
	if weapon_card and weapon_card.def:
		weapon_range = weapon_card.def.range_value
	var highlights: Array[Dictionary] = []
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if mech_id == source_mech_id:
			continue
		if _RangeCalculator.is_in_weapon_range(source_mech.position, m.position, weapon_range, gs.map_state.cells):
			highlights.append(m.position)
	if highlights.is_empty():
		battle.log.append({"message": "反击范围内无机甲可攻击，取消反击", "details": {}})
		_skip_player_counterattack()
		return
	_counterattack_target_select_active = true
	if battle_board:
		battle_board.highlight_hexes(highlights)
	_show_cancel_button(true)
	battle.log.append({"message": "反击目标选择：点击范围内的1台机甲", "details": {}})
	_refresh_battle()


## 选择反击目标机甲 → 发动 attack2
func _select_counterattack_target(hex: Dictionary) -> void:
	if battle == null or battle.context == null:
		_counterattack_target_select_active = false
		return
	var gs = battle.context.game_state
	var source_mech_id: StringName = _counterattack_pending.get("source_mech_id", &"")
	var source_mech = gs.mechs.get(source_mech_id)
	if source_mech == null:
		_counterattack_target_select_active = false
		_skip_player_counterattack()
		return
	var weapon_card = gs.get_card(_counterattack_weapon_id)
	var weapon_range: int = 1
	if weapon_card and weapon_card.def:
		weapon_range = weapon_card.def.range_value
	# 查找点击位置上、在反击方武器范围内的机甲（除反击方自身）
	var target_mech_id: StringName = &""
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if mech_id == source_mech_id:
			continue
		if int(m.position.get("q", 0)) == int(hex.get("q", 0)) and int(m.position.get("r", 0)) == int(hex.get("r", 0)):
			if _RangeCalculator.is_in_weapon_range(source_mech.position, m.position, weapon_range, gs.map_state.cells):
				target_mech_id = mech_id
				break
	if target_mech_id == &"":
		battle.log.append({"message": "该位置无可用反击目标", "details": {}})
		_refresh_battle()
		return

	_counterattack_target_select_active = false
	_counterattack_weapon_id = &""
	if battle_board:
		battle_board.clear_highlight()
	_show_cancel_button(false)
	_counterattack_pending["weapon_id"] = _counterattack_weapon_id
	# 反击期间损伤放置完成应结束敌方回合
	battle.enemy_turn_phase = "awaiting_damage_placement"
	_counterattack_pending["weapon_id"] = weapon_card.instance_id if weapon_card else &""
	_counterattack_pending["target_id"] = target_mech_id
	var result: Dictionary = battle.begin_pending_counterattack(_counterattack_pending)
	_refresh_battle()
	if not result.get("ok", false):
		battle.log.append({"message": "反击发动失败：%s" % String(result.get("message", "")), "details": {}})
		_finish_enemy_turn_after_counterattack()
		return
	# attack2 由AI自动迎击并结算，state 应为 resolved；极少数情况交由响应面板
	if result.get("state", "") == "awaiting_player_response":
		_show_response_panel(result)
		return
	_handle_attack_result(result)
	# 若需玩家放置损伤，面板会处理；否则直接结束敌方回合
	if not damage_placement_panel.visible:
		_finish_enemy_turn_after_counterattack()


## 反击(attack2)结算后结束敌方回合
func _finish_enemy_turn_after_counterattack() -> void:
	_counterattack_pending = {}
	_counterattack_turn = ""
	# finish_enemy_turn 会结束敌方回合、检查胜负并在战斗继续时开启玩家回合
	battle.finish_enemy_turn()
	_refresh_battle()
	_finish_battle_if_needed()


## AI反击(attack2)已结算（玩家回合内）：处理损伤放置，然后继续玩家回合
func _handle_ai_counterattack_resolved(resolve_result: Dictionary) -> void:
	attack_flow.reset()
	_handle_attack_result(resolve_result)
	_refresh_battle()
	_finish_battle_if_needed()


## 玩家回合：玩家发动的攻击结算后，检查 AI 是否反击(attack2)
func _maybe_trigger_ai_counterattack(resolve_result: Dictionary) -> void:
	var pending: Dictionary = battle.get_counterattack_pending(resolve_result, &"enemy")
	if pending.is_empty():
		return
	# AI 反击选择目标：反击的附加攻击是另一次普通攻击，需选择反击方武器范围内的1台机甲。
	# 优先原攻击者，若不在范围内则选范围内其他机甲，否则放弃反击。
	var gs = battle.context.game_state
	var source_mech_id: StringName = pending.get("source_mech_id", &"")
	var source_mech = gs.mechs.get(source_mech_id)
	if source_mech != null:
		var weapon_ids: Array[StringName] = source_mech.get_weapon_ids()
		var weapon_id: StringName = pending.get("weapon_id", &"")
		if weapon_id == &"" or not weapon_ids.has(weapon_id):
			weapon_id = weapon_ids[0] if not weapon_ids.is_empty() else &""
		if weapon_id == &"":
			battle.log.append({"message": "AI反击无机甲武器可用，取消反击", "details": {}})
			return
		var wcard = gs.get_card(weapon_id)
		var wrange: int = 1
		if wcard and wcard.def:
			wrange = wcard.def.range_value
		var target_id: StringName = &""
		var default_target: StringName = pending.get("target_id", &"")
		if default_target != &"" and gs.mechs.has(default_target) and not gs.mechs[default_target].destroyed:
			if _RangeCalculator.is_in_weapon_range(source_mech.position, gs.mechs[default_target].position, wrange, gs.map_state.cells):
				target_id = default_target
		if target_id == &"":
			for mech_id: StringName in gs.mechs:
				var m = gs.mechs[mech_id]
				if m == null or m.destroyed or mech_id == source_mech_id:
					continue
				if _RangeCalculator.is_in_weapon_range(source_mech.position, m.position, wrange, gs.map_state.cells):
					target_id = mech_id
					break
		if target_id == &"":
			battle.log.append({"message": "AI反击范围内无机甲可攻击，取消反击", "details": {}})
			return
		pending["weapon_id"] = weapon_id
		pending["target_id"] = target_id
	var result: Dictionary = battle.begin_pending_counterattack(pending)
	_refresh_battle()
	if not result.get("ok", false):
		battle.log.append({"message": "AI反击失败：%s" % String(result.get("message", "")), "details": {}})
		return
	# 攻击2：防守方为玩家 → 需要玩家迎击响应
	if result.get("state", "") == "awaiting_player_response":
		_ai_counterattack_active = true
		_show_response_panel(result)
	else:
		# 直接结算（理论上不会走到，防守方为玩家必进入响应窗口）
		_handle_ai_counterattack_resolved(result)

## EffectEngine hook 信号回调：转发给消息日志
func _on_hook_fired(hook: StringName, payload: Dictionary) -> void:
	if message_log:
		message_log.on_hook_fired(hook, payload)

## 敌方信息按钮点击
func _on_enemy_info_clicked() -> void:
	if enemy_info_popup and battle and battle.context:
		enemy_info_popup.configure(battle.context)
		enemy_info_popup.popup_centered(Vector2i(320, 520))

## 牌堆信息按钮点击
func _on_deck_info_clicked() -> void:
	if deck_info_popup and battle and battle.context:
		deck_info_popup.configure(battle.context)
		deck_info_popup.popup_centered(Vector2i(400, 560))

# ═══════════════════════════════════════════
# 攻击交互流程
# ═══════════════════════════════════════════

## 进入攻击模式
func _enter_attack_mode(attack_card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if not mech:
		return

	# 获取武器列表
	var weapon_ids: Array[StringName] = mech.get_weapon_ids()
	if weapon_ids.is_empty():
		battle.log.append({"message": "没有可用武器", "details": {}})
		return

	attack_flow.enter_select_weapon(attack_card_id, &"player", &"enemy", false)

	# 如果只有1把武器，自动选择
	if weapon_ids.size() == 1:
		_on_weapon_selected(weapon_ids[0])
	else:
		# 有2把武器，显示选择面板
		weapon_picker_panel.configure(battle.context, weapon_ids)
		weapon_picker_panel.visible = true
		_show_cancel_button(true)
		_refresh_battle()

## 武器选择回调（攻击武器选择 或 武器槽位替换选择 或 辅助牌武器选择）
func _on_weapon_selected(weapon_id: StringName) -> void:
	if battle == null or battle.context == null:
		return

	# 如果正在为反击(attack2)选择武器
	if _counterattack_weapon_select_active:
		_on_counterattack_weapon_selected(weapon_id)
		return

	# 如果正在为辅助牌选择武器（如聚能），走辅助牌流程
	if _support_weapon_select_card_id != &"":
		_on_support_weapon_selected(weapon_id)
		return

	# 如果正在选择替换哪个武器槽，走装备流程
	if _weapon_slot_select_card_id != &"":
		_on_weapon_slot_selected_for_equipment(weapon_id)
		return

	attack_flow.enter_select_target(weapon_id)
	weapon_picker_panel.visible = false

	# 高亮攻击范围
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if not mech:
		return

	var weapon_card = gs.get_card(weapon_id)
	var weapon_range: int = 1
	if weapon_card and weapon_card.def:
		weapon_range = weapon_card.def.range_value
	var reachable: Array[Dictionary] = _RangeCalculator.get_weapon_reachable_hexes(
		mech.position, weapon_range, gs.map_state.cells
	)
	battle_board.highlight_hexes(reachable)
	battle.log.append({"message": "攻击模式：选择目标（点击敌方位置）", "details": {}})
	_show_cancel_button(true)
	_refresh_battle()

## 武器选择取消
func _on_weapon_selection_cancelled() -> void:
	_cancel_attack_mode()
	_refresh_battle()

## 取消攻击按钮
func _on_cancel_attack() -> void:
	# 强袭移动取消 = 原地停留并结算（攻击已声明，不能整体撤销）
	if _assault_movement_active:
		var gs = battle.context.game_state
		var attack_context: Dictionary = gs.attacks.get(battle.current_attack_id, {})
		var attacker_id: StringName = attack_context.get("attacker_id", &"")
		var attacker_mech = gs.mechs.get(attacker_id)
		if attacker_mech:
			_execute_assault_movement(attacker_mech.position.duplicate())
		return
	# 反击目标选择取消 = 不发动反击
	if _counterattack_target_select_active:
		_counterattack_target_select_active = false
		_counterattack_weapon_id = &""
		if battle_board:
			battle_board.clear_highlight()
		_show_cancel_button(false)
		_skip_player_counterattack()
		return
	_cancel_attack_mode()
	_refresh_battle()

## 取消攻击模式（通用清理）
func _cancel_attack_mode() -> void:
	attack_flow.reset()
	_support_target_select_card_id = &""
	_support_weapon_select_card_id = &""
	_choice_select_card_id = &""
	_weapon_slot_select_card_id = &""
	_repair_target_select_card_id = &""
	_repair_selected_target_mech_id = &""
	if battle_board:
		battle_board.clear_highlight()
	if weapon_picker_panel:
		weapon_picker_panel.visible = false
	if damage_placement_panel:
		damage_placement_panel.visible = false
	_show_cancel_button(false)

## 显示/隐藏取消攻击按钮
func _show_cancel_button(show: bool) -> void:
	if cancel_attack_button:
		cancel_attack_button.visible = show

## 尝试攻击目标
func _try_attack_target(hex: Dictionary) -> void:
	if battle == null or battle.context == null:
		return

	# 保存攻击参数（在 reset 前保存，因为 reset 会清空这些字段）
	var saved_weapon_id: StringName = attack_flow.weapon_id
	var saved_attack_card_id: StringName = attack_flow.attack_card_id

	# 清除选择状态
	attack_flow.reset()
	if battle_board:
		battle_board.clear_highlight()
	_show_cancel_button(false)

	var gs = battle.context.game_state
	# 检查hex上是否有敌方机甲
	var target_mech_id: StringName = &""
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m.destroyed:
			continue
		if int(m.position.get("q", 0)) == int(hex.get("q", 0)) and int(m.position.get("r", 0)) == int(hex.get("r", 0)):
			if m.owner_player_id != &"player":
				target_mech_id = mech_id
				break

	if target_mech_id == &"":
		battle.log.append({"message": "该位置无敌方机甲", "details": {}})
		_refresh_battle()
		return

	# 发动攻击（使用统一流程）
	var result: Dictionary = battle.begin_attack(&"player", &"enemy", saved_weapon_id, saved_attack_card_id)
	SessionLogger.log_call("app_root", "begin_attack", {
		"attacker": "player", "target": "enemy",
		"weapon_id": String(saved_weapon_id), "attack_card_id": String(saved_attack_card_id),
	}, result)

	if not result.get("ok", false):
		battle.log.append({"message": "攻击失败: %s" % String(result.get("message", "")), "details": {}})
		_refresh_battle()
		return

	# 检查结果状态
	var state: String = result.get("state", "")
	if state == "awaiting_player_response":
		# 玩家攻击时，敌方(AI)迎击由 begin_attack 内部自动处理；
		# 若返回响应窗口说明需玩家响应（极少）。这里走损伤放置/反击流程。
		_handle_attack_result(result)
	elif state == "resolved":
		# 攻击已结算，处理损伤放置
		_last_player_attack_result = result
		_handle_attack_result(result)
		# 若未弹出损伤放置面板，attack1 已完全结算 → 检查AI反击
		if not damage_placement_panel.visible:
			_maybe_trigger_ai_counterattack(result)
	elif state == "awaiting_assault_movement":
		# 强袭：目标响应结算完成后，攻击方用当前动力移动，之后再结算本次攻击
		_enter_assault_movement_mode()
	else:
		battle.log.append({"message": "攻击结果: %s" % state, "details": result})
		_refresh_battle()

	_finish_battle_if_needed()

## 处理攻击结算结果
func _handle_attack_result(result: Dictionary) -> void:
	if not result.get("hit", false):
		battle.log.append({"message": "攻击未命中", "details": result})
		_refresh_battle()
		return

	var damage: int = int(result.get("damage", 0))
	var markers: int = int(result.get("markers", 0))
	battle.log.append({"message": "攻击命中！伤害: %d 损伤: %d" % [damage, markers], "details": result})

	if markers > 0:
		var chooser: StringName = result.get("chooser_player_id", &"")
		var target_mech: StringName = result.get("target_mech_id_for_tokens", &"")

		if chooser == &"player":
			# 玩家选择损伤放置
			attack_flow.enter_damage_placement(target_mech, markers, chooser)
			damage_placement_panel.configure(battle.context, target_mech, markers)
			damage_placement_panel.visible = true
		else:
			# AI 自动放置
			battle.auto_place_damage_tokens(target_mech, markers)

	_refresh_battle()

## 损伤放置完成回调
func _on_damage_placement_completed() -> void:
	damage_placement_panel.visible = false
	attack_flow.reset()

	# 如果是敌方回合流程中的损伤放置（或反击 attack2 后），继续/结束敌方回合
	if battle.enemy_turn_phase == "awaiting_damage_placement":
		var was_counterattack: bool = _counterattack_turn == "enemy" and not _counterattack_pending.is_empty()
		if was_counterattack:
			_finish_enemy_turn_after_counterattack()
		else:
			var _result = battle.finish_enemy_turn()
			_refresh_battle()
			_finish_battle_if_needed()
		return

	# 玩家回合：attack1 损伤放置完成 → 检查AI反击(attack2)
	var stored_result: Dictionary = _last_player_attack_result
	_last_player_attack_result = {}
	_refresh_battle()
	_finish_battle_if_needed()
	if get_result_state() == "active" and not stored_result.is_empty():
		_maybe_trigger_ai_counterattack(stored_result)

## 效果选择完成回调
func _on_choice_made(effect_id: StringName) -> void:
	if choice_panel:
		choice_panel.visible = false

	# 反击(attack2)是否发动的选择
	if _counterattack_prompt_active:
		_counterattack_prompt_active = false
		if String(effect_id) == "__counterattack_yes__":
			_begin_player_counterattack()
		else:
			_skip_player_counterattack()
		return

	var card_id: StringName = _choice_select_card_id
	_choice_select_card_id = &""
	if card_id == &"":
		_refresh_battle()
		return
	# 将选择的效果ID加入 payload 并打出辅助牌
	var payload := {"chosen_effect_id": effect_id}
	# 维修目标选择已完成时，注入目标机甲；未指定则默认以自身机甲为目标
	if _repair_selected_target_mech_id != &"":
		payload["target_mech_id"] = _repair_selected_target_mech_id
		_repair_selected_target_mech_id = &""
	_play_action_card(card_id, payload)


## 效果选择取消回调
func _on_choice_cancelled() -> void:
	if choice_panel:
		choice_panel.visible = false
	# 反击提示取消 → 视为不发动
	if _counterattack_prompt_active:
		_skip_player_counterattack()
		return
	_choice_select_card_id = &""
	_repair_selected_target_mech_id = &""
	_repair_target_select_card_id = &""

## 显示弃牌选择面板
func _show_discard_select_panel(discard_info: Dictionary, card_id: StringName, effect_id: StringName) -> void:
	_discard_select_card_id = card_id
	_discard_select_pending = discard_info
	var discard_player_id: StringName = discard_info.get("discard_player_id", &"")
	var count: int = int(discard_info.get("count", 1))
	var face_up: bool = bool(discard_info.get("face_up", true))
	var card_type_filter: StringName = discard_info.get("card_type_filter", &"")
	discard_select_panel.configure(battle.context, discard_player_id, count, face_up, card_type_filter)
	discard_select_panel.visible = true
	_refresh_battle()


## 弃牌选择完成回调
func _on_discard_selection_completed(selected_card_ids: Array[StringName]) -> void:
	discard_select_panel.visible = false
	var pending: Dictionary = _discard_select_pending

	if _discard_select_card_id != &"":
		# 辅助牌打出流程的弃牌选择
		var payload := {"selected_action_card_ids": selected_card_ids}
		var card_id: StringName = _discard_select_card_id
		_discard_select_card_id = &""
		_discard_select_pending = {}
		_play_action_card(card_id, payload)
	elif pending.get("reason", &"") == &"END_TURN_HAND_LIMIT":
		# 回合结束弃牌：弃置玩家选择的牌后继续结束回合流程
		for card_id: StringName in selected_card_ids:
			battle.context.game_actions.discard_action_card({
				"player_id": &"player",
				"card_id": card_id,
				"reason": &"END_TURN_HAND_LIMIT",
			})
		battle.log.append({"message": "弃置了 %d 张行动牌" % selected_card_ids.size(), "details": {}})
		_discard_select_pending = {}
		_refresh_battle()
		_finish_player_turn()
	elif pending.has("reason"):
		# 攻击结算后触发的弃牌选择，直接弃牌
		var discard_player_id: StringName = pending.get("discard_player_id", &"")
		for card_id: StringName in selected_card_ids:
			battle.context.game_actions.discard_action_card({
				"player_id": discard_player_id,
				"card_id": card_id,
				"reason": pending.get("reason", &"EFFECT_DISCARD"),
			})
		battle.log.append({"message": "弃置了 %d 张行动牌" % selected_card_ids.size(), "details": {}})
		_discard_select_pending = {}
		_refresh_battle()


## 显示待处理弃牌选择面板（攻击结算后触发）
func _show_discard_select_panel_for_pending(pending: Dictionary) -> void:
	var discard_player_id: StringName = pending.get("discard_player_id", &"")
	var count: int = int(pending.get("count", 1))
	var face_up: bool = bool(pending.get("face_up", true))
	var card_type_filter: StringName = pending.get("card_type_filter", &"")
	_discard_select_pending = pending
	discard_select_panel.configure(battle.context, discard_player_id, count, face_up, card_type_filter)
	discard_select_panel.visible = true
	battle.log.append({"message": "请选择弃置的行动牌", "details": {}})
	_refresh_battle()
	_refresh_battle()


## 显示迎击面板
func _show_response_panel(attack_result: Dictionary) -> void:
	if not battle or not battle.context:
		return
	var attack_id: StringName = attack_result.get("attack_id", battle.current_attack_id)
	response_panel.configure(battle.context, attack_id)
	response_panel.visible = true
	_refresh_battle()

## 显示损伤放置面板
func _show_damage_placement(attack_result: Dictionary) -> void:
	if not battle or not battle.context:
		return
	var target_mech: StringName = attack_result.get("target_mech_id_for_tokens", &"")
	var markers: int = int(attack_result.get("markers", 0))
	if target_mech != &"" and markers > 0:
		attack_flow.enter_damage_placement(target_mech, markers, &"player")
		damage_placement_panel.configure(battle.context, target_mech, markers)
		damage_placement_panel.visible = true
	else:
		# 无需放置，直接继续
		var _result = battle.finish_enemy_turn()
		_refresh_battle()
		_finish_battle_if_needed()

## 打出辅助牌
func _play_action_card(card_id: StringName, payload: Dictionary = {}) -> void:
	if battle == null or battle.context == null:
		return
	var result: Dictionary = battle.context.card_play_service.play_action_card(&"player", card_id, payload)
	SessionLogger.log_call("app_root", "play_action_card", {"player": "player", "card_id": String(card_id), "payload": payload}, result)
	if result.get("ok", false):
		battle.log.append({"message": "打出了行动牌", "details": {}})
	elif result.get("needs", "") == &"weapon_select":
		# 需要玩家选择武器（如聚能）
		_enter_support_weapon_select(card_id)
		return
	elif result.get("needs", "") == &"discard_select":
		# 需要玩家选择弃牌目标
		_show_discard_select_panel(result.get("discard_info", {}), card_id, result.get("effect_id", &""))
	else:
		battle.log.append({"message": "打出失败: %s" % String(result.get("message", "")), "details": {}})
	_refresh_battle()


## 判断辅助牌是否为掩护牌（不能主动打出）
func _is_cover_card(card) -> bool:
	if card == null or card.def == null:
		return false
	# 检查效果的 hook 是否为 HOOK_ATTACK_DECLARED（掩护牌特征）
	for effect in card.def.effects:
		if effect and String(effect.hook) == "ON_ATTACK_DECLARED":
			return true
	# 检查 effect_ids 是否包含掩护效果
	if card.def.card_id == &"action_016_掩护":
		return true
	return false


## 判断辅助牌是否需要选择目标机甲
## 判断辅助牌是否包含二选一效果（CHOOSE_ONE）
func _support_card_has_choose_one(card) -> bool:
	if card == null or card.def == null:
		return false
	for effect in card.def.effects:
		if effect == null:
			continue
		for action in effect.actions:
			if action is Dictionary and String(action.get("type", "")) == "CHOOSE_ONE":
				return true
	return false


## 进入效果选择模式（二选一）
func _enter_choice_select(card_id: StringName) -> void:
	_choice_select_card_id = card_id
	# 从卡牌效果中提取 CHOOSE_ONE 的选项
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	if card == null or card.def == null:
		_choice_select_card_id = &""
		return
	var options: Array[Dictionary] = []
	for effect in card.def.effects:
		if effect == null:
			continue
		for action in effect.actions:
			if action is Dictionary and String(action.get("type", "")) == "CHOOSE_ONE":
				var action_params: Dictionary = action.get("params", {})
				var raw_options: Array = action_params.get("options", [])
				for opt in raw_options:
					if opt is Dictionary:
						options.append(opt)
				break
		if options.size() > 0:
			break
	if options.is_empty():
		_choice_select_card_id = &""
		return
	if choice_panel:
		choice_panel.configure(options)
		choice_panel.visible = true
	_refresh_battle()


## 判断是否为维修牌（action_013_维修）
func _is_repair_card(card) -> bool:
	if card == null or card.def == null:
		return false
	return card.def.card_id == &"action_013_维修"


## 获取维修可选目标机甲列表：自身机甲 + 1格范围内的其他机甲
func _get_repair_candidate_mechs() -> Array:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return []
	var candidates: Array = []
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if _HexGrid.distance(m.position, mech.position) <= 1:
			candidates.append(m)
	return candidates


## 处理维修打出：若1格范围内有其他机甲则先选目标，否则直接进入效果二选一
func _handle_repair_play(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var candidates: Array = _get_repair_candidate_mechs()
	# 仅自身可选（范围1格内无其他机甲）→ 默认对自身使用，跳过目标选择
	if candidates.size() <= 1:
		_repair_selected_target_mech_id = &""
		_enter_choice_select(card_id)
		return
	# 范围内有其他机甲 → 让玩家选择对谁使用维修
	_enter_repair_target_select(card_id, candidates)


## 进入维修目标选择模式：高亮自身与1格范围内的其他机甲
func _enter_repair_target_select(card_id: StringName, candidates: Array) -> void:
	_repair_target_select_card_id = card_id
	if battle_board:
		var highlights: Array[Dictionary] = []
		for m in candidates:
			highlights.append(m.position)
		battle_board.highlight_hexes(highlights)
	_show_cancel_button(true)
	battle.log.append({"message": "维修目标选择：点击自身或1格范围内的机甲", "details": {}})
	_refresh_battle()


## 选择维修目标机甲
func _select_repair_target(hex: Dictionary) -> void:
	if battle == null or battle.context == null:
		_repair_target_select_card_id = &""
		return
	var gs = battle.context.game_state
	var card_id: StringName = _repair_target_select_card_id
	_repair_target_select_card_id = &""
	_show_cancel_button(false)
	if battle_board:
		battle_board.clear_highlight()

	# 在候选目标中查找点击位置上的机甲
	var target_mech_id: StringName = &""
	var player_mech = gs.get_mech_for_player(&"player")
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if player_mech != null and _HexGrid.distance(m.position, player_mech.position) > 1:
			continue
		if int(m.position.get("q", 0)) == int(hex.get("q", 0)) and int(m.position.get("r", 0)) == int(hex.get("r", 0)):
			target_mech_id = mech_id
			break

	if target_mech_id == &"":
		battle.log.append({"message": "该位置无可用机甲", "details": {}})
		_refresh_battle()
		return

	# 记录目标，进入维修效果二选一
	_repair_selected_target_mech_id = target_mech_id
	_enter_choice_select(card_id)


func _support_card_needs_target(card) -> bool:
	if card == null or card.def == null:
		return false
	for effect in card.def.effects:
		if effect == null:
			continue
		for rule in effect.target_rules:
			var rule_name: String = String(rule.get("rule", ""))
			if rule_name in ["CHOOSE_ENEMY_MECH", "CHOOSE_ENEMY_MECH_IN_RANGE", "CHOOSE_MECH_IN_VARIABLE_RANGE"]:
				return true
	return false


## 判断辅助牌是否需要选择我方武器（CHOOSE_OWN_WEAPON，如聚能）
func _support_card_needs_weapon(card) -> bool:
	if card == null or card.def == null:
		return false
	for effect in card.def.effects:
		if effect == null:
			continue
		for rule in effect.target_rules:
			if String(rule.get("rule", "")) == "CHOOSE_OWN_WEAPON":
				return true
	return false


## 进入辅助牌武器选择模式（如聚能选武器）
func _enter_support_weapon_select(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	_support_weapon_select_card_id = card_id
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		_support_weapon_select_card_id = &""
		return
	var weapon_ids: Array[StringName] = mech.get_weapon_ids()
	if weapon_ids.is_empty():
		battle.log.append({"message": "没有可用武器", "details": {}})
		_support_weapon_select_card_id = &""
		_refresh_battle()
		return
	# 只有一把武器时自动选择
	if weapon_ids.size() == 1:
		_on_support_weapon_selected(weapon_ids[0])
		return
	weapon_picker_panel.configure(battle.context, weapon_ids, "── 选择要聚能的武器 ──")
	weapon_picker_panel.visible = true
	_show_cancel_button(true)
	battle.log.append({"message": "辅助牌武器选择：选择1把武器", "details": {}})
	_refresh_battle()


## 辅助牌武器选择回调
func _on_support_weapon_selected(weapon_id: StringName) -> void:
	var card_id: StringName = _support_weapon_select_card_id
	_support_weapon_select_card_id = &""
	if weapon_picker_panel:
		weapon_picker_panel.visible = false
	_show_cancel_button(false)
	if card_id == &"":
		_refresh_battle()
		return
	# 将选中的武器加入 payload 并打出辅助牌
	_play_action_card(card_id, {"selected_weapon_id": weapon_id})


## 进入辅助牌目标选择模式
func _enter_support_target_select(card_id: StringName) -> void:
	_support_target_select_card_id = card_id
	if battle_board:
		# 高亮所有敌方机甲位置
		var gs = battle.context.game_state
		var highlights: Array[Dictionary] = []
		for mech_id: StringName in gs.mechs:
			var m = gs.mechs[mech_id]
			if m.destroyed or m.owner_player_id == &"player":
				continue
			highlights.append(m.position)
		battle_board.highlight_hexes(highlights)
	_show_cancel_button(true)
	battle.log.append({"message": "辅助牌目标选择：点击敌方机甲", "details": {}})
	_refresh_battle()


## 选择辅助牌的目标机甲
func _select_support_target(hex: Dictionary) -> void:
	if battle == null or battle.context == null:
		_support_target_select_card_id = &""
		return

	var gs = battle.context.game_state
	var card_id: StringName = _support_target_select_card_id
	_support_target_select_card_id = &""
	_show_cancel_button(false)
	if battle_board:
		battle_board.clear_highlight()

	# 查找点击位置上的敌方机甲
	var target_mech_id: StringName = &""
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m.destroyed:
			continue
		if int(m.position.get("q", 0)) == int(hex.get("q", 0)) and int(m.position.get("r", 0)) == int(hex.get("r", 0)):
			if m.owner_player_id != &"player":
				target_mech_id = mech_id
				break

	if target_mech_id == &"":
		battle.log.append({"message": "该位置无敌方机甲", "details": {}})
		_refresh_battle()
		return

	# 将目标信息加入 payload 并打出辅助牌
	var payload := {"target_mech_id": target_mech_id}
	_play_action_card(card_id, payload)

# ═══════════════════════════════════════════
# 刷新与工具
# ═══════════════════════════════════════════

func _refresh_battle() -> void:
	if battle == null:
		return

	# 同步兼容字段
	battle._sync_compat_fields()

	var player: Dictionary = battle.units.get("player", {})
	var enemy: Dictionary = battle.units.get("enemy", {})

	# 更新状态栏
	if battle_summary_label:
		battle_summary_label.text = "回合 %d | 行动方: %s | 我方 HP %d/%d 动力 %d/%d 金币 %d | 敌方 HP %d/%d" % [
			battle.turn_number,
			battle.active_side,
			int(player.get("life", 0)),
			int(player.get("max_life", 0)),
			int(player.get("power", 0)),
			int(player.get("max_power", 0)),
			int(player.get("gold", 0)),
			int(enemy.get("life", 0)),
			int(enemy.get("max_life", 0)),
		]

	# 更新地图
	if battle_board:
		battle_board.configure(battle.map_tiles, battle.units)

	# 更新手牌面板
	if hand_panel and battle.context:
		hand_panel.configure(battle.context)

	# 更新装备面板
	if equipment_panel and battle.context:
		var mech = battle.context.game_state.get_mech_for_player(&"player")
		if mech:
			equipment_panel.configure(mech)

	# 更新技能栏
	if skill_bar and battle.context:
		skill_bar.configure(battle.context)

	# 更新消息日志（追赶新日志条目）
	if message_log and battle.context:
		message_log.configure(battle.context)

func _sync_and_refresh() -> void:
	_refresh_battle()

func _finish_battle_if_needed() -> void:
	var result = battle.get_result()
	if String(result.get("state", "inactive")) == "active":
		return
	var record := {
		"state": String(result.get("state", "inactive")),
		"reason": String(result.get("reason", "")),
		"turn_count": battle.turn_number,
	}
	campaign.record_battle_result(record)
	_show_result(record)

func get_result_state() -> String:
	if battle == null:
		return "inactive"
	var result = battle.get_result()
	return String(result.get("state", "inactive"))

# ═══════════════════════════════════════════
# 结果 / 战役中心 / 图鉴
# ═══════════════════════════════════════════

func _show_result(result: Dictionary) -> void:
	var layout := _begin_screen("战斗结果")
	var state := String(result.get("state", "inactive"))
	var state_text := "胜利" if state == "victory" else "失败"
	_add_text(layout, state_text)
	_add_text(layout, "原因: %s" % String(result.get("reason", "")))
	_add_text(layout, "回合数: %d" % int(result.get("turn_count", 0)))
	_add_button(layout, "重试", Callable(self, "_start_tutorial_battle"))
	_add_button(layout, "返回战役中心", Callable(self, "_show_campaign_hub"))
	_add_button(layout, "返回主菜单", Callable(self, "_show_main_menu"))

func _show_campaign_hub() -> void:
	var layout := _begin_screen("战役中心")
	var pilot: Dictionary = campaign.selected_pilot
	_add_text(layout, "当前机师: %s" % String(pilot.get("name", "克劳德")))
	if campaign.last_result.is_empty():
		_add_text(layout, "上次结果: 暂无")
	else:
		var state := String(campaign.last_result.get("state", "inactive"))
		var result_text := "胜利" if state == "victory" else "失败"
		_add_text(layout, "上次结果: %s - %s" % [result_text, String(campaign.last_result.get("reason", ""))])
		_add_text(layout, "上次回合数: %d" % int(campaign.last_result.get("turn_count", 0)))
	_add_button(layout, "再来一战", Callable(self, "_start_tutorial_battle"))
	_add_button(layout, "调整装备", Callable(self, "_show_loadout"))
	_add_button(layout, "返回主菜单", Callable(self, "_show_main_menu"))

func _show_collection() -> void:
	var layout := _begin_screen("图鉴")
	_add_text(layout, "奖励与解锁不在最小实现范围内。")
	_add_button(layout, "返回主菜单", Callable(self, "_show_main_menu"))

func _show_error(message: String) -> void:
	var layout := _begin_screen("启动失败")
	_add_text(layout, message)
	_add_button(layout, "退出", Callable(self, "_quit_app"))

# ═══════════════════════════════════════════
# UI 工具方法
# ═══════════════════════════════════════════

func _begin_screen(title: String) -> VBoxContainer:
	_clear_screen()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)
	current_screen = margin
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 4)
	margin.add_child(layout)
	var heading := Label.new()
	heading.text = title
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 22)
	layout.add_child(heading)
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(status_label)
	return layout

func _clear_screen() -> void:
	# 断开 EffectEngine hook 信号，防止悬挂引用
	if battle and battle.context and battle.context.effect_engine:
		if battle.context.effect_engine.hook_fired.is_connected(Callable(self, "_on_hook_fired")):
			battle.context.effect_engine.hook_fired.disconnect(Callable(self, "_on_hook_fired"))
	if enemy_info_popup and is_instance_valid(enemy_info_popup):
		enemy_info_popup.queue_free()
	if deck_info_popup and is_instance_valid(deck_info_popup):
		deck_info_popup.queue_free()
	if current_screen != null and is_instance_valid(current_screen):
		current_screen.queue_free()
	current_screen = null
	status_label = null
	battle_summary_label = null
	message_log = null
	enemy_info_popup = null
	deck_info_popup = null
	battle_board = null
	hand_panel = null
	equipment_panel = null
	skill_bar = null
	response_panel = null
	weapon_picker_panel = null
	damage_placement_panel = null
	choice_panel = null
	discard_select_panel = null
	cancel_attack_button = null

func _add_text(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label

func _add_button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(140, 32)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _on_equipment_toggled(pressed: bool, id: String) -> void:
	selected_equipment[id] = pressed

func _equipment_label(item: Dictionary) -> String:
	if item.has("name"):
		return "%s (%s)" % [String(item.get("name", "")), String(item.get("rarity", "N"))]
	return "%s-%s (%s)" % [String(item.get("set_name", "装备")), String(item.get("slot", "")), String(item.get("rarity", "N"))]

func _show_status(message: String) -> void:
	if status_label != null:
		status_label.text = message
	else:
		push_warning(message)

func _status_ok(status: Dictionary) -> bool:
	return bool(status.get("ok", false))

func _status_message(status: Dictionary) -> String:
	return String(status.get("message", "unknown error"))

func _quit_app() -> void:
	SessionLogger.log_raw("════════ 会话结束 ════════")
	get_tree().quit()
