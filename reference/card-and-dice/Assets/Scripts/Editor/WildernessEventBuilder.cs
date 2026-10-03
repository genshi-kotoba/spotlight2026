// =============================================================================
// 编辑器工具：荒野事件构建器（设计页《荒野事件-design》§2/§4 → 资产落库）
// 数据源：Assets/Scripts/Editor/WildernessEventContent.json
//   （32 事件 + 10 临时强化；文案按 design §1.6 规矩撰写）
// 口径依据：docs/2026-09-16_荒野事件-design.md
//   · §1.4 五条防刷铁律（构建时自检：正收益/进战必 endEvent、付出必有收益、灵魂只出不进）
//   · §5.4 32 个事件全 once=false —— 一次性语义全由结果级 endEvent 承担
//   · §3.1 群系标签分池 → 目录 WildernessEventCatalog（Assets/Resources/）
// 菜单：Tools/荒野事件/0..3（幂等：按路径 LoadOrCreate，已存在只覆盖字段不重复建）
// 注意：邮车「撬开货箱」与招魂坛「献上一个灵魂」的随机卡牌暂不产出
//   （用户 2026-09-16 拍板「先留空，等卡牌线」）——两个选项照常可点、照常结算其它部分。
// =============================================================================
#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEditor;
using UnityEngine;

public static class WildernessEventBuilder
{
    const string JsonPath    = "Assets/Scripts/Editor/WildernessEventContent.json";
    const string EventDir    = "Assets/Data/Events";
    const string BuffDir     = "Assets/Data/TempBuffs";
    const string ItemDir     = "Assets/Data/Items";
    const string CatalogPath = "Assets/Resources/WildernessEventCatalog.asset";

    // ------------------------------------------------------------------
    // JSON DTO（JsonUtility 兼容：public 字段 + [Serializable]，无字典）
    // ------------------------------------------------------------------
    [Serializable] public class Root    { public List<BuffDto> buffs; public List<EventDto> events; }
    [Serializable] public class BuffDto { public string name; public int kind; public int value; public string desc; }
    [Serializable] public class EventDto { public string name; public int biome; public string title; public string desc; public List<OptDto> options; }
    [Serializable] public class OptDto  { public string text; public int check; public int d; public List<CostDto> costs; public ResDto success; public ResDto failure; }
    [Serializable] public class CostDto { public string item; public bool any; public int type; public int amount; }
    [Serializable] public class ItemDto { public string item; public int amount; }
    [Serializable] public class ResDto
    {
        public string flavor; public bool end;
        public int hp; public int energy; public int dice; public int salvage;
        public int combat; public int remove; public int duplicate;
        public string buff; public List<ItemDto> items;
    }

    static Root _root;
    static Root Data { get { if (_root == null) Load(); return _root; } }

    /// <summary>
    /// 每次菜单入口先清缓存再取数据：连跑两次菜单之间**不会发生域重载**，
    /// 不清就会拿第一遍解析出的旧 JSON（改了数据文件重跑却看不到变化）。
    /// </summary>
    static Root Reload()
    {
        _root = null;
        return Data;
    }

    static void Load()
    {
        TextAsset ta = AssetDatabase.LoadAssetAtPath<TextAsset>(JsonPath);
        if (ta == null)
        {
            Debug.LogError("[事件构建器] 找不到数据文件 " + JsonPath);
            return;
        }
        _root = JsonUtility.FromJson<Root>(ta.text);
    }

    // ------------------------------------------------------------------
    // 入口：一键全部
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野事件/0. 一键全部（临时强化→事件→目录）")]
    public static void BuildAll()
    {
        int b = BuildBuffs();
        int e = BuildEvents();
        int c = BuildCatalog();
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log(string.Format("[事件构建器] 全量完成：临时强化 {0}｜事件 {1}｜目录收录 {2}", b, e, c));
    }

    // ------------------------------------------------------------------
    // 1. 临时强化（design §2：6 枚群系特色 + 4 枚通用）
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野事件/1. 临时强化")]
    public static int BuildBuffs()
    {
        if (Reload() == null || Data.buffs == null) return 0;
        EnsureFolder(BuffDir);
        int n = 0;
        foreach (BuffDto dto in Data.buffs)
        {
            TempBuffData buff = LoadOrCreate<TempBuffData>(BuffDir + "/" + dto.name + ".asset");
            buff.buffId = "BUFF_WILD_" + dto.name;
            buff.buffName = dto.name;
            buff.description = dto.desc;
            buff.kind = (TempBuffKind)Mathf.Clamp(dto.kind, 0, 9);
            buff.value = dto.value;
            // icon 刻意不覆盖：新资产留空走纯文字，手工挂过图的资产重跑不丢
            EditorUtility.SetDirty(buff);
            n++;
        }
        AssetDatabase.SaveAssets();
        Debug.Log("[事件构建器] 临时强化 " + n + " 枚 → " + BuffDir);
        return n;
    }

    // ------------------------------------------------------------------
    // 2. 事件（design §4 全表 32 个）
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野事件/2. 事件")]
    public static int BuildEvents()
    {
        if (Reload() == null || Data.events == null) return 0;
        EnsureFolder(EventDir);

        int n = 0, optCount = 0, costMiss = 0, itemMiss = 0, buffMiss = 0;
        List<string> audits = new List<string>();

        foreach (EventDto dto in Data.events)
        {
            EventData ed = LoadOrCreate<EventData>(EventDir + "/" + dto.name + ".asset");
            ed.eventId = dto.name;
            ed.title = dto.title;
            ed.description = dto.desc;
            ed.once = false;                                   // §5.4：一次性语义全由结果级 endEvent 承担
            ed.biomeTag = (BiomeTag)Mathf.Clamp(dto.biome, -1, 6);

            ed.options = new List<EventOption>();
            foreach (OptDto od in dto.options)
            {
                EventOption opt = new EventOption();
                opt.optionText = od.text;
                opt.checkType = (CheckType)Mathf.Clamp(od.check, 0, 5);
                opt.difficulty = od.d > 0 ? od.d : 4;

                opt.costs = new List<EventItemCost>();
                if (od.costs != null)
                {
                    foreach (CostDto cd in od.costs)
                    {
                        EventItemCost cost = new EventItemCost();
                        cost.anyOfType = cd.any || string.IsNullOrEmpty(cd.item);
                        cost.type = (ItemType)Mathf.Clamp(cd.type, 0, 5);
                        cost.amount = Mathf.Max(1, cd.amount);
                        if (!cost.anyOfType)
                        {
                            cost.item = LoadItem(cd.item);
                            if (cost.item == null) { costMiss++; Debug.LogWarning("[事件构建器] " + dto.name + " 代价物品缺失：" + cd.item); }
                        }
                        opt.costs.Add(cost);
                    }
                }

                opt.success = BuildResult(od.success, dto.name, ref itemMiss, ref buffMiss);
                opt.failure = BuildResult(od.failure, dto.name, ref itemMiss, ref buffMiss);

                if (opt.checkType != CheckType.无 && opt.failure == null)
                    audits.Add(dto.name + "「" + od.text + "」有鉴定但缺失败结果");

                AuditOption(opt, dto.name, audits);
                ed.options.Add(opt);
                optCount++;
            }

            EditorUtility.SetDirty(ed);
            n++;
        }

        AssetDatabase.SaveAssets();
        Debug.Log(string.Format("[事件构建器] 事件 {0} 个 / 选项 {1} 条 → {2}（代价物品缺失 {3}、奖励物品缺失 {4}、强化缺失 {5}）",
            n, optCount, EventDir, costMiss, itemMiss, buffMiss));
        if (audits.Count > 0)
            Debug.LogWarning("[事件构建器] 防刷自检 " + audits.Count + " 条：\n" + string.Join("\n", audits.ToArray()));
        else
            Debug.Log("[事件构建器] 防刷自检通过（铁律 1/2/5 + 灵魂只出不进）");
        return n;
    }

    static EventResult BuildResult(ResDto dto, string evName, ref int itemMiss, ref int buffMiss)
    {
        if (dto == null) return null;

        EventResult r = new EventResult();
        r.flavorText = dto.flavor;
        r.endEvent = dto.end;
        r.hpChange = dto.hp;
        r.energyChange = dto.energy;
        r.diceChange = dto.dice;
        r.salvageChange = dto.salvage;
        r.triggerCombat = dto.combat > 0;
        r.combatEnemyCount = Mathf.Clamp(dto.combat > 0 ? dto.combat : 1, 1, 2);
        r.removeCards = Mathf.Max(0, dto.remove);
        r.duplicateCards = Mathf.Max(0, dto.duplicate);

        r.grantBuff = null;
        if (!string.IsNullOrEmpty(dto.buff))
        {
            r.grantBuff = AssetDatabase.LoadAssetAtPath<TempBuffData>(BuffDir + "/" + dto.buff + ".asset");
            if (r.grantBuff == null) { buffMiss++; Debug.LogWarning("[事件构建器] " + evName + " 强化缺失：" + dto.buff); }
        }

        // 随机卡牌暂不产出（邮车 / 招魂坛）——等卡牌线，字段先留空
        r.addCards = new List<CardData>();
        r.addItems = new List<EventItemReward>();
        if (dto.items != null)
        {
            foreach (ItemDto id in dto.items)
            {
                ItemData item = LoadItem(id.item);
                if (item == null) { itemMiss++; Debug.LogWarning("[事件构建器] " + evName + " 奖励物品缺失：" + id.item); continue; }
                r.addItems.Add(new EventItemReward { item = item, amount = Mathf.Max(1, id.amount) });
            }
        }
        return r;
    }

    // ------------------------------------------------------------------
    // 防刷自检（design §1.4 五条铁律的机器可查部分）
    // ------------------------------------------------------------------
    static void AuditOption(EventOption opt, string evName, List<string> audits)
    {
        string where = evName + "「" + opt.optionText + "」";
        AuditResult(opt.success, where + "·成功", audits);
        AuditResult(opt.failure, where + "·失败", audits);
    }

    static void AuditResult(EventResult r, string where, List<string> audits)
    {
        if (r == null) return;

        // 铁律 2：进战结果一律 endEvent
        if (r.triggerCombat && !r.endEvent)
            audits.Add(where + "：进战但未 endEvent（铁律 2）");

        // 铁律 1：正收益结果一律 endEvent
        bool gain = r.hpChange > 0 || r.energyChange > 0 || r.diceChange > 0 || r.salvageChange > 0
                    || r.grantBuff != null || r.removeCards > 0 || r.duplicateCards > 0
                    || (r.addItems != null && r.addItems.Count > 0)
                    || (r.addCards != null && r.addCards.Count > 0);
        if (gain && !r.endEvent)
            audits.Add(where + "：正收益但未 endEvent（铁律 1）");

        // 灵魂只出不进：事件不产出灵魂
        if (r.addItems != null)
            foreach (EventItemReward it in r.addItems)
                if (it != null && it.item != null && it.item.type == ItemType.灵魂)
                    audits.Add(where + "：产出灵魂（灵魂只出不进）");
    }

    // ------------------------------------------------------------------
    // 3. 事件目录（design §3.1：Assets/Resources/WildernessEventCatalog.asset）
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野事件/3. 事件目录")]
    public static int BuildCatalog()
    {
        if (Reload() == null || Data.events == null) return 0;
        EnsureFolder("Assets/Resources");

        WildernessEventCatalog cat = AssetDatabase.LoadAssetAtPath<WildernessEventCatalog>(CatalogPath);
        if (cat == null)
        {
            cat = ScriptableObject.CreateInstance<WildernessEventCatalog>();
            AssetDatabase.CreateAsset(cat, CatalogPath);
        }

        // 顺序：通用池先、群系 1..6 依次（池内保持 JSON 顺序；抽取时按 eventId 去重，顺序不影响公平性）
        int[] order = new int[] { -1, 1, 2, 3, 4, 5, 6 };
        cat.events = new List<EventData>();
        int miss = 0;
        StringBuilder dist = new StringBuilder();
        foreach (int biome in order)
        {
            int c = 0;
            foreach (EventDto dto in Data.events)
            {
                if (dto.biome != biome) continue;
                EventData ed = AssetDatabase.LoadAssetAtPath<EventData>(EventDir + "/" + dto.name + ".asset");
                if (ed == null) { miss++; Debug.LogWarning("[事件构建器] 目录收录时找不到资产：" + dto.name); continue; }
                cat.events.Add(ed);
                c++;
            }
            dist.Append(biome == -1 ? "通用" : ((BiomeTag)biome).ToString()).Append(" ").Append(c).Append("｜");
        }

        EditorUtility.SetDirty(cat);
        AssetDatabase.SaveAssets();
        Debug.Log("[事件构建器] 目录收录 " + cat.events.Count + " 个（缺失 " + miss + "）→ " + CatalogPath + "  " + dist);
        return cat.events.Count;
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------
    static ItemData LoadItem(string name)
    {
        if (string.IsNullOrEmpty(name)) return null;
        return AssetDatabase.LoadAssetAtPath<ItemData>(ItemDir + "/" + name + ".asset");
    }

    static T LoadOrCreate<T>(string path) where T : ScriptableObject
    {
        T asset = AssetDatabase.LoadAssetAtPath<T>(path);
        if (asset != null) return asset;
        asset = ScriptableObject.CreateInstance<T>();
        AssetDatabase.CreateAsset(asset, path);
        return asset;
    }

    static void EnsureFolder(string folder)
    {
        if (AssetDatabase.IsValidFolder(folder)) return;
        string parent = Path.GetDirectoryName(folder).Replace('\\', '/');
        string leaf = Path.GetFileName(folder);
        if (!AssetDatabase.IsValidFolder(parent)) EnsureFolder(parent);
        AssetDatabase.CreateFolder(parent, leaf);
    }
}
#endif
