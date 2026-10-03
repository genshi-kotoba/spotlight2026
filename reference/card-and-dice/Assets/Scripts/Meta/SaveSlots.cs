// =============================================================================
// 模块：Meta - SaveSlots 多存档位管理（局外持久化）
// 用途：把原来唯一的 meta_save.json 拆成 3 个**互相独立**的存档位
//       （persistentDataPath/meta_save_slot{1,2,3}.json），供「藏身处右下角三存档区」使用。
// 设计依据：用户 2026-09-14 决策——右下角三个存档区域、三个独立存档位；
//           每次来到藏身处自动保存；可单独清空。
//
// 职责边界：本类只负责「文件系统 + 当前槽索引」，不认识钱包内容语义；
//           MetaWallet 通过 SaveSlots.ActiveSlotPath 决定读写哪个文件。
// 兼容：首次访问时若发现旧的单档 meta_save.json 且三个槽都不存在 → 自动迁移为「存档 1」，
//       避免老进度凭空消失（迁移只做一次，不覆盖任何已有槽）。
// =============================================================================
using System;
using System.IO;
using UnityEngine;

public static class SaveSlots
{
    /// <summary>存档位数量（用户定稿：3）。</summary>
    public const int Count = 3;

    /// <summary>当前存档位在 PlayerPrefs 里的键（跨 Play 保留）。</summary>
    const string ActivePrefKey = "saveslot.active";

    /// <summary>旧版单档文件名（仅用于一次性迁移）。</summary>
    const string LegacyFileName = "meta_save.json";

    // ------------------------------------------------------------------
    // 路径
    // ------------------------------------------------------------------

    /// <summary>某个槽的存档文件绝对路径。slot 会被夹到 [1, Count]。</summary>
    public static string PathFor(int slot)
    {
        slot = Mathf.Clamp(slot, 1, Count);
        return Path.Combine(Application.persistentDataPath, $"meta_save_slot{slot}.json");
    }

    /// <summary>当前槽的存档文件绝对路径（MetaWallet 读写都走这里）。</summary>
    public static string ActiveSlotPath => PathFor(ActiveSlot);

    static string LegacyPath => Path.Combine(Application.persistentDataPath, LegacyFileName);

    // ------------------------------------------------------------------
    // 当前槽
    // ------------------------------------------------------------------

    static bool _legacyChecked;

    /// <summary>当前存档位（1..Count），首次读取会顺带做一次旧档迁移。</summary>
    public static int ActiveSlot
    {
        get
        {
            MigrateLegacyOnce();
            return Mathf.Clamp(PlayerPrefs.GetInt(ActivePrefKey, 1), 1, Count);
        }
    }

    /// <summary>设置当前存档位（立即写 PlayerPrefs）。</summary>
    public static void SetActive(int slot)
    {
        MigrateLegacyOnce();
        slot = Mathf.Clamp(slot, 1, Count);
        PlayerPrefs.SetInt(ActivePrefKey, slot);
        PlayerPrefs.Save();
        Debug.Log($"[SaveSlots] 当前存档位 → {slot}");
    }

    // ------------------------------------------------------------------
    // 读 / 判空 / 清空
    // ------------------------------------------------------------------

    /// <summary>该槽是否已有存档文件。</summary>
    public static bool Exists(int slot)
    {
        MigrateLegacyOnce();
        try { return File.Exists(PathFor(slot)); }
        catch (Exception e) { Debug.LogWarning($"[SaveSlots] 槽 {slot} 存在性检查失败：{e.Message}"); return false; }
    }

    /// <summary>读取某槽的存档数据；文件不存在或解析失败返回 false（data 为 null）。</summary>
    public static bool TryRead(int slot, out MetaWallet.SaveData data)
    {
        data = null;
        try
        {
            string p = PathFor(slot);
            if (!File.Exists(p)) return false;
            data = JsonUtility.FromJson<MetaWallet.SaveData>(File.ReadAllText(p));
            return data != null;
        }
        catch (Exception e)
        {
            Debug.LogWarning($"[SaveSlots] 槽 {slot} 读取失败：{e.Message}");
            return false;
        }
    }

    /// <summary>判定一份存档是否等同「空档」（无文件 / 全零 = 没有可看的进度）。</summary>
    public static bool IsEmpty(MetaWallet.SaveData d)
    {
        if (d == null) return true;
        return MaterialTotal(d) == 0 && SoulTotal(d) == 0
               && d.tutorialStage == 0 && d.corpseX < 0;
    }

    /// <summary>一份存档里的材料总件数（★v2.1 材料按种类存：按堆求和；含旧档遗留的整数计数）。</summary>
    static int MaterialTotal(MetaWallet.SaveData d)
    {
        if (d == null) return 0;
        int n = d.materials;   // 旧档遗留字段（未迁移的整数材料）
        if (d.materialStacks != null)
            foreach (MetaWallet.NamedStack s in d.materialStacks)
                if (s != null) n += s.count;
        return n;
    }

    /// <summary>一份存档里的灵魂总数（★2026-09-14 灵魂按种类存：按堆求和；含旧档遗留的整数计数）。</summary>
    static int SoulTotal(MetaWallet.SaveData d)
    {
        if (d == null) return 0;
        int n = d.souls;   // 旧档遗留字段
        if (d.soulStacks != null)
            foreach (MetaWallet.NamedStack s in d.soulStacks)
                if (s != null) n += s.count;
        return n;
    }

    /// <summary>删除某槽的存档文件。</summary>
    public static void Clear(int slot)
    {
        try
        {
            string p = PathFor(slot);
            if (File.Exists(p)) { File.Delete(p); Debug.Log($"[SaveSlots] 槽 {slot} 已清空（文件已删除）"); }
            else Debug.Log($"[SaveSlots] 槽 {slot} 本来就是空的");
        }
        catch (Exception e)
        {
            Debug.LogWarning($"[SaveSlots] 槽 {slot} 清空失败：{e.Message}");
        }
    }

    /// <summary>给 UI 用的一行摘要（不修改任何状态）。</summary>
    public static string Describe(int slot)
    {
        if (!TryRead(slot, out MetaWallet.SaveData d) || IsEmpty(d)) return "（空）";
        string tut = d.tutorialStage >= 1 ? "已过教程" : "教程中";
        return $"材料 {MaterialTotal(d)} · 灵魂 {SoulTotal(d)} · {tut}";
    }

    // ------------------------------------------------------------------
    // 旧档迁移
    // ------------------------------------------------------------------

    /// <summary>
    /// 把旧的单档 meta_save.json 迁移成「存档 1」。只在下面两个条件都成立时执行：
    /// ① 旧档存在；② 三个槽都还没有文件（否则说明已经在用多存档，绝不覆盖）。
    /// </summary>
    public static void MigrateLegacyOnce()
    {
        if (_legacyChecked) return;
        _legacyChecked = true;
        try
        {
            if (!File.Exists(LegacyPath)) return;
            for (int i = 1; i <= Count; i++)
            {
                if (File.Exists(PathFor(i))) return;   // 已有槽文件 → 不动
            }
            File.Copy(LegacyPath, PathFor(1), false);
            Debug.Log("[SaveSlots] 检测到旧版单档 meta_save.json → 已迁移为「存档 1」");
        }
        catch (Exception e)
        {
            Debug.LogWarning($"[SaveSlots] 旧档迁移失败（忽略，按空档继续）：{e.Message}");
        }
    }
}
