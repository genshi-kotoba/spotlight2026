using UnityEngine;
using System.IO;
#if UNITY_EDITOR
using UnityEditor;
#endif

public class CreateCircleSprite : MonoBehaviour
{
    // ★2026-09-09：MenuItem/AssetDatabase 只在编辑器可用，整段包进 #if UNITY_EDITOR——
    //   原先顶层 using UnityEditor 会让 Player 构建直接编译失败（Console 里的 CS0246 旧报错）。
#if UNITY_EDITOR
    [MenuItem("Tools/Create Circle Sprite")]
    public static void CreateCircle()
    {
        // 创建一个256x256的纹理
        Texture2D texture = new Texture2D(256, 256, TextureFormat.RGBA32, false);
        
        // 填充透明背景
        for (int x = 0; x < 256; x++)
        {
            for (int y = 0; y < 256; y++)
            {
                texture.SetPixel(x, y, Color.clear);
            }
        }
        
        // 绘制圆形
        int centerX = 128;
        int centerY = 128;
        int radius = 100;
        
        for (int x = 0; x < 256; x++)
        {
            for (int y = 0; y < 256; y++)
            {
                float distance = Mathf.Sqrt(Mathf.Pow(x - centerX, 2) + Mathf.Pow(y - centerY, 2));
                if (distance <= radius)
                {
                    texture.SetPixel(x, y, Color.black);
                }
            }
        }
        
        // 应用更改
        texture.Apply();
        
        // 保存为PNG文件
        byte[] bytes = texture.EncodeToPNG();
        string path = Application.dataPath + "/Textures/CircleDot.png";
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllBytes(path, bytes);
        
        // 刷新AssetDatabase
        #if UNITY_EDITOR
        UnityEditor.AssetDatabase.Refresh();
        #endif
        
        Debug.Log("Circle sprite created at: " + path);
    }
#endif
}