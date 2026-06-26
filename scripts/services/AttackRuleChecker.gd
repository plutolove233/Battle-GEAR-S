## AttackRuleChecker.gd — 攻击合法性检查服务
##
## 从 AttackService 中提取的攻击前验证逻辑。
## 检查攻击者、目标、武器、攻击牌、射程等所有前置条件。
class_name AttackRuleChecker
extends RefCounted

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

var context = null  # type: GameContext

## 上一次检查的错误信息
var last_error: String = ""


## 检查攻击是否合法
## 返回: { legal: bool, error: String }
func can_declare_attack(attacker_id: StringName, target_id: StringName, weapon_id: StringName, attack_card_id: StringName) -> Dictionary:
	last_error = ""
	var gs = context.game_state

	# ── 攻击者检查 ──
	var attacker = gs.mechs.get(attacker_id)
	if attacker == null:
		last_error = "攻击者不存在"
		return {"legal": false, "error": last_error}
	if attacker.destroyed:
		last_error = "攻击者已被摧毁"
		return {"legal": false, "error": last_error}

	# ── 是否当前玩家 ──
	var attacker_player = gs.get_player_for_mech(attacker_id)
	if attacker_player == null or attacker_player.player_id != gs.active_player_id:
		last_error = "不是当前行动玩家"
		return {"legal": false, "error": last_error}

	# ── 是否主阶段 ──
	if gs.phase != &"MAIN":
		last_error = "当前不是主阶段"
		return {"legal": false, "error": last_error}

	# ── 攻击者是否不能攻击 ──
	if attacker.statuses.any(func(s: Dictionary) -> bool: return s.get("type", &"") == &"CANNOT_ATTACK"):
		last_error = "攻击者处于不可攻击状态"
		return {"legal": false, "error": last_error}

	# ── 本回合攻击次数 ──
	if not attacker.can_attack():
		last_error = "本回合攻击次数已用完"
		return {"legal": false, "error": last_error}

	# ── 攻击牌检查 ──
	var attack_card = gs.get_card(attack_card_id)
	if attack_card == null:
		last_error = "攻击牌不存在"
		return {"legal": false, "error": last_error}
	if not attack_card.def is _ActionCardDef:
		last_error = "攻击牌不是行动牌"
		return {"legal": false, "error": last_error}
	if attack_card.def.action_type != &"攻击":
		last_error = "攻击牌不是攻击类型"
		return {"legal": false, "error": last_error}
	if not attacker_player.action_hand.has(attack_card_id):
		last_error = "攻击牌不在手牌中"
		return {"legal": false, "error": last_error}

	# ── 武器检查 ──
	var weapon_card = gs.get_card(weapon_id)
	if weapon_card == null:
		last_error = "武器不存在"
		return {"legal": false, "error": last_error}
	var weapon_ids: Array[StringName] = attacker.get_weapon_ids()
	if not weapon_ids.has(weapon_id):
		last_error = "武器不属于该机甲"
		return {"legal": false, "error": last_error}
	# 武器是否在武器区
	if weapon_card.zone != &"equipment_slot":
		last_error = "武器不在装备区"
		return {"legal": false, "error": last_error}
	# 武器是否损坏
	if weapon_card.damage_tokens >= weapon_card.def.durability:
		last_error = "武器已损坏"
		return {"legal": false, "error": last_error}

	# ── 目标检查 ──
	var target = gs.mechs.get(target_id)
	if target == null:
		last_error = "目标不存在"
		return {"legal": false, "error": last_error}
	if target.destroyed:
		last_error = "目标已被摧毁"
		return {"legal": false, "error": last_error}

	# ── 射程检查 ──
	var weapon_range: int = _get_weapon_range(weapon_card)
	if not _is_in_weapon_range(attacker.position, target.position, weapon_range):
		last_error = "目标不在射程内"
		return {"legal": false, "error": last_error}

	return {"legal": true, "error": ""}


## ── 内部方法 ──


## 获取武器射程
func _get_weapon_range(weapon_card) -> int:
	if weapon_card and weapon_card.def and weapon_card.def is _EquipmentCardDef:
		return weapon_card.def.range_value
	return 1


## 检查目标是否在武器射程内（BFS动力可达）
func _is_in_weapon_range(origin: Dictionary, target: Dictionary, range_value: int) -> bool:
	# 使用 RangeCalculator（阶段2实现后替换）
	# 当前先用简单hex距离作为回退
	var dist: int = _HexGrid.distance(origin, target)
	return dist <= range_value
