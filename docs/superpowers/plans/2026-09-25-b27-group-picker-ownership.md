# B27 实现计划：选人面板归属

1. 在 `GroupPickerTests` 增加预存“添加群成员”与发起群聊面板的假件：两个命令都在快捷键、AX 写、取消前拒绝。
2. 在 `openGroupPicker` 记录无 sheet 的起点，⌘N 前再次检查；动作后用唯一 sheet、标题、空选择和同窗 PID/frame 作后验。`closeGroupPicker` 只取消同句柄的本命令面板并读回关闭。
3. `readContacts` 对可写滚动条要求唯一；多个时抛明确错误，不产生滚动写，不返回不完整结果。单条滚动后读回值与面板归属，结束时关闭面板，关闭失败不返回成功。
4. 跑 `GroupPickerTests`、`swift build`、全量 `swift test`、secret 检查和 `git diff --check`；门报告区分 fake 与待活体，不操作真实客户端。
