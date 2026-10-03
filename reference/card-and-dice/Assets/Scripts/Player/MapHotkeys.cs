// =============================================================================
// 模块：全局快捷键 MapHotkeys
// 用途：把高频操作从「点按钮」变成「敲键」，减少鼠标来回移动。
//
//   当前只有一条：**空格 = 结束回合**（等价于点 EndTurnButton）。
//
// ★2026-09-12 变更：本文件原本还有「右键 = 耗 1 枚探索骰换行动点」，已**删除**。
//   原因：移动改成「点远处 → 超出行动点的部分自动消耗探索骰」之后（HexMover.PayDiceForMove），
//   玩家不必再手动换行动点——系统在点下去的那一刻就算好并扣掉了。
//   留着右键反而会和自动扣骰重复扣两次。
//
// -----------------------------------------------------------------------------
// ★ 让路规则（用户明确要求，也是本文件最容易出错的地方）
// -----------------------------------------------------------------------------
// 用户原话：「注意打开背包的时候以及手上正操作着卡牌的时候按右键不要消耗探索骰子换步数」。
// 实现在 Interactions.CanUseGlobalHotkeys()：任何「会挡住战场的界面」或「卡牌交互流」期间
// 一律不响应快捷键。逐条对应：
//   · 打开背包 → InventoryUI 置 ModalPopupActive = true      → 让路
//   · 手上操作卡牌 → Interactions.CardInteractionActive（手牌拖动/点击跟随/指向、
//                    战术槽起手/指向全部会置）                → 让路
//   · 卡包（非模态，不置 ModalPopupActive）→ 单独判 CardPackUI.IsOpen → 让路
//   · 事件/搜刮/篝火/战报/装填/设置/魂灯 → 同上（ModalPopupActive 或各自 IsOpen）
//   · 结算中（ActionSystem.IsPerforming）                       → 让路
//
// 空格与鼠标位置无关（看着哪里都能按）；战斗态与探索态都支持，
// 最终交给各管理器自己的状态守卫（TurnManager / ExplorationTurnManager）。
//
// 挂载：突袭场景（TutorialScene / FogTownScene）的 GameManager（与 ExplorationTurnManager 同对象）。
// =============================================================================
using UnityEngine;

public class MapHotkeys : MonoBehaviour
{
    [Header("快捷键开关")]
    [Tooltip("空格 = 结束回合")]
    public bool enableEndTurnHotkey = true;

    private void Update()
    {
        if (enableEndTurnHotkey && Input.GetKeyDown(KeyCode.Space)) TryEndTurn();
    }

    /// <summary>
    /// 与点 EndTurnButton 等价：按钮的可用性判定（Interactions.CanUseEndTurnButton）
    /// 已经覆盖「模态弹窗打开 / 不是玩家阶段 / 敌人回合」，这里只需要再排除
    /// 「正在操作卡牌 / 结算中 / 其他非模态面板打开」（统一走 CanUseGlobalHotkeys）。
    /// </summary>
    private void TryEndTurn()
    {
        if (!Interactions.CanUseGlobalHotkeys()) return;
        if (!Interactions.CanUseEndTurnButton()) return;
        if (GameStateManager.Instance == null) return;

        if (GameStateManager.Instance.CurrentState == GameState.Battle)
        {
            TurnManager.Instance?.EndPlayerTurn();
        }
        else
        {
            ExplorationTurnManager.Instance?.EndExplorationTurn();
        }
        Debug.Log("[快捷键] 空格 → 结束回合");
    }
}
