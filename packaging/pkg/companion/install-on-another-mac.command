#!/bin/bash
# imctl 1.0.14 开发版：在第二台 Mac（Apple 芯片）上安装。双击本文件即可（终端会打开）。
set -e
cd "$(dirname "$0")"
echo "== 1/3 安装 imctl.app 到 /Applications（需要本机管理员密码）=="
xattr -d com.apple.quarantine imctl-1.0.14.pkg 2>/dev/null || true
sudo installer -pkg imctl-1.0.14.pkg -target /
echo "== 2/3 一次性初始化：装守护进程 + 请求辅助功能、屏幕录制与访问企微数据授权 =="
echo "   对话框出现时点「允许」；屏幕录制未授权时按提示在系统设置中允许 imctl.app。"
echo "   完全磁盘访问权限可在控制台「体检」页点按钮打开设置页添加。"
/Applications/imctl.app/Contents/MacOS/imctl setup || true
echo "== 3/3 检查 =="
/Applications/imctl.app/Contents/MacOS/imctl setup --check || true
/Applications/imctl.app/Contents/MacOS/imctl doctor || true
/Applications/imctl.app/Contents/MacOS/imctl call controller.diagnose 2>/dev/null | head -20 || echo "（守护进程还没起来或企微没开：打开企业微信后再跑 imctl setup --check）"
echo
echo "完成。打开 /Applications/imctl.app 看控制台；要接 Claude Code / Codex 再跑："
echo "  /Applications/imctl.app/Contents/MacOS/imctl mcp install --claude-code --codex --skills"
