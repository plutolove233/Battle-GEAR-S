## GameConfig.gd — 游戏常量配置
##
## 集中管理所有游戏规则常量，避免硬编码散落各处。
## 数值来源：机斗战甲规则书。
class_name GameConfig
extends RefCounted


## ── 初始资源 ──

## 初始金币
const INITIAL_GOLD: int = 15

## 每回合获得金币
const GOLD_PER_TURN: int = 2


## ── 抽牌 ──

## 每回合抽行动牌数
const DRAW_ACTION_PER_TURN: int = 2

## 每回合抽装备牌数
const DRAW_EQUIPMENT_PER_TURN: int = 1

## 行动牌手牌上限（默认，机师牌可修改）
const DEFAULT_ACTION_HAND_LIMIT: int = 5

## 花金币抽行动牌费用
const PAID_DRAW_ACTION_COST: int = 2

## 花金币抽1张行动牌
const PAID_DRAW_ACTION_COUNT: int = 1


## ── 攻击 ──

## 默认每回合攻击次数上限（机师牌可修改）
const DEFAULT_ATTACK_LIMIT: int = 1

## 损伤标记阈值：每5点攻击力产生1枚损伤标记
const DAMAGE_TOKEN_PER_POWER: int = 5


## ── 商店 ──

## 商店普通装备槽数
const SHOP_NORMAL_SLOTS: int = 3

## 刷新商店费用
const SHOP_REFRESH_COST: int = 2

## 查看隐藏高级装备费用
const SHOP_REVEAL_COST: int = 2

## 直接购买隐藏高级装备费用
const SHOP_BUY_HIDDEN_COST: int = 10


## ── 地图 ──

## 默认地图宽度（列数）
const DEFAULT_MAP_COLS: int = 24

## 默认地图高度（行数）
const DEFAULT_MAP_ROWS: int = 8

## 金币标记投骰面数
const GOLD_MARKER_D6: int = 6

## 陷阱爆炸范围（hex距离）
const TRAP_BLAST_RANGE: int = 1

## 陷阱爆炸基础伤害
const TRAP_BLAST_DAMAGE: int = 3

## 陷阱爆炸损伤标记数
const TRAP_BLAST_TOKENS: int = 1


## ── 胜利 ──

## 最大回合数（超过则按HP判定）
const MAX_TURNS: int = 30


## ── 装备卖出 ──

## 按稀有度的卖出价格
const SELL_PRICE_BY_RARITY: Dictionary = {
	&"N": 1,
	&"R": 2,
	&"SR": 3,
	&"SSR": 5,
}
