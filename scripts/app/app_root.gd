extends Control

const _DataRegistry = preload("res://scripts/data/data_registry.gd")
const _CampaignState = preload("res://scripts/campaign/campaign_state.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _BattleMessageLog = preload("res://scripts/ui/battle_message_log.gd")
const _EnemyInfoPopup = preload("res://scripts/ui/enemy_info_popup.gd")
const _AttackFlowController = preload("res://scripts/ui/attack_flow_controller.gd")
const _WeaponPickerPanel = preload("res://scripts/ui/weapon_picker_panel.gd")
const _DamagePlacementPanel = preload("res://scripts/ui/damage_placement_panel.gd")
const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")

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
## 辅助牌效果选择状态：正在选择效果的辅助牌ID
var _choice_select_card_id: StringName = &""

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

	# 如果在辅助牌目标选择模式，选择该位置上的机甲
	if _support_target_select_card_id != &"":
		_select_support_target(hex)
		return

	# 如果在攻击目标选择模式，尝试攻击该位置上的机甲
	if attack_flow.current_state == _AttackFlowController.SELECT_TARGET:
		_try_attack_target(hex)
		return

	# 否则尝试移动
	var result = battle.move_unit("player", hex)
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
			if _support_card_has_choose_one(card):
				_enter_choice_select(card_id)
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
		for ws_id: StringName in [&"weapon_1", &"weapon_2"]:
			if mech.slots.has(ws_id) and not mech.slots[ws_id].equipped_card:
				slot_id = ws_id
				break
		if slot_id == &"":
			slot_id = &"weapon_1"

	if slot_id == &"":
		battle.log.append({"message": "无可用槽位", "details": {}})
		_refresh_battle()
		return

	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", card_id, slot_id)
	if result.get("ok", false):
		battle.log.append({"message": "装备了 %s" % card.def.display_name, "details": {}})
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

	var result = battle.end_player_turn()
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

	# 提交迎击并结算攻击
	var resolve_result = battle.handle_response(battle.current_attack_id, card_id)
	response_panel.visible = false

	# 继续敌方回合流程
	_continue_enemy_turn_after_response(resolve_result)

## 跳过迎击
func _on_response_passed() -> void:
	if battle == null:
		return

	# 跳过迎击并结算攻击
	var resolve_result = battle.handle_response(battle.current_attack_id, &"")
	response_panel.visible = false

	# 继续敌方回合流程
	_continue_enemy_turn_after_response(resolve_result)

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

## EffectEngine hook 信号回调：转发给消息日志
func _on_hook_fired(hook: StringName, payload: Dictionary) -> void:
	if message_log:
		message_log.on_hook_fired(hook, payload)

## 敌方信息按钮点击
func _on_enemy_info_clicked() -> void:
	if enemy_info_popup and battle and battle.context:
		enemy_info_popup.configure(battle.context)
		enemy_info_popup.popup_centered(Vector2i(320, 520))

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

## 武器选择回调
func _on_weapon_selected(weapon_id: StringName) -> void:
	if battle == null or battle.context == null:
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
	_cancel_attack_mode()
	_refresh_battle()

## 取消攻击模式（通用清理）
func _cancel_attack_mode() -> void:
	attack_flow.reset()
	_support_target_select_card_id = &""
	_choice_select_card_id = &""
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

	if not result.get("ok", false):
		battle.log.append({"message": "攻击失败: %s" % String(result.get("message", "")), "details": {}})
		_refresh_battle()
		return

	# 检查结果状态
	var state: String = result.get("state", "")
	if state == "awaiting_player_response":
		# 不应该出现在玩家攻击时（敌方迎击由AI处理）
		_show_response_panel(result)
	elif state == "resolved":
		# 攻击已结算，处理损伤放置
		_handle_attack_result(result)
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

	# 如果是敌方回合流程中的损伤放置，继续敌方回合
	if battle.enemy_turn_phase == "awaiting_damage_placement":
		var _result = battle.finish_enemy_turn()
		_refresh_battle()
		_finish_battle_if_needed()
		return

	_refresh_battle()

## 效果选择完成回调
func _on_choice_made(effect_id: StringName) -> void:
	if choice_panel:
		choice_panel.visible = false
	var card_id: StringName = _choice_select_card_id
	_choice_select_card_id = &""
	if card_id == &"":
		_refresh_battle()
		return
	# 将选择的效果ID加入 payload 并打出辅助牌
	var payload := {"chosen_effect_id": effect_id}
	_play_action_card(card_id, payload)


## 效果选择取消回调
func _on_choice_cancelled() -> void:
	if choice_panel:
		choice_panel.visible = false
	_choice_select_card_id = &""
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
	if result.get("ok", false):
		battle.log.append({"message": "打出了行动牌", "details": {}})
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
	if current_screen != null and is_instance_valid(current_screen):
		current_screen.queue_free()
	current_screen = null
	status_label = null
	battle_summary_label = null
	message_log = null
	enemy_info_popup = null
	battle_board = null
	hand_panel = null
	equipment_panel = null
	skill_bar = null
	response_panel = null
	weapon_picker_panel = null
	damage_placement_panel = null
	choice_panel = null
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
	get_tree().quit()
