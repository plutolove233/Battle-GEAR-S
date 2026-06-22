import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from export_rule_data import export_from_rule_dir, normalize_id, require_fields, write_json


class ExportRuleDataTest(unittest.TestCase):
    def test_normalize_id_keeps_chinese_readable(self):
        self.assertEqual(normalize_id("action", "进攻", 1), "action_001_进攻")

    def test_require_fields_rejects_empty_required_value(self):
        row = {"id": "card_001", "name": "", "rarity": "N"}
        with self.assertRaises(ValueError) as ctx:
            require_fields(row, ["id", "name", "rarity"], "action_cards")
        self.assertIn("action_cards missing name", str(ctx.exception))

    def test_write_json_creates_pretty_utf8_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "cards.json"
            write_json(target, [{"id": "action_001_进攻", "name": "进攻"}])
            loaded = json.loads(target.read_text(encoding="utf-8"))
            self.assertEqual(loaded[0]["name"], "进攻")

    def test_export_skips_action_footer_rows(self):
        books = {
            "行动+事件牌.xlsx": {
                "行动牌": [
                    ["名称", "类型", "品质", "效果", "数量"],
                    ["进攻", "攻击", "N", "选择1把武器对1台范围内的机甲发动攻击。", "14"],
                    ["", "", "", "", "152", ""],
                ],
                "事件牌": [["名称", "延时", "收益", "品质", "数量", "计时方式", "效果"]],
            },
            "装备牌+机甲框架.xlsx": {
                "装备牌部件": [["机甲名称", "位置", "品质", "数量", "效果", "护甲", "动力", "耐久", "金币"]],
                "装备牌武器": [["武器名称", "类型", "品质", "数量", "效果", "威力", "范围", "耐久", "金币"]],
            },
            "太空纪元历史线.xlsx": {"Sheet1": [["纪元", "年份", "月份", "日期", "地点", "事件", "标签"]]},
        }

        with tempfile.TemporaryDirectory() as tmp:
            with patch("export_rule_data.read_xlsx", side_effect=lambda path: books[path.name]):
                export_from_rule_dir(Path("rule"), Path(tmp))

            action_cards = json.loads((Path(tmp) / "cards/action_cards.json").read_text(encoding="utf-8"))
            self.assertEqual([card["name"] for card in action_cards], ["进攻"])

    def test_export_rejects_leading_part_continuation_with_context(self):
        books = {
            "行动+事件牌.xlsx": {
                "行动牌": [["名称", "类型", "品质", "效果", "数量"]],
                "事件牌": [["名称", "延时", "收益", "品质", "数量", "计时方式", "效果"]],
            },
            "装备牌+机甲框架.xlsx": {
                "装备牌部件": [
                    ["机甲名称", "位置", "品质", "数量", "效果", "护甲", "动力", "耐久", "金币"],
                    ["", "头部", "N", "1", "缺少套装名称。", "1", "0", "1", "1"],
                ],
                "装备牌武器": [["武器名称", "类型", "品质", "数量", "效果", "威力", "范围", "耐久", "金币"]],
            },
            "太空纪元历史线.xlsx": {"Sheet1": [["纪元", "年份", "月份", "日期", "地点", "事件", "标签"]]},
        }

        with tempfile.TemporaryDirectory() as tmp:
            with patch("export_rule_data.read_xlsx", side_effect=lambda path: books[path.name]):
                with self.assertRaises(ValueError) as ctx:
                    export_from_rule_dir(Path("rule"), Path(tmp))

        self.assertIn("equipment_parts missing set_name in sheet 装备牌部件 row 2", str(ctx.exception))

    def test_export_inherits_history_year_for_continuation_rows(self):
        books = {
            "行动+事件牌.xlsx": {
                "行动牌": [["名称", "类型", "品质", "效果", "数量"]],
                "事件牌": [["名称", "延时", "收益", "品质", "数量", "计时方式", "效果"]],
            },
            "装备牌+机甲框架.xlsx": {
                "装备牌部件": [["机甲名称", "位置", "品质", "数量", "效果", "护甲", "动力", "耐久", "金币"]],
                "装备牌武器": [["武器名称", "类型", "品质", "数量", "效果", "威力", "范围", "耐久", "金币"]],
            },
            "太空纪元历史线.xlsx": {
                "Sheet1": [
                    ["序号", "纪元", "年份", "月份", "日期", "地点", "事件", "标签"],
                    ["1", "S.E.", "231", "9", "", "", "前置事件", ""],
                    ["2", "S.E.", "", "10", "", "", "延续事件", ""],
                ]
            },
        }

        with tempfile.TemporaryDirectory() as tmp:
            with patch("export_rule_data.read_xlsx", side_effect=lambda path: books[path.name]):
                export_from_rule_dir(Path("rule"), Path(tmp))

            history = json.loads((Path(tmp) / "lore/history_nodes.json").read_text(encoding="utf-8"))
            self.assertEqual(history[1]["year"], "231")


if __name__ == "__main__":
    unittest.main()
