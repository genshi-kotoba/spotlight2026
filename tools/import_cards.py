"""只读 Excel 的卡牌页，同步游戏 CSV；效果指令和解锁状态不由本脚本改写。"""
import argparse
import csv
import io
import json
from pathlib import Path

import openpyxl


ROOT = Path(__file__).resolve().parents[1]
FIELDS = [
    ("编号", "编号"), ("卡图资源路径", "卡图资源路径"), ("卡名", "卡名"),
    ("效果文本", "效果"), ("类型", "类型"), ("文本", "文本"), ("稀有度", "稀有度"),
]


def read_cards(workbook):
    book = openpyxl.load_workbook(workbook, data_only=True)
    try:
        rows = iter(book["卡牌"].values)
        headers = list(next(rows))
        missing = [source for _, source in FIELDS if source not in headers]
        if missing:
            raise ValueError(f"卡牌页缺少列：{missing}")
        records = []
        seen = set()
        for row_number, cells in enumerate(rows, 2):
            source = dict(zip(headers, cells))
            number = source["编号"]
            # 有格式但已清空的尾行不是卡牌，不能导成编号 None 的假记录。
            if number is None or str(number).strip() == "":
                if any(value is not None and str(value).strip() for value in cells):
                    raise ValueError(f"卡牌页第 {row_number} 行有数据但没有编号")
                continue
            if isinstance(number, bool):
                raise ValueError(f"卡牌页第 {row_number} 行的编号无效")
            if isinstance(number, float) and number.is_integer():
                number = int(number)
            card_id = str(number).strip()
            if card_id in seen:
                raise ValueError(f"重复卡牌编号：{card_id}")
            seen.add(card_id)
            record = {}
            for target, key in FIELDS:
                raw = source[key]
                record[target] = "暂无" if raw is None or str(raw).strip() == "" else str(raw).strip()
            record["编号"] = card_id
            records.append(record)
        if not records:
            raise ValueError("卡牌页没有有效记录，拒绝清空游戏目录")
        return records
    finally:
        book.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "data/text/cards.csv")
    parser.add_argument("--check", action="store_true", help="只校验，不写入任何文件")
    parser.add_argument("--accept-effect-changes", action="store_true", help="人工确认已同步效果JSON后，允许更新效果文本")
    args = parser.parse_args()
    records = read_cards(args.workbook)
    programs = json.loads((ROOT / "data/cards/formal/programs.json").read_text(encoding="utf-8"))
    missing = [record["编号"] for record in records if record["编号"] not in programs]
    if missing:
        raise ValueError(f"这些卡牌尚无事件队列效果定义，拒绝导入半成品目录：{missing}")
    old = []
    if args.output.exists():
        with args.output.open(encoding="utf-8-sig", newline="") as file:
            old = list(csv.DictReader(file))
    before = {record["编号"]: record for record in old}
    after = {record["编号"]: record for record in records}
    changed = [key for key in after if key in before and before[key] != after[key]]
    effects = [key for key in changed if before[key]["效果文本"] != after[key]["效果文本"]]
    print(f"Cards: {len(records)}; added: {[key for key in after if key not in before]}; "
          f"removed: {[key for key in before if key not in after]}; changed: {changed}")
    if effects and not args.accept_effect_changes:
        raise ValueError(f"效果文本已变化，先人工同步事件队列指令，再用 --accept-effect-changes 导入：{effects}")
    if args.check:
        if old != records:
            raise ValueError("当前游戏 CSV 与卡牌表不一致")
        print("CHECK PASS: every card field matches the workbook")
        return
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=[target for target, _ in FIELDS], lineterminator="\n")
    writer.writeheader()
    writer.writerows(records)
    args.output.write_text(output.getvalue(), encoding="utf-8", newline="")
    print(f"Imported {len(records)} cards -> {args.output}")


if __name__ == "__main__":
    main()
