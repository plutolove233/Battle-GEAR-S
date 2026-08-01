# -*- coding: utf-8 -*-
import json, re, io, sys

DOC = "new_logic/装备牌部件_全部装备牌信息.txt"
JSON_PATH = "data/cards/equipment_parts.json"

def parse_doc(path):
    with io.open(path, encoding="utf-8") as f:
        text = f.read()
    cards = {}
    blocks = re.split(r"\n【(\d{3})】\n", text)
    for i in range(1, len(blocks), 2):
        num = blocks[i]
        body = blocks[i+1]
        card = {"num": num}
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("名称："): card["name"] = line[3:]
            elif line.startswith("设置的位置："): card["slot"] = line[len("设置的位置："):]
            elif line.startswith("护甲："): card["armor"] = line[3:]
            elif line.startswith("动力："): card["power"] = line[3:]
            elif line.startswith("耐久："): card["durability"] = line[3:]
            elif line.startswith("金币："): card["cost"] = line[3:]
            elif line.startswith("效果文本："): card["effect_text"] = line[len("效果文本："):]
        cards[num] = card
    return cards

def main():
    doc = parse_doc(DOC)
    with io.open(JSON_PATH, encoding="utf-8") as f:
        arr = json.load(f)

    # build num -> json index
    num_to_idx = {}
    for idx, c in enumerate(arr):
        m = re.match(r"part_(\d{3})_", c["id"])
        if m:
            num_to_idx[m.group(1)] = idx

    changes = []
    for num in sorted(doc.keys()):
        d = doc[num]
        if num not in num_to_idx:
            print("WARN: no json for", num); continue
        c = arr[num_to_idx[num]]
        # update numerical values
        for fld, dv in [("armor", d["armor"]), ("power", d["power"]),
                        ("durability", d["durability"]), ("cost", d["cost"])]:
            iv = int(dv)
            if c.get(fld) != iv:
                changes.append((num, c["id"], fld, c.get(fld), iv))
                c[fld] = iv
        # update effect_text
        if c.get("effect_text") != d["effect_text"]:
            changes.append((num, c["id"], "effect_text", c.get("effect_text"), d["effect_text"]))
            c["effect_text"] = d["effect_text"]

    with io.open(JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(arr, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print("Applied %d field changes across cards." % len(changes))
    # summary by card
    from collections import Counter
    cnt = Counter(ch[0] for ch in changes)
    print("Cards touched: %d" % len(cnt))

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
