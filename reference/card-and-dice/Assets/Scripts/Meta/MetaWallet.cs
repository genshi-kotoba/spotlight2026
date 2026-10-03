// =============================================================================
// 模块：Meta - MetaWallet 跨局钱包（局外持久化）
// 用途：存「藏身处」的跨局资源——材料、灵魂（★按种类）、教学进度，以及玩家阵亡后
//       留在地图上的「尸体」记录（下次出击可回收，参考逃离塔科夫）。
// 持久化：JSON 写到 Application.persistentDataPath/meta_save_slot{N}.json（N = 当前存档位 1..3，
//           由 SaveSlots 管理；旧版单档 meta_save.json 首次访问时自动迁移为存档 1）。
// 本类与当局运行时 InventoryManager / runtimeDeck 完全解耦，只做跨局资源的持久层。
//
// ★2026-09-14 重构（用户决策「那三个强化直接删了，做新的设施」，设计稿
//   docs/2026-09-11_藏身处与灵魂装置-design.md §0）：
//   · **删掉全部 3 项数值强化**（最大生命 / 起始战斗骰 / 起始牌库）——
//     它们是上一轮的错误实现，藏身处的成长改为「烧魂抽配方/被动 → 工坊制卡」。
//   · **灵魂从「一个整数计数器」改为「按种类的灵魂背包」**——
//     魂 = 废墟图书馆式的「书」，按怪种区分（哥布林的灵魂 ×7 / 史莱姆的灵魂 ×2）。
//     旧档里的整数 `souls` 读取时一次性迁移成一条「未分类的灵魂」堆（不静默丢数）。
//
// 经济模型（source / sink，2026-09-16 v2.1 修订）：
//   灵魂  source = 撤离全额入账 / 死亡保留一半；sink = 灵魂提取装置（一怪一池无放回）＋命途。   （有 source 有 sink）
//   材料  source = 撤离全额入账；sink = 工坊三件套（制卡 / 制骰 / 被动激活）＋命途。           [sink 在 B3]
//   ★v2.1（B1）：**材料从「一个整数」改为按种类记堆**（怪材按家族 / 卡牌碎片 / 物资，设计稿 §2.2-②）；
//     尸体材料同样按种类记；同时预置后续分批（B2–B6）要用的存档字段。
//     旧档里的整数 `materials` / `corpseMaterials` 读取时一次性迁移成「未分类的材料」堆（不静默丢数）。
// =============================================================================
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEngine;

/// <summary>
/// 跨局钱包（纯静态）。首次访问自动从磁盘加载，任何改动立即写回。
/// </summary>
public static class MetaWallet
{
    // ------------------------------------------------------------------
    // 场景名常量（跳转统一出口）
    // ------------------------------------------------------------------
    /// <summary>新手教程场景（40×13 教程图，编辑期烘焙进场景）。★2026-09-15 由 RaidScene 改名而来。</summary>
    public const string TUTORIAL_SCENE = "TutorialScene";
    /// <summary>第一章「雾镇内」场景（80×50，进图时从 raid_town.txt 现烘，不烘进场景）。</summary>
    public const string FOGTOWN_SCENE = "FogTownScene";
    /// <summary>局外藏身处场景（2D 面板）。</summary>
    public const string HIDEOUT_SCENE = "HideoutScene";

    /// <summary>旧档迁移时给「原本只有一个整数计数的灵魂」用的兜底名字。</summary>
    public const string LegacySoulName = "未分类的灵魂";

    /// <summary>旧档迁移时给「原本只有一个整数计数的材料」用的兜底名字。</summary>
    public const string LegacyMaterialName = "未分类的材料";

    // ------------------------------------------------------------------
    // 存档数据
    // ------------------------------------------------------------------
    /// <summary>「名字 + 数量」的堆（灵魂按怪种 / 材料按种类 / 实物按物品，共用同一范式）。name 取 ItemData.itemName。</summary>
    [Serializable]
    public class NamedStack
    {
        public string name;
        public int count;
    }

    /// <summary>★v2.1 B1 占位：出击快照——整装面板选了什么。写入方 B4（设计稿 §5/§10-3）。</summary>
    [Serializable]
    public class LoadoutSnapshot
    {
        /// <summary>自由栏位选入的卡（CardData.cardID）。</summary>
        public List<string> cards = new List<string>();
        /// <summary>被动编队（PassiveData 名）。</summary>
        public List<string> passives = new List<string>();
        /// <summary>携带的骰子（ItemData.itemName × 数量）。</summary>
        public List<NamedStack> dice = new List<NamedStack>();
        /// <summary>携带的消耗品（ItemData.itemName × 数量）。</summary>
        public List<NamedStack> consumables = new List<NamedStack>();
    }

    [Serializable]
    public class SaveData
    {
        /// <summary>★v2.1：材料按种类存（怪材按家族 / 卡牌碎片 / 物资）。原为 int materials。</summary>
        public List<NamedStack> materialStacks = new List<NamedStack>();

        /// <summary>
        /// ⚠️ 旧档遗留字段（v2.1 之前的「材料总数」）。只在读盘时做一次性迁移用：
        /// 若 materialStacks 为空而它 &gt; 0，就转成一条「未分类的材料」堆并清零。
        /// 新写入的存档里它恒为 0。
        /// </summary>
        public int materials;

        /// <summary>灵魂按种类存（2026-09-14 起；原为 int souls）。</summary>
        public List<NamedStack> soulStacks = new List<NamedStack>();

        /// <summary>⚠️ 旧档遗留字段（灵魂总数）。同 materials 的处理。</summary>
        public int souls;

        // ★2026-09-12 教学进度：0 = 教程未完成（首通走教程图）；>=1 = 教程已完成（之后进藏身处）。
        // 用 int 而非 bool，预留后续「两次循环」stage(0/1/2/3) 扩展，不破坏存档结构。
        public int tutorialStage = 0;

        // 玩家阵亡遗留的尸体（下次出击回收）。corpseX < 0 表示无待回收尸体。
        public int corpseX = -1;
        public int corpseY = -1;

        /// <summary>★v2.1：尸体里的材料按种类记（下次出击回收；回收落地见 PendingCorpseSpawner）。</summary>
        public List<NamedStack> corpseMaterialStacks = new List<NamedStack>();

        /// <summary>⚠️ 旧档遗留字段（尸体材料总数）。同 materials 的处理。</summary>
        public int corpseMaterials;

        // ------------------------------------------------------------------
        // ★v2.1 B1 占位字段：本批只定义（含旧档兼容），写入方见设计稿 §13 分批表。
        // ------------------------------------------------------------------
        /// <summary>已提取的配方（卡 CardData.cardID / 被动 PassiveData 名）——B2 灵魂装置写入。</summary>
        public List<string> unlockedRecipes = new List<string>();
        /// <summary>卡牌库存：已制成的卡（name = cardID）× 张数——B3 工坊写入。</summary>
        public List<NamedStack> craftedCards = new List<NamedStack>();
        /// <summary>已激活的被动（PassiveData 名；永久不丢）——B2/B3 写入。</summary>
        public List<string> passiveUnlocks = new List<string>();
        /// <summary>实物库：跨局存下的骰子 / 消耗品（name = ItemData.itemName）——B4/B5 写入。</summary>
        public List<NamedStack> storedItems = new List<NamedStack>();
        /// <summary>已购买的命途节点 id——B6 写入。</summary>
        public List<string> upgradedNodes = new List<string>();
        /// <summary>出击快照（整装面板选的卡 / 被动 / 骰子 / 消耗品）——B4 写入。</summary>
        public LoadoutSnapshot loadout = new LoadoutSnapshot();
    }

    static SaveData _data;

    // ★2026-09-14：存档从「单一 meta_save.json」改为「3 个独立存档位」——
    // 实际读写路径由当前存档位决定（SaveSlots.ActiveSlotPath），路径解析集中在 SaveSlots。
    static string SavePath => SaveSlots.ActiveSlotPath;

    static void EnsureLoaded()
    {
        if (_data != null) return;
        Load();
    }

    // ------------------------------------------------------------------
    // 查询
    // ------------------------------------------------------------------

    /// <summary>材料总件数（所有种类求和）。★v2.1：原为 int Materials。</summary>
    public static int MaterialCount { get { EnsureLoaded(); return SumOf(_data.materialStacks); } }

    /// <summary>材料堆（只读视图；调用方不要改这个列表）。</summary>
    public static IReadOnlyList<NamedStack> MaterialStacks
    {
        get { EnsureLoaded(); return _data.materialStacks; }
    }

    /// <summary>某一种材料的持有数（name 取 ItemData.itemName）。</summary>
    public static int MaterialCountOf(string materialName)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(materialName)) return 0;
        foreach (NamedStack s in _data.materialStacks)
            if (s.name == materialName) return s.count;
        return 0;
    }

    /// <summary>资源条/仓库用的一行摘要：「铁屑×3 兽骨×2」，空则「无」。</summary>
    public static string MaterialSummary() { EnsureLoaded(); return SummaryOf(_data.materialStacks); }

    /// <summary>灵魂种类堆（只读视图；调用方不要改这个列表）。</summary>
    public static IReadOnlyList<NamedStack> SoulStacks
    {
        get { EnsureLoaded(); return _data.soulStacks; }
    }

    /// <summary>灵魂总数（所有种类求和）。</summary>
    public static int SoulCount { get { EnsureLoaded(); return SumOf(_data.soulStacks); } }

    /// <summary>某一种灵魂的持有数。</summary>
    public static int SoulCountOf(string soulName)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(soulName)) return 0;
        foreach (NamedStack s in _data.soulStacks)
            if (s.name == soulName) return s.count;
        return 0;
    }

    /// <summary>资源条/仓库用的一行摘要：「哥布林的灵魂×4 史莱姆的灵魂×2」，空则「无」。</summary>
    public static string SoulSummary() { EnsureLoaded(); return SummaryOf(_data.soulStacks); }

    // ------------------------------------------------------------------
    // 堆表工具（纯函数：结算归并、摘要显示与 L2 断言共用）
    // ------------------------------------------------------------------

    /// <summary>堆表里所有条目的件数之和。</summary>
    public static int SumOf(IReadOnlyList<NamedStack> stacks)
    {
        if (stacks == null) return 0;
        int n = 0;
        for (int i = 0; i < stacks.Count; i++)
        {
            NamedStack s = stacks[i];
            if (s != null && s.count > 0) n += s.count;
        }
        return n;
    }

    /// <summary>堆表的一行摘要：「铁屑×3 兽骨×2」（按加入顺序），空则「无」。</summary>
    public static string SummaryOf(IReadOnlyList<NamedStack> stacks)
    {
        if (stacks == null) return "无";
        var sb = new StringBuilder();
        for (int i = 0; i < stacks.Count; i++)
        {
            NamedStack s = stacks[i];
            if (s == null || s.count <= 0 || string.IsNullOrEmpty(s.name)) continue;
            if (sb.Length > 0) sb.Append(' ');
            sb.Append(s.name).Append('×').Append(s.count);
        }
        return sb.Length == 0 ? "无" : sb.ToString();
    }

    /// <summary>把一串背包格按物品名归并成堆（撤离/阵亡结算取「材料清单」用；纯函数，L2 可断言）。</summary>
    public static List<NamedStack> AggregateStacks(IEnumerable<InventorySlot> slots)
    {
        var result = new List<NamedStack>();
        if (slots == null) return result;
        foreach (InventorySlot slot in slots)
        {
            if (slot == null || slot.item == null || slot.count <= 0) continue;
            string name = string.IsNullOrEmpty(slot.item.itemName) ? LegacyMaterialName : slot.item.itemName;
            AddToStacks(result, name, slot.count);
        }
        return result;
    }

    /// <summary>把一串堆并入目标堆表（同名累加；空名归「未分类的材料」；纯函数）。返回并入的总件数。</summary>
    public static int MergeStacks(List<NamedStack> target, IEnumerable<NamedStack> incoming)
    {
        if (target == null || incoming == null) return 0;
        int n = 0;
        foreach (NamedStack s in incoming)
        {
            if (s == null || s.count <= 0) continue;
            string name = string.IsNullOrEmpty(s.name) ? LegacyMaterialName : s.name;
            AddToStacks(target, name, s.count);
            n += s.count;
        }
        return n;
    }

    /// <summary>同名累加，没有就新建一条。</summary>
    static void AddToStacks(List<NamedStack> stacks, string name, int count)
    {
        if (count <= 0) return;
        foreach (NamedStack s in stacks)
        {
            if (s.name == name) { s.count += count; return; }
        }
        stacks.Add(new NamedStack { name = name, count = count });
    }

    /// <summary>从堆表里扣同名 count 件（不足返回 false、不动账；扣空后清行）。★B3 起供工坊 API 复用。</summary>
    static bool TryConsumeFrom(List<NamedStack> stacks, string name, int count)
    {
        if (stacks == null || string.IsNullOrEmpty(name) || count <= 0) return false;
        int have = 0;
        foreach (NamedStack s in stacks)
            if (s != null && s.name == name && s.count > 0) have += s.count;
        if (have < count) return false;

        int need = count;
        foreach (NamedStack s in stacks)
        {
            if (s == null || s.name != name || s.count <= 0) continue;
            int take = Math.Min(s.count, need);
            s.count -= take;
            need -= take;
            if (need <= 0) break;
        }
        stacks.RemoveAll(s => s != null && s.count <= 0);
        return true;
    }

    /// <summary>堆表里某一名字的持有数（纯查询）。</summary>
    static int CountIn(List<NamedStack> stacks, string name)
    {
        if (stacks == null || string.IsNullOrEmpty(name)) return 0;
        foreach (NamedStack s in stacks)
            if (s != null && s.name == name && s.count > 0) return s.count;
        return 0;
    }

    // ------------------------------------------------------------------
    // 教学进度（2026-09-12 垂直切片）
    // ------------------------------------------------------------------

    /// <summary>当前教学进度档位（0=未完成，>=1=完成）。</summary>
    public static int TutorialStage { get { EnsureLoaded(); return _data.tutorialStage; } }

    /// <summary>设置教学进度档位并落盘（TutorialProgress.MarkComplete 调用）。</summary>
    public static void SetTutorialStage(int v)
    {
        EnsureLoaded();
        _data.tutorialStage = v;
        Save();
    }

    // ------------------------------------------------------------------
    // 尸体记录（死亡遗留，下次出击回收）
    // ------------------------------------------------------------------

    public static bool HasPendingCorpse { get { EnsureLoaded(); return _data.corpseX >= 0; } }

    public static Vector2Int PendingCorpseCoord
    {
        get { EnsureLoaded(); return new Vector2Int(_data.corpseX, _data.corpseY); }
    }

    /// <summary>尸体里的材料堆（只读视图；回收落地见 PendingCorpseSpawner）。</summary>
    public static IReadOnlyList<NamedStack> PendingCorpseMaterialStacks
    {
        get { EnsureLoaded(); return _data.corpseMaterialStacks; }
    }

    /// <summary>尸体里材料的总件数（原 PendingCorpseMaterials）。</summary>
    public static int PendingCorpseMaterialCount
    {
        get { EnsureLoaded(); return SumOf(_data.corpseMaterialStacks); }
    }

    public static void ClearPendingCorpse()
    {
        EnsureLoaded();
        _data.corpseX = -1;
        _data.corpseY = -1;
        _data.corpseMaterialStacks.Clear();
        _data.corpseMaterials = 0;
        Save();
    }

    // ------------------------------------------------------------------
    // 入账
    // ------------------------------------------------------------------

    /// <summary>物资堆名（design §1.2：物资＝直入局外账的通用资源，不进背包）。</summary>
    public const string SalvageName = "物资";

    /// <summary>卡牌碎片堆名（只由卡牌变出：拆解 / 回收；设计稿 §2 经济总表）。</summary>
    public const string ShardMaterialName = "卡牌碎片";

    /// <summary>
    /// 事件物资入账（design §3.6 的 salvageChange）：**直写局外账并立即落盘**，
    /// 不随阵亡丢失（与撤离才入账的材料不同）。负数 = 扣，扣到 0 为止。
    /// </summary>
    public static void AddSalvage(int delta)
    {
        EnsureLoaded();
        if (delta == 0) return;

        if (delta > 0)
        {
            AddToStacks(_data.materialStacks, SalvageName, delta);
        }
        else
        {
            int need = -delta;
            foreach (NamedStack s in _data.materialStacks)
            {
                if (s == null || s.name != SalvageName || s.count <= 0) continue;
                int take = Math.Min(s.count, need);
                s.count -= take;
                need -= take;
                if (need <= 0) break;
            }
            _data.materialStacks.RemoveAll(s => s != null && s.count <= 0);
            if (need > 0) Debug.LogWarning($"[MetaWallet] 物资不足，欠 {need}（已扣到 0）");
        }

        Save();
        Debug.Log($"[MetaWallet] 事件物资 {delta:+0;-0} → 物资 {MaterialSummary()}");
    }

    /// <summary>
    /// 撤离结算：把当局材料与灵魂全额入账（调用方须在 EndExpedition 之前取数）。
    /// 材料传「按物品名归并好的堆」（MetaWallet.AggregateStacks），灵魂传魂灯里的 ItemData。
    /// </summary>
    public static void DepositRun(IEnumerable<NamedStack> materials, IEnumerable<ItemData> souls)
    {
        EnsureLoaded();
        int mats = MergeStacks(_data.materialStacks, materials);
        int kinds = AddSouls(souls);
        Save();
        Debug.Log($"[MetaWallet] 撤离入账：材料 +{mats}、灵魂 +{kinds} 条 → " +
                  $"材料 {MaterialSummary()}、灵魂 {SoulSummary()}");
    }

    /// <summary>死亡结算：材料（按种类）丢进尸体（下次出击回收），保留一半灵魂入账（按条数向上取整）。</summary>
    public static void RecordDeath(Vector2Int coord, IEnumerable<NamedStack> materials, IEnumerable<ItemData> soulsKept)
    {
        EnsureLoaded();
        _data.corpseX = coord.x;
        _data.corpseY = coord.y;
        _data.corpseMaterialStacks.Clear();
        int mats = MergeStacks(_data.corpseMaterialStacks, materials);
        int kept = AddSouls(soulsKept);
        Save();
        Debug.Log($"[MetaWallet] 死亡：材料 {mats}（{SummaryOf(_data.corpseMaterialStacks)}）" +
                  $"丢在 Hex_{coord.x}_{coord.y} 待回收，灵魂 +{kept} 条 → 灵魂 {SoulSummary()}");
    }

    /// <summary>把一串灵魂（按 itemName 归类，每条 1 件）加进灵魂背包。返回加入的条数。</summary>
    private static int AddSouls(IEnumerable<ItemData> souls)
    {
        if (souls == null) return 0;
        int n = 0;
        foreach (ItemData soul in souls)
        {
            if (soul == null) continue;
            string name = string.IsNullOrEmpty(soul.itemName) ? LegacySoulName : soul.itemName;
            AddToStacks(_data.soulStacks, name, 1);
            n++;
        }
        return n;
    }

    // ------------------------------------------------------------------
    // ★B2 装置：配方解锁 ＋ 灵魂消耗（一怪一池无放回的写入口）
    // ------------------------------------------------------------------

    /// <summary>该配方是否已抽出（卡传 cardID、被动传 passiveName）。</summary>
    public static bool IsRecipeUnlocked(string recipeId)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(recipeId)) return false;
        return _data.unlockedRecipes.Contains(recipeId);
    }

    /// <summary>写入一条已抽出配方（去重＋立即落盘）。返回 true = 本次是新写入。</summary>
    public static bool AddRecipe(string recipeId)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(recipeId) || _data.unlockedRecipes.Contains(recipeId)) return false;
        _data.unlockedRecipes.Add(recipeId);
        Save();
        return true;
    }

    /// <summary>扣灵魂（装置抽卡用）。不足 = 不动账、返回 false。</summary>
    public static bool TryConsumeSoul(string soulName, int count)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(soulName) || count <= 0) return false;

        int have = 0;
        foreach (NamedStack s in _data.soulStacks)
            if (s != null && s.name == soulName) have += s.count;
        if (have < count) return false;

        int need = count;
        foreach (NamedStack s in _data.soulStacks)
        {
            if (s == null || s.name != soulName || s.count <= 0) continue;
            int take = Math.Min(s.count, need);
            s.count -= take;
            need -= take;
            if (need <= 0) break;
        }
        _data.soulStacks.RemoveAll(s => s != null && s.count <= 0);
        Save();
        return true;
    }

    // ------------------------------------------------------------------
    // ★B3 工坊：材料「任一」扣料 / 加材料 / 卡牌库存 / 被动激活 / 实物库
    // ------------------------------------------------------------------

    /// <summary>一组材料名的持有总数（「任一」扣料的前置检查）。</summary>
    public static int MaterialCountAnyOf(IReadOnlyList<string> names)
    {
        EnsureLoaded();
        if (names == null) return 0;
        int n = 0;
        for (int i = 0; i < names.Count; i++) n += CountIn(_data.materialStacks, names[i]);
        return n;
    }

    /// <summary>从一组材料里按顺序扣 count 件（「任一」语义：跨名字合计够即可）。不足 = 不动账、返回 false。</summary>
    public static bool TryConsumeAnyMaterial(IReadOnlyList<string> names, int count)
    {
        EnsureLoaded();
        if (names == null || count <= 0) return false;
        if (MaterialCountAnyOf(names) < count) return false;

        int need = count;
        for (int i = 0; i < names.Count && need > 0; i++)
        {
            string name = names[i];
            foreach (NamedStack s in _data.materialStacks)
            {
                if (s == null || s.name != name || s.count <= 0) continue;
                int take = Math.Min(s.count, need);
                s.count -= take;
                need -= take;
                if (need <= 0) break;
            }
        }
        _data.materialStacks.RemoveAll(s => s != null && s.count <= 0);
        Save();
        return true;
    }

    /// <summary>加材料（拆解碎片回流等）。count ≤ 0 = 无操作。</summary>
    public static void AddMaterial(string name, int count)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(name) || count <= 0) return;
        AddToStacks(_data.materialStacks, name, count);
        Save();
        Debug.Log($"[MetaWallet] 材料 +{count} {name} → {MaterialSummary()}");
    }

    /// <summary>调试作弊（F8）：把一批材料各补到至少 target 件，已有的多于 target 不动；整体只存一次档。返回变动的材料种数。</summary>
    public static int EnsureMaterials(IReadOnlyList<string> names, int target)
    {
        EnsureLoaded();
        if (names == null || target <= 0) return 0;
        int changed = 0;
        for (int i = 0; i < names.Count; i++)
        {
            string n = names[i];
            if (string.IsNullOrEmpty(n)) continue;
            int cur = MaterialCountOf(n);
            if (cur >= target) continue;
            AddToStacks(_data.materialStacks, n, target - cur);
            changed++;
        }
        if (changed > 0) Save();
        return changed;
    }

    /// <summary>已抽出配方（卡 cardID / 被动名 混存；只读视图，调用方不要改）。</summary>
    public static IReadOnlyList<string> UnlockedRecipes
    {
        get { EnsureLoaded(); return _data.unlockedRecipes; }
    }

    /// <summary>卡牌库存（只读视图；name = cardID）。</summary>
    public static IReadOnlyList<NamedStack> CraftedCards
    {
        get { EnsureLoaded(); return _data.craftedCards; }
    }

    public static int CraftedCardCount(string cardID)
    {
        EnsureLoaded();
        return CountIn(_data.craftedCards, cardID);
    }

    /// <summary>制卡入库（按张数累加）。</summary>
    public static void AddCraftedCard(string cardID, int count)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(cardID) || count <= 0) return;
        AddToStacks(_data.craftedCards, cardID, count);
        Save();
        Debug.Log($"[MetaWallet] 卡牌库存 +{count} {cardID}（共 {CraftedCardCount(cardID)}）");
    }

    /// <summary>扣卡牌库存（拆解）。不足 = 不动账、返回 false。</summary>
    public static bool TryConsumeCraftedCard(string cardID, int count)
    {
        EnsureLoaded();
        if (!TryConsumeFrom(_data.craftedCards, cardID, count)) return false;
        Save();
        return true;
    }

    /// <summary>已激活被动（只读视图；永久不丢）。</summary>
    public static IReadOnlyList<string> ActivePassives
    {
        get { EnsureLoaded(); return _data.passiveUnlocks; }
    }

    public static bool IsPassiveActive(string passiveName)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(passiveName)) return false;
        return _data.passiveUnlocks.Contains(passiveName);
    }

    /// <summary>激活一条被动（去重＋立即落盘）。返回 true = 本次新激活。</summary>
    public static bool ActivatePassive(string passiveName)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(passiveName) || _data.passiveUnlocks.Contains(passiveName)) return false;
        _data.passiveUnlocks.Add(passiveName);
        Save();
        Debug.Log($"[MetaWallet] 被动激活：{passiveName}（已激活 {_data.passiveUnlocks.Count} 条）");
        return true;
    }

    /// <summary>实物库（骰子 / 消耗品按物品名 × 数量；只读视图）。</summary>
    public static IReadOnlyList<NamedStack> StoredItems
    {
        get { EnsureLoaded(); return _data.storedItems; }
    }

    public static int StoredItemCount(string itemName)
    {
        EnsureLoaded();
        return CountIn(_data.storedItems, itemName);
    }

    /// <summary>实物入库（制骰等）。</summary>
    public static void AddStoredItem(string itemName, int count)
    {
        EnsureLoaded();
        if (string.IsNullOrEmpty(itemName) || count <= 0) return;
        AddToStacks(_data.storedItems, itemName, count);
        Save();
        Debug.Log($"[MetaWallet] 实物库 +{count} {itemName}（共 {StoredItemCount(itemName)}）");
    }

    /// <summary>扣实物库。不足 = 不动账、返回 false。</summary>
    public static bool TryConsumeStoredItem(string itemName, int count)
    {
        EnsureLoaded();
        if (!TryConsumeFrom(_data.storedItems, itemName, count)) return false;
        Save();
        return true;
    }

    // ------------------------------------------------------------------
    // ★B4 整装：loadout 快照读写 ＋ 校验 ＋ 出击提交（扣库存）
    // ------------------------------------------------------------------

    /// <summary>被动价值预算基础上限（2026-09-17 用户拍板 6；命途灵魂轨以后 +1/层）。</summary>
    public const int PassValueCap = 6;

    /// <summary>卡组自由栏位初始格数（2026-09-16 用户裁「自由栏位初始 2」；命途编制轨可扩）。</summary>
    public const int FreeDeckSlots = 2;

    /// <summary>
    /// 校验整装快照（纯查询、不动账）：
    ///   · 被动：每条须已激活且能查到资产，Σvalue ≤ PassValueCap；
    ///   · 卡组：自由栏位 ≤ FreeDeckSlots，且每张都有对应库存；
    ///   · 骰子 / 消耗品：总件数 ≤ 背包分区容量，且实物库存充足。
    /// 通过返回 true，否则 error 填原因（面板标红 / 禁止保存出击用）。
    /// </summary>
    public static bool ValidateLoadout(LoadoutSnapshot s, WildernessCraftCatalog cat, out string error)
    {
        error = "";
        if (s == null) { error = "配置为空"; return false; }

        // 被动编队：已激活 + Σvalue ≤ 上限
        int value = 0;
        if (s.passives != null)
        {
            for (int i = 0; i < s.passives.Count; i++)
            {
                string pn = s.passives[i];
                if (!IsPassiveActive(pn)) { error = "被动未激活：" + pn; return false; }
                PassiveData p = cat != null ? cat.PassiveFor(pn) : null;
                if (p == null) { error = "查不到被动：" + pn; return false; }
                value += p.value;
            }
        }
        if (value > PassValueCap) { error = "被动总价值 " + value + " 超过上限 " + PassValueCap; return false; }

        // 卡组自由栏位：≤ K 且库存充足（同卡多张按出现次数计）
        if (s.cards != null)
        {
            if (s.cards.Count > FreeDeckSlots) { error = "自由栏位 " + s.cards.Count + " 超过 " + FreeDeckSlots; return false; }
            var want = new Dictionary<string, int>();
            for (int i = 0; i < s.cards.Count; i++)
            {
                string id = s.cards[i];
                if (string.IsNullOrEmpty(id)) { error = "卡组里有空卡位"; return false; }
                int n;
                want.TryGetValue(id, out n);
                want[id] = n + 1;
            }
            foreach (KeyValuePair<string, int> kv in want)
            {
                if (CraftedCardCount(kv.Key) < kv.Value) { error = "卡牌库存不足：" + kv.Key; return false; }
            }
        }

        // 骰子 ≤ 6、消耗品 ≤ 3，且实物库存充足
        if (!ValidateStacks(s.dice, Inventory.DiceCapacity, out error)) return false;
        if (!ValidateStacks(s.consumables, Inventory.ConsumableCapacity, out error)) return false;

        return true;
    }

    /// <summary>实物堆校验（骰子/消耗品共用）：总件数 ≤ 分区容量且每堆库存充足。纯查询。</summary>
    static bool ValidateStacks(List<NamedStack> stacks, int cap, out string error)
    {
        error = "";
        if (stacks == null) return true;
        int total = 0;
        for (int i = 0; i < stacks.Count; i++)
        {
            NamedStack st = stacks[i];
            if (st == null || st.count <= 0) continue;
            if (string.IsNullOrEmpty(st.name)) { error = "实物里有空名字的堆"; return false; }
            total += st.count;
            if (StoredItemCount(st.name) < st.count) { error = "实物库存不足：" + st.name; return false; }
        }
        if (total > cap) { error = "实物 " + total + " 件超过容量 " + cap; return false; }
        return true;
    }

    /// <summary>保存整装配置：校验通过才写盘。**不扣库存**（扣在出击确认）。</summary>
    public static bool SaveLoadout(LoadoutSnapshot s, WildernessCraftCatalog cat, out string error)
    {
        EnsureLoaded();
        if (!ValidateLoadout(s, cat, out error)) return false;
        _data.loadout = CloneLoadout(s);
        Save();
        return true;
    }

    /// <summary>当前已保存的整装快照（深拷贝；面板预填用，改它不会动存档）。</summary>
    public static LoadoutSnapshot PeekLoadout()
    {
        EnsureLoaded();
        return CloneLoadout(_data.loadout);
    }

    /// <summary>清空快照（开局发放完成后调用，防下次开面板预填到已消耗的配置）。</summary>
    public static void ClearLoadout()
    {
        EnsureLoaded();
        _data.loadout = new LoadoutSnapshot();
        Save();
    }

    /// <summary>
    /// 出击提交：校验 → 扣库存（卡 / 骰子 / 消耗品）→ 写快照 → 一次落盘。
    /// 任一环节失败 = 不动账、返回 false（面板据此不跳图）。
    /// </summary>
    public static bool TryCommitDeploy(LoadoutSnapshot s, WildernessCraftCatalog cat, out string error)
    {
        EnsureLoaded();
        if (!ValidateLoadout(s, cat, out error)) return false;

        // 扣卡牌库存（按每种卡的出现张数）
        if (s.cards != null && s.cards.Count > 0)
        {
            var want = new Dictionary<string, int>();
            for (int i = 0; i < s.cards.Count; i++)
            {
                string id = s.cards[i];
                int n;
                want.TryGetValue(id, out n);
                want[id] = n + 1;
            }
            foreach (KeyValuePair<string, int> kv in want)
            {
                if (!TryConsumeFrom(_data.craftedCards, kv.Key, kv.Value))
                {
                    error = "扣卡牌库存失败：" + kv.Key;
                    return false;
                }
            }
        }

        // 扣实物库（骰子 / 消耗品）
        if (!ConsumeStacks(_data.storedItems, s.dice, out error)) return false;
        if (!ConsumeStacks(_data.storedItems, s.consumables, out error)) return false;

        _data.loadout = CloneLoadout(s);
        Save();
        return true;
    }

    static bool ConsumeStacks(List<NamedStack> source, List<NamedStack> take, out string error)
    {
        error = "";
        if (take == null) return true;
        for (int i = 0; i < take.Count; i++)
        {
            NamedStack st = take[i];
            if (st == null || st.count <= 0) continue;
            if (!TryConsumeFrom(source, st.name, st.count))
            {
                error = "扣实物库存失败：" + st.name;
                return false;
            }
        }
        return true;
    }

    /// <summary>快照深拷贝（Peek / 写盘共用；入参 null → 空快照）。</summary>
    static LoadoutSnapshot CloneLoadout(LoadoutSnapshot s)
    {
        var c = new LoadoutSnapshot();
        if (s == null) return c;
        if (s.cards != null) c.cards.AddRange(s.cards);
        if (s.passives != null) c.passives.AddRange(s.passives);
        CloneStacks(c.dice, s.dice);
        CloneStacks(c.consumables, s.consumables);
        return c;
    }

    static void CloneStacks(List<NamedStack> target, List<NamedStack> source)
    {
        if (source == null) return;
        for (int i = 0; i < source.Count; i++)
        {
            NamedStack st = source[i];
            target.Add(st != null ? new NamedStack { name = st.name, count = st.count } : new NamedStack());
        }
    }

    // ------------------------------------------------------------------
    // 持久化
    // ------------------------------------------------------------------

    static void Load()
    {
        try
        {
            if (File.Exists(SavePath))
            {
                _data = JsonUtility.FromJson<SaveData>(File.ReadAllText(SavePath));
            }
        }
        catch (Exception e)
        {
            Debug.LogWarning($"[MetaWallet] 存档读取失败，回退空钱包：{e.Message}");
        }
        if (_data == null) _data = new SaveData();
        NormalizeLists();
        MigrateLegacyInts();
    }

    /// <summary>老档 / 手改档里可能缺列表（FromJson 会给 null）——统一补成空表。</summary>
    static void NormalizeLists()
    {
        if (_data.materialStacks == null) _data.materialStacks = new List<NamedStack>();
        if (_data.soulStacks == null) _data.soulStacks = new List<NamedStack>();
        if (_data.corpseMaterialStacks == null) _data.corpseMaterialStacks = new List<NamedStack>();
        if (_data.unlockedRecipes == null) _data.unlockedRecipes = new List<string>();
        if (_data.craftedCards == null) _data.craftedCards = new List<NamedStack>();
        if (_data.passiveUnlocks == null) _data.passiveUnlocks = new List<string>();
        if (_data.storedItems == null) _data.storedItems = new List<NamedStack>();
        if (_data.upgradedNodes == null) _data.upgradedNodes = new List<string>();
        if (_data.loadout == null) _data.loadout = new LoadoutSnapshot();
    }

    /// <summary>
    /// 旧档迁移：把 v2.1 之前的三个「整数计数」（材料 / 灵魂 / 尸体材料）各转成一条「未分类」堆。
    /// 已有新格式数据的档不动（避免重复算）；旧计数一律清零（Save 里也不再写回）。
    /// </summary>
    static void MigrateLegacyInts()
    {
        int mats = MigrateLegacyStack(_data.materialStacks, _data.materials, LegacyMaterialName);
        int souls = MigrateLegacyStack(_data.soulStacks, _data.souls, LegacySoulName);
        int corpse = MigrateLegacyStack(_data.corpseMaterialStacks, _data.corpseMaterials, LegacyMaterialName);

        _data.materials = 0;
        _data.souls = 0;
        _data.corpseMaterials = 0;

        ReportMigration("材料", LegacyMaterialName, mats);
        ReportMigration("灵魂", LegacySoulName, souls);
        ReportMigration("尸体材料", LegacyMaterialName, corpse);

        if (mats + souls + corpse > 0) Save();
    }

    static void ReportMigration(string label, string legacyName, int migrated)
    {
        if (migrated <= 0) return;
        Debug.LogWarning($"[MetaWallet] 旧档迁移：整数{label} {migrated} → 「{legacyName}×{migrated}」" +
                         "（旧档没有种类信息，只能归到未分类；可在 F9 面板清档重来）");
    }

    /// <summary>
    /// 迁移核心（纯函数，L2 可断言）：legacyCount &gt; 0 且 stacks 为空 → 并入一条 legacyName 堆。
    /// 返回并入的件数（0 = 无需迁移 / 已有新格式数据）。
    /// </summary>
    public static int MigrateLegacyStack(List<NamedStack> stacks, int legacyCount, string legacyName)
    {
        if (stacks == null || legacyCount <= 0 || stacks.Count > 0) return 0;
        stacks.Add(new NamedStack { name = legacyName, count = legacyCount });
        return legacyCount;
    }

    static void Save()
    {
        try
        {
            _data.souls = 0;            // 旧字段不再写入（保留字段只为读旧档）
            _data.materials = 0;
            _data.corpseMaterials = 0;
            File.WriteAllText(SavePath, JsonUtility.ToJson(_data, true));
        }
        catch (Exception e)
        {
            Debug.LogWarning($"[MetaWallet] 存档写入失败：{e.Message}");
        }
    }

    /// <summary>
    /// 立即把当前内存数据落盘到「当前存档位」。
    /// 用途：进藏身处时的自动保存（用户 2026-09-14 决策）。改动本身已即时写盘，这里是显式兜底。
    /// </summary>
    public static void Flush()
    {
        EnsureLoaded();
        Save();
        Debug.Log($"[MetaWallet] 自动保存 → 存档 {SaveSlots.ActiveSlot}（材料 {MaterialSummary()}、" +
                  $"灵魂 {SoulSummary()}、教学 {_data.tutorialStage}）");
    }

    /// <summary>
    /// 切换「当前存档位」并重新加载：空槽 = 全新档（全零），不会拿上一槽的数据顶包。
    /// </summary>
    public static void SwitchSlot(int slot)
    {
        SaveSlots.SetActive(slot);
        _data = null;          // 丢掉旧槽缓存
        EnsureLoaded();        // 从新槽文件重新加载（无文件则 new SaveData）
        Debug.Log($"[MetaWallet] 已切到存档 {slot}：材料 {MaterialSummary()}、灵魂 {SoulSummary()}、教学 {_data.tutorialStage}");
    }

    /// <summary>调试/重置用：清空钱包并删档。</summary>
    public static void ResetAll()
    {
        _data = new SaveData();
        Save();
        Debug.Log("[MetaWallet] 钱包已重置");
    }
}
