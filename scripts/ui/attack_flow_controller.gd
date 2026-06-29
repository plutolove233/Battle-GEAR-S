## AttackFlowController.gd — 攻击流程状态机
##
## 追踪攻击流程的当前阶段，协调 UI 与服务之间的交互。
## 不持有 UI，仅追踪状态。app_root 通过检查状态决定显示哪个面板。
class_name AttackFlowController
extends RefCounted

## 状态常量
const IDLE: StringName = &"IDLE"
const SELECT_WEAPON: StringName = &"SELECT_WEAPON"
const SELECT_TARGET: StringName = &"SELECT_TARGET"
const RESPONSE_WINDOW: StringName = &"RESPONSE_WINDOW"
const DAMAGE_PLACEMENT: StringName = &"DAMAGE_PLACEMENT"

## 当前状态
var current_state: StringName = IDLE

## ── 攻击流程上下文 ──

## 选定的攻击牌 instance_id
var attack_card_id: StringName = &""
## 选定的武器 instance_id
var weapon_id: StringName = &""
## 攻击声明后生成的 attack_id
var attack_id: StringName = &""
## 攻击方 player_id
var attacker_player_id: StringName = &""
## 防守方 player_id
var defender_player_id: StringName = &""
## 是否为敌方回合（敌方发起的攻击）
var is_enemy_turn: bool = false
## 损伤放置的目标机甲 ID
var target_mech_id_for_tokens: StringName = &""
## 需放置的损伤标记数量
var token_count: int = 0
## 选择放置位置的玩家 ID
var chooser_player_id: StringName = &""


## ── 状态转换方法 ──


## 重置到空闲状态
func reset() -> void:
	current_state = IDLE
	attack_card_id = &""
	weapon_id = &""
	attack_id = &""
	attacker_player_id = &""
	defender_player_id = &""
	is_enemy_turn = false
	target_mech_id_for_tokens = &""
	token_count = 0
	chooser_player_id = &""


## 进入武器选择阶段
func enter_select_weapon(attack_card: StringName, attacker: StringName, defender: StringName, enemy_turn: bool) -> void:
	current_state = SELECT_WEAPON
	attack_card_id = attack_card
	attacker_player_id = attacker
	defender_player_id = defender
	is_enemy_turn = enemy_turn


## 进入目标选择阶段（武器已选定）
func enter_select_target(weapon: StringName) -> void:
	current_state = SELECT_TARGET
	weapon_id = weapon


## 进入迎击响应窗口
func enter_response_window(attack: StringName) -> void:
	current_state = RESPONSE_WINDOW
	attack_id = attack


## 进入损伤放置阶段
func enter_damage_placement(target_mech: StringName, tokens: int, chooser: StringName) -> void:
	current_state = DAMAGE_PLACEMENT
	target_mech_id_for_tokens = target_mech
	token_count = tokens
	chooser_player_id = chooser


## 是否在攻击选择阶段（应显示取消按钮）
func is_in_selection_phase() -> bool:
	return current_state == SELECT_WEAPON or current_state == SELECT_TARGET
