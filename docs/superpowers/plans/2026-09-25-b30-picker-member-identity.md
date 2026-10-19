# B30 群成员选择身份复核计划

1. `GroupPickerSheet` 从已选表的 AXRow 读取每行唯一的 AXStaticText；空值或多个值不作姓名推断。
2. `pickMembers` 在焦点与前台状态稳定后重定位面板，校对搜索文本、唯一候选与已选名单，随后只投递一次既有的 pid 级回车。
3. 等待已选名单增加一人，要求新增姓名与请求值一致；其余情况抛验证错误，由 `group.create` / `group.addMembers` 的原有错误清理关闭面板。
4. 扩充合成夹具和负例，再运行聚焦测试、`swift build`、全量 `swift test`、`check-secrets.sh`、`git diff --check`。
5. 门报告区分 fake、源码和活体；本隔离任务不向真实会话发送、不创建群或加人。
