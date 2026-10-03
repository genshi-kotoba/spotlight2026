using System.IO;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace CardDice.EditorTools
{
    /// <summary>
    /// 构建后处理：清掉输出目录里的 .pdb 调试符号。
    ///
    /// 背景（2026-09-14）：Mono 后端构建时 Unity 会把全部托管程序集的 .pdb 一并拷进
    /// `&lt;游戏&gt;_Data/Managed/`，实测 90 个文件共 8.03 MB，而 Build Settings 里
    /// 没有开关可以关掉（只有 Development Build，且本项目本来就是 False）。
    /// 这些 .pdb 只用于还原托管堆栈行号，发布包不需要。
    ///
    /// 若需要调试玩家端堆栈，把 s_stripPdb 改成 false 再构建即可。
    /// 本脚本位于 Editor 目录，不会进入游戏构建。
    /// </summary>
    public class BuildPostProcess : IPostprocessBuildWithReport
    {
        /// <summary>false = 保留 .pdb（需要调试玩家端堆栈时改成 false）</summary>
        private static bool s_stripPdb = true;

        public int callbackOrder
        {
            get { return 0; }
        }

        public void OnPostprocessBuild(BuildReport report)
        {
            if (!s_stripPdb)
            {
                return;
            }

            string outputPath = report.summary.outputPath;
            if (string.IsNullOrEmpty(outputPath))
            {
                return;
            }

            string root = Path.GetDirectoryName(outputPath);
            if (string.IsNullOrEmpty(root) || !Directory.Exists(root))
            {
                return;
            }

            int removed = 0;
            long bytes = 0;
            string[] pdbs;
            try
            {
                pdbs = Directory.GetFiles(root, "*.pdb", SearchOption.AllDirectories);
            }
            catch (System.Exception e)
            {
                Debug.LogWarning("[BuildPostProcess] 枚举 .pdb 失败：" + e.Message);
                return;
            }

            foreach (string pdb in pdbs)
            {
                try
                {
                    bytes += new FileInfo(pdb).Length;
                    File.Delete(pdb);
                    removed++;
                }
                catch (System.Exception)
                {
                    // 单个文件删不掉不影响构建结果，跳过
                }
            }

            if (removed > 0)
            {
                Debug.Log(string.Format(
                    "[BuildPostProcess] 已清理 {0} 个 .pdb 调试符号，节省 {1:F2} MB",
                    removed, bytes / 1048576.0));
            }
        }
    }
}
