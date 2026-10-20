"""只读附魔页，导出运行时表；不依赖错误的 worksheet dimensions。"""
import argparse
import json
from pathlib import Path
import openpyxl

SHORT_NAMES = ["弃牌入队", "回响", "锋锐", "轻灵", "残响", "血偿", "弃牌冲击",
               "弃牌抽取", "弃牌护盾", "指针回响", "指针回溯", "奋勇", "破盾",
               "伤害护盾", "汲取", "抽取", "易伤", "淬毒", "虚弱", "弃牌增伤", "弃牌增盾", "斩杀恢复"]


def read_enchantments(path):
    book = openpyxl.load_workbook(path, data_only=True, read_only=True)
    try:
        sheet = book["附魔"]
        sheet.reset_dimensions()
        rows = iter(sheet.values)
        if tuple(next(rows)[:4]) != ("编号", "效果", "类别", "符号"):
            raise ValueError("附魔表头不匹配")
        result = {}
        for row in rows:
            if not row or row[0] is None:
                continue
            number = int(row[0])
            key = {2: "repeat_2", 3: "damage_30"}.get(number, f"enchant_{number:03d}")
            if key in result or len(row) < 4 or any(value is None for value in row[:4]):
                raise ValueError(f"附魔行缺字段或编号重复：{row}")
            result[key] = {"number": number, "name": SHORT_NAMES[number - 1],
                           "text": str(row[1]).strip(), "type": str(row[2]).strip(),
                           "symbol": str(row[3]).strip(), "price": 100}
            # 用户本次确认的勘误；原工作簿保持只读，下次导入也不得恢复歧义旧文案。
            if number == 6:
                result[key]["text"] = "这张牌会对自己造成等额伤害，然后对敌人造成双倍伤害"
        if set(value["number"] for value in result.values()) != set(range(1, 23)):
            raise ValueError("当前实现要求附魔编号 1—22 全部存在")
        return result
    finally:
        book.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("workbook", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "data/cards/enchantments.json")
    args = parser.parse_args()
    data = read_enchantments(args.workbook)
    args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"导入 {len(data)} 种附魔：{args.output}")
