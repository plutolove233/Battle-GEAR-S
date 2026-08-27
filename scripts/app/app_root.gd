extends Control
const SLog = preload("res://scripts/services/slog.gd")

const _DataRegistry = preload("res://scripts/data/data_registry.gd")
const _CampaignState = preload("res://scripts/campaign/campaign_state.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _BattleMessageLog = preload("res://scripts/ui/battle_message_log.gd")
const _EnemyInfoPopup = preload("res://scripts/ui/enemy_info_popup.gd")
const _MechDetailPanel = preload("res://scripts/ui/mech_detail_panel.gd")
const _StatusPanel = preload("res://scripts/ui/status_panel.gd")
const _AttackFlowController = preload("res://scripts/ui/attack_flow_controller.gd")
const _WeaponPickerPanel = preload("res://scripts/ui/weapon_picker_panel.gd")
const _DamagePlacementPanel = preload("res://scripts/ui/damage_placement_panel.gd")
const _DamageAdjustPanel = preload("res://scripts/ui/damage_adjust_panel.gd")
const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")
const _DiscardSelectPanel = preload("res://scripts/ui/discard_select_panel.gd")
const _ThrustSelectPanel = preload("res://scripts/ui/thrust_select_panel.gd")
const _UniteAttackSelectPanel = preload("res://scripts/ui/unite_attack_select_panel.gd")
const _AwakenSelectPanel = preload("res://scripts/ui/awaken_select_panel.gd")
const _Pilot003SkipPanel = preload("res://scripts/ui/pilot_003_skip_panel.gd")
const _ImmediateSetEquipmentPanel = preload("res://scripts/ui/immediate_set_equipment_panel.gd")
const _CardDisplayPanel = preload("res://scripts/ui/card_display_panel.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
const _DeckInfoPopup = preload("res://scripts/ui/deck_info_popup.gd")
const _ShopPanel = preload("res://scripts/ui/shop_panel.gd")
const _HiddenCardViewPanel = preload("res://scripts/ui/hidden_card_view_panel.gd")
const _SellEquipmentPanel = preload("res://scripts/ui/sell_equipment_panel.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")
const _DevModePanel = preload("res://scripts/ui/dev_mode_panel.gd")
const _TmpZonePanel = preload("res://scripts/ui/tmp_zone_panel.gd")
const _NetHost = preload("res://scripts/net/net_host.gd")
const _NetClient = preload("res://scripts/net/net_client.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")

## 诊断开关（敌方回合卡死/动作完成回调查排查遗留）。
## 默认关闭：_check_enemy_turn_complete 经 call_deferred 反复触发时，
## 这些 [DIAG] 会写入 GB 级日志。复现敌方回合卡死时再置 true。
const _DIAG_ENEMY_TURN := false

## 槽位中文名映射（与 EquipmentPanel 保持一致）
const SLOT_NAMES: Dictionary = {
	&"头部": "头部", &"躯干": "躯干", &"右臂": "右臂", &"左臂": "左臂",
	&"右腿": "右腿", &"左腿": "左腿",
	&"weapon_1": "武器1", &"weapon_2": "武器2",
	&"reserve_1": "备用1", &"reserve_2": "备用2",
	&"event": "事件", &"pilot": "机师",
}

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
var tmp_zone_panel = null  # type: TmpZonePanel
var equipment_panel = null  # type: EquipmentPanel
var skill_bar = null  # type: SkillBar
var response_panel = null  # type: ResponsePanel
var message_log = null  # type: BattleMessageLog
var enemy_info_popup = null  # type: EnemyInfoPopup
var mech_detail_panel = null  # type: MechDetailPanel
## 机甲状态列表面板（集中显示所有机甲的联合/锁定等状态）
var status_panel = null  # type: StatusPanel

## 攻击流程控制器
var attack_flow: RefCounted = null  # type: AttackFlowController
## 武器选择面板
var weapon_picker_panel = null  # type: WeaponPickerPanel
## 损伤放置面板
var damage_placement_panel = null  # type: DamagePlacementPanel
## 损伤调整面板（薇尔 pilot_059 回合开始：每槽位 +1/-1+取消）
var damage_adjust_panel = null  # type: DamageAdjustPanel
## 效果选择面板（维修等二选一卡牌）
var choice_panel = null  # type: ChoicePanel
## 瓦恩武器修改三横排选项面板（pilot_083 效果1/RE phase2）
var weapon_modify_options_panel = null  # type: WeaponModifyOptionsPanel
## 瓦恩武器修改选项面板当前挂起的动作 id（确认/取消经 resume_effect 双端续跑）
var _p083_options_action_id: StringName = &""
## 步进数值输入面板（pilot_004 装甲转能：LineEdit+±3+键盘）
var stepper_panel = null  # type: StepperPanel
## 弹窗浮层：全屏居中容器，承载所有弹窗面板（choice/response/weapon_picker 等），
## 使其脱离 _begin_screen 的 VBox 流式布局——否则内容总高超出窗口时，
## 排在 child index 后段的弹窗的确认/取消按钮会被挤到窗口外裁切。
var popup_overlay = null  # type: CenterContainer
## 逐格移动模态遮罩：移动中拦截全屏点击（点任意位置停止移动，且不触发按钮/功能）。
## 仅 pacing 阶段（waiting_timing 50ms/格暂停）启用；弹窗显示时关闭让玩家交互。
var _move_overlay: Control = null
## 取消攻击按钮
var cancel_attack_button = null  # type: Button
## 辅助牌目标选择状态：正在选择目标的辅助牌ID
var _support_target_select_card_id: StringName = &""
## 辅助牌武器选择状态：正在选择武器的辅助牌ID（如聚能）
var _support_weapon_select_card_id: StringName = &""
## 辅助牌效果选择状态：正在选择效果的辅助牌ID
var _choice_select_card_id: StringName = &""
## 铠威攻击窗口确认弹窗是否正在展示（防 _refresh_battle 反复重弹）
var _attack_window_prompt_showing: bool = false
## 铠厉通用「被响应→抽2装备设置/弃置获金」确认弹窗是否正在展示（防反复重弹）
var _responded_equip_prompt_showing: bool = false
## 铠厉逐张「设置/弃置获金」面板是否在展示（面板按钮回调路由到 responded_equip_card 链而非 resume_effect）
var _responded_equip_set_active: bool = false
## 铠德「被响应→三选一」弹窗是否正在展示（防 _refresh_battle 反复重弹）
var _pilot_060_prompt_showing: bool = false
## 商店购买待确认状态：{kind: "normal"|"advanced", slot_index: int}
var _shop_buy_pending: Dictionary = {}
## 损伤转移弹窗上下文：{mech_id, to_slot, action_id}（A6 装备效果 redirect_select）
var _redirect_context: Dictionary = {}
## 锁步损伤放置：当前放置目标机甲 ID（_show_popup damage_token_placement 时记录，逐点 _net_exec 带上）
var _damage_placement_target_mech_id: StringName = &""
## 锁步损伤放置：当前面板对应的 damage_change 动作 ID（完成时直接恢复该动作，避免被并发的
## 装备离场效果弹窗覆盖 ActionUIBridge 单一等待动作槽，导致攻击牌卡在临时区）
var _damage_placement_action_id: StringName = &""
## 损伤调整面板（薇尔 pilot_059）：当前面板对应的效果挂起动作 ID（确认/取消时 resume_effect）
var _damage_adjust_action_id: StringName = &""
## 损伤面板挂起栈：攻击损伤放置中途被效果移除损伤打断时，挂起当前面板状态+动作ID+目标机甲，
## 待移除完成后恢复续操作（LIFO，支持嵌套）。解决两个 damage_change 交错复用单面板实例。
var _damage_suspend_stack: Array = []
## 模态弹窗堆栈（LIFO）：仅顶层面板可见可点；新弹窗入栈隐藏下层避免重影，
## 顶层 visible=false 时由 visibility_changed 自动出栈并恢复下层。
## 解决装备效果弹窗挤压重叠（问题1）与损伤面板+效果弹窗重叠（问题2）。
var _popup_stack: Array = []
var _popup_scrim: ColorRect = null
var _popup_suppress_vis: bool = false
var _popup_stylebox_cache: Dictionary = {}
var _POPUP_BG := Color(0.08, 0.09, 0.12, 1.0)
var _POPUP_ACCENT_COLORS := {
	&"damage_token_placement": Color(0.85, 0.75, 0.3),
	&"effect_choice": Color(0.45, 0.7, 1.0),
	&"choice_select": Color(0.45, 0.7, 1.0),
	&"use_card_confirm": Color(0.45, 0.7, 1.0),
	&"integer_select": Color(0.55, 0.85, 0.55),
	&"redirect_select": Color(0.9, 0.6, 0.4),
	&"discard_card_select": Color(0.75, 0.55, 0.95),
	&"thrust_select": Color(0.5, 0.85, 0.85),
	&"immediate_set_equipment": Color(0.6, 0.85, 0.5),
	&"unite_attack_select": Color(0.95, 0.6, 0.6),
	&"pilot_018_equipment_select": Color(0.7, 0.85, 0.6),
	&"pilot_025_reserve_select": Color(0.7, 0.85, 0.6),
	&"awaken_select": Color(0.95, 0.8, 0.4),
	&"weapon_select": Color(0.7, 0.7, 0.78),
	&"weapon_charge_select": Color(0.7, 0.7, 0.78),
	&"response_window": Color(0.85, 0.45, 0.45),
}
## 弃牌选择面板
var discard_select_panel = null  # type: DiscardSelectPanel
## pilot_009 美杜莎非阻塞可拖拽展示浮窗（展示目标行动牌，只弹给查看者）
var card_display_panel = null  # type: CardDisplayPanel
## 推进多选面板（推进 effect2：使用迎击牌时选若干推进一起打出）
var thrust_select_panel = null  # type: ThrustSelectPanel
var _thrust_select_action_id: StringName = &""
## 联合攻击单选面板（联合状态效果1：unite机甲攻击结算后 Target 选1张攻击牌联合攻击）
var unite_attack_select_panel = null  # type: UniteAttackSelectPanel
var pilot_003_skip_panel = null  # type: Pilot003SkipPanel
var _pilot_003_skip_action_id: StringName = &""
## pilot_003 effect_01 选置顶牌单选面板（复用 UniteAttackSelectPanel 通用化实例）
var pilot_003_choose_top_panel = null  # type: UniteAttackSelectPanel
var _pilot_003_choose_top_action_id: StringName = &""
var _unite_attack_action_id: StringName = &""
## 立即设置装备面板（effect_005：弃置抽1装备立即设置，不设置则弃置抽到的牌）
var immediate_set_equipment_panel = null  # type: ImmediateSetEquipmentPanel
var _immediate_set_action_id: StringName = &""
## pilot_014 亚伦选机师牌选框：缓存当前选项（含 pilot_instance/player_id/mech_id），供 _on_choice_made 回查。
var _pilot_014_select_options: Array = []
## pilot_032 爱瑞娅选机师牌选框：缓存当前选项（含 pilot_instance/player_id/mech_id），供 _on_choice_made 回查。
var _pilot_032_select_options: Array = []
## pilot_018 苔丝弃装备牌选框：缓存当前选项（card_id=装备 instance_id），供 _on_choice_made 回查。
var _pilot_018_select_options: Array[Dictionary] = []
## pilot_088 征服宣言类型选框：缓存当前选项（effect_id=type_攻击/迎击/辅助，declared_type=类型），供 _on_choice_made 回查。
var _pilot_088_type_options: Array = []
## 觉醒种类单选面板（觉醒效果：弃牌堆无预判/识破时选1种行动牌）
var awaken_select_panel = null  # type: AwakenSelectPanel
var _awaken_select_action_id: StringName = &""
## 牌堆信息弹窗
var deck_info_popup = null  # type: DeckInfoPopup
## 商店面板
var shop_panel = null  # type: ShopPanel
## 查看隐藏装备面板（霍恩 pilot_046 等 HIDDEN_VIEW_AND_ACQUIRE）
var hidden_card_view_panel = null  # type: HiddenCardViewPanel
## 隐藏获取当前等待动作 id（面板花费获取/关闭 → ui_confirmed 恢复）
var _hidden_view_action_id: StringName = &""
## effect_choice（choose_one_effect 二选一/确认）弹窗当前等待动作 id + 选项缓存：
## 弹窗打开时捕获（TimingEngine CHOOSE_ONE 挂起 emit 带 action_id），确认/取消走
## _net_exec("resume_effect") 精确路由。共享等待槽（ActionUIBridge._waiting_action_id）
## 是单槽，并发挂起（如杰狞伤害转移弹窗+损伤放置弹窗）时后者覆盖前者，
## 从槽读 action_id 会错路由/丢输入 -> hp_change 永久挂起、攻击不结算（bug1）。
var _effect_choice_action_id: StringName = &""
var _effect_choice_options: Array = []
## 卖出装备面板
var sell_equipment_panel = null  # type: SellEquipmentPanel
## 弃牌选择状态：正在弃牌的辅助牌ID
var _discard_select_card_id: StringName = &""
## 弃牌选择状态：弃牌信息
var _discard_select_pending: Dictionary = {}
## 迎击移动(回避/疾行/反击)缓存：攻击方可达范围(红色闪烁)。
## 攻击方在迎击移动期间不动，范围固定，缓存避免每次移动循环都重算 BFS。
## _evade_range_attacker_key 为 "attacker_id,weapon_range,attacker_pos" 用于校验缓存有效性。
var _evade_range_hexes: Array[Dictionary] = []
var _evade_range_attacker_key: String = ""
## 武器槽位选择状态：正在选择替换哪个武器槽的装备牌ID
var _weapon_slot_select_card_id: StringName = &""
## 设置操作状态：正在选择设置区域的装备牌ID
var _set_equipment_card_id: StringName = &""
## 卖出操作状态：是否正在执行卖出操作
var _sell_mode_active: bool = false
## 卖出装备按钮引用（用于更新文本）
var _sell_button: Button = null
## 2金币抽牌按钮引用（每我方回合1次，花2金币抽1张行动牌）
var _paid_draw_button: Button = null
## 设陷按钮引用（机甲拥有设陷状态时可用，点击记录当前位置）
var _set_trap_button: Button = null
## 美杜莎操控按钮引用（pilot_009：本回合弃行动牌记录类型后，列出受控目标的同类行动牌供使用）
var _medusa_control_button: Button = null
## 美杜莎操控选择中标记（复用 unite_attack_select 面板做单选，与联合攻击选择区分）
var _medusa_control_select_active: bool = false
## GeneratedActionEffects.build_all_effects 缓存（pilot_009 主动牌判定用，惰性构建一次）
var _pilot_009_all_effects_cache: Dictionary = {}
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
## 机雷设陷多格选格状态：剩余可放格 / 已选格 / 需选格数（双子机雷 count=2，逐格点击）
var _map_cell_select_valid: Array = []
var _map_cell_select_chosen: Array = []
## 回合结束流程挂起状态（end_turn 返回 suspended 时置位）：{active: bool, player_id: String}
## 玩家交互完成（end_turn_flow_completed 信号）后由 _on_end_turn_flow_completed 流转下家回合。
var _pending_turn_flow: Dictionary = {}
## pilot_006 里昂狩猎豁免：攻击数=0 豁免使用时，选目标只能选标记机甲（约束目标选择）。
## attack_target_select popup 时存，点击非标记机甲时拒绝。
var _pilot_006_forced_target: StringName = &""
var _map_cell_select_count: int = 1
## 选格弹窗对应的 TimingEngine 挂起动作 id（map_cell_select 打开时捕获）：
## 确认/取消走 resume_effect 按 id 精确路由。共享槽路径（ui_confirmed/ui_cancelled）在
## PvP 对端会被弹窗 owner 门控 skip_remote_waiting 清槽，广播的输入撞"槽空早return"被丢
## -> 对端永远停在选格挂起，三方不同步卡死（墨尘移至分支实机根因）。
var _map_cell_select_action_id: StringName = &""
## 多目标攻击选择（双连等）：_multi_attack_target_count>=2 时进入多选模式，
## 逐个点击目标机甲收集到 _multi_attack_target_chosen，选满或点"取消"（>=1时）提交。
var _multi_attack_target_chosen: Array = []  # [{"q","r","target_id"}]
var _multi_attack_target_count: int = 1
## 通用多选机甲（CHOOSE_MANY_MECHS，奥黛尔 pilot_038「选最多2台4格内机甲含我方」）：
## 非空时处于该模式。与攻击多选(_multi_attack_target_count>=2)区分：可含自己、有 min_count、
## 无陷阱目标。复用 _multi_attack_target_chosen/_multi_attack_target_count 收集/提交。
var _mech_multi_select_opts: Dictionary = {}
## 当前待处理的反击 pending（attack2）
var _counterattack_pending: Dictionary = {}
## 反击上下文：反击发生在哪一方的回合 ("player"/"enemy")
var _counterattack_turn: String = ""
## AI反击(玩家回合)状态：等待玩家对 attack2 进行迎击
var _ai_counterattack_active: bool = false
## 玩家回合内最近一次攻击(attack1)的结算结果，用于在其损伤放置完成后触发AI反击
var _last_player_attack_result: Dictionary = {}
## 新动作系统：是否使用新系统驱动 UI（默认 true，新系统为唯一入口）
var _use_new_action_system: bool = true
## enemy turn damage placement flag (replaces removed battle.enemy_turn_phase)
var _damage_placement_in_enemy_turn: bool = false
## 帧末合并刷新脏标记：同一帧内多个时点/动作完成信号只触发一次全量 _refresh_battle。
var _refresh_pending: bool = false
## 开发者模式
var dev_mode: bool = false
var dev_panel: Control = null  # type: DevModePanel

## ── PvP 测试模式（双窗口人类对人类）──
## game_mode: &"PVE"（原人类打AI）/ &"PVP"（双人类双窗口）
var game_mode: StringName = &"PVE"
## 本窗口控制的玩家 ID（host=player，client=enemy）。UI 面板按此显示己方视角。
var local_player_id: StringName = &"player"
## true = client 进程（只渲染 host 下发的快照 + 上行 intent，不本地执行逻辑）
var is_network_client: bool = false
## host 端 TCP 服务 / client 端 TCP 连接（Node，挂树跑 _process）
var net_host: Node = null
var net_client: Node = null
## PvP 通信端口
var _pvp_port: int = 0
## PvP 锁步同步随机种子（host 选取，发给 client；双端用同一种子 start_tutorial 建出相同牌堆）
var _pvp_seed: int = -1
## client 是否已收到种子并自建局（Phase 2：自建前忽略 snapshot）
var _pvp_self_built: bool = false
## PvP 开局机师三选一：本方候选池（host=前3 / client=host 发来的后3）
var _pvp_pilot_pool: Array = []
## client 候选机师 def_id 列表（host 生成，经 seed 消息发给 client）
var _pvp_client_pilot_ids: Array = []
## 本方已选机师 def_id
var _pvp_my_pilot_id: String = ""
## 对方已选机师 def_id 及其归属玩家（player/enemy）
var _pvp_remote_pilot_id: String = ""
var _pvp_remote_player_id: StringName = &""
## 是否已到 PvP 开局机师选择阶段（双方各自选择）
var _pvp_pilot_selecting: bool = false
## host spawn 出的 client 进程 PID（退出时 kill，避免遗留窗口/端口占用致无法开新局）
var _pvp_client_pid: int = -1
## 正在退出 PvP 会话（防 disconnect 回调与 session_end 互相重入）
var _pvp_exiting: bool = false
## PVP3 专用：2个 client 的机师候选 id（player_id[String] -> Array[String]）
var _pvp3_client_pilot_ids: Dictionary = {}
## PVP3 专用：2个 client 进程 pid（player_id[String] -> int）
var _pvp3_client_pids: Dictionary = {}
## PVP3 专用：已收到的对方机师选择（player_id[String] -> pilot_id[String]）
var _pvp_remote_pilots: Dictionary = {}

func _ready() -> void:
	set_process(true)
	_f3_held = false
	_force_maximize_window()
	_maximize_recheck_frames = 120  # 约2秒：覆盖子进程（PvP client）首帧窗口初始化覆盖 mode 的窗口期
	_load_app_state()

## 启动强制最大化窗口（兜底：project.godot mode=2 在某些环境/驱动下不生效）。
## headless（--headless 测试模式）跳过--无实际窗口，调用无意义。
func _force_maximize_window() -> void:
	if DisplayServer.get_name() == &"headless":
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)

## 首帧复查计数：>0 时每帧检查窗口是否仍为最大化（host spawn 的 client 进程首帧
## 窗口初始化可能把 _ready 设置的 MAXIMIZED 覆盖回 WINDOWED），不是则重设。
## 递减到 0 后不再干预（用户之后手动还原窗口化不被打扰）。
var _maximize_recheck_frames: int = 0

var _f3_held: bool = false

func _process(_delta: float) -> void:
	if _maximize_recheck_frames > 0:
		_maximize_recheck_frames -= 1
		if DisplayServer.get_name() != &"headless" \
				and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MAXIMIZED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	if Input.is_key_pressed(KEY_F3):
		if not _f3_held:
			_f3_held = true
			dev_mode = not dev_mode
			print("[DEV] F3 pressed, dev_mode=", dev_mode, " dev_panel=", dev_panel != null)
			if dev_panel:
				dev_panel.visible = dev_mode
				if dev_mode:
					# 置于最上层，确保不被其他 UI 遮挡
					move_child(dev_panel, -1)
					if battle and battle.context:
						dev_panel.setup(battle.context)
	else:
		_f3_held = false

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
	# 命令行启动 PvP：--pvp-host 直接当 host 开局（便于脚本化/自动化测试）
	var args := OS.get_cmdline_args()
	if args.has("--pvp-host"):
		_start_pvp_host()
		return
	if args.has("--pvp3-host"):
		_start_pvp3_host()
		return
	# PvP client 模式：跳过主菜单，直接连 host 等待快照
	if args.has("--pvp-client"):
		_start_pvp_client(args)
		return
	if args.has("--pvp3-client"):
		_start_pvp3_client(args)
		return
	_show_main_menu()

func _toggle_dev_mode() -> void:
	dev_mode = not dev_mode
	if dev_panel:
		dev_panel.visible = dev_mode
		if dev_mode and battle and battle.context:
			dev_panel.setup(battle.context)

func _on_dev_panel_close() -> void:
	dev_mode = false
	if dev_panel:
		dev_panel.visible = false

# ═══════════════════════════════════════════
# 主菜单
# ═══════════════════════════════════════════

## 战斗界面"返回主菜单"：PvP 走会话退出（通知对方+清理 TCP/子进程），PvE 直接回主菜单。
func _on_return_to_main_menu() -> void:
	if _is_pvp_mode():
		_quit_pvp_session()
	else:
		_show_main_menu()

func _show_main_menu() -> void:
	# PvP 会话中返回主菜单：先退出 PvP（通知对方+清理网络/子进程），host 会再次进入此方法显示菜单
	if _is_pvp_mode() and not _pvp_exiting:
		_quit_pvp_session()
		return
	var layout := _begin_screen("机斗战甲")
	_add_button(layout, "新战役", Callable(self, "_show_loadout"))
	_add_button(layout, "PvP测试模式", Callable(self, "_start_pvp_host"))
	_add_button(layout, "3人PvP测试", Callable(self, "_start_pvp3_host"))
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
	# vs-AI 每局随机牌堆顺序（测试默认 rng_seed=0 确定；PvP 用共享种子，各自在 _apply_pvp_seed_and_build 设）
	battle.rng_seed = randi()
	var start_result = battle.start_tutorial(registry)
	if not _status_ok(start_result):
		_show_status("战斗启动失败: %s" % _status_message(start_result))
		return
	_show_battle()
	var turn_result = battle.start_turn("player")
	if not _status_ok(turn_result):
		battle.log.append({"message": "玩家回合启动失败", "details": {"reason": _status_message(turn_result)}})
	call_deferred("_refresh_battle")  # 首回合 start_turn 后刷新抽牌/金币到 UI

# ═══════════════════════════════════════════
# 战斗界面 — 左右分区布局
# ═══════════════════════════════════════════

# ═══════════════════════════════════════════
# PvP 测试模式（双窗口人类对人类）
# ═══════════════════════════════════════════

## 是否处于 PvP 模式（2人 PVP 或 3人 PVP3，均走锁步：广播 input / 无 AI 驱动 / 切对手回合）。
func _is_pvp_mode() -> bool:
	return game_mode == &"PVP" or game_mode == &"PVP3"

## 对手玩家 ID（1v1：除 local_player_id 外的玩家）
func _opponent_player_id() -> StringName:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return &"enemy" if local_player_id == &"player" else &"player"
	return battle.context.game_state.get_opponent_player_id(local_player_id)

## 主菜单「PvP测试模式」：以 host 启动，建 PvP 局，开 NetHost，spawn client 进程
func _start_pvp_host() -> void:
	# 清理上一轮 PvP 残留（旧 net_host 端口占用 / 旧 client 进程），否则新局监听端口失败
	_pvp_cleanup()
	_reset_pvp_state()
	_pvp_port = 45678
	game_mode = &"PVP"
	local_player_id = &"player"
	is_network_client = false
	# 锁步：host 选取随机种子，建局后发给 client，双端用同种子 start_tutorial 产出相同牌堆
	_pvp_seed = randi()
	battle = _BattleState.new()
	battle.rng_seed = _pvp_seed
	battle.pvp_map_features = true
	var start_result = battle.start_tutorial(registry)
	if not _status_ok(start_result):
		_show_status("PvP 战斗启动失败: %s" % _status_message(start_result))
		return
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	# 窗口标题区分 host/client
	DisplayServer.window_set_title("机斗战甲 [PvP - 玩家/host]")
	# 启动 NetHost
	net_host = _NetHost.new()
	add_child(net_host)
	var host_err = net_host.start(_pvp_port)
	if host_err != OK:
		_show_status("PvP 监听端口 %d 失败: %d" % [_pvp_port, host_err])
		return
	net_host.client_connected.connect(_on_pvp_client_connected)
	net_host.client_disconnected.connect(_on_pvp_client_disconnected)
	net_host.message_received.connect(_on_pvp_host_message)
	# spawn client 进程（enemy 窗）
	_spawn_pvp_client()
	# 开局机师三选一：共享种子产出 3 候选（双端一致），双方同时选。
	# host 立即弹本方选择屏；client 连上收到种子后也立即弹本方选择屏（不等 host 选完）。
	# 双方都选完由 _check_pvp_both_selected 统一开战（PvP 锁步）。
	_generate_pvp_pilot_pool()
	_pvp_pilot_selecting = true
	_show_pvp_pilot_select("host")
	battle.log.append({"message": "[PvP] host 已启动，请选择机师（client 连上后可同时选择，双方都选完开战）...", "details": {}})


## 已落码机师判断：001-088 全量落码，全部放行。
## 若未来新增尚未落码的机师，在此恢复按 id 过滤。
func _is_pilot_implemented(_pilot_id: String) -> bool:
	return true


## 从已落码机师池洗牌取 n 张。
## 注意：这里必须用独立 RNG，不能消耗 battle.context.rng--候选池只由 host 生成，
## 结果经 seed 消息（client_pilot_ids）发给 client，client 不重算；若走同步随机流，
## host 会比 client 多消耗 N-1 次随机数，后续所有 synced 随机（骰子/重洗牌/随机槽位）
## 双端永久分叉，锁步 desync。
func _shuffle_implemented_pilots(n: int) -> Array:
	if registry == null:
		return []
	var all_pilots: Array = []
	for item in registry.list_pilot_cards():
		if typeof(item) == TYPE_DICTIONARY and _is_pilot_implemented(String(item.get("id", ""))):
			all_pilots.append(item)
	if all_pilots.is_empty():
		return []
	var rng := RandomNumberGenerator.new()
	for i in range(all_pilots.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = all_pilots[i]
		all_pilots[i] = all_pilots[j]
		all_pilots[j] = tmp
	var result: Array = []
	for i in range(mini(n, all_pilots.size())):
		result.append(all_pilots[i])
	return result


## 生成 PvP 开局机师候选池：host 与 client 各自独立 3 张（共 6 张不重复）。
## host 端从已落码池洗牌取 6，前 3 为本方候选 _pvp_pilot_pool，后 3 为 client 候选
## _pvp_client_pilot_ids（经 seed 消息发给 client）。
func _generate_pvp_pilot_pool() -> void:
	_pvp_pilot_pool = []
	_pvp_client_pilot_ids = []
	var six: Array = _shuffle_implemented_pilots(6)
	if six.size() < 6:
		# 已落码不足 6（理论不会：001-088 共 88 张），退化为双端共享前 3
		_pvp_pilot_pool = six.duplicate()
		return
	for i in range(3):
		_pvp_pilot_pool.append(six[i])
	for i in range(3, 6):
		var item: Dictionary = six[i]
		_pvp_client_pilot_ids.append(String(item.get("id", "")))


## 生成 PVP3 开局机师候选池：9 张分 3 组各 3（host/player + enemy + third，不重复）。
## host 端从已落码池洗牌取 9：前 3 为本方候选 _pvp_pilot_pool，中 3 为 enemy 候选，
## 后 3 为 third 候选（存 _pvp3_client_pilot_ids，经 seed 消息定向发给各 client）。
func _generate_pvp3_pilot_pool() -> void:
	_pvp_pilot_pool = []
	_pvp3_client_pilot_ids = {}
	var nine: Array = _shuffle_implemented_pilots(9)
	if nine.size() < 9:
		# 已落码不足 9（理论不会：001-088 共 88 张），退化为三方共享前 3
		_pvp_pilot_pool = nine.duplicate()
		return
	for i in range(3):
		_pvp_pilot_pool.append(nine[i])
	var enemy_ids: Array = []
	for i in range(3, 6):
		enemy_ids.append(String(nine[i].get("id", "")))
	_pvp3_client_pilot_ids["enemy"] = enemy_ids
	var third_ids: Array = []
	for i in range(6, 9):
		third_ids.append(String(nine[i].get("id", "")))
	_pvp3_client_pilot_ids["third"] = third_ids


## client 端收到 host 发的本方候选 id 列表后，建 _pvp_pilot_pool（按 id 从 registry 查字典）。
func _build_client_pilot_pool_from_ids(ids: Array) -> void:
	_pvp_pilot_pool = []
	if registry == null:
		return
	for raw_id in ids:
		var pid: String = String(raw_id)
		if pid == "":
			continue
		for item in registry.list_pilot_cards():
			if typeof(item) == TYPE_DICTIONARY and String(item.get("id", "")) == pid:
				_pvp_pilot_pool.append(item)
				break


## 显示 PvP 开局机师三选一屏（本方候选 _pvp_pilot_pool）。双方各自独立选择，不冲突。
func _show_pvp_pilot_select(side: String) -> void:
	var layout := _begin_screen("选择机师")
	_add_text(layout, "从以下 3 名机师中选择 1 名（双方各自选择，互不影响）。")
	if not _pvp_pilot_pool.is_empty():
		for item in _pvp_pilot_pool:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var pid: String = String(item.get("id", ""))
			if pid == "":
				continue
			var cost: int = int(item.get("cost", 0))
			var btn := Button.new()
			var is_mine: bool = String(_pvp_my_pilot_id) == pid
			btn.text = "%s [%s/%s] 费用%d%s" % [
				String(item.get("name", pid)), String(item.get("rarity", "")), String(item.get("faction", "")), cost,
				"（已选）" if is_mine else ""
			]
			btn.custom_minimum_size = Vector2(480, 44)
			btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			var p_id = pid
			btn.pressed.connect(Callable(self, "_on_pvp_pilot_picked").bind(p_id))
			layout.add_child(btn)
			# 技能文本预览（小字）
			var eff := String(item.get("effect_text", ""))
			if eff.strip_edges() != "":
				var eff_label := Label.new()
				eff_label.text = "  技能：%s" % eff
				eff_label.autowrap_mode = TextServer.AUTOWRAP_WORD
				eff_label.add_theme_font_size_override("font_size", 12)
				eff_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
				eff_label.custom_minimum_size = Vector2(520, 0)
				eff_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				layout.add_child(eff_label)
	_add_button(layout, "返回主菜单", Callable(self, "_show_main_menu"))


## 玩家点选机师：记录本方选择并广播。不立即 set_pilot——等双方都选完由
## _pvp_both_pilots_ready 按固定顺序（player→enemy）统一 set_pilot，保证双端锁步 instance_id 一致。
func _on_pvp_pilot_picked(pilot_id: String) -> void:
	if _pvp_my_pilot_id != "":
		return  # 已选，忽略重复点击
	_pvp_my_pilot_id = pilot_id
	_send_pilot_select(pilot_id)
	_show_pvp_pilot_select("host" if not is_network_client else "client")  # 刷新屏显示"已选"
	if game_mode == &"PVP3":
		_check_pvp3_all_selected()
	else:
		_check_pvp_both_selected()


## 发送机师选择给对方（host→client / client→host，直发不经 _dispatch_input 避免本地重复 set_pilot）。
## host 若在 client 连上前已选，先记下，client 连上后由 _on_pvp_client_connected 补发。
func _send_pilot_select(pilot_id: String) -> void:
	var msg := {"type": "input", "op": "pilot_select", "data": {"pilot_id": pilot_id, "player_id": String(local_player_id)}, "sender": String(local_player_id)}
	if is_network_client:
		if net_client != null and net_client.is_connected_to_host():
			net_client.send(msg)
	elif net_host != null and net_host.is_client_connected():
		net_host.send(msg)


## 收到对方机师选择：记录（含归属玩家），双方都选完则开回合。
func _on_remote_pilot_select(data: Dictionary) -> void:
	var remote_pid: String = String(data.get("pilot_id", ""))
	var remote_player: String = String(data.get("player_id", ""))
	if remote_player == "" or remote_pid == "":
		return
	if game_mode == &"PVP3":
		# PVP3：记入字典（player_id -> pilot_id），三方都选完才开战
		_pvp_remote_pilots[remote_player] = remote_pid
		_check_pvp3_all_selected()
		return
	_pvp_remote_pilot_id = remote_pid
	_pvp_remote_player_id = StringName(remote_player)
	# 同时选择：本方选择屏已在 _apply_pvp_seed_and_build(client)/_start_pvp_host(host) 弹出，
	# 此处仅记录对方选择；双方都选完由 _check_pvp_both_selected 统一开战。
	_check_pvp_both_selected()


## 双方机师都已选定（本方 + 对方）→ 按固定顺序 set_pilot(player→enemy) 再开战斗。
## 顺序固定保证双端锁步 instance_id 一致（host=player 选择、client=enemy 选择）。
func _check_pvp_both_selected() -> void:
	if _pvp_my_pilot_id == "" or _pvp_remote_pilot_id == "":
		return
	if not _pvp_pilot_selecting:
		return
	_pvp_pilot_selecting = false
	# 解析 player/enemy 各自的机师 def_id：host(player 方) 选的是 _pvp_my_pilot_id，
	# client(enemy 方) 选的是 _pvp_remote_pilot_id；反过来对 client 亦然。统一按玩家归属取。
	var player_pilot: String = _pvp_my_pilot_id if String(local_player_id) == "player" else _pvp_remote_pilot_id
	var enemy_pilot: String = _pvp_remote_pilot_id if String(local_player_id) == "player" else _pvp_my_pilot_id
	if battle == null or battle.context == null or battle.context.game_state == null:
		return
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech != null and player_pilot != "":
		_apply_pvp_pilot_to_mech(player_mech, player_pilot)
	if enemy_mech != null and enemy_pilot != "":
		_apply_pvp_pilot_to_mech(enemy_mech, enemy_pilot)
	# 开始战斗（先刷新一遍让 set_pilot 数值生效）
	_show_battle()
	var turn_result = battle.start_turn("player")
	if not _status_ok(turn_result):
		battle.log.append({"message": "玩家回合启动失败", "details": {"reason": _status_message(turn_result)}})
	call_deferred("_refresh_battle")  # 首回合 start_turn 后刷新抽牌/金币到 UI
	battle.log.append({"message": "[PvP] 双方机师已选，战斗开始", "details": {}})


## PVP3：三方机师都已选定（本方 + 2 对手）-> 按固定顺序 set_pilot(player->enemy->third) 再开战斗。
## 顺序固定保证三方锁步 instance_id 一致。
func _check_pvp3_all_selected() -> void:
	if _pvp_my_pilot_id == "":
		return
	if not _pvp_pilot_selecting:
		return
	# 需收到除本方外两方选择（player/enemy/third 中非 local 的两个；client 视角对手含 player）
	for check_pid: StringName in [&"player", &"enemy", &"third"]:
		if check_pid == local_player_id:
			continue
		if not _pvp_remote_pilots.has(String(check_pid)):
			return
	_pvp_pilot_selecting = false
	# 解析三方机师 def_id：本方选择 = _pvp_my_pilot_id，对手选择 = _pvp_remote_pilots[pid]
	var pilots: Dictionary = {}
	pilots[String(local_player_id)] = _pvp_my_pilot_id
	for pid_key in _pvp_remote_pilots.keys():
		pilots[pid_key] = _pvp_remote_pilots[pid_key]
	if battle == null or battle.context == null or battle.context.game_state == null:
		return
	var gs = battle.context.game_state
	# 按固定顺序 player->enemy->third set_pilot（锁步 instance_id 一致）
	for pid: StringName in [&"player", &"enemy", &"third"]:
		var pilot_def_id: String = pilots.get(String(pid), "")
		if pilot_def_id == "":
			continue
		var mech = gs.get_mech_for_player(pid)
		if mech != null:
			_apply_pvp_pilot_to_mech(mech, pilot_def_id)
	# 开始战斗（先刷新让 set_pilot 数值生效）
	_show_battle()
	var turn_result = battle.start_turn("player")
	if not _status_ok(turn_result):
		battle.log.append({"message": "玩家回合启动失败", "details": {"reason": _status_message(turn_result)}})
	call_deferred("_refresh_battle")
	battle.log.append({"message": "[PVP3] 三方机师已选，战斗开始", "details": {}})


## 给指定机甲 set_pilot（建机师牌实例 + 注册效果 + 数值联动）。
func _apply_pvp_pilot_to_mech(mech, pilot_def_id: String) -> void:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return
	var pid_def = battle.context.card_database.get_card(StringName(pilot_def_id)) if battle.context.card_database != null else null
	if pid_def == null:
		return
	var inst_id: StringName = battle.context.game_state.next_id(&"pilot")
	var card = _CardInstance.new(inst_id, pid_def)
	card.owner_player_id = mech.owner_player_id
	battle.context.game_state.cards[inst_id] = card
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	# 扣除机师初始花费金币（与 campaign select_pilot_with_cost 一致；开局选机师即付费）
	# 在 start_turn(+2金币) 之前扣，双端各自按相同 pilot_def 扣除保持锁步一致
	var cost: int = int(pid_def.cost) if pid_def.get("cost") != null else 0
	if cost > 0:
		var payer = battle.context.game_state.get_player_for_mech(mech.mech_id)
		if payer != null:
			payer.gold = maxi(0, payer.gold - cost)
func _spawn_pvp_client() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var arg_list := ["--path", proj, "--pvp-client", "--pvp-port", str(_pvp_port), "--pvp-local-player", "enemy"]
	if DisplayServer.get_name() == "headless":
		arg_list.push_front("--headless")
	# 继承 host 的渲染驱动参数（如 --rendering-driver opengl3），
	# 否则 client 子进程用默认 Vulkan/D3D12，在不支持的环境启动即闪退
	var cmdline := OS.get_cmdline_args()
	for i in range(cmdline.size()):
		var a := String(cmdline[i])
		if a == "--rendering-driver" and i + 1 < cmdline.size():
			arg_list.push_back("--rendering-driver")
			arg_list.push_back(String(cmdline[i + 1]))
			break
		elif a.begins_with("--rendering-driver="):
			arg_list.push_back(a)
			break
	var args := PackedStringArray(arg_list)
	var pid = OS.create_process(exe, args, false)
	if pid == -1:
		battle.log.append({"message": "[PvP] 启动 client 进程失败", "details": {"exe": exe}})
	else:
		_pvp_client_pid = pid
		battle.log.append({"message": "[PvP] 已 spawn client 进程 pid=%d" % pid, "details": {}})

## client 进程入口：解析参数，建渲染用 context，连 host，显示空战斗界面等快照
func _start_pvp_client(args: PackedStringArray) -> void:
	is_network_client = true
	game_mode = &"PVP"
	local_player_id = &"enemy"
	var port := 45678
	for i in range(args.size()):
		if String(args[i]) == "--pvp-port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif String(args[i]) == "--pvp-local-player" and i + 1 < args.size():
			local_player_id = StringName(String(args[i + 1]))
	_pvp_port = port
	# 窗口标题 + 位置偏移，方便与 host 窗区分（用户可拖到第二显示器）
	DisplayServer.window_set_title("机斗战甲 [PvP - 敌方/client]")
	# 仅窗口化时偏移（最大化时偏移无意义且可能取消最大化--启动已强制最大化）
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_position(DisplayServer.window_get_position() + Vector2i(60, 40))
	# 一段式启动（与 host 一致）：不建临时 context，先连 host 等种子；种子到达后
	# _apply_pvp_seed_and_build 调 start_tutorial + _show_battle 建真实 context 并连信号。
	# 避免"临时 context + 自建替换"导致 action_ui_bridge 信号断裂、弹窗不弹。
	_begin_screen("PvP 连接中")
	_show_status("正在连接 host (port %d)..." % port)
	# 连 host
	net_client = _NetClient.new()
	net_client.local_player_id = local_player_id
	add_child(net_client)
	net_client.connected_to_host.connect(_on_pvp_connected_to_host)
	net_client.disconnected_from_host.connect(_on_pvp_disconnected)
	net_client.message_received.connect(_on_pvp_client_message)
	net_client.connect_to(port)


## client 收到 host 种子后自建局（同种子 start_tutorial 产出与 host 相同的牌堆/初始状态）。
## 一段式：start_tutorial 建真实 context -> _show_battle 建面板并连信号（与 host 完全一致），
## 不再有"临时 context + 替换"两段式，故不会出现信号断裂。
func _apply_pvp_seed_and_build(seed: int, client_pilot_ids: Array = []) -> void:
	if _pvp_self_built:
		return
	_pvp_seed = seed
	if battle == null:
		battle = _BattleState.new()
	battle.rng_seed = seed
	battle.pvp_map_features = true
	var start_result = battle.start_tutorial(registry)
	if not _status_ok(start_result):
		_show_status("PvP 自建局失败: %s" % _status_message(start_result))
		return
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	_pvp_self_built = true
	# client 本方候选 = host 发来的 3 个机师 id（与 host 的 3 个不重复，共 6 张）。
	# 双方各自独立选择，回合稍后由 _check_pvp_both_selected 统一 start_turn（PvP 锁步）。
	_build_client_pilot_pool_from_ids(client_pilot_ids)
	_pvp_pilot_selecting = true
	# 同时选择：client 拿到本方候选池即弹选择屏，不等 host 选完。
	# 双方各自独立选，都选完由 _check_pvp_both_selected 统一开战（PvP 锁步）。
	_show_pvp_pilot_select("client")
	# _begin_screen -> _clear_screen 会断开动作信号，须重连（_show_battle 末尾也会重连，幂等）。
	_connect_action_signals()


## 主菜单「3人PvP测试」：host 启动 3人局，开 NetHost(max_clients=2)，spawn 2 个 client 进程。
## host 控制 player；enemy/third 各为独立 client 窗口。星型拓扑：host 中继 client<->client input。
func _start_pvp3_host() -> void:
	_pvp_cleanup()
	_reset_pvp_state()
	_pvp_port = 45678
	game_mode = &"PVP3"
	local_player_id = &"player"
	is_network_client = false
	# 锁步：host 选取随机种子，发给 2 个 client，三方用同种子 start_pvp3 产出相同牌堆
	_pvp_seed = randi()
	battle = _BattleState.new()
	battle.rng_seed = _pvp_seed
	battle.pvp_map_features = true
	var start_result = battle.start_pvp3(registry)
	if not _status_ok(start_result):
		_show_status("PVP3 战斗启动失败: %s" % _status_message(start_result))
		return
	# start_pvp3 已设三方 is_human=true
	DisplayServer.window_set_title("机斗战甲 [PVP3 - 玩家/host]")
	# 启动 NetHost（max_clients=2）
	net_host = _NetHost.new()
	add_child(net_host)
	var host_err = net_host.start(_pvp_port, 2)
	if host_err != OK:
		_show_status("PVP3 监听端口 %d 失败: %d" % [_pvp_port, host_err])
		return
	net_host.client_connected.connect(_on_pvp3_client_connected)
	net_host.client_disconnected.connect(_on_pvp_client_disconnected)
	net_host.message_received.connect(_on_pvp_host_message)
	# spawn 2 个 client 进程（enemy 窗 + third 窗）
	_spawn_pvp3_client(&"enemy")
	_spawn_pvp3_client(&"third")
	# 开局机师九选一：共享种子产出 9 候选分 3 组（host3+enemy3+third3，不重复）
	_generate_pvp3_pilot_pool()
	_pvp_pilot_selecting = true
	_show_pvp_pilot_select("host")
	battle.log.append({"message": "[PVP3] host 已启动，请选择机师（2 个 client 连上后可同时选择，三方都选完开战）...", "details": {}})


## spawn 1 个 PVP3 client 进程（player_id=enemy/third）。
func _spawn_pvp3_client(player_id: StringName) -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var arg_list := ["--pvp3-client", "--pvp-port", str(_pvp_port), "--pvp-local-player", String(player_id)]
	if DisplayServer.get_name() == "headless":
		arg_list.push_front("--headless")
	# 继承 host 的渲染驱动参数（见 _spawn_pvp_client 注释）
	var cmdline := OS.get_cmdline_args()
	for i in range(cmdline.size()):
		var a := String(cmdline[i])
		if a == "--rendering-driver" and i + 1 < cmdline.size():
			arg_list.push_back("--rendering-driver")
			arg_list.push_back(String(cmdline[i + 1]))
			break
		elif a.begins_with("--rendering-driver="):
			arg_list.push_back(a)
			break
	var args := PackedStringArray(arg_list)
	var pid = OS.create_process(exe, args, false)
	if pid == -1:
		battle.log.append({"message": "[PVP3] 启动 %s client 进程失败" % String(player_id), "details": {"exe": exe}})
	else:
		_pvp3_client_pids[String(player_id)] = pid
		battle.log.append({"message": "[PVP3] 已 spawn %s client 进程 pid=%d" % [String(player_id), pid], "details": {}})


## PVP3 client 进程入口：解析参数（--pvp-local-player=enemy/third），连 host，显示空界面等种子。
func _start_pvp3_client(args: PackedStringArray) -> void:
	is_network_client = true
	game_mode = &"PVP3"
	local_player_id = &"enemy"  # 默认，下方按参数覆盖
	var port := 45678
	for i in range(args.size()):
		if String(args[i]) == "--pvp-port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif String(args[i]) == "--pvp-local-player" and i + 1 < args.size():
			local_player_id = StringName(String(args[i + 1]))
	_pvp_port = port
	# 窗口标题 + 位置偏移，三方窗区分
	DisplayServer.window_set_title("机斗战甲 [PVP3 - %s/client]" % String(local_player_id))
	var offset := Vector2i(60, 40) if local_player_id == &"enemy" else Vector2i(120, 80)
	# 仅窗口化时偏移（最大化时偏移无意义且可能取消最大化--启动已强制最大化）
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_position(DisplayServer.window_get_position() + offset)
	_begin_screen("PVP3 连接中")
	_show_status("正在连接 host (port %d)..." % port)
	# 连 host
	net_client = _NetClient.new()
	net_client.local_player_id = local_player_id
	add_child(net_client)
	net_client.connected_to_host.connect(_on_pvp_connected_to_host)
	net_client.disconnected_from_host.connect(_on_pvp_disconnected)
	net_client.message_received.connect(_on_pvp_client_message)
	net_client.connect_to(port)


## PVP3 client 收到 host 种子后自建局（同种子 start_pvp3 产出与 host 相同牌堆/初始状态）。
func _apply_pvp3_seed_and_build(seed_val: int, client_pilot_ids: Array = []) -> void:
	if _pvp_self_built:
		return
	_pvp_seed = seed_val
	if battle == null:
		battle = _BattleState.new()
	battle.rng_seed = seed_val
	battle.pvp_map_features = true
	var start_result = battle.start_pvp3(registry)
	if not _status_ok(start_result):
		_show_status("PVP3 自建局失败: %s" % _status_message(start_result))
		return
	_pvp_self_built = true
	# client 本方候选 = host 定向发来的 3 个机师 id
	_build_client_pilot_pool_from_ids(client_pilot_ids)
	_pvp_pilot_selecting = true
	_show_pvp_pilot_select("client")
	_connect_action_signals()


# ═══════════════════════════════════════════
# PvP 会话退出与清理
# ═══════════════════════════════════════════

## 退出 PvP 会话：通知对方 -> 清理网络/子进程 -> 重置状态。
# 任一玩家"返回主菜单"或断线时调用。host 回主菜单（可开新局），client 关窗（spawn 进程）。
# 双方都清理 TCP 与 client 子进程，确保端口/进程释放，可立即开新一轮 PvP 测试。
func _quit_pvp_session() -> void:
	if not _is_pvp_mode():
		return
	if _pvp_exiting:
		return
	_pvp_exiting = true
	var was_client := is_network_client
	# 通知对方退出（对方收到 session_end 或检测到断线后各自清理；断线兜底）
	_broadcast_session_end()
	_pvp_cleanup()
	_reset_pvp_state()
	if was_client:
		# client 是 host spawn 的子进程：直接关窗（不回主菜单，避免遗留第二窗口）
		get_tree().quit()
	else:
		# host 回主菜单，可点"PvP测试模式"开新一轮
		_show_main_menu()


## 向对方下发 session_end（若仍连接）。cleanup 前调用，确保对方能收到主动退出信号。
func _broadcast_session_end() -> void:
	var msg := {"type": "session_end"}
	if is_network_client:
		if net_client != null and net_client.is_connected_to_host():
			net_client.send(msg)
	elif net_host != null and net_host.is_client_connected():
		net_host.send(msg)


## 停止 TCP（host stop / client disconnect）并 kill host spawn 的 client 子进程。
func _pvp_cleanup() -> void:
	if net_host != null:
		net_host.stop()
		if is_instance_valid(net_host):
			net_host.queue_free()
		net_host = null
	if net_client != null:
		net_client.disconnect_from_host()
		if is_instance_valid(net_client):
			net_client.queue_free()
		net_client = null
	# host 杀掉 spawn 的 client 进程，确保其窗口关闭、端口释放
	if _pvp_client_pid > 0:
		OS.kill(_pvp_client_pid)
		_pvp_client_pid = -1
	# PVP3：杀掉 spawn 的 2 个 client 进程
	for pid_key in _pvp3_client_pids.keys():
		var cpid: int = int(_pvp3_client_pids[pid_key])
		if cpid > 0:
			OS.kill(cpid)
	_pvp3_client_pids.clear()


## 重置所有 PvP 相关状态（清理后调用，为新局铺路）。
func _reset_pvp_state() -> void:
	game_mode = &"PVE"
	is_network_client = false
	_pvp_self_built = false
	_pvp_seed = -1
	_pvp_client_pid = -1
	_pvp_exiting = false
	# 丢弃旧战斗状态（含旧 context 的动作/时点引擎），避免与新局串味
	battle = null
	# 机师选择状态清零（新局重建）
	_pvp_pilot_pool = []
	_pvp_client_pilot_ids = []
	_pvp_my_pilot_id = ""
	_pvp_remote_pilot_id = ""
	_pvp_remote_player_id = &""
	_pvp_pilot_selecting = false
	# PVP3 专用状态清零
	_pvp3_client_pilot_ids.clear()
	_pvp3_client_pids.clear()
	_pvp_remote_pilots.clear()


# ── host 端回调 ──

func _on_pvp_client_connected() -> void:
	if battle != null:
		battle.log.append({"message": "[PvP] client 已连接", "details": {}})
	# 锁步：先发种子（含 client 本方候选机师 id），client 收到后自建局 + 建本方候选池
	if net_host != null and net_host.is_client_connected():
		net_host.send({"type": "seed", "seed": _pvp_seed, "client_pilot_ids": _pvp_client_pilot_ids})
		# host 若已先选好机师，补发给 client（双方都选完才开战）
		if _pvp_my_pilot_id != "":
			net_host.send({"type": "input", "op": "pilot_select", "data": {"pilot_id": _pvp_my_pilot_id, "player_id": String(local_player_id)}})
	_refresh_battle()


## PVP3 host：client 连上（hello 带 player_id）-> 按玩家定向发种子 + 该 client 的候选机师 id。
func _on_pvp3_client_connected(player_id: StringName) -> void:
	if battle != null:
		battle.log.append({"message": "[PVP3] client %s 已连接" % String(player_id), "details": {}})
	if net_host == null or not net_host.is_client_connected(player_id):
		return
	var pilot_ids: Array = _pvp3_client_pilot_ids.get(String(player_id), [])
	net_host.send_to(player_id, {"type": "seed", "seed": _pvp_seed, "client_pilot_ids": pilot_ids})
	# host 若已先选好机师，补发给该 client（三方都选完才开战）
	if _pvp_my_pilot_id != "":
		net_host.send_to(player_id, {"type": "input", "op": "pilot_select", "data": {"pilot_id": _pvp_my_pilot_id, "player_id": String(local_player_id)}, "sender": String(local_player_id)})


func _on_pvp_client_disconnected(_player_id: StringName = &"") -> void:
	if battle != null:
		battle.log.append({"message": "[PvP] client 断开", "details": {}})
	# client 断开（关窗/退出/崩溃）-> host 自动退出 PvP 回主菜单（_pvp_exiting 守卫防自身退出时重入）
	if _is_pvp_mode() and not _pvp_exiting:
		_quit_pvp_session()

## host 收到 client 的 intent：按 action 分发，以 client 的玩家身份执行
func _on_pvp_host_message(msg: Variant) -> void:
	if battle == null or battle.context == null:
		return
	if typeof(msg) != TYPE_DICTIONARY:
		return
	var d: Dictionary = msg
	# Phase 3 锁步:对等输入交换(host 收 client 的 input,本地执行)
	if String(d.get("type", "")) == "input":
		_apply_remote_input(String(d.get("op", "")), d.get("data", {}))
		# PVP3 星型中继：host 收 client input 后广播给所有 client（发送方按 sender 跳过，避免重复执行）
		if game_mode == &"PVP3" and net_host != null and net_host.is_client_connected():
			net_host.send(d)
	elif String(d.get("type", "")) == "session_end":
		# client 主动退出 -> host 自动退出回主菜单
		_quit_pvp_session()

## 开发者模式编辑请求：走 _net_exec(dev_edit) 双端应用
func _on_dev_edit_requested(op: StringName, params: Dictionary) -> void:
	_net_exec("dev_edit", {"op": op, "params": params})


## 应用开发者模式编辑（host 真实 context）。逻辑与 DevModePanel 各 op 一致。
func _apply_dev_edit(op: StringName, params: Dictionary) -> void:
	var gs = battle.context.game_state
	var target: StringName = params.get("target", &"")
	if target == &"" or not gs.players.has(target):
		return
	var player = gs.players.get(target)
	var mech = gs.get_mech_for_player(target)
	var db = battle.context.card_database
	var ctx = battle.context
	match op:
		&"add_action_card":
			var def = db.get_card(params.get("card_id", &"")) if db != null else null
			if def != null:
				var inst = _CardInstance.new(gs.next_id("card"), def)
				inst.owner_player_id = target
				inst.mech_id = mech.mech_id if mech else &""
				inst.zone = &"action_hand"
				gs.cards[inst.instance_id] = inst
				player.action_hand.append(inst.instance_id)
				ctx.register_hand_card_availability(inst.instance_id)
		&"discard_all_action_cards":
			for cid: StringName in player.action_hand.duplicate():
				ctx.unregister_hand_card_availability(cid)
				var c = gs.get_card(cid)
				if c: c.zone = &"discard"
				player.action_hand.erase(cid)
		&"discard_one_action_card":
			if not player.action_hand.is_empty():
				var cid: StringName = player.action_hand[0]
				ctx.unregister_hand_card_availability(cid)
				var c = gs.get_card(cid)
				if c: c.zone = &"discard"
				player.action_hand.erase(cid)
		&"add_equipment_card":
			var def = db.get_card(params.get("card_id", &"")) if db != null else null
			if def != null:
				var inst = _CardInstance.new(gs.next_id("card"), def)
				inst.owner_player_id = target
				inst.mech_id = mech.mech_id if mech else &""
				inst.zone = &"equipment_hand"
				gs.cards[inst.instance_id] = inst
				player.equipment_hand.append(inst.instance_id)
		&"set_equipment_to_slot":
			var card_def_id: StringName = params.get("card_def_id", &"")
			var slot_id: StringName = params.get("slot_id", &"")
			var equip_card_id: StringName = &""
			for cid: StringName in player.equipment_hand:
				var c = gs.get_card(cid)
				if c and c.def and c.def.card_id == card_def_id:
					equip_card_id = cid
					break
			if equip_card_id == &"":
				var def = db.get_card(card_def_id) if db != null else null
				if def == null:
					return
				var inst = _CardInstance.new(gs.next_id("card"), def)
				inst.owner_player_id = target
				inst.mech_id = mech.mech_id if mech else &""
				inst.zone = &"equipment_hand"
				gs.cards[inst.instance_id] = inst
				player.equipment_hand.append(inst.instance_id)
				equip_card_id = inst.instance_id
			ctx.card_set_service.set_equipment(target, equip_card_id, slot_id)
		&"discard_all_equipment_cards":
			for cid: StringName in player.equipment_hand.duplicate():
				ctx.deck_service.discard_card(cid, &"dev_mode")
			player.equipment_hand.clear()
		&"unequip_all_equipment":
			if mech:
				for sid: StringName in mech.slots:
					var slot = mech.slots[sid]
					if slot.equipped_card != null:
						ctx.deck_service.discard_card(slot.equipped_card.instance_id, &"replaced")
						slot.equipped_card = null
		&"add_region_damage":
			var ard_sid: StringName = params.get("slot_id", &"")
			if mech and mech.slots.has(ard_sid):
				# 双计：region + 装备卡 damage_tokens，与正常 DamageTokenService 一致，
				# 使装备面板在有装备卡时也能显示损伤（直接改数字，不触发损坏/时点——额外权限）
				var ard_slot = mech.slots[ard_sid]
				ard_slot.region_damage_tokens += 1
				if ard_slot.equipped_card != null:
					ard_slot.equipped_card.damage_tokens += 1
				mech.recalc_power_limits()  # 派生动力(016/021/048)随损伤变，同步max_power/power
		&"remove_region_damage":
			var rrd_sid: StringName = params.get("slot_id", &"")
			if mech and mech.slots.has(rrd_sid):
				var rrd_slot = mech.slots[rrd_sid]
				if rrd_slot.region_damage_tokens > 0:
					rrd_slot.region_damage_tokens -= 1
					if rrd_slot.equipped_card != null and rrd_slot.equipped_card.damage_tokens > 0:
						rrd_slot.equipped_card.damage_tokens -= 1
					mech.recalc_power_limits()  # 派生动力(016/021/048)随损伤变，同步max_power/power
		&"clear_all_region_damage":
			if mech:
				for sid: StringName in mech.slots:
					var cad_slot = mech.slots[sid]
					cad_slot.region_damage_tokens = 0
					if cad_slot.equipped_card != null:
						cad_slot.equipped_card.damage_tokens = 0
				mech.recalc_power_limits()  # 清空损伤后派生动力归零，同步max_power/power
		&"modify_hp":
			if mech:
				mech.current_hp = clampi(mech.current_hp + int(params.get("amount", 0)), 0, mech.max_hp)
		&"set_full_hp":
			if mech:
				mech.current_hp = mech.max_hp
		&"modify_power":
			if mech:
				mech.dev_modify_power(int(params.get("amount", 0)))
		&"set_full_power":
			if mech:
				mech.restore_own_power_to_full()
		&"modify_gold":
			player.gold = maxi(0, player.gold + int(params.get("amount", 0)))
		&"set_gold_50":
			player.gold = 50
		&"modify_armor":
			if mech:
				for sid: StringName in mech.slots:
					mech.slots[sid].armor_modifier += int(params.get("amount", 0))
		&"change_pilot":
			# PvP dev 换机师：走 DevModeService（unset 旧 + set 新，注销旧 listener + 重算派生）
			var cp_dev := DevModeService.new()
			cp_dev.context = ctx
			var cp_res: Dictionary = cp_dev.change_pilot(target, StringName(params.get("pilot_def_id", &"")))
			if not cp_res.get("ok", false):
				battle.log.append({"message": "[PvP] dev 换机师失败: %s" % String(cp_res.get("message", "")), "details": {}})
		&"modify_limits":
			# PvP dev 修改数值：attack_limit/action_card_limit/gold（即时重算 max_attacks_per_turn）
			var ml_dev := DevModeService.new()
			ml_dev.context = ctx
			ml_dev.modify_player_limits(
				target,
				int(params.get("attack_limit", -1)),
				int(params.get("action_card_limit", -1)),
				int(params.get("gold", -1))
			)
		&"set_event_card":
			# PvP dev 设置事件牌：走完整 set_event_card 动作链（顶旧+注册+派生+instant结算）
			var sec_dev := DevModeService.new()
			sec_dev.context = ctx
			var sec_res: Dictionary = sec_dev.set_event_card(target, StringName(params.get("event_def_id", &"")))
			if not sec_res.get("ok", false):
				battle.log.append({"message": "[PvP] dev 设置事件牌失败: %s" % String(sec_res.get("message", "")), "details": {}})
		&"discard_event_card":
			# PvP dev 弃置事件牌：完整 discard 动作（事件分支永久离场）
			var dec_dev := DevModeService.new()
			dec_dev.context = ctx
			var dec_res: Dictionary = dec_dev.discard_event_card(target)
			if not dec_res.get("ok", false):
				battle.log.append({"message": "[PvP] dev 弃置事件牌失败: %s" % String(dec_res.get("message", "")), "details": {}})
		&"set_event_timer":
			# PvP dev 改事件计时数：直接改数值（不触发到期结算）
			var set_dev := DevModeService.new()
			set_dev.context = ctx
			var set_res: Dictionary = set_dev.set_event_timer(target, int(params.get("value", 0)))
			if not set_res.get("ok", false):
				battle.log.append({"message": "[PvP] dev 改计时失败: %s" % String(set_res.get("message", "")), "details": {}})
		_:
			battle.log.append({"message": "[PvP] 未知 dev_edit op: %s" % String(op), "details": {}})

# ── client 端回调 ──

func _on_pvp_connected_to_host() -> void:
	if battle != null:
		battle.log.append({"message": "[PvP] 已连接 host", "details": {}})
	_refresh_battle()

func _on_pvp_disconnected() -> void:
	if battle != null:
		battle.log.append({"message": "[PvP] 与 host 断开", "details": {}})
	# host 断开（回主菜单/退出）-> client 自动退出关窗（_pvp_exiting 守卫防自身退出时重入）
	if _is_pvp_mode() and not _pvp_exiting:
		_quit_pvp_session()

## client 收到 host 下发的消息：input -> 本地执行(对等)；seed/battle_over
func _on_pvp_client_message(msg: Variant) -> void:
	if typeof(msg) != TYPE_DICTIONARY:
		return
	var d: Dictionary = msg
	match String(d.get("type", "")):
		"seed":
			# host 发来的锁步随机种子 + client 本方候选机师 id，client 据此自建局（与 host 相同牌堆/初始状态）
			if game_mode == &"PVP3":
				_apply_pvp3_seed_and_build(int(d.get("seed", 0)), d.get("client_pilot_ids", []))
			else:
				_apply_pvp_seed_and_build(int(d.get("seed", 0)), d.get("client_pilot_ids", []))
		"input":
			# PVP3 星型中继：host 广播回的自己的 input 跳过（已本地执行）；其余执行
			var sender: String = String(d.get("sender", ""))
			if sender != "" and sender == String(local_player_id):
				return
			_apply_remote_input(String(d.get("op", "")), d.get("data", {}))
		"battle_over":
			if battle != null:
				battle.log.append({"message": "[PvP] 战斗结束", "details": d.get("data", {})})
				_refresh_battle()
		"session_end":
			# host 主动退出 -> client 自动退出关窗
			_quit_pvp_session()
		_:
			pass


# ═══════════════════════════════════════════
# Phase 3 锁步:对等输入交换（双端对等跑引擎,交换输入而非状态）
# ═══════════════════════════════════════════

## 广播输入给对方（host->client 或 client->host）。op 用 String,data 用 String key + 保留 StringName 值。
func _broadcast_input(op: String, data: Dictionary) -> void:
	var msg := {"type": "input", "op": op, "data": data, "sender": String(local_player_id)}
	if is_network_client:
		if net_client != null and net_client.is_connected_to_host():
			net_client.send(msg)
	elif net_host != null and net_host.is_client_connected():
		net_host.send(msg)


## 本方操作入口:本地执行 + 广播。PvE 退化为只本地执行（不广播）。
## PvP 锁步根因修复：op 的引擎应用统一 call_deferred 入队（MessageQueue FIFO 尾部），
## 与引擎 deferred 续跑链（SETTLE 优先级链/_seq 续跑/时点监听链）同队列排序。
## 此前立即执行会让 op 插进续跑链中间：双端动作创建顺序错位 -> ActionRegistry
## 计数器发散 -> resume_effect/damage_placement_done 按 action_id 路由在远端
## 静默落空 -> 挂起死锁（事件牌留事件区/拦截窗漏弹等）。
## 本地入队尾 + 远端收到后同样入队尾：两端队列顺序严格一致，动作 id 强一致。
## 白名单 op（UI 同步依赖返回值，如 play_action_card 确认框读 ok/message）
## 保持立即执行；单人/PvE 模式无同步问题，保持原立即路径。
const _SYNC_DISPATCH_OPS: Array[StringName] = [&"play_action_card"]

func _net_exec(op: String, data: Dictionary) -> Variant:
	if _is_pvp_mode() and not _SYNC_DISPATCH_OPS.has(StringName(op)):
		_broadcast_input(op, data)
		_dispatch_deferred_op.call_deferred(op, data)
		return {}
	var r: Variant = _dispatch_input(op, data)
	if _is_pvp_mode():
		_broadcast_input(op, data)
	return r


## 收到对方输入:只本地执行,不广播。PvP 下同样 defer 入队尾（锁步保序，见 _net_exec 注释）。
func _apply_remote_input(op: String, data: Dictionary) -> void:
	if _is_pvp_mode() and not _SYNC_DISPATCH_OPS.has(StringName(op)):
		_dispatch_deferred_op.call_deferred(op, data)
		return
	_dispatch_input(op, data)


## deferred op 应用：由 MessageQueue 在帧尾统一执行（与引擎续跑链同队列保序）。
func _dispatch_deferred_op(op: String, data: Dictionary) -> void:
	_dispatch_input(op, data)


## 输入分发:op -> 引擎方法（纯执行,无 UI/无广播）。返回 result 供本地 needs 处理。
## player_id 来自 data（本方操作时=local_player_id），双端用同一 player_id 执行,保证状态同步。
func _dispatch_input(op: String, data: Dictionary) -> Variant:
	if battle == null or battle.context == null:
		return {}
	var ctx = battle.context
	match op:
		"pilot_select":
			# 对方选定机师：host 收到 client 选择 → 双端 ready start_turn；
			# client 收到 host 选择 → 记录后弹本方选择屏（host 那张置灰）。
			_on_remote_pilot_select(data)
			return {}
		"move":
			var mv_pid: StringName = data.get("player_id", &"")
			var mv_hex := {"q": int(data.get("q", 0)), "r": int(data.get("r", 0))}
			# 移动方本窗口：先记录终点 + 规划原定路线（起点+各格），供移动中画"剩余尾巴"。
			# 移动中只显示原路线的剩余部分（不重新寻路），路线始终是同一条、越来越短。
			if battle_board and String(mv_pid) == String(local_player_id) and battle.context and battle.context.map_service:
				battle_board._move_destination = mv_hex.duplicate()
				var _mv_mech = battle.context.game_state.get_mech_for_player(local_player_id) if battle.context.game_state else null
				if _mv_mech != null:
					battle_board._local_mech_pos = _mv_mech.position.duplicate()
					var _planned: Array = battle.context.map_service.find_optimal_path(_mv_mech.mech_id, mv_hex, _mv_mech.power)
					var _cells: Array = [_mv_mech.position.duplicate()]
					for _pc in _planned:
						_cells.append({"q": int(_pc.get("q", 0)), "r": int(_pc.get("r", 0))})
					battle_board.set_planned_path(_cells)
			var mv_result = battle.move_unit(String(mv_pid), mv_hex)
			SLog.log_call("app_root", "net_move", {"actor": String(mv_pid), "hex": mv_hex}, mv_result)
			if not _status_ok(mv_result):
				battle.log.append({"message": "移动失败: %s" % _status_message(mv_result), "details": {}})
			# 移动仍在进行（逐格 pacing）：全量刷新作 move-start（显示第一格+面板）。
			# 移动已同步完成（1格/无动画）：用轻量 _refresh_after_move_end，避免全量
			# _refresh_battle 的 board.configure 重算缩放致 move-end 屏闪。
			if _status_ok(mv_result) and _has_active_single_move():
				_refresh_battle()
			elif _status_ok(mv_result):
				_refresh_after_move_end()
			else:
				_refresh_battle()
			# 移动方逐格移动中：启用模态遮罩（点任意位置停止，不触发按钮/功能）。
			# 不再用取消按钮--移动中点击 UI 任意位置即停在当前已完成格。
			if String(mv_pid) == String(local_player_id):
				_update_move_overlay()
			# 移动失败/未启动：清终点与原定路线，避免残留连线
			if battle_board and not (_status_ok(mv_result) and _has_active_single_move()):
				battle_board._move_destination = {}
				battle_board._planned_path_cells = []
				battle_board._move_path_centers = []
			return mv_result
		"play_action_card":
			var pc_pid: StringName = data.get("player_id", &"")
			var pc_card: StringName = data.get("card_instance_id", &"")
			var pc_payload: Dictionary = data.get("payload", {})
			var pc_result: Dictionary = battle.execute_use_action_card(pc_pid, pc_card, pc_payload)
			SLog.log_call("app_root", "net_play_card", {"actor": String(pc_pid), "card": String(pc_card)}, pc_result)
			if not pc_result.get("ok", false):
				battle.log.append({"message": "打牌失败: %s" % String(pc_result.get("message", "")), "details": {}})
			_request_refresh()
			return pc_result
		"unite_discard_draw":
			# 联合效果2：弃置此牌 + 抽1张行动牌。走正式 discard_card / gain_card 动作
			# （发 DISCARD_BEFORE/AFTER/SETTLE 与 GAIN_CARD_BEFORE/AFTER/SETTLE 时点，离场等效果可响应），
			# 而非直接调原子方法。牌仍在手牌时由 UI 询问后走此 op；双端同 player_id 执行保证锁步同步。
			var udd_pid: StringName = data.get("player_id", &"")
			var udd_card: StringName = data.get("card_instance_id", &"")
			if udd_pid != &"" and udd_card != &"" and ctx.game_state.cards.has(udd_card):
				var udd_mech = ctx.game_state.get_mech_for_player(udd_pid)
				var udd_mech_id: StringName = udd_mech.mech_id if udd_mech != null else &""
				# 1. 弃置此牌（discard_card 动作；行动牌无离场监听器，应同步完成）
				var dd_result: Dictionary = ctx.action_service.execute(&"discard_card", {
					"card_ids": [udd_card],
					"executor": &"system_default",
					"player_id": udd_pid,
					"reason": &"UNITE_DISCARD",
				})
				if dd_result.get("state", &"") == &"completed" and udd_mech_id != &"":
					# 2. 抽1张行动牌（gain_card 动作）：取行动牌堆顶第1张（空则重洗弃牌堆，
					#    synced_shuffle 保证 PvP 双端确定性）
					var udd_deck: Array = ctx.game_state.deck_state.action_deck
					if udd_deck.is_empty():
						ctx.deck_service._reshuffle_discard_into_deck(&"action_deck")
						udd_deck = ctx.game_state.deck_state.action_deck
					if not udd_deck.is_empty():
						var udd_top: StringName = udd_deck[0]
						ctx.action_service.execute(&"gain_card", {
							"card_ids": [udd_top],
							"mech_ids": [udd_mech_id],
							"from_zone": &"action_deck",
							"reason": &"UNITE_DRAW",
						})
					battle.log.append({"message": "联合：弃置此牌并抽取1张行动牌", "details": {}})
				else:
					battle.log.append({"message": "联合：弃置未完成，跳过抽牌", "details": {}})
			else:
				battle.log.append({"message": "联合弃牌抽牌失败：找不到牌或玩家", "details": {}})
			_request_refresh()
			return {}
		"set_equipment":
			_net_set_equipment(data.get("player_id", &""), data.get("card_instance_id", &""), data.get("slot_id", &""))
			_request_refresh()
			return {}
		"sell_equipment":
			var se_pid: StringName = data.get("player_id", &"")
			var se_card: StringName = data.get("card_instance_id", &"")
			var se_result: Dictionary = ctx.card_set_service.sell_equipment(se_pid, se_card)
			SLog.log_call("app_root", "net_sell_equipment", {"actor": String(se_pid), "card": String(se_card)}, se_result)
			if se_result.get("ok", false):
				battle.log.append({"message": "卖出成功: +%d 金币" % int(se_result.get("gold_earned", 0)), "details": {}})
			else:
				battle.log.append({"message": "卖出失败: %s" % String(se_result.get("message", "")), "details": {}})
			_request_refresh()
			return se_result
		"paid_draw_action":
			var pd_pid: StringName = data.get("player_id", &"")
			var pd_result: Dictionary = ctx.game_actions.paid_draw_action_card({"player_id": pd_pid})
			SLog.log_call("app_root", "net_paid_draw_action", {"actor": String(pd_pid)}, pd_result)
			if pd_result.get("ok", false):
				battle.log.append({"message": "2金币抽牌成功", "details": {}})
			else:
				battle.log.append({"message": "2金币抽牌失败：%s" % String(pd_result.get("message", "")), "details": {}})
			_request_refresh()
			return pd_result
		"set_trap_arm":
			# 设陷按钮：记录本方机甲当前位置（arm），机甲离开后由 MapService 离场放置陷阱+消耗1层
			var sta_pid: StringName = data.get("player_id", &"")
			var sta_mech = ctx.game_state.get_mech_for_player(sta_pid) if ctx != null and ctx.game_state != null else null
			var sta_result: Dictionary = {"ok": false}
			if sta_mech != null:
				sta_result = ctx.map_service.arm_set_trap(sta_mech.mech_id)
				SLog.log_call("app_root", "net_set_trap_arm", {"actor": String(sta_pid)}, sta_result)
				if not sta_result.get("ok", false):
					battle.log.append({"message": "设陷失败: %s" % String(sta_result.get("message", "")), "details": {}})
			_request_refresh()
			return sta_result
		"shop_buy":
			var sb_pid: StringName = data.get("player_id", &"")
			var sb_kind := String(data.get("kind", &""))
			var sb_discount := bool(data.get("discount", false))
			var sb_pilot_original := bool(data.get("pilot_original", false))
			var sb_result: Dictionary = {"ok": false}
			if sb_kind == "normal":
				sb_result = ctx.shop_service.buy_normal_equipment(sb_pid, int(data.get("slot_index", 0)), sb_discount, sb_pilot_original)
			else:
				sb_result = ctx.shop_service.buy_advanced_equipment(sb_pid, sb_discount, sb_pilot_original)
			if sb_result.get("ok", false):
				battle.log.append({"message": "购买成功: %s" % String(sb_result.get("message", "")), "details": {}})
			else:
				battle.log.append({"message": "购买失败: %s" % String(sb_result.get("message", "")), "details": {}})
			_request_refresh()
			return sb_result
		"shop_refresh":
			var sr_pid: StringName = data.get("player_id", &"")
			var sr_result = ctx.shop_service.refresh_shop(sr_pid)
			if sr_result.get("ok", false):
				battle.log.append({"message": "刷新商店成功", "details": {}})
			else:
				battle.log.append({"message": "刷新商店失败: %s" % String(sr_result.get("message", "")), "details": {}})
			_request_refresh()
			return sr_result
		"shop_reveal":
			var rv_pid: StringName = data.get("player_id", &"")
			var rv_result = ctx.shop_service.reveal_hidden_advanced(rv_pid)
			if rv_result.get("ok", false):
				battle.log.append({"message": "已查看隐藏装备", "details": {}})
			else:
				battle.log.append({"message": "查看失败: %s" % String(rv_result.get("message", "")), "details": {}})
			_request_refresh()
			return rv_result
		"shop_buy_hidden":
			var bh_pid: StringName = data.get("player_id", &"")
			var bh_result = ctx.shop_service.buy_hidden_advanced(bh_pid)
			if bh_result.get("ok", false):
				battle.log.append({"message": "购买成功: %s" % String(bh_result.get("message", "")), "details": {}})
			else:
				battle.log.append({"message": "购买失败: %s" % String(bh_result.get("message", "")), "details": {}})
			_request_refresh()
			return bh_result
		"equipment_active":
			_net_equipment_active(data.get("card_instance_id", &""), data.get("effect_id", &""))
			_request_refresh()
			return {}
		"granted_effect":
			# granted 授予效果（pilot_002 莱比尔协同·进攻 EX 按钮）：来源牌=pilot_002(莱比尔机甲)，
			# 执行机甲=被授予联邦机甲 A（acting_mech_id），须显式传 A 构造 source.mech_id=A 的 effect_fire。
			_net_granted_effect(data.get("card_instance_id", &""), data.get("effect_id", &""), data.get("acting_mech_id", &""))
			_request_refresh()
			return {}
		"attack_window_confirm":
			# 铠威攻击窗口触发确认（弹窗后）：accept=抽1张行动牌+打开窗口 / cancel=无事发生。
			# 双端同 player_id/mech_id 执行保证锁步（确认的抽牌走 gain_card 动作发 GAIN_CARD 时点）。
			_net_attack_window_confirm(data.get("player_id", &""), data.get("mech_id", &""), bool(data.get("accept", false)))
			_request_refresh()
			return {}
		"responded_equip_confirm":
			# 铠厉通用「被响应→抽2装备设置/弃置获金」触发确认（弹窗后）：accept=抽2装备并逐张设置/弃置获金 /
			# cancel=无事发生。双端同 player_id/mech_id 执行保证锁步（抽牌走 gain_card 动作发 GAIN_CARD 时点）。
			_net_responded_equip_confirm(data.get("player_id", &""), data.get("mech_id", &""), bool(data.get("accept", false)))
			_request_refresh()
			return {}
		"pilot_060_choice":
			# 铠德「被响应→三选一」触发选择（弹窗后）：choice=0/1/2 执行对应奖励（抽2行动/回3动力/获4金），
			# 其它=放弃。双端同 player_id/mech_id/choice 执行保证锁步（抽牌走 gain_card 动作发 GAIN_CARD 时点）。
			_net_pilot_060_choice(data.get("player_id", &""), data.get("mech_id", &""), int(data.get("choice", -1)))
			_request_refresh()
			return {}
		"responded_equip_card":
			# 铠厉逐张「设置/弃置获金」面板回调：result.slot_id 非空=设置到该槽；否则=弃置获金(cost)。
			# 当前链的归属/当前卡从 GameState.responded_equip_chain 读取（双端一致），推进链后若仍有
			# 下一张卡会继续弹面板。弃置获金：弃置抽到的装备 + 我方获得该牌面 cost 金币。
			_net_responded_equip_card(data.get("result", {}))
			_request_refresh()
			return {}
		"attack_window_close":
			# 铠威攻击窗口主动取消（玩家点「取消攻击」退出窗口）：双端执行关闭+处理队列，保持锁步。
			_ActionPilotEffects.attack_window_close(ctx)
			_request_refresh()
			return {}
		"end_turn":
			_net_end_turn(data.get("player_id", &""))
			return {}
		"resume_turn_discard":
			# 弃超限牌阻塞窗确认（end_turn 第5步）：释放共享等待槽后续跑流程
			# （弃置->重入第5步->6~9步->流转下家）。双端同 action_id/ids 执行保证锁步。
			var rtd_aid: StringName = data.get("action_id", &"")
			if ctx.action_ui_bridge:
				ctx.action_ui_bridge.release_waiting_slot_if_owner(rtd_aid)
			if ctx.turn_service:
				ctx.turn_service.resume_end_turn_discard(rtd_aid, data.get("card_ids", []))
			_request_refresh()
			return {}
		"ui_confirmed":
			if ctx.action_ui_bridge:
				ctx.action_ui_bridge.on_ui_confirmed(data.get("data", {}))
			# 选择后刷新：棋盘相关选择（选目标/选移动格/选机甲）需全量刷新以更新高亮；
			# 效果/弃牌/二选一/损伤等非棋盘选择用轻量 _refresh_panels_only 跳过 192 格重绘减卡顿。
			# on_ui_confirmed -> _apply_action_input 还会 emit action_input_resolved（已改 _request_refresh
			# 延迟合并），此处按数据特征二选一同步刷新，避免双全量刷新卡顿。
			var _uc_data = data.get("data", {})
			if _uc_data is Dictionary and (_uc_data.has("target_cell") or _uc_data.has("target_id") or _uc_data.has("target_mech_id")):
				_request_refresh()
			else:
				_refresh_panels_only()
			return {}
		"damage_placement_done":
			# 损伤放置/移除完成：按记录的 damage_change 动作 ID 精确恢复（不依赖共享等待槽）
			if ctx.action_ui_bridge:
				ctx.action_ui_bridge.resolve_damage_placement(StringName(data.get("action_id", &"")), {"placed": true})
			# 损伤放置不改变棋盘可视状态，轻量刷新面板即可（棋盘由后续时点 _request_refresh 补齐）
			_refresh_panels_only()
			return {}
		"ui_cancelled":
			if ctx.action_ui_bridge:
				ctx.action_ui_bridge.on_ui_cancelled()
			_request_refresh()
			return {}
		"cancel_move":
			# 取消进行中的单次移动动作（逐格 basic_move 中断，机甲停在当前已完成格）。
			# 按 mech_id 取消顶层 single_move--不依赖 action_id 匹配（锁步计数器若已发散，
			# 按 action_id 取消会空操作，远端 single_move 继续走到终点致位置不同步）。
			var cm_mech_id: StringName = StringName(data.get("mech_id", &""))
			if cm_mech_id != &"" and ctx.action_registry:
				for a in ctx.action_registry.get_actions_by_type(&"single_move"):
					if a.parent_action_id == &"" and StringName(a.record.get("mech_id", &"")) == cm_mech_id:
						if a.state == &"running" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action" or a.state == &"waiting_input":
							if ctx.action_service:
								ctx.action_service.cancel_action(a.action_id)
						break
			# 强制同步机甲位置/动力/格数到本方实际值。远端 single_move 可能已走到终点
			# （上面 cancel 找不到进行中动作），此处把状态拉回本方取消时的真实值，保证两端一致。
			if cm_mech_id != &"" and ctx.game_state and ctx.game_state.mechs.has(cm_mech_id):
				var cm_mech = ctx.game_state.mechs.get(cm_mech_id)
				if cm_mech != null:
					cm_mech.position = {"q": int(data.get("q", cm_mech.position.get("q", 0))), "r": int(data.get("r", cm_mech.position.get("r", 0)))}
					cm_mech.power = int(data.get("power", cm_mech.power))
					cm_mech.power_spent_this_turn = int(data.get("power_spent", cm_mech.power_spent_this_turn))
					cm_mech.temp_power = int(data.get("temp_power", cm_mech.temp_power))
					cm_mech.own_power_spent_this_turn = int(data.get("own_power_spent", cm_mech.own_power_spent_this_turn))
					cm_mech.temp_power_granted_this_turn = int(data.get("temp_power_granted", cm_mech.temp_power_granted_this_turn))
					cm_mech.cells_moved_this_turn = int(data.get("cells_moved", cm_mech.cells_moved_this_turn))
			# 强制同步 ActionRegistry 计数器到本方值：先前动作(设装备/打牌)可能已使两端计数器
			# 发散，致后续动作 action_id 不匹配（攻击响应窗口 respond_attack 找不到动作->攻击卡临时区）。
			# 仅当无其他活跃动作时才重设--避免与仍在挂起的效果动作(如 effect_017 EXECUTE_SINGLE_MOVE)
			# 的 action_id 冲突。被取消的 single_move 及其 basic_move 子动作均已清理，不计入。
			if ctx.action_registry != null and data.has("action_counter") and ctx.action_registry.get_active_count() == 0:
				ctx.action_registry._id_counter = int(data.get("action_counter", ctx.action_registry._id_counter))
			# 轻量刷新（清移动连线+面板），避免全量 _refresh_battle 致界面抖动
			_refresh_after_move_end()
			return {}
		"respond_attack":
			var ra_action_id: StringName = data.get("action_id", &"")
			var ra_pass := bool(data.get("pass", false))
			var ra_selected: Array[Dictionary] = []
			if not ra_pass:
				ra_selected = _build_selected_cards_from_card(data.get("card_instance_id", &""), data.get("effect_id", &""))
			# 问题4：pass 时传 player_id 做多玩家 pass 追踪；handle_response_selection 返回
			# true=窗口应关闭（确认响应/全 pass/旧行为），false=保持（部分 pass，其他玩家仍可响应）。
			var ra_pass_pid: StringName = StringName(data.get("player_id", &"")) if ra_pass else &""
			var ra_should_close: bool = true
			if ctx.timing_engine:
				ra_should_close = ctx.timing_engine.handle_response_selection(ra_action_id, ra_selected, ra_pass_pid)
			# 竞争关闭：确认响应/全 pass/旧行为 -> 关窗；
			# 部分 pass（其他玩家未响应）-> 保持本端窗口（若本端是未 pass 的响应方）。
			# （响应发起端自己已在 _on_response_passed/_on_response_selected 关窗。）
			if ra_should_close and response_panel:
				response_panel.visible = false
			_request_refresh()
			return {}
		"resume_effect":
			var re_action_id: StringName = data.get("action_id", &"")
			var re_data: Dictionary = data.get("data", {})
			if ctx.action_ui_bridge:
				# 走 bridge.resolve_effect_input：恢复挂起效果的同时清除共享等待锁。
				# 之前直连 timing_engine.resume_pending_effect 绕过 bridge，_waiting_action_id 残留
				# 导致效果弹窗确认后 UI 全锁（"发动后动不了"）。
				ctx.action_ui_bridge.resolve_effect_input(re_action_id, re_data)
			elif ctx.timing_engine:
				ctx.timing_engine.resume_pending_effect(re_action_id, re_data)
			_request_refresh()
			return {}
		"damage_place":
			var dp_slot: StringName = data.get("slot_id", &"")
			var dp_mech: StringName = data.get("target_mech_id", &"")
			if dp_mech != &"" and dp_slot != &"":
				ctx.damage_token_service.place_one_damage_token(dp_mech, dp_slot)
				ctx.damage_token_service.check_and_handle_equipment_break(dp_mech, dp_slot)
			_refresh_damage_ui()
			return {}
		"damage_remove":
			# 锁步损伤移除（维修等 decrease 效果）：每点一个槽位移除1损伤，双端应用
			var dr_slot: StringName = data.get("slot_id", &"")
			var dr_mech: StringName = data.get("target_mech_id", &"")
			if dr_mech != &"" and dr_slot != &"":
				ctx.game_actions.remove_damage_tokens({"mech_id": dr_mech, "slot_id": dr_slot, "amount": 1})
			_refresh_damage_ui()
			return {}
		"discard_cards":
			# 攻击结算后触发的弃牌（非 action 引擎 need_input 路径）：双端直接弃牌
			# 走 discard_card 动作发时点，使监听 DISCARD_SETTLE 的效果（如安德洛美达回收维修）触发
			var dc_pid: StringName = data.get("player_id", &"")
			var dc_cards: Array = data.get("card_ids", [])
			var dc_reason: StringName = data.get("reason", &"EFFECT_DISCARD")
			if not dc_cards.is_empty():
				ctx.deck_service.discard_cards(dc_cards, dc_reason)
			battle.log.append({"message": "弃置了 %d 张行动牌" % dc_cards.size(), "details": {}})
			_request_refresh()
			return {}
		"dev_edit":
			_apply_dev_edit(data.get("op", &""), data.get("params", {}))
			_request_refresh()
			return {}
		_:
			battle.log.append({"message": "[PvP] 未知 input op: %s" % op, "details": {}})
			_request_refresh()
			return {}


## 从行动牌 instance_id 重建 selected_cards（含 ActionEffect 对象,不可网络序列化）。
## 双端各自调用,网络只传 card_instance_id。逻辑取自 _on_response_selected。
func _build_selected_cards_from_card(card_id: StringName, effect_id: StringName = &"") -> Array[Dictionary]:
	var selected_cards: Array[Dictionary] = []
	if card_id == &"" or battle == null or battle.context == null:
		return selected_cards
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	if card == null or card.def == null:
		return selected_cards
	var is_counter_card: bool = card.def.card_kind == &"action" and card.def.action_type == &"迎击"
	# 优先用透传的 effect_id（响应窗口选中时携带，覆盖行动牌/装备牌/机师牌）。
	# 装备 AVAILABILITY 效果（如 effect_084 一角兽右腿）不在 GeneratedActionEffects，须另查装备效果表，
	# 否则双端重建 selected_cards 为空 -> handle_response_selection 误判为取消（攻击不被响应）。
	if effect_id != &"":
		var eff: ActionEffect = GeneratedActionEffects.build_all_effects().get(effect_id)
		if eff == null:
			eff = GeneratedEquipmentEffects.build_equipment_effects().get(effect_id)
		if eff == null:
			# granted 机师 AVAILABILITY 效果（pilot_002 莱比尔协同·防御）在 ActionPilotEffects，
			# 须另查，否则 selected_cards 为空 -> handle_response_selection 误判为取消（攻击不被响应）。
			eff = ActionPilotEffects.build_pilot_effects().get(effect_id)
		if eff != null and eff.mode == "AVAILABILITY":
			selected_cards.append({
				"effect_id": effect_id,
				"card_instance_id": card_id,
				"effect": eff,
				"availability_priority": eff.availability_priority,
				"card_name": card.def.display_name,
				"is_counter": is_counter_card,
			})
			return selected_cards
	# 退回：按 card_id 扫描行动牌 AVAILABILITY 效果（兼容未带 effect_id 的调用）
	var card_mappings: Array = GeneratedActionEffects.get_effects_for_card(card.def.card_id)
	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()
	for mapping in card_mappings:
		var eid: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
		var effect: ActionEffect = all_effects.get(eid)
		if effect and effect.mode == "AVAILABILITY":
			selected_cards.append({
				"effect_id": eid,
				"card_instance_id": card_id,
				"effect": effect,
				"availability_priority": effect.availability_priority,
				"card_name": card.def.display_name,
				"is_counter": is_counter_card,
			})
			break
	return selected_cards


## 设置装备（锁步版）：备用区->手牌迁移 + card_set_service.set_equipment。逻辑取自 _handle_client_set_equipment。
func _net_set_equipment(pid: StringName, card_id: StringName, slot_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var ctx = battle.context
	var gs = ctx.game_state
	if card_id == &"" or slot_id == &"":
		return
	var player = gs.players.get(pid)
	if player == null:
		return
	# 备用区 -> 手牌（从备用区重新设置装备时,先把牌移回手牌）
	if not player.equipment_hand.has(card_id):
		var mech = gs.get_mech_for_player(pid)
		var moved := false
		if mech != null:
			for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
				if not mech.slots.has(rs_id):
					continue
				var rs_slot = mech.slots[rs_id]
				if rs_slot.equipped_card != null and rs_slot.equipped_card.instance_id == card_id:
					rs_slot.equipped_card = null
					player.equipment_hand.append(card_id)
					moved = true
					break
		if not moved:
			battle.log.append({"message": "[PvP] 设置装备失败:装备不在手牌或备用区", "details": {"card": String(card_id)}})
			return
	var result: Dictionary = ctx.card_set_service.set_equipment(pid, card_id, slot_id)
	SLog.log_call("app_root", "net_set_equipment", {"actor": String(pid), "card": String(card_id), "slot": String(slot_id)}, result)
	if result.get("ok", false):
		battle.log.append({"message": "装备设置成功: %s -> %s" % [String(card_id), String(slot_id)], "details": {}})
	else:
		battle.log.append({"message": "装备设置失败: %s" % String(result.get("message", "")), "details": {}})


## 装备主动效果（锁步版）：走 effect_fire 动作。逻辑取自 _on_equipment_active_clicked。
func _net_equipment_active(card_id: StringName, effect_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var context = battle.context
	var card = context.game_state.get_card(card_id) if context.game_state != null else null
	if card == null:
		battle.log.append({"message": "装备效果发动失败:找不到牌实例", "details": {}})
		return
	var src: Dictionary = {
		"card_instance_id": card_id,
		"mech_id": card.mech_id,
		"player_id": card.owner_player_id,
		"effect_id": effect_id,
	}
	var payload: Dictionary = {
		"effect_id": effect_id,
		"player_id": card.owner_player_id,
		"source_mech_id": card.mech_id,
		"card_instance_id": card_id,
		"phase": context.game_state.phase,
		"source": src,
	}
	if context.action_service != null:
		context.action_service.execute(&"effect_fire", payload)
		battle.log.append({"message": "发动装备效果: %s" % String(effect_id), "details": {}})


## granted 授予效果（锁步版）：走 effect_fire 动作。与 _net_equipment_active 的区别--
## 来源牌 card_instance_id=pilot_002(在莱比尔机甲上)，但执行机甲=被授予的联邦机甲 A(acting_mech_id)。
## 故 source.mech_id/source_mech_id/player_id 取 A 而非 card.mech_id(莱比尔)，
## 使 _execute_effect_by_id 按 mech_id=A 命中 A 的 granted listener，效果以 A 身份执行（消耗 A 攻击数等）。
func _net_granted_effect(card_id: StringName, effect_id: StringName, acting_mech_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var context = battle.context
	if acting_mech_id == &"" or context.game_state == null:
		return
	var card = context.game_state.get_card(card_id) if context.game_state != null else null
	if card == null:
		battle.log.append({"message": "授予效果发动失败:找不到来源牌实例", "details": {}})
		return
	var acting_mech = context.game_state.mechs.get(acting_mech_id)
	if acting_mech == null:
		battle.log.append({"message": "授予效果发动失败:找不到执行机甲", "details": {}})
		return
	var acting_player_id: StringName = acting_mech.owner_player_id
	var src: Dictionary = {
		"card_instance_id": card_id,
		"mech_id": acting_mech_id,
		"player_id": acting_player_id,
		"effect_id": effect_id,
	}
	var payload: Dictionary = {
		"effect_id": effect_id,
		"player_id": acting_player_id,
		"source_mech_id": acting_mech_id,
		"mech_id": acting_mech_id,
		"card_instance_id": card_id,
		"phase": context.game_state.phase,
		"source": src,
	}
	if context.action_service != null:
		context.action_service.execute(&"effect_fire", payload)
		battle.log.append({"message": "发动授予效果: %s（执行机甲 %s）" % [String(effect_id), String(acting_mech_id)], "details": {}})


## 铠威攻击窗口触发确认（锁步版）：accept=抽1张行动牌+打开窗口 / cancel=无事发生。
## 确认框由 pending_prompt 弹窗触发；双端执行 attack_window_confirm 保持状态同步。
func _net_attack_window_confirm(player_id: StringName, mech_id: StringName, accept: bool) -> void:
	if battle == null or battle.context == null:
		return
	_ActionPilotEffects.attack_window_confirm(battle.context, player_id, mech_id, accept)


## 铠厉通用「被响应→抽2装备设置/弃置获金」触发确认（锁步版）：accept=抽2装备并逐张设置/弃置获金 /
## cancel=无事发生。确认框由 pending_confirm 弹窗触发；双端执行 responded_equip_confirm 保持状态同步。
func _net_responded_equip_confirm(player_id: StringName, mech_id: StringName, accept: bool) -> void:
	if battle == null or battle.context == null:
		return
	_ActionPilotEffects.responded_equip_confirm(battle.context, player_id, mech_id, accept)


## 铠德「被响应→三选一」触发选择（锁步版）：choice=0/1/2 执行对应奖励（抽2行动/回3动力/获4金），
## 其它=放弃。三选一由 pending_choice 弹窗触发；双端执行 pilot_060_choose 保持状态同步。
func _net_pilot_060_choice(player_id: StringName, mech_id: StringName, choice: int) -> void:
	if battle == null or battle.context == null:
		return
	_ActionPilotEffects.pilot_060_choose(battle.context, player_id, mech_id, choice)


## 铠厉逐张「设置/弃置获金」面板回调（锁步版）：从 GameState.responded_equip_chain 读当前链的归属与
## 当前卡，双端执行 responded_equip_card_resume（设置=set_equipment 动作 / 弃置=discard_card+gain_gold(cost)），
## 再推进链（若有下一张继续弹面板）。
func _net_responded_equip_card(result: Dictionary) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	if gs == null:
		return
	var chain: Dictionary = gs.responded_equip_chain
	if chain.is_empty():
		return
	var re_pid: StringName = chain.get("owner_player_id", &"")
	var re_mid: StringName = chain.get("owner_mech_id", &"")
	var re_cards: Array = chain.get("card_ids", [])
	var re_index: int = int(chain.get("index", 0))
	if re_index >= re_cards.size():
		return
	_ActionPilotEffects.responded_equip_card_resume(battle.context, re_pid, re_mid, re_cards[re_index], result)


## 结束回合（锁步版）：弃牌 + end_turn + 胜负检查 + 切对手回合（无 AI）。
## 弃超限牌由 end_turn 流程第5步阻塞窗处理（正常顺序：拾荒等时点先结算），选牌经
## resume_turn_discard op 双端续跑。
func _net_end_turn(pid: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var ctx = battle.context
	var gs = ctx.game_state
	if gs.active_player_id != &"" and gs.active_player_id != pid:
		battle.log.append({"message": "[PvP] 非己方回合,结束回合被拒", "details": {}})
		return
	# 清理残留动作（必须在弃置超限牌【之前】：弃牌发 DISCARD_AFTER 时点会挂起监听型效果弹窗
	# （肯尼斯效果2/德伦迪抽牌等）等待玩家确认，cancel 在弃牌后会无差别杀掉挂起中的弹窗动作，
	# 弹窗成孤儿点不动（回合结束弃牌选抽牌不抽的根因）。调整后弃牌触发的挂起效果幸存，
	# 玩家确认后 resume 生效，与弥雅 TURN_AFTER_END 挂起先例同款时序。）
	if ctx.action_engine:
		ctx.action_engine.cancel_all_actions()
	var end_result: Dictionary = ctx.turn_service.end_turn(pid)
	_refresh_battle()
	_finish_battle_if_needed()
	if get_result_state() != "active":
		return
	if end_result.get("suspended", false):
		# 回合结束流程挂起（拾荒/修整/事件到期弹窗等）：弃超限牌/弃装备/流转下家等剩余步骤
		# 延迟到玩家交互完成（end_turn_flow_completed 信号）后执行（弃超限牌在流程第5步，
		# 天然晚于拾荒窗等 TURN_BEFORE_END 时点效果）。
		_pending_turn_flow = {"active": true, "player_id": String(pid)}
		return
	# PvP 切对手回合（无 AI 驱动）
	var other: StringName
	if game_mode == &"PVP3":
		other = gs.get_next_player_id(pid)
	else:
		other = gs.get_opponent_player_id(pid)
	battle.start_turn(String(other))
	_refresh_battle()


## 回合结束流程完成（含挂起恢复路径）：执行被暂停的回合流转
func _on_end_turn_flow_completed(pid: StringName) -> void:
	if not _pending_turn_flow.get("active", false):
		return
	if String(_pending_turn_flow.get("player_id", "")) != String(pid):
		return
	var is_local_flow: bool = bool(_pending_turn_flow.get("local_flow", false))
	_pending_turn_flow = {}
	if battle == null or battle.context == null:
		return
	_refresh_battle()
	_finish_battle_if_needed()
	if get_result_state() != "active":
		return
	if is_local_flow:
		# 本地路径（_finish_player_turn 挂起）：PvP 直接切对手；PvE 开始敌方回合（多步式 AI）
		if _is_pvp_mode():
			_pvp_start_other_turn()
		else:
			_start_enemy_turn_flow()
		return
	# PvP 网络路径（_net_end_turn 挂起）：切下家回合
	var gs = battle.context.game_state
	var other: StringName
	if game_mode == &"PVP3":
		other = gs.get_next_player_id(pid)
	else:
		other = gs.get_opponent_player_id(pid)
	battle.start_turn(String(other))
	_refresh_battle()


## PvP 回合切换：当前 active 方结束回合 -> 开对手回合（无 AI 驱动）
func _pvp_start_other_turn() -> void:
	var other: StringName
	if game_mode == &"PVP3":
		other = battle.context.game_state.get_next_player_id(local_player_id)
	else:
		other = _opponent_player_id()
	battle.start_turn(String(other))
	_refresh_battle()
	_finish_battle_if_needed()


# ── Phase G：弹窗路由 ──

## 判定一个弹窗归属哪个玩家（用于 PvP 路由到正确窗口）。
## 返回 &"" 表示不路由（本地显示）。
func _popup_owner(popup_type: StringName, params: Dictionary) -> StringName:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return &""
	var gs = battle.context.game_state
	match popup_type:
		&"weapon_select", &"attack_target_select":
			return _owner_of_mech_id(params.get("attacker_id", &""))
		&"move_target_select":
			return _owner_of_mech_id(params.get("mech_id", &""))
		&"response_window":
			return _owner_of_mech_id(params.get("target_id", &""))
		&"discard_card_select":
			# 优先按 executor 路由（谁操作弹给谁）。
			# 识破偷牌: executor=识破使用方(防御方/选牌人), discard_player_id=攻击方(被偷的人)，
			#   必须按 executor 路由，否则弹窗错发给攻击方（client 用识破却 host 选牌的 bug）。
			# 强制弃牌: executor=弃牌者自己。optional 弃牌(闪击): 无 executor，回退 player_id。
			var d_ex: StringName = params.get("executor", &"")
			if d_ex != &"" and gs.players.has(d_ex):
				return d_ex
			var dp: StringName = params.get("discard_player_id", params.get("player_id", &""))
			if dp != &"" and gs.players.has(dp):
				return dp
			return &""
		&"damage_token_placement":
			# G2：按 executor 路由（client 为攻击方时 executor=enemy，弹给 client 放损伤）
			return _owner_of_mech_id(params.get("executor", &""))
		&"unite_attack_select":
			# 联合攻击弹窗路由给 Target（被联合者）的玩家，而非发动攻击的 unite 机甲玩家。
			# target_mech_id = 联合状态所在机甲（Target），其 owner 即应操作弹窗的玩家。
			return _owner_of_mech_id(params.get("target_mech_id", &""))
		&"use_card_confirm", &"choice_select", &"effect_choice", &"mech_target_select", \
		&"weapon_charge_select", &"repair_target_select", &"redirect_select", &"thrust_select", \
		&"awaken_select", &"immediate_set_equipment", &"integer_select", &"map_cell_select", &"mech_multi_select", &"pilot_003_skip_players", &"pilot_003_choose_top", &"pilot_009_card_display", &"pilot_014_target_select", &"pilot_018_equipment_select", &"pilot_025_reserve_select", &"pilot_032_target_select", &"hidden_card_view_select", &"hidden_reserve_slot_select", &"damage_adjust", &"pilot_083_options", &"pilot_088_type_select":
			var pid: StringName = params.get("player_id", &"")
			if pid != &"" and gs.players.has(pid):
				return pid
			var mid: StringName = params.get("mech_id", params.get("source_mech_id", params.get("from_mech_id", params.get("redirect_mech_id", &""))))
			var o := _owner_of_mech_id(mid)
			if o != &"":
				return o
			# 兜底：取当前等待动作的 player_id
			return _waiting_action_owner()
		_:
			return &""


## 取机甲 id 的归属玩家；若传入的是 player_id 直接返回
func _owner_of_mech_id(mech_id: StringName) -> StringName:
	if mech_id == &"" or battle == null or battle.context == null or battle.context.game_state == null:
		return &""
	var gs = battle.context.game_state
	var m = gs.mechs.get(mech_id)
	if m != null:
		return m.owner_player_id
	if gs.players.has(mech_id):
		return mech_id
	return &""


## 取当前 action_ui_bridge 等待中动作的发起方玩家
func _waiting_action_owner() -> StringName:
	if battle.context.action_ui_bridge == null or battle.context.action_registry == null:
		return &""
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		return &""
	var action = battle.context.action_registry.get_action(wait_info.get("action_id", &""))
	if action == null:
		return &""
	var pid: StringName = action.record.get("player_id", &"")
	# set_equipment 等动作的 player_id 只注入到 action.source（非 record 顶层），
	# 故 record 取空时回退 action.source.player_id，否则其触发的弹窗 _popup_owner 兜底返回空、
	# PvP 下两端都弹（设置装备时 effect_033 等选项弹窗给所有玩家弹的根因）。
	if pid == &"" and action.source is Dictionary:
		pid = action.source.get("player_id", &"")
	if pid != &"" and battle.context.game_state.players.has(pid):
		return pid
	return &""


## 连接当前 battle.context 的动作系统信号到 app_root 处理器（幂等：已连接则跳过）。
## host/client 共用此入口。context (re)build 后必须调用——client 自建局时 start_tutorial
## 会新建 GameContext 替换旧的，新 context 的 action_ui_bridge/timing_engine/action_engine
## 信号无人接收，导致 weapon_select/attack_target_select/response_window 等弹窗不弹
## （client 用攻击牌不弹选择窗口、被攻击不弹响应窗口的根因）。
func _connect_action_signals() -> void:
	if battle == null or battle.context == null:
		return
	var ctx = battle.context
	# UI 模式开启逐格移动动画（测试模式不走此入口，保持同步执行）
	ctx.move_animation_enabled = true
	if ctx.action_ui_bridge:
		var pu := Callable(self, "_on_action_ui_popup_requested")
		if not ctx.action_ui_bridge.request_ui_popup.is_connected(pu):
			ctx.action_ui_bridge.request_ui_popup.connect(pu)
		var ir := Callable(self, "_on_action_input_resolved")
		if not ctx.action_ui_bridge.action_input_resolved.is_connected(ir):
			ctx.action_ui_bridge.action_input_resolved.connect(ir)
	if ctx.timing_engine:
		var tf := Callable(self, "_on_timing_fired")
		if not ctx.timing_engine.timing_fired.is_connected(tf):
			ctx.timing_engine.timing_fired.connect(tf)
		var eef := Callable(self, "_on_equipment_effect_fired")
		if not ctx.timing_engine.equipment_effect_fired.is_connected(eef):
			ctx.timing_engine.equipment_effect_fired.connect(eef)
		var ts := Callable(self, "_on_target_selection_requested")
		if not ctx.timing_engine.request_target_selection.is_connected(ts):
			ctx.timing_engine.request_target_selection.connect(ts)
		var p24rw := Callable(self, "_on_pilot_024_repair_window_changed")
		if not ctx.timing_engine.pilot_024_repair_window_changed.is_connected(p24rw):
			ctx.timing_engine.pilot_024_repair_window_changed.connect(p24rw)
	if ctx.action_engine:
		var ac := Callable(self, "_on_action_completed")
		if not ctx.action_engine.action_completed.is_connected(ac):
			ctx.action_engine.action_completed.connect(ac)
	# 回合结束流程完成（end_turn 挂起恢复路径）：驱动被暂停的回合流转（_net_end_turn 等）
	if ctx.turn_service:
		var etf := Callable(self, "_on_end_turn_flow_completed")
		if not ctx.turn_service.end_turn_flow_completed.is_connected(etf):
			ctx.turn_service.end_turn_flow_completed.connect(etf)


# ═══════════════════════════════════════════
# 战斗界面 - 左右分区布局
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
	equipment_panel.reserve_set_clicked.connect(Callable(self, "_on_reserve_set_clicked"))
	equipment_panel.equipment_active_clicked.connect(Callable(self, "_on_equipment_active_clicked"))
	equipment_panel.granted_effect_clicked.connect(Callable(self, "_on_granted_effect_clicked"))
	equipment_panel.mech_detail_requested.connect(Callable(self, "_on_mech_detail_requested"))
	right_panel.add_child(equipment_panel)

	skill_bar = SkillBar.new()
	right_panel.add_child(skill_bar)

	# 消息日志（右侧面板底部，占据剩余空间）
	message_log = _BattleMessageLog.new()
	message_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_panel.add_child(message_log)

	# ── 临时区面板（手牌区上方，半透明显示使用中行动牌）──
	tmp_zone_panel = _TmpZonePanel.new()
	layout.add_child(tmp_zone_panel)

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
	_sell_button = _add_button(action_bar, "卖出(*)", Callable(self, "_on_sell_equipment_clicked"), "sell")
	_paid_draw_button = _add_button(action_bar, "2金币抽牌", Callable(self, "_on_paid_draw_clicked"), "paid_draw")
	_set_trap_button = _add_button(action_bar, "设陷", Callable(self, "_on_set_trap_clicked"), "set_trap")
	_medusa_control_button = _add_button(action_bar, "美杜莎操控", Callable(self, "_on_medusa_control_clicked"), "medusa_control")
	_add_button(action_bar, "商店", Callable(self, "_on_shop_clicked"))
	_add_button(action_bar, "牌堆信息", Callable(self, "_on_deck_info_clicked"))
	_add_button(action_bar, "返回主菜单", Callable(self, "_on_return_to_main_menu"))

	# ── 取消攻击按钮（初始隐藏）──
	cancel_attack_button = Button.new()
	cancel_attack_button.text = "取消攻击"
	cancel_attack_button.custom_minimum_size = Vector2(140, 32)
	cancel_attack_button.visible = false
	cancel_attack_button.pressed.connect(Callable(self, "_on_cancel_attack"))
	layout.add_child(cancel_attack_button)

	# ── 弹窗浮层（全屏居中容器，承载所有弹窗面板）──
	# 不加到 layout：弹窗需脱离 VBox 流式布局、屏幕居中，避免内容超出窗口时
	# 确认/取消按钮被挤到窗口外裁切。mouse_filter=IGNORE 透传背景点击，
	# 弹窗面板自身矩形负责拦截输入，无弹窗时不挡任何操作。
	popup_overlay = CenterContainer.new()
	popup_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(popup_overlay)
	# 弹窗按钮/选项与深色弹窗背景(_POPUP_BG)区分：popup_overlay 套一个仅覆盖 Button 样式的
	# 本地 Theme，级联到所有弹窗面板及其动态创建的按钮；只定义 Button 项，Label/Scroll 等回退
	# 原主题不受影响。各按钮自身的 add_theme_*_override（选中高亮/字体色）仍优先于此 Theme。
	popup_overlay.theme = _build_popup_button_theme()
	# 模态弹窗遮罩：弹窗显示时全屏暗色遮罩，挡住棋盘/取消按钮/下层面板，
	# 仅顶层弹窗（popup_overlay 内，位于遮罩之上）可交互。位置保持在 popup_overlay 之下。
	_popup_stack.clear()
	_damage_suspend_stack.clear()
	if _popup_scrim == null or not is_instance_valid(_popup_scrim):
		_popup_scrim = ColorRect.new()
		_popup_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
		_popup_scrim.color = Color(0.0, 0.0, 0.0, 0.7)
		_popup_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
		_popup_scrim.visible = false
		add_child(_popup_scrim)
	move_child(_popup_scrim, popup_overlay.get_index())

	# 逐格移动模态遮罩（在 popup_overlay 之上）：移动中拦截全屏点击，点任意位置停止移动。
	# 透明不遮挡画面；mouse_filter IGNORE 时不拦截（非移动阶段），STOP 时拦截（移动阶段）。
	_move_overlay = Control.new()
	_move_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_move_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_move_overlay.gui_input.connect(Callable(self, "_on_move_overlay_input"))
	add_child(_move_overlay)

	# ── 敌方信息弹窗（初始隐藏）──
	enemy_info_popup = _EnemyInfoPopup.new()
	add_child(enemy_info_popup)

	# ── 机甲详细信息弹窗（初始隐藏）──
	mech_detail_panel = _MechDetailPanel.new()
	add_child(mech_detail_panel)

	# ── 机甲状态列表面板（初始隐藏）──
	status_panel = _StatusPanel.new()
	add_child(status_panel)

	# ── 牌堆信息弹窗（初始隐藏）──
	deck_info_popup = _DeckInfoPopup.new()
	add_child(deck_info_popup)

	# ── 商店面板（初始隐藏）──
	shop_panel = _ShopPanel.new()
	shop_panel.local_player_id = local_player_id
	shop_panel.normal_equipment_buy_clicked.connect(Callable(self, "_on_shop_normal_buy_clicked"))
	shop_panel.advanced_equipment_buy_clicked.connect(Callable(self, "_on_shop_advanced_buy_clicked"))
	shop_panel.reveal_hidden_clicked.connect(Callable(self, "_on_shop_reveal_hidden_clicked"))
	shop_panel.buy_hidden_advanced_clicked.connect(Callable(self, "_on_shop_buy_hidden_clicked"))
	shop_panel.refresh_shop_clicked.connect(Callable(self, "_on_shop_refresh_clicked"))
	shop_panel.visible = false
	add_child(shop_panel)

	# ── 卖出装备面板（初始隐藏）──
	sell_equipment_panel = _SellEquipmentPanel.new()
	sell_equipment_panel.local_player_id = local_player_id
	sell_equipment_panel.equipment_confirmed.connect(Callable(self, "_on_sell_panel_equipment_selected"))
	sell_equipment_panel.cancelled.connect(Callable(self, "_on_sell_panel_cancelled"))
	sell_equipment_panel.visible = false
	popup_overlay.add_child(sell_equipment_panel)

	# ── 迎击面板（初始隐藏）──
	response_panel = ResponsePanel.new()
	response_panel.response_selected.connect(Callable(self, "_on_response_selected"))
	response_panel.response_passed.connect(Callable(self, "_on_response_passed"))
	response_panel.availability_effect_selected.connect(Callable(self, "_on_availability_effect_selected"))
	response_panel.visible = false
	popup_overlay.add_child(response_panel)

	# ── 武器选择面板（初始隐藏）──
	weapon_picker_panel = _WeaponPickerPanel.new()
	weapon_picker_panel.weapon_selected.connect(Callable(self, "_on_weapon_selected"))
	weapon_picker_panel.selection_cancelled.connect(Callable(self, "_on_weapon_selection_cancelled"))
	weapon_picker_panel.visible = false
	popup_overlay.add_child(weapon_picker_panel)

	# ── 损伤放置面板（初始隐藏）──
	damage_placement_panel = _DamagePlacementPanel.new()
	damage_placement_panel.placement_completed.connect(Callable(self, "_on_damage_placement_completed"))
	if _is_pvp_mode():
		damage_placement_panel.network_mode = true
		damage_placement_panel.token_placed.connect(_on_damage_token_placed)
	damage_placement_panel.token_removed.connect(_on_damage_token_removed)
	damage_placement_panel.visible = false
	popup_overlay.add_child(damage_placement_panel)

	# ── 损伤调整面板（薇尔 pilot_059 回合开始，初始隐藏）──
	damage_adjust_panel = _DamageAdjustPanel.new()
	damage_adjust_panel.adjust_chosen.connect(Callable(self, "_on_damage_adjust_chosen"))
	damage_adjust_panel.adjust_cancelled.connect(Callable(self, "_on_damage_adjust_cancelled"))
	damage_adjust_panel.visible = false
	popup_overlay.add_child(damage_adjust_panel)

	# ── 效果选择面板（初始隐藏）──
	var _ChoicePanel = preload("res://scripts/ui/choice_panel.gd")
	choice_panel = _ChoicePanel.new()
	choice_panel.choice_made.connect(Callable(self, "_on_choice_made"))
	choice_panel.choice_cancelled.connect(Callable(self, "_on_choice_cancelled"))
	choice_panel.visible = false
	popup_overlay.add_child(choice_panel)

	# ── 瓦恩武器修改三横排选项面板（pilot_083，初始隐藏）──
	var _WeaponModifyOptionsPanel = preload("res://scripts/ui/weapon_modify_options_panel.gd")
	weapon_modify_options_panel = _WeaponModifyOptionsPanel.new()
	weapon_modify_options_panel.options_confirmed.connect(Callable(self, "_on_p083_options_confirmed"))
	weapon_modify_options_panel.options_cancelled.connect(Callable(self, "_on_p083_options_cancelled"))
	weapon_modify_options_panel.visible = false
	popup_overlay.add_child(weapon_modify_options_panel)

	# ── 查看隐藏装备面板（霍恩 pilot_046 等，初始隐藏）──
	hidden_card_view_panel = _HiddenCardViewPanel.new()
	hidden_card_view_panel.acquire_clicked.connect(Callable(self, "_on_hidden_view_acquire"))
	hidden_card_view_panel.cancelled.connect(Callable(self, "_on_hidden_view_cancelled"))
	# PopupPanel 非「关闭」按钮的隐藏路径（点弹窗外/Esc/焦点丢失）不发 cancelled 信号：
	# 动作残留 + 共享等待槽不清 -> 所有主动按钮置灰（bug3 霍恩按钮死）。
	# popup_hide 兜底走守卫式取消（Godot 4.6 Window 无 popup_hide_on_focus_loss 属性，
	# 焦点丢失会自动隐藏面板 -> 由守卫取消统一收尾，效果可再点）。
	hidden_card_view_panel.popup_hide.connect(Callable(self, "_on_hidden_view_popup_hidden"))
	hidden_card_view_panel.visible = false
	popup_overlay.add_child(hidden_card_view_panel)

	# ── 步进数值输入面板（pilot_004 装甲转能：LineEdit+±3+键盘）──
	var _StepperPanel = preload("res://scripts/ui/stepper_panel.gd")
	stepper_panel = _StepperPanel.new()
	stepper_panel.choice_made.connect(Callable(self, "_on_choice_made"))
	stepper_panel.choice_cancelled.connect(Callable(self, "_on_choice_cancelled"))
	stepper_panel.visible = false
	popup_overlay.add_child(stepper_panel)

	# ── 弃牌选择面板（初始隐藏）──
	discard_select_panel = _DiscardSelectPanel.new()
	discard_select_panel.selection_completed.connect(Callable(self, "_on_discard_selection_completed"))
	discard_select_panel.selection_cancelled.connect(Callable(self, "_on_discard_selection_cancelled"))
	discard_select_panel.visible = false
	popup_overlay.add_child(discard_select_panel)

	# ── pilot_009 美杜莎非阻塞可拖拽展示浮窗（初始隐藏，非模态不入堆栈）──
	# 挂根节点 self（非 popup_overlay 的 CenterContainer）：CenterContainer 会强制居中覆盖
	# position；挂根且 add_child 顺序在 popup_overlay/scrim 之后，自然浮在模态弹窗之上、
	# position（左上）生效、拖拽不偏移。
	card_display_panel = _CardDisplayPanel.new()
	card_display_panel.visible = false
	add_child(card_display_panel)

	# ── 推进多选面板（初始隐藏）──
	thrust_select_panel = _ThrustSelectPanel.new()
	thrust_select_panel.selection_completed.connect(Callable(self, "_on_thrust_selection_completed"))
	thrust_select_panel.selection_cancelled.connect(Callable(self, "_on_thrust_selection_cancelled"))
	thrust_select_panel.visible = false
	popup_overlay.add_child(thrust_select_panel)

	# ── 立即设置装备面板（初始隐藏）──
	immediate_set_equipment_panel = _ImmediateSetEquipmentPanel.new()
	immediate_set_equipment_panel.slot_selected.connect(Callable(self, "_on_immediate_set_slot_selected"))
	immediate_set_equipment_panel.sell_selected.connect(Callable(self, "_on_immediate_set_sell"))
	immediate_set_equipment_panel.cancelled.connect(Callable(self, "_on_immediate_set_cancelled"))
	immediate_set_equipment_panel.visible = false
	popup_overlay.add_child(immediate_set_equipment_panel)

	# ── 联合攻击单选面板（初始隐藏）──
	unite_attack_select_panel = _UniteAttackSelectPanel.new()
	unite_attack_select_panel.selection_completed.connect(Callable(self, "_on_unite_attack_selection_completed"))
	unite_attack_select_panel.selection_cancelled.connect(Callable(self, "_on_unite_attack_selection_cancelled"))
	unite_attack_select_panel.visible = false
	popup_overlay.add_child(unite_attack_select_panel)

	pilot_003_skip_panel = _Pilot003SkipPanel.new()
	pilot_003_skip_panel.skip_players_submitted.connect(Callable(self, "_on_pilot_003_skip_submitted"))
	pilot_003_skip_panel.skip_players_cancelled.connect(Callable(self, "_on_pilot_003_skip_cancelled"))
	pilot_003_skip_panel.visible = false
	popup_overlay.add_child(pilot_003_skip_panel)

	# ── pilot_003 effect_01 选置顶牌单选面板（复用 UniteAttackSelectPanel，通用化后定制文案）──
	pilot_003_choose_top_panel = _UniteAttackSelectPanel.new()
	pilot_003_choose_top_panel.selection_completed.connect(Callable(self, "_on_pilot_003_choose_top_completed"))
	pilot_003_choose_top_panel.selection_cancelled.connect(Callable(self, "_on_pilot_003_choose_top_cancelled"))
	pilot_003_choose_top_panel.visible = false
	popup_overlay.add_child(pilot_003_choose_top_panel)

	# ── 觉醒种类单选面板（初始隐藏）──
	awaken_select_panel = _AwakenSelectPanel.new()
	awaken_select_panel.selection_completed.connect(Callable(self, "_on_awaken_selection_completed"))
	awaken_select_panel.selection_cancelled.connect(Callable(self, "_on_awaken_selection_cancelled"))
	awaken_select_panel.visible = false
	popup_overlay.add_child(awaken_select_panel)
	# 模态弹窗堆栈：监听各弹窗面板可见性，面板被处理器隐藏(visible=false)时自动出栈
	for _pp in [response_panel, weapon_picker_panel, damage_placement_panel, damage_adjust_panel, choice_panel, discard_select_panel, thrust_select_panel, immediate_set_equipment_panel, unite_attack_select_panel, awaken_select_panel, pilot_003_skip_panel, pilot_003_choose_top_panel, hidden_card_view_panel]:
		if _pp != null:
			_pp.visibility_changed.connect(Callable(self, "_on_popup_visibility_changed").bind(_pp))

	# ── 开发者面板（初始隐藏，F3 切换）──
	dev_panel = _DevModePanel.new()
	dev_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	dev_panel.close_requested.connect(Callable(self, "_on_dev_panel_close"))
	# PvP 锁步：dev 编辑走 _net_exec(dev_edit) 双端应用（不本地直改）
	if _is_pvp_mode():
		dev_panel.network_mode = true
		dev_panel.dev_edit_requested.connect(_on_dev_edit_requested)
	else:
		# 本地模式：dev 直接改 state 后 emit edit_applied，刷新主战斗 UI（PvP 走 _net_exec 已刷新，不会 emit 本信号）
		dev_panel.edit_applied.connect(_refresh_battle)
	dev_panel.visible = false
	add_child(dev_panel)
	# 置于最上层，避免被后续 UI 遮挡
	move_child(dev_panel, -1)

	# ── 连接动作系统信号（幂等；context 重建后需重连，见 _apply_pvp_seed_and_build）──
	_connect_action_signals()

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
	# ── 新动作系统：检查是否正在等待输入 ──
	# 只要 ActionUIBridge 在等待任意输入，地图点击一律拦截，绝不 fall-through 到 move_unit。
	# 未识别的输入类型（place_damage_tokens / respond_attack / choose_one / select_weapon /
	# confirm_use_card 等）由各自的面板/按钮处理，地图点击仅忽略。
	if battle.context and battle.context.action_ui_bridge:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if not wait_info.is_empty():
			var input_type: StringName = wait_info.get("input_type", &"")
			match input_type:
				&"mech_multi_select":
					# 通用多选机甲（CHOOSE_MANY_MECHS，奥黛尔 pilot_038）：范围内机甲多选 toggle，
					# 复用 _multi_attack_target_handle_click（含自己/无陷阱/范围校验在此兜底）。
					var mms_mid: StringName = _find_mech_at_hex(hex)
					if mms_mid == &"":
						battle.log.append({"message": "该格无可选机甲；点击红色闪烁格内的机甲选择目标", "details": {}})
						_request_refresh()
						return
					# 范围校验：仅响应技能范围圆内的点击
					var mms_ok := false
					for _mhx in _mech_multi_select_opts.get("hexes", []):
						if int(_mhx.get("q", -999)) == int(hex.get("q", -998)) and int(_mhx.get("r", -999)) == int(hex.get("r", -998)):
							mms_ok = true
							break
					if not mms_ok:
						battle.log.append({"message": "该机甲不在可选择范围内，请点击红色闪烁格内的机甲", "details": {}})
						_request_refresh()
						return
					# 含自己：include_self=false 时拒绝选自己（handle 里 attacker_id 为空不会误拦）
					if mms_mid == StringName(_mech_multi_select_opts.get("source_mech_id", &"")) and not bool(_mech_multi_select_opts.get("include_self", false)):
						battle.log.append({"message": "不能选择自己", "details": {}})
						_request_refresh()
						return
					_multi_attack_target_handle_click(hex, mms_mid, wait_info)
					return
				&"select_attack_target":
					var target_id: StringName = _find_mech_at_hex(hex)
					# pilot_006 里昂狩猎豁免：只能选标记机甲（约束目标选择）
					if _pilot_006_forced_target != &"" and target_id != &"" and target_id != _pilot_006_forced_target:
						battle.log.append({"message": "里昂狩猎豁免：本次攻击只能以狩猎标记机甲为目标", "details": {}})
						_request_refresh()
						return
					# 多目标攻击选择模式（双连等）：逐个点击机甲收集，可点已选机甲取消，选满自动提交
					if _multi_attack_target_count >= 2:
						_multi_attack_target_handle_click(hex, target_id, wait_info)
						return
					if target_id != &"":
						_clear_attack_highlights()
						# select_attack_target 兼引擎级挂起（pilot_019 缴械冲击目标多选）：
						# 有 _pending_effect 时按 action_id 精确路由（对端槽被 skip_remote_waiting
						# 清空后共享槽 ui_confirmed 丢输入->对端停在挂起三方卡死）；
						# 正常攻击（桥槽 need_input 无 _pending_effect）走 per-end 自驱 ui_confirmed。
						var sat_aid: StringName = StringName(wait_info.get("action_id", &""))
						if sat_aid != &"" and battle.context.timing_engine.has_pending_effect(sat_aid):
							_net_exec("resume_effect", {"action_id": sat_aid, "data": {"target_id": target_id}})
						else:
							_net_exec("ui_confirmed", {"data": {"target_id": target_id}})
					else:
						# 陷阱可选为攻击目标（攻击即引爆，无响应窗口）：点含陷阱标记的格
						var sat_q: int = int(hex.get("q", 0))
						var sat_r: int = int(hex.get("r", 0))
						var sat_trap: Dictionary = {}
						if battle.context and battle.context.game_state:
							for m in battle.context.game_state.map_state.get_markers_at(sat_q, sat_r):
								if m.get("type", &"") == &"TRAP":
									sat_trap = m
									break
						if not sat_trap.is_empty():
							_clear_attack_highlights()
							_net_exec("ui_confirmed", {"data": {
								"target_id": sat_trap.get("marker_id", &""),
								"target_is_trap": true,
								"target_trap_q": sat_q,
								"target_trap_r": sat_r,
							}})
						else:
							battle.log.append({"message": "该格无可攻击目标（机甲或陷阱），请点亮格内的机甲/陷阱或点取消", "details": {}})
							_request_refresh()
					return
				&"select_map_cell":
					# 机雷设陷选格：仅在标绿的可放陷阱格内生效。count>1 时逐格点击收集，选满后提交。
					var smc_q: int = int(hex.get("q", 0))
					var smc_r: int = int(hex.get("r", 0))
					var smc_cell_id: String = ""
					var smc_idx: int = -1
					for _i in range(_map_cell_select_valid.size()):
						var _c = _map_cell_select_valid[_i]
						if int(_c.get("q", -999)) == smc_q and int(_c.get("r", -999)) == smc_r:
							smc_cell_id = String(_c.get("cell_id", "%d,%d" % [smc_q, smc_r]))
							smc_idx = _i
							break
					if smc_cell_id == "":
						battle.log.append({"message": "该格不可选（非绿色高亮格），请点绿格或点取消", "details": {}})
						_request_refresh()
						return
					_map_cell_select_chosen.append(smc_cell_id)
					_map_cell_select_valid.remove_at(smc_idx)
					if _map_cell_select_chosen.size() >= _map_cell_select_count:
						_clear_attack_highlights()
						# 捕获了挂起动作 id 时走 resume_effect 按 id 精确路由（对端槽被
						# skip_remote_waiting 清空后共享槽 ui_confirmed 会丢输入->三方卡死）；
						# 无捕获（旧路径/本地无挂起）回退原 ui_confirmed 共享槽路径。
						if _map_cell_select_action_id != &"":
							if _map_cell_select_count <= 1:
								_net_exec("resume_effect", {"action_id": _map_cell_select_action_id, "data": {"selected_cell_id": smc_cell_id}})
							else:
								_net_exec("resume_effect", {"action_id": _map_cell_select_action_id, "data": {"selected_cell_ids": _map_cell_select_chosen.duplicate()}})
							_map_cell_select_action_id = &""
						elif _map_cell_select_count <= 1:
							_net_exec("ui_confirmed", {"data": {"selected_cell_id": smc_cell_id}})
						else:
							_net_exec("ui_confirmed", {"data": {"selected_cell_ids": _map_cell_select_chosen.duplicate()}})
						return
					# 未选满：刷新高亮（已选格移除->不可再选），继续等待下一格
					_refresh_map_cell_highlight()
					_request_refresh()
					return
				&"select_move_target":
					# 迎击循环移动（回避/疾行/反击）：点格子移动。
					# 仅当该格是当前剩余动力可达的相邻格时才回填，否则给玩家提示并保持等待——
					# 否则 map_service.move_mech_to_hex 静默失败（动力不扣、循环不变），玩家"点了没反应"
					# 误以为卡死，放弃操作后 AI 攻击永远停在 waiting_sub_action → 敌方回合无法结束。
					var mv_mech_id_sm: StringName = StringName(wait_info.get("input_params", {}).get("mech_id", &""))
					var mv_mech_sm = battle.context.game_state.mechs.get(mv_mech_id_sm) if mv_mech_id_sm != &"" else null
					var reachable_sm: Array[Dictionary] = []
					if mv_mech_sm != null:
						var avail_p: int = int(wait_info.get("input_params", {}).get("available_power", 0))
						if avail_p <= 0:
							avail_p = mv_mech_sm.power
						var cells_sm: Dictionary = battle.context.game_state.map_state.cells if battle.context.game_state.map_state else {}
						var _mc_sm: Dictionary = battle.context.map_service.resolve_move_cost_params(mv_mech_sm.owner_player_id)
						reachable_sm = _RangeCalculator.get_move_reachable_hexes(mv_mech_sm.position, avail_p, cells_sm, int(_mc_sm["green_cost"]), _mc_sm["aura_cells"])
					var ok_click := false
					for hx in reachable_sm:
						if int(hx.get("q", -999)) == int(hex.get("q", -998)) and int(hx.get("r", -999)) == int(hex.get("r", -998)):
							ok_click = true
							break
					if not ok_click:
						battle.log.append({"message": "该格不可达（动力不足/非相邻/越界），请点亮绿格或点取消结束移动", "details": {}})
						_request_refresh()
						return
					var cell_id: String = "%d,%d" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
					_net_exec("ui_confirmed", {"data": {"target_cell": cell_id}})
					return
				&"select_mech_target":
					var mech_id: StringName = _find_mech_at_hex(hex)
					if mech_id != &"":
						# 排除自身（CHOOSE_OTHER_MECH 不能选自己；pilot_002 转化选 B）
						var smt_src_mid: StringName = StringName(wait_info.get("input_params", {}).get("mech_id", &""))
						if smt_src_mid != &"" and mech_id == smt_src_mid:
							battle.log.append({"message": "不能选择自己", "details": {}})
							_request_refresh()
							return
						# pilot_021 塔莉娅：只允许选 valid_mech_ids（4格内其他机甲）
						var smt_valid: Array = wait_info.get("input_params", {}).get("valid_mech_ids", [])
						if not smt_valid.is_empty() and mech_id not in smt_valid:
							battle.log.append({"message": "该机甲不在4格范围内，请选择范围内的机甲", "details": {}})
							_request_refresh()
							return
						# 引擎级挂起（_pending_effect）的效果选目标：确认按 action_id 精确路由（resume_effect）。
						# 否则对端槽被 skip_remote_waiting 清空后共享槽 ui_confirmed 早 return 丢输入
						# （骇客窥牌/维罗妮卡/征服/塔莉娅/动力税贡赋等 PvP 三方卡死）。无捕获回退原路径。
						var smt_aid: StringName = StringName(wait_info.get("action_id", &""))
						if smt_aid != &"":
							_net_exec("resume_effect", {"action_id": smt_aid, "data": {"target_id": mech_id}})
						else:
							_net_exec("ui_confirmed", {"data": {"target_id": mech_id}})
					return
				&"select_repair_target":
					# 维修目标：自身或1格内的机甲，且须为非满状态（HP未满或有损伤）
					var mech_id: StringName = _find_mech_at_hex(hex)
					if mech_id != &"":
						var src_mid: StringName = StringName(wait_info.get("input_params", {}).get("mech_id", &""))
						var tgt_mech = battle.context.game_state.mechs.get(mech_id)
						if not _is_repair_target_in_range(mech_id, src_mid):
							battle.log.append({"message": "维修目标须为自身或1格内的机甲", "details": {}})
							_request_refresh()
						elif tgt_mech != null and not _mech_can_be_repaired(tgt_mech):
							battle.log.append({"message": "该机甲满状态（满血且无损伤），无可维修项", "details": {}})
							_request_refresh()
						else:
							# 引擎级挂起的目标选择确认：按 action_id 精确路由（同 select_mech_target 理由，
							# 对端槽被 skip_remote_waiting 清空后共享槽 ui_confirmed 丢输入）。
							var rp_aid: StringName = StringName(wait_info.get("action_id", &""))
							if rp_aid != &"":
								_net_exec("resume_effect", {"action_id": rp_aid, "data": {"target_id": mech_id}})
							else:
								_net_exec("ui_confirmed", {"data": {"target_id": mech_id}})
					return
				_:
					# 其它输入类型：地图点击不响应、不走 move_unit
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
	# 回合守卫：仅在玩家回合允许自由移动。敌方回合（AI 攻击/响应期间）玩家点击空地
	# 不应触发 move_unit——否则玩家可在敌方回合随意移动（bug1）。
	# 注：合法的敌方回合玩家输入（回避移动 select_move_target、损伤放置等）已在上文
	# waiting input 分支处理并 return，不会走到这里。
	# active_player_id 为空（战斗尚未开始回合）时不拦截，兼容初始化。
	if not _is_my_turn():
		return
	# 琳 RE 维修请求方阻塞：确认等待/维修窗口期间不能移动
	if _pilot_024_requester_blocked():
		return
	# 铠威攻击窗口：严格只开放攻击，不能移动
	if _attack_window_active_for_local():
		battle.log.append({"message": "攻击窗口期间不能移动，只能发动攻击", "details": {}})
		return
	# 逐格移动动画进行中（single_move 处于 waiting_timing 50ms/格暂停）：忽略新的移动点击，
	# 否则会与进行中的 single_move 并发（旧动作尚未完成又起新动作）。玩家应等待动画结束或点取消。
	if _has_active_single_move():
		return
	var mv_q := int(hex.get("q", 0))
	var mv_r := int(hex.get("r", 0))
	_net_exec("move", {"player_id": local_player_id, "q": mv_q, "r": mv_r})

	## 点击行动牌（新规则：弹出确认对话框）
func _on_action_card_clicked(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	if gs == null:
		return
	# 请求方被 RE 维修流程阻塞（确认等待/维修窗口）：不能打牌
	if _pilot_024_requester_blocked():
		battle.log.append({"message": "维修窗口进行中，等待琳维修", "details": {}})
		_request_refresh()
		return
	# 琳维修窗口激活且本机是琳：仅维修牌可点，其他行动牌不可用。
	# 跳过 _is_my_turn 守卫（窗口期间是请求方回合，琳不在自己回合）。
	# 维修牌放行走确认对话框，目标锁定请求方（_execute_effect 已注入，跳过维修目标检查）。
	if _pilot_024_lin_window_active():
		var wcard = gs.get_card(card_id)
		if wcard == null or wcard.def == null:
			return
		if wcard.def.card_id != &"action_013_维修":
			battle.log.append({"message": "维修窗口期间只能使用维修牌或「当作维修」效果", "details": {}})
			_request_refresh()
			return
		_show_cancel_button(false)  # 隐藏「取消维修」，避免与维修流程冲突
		_choice_select_card_id = card_id
		var win_options: Array[Dictionary] = [
			{"label": "确定使用", "effect_id": &"__confirm_use_action_card__"},
		]
		choice_panel.configure(win_options)
		choice_panel.visible = true
		battle.log.append({"message": "使用行动牌: %s - 确认使用？" % wcard.def.display_name, "details": {}})
		return
	# 铠威攻击窗口：严格只开放「攻击」行动牌（窗口期间攻击不消耗回合攻击次数，由
	# use_action_card 的 attack_window 豁免处理）。其余行动牌（辅助/维修等）不可用。
	if _attack_window_active_for_local():
		var aw_card = gs.get_card(card_id)
		if aw_card == null or aw_card.def == null:
			return
		if String(aw_card.def.action_type) != "攻击":
			battle.log.append({"message": "攻击窗口期间只能发动攻击", "details": {}})
			_request_refresh()
			return
		_choice_select_card_id = card_id
		var aw_options: Array[Dictionary] = [
			{"label": "确定使用", "effect_id": &"__confirm_use_action_card__"},
		]
		choice_panel.configure(aw_options)
		choice_panel.visible = true
		battle.log.append({"message": "使用行动牌: %s - 确认使用？" % aw_card.def.display_name, "details": {}})
		return
	# 通用弹窗锁定：有等待输入（目标选择/二选一/弃牌等弹窗进行中）时禁止主动打行动牌，
	# 否则弹窗期间还能出牌造成状态错乱（塔莉娅021 选目标机甲时仍能使用行动牌）。
	# 琳维修窗已在上面分支处理（仅维修牌可点），此处只拦其余弹窗。响应窗口迎击走 response_panel 不在此。
	if battle.context.action_ui_bridge and not battle.context.action_ui_bridge.get_waiting_action_info().is_empty():
		battle.log.append({"message": "有进行中的选择/操作，先完成或点「取消」后再打牌", "details": {}})
		_request_refresh()
		return
	# 回合守卫：玩家只能在己方回合主动打出行动牌（迎击牌走响应窗口，不受此限）。
	if not _is_my_turn():
		return
	var card = gs.get_card(card_id)
	if card == null or card.def == null:
		return

	var action_type: String = String(card.def.action_type)

	# 迎击牌不能主动打出
	if action_type == "迎击":
		battle.log.append({"message": "迎击牌只能在响应窗口中使用", "details": {}})
		_request_refresh()
		return

	# 检查攻击牌是否有可用目标（规则10：若最大范围内没有任何目标，该攻击牌也无法使用）
	# 含虚拟武器（神莺躯干）：只有虚拟武器能打到目标时攻击牌同样可用。
	if action_type == "攻击":
		var mech = gs.get_mech_for_player(local_player_id)
		if mech:
			var weapon_ids: Array[StringName] = _get_all_usable_weapon_ids(mech, true)
			var has_valid_target: bool = false
			for wid in weapon_ids:
				# 冷却中/锁定中的武器不能攻击（effect_125/104），不计入可用目标检查
				var w_card = gs.cards.get(wid) if gs else null
				if w_card != null and not String(wid).begins_with("frame_base_weapon") and _weapon_attack_blocked(gs, w_card):
					continue
				if _weapon_has_attackable_target(mech, wid):
					has_valid_target = true
					break
			if not has_valid_target:
				battle.log.append({"message": "没有可攻击的目标", "details": {}})
				_request_refresh()
				return

	# 维修牌：自身与1格内机甲均满状态（满血+0损伤）则无可维修目标，点击无反应
	if card.def.card_id == &"action_013_维修":
		if not _has_repairable_target():
			battle.log.append({"message": "维修：自身与1格内机甲均满状态，无可维修目标", "details": {}})
			_request_refresh()
			return
	# 联合：点击时先询问「使用联合效果 / 弃置抽1张 / 取消」（牌仍在手牌，未进临时区）。
	# 弃置抽牌路径不走 use_action_card，由 _on_choice_made -> unite_discard_draw 网络op 弃此牌+抽1张。
	if card.def.card_id == &"action_018_联合":
		_choice_select_card_id = card_id
		var unite_options: Array[Dictionary] = [
			{"label": "使用联合效果", "effect_id": &"__unite_use__"},
			{"label": "弃置此牌，抽1张行动牌", "effect_id": &"__unite_discard_draw__"},
			{"label": "取消", "effect_id": &"__unite_cancel__"},
		]
		choice_panel.configure(unite_options)
		choice_panel.visible = true
		battle.log.append({"message": "联合：选择「使用联合效果」或「弃置此牌抽1张行动牌」", "details": {}})
		return

	# ── 新动作系统：通过 ActionService 执行，弹出确认对话框 ──
	if battle.context.action_ui_bridge:
		# 使用确认对话框（通过choice_panel）：仅"确定使用"一项，取消走底部固定取消按钮。
		_choice_select_card_id = card_id  # 保存当前确认的卡牌ID
		var options: Array[Dictionary] = [
			{"label": "确定使用", "effect_id": &"__confirm_use_action_card__"},
		]
		choice_panel.configure(options)
		choice_panel.visible = true
		battle.log.append({"message": "使用行动牌: %s - 确认使用？" % card.def.display_name, "details": {}})
		return


## 点击装备牌
func _on_equipment_card_clicked(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	# PvP client 也可点击装备牌进入槽位选择（确认槽位后走 set_equipment intent 上行 host）。
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	if not card or not card.def:
		return

	# 铠威攻击窗口：严格只开放攻击，不能设装备
	if _attack_window_active_for_local():
		battle.log.append({"message": "攻击窗口期间只能发动攻击", "details": {}})
		_request_refresh()
		return

	# 点击装备牌时，进入设置操作，让玩家选择槽位
	_enter_set_equipment_mode(card_id)

## 进入武器槽位选择模式（两个武器槽都有装备时）
func _enter_weapon_slot_select(card_id: StringName) -> void:
	_weapon_slot_select_card_id = card_id
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if not mech:
		return
	# 显示当前两个武器槽的装备，让玩家选择替换哪个（冷却中/锁定中的武器也可替换）
	var weapon_ids: Array[StringName] = mech.get_weapon_ids()
	weapon_picker_panel.configure(battle.context, weapon_ids, "── 选择要替换的武器 ──", mech, true)
	weapon_picker_panel.visible = true
	battle.log.append({"message": "选择要替换的武器槽", "details": {}})
	_show_cancel_button(true)
	_request_refresh()


## 武器槽位选择回调（复用 weapon_selected 信号，但此时是选择替换哪个槽）
func _on_weapon_slot_selected_for_equipment(weapon_id: StringName) -> void:
	weapon_picker_panel.visible = false
	_show_cancel_button(false)
	var card_id: StringName = _weapon_slot_select_card_id
	_weapon_slot_select_card_id = &""
	if card_id == &"":
		_request_refresh()
		return
	# 找到选中武器所在的槽位
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if not mech:
		_request_refresh()
		return

	var target_slot_id: StringName = &""
	var wid_str = String(weapon_id)

	# 检查是否是基础武器虚拟 ID
	if wid_str.begins_with("frame_base_weapon"):
		if wid_str.begins_with("frame_base_weapon_"):
			# "frame_base_weapon_" 长度为 18，trim_prefix 取末尾数字（1-based）→ 0-based 索引
			var index = wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
			target_slot_id = StringName("weapon_%d" % [index + 1])
		else:
			target_slot_id = &"weapon_1"
	else:
		# 普通装备武器
		for slot_id: StringName in [&"weapon_1", &"weapon_2"]:
			if mech.slots.has(slot_id) and mech.slots[slot_id].equipped_card:
				if mech.slots[slot_id].equipped_card.instance_id == weapon_id:
					target_slot_id = slot_id
					break

	if target_slot_id == &"":
		battle.log.append({"message": "未找到对应武器槽", "details": {}})
		_request_refresh()
		return
	_do_set_equipment(card_id, target_slot_id)


## 实际执行装备设置
func _do_set_equipment(card_id: StringName, slot_id: StringName) -> void:
	_net_exec("set_equipment", {"player_id": local_player_id, "card_instance_id": card_id, "slot_id": slot_id})


## 装备主动效果被点击（机动头部抽牌、狙击右臂弃牌回动力等）
## 走 effect_fire 动作完整执行（条件/费用/once_per_turn 检查 + 效果动作），不走旧 use_active_effect。
func _on_equipment_active_clicked(card_instance_id: StringName, effect_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	_net_exec("equipment_active", {"card_instance_id": card_instance_id, "effect_id": effect_id})


## granted 授予效果 EX 按钮被点击（pilot_002 莱比尔协同·进攻）。
## 走 granted_effect op 锁步（携带 acting_mech_id=执行机甲 A），双端各 _net_granted_effect 构造 effect_fire。
func _on_granted_effect_clicked(card_instance_id: StringName, effect_id: StringName, mech_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	_net_exec("granted_effect", {"card_instance_id": card_instance_id, "effect_id": effect_id, "acting_mech_id": mech_id})


## 结束玩家回合
func _end_player_turn() -> void:
	if battle == null:
		return
	# 回合守卫：仅在玩家回合允许结束。敌方回合（含 AI 攻击等待玩家响应/回避移动期间）
	# 若允许玩家点“结束回合”会调 end_turn(player) 搅乱状态机，导致敌方回合无法正常兜底结束、
	# 玩家被迫手动点结束回合才能进入下一回合（bug1）。
	# active_player_id 为空（战斗尚未开始回合）时不拦截，兼容初始化。
	if not _is_my_turn():
		battle.log.append({"message": "非己方回合，无法结束回合", "details": {}})
		_refresh_battle()
		return
	# 琳 RE 维修请求方阻塞：确认等待/维修窗口期间不能结束回合
	if _pilot_024_requester_blocked():
		battle.log.append({"message": "维修窗口进行中，等待琳维修", "details": {}})
		_refresh_battle()
		return
	# 铠威攻击窗口：不能结束回合（须发动完窗口攻击或点「取消攻击」关闭窗口）
	if _attack_window_active_for_local():
		battle.log.append({"message": "攻击窗口期间不能结束回合", "details": {}})
		_refresh_battle()
		return
	_cancel_attack_mode()

	# 直接结束回合：弃置超限行动牌由 end_turn 流程第5步弹【阻塞窗】处理
	# （正常顺序执行：拾荒等 TURN_BEFORE_END 时点效果先结算完，才轮到弃超限牌选牌窗）。
	# PvP 走锁步 end_turn op（双端执行 end+切对手），PvE 走原 _finish_player_turn（含 AI 敌方回合）
	if _is_pvp_mode():
		_net_exec("end_turn", {"player_id": local_player_id})
	else:
		_finish_player_turn()


## 实际执行结束回合流程（点结束回合直接进入；弃超限牌在第5步阻塞窗中由玩家选择，
## 弃置挪到清理残留动作【之后】执行，保护弃牌触发的监听型效果弹窗不被 cancel 杀掉）
func _finish_player_turn() -> void:
	# 清理玩家回合中残留的未完成动作（如打出"破甲"后直接结束回合，
	# 攻击效果动作 weapon_select 永远无人响应，残留动作会阻塞后续敌方回合的结束检查）。
	# 必须在弃置超限牌之前：弃牌发 DISCARD_AFTER 时点会挂起监听型效果弹窗（肯尼斯效果2等），
	# cancel 在弃牌后会无差别杀掉挂起中的弹窗动作致其成孤儿点不动。
	if battle.context and battle.context.action_engine:
		battle.context.action_engine.cancel_all_actions()
	# 弃置超限行动牌在 end_turn 流程第5步的阻塞窗中由玩家选择后弃置
	# （TURN_BEFORE_END 拾荒等时点效果先结算；弃牌走 discard_card 动作发时点，
	# 监听器如安德洛美达 effect_01b 回收维修正常触发）。
	var result = battle.end_player_turn()
	SLog.log_call("app_root", "end_player_turn", {}, result)
	if not _status_ok(result):
		battle.log.append({"message": "结束回合失败", "details": {"reason": _status_message(result)}})
	_refresh_battle()
	_finish_battle_if_needed()
	if get_result_state() != "active":
		return

	if result.get("suspended", false):
		# 回合结束流程挂起（拾荒/修整/事件到期弹窗等）：流转延迟到 end_turn_flow_completed
		_pending_turn_flow = {"active": true, "player_id": String(local_player_id), "local_flow": true}
		return

	# PvP：直接切对手回合（无 AI 驱动）；PvE：开始敌方回合（多步式 AI）
	if _is_pvp_mode():
		_pvp_start_other_turn()
	else:
		_start_enemy_turn_flow()


## 判断某 player_id 是否由人类控制（用于 UI 输入路由：人类才弹窗/响应点击，AI 走代码决策）。
## 未知（无 context / 玩家不存在）默认 true（人类），保守走 UI 而非自动决策。
func _is_human_player_id(pid: StringName) -> bool:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return true
	var p = battle.context.game_state.players.get(pid)
	if p == null:
		return true
	return p.is_human


## 判断当前是否轮到本窗口行动（active == local_player_id）。
## PvE/PvP 通用：PvE 下 active=enemy(AI) 时返回 false 锁住玩家输入；
## PvP 下 active=对手时返回 false，host/client 各自只能在己方回合操作。
## active 为空（战斗未开始回合）保守允许。
func _is_my_turn() -> bool:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return true
	var ap: StringName = battle.context.game_state.active_player_id
	if ap == &"":
		return true
	return ap == local_player_id


## 敌方回合流程
func _start_enemy_turn_flow() -> void:
	var result = battle.start_enemy_turn()

	match result.get("state", ""):
		"waiting_timing", "waiting_input", "waiting_effect_action":
			# 新系统：攻击暂停等待响应/输入/效果动作，由 TimingEngine/ActionUIBridge 信号驱动后续流程。
			# AI 改走 use_action_card 后，顶层为 use_action_card，attack 效果动作在 ATTACK_AT 暂停时
			# 顶层处于 waiting_sub_action；与 waiting_timing 同样交由信号驱动，不在此处结束回合。
			_refresh_battle()
		"awaiting_damage_placement":
			_show_damage_placement(result)
		"ai_done":
			# AI 无可行动作（开局即无可打牌/不可攻击/不在射程）→ 直接结束敌方回合
			battle.finish_enemy_turn()
			_refresh_battle()
			_finish_battle_if_needed()
		"battle_over", "done":
			_refresh_battle()
			_finish_battle_if_needed()
		_:
			_refresh_battle()
			_finish_battle_if_needed()


## Response selected (new system: delegate to TimingEngine.handle_response_selection)
func _on_response_selected(card_id: StringName, effect_id: StringName = &"") -> void:
	if battle == null or battle.context == null:
		return
	response_panel.visible = false
	# 锁步:走 respond_attack op（双端各自从 card_id+effect_id 重建 selected_cards）。PvE 退化本地执行。
	var rs_wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info() if battle.context.action_ui_bridge else {}
	var rs_action_id: StringName = rs_wait.get("action_id", &"")
	_net_exec("respond_attack", {"action_id": rs_action_id, "card_instance_id": card_id, "effect_id": effect_id, "pass": false})


## Response passed (new system: call TimingEngine.handle_response_selection with empty array)
## 问题4：传 local_player_id 做多玩家 pass 追踪（一个玩家 pass 不影响其他人响应权）
func _on_response_passed() -> void:
	if battle == null or battle.context == null:
		return
	response_panel.visible = false
	var rp_wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info() if battle.context.action_ui_bridge else {}
	var rp_action_id: StringName = rp_wait.get("action_id", &"")
	_net_exec("respond_attack", {"action_id": rp_action_id, "pass": true, "player_id": String(local_player_id)})


## New action system: availability effect selected from response panel
## This handles the case when player selects a response card in the new action system
func _on_availability_effect_selected(effect_id: StringName, card_instance_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	response_panel.visible = false

	# 获取当前等待的动作信息
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		_request_refresh()
		return

	var action_id: StringName = wait_info.get("action_id", &"")
	if action_id == &"":
		_request_refresh()
		return

	# 锁步:走 respond_attack op（双端从 card_id+effect_id 重建 selected_cards）
	_net_exec("respond_attack", {"action_id": action_id, "card_instance_id": card_instance_id, "effect_id": effect_id, "pass": false})


## Continue enemy turn after response (new system: TimingEngine auto-resumes action)
func _continue_enemy_turn_after_response(resolve_result: Dictionary) -> void:
	var result = battle.finish_enemy_turn()
	_request_refresh()
	_finish_battle_if_needed()


# ═══════════════════════════════════════════
# Evade/Assault movement and Counterattack - migrated to new Action system
# (Movement from evade/rush/counter handled by TimingEngine LISTEN effects;
#   app_root no longer manages hex-click movement selection for these)
# ═══════════════════════════════════════════
# 迎击移动（回避/疾行/反击）与反击(attack2)
# ═══════════════════════════════════════════

## 进入迎击移动模式：高亮可达格子，等待玩家点击
func _enter_evade_movement_mode() -> void:
	_evade_movement_active = true
	var gs = battle.context.game_state
	var attack_context: Dictionary = {}  # old attack context removed in new system
	var target_id: StringName = attack_context.get("target_id", &"")
	var target_mech = gs.mechs.get(target_id)
	if target_mech == null:
		_evade_movement_active = false
		return
	var budget: int = 0  # get_evade_movement_budget removed in new system
	var _mc_ev: Dictionary = battle.context.map_service.resolve_move_cost_params(target_mech.owner_player_id)
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(
		target_mech.position, budget, gs.map_state.cells, int(_mc_ev["green_cost"]), _mc_ev["aura_cells"]
	)
	# 允许停留原地（也算移动完成）
	reachable.append({"q": int(target_mech.position.get("q", 0)), "r": int(target_mech.position.get("r", 0))})
	if battle_board:
		battle_board.highlight_hexes(reachable)
	battle.log.append({"message": "迎击移动：使用 %d 动力选择移动目标格（可点击原地停留）" % budget, "details": {}})
	_show_cancel_button(true)
	_request_refresh()


## 玩家在迎击移动模式下点击格子
func _execute_evade_movement(hex: Dictionary) -> void:
	var resolve_result: Dictionary = {}  # execute_evade_movement removed in new system
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
	var attack_context: Dictionary = {}  # old attack context removed in new system
	var attacker_id: StringName = attack_context.get("attacker_id", &"")
	var attacker_mech = gs.mechs.get(attacker_id)
	if attacker_mech == null:
		_assault_movement_active = false
		return
	var budget: int = 0  # get_assault_movement_budget removed in new system
	var _mc_as: Dictionary = battle.context.map_service.resolve_move_cost_params(attacker_mech.owner_player_id)
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(
		attacker_mech.position, budget, gs.map_state.cells, int(_mc_as["green_cost"]), _mc_as["aura_cells"]
	)
	# 允许停留原地（也算移动完成）
	reachable.append({"q": int(attacker_mech.position.get("q", 0)), "r": int(attacker_mech.position.get("r", 0))})
	if battle_board:
		battle_board.highlight_hexes(reachable)
	battle.log.append({"message": "强袭移动：使用 %d 动力选择移动目标格（可点击原地停留）" % budget, "details": {}})
	_show_cancel_button(true)
	_request_refresh()


## 玩家在强袭移动模式下点击格子
func _execute_assault_movement(hex: Dictionary) -> void:
	var resolve_result: Dictionary = {}  # execute_assault_movement removed in new system
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
	var pending: Dictionary = {}  # get_counterattack_pending removed in new system
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
	_request_refresh()


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
		weapon_picker_panel.configure(battle.context, weapon_ids, "── 反击：选择武器 ──", source_mech)
		weapon_picker_panel.visible = true
	_request_refresh()


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
	var weapon_range: int = _get_weapon_range(source_mech, _counterattack_weapon_id)
	var _attack_aura: Dictionary = battle.context.map_service.get_attack_aura_cells()
	# 攻击路径障碍（其他机甲格不可穿过）+ 陷落"不能被选为目标"排除
	var _attack_blocked: Dictionary = battle.context.map_service.get_attack_blocked_keys(source_mech_id)
	var highlights: Array[Dictionary] = []
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if mech_id == source_mech_id:
			continue
		if m.has_status(&"cannot_be_targeted"):
			continue
		if _RangeCalculator.is_in_weapon_range(source_mech.position, m.position, weapon_range, gs.map_state.cells, _attack_aura, _attack_blocked):
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
	_request_refresh()


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
	var weapon_range: int = _get_weapon_range(source_mech, _counterattack_weapon_id)
	var _attack_aura: Dictionary = battle.context.map_service.get_attack_aura_cells()
	var _attack_blocked: Dictionary = battle.context.map_service.get_attack_blocked_keys(source_mech_id)
	# 查找点击位置上、在反击方武器范围内的机甲（除反击方自身）
	var target_mech_id: StringName = &""
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if mech_id == source_mech_id:
			continue
		if m.has_status(&"cannot_be_targeted"):
			continue
		if int(m.position.get("q", 0)) == int(hex.get("q", 0)) and int(m.position.get("r", 0)) == int(hex.get("r", 0)):
			if _RangeCalculator.is_in_weapon_range(source_mech.position, m.position, weapon_range, gs.map_state.cells, _attack_aura, _attack_blocked):
				target_mech_id = mech_id
				break
	if target_mech_id == &"":
		battle.log.append({"message": "该位置无可用反击目标", "details": {}})
		_request_refresh()
		return

	_counterattack_target_select_active = false
	# 先把玩家选中的反击武器 id 存入 pending（_counterattack_weapon_id 此刻仍是选中值，
	# 下面清空后才会丢失），再清空本地选择态。
	_counterattack_pending["weapon_id"] = _counterattack_weapon_id
	_counterattack_pending["target_id"] = target_mech_id
	_counterattack_weapon_id = &""
	if battle_board:
		battle_board.clear_highlight()
	_show_cancel_button(false)
	# 反击期间损伤放置完成应结束敌方回合
	# enemy_turn_phase removed - handled by new system
	# New system: counterattack via TimingEngine
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
	var pending: Dictionary = {}  # New system: counterattacks handled by TimingEngine
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
		var wrange: int = _get_weapon_range(source_mech, weapon_id)
		var _ai_blocked: Dictionary = battle.context.map_service.get_attack_blocked_keys(source_mech_id)
		var target_id: StringName = &""
		var default_target: StringName = pending.get("target_id", &"")
		if default_target != &"" and gs.mechs.has(default_target) and not gs.mechs[default_target].destroyed:
			if _RangeCalculator.is_in_weapon_range(source_mech.position, gs.mechs[default_target].position, wrange, gs.map_state.cells, {}, _ai_blocked):
				target_id = default_target
		if target_id == &"":
			for mech_id: StringName in gs.mechs:
				var m = gs.mechs[mech_id]
				if m == null or m.destroyed or mech_id == source_mech_id:
					continue
				if m.has_status(&"cannot_be_targeted"):
					continue
				if _RangeCalculator.is_in_weapon_range(source_mech.position, m.position, wrange, gs.map_state.cells, {}, _ai_blocked):
					target_id = mech_id
					break
		if target_id == &"":
			battle.log.append({"message": "AI反击范围内无机甲可攻击，取消反击", "details": {}})
			return
		pending["weapon_id"] = weapon_id
		pending["target_id"] = target_id
	var result: Dictionary = {}  # New system: counterattack via TimingEngine
	return
	_request_refresh()
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

## 新动作系统：TimingEngine 时点信号回调（用于消息日志/调试 + 逐格移动轻量刷新）
func _on_timing_fired(timing: StringName, payload: Dictionary) -> void:
	if message_log:
		message_log.on_timing_fired(timing, payload)
	if battle == null or battle.context == null:
		return
	# 逐格移动：每格 BASIC_MOVE_AFTER/SETTLE 后轻量刷新棋盘（仅同步 units + 状态栏 + board），
	# 让玩家看到机甲逐格移动。配合 single_move 的 yield_frame 50ms/格暂停。
	# 不走 _request_refresh 全量（避免每格全量重建手牌/装备/技能/消息）；移动期间这些面板不变。
	# 其它时点仍走 _request_refresh 延迟合并全量刷新。
	var t := String(timing)
	if t == "BASIC_MOVE_AFTER" or t == "BASIC_MOVE_SETTLE":
		_refresh_board_only()
	else:
		# 不在此处直接 _refresh_battle--时点链同帧爆发多次会全量重建多次。
		# 走 _on_equipment_effect_fired 的 _request_refresh 路径即可覆盖（装备效果时点也会触发它）。
		pass


## 装备牌效果发动信号转发给消息框（显示「⚙ [装备] 牌名 发动效果」）
func _on_equipment_effect_fired(card_name: String, effect_id: StringName, description: String, source_mech_id: StringName) -> void:
	if message_log:
		message_log.on_equipment_effect_fired(card_name, effect_id, description, source_mech_id)
	# 时点结算后同步画面/数值：ATTACK_AFTER(伤害/HP/损伤标记)、TURN_START(抽牌/加金币/回复动力)、
	# ATTACK_SETTLE 等。此前刷新完全靠 UI 确认回调手动调用，不经过弹窗的时点链结算
	# （如攻击伤害结算、回合开始资源回复）会导致"实际变了但画面不刷新，得再操作一下才看到"。
	# 延迟合并：一次攻击爆发 5 个时点，同步 _refresh_battle() × 5 = 5 次全量重建，卡顿。
	# 改 _request_refresh() → call_deferred + 脏标记，同一帧多次时点末帧仅刷新一次。
	# 守卫不在同步处查——timing_fired.emit 先于响应窗口 need_input 设置（见 TimingEngine.fire_timing），
	# 此刻 get_waiting_action_info() 仍空会误放行。守卫移入 _refresh_battle_coalesced 帧末执行，
	# 届时等待输入态已稳定，能正确跳过以保留迎击移动/损伤放置/响应窗口的高亮与弹窗。
	if battle == null or battle.context == null:
		return
	_request_refresh()

## 动作完成回调：敌方回合中所有动作结算完毕后接续结束敌方回合
## 响应窗口/损伤放置等由 UI 信号驱动恢复的路径，完成后无人调用 finish_enemy_turn()，
## 导致敌方回合永不结束、玩家回合（含动力回复）不开始。此处统一兜底。
func _on_action_completed(_action_id: StringName, _action_type: StringName, _record: Dictionary) -> void:
	if battle == null or battle.context == null:
		return
	if _DIAG_ENEMY_TURN:
		SLog.log_raw("[DIAG _on_action_completed] received: action=" + String(_action_id) + " type=" + String(_action_type) + " active_player=" + String(battle.context.game_state.active_player_id))
	# 动作自然完成(非经取消/确认路径)时，若此时无其他等待输入的动作，
	# 清理地图高亮与取消按钮——否则 move_target_select 等弹窗留下的绿色高亮
	# 和取消按钮会残留到回合切换后（迎击移动后攻击立即结算的残留UI问题）。
	# 仅当确实没有等待中的动作时才清，避免误清损伤放置/响应窗口等并行流程。
	if battle.context.action_ui_bridge:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if wait_info.is_empty():
			if battle_board:
				battle_board.clear_highlight()
				battle_board.clear_attack_targets()
			# 仅当没有进行中的单次移动时才隐藏取消按钮--逐格移动中每格 basic_move
			# 子动作完成都会触发本回调，但父 single_move 仍在进行（waiting_timing 暂停），
			# 取消按钮应保留到移动真正结束（父动作完成时 _has_active_single_move 为 false）。
			if not _has_active_single_move():
				_show_cancel_button(false)
			# 迎击移动结束（无等待动作），清空攻击范围缓存
			_clear_evade_range_cache()
	# 顶层自由移动完成：轻量刷新（清移动连线+面板），避免全量 _refresh_battle 重建手牌 +
	# board.configure 重算 _grid_scale 在布局抖动时致界面抖动。效果驱动的子动作 single_move
	#（回避/反击/强袭，parent_action_id 非空）不走此分支，仍由全量刷新覆盖攻击流程。
	# 仅人类方移动（PvP 任意方 / PvE 玩家方）走轻量刷新；PvE 敌方(AI)移动需走下方
	# _check_enemy_turn_complete 接续 AI 回合，不能提前 return。
	if _action_type == &"single_move" and String(_record.get("parent_action_id", &"")) == &"" \
		and (_is_pvp_mode() or battle.context.game_state.active_player_id != &"enemy"):
		_refresh_after_move_end()
		return
	# PvP 锁步：无 AI 驱动,双端动作完成后刷新画面。
	if _is_pvp_mode():
		_request_refresh()
		return
	# 仅敌方回合需要兜底接续（玩家回合由“结束回合”按钮驱动）
	if battle.context.game_state.active_player_id != &"enemy":
		if _DIAG_ENEMY_TURN:
			SLog.log_raw("[DIAG _on_action_completed] skip: active_player_id=" + String(battle.context.game_state.active_player_id) + " action=" + String(_action_id) + " type=" + String(_action_type))
		# 玩家回合：动作结算完成后同步画面/数值。此前玩家回合此处直接 return 不刷新，
		# 导致不经过 UI 弹窗确认的动作（时点链/效果动作结算，如攻击伤害结算）画面与数值
		# 不更新，得再操作一下才看到。延迟合并到帧末——动作完成常与其 ATTACK_SETTLE
		# 等时点在同一帧爆发，合并避免双重重建。守卫在 _refresh_battle_coalesced 帧末
		# 执行（届时等待输入态已稳定），有并行 need_input 流程则跳过保留高亮与弹窗。
		_request_refresh()
		return
	if _DIAG_ENEMY_TURN:
		SLog.log_raw("[DIAG _on_action_completed] will check: action=" + String(_action_id) + " type=" + String(_action_type))
	# call_deferred：等本帧 cleanup_action 跑完、active_actions 状态稳定后再检查
	call_deferred("_check_enemy_turn_complete")


## 检查敌方回合是否所有动作都已结算，是则结束敌方回合开启玩家回合


## 检查敌方回合是否所有动作都已结算，是则结束敌方回合开启玩家回合
func _check_enemy_turn_complete() -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	if gs.active_player_id != &"enemy":
		return  # 已切换（防重入）
	var ac: int = battle.context.action_registry.get_active_count()
	var wi: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info() if battle.context.action_ui_bridge else {}
	if _DIAG_ENEMY_TURN:
		SLog.log_raw("[DIAG _check_enemy_turn_complete] active_count=" + str(ac) + " waiting_empty=" + str(bool(wi.is_empty())))
	# 仍有等待玩家输入的动作（损伤面板/响应窗口未关）→ 不该结束回合
	if battle.context.action_ui_bridge and not battle.context.action_ui_bridge.get_waiting_action_info().is_empty():
		if _DIAG_ENEMY_TURN:
			SLog.log_raw("[DIAG] 仍有等待输入: " + str(wi))
		return
	# 检查是否有处于等待态的动作（waiting_input/waiting_timing/waiting_sub_action）。
	# 已完成/已取消的残留动作（cleanup 时序未清）不应阻塞回合结束——
	# 否则玩家迎击响应AI攻击后，ATTACK_SETTLE 完成却因残留 action 永不结束敌方回合。
	# 防御：若残留的动作属于上一回合（玩家回合打牌未完成就结束回合），直接全部取消，
	# 避免永久卡死敌方回合。
	var has_pending := false
	if ac > 0:
		for aid in battle.context.action_registry.get_active_ids():
			var a = battle.context.action_registry.get_action(aid)
			var st = String(a.state) if a != null else "?"
			var tp = String(a.action_type) if a != null else "?"
			var pt = String(a.parent_action_id) if a != null else "?"
			if _DIAG_ENEMY_TURN:
				SLog.log_raw("[DIAG] 残留 action " + String(aid) + " state=" + st + " type=" + tp + " parent=" + pt)
			if st == &"waiting_input" or st == &"waiting_timing" or st == &"waiting_effect_action" or st == &"running":
				has_pending = true
		if has_pending:
			# 有 pending 则直接 return，等其自行完成（子动作通知恢复父动作，action_completed
			# 重新触发本函数）。不再 cancel_all_actions--此前防御清理会误杀合法等待中的攻击
			# （AI 攻击被迎击响应后停在 waiting_effect_action，被当残留取消，攻击凭空消失）。
			# 残留动作根源（重入双重驱动）已由 ActionEngine._run_step_loop 的 completed 守卫修复。
			return
	if _DIAG_ENEMY_TURN:
		SLog.log_raw("[DIAG] 调用 ai_controller.take_next_action / finish_enemy_turn")
	# 所有动作结算完毕、无等待输入 → 由 AIController 决定下一个动作；
	# AI 无可行动作返回 ai_done 时才真正结束敌方回合（end_turn(enemy)+start_turn(player)+restore_power）。
	if battle.context.ai_controller != null:
		var ai_res: Dictionary = battle.context.ai_controller.take_next_action(&"enemy")
		var st = String(ai_res.get("state", &""))
		if st == "ai_done" or st == "battle_over":
			battle.finish_enemy_turn()
	_refresh_battle()
	_finish_battle_if_needed()

## 新动作系统：效果需要玩家选择目标时弹出UI
var _pending_target_action_id: StringName = &""
var _pending_target_effect_id: StringName = &""
func _on_target_selection_requested(action_id: StringName, effect, input_type: StringName, payload: Dictionary) -> void:
	# 锁步:双端都触发,只本方(owner==local)显示高亮等输入,对方忽略(等对方 input)
	if _is_pvp_mode():
		var ts_mid: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
		if ts_mid == &"" and effect != null and effect.source is Dictionary:
			ts_mid = effect.source.get("mech_id", effect.source.get("source_mech_id", &""))
		var ts_owner: StringName = _owner_of_mech_id(ts_mid)
		if ts_owner != &"" and ts_owner != local_player_id:
			return
	_pending_target_action_id = action_id
	_pending_target_effect_id = effect.effect_id if effect else &""
	match input_type:
		&"mech_target_select":
			# 需要选择目标机甲（锁定等）
			_support_target_select_card_id = payload.get("card_instance_id", &"")
			if _support_target_select_card_id != &"":
				# 高亮敌方机甲位置
				if battle_board:
					battle_board.highlight_hexes(_get_all_mech_hexes())
				battle.log.append({"message": "选择目标机甲", "details": {}})
				_show_cancel_button(true)
				_request_refresh()
		&"weapon_charge_select":
			# 聚能武器选择统一走 ActionUIBridge -> _show_popup("weapon_charge_select")。
			# 旧路径 _enter_support_weapon_select 会重复开面板、且仅1把武器时自动 _on_support_weapon_selected
			# -> _play_action_card 重放（selected_weapon_id 不进 record_keys）-> 新动作仍无武器 -> 重新挂起，
			# 表现为"选武器面板一直跳，不点取消结束不了"。故此处不再调用旧路径。
			pass
		&"repair_target_select":
			# 维修：选择自身或范围内机甲（默认1格；机师牌 repair_boost 坎得等 range=4）。高亮这些机甲所在格。
			if battle_board and battle and battle.context:
				var highlights: Array[Dictionary] = []
				var src_mech_id: StringName = StringName(payload.get("mech_id", payload.get("source_mech_id", &"")))
				if src_mech_id == &"":
					var sm = battle.context.game_state.get_mech_for_player(&"player")
					src_mech_id = sm.mech_id if sm else &""
				var src_mech = battle.context.game_state.mechs.get(src_mech_id) if src_mech_id != &"" else null
				var hlt_range: int = _ActionPilotEffects.get_repair_range(battle.context.game_state, src_mech_id)
				for mid: StringName in battle.context.game_state.mechs:
					var m = battle.context.game_state.mechs[mid]
					if m == null or m.destroyed:
						continue
					if src_mech == null or _HexGrid.distance(m.position, src_mech.position) <= hlt_range:
						highlights.append(m.position)
				battle_board.highlight_hexes(highlights)
			battle.log.append({"message": "选择维修目标机甲（自身或范围内）", "details": {}})
			_show_cancel_button(true)
			_request_refresh()
		_:
			push_warning("未知的目标选择类型: %s" % input_type)


## 获取所有机甲位置的格子（用于高亮）
func _get_all_mech_hexes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if battle == null or battle.context == null:
		return result
	var gs = battle.context.game_state
	for mech_id in gs.mechs:
		var mech = gs.mechs[mech_id]
		if mech and not mech.destroyed:
			result.append(mech.position)
	return result

## 新动作系统：ActionUIBridge 请求 UI 弹窗
## 迎击移动(回避/疾行/反击)期间，获取攻击方能攻击到的所有格子(红色闪烁用)。
## 从 active_actions 中找到等待效果动作完成的 attack 动作，取其 attacker_id 与 weapon_range，
# 用 BFS 算武器可达范围。攻击方在迎击移动期间不动，范围固定，按 "attacker_id,range,pos" 缓存。
func _get_evade_attacker_range_hexes(defender_mech_id: StringName) -> Array[Dictionary]:
	if battle == null or battle.context == null:
		_evade_range_hexes = []
		_evade_range_attacker_key = ""
		return []
	var gs = battle.context.game_state
	var action_registry = battle.context.action_registry
	if action_registry == null:
		return _evade_range_hexes

	# 找到正在威胁 defender 的 attack 动作（record.target_id == defender_mech_id）。
	# 链路场景（A 攻 B -> B 反击 A -> A 回避）：A 的原始攻击(#1, target=B)与 B 的反击
	# (#2, target=A)同时处于 waiting_effect_action；旧实现取"第一个 waiting 的 attack"=#1，
	# 红格显示 A 自己的攻击范围（错）。应取 target_id == 回避方(#2)的攻击，显示 B 的反击范围。
	# 反击移动场景（B 反击时自身移动）：mover=B 即 #1 的 target，取 #1 显示 A 的威胁范围（正确）。
	# 取最后一个匹配项=最新创建的攻击=当前正在响应的攻击（active_actions 按创建序插入）。
	var attack_action = null
	for aid: StringName in action_registry.active_actions:
		var act = action_registry.get_action(aid)
		if act == null:
			continue
		if act.action_type == &"attack" and (act.state == &"waiting_effect_action" or act.state == &"waiting_timing"):
			if act.record.get("target_id", &"") == defender_mech_id:
				attack_action = act
	if attack_action == null:
		# 没有威胁 defender 的等待中攻击（异常/非迎击移动场景），返回空，不标红
		return []

	var attacker_id: StringName = attack_action.record.get("attacker_id", &"")
	var weapon_range: int = int(attack_action.record.get("weapon_range", 1))
	var attacker_mech = gs.mechs.get(attacker_id) if attacker_id != &"" else null
	if attacker_mech == null:
		return []

	# 缓存校验：攻击方位置与范围未变则复用
	var attacker_pos: Dictionary = attacker_mech.position
	var cache_key: String = "%s,%d,%s,%s" % [String(attacker_id), weapon_range, str(attacker_pos.get("q", 0)), str(attacker_pos.get("r", 0))]
	if cache_key == _evade_range_attacker_key and not _evade_range_hexes.is_empty():
		return _evade_range_hexes

	# 重新计算武器可达范围（以攻击方位置为中心；光环格视为绿格、耗2射程预算）
	# 机甲格为攻击路径障碍（可作终点不可穿过），与实际攻击判定一致
	var map_cells: Dictionary = gs.map_state.cells if gs.map_state else {}
	var _attack_aura: Dictionary = battle.context.map_service.get_attack_aura_cells()
	var _attack_blocked: Dictionary = battle.context.map_service.get_attack_blocked_keys(attacker_id)
	_evade_range_hexes = _RangeCalculator.get_weapon_reachable_hexes(attacker_pos, weapon_range, map_cells, _attack_aura, _attack_blocked)
	_evade_range_attacker_key = cache_key
	return _evade_range_hexes

## 迎击移动结束时清空缓存（攻击动作完成后调用，避免下次迎击误用旧范围）
func _clear_evade_range_cache() -> void:
	_evade_range_hexes = []
	_evade_range_attacker_key = ""

## ActionUIBridge 请求 UI 弹窗：锁步下双端都触发,只本方(owner==local)显示,对方忽略(等对方 input)
func _on_action_ui_popup_requested(popup_type: StringName, params: Dictionary) -> void:
	# pilot_009 非阻塞展示浮窗：给除目标持有者外的所有客户端（美杜莎+第三方观察者），目标自己不看自己的牌。
	# 不走通用 _popup_owner 门控（那个按 player_id=美杜莎 路由，会漏掉 PvP3 第三方观察者）。
	# 直接配置 + 显示后返回，跳过 _show_popup/_present_popup 模态逻辑；浮窗挂根节点故浮在模态弹窗之上。
	if popup_type == &"pilot_009_card_display":
		var p9d_tgt_owner := _owner_of_mech_id(params.get("target_id", &""))
		if p9d_tgt_owner != &"" and p9d_tgt_owner == local_player_id:
			return  # 目标自己不看（PvE/PvP/PvP3 通用）
		_update_move_overlay()
		if card_display_panel and battle and battle.context:
			var gs = battle.context.game_state
			var p9d_target_id: StringName = params.get("target_id", &"")
			var p9d_holder_name: String = String(p9d_target_id)
			if p9d_target_id != &"" and gs != null:
				var p9d_mech = gs.mechs.get(p9d_target_id)
				if p9d_mech != null and p9d_mech.frame_def != null and String(p9d_mech.frame_def.display_name) != "":
					p9d_holder_name = String(p9d_mech.frame_def.display_name)
			card_display_panel.configure(String(params.get("source_label", "目标行动牌")), p9d_holder_name, params.get("display_cards", []))
		return
	# pilot_028 乌尔宣言展示浮窗：所有玩家（含乌尔自己）都能看到本轮宣言类型。
	# 不走 _popup_owner 门控（那个按 player_id 路由会漏掉 PvP3 第三方观察者与乌尔自己）。
	# 非阻塞：直接配置 + 显示后返回，不进入模态弹窗堆栈。
	if popup_type == &"pilot_028_declared_display":
		var p28d_type: String = String(params.get("declared_type", ""))
		if p28d_type == "":
			p28d_type = "未宣言"
		_update_move_overlay()
		if card_display_panel and battle and battle.context:
			card_display_panel.configure(String(params.get("source_label", "乌尔宣言")), "乌尔", [{"name": "本轮宣言", "type": p28d_type}])
		return
	# pilot_058 卡米拉展示浮窗：只弹给其他玩家（自己不看自己的牌——参考美杜莎 p009 显示对象）。
	# 不走 _popup_owner 门控（那个按 player_id 路由会漏掉 PvP3 第三方观察者）。
	# 非阻塞：直接配置 + 显示后返回，不进入模态弹窗堆栈。
	if popup_type == &"pilot_058_card_display":
		var p58d_owner := _owner_of_mech_id(params.get("owner_mech_id", &""))
		if p58d_owner != &"" and p58d_owner == local_player_id:
			return  # 持有者不看自己的牌（PvE/PvP/PvP3 通用）
		_update_move_overlay()
		if card_display_panel and battle and battle.context:
			var gs = battle.context.game_state
			var p58d_mid: StringName = params.get("owner_mech_id", &"")
			var p58d_holder_name: String = String(p58d_mid)
			if p58d_mid != &"" and gs != null:
				var p58d_mech = gs.mechs.get(p58d_mid)
				if p58d_mech != null and p58d_mech.frame_def != null and String(p58d_mech.frame_def.display_name) != "":
					p58d_holder_name = String(p58d_mech.frame_def.display_name)
			card_display_panel.configure(String(params.get("source_label", "展示行动牌")), p58d_holder_name, params.get("display_cards", []))
		return
	# pilot_066 骇客窥牌展示浮窗：只弹给查看方玩家本人（骇客自己——看别人牌，自己的牌无须隐藏）。
	# 不走 _popup_owner 门控（那个按 player_id 路由会漏掉 PvP3 第三方观察者）；按 owner_player_id==local 过滤。
	# 非阻塞：直接配置 + 显示后返回，不进入模态弹窗堆栈。
	if popup_type == &"pilot_066_card_display":
		if String(params.get("owner_player_id", &"")) != String(local_player_id):
			return  # 只有查看方（骇客玩家）端显示；PvP 双端都触发，非查看方静默
		_update_move_overlay()
		if card_display_panel and battle and battle.context:
			var gs = battle.context.game_state
			var p66d_mid: StringName = params.get("target_mech_id", &"")
			var p66d_holder_name: String = String(p66d_mid)
			if p66d_mid != &"" and gs != null:
				var p66d_mech = gs.mechs.get(p66d_mid)
				if p66d_mech != null and p66d_mech.frame_def != null and String(p66d_mech.frame_def.display_name) != "":
					p66d_holder_name = String(p66d_mech.frame_def.display_name)
			card_display_panel.configure(String(params.get("source_label", "查看目标行动牌")), p66d_holder_name, params.get("display_cards", []))
		return
	# pilot_088 征服宣言+随机展示浮窗：所有玩家端显示（用户决策：合成一个浮窗，宣言类型+展示牌
	# 都展示；目标持有者也能看到自己牌的信息，无泄露）。不走 _popup_owner 门控，不过滤持有者。
	# 非阻塞：直接配置 + 显示后返回，不进入模态弹窗堆栈。
	if popup_type == &"pilot_088_conquer_display":
		_update_move_overlay()
		if card_display_panel and battle and battle.context:
			var gs = battle.context.game_state
			var p88d_mid: StringName = params.get("owner_mech_id", &"")
			var p88d_holder_name: String = String(p88d_mid)
			if p88d_mid != &"" and gs != null:
				var p88d_mech = gs.mechs.get(p88d_mid)
				if p88d_mech != null and p88d_mech.frame_def != null and String(p88d_mech.frame_def.display_name) != "":
					p88d_holder_name = String(p88d_mech.frame_def.display_name)
			card_display_panel.configure(String(params.get("source_label", "征服：宣言与目标随机展示")), p88d_holder_name, params.get("display_cards", []))
		return
	# pilot_088 征服宣言类型三选一（攻击/迎击/辅助，不可取消）：复用 choice_panel 单选。
	# _popup_owner 按 player_id 路由到施法者玩家端。PvP 双端/三方锁步下本信号所有端都触发，
	# 必须在此过滤（此前漏了门控，非施法者端也弹类型框，玩家误操作/只见结果框）。
	if popup_type == &"pilot_088_type_select":
		if _is_pvp_mode():
			var p88_owner: StringName = _popup_owner(&"pilot_088_type_select", params)
			if p88_owner != &"" and p88_owner != local_player_id:
				return  # 对方施法者的宣言类型框，本端不弹
		if choice_panel and battle and battle.context:
			var p088_options: Array = params.get("options", [])
			var p088_typed: Array[Dictionary] = []
			for opt in p088_options:
				if opt is Dictionary:
					p088_typed.append(opt)
			_pilot_088_type_options = p088_typed
			choice_panel.configure(p088_typed, String(params.get("source_label", "选择宣言的行动牌类型")), false)
			# 模态入栈（遮罩阻塞，阻止框外点击穿透；选择经 choice_made 隐藏面板时自动出栈）
			_present_popup(&"choice_prompt", choice_panel)
		return
	# 铠威攻击窗口触发确认：仅窗口归属玩家端弹确认框（PvP 双端都触发本信号，按 owner 过滤）。
	# _show_attack_window_prompt 内 _present_popup 模态入栈（遮罩阻塞，阻止框外点击穿透）。
	if popup_type == &"attack_window_confirm":
		if String(params.get("player_id", &"")) != String(local_player_id):
			return
		if battle and battle.context and battle.context.game_state:
			var aw_g: Dictionary = battle.context.game_state.attack_window_pending_prompt
			if not aw_g.is_empty() and not _attack_window_prompt_showing:
				_show_attack_window_prompt(aw_g)
		return
	# 铠厉通用「被响应→抽2装备设置/弃置获金」触发确认：仅触发归属玩家端弹确认框（PvP 双端都触发本信号，
	# 按 owner 过滤）。_show_responded_equip_confirm_prompt 内 _present_popup 模态入栈。
	if popup_type == &"responded_equip_confirm":
		if String(params.get("player_id", &"")) != String(local_player_id):
			return
		if battle and battle.context and battle.context.game_state:
			var re_g: Dictionary = battle.context.game_state.responded_equip_pending_confirm
			if not re_g.is_empty() and not _responded_equip_prompt_showing:
				_show_responded_equip_confirm_prompt(re_g)
		return
	# 铠德「被响应→三选一」触发选择：仅触发归属玩家端弹三选一（PvP 双端都触发本信号，按 owner 过滤）。
	# 非阻塞 choice_panel，不进入模态弹窗堆栈。
	if popup_type == &"pilot_060_choice":
		if String(params.get("player_id", &"")) != String(local_player_id):
			return
		if battle and battle.context and battle.context.game_state:
			var p60_g: Dictionary = battle.context.game_state.pilot_060_pending_choice
			if not p60_g.is_empty() and not _pilot_060_prompt_showing:
				_show_pilot_060_choice_prompt(p60_g)
		return
	# 铠厉逐张「设置/弃置获金」面板：仅当前卡归属玩家端弹面板（双端都触发本信号，按 owner 过滤）。
	# 复用 immediate_set_equipment_panel（allow_sell=true 且 sell_price=牌面cost，卖出按钮文案改为
	# 「弃置此牌（+N金币）」；隐藏取消按钮——每张必须二选一：设置 / 弃置获金，无跳过）。
	if popup_type == &"responded_equip_card_set":
		if String(params.get("player_id", &"")) != String(local_player_id):
			return
		if not _responded_equip_set_active and immediate_set_equipment_panel and battle and battle.context:
			_responded_equip_set_active = true
			immediate_set_equipment_panel.configure(battle.context, String(params.get("card_id", &"")), params.get("valid_slots", []), String(params.get("mech_id", &"")), true, int(params.get("sell_price", 0)), "被响应抽到的装备：立即设置，或弃置此牌获得金币", true, "弃置此牌（+%d 金币）")
			immediate_set_equipment_panel.visible = true
		return
	if _is_pvp_mode() and popup_type == &"response_window":
		# 多响应方响应窗口（问题3）：响应窗口不再按 target owner 单 owner 门控。
		# 每条可用牌带 owner_player_id（get_available_cards 填充），按本地玩家过滤：
		#   被攻击目标玩家 -> 看自己的迎击牌/响应效果；
		#   相邻且在攻击范围内持反击/疾行的迪恩玩家 -> 单独弹自己的窗口（反击/疾行+挡攻转化）。
		# 无本地条目不弹（迪恩不符条件时本地窗口为空跳过；第三方观察者窗口为空跳过）。
		var rw_cards: Array = params.get("available_cards", [])
		var rw_local: Array = []
		for rw_e in rw_cards:
			if rw_e is Dictionary and StringName(rw_e.get("owner_player_id", &"")) == local_player_id:
				rw_local.append(rw_e)
		if rw_local.is_empty():
			return
		params = params.duplicate()
		params["available_cards"] = rw_local
	elif _is_pvp_mode():
		var owner_pid: StringName = _popup_owner(popup_type, params)
		if owner_pid != &"" and owner_pid != local_player_id:
			# 对方弹窗，本端不显示。释放共享等待槽并恢复队首排队请求：回合并类
			# 并行窗口（拾荒/宝藏/修悟多玩家 TURN_BEFORE_END 同时等待输入）下，
			# 本机玩家的窗口不能被远端不可见窗口占槽阻塞（其输入由对方端
			# resume_effect 网络op 回填，动作本身仍处于挂起）。
			if battle and battle.context and battle.context.action_ui_bridge:
				battle.context.action_ui_bridge.skip_remote_waiting(
					StringName(String(params.get("action_id", &""))))
			return  # 对方弹窗,本端不显示,等对方 input
	# 弹窗显示：关闭移动模态遮罩，让玩家与弹窗交互（移动 pacing 期间弹出的 effect_017 等）
	_update_move_overlay()
	# 记录展示前可见的弹窗面板，供 _present_popup 识别新弹出的面板（板选类无面板则不入栈）
	var _vis_before: Array = _visible_popup_panels()
	_show_popup(popup_type, params)
	var _new_panel = _newly_visible_popup_panel(_vis_before)
	if _new_panel != null:
		_present_popup(popup_type, _new_panel)


## ── 模态弹窗堆栈 ──
## 入栈：新弹窗置顶，隐藏下层面板（避免重影），显示模态遮罩，按类型上强调色。
## 出栈：面板被处理器设 visible=false 时由 visibility_changed 自动触发；损伤面板完成时
## 可能已被堆栈隐藏（visible 无变化不触发回调），由 _dismiss_popup_panel 显式出栈。
func _present_popup(popup_type: StringName, panel) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	_popup_suppress_vis = true
	# 隐藏下层面板（避免重影）；同面板重弹则不隐藏
	if not _popup_stack.is_empty() and _popup_stack.back().panel != panel:
		var lower = _popup_stack.back().panel
		if lower != null and is_instance_valid(lower):
			lower.visible = false
	# 移除既有同面板条目（重弹场景），再入栈
	for i in range(_popup_stack.size() - 1, -1, -1):
		if _popup_stack[i].panel == panel:
			_popup_stack.remove_at(i)
	_popup_stack.append({"popup_type": popup_type, "panel": panel})
	if _popup_scrim != null and is_instance_valid(_popup_scrim):
		_popup_scrim.visible = true
	panel.visible = true
	if panel.get_parent() == popup_overlay:
		popup_overlay.move_child(panel, -1)
	_apply_popup_accent(popup_type, panel)
	_popup_suppress_vis = false


## 从堆栈移除指定面板条目；若为顶层则恢复下层，堆栈空则关闭遮罩。
func _pop_popup_entry(panel) -> void:
	var idx := -1
	for i in range(_popup_stack.size()):
		if _popup_stack[i].panel == panel:
			idx = i
			break
	if idx == -1:
		return
	_popup_stack.remove_at(idx)
	if _popup_stack.is_empty():
		if _popup_scrim != null and is_instance_valid(_popup_scrim):
			_popup_scrim.visible = false
	else:
		var nt = _popup_stack.back().panel
		if nt != null and is_instance_valid(nt):
			if not nt.visible:
				nt.visible = true
			if nt.get_parent() == popup_overlay:
				popup_overlay.move_child(nt, -1)


## 面板可见性变化回调：仅处理"隐藏"（处理器设 visible=false）-> 自动出栈
func _on_popup_visibility_changed(panel) -> void:
	if _popup_suppress_vis:
		return
	if panel == null or not is_instance_valid(panel):
		return
	if panel.visible:
		return
	_pop_popup_entry(panel)


## 显式关闭并出栈某面板（损伤面板完成时可能已被堆栈隐藏，visible 无变化不会触发回调）
func _dismiss_popup_panel(panel) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	_popup_suppress_vis = true
	if panel.visible:
		panel.visible = false
	_popup_suppress_vis = false
	_pop_popup_entry(panel)


## 按 popup_type 给 PanelContainer 面板上不透明背景+强调色描边（与按钮配色区分，避免重影）
func _apply_popup_accent(popup_type: StringName, panel) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	if not (panel is PanelContainer):
		return
	var accent: Color = _POPUP_ACCENT_COLORS.get(popup_type, Color(0.6, 0.6, 0.65))
	var sb = _popup_stylebox_cache.get(accent)
	if sb == null:
		sb = StyleBoxFlat.new()
		sb.bg_color = _POPUP_BG
		sb.set_border_width_all(3)
		sb.border_color = accent
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(12)
		_popup_stylebox_cache[accent] = sb
	panel.add_theme_stylebox_override("panel", sb)


## 构建弹窗按钮专用 Theme：仅覆盖 Button 的 normal/hover/pressed/disabled/focus 样式与字体色，
## 使弹窗内按钮/选项带独立底色+描边，与弹窗深色背景(_POPUP_BG≈0.08)区分，避免同色难辨。
## 设到 popup_overlay 上级联到所有弹窗；只定义 Button 项，其余控件回退项目/默认主题。
func _build_popup_button_theme() -> Theme:
	var t := Theme.new()
	var border := Color(0.40, 0.43, 0.50)
	var border_hover := Color(0.62, 0.66, 0.74)
	var cr := 4
	var cm := 8
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(0.18, 0.19, 0.23)
	sb_normal.border_color = border
	sb_normal.set_border_width_all(1)
	sb_normal.set_corner_radius_all(cr)
	sb_normal.set_content_margin_all(cm)
	var sb_hover := StyleBoxFlat.new()
	sb_hover.bg_color = Color(0.26, 0.28, 0.33)
	sb_hover.border_color = border_hover
	sb_hover.set_border_width_all(2)
	sb_hover.set_corner_radius_all(cr)
	sb_hover.set_content_margin_all(cm)
	var sb_pressed := StyleBoxFlat.new()
	sb_pressed.bg_color = Color(0.12, 0.13, 0.16)
	sb_pressed.border_color = border
	sb_pressed.set_border_width_all(1)
	sb_pressed.set_corner_radius_all(cr)
	sb_pressed.set_content_margin_all(cm)
	var sb_disabled := StyleBoxFlat.new()
	sb_disabled.bg_color = Color(0.12, 0.13, 0.15)
	sb_disabled.border_color = Color(0.24, 0.25, 0.28)
	sb_disabled.set_border_width_all(1)
	sb_disabled.set_corner_radius_all(cr)
	sb_disabled.set_content_margin_all(cm)
	t.set_stylebox("normal", "Button", sb_normal)
	t.set_stylebox("hover", "Button", sb_hover)
	t.set_stylebox("pressed", "Button", sb_pressed)
	t.set_stylebox("disabled", "Button", sb_disabled)
	# focus 用空样式覆盖，去掉 Godot 默认虚线聚焦框（鼠标驱动游戏，无需键盘聚焦框；空样式不遮挡 hover）
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.92, 0.93, 0.95))
	t.set_color("font_hover_color", "Button", Color(1.0, 1.0, 1.0))
	t.set_color("font_pressed_color", "Button", Color(0.85, 0.86, 0.88))
	t.set_color("font_disabled_color", "Button", Color(0.50, 0.51, 0.54))
	return t


## 当前可见的弹窗面板列表（板选类无面板，不在此列）
func _visible_popup_panels() -> Array:
	var out: Array = []
	for p in [response_panel, weapon_picker_panel, damage_placement_panel, damage_adjust_panel, choice_panel, discard_select_panel, thrust_select_panel, immediate_set_equipment_panel, unite_attack_select_panel, awaken_select_panel, pilot_003_skip_panel, pilot_003_choose_top_panel, hidden_card_view_panel]:
		if p != null and is_instance_valid(p) and p.visible:
			out.append(p)
	return out


## 找出展示后新可见的弹窗面板（即本次 _show_popup 弹出的）
func _newly_visible_popup_panel(before: Array):
	for p in [response_panel, weapon_picker_panel, damage_placement_panel, damage_adjust_panel, choice_panel, discard_select_panel, thrust_select_panel, immediate_set_equipment_panel, unite_attack_select_panel, awaken_select_panel, pilot_003_skip_panel, pilot_003_choose_top_panel, hidden_card_view_panel]:
		if p != null and is_instance_valid(p) and p.visible and not (p in before):
			return p
	return null


func _clear_popup_stack() -> void:
	_popup_suppress_vis = true
	_popup_stack.clear()
	_damage_suspend_stack.clear()
	if _popup_scrim != null and is_instance_valid(_popup_scrim):
		_popup_scrim.visible = false
	_popup_suppress_vis = false


## 实际显示弹窗（锁步下仅本方 owner 弹窗走到此,对方弹窗已在 _on_action_ui_popup_requested 拦截）
func _show_popup(popup_type: StringName, params: Dictionary) -> void:
	match popup_type:
		&"weapon_select":
			if weapon_picker_panel and battle and battle.context:
				var attacker_id: StringName = params.get("attacker_id", &"")
				var gs = battle.context.game_state
				var attacker_mech = gs.mechs.get(attacker_id)
				if attacker_mech:
					# 含虚拟武器（神莺躯干，攻击需 power>0）；只列范围内有可攻击目标的武器
					# （范围内无目标的武器不出现，复用攻击牌预检查逻辑）。
					# 冷却中/锁定中的武器不出现（effect_125/104，"不会出现在攻击时的选框"）。
					var all_weapons: Array[StringName] = _get_all_usable_weapon_ids(attacker_mech, true)
					var weapon_ids: Array[StringName] = []
					for wid in all_weapons:
						var w_card = gs.cards.get(wid) if gs else null
						if w_card != null and not String(wid).begins_with("frame_base_weapon") and _weapon_attack_blocked(gs, w_card):
							continue
						if _weapon_has_attackable_target(attacker_mech, wid):
							weapon_ids.append(wid)
					weapon_picker_panel.configure(battle.context, weapon_ids, "── 选择武器 ──", attacker_mech)
					weapon_picker_panel.visible = true
		&"attack_target_select":
			if battle_board and battle and battle.context:
				var attacker_id: StringName = params.get("attacker_id", &"")
				var gs = battle.context.game_state
				var attacker_mech = gs.mechs.get(attacker_id) if gs else null
				var from_pos: Dictionary = params.get("from_position", {})
				if from_pos.is_empty() and attacker_mech != null:
					from_pos = attacker_mech.position
				# pilot_006 里昂狩猎豁免：只能选标记机甲（约束目标选择）
				_pilot_006_forced_target = params.get("pilot_006_forced_target", &"")
				# pilot_019 缴械冲击：hex 距离4内的其他机甲（技能范围圆，非武器BFS可达）。
				# 红闪仅范围内其他机甲（排除自己/陷阱）；target_count=2 进入多选。
				if String(params.get("target_kind", &"")) == &"pilot_019":
					_pilot_006_forced_target = &""
					var highlights: Array[Dictionary] = []
					if not from_pos.is_empty() and gs and gs.map_state:
						highlights = _RangeCalculator.get_skill_range_hexes(from_pos, int(params.get("weapon_range", 4)), gs.map_state.cells)
					battle_board.highlight_hexes(highlights)
					var target_hexes: Array[Dictionary] = []
					for hx: Dictionary in highlights:
						var mid: StringName = _find_mech_at_hex(hx)
						if mid != &"" and mid != attacker_id:
							target_hexes.append(hx)
					battle_board.highlight_attack_targets(target_hexes)
					_show_cancel_button(true)
					_multi_attack_target_count = 2
					_multi_attack_target_chosen = []
					battle_board.clear_multi_target_marks()
					battle.log.append({"message": "缴械冲击：点击红色闪烁格内的机甲选择目标（最多2台，可点已选机甲取消）；点「取消」=用已选目标继续", "details": {}})
					return
				var _attack_aura: Dictionary = battle.context.map_service.get_attack_aura_cells()
				# 机甲格为攻击路径障碍（可作终点不可穿过），与 _step_select_target 校验一致
				var _attack_blocked: Dictionary = battle.context.map_service.get_attack_blocked_keys(attacker_id)
				var highlights: Array[Dictionary] = _RangeCalculator.get_weapon_reachable_hexes(
					from_pos, params.get("weapon_range", 1), gs.map_state.cells if gs else {}, _attack_aura, _attack_blocked
				)
				# 绿色：武器可达的全部格子（范围标识）
				battle_board.highlight_hexes(highlights)
				# 红色闪烁：其中有机甲的格子（可攻击格子，不区分敌我）+ 陷阱标记格（可攻击目标，攻击即引爆）
				# 陷落等"不能被选为目标"的机甲格不作为可攻击目标（如同消失）
				var target_hexes: Array[Dictionary] = []
				for hx: Dictionary in highlights:
					var hx_mid: StringName = _find_mech_at_hex(hx)
					if hx_mid != &"":
						var hx_mech = gs.mechs.get(hx_mid) if gs else null
						if hx_mech != null and hx_mech.has_status(&"cannot_be_targeted"):
							continue
						target_hexes.append(hx)
					else:
						for m in gs.map_state.get_markers_at(int(hx.get("q", 0)), int(hx.get("r", 0))):
							if m.get("type", &"") == &"TRAP":
								target_hexes.append(hx)
								break
				battle_board.highlight_attack_targets(target_hexes)
				_show_cancel_button(true)
				# 多目标攻击（双连等）：target_count>=2 进入多选模式
				_multi_attack_target_count = int(params.get("target_count", 1))
				_multi_attack_target_chosen = []
				battle_board.clear_multi_target_marks()
				if _multi_attack_target_count >= 2:
					battle.log.append({"message": "多目标攻击：点击红色闪烁格内的机甲选择目标（最多%d台，可点已选机甲取消选择）；选陷阱=单目标；点「取消」=用已选目标继续" % _multi_attack_target_count, "details": {}})
				else:
					battle.log.append({"message": "选择攻击目标：点击红色闪烁格内的机甲或陷阱（绿色为武器范围）", "details": {}})
		&"mech_multi_select":
			# 通用多选机甲（CHOOSE_MANY_MECHS，奥黛尔 pilot_038「选最多2台4格内机甲含我方」）。
			# 高亮技能范围圆；红闪范围内存活机甲（include_self=true 含自己；无陷阱目标）。
			if battle_board and battle and battle.context:
				var mm_source_id: StringName = params.get("source_mech_id", &"")
				var mm_gs = battle.context.game_state
				var mm_src = mm_gs.mechs.get(mm_source_id) if mm_gs else null
				var mm_from: Dictionary = params.get("from_position", {})
				if mm_from.is_empty() and mm_src != null:
					mm_from = mm_src.position
				var mm_range: int = int(params.get("range", 4))
				var mm_max: int = int(params.get("max_count", 1))
				var mm_min: int = int(params.get("min_count", 1))
				var mm_include_self: bool = bool(params.get("include_self", false))
				var mm_highlights: Array[Dictionary] = []
				if not mm_from.is_empty() and mm_gs and mm_gs.map_state:
					# include_self=true 时范围圆含 origin 自身格（奥黛尔 pilot_038 可选中自己）
					mm_highlights = _RangeCalculator.get_skill_range_hexes(mm_from, mm_range, mm_gs.map_state.cells, mm_include_self)
				battle_board.highlight_hexes(mm_highlights)
				var mm_target_hexes: Array[Dictionary] = []
				for hx: Dictionary in mm_highlights:
					var mm_mid: StringName = _find_mech_at_hex(hx)
					if mm_mid == &"":
						continue
					if mm_mid == mm_source_id and not mm_include_self:
						continue
					var mm_m = mm_gs.mechs.get(mm_mid) if mm_gs else null
					if mm_m == null or mm_m.destroyed:
						continue
					mm_target_hexes.append(hx)
				battle_board.highlight_attack_targets(mm_target_hexes)
				_show_cancel_button(true)
				_mech_multi_select_opts = {
					"source_mech_id": mm_source_id, "min_count": mm_min, "max_count": mm_max,
					"include_self": mm_include_self, "label": String(params.get("label", "选择目标机甲")),
					"hexes": mm_highlights,
					"action_id": params.get("action_id", &""),
				}
				_multi_attack_target_count = mm_max
				_multi_attack_target_chosen = []
				battle_board.clear_multi_target_marks()
				battle.log.append({"message": "%s：点击红色闪烁格内的机甲选择目标（最多%d台，可点已选机甲取消选择）；点「取消」=用已选目标继续" % [String(params.get("label", "选择目标机甲")), mm_max], "details": {}})
		&"map_cell_select":
			# 通用选格（机雷设陷 / 格雷厄姆 pilot_057 移陷等）：标绿 valid_cells 格，点击选择；
			# count>1（双子机雷）：逐格点击，已选格从高亮移除（不可再选），选满 count 格后提交。
			# no_cancel=true：弃牌已付出的后续阶段，隐藏取消按钮（必须选格）。
			if battle_board:
				_map_cell_select_valid = params.get("valid_cells", []).duplicate(true)
				_map_cell_select_chosen = []
				_map_cell_select_count = int(params.get("count", 1))
				# 捕获挂起动作 id：确认/取消改走 resume_effect 精确路由（见变量声明处注释）
				_map_cell_select_action_id = StringName(String(params.get("action_id", &"")))
				_refresh_map_cell_highlight()
				_show_cancel_button(not bool(params.get("no_cancel", false)))
				battle.log.append({"message": "选择格子：点击绿色格确认（%s）" % String(params.get("label", "")), "details": {}})
		&"move_target_select":
			if battle_board:
				# single_move 动作的 input_params 用 current_position（机甲当前位置）与
				# available_power（本次循环剩余动力）。
				var from_pos: Dictionary = params.get("current_position", params.get("from_position", {}))
				var move_power: int = int(params.get("available_power", params.get("power", 1)))
				var mv_mech_id: StringName = params.get("mech_id", &"")
				if from_pos.is_empty():
					# 退路：从 mech_id 取当前位置
					if mv_mech_id != &"" and battle.context and battle.context.game_state:
						var mv_mech = battle.context.game_state.mechs.get(mv_mech_id)
						if mv_mech != null:
							from_pos = mv_mech.position
							if move_power <= 0:
								move_power = mv_mech.power
				# 迎击移动高亮：标红闪烁"攻击方能攻击到的所有格子"，让被攻击方知道往哪跑能脱离攻击范围。
				# （原实现标绿"自己可移动的格子"，但视觉混乱且不直观——看不到威胁范围。）
				# 攻击方在迎击移动期间不动，范围固定，缓存避免每次移动循环重算 BFS。
				# 先刷新：移动后机甲位置需同步到 battle_board.units（select_move_target 点格子路径
				# 本身不调 _refresh_battle，否则机甲视觉位置不更新，表现为"点了没动/卡顿"）。
				_refresh_battle()
				var attacker_range_hexes: Array[Dictionary] = _get_evade_attacker_range_hexes(mv_mech_id)
				battle_board.clear_highlight()
				# 玩家可移动的可达格（绿）：剩余动力 BFS。玩家必须有点得亮的格子才能操作，
				# 否则只看到红色威胁范围时容易"不知道点哪"，放弃操作导致 AI 攻击永远停在
				# waiting_sub_action、敌方回合无法结束。
				var reachable_move: Array[Dictionary] = []
				if not from_pos.is_empty() and battle.context and battle.context.game_state:
					var gs_mv = battle.context.game_state
					var cells_mv: Dictionary = gs_mv.map_state.cells if gs_mv.map_state else {}
					var _mc_mv: Dictionary = battle.context.map_service.resolve_move_cost_params(local_player_id)
					reachable_move = _RangeCalculator.get_move_reachable_hexes(from_pos, move_power, cells_mv, int(_mc_mv["green_cost"]), _mc_mv["aura_cells"])
				battle_board.highlight_hexes(reachable_move)
				battle_board.highlight_attack_targets(attacker_range_hexes)
				# 回避/疾行/反击的循环移动：显示取消按钮供玩家"停止移动"（取消 single_move 即结束循环，
				# 父 use_action_card 与原攻击动作随后正常恢复结算）。
				_show_cancel_button(true)
				battle.log.append({"message": "迎击移动：绿格=可移动（剩余动力 %d），红闪=攻击方范围（移出可脱险）；点绿格移动或点取消结束" % move_power, "details": {}})
		&"response_window":
			if response_panel:
				# client 无 TimingEngine 数据，用 host 转发来的 available_cards 显示
				response_panel.configure_with_cards(battle, params.get("action_id", &""), params.get("available_cards", []))
				response_panel.visible = true
		&"discard_card_select":
			# 弃牌/偷牌选择弹窗。三种模式（通用协议，调用方按需传 count/max_count/min_count/face_up/
			# no_cancel/action_verb/source_label/executor/mode）：
			#   ① mode=need_input（STEAL/discard_card 动作 need_input）：动作挂在 waiting_input，
			#      玩家选牌后调 ActionUIBridge.on_ui_confirmed({"determined_card_ids":...}) 让 ActionEngine 重跑 step。
			#   ② mode=resume_pending（机师效果等挂起的效果弃牌：苔丝弃攻击方牌/肯耳忒逐目标弃牌）：
			#      玩家选牌/取消后由 _on_discard_selection_completed/_cancelled 调 resume_pending_effect
			#      回填 selected_action_card_ids / cancelled。
			#   ③ 其余（optional 闪击弃牌）：TimingEngine._request_optional_discard 挂起的效果，同 resume 回填。
			if discard_select_panel and battle and battle.context:
				var ds_player_id: StringName = params.get("discard_player_id", params.get("player_id", &""))
				# count 显式优先，未传则回退 max_count（恰好选 N 张的效果常只传 max_count/min_count）
				var ds_count: int = int(params.get("count", params.get("max_count", 1)))
				var ds_face_up: bool = bool(params.get("face_up", true))
				var ds_verb: StringName = params.get("action_verb", &"discard")
				var ds_no_cancel: bool = bool(params.get("no_cancel", false))
				var ds_exclude: Array = params.get("exclude_card_ids", [])
				# pilot_021 塔莉娅赐予：至少选 min_count 张、自定义标题、只列 allowed_card_ids（剩余禁牌）
				var ds_min_count: int = int(params.get("min_count", 0))
				var ds_title_override: String = String(params.get("title_override", ""))
				var ds_allowed: Array = params.get("allowed_card_ids", [])
				var ds_source: String = String(params.get("source_label", ""))
				_discard_select_card_id = &""  # 不走辅助牌同步路径
				var ds_mode: StringName = String(params.get("mode", &""))
				if ds_mode == &"turn_end_flow":
					# 回合结束弃超限牌阻塞窗（end_turn 第5步）：仅弃牌玩家本机弹
					# （PvP 其他端不弹，等待 resume_turn_discard op 同步状态）。
					if String(ds_player_id) != String(local_player_id):
						return
					_discard_select_pending = {
						"mode": &"turn_end_flow",
						"action_id": params.get("action_id", &""),
						"discard_player_id": ds_player_id,
						"count": ds_count,
						"face_up": ds_face_up,
					}
					discard_select_panel.configure(battle.context, ds_player_id, ds_count, ds_face_up, &"", ds_verb, ds_source, true, ds_exclude, ds_count, ds_title_override, ds_allowed)
					discard_select_panel.visible = true
					battle.log.append({"message": "回合结束：选择弃置 %d 张超限行动牌" % ds_count, "details": {}})
				elif ds_mode == &"need_input":
					# STEAL/discard_card 动作 need_input 路径
					_discard_select_pending = {
						"mode": &"need_input",
						"action_id": params.get("action_id", &""),
						"discard_player_id": ds_player_id,
						"count": ds_count,
						"face_up": ds_face_up,
					}
					discard_select_panel.configure(battle.context, ds_player_id, ds_count, ds_face_up, &"", ds_verb, ds_source, ds_no_cancel, ds_exclude, ds_min_count, ds_title_override, ds_allowed)
					discard_select_panel.visible = true
					battle.log.append({"message": "选择1张行动牌%s" % ("获取" if ds_verb == &"gain" else "弃置"), "details": {}})
				elif ds_mode == &"resume_pending":
					# 效果挂起弃牌：弹窗按 executor（操作者=效果持有者）路由（_popup_owner 优先 executor），
					# confirm/cancel 回填 resume_pending_effect 的对应 phase。
					_discard_select_pending = {
						"mode": &"resume_pending",
						"action_id": params.get("action_id", &""),
						"discard_player_id": ds_player_id,
						"count": ds_count,
						"face_up": ds_face_up,
					}
					discard_select_panel.configure(battle.context, ds_player_id, ds_count, ds_face_up, &"", ds_verb, ds_source, ds_no_cancel, ds_exclude, ds_min_count, ds_title_override, ds_allowed)
					discard_select_panel.visible = true
					battle.log.append({"message": "选择%s %d 张行动牌" % ["获取" if ds_verb == &"gain" else "弃置", ds_count], "details": {}})
				else:
					# 闪击 optional 弃牌
					_discard_select_pending = {
						"optional": true,
						"action_id": params.get("action_id", &""),
						"discard_player_id": ds_player_id,
						"count": ds_count,
						"face_up": ds_face_up,
					}
					discard_select_panel.configure(battle.context, ds_player_id, ds_count, ds_face_up, &"", ds_verb, ds_source, ds_no_cancel, ds_exclude, ds_min_count, ds_title_override, ds_allowed)
					discard_select_panel.visible = true
					battle.log.append({"message": "闪击：弃1张行动牌可再攻1次，或取消", "details": {}})
				_request_refresh()
		&"damage_token_placement":
			if damage_placement_panel:
				# 若损伤面板已在显示（攻击损伤放置中途被效果移除损伤打断），先挂起当前面板
				# 状态+动作ID+目标机甲，待移除完成后恢复续操作（两个 damage_change 交错复用单面板）
				if damage_placement_panel.visible:
					_damage_suspend_stack.append({
						"state": damage_placement_panel.suspend_state(),
						"action_id": _damage_placement_action_id,
						"target_mech_id": _damage_placement_target_mech_id,
					})
				# damage_change 动作的 input_params 用 mech_ids(数组)；兼容旧 target_mech_id
				var target_mech_id: StringName = params.get("target_mech_id", &"")
				if target_mech_id == &"":
					var mech_ids: Array = params.get("mech_ids", [])
					if not mech_ids.is_empty():
						target_mech_id = mech_ids[0]
				_damage_placement_target_mech_id = target_mech_id
				# 记录本面板对应的 damage_change 动作 ID：完成时直接恢复该动作，避免被并发的装备
				# 离场效果弹窗覆盖 ActionUIBridge 单一等待动作槽（否则攻击牌会卡在临时区）。
				if battle.context.action_ui_bridge:
					_damage_placement_action_id = battle.context.action_ui_bridge.get_waiting_action_info().get("action_id", &"")
				var dp_amount: int = params.get("amount", 0)
				if bool(params.get("removal_mode", false)):
					# 维修/装备离场移除损伤：弹 removal 模式损伤框，逐一选槽位减少损伤
					# exclude_slot_id：排除指定槽（effect_079 移除"其他区域"损伤，排除来源槽）
					var dp_exclude: StringName = StringName(params.get("exclude_slot_id", &""))
					# 来源标签：优先取 input_params.source_label（薇尔 pilot_059 等效果自带），
					# 否则沿父链找 discard_card 取被弃装备牌名（effect_031/079 离场移除损伤）
					var dp_source: String = String(params.get("source_label", ""))
					if dp_source == "" and _damage_placement_action_id != &"" and battle.context.timing_engine:
						dp_source = battle.context.timing_engine.get_removal_source_label(_damage_placement_action_id)
					# allow_cancel/max_mode：最多移除场景显示「完成/取消」按钮（可提前结束/取消）
					var dp_allow_cancel: bool = bool(params.get("allow_cancel", false))
					var dp_max_mode: bool = bool(params.get("max_mode", false))
					damage_placement_panel.configure_removal(battle.context, target_mech_id, dp_amount, dp_exclude, dp_source, dp_allow_cancel, dp_max_mode)
				else:
					damage_placement_panel.configure(battle.context, target_mech_id, dp_amount)
				damage_placement_panel.visible = true
		&"damage_adjust":
			# 损伤调整面板（薇尔 pilot_059 回合开始）：让玩家选每槽位 +1/-1 或取消，仅1次机会。
			# 记录效果挂起动作 ID，确认/取消时 _net_exec("resume_effect") 双端续跑。
			if damage_adjust_panel and battle and battle.context:
				var adj_mech: StringName = StringName(params.get("mech_id", &""))
				var adj_label: String = String(params.get("source_label", ""))
				_damage_adjust_action_id = StringName(params.get("action_id", &""))
				damage_adjust_panel.configure(battle.context, adj_mech, adj_label)
				damage_adjust_panel.visible = true
		&"use_card_confirm":
			if choice_panel:
				var options: Array[Dictionary] = [
					{"label": "确定使用", "effect_id": &"__confirm_use__"},
					{"label": "取消", "effect_id": &"__cancel_use__"},
				]
				choice_panel.configure(options)
				choice_panel.visible = true
		&"weapon_charge_select":
			if weapon_picker_panel and battle and battle.context:
				var wc_mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
				var wc_mech = battle.context.game_state.mechs.get(wc_mech_id)
				if wc_mech:
					# 聚能弹窗包括我方所有武器（含虚拟武器神莺躯干）；聚能不是攻击，不要求 power>0、不过滤目标。
					# 冷却中/锁定中的武器仍可选（对此类武器聚能可解除不能攻击状态，effect_126/104）。
					var weapon_ids: Array[StringName] = _get_all_usable_weapon_ids(wc_mech, false)
					weapon_picker_panel.configure(battle.context, weapon_ids, "── 选择要聚能的武器 ──", wc_mech, true)
					weapon_picker_panel.visible = true
					_show_cancel_button(true)
					battle.log.append({"message": "聚能：选择1把武器施加聚能状态（或点取消放弃）", "details": {}})
		&"repair_target_select":
			if battle_board and battle and battle.context:
				var highlights: Array[Dictionary] = []
				# bridge emit 的 input_params 用 mech_id（非 from_mech_id）；此处取源机甲高亮自身+范围内机甲
				# （默认1格；机师牌 repair_boost 坎得等 range=4）。
				var rp_mech_id: StringName = params.get("mech_id", params.get("source_mech_id", params.get("from_mech_id", &"")))
				var rp_mech = battle.context.game_state.mechs.get(rp_mech_id)
				if rp_mech:
					var rp_range: int = _ActionPilotEffects.get_repair_range(battle.context.game_state, rp_mech_id)
					for mid: StringName in battle.context.game_state.mechs:
						var m = battle.context.game_state.mechs[mid]
						if m == null or m.destroyed:
							continue
						if _HexGrid.distance(m.position, rp_mech.position) <= rp_range:
							if _mech_can_be_repaired(m):
								highlights.append(m.position)
				battle_board.highlight_hexes(highlights)
				_show_cancel_button(true)
				battle.log.append({"message": "维修：点击自身或范围内的机甲选择目标（或点取消放弃）", "details": {}})
		&"effect_choice":
			if choice_panel:
				var options: Array = params.get("options", [])
				var typed_options: Array[Dictionary] = []
				for opt in options:
					if opt is Dictionary:
						typed_options.append(opt)
				# 捕获挂起动作 id + 选项（TimingEngine CHOOSE_ONE emit 必带 action_id），
				# 确认/取消走 resume_effect 精确路由：并发挂起（伤害转移+损伤放置）共享槽被
				# 覆盖时不再丢输入（bug1）。无 action_id（异常）回退共享槽路径。
				_effect_choice_action_id = StringName(params.get("action_id", &""))
				_effect_choice_options = options
				# 里昂效果2（战后逼迫 pilot_006_effect_03）为强制二选一，隐藏底部取消按钮（不可取消）。
				# 其他 effect_choice（维修二选一/是否继续发动等）保留底部取消按钮。
				var ec_effect_id: StringName = StringName(params.get("effect_id", &""))
				var ec_allow_cancel: bool = (ec_effect_id != &"pilot_006_effect_03")
				choice_panel.configure(typed_options, String(params.get("source_label", "")), ec_allow_cancel)
				choice_panel.visible = true
		&"integer_select":
			# CHOOSE_INTEGER：stepper=true 步进面板（pilot_004 装甲转能）/ 否则按钮列表（effect_040/041 金币换动力）
			if bool(params.get("stepper", false)) and stepper_panel:
				stepper_panel.configure(
					String(params.get("label", "选择n")),
					int(params.get("min_value", 0)),
					int(params.get("max_value", 0)),
					bool(params.get("optional", false)),
					int(params.get("step", 3)))
				stepper_panel.visible = true
			elif choice_panel:
				var ii_min: int = int(params.get("min_value", 1))
				var ii_max: int = int(params.get("max_value", ii_min))
				var ii_label: String = String(params.get("label", "选择n"))
				var ii_options: Array[Dictionary] = []
				for n_ii in range(ii_min, ii_max + 1):
					ii_options.append({"label": "%s（n=%d）" % [ii_label, n_ii], "effect_id": StringName("__int_%d__" % n_ii)})
				if bool(params.get("optional", false)):
					ii_options.append({"label": "取消", "effect_id": &"__cancel_int__"})
				choice_panel.configure(ii_options, String(params.get("source_label", "")))
				choice_panel.visible = true
				battle.log.append({"message": ii_label, "details": {}})
		&"mech_target_select":
			if battle_board:
				var highlights: Array[Dictionary] = []
				# pilot_021 塔莉娅：优先用 valid_mech_ids（4格内候选）高亮
				var _mt_valid: Array = params.get("valid_mech_ids", [])
				if not _mt_valid.is_empty():
					for mid: StringName in _mt_valid:
						var m = battle.context.game_state.mechs.get(mid)
						if m == null or m.destroyed:
							continue
						highlights.append(m.position)
				else:
					# 排除来源机甲自身（CHOOSE_OTHER_MECH 不能选自己；pilot_002 转化选 B）
					var _mt_src_mid: StringName = params.get("mech_id", &"")
					for mid: StringName in battle.context.game_state.mechs:
						if mid == _mt_src_mid:
							continue
						var m = battle.context.game_state.mechs[mid]
						if m == null or m.destroyed:
							continue
						highlights.append(m.position)
				battle_board.highlight_hexes(highlights)
				# 通用取消：地图选机甲类弹窗（塔莉娅赐予/维罗妮卡给金等）显示底部「取消」按钮。
				# 点取消走 ui_cancelled -> resume_pending_effect(cancelled)，由各阶段 handler 决定语义
				# （塔莉娅=结束循环；维罗妮卡=取消该阶段）。无候选时提示防止"点了没反应"。
				_show_cancel_button(true)
				var _mt_label: String = String(params.get("source_label", params.get("label", "选择目标机甲")))
				if highlights.is_empty():
					battle.log.append({"message": "无候选目标机甲，点「取消」结束选择", "details": {}})
				else:
					battle.log.append({"message": "%s（%d台可选中）；点「取消」结束选择" % [_mt_label, highlights.size()], "details": {}})
		&"redirect_select":
			# 损伤转移汇总（A6 装备效果）：用 choice_panel 让玩家选转移点数档位
			if choice_panel:
				var total: int = int(params.get("total_points", 0))
				var max_pts: int = int(params.get("max_points", -1))
				var redir_mech_id: StringName = params.get("redirect_mech_id", &"")
				# 转移目标=本牌所在 slot（TimingEngine 从 binding_context.slot_id 传入，如 effect_004 联邦右臂=右臂）。
				# 兜底：未传时遍历机甲第一个有装备的槽位（旧逻辑，保兼容）。
				var to_slot: StringName = StringName(params.get("redirect_slot_id", &""))
				if to_slot == &"" and redir_mech_id != &"" and battle.context.game_state != null:
					var redir_mech = battle.context.game_state.mechs.get(redir_mech_id)
					if redir_mech != null:
						for sid in redir_mech.slots:
							var slot = redir_mech.slots[sid]
							if slot != null and slot.equipped_card != null:
								to_slot = StringName(String(sid))
								break
				if bool(params.get("all_or_nothing", false)):
					# 盾牌（effect_127/133/136）：全部转移(减伤后) / 不转移，二选一。
					# 转移=transfer 点到本牌槽+减伤 absorb 点消失；不转移=损伤回原目标正常放置。
					var ao_transfer: int = int(params.get("transfer", 0))
					var ao_src: String = String(params.get("source_label", "转移全部损伤至此牌"))
					var ao_options: Array[Dictionary] = []
					ao_options.append({"label": "不转移", "effect_id": &"__redirect_cancel__"})
					ao_options.append({"label": ao_src, "effect_id": &"__redirect_confirm__"})
					choice_panel.configure(ao_options, "盾牌损伤转移")
					choice_panel.visible = true
					_redirect_context = {"mech_id": redir_mech_id, "to_slot": to_slot, "action_id": params.get("action_id", &""), "all_or_nothing": true, "transfer": ao_transfer}
				else:
					# 计算可转移上限
					var cap: int = total
					if max_pts > 0:
						cap = mini(cap, max_pts)
					# 构造档位选项：0(不转移)/1/2/.../cap
					var options: Array[Dictionary] = []
					options.append({"label": "不转移", "effect_id": &"__redirect_0__", "count": 0})
					for n in range(1, cap + 1):
						options.append({"label": "转移 %d 点损伤至此牌区域" % n, "effect_id": StringName("__redirect_%d__" % n), "count": n})
					choice_panel.configure(options, String(params.get("source_label", "")))
					choice_panel.visible = true
					# 记录转移上下文，供 _on_choice_selected 读取
					_redirect_context = {"mech_id": redir_mech_id, "to_slot": to_slot, "action_id": params.get("action_id", &"")}
		&"thrust_select":
			# 推进 effect2 多选 / 乌尔效果2 需交牌：列出候选行动牌供多选，确认后一起打出/交出。
			# min_count>0 时（乌尔需交牌）不足张数确认按钮禁用。
			if thrust_select_panel and battle and battle.context:
				var ts_card_ids: Array = params.get("card_ids", [])
				var ts_label: String = params.get("label", "选择要一起打出的牌")
				_thrust_select_action_id = params.get("action_id", &"")
				thrust_select_panel.configure(battle.context, ts_card_ids, ts_label, params.get("per_card_suffix", ""), params.get("confirm_verb", "打出"), params.get("cancel_label", "不打出"), int(params.get("max_count", 0)), int(params.get("min_count", 0)), bool(params.get("no_cancel", false)), bool(params.get("hide_card_info", false)), params.get("extra_options", []))
				thrust_select_panel.visible = true
		&"immediate_set_equipment":
			# effect_005 立即设置装备 / effect_065 抽装备立即设置或卖出：列出抽到的牌与合法空槽
			if immediate_set_equipment_panel and battle and battle.context:
				var ise_drawn_id: StringName = params.get("drawn_card_id", &"")
				var ise_slots: Array = params.get("valid_slots", [])
				var ise_mech_id: StringName = params.get("mech_id", &"")
				_immediate_set_action_id = params.get("action_id", &"")
				var ise_allow_sell: bool = bool(params.get("allow_sell", false))
				var ise_sell_price: int = int(params.get("sell_price", 0))
				immediate_set_equipment_panel.configure(battle.context, ise_drawn_id, ise_slots, ise_mech_id, ise_allow_sell, ise_sell_price, String(params.get("source_label", "")))
				immediate_set_equipment_panel.visible = true
		&"pilot_014_target_select":
			# pilot_014 亚伦：列出场上所有机师牌（机师名+归属+当前行动牌上限），选1张使其行动牌上限+2。
			# options 每项 {label, effect_id=pilot_instance, pilot_instance, player_id, mech_id}；复用 choice_panel。
			if choice_panel and battle and battle.context:
				var p014_options: Array = params.get("options", [])
				var p014_typed: Array[Dictionary] = []
				for opt in p014_options:
					if opt is Dictionary:
						p014_typed.append(opt)
				_pilot_014_select_options = p014_typed
				var p014_optional: bool = bool(params.get("optional", true))
				choice_panel.configure(p014_typed, String(params.get("source_label", "选择1张机师牌使其行动牌上限+2")), p014_optional)
				choice_panel.visible = true
		&"pilot_032_target_select":
			# pilot_032 爱瑞娅：列出场上所有机师牌（机师名+归属+当前行动牌上限），选1张使其行动牌上限+2。
			# options 每项 {label, effect_id=pilot_instance, pilot_instance, player_id, mech_id}；复用 choice_panel。
			if choice_panel and battle and battle.context:
				var p032_options: Array = params.get("options", [])
				var p032_typed: Array[Dictionary] = []
				for opt in p032_options:
					if opt is Dictionary:
						p032_typed.append(opt)
				_pilot_032_select_options = p032_typed
				var p032_optional: bool = bool(params.get("optional", true))
				choice_panel.configure(p032_typed, String(params.get("source_label", "选择1张机师牌使其行动牌上限+2")), p032_optional)
				choice_panel.visible = true
		&"unite_attack_select":
			# 联合状态效果1：unite机甲攻击结算后，Target 选1张攻击牌联合攻击。
			# 弹窗已由 _popup_owner 路由到 Target 玩家窗口（PvP 对方弹窗本端不显示）。
			# no_cancel=true（里欧娜 pilot_047 战后威逼）：隐藏取消按钮强制必选。
			if unite_attack_select_panel and battle and battle.context:
				var ua_card_ids: Array = params.get("card_ids", [])
				var ua_label: String = params.get("label", "联合攻击：选择1张攻击牌使用")
				var ua_no_cancel: bool = bool(params.get("no_cancel", false))
				_unite_attack_action_id = params.get("action_id", &"")
				unite_attack_select_panel.configure(battle.context, ua_card_ids, ua_label, "[攻击牌]", "确认使用", "取消（不联合攻击）", [], "", false, ua_no_cancel)
				unite_attack_select_panel.visible = true
				battle.log.append({"message": "联合攻击：选择1张攻击牌使用或取消", "details": {}})
		&"pilot_018_equipment_select":
			# pilot_018 苔丝 effect_01b：选1张损伤≥2装备牌弃置（攻击方装备牌，明牌列出）。
			# candidates 每项 {card_id, slot_id, name, kind, damage, durability}；复用 choice_panel。
			# 选项 effect_id=装备牌 instance_id；confirm 后 _on_choice_made 走 resume_pending_effect。
			if choice_panel and battle and battle.context:
				var p018_cands: Array = params.get("candidates", [])
				var p018_opts: Array[Dictionary] = []
				for c in p018_cands:
					if c is Dictionary:
						var _cname: String = String(c.get("name", ""))
						var _ckind: String = String(c.get("kind", ""))
						var _cdmg: int = int(c.get("damage", 0))
						var _cdur: int = int(c.get("durability", 0))
						var _kind_label: String = "武器" if _ckind == &"WEAPON" else ("部件" if _ckind == &"PART" else _ckind)
						p018_opts.append({
							"label": "%s [%s] 损伤%d/耐久%d" % [_cname, _kind_label, _cdmg, _cdur],
							"effect_id": c.get("card_id", &""),
						})
				_pilot_018_select_options = p018_opts
				choice_panel.configure(p018_opts, String(params.get("label", "苔丝：选择弃置攻击方的1张损伤≥2装备牌")), false)
				choice_panel.visible = true
		&"pilot_025_reserve_select":
			# pilot_025 约书亚 1b：选1张备用区装备牌设置到区域。options 每项 {label, effect_id=card_id}；复用 choice_panel。
			if choice_panel and battle and battle.context:
				var p025_rv_opts: Array = params.get("options", [])
				var p025_rv_typed: Array[Dictionary] = []
				for o in p025_rv_opts:
					if o is Dictionary:
						p025_rv_typed.append(o)
				choice_panel.configure(p025_rv_typed, String(params.get("label", "约书亚：选择1张备用区装备牌设置到区域")), true)
				choice_panel.visible = true
		&"hidden_card_view_select":
			# 通用「查看隐藏装备」Phase A（霍恩 pilot_046 等 HIDDEN_VIEW_AND_ACQUIRE）：
			# 打开 hidden_card_view_panel 列出候选（商店隐藏牌 + 其他机甲备用区白板），
			# 可关闭=取消效果（查看无条件，可反复再点）；打开面板即给商店隐藏牌标记已知（每玩家）。
			if hidden_card_view_panel and battle and battle.context:
				var hcv_action_id: StringName = params.get("action_id", &"")
				_hidden_view_action_id = hcv_action_id
				var hcv_pid: StringName = params.get("player_id", &"")
				var hcv_candidates: Array = params.get("candidates", [])
				var hcv_typed: Array[Dictionary] = []
				for c in hcv_candidates:
					if c is Dictionary:
						hcv_typed.append(c)
				var hcv_player = battle.context.game_state.players.get(hcv_pid) if battle.context.game_state != null else null
				var hcv_gold: int = hcv_player.gold if hcv_player != null else 0
				# 获取每回合1次是否已用满 → 「花费获取」置灰（查看无条件，仅获取限次）。
				# source_card_instance_id 由 TimingEngine 透传（binding_context.card_instance_id）。
				var hcv_acquire_used: bool = false
				if battle.context.timing_engine != null:
					var hcv_key: StringName = params.get("once_per_turn_key", &"")
					var hcv_src_cid: StringName = params.get("source_card_instance_id", &"")
					hcv_acquire_used = hcv_key != &"" and hcv_src_cid != &"" and not battle.context.timing_engine.is_once_per_turn_key_available(hcv_key, hcv_src_cid, 1)
				hidden_card_view_panel.configure(hcv_typed, hcv_gold, hcv_acquire_used)
				hidden_card_view_panel.visible = true
				battle.log.append({"message": "查看隐藏装备：选择1张牌花费金币获取，或点关闭", "details": {}})
		&"hidden_reserve_slot_select":
			# 通用「查看隐藏装备」Phase B：选目标 RESERVE 槽（全部机甲，含自己）。
			# options 每项 {label, effect_id="mech_id:slot_id"}；复用 choice_panel，强制选择不可取消。
			if choice_panel and battle and battle.context:
				var hrv_opts: Array = params.get("options", [])
				var hrv_typed: Array[Dictionary] = []
				for o in hrv_opts:
					if o is Dictionary:
						hrv_typed.append(o)
				choice_panel.configure(hrv_typed, String(params.get("label", "选择放置的备用区域（显示当前牌）")), false)
				choice_panel.visible = true
		&"pilot_003_skip_players":
			# pilot_003 e3 复选框：瑟尔基尔玩家勾选「抽牌跳过正面牌」的玩家（含自己），提交后生效。
			# 弹窗已由 _popup_owner 按 player_id 路由到瑟尔基尔玩家窗口。
			if pilot_003_skip_panel and battle and battle.context:
				_pilot_003_skip_action_id = params.get("action_id", &"")
				var p003s_players: Array = params.get("player_ids", [])
				var p003s_checked: Array = params.get("checked", [])
				pilot_003_skip_panel.configure(p003s_players, p003s_checked, String(params.get("source_label", "")))
				pilot_003_skip_panel.visible = true
				battle.log.append({"message": "跳过公开牌：勾选抽牌跳过正面牌的玩家并提交", "details": {}})
		&"pilot_003_choose_top":
			# pilot_003 e1 phase 链：选完埋牌后弹"选1张置顶(可取消)"窗。复用通用化 unite 单选面板，
			# card_suffix=空（非攻击牌后缀）、confirm_verb=置顶、cancel_label=不置顶。
			if pilot_003_choose_top_panel and battle and battle.context:
				_pilot_003_choose_top_action_id = params.get("action_id", &"")
				var p003t_card_ids: Array = params.get("card_ids", [])
				pilot_003_choose_top_panel.configure(battle.context, p003t_card_ids, String(params.get("label", "选择1张正面牌放置到牌堆顶（可取消）")), "", "置顶", "不置顶（仅随机插入）")
				pilot_003_choose_top_panel.visible = true
				battle.log.append({"message": "公开埋牌：选择1张正面牌放置到牌堆顶（可取消）", "details": {}})
		&"awaken_select":
			# 觉醒：弃牌堆无预判/识破时，选1种行动牌（列种类+数量）。
			# 弹窗已由 _popup_owner 路由到使用觉醒牌的玩家窗口（PvP 对方弹窗本端不显示）。
			if awaken_select_panel and battle and battle.context:
				var aw_options: Array = params.get("options", [])
				var aw_label: String = params.get("label", "觉醒：选择1种行动牌")
				var aw_hint: String = params.get("hint", "")
				_awaken_select_action_id = params.get("action_id", &"")
				awaken_select_panel.configure(battle.context, aw_options, aw_label, aw_hint)
				awaken_select_panel.visible = true
				battle.log.append({"message": "觉醒：选择1种行动牌（弃牌堆无预判/识破）", "details": {}})
		&"pilot_083_options":
			# 瓦恩武器修改 phase2：三横排互斥选项（名称附加/类型转变/数值加成，行内独立可留空）。
			# 弹窗已由 _popup_owner 按 player_id 路由到瓦恩持有者玩家窗口（PvP 对方弹窗本端不显示）。
			if weapon_modify_options_panel and battle and battle.context:
				_p083_options_action_id = params.get("action_id", &"")
				var p083_wname: String = String(params.get("weapon_name", ""))
				var p083_src: String = String(params.get("source_label", ""))
				weapon_modify_options_panel.configure(p083_wname, p083_src)
				weapon_modify_options_panel.visible = true
				battle.log.append({"message": "瓦恩-武器修改：选择名称/类型/数值加成（每行可留空）", "details": {}})
		_:
			battle.log.append({"message": "[新系统] 请求UI弹窗: %s" % String(popup_type), "details": params})

## 新动作系统：ActionUIBridge 输入已解决
func _on_action_input_resolved(action_id: StringName, input_data: Dictionary) -> void:
	# 输入已解决后，动作由 ActionUIBridge 内部继续执行
	battle.log.append({"message": "[新系统] 动作输入已解决: %s" % String(action_id), "details": {}})
	# 此信号在 _apply_action_input 里于 resume/continue（动作链）之前 emit，同步刷新会刷出链前旧状态、
	# 且与 ui_confirmed 处理器/动作完成的刷新重复（曾致每次选择 2~3 次全量 192 格重绘=卡顿）。
	# 改为延迟合并：动作链跑完后帧末仅刷新一次（_refresh_battle_coalesced 在有待弹窗时会跳过，
	# 由该弹窗关闭后再补），显著减少弹窗选择后的卡顿。
	_request_refresh()
	# 弹窗关闭后，若移动仍在 pacing（如 effect_017 选移动后继续逐格），重新启用遮罩
	_update_move_overlay()

## 敌方信息按钮点击
func _on_enemy_info_clicked() -> void:
	if enemy_info_popup and battle and battle.context:
		enemy_info_popup.configure(battle.context, local_player_id)
		enemy_info_popup.popup_centered(Vector2i(320, 520))

## 机甲详情按钮点击（来自装备面板）：打开该机甲的动力/护甲来源明细+状态弹窗
func _on_mech_detail_requested(mech) -> void:
	if mech_detail_panel and battle and battle.context:
		mech_detail_panel.configure(mech, battle.context)
		mech_detail_panel.popup_centered(Vector2i(460, 640))

## 机甲状态面板按钮点击：集中显示所有机甲的联合/锁定等状态
func _on_status_panel_clicked() -> void:
	if status_panel and battle and battle.context:
		status_panel.configure(battle.context)
		status_panel.popup_centered(Vector2i(420, 520))

## 牌堆信息按钮点击
func _on_deck_info_clicked() -> void:
	if deck_info_popup and battle and battle.context:
		deck_info_popup.configure(battle.context)
		deck_info_popup.popup_centered(Vector2i(400, 560))

## 商店按钮点击
func _on_shop_clicked() -> void:
	if battle == null or battle.context == null:
		return
	# 铠威攻击窗口：严格只开放攻击，不能开商店
	if _attack_window_active_for_local():
		battle.log.append({"message": "攻击窗口期间只能发动攻击", "details": {}})
		_request_refresh()
		return
	if shop_panel:
		shop_panel.configure(battle.context)
		shop_panel.visible = true

## 商店：购买普通装备
func _on_shop_normal_buy_clicked(slot_index: int) -> void:
	if battle == null or battle.context == null:
		return
	var shop_service = battle.context.shop_service
	var gs = battle.context.game_state
	var shop = gs.shop_state
	if slot_index < 0 or slot_index >= shop.normal_slots.size():
		return
	var card_id: StringName = shop.normal_slots[slot_index]
	if card_id == &"":
		return
	var card = gs.get_card(card_id)
	var full_price: int = shop_service._get_buy_price(card)
	var face_price: int = shop_service._get_face_value_price(card)
	var has_discount: bool = shop_service.has_discount(local_player_id)
	var fv_buy: Dictionary = _ActionPilotEffects.get_face_value_buy_uses(gs, local_player_id)
	var pilot_face_uses: int = int(fv_buy.get("uses", 0))
	var pilot_face_name: String = String(fv_buy.get("source_name", ""))
	if pilot_face_name == "":
		pilot_face_name = "原价"
	var can_afford_full: bool = gs.players.get(local_player_id) != null and gs.players[local_player_id].gold >= full_price
	var can_afford_face: bool = gs.players.get(local_player_id) != null and gs.players[local_player_id].gold >= face_price
	# 记录待购买状态
	_shop_buy_pending = {"kind": &"normal", "slot_index": slot_index}
	# 弹购买选项选框
	var options: Array[Dictionary] = []
	options.append({"label": "确定花费 %d 金币购买" % full_price, "effect_id": &"__shop_buy_confirm__"})
	if has_discount and can_afford_face:
		options.append({"label": "用折扣花费 %d 原价购买" % face_price, "effect_id": &"__shop_buy_discount__"})
	if pilot_face_uses > 0 and can_afford_face:
		options.append({"label": "用%s花费 %d 原价购买（剩余%d次）" % [pilot_face_name, face_price, pilot_face_uses], "effect_id": &"__shop_buy_pilot_original__"})
	options.append({"label": "取消", "effect_id": &"__shop_buy_cancel__"})
	if choice_panel:
		choice_panel.configure(options)
		choice_panel.visible = true
	if not can_afford_full and not (has_discount and can_afford_face) and not (pilot_face_uses > 0 and can_afford_face):
		battle.log.append({"message": "金币不足", "details": {}})

## 商店：购买高级装备
func _on_shop_advanced_buy_clicked() -> void:
	if battle == null or battle.context == null:
		return
	var shop_service = battle.context.shop_service
	var gs = battle.context.game_state
	var shop = gs.shop_state
	if shop.advanced_slot == &"":
		return
	var card = gs.get_card(shop.advanced_slot)
	var full_price: int = shop_service._get_buy_price(card)
	var face_price: int = shop_service._get_face_value_price(card)
	var has_discount: bool = shop_service.has_discount(local_player_id)
	var fv_buy: Dictionary = _ActionPilotEffects.get_face_value_buy_uses(gs, local_player_id)
	var pilot_face_uses: int = int(fv_buy.get("uses", 0))
	var pilot_face_name: String = String(fv_buy.get("source_name", ""))
	if pilot_face_name == "":
		pilot_face_name = "原价"
	var can_afford_full: bool = gs.players.get(local_player_id) != null and gs.players[local_player_id].gold >= full_price
	var can_afford_face: bool = gs.players.get(local_player_id) != null and gs.players[local_player_id].gold >= face_price
	_shop_buy_pending = {"kind": &"advanced"}
	var options: Array[Dictionary] = []
	options.append({"label": "确定花费 %d 金币购买" % full_price, "effect_id": &"__shop_buy_confirm__"})
	if has_discount and can_afford_face:
		options.append({"label": "用折扣花费 %d 原价购买" % face_price, "effect_id": &"__shop_buy_discount__"})
	if pilot_face_uses > 0 and can_afford_face:
		options.append({"label": "用%s花费 %d 原价购买（剩余%d次）" % [pilot_face_name, face_price, pilot_face_uses], "effect_id": &"__shop_buy_pilot_original__"})
	options.append({"label": "取消", "effect_id": &"__shop_buy_cancel__"})
	if choice_panel:
		choice_panel.configure(options)
		choice_panel.visible = true
	if not can_afford_full and not (has_discount and can_afford_face) and not (pilot_face_uses > 0 and can_afford_face):
		battle.log.append({"message": "金币不足", "details": {}})

## 商店：查看隐藏高级装备
func _on_shop_reveal_hidden_clicked() -> void:
	if battle == null or battle.context == null:
		return
	_net_exec("shop_reveal", {"player_id": local_player_id})
	if shop_panel:
		shop_panel.configure(battle.context)

## 商店：购买隐藏高级装备
func _on_shop_buy_hidden_clicked() -> void:
	if battle == null or battle.context == null:
		return
	_net_exec("shop_buy_hidden", {"player_id": local_player_id})
	if shop_panel:
		shop_panel.configure(battle.context)

## 商店：刷新商店
func _on_shop_refresh_clicked() -> void:
	if battle == null or battle.context == null:
		return
	_net_exec("shop_refresh", {"player_id": local_player_id})
	if shop_panel:
		shop_panel.configure(battle.context)

# ═══════════════════════════════════════════
# 卖出装备和设置操作
# ═══════════════════════════════════════════

## 点击2金币抽牌按钮：花2金币抽1张行动牌（每我方回合1次，所有玩家基础效果）
func _on_paid_draw_clicked() -> void:
	if battle == null or battle.context == null:
		return
	# 铠威攻击窗口：严格只开放攻击，不能花钱抽牌
	if _attack_window_active_for_local():
		battle.log.append({"message": "攻击窗口期间只能发动攻击", "details": {}})
		_request_refresh()
		return
	if not _is_my_turn():
		battle.log.append({"message": "只能在己方回合使用2金币抽牌", "details": {}})
		_request_refresh()
		return
	var gs = battle.context.game_state
	var player = gs.players.get(local_player_id)
	if not player:
		return
	if player.paid_draw_count_this_turn > 0:
		battle.log.append({"message": "本回合已用过2金币抽牌", "details": {}})
		_request_refresh()
		return
	if player.gold < _GameConfig.PAID_DRAW_ACTION_COST:
		battle.log.append({"message": "金币不足（需%d）" % _GameConfig.PAID_DRAW_ACTION_COST, "details": {}})
		_request_refresh()
		return
	_net_exec("paid_draw_action", {"player_id": local_player_id})


## 点击卖出装备按钮
func _on_sell_equipment_clicked() -> void:
	if battle == null or battle.context == null:
		return
	# 铠威攻击窗口：严格只开放攻击，不能卖出装备
	if _attack_window_active_for_local():
		battle.log.append({"message": "攻击窗口期间只能发动攻击", "details": {}})
		_request_refresh()
		return
	var gs = battle.context.game_state
	var player = gs.players.get(local_player_id)
	if not player:
		return

	# 检查是否还有卖出机会
	var remaining = _GameConfig.SELL_EQUIPMENT_LIMIT_PER_TURN - player.sell_equipment_count_this_turn
	if remaining <= 0:
		battle.log.append({"message": "本回合已用完卖出装备的机会", "details": {}})
		_request_refresh()
		return

	# 显示卖出装备面板
	sell_equipment_panel.configure(battle.context)
	sell_equipment_panel.visible = true
	battle.log.append({"message": "选择要卖出的装备", "details": {}})

## 卖出装备选择回调（从卖出面板）
func _on_sell_panel_equipment_selected(card_id: StringName) -> void:
	sell_equipment_panel.visible = false

	if battle == null or battle.context == null:
		_request_refresh()
		return

	if battle.context.card_set_service == null:
		_request_refresh()
		return

	_net_exec("sell_equipment", {"player_id": local_player_id, "card_instance_id": card_id})

## 卖出装备取消回调
func _on_sell_panel_cancelled() -> void:
	sell_equipment_panel.visible = false
	_request_refresh()

## 点击设陷按钮：记录本方机甲当前位置（arm），机甲离开后由 MapService 离场放置陷阱+消耗1层。
## 仅本方机甲拥有设陷状态时按钮可见/可用（见 _update_set_trap_button）。
func _on_set_trap_clicked() -> void:
	if battle == null or battle.context == null:
		return
	# 铠威攻击窗口：严格只开放攻击，不能设陷
	if _attack_window_active_for_local():
		battle.log.append({"message": "攻击窗口期间只能发动攻击", "details": {}})
		_request_refresh()
		return
	_net_exec("set_trap_arm", {"player_id": local_player_id})

## 更新设陷按钮可见/可用状态：本方机甲有设陷状态(层数>0)时显示；
## 已在当前位置 arm 则禁用（须先移动后再 arm）。
func _update_set_trap_button() -> void:
	if _set_trap_button == null:
		return
	if battle == null or battle.context == null:
		_set_trap_button.visible = false
		return
	var gs = battle.context.game_state
	if gs == null:
		_set_trap_button.visible = false
		return
	var mech = gs.get_mech_for_player(local_player_id)
	if mech == null:
		_set_trap_button.visible = false
		return
	var st: Dictionary = mech.get_status(&"SET_TRAP")
	if st.is_empty() or int(st.get("stacks", 0)) <= 0:
		_set_trap_button.visible = false
		return
	_set_trap_button.visible = true
	var armed := String(st.get("armed_cell", ""))
	var cur := "%s,%s" % [int(mech.position.get("q", 0)), int(mech.position.get("r", 0))]
	if armed == cur:
		_set_trap_button.text = "设陷(已设)"
		_set_trap_button.disabled = true
	else:
		_set_trap_button.text = "设陷(%d)" % int(st.get("stacks", 0))
		_set_trap_button.disabled = false

## 更新美杜莎操控按钮可见状态：本方为 pilot_009 控制者且本回合已弃牌记录类型、
## 存在受控目标同类行动牌时显示。仅我方回合可见。
func _update_medusa_control_button() -> void:
	if _medusa_control_button == null:
		return
	if battle == null or battle.context == null:
		_medusa_control_button.visible = false
		return
	if not _is_my_turn():
		_medusa_control_button.visible = false
		return
	var gs = battle.context.game_state
	if gs == null:
		_medusa_control_button.visible = false
		return
	var grants := _ActionPilotEffects.get_pilot_009_controlled_grants(local_player_id, gs)
	# 仅当存在至少1张可主动使用的受控牌时显示（攻击/可主动辅助）
	var has_active := false
	for g: Dictionary in grants:
		var card_ids: Array = g.get("card_ids", [])
		if card_ids.is_empty():
			continue
		for cid: StringName in card_ids:
			var c = gs.get_card(cid)
			if c == null or c.def == null:
				continue
			if _pilot_009_card_is_usable_active(c.def):
				has_active = true
				break
		if has_active:
			break
	_medusa_control_button.visible = has_active
	if has_active:
		_medusa_control_button.disabled = false

## 判定受控牌是否为可主动使用类型（攻击牌 / 非被动辅助牌）。
## 迎击牌（响应窗口）/ 掩护·推进（permanent_while_in_hand 触发窗口）为被动牌，不列主动按钮。
func _pilot_009_card_is_usable_active(card_def) -> bool:
	if card_def == null:
		return false
	var at := String(card_def.action_type)
	if at == "攻击":
		return true
	if at == "迎击":
		return false # 被动：响应窗口
	if at == "辅助":
		# 掩护/推进等 permanent_while_in_hand 被动牌走触发窗口，不列主动按钮；
		# 维修/聚能等可主动辅助牌（无 permanent_while_in_hand 效果）可列。
		var mappings: Array = _GeneratedActionEffects.get_effects_for_card(card_def.card_id)
		var all_effects: Dictionary = _pilot_009_all_effects()
		for mapping in mappings:
			var eid: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
			var eff = all_effects.get(eid)
			if eff != null and eff.permanent_while_in_hand:
				return false
		return true
	return false

## 惰性构建并缓存 GeneratedActionEffects 全表（pilot_009 主动牌判定复用，避免每帧重建）。
func _pilot_009_all_effects() -> Dictionary:
	if _pilot_009_all_effects_cache.is_empty():
		_pilot_009_all_effects_cache = _GeneratedActionEffects.build_all_effects()
	return _pilot_009_all_effects_cache

## 点击美杜莎操控按钮：列出本方 pilot_009 当前受控目标的同类行动牌（攻击/可主动辅助），
## 单选确认后经 _play_action_card 打出（use_action_card 的受控牌校验会跨手牌擦除目标手牌）。
## 复用 unite_attack_select_panel 做单选，以 _medusa_control_select_active 与联合攻击区分。
func _on_medusa_control_clicked() -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	if gs == null:
		return
	var grants := _ActionPilotEffects.get_pilot_009_controlled_grants(local_player_id, gs)
	# 收集瑟尔基尔 effect_02 判定管线中的牌（应"出现但不可选"）。
	var judging_entries: Array[Dictionary] = []
	if battle.context.action_service != null and battle.context.action_service.has_method(&"get_p003_judging_card_entries"):
		judging_entries = battle.context.action_service.get_p003_judging_card_entries()
	# 受控范围：target_mech_id -> [受控 card_type...]，用于判定管线牌是否属本美杜莎受控。
	var controlled_types_by_mech: Dictionary = {}
	for g: Dictionary in grants:
		var tm: StringName = StringName(String(g.get("target_mech_id", &"")))
		var ct: String = String(g.get("card_type", &""))
		if tm != &"" and ct != "":
			if not controlled_types_by_mech.has(tm):
				controlled_types_by_mech[tm] = []
			controlled_types_by_mech[tm].append(ct)
	# 手牌中所有 card_id 集合（区分"在手 vs 已离手"）+ 受控范围内 usable_active 的判定管线牌。
	var in_hand_set: Dictionary = {}
	for g: Dictionary in grants:
		for cid: StringName in g.get("card_ids", []):
			in_hand_set[cid] = true
	var judging_card_ids: Array = [] # [StringName] 受控范围内 usable_active 的判定管线牌（含在手与已离手）
	for je: Dictionary in judging_entries:
		var jcid: StringName = StringName(String(je.get("card_id", &"")))
		var jmid: StringName = StringName(String(je.get("owner_mech_id", &"")))
		if jcid == &"" or jmid == &"":
			continue
		if not controlled_types_by_mech.has(jmid):
			continue
		var jc = gs.get_card(jcid)
		if jc == null or jc.def == null:
			continue
		if not _pilot_009_card_is_usable_active(jc.def):
			continue
		var jtypes: Array = controlled_types_by_mech[jmid]
		if not jtypes.has(String(jc.def.action_type)):
			continue
		if not judging_card_ids.has(jcid):
			judging_card_ids.append(jcid)
	var judging_set: Dictionary = {}
	for jcid in judging_card_ids:
		judging_set[jcid] = true
	# 可选：在手·usable_active·非管线；禁选：在手·管线 + 已离手·管线
	var selectable: Array = [] # [StringName]
	var disabled_card_ids: Array = [] # [StringName]
	for jcid in judging_card_ids:
		disabled_card_ids.append(jcid)
	for g: Dictionary in grants:
		for cid: StringName in g.get("card_ids", []):
			var c = gs.get_card(cid)
			if c == null or c.def == null:
				continue
			if not _pilot_009_card_is_usable_active(c.def):
				continue
			if judging_set.has(cid):
				if not disabled_card_ids.has(cid):
					disabled_card_ids.append(cid)
			else:
				selectable.append(cid)
	if selectable.is_empty() and disabled_card_ids.is_empty():
		_request_refresh()
		return
	# 即使仅1张可选也弹选框（裁定：和手牌一样需玩家点选+确认，不直接打出）。
	# 复用 unite_attack_select 面板，click_to_confirm=true：点牌即 emit -> app_root 弹"确定使用?"确认框。
	var card_ids: Array = []
	for cid in selectable:
		card_ids.append(cid)
	for cid in disabled_card_ids:
		card_ids.append(cid)
	# 临时把 holder 标注塞进牌名后缀——unite 面板按 _card_suffix 统一后缀，无法逐张区分，
	# 故此处退化为统一 "(来自目标)" 后缀；逐张来源已在展示浮窗中体现。
	_medusa_control_select_active = true
	unite_attack_select_panel.configure(battle.context, card_ids, "美杜莎操控：选择1张受控行动牌使用", "[受控]", "打出", "取消", disabled_card_ids, "[受控·处理中]", true)
	unite_attack_select_panel.visible = true

## 取目标机甲持有者显示名（用于「来自XX」标注）：优先机甲框架名，回退玩家id。
func _pilot_009_holder_display_name(target_mech_id: StringName, gs) -> String:
	if gs == null:
		return String(target_mech_id)
	var mech = gs.mechs.get(target_mech_id, null)
	if mech != null and mech.frame_def != null and String(mech.frame_def.display_name) != "":
		return String(mech.frame_def.display_name)
	var player = gs.get_player_for_mech(target_mech_id) if gs.has_method(&"get_player_for_mech") else null
	if player != null:
		return String(player.player_id) if "player_id" in player else String(target_mech_id)
	return String(target_mech_id)

## 显示卖出装备选择面板
func _show_sell_equipment_panel() -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	if not player or not mech:
		return

	# 收集可卖出选项
	var options: Array[Dictionary] = []

	# 1. 玩家手中的装备牌
	for card_id: StringName in player.equipment_hand:
		var card = gs.get_card(card_id)
		if card and card.def:
			options.append({
				"type": "hand",
				"card_id": card_id,
				"effect_id": card_id,  # 使用 card_id 作为 effect_id
				"label": "%s (手中)" % card.def.display_name,
			})

	# 2. 备用区的装备牌
	for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
		if mech.slots.has(rs_id) and mech.slots[rs_id].equipped_card != null:
			var card = mech.slots[rs_id].equipped_card
			if card and card.def:
				var reserve_name = "备用1" if rs_id == &"reserve_1" else "备用2"
				options.append({
					"type": "reserve",
					"card_id": card.instance_id,
					"slot_id": rs_id,
					"effect_id": card.instance_id,  # 使用 card_id 作为 effect_id
					"label": "%s: %s (%s)" % [reserve_name, card.def.display_name, _get_card_rarity_text(card.def.rarity)],
				})

	if options.is_empty():
		battle.log.append({"message": "没有可卖出的装备", "details": {}})
		_sell_mode_active = false
		_request_refresh()
		return

	# 使用 choice_panel 显示选项
	choice_panel.configure(options)
	choice_panel.visible = true
	battle.log.append({"message": "选择要卖出的装备", "details": {}})

## 获取稀有度文本
func _get_card_rarity_text(rarity: StringName) -> String:
	match rarity:
		&"N": return "普通"
		&"R": return "稀有"
		&"SR": return "超稀有"
		&"SSR": return "极稀有"
		_: return "普通"

## 点击装备牌进入设置操作（选择槽位）
func _enter_set_equipment_mode(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(local_player_id)
	if not mech:
		return

	var card = gs.get_card(card_id)
	if not card or not card.def:
		return

	_set_equipment_card_id = card_id
	_show_set_equipment_panel(card)

## 显示设置装备选择面板
func _show_set_equipment_panel(card) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(local_player_id)
	if not mech:
		return

	# 收集可用槽位
	var options: Array[Dictionary] = []

	# 所有装备都可以设置到部件槽位和备用区
	if card.def.equipment_kind == &"PART":
		# 部件只能设置到对应槽位 + 备用区
		var slot_id = card.def.slot
		if mech.slots.has(slot_id):
			var slot = mech.slots[slot_id]
			var current = _get_slot_equipment_text(slot)
			options.append({
				"slot_id": slot_id,
				"effect_id": slot_id,
				"label": "%s (%s)" % [SLOT_NAMES.get(slot_id, slot_id), current],
			})
		# 添加备用区选项
		for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
			if mech.slots.has(rs_id):
				var slot = mech.slots[rs_id]
				var current = _get_slot_equipment_text(slot)
				options.append({
					"slot_id": rs_id,
					"effect_id": rs_id,
					"label": "%s (%s)" % [SLOT_NAMES.get(rs_id, rs_id), current],
				})
	elif card.def.equipment_kind == &"WEAPON":
		# 武器可以设置到任一武器槽 + 备用区
		for ws_id: StringName in [&"weapon_1", &"weapon_2"]:
			if mech.slots.has(ws_id):
				var slot = mech.slots[ws_id]
				var current = _get_slot_equipment_text(slot)
				options.append({
					"slot_id": ws_id,
					"effect_id": ws_id,
					"label": "%s (%s)" % [SLOT_NAMES.get(ws_id, ws_id), current],
				})
		# 添加备用区选项
		for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
			if mech.slots.has(rs_id):
				var slot = mech.slots[rs_id]
				var current = _get_slot_equipment_text(slot)
				options.append({
					"slot_id": rs_id,
					"effect_id": rs_id,
					"label": "%s (%s)" % [SLOT_NAMES.get(rs_id, rs_id), current],
				})
	else:
		# 其他类型装备添加到备用区
		for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
			if mech.slots.has(rs_id):
				var slot = mech.slots[rs_id]
				var current = _get_slot_equipment_text(slot)
				options.append({
					"slot_id": rs_id,
					"effect_id": rs_id,
					"label": "%s (%s)" % [SLOT_NAMES.get(rs_id, rs_id), current],
				})

	if options.is_empty():
		battle.log.append({"message": "没有可用槽位", "details": {}})
		_set_equipment_card_id = &""
		_request_refresh()
		return

	# 使用 choice_panel 显示选项（choice_panel 会自动添加取消按钮）
	choice_panel.configure(options)
	choice_panel.visible = true
	battle.log.append({"message": "选择设置区域", "details": {}})

## 获取槽位装备描述
func _get_slot_equipment_text(slot) -> String:
	if slot.equipped_card and slot.equipped_card.def:
		return slot.equipped_card.def.display_name
	return "空"

## 设置区域选择回调
func _on_set_equipment_slot_selected(option: Dictionary) -> void:
	choice_panel.visible = false
	var slot_id = option.get("slot_id", &"")
	var card_id = _set_equipment_card_id
	_set_equipment_card_id = &""

	if slot_id == &"" or slot_id == "":
		# 取消
		_request_refresh()
		return

	# 执行设置
	_do_set_equipment(card_id, slot_id)

## 点击备用区设置按钮
func _on_reserve_set_clicked(slot_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(local_player_id)
	var player = gs.players.get(local_player_id)
	if not mech or not player:
		return

	# 检查备用区是否有装备
	if not mech.slots.has(slot_id) or not mech.slots[slot_id].equipped_card:
		return

	# 获取备用区的装备
	var reserve_card = mech.slots[slot_id].equipped_card
	if not reserve_card or not reserve_card.def:
		return

	# "禁"标签拦截（法尔科 pilot_073 弃2抽高级装备置备用区等）：打标签玩家下个回合开始前
	# 不能主动设置（含从备用区移到手牌再设置）。按钮置灰 + 此处后端双保险。
	if _ActionPilotEffects.equip_forbid_tagged(reserve_card):
		battle.log.append({"message": "该装备尚不能主动设置（禁标签）", "details": {}})
		_request_refresh()
		return

	# 进入设置操作，将备用区的装备设置到其他槽位
	# 先从备用区移除
	mech.slots[slot_id].equipped_card = null
	# 添加回玩家手牌（这样 _enter_set_equipment_mode 才能正确处理）
	player.equipment_hand.append(reserve_card.instance_id)

	# 进入设置模式，设置这个装备
	_enter_set_equipment_mode(reserve_card.instance_id)

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

	# 获取武器列表（含虚拟武器神莺躯干，攻击需 power>0；只列范围内有可攻击目标的武器）
	var all_weapons: Array[StringName] = _get_all_usable_weapon_ids(mech, true)
	var weapon_ids: Array[StringName] = []
	for wid in all_weapons:
		if _weapon_has_attackable_target(mech, wid):
			weapon_ids.append(wid)
	if weapon_ids.is_empty():
		battle.log.append({"message": "没有可用武器", "details": {}})
		return

	attack_flow.enter_select_weapon(attack_card_id, &"player", &"enemy", false)

	# 如果只有1把武器，自动选择
	if weapon_ids.size() == 1:
		_on_weapon_selected(weapon_ids[0])
	else:
		# 有多把武器，显示选择面板
		weapon_picker_panel.configure(battle.context, weapon_ids, "── 选择武器 ──", mech)
		weapon_picker_panel.visible = true
		_show_cancel_button(true)
		_request_refresh()

## 武器选择回调（攻击武器选择 或 武器槽位替换选择 或 辅助牌武器选择）
func _on_weapon_selected(weapon_id: StringName) -> void:
	# ── 新动作系统：如果正在等待武器选择输入，反馈给ActionUIBridge ──
	if battle and battle.context and battle.context.action_ui_bridge:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if wait_info.get("input_type", &"") == &"select_weapon":
			# 选完武器立即关闭面板，避免面板残留需玩家手动点取消、
			# 且面板仍在时误触发后续 on_ui_cancelled 造成攻击动作被二次驱动。
			weapon_picker_panel.visible = false
			_show_cancel_button(false)
			_net_exec("ui_confirmed", {"data": {"weapon_id": weapon_id}})
			return
		if wait_info.get("input_type", &"") == &"select_weapon_for_charge":
			# 聚能选武器：input_type 是 select_weapon_for_charge（非 popup_type weapon_charge_select）。
			# 注入 selected_weapon_id（CHOOSE_OWN_WEAPON 目标规则读此键），经 resume_pending_effect
			# 续跑 _execute_effect -> APPLY_ENERGY_TO_WEAPON。清理旧路径残留避免下次误走 _on_support_weapon_selected。
			weapon_picker_panel.visible = false
			_show_cancel_button(false)
			_support_weapon_select_card_id = &""
			var wchg_aid: StringName = StringName(wait_info.get("action_id", &""))
			if wchg_aid != &"":
				_net_exec("resume_effect", {"action_id": wchg_aid, "data": {"selected_weapon_id": weapon_id}})
			else:
				_net_exec("ui_confirmed", {"data": {"selected_weapon_id": weapon_id}})
			return

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

	# 攻击武器选择已统一走新动作系统（ActionUIBridge.on_ui_confirmed），
	# 旧 attack_flow.enter_select_target 路径已废弃移除。
	weapon_picker_panel.visible = false
	_request_refresh()

## 武器选择取消
func _on_weapon_selection_cancelled() -> void:
	# ── 新动作系统：如果正在等待输入，取消该动作 ──
	if battle and battle.context and battle.context.action_ui_bridge:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if not wait_info.is_empty():
			_net_exec("ui_cancelled", {})
			_clear_attack_highlights()
			return

	_cancel_attack_mode()
	_request_refresh()

## 取消攻击按钮
func _on_cancel_attack() -> void:
	# ── 琳 RE 维修窗口取消：窗口激活 且 本机是琳 且 未在修复牌确认对话框中 ──
	# 点「取消维修」= 关闭窗口，恢复请求方回合。窗口期间琳可能已开始维修
	# （确认对话框 / 维修二选一 / 移除损伤面板），此时底部取消按钮已被隐藏，
	# 此处仅兜底处理异常情况（防御：取消任何进行中的等待输入）。
	if _pilot_024_lin_window_active() and _choice_select_card_id == &"":
		if battle and battle.context and battle.context.action_ui_bridge:
			var p24_wi: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
			if not p24_wi.is_empty():
				_net_exec("ui_cancelled", {})
		_ActionPilotEffects.pilot_024_close_repair_window(battle.context)
		_show_cancel_button(false)
		battle.log.append({"message": "琳取消了维修请求", "details": {}})
		_request_refresh()
		return
	# ── 新动作系统：如果正在等待输入，取消该动作 ──
	if battle and battle.context and battle.context.action_ui_bridge:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if not wait_info.is_empty():
			# 通用多选机甲（CHOOSE_MANY_MECHS，奥黛尔 pilot_038 / 弥雅 pilot_071）：取消按钮=用已选
			# 目标继续（已选>=min_count 提交，<min_count 中止=取消整个效果不计次）。
			# 提交/取消均带 action_id 精确路由：效果挂起后共享等待槽可能被后续时点弹窗覆盖，
			# 按共享槽走 ui_confirmed/ui_cancelled 会指向错误动作（弥雅"选了没反应"根因）。
			if not _mech_multi_select_opts.is_empty():
				var _mm_aid: StringName = StringName(_mech_multi_select_opts.get("action_id", &""))
				if _multi_attack_target_chosen.size() >= int(_mech_multi_select_opts.get("min_count", 1)):
					_submit_multi_attack_targets(_mm_aid)
				else:
					_clear_attack_highlights()
					if _mm_aid != &"":
						_net_exec("resume_effect", {"action_id": _mm_aid, "data": {"cancelled": true}})
					else:
						_net_exec("ui_cancelled", {})
				return
			# 多目标攻击选择：取消按钮=用已选目标继续（>=1 时提交，0 时中止）
			if _multi_attack_target_count >= 2:
				if not _multi_attack_target_chosen.is_empty():
					_submit_multi_attack_targets()
				else:
					_net_exec("ui_cancelled", {})
					_clear_attack_highlights()
				return
			# 通用选格取消（机雷/格雷厄姆移陷/墨尘等）：同确认路径走 resume_effect 按
			# action_id 精确路由带 cancelled=true（共享槽 ui_cancelled 在对端被
			# skip_remote_waiting 清槽后早return 丢输入->对端停在选格挂起三方卡死）。
			if _map_cell_select_action_id != &"":
				var smc_aid: StringName = _map_cell_select_action_id
				_map_cell_select_action_id = &""
				_clear_attack_highlights()
				_net_exec("resume_effect", {"action_id": smc_aid, "data": {"cancelled": true}})
				return
			# 引擎级挂起（_pending_effect）的效果取消：按 action_id 精确路由带 cancelled=true
			# （骇客窥牌/通用目标选择等。共享槽 ui_cancelled 在对端被 skip_remote_waiting
			# 清槽后早 return 丢输入->对端停在挂起三方卡死）。无挂起走原共享槽路径。
			var _uic_aid: StringName = StringName(wait_info.get("action_id", &""))
			if _uic_aid != &"" and battle.context.timing_engine.has_pending_effect(_uic_aid):
				_net_exec("resume_effect", {"action_id": _uic_aid, "data": {"cancelled": true}})
			else:
				_net_exec("ui_cancelled", {})
			_clear_attack_highlights()
			return

	# 强袭移动取消 = 原地停留并结算（攻击已声明，不能整体撤销）
	# ── 单次移动动作进行中（逐格 basic_move，无 wait_info）：取消该动作 ──
	if battle and battle.context and battle.context.action_registry:
		for a in battle.context.action_registry.get_actions_by_type(&"single_move"):
			# waiting_timing = 逐格移动 50ms/格暂停中，同样可中断
			if a.state == &"running" or a.state == &"waiting_effect_action" or a.state == &"waiting_input" or a.state == &"waiting_timing":
				_net_exec("cancel_move", _build_cancel_move_data(a))
				_show_cancel_button(false)
				return
	if _assault_movement_active:
		var gs = battle.context.game_state
		var attack_context: Dictionary = {}  # old attack context removed in new system
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
	# 铠威攻击窗口取消：无进行中的攻击/移动/输入时，点「取消攻击」关闭窗口（结束本次窗口）。
	# 注意需放在 waiting_input / single_move 分支之后——窗口内攻击的目标选择取消走上面动作取消，
	# 窗口本身保留可再次攻击；此处只处理「主动退出窗口」。PvP 走 attack_window_close op 双端关窗保持锁步。
	if _attack_window_active_for_local():
		_cancel_attack_mode()
		_net_exec("attack_window_close", {})
		battle.log.append({"message": "取消攻击窗口", "details": {}})
		_request_refresh()
		return
	_cancel_attack_mode()
	_request_refresh()

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
		battle_board.clear_attack_targets()
	if weapon_picker_panel:
		weapon_picker_panel.visible = false
	if damage_placement_panel:
		damage_placement_panel.visible = false
	_show_cancel_button(false)

## 显示/隐藏取消攻击按钮
func _show_cancel_button(show: bool) -> void:
	if cancel_attack_button:
		cancel_attack_button.visible = show

## ═══════════════════════════════════════════
## 琳 pilot_024 RE 维修窗口 UI
## ═══════════════════════════════════════════

## 琳 RE 维修窗口状态变化：打开时本机为琳 -> 显示「取消维修」按钮；关闭 -> 隐藏并恢复文字。
## 请求方端（本机非琳）不显示取消按钮（请求方回合被阻塞，无法主动取消）。
func _on_pilot_024_repair_window_changed(opened: bool, requester_mech_id: StringName) -> void:
	if cancel_attack_button == null:
		return
	if opened:
		var gs = battle.context.game_state if (battle and battle.context) else null
		if gs == null:
			return
		var lin_mid: StringName = _ActionPilotEffects.pilot_024_find_lin_mech(gs)
		if lin_mid == &"":
			return
		var lin_mech = gs.mechs.get(lin_mid)
		if lin_mech == null or lin_mech.owner_player_id != local_player_id:
			return  # 本机不是琳，不显示取消按钮
		cancel_attack_button.text = "取消维修"
		_show_cancel_button(true)
	else:
		cancel_attack_button.text = "取消攻击"
		_show_cancel_button(false)


## 请求方是否被 RE 维修流程阻塞（确认等待阶段 + 维修窗口阶段）。
## 确认等待：RE 请求 popup 路由到琳（player_id 非本机）且 effect_id==pilot_024_re_request。
## 维修窗口：gs.pilot_024_repair_window 的 requester_mech_id 是本机机甲。
## 阻塞期间请求方不能移动/打牌/结束回合（等待琳维修）。
func _pilot_024_requester_blocked() -> bool:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return false
	var gs = battle.context.game_state
	# 维修窗口激活：请求方被阻塞
	var win: Dictionary = _ActionPilotEffects.pilot_024_repair_window(gs)
	if not win.is_empty():
		var my_mech = gs.get_mech_for_player(local_player_id)
		if my_mech != null and String(win.get("requester_mech_id", &"")) == String(my_mech.mech_id):
			return true
	# 确认等待阶段：本机 RE 请求已发出，等待琳确认
	if battle.context.action_ui_bridge:
		var p24_wi: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if not p24_wi.is_empty() and p24_wi.get("input_type", &"") == &"choose_one_effect":
			var p24_ip: Dictionary = p24_wi.get("input_params", {})
			if String(p24_ip.get("effect_id", &"")) == "pilot_024_re_request":
				return String(p24_ip.get("player_id", &"")) != String(local_player_id)
	return false


## 维修窗口是否激活 且 本机是琳（琳可进行窗口维修：点维修牌 / 用效果1 / 取消维修）。
func _pilot_024_lin_window_active() -> bool:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return false
	var gs = battle.context.game_state
	if not _ActionPilotEffects.pilot_024_window_active(gs):
		return false
	var lin_mid: StringName = _ActionPilotEffects.pilot_024_find_lin_mech(gs)
	if lin_mid == &"":
		return false
	var lin_mech = gs.mechs.get(lin_mid)
	return lin_mech != null and lin_mech.owner_player_id == local_player_id

# ═══════════════════════════════════════════
## 铠威 pilot_039 通用攻击窗口 UI
## ═══════════════════════════════════════════

## 攻击窗口是否激活 且 归属本机玩家（本机可在窗口内发动攻击）。
func _attack_window_active_for_local() -> bool:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return false
	return _ActionPilotEffects.attack_window_active_for_player(battle.context.game_state, local_player_id)

## 展示攻击窗口确认弹窗（accept=抽1张行动牌+打开窗口 / cancel=无事发生）。
func _show_attack_window_prompt(pending: Dictionary) -> void:
	if choice_panel == null or battle == null or battle.context == null:
		return
	_attack_window_prompt_showing = true
	var mid: StringName = pending.get("mech_id", &"")
	var mech = battle.context.game_state.mechs.get(mid) if battle.context.game_state != null else null
	var mech_name: String = String(mech.frame_def.display_name) if mech != null and mech.frame_def != null else String(mid)
	var win_options: Array[Dictionary] = [
		{"label": "抽1张行动牌并立即攻击", "effect_id": &"__attack_window_accept__"},
		{"label": "不抽，结束", "effect_id": &"__attack_window_cancel__"},
	]
	choice_panel.configure(win_options)
	# 模态入栈（_present_popup 显示遮罩+隐藏下层）：阻止确认框外点击穿透（铠威 bug：非模态时
	# 还能点外部地图/手牌）。确认/取消经 choice_made/choice_cancelled 隐藏面板时 visibility_changed
	# 自动出栈关闭遮罩（choice_panel 已在模态弹窗监听列表）。
	_present_popup(&"choice_prompt", choice_panel)
	battle.log.append({"message": "铠威：攻击被响应，是否抽1张行动牌并立即发动1次攻击？（%s）" % mech_name, "details": {}})


## 铠厉通用「被响应→抽2装备设置/弃置获金」确认弹窗（accept=抽2张装备牌并逐张设置/弃置获金 /
## cancel=不发动）。被动效果：我方发动的攻击被响应时弹窗询问是否发动。
func _show_responded_equip_confirm_prompt(pending: Dictionary) -> void:
	if choice_panel == null or battle == null or battle.context == null:
		return
	_responded_equip_prompt_showing = true
	var re_mid: StringName = pending.get("mech_id", &"")
	var re_mech = battle.context.game_state.mechs.get(re_mid) if battle.context.game_state != null else null
	var re_mech_name: String = String(re_mech.frame_def.display_name) if re_mech != null and re_mech.frame_def != null else String(re_mid)
	var re_options: Array[Dictionary] = [
		{"label": "发动（抽2张装备牌并逐张设置/弃置获金）", "effect_id": &"__responded_equip_accept__"},
		{"label": "不发动", "effect_id": &"__responded_equip_cancel__"},
	]
	choice_panel.configure(re_options)
	_present_popup(&"choice_prompt", choice_panel)
	battle.log.append({"message": "你的攻击被响应：是否抽2张装备牌，若不设置则弃置并获得牌面金币？（%s）" % re_mech_name, "details": {}})

## 铠德「被响应→三选一」弹窗（choice=0/1/2 对应 抽2张行动牌/回复3动力/获得4金币；底部「取消」=放弃）。
## 被动效果：我方发动的攻击被响应时弹窗询问选择其一（或放弃不发动）。
func _show_pilot_060_choice_prompt(pending: Dictionary) -> void:
	if choice_panel == null or battle == null or battle.context == null:
		return
	_pilot_060_prompt_showing = true
	var p60_mid: StringName = pending.get("mech_id", &"")
	var p60_mech = battle.context.game_state.mechs.get(p60_mid) if battle.context.game_state != null else null
	var p60_mech_name: String = String(p60_mech.frame_def.display_name) if p60_mech != null and p60_mech.frame_def != null else String(p60_mid)
	var p60_options: Array[Dictionary] = [
		{"label": "抽2张行动牌", "effect_id": &"__pilot_060_choice_0__"},
		{"label": "回复3动力", "effect_id": &"__pilot_060_choice_1__"},
		{"label": "获得4金币", "effect_id": &"__pilot_060_choice_2__"},
	]
	choice_panel.configure(p60_options, "铠德·被响应三选一（%s）" % p60_mech_name)
	_present_popup(&"choice_prompt", choice_panel)
	battle.log.append({"message": "你的攻击被响应，可以选择其一：抽2张行动牌/回复3动力/获得4金币，或取消放弃。（%s）" % p60_mech_name, "details": {}})

## 攻击窗口 UI 刷新（_refresh_battle 帧末调用）：
## ①确认弹窗：pending_prompt 归属本机且未在展示 -> 弹确认（含 request_ui_popup 触发路径，幂等守卫）。
## ②窗口激活且无等待输入：显示底部「取消攻击」按钮（可主动关闭窗口）。
func _maybe_update_attack_window_ui() -> void:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return
	var gs = battle.context.game_state
	if not gs.attack_window_pending_prompt.is_empty():
		var awp: Dictionary = gs.attack_window_pending_prompt
		if String(awp.get("player_id", &"")) == String(local_player_id) and not _attack_window_prompt_showing:
			_show_attack_window_prompt(awp)
			return
	if _attack_window_active_for_local():
		var aw_wait: bool = battle.context.action_ui_bridge != null and not battle.context.action_ui_bridge.get_waiting_action_info().is_empty()
		if not aw_wait and cancel_attack_button != null:
			cancel_attack_button.text = "取消攻击"
			_show_cancel_button(true)

## 铠厉通用「被响应→抽2装备设置/弃置获金」UI 周期检查（_refresh_battle 帧末调用，幂等守卫）：
## ①确认弹窗：responded_equip_pending_confirm 归属本机且未在展示 -> 弹确认（含 request_ui_popup 触发路径兜底）。
## ②逐张设置面板：responded_equip_chain 当前卡归属本机且面板未在展示 -> 弹「立即设置/弃置获金(cost)」面板。
func _maybe_update_responded_equip_ui() -> void:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return
	var gs = battle.context.game_state
	if not gs.responded_equip_pending_confirm.is_empty():
		var rep: Dictionary = gs.responded_equip_pending_confirm
		if String(rep.get("player_id", &"")) == String(local_player_id) and not _responded_equip_prompt_showing:
			_show_responded_equip_confirm_prompt(rep)
			return
	if not gs.responded_equip_chain.is_empty() and not _responded_equip_set_active:
		var chain: Dictionary = gs.responded_equip_chain
		if String(chain.get("owner_player_id", &"")) == String(local_player_id):
			var re_cards: Array = chain.get("card_ids", [])
			var re_index: int = int(chain.get("index", 0))
			if re_index < re_cards.size() and immediate_set_equipment_panel != null:
				var re_mid: StringName = chain.get("owner_mech_id", &"")
				var re_cid: StringName = re_cards[re_index]
				var re_mech = gs.mechs.get(re_mid)
				var re_card = gs.get_card(re_cid)
				if re_card != null and re_card.def != null:
					_responded_equip_set_active = true
					var re_slots: Array = _ActionPilotEffects.responded_equip_valid_slots(re_mech, re_card)
					var re_cost: int = _ActionPilotEffects.responded_equip_card_cost(re_card)
					immediate_set_equipment_panel.configure(battle.context, re_cid, re_slots, re_mid, true, re_cost, "被响应抽到的装备：立即设置，或弃置此牌获得金币", true, "弃置此牌（+%d 金币）")
					immediate_set_equipment_panel.visible = true

## 铠德「被响应→三选一」UI 周期检查（_refresh_battle 帧末调用，幂等守卫）：
## pilot_060_pending_choice 归属本机且未在展示 -> 弹三选一（含 request_ui_popup 触发路径兜底）。
func _maybe_update_pilot_060_ui() -> void:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return
	var gs = battle.context.game_state
	if not gs.pilot_060_pending_choice.is_empty():
		var p60_p: Dictionary = gs.pilot_060_pending_choice
		if String(p60_p.get("player_id", &"")) == String(local_player_id) and not _pilot_060_prompt_showing:
			_show_pilot_060_choice_prompt(p60_p)

## 是否有进行中的单次移动动作（含逐格暂停的 waiting_timing / 效果挂起的 waiting_effect_action / waiting_input）。
## 用于：①"move"后仅在移动仍进行时显示取消按钮（同步完成的移动无需取消，否则按钮残留）；
## ②动作完成回调中仅在无进行中移动时隐藏取消按钮（逐格移动每格 basic_move 子动作完成都会触发回调，
##   但父 single_move 仍在进行，取消按钮应保留到移动真正结束）。
func _has_active_single_move() -> bool:
	if battle == null or battle.context == null or battle.context.action_registry == null:
		return false
	for a in battle.context.action_registry.get_actions_by_type(&"single_move"):
		if a.state == &"running" or a.state == &"waiting_effect_action" or a.state == &"waiting_input" or a.state == &"waiting_timing":
			return true
	return false

## 逐格移动是否处于 pacing 阶段（可点击停止）：有进行中的 single_move 且无弹窗等待输入，
## 且本窗口是移动方（active_player_id == local_player_id）--非移动方/玩家看 AI 移动时不应能停止。
## 弹窗显示时（如 effect_017 回复动力+移动）返回 false，让玩家与弹窗交互而非停止移动。
func _move_is_pacing() -> bool:
	if battle == null or battle.context == null:
		return false
	if not _has_active_single_move():
		return false
	if battle.context.action_ui_bridge and not battle.context.action_ui_bridge.get_waiting_action_info().is_empty():
		return false
	if battle.context.game_state != null and battle.context.game_state.active_player_id != StringName(local_player_id):
		return false
	return true

## 更新移动模态遮罩：pacing 时拦截全屏点击（点任意位置停止移动），否则透传。
func _update_move_overlay() -> void:
	if _move_overlay == null or not is_instance_valid(_move_overlay):
		return
	_move_overlay.mouse_filter = Control.MOUSE_FILTER_STOP if _move_is_pacing() else Control.MOUSE_FILTER_IGNORE

## 移动遮罩点击：停止进行中的移动（取消 single_move，机甲停在当前已完成格）。
func _on_move_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if battle and battle.context and battle.context.action_registry:
			for a in battle.context.action_registry.get_actions_by_type(&"single_move"):
				if a.state == &"running" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action" or a.state == &"waiting_input":
					_net_exec("cancel_move", _build_cancel_move_data(a))
					break
		_update_move_overlay()

## 构造 cancel_move 同步数据：取机甲当前（已完成逐格 basic_move 后的）位置/动力/移动格数。
## 远端按 mech_id 取消进行中的 single_move（不依赖 action_id 匹配--锁步计数器一旦发散，
## 按 action_id 取消会空操作，远端 single_move 走到终点致位置不同步），再把机甲状态
## 强制同步到本方实际值，确保取消后两端位置/动力/格数完全一致。
func _build_cancel_move_data(single_move_action) -> Dictionary:
	var mech_id: StringName = single_move_action.record.get("mech_id", &"")
	var mech = battle.context.game_state.mechs.get(mech_id) if (battle and battle.context and battle.context.game_state) else null
	if mech == null:
		return {"mech_id": String(mech_id)}
	return {
		"mech_id": String(mech_id),
		"q": int(mech.position.get("q", 0)),
		"r": int(mech.position.get("r", 0)),
		"power": int(mech.power),
		"power_spent": int(mech.power_spent_this_turn),
		"temp_power": int(mech.temp_power),
		"own_power_spent": int(mech.own_power_spent_this_turn),
		"temp_power_granted": int(mech.temp_power_granted_this_turn),
		"cells_moved": int(mech.cells_moved_this_turn),
		# 本方 ActionRegistry 计数器当前值：远端若因先前动作(设装备/打牌)致计数器发散，
		# 后续攻击等动作的 action_id 会两端不匹配（respond_attack 找不到动作->攻击卡临时区）。
		# 移动取消时无其他活跃动作，把远端计数器拉回本方值，保证后续动作 action_id 重新对齐。
		"action_counter": int(battle.context.action_registry._id_counter) if (battle.context and battle.context.action_registry) else 0,
	}

## 清除攻击目标选择的双高亮（绿色范围 + 红色闪烁）并隐藏取消按钮
## 在目标确认或取消时调用，使地图恢复为正常 UI
## 顶层自由移动结束后的轻量刷新：清移动连线 + 刷新面板（状态/装备/技能/消息）。
## 不走全量 _refresh_battle--移动未改变手牌，且 board.configure 会重算 _grid_scale，
## 在面板重建布局抖动时读到瞬态尺寸致界面抖动。board 位置已由逐格 _refresh_board_only 更新，
## 此处仅 queue_redraw 清除路径连线。
func _refresh_after_move_end() -> void:
	if battle == null or battle.context == null:
		return
	# 取消已排队的延迟全量刷新（basic_move 子动作完成时 _request_refresh 排入的）：
	# 否则帧末 _refresh_battle_coalesced 会因父 single_move 已完成（_has_active_single_move=false）
	# 跑全量 _refresh_battle -> battle_board.configure -> _update_grid_transform 重算缩放，
	# 在面板重建布局抖动时读到瞬态尺寸致整片棋盘闪一下（move-end 屏闪根因）。
	_refresh_pending = false
	if battle_board:
		battle_board._move_active = false
		battle_board._move_destination = {}
		battle_board._planned_path_cells = []
		battle_board._move_path_centers = []
		battle_board.queue_redraw()
	_refresh_damage_ui()
	_update_move_overlay()

func _clear_attack_highlights() -> void:
	if battle_board:
		battle_board.clear_highlight()      # 清绿色范围 + 连带清红色闪烁层
		battle_board.clear_attack_targets()
	_show_cancel_button(false)
	_pilot_006_forced_target = &""  # 清里昂狩猎豁免约束
	# 重置多目标攻击选择状态
	_multi_attack_target_count = 1
	_multi_attack_target_chosen = []
	# 重置通用多选机甲模式（CHOOSE_MANY_MECHS）
	_mech_multi_select_opts = {}

## 多目标攻击选择：处理机甲点击（toggle 加入/移除）或陷阱点击（单目标提交）
func _multi_attack_target_handle_click(hex: Dictionary, target_id: StringName, wait_info: Dictionary) -> void:
	var attacker_id: StringName = StringName(wait_info.get("input_params", {}).get("attacker_id", &""))
	# pilot_019 缴械冲击：无陷阱目标，空格点击仅提示（跳过陷阱单目标提交路径）
	var p019_ui_mode: bool = String(wait_info.get("input_params", {}).get("target_kind", &"")) == "pilot_019"
	# 陷阱目标（多选模式下点陷阱=单目标攻击，立即提交，不进入多目标流程）
	if target_id == &"":
		if not p019_ui_mode:
			var sat_q := int(hex.get("q", 0))
			var sat_r := int(hex.get("r", 0))
			if battle.context and battle.context.game_state:
				for m in battle.context.game_state.map_state.get_markers_at(sat_q, sat_r):
					if m.get("type", &"") == &"TRAP":
						_clear_attack_highlights()
						_net_exec("ui_confirmed", {"data": {
							"target_id": m.get("marker_id", &""),
							"target_is_trap": true,
							"target_trap_q": sat_q,
							"target_trap_r": sat_r,
						}})
						return
		battle.log.append({"message": "该格无可攻击机甲；点击红色闪烁格内的机甲选择目标，或点取消用已选目标继续", "details": {}})
		_request_refresh()
		return
	# 不可选攻击方自己
	if target_id == attacker_id:
		battle.log.append({"message": "不可选择攻击方自己作为目标", "details": {}})
		_request_refresh()
		return
	# 切换：已选则取消，未选则加入（不超过目标数上限）
	var existing := -1
	for i in range(_multi_attack_target_chosen.size()):
		if StringName(_multi_attack_target_chosen[i].get("target_id", "")) == target_id:
			existing = i
			break
	if existing >= 0:
		_multi_attack_target_chosen.remove_at(existing)
	else:
		if _multi_attack_target_chosen.size() >= _multi_attack_target_count:
			battle.log.append({"message": "已达最大目标数 %d，请点取消继续，或点已选机甲取消后重选" % _multi_attack_target_count, "details": {}})
			_request_refresh()
			return
		_multi_attack_target_chosen.append({"q": int(hex.get("q", 0)), "r": int(hex.get("r", 0)), "target_id": String(target_id)})
	# 选满自动提交（通用多选机甲带 action_id 精确路由，弥雅 p071 等）
	if _multi_attack_target_chosen.size() >= _multi_attack_target_count:
		_submit_multi_attack_targets(StringName(_mech_multi_select_opts.get("action_id", &"")))
		return
	# 未选满：刷新序号标记 + 提示
	_refresh_multi_attack_marks()
	battle.log.append({"message": "已选 %d/%d 台目标；继续点击机甲，或点取消开始攻击" % [_multi_attack_target_chosen.size(), _multi_attack_target_count], "details": {}})
	_request_refresh()

## 刷新多目标序号标记（battle_board 上画 1/2/3...）
func _refresh_multi_attack_marks() -> void:
	if battle_board:
		battle_board.set_multi_target_marks(_multi_attack_target_chosen)

## 提交多目标攻击选择（target_ids 数组）
## precise_action_id 非空=通用多选机甲（CHOOSE_MANY_MECHS，弥雅 p071 回合后选机甲等）：
## 带 action_id 走 resume_effect 精确路由，绕过共享等待槽（_waiting_action_id）——效果挂起后
## 可能被后续时点弹窗覆盖（p049 家族），按共享槽恢复会指向错误动作致"选了没反应"。
## 攻击多目标（双连，无 precise_action_id）仍走 ui_confirmed 共享槽恢复攻击动作。
func _submit_multi_attack_targets(precise_action_id: StringName = &"") -> void:
	var target_ids: Array = []
	for c in _multi_attack_target_chosen:
		target_ids.append(StringName(c.get("target_id", "")))
	_clear_attack_highlights()
	if precise_action_id != &"":
		_net_exec("resume_effect", {"action_id": precise_action_id, "data": {"target_ids": target_ids}})
		return
	_net_exec("ui_confirmed", {"data": {"target_ids": target_ids}})

## 刷新机雷设陷选格高亮：仅高亮剩余可放格（已选格已从 _map_cell_select_valid 移除->不可再选）
func _refresh_map_cell_highlight() -> void:
	if battle_board == null:
		return
	var hexes: Array[Dictionary] = []
	for c in _map_cell_select_valid:
		hexes.append({"q": int(c.get("q", 0)), "r": int(c.get("r", 0))})
	battle_board.highlight_hexes(hexes)

## 尝试攻击目标
## 新动作系统下，攻击目标选择由 ActionUIBridge 驱动（_on_battle_hex_clicked 已在
## select_attack_target 时回填 on_ui_confirmed({"target_id":...})）。本函数仅作
## 旧入口兼容兜底：若 ActionUIBridge 正在等待 select_attack_target，回填目标；
## 否则不再走旧 execute_attack_action 流程（避免产生重复的独立攻击动作 action_5）。
func _try_attack_target(hex: Dictionary) -> void:
	if battle == null or battle.context == null:
		return

	# 新动作系统：回填攻击目标选择
	if battle.context.action_ui_bridge:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if wait_info.get("input_type", &"") == &"select_attack_target":
			var target_id: StringName = _find_mech_at_hex(hex)
			if target_id != &"":
				_net_exec("ui_confirmed", {"data": {"target_id": target_id}})
			else:
				battle.log.append({"message": "该位置无敌方机甲", "details": {}})
				_request_refresh()
			return

	# 旧 attack_flow 入口已废弃，不再调用 battle.execute_attack_action
	battle.log.append({"message": "攻击目标选择已由新动作系统接管", "details": {}})
	_request_refresh()

## 处理攻击结算结果
func _handle_attack_result(result: Dictionary) -> void:
	if not result.get("hit", false):
		battle.log.append({"message": "攻击未命中", "details": result})
		_request_refresh()
		return

	var damage: int = int(result.get("damage", 0))
	var markers: int = int(result.get("markers", 0))
	battle.log.append({"message": "攻击命中！伤害: %d 损伤: %d" % [damage, markers], "details": result})

	if markers > 0:
		var chooser: StringName = result.get("chooser_player_id", &"")
		var target_mech: StringName = result.get("target_mech_id_for_tokens", &"")

		if _is_human_player_id(chooser):
			# 玩家选择损伤放置
			attack_flow.enter_damage_placement(target_mech, markers, chooser)
			damage_placement_panel.configure(battle.context, target_mech, markers)
			damage_placement_panel.visible = true
		else:
			# AI 自动放置
			battle.auto_place_damage_tokens(target_mech, markers)

	_request_refresh()

## 损伤调整面板（薇尔 pilot_059）：玩家选择移除/设置1损伤
func _on_damage_adjust_chosen(slot_id: StringName, is_set: bool) -> void:
	var adj_action_id: StringName = _damage_adjust_action_id
	_damage_adjust_action_id = &""
	_dismiss_popup_panel(damage_adjust_panel)
	if adj_action_id != &"":
		_net_exec("resume_effect", {"action_id": adj_action_id, "data": {"choice": ("set" if is_set else "remove"), "slot_id": slot_id}})
	_request_refresh()

## 损伤调整面板（薇尔 pilot_059）：玩家取消调整
func _on_damage_adjust_cancelled() -> void:
	var adj_action_id: StringName = _damage_adjust_action_id
	_damage_adjust_action_id = &""
	_dismiss_popup_panel(damage_adjust_panel)
	if adj_action_id != &"":
		_net_exec("resume_effect", {"action_id": adj_action_id, "data": {"choice": "cancel"}})
	_request_refresh()

## 瓦恩武器修改选项面板（pilot_083）：玩家确认施加打包状态（name_suffix/type_override/might/range）
func _on_p083_options_confirmed(payload: Dictionary) -> void:
	var p083_action_id: StringName = _p083_options_action_id
	_p083_options_action_id = &""
	_dismiss_popup_panel(weapon_modify_options_panel)
	if p083_action_id != &"":
		_net_exec("resume_effect", {"action_id": p083_action_id, "data": {"options": payload}})
	_refresh_panels_only()

## 瓦恩武器修改选项面板（pilot_083）：玩家取消（不施加，owner 不耗次数；re RE 已耗不退）
func _on_p083_options_cancelled() -> void:
	var p083_action_id: StringName = _p083_options_action_id
	_p083_options_action_id = &""
	_dismiss_popup_panel(weapon_modify_options_panel)
	if p083_action_id != &"":
		_net_exec("resume_effect", {"action_id": p083_action_id, "data": {"cancelled": true}})
	_refresh_panels_only()

## 损伤放置完成回调
func _on_damage_placement_completed() -> void:
	var dp_action_id: StringName = _damage_placement_action_id
	_damage_placement_action_id = &""
	_dismiss_popup_panel(damage_placement_panel)
	var resolved: bool = false
	if battle and battle.context:
		# 优先用面板记录的 damage_change 动作 ID 直接恢复（避免被并发的装备离场效果弹窗
		# 覆盖 ActionUIBridge 单一等待动作槽，导致 damage_change 不结算、攻击牌卡临时区）。
		if dp_action_id != &"":
			_net_exec("damage_placement_done", {"action_id": dp_action_id})
			resolved = true
		else:
			# 退路：无记录动作 ID，走原 ui_confirmed 路径（依赖共享等待槽）
			if battle.context.action_ui_bridge:
				var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
				if wait_info.get("input_type", &"") == &"place_damage_tokens":
					_net_exec("ui_confirmed", {"data": {"placed": true}})
					resolved = true
	# 恢复被挂起的损伤放置面板（攻击损伤设置被效果移除损伤打断后的续操作）：
	# restore 攻击面板状态+动作ID+目标机甲，重新显示让玩家继续放剩余 token。
	# 完成后 resolve 攻击 damage_change -> 攻击结算 -> 反击弹出。
	if not _damage_suspend_stack.is_empty():
		var ctx: Dictionary = _damage_suspend_stack.pop_back()
		if damage_placement_panel and is_instance_valid(damage_placement_panel):
			damage_placement_panel.resume_state(ctx.get("state", {}))
			_damage_placement_action_id = ctx.get("action_id", &"")
			_damage_placement_target_mech_id = ctx.get("target_mech_id", &"")
			_present_popup(&"damage_token_placement", damage_placement_panel)
		return
	if resolved:
		return
	# 旧链路已废弃：不再走 attack_flow / _last_player_attack_result / _maybe_trigger_ai_counterattack
	_request_refresh()
	_finish_battle_if_needed()


## 锁步损伤放置：每点一个槽位走 damage_place op 双端应用
func _on_damage_token_placed(slot_id: StringName) -> void:
	_net_exec("damage_place", {"slot_id": slot_id, "target_mech_id": _damage_placement_target_mech_id})

## 锁步损伤移除：每点一个槽位走 damage_remove op 双端应用
func _on_damage_token_removed(slot_id: StringName) -> void:
	_net_exec("damage_remove", {"slot_id": slot_id, "target_mech_id": _damage_placement_target_mech_id})

## 效果选择完成回调
func _on_choice_made(effect_id: StringName) -> void:
	# ── 铠威攻击窗口触发确认（accept=抽1张行动牌并立即攻击 / cancel=不抽结束）──
	# 需在 wait_info 桥接处理之前：确认框非 ActionUIBridge 输入，且窗口提示时无等待输入。
	if effect_id == &"__attack_window_accept__" or effect_id == &"__attack_window_cancel__":
		if battle and battle.context and battle.context.game_state:
			var aw_pending: Dictionary = battle.context.game_state.attack_window_pending_prompt
			if not aw_pending.is_empty() and String(aw_pending.get("player_id", &"")) == String(local_player_id):
				var aw_pid: StringName = aw_pending.get("player_id", &"")
				var aw_mid: StringName = aw_pending.get("mech_id", &"")
				if choice_panel:
					choice_panel.visible = false
				_attack_window_prompt_showing = false
				_net_exec("attack_window_confirm", {"player_id": aw_pid, "mech_id": aw_mid, "accept": effect_id == &"__attack_window_accept__"})
				return
	# ── 铠厉通用「被响应→抽2装备设置/弃置获金」触发确认（accept=抽2并逐张设置/弃置获金 / cancel=不发动）──
	# 需在 wait_info 桥接处理之前：确认框非 ActionUIBridge 输入，且触发提示时无等待输入。
	if effect_id == &"__responded_equip_accept__" or effect_id == &"__responded_equip_cancel__":
		if battle and battle.context and battle.context.game_state:
			var re_pending: Dictionary = battle.context.game_state.responded_equip_pending_confirm
			if not re_pending.is_empty() and String(re_pending.get("player_id", &"")) == String(local_player_id):
				var re_pid: StringName = re_pending.get("player_id", &"")
				var re_mid: StringName = re_pending.get("mech_id", &"")
				if choice_panel:
					choice_panel.visible = false
				_responded_equip_prompt_showing = false
				_net_exec("responded_equip_confirm", {"player_id": re_pid, "mech_id": re_mid, "accept": effect_id == &"__responded_equip_accept__"})
				return
	# ── 铠德「被响应→三选一」（choice_0=抽2行动/choice_1=回3动力/choice_2=获4金）──
	# 独立 if（不嵌套在铠威分支内）：三选一框非 ActionUIBridge 输入，且触发提示时无等待输入。
	# 需在 wait_info 桥接处理之前，避免被当作效果选择输入误转发。
	if effect_id == &"__pilot_060_choice_0__" or effect_id == &"__pilot_060_choice_1__" or effect_id == &"__pilot_060_choice_2__":
		if battle and battle.context and battle.context.game_state:
			var p60_pending: Dictionary = battle.context.game_state.pilot_060_pending_choice
			if not p60_pending.is_empty() and String(p60_pending.get("player_id", &"")) == String(local_player_id):
				var p60_pid: StringName = p60_pending.get("player_id", &"")
				var p60_mid: StringName = p60_pending.get("mech_id", &"")
				if choice_panel:
					choice_panel.visible = false
				_pilot_060_prompt_showing = false
				var p60_choice: int = 0
				if effect_id == &"__pilot_060_choice_1__":
					p60_choice = 1
				elif effect_id == &"__pilot_060_choice_2__":
					p60_choice = 2
				_net_exec("pilot_060_choice", {"player_id": p60_pid, "mech_id": p60_mid, "choice": p60_choice})
				return
	# ── effect_choice（choose_one_effect 二选一/确认）：优先按弹窗打开时捕获的 action_id 精确路由 ──
	# 共享等待槽是单槽：并发挂起（如杰狞伤害转移弹窗+损伤放置弹窗）时后者覆盖前者，槽内
	# input_type 已不是 effect_choice，旧共享槽路径会错路由/丢输入 -> hp_change 永久挂起、
	# 攻击不结算（bug1）。仅当 effect_choice 弹窗仍在模态栈顶（用户点的就是它）时使用捕获路由，
	# 其他 choice_panel 弹窗后弹置顶时各走各自分支；无捕获（异常）回退下方共享槽路径。
	if _effect_choice_action_id != &"" and not _popup_stack.is_empty() \
			and String(_popup_stack.back().get("popup_type", "")) == "effect_choice":
		if choice_panel:
			choice_panel.visible = false
		var ec_aid: StringName = _effect_choice_action_id
		var ec_opts: Array = _effect_choice_options
		_effect_choice_action_id = &""
		_effect_choice_options = []
		var ec_idx: int = -1
		for i in range(ec_opts.size()):
			var ec_opt: Dictionary = ec_opts[i] if ec_opts[i] is Dictionary else {}
			if String(ec_opt.get("effect_id", &"")) == String(effect_id):
				ec_idx = int(ec_opt.get("option_index", i))
				break
		if ec_idx < 0:
			# 兜底：effect_id 形如 "option_N"
			var ec_es := String(effect_id)
			if ec_es.begins_with("option_"):
				ec_idx = ec_es.substr(7).to_int()
		var ec_data: Dictionary = {"chosen_effect_id": effect_id, "confirmed": true}
		if ec_idx >= 0:
			ec_data["chosen_option_index"] = ec_idx
		_net_exec("resume_effect", {"action_id": ec_aid, "data": ec_data})
		return
	# ── 新动作系统：如果正在等待选择输入，反馈给ActionUIBridge ──
	if battle and battle.context and battle.context.action_ui_bridge:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if not wait_info.is_empty():
			var input_type: StringName = wait_info.get("input_type", &"")
			if input_type == &"use_card_confirm" or input_type == &"choose_one":
				_net_exec("ui_confirmed", {"data": {"chosen_effect_id": effect_id, "confirmed": true}})
				return
			if input_type == &"choose_one_effect" or input_type == &"effect_choice":
				# 维修二选一：把选项 effect_id(option_N) 映射回 option_index，回填给 TimingEngine 续跑
				# 立即隐藏 choice_panel：否则动作完成后 _on_action_completed 只清全局取消按钮，
				# 二选一弹窗残留致玩家误以为未生效、需再点一次确认（"取消消失但要再点一次"bug）。
				if choice_panel:
					choice_panel.visible = false
				var idx: int = -1
				var options: Array = wait_info.get("input_params", {}).get("options", [])
				for i in range(options.size()):
					var opt: Dictionary = options[i] if options[i] is Dictionary else {}
					if String(opt.get("effect_id", &"")) == String(effect_id):
						idx = int(opt.get("option_index", i))
						break
				if idx < 0:
					# 兜底：effect_id 形如 "option_N"
					var es := String(effect_id)
					if es.begins_with("option_"):
						idx = es.substr(7).to_int()
				# 引擎级挂起（_pending_effect）的效果确认：按 action_id 精确路由（resume_effect）。
				# 对端槽被 skip_remote_waiting 清空后共享槽 ui_confirmed 早 return 丢输入->三方卡死
				#（同骇客窥牌根因）。无捕获回退原共享槽路径。主路径（_effect_choice_action_id 捕获）见 6088。
				var co_aid: StringName = StringName(wait_info.get("action_id", &""))
				if co_aid != &"":
					var co_data: Dictionary = {"chosen_effect_id": effect_id, "confirmed": true}
					if idx >= 0:
						co_data["chosen_option_index"] = idx
					_net_exec("resume_effect", {"action_id": co_aid, "data": co_data})
				elif idx >= 0:
					_net_exec("ui_confirmed", {"data": {"chosen_option_index": idx, "chosen_effect_id": effect_id, "confirmed": true}})
				else:
					_net_exec("ui_confirmed", {"data": {"chosen_effect_id": effect_id, "confirmed": true}})
				return
			if input_type == &"choose_integer":
				# 金币换动力整数选择（effect_040/041）：解析 __int_N__ 回填 chosen_value
				var es_ci := String(effect_id)
				if choice_panel:
					choice_panel.visible = false
				if stepper_panel:
					stepper_panel.visible = false
				if es_ci.begins_with("__int_") and es_ci.ends_with("__"):
					var n_ci: int = es_ci.substr(6, es_ci.length() - 8).to_int()
					var ci_aid: StringName = StringName(wait_info.get("action_id", &""))
					if ci_aid != &"":
						_net_exec("resume_effect", {"action_id": ci_aid, "data": {"chosen_value": n_ci, "confirmed": true}})
					else:
						_net_exec("ui_confirmed", {"data": {"chosen_value": n_ci, "confirmed": true}})
				else:
					var ci_aid2: StringName = StringName(wait_info.get("action_id", &""))
					if ci_aid2 != &"":
						_net_exec("resume_effect", {"action_id": ci_aid2, "data": {"cancelled": true}})
					else:
						_net_exec("ui_confirmed", {"data": {"cancelled": true}})
				return
			if input_type == &"redirect_select":
				# 损伤转移：把选中的档位 effect_id(__redirect_N__) 解析为转移点数，构造 redirect_plan 回填
				if bool(_redirect_context.get("all_or_nothing", false)):
					# 盾牌 all_or_nothing：__redirect_confirm__=转移全部(transfer 点+减伤吸收)，__redirect_cancel__=不转移
					var ao_plan: Array = []
					var ao_confirmed: bool = (effect_id == &"__redirect_confirm__")
					if ao_confirmed:
						var ao_transfer: int = int(_redirect_context.get("transfer", 0))
						if ao_transfer > 0:
							ao_plan = [{"to_mech_id": _redirect_context.get("mech_id", &""), "to_slot_id": _redirect_context.get("to_slot", &""), "count": ao_transfer}]
					_redirect_context = {}
					if choice_panel:
						choice_panel.visible = false
					var rd_ao_aid: StringName = StringName(wait_info.get("action_id", &""))
					if rd_ao_aid != &"":
						_net_exec("resume_effect", {"action_id": rd_ao_aid, "data": {"redirect_plan": ao_plan, "all_or_nothing_confirmed": ao_confirmed}})
					else:
						_net_exec("ui_confirmed", {"data": {"redirect_plan": ao_plan, "all_or_nothing_confirmed": ao_confirmed}})
					return
				var es := String(effect_id)
				var n: int = 0
				if es.begins_with("__redirect_") and es.ends_with("__"):
					n = es.substr(11, es.length() - 13).to_int()
				var plan: Array = []
				if n > 0 and not _redirect_context.is_empty():
					plan = [{"to_mech_id": _redirect_context.get("mech_id", &""), "to_slot_id": _redirect_context.get("to_slot", &""), "count": n}]
				_redirect_context = {}
				if choice_panel:
					choice_panel.visible = false
				var rd_aid: StringName = StringName(wait_info.get("action_id", &""))
				if rd_aid != &"":
					_net_exec("resume_effect", {"action_id": rd_aid, "data": {"redirect_plan": plan}})
				else:
					_net_exec("ui_confirmed", {"data": {"redirect_plan": plan}})
				return
			if input_type == &"pilot_014_target_select":
				# pilot_014 亚伦选机师牌：effect_id=选中机师牌 instance_id，回查 option 取 player_id/mech_id。
				if choice_panel:
					choice_panel.visible = false
				var p014_target: StringName = effect_id
				var p014_pid: StringName = &""
				var p014_mid: StringName = &""
				for opt in _pilot_014_select_options:
					var od: Dictionary = opt if opt is Dictionary else {}
					if String(od.get("pilot_instance", &"")) == String(p014_target) or String(od.get("effect_id", &"")) == String(p014_target):
						p014_pid = od.get("player_id", &"")
						p014_mid = od.get("mech_id", &"")
						break
				_pilot_014_select_options = []
				var p14_aid: StringName = StringName(wait_info.get("action_id", &""))
				if p14_aid != &"":
					_net_exec("resume_effect", {"action_id": p14_aid, "data": {"pilot_014_target_pilot": p014_target, "pilot_014_player_id": p014_pid, "pilot_014_mech_id": p014_mid, "confirmed": true}})
				else:
					_net_exec("ui_confirmed", {"data": {"pilot_014_target_pilot": p014_target, "pilot_014_player_id": p014_pid, "pilot_014_mech_id": p014_mid, "confirmed": true}})
				return
			if input_type == &"pilot_088_type_select":
				# pilot_088 征服宣言类型三选一（攻击/迎击/辅助，不可取消）：effect_id 即选项中的
				# effect_id（type_攻击/迎击/辅助），回查 _pilot_088_type_options 取 declared_type 回填。
				if choice_panel:
					choice_panel.visible = false
				var p088_declared: String = ""
				for opt in _pilot_088_type_options:
					var od: Dictionary = opt if opt is Dictionary else {}
					if String(od.get("effect_id", &"")) == String(effect_id):
						p088_declared = String(od.get("declared_type", ""))
						break
				_pilot_088_type_options = []
				var p88_aid: StringName = StringName(wait_info.get("action_id", &""))
				if p88_aid != &"":
					_net_exec("resume_effect", {"action_id": p88_aid, "data": {"pilot_088_declared_type": p088_declared, "confirmed": true}})
				else:
					_net_exec("ui_confirmed", {"data": {"pilot_088_declared_type": p088_declared, "confirmed": true}})
				return
			if input_type == &"pilot_032_target_select":
				# pilot_032 爱瑞娅选机师牌：effect_id=选中机师牌 instance_id，回查 option 取 player_id/mech_id。
				if choice_panel:
					choice_panel.visible = false
				var p032_target: StringName = effect_id
				var p032_pid: StringName = &""
				var p032_mid: StringName = &""
				for opt in _pilot_032_select_options:
					var od: Dictionary = opt if opt is Dictionary else {}
					if String(od.get("pilot_instance", &"")) == String(p032_target) or String(od.get("effect_id", &"")) == String(p032_target):
						p032_pid = od.get("player_id", &"")
						p032_mid = od.get("mech_id", &"")
						break
				_pilot_032_select_options = []
				var p32_aid: StringName = StringName(wait_info.get("action_id", &""))
				if p32_aid != &"":
					_net_exec("resume_effect", {"action_id": p32_aid, "data": {"pilot_032_target_pilot": p032_target, "pilot_032_player_id": p032_pid, "pilot_032_mech_id": p032_mid, "confirmed": true}})
				else:
					_net_exec("ui_confirmed", {"data": {"pilot_032_target_pilot": p032_target, "pilot_032_player_id": p032_pid, "pilot_032_mech_id": p032_mid, "confirmed": true}})
				return
			if input_type == &"pilot_018_select_equipment":
				# pilot_018 苔丝弃装备牌：effect_id=选中装备牌 instance_id，走 resume_pending_effect 回填。
				if choice_panel:
					choice_panel.visible = false
				var p018_eq_cid: StringName = effect_id
				_pilot_018_select_options = []
				var p018_action_id: StringName = wait_info.get("input_params", {}).get("action_id", &"")
				_net_exec("resume_effect", {"action_id": p018_action_id, "data": {"selected_card_id": p018_eq_cid}})
				return
			if input_type == &"pilot_025_reserve_select":
				# pilot_025 约书亚 1b 选备用装备：effect_id=选中装备牌 instance_id，走 resume_pending_effect 回填。
				if choice_panel:
					choice_panel.visible = false
				var p025_rv_cid: StringName = effect_id
				var p025_rv_action_id: StringName = wait_info.get("input_params", {}).get("action_id", &"")
				_net_exec("resume_effect", {"action_id": p025_rv_action_id, "data": {"selected_card_id": p025_rv_cid}})
				return
			if input_type == &"hidden_reserve_slot":
				# 通用「查看隐藏装备」Phase B：effect_id="mech_id:slot_id"，解码后回填目标备用槽。
				# 强制选择不可取消（allow_cancel=false）；无效目标由 TimingEngine 中止（不扣金）。
				if choice_panel:
					choice_panel.visible = false
				var hrv_es := String(effect_id)
				var hrv_colon: int = hrv_es.find(":")
				var hrv_tmid: StringName = hrv_es.substr(0, hrv_colon) if hrv_colon >= 0 else ""
				var hrv_tsid: StringName = hrv_es.substr(hrv_colon + 1) if hrv_colon >= 0 else ""
				var hrv_action_id: StringName = wait_info.get("input_params", {}).get("action_id", &"")
				_net_exec("resume_effect", {"action_id": hrv_action_id, "data": {"target_mech_id": hrv_tmid, "target_slot_id": hrv_tsid, "confirmed": true}})
				return

	# ── 行动牌确认对话框处理 ──
	if _choice_select_card_id != &"":
		if effect_id == &"__confirm_use_action_card__":
			var card_id = _choice_select_card_id
			_choice_select_card_id = &""
			choice_panel.visible = false
			if battle and battle.context:
				var result: Variant = _net_exec("play_action_card", {"player_id": local_player_id, "card_instance_id": card_id})
				if result is Dictionary and not result.get("ok", false):
					battle.log.append({"message": "使用失败: %s" % String(result.get("message", "")), "details": {}})
			return
		elif effect_id == &"__cancel_use_action_card__":
			# 用户取消使用
			_choice_select_card_id = &""
			choice_panel.visible = false
			battle.log.append({"message": "取消使用行动牌", "details": {}})
			_request_refresh()
			return
		elif effect_id == &"__unite_use__":
			# 联合：使用联合效果（走正常 use_action_card，执行 effect1：选其他机甲施加联合状态）
			var u_card_id = _choice_select_card_id
			_choice_select_card_id = &""
			choice_panel.visible = false
			if battle and battle.context:
				var u_result: Variant = _net_exec("play_action_card", {"player_id": local_player_id, "card_instance_id": u_card_id})
				if u_result is Dictionary and not u_result.get("ok", false):
					battle.log.append({"message": "使用失败: %s" % String(u_result.get("message", "")), "details": {}})
			return
		elif effect_id == &"__unite_discard_draw__":
			# 联合效果2：弃置此牌（仍在手牌）+ 抽1张行动牌，不走 use_action_card
			var dd_card_id = _choice_select_card_id
			_choice_select_card_id = &""
			choice_panel.visible = false
			_net_exec("unite_discard_draw", {"player_id": local_player_id, "card_instance_id": dd_card_id})
			return
		elif effect_id == &"__unite_cancel__":
			_choice_select_card_id = &""
			choice_panel.visible = false
			battle.log.append({"message": "取消使用联合", "details": {}})
			_request_refresh()
			return

	# ── 商店购买三选项处理 ──
	if not _shop_buy_pending.is_empty():
		var pending: Dictionary = _shop_buy_pending
		_shop_buy_pending = {}
		if choice_panel:
			choice_panel.visible = false
		if effect_id == &"__shop_buy_confirm__" or effect_id == &"__shop_buy_discount__" or effect_id == &"__shop_buy_pilot_original__":
			_net_exec("shop_buy", {
				"player_id": local_player_id,
				"kind": String(pending.get("kind", &"")),
				"slot_index": int(pending.get("slot_index", 0)),
				"discount": effect_id == &"__shop_buy_discount__",
				"pilot_original": effect_id == &"__shop_buy_pilot_original__",
			})
		# __shop_buy_cancel__: 无操作
		if shop_panel:
			shop_panel.configure(battle.context)
		return

	if choice_panel:
		choice_panel.visible = false

	battle.log.append({"message": "收到选择, _sell_mode_active=%s, effect_id=%s" % [_sell_mode_active, effect_id], "details": {}})

	# 卖出模式
	if _sell_mode_active:
		_sell_mode_active = false

		battle.log.append({"message": "卖出模式处理中, effect_id=%s" % String(effect_id), "details": {}})

		# 直接执行卖出，不做检查
		var card_id = effect_id
		battle.log.append({"message": "调用sell_equipment, card_id=%s" % String(card_id), "details": {}})

		var result = battle.context.card_set_service.sell_equipment(&"player", card_id)
		SLog.log_call("app_root", "sell_equipment", {"player": "player", "card_id": String(card_id)}, result)

		battle.log.append({"message": "sell_equipment结果: %s" % result, "details": {}})

		if result.get("ok", false):
			var gold = result.get("gold_earned", 0)
			battle.log.append({"message": "卖出装备获得 %d 金币" % gold, "details": {}})
		else:
			battle.log.append({"message": "卖出失败: %s" % result.get("message", ""), "details": {}})

		_request_refresh()
		return

	# 设置模式
	if _set_equipment_card_id != &"":
		var slot_id = effect_id
		var card_id = _set_equipment_card_id
		_set_equipment_card_id = &""
		if slot_id != &"" and slot_id != "":
			_do_set_equipment(card_id, slot_id)
		else:
			_request_refresh()
		return

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
		_request_refresh()
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
	# 必须在隐藏面板之前判定 effect_choice 精确路由：choice_panel.visible=false 会同步触发
	# _on_popup_visibility_changed -> _pop_popup_entry 弹出弹窗栈，之后再查 _popup_stack.back()
	# 恒不命中（死代码），effect_choice 取消会退化为无向 ui_cancelled——该 op 只在槽位恰好
	# 持有该动作的一端落地，其余端槽位已被 skip_remote_waiting 清空而静默丢弃 -> 拦截动作
	# 在其余端永久挂起 + 动作 id 发散 -> PvP3 实机对端完全卡死无弹窗（0827 根因①）。
	# 顺序与 _on_choice_made（确认路径）保持一致：先查栈、后隐藏。
	var ecc_cancel_aid: StringName = &""
	if _effect_choice_action_id != &"" and not _popup_stack.is_empty() \
			and String(_popup_stack.back().get("popup_type", "")) == "effect_choice":
		ecc_cancel_aid = _effect_choice_action_id
	if choice_panel:
		choice_panel.visible = false
	if stepper_panel:
		stepper_panel.visible = false
	# 铠威攻击窗口确认框底部「取消」：视为「不抽，结束」，双端执行 attack_window_confirm(accept=false)
	# 清 pending 保持锁步。此前仅清本地展示标记，下一帧 _maybe_update_attack_window_ui 重弹造成
	# 「一直卡住只能点取消」的循环卡死。
	if _attack_window_prompt_showing:
		_attack_window_prompt_showing = false
		if battle and battle.context and battle.context.game_state:
			var aw_cancel_pending: Dictionary = battle.context.game_state.attack_window_pending_prompt
			if not aw_cancel_pending.is_empty() and String(aw_cancel_pending.get("player_id", &"")) == String(local_player_id):
				_net_exec("attack_window_confirm", {
					"player_id": aw_cancel_pending.get("player_id", &""),
					"mech_id": aw_cancel_pending.get("mech_id", &""),
					"accept": false,
				})
				return
	# 铠德「被响应→三选一」框被外部关闭（未选分支，点底部「取消」）：视为放弃（choice=-1），
	# 双端执行清 pending 保持锁步（不选任何奖励，后续触发继续处理）。
	if _pilot_060_prompt_showing:
		_pilot_060_prompt_showing = false
		if battle and battle.context and battle.context.game_state:
			var p60_pending: Dictionary = battle.context.game_state.pilot_060_pending_choice
			if not p60_pending.is_empty() and String(p60_pending.get("player_id", &"")) == String(local_player_id):
				_net_exec("pilot_060_choice", {"player_id": p60_pending.get("player_id", &""), "mech_id": p60_pending.get("mech_id", &""), "choice": -1})
		return

	# 损伤转移取消（A6）：不转移，回填空 redirect_plan
	if not _redirect_context.is_empty():
		_redirect_context = {}
		if battle and battle.context and battle.context.action_ui_bridge:
			var rd_cancel_wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
			var rd_cancel_aid: StringName = StringName(rd_cancel_wait.get("action_id", &""))
			if rd_cancel_aid != &"":
				_net_exec("resume_effect", {"action_id": rd_cancel_aid, "data": {"redirect_plan": []}})
			else:
				_net_exec("ui_confirmed", {"data": {"redirect_plan": []}})
		return

	# effect_choice（choose_one_effect）弹窗取消：按隐藏前捕获的 action_id 精确路由（bug1，
	# 同 _on_choice_made 的捕获路由：共享槽被并发挂起覆盖时 ui_cancelled 会错取消别的动作）。
	# resume_effect 按动作 id 定向，三端的 _pending_effect 都持有该动作 -> 全端一致取消，锁步保持。
	if ecc_cancel_aid != &"":
		_effect_choice_action_id = &""
		_effect_choice_options = []
		_net_exec("resume_effect", {"action_id": ecc_cancel_aid, "data": {"cancelled": true}})
		return

	# 效果二选一/确认/整数选择弹窗取消（如联邦左腿 effect_007「弃牌减损伤」取消）：
	# 必须回填 cancelled 让 TimingEngine.resume_pending_effect 跳过该效果并恢复父动作（攻击）继续结算，
	# 否则父动作永远停在 waiting_timing、攻击牌滞留临时区到回合结束（bug1b）。
	# ui_cancelled 经 _apply_action_cancel -> resume_pending_effect({cancelled:true})，攻击继续到放置损伤。
	if battle and battle.context and battle.context.action_ui_bridge:
		var wi: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if not wi.is_empty():
			var it: StringName = wi.get("input_type", &"")
			if it == &"choose_one_effect" or it == &"effect_choice" or it == &"choose_one" \
				or it == &"use_card_confirm" or it == &"confirm_use_card" or it == &"choose_integer" \
				or it == &"pilot_014_target_select" or it == &"pilot_025_reserve_select" or it == &"pilot_032_target_select" \
				or it == &"pilot_088_type_select":
				_pilot_014_select_options = []
				_pilot_032_select_options = []
				_pilot_088_type_options = []
				# 引擎级挂起（_pending_effect）的效果取消：按 action_id 精确路由带 cancelled=true
				#（同确认路径根因：共享槽 ui_cancelled 在对端被 skip_remote_waiting 清槽后
				# 早 return 丢输入 -> 对端停在挂起三方卡死）。无挂起回退原共享槽路径。
				var _cc_aid: StringName = StringName(wi.get("action_id", &""))
				if _cc_aid != &"" and battle.context.timing_engine.has_pending_effect(_cc_aid):
					_net_exec("resume_effect", {"action_id": _cc_aid, "data": {"cancelled": true}})
				else:
					_net_exec("ui_cancelled", {})
				return

	# 卖出模式取消
	if _sell_mode_active:
		_sell_mode_active = false
		_request_refresh()
		return

	# 设置模式取消
	if _set_equipment_card_id != &"":
		# 如果是从备用区拿出来设置的装备，需要处理
		var gs = battle.context.game_state
		var mech = gs.get_mech_for_player(&"player")
		var player = gs.players.get(&"player")
		if mech and player:
			# 检查装备是否在玩家手牌中（从备用区拿出来的情况）
			if player.equipment_hand.has(_set_equipment_card_id):
				# 找到这张牌是从哪个备用区拿出来的，归还回去
				# 暂时简单处理：不做处理，让它留在手牌中
				pass
		_set_equipment_card_id = &""
		_request_refresh()
		return

	# 反击提示取消 → 视为不发动
	if _counterattack_prompt_active:
		_skip_player_counterattack()
		return
	_choice_select_card_id = &""
	_repair_selected_target_mech_id = &""
	_repair_target_select_card_id = &""

## 通用「查看隐藏装备」Phase A：花费获取某候选牌 → resume_pending_effect 回填 selected_card_id。
## 面板信号（hidden_card_view_panel.acquire_clicked）。
func _on_hidden_view_acquire(card_id: StringName) -> void:
	# 先取走 id 再隐藏面板：visible=false 同步发 popup_hide -> _on_hidden_view_popup_hidden，
	# 若它先跑会把 id 抢走按取消恢复（bug3 修复配套顺序）。
	var hva_action_id: StringName = _hidden_view_action_id
	_hidden_view_action_id = &""
	if hidden_card_view_panel:
		hidden_card_view_panel.visible = false
	if hva_action_id != &"":
		_net_exec("resume_effect", {"action_id": hva_action_id, "data": {"selected_card_id": card_id}})

## 通用「查看隐藏装备」Phase A：关闭面板（取消效果，可反复再点）→ resume_pending_effect 回填 cancelled。
func _on_hidden_view_cancelled() -> void:
	# 同样先取 id 再隐藏面板（popup_hide 同步双发时第二跑见空 id 幂等空转）。
	var hvc_action_id: StringName = _hidden_view_action_id
	_hidden_view_action_id = &""
	if hidden_card_view_panel:
		hidden_card_view_panel.visible = false
	if hvc_action_id != &"":
		_net_exec("resume_effect", {"action_id": hvc_action_id, "data": {"cancelled": true}})

## 隐藏装备面板被非按钮路径关闭（点弹窗外/Esc 等）的兜底：popup_hide -> 守卫式取消。
## 模态堆栈隐藏下层面板（_popup_suppress_vis 期间）非用户关闭，跳过；
## id 已被 acquire/cancelled 取走时幂等空转。修复：动作残留 + 共享等待槽不清 ->
## 所有主动效果按钮置灰（bug3 霍恩「按钮不能再重复点击」）。
func _on_hidden_view_popup_hidden() -> void:
	if _popup_suppress_vis:
		return
	if _hidden_view_action_id == &"":
		return
	_on_hidden_view_cancelled()

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
	_request_refresh()


## 弃牌选择完成回调
func _on_discard_selection_completed(selected_card_ids: Array[StringName]) -> void:
	discard_select_panel.visible = false
	var pending: Dictionary = _discard_select_pending

	# 回合结束弃超限牌阻塞窗（end_turn 第5步）：选牌经 resume_turn_discard op
	# 双端续跑（弃置->重入第5步->6~9步->流转下家）。
	if String(pending.get("mode", &"")) == &"turn_end_flow" and pending.has("action_id"):
		var tdf_aid: StringName = pending.get("action_id", &"")
		_discard_select_pending = {}
		var tdf_ids: Array = []
		for cid in selected_card_ids:
			tdf_ids.append(String(cid))
		_net_exec("resume_turn_discard", {"action_id": String(tdf_aid), "card_ids": tdf_ids})
		return

	# STEAL/discard_card 动作 need_input 路径：选完牌回填 determined_card_ids，
	# ActionEngine 重跑 _step_determine_cards → _step_transfer_to_holder 完成转移。
	if String(pending.get("mode", &"")) == &"need_input" and pending.has("action_id"):
		_discard_select_pending = {}
		var ni_ids: Array = []
		for cid in selected_card_ids:
			ni_ids.append(cid)
		_net_exec("ui_confirmed", {"data": {"determined_card_ids": ni_ids}})
		return

	# 闪击 optional 弃牌：玩家选了牌，续跑挂起的效果（弃牌 + 再攻）
	if pending.get("optional", false) and pending.has("action_id"):
		var action_id: StringName = pending.get("action_id", &"")
		_discard_select_pending = {}
		var opt_ids: Array = []
		for cid in selected_card_ids:
			opt_ids.append(cid)
		_net_exec("resume_effect", {"action_id": action_id, "data": {"selected_action_card_ids": opt_ids}})
		return

	# mode=resume_pending（机师效果等挂起的效果弃牌：苔丝弃攻击方牌/肯耳忒逐目标弃牌）：
	# 玩家选满牌后回填 selected_action_card_ids 续跑挂起效果（resume_pending_effect 对应 phase）。
	if String(pending.get("mode", &"")) == &"resume_pending" and pending.has("action_id"):
		var action_id: StringName = pending.get("action_id", &"")
		_discard_select_pending = {}
		var rp_ids: Array = []
		for cid in selected_card_ids:
			rp_ids.append(cid)
		_net_exec("resume_effect", {"action_id": action_id, "data": {"selected_action_card_ids": rp_ids}})
		return

	if _discard_select_card_id != &"":
		# 辅助牌打出流程的弃牌选择
		var payload := {"selected_action_card_ids": selected_card_ids}
		var card_id: StringName = _discard_select_card_id
		_discard_select_card_id = &""
		_discard_select_pending = {}
		_play_action_card(card_id, payload)
	elif pending.has("reason"):
		# 攻击结算后触发的弃牌选择：走 discard_cards op 双端弃牌
		var discard_player_id: StringName = pending.get("discard_player_id", &"")
		var dr_ids: Array = []
		for cid in selected_card_ids:
			dr_ids.append(cid)
		_discard_select_pending = {}
		_net_exec("discard_cards", {
			"player_id": discard_player_id,
			"card_ids": dr_ids,
			"reason": String(pending.get("reason", &"EFFECT_DISCARD")),
		})


## 弃牌选择取消回调
func _on_discard_selection_cancelled() -> void:
	discard_select_panel.visible = false
	var pending: Dictionary = _discard_select_pending
	if String(pending.get("mode", &"")) == &"turn_end_flow":
		# 回合结束弃超限牌不可取消：重新显示面板
		battle.log.append({"message": "必须弃置超出上限的行动牌", "details": {}})
		discard_select_panel.visible = true
		_request_refresh()
		return
	# 闪击 optional 弃牌取消：不再攻，恢复挂起的效果（cancelled 分支不弃牌不执行 actions）
	if pending.get("optional", false) and pending.has("action_id"):
		var action_id: StringName = pending.get("action_id", &"")
		_discard_select_card_id = &""
		_discard_select_pending = {}
		_net_exec("resume_effect", {"action_id": action_id, "data": {"cancelled": true}})
		return
	# mode=resume_pending 取消：恢复挂起效果（cancelled=true 由各 phase 决定跳过/中止）
	if String(pending.get("mode", &"")) == &"resume_pending" and pending.has("action_id"):
		var action_id: StringName = pending.get("action_id", &"")
		_discard_select_card_id = &""
		_discard_select_pending = {}
		_net_exec("resume_effect", {"action_id": action_id, "data": {"cancelled": true}})
		return
	# STEAL/discard_card need_input 取消：玩家选「不弃/不偷任何牌」-> 带 cancelled=true
	# 让动作 _step_determine_cards 走取消分支弃0张完成（空 determined_card_ids 会被判首次运行重弹死循环）。
	if String(pending.get("mode", &"")) == &"need_input" and pending.has("action_id"):
		_discard_select_card_id = &""
		_discard_select_pending = {}
		_net_exec("ui_confirmed", {"data": {"determined_card_ids": [], "cancelled": true}})
		return
	_discard_select_card_id = &""
	_discard_select_pending = {}
	_request_refresh()


## 推进多选确认回调：选中的推进一起打出（各动力+4），再继续迎击牌。
## selected_extra_ids：掩护窗口附加复选框选项（洛尔恩转化掩护等），与卡牌一并返回。
func _on_thrust_selection_completed(selected_card_ids: Array[StringName], selected_extra_ids: Array[StringName]) -> void:
	thrust_select_panel.visible = false
	var action_id: StringName = _thrust_select_action_id
	_thrust_select_action_id = &""
	var ts_ids: Array = []
	for cid in selected_card_ids:
		ts_ids.append(cid)
	var ts_extra: Array = []
	for eid in selected_extra_ids:
		ts_extra.append(String(eid))
	_net_exec("resume_effect", {"action_id": action_id, "data": {"selected_card_ids": ts_ids, "selected_extra_ids": ts_extra}})


## 推进多选取消回调：不打出推进，迎击牌继续
func _on_thrust_selection_cancelled() -> void:
	thrust_select_panel.visible = false
	var action_id: StringName = _thrust_select_action_id
	_thrust_select_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"cancelled": true}})


## 立即设置装备：玩家选了合法槽 -> set_equipment
## 铠厉链模式（_responded_equip_set_active）：设置到该槽（responded_equip_card op 走 set_equipment 动作）。
func _on_immediate_set_slot_selected(slot_id: StringName) -> void:
	immediate_set_equipment_panel.visible = false
	if _responded_equip_set_active:
		_responded_equip_set_active = false
		_net_exec("responded_equip_card", {"result": {"slot_id": slot_id}})
		return
	var action_id: StringName = _immediate_set_action_id
	_immediate_set_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"chosen_slot_id": slot_id}})


## 立即设置装备取消：不设置，抽到的牌将被弃置
## 铠厉链模式（_responded_equip_set_active）：弃置此牌并获牌面 cost 金币（无跳过，取消同弃置获金）。
func _on_immediate_set_cancelled() -> void:
	immediate_set_equipment_panel.visible = false
	if _responded_equip_set_active:
		_responded_equip_set_active = false
		_net_exec("responded_equip_card", {"result": {"action": "discard"}})
		return
	var action_id: StringName = _immediate_set_action_id
	_immediate_set_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"cancelled": true}})


## 立即设置装备选择卖出（effect_065）：卖出抽到的装备
## 铠厉链模式（_responded_equip_set_active）：卖出按钮即「弃置此牌（+cost金币）」按钮——弃置获金。
func _on_immediate_set_sell() -> void:
	immediate_set_equipment_panel.visible = false
	if _responded_equip_set_active:
		_responded_equip_set_active = false
		_net_exec("responded_equip_card", {"result": {"action": "discard"}})
		return
	var action_id: StringName = _immediate_set_action_id
	_immediate_set_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"chosen_action": "sell"}})


## 联合攻击单选确认回调：打出选中的攻击牌（结算后由动作系统去除此联合状态）
func _on_unite_attack_selection_completed(selected_card_id: StringName) -> void:
	unite_attack_select_panel.visible = false
	if _medusa_control_select_active:
		_medusa_control_select_active = false
		# 和手牌点击一致：弹"确定使用?"确认框，确认后走 __confirm_use_action_card__ -> play_action_card。
		# 取消则回填 battle（_on_choice_cancelled 兜底清场，与手牌确认弹窗取消一致）。
		_choice_select_card_id = selected_card_id
		var options: Array[Dictionary] = [
			{"label": "确定使用", "effect_id": &"__confirm_use_action_card__"},
		]
		choice_panel.configure(options)
		choice_panel.visible = true
		var _card = battle.context.game_state.get_card(selected_card_id) if (battle != null and battle.context != null) else null
		var _dn: String = _card.def.display_name if (_card != null and _card.def != null) else String(selected_card_id)
		if battle != null:
			battle.log.append({"message": "使用受控牌: %s - 确认使用？" % _dn, "details": {}})
		return
	var action_id: StringName = _unite_attack_action_id
	_unite_attack_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"selected_card_id": selected_card_id}})


## 联合攻击单选取消回调：不联合攻击，联合状态保留到回合结束
func _on_unite_attack_selection_cancelled() -> void:
	unite_attack_select_panel.visible = false
	if _medusa_control_select_active:
		_medusa_control_select_active = false
		return
	var action_id: StringName = _unite_attack_action_id
	_unite_attack_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"cancelled": true}})


## pilot_003 e3 复选框提交：整组覆盖跳过玩家集合（player_ids 为空=全部取消勾选）
func _on_pilot_003_skip_submitted(player_ids: Array) -> void:
	pilot_003_skip_panel.visible = false
	var action_id: StringName = _pilot_003_skip_action_id
	_pilot_003_skip_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"player_ids": player_ids}})


## pilot_003 e3 复选框取消：不修改现有勾选
func _on_pilot_003_skip_cancelled() -> void:
	pilot_003_skip_panel.visible = false
	var action_id: StringName = _pilot_003_skip_action_id
	_pilot_003_skip_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"cancelled": true}})


## pilot_003 e1 选置顶牌确认：把选中牌回填给 effect_01 phase 链（pilot_003_choose_top resume 读 selected_card_id）
func _on_pilot_003_choose_top_completed(selected_card_id: StringName) -> void:
	pilot_003_choose_top_panel.visible = false
	var action_id: StringName = _pilot_003_choose_top_action_id
	_pilot_003_choose_top_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"selected_card_id": selected_card_id}})


## pilot_003 e1 选置顶牌取消：不置顶（仅随机插入），deck_top_card_id=空
func _on_pilot_003_choose_top_cancelled() -> void:
	pilot_003_choose_top_panel.visible = false
	var action_id: StringName = _pilot_003_choose_top_action_id
	_pilot_003_choose_top_action_id = &""
	_net_exec("resume_effect", {"action_id": action_id, "data": {"cancelled": true}})


## 觉醒种类单选确认回调：把选中的 card_def_id 回填给觉醒动作（awaken 子动作 waiting_input 路径）
## 走 ui_confirmed 网络op（与 redirect_select/steal弃牌 同路径），双端各调 on_ui_confirmed -> continue_action。
## 两轮（预判/识破）各弹一次，每次独立 need_input 暂停/恢复。
func _on_awaken_selection_completed(selected_def_id: StringName) -> void:
	awaken_select_panel.visible = false
	_awaken_select_action_id = &""
	_net_exec("ui_confirmed", {"data": {"chosen_card_def_id": selected_def_id}})


## 觉醒种类单选取消回调（UI 无取消按钮，留作扩展）：跳过弃牌堆选取，仅抽牌堆顶1张
func _on_awaken_selection_cancelled() -> void:
	awaken_select_panel.visible = false
	_awaken_select_action_id = &""
	_net_exec("ui_confirmed", {"data": {"_awaken_skip_to_top": true}})


## 显示迎击面板
func _show_response_panel(attack_result: Dictionary) -> void:
	if not battle or not battle.context:
		return
	var action_id: StringName = attack_result.get("action_id", &"")
	if action_id != &"":
		response_panel.configure_new_system(battle, action_id)
	else:
		return
	response_panel.visible = true
	_request_refresh()

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
		_request_refresh()
		_finish_battle_if_needed()

## 打出辅助牌
func _play_action_card(card_id: StringName, payload: Dictionary = {}) -> void:
	if battle == null or battle.context == null:
		return
	var result: Variant = _net_exec("play_action_card", {"player_id": local_player_id, "card_instance_id": card_id, "payload": payload})
	if result is Dictionary:
		if result.get("ok", false):
			battle.log.append({"message": "打出了行动牌", "details": {}})
		elif result.get("needs", "") == &"weapon_select":
			_enter_support_weapon_select(card_id)
			return
		elif result.get("needs", "") == &"discard_select":
			_show_discard_select_panel(result.get("discard_info", {}), card_id, result.get("effect_id", &""))
		else:
			battle.log.append({"message": "打出失败: %s" % String(result.get("message", "")), "details": {}})
	_request_refresh()


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
	_request_refresh()


## 判断是否为维修牌（action_013_维修）
func _is_repair_card(card) -> bool:
	if card == null or card.def == null:
		return false
	return card.def.card_id == &"action_013_维修"


## 获取维修可选目标机甲列表：自身机甲 + 范围内其他机甲（默认1格；机师牌 repair_boost 坎得等 range=4）
func _get_repair_candidate_mechs() -> Array:
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return []
	var rcm_range: int = _ActionPilotEffects.get_repair_range(gs, mech.mech_id)
	var candidates: Array = []
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if _HexGrid.distance(m.position, mech.position) <= rcm_range:
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
	_request_refresh()


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
		_request_refresh()
		return

	# 记录目标，进入维修效果二选一
	_repair_selected_target_mech_id = target_mech_id
	_enter_choice_select(card_id)


## 维修目标合法性：自身或范围内机甲（默认1格；机师牌 repair_boost 坎得等 range=4）
func _is_repair_target_in_range(target_mech_id: StringName, src_mech_id: StringName) -> bool:
	if target_mech_id == &"" or battle == null or battle.context == null:
		return false
	var gs = battle.context.game_state
	if gs == null:
		return false
	if target_mech_id == src_mech_id:
		return true
	var src_mech = gs.mechs.get(src_mech_id) if src_mech_id != &"" else null
	var tgt_mech = gs.mechs.get(target_mech_id)
	if src_mech == null or tgt_mech == null:
		return false
	var rng_range: int = _ActionPilotEffects.get_repair_range(gs, src_mech_id)
	return _HexGrid.distance(src_mech.position, tgt_mech.position) <= rng_range


## 机甲是否为满状态（满血且无任何损伤）--满状态则无需维修
func _mech_is_full_state(mech) -> bool:
	if mech == null:
		return false
	# 满血判定
	if mech.current_hp < mech.max_hp:
		return false
	# 无损伤判定（区域损伤 + 装备牌损伤）
	for slot_id in mech.slots:
		var slot = mech.slots[slot_id]
		if slot == null:
			continue
		if slot.region_damage_tokens > 0:
			return false
		if slot.equipped_card != null and slot.equipped_card.damage_tokens > 0:
			return false
	return true


## 机甲是否可被维修（非满状态：HP未满或有损伤）
func _mech_can_be_repaired(mech) -> bool:
	return not _mech_is_full_state(mech)


## 维修是否有可用目标：自身与范围内机甲（默认1格；机师牌 repair_boost 坎得等 range=4）存在非满状态者
func _has_repairable_target() -> bool:
	if battle == null or battle.context == null:
		return false
	var gs = battle.context.game_state
	var src_mech = gs.get_mech_for_player(local_player_id)
	if src_mech == null:
		return false
	var hrt_range: int = _ActionPilotEffects.get_repair_range(gs, src_mech.mech_id)
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if _HexGrid.distance(m.position, src_mech.position) > hrt_range:
			continue
		if _mech_can_be_repaired(m):
			return true
	return false


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
	# 聚能：含虚拟武器（神莺躯干），不要求 power>0（聚能不是攻击，动力限制只针对"发动攻击"）
	var weapon_ids: Array[StringName] = _get_all_usable_weapon_ids(mech, false)
	if weapon_ids.is_empty():
		battle.log.append({"message": "没有可用武器", "details": {}})
		_support_weapon_select_card_id = &""
		_request_refresh()
		return
	# 只有一把武器时自动选择
	if weapon_ids.size() == 1:
		_on_support_weapon_selected(weapon_ids[0])
		return
	# 冷却中/锁定中的武器仍可选（聚能可解除不能攻击状态）
	weapon_picker_panel.configure(battle.context, weapon_ids, "── 选择要聚能的武器 ──", mech, true)
	weapon_picker_panel.visible = true
	_show_cancel_button(true)
	battle.log.append({"message": "辅助牌武器选择：选择1把武器", "details": {}})
	_request_refresh()


## 辅助牌武器选择回调
func _on_support_weapon_selected(weapon_id: StringName) -> void:
	var card_id: StringName = _support_weapon_select_card_id
	_support_weapon_select_card_id = &""
	if weapon_picker_panel:
		weapon_picker_panel.visible = false
	_show_cancel_button(false)
	if card_id == &"":
		_request_refresh()
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
	_request_refresh()


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
		_request_refresh()
		return

	# 锁步:目标选择回填走 ui_confirmed op（_waiting_action_id 已由 action_needs_input 设）
	if _pending_target_action_id != &"":
		var pt_aid: StringName = _pending_target_action_id
		_pending_target_action_id = &""
		_pending_target_effect_id = &""
		var pt_pending: bool = false
		if battle and battle.context and battle.context.timing_engine:
			pt_pending = battle.context.timing_engine.has_pending_effect(pt_aid)
		if pt_pending:
			_net_exec("resume_effect", {"action_id": String(pt_aid), "data": {"target_id": target_mech_id, "target_mech_id": target_mech_id}})
		else:
			_net_exec("ui_confirmed", {"data": {"target_id": target_mech_id, "target_mech_id": target_mech_id}})
	return

	# 旧流程：将目标信息加入 payload 并打出辅助牌
	var payload := {"target_mech_id": target_mech_id}
	_play_action_card(card_id, payload)

# ═══════════════════════════════════════════
# 刷新与工具
# ═══════════════════════════════════════════

## 延迟合并刷新：信号驱动热路径（_on_timing_fired / _on_action_completed 玩家回合分支）
## 通过 call_deferred 调用。一次攻击爆发 5 个时点（ATTACK_BEFORE/PRE/AT/AFTER/SETTLE），
## 同步调 _refresh_battle() × 5 = 5 次全量面板重建 + 5 次六边形重绘，严重卡顿。
## 改为 call_deferred + 脏标记：同一帧多次时点 → 末帧仅刷新一次。
## 守卫在帧末执行——此时 timing_fired 之后同步触发的 need_input（响应窗口/迎击移动/
## 损伤放置）已设 _waiting_action_id，get_waiting_action_info() 返回非空：
##   - 有等待输入弹窗时 → 只做 _refresh_panels_only 面板轻量刷新（手牌/临时区/装备/技能/
##     消息/状态栏），跳过 battle_board 全量 configure（保留弹窗背后的高亮与弹窗自身）。
##     这样临时区"使用中"牌、装备损伤、手牌增删在弹窗期间仍实时更新，不落后到关闭后。
##   - 这些流程自身在确认/关闭时会再刷新，补齐棋盘。
func _refresh_battle_coalesced() -> void:
	if not _refresh_pending:
		return  # 已被本帧先前的 deferred 调用处理
	_refresh_pending = false
	if battle == null or battle.context == null:
		return
	if battle.context.action_ui_bridge and not battle.context.action_ui_bridge.get_waiting_action_info().is_empty():
		_refresh_panels_only()
		return
	# 逐格移动进行中：不碰棋盘。_refresh_board_only 已在每格 BASIC_MOVE_AFTER 同步刷新棋盘+
	# 状态栏；若全量 _refresh_battle（重建手牌/装备等面板）会引发布局抖动，使 battle_board 的
	# _grid_scale 读到瞬态 get_rect() -> 棋盘变形放大。但面板轻量刷新照做——移动中触发的效果
	#（骇客窥牌加成攻击次数/行动牌上限、汀兰光环改动力消耗等）须立即显示，否则数值要等移动
	# 整个动作完成后才更新（用户反馈"过了一会才加上"）。panels_only 差量便宜、不重建棋盘，
	# 无布局抖动。移动结束时（_has_active_single_move 为 false）再全量 _refresh_battle 补齐。
	if _has_active_single_move():
		_refresh_panels_only()
		return
	_refresh_battle()

## 请求帧末刷新（去重）：信号驱动热路径调用此函数而非直接 _refresh_battle。
func _request_refresh() -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	call_deferred("_refresh_battle_coalesced")

## 逐格移动轻量刷新：仅同步 units + 状态栏 + 棋盘（跳过手牌/装备/技能/消息/卖出/dev）。
## 在 BASIC_MOVE_AFTER/SETTLE 时点同步调用，让玩家看到机甲逐格移动（配合 single_move
## 的 yield_frame 50ms/格暂停）。用 battle_board.update_units（不重算 _grid_scale），
## 避免逐格 _update_grid_transform 在布局抖动时读到瞬态尺寸致棋盘变形放大。
## 移动期间手牌/装备/技能不变，故跳过；移动结束时 _on_action_completed 的 _request_refresh 全量补齐。
func _refresh_board_only() -> void:
	if battle == null or battle.context == null:
		return
	battle._sync_compat_fields()
	# 状态栏（动力/HP 随每格移动变化）
	if battle_summary_label:
		var local_unit: Dictionary = battle.units.get(String(local_player_id), {})
		var opp_unit: Dictionary = battle.units.get(String(_opponent_player_id()), {})
		battle_summary_label.text = _build_status_bar_text()
	# 棋盘（仅 units 更新，不重算缩放变换）+ 移动标志/当前位置（供"当前位置->目标"实时连线）
	if battle_board:
		battle_board.update_units(battle.units)
		battle_board._context = battle.context
		battle_board.local_player_id = local_player_id
		battle_board._move_active = _has_active_single_move()
		var _bb_local_mech = battle.context.game_state.get_mech_for_player(local_player_id) if battle.context.game_state else null
		if _bb_local_mech != null:
			battle_board._local_mech_id = _bb_local_mech.mech_id
			battle_board._local_mech_pos = _bb_local_mech.position.duplicate()
			# 移动中：沿原定路线取"当前位置->终点"的剩余尾巴（不重新寻路），
			# 保证路线始终是同一条、越来越短。_local_mech_pos 已设为当前位置。
			if battle_board._move_active and not battle_board._planned_path_cells.is_empty():
				battle_board._update_move_path_tail()
			elif battle_board._move_active:
				battle_board._move_path_centers = []
			else:
				battle_board._move_path_centers = []
		else:
			battle_board._local_mech_id = &""
			battle_board._local_mech_pos = {}
			battle_board._move_path_centers = []
	# 同步移动模态遮罩（pacing 时拦截点击停止，弹窗/移动结束时透传）
	_update_move_overlay()

## 损伤放置/移除后的轻量刷新：只更新损伤相关 UI（状态栏/装备面板/技能栏/消息日志）。
## 跳过 battle_board（192格重绘）/手牌/临时区--损伤放置期间无移动、无手牌变化，
## 每点一次 +损伤 都全量 _refresh_battle 会明显卡顿（bug3 优化）。
func _refresh_damage_ui() -> void:
	if battle == null or battle.context == null:
		return
	battle._sync_compat_fields()
	# 状态栏
	if battle_summary_label:
		var local_unit: Dictionary = battle.units.get(String(local_player_id), {})
		var opp_unit: Dictionary = battle.units.get(String(_opponent_player_id()), {})
		battle_summary_label.text = _build_status_bar_text()
	# 装备面板（损伤 token 变化）
	if equipment_panel and battle.context:
		var mech = battle.context.game_state.get_mech_for_player(local_player_id)
		if mech:
			equipment_panel.configure(mech, false, battle.context)
	# 技能栏（装备损坏可能移除技能）
	if skill_bar and battle.context:
		skill_bar.configure(battle.context)
	# 消息日志（损坏/效果消息）
	if message_log and battle.context:
		message_log.configure(battle.context)
	# 设陷按钮：移动离场放陷阱后层数/armed_cell 变化需及时刷新（否则按钮残留灰色）
	_update_set_trap_button()
	_update_medusa_control_button()

## 效果弹窗/损伤放置等选择后的轻量刷新：只更新面板（状态栏/手牌/临时区/装备/技能/消息/卖出按钮），
## 跳过 battle_board.configure -> queue_redraw -> _draw 192 格重绘（效果/损伤选择不改变棋盘可视状态，
## 全量重绘是"弹窗选择后卡顿"的主因）。棋盘在动作完成/时点触发时由 _request_refresh 全量补齐。
func _refresh_panels_only() -> void:
	if battle == null or battle.context == null:
		return
	battle._sync_compat_fields()
	var local_unit: Dictionary = battle.units.get(String(local_player_id), {})
	var opp_unit: Dictionary = battle.units.get(String(_opponent_player_id()), {})
	if battle_summary_label:
		battle_summary_label.text = _build_status_bar_text()
	if hand_panel and battle.context:
		hand_panel.local_player_id = local_player_id
		hand_panel.configure(battle.context)
	if tmp_zone_panel and battle.context:
		tmp_zone_panel.configure(battle.context)
	if equipment_panel and battle.context:
		var mech = battle.context.game_state.get_mech_for_player(local_player_id)
		if mech:
			equipment_panel.configure(mech, false, battle.context)
	if skill_bar and battle.context:
		skill_bar.configure(battle.context)
	if message_log and battle.context:
		message_log.configure(battle.context)
	if _sell_button and battle.context:
		var gs = battle.context.game_state
		var player_state = gs.players.get(local_player_id) if gs else null
		if player_state:
			var remaining = _GameConfig.SELL_EQUIPMENT_LIMIT_PER_TURN - player_state.sell_equipment_count_this_turn
			_sell_button.text = "卖出(%d/2)" % remaining
			_sell_button.disabled = (remaining <= 0)
	if _paid_draw_button and battle.context:
		var gs = battle.context.game_state
		var player_state = gs.players.get(local_player_id) if gs else null
		if player_state:
			_paid_draw_button.text = "抽牌(%d金)" % _GameConfig.PAID_DRAW_ACTION_COST
			_paid_draw_button.disabled = (player_state.paid_draw_count_this_turn > 0) or (not _is_my_turn()) or (player_state.gold < _GameConfig.PAID_DRAW_ACTION_COST)
	_update_set_trap_button()
	_update_medusa_control_button()


## 构建状态栏文本：己方信息 + 所有对手 HP（3人显示2对手，2人显示1对手）。
func _build_status_bar_text() -> String:
	var local_unit: Dictionary = battle.units.get(String(local_player_id), {})
	var text := "回合 %d | 行动方: %s | 我方(%s) HP %d/%d 动力 %d/%d 金币 %d" % [
		battle.turn_number, battle.active_side, String(local_player_id),
		int(local_unit.get("life", 0)), int(local_unit.get("max_life", 0)),
		int(local_unit.get("power", 0)), int(local_unit.get("max_power", 0)), int(local_unit.get("gold", 0)),
	]
	# 对手：遍历所有非 local 玩家（3人=2对手，2人=1对手）
	if battle.context and battle.context.game_state:
		for pid: StringName in battle.context.game_state.players:
			if pid == local_player_id:
				continue
			var opp_u: Dictionary = battle.units.get(String(pid), {})
			text += " | 敌方(%s) HP %d/%d" % [String(pid), int(opp_u.get("life", 0)), int(opp_u.get("max_life", 0))]
	return text

func _refresh_battle() -> void:
	if battle == null:
		return

	# 同步兼容字段
	battle._sync_compat_fields()
	# 本窗口视角：local = 己方，opponent = 敌方（PvP host=player, client=enemy）
	var local_unit: Dictionary = battle.units.get(String(local_player_id), {})
	var opp_unit: Dictionary = battle.units.get(String(_opponent_player_id()), {})

	# 更新状态栏（标出玩家ID，PvP双窗口视角一目了然）
	if battle_summary_label:
		battle_summary_label.text = _build_status_bar_text()

	# 更新地图
	if battle_board:
		battle_board.configure(battle.map_tiles, battle.units)
		# 悬停路径预览需要 context（find_optimal_path）与本地机甲 id（路径起点）
		battle_board._context = battle.context
		battle_board.local_player_id = local_player_id
		var _bb_local_mech = battle.context.game_state.get_mech_for_player(local_player_id) if battle.context and battle.context.game_state else null
		battle_board._local_mech_id = _bb_local_mech.mech_id if _bb_local_mech != null else &""
		battle_board._local_mech_pos = _bb_local_mech.position.duplicate() if _bb_local_mech != null else {}
		# 移动标志：移动中 _refresh_battle 不应被调用（被 _refresh_battle_coalesced 跳过），
		# 但移动结束时此处会跑。移动结束清 _move_destination，避免残留连线。
		var _move_active_now := _has_active_single_move()
		battle_board._move_active = _move_active_now
		if not _move_active_now:
			battle_board._move_destination = {}
			battle_board._planned_path_cells = []
			battle_board._move_path_centers = []

	# 更新手牌面板（按本窗口 local_player_id 显示己方手牌）
	if hand_panel and battle.context:
		hand_panel.local_player_id = local_player_id
		hand_panel.configure(battle.context)

	# 更新临时区面板（使用中行动牌）
	if tmp_zone_panel and battle.context:
		tmp_zone_panel.configure(battle.context)

	# 更新装备面板（己方机甲）
	if equipment_panel and battle.context:
		var mech = battle.context.game_state.get_mech_for_player(local_player_id)
		if mech:
			equipment_panel.configure(mech, false, battle.context)

	# 更新技能栏
	if skill_bar and battle.context:
		skill_bar.configure(battle.context)

	# 更新消息日志（追赶新日志条目）
	if message_log and battle.context:
		message_log.configure(battle.context)

	# 更新卖出按钮文本（己方卖出次数）
	if _sell_button and battle.context:
		var gs = battle.context.game_state
		var player_state = gs.players.get(local_player_id)
		if player_state:
			var remaining = _GameConfig.SELL_EQUIPMENT_LIMIT_PER_TURN - player_state.sell_equipment_count_this_turn
			_sell_button.text = "卖出(%d/2)" % remaining
			_sell_button.disabled = (remaining <= 0)
	if _paid_draw_button and battle.context:
		var gs = battle.context.game_state
		var player_state = gs.players.get(local_player_id) if gs else null
		if player_state:
			_paid_draw_button.text = "抽牌(%d金)" % _GameConfig.PAID_DRAW_ACTION_COST
			_paid_draw_button.disabled = (player_state.paid_draw_count_this_turn > 0) or (not _is_my_turn()) or (player_state.gold < _GameConfig.PAID_DRAW_ACTION_COST)
	_update_set_trap_button()
	_update_medusa_control_button()
	# 铠威攻击窗口：确认弹窗 + 窗口期间「取消攻击」按钮
	_maybe_update_attack_window_ui()
	# 铠厉通用「被响应→抽2装备设置/弃置获金」：确认弹窗 + 逐张「设置/弃置获金」面板
	_maybe_update_responded_equip_ui()
	_maybe_update_pilot_060_ui()

	# 更新开发者面板
	if dev_panel and dev_panel.visible and battle.context:
		dev_panel.setup(battle.context)

## 在hex上查找机甲ID（新系统辅助方法）
## 获取武器射程（统一处理实体武器牌与基础武器虚拟ID）
## 基础武器虚拟ID "frame_base_weapon_<N>" 不在 cards 字典里，get_card 返回 null，
## 旧代码此处默认 range=1 → 只能攻击相邻格。这里对基础武器走 mech.get_base_weapon 取真实射程。
func _get_weapon_range(mech, weapon_id: StringName) -> int:
	if mech == null:
		return 1
	var wid_str := String(weapon_id)
	var base_range: int = 1
	var weapon_kind: StringName = &""
	if wid_str.begins_with("frame_base_weapon_"):
		var slot_index: int = wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
		var base_weapon: Dictionary = mech.get_base_weapon(slot_index)
		if base_weapon.is_empty():
			return 1
		# 基础武器走派生统计（含瓦恩 pilot_083 基础武器范围加成）
		var _bws: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, slot_index)
		base_range = int(_bws.get("range_value", int(base_weapon.get("range_value", 1))))
		weapon_kind = _bws.get("weapon_kind", base_weapon.get("weapon_kind", &""))
	else:
		# 实体武器牌 / 虚拟武器（帝国的神莺·躯干 effect_087）
		var gs = battle.context.game_state if (battle != null and battle.context != null) else null
		var weapon_card = gs.get_card(weapon_id) if gs != null else null
		if weapon_card and weapon_card.def:
			# 统一走有效统计（虚拟武器/实体武器都含，含瓦恩 pilot_083 卡牌武器范围加成）
			var _st: Dictionary = _GenEquipEffects.get_effective_weapon_stats(weapon_card)
			base_range = int(_st.get("range_value", 1))
			weapon_kind = _st.get("weapon_kind", &"")
		else:
			return 1
	# 狙击装·头部被动远程范围加成（effect_022 +1 / effect_055 +2，派生值实时重算）
	var _gs_wr = battle.context.game_state if (battle != null and battle.context != null) else null
	# 待用「下次攻击范围加成」（影刹 pilot_069 未移>4 下次攻击范围+1 等，ACCUMULATE 注册表）：
	# 攻击前置检查须计入，否则范围加成只在实际攻击时（ATTACK_BEFORE）生效、攻击牌预检仍按
	# 基础射程判"无可用目标"（4 射程武器打 5 格敌人攻击牌却显示不可用）。
	var _pending_range: int = _ActionPilotEffects.get_pending_next_attack_range(_gs_wr, mech) if _gs_wr != null else 0
	return base_range + _GenEquipEffects.get_passive_weapon_range_bonus(mech, weapon_kind) + _pending_range


## 获取机甲所有可用作武器的ID列表（实体武器 + 虚拟武器）
## 实体武器：weapon_1/weapon_2 槽（含基础武器虚拟ID frame_base_weapon_N）
## 虚拟武器：帝国的神莺·躯干 effect_087（躯干装备牌当远程武器用，ID=躯干牌instance_id，
##   不占武器槽；face_down/disabled 时 is_equipment_active 判定不通过自动排除--"效果被无效
##   则不能当武器"）。攻击和聚能都适用。
## require_power_for_virtual=true（攻击用）时，虚拟武器需当前动力>0才列入：
##   effect_088 cost SPEND_POWER(ALL_CURRENT) 需 power>=1，power=0 时虚拟武器攻击无法发动。
##   聚能(false)不限制（聚能不是攻击，动力限制只针对"发动攻击"）。
func _get_all_usable_weapon_ids(mech, require_power_for_virtual: bool) -> Array[StringName]:
	var result: Array[StringName] = []
	if mech == null:
		return result
	result.append_array(mech.get_weapon_ids())
	# 动力0时攻击不能用虚拟武器（聚能不限制）
	if require_power_for_virtual and int(mech.power) <= 0:
		return result
	if mech.slots == null:
		return result
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot == null:
			continue
		var card = slot.equipped_card
		var vw = _GenEquipEffects.get_virtual_weapon_from_equipment(card)
		if not vw.is_empty():
			result.append(card.instance_id)
	return result


## 武器是否处于不能攻击状态（冷却中 effect_125 / 锁定中 effect_104）。
## 攻击选框与攻击牌前置检查排除这类武器（"不会出现在攻击时的选框"）；聚能选框保留可选。
## 锁定以目标身上 source_card_id=本武器 的 LOCKED 状态为权威，缓存失效则清并放行。
func _weapon_attack_blocked(gs, card) -> bool:
	if card == null:
		return false
	if "counters" in card and bool(card.counters.get("cooldown_active", false)):
		return true
	var lock_tgt: StringName = card.lock_target_mech_id if "lock_target_mech_id" in card else &""
	if lock_tgt == &"":
		return false
	if gs == null:
		return true
	var lock_mech = gs.mechs.get(lock_tgt)
	if lock_mech == null or lock_mech.destroyed:
		card.lock_target_mech_id = &""
		return false
	for s in lock_mech.statuses:
		if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == String(card.instance_id):
			return true
	card.lock_target_mech_id = &""
	return false


## 武器射程内是否有可攻击目标（复用攻击牌预检查逻辑，规则10）
## 用于攻击武器选择弹窗过滤：范围内无目标的武器不列入弹窗。
func _weapon_has_attackable_target(mech, weapon_id: StringName) -> bool:
	if battle == null or battle.context == null or mech == null:
		return false
	var gs = battle.context.game_state
	var weapon_range: int = _get_weapon_range(mech, weapon_id)
	var _attack_aura: Dictionary = battle.context.map_service.get_attack_aura_cells()
	# 机甲格为攻击路径障碍（可作终点不可穿过）+ 陷落"不能被选为目标"排除
	var _attack_blocked: Dictionary = battle.context.map_service.get_attack_blocked_keys(mech.mech_id)
	var reachable: Array[Dictionary] = _RangeCalculator.get_weapon_reachable_hexes(
		mech.position, weapon_range, gs.map_state.cells if gs.map_state else {}, _attack_aura, _attack_blocked
	)
	for hex in reachable:
		var target_mech_id: StringName = _find_mech_at_hex(hex)
		if target_mech_id != &"" and target_mech_id != mech.mech_id:
			var t_mech = gs.mechs.get(target_mech_id)
			if t_mech != null and t_mech.has_status(&"cannot_be_targeted"):
				continue
			return true
		# 陷阱标记也是可攻击目标（攻击即引爆，无响应窗口）
		for m in gs.map_state.get_markers_at(int(hex.get("q", 0)), int(hex.get("r", 0))):
			if m.get("type", &"") == &"TRAP":
				return true
	return false


func _find_mech_at_hex(hex: Dictionary) -> StringName:
	if battle == null or battle.context == null:
		return &""
	var gs = battle.context.game_state
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null or m.destroyed:
			continue
		if int(m.position.get("q", 0)) == int(hex.get("q", 0)) and int(m.position.get("r", 0)) == int(hex.get("r", 0)):
			return mech_id
	return &""

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
		"winner": String(result.get("winner", "")),
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
	var winner := String(result.get("winner", ""))
	# 按 winner vs local_player_id 判定本方胜负（PvP/PVP3 多端各自视角）；
	# 无 winner 字段时 fallback state（PvE 兼容）
	var is_win: bool = (winner == String(local_player_id)) if winner != "" else (state == "victory")
	var state_text := "胜利" if is_win else "失败"
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
	# 断开新动作系统信号，防止悬挂引用（I1: hook_fired 已不再连接）
	if battle and battle.context and battle.context.action_ui_bridge:
		if battle.context.action_ui_bridge.request_ui_popup.is_connected(Callable(self, "_on_action_ui_popup_requested")):
			battle.context.action_ui_bridge.request_ui_popup.disconnect(Callable(self, "_on_action_ui_popup_requested"))
		if battle.context.action_ui_bridge.action_input_resolved.is_connected(Callable(self, "_on_action_input_resolved")):
			battle.context.action_ui_bridge.action_input_resolved.disconnect(Callable(self, "_on_action_input_resolved"))
	if battle and battle.context and battle.context.timing_engine:
		if battle.context.timing_engine.timing_fired.is_connected(Callable(self, "_on_timing_fired")):
			battle.context.timing_engine.timing_fired.disconnect(Callable(self, "_on_timing_fired"))
		if battle.context.timing_engine.equipment_effect_fired.is_connected(Callable(self, "_on_equipment_effect_fired")):
			battle.context.timing_engine.equipment_effect_fired.disconnect(Callable(self, "_on_equipment_effect_fired"))
		if battle.context.timing_engine.pilot_024_repair_window_changed.is_connected(Callable(self, "_on_pilot_024_repair_window_changed")):
			battle.context.timing_engine.pilot_024_repair_window_changed.disconnect(Callable(self, "_on_pilot_024_repair_window_changed"))
	# 断开 ActionEngine 动作完成信号，防止悬挂引用
	if battle and battle.context and battle.context.action_engine:
		if battle.context.action_engine.action_completed.is_connected(Callable(self, "_on_action_completed")):
			battle.context.action_engine.action_completed.disconnect(Callable(self, "_on_action_completed"))
	if enemy_info_popup and is_instance_valid(enemy_info_popup):
		enemy_info_popup.queue_free()
	if mech_detail_panel and is_instance_valid(mech_detail_panel):
		mech_detail_panel.queue_free()
	if status_panel and is_instance_valid(status_panel):
		status_panel.queue_free()
	if deck_info_popup and is_instance_valid(deck_info_popup):
		deck_info_popup.queue_free()
	if shop_panel and is_instance_valid(shop_panel):
		shop_panel.queue_free()
	# popup_overlay 承载的弹窗面板不再随 current_screen（margin 子树）释放，
	# 因它们改挂 popup_overlay（在 self 下），需显式释放。
	_clear_popup_stack()
	if _popup_scrim and is_instance_valid(_popup_scrim):
		_popup_scrim.queue_free()
	_popup_scrim = null
	if popup_overlay and is_instance_valid(popup_overlay):
		popup_overlay.queue_free()
	if _move_overlay and is_instance_valid(_move_overlay):
		_move_overlay.queue_free()
	_move_overlay = null
	if current_screen != null and is_instance_valid(current_screen):
		current_screen.queue_free()
	current_screen = null
	status_label = null
	battle_summary_label = null
	message_log = null
	enemy_info_popup = null
	mech_detail_panel = null
	status_panel = null
	deck_info_popup = null
	shop_panel = null
	popup_overlay = null
	battle_board = null
	hand_panel = null
	equipment_panel = null
	skill_bar = null
	response_panel = null
	weapon_picker_panel = null
	damage_placement_panel = null
	damage_adjust_panel = null
	choice_panel = null
	discard_select_panel = null
	thrust_select_panel = null
	unite_attack_select_panel = null
	pilot_003_skip_panel = null
	pilot_003_choose_top_panel = null
	awaken_select_panel = null
	cancel_attack_button = null
	if dev_panel and is_instance_valid(dev_panel):
		dev_panel.queue_free()
	dev_panel = null
	# card_display_panel 挂根节点（非 popup_overlay），须显式释放，否则跨屏残留。
	if card_display_panel and is_instance_valid(card_display_panel):
		card_display_panel.queue_free()
	card_display_panel = null

func _add_text(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label

func _add_button(parent: Node, text: String, callback: Callable, name: String = "") -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(140, 32)
	button.pressed.connect(callback)
	if name != "":
		button.set_meta("button_id", name)
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
	# 退出前清理 PvP（停 TCP / kill client 子进程），避免遗留窗口与端口占用
	if _is_pvp_mode():
		_pvp_cleanup()
		_reset_pvp_state()
	SLog.log_raw("════════ 会话结束 ════════")
	get_tree().quit()
