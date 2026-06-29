## AttackService.gd — 攻击服务
##
## 实现两阶段攻击流程：
## 声明攻击 → 响应窗口 → 结算攻击
## 包含范围验证、伤害计算、损伤标记放置
class_name AttackService
extends RefCounted

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _BattleMath = preload("res://scripts/battle/battle_math.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

var context = null  # type: GameContext


## 声明攻击
## 验证条件 → 创建攻击上下文 → 消耗攻击牌 → 触发钩子 → 进入响应窗口
func declare_attack(attacker_id: StringName, target_id: StringName, weapon_id: StringName, attack_card_id: StringName) -> Dictionary:
	var gs = context.game_state

	# ── 1. 验证 ──
	var attacker = gs.mechs.get(attacker_id)
	var target = gs.mechs.get(target_id)

	if attacker == null:
		return {"ok": false, "message": "攻击者不存在"}
	if target == null:
		return {"ok": false, "message": "目标不存在"}
	if attacker.destroyed:
		return {"ok": false, "message": "攻击者已被摧毁"}
	if target.destroyed:
		return {"ok": false, "message": "目标已被摧毁"}

	# 验证武器属于攻击者
	var weapon_ids: Array[StringName] = attacker.get_weapon_ids()
	if not weapon_ids.has(weapon_id):
		return {"ok": false, "message": "武器不属于该机甲"}

	# 验证攻击牌在手牌中
	var player = gs.get_player_for_mech(attacker_id)
	if player == null:
		return {"ok": false, "message": "找不到攻击者所属玩家"}
	if not player.action_hand.has(attack_card_id):
		return {"ok": false, "message": "攻击牌不在手牌中"}

	# 验证攻击次数
	if not attacker.can_attack():
		return {"ok": false, "message": "本回合无法再攻击"}

	# 验证射程（使用RangeCalculator BFS动力可达）
	var weapon_card = gs.get_card(weapon_id)
	var weapon_range: int = _get_weapon_range(weapon_card)
	var map_cells: Dictionary = gs.map_state.cells if gs.map_state else {}
	if not _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, map_cells):
		return {"ok": false, "message": "目标不在射程内"}

	# ── 2. 创建攻击上下文 ──
	var attack_id: StringName = gs.next_id("attack")
	var weapon_might: int = _get_weapon_might(weapon_card)
	var attack_context: Dictionary = {
		"attack_id": attack_id,
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": weapon_id,
		"attack_card_id": attack_card_id,
		"power": weapon_might,
		"range_value": weapon_range,
		"hit": false,
		"cancelled": false,
	}
	gs.attacks[attack_id] = attack_context
	gs.current_attack_id = attack_id

	# ── 3. 从手牌移除攻击牌 ──
	player.action_hand.erase(attack_card_id)

	# ── 4. 消耗攻击次数 ──
	attacker.attack_count_this_turn += 1

	# ── 5. 触发攻击牌打出钩子 ──
	_fire_hook(_EffectConst.HOOK_ATTACK_CARD_PLAYED, {
		"attack_id": attack_id,
		"attacker_id": attacker_id,
		"attack_card_id": attack_card_id,
	})

	# ── 6. 触发攻击声明钩子 ──
	_fire_hook(_EffectConst.HOOK_ATTACK_DECLARED, {
		"attack_id": attack_id,
		"card_id": attack_card_id,
	})

	# ── 7. 检查是否被取消 ──
	if attack_context.get("cancelled", false):
		_cleanup_attack(attack_id)
		return {"ok": false, "message": "攻击被取消"}

	# ── 8. 触发响应窗口钩子 ──
	_fire_hook(_EffectConst.HOOK_ATTACK_RESPONSE_WINDOW, {
		"attack_id": attack_id,
		"attacker_id": attacker_id,
		"target_id": target_id,
	})

	gs.write_log(&"attack_declared", {
		"attack_id": String(attack_id),
		"attacker_id": String(attacker_id),
		"target_id": String(target_id),
	})
	return {"ok": true, "state": "awaiting_response", "attack_id": attack_id}


## 提交响应
## 记录响应牌和参数到攻击上下文
func submit_response(attack_id: StringName, response_card_id: StringName, payload: Dictionary) -> Dictionary:
	var gs = context.game_state
	var attack_context: Dictionary = gs.attacks.get(attack_id, {})

	if attack_context.is_empty():
		return {"ok": false, "message": "攻击上下文不存在"}

	# 记录响应信息
	attack_context["response_card_id"] = response_card_id
	attack_context["response_payload"] = payload

	# 从防守方手牌移除迎击牌
	var target_id: StringName = attack_context.get("target_id", &"")
	var defender_player = context.game_state.get_player_for_mech(target_id)
	if defender_player:
		defender_player.action_hand.erase(response_card_id)

	gs.write_log(&"attack_response", {
		"attack_id": String(attack_id),
		"response_card_id": String(response_card_id),
	})
	return {"ok": true, "attack_id": attack_id}


## 结算攻击
## 修正窗口 → 射程复查 → 命中判定 → 伤害计算 → 返回损伤放置信息
## 不再直接放置损伤标记，由 UI 层决定放置方式
func resolve_attack(attack_id: StringName) -> Dictionary:
	var gs = context.game_state
	var attack_context: Dictionary = gs.attacks.get(attack_id, {})

	if attack_context.is_empty():
		return {"ok": false, "message": "攻击上下文不存在"}

	var attacker_id: StringName = attack_context.get("attacker_id", &"")
	var target_id: StringName = attack_context.get("target_id", &"")
	var attacker = gs.mechs.get(attacker_id)
	var target = gs.mechs.get(target_id)

	# ── 1. 触发攻击修正窗口 ──
	_fire_hook(_EffectConst.HOOK_ATTACK_MODIFIER_WINDOW, {
		"attack_id": attack_id,
		"phase": "modifier_window",
	})

	# ── 2. 再次检查射程（目标可能在响应阶段移动了） ──
	var weapon_range: int = int(attack_context.get("range_value", 1))
	if attacker and target:
		var map_cells: Dictionary = gs.map_state.cells if gs.map_state else {}
		if not _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, map_cells):
			attack_context["hit"] = false
			_fire_hook(_EffectConst.HOOK_ATTACK_MISS, {
				"attack_id": attack_id,
				"miss": true,
			})
			_fire_hook(_EffectConst.HOOK_ATTACK_RESOLVED, {
				"attack_id": attack_id,
			})
			_cleanup_attack(attack_id)
			gs.write_log(&"attack_miss", {"attack_id": String(attack_id), "reason": "out_of_range"})
			return {"ok": true, "hit": false, "reason": "out_of_range"}

	# ── 3. 命中 ──
	attack_context["hit"] = true
	_fire_hook(_EffectConst.HOOK_ATTACK_HIT, {
		"attack_id": attack_id,
		"attacker_id": String(attacker_id),
		"target_id": String(target_id),
	})

	# ── 4. 计算伤害 ──
	var attack_power: int = int(attack_context.get("power", 0))
	var target_armor: int = 0
	if target:
		target_armor = target.get_armor()
	var calc_result: Dictionary = _BattleMath.calculate_attack(attack_power, target_armor)
	var damage: int = int(calc_result.get("damage", 0))
	var markers: int = int(calc_result.get("markers", 0))

	# ── 5. 触发伤害修正窗口 ──
	_fire_hook(_EffectConst.HOOK_DAMAGE_DEALT, {
		"attack_id": attack_id,
		"target_id": String(target_id),
		"damage": damage,
		"markers": markers,
	})

	# 从 temp_values 读取修正后的伤害（效果可能修改）
	damage = int(gs.temp_values.get("modified_damage", damage))
	markers = int(gs.temp_values.get("modified_markers", markers))

	# ── 6. 造成 HP 伤害（始终对原目标结算） ──
	if target and damage > 0:
		target.current_hp = max(0, target.current_hp - damage)
		if target.current_hp <= 0:
			gs.destroy_mech(target_id, "attack")

	# ── 7. 确定损伤放置参数 ──
	# 无迎击：攻击方选择放置在防守方机甲上
	# 有迎击：迎击方（防守方）选择放置在攻击方机甲上
	var responded: bool = attack_context.has("response_card_id") and attack_context.get("response_card_id", &"") != &""
	var target_mech_id_for_tokens: StringName
	var chooser_player_id: StringName

	if responded:
		# 迎击方选择损伤放在攻击方机甲上
		target_mech_id_for_tokens = attacker_id
		chooser_player_id = gs.get_player_for_mech(target_id).player_id if gs.get_player_for_mech(target_id) else &""
	else:
		# 攻击方选择损伤放在防守方机甲上
		target_mech_id_for_tokens = target_id
		chooser_player_id = gs.get_player_for_mech(attacker_id).player_id if gs.get_player_for_mech(attacker_id) else &""

	# ── 8. 触发攻击结算钩子 ──
	_fire_hook(_EffectConst.HOOK_ATTACK_RESOLVED, {
		"attack_id": attack_id,
		"hit": true,
		"damage": damage,
	})

	_cleanup_attack(attack_id)
	gs.write_log(&"attack_resolved", {
		"attack_id": String(attack_id),
		"hit": true,
		"damage": damage,
		"markers": markers,
	})

	return {
		"ok": true,
		"hit": true,
		"damage": damage,
		"markers": markers,
		"target_mech_id_for_tokens": target_mech_id_for_tokens,
		"chooser_player_id": chooser_player_id,
	}


## ── 内部方法 ──


## 获取武器威力
func _get_weapon_might(weapon_card) -> int:
	if weapon_card and weapon_card.def and weapon_card.def is _EquipmentCardDef:
		return weapon_card.def.might
	return 0


## 获取武器射程
func _get_weapon_range(weapon_card) -> int:
	if weapon_card and weapon_card.def and weapon_card.def is _EquipmentCardDef:
		return weapon_card.def.range_value
	return 1


## 触发效果钩子（通过 EffectEngine）
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)


## 清理攻击上下文
func _cleanup_attack(attack_id: StringName) -> void:
	var gs = context.game_state
	gs.attacks.erase(attack_id)
	if gs.current_attack_id == attack_id:
		gs.current_attack_id = &""
