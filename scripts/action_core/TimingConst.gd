## TimingConst.gd — 时点常量定义
##
## 定义所有游戏动作生命周期中的时点（Timing Point）。
## 每个时点对应动作执行流程中的一个暂停点，
## 效果可以监听时点并在时点触发时执行。
##
## 参考：new_logic/各动作的生命周期与时点.docx
extends RefCounted
class_name TimingConst

## ── 效果模式 ──
const MODE_DIRECT := &"DIRECT"          ## 直接执行：使用行动牌时立即执行
const MODE_LISTEN := &"LISTEN"          ## 监听型：监听指定动作的指定时点
const MODE_AVAILABILITY := &"AVAILABILITY"  ## 可用条件型：在响应窗口等场景中作为可选牌出现

## ── 可用条件类型 ──
const AVAIL_RESPOND_ATTACK := &"RESPOND_ATTACK"  ## 响应攻击：当被攻击时可用
const AVAIL_ALLY_IN_RANGE_TARGETED := &"ALLY_IN_RANGE_TARGETED"  ## 掩护：攻击范围内友方被攻击时可用

## ── 回合周期 ──
const ROUND_START           := &"ROUND_START"             ## 新轮次开始（优先于回合开始前）
const TURN_BEFORE_START     := &"TURN_BEFORE_START"       ## 回合开始前
const TURN_START            := &"TURN_START"              ## 回合开始时（回复动力）
const TURN_AFTER_START      := &"TURN_AFTER_START"        ## 回合开始后（抽牌+金币之后）
const TURN_BEFORE_END       := &"TURN_BEFORE_END"         ## 回合结束前
const TURN_END              := &"TURN_END"                ## 回合结束时
const TURN_AFTER_END        := &"TURN_AFTER_END"          ## 回合结束后

## ── 攻击动作 ──
const ATTACK_BEFORE         := &"ATTACK_BEFORE"           ## 攻击前（选择武器后）
const ATTACK_PRE            := &"ATTACK_PRE"              ## 攻击时前（选择目标后）
const ATTACK_AT             := &"ATTACK_AT"               ## 攻击时（发动攻击，响应窗口）
const ATTACK_AFTER          := &"ATTACK_AFTER"            ## 攻击后（伤害计算后）
const ATTACK_SETTLE         := &"ATTACK_SETTLE"           ## 攻击结算（清理动作信息）

## ── 使用行动牌动作 ──
const USE_ACTION_BEFORE     := &"USE_ACTION_BEFORE"       ## 使用行动牌前
const USE_ACTION_AT         := &"USE_ACTION_AT"           ## 使用行动牌时（牌进入临时区后）
const USE_ACTION_AFTER      := &"USE_ACTION_AFTER"        ## 使用行动牌后
const USE_ACTION_SETTLE     := &"USE_ACTION_SETTLE"       ## 使用行动牌结算

## ── 数值修正动作 ──
const STAT_MOD_BEFORE       := &"STAT_MOD_BEFORE"         ## 数值修正前
const STAT_MOD_AFTER        := &"STAT_MOD_AFTER"          ## 数值修正后
const STAT_MOD_SETTLE       := &"STAT_MOD_SETTLE"         ## 数值修正结算

## ── 移动动作 ──
const BASIC_MOVE_BEFORE     := &"BASIC_MOVE_BEFORE"       ## 基础移动前
const BASIC_MOVE_AT         := &"BASIC_MOVE_AT"           ## 基础移动时
const BASIC_MOVE_AFTER      := &"BASIC_MOVE_AFTER"        ## 基础移动后
const BASIC_MOVE_SETTLE     := &"BASIC_MOVE_SETTLE"       ## 基础移动结算
const SINGLE_MOVE_SETTLE    := &"SINGLE_MOVE_SETTLE"      ## 单次移动结算

## ── 设置装备牌动作 ──
const SET_EQUIP_BEFORE      := &"SET_EQUIP_BEFORE"        ## 设置装备牌前
const SET_EQUIP_AT          := &"SET_EQUIP_AT"            ## 设置装备牌时
const SET_EQUIP_AFTER       := &"SET_EQUIP_AFTER"         ## 设置装备牌后
const SET_EQUIP_SETTLE      := &"SET_EQUIP_SETTLE"        ## 设置装备牌结算

## ── 获取牌动作 ──
const GAIN_CARD_BEFORE      := &"GAIN_CARD_BEFORE"        ## 获取牌前
const GAIN_CARD_AFTER       := &"GAIN_CARD_AFTER"         ## 获取牌后
const GAIN_CARD_SETTLE      := &"GAIN_CARD_SETTLE"        ## 获取牌结算

## ── 弃置牌动作 ──
const DISCARD_BEFORE        := &"DISCARD_BEFORE"          ## 弃置牌前
const DISCARD_AFTER         := &"DISCARD_AFTER"           ## 弃置牌后
const DISCARD_SETTLE        := &"DISCARD_SETTLE"          ## 弃置牌结算

## ── 效果发动动作 ──
const EFFECT_FIRE_BEFORE    := &"EFFECT_FIRE_BEFORE"      ## 效果发动前
const EFFECT_FIRE_AFTER     := &"EFFECT_FIRE_AFTER"       ## 效果发动后
const EFFECT_FIRE_SETTLE    := &"EFFECT_FIRE_SETTLE"      ## 效果发动结算

## ── 生命变动动作 ──
const HP_CHANGE_BEFORE      := &"HP_CHANGE_BEFORE"        ## 生命变动前
const HP_CHANGE_AFTER       := &"HP_CHANGE_AFTER"         ## 生命变动后
const HP_CHANGE_SETTLE      := &"HP_CHANGE_SETTLE"        ## 生命变动结算

## ── 损伤变动动作 ──
const DAMAGE_CHANGE_BEFORE  := &"DAMAGE_CHANGE_BEFORE"    ## 损伤变动前
const DAMAGE_CHANGE_AFTER   := &"DAMAGE_CHANGE_AFTER"     ## 损伤变动后
const DAMAGE_CHANGE_SETTLE  := &"DAMAGE_CHANGE_SETTLE"    ## 损伤变动结算

## ── 损伤转移窗口（A6 装备损伤转移）──
## damage_change 动作在 place_damage_tokens 前 fire 此时点，
## 转移效果（联邦右臂 effect_004 / 机动右臂 effect_019）监听并弹汇总窗选转移点数，
## 提交后写 damage_change.record["redirect_plan"]，place_damage_tokens 按转移后目标放置。
const DAMAGE_REDIRECT_WINDOW := &"DAMAGE_REDIRECT_WINDOW"

## ── 展示牌动作 ──
const SHOW_CARD_BEFORE      := &"SHOW_CARD_BEFORE"        ## 展示牌前
const SHOW_CARD_AFTER       := &"SHOW_CARD_AFTER"         ## 展示牌后
const SHOW_CARD_SETTLE      := &"SHOW_CARD_SETTLE"        ## 展示牌结算

## ── 胜利条件 ──
const VICTORY_REACHED       := &"VICTORY_REACHED"         ## 达到胜利条件
