import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from export_rule_data import normalize_id, require_fields, write_json


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


if __name__ == "__main__":
    unittest.main()
