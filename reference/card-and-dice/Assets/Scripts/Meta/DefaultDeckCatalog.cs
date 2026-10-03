// =============================================================================
// 模块：Meta - DefaultDeckCatalog 固定初始卡组目录
// 用途：固定初始卡组的**单一数据源**——藏身处整装面板「初始卡组」展示 +
//       开局 CardDeckManager.BuildRuntimeDeck 构建都读它。
//       目录缺失时 CardDeckManager 退回 Inspector 配置（老链路，不阻断游戏）。
// 资产位置：Assets/Resources/DefaultDeckCatalog.asset
// 生成/补齐：菜单 Tools/藏身处/3. 默认卡组目录（从场景里的 CardDeckManager 配置抄录）
// 设计依据：docs/2026-09-16_藏身处-design.md §5（B4 整装三页）
// =============================================================================
using System;
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "默认卡组目录", menuName = "CardDice/默认卡组目录")]
public class DefaultDeckCatalog : ScriptableObject
{
    public const string ResourcePath = "DefaultDeckCatalog";

    [Serializable]
    public class Entry
    {
        public CardData card;
        public int count = 1;
    }

    public List<Entry> entries = new List<Entry>();

    /// <summary>取 Resources 资产；没有资产返回 null（调用方自行降级）。</summary>
    public static DefaultDeckCatalog Load()
    {
        return Resources.Load<DefaultDeckCatalog>(ResourcePath);
    }
}
