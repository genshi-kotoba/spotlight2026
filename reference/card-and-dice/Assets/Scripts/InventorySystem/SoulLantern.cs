// =============================================================================
// 模块：M7 背包系统 - SoulLantern 魂灯
// 用途：存放灵魂的容器（spec §7）。容量 10，灵魂不可堆叠（1 条 = 1 格）
// 设计依据：spec §7 + 《废墟图书馆》敌人之书式专属灵魂
// 说明：魂灯物品本身占常规分区 1 格（ItemType.容器），本类只管灯内灵魂
// =============================================================================
using System;
using System.Collections.Generic;

public class SoulLantern
{
    /// <summary>本阶段固定容量（spec §16；未来局外/被动升级扩容）</summary>
    public const int Capacity = 10;

    /// <summary>灯内灵魂（每项一条，按获得顺序）</summary>
    public readonly List<ItemData> Souls = new List<ItemData>();

    /// <summary>灯内变化（UI 刷新用）</summary>
    public event Action OnChanged;

    public bool IsFull => Souls.Count >= Capacity;

    public int Count => Souls.Count;

    /// <summary>放入一条灵魂。灯满或非灵魂物品 → false。</summary>
    public bool TryAdd(ItemData soul)
    {
        if (soul == null || soul.type != ItemType.灵魂 || IsFull) return false;
        Souls.Add(soul);
        OnChanged?.Invoke();
        return true;
    }

    /// <summary>销毁指定序号的灵魂（灯满时腾空间 / 玩家主动销毁）。成功 → true。</summary>
    public bool RemoveAt(int index)
    {
        if (index < 0 || index >= Souls.Count) return false;
        Souls.RemoveAt(index);
        OnChanged?.Invoke();
        return true;
    }

    /// <summary>同种灵魂数量（魂灯界面显示用）。</summary>
    public int CountOf(ItemData soul)
    {
        int n = 0;
        foreach (ItemData s in Souls) if (s == soul) n++;
        return n;
    }

    public void Clear()
    {
        if (Souls.Count == 0) return;
        Souls.Clear();
        OnChanged?.Invoke();
    }
}
