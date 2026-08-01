#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 part_id 精确重写 part_001-126 的 effect_ids，权威来源为两份拆解 spec：
  new_logic/装备牌效果拆解_001-066.txt
  new_logic/装备牌效果拆解_067-126.txt
每张牌首个 effect_ids：[...] 行即为权威绑定。保持原文件行尾（CRLF/LF）与缩进，
使 git diff 仅含 effect_ids 内容变更。
"""
import re

FN = "data/cards/equipment_parts.json"
SPECS = [
    "new_logic/装备牌效果拆解_001-066.txt",
    "new_logic/装备牌效果拆解_067-126.txt",
]


def parse_spec(fn):
    txt = open(fn, encoding="utf-8").read()
    out = {}
    for c in re.split(r"\n(?=\[装备牌 \d{3}\])", txt):
        mh = re.search(r"\[装备牌 (\d{3})\]", c)
        if not mh:
            continue
        num = mh.group(1)
        e = re.search(r"effect_ids：\[(.*?)\]", c)
        if not e:
            continue
        out[num] = re.findall(r"equipment_effect_(\d+)", e.group(1))
    return out


M = {}
for s in SPECS:
    M.update(parse_spec(s))

raw = open(FN, "rb").read()
text = raw.replace(b"\r\n", b"\n").decode("utf-8")
orig_crlf = b"\r\n" in raw


def build_block(nums, eol):
    ids = ['      "equipment_effect_' + n + '"' for n in nums]
    return '"effect_ids": [' + eol + ("," + eol).join(ids) + eol + "    ]"


eol = "\r\n" if orig_crlf else "\n"
cnt = 0
for num, nums in M.items():
    pat = re.compile(
        r'("id": "part_' + num + r'_[^"]*".*?"effect_ids": \[)([^\]]*)(\])',
        re.S,
    )

    def repl(mo, _nums=nums):
        pre = mo.group(1).rsplit('"effect_ids": [', 1)[0]
        return pre + build_block(_nums, eol)

    text, n = pat.subn(repl, text)
    cnt += n

out_eol = "\r\n" if orig_crlf else "\n"
open(FN, "wb").write(text.replace("\n", out_eol).encode("utf-8"))
print("replaced %d parts; orig_crlf=%s; total mapping=%d" % (cnt, orig_crlf, len(M)))
