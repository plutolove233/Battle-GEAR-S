#!/usr/bin/env python3
import argparse
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

NS = {
    "s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}


def normalize_id(prefix: str, name: str, index: int) -> str:
    safe_name = re.sub(r"\s+", "_", str(name).strip())
    safe_name = re.sub(r"[^\w\u4e00-\u9fff]+", "_", safe_name)
    safe_name = safe_name.strip("_")
    return f"{prefix}_{index:03d}_{safe_name}"


def require_fields(row: dict, fields: list[str], dataset_name: str) -> None:
    for field in fields:
        if str(row.get(field, "")).strip() == "":
            row_id = row.get("id", "<no-id>")
            raise ValueError(f"{dataset_name} missing {field} in {row_id}")


def write_json(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(rows, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _column_index(cell_ref: str) -> int:
    match = re.match(r"([A-Z]+)", cell_ref or "")
    if not match:
        return 0
    result = 0
    for char in match.group(1):
        result = result * 26 + ord(char) - 64
    return result - 1


def _clean(value: str) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def read_xlsx(path: Path) -> dict[str, list[list[str]]]:
    with ZipFile(path) as archive:
        shared_strings: list[str] = []
        if "xl/sharedStrings.xml" in archive.namelist():
            shared_root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
            for item in shared_root.findall("s:si", NS):
                shared_strings.append("".join(t.text or "" for t in item.findall(".//s:t", NS)))

        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        rels = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        rel_map = {rel.attrib["Id"]: rel.attrib["Target"] for rel in rels}
        sheets: dict[str, list[list[str]]] = {}

        for sheet in workbook.findall(".//s:sheet", NS):
            name = sheet.attrib["name"]
            rel_id = sheet.attrib[f"{{{NS['r']}}}id"]
            target = rel_map[rel_id]
            if not target.startswith("xl/"):
                target = "xl/" + target
            sheet_root = ET.fromstring(archive.read(target))
            rows: list[list[str]] = []
            for row_node in sheet_root.findall(".//s:sheetData/s:row", NS):
                cells: list[tuple[int, str]] = []
                max_index = -1
                for cell in row_node.findall("s:c", NS):
                    index = _column_index(cell.attrib.get("r", ""))
                    value = ""
                    value_node = cell.find("s:v", NS)
                    if value_node is not None and value_node.text is not None:
                        if cell.attrib.get("t") == "s":
                            value = shared_strings[int(value_node.text)]
                        else:
                            value = value_node.text
                    inline_node = cell.find("s:is", NS)
                    if inline_node is not None:
                        value = "".join(t.text or "" for t in inline_node.findall(".//s:t", NS))
                    cells.append((index, _clean(value)))
                    max_index = max(max_index, index)
                values = [""] * (max_index + 1)
                for index, value in cells:
                    values[index] = value
                if any(values):
                    rows.append(values)
            sheets[name] = rows
        return sheets


def _row_dict(header: list[str], row: list[str]) -> dict[str, str]:
    return {header[index]: row[index] if index < len(row) else "" for index in range(len(header))}


def export_from_rule_dir(rule_dir: Path, output_dir: Path) -> None:
    action_book = read_xlsx(rule_dir / "行动+事件牌.xlsx")
    equipment_book = read_xlsx(rule_dir / "装备牌+机甲框架.xlsx")
    history_book = read_xlsx(rule_dir / "太空纪元历史线.xlsx")

    action_rows = []
    for index, row in enumerate(action_book["行动牌"][1:], start=1):
        source = _row_dict(action_book["行动牌"][0], row)
        name = source.get("名称", "")
        item = {
            "id": normalize_id("action", name, index),
            "name": name,
            "type": source.get("类型", ""),
            "rarity": source.get("品质", ""),
            "count": int(float(source.get("数量", "0") or 0)),
            "effect_text": source.get("效果", ""),
            "effect_id": "basic_attack" if name == "进攻" else "effect_unimplemented",
        }
        require_fields(item, ["id", "name", "type", "rarity", "effect_text"], "action_cards")
        action_rows.append(item)

    event_rows = []
    for index, row in enumerate(action_book["事件牌"][1:], start=1):
        source = _row_dict(action_book["事件牌"][0], row)
        name = source.get("名称", "")
        item = {
            "id": normalize_id("event", name, index),
            "name": name,
            "delay": int(float(source.get("延时", "0") or 0)),
            "tone": source.get("收益", ""),
            "rarity": source.get("品质", ""),
            "count": int(float(source.get("数量", "0") or 0)),
            "timing": source.get("计时方式", ""),
            "effect_text": source.get("效果", ""),
            "effect_id": "effect_unimplemented",
        }
        require_fields(item, ["id", "name", "rarity", "effect_text"], "event_cards")
        event_rows.append(item)

    parts = []
    for index, row in enumerate(equipment_book["装备牌部件"][1:], start=1):
        source = _row_dict(equipment_book["装备牌部件"][0], row)
        mech_name = source.get("机甲名称", "") or parts[-1]["set_name"]
        item = {
            "id": normalize_id("part", f"{mech_name}_{source.get('位置', '')}", index),
            "set_name": mech_name,
            "slot": source.get("位置", ""),
            "rarity": source.get("品质", ""),
            "count": int(float(source.get("数量", "0") or 0)),
            "effect_text": source.get("效果", ""),
            "armor": int(float(source.get("护甲", "0") or 0)),
            "power": int(float(source.get("动力", "0") or 0)),
            "durability": int(float(source.get("耐久", "0") or 0)),
            "cost": int(float(source.get("金币", "0") or 0)),
            "effect_id": "effect_unimplemented",
        }
        require_fields(item, ["id", "set_name", "slot", "rarity"], "equipment_parts")
        parts.append(item)

    weapons = []
    for index, row in enumerate(equipment_book["装备牌武器"][1:], start=1):
        source = _row_dict(equipment_book["装备牌武器"][0], row)
        item = {
            "id": normalize_id("weapon", source.get("武器名称", ""), index),
            "name": source.get("武器名称", ""),
            "weapon_type": source.get("类型", ""),
            "rarity": source.get("品质", ""),
            "count": int(float(source.get("数量", "0") or 0)),
            "effect_text": source.get("效果", ""),
            "damage": int(float(source.get("威力", "0") or 0)),
            "range": int(float(source.get("范围", "0") or 0)),
            "durability": int(float(source.get("耐久", "0") or 0)),
            "cost": int(float(source.get("金币", "0") or 0)),
            "effect_id": "effect_unimplemented",
        }
        require_fields(item, ["id", "name", "weapon_type", "rarity"], "equipment_weapons")
        weapons.append(item)

    history = []
    for index, row in enumerate(history_book["Sheet1"][1:], start=1):
        source = _row_dict(history_book["Sheet1"][0], row)
        item = {
            "id": normalize_id("history", source.get("事件", "")[:12], index),
            "era": source.get("纪元", ""),
            "year": source.get("年份", ""),
            "month": source.get("月份", ""),
            "day": source.get("日期", ""),
            "place": source.get("地点", ""),
            "event": source.get("事件", ""),
            "tag": source.get("标签", ""),
        }
        require_fields(item, ["id", "era", "year", "event"], "history_nodes")
        history.append(item)

    write_json(output_dir / "cards/action_cards.json", action_rows)
    write_json(output_dir / "cards/event_cards.json", event_rows)
    write_json(output_dir / "cards/equipment_parts.json", parts)
    write_json(output_dir / "cards/equipment_weapons.json", weapons)
    write_json(output_dir / "lore/history_nodes.json", history)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rule-dir", default="rule")
    parser.add_argument("--output-dir", default="data")
    args = parser.parse_args()
    export_from_rule_dir(Path(args.rule_dir), Path(args.output_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
