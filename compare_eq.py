# -*- coding: utf-8 -*-
import json, re, io, sys
# force UTF-8 output on Windows console
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

DOC = "new_logic/装备牌部件_全部装备牌信息.txt"
JSON_PATH = "data/cards/equipment_parts.json"
OUT = "eq_diff_report.txt"
_out = io.open(OUT, "w", encoding="utf-8")
def P(s=""):
    _out.write(s + "\n")

def parse_doc(path):
    with io.open(path, encoding="utf-8") as f:
        text = f.read()
    cards = {}
    # split by card block header 【NNN】
    blocks = re.split(r"\n【(\d{3})】\n", text)
    # blocks[0] is preamble, then pairs (num, body)
    for i in range(1, len(blocks), 2):
        num = blocks[i]
        body = blocks[i+1]
        card = {"num": num}
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("名称："):
                card["name"] = line[len("名称："):]
            elif line.startswith("设置的位置："):
                card["slot"] = line[len("设置的位置："):]
            elif line.startswith("护甲："):
                card["armor"] = line[len("护甲："):]
            elif line.startswith("动力："):
                card["power"] = line[len("动力："):]
            elif line.startswith("耐久："):
                card["durability"] = line[len("耐久："):]
            elif line.startswith("金币："):
                card["cost"] = line[len("金币："):]
            elif line.startswith("效果文本："):
                card["effect_text"] = line[len("效果文本："):]
        cards[num] = card
    return cards

def load_json(path):
    with io.open(path, encoding="utf-8") as f:
        arr = json.load(f)
    out = {}
    for c in arr:
        out[c["id"]] = c
    return out

def main():
    doc = parse_doc(DOC)
    js = load_json(JSON_PATH)

    P("="*80)
    P("差异报告: 权威文档 vs equipment_parts.json")
    P("="*80)

    # Map doc num -> json id
    # json id like part_001_量产装_头部
    total_diffs = 0
    card_diffs = []
    for num in sorted(doc.keys()):
        d = doc[num]
        # find json card whose id starts with part_<num>_
        jid = None
        j = None
        for k, v in js.items():
            if k.startswith("part_%s_" % num):
                jid = k; j = v; break
        if j is None:
            P("\n### 【%s】 %s  -- JSON中未找到对应牌!" % (num, d.get("name")))
            total_diffs += 1
            continue
        diffs = []
        # name: doc name = set_name + "·" + slot
        expected_name = j.get("set_name","") + "·" + j.get("slot","")
        if expected_name != d.get("name",""):
            diffs.append(("名称", d.get("name",""), expected_name))
        # slot
        if d.get("slot","") != j.get("slot",""):
            diffs.append(("设置的位置", d.get("slot",""), j.get("slot","")))
        # armor
        if str(d.get("armor","")) != str(j.get("armor","")):
            diffs.append(("护甲", d.get("armor",""), j.get("armor","")))
        # power
        if str(d.get("power","")) != str(j.get("power","")):
            diffs.append(("动力", d.get("power",""), j.get("power","")))
        # durability
        if str(d.get("durability","")) != str(j.get("durability","")):
            diffs.append(("耐久", d.get("durability",""), j.get("durability","")))
        # cost
        if str(d.get("cost","")) != str(j.get("cost","")):
            diffs.append(("金币", d.get("cost",""), j.get("cost","")))
        # effect_text
        if d.get("effect_text","") != j.get("effect_text",""):
            diffs.append(("效果文本", d.get("effect_text",""), j.get("effect_text","")))

        if diffs:
            total_diffs += 1
            card_diffs.append((num, d, j, diffs))
            P("\n### 【%s】 %s (json: %s)" % (num, d.get("name",""), jid))
            for fld, docv, jsv in diffs:
                P("  [%s]" % fld)
                P("    权威文档: %s" % docv)
                P("    当前JSON: %s" % jsv)

    P("\n" + "="*80)
    P("共有差异的牌数: %d / %d" % (total_diffs, len(doc)))
    P("="*80)

    # Also: any JSON cards not in doc (besides test card)?
    P("\nJSON中有但文档中没有的牌:")
    for k, v in js.items():
        m = re.match(r"part_(\d{3})_", k)
        if not m:
            P("  %s (非编号牌)" % k)
            continue
        num = m.group(1)
        if num not in doc:
            P("  %s" % k)

if __name__ == "__main__":
    main()
