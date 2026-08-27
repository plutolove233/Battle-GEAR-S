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

## ── 金币 ──
const GAIN_GOLD_AFTER       := &"GAIN_GOLD_AFTER"           ## 获得金币后（payload: gainer_player_id/gainer_mech_id/amount/from_player_id/reason）
const GIVE_GOLD_AFTER       := &"GIVE_GOLD_AFTER"           ## 给予其他玩家金币后（payload: giver_player_id/gainer_player_id/amount）

## ── 商店购买（虚拟时点，非动作步骤时点）──
## 购买成功后发出（ShopService 三条购买路径统一 fire），供"购买后触发"类效果（莉卡尔 pilot_054 等）监听。
## payload: player_id（购买者）/buyer_mech_id/card_id/is_advanced（是否高级装备=SR/SSR稀有度）/price
const SHOP_BUY_AFTER        := &"SHOP_BUY_AFTER"            ## 商店购买装备牌后

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

## ── 动力消耗事件（虚拟时点，非动作步骤时点）──
## GameActions.spend_power 对全部动力消耗路径统一通知（reason=BASIC_MOVE 除外：移动消耗由
## BASIC_MOVE_AT 时点监听避免双计）。动力税类效果（杰西卡 pilot_050 e1 等）LISTEN 此时点。
const POWER_SPENT           := &"power_spent"             ## 动力消耗（消耗时立即阻塞）

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

## ── 卡牌离堆（pilot_003 瑟尔基尔 effect_02）──
const CARD_LEAVE_ACTION_DECK_BEFORE := &"CARD_LEAVE_ACTION_DECK_BEFORE"  ## 行动牌离开牌堆前

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

## ── 设置事件牌动作 ──
## set_event_card 动作步骤时点（事件标记拾取/计时结束抽新牌等路径统一走该动作）
const EVENT_SET_BEFORE      := &"EVENT_SET_BEFORE"        ## 设置事件牌前
const EVENT_SET_AT          := &"EVENT_SET_AT"            ## 设置事件牌时（放置到事件区域）
const EVENT_SET_AFTER       := &"EVENT_SET_AFTER"         ## 设置事件牌后（效果已注册）
const EVENT_SET_SETTLE      := &"EVENT_SET_SETTLE"        ## 设置事件牌结算
const EVENT_RESOLVE         := &"EVENT_RESOLVE"           ## 事件牌结算（instant 牌设置后即刻结算）
const EVENT_TIMER_TICK      := &"EVENT_TIMER_TICK"        ## 事件计时-1（payload: event_card_id/mech_id/timer/before）
const EVENT_TIMER_EXPIRE    := &"EVENT_TIMER_EXPIRE"      ## 事件计时归零（到期结算，先于弃置；payload: event_card_id/mech_id）

## ── 胜利条件 ──
const VICTORY_REACHED       := &"VICTORY_REACHED"         ## 达到胜利条件

## ── 掩护窗口附加选项（虚拟时点，非动作步骤时点）──
## 不会被 fire_timing 正常触发：仅由掩护多选窗（CHOOSE_MANY_CARDS collect_cover_window_extras）
## 收集窗口拥有玩家注册在此的监听效果，作为复选框附加选项展示（洛尔恩 pilot_062 转化掩护）。
## 选中后由确认路径直接 _execute_actions 该效果，此时点只作存储/遍历入口。
const COVER_WINDOW_EXTRA     := &"COVER_WINDOW_EXTRA"     ## 掩护窗口附加选项（复选框）
const THRUST_WINDOW_EXTRA    := &"THRUST_WINDOW_EXTRA"    ## 推进窗口附加选项（复选框，温斯顿 pilot_082 转化推进）
