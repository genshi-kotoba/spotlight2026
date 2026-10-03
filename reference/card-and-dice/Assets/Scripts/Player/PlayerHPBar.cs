// =============================================================================
// 模块：PlayerHPBar（玩家脚下血条 UI）
// 用途：在玩家脚下显示 HP 进度条，订阅 PlayerHealth.OnHPChanged 自动刷新
// 实现方式：与敌人血条（EnemyHPBar）完全同构 —— World Space Canvas + Slider，
//           固定 70° 倾斜匹配摄像机俯视角，不显示数字变化外的额外逻辑
// 设计依据：《总策划案》战斗系统 + 用户需求（2026-08-17）：玩家脚下血条与敌人一致
// 挂载位置：Player/HPBarCanvas（Canvas 子对象）
// =============================================================================
using System.Collections;
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 玩家脚下血条。挂在玩家 HPBarCanvas（World Space Canvas）上。
/// 参数与敌人血条对齐：pitch=70° / yaw=0° / 不做 Billboard（固定角度）。
/// </summary>
[RequireComponent(typeof(Canvas))]
public class PlayerHPBar : MonoBehaviour
{
    [Header("UI 引用")]
    [Tooltip("血条 Slider（必须填，value 范围 0~1）")]
    [SerializeField] private Slider hpSlider;

    [Tooltip("HP 文本（可空，显示 'currentHP/maxHP'，与敌人血条同款）")]
    [SerializeField] private Text hpText;

    [Header("跟随设置（与敌人血条对齐）")]
    [Tooltip("血条向前倾斜角度（X 轴旋转）。摄像机俯视角 70°，与敌人血条保持一致。")]
    [SerializeField] [Range(0f, 90f)] private float pitchAngle = 70f;

    [Tooltip("血条水平朝向（Y 轴旋转）。0°=面朝 +Z，与敌人血条保持一致。")]
    [SerializeField] [Range(0f, 360f)] private float yawAngle = 0f;

    [Tooltip("是否每帧自动面向摄像机（Billboard）。默认关闭，与敌人血条策略一致。")]
    [SerializeField] private bool faceCamera = false;

    // -------- 内部引用 --------
    private PlayerHealth playerHealth;
    private Camera mainCamera;

    private void Awake()
    {
        mainCamera = Camera.main;

        // ★2026-08-18：血条纯显示，禁用旗下所有 Graphic 的射线检测。
        // World Space Canvas 的 Image/Text 默认 raycastTarget=true，
        // 会被 EventSystem.IsPointerOverGameObject() 判为"鼠标在 UI 上"，
        // 挡住 HexMover 的格子悬停高亮/点击移动。与 EnemyHPBar 同款修复。
        // 放在所有 early return 之前，保证任何路径都执行。
        DisableRaycastTargets();

        // 向上查找 PlayerHealth（HPBar 是 Player 的子对象）
        playerHealth = GetComponentInParent<PlayerHealth>();
        if (playerHealth == null)
        {
            Debug.LogError($"[PlayerHPBar] {gameObject.name} 未在父级找到 PlayerHealth！");
            return;
        }

        if (hpSlider == null)
        {
            Debug.LogError($"[PlayerHPBar] {gameObject.name} 未指定 hpSlider！血条无法显示");
            return;
        }

        // 应用固定角度（不做 Billboard）
        ApplyFixedAngle();
    }

    /// <summary>
    /// 应用固定的倾斜角度和水平朝向（与 EnemyHPBar 同款逻辑）
    /// </summary>
    private void ApplyFixedAngle()
    {
        if (faceCamera) return;
        transform.localEulerAngles = new Vector3(pitchAngle, yawAngle, 0f);
    }

    /// <summary>
    /// 递归禁用血条下所有 Graphic（Image/Text/Slider 子件）的 raycastTarget。
    /// 血条不需要接收点击/悬停，关掉后不参与 UGUI 射线（与 EnemyHPBar 同款）。
    /// </summary>
    private void DisableRaycastTargets()
    {
        foreach (var graphic in GetComponentsInChildren<Graphic>(true))
        {
            graphic.raycastTarget = false;
        }
    }

    private void OnEnable()
    {
        if (playerHealth != null)
        {
            playerHealth.OnHPChanged += HandleHPChanged;
        }
    }

    private void OnDisable()
    {
        if (playerHealth != null)
        {
            playerHealth.OnHPChanged -= HandleHPChanged;
        }
    }

    private void Start()
    {
        // 初始刷新一次（显示满血）
        RefreshBar(playerHealth.CurrentHP, playerHealth.MaxHP);
    }

    private void LateUpdate()
    {
        // 只有 Billboard 模式才每帧更新朝向（默认关闭）
        if (!faceCamera) return;
        if (mainCamera == null) mainCamera = Camera.main;
        if (mainCamera == null) return;

        transform.LookAt(mainCamera.transform.position);
    }

    // ------------------------------------------------------------------
    // 调试/编辑辅助（与 EnemyHPBar 同款）
    // ------------------------------------------------------------------

    [ContextMenu("调试：应用固定角度")]
    private void Debug_ApplyFixedAngle()
    {
        ApplyFixedAngle();
        Debug.Log($"[PlayerHPBar] 已应用固定角度：pitch={pitchAngle}°, yaw={yawAngle}° → 实际 {transform.localEulerAngles}");
    }

    // ------------------------------------------------------------------
    // 事件处理
    // ------------------------------------------------------------------

    private void HandleHPChanged(int currentHP, int maxHP)
    {
        RefreshBar(currentHP, maxHP);
    }

    // ------------------------------------------------------------------
    // 刷新显示
    // ------------------------------------------------------------------

    private void RefreshBar(int currentHP, int maxHP)
    {
        if (hpSlider == null) return;

        float ratio = maxHP > 0 ? (float)currentHP / maxHP : 0f;
        hpSlider.value = Mathf.Clamp01(ratio);

        if (hpText != null)
        {
            hpText.text = $"{currentHP}/{maxHP}";
        }
    }
}
