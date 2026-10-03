using UnityEngine;

/// <summary>
/// ★美术接入：把 Player.prefab 根节点的占位方块（MeshRenderer）换成
/// Resources/PlayerPortrait/Player 精灵（地图小人立绘）。
/// 运行时 Awake 执行一次，仅换视觉，不改任何游戏逻辑/碰撞。
/// </summary>
[RequireComponent(typeof(MeshRenderer))]
public class PlayerPortraitSwapper : MonoBehaviour
{
    [SerializeField] private string spritePath = "PlayerPortrait/Player";

    [Tooltip("地图上立绘的世界高度（格顶面到头顶）")]
    public float bodyWorldHeight = 0.7f;

    private void Awake()
    {
        Sprite sprite = Resources.Load<Sprite>(spritePath);
        if (sprite == null) return;

        float spriteWorldH = sprite.rect.height / sprite.pixelsPerUnit;
        if (spriteWorldH < 1e-4f) return;

        // 关掉占位方块（不删：碰撞体在根节点上，不受影响；forceRenderingOff 防别的系统把它 enable 回来）
        MeshRenderer block = GetComponent<MeshRenderer>();
        if (block != null)
        {
            block.enabled = false;
            block.forceRenderingOff = true;
        }

        // 在独立的子节点挂精灵（与敌人一致：不缩放根节点、不动碰撞盒）
        Transform bodySprite = transform.Find("BodySprite");
        if (bodySprite == null)
        {
            bodySprite = new GameObject("BodySprite").transform;
            bodySprite.SetParent(transform, false);
        }

        SpriteRenderer sr = bodySprite.GetComponent<SpriteRenderer>();
        if (sr == null) sr = bodySprite.gameObject.AddComponent<SpriteRenderer>();
        sr.sprite = sprite;
        sr.enabled = true;
        sr.sortingOrder = 10;

        // 立绘正对镜头：相机是固定 70° 俯视，不跟着俯就要被压扁成 34% 高（与 EnemyHPBar 同一套约定）
        Quaternion face = Quaternion.Euler(CameraPitch(), 0f, 0f);
        bodySprite.localRotation = face;

        // 高度按世界单位算，要除以父级缩放（玩家根节点是 0.5，不除就只有一半高）
        float parentScale = transform.lossyScale.y;
        if (parentScale < 1e-4f) parentScale = 1f;
        bodySprite.localScale = Vector3.one * (bodyWorldHeight / spriteWorldH / parentScale);

        // 脚底踩在格子顶面上（根 Y=0.5、方块中心在根上 ⇒ 底边 0.25），抬 3cm 防与格面互插
        Vector3 feet = new Vector3(transform.position.x, transform.position.y - 0.25f + 0.03f, transform.position.z);
        bodySprite.position = feet + (face * Vector3.up) * (bodyWorldHeight * 0.5f);
    }

    /// <summary>相机俯角（固定 70°，只平移缩放不转向）。与 EnemyController 同一约定。</summary>
    private static float cameraPitchCache = -1f;

    private static float CameraPitch()
    {
        if (cameraPitchCache < 0f)
        {
            Camera cam = Camera.main;
            cameraPitchCache = cam != null ? cam.transform.eulerAngles.x : 70f;
        }
        return cameraPitchCache;
    }
}
