## ActionUIBridge.gd — UI与ActionEngine的桥接层
##
## 负责将 ActionEngine 需要玩家输入的步骤转换为 UI 弹窗/选框，
## 并在玩家确认后调用 ActionService.continue_action() 继续执行。
##
## 连接信号：
##   ActionEngine.action_needs_input → _on_action_needs_input
##   UI组件的确认信号 → _on_ui_confirmed
extends RefCounted
class_name ActionUIBridge

const _TC = preload("res://scripts/action_core/TimingConst.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

## 依赖注入：GameContext 容器
var context = null

## 当前等待输入的动作ID
var _waiting_action_id: StringName = &""
## 当前等待的输入类型
var _current_input_type: StringName = &""
## 当前输入参数
var _current_input_params: Dictionary = {}

## 多效果并发等待输入的排队表（{action_id: {input_type, input_params}}）。
## 场景：联合连携攻击C（独立顶层）与攻击A 的闪击弃牌/再攻击D 并行时，
## 两者的 need_input 请求竞争同一个共享槽 _waiting_action_id。旧语义"后到覆盖先到"：
## 先到请求（联合攻击C 的选武器）被覆盖后永久丢失，后到者完成时槽清空，
## 先到动作滞留 waiting_input 无弹窗 -> UI 卡死 / 双端发散（联合不同步根因）。
## 新语义"后到排队"：槽被占时新请求入队；槽释放（确认/取消/动作完成）时按
## 插入序 refire 队首（重新 emit 弹窗+占槽）。玩家按队列顺序处理，不插队不丢失。
var _queued_waiting_inputs: Dictionary = {}

## 非模态展示浮窗（不占共享槽、不排队）：纯展示可随时关闭，与任何输入窗互斥无意义；
## 若入队会阻塞后续真实输入请求（浮窗永不"确认"释放槽）。
## input_type -> popup_type 映射，_on_action_needs_input 开头拦截直接 emit。
const NONMODAL_DISPLAY_POPUPS: Dictionary = {
	&"pilot_009_show_display": &"pilot_009_card_display",
	&"pilot_028_show_declared": &"pilot_028_declared_display",
	&"pilot_058_show_display": &"pilot_058_card_display",
	&"view_random_other_hand_show_display": &"pilot_066_card_display",
	&"pilot_088_conquer_display": &"pilot_088_conquer_display",
}

## ── 信号 ──
signal request_ui_popup(popup_type: StringName, params: Dictionary)
signal action_input_resolved(action_id: StringName, input_data: Dictionary)


## 初始化：连接 ActionEngine 与 TimingEngine 信号
## 注意：响应窗口（respond_attack）的 input 请求由 TimingEngine 发出
## （TimingEngine._handle_response_window 在 ATTACK_AT 时点 emit action_needs_input），
## 而非 ActionEngine。因此必须同时连接 TimingEngine 的同名信号，否则
## 响应窗口信号无人接收，ResponsePanel 永远不会弹出，攻击动作卡死在 waiting_timing。
func setup() -> void:
	if context != null and context.action_engine != null:
		context.action_engine.action_needs_input.connect(_on_action_needs_input)
		context.action_engine.action_completed.connect(_on_action_completed)
		context.action_engine.action_cancelled.connect(_on_action_cancelled)
	if context != null and context.timing_engine != null:
		context.timing_engine.action_needs_input.connect(_on_action_needs_input)
		# 响应窗口关闭（确认响应/pass/全pass）= 该输入请求已解决：清共享槽并恢复排队请求。
		# 否则槽残留指向攻击动作，后续并发请求（反击打出后的移动选格、攻击推进后的
		# 损伤放置等）被误判"槽被占"而排队不弹 -> 卡死。旧覆盖语义下槽被新请求抢走可
		# 自愈，排队语义必须显式清。
		context.timing_engine.response_window_closed.connect(_on_response_window_closed)


## 响应窗口已关闭（TimingEngine.handle_response_selection 各路径 emit）：
## 清理共享槽（若仍指向该攻击动作）+ 恢复队首排队请求。
func _on_response_window_closed(action_id: StringName, _selected_effects: Array) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	_refire_first_queued_waiting()


## ActionEngine 需要玩家输入时的回调
func _on_action_needs_input(action_id: StringName, input_type: StringName, input_params: Dictionary) -> void:
	# 早到输入信箱（主汇入点）：该动作若有早到的恢复输入（网络/点击先于挂起到达），
	# 此刻挂起已注册 -> 取出 deferred 补投并直接返回（不弹窗不占槽，本次等待由补投恢复）。
	# 挂起后引擎可能静默（无后续时点），故除 fire_timing 兜底外必须在汇入点排空。
	if context != null and context.timing_engine != null \
			and context.timing_engine.drain_effect_input_for(action_id):
		return
	# 非模态展示浮窗：不占槽不排队，直接弹（与任何输入窗可并存）
	if NONMODAL_DISPLAY_POPUPS.has(input_type):
		request_ui_popup.emit(NONMODAL_DISPLAY_POPUPS.get(input_type), input_params)
		return
	# 多效果并发等待输入：槽已被其他动作占用时排队（不覆盖、不弹窗），
	# 槽释放时 _refire_first_queued_waiting 按插入序恢复（弹窗+占槽）。
	# 同一动作的重复请求（选武器->选目标等链式推进）直接更新槽，不排队。
	if _waiting_action_id != &"" and _waiting_action_id != action_id:
		_queued_waiting_inputs[action_id] = {
			"input_type": input_type,
			"input_params": input_params.duplicate(true),
		}
		return
	_queued_waiting_inputs.erase(action_id)
	_waiting_action_id = action_id
	_current_input_type = input_type
	_current_input_params = input_params

	# 注入来源标签（"牌名：效果描述"），供弹框顶部显示来源，避免玩家分不清是哪个效果。
	# 从 TimingEngine 挂起效果取；非效果驱动的弹框（如攻击损伤放置）无标签，用面板自身标题。
	if not input_params.has("source_label") and context != null and context.timing_engine != null:
		var _slabel: String = context.timing_engine.get_pending_source_label(action_id)
		if _slabel != "":
			input_params["source_label"] = _slabel

	# 根据输入类型分发到不同的 UI 弹窗
	match input_type:
		&"select_weapon":
			# AI 攻击选武器：自动选第一把武器（AI 普通攻击已预填 weapon_id 不走此；
			# 反击 attack B 等未预填武器的 AI 攻击走此分支）
			if _is_ai_source(input_params):
				_auto_select_weapon(action_id, input_params)
				return
			request_ui_popup.emit(&"weapon_select", input_params)
		&"select_attack_target":
			# AI 攻击选目标：自动选射程内第一个敌方
			if _is_ai_source(input_params):
				_auto_select_attack_target(action_id, input_params)
				return
			request_ui_popup.emit(&"attack_target_select", input_params)
		&"select_move_target":
			# 迎击移动（回避/疾行/反击）：若移动方为 AI，自动选格移动躲开攻击方；
			# 否则弹选格 UI 给玩家。
			# AI 自动决策改 call_deferred：避免 re-entrant continue_action 在移动循环中
			# 嵌套过深（高动力时机甲多步移动，每步同步重入 continue_action 致栈溢出）。
			# deferred 后每步移动独立一帧，循环变迭代式，栈不增长。
			if _is_ai_mover(input_params):
				call_deferred("_auto_move_target", action_id, input_params)
				return
			request_ui_popup.emit(&"move_target_select", input_params)
		&"select_equipment_slot":
			request_ui_popup.emit(&"equipment_slot_select", input_params)
		&"select_discard_cards":
			# AI 弃牌（闪击2/装备效果/机师效果强制弃牌等）：自动弃前 N 张行动牌，不弹人类窗
			if _is_ai_source(input_params):
				_auto_discard_cards(action_id, input_params)
				return
			request_ui_popup.emit(&"discard_card_select", input_params)
		&"place_damage_tokens":
			# AI（executor 非 player）不弹 UI，自动放置损伤
			if _is_ai_executor(input_params):
				_auto_place_damage_tokens(input_params)
				return
			request_ui_popup.emit(&"damage_token_placement", input_params)
		&"damage_adjust":
			# 损伤调整面板（薇尔 pilot_059 回合开始：每槽位 +1/-1+取消，仅1次机会）
			request_ui_popup.emit(&"damage_adjust", input_params)
		&"show_cards":
			request_ui_popup.emit(&"card_show", input_params)
		&"choose_one":
			# AI 二选一：默认选第一项（最小可用策略）
			if _is_ai_source(input_params):
				on_ui_confirmed({"chosen_option_index": 0})
				return
			request_ui_popup.emit(&"choice_select", input_params)
		&"select_mech_target":
			# 锁定/联合目标选择：AI 自动选第一个存活敌方
			if _is_ai_source(input_params):
				_auto_mech_target(action_id, input_params)
				return
			request_ui_popup.emit(&"mech_target_select", input_params)
		&"respond_attack":
			# 响应窗口：若响应方（被攻击目标）为 AI，自动决策；否则弹响应窗口给玩家
			if _is_ai_responder(input_params):
				_auto_respond(action_id, input_params)
				return
			# 响应窗口：列出所有 AVAILABILITY 模式的效果牌
			_show_response_window(action_id, input_params)
		&"confirm_use_card":
			# 使用行动牌前的确认对话框
			request_ui_popup.emit(&"use_card_confirm", input_params)
		&"select_weapon_for_charge":
			# 聚能武器选择：AI 自动选第一把武器
			if _is_ai_source(input_params):
				_auto_select_weapon(action_id, input_params)
				return
			request_ui_popup.emit(&"weapon_charge_select", input_params)
		&"select_repair_target":
			# 维修目标机甲选择：AI 自动选自身（最小可用，避免卡死）
			if _is_ai_source(input_params):
				_auto_repair_target(action_id, input_params)
				return
			request_ui_popup.emit(&"repair_target_select", input_params)
		&"select_map_cell":
			# 机雷设陷选格：AI 已在 TimingEngine._execute_actions 自动选第一格，此处仅玩家路径。
			request_ui_popup.emit(&"map_cell_select", input_params)
		&"choose_one_effect":
			# 维修二选一：回复4HP vs 移除2损伤。AI 自动决策；玩家弹 effect_choice
			if _is_ai_source(input_params):
				_auto_repair_choose_one(action_id, input_params)
				return
			request_ui_popup.emit(&"effect_choice", input_params)
		&"pilot_083_options":
			# 瓦恩武器修改 phase2：三横排互斥选项面板（weapon_modify_options_panel）。
			# 弹窗已由 TimingEngine 按持有者玩家 player_id 路由；AI 不点主动/RE 按钮不会走到。
			request_ui_popup.emit(&"pilot_083_options", input_params)
		&"choose_integer":
			# 金币换动力整数选择（effect_040/041）。AI 已在 TimingEngine 自动选 min，此处仅玩家路径。
			request_ui_popup.emit(&"integer_select", input_params)
		&"select_target_mech":
			# 锁定/联合目标选择：AI 自动选第一个存活敌方
			if _is_ai_source(input_params):
				_auto_mech_target(action_id, input_params)
				return
			request_ui_popup.emit(&"mech_target_select", input_params)
		&"redirect_select":
			# 损伤转移汇总窗（A6 装备效果）：玩家选转移若干点到本牌区域。
			# AI 已在 TimingEngine._execute_actions 的 OFFER_DAMAGE_REDIRECT 分支自动决策，此处仅玩家路径。
			request_ui_popup.emit(&"redirect_select", input_params)
		&"select_thrust_cards":
			# 推进 effect2 多选：持有者使用迎击牌时弹窗选若干推进一起打出。
			# AI 已在 TimingEngine._execute_actions 的 CHOOSE_MANY_CARDS 分支跳过，此处仅玩家路径。
			request_ui_popup.emit(&"thrust_select", input_params)
		&"thrust_select":
			# pilot_019 缴械冲击支付 / pilot_020 肯德弃任意行动牌等：多选行动牌弹窗。
			# 复用 thrust_select 面板；confirm/cancel 由 app_root _on_thrust_selection_completed/_cancelled
			# 发 resume_effect {selected_card_ids}/{cancelled} 闭环。AI 不点 DIRECT 按钮不会走到，
			# 与 select_thrust_cards 同款无需 AI 兜底。
			request_ui_popup.emit(&"thrust_select", input_params)
		&"mech_multi_select":
			# 通用多选机甲（CHOOSE_MANY_MECHS，奥黛尔 pilot_038「选最多2台4格内机甲含我方」）：
			# 地图点选多台机甲（复用攻击多选交互）。AI 已在 TimingEngine._prompt_choose_many_mechs
			# 跳过，此处仅人类玩家路径。
			request_ui_popup.emit(&"mech_multi_select", input_params)
		&"hidden_card_view":
			# 霍恩 pilot_046 等「查看隐藏装备」：打开 hidden_card_view_panel（阻塞，可关闭）。
			# AI 已在 TimingEngine._handle_hidden_view_and_acquire 跳过，此处仅人类玩家路径。
			request_ui_popup.emit(&"hidden_card_view_select", input_params)
		&"hidden_reserve_slot":
			# 霍恩 pilot_046 等「隐藏装备获取」选目标备用区（allow_cancel=false，全部玩家 RESERVE 槽）。
			# AI 已被 hidden_card_view 分支拦截，此处仅人类玩家路径。
			request_ui_popup.emit(&"hidden_reserve_slot_select", input_params)
		&"select_unite_attack_card":
			# 联合状态效果1：unite机甲攻击结算后，弹窗让 Target 选1张攻击牌联合攻击。
			# AI Target 已在 TimingEngine._execute_actions 的 UNITE_ATTACK_OFFER 分支跳过。
			# 弹窗路由到 Target 玩家（_popup_owner 按 target_mech_id 反查 owner）。
			request_ui_popup.emit(&"unite_attack_select", input_params)
		&"select_pilot_006_attack_card":
			# pilot_006 e3 战后逼迫：被选机甲选1张攻击牌 use_action_card（取消=受到4伤害）。
			# 复用 unite_attack_select 面板（同为"选1张攻击牌"单选+取消），input_params 携带
			# card_ids/label/action_id/player_id（被选机甲玩家），_popup_owner 据此路由到对应玩家窗口。
			request_ui_popup.emit(&"unite_attack_select", input_params)
		&"pilot_018_select_equipment":
			# pilot_018 苔丝 effect_01b：选1张损伤≥2装备牌弃置（攻击方装备牌，明牌列出）。
			# 复用 choice_panel（通用单选），选项 effect_id=装备牌 instance_id。
			# AI 苔丝已在 TimingEngine 跳过，此处仅玩家路径。
			request_ui_popup.emit(&"pilot_018_equipment_select", input_params)
		&"pilot_025_reserve_select":
			# pilot_025 约书亚 1b：选1张备用区装备牌设置（复用 choice_panel 单选）。
			# AI 约书亚已在 TimingEngine 跳过，此处仅玩家路径。
			request_ui_popup.emit(&"pilot_025_reserve_select", input_params)
		&"pilot_025_slot_select":
			# pilot_025 约书亚 1b：选目标区域设置该备用装备（复用 immediate_set_equipment 面板）。
			# AI 约书亚已在 TimingEngine 跳过，此处仅玩家路径。
			request_ui_popup.emit(&"immediate_set_equipment", input_params)
		&"select_pilot_003_skip_players":
			# pilot_003 e3 复选框：瑟尔基尔玩家勾选「抽牌跳过正面牌」的玩家。
			# AI 不支持复选框，跳过（不修改设置）。弹窗由 _popup_owner 按 player_id 路由。
			if _is_ai_source(input_params):
				return
			request_ui_popup.emit(&"pilot_003_skip_players", input_params)
		&"select_pilot_003_choose_top":
			# pilot_003 e1 phase 链：选完埋牌后弹"选1张置顶(可取消)"窗。AI 不会到此（CHOOSE_MANY 已跳过）。
			# 复用 unite 单选面板（通用化后 card_suffix/confirm_verb/cancel_label 可定制），按 player_id 路由。
			if _is_ai_source(input_params):
				return
			request_ui_popup.emit(&"pilot_003_choose_top", input_params)
		&"pilot_009_pay_select":
			# pilot_009 弹窗① 支付：美杜莎弃1张自己行动牌（记录类型，可取消=中止）。
			# 复用 discard_card_select 面板；mode 非 need_input -> optional 路径，confirm/cancel 走 resume_effect。
			# AI 美杜莎：自动弃首张行动牌（最小可用，避免挂死）。
			if _is_ai_source(input_params):
				var pay_pid: StringName = input_params.get("discard_player_id", input_params.get("player_id", &""))
				if pay_pid != &"" and context != null and context.game_state != null:
					var pay_player = context.game_state.players.get(pay_pid)
					if pay_player != null and not pay_player.action_hand.is_empty():
						var _first_action := &""
						for _pcid: StringName in pay_player.action_hand:
							var _pc = context.game_state.get_card(_pcid)
							if _pc != null and _pc.def != null and _pc.def.card_kind == &"action":
								_first_action = _pcid
								break
						if _first_action != &"":
							on_ui_confirmed({"selected_action_card_ids": [_first_action]})
							return
				on_ui_cancelled()
				return
			request_ui_popup.emit(&"discard_card_select", input_params)
		&"pilot_009_show_display":
			# pilot_009 非阻塞展示浮窗：列出目标行动牌（只弹给美杜莎，可拖拽/可关闭）。
			# 不捕获 _waiting_action_id（非模态），不阻塞弃牌选1窗。
			request_ui_popup.emit(&"pilot_009_card_display", input_params)
		&"pilot_028_show_declared":
			# pilot_028 乌尔宣言展示浮窗（非阻塞，所有玩家可见，含乌尔自己）。可拖拽/可关闭。
			request_ui_popup.emit(&"pilot_028_declared_display", input_params)
		&"pilot_058_show_display":
			# pilot_058 卡米拉展示浮窗（非阻塞，只弹给其他玩家——自己不看自己的牌）。可拖拽/可关闭。
			request_ui_popup.emit(&"pilot_058_card_display", input_params)
		&"view_random_other_hand_show_display":
			# 通用「随机查看其他机甲行动牌」展示浮窗（骇客 pilot_066）：非阻塞，只弹给查看方玩家本人
			# （app_root 按 owner_player_id==local 过滤；PvP 双端都触发，非所有者端静默）。可拖拽/可关闭。
			request_ui_popup.emit(&"pilot_066_card_display", input_params)
		&"select_awaken_card_type":
			# 觉醒：弃牌堆无预判/识破时，弹框让玩家选1种行动牌（列种类+数量）。
			# AI 自动选第一项（最小可用，避免挂死）；人类弹 awaken_select 窗。
			if _is_ai_source(input_params):
				var aw_opts: Array = input_params.get("options", [])
				var aw_pick: StringName = &""
				if not aw_opts.is_empty():
					var first: Dictionary = aw_opts[0] if aw_opts[0] is Dictionary else {}
					aw_pick = first.get("def_id", &"")
				on_ui_confirmed({"chosen_card_def_id": aw_pick})
				return
			request_ui_popup.emit(&"awaken_select", input_params)
		&"immediate_set_equipment":
			# effect_005 立即设置装备：AI 已在 TimingEngine._execute_actions 自动选首槽，此处仅玩家路径。
			request_ui_popup.emit(&"immediate_set_equipment", input_params)
		&"pilot_014_target_select":
			# pilot_014 亚伦选机师牌：弹列表选框(每项机师名+行动牌上限)，复用 choice_panel。
			# AI 兜底自动选第一项（AI 不点机师按钮，但避免挂死）；人类走 pilot_014_target_select 弹窗。
			if _is_ai_source(input_params):
				var p014_ai_opts: Array = input_params.get("options", [])
				if not p014_ai_opts.is_empty():
					var p014_ai_o: Dictionary = p014_ai_opts[0] if p014_ai_opts[0] is Dictionary else {}
					on_ui_confirmed({
						"pilot_014_target_pilot": p014_ai_o.get("pilot_instance", &""),
						"pilot_014_player_id": p014_ai_o.get("player_id", &""),
						"pilot_014_mech_id": p014_ai_o.get("mech_id", &""),
					})
					return
				on_ui_cancelled()
				return
			request_ui_popup.emit(&"pilot_014_target_select", input_params)
		&"pilot_088_type_select":
			# 征服宣言三选一（攻击/迎击/辅助，不可取消）：复用 choice_panel 单选。
			# AI 兜底自动选第一项（AI 不点主动按钮，避免挂死）；人类走 pilot_088_type_select 弹窗。
			if _is_ai_source(input_params):
				var p088_ai_opts: Array = input_params.get("options", [])
				if not p088_ai_opts.is_empty():
					var p088_ai_o: Dictionary = p088_ai_opts[0] if p088_ai_opts[0] is Dictionary else {}
					on_ui_confirmed({"pilot_088_declared_type": String(p088_ai_o.get("declared_type", "攻击"))})
					return
				on_ui_cancelled()
				return
			request_ui_popup.emit(&"pilot_088_type_select", input_params)
		&"pilot_088_conquer_display":
			# 征服宣言+随机展示浮窗（非阻塞，所有玩家端显示；不捕获 _waiting_action_id）。
			request_ui_popup.emit(&"pilot_088_conquer_display", input_params)
		&"pilot_032_pay_select":
			# pilot_032 弹窗① 支付：爱瑞娅弃1张自己行动牌（可取消=中止，不计次数）。
			# 复用 discard_card_select 面板；mode 非 need_input -> optional 路径，confirm/cancel 走 resume_effect。
			# AI 爱瑞娅：自动弃首张行动牌（最小可用，避免挂死）。
			if _is_ai_source(input_params):
				var p032_pay_pid: StringName = input_params.get("discard_player_id", input_params.get("player_id", &""))
				if p032_pay_pid != &"" and context != null and context.game_state != null:
					var p032_pay_player = context.game_state.players.get(p032_pay_pid)
					if p032_pay_player != null and not p032_pay_player.action_hand.is_empty():
						var p032_first_action := &""
						for p032_pcid: StringName in p032_pay_player.action_hand:
							var p032_pc = context.game_state.get_card(p032_pcid)
							if p032_pc != null and p032_pc.def != null and p032_pc.def.card_kind == &"action":
								p032_first_action = p032_pcid
								break
						if p032_first_action != &"":
							on_ui_confirmed({"selected_action_card_ids": [p032_first_action]})
							return
				on_ui_cancelled()
				return
			request_ui_popup.emit(&"discard_card_select", input_params)
		&"pilot_032_target_select":
			# pilot_032 弹窗② 选机师牌：弹列表选框(每项机师名+行动牌上限)，复用 choice_panel。
			# AI 兜底自动选第一项（AI 不点机师按钮，但避免挂死）；人类走 pilot_032_target_select 弹窗。
			if _is_ai_source(input_params):
				var p032_ai_opts: Array = input_params.get("options", [])
				if not p032_ai_opts.is_empty():
					var p032_ai_o: Dictionary = p032_ai_opts[0] if p032_ai_opts[0] is Dictionary else {}
					on_ui_confirmed({
						"pilot_032_target_pilot": p032_ai_o.get("pilot_instance", &""),
						"pilot_032_player_id": p032_ai_o.get("player_id", &""),
						"pilot_032_mech_id": p032_ai_o.get("mech_id", &""),
					})
					return
				on_ui_cancelled()
				return
			request_ui_popup.emit(&"pilot_032_target_select", input_params)
		_:
			push_warning("ActionUIBridge: 未知输入类型: %s" % String(input_type))
			request_ui_popup.emit(&"generic_input", input_params)


## 判断 place_damage_tokens 的执行者是否为 AI（非人类玩家）
func _is_ai_executor(input_params: Dictionary) -> bool:
	var executor: StringName = input_params.get("executor", &"")
	if executor == &"":
		return false
	# executor 可能是 player_id 或 mech_id：优先按 player_id 查，否则按 mech_id 反查 owner
	if context != null and context.game_state != null:
		if context.game_state.players.has(executor):
			return not _is_human_player_id(executor)
		var m = context.game_state.mechs.get(executor)
		if m != null:
			return not _is_human_player_id(m.owner_player_id)
	return false


## 判断某 player_id 是否由人类控制。
## 未知（无 context / 玩家不存在）默认 true（人类），保守走 UI 弹窗而非自动决策，
## 与历史 `!= &"player"` 在 not-found 时返回 false（即非 AI）的行为一致。
func _is_human_player_id(player_id: StringName) -> bool:
	if player_id == &"" or context == null or context.game_state == null:
		return true
	var player = context.game_state.players.get(player_id)
	if player == null:
		return true
	return player.is_human


## 判断效果发起方是否为 AI（非人类）。来源机甲经 input_params.mech_id / source_mech_id 定位。
func _is_ai_source(input_params: Dictionary) -> bool:
	var mech_id: StringName = _resolve_owner_mech_id(input_params)
	return _is_ai_mech_id(mech_id)


## 从 input_params 多种字段统一提取"发起方机甲 id"
## 不同 input_type 携带字段不同：attacker_id(攻击选武器/目标) / executor(弃牌) /
## mech_id·source_mech_id(维修/锁定/联合/二选一) / target_id(响应窗口,此处不用)。
func _resolve_owner_mech_id(input_params: Dictionary) -> StringName:
	var mech_id: StringName = input_params.get("attacker_id", &"")
	if mech_id == &"":
		mech_id = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	if mech_id == &"":
		mech_id = input_params.get("executor", &"")
	# executor/player_id 可能是 player_id 而非 mech_id：反查其机甲
	if mech_id == &"" or context == null or context.game_state == null:
		var pid: StringName = input_params.get("player_id", &"")
		if pid != &"" and context != null and context.game_state != null:
			var m = context.game_state.get_mech_for_player(pid)
			if m != null:
				return m.mech_id
		return &""
	# 若取到的 mech_id 实为 player_id（mechs 字典查不到），反查
	if context != null and context.game_state != null and not context.game_state.mechs.has(mech_id):
		var m2 = context.game_state.get_mech_for_player(mech_id)
		if m2 != null:
			return m2.mech_id
	return mech_id


## 判断机甲 id 是否属于 AI（非人类）
func _is_ai_mech_id(mech_id: StringName) -> bool:
	var owner = _get_player_for_mech_id(mech_id)
	return owner != null and not owner.is_human


## 通过 GameState 的机甲→玩家关系判断控制方，避免只读 mech.owner_player_id 导致
## 临时/旧状态下把人类机甲误判为 AI（或反之）。
func _get_player_for_mech_id(mech_id: StringName):
	if mech_id == &"" or context == null or context.game_state == null:
		return null
	var player = context.game_state.get_player_for_mech(mech_id)
	if player != null:
		return player
	var mech = context.game_state.mechs.get(mech_id)
	if mech != null:
		player = context.game_state.players.get(mech.owner_player_id)
	return player


## AI 自动选维修目标：默认选自身机甲（若自身有损伤或未满血优先自身）。
func _auto_repair_target(action_id: StringName, input_params: Dictionary) -> void:
	var mech_id: StringName = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	if mech_id == &"":
		on_ui_cancelled()
		return
	on_ui_confirmed({"target_id": mech_id, "target_mech_id": mech_id})


## AI 自动选维修二选一：自身未满血→回复4生命(选项0)；否则若有损伤→移除2损伤(选项1)；默认0。
func _auto_repair_choose_one(_action_id: StringName, input_params: Dictionary) -> void:
	var mech_id: StringName = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	var idx: int = 0
	if mech_id != &"" and context != null and context.game_state != null:
		var mech = context.game_state.mechs.get(mech_id)
		if mech != null:
			var full: bool = mech.current_hp >= mech.max_hp
			var has_damage: bool = false
			for slot_id in mech.slots:
				var slot = mech.slots[slot_id]
				if slot != null and slot.damage_tokens > 0:
					has_damage = true
					break
			if full and has_damage:
				idx = 1  # 满血但有损伤 → 移除损伤
			else:
				idx = 0  # 否则回复生命
	on_ui_confirmed({"chosen_option_index": idx})


## AI 自动选攻击武器：选机甲第一把武器（AI 普通攻击已预填武器不走此；
## 反击 attack B 等未预填武器的 AI 攻击走此分支）。
func _auto_select_weapon(_action_id: StringName, input_params: Dictionary) -> void:
	var attacker_id: StringName = input_params.get("attacker_id", input_params.get("mech_id", &""))
	if attacker_id == &"" or context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var attacker = context.game_state.mechs.get(attacker_id)
	if attacker == null:
		on_ui_cancelled()
		return
	var weapon_ids: Array[StringName] = attacker.get_weapon_ids()
	if weapon_ids.is_empty():
		on_ui_cancelled()
		return
	on_ui_confirmed({"weapon_id": weapon_ids[0]})


## AI 自动选攻击目标：在所选武器射程内选第一个存活敌方；无可选则取消
func _auto_select_attack_target(_action_id: StringName, input_params: Dictionary) -> void:
	var attacker_id: StringName = input_params.get("attacker_id", &"")
	if attacker_id == &"" or context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var attacker = context.game_state.mechs.get(attacker_id)
	if attacker == null:
		on_ui_cancelled()
		return
	var weapon_range: int = int(input_params.get("weapon_range", 1))
	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
	var _attack_aura: Dictionary = context.map_service.get_attack_aura_cells()
	# 机甲格为攻击路径障碍 + 陷落"不能被选为目标"排除（AI 同样遵守攻击规则）
	var _attack_blocked: Dictionary = context.map_service.get_attack_blocked_keys(attacker_id)
	# 射程内第一个存活敌方（非自身、非同阵营）
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if mid == attacker_id:
			continue
		if m.owner_player_id == attacker.owner_player_id:
			continue
		if m.has_status(&"cannot_be_targeted"):
			continue
		if _RangeCalculator.is_in_weapon_range(attacker.position, m.position, weapon_range, map_cells, _attack_aura, _attack_blocked):
			on_ui_confirmed({"target_id": mid})
			return
	# 射程内无敌方：取消（避免 AI 攻击卡死）
	on_ui_cancelled()


## AI 自动弃牌：弃前 N 张行动牌（明牌顺序，AI 不挑）。optional 弃牌（闪击2）也走此。
func _auto_discard_cards(_action_id: StringName, input_params: Dictionary) -> void:
	if context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var mech_id: StringName = _resolve_owner_mech_id(input_params)
	var player_id: StringName = input_params.get("player_id", &"")
	if player_id == &"" and mech_id != &"" and context.game_state != null:
		var mch = context.game_state.mechs.get(mech_id)
		if mch != null:
			player_id = mch.owner_player_id
	if player_id == &"":
		on_ui_cancelled()
		return
	var player = context.game_state.players.get(player_id)
	if player == null:
		on_ui_cancelled()
		return
	var count: int = int(input_params.get("count", 1))
	var picked: Array = []
	for cid: StringName in player.action_hand:
		picked.append(cid)
		if picked.size() >= count:
			break
	if picked.is_empty():
		# 无牌可弃：optional 弃牌取消；强制弃牌也无牌可弃只能取消
		on_ui_confirmed({"selected_action_card_ids": [], "determined_card_ids": [], "cancelled": true})
		return
	# 回填两个键：
	#   - selected_action_card_ids：optional 弃牌（闪击2）走 resume_pending_effect 读此
	#   - determined_card_ids：discard_card 动作走 continue_action 重跑 _step_determine_cards 读此
	# on_ui_confirmed 内按 has_pending_effect 自动分发到对应路径，另一键被忽略。
	on_ui_confirmed({
		"selected_action_card_ids": picked,
		"determined_card_ids": picked,
	})


## AI 自动选目标机甲（锁定/联合等）：选第一个存活的敌方机甲
func _auto_mech_target(_action_id: StringName, input_params: Dictionary) -> void:
	var src_mech_id: StringName = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	if context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var picked: StringName = &""
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if mid == src_mech_id:
			continue
		picked = mid
		break
	if picked == &"":
		on_ui_cancelled()
		return
	on_ui_confirmed({"target_id": picked, "target_mech_id": picked})


## 判断响应窗口的响应方（被攻击目标）是否为 AI
func _is_ai_responder(input_params: Dictionary) -> bool:
	var target_id: StringName = input_params.get("target_id", &"")
	if target_id == &"" or context == null or context.game_state == null:
		return false
	return _is_ai_mech_id(target_id)


## 判断迎击移动的移动方机甲是否为 AI（非人类）
## 回避/疾行/反击效果发起的 single_move 的 input_params.mech_id 即移动方机甲。
func _is_ai_mover(input_params: Dictionary) -> bool:
	var mech_id: StringName = input_params.get("mech_id", &"")
	return _is_ai_mech_id(mech_id)


## AI 自动移动：分两类——
## (a) 迎击移动（移动方=防御方/被攻击目标，回避/疾行/反击发起）：优先逃出攻击方射程；
## (b) 强袭追击移动（移动方=攻击者，强袭 effect2 在目标响应后发起）：保持在目标射程内以保证
##     本攻击命中，同时尽量远离目标的武器范围以躲反击（若有空间）。无法兼顾则优先保命中。
## 循环移动期间每次选格都会再次回调本方法，直到动力耗尽或无路可走，自动结束循环。
func _auto_move_target(action_id: StringName, input_params: Dictionary) -> void:
	if context == null or context.game_state == null:
		_resolve_action_cancel(action_id)
		return
	var mech_id: StringName = input_params.get("mech_id", &"")
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		_resolve_action_cancel(action_id)
		return
	var available_power: int = int(input_params.get("available_power", 0))
	var pos: Dictionary = mech.position

	# 取 attack 动作的 attacker_id / target_id / weapon_range（沿父链查）
	var attacker_pos: Dictionary = {}
	var target_pos: Dictionary = {}
	var target_id: StringName = &""
	var weapon_range: int = 1
	var mover_is_attacker: bool = false
	if context.action_registry != null:
		var cur_id: StringName = action_id
		for _i in 4:
			var cur = context.action_registry.get_action(cur_id)
			if cur == null:
				break
			if cur.action_type == &"attack":
				var atk_id: StringName = cur.record.get("attacker_id", &"")
				var atk_mech = context.game_state.mechs.get(atk_id)
				if atk_mech != null:
					attacker_pos = atk_mech.position
				target_id = cur.record.get("target_id", &"")
				var tgt_mech = context.game_state.mechs.get(target_id)
				if tgt_mech != null:
					target_pos = tgt_mech.position
				weapon_range = int(cur.record.get("weapon_range", 1))
				mover_is_attacker = (atk_id == mech_id)
				break
			cur_id = cur.parent_action_id
			if cur_id == &"":
				break

	# 目标反击最大射程（强袭躲反击用）：取目标所有武器 range 最大值
	var target_counter_range: int = 0
	if target_id != &"":
		var tgt_mech2 = context.game_state.mechs.get(target_id)
		if tgt_mech2 != null:
			for wid: StringName in tgt_mech2.get_weapon_ids():
				var wcard = context.game_state.get_card(wid)
				if wcard != null and wcard.def != null:
					target_counter_range = max(target_counter_range, wcard.def.range_value)

	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}

	# 攻击射程光环（光环格视为绿格、耗2射程预算）--用于逃跑判定/评分，与攻击范围高亮一致。
	var _attack_aura: Dictionary = context.map_service.get_attack_aura_cells()
	# 通用移动消耗参数（效果元数据驱动）：按移动方玩家算折扣（持有者玩家绿格耗1）+ 光环转化绿格。
	var _mc_ui := {"green_cost": 2, "aura_cells": {}}
	var _mover_mech = context.game_state.mechs.get(mech_id) if context.game_state.mechs != null else null
	if _mover_mech != null:
		_mc_ui = context.map_service.resolve_move_cost_params(_mover_mech.owner_player_id)
	# 相邻可达格（剩余动力足够）
	var neighbors: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(pos, max(1, available_power), map_cells, int(_mc_ui["green_cost"]), _mc_ui["aura_cells"])
	if neighbors.is_empty():
		_resolve_action_cancel(action_id)
		return

	# 迎击移动：若当前格已逃出攻击范围，停止移动（逃脱达成，避免 0 动力原地循环致栈溢出）
	if not mover_is_attacker and not attacker_pos.is_empty():
		if not _RangeCalculator.is_in_weapon_range(attacker_pos, pos, weapon_range, map_cells, _attack_aura):
			_resolve_action_cancel(action_id)
			return

	var best: Dictionary = {}
	if mover_is_attacker and not target_pos.is_empty():
		best = _score_assault_move(neighbors, target_pos, weapon_range, map_cells, target_counter_range, _attack_aura)
	else:
		var prev_pos: Dictionary = input_params.get("previous_position", {})
		best = _score_evade_move(neighbors, attacker_pos, weapon_range, map_cells, prev_pos, _attack_aura)

	if best.is_empty():
		_resolve_action_cancel(action_id)
		return

	# 选中原地（无更优格）则停止移动，避免 0 动力消耗移动死循环（栈溢出）
	if int(best.get("q", 0)) == int(pos.get("q", 0)) and int(best.get("r", 0)) == int(pos.get("r", 0)):
		_resolve_action_cancel(action_id)
		return

	var cell_id: String = "%d,%d" % [int(best.get("q", 0)), int(best.get("r", 0))]
	_resolve_action_input(action_id, {"target_cell": cell_id})


## 强袭追击评分：优先保持在目标射程内（保命中 +2000），其次躲开目标反击射程（+500，
## 仅在不破坏命中的前提下；若我方武器射程<目标反击射程才能兼顾），其次靠近目标（距离越小越好）。
func _score_assault_move(neighbors: Array, target_pos: Dictionary, weapon_range: int, map_cells: Dictionary, target_counter_range: int, aura_green_cells: Dictionary = {}) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -1e9
	for hex in neighbors:
		var in_range: bool = _RangeCalculator.is_in_weapon_range(target_pos, hex, weapon_range, map_cells, aura_green_cells)
		var dist: int = _HexGrid.distance(target_pos, hex)
		var score: float = (2000.0 if in_range else 0.0) + (-dist * 10.0)
		# 躲反击：该格不在目标武器射程内（命中优先级 2000 >> 500，不会为躲反击而放弃命中）
		if target_counter_range > 0:
			var in_counter: bool = _RangeCalculator.is_in_weapon_range(target_pos, hex, target_counter_range, map_cells, aura_green_cells)
			if not in_counter:
				score += 500.0
		if score > best_score:
			best_score = score
			best = hex
	return best


## 迎击移动评分：优先逃出攻击范围（+1000），其次离攻击方更远。
## previous_pos：上一步起点，施加大惩罚防回访振荡（B1 修复）。
func _score_evade_move(neighbors: Array, attacker_pos: Dictionary, weapon_range: int, map_cells: Dictionary, previous_pos: Dictionary = {}, aura_green_cells: Dictionary = {}) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -1e9
	for hex in neighbors:
		var in_range: bool = false
		if not attacker_pos.is_empty():
			in_range = _RangeCalculator.is_in_weapon_range(attacker_pos, hex, weapon_range, map_cells, aura_green_cells)
		var dist: int = 0
		if not attacker_pos.is_empty():
			dist = _HexGrid.distance(attacker_pos, hex)
		# 出范围 +1000，距离越远分越高
		var score: float = (dist * 1.0) + (1000.0 if not in_range else 0.0)
		# 防回访：回到上一步起点施大惩罚（避免两等距格来回跳）
		if not previous_pos.is_empty() and int(hex.get("q", 0)) == int(previous_pos.get("q", 0)) and int(hex.get("r", 0)) == int(previous_pos.get("r", 0)):
			score -= 10000.0
		if score > best_score:
			best_score = score
			best = hex
	return best


## AI 自动放置损伤（不弹 UI），放置后回填动作继续执行
func _auto_place_damage_tokens(input_params: Dictionary) -> void:
	var mech_ids: Array = input_params.get("mech_ids", [])
	var amount: int = int(input_params.get("amount", 0))
	var removal: bool = bool(input_params.get("removal_mode", false))
	# removal 模式（维修移除损伤）：自动移除；放置模式：damage_token_service 按优先级放置
	if context != null:
		for mech_id: StringName in mech_ids:
			if removal and context.game_actions != null:
				context.game_actions.remove_damage_tokens({"mech_id": mech_id, "amount": amount})
			elif not removal and context.damage_token_service != null:
				context.damage_token_service.place_damage_tokens({
					"mech_id": mech_id,
					"count": amount,
				})
	# 回填动作（damage_change 的 set_damage 步骤收到任意 input 即继续结算）
	on_ui_confirmed({"auto_placed": true})


## AI 自动响应攻击窗口
## 委托给 AIController.decide_response（能逃则逃，不能逃才反打）；无 AIController 时退回"最高优先级"。
func _auto_respond(action_id: StringName, input_params: Dictionary) -> void:
	if context == null or context.timing_engine == null:
		return
	var available: Array[Dictionary] = []
	if context.timing_engine != null and context.action_registry != null:
		var action = context.action_registry.get_action(action_id)
		if action != null:
			available = context.timing_engine.get_available_cards(_TC.ATTACK_AT, action)
	if available.is_empty():
		var empty_sel: Array[Dictionary] = []
		context.timing_engine.handle_response_selection(action_id, empty_sel)
		return
	var selected: Array = []
	if context.ai_controller != null:
		selected = context.ai_controller.decide_response(action_id, available)
	if selected.is_empty():
		# 退回原策略：使用最高优先级响应牌
		selected = [available[0]]
	# handle_response_selection 期望 Array[Dictionary]；selected 是 Array，逐项构造
	var best_sel: Array[Dictionary] = []
	for entry in selected:
		if entry is Dictionary:
			best_sel.append(entry)
	context.timing_engine.handle_response_selection(action_id, best_sel)


## 显示响应窗口
func _show_response_window(action_id: StringName, params: Dictionary) -> void:
	var available_cards: Array = []
	if context != null and context.timing_engine != null and context.action_registry != null:
		var action = context.action_registry.get_action(action_id)
		if action != null:
			available_cards = context.timing_engine.get_available_cards(_TC.ATTACK_AT, action)

	# 将可用效果转换为UI显示数据
	# 注意：get_available_cards 返回的是 Dictionary 数组，每个元素含
	# effect_id / card_instance_id / display_name 等键（无 source 字段）。
	# pilot_009 美杜莎受控牌（若其类型被其他玩家控制）标注「(来自XX)」以区分来源；
	# 被动牌触发窗口集成延后，此处为预留 hook（granted listener 接入后生效）。
	var display_data: Array[Dictionary] = []
	for entry in available_cards:
		var card_instance_id: StringName = entry.get("card_instance_id", &"")
		var card = context.game_state.get_card(card_instance_id) if card_instance_id != &"" and context != null and context.game_state != null else null
		var _card_name: String = card.def.display_name if card and card.def else String(entry.get("effect_id", &""))
		if card != null and card.def != null and card.def.card_kind == &"action" and _ActionPilotEffects != null:
			var _ctrl_type: StringName = StringName(String(card.def.action_type))
			var _ctrl_mech: StringName = card.mech_id
			if _ctrl_mech != &"":
				for _ctrl_pid: StringName in _ActionPilotEffects.get_pilot_009_controllers(_ctrl_mech, _ctrl_type):
					if _ctrl_pid != card.owner_player_id:
						# 标注来源：取控制者机甲名（无则用玩家 id）
						var _src_name: String = String(_ctrl_pid)
						if context != null and context.game_state != null:
							var _ctrl_m = context.game_state.get_mech_for_player(_ctrl_pid)
							if _ctrl_m != null and _ctrl_m.frame_def != null and String(_ctrl_m.frame_def.display_name) != "":
								_src_name = String(_ctrl_m.frame_def.display_name)
						_card_name += "(来自%s)" % _src_name
						break
		display_data.append({
			"effect_id": entry.get("effect_id", &""),
			"card_instance_id": card_instance_id,
			"display_name": entry.get("display_name", &""),
			"card_name": _card_name,
			# 透传 PvP 路由/响应窗口选择所需字段：
			# - owner_player_id：app_root 在 PvP 模式按 owner_player_id==local_player_id 过滤响应窗口条目，
			#   缺此字段会导致所有条目被过滤、窗口永不弹出、攻击卡死 waiting_timing。
			# - effect/availability_priority/seq：_build_selected_cards_from_card 重建 selected_cards、
			#   handle_response_selection 排序用；display_data 即 client 端 configure_with_cards 收到的列表。
			# - is_counter：迎击牌标注（行动牌响应牌弃置等流程区分用）。
			"owner_player_id": entry.get("owner_player_id", &""),
			"effect": entry.get("effect", null),
			"availability_priority": entry.get("availability_priority", 0),
			"seq": entry.get("seq", 0),
			"is_counter": bool(entry.get("is_counter", false)),
		})

	request_ui_popup.emit(&"response_window", {
		"action_id": action_id,
		"available_cards": display_data,
		"attacker_id": params.get("attacker_id", &""),
		"target_id": params.get("target_id", &""),
	})


## UI组件确认后的回调（由 UI 调用）
func on_ui_confirmed(input_data: Dictionary) -> void:
	if _waiting_action_id == &"":
		return

	var action_id: StringName = _waiting_action_id
	_waiting_action_id = &""
	_current_input_type = &""
	_current_input_params = {}

	_apply_action_input(action_id, input_data)
	# 确认后同步链可能发起新 need_input（选武器->选目标）已占槽；
	# 槽仍空闲时按插入序恢复排队的并发等待请求（联合攻击C 选武器等）
	_refire_first_queued_waiting()


## UI组件取消时的回调
func on_ui_cancelled() -> void:
	if _waiting_action_id == &"":
		return

	var action_id: StringName = _waiting_action_id
	_waiting_action_id = &""
	_current_input_type = &""
	_current_input_params = {}

	_apply_action_cancel(action_id)
	_refire_first_queued_waiting()


## 槽空闲时按插入序恢复队首的并发等待请求（重新走 _on_action_needs_input 占槽+弹窗）。
## 跳过已不在等待态的动作登记（输入已被其他路径解决/动作已完成的残留条目）。
func _refire_first_queued_waiting() -> void:
	if _waiting_action_id != &"":
		return
	while not _queued_waiting_inputs.is_empty():
		var q_aid: StringName = _queued_waiting_inputs.keys()[0]
		var entry: Dictionary = _queued_waiting_inputs.get(q_aid, {})
		_queued_waiting_inputs.erase(q_aid)
		var q_action = null
		if context != null and context.action_registry != null:
			q_action = context.action_registry.get_action(q_aid)
		if q_action == null or (String(q_action.state) != &"waiting_input" and String(q_action.state) != &"waiting_timing"):
			continue
		_on_action_needs_input(q_aid, entry.get("input_type", &""), entry.get("input_params", {}))
		return


## 供 TimingEngine.resume_pending_effect 消费挂起输入时调用：该动作的旧输入请求已被
## resume 消费，槽中残留等待过时，释放之（仅当槽仍指向该动作）。
## 旧"后到覆盖"语义下槽被新请求抢走可自愈；排队语义下残留会阻塞后续不同动作的新输入
## （效果续跑弹新窗被判"槽被占"而排队不弹 -> UI 无窗可弹/卡死）。
## 不做 refire：resume 续跑可能同步弹出新窗占槽，队首恢复由后续槽事件（新窗完成/
## 动作完成/响应窗关闭）触发。bridge.resolve_effect_input 调用前已自行清槽，此处幂等。
func release_waiting_slot_if_owner(action_id: StringName) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}


## 远端玩家的等待窗（弹窗按 owner 路由到对方端显示，本机不弹）：释放共享槽并恢复
## 队首排队请求。不 resolve 该动作（交互决策在对方端，输入经 resume_effect 网络op
## 回填后由 resolve_effect_input 按动作 id 精确处理）；本机玩家的排队窗口不被远端
## 不可见窗口阻塞（TURN_BEFORE_END 拾荒/宝藏/修悟多玩家并行等待场景，app_root 的
## PvP 弹窗 owner 门控处调用）。
func skip_remote_waiting(action_id: StringName) -> void:
	if action_id == &"":
		return
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
		_refire_first_queued_waiting()


## 当前排队中的并发等待动作 id 列表（插入序）。供测试/调试断言排队语义
## （并发等待不丢失，槽释放后按序恢复）。
func get_queued_waiting_action_ids() -> Array:
	return _queued_waiting_inputs.keys()


## 损伤放置/移除完成：按记录的 damage_change 动作 ID 精确恢复。
## 损伤放置期间可能因装备损坏触发离场效果弹窗，覆盖了共享 _waiting_action_id 槽；
## 此处用面板记录的 action_id 直接恢复 damage_change，使攻击正常结算（攻击牌不卡临时区）。
## action_id 为空或动作已不存在时退回 on_ui_confirmed 共享槽路径。
func resolve_damage_placement(action_id: StringName, input_data: Dictionary) -> void:
	if action_id != &"" and context != null and context.action_registry != null:
		var action = context.action_registry.get_action(action_id)
		if action != null:
			# _resolve_action_input 仅当共享槽仍指向本动作时清槽，否则保留并发效果弹窗的等待槽
			_resolve_action_input(action_id, input_data)
			return
	on_ui_confirmed(input_data)


## 按 action_id 精确回填输入（不走共享 _waiting_action_id 槽）。
## 供 call_deferred 的 AI 自动决策（_auto_move_target）使用：延迟回调执行时，
## _waiting_action_id 可能已被后到的 waiting_input 动作覆盖（如强袭 effect2 与响应移动
## 并发 waiting_input），若用 on_ui_confirmed 会把输入错路由到后到动作（玩家被 AI 自动
## 移动的 bug）。此处仅当共享槽仍指向本动作时清槽，并直接回填本动作。
func _resolve_action_input(action_id: StringName, input_data: Dictionary) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	_apply_action_input(action_id, input_data)
	_refire_first_queued_waiting()


## 按 action_id 精确取消（供 call_deferred 的 AI 自动决策使用，理由同 _resolve_action_input）。
func _resolve_action_cancel(action_id: StringName) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	_apply_action_cancel(action_id)
	_refire_first_queued_waiting()


## 效果弹窗确认（resume_effect op）：恢复 TimingEngine 挂起的效果，同时清除共享等待锁。
## 与 on_ui_confirmed 对齐——效果弹窗（pilot_025 选备用/选区域、pilot_003、pilot_018、
## choose_one_effect 等）走 _net_exec("resume_effect") 直连 resume_pending_effect，绕过
## on_ui_confirmed，导致 _waiting_action_id 残留 -> 主动效果按钮全部置灰 + 地图点击被拦截
## （"发动后动不了"）。此处仅当锁仍指向被恢复的动作时清锁，否则保留并发弹窗的等待槽。
func resolve_effect_input(action_id: StringName, input_data: Dictionary) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	if context != null and context.timing_engine != null:
		context.timing_engine.resume_pending_effect(action_id, input_data)
	_refire_first_queued_waiting()


## 实际回填输入到指定动作：优先恢复 TimingEngine 挂起的效果，否则 continue_action。
func _apply_action_input(action_id: StringName, input_data: Dictionary) -> void:
	action_input_resolved.emit(action_id, input_data)
	# 目标选择 / 二选一 等由 TimingEngine 挂起的效果：走 resume_pending_effect 续跑
	# （这些效果的目标检查在动作执行之前，continue_action 直接走下一 step 会漏掉效果执行）
	if context != null and context.timing_engine != null and context.timing_engine.has_pending_effect(action_id):
		context.timing_engine.resume_pending_effect(action_id, input_data)
		return
	# 调用 ActionService 继续执行动作
	if context != null and context.action_service != null:
		context.action_service.continue_action(action_id, input_data)


## 实际取消指定动作：TimingEngine 挂起的效果走 resume_pending_effect(cancelled)，否则 cancel_action。
func _apply_action_cancel(action_id: StringName) -> void:
	# TimingEngine 挂起的效果（目标选择/二选一）：取消则不执行该效果，恢复动作继续后续步骤
	if context != null and context.timing_engine != null and context.timing_engine.has_pending_effect(action_id):
		context.timing_engine.resume_pending_effect(action_id, {"cancelled": true})
		return
	if context != null and context.action_service != null:
		context.action_service.cancel_action(action_id)


## 动作完成时的回调
func _on_action_completed(action_id: StringName, _action_type: StringName, _record: Dictionary) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	# 并发排队中的动作登记清理 + 槽空闲时恢复队首（动作链全部结算后，
	# 残留的排队请求如联合攻击C 选武器必须重新弹出，否则永久滞留）
	_queued_waiting_inputs.erase(action_id)
	_refire_first_queued_waiting()


## 动作取消时的回调
func _on_action_cancelled(action_id: StringName, _action_type: StringName) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	_queued_waiting_inputs.erase(action_id)
	_refire_first_queued_waiting()


## 获取当前等待输入的动作信息
## 返回空字典表示无等待中的动作，否则返回 action_id / input_type / input_params
func get_waiting_action_info() -> Dictionary:
	if _waiting_action_id == &"":
		return {}
	return {
		"action_id": _waiting_action_id,
		"input_type": _current_input_type,
		"input_params": _current_input_params,
	}
