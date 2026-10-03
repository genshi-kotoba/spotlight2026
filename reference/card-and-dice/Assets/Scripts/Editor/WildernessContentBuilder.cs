// =============================================================================
// 编辑器工具：荒野内容构建器（设计页 v3 → 资产落库，一次性工具 + 可反复执行）
// 数据源：Assets/Scripts/Editor/WildernessContent.json
//   （由 docs/_tmp_gen_content.js 从 docs/2026-09-16_荒野怪物设计页-v3.html 生成）
// 口径依据：设计页 R3 第八节（平衡对标）/ 第九节（骰子装配）/ 第十节（两条定义补齐）
//   · 骰子装配 = 每张招式 CardData 的 diceSlot1-4 装「破旧骰子 d4」× 骰数列（d6 会让全表失准）
//   · 敌人出牌走 card 自带骰子（EnemyCardExecutor → card.RollAllDice），IntentOption 骰槽留空
// 菜单：Tools/荒野/1..7（幂等：按路径 LoadOrCreate，已存在只覆盖字段不重复建）
//   ★2026-09-16 掉落物批：1b 材料（七族三件套 21 件 + 精英/Boss 独特 15 件）、
//     5 小队改为按「怪自己」的 material/uniqueDrop 派生（不再按小队一种材料）、
//     7 宝箱目录（七群系各一行 → Assets/Resources/WildernessChestCatalog.asset）
// =============================================================================
#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

public static class WildernessContentBuilder
{
    const string JsonPath      = "Assets/Scripts/Editor/WildernessContent.json";
    const string CardDir       = "Assets/Data/Cards/Wilderness";
    const string EnemyDir      = "Assets/Data/Enemies/Wilderness";
    const string ItemDir       = "Assets/Data/Items";
    const string PassiveDir    = "Assets/Data/Passives";
    const string SquadDir      = "Assets/Data/Squads";
    const string EncounterDir  = "Assets/Resources/Encounters";
    const string D4Path        = "Assets/Data/Dice/破旧骰子.asset";
    // 荒野敌人共用占位视觉壳（复制自 Enemy_哥布林.prefab：红方块 + 血条）——缺它 = SpawnResolver 白方块兜底、无血条 UI
    const string EnemyPrefabPath = "Assets/Prefabs/Enemy_荒野.prefab";
    const string PlayerSoulA   = "史莱姆的灵魂";     // 流浪怪已用旧灵魂（本次不重建）
    const string PlayerSoulB   = "哥布林的灵魂";

    static int _idCounter;

    // ------------------------------------------------------------------
    // JSON DTO（JsonUtility 兼容：public 字段 + [Serializable]，无字典）
    // ------------------------------------------------------------------
    [Serializable] public class Root       { public List<SoulDto> souls; public List<MaterialDto> materials; public List<PassiveDto> passives; public List<CardDto> cards; public List<EnemyDto> enemies; public List<SquadDto> squads; public List<TableDto> tables; public List<ChestLootDto> chestLoot; }
    [Serializable] public class SoulDto    { public string name; public string desc; }
    [Serializable] public class MaterialDto { public string name; public string desc; }
    [Serializable] public class ChestLootDto { public int biome; public string family; public string item; public int min; public int max; }
    [Serializable] public class PassiveDto { public string name; public string desc; public int moveDelta; public int visionDelta; public bool hasMove; public bool hasVision; public int rarity; public int value; }
    [Serializable] public class EffectDto  { public int type; public int target; public int @base; public int dice; public int count; public int countDice; public int duration; public string status; public int stacks; }
    [Serializable] public class CardDto    { public string name; public int energy; public int cooldown; public int range; public int suit; public int dice; public string desc; public string rawDesc; public int rarity; public List<EffectDto> effects; }
    [Serializable] public class OptionDto  { public string card; public bool advance; }
    [Serializable] public class BigDto     { public List<OptionDto> options; }
    [Serializable] public class EnemyDto   { public string name; public string unitId; public string family; public int hpMin; public int hpMax; public int move; public int vision; public int patrolAP; public int patrolRadius; public int leash; public string role; public string preset; public bool canSprint; public bool isBoss; public bool isElite; public string soul; public List<string> passives; public List<BigDto> loop; public List<string> loot; public string material; public string uniqueDrop; }
    [Serializable] public class MemberDto  { public string preset; }
    [Serializable] public class SquadDto   { public string name; public string family; public int formation; public List<MemberDto> members; }
    [Serializable] public class EntryDto   { public string squad; public int weight; }
    [Serializable] public class TableDto   { public string name; public string mapId; public string biome; public int minSquads; public int maxSquads; public int minWaypoints; public int maxWaypoints; public int patrolAPMin; public int patrolAPMax; public int minDistanceFromStart; public int minSquadSeparation; public List<EntryDto> entries; }

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
            Debug.LogError("[荒野构建器] 找不到数据文件 " + JsonPath + "（跑 docs/_tmp_gen_content.js 生成）");
            return;
        }
        _root = JsonUtility.FromJson<Root>(ta.text);
    }

    // ------------------------------------------------------------------
    // 入口：一键全部
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/0. 一键全部（灵魂→材料→卡→被动→敌人→小队→遭遇表→宝箱→灵魂池→工坊目录）")]
    public static void BuildAll()
    {
        _idCounter = 0;
        int[] n = new int[10];
        n[0] = BuildSouls();
        n[1] = BuildMaterials();      // 必须早于 BuildSquads：小队掉落要按名字取材料资产
        n[2] = BuildCards();
        n[3] = BuildPassives();
        n[4] = BuildEnemies();        // 必须早于 BuildSoulCatalog：灵魂池目录要按名字取敌人资产
        n[5] = BuildSquads();
        n[6] = BuildTables();
        n[7] = BuildChestCatalog();
        n[8] = BuildSoulCatalog();
        n[9] = BuildCraftCatalog();   // 必须最后：依赖敌人（family）＋ 卡/被动/材料资产全部就位
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log(string.Format("[荒野构建器] 全量完成：灵魂 {0}｜材料 {1}｜卡 {2}｜被动 {3}｜敌人 {4}｜小队 {5}｜遭遇表 {6}｜宝箱目录 {7}｜灵魂池 {8}｜工坊目录 {9}",
            n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8], n[9]));
    }

    // ------------------------------------------------------------------
    // 1. 骰子与灵魂
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/1. 灵魂物品")]
    public static int BuildSouls()
    {
        if (Reload() == null) return 0;
        EnsureFolder(ItemDir);
        int n = 0;
        foreach (SoulDto s in Data.souls)
        {
            ItemData item = LoadOrCreate<ItemData>(ItemDir + "/" + s.name + ".asset");
            if (string.IsNullOrEmpty(item.itemID)) item.itemID = NewID("ITEM");
            item.itemName = s.name;
            item.description = s.desc;
            item.type = ItemType.灵魂;
            item.stackLimit = 1;
            EditorUtility.SetDirty(item);
            n++;
        }
        AssetDatabase.SaveAssets();
        Debug.Log("[荒野构建器] 灵魂物品 " + n + " 个 → " + ItemDir);
        return n;
    }

    // ------------------------------------------------------------------
    // 1b. 材料（七族各三件套 = 21 件族材 + 15 件精英/Boss 独特）
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/1b. 材料（族材＋独特）")]
    public static int BuildMaterials()
    {
        if (Reload() == null) return 0;
        EnsureFolder(ItemDir);
        int n = 0;
        foreach (MaterialDto m in Data.materials)
        {
            ItemData item = LoadOrCreate<ItemData>(ItemDir + "/" + m.name + ".asset");
            if (string.IsNullOrEmpty(item.itemID)) item.itemID = NewID("ITEM");
            item.itemName = m.name;
            item.description = m.desc;
            item.type = ItemType.材料;
            item.stackLimit = 20;
            EditorUtility.SetDirty(item);
            n++;
        }
        AssetDatabase.SaveAssets();
        Debug.Log("[荒野构建器] 材料 " + n + " 件 → " + ItemDir +
                  "（族材 21 + 精英/Boss 独特 15）");
        return n;
    }

    // ------------------------------------------------------------------
    // 2. 招式卡
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/2. 招式卡")]
    public static int BuildCards()
    {
        if (Reload() == null) return 0;
        EnsureFolder("Assets/Data/Cards");
        EnsureFolder(CardDir);
        DiceData d4 = AssetDatabase.LoadAssetAtPath<DiceData>(D4Path);
        if (d4 == null) { Debug.LogError("[荒野构建器] 缺 " + D4Path + "（d4 基线骰）"); return 0; }

        int n = 0;
        foreach (CardDto c in Data.cards)
        {
            CardData card = LoadOrCreate<CardData>(CardDir + "/" + c.name + ".asset");
            card.cardID = "CARD_WILD_" + c.name;
            card.cardName = c.name;
            card.energyCost = c.energy;
            card.cooldown = c.cooldown;
            card.rangeConfig = new ValueConfig { baseValue = c.range, diceSelect = DiceSelect.无 };
            card.description = c.desc;
            card.rarity = (CardRarity)Mathf.Clamp(c.rarity, 0, 3);
            card.suit1 = (SuitOption)c.suit; card.suit2 = SuitOption.无; card.suit3 = SuitOption.无; card.suit4 = SuitOption.无;
            card.isUpgraded = false;
            card.upgradeEffect = "无";
            card.diceSlot1 = c.dice >= 1 ? d4 : null;
            card.diceSlot2 = c.dice >= 2 ? d4 : null;
            card.diceSlot3 = c.dice >= 3 ? d4 : null;
            card.diceSlot4 = c.dice >= 4 ? d4 : null;
            card.effects = new List<CardEffect>();
            if (c.effects != null)
            {
                foreach (EffectDto e in c.effects)
                {
                    CardEffect fx = new CardEffect();
                    fx.targetType = e.type == 1 ? CardTargetType.自己 : (CardTargetType)Mathf.Clamp(e.target, 0, 2);
                    // ★2026-09-16 次数骰（「[1] 伤害 ×t1 次」）：count 位吃骰子，段数由掷骰决定；
                    // 伤害本体 base 固定不吃骰 → 每段都吃力量加成，且不受骰面上下限修正影响。
                    DiceSelect countDie = (DiceSelect)Mathf.Clamp(e.countDice, 0, 4);
                    fx.attackCountConfig = new ValueConfig { baseValue = e.count > 0 ? e.count : 1, diceSelect = countDie };
                    if (e.type == 0)
                    {
                        fx.effectType = CardEffectType.伤害;
                        fx.damageConfig = new ValueConfig { baseValue = e.@base, diceSelect = (DiceSelect)e.dice };
                    }
                    else if (e.type == 1)
                    {
                        fx.effectType = CardEffectType.防御;
                        fx.defenseConfig = new ValueConfig { baseValue = e.@base, diceSelect = (DiceSelect)e.dice };
                        fx.defenseCountConfig = new ValueConfig { baseValue = 1, diceSelect = countDie };
                    }
                    else
                    {
                        fx.effectType = CardEffectType.效果;
                        fx.effectTypeName = e.status;
                        fx.effectStacksConfig = new ValueConfig
                        {
                            baseValue = e.stacks > 0 ? e.stacks : e.@base,
                            diceSelect = (DiceSelect)e.dice
                        };
                        fx.effectCountConfig = new ValueConfig { baseValue = 1, diceSelect = countDie };
                    }
                    card.effects.Add(fx);
                }
            }
            EditorUtility.SetDirty(card);
            n++;
        }
        AssetDatabase.SaveAssets();
        Debug.Log("[荒野构建器] 招式卡 " + n + " 张 → " + CardDir + "（骰槽＝破旧骰子 d4 × 骰数列）");
        return n;
    }

    // ------------------------------------------------------------------
    // 3. 被动
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/3. 被动")]
    public static int BuildPassives()
    {
        if (Reload() == null) return 0;
        EnsureFolder(PassiveDir);
        int n = 0;
        foreach (PassiveDto p in Data.passives)
        {
            PassiveData pa = LoadOrCreate<PassiveData>(PassiveDir + "/" + p.name + ".asset");
            pa.passiveID = "PASSIVE_WILD_" + p.name;
            pa.passiveName = p.name;
            pa.description = p.desc;
            // ★B2 装置：稀有度（抽取权重档）+ 价值点（编队预算），值表见 B2 计划 §3
            pa.rarity = (CardRarity)Mathf.Clamp(p.rarity, 0, 3);
            pa.value = Mathf.Clamp(p.value, 1, 4);
            pa.grants = new List<PassiveGrant>();
            // 只落引擎能表达的两条：移动力/视野属性修饰；其余机制（标记/复活/荆棘/毒…）暂在 description
            if (p.hasMove)
            {
                PassiveGrant g = new PassiveGrant();
                g.type = GrantType.AttributeModifier;
                g.attribute = new AttributeModifier { attribute = AttributeType.MoveRange, delta = p.moveDelta };
                g.statusEffectName = ""; g.stacks = 0;
                pa.grants.Add(g);
            }
            if (p.hasVision)
            {
                PassiveGrant g = new PassiveGrant();
                g.type = GrantType.AttributeModifier;
                g.attribute = new AttributeModifier { attribute = AttributeType.VisionRange, delta = p.visionDelta };
                g.statusEffectName = ""; g.stacks = 0;
                pa.grants.Add(g);
            }
            EditorUtility.SetDirty(pa);
            n++;
        }
        AssetDatabase.SaveAssets();
        Debug.Log("[荒野构建器] 被动 " + n + " 条 → " + PassiveDir + "（可落属性修饰 " + CountGrants() + " 条）");
        return n;
    }

    static int CountGrants()
    {
        int g = 0;
        foreach (PassiveDto p in Data.passives) if (p.hasMove || p.hasVision) g++;
        return g;
    }

    // ------------------------------------------------------------------
    // 4. 敌人
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/4. 敌人")]
    public static int BuildEnemies()
    {
        if (Reload() == null) return 0;
        EnsureFolder("Assets/Data/Enemies");
        EnsureFolder(EnemyDir);

        int n = 0, loopMiss = 0;
        foreach (EnemyDto e in Data.enemies)
        {
            EnemyData ed = LoadOrCreate<EnemyData>(EnemyDir + "/" + e.name + ".asset");
            ed.enemyID = "ENEMY_WILD_" + e.unitId;
            ed.enemyName = e.name;
            ed.hpMin = e.hpMin; ed.hpMax = e.hpMax;
            ed.moveRange = e.move; ed.visionRange = e.vision;
            ed.patrolAP = e.patrolAP; ed.patrolRadius = e.patrolRadius;
            ed.searchLeashRadius = e.leash;
            ed.combatRole = ParseEnum<CombatRole>(e.role, CombatRole.近卫);
            ed.canSprint = e.canSprint; ed.sprintValue = 1; ed.sprintMax = 3;
            ed.movePreset = ParseEnum<MoveAIPresetType>(e.preset, MoveAIPresetType.本能);
            ed.moveParams = new MoveParams
            {
                kiteDistance = ed.movePreset == MoveAIPresetType.风筝 ? 1 : 0,
                keepAwayMinDist = 0,
                interceptVision = ed.movePreset == MoveAIPresetType.拦截 ? e.vision : 0
            };

            ed.prefab = AssetDatabase.LoadAssetAtPath<GameObject>(EnemyPrefabPath);
            if (ed.prefab == null) Debug.LogWarning("[荒野构建器] 缺占位预制体：" + EnemyPrefabPath);

            ItemData soul = AssetDatabase.LoadAssetAtPath<ItemData>(ItemDir + "/" + e.soul + ".asset");
            if (soul == null) Debug.LogWarning("[荒野构建器] " + e.name + " 缺灵魂资产：" + e.soul);
            ed.soulItem = soul;

            ed.passives = new List<PassiveData>();
            if (e.passives != null)
                foreach (string pn in e.passives)
                {
                    PassiveData pa = AssetDatabase.LoadAssetAtPath<PassiveData>(PassiveDir + "/" + pn + ".asset");
                    if (pa == null) Debug.LogWarning("[荒野构建器] " + e.name + " 缺被动资产：" + pn);
                    else ed.passives.Add(pa);
                }

            // ★B2 装置：产出卡全集（灵魂提取池的「卡」半边，被动半边＝上面的 ed.passives）。
            //   来源同小队掉落配置（同一个 JSON loot），两处不会分叉。
            ed.lootCards = new List<CardData>();
            if (e.loot != null)
                foreach (string cn in e.loot)
                {
                    CardData cd = AssetDatabase.LoadAssetAtPath<CardData>(CardDir + "/" + cn + ".asset");
                    if (cd == null) Debug.LogWarning("[荒野构建器] " + e.name + " 产出卡缺失：" + cn);
                    else ed.lootCards.Add(cd);
                }

            ed.intentLoop = new List<EnemyBigIntent>();
            if (e.loop != null)
                foreach (BigDto b in e.loop)
                {
                    EnemyBigIntent big = new EnemyBigIntent();
                    foreach (OptionDto o in b.options)
                    {
                        CardData cd = AssetDatabase.LoadAssetAtPath<CardData>(CardDir + "/" + o.card + ".asset");
                        if (cd == null) { Debug.LogWarning("[荒野构建器] " + e.name + " 循环引卡缺失：" + o.card); loopMiss++; continue; }
                        // 骰槽留空 = 沿用 card 自带骰（EnemyCardExecutor 走 card.RollAllDice）
                        big.options.Add(new EnemyIntentOption { card = cd, advanceOnSuccess = o.advance });
                    }
                    ed.intentLoop.Add(big);
                }

            EditorUtility.SetDirty(ed);
            n++;
        }
        AssetDatabase.SaveAssets();
        Debug.Log("[荒野构建器] 敌人 " + n + " 个 → " + EnemyDir + (loopMiss > 0 ? "（循环引卡缺失 " + loopMiss + "）" : ""));
        return n;
    }

    // ------------------------------------------------------------------
    // 5. 小队（含掉落配置；站位用 SpawnResolver.ApplyFormation 自动填）
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/5. 小队")]
    public static int BuildSquads()
    {
        if (Reload() == null) return 0;
        int n = 0;
        foreach (SquadDto s in Data.squads)
        {
            EnemySquadData sq = LoadOrCreate<EnemySquadData>(SquadDir + "/" + s.name + ".asset");
            sq.squadID = "SQUAD_WILD_" + s.name;
            sq.squadName = s.name;
            sq.formation = (FormationType)Mathf.Clamp(s.formation, 0, 4);
            sq.units = new List<EnemyUnitConfig>();
            foreach (MemberDto m in s.members)
            {
                EnemyData preset = AssetDatabase.LoadAssetAtPath<EnemyData>(EnemyDir + "/" + m.preset + ".asset");
                if (preset == null) { Debug.LogWarning("[荒野构建器] " + s.name + " 缺敌人资产：" + m.preset); continue; }
                sq.units.Add(new EnemyUnitConfig { preset = preset, hexOffset = Vector2Int.zero });
            }
            SpawnResolver.ApplyFormation(sq);       // 按编队模板自动填 hexOffset

            // ★2026-09-16 族材按「怪自己」派生，不按小队：混编队（狼+鳄+蟒）各掉各的，
            //   同一只精英在哪支队伍里都掉同一件独特 —— 掉落跟怪走。
            SquadDropConfig cfg = new SquadDropConfig();
            foreach (EnemyUnitConfig u in sq.units)
            {
                EnemyDto dto = FindEnemy(u.preset.enemyName);
                MemberDropConfig mc = new MemberDropConfig
                {
                    presetRef = u.preset,
                    soulMode = SoulDropMode.沿用预设,
                    bagCardChance = 0.3f
                };
                if (dto != null)
                {
                    // 数量档：普通 3–5 / 精英 6–8 / Boss 10–12
                    int lo = dto.isBoss ? 10 : (dto.isElite ? 6 : 3);
                    int hi = dto.isBoss ? 12 : (dto.isElite ? 8 : 5);
                    ItemData mat = LoadItem(dto.material);
                    if (mat == null) Debug.LogWarning("[荒野构建器] " + s.name + " 的 " + dto.name +
                                                      " 缺族材资产：" + dto.material);
                    else mc.materials.Add(new MaterialDropRange { item = mat, min = lo, max = hi });

                    // 精英 / Boss 的独特掉落（各 1 件，材料型；跟着怪走）
                    ItemData uniq = LoadItem(dto.uniqueDrop);
                    if (uniq != null)
                        mc.materials.Add(new MaterialDropRange { item = uniq, min = 1, max = 1 });
                    else if (!string.IsNullOrEmpty(dto.uniqueDrop))
                        Debug.LogWarning("[荒野构建器] " + s.name + " 的 " + dto.name +
                                         " 缺独特掉落资产：" + dto.uniqueDrop);
                }
                if (dto != null && dto.loot != null)
                {
                    foreach (string cardName in dto.loot)
                    {
                        CardData cd = AssetDatabase.LoadAssetAtPath<CardData>(CardDir + "/" + cardName + ".asset");
                        if (cd == null) { Debug.LogWarning("[荒野构建器] " + s.name + " 掉落卡缺失：" + cardName); continue; }
                        mc.rewardCards.Add(new WeightedCardEntry { card = cd, weight = 1f });
                        mc.bagCards.Add(new WeightedCardEntry { card = cd, weight = 1f });
                    }
                }
                cfg.members.Add(mc);
            }
            sq.dropConfig = cfg;
            EditorUtility.SetDirty(sq);
            n++;
        }
        AssetDatabase.SaveAssets();
        Debug.Log("[荒野构建器] 小队 " + n + " 支 → " + SquadDir);
        return n;
    }

    // ------------------------------------------------------------------
    // 6. 群系遭遇表
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/6. 遭遇表")]
    public static int BuildTables()
    {
        if (Reload() == null) return 0;
        EnsureFolder("Assets/Resources");
        EnsureFolder(EncounterDir);
        int n = 0;
        foreach (TableDto t in Data.tables)
        {
            EncounterTable table = LoadOrCreate<EncounterTable>(EncounterDir + "/" + t.name + ".asset");
            table.mapId = t.mapId;
            table.biome = t.biome;
            table.minSquadsPerZone = t.minSquads;
            table.maxSquadsPerZone = t.maxSquads;
            table.minWaypoints = t.minWaypoints;
            table.maxWaypoints = t.maxWaypoints;
            table.patrolAPMin = t.patrolAPMin;
            table.patrolAPMax = t.patrolAPMax;
            table.minDistanceFromStart = t.minDistanceFromStart;
            table.minSquadSeparation = t.minSquadSeparation;
            table.entries = new List<EncounterTable.Entry>();
            foreach (EntryDto en in t.entries)
            {
                EnemySquadData sq = AssetDatabase.LoadAssetAtPath<EnemySquadData>(SquadDir + "/" + en.squad + ".asset");
                if (sq == null) { Debug.LogWarning("[荒野构建器] " + t.name + " 缺小队资产：" + en.squad); continue; }
                table.entries.Add(new EncounterTable.Entry { squad = sq, weight = en.weight });
            }
            EditorUtility.SetDirty(table);
            n++;
        }
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log("[荒野构建器] 遭遇表 " + n + " 张 → " + EncounterDir);
        return n;
    }

    // ------------------------------------------------------------------
    // 7. 宝箱目录（七群系各一行：本群系箱子出的那件族材）
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/7. 宝箱目录")]
    public static int BuildChestCatalog()
    {
        if (Reload() == null) return 0;
        EnsureFolder("Assets/Resources");
        WildernessChestCatalog cat = LoadOrCreate<WildernessChestCatalog>(
            "Assets/Resources/" + WildernessChestCatalog.ResourcePath + ".asset");
        cat.rows = new List<WildernessChestCatalog.ChestLootRow>();
        int n = 0;
        foreach (ChestLootDto c in Data.chestLoot)
        {
            ItemData item = LoadItem(c.item);
            if (item == null) { Debug.LogWarning("[荒野构建器] 宝箱目录缺材料资产：" + c.item); continue; }
            cat.rows.Add(new WildernessChestCatalog.ChestLootRow
            {
                biome = c.biome,
                family = c.family,
                item = item,
                min = c.min,
                max = c.max
            });
            n++;
        }
        EditorUtility.SetDirty(cat);
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log("[荒野构建器] 宝箱目录 " + n + " 行 → Assets/Resources/" +
                  WildernessChestCatalog.ResourcePath + ".asset");
        return n;
    }

    // ------------------------------------------------------------------
    // 8. 灵魂池目录（灵魂 → 怪；藏身处「灵魂提取装置」按玩家手上的灵魂反查产出池）
    //    为什么必须落表：EnemyData 资产不在 Resources 下，运行期扫不到；灵魂对怪是单向引用。
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/8. 灵魂池目录")]
    public static int BuildSoulCatalog()
    {
        if (Reload() == null) return 0;
        EnsureFolder("Assets/Resources");
        WildernessSoulCatalog cat = LoadOrCreate<WildernessSoulCatalog>(
            "Assets/Resources/" + WildernessSoulCatalog.ResourcePath + ".asset");
        cat.rows = new List<WildernessSoulCatalog.SoulRow>();
        int n = 0;
        foreach (EnemyDto e in Data.enemies)
        {
            ItemData soul = LoadItem(e.soul);
            EnemyData enemy = AssetDatabase.LoadAssetAtPath<EnemyData>(EnemyDir + "/" + e.name + ".asset");
            if (soul == null || enemy == null)
            {
                Debug.LogWarning("[荒野构建器] 灵魂池目录缺行：" + e.name + "（soul=" + e.soul + "）");
                continue;
            }
            cat.rows.Add(new WildernessSoulCatalog.SoulRow { soul = soul, enemy = enemy });
            n++;
        }
        EditorUtility.SetDirty(cat);
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log("[荒野构建器] 灵魂池目录 " + n + " 行 → Assets/Resources/" +
                  WildernessSoulCatalog.ResourcePath + ".asset");
        return n;
    }

    // ------------------------------------------------------------------
    // 9. 工坊素材目录（B3：制卡/被动激活/兑物资的素材归属）
    // ------------------------------------------------------------------
    [MenuItem("Tools/荒野/9. 工坊素材目录")]
    public static int BuildCraftCatalog()
    {
        if (Reload() == null) return 0;
        EnsureFolder("Assets/Resources");
        WildernessCraftCatalog cat = LoadOrCreate<WildernessCraftCatalog>(
            "Assets/Resources/" + WildernessCraftCatalog.ResourcePath + ".asset");

        // 1) 家族 → 三件套 = 该族怪的 material ∪ 该族 chestLoot.item（按首见顺序，构建结果确定）
        var famOrder = new List<string>();
        var famMats = new Dictionary<string, List<string>>();
        foreach (EnemyDto e in Data.enemies)
        {
            if (string.IsNullOrEmpty(e.family) || string.IsNullOrEmpty(e.material)) continue;
            if (!famMats.ContainsKey(e.family)) { famMats[e.family] = new List<string>(); famOrder.Add(e.family); }
            if (!famMats[e.family].Contains(e.material)) famMats[e.family].Add(e.material);
        }
        foreach (ChestLootDto c in Data.chestLoot)
        {
            if (string.IsNullOrEmpty(c.family) || string.IsNullOrEmpty(c.item)) continue;
            if (!famMats.ContainsKey(c.family)) { famMats[c.family] = new List<string>(); famOrder.Add(c.family); }
            if (!famMats[c.family].Contains(c.item)) famMats[c.family].Add(c.item);
        }

        cat.families = new List<WildernessCraftCatalog.FamilyRow>();
        var claimed = new HashSet<string>();   // 已被族三件套认领的材料名
        foreach (string fam in famOrder)
        {
            var row = new WildernessCraftCatalog.FamilyRow { family = fam, materials = new List<ItemData>() };
            foreach (string mn in famMats[fam])
            {
                ItemData item = LoadItem(mn);
                if (item == null) { Debug.LogWarning("[荒野构建器] 工坊目录缺族材资产：" + fam + " / " + mn); continue; }
                row.materials.Add(item);
                claimed.Add(mn);
            }
            cat.families.Add(row);
        }

        // 2) 独特素材 = 材料总表 − 族三件套
        cat.uniqueMaterials = new List<ItemData>();
        foreach (MaterialDto m in Data.materials)
        {
            if (claimed.Contains(m.name)) continue;
            ItemData item = LoadItem(m.name);
            if (item == null) { Debug.LogWarning("[荒野构建器] 工坊目录缺独特素材资产：" + m.name); continue; }
            cat.uniqueMaterials.Add(item);
        }

        // 3) 卡 → 家族（跨族实测 0；万一将来跨族取首个并警告）
        cat.cards = new List<WildernessCraftCatalog.CardRow>();
        var cardFam = new Dictionary<string, string>();
        var cardOrder = new List<string>();
        foreach (EnemyDto e in Data.enemies)
        {
            if (e.loot == null) continue;
            foreach (string cn in e.loot)
            {
                if (string.IsNullOrEmpty(cn)) continue;
                if (!cardFam.ContainsKey(cn)) { cardFam[cn] = e.family; cardOrder.Add(cn); }
                else if (cardFam[cn] != e.family) Debug.LogWarning("[荒野构建器] 卡跨族（取首个）：" + cn + " " + cardFam[cn] + "/" + e.family);
            }
        }
        foreach (string cn in cardOrder)
        {
            CardData cd = AssetDatabase.LoadAssetAtPath<CardData>(CardDir + "/" + cn + ".asset");
            if (cd == null) { Debug.LogWarning("[荒野构建器] 工坊目录缺卡资产：" + cn); continue; }
            cat.cards.Add(new WildernessCraftCatalog.CardRow { card = cd, family = cardFam[cn] });
        }

        // 4) 被动 → 家族
        cat.passives = new List<WildernessCraftCatalog.PassiveRow>();
        var pasFam = new Dictionary<string, string>();
        var pasOrder = new List<string>();
        foreach (EnemyDto e in Data.enemies)
        {
            if (e.passives == null) continue;
            foreach (string pn in e.passives)
            {
                if (string.IsNullOrEmpty(pn)) continue;
                if (!pasFam.ContainsKey(pn)) { pasFam[pn] = e.family; pasOrder.Add(pn); }
                else if (pasFam[pn] != e.family) Debug.LogWarning("[荒野构建器] 被动跨族（取首个）：" + pn);
            }
        }
        foreach (string pn in pasOrder)
        {
            PassiveData pa = AssetDatabase.LoadAssetAtPath<PassiveData>(PassiveDir + "/" + pn + ".asset");
            if (pa == null) { Debug.LogWarning("[荒野构建器] 工坊目录缺被动资产：" + pn); continue; }
            cat.passives.Add(new WildernessCraftCatalog.PassiveRow { passive = pa, family = pasFam[pn] });
        }

        EditorUtility.SetDirty(cat);
        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
        Debug.Log("[荒野构建器] 工坊素材目录：族 " + cat.families.Count + "｜族材 " + claimed.Count +
                  "｜独特 " + cat.uniqueMaterials.Count + "｜卡 " + cat.cards.Count + "｜被动 " + cat.passives.Count +
                  " → Assets/Resources/" + WildernessCraftCatalog.ResourcePath + ".asset");
        return cat.cards.Count;
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------
    /// <summary>按材料名取 Assets/Data/Items 下的 ItemData；空名/null 返回 null（不报警）。</summary>
    static ItemData LoadItem(string itemName)
    {
        if (string.IsNullOrEmpty(itemName)) return null;
        return AssetDatabase.LoadAssetAtPath<ItemData>(ItemDir + "/" + itemName + ".asset");
    }

    static EnemyDto FindEnemy(string name)
    {
        foreach (EnemyDto e in Data.enemies) if (e.name == name) return e;
        return null;
    }

    static T ParseEnum<T>(string name, T fallback) where T : struct
    {
        try { return (T)Enum.Parse(typeof(T), name); }
        catch { Debug.LogWarning("[荒野构建器] 枚举解析失败：" + name + "（用兜底 " + fallback + "）"); return fallback; }
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

    static string NewID(string prefix)
    {
        return string.Format("{0}_WILD_{1:HHmmss}_{2}", prefix, System.DateTime.Now, ++_idCounter);
    }
}
#endif
