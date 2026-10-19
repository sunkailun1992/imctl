import Testing
@testable import WeComAdapter

@Suite("TimeLabel")
struct TimeLabelTests {
    @Test func matchesAbsoluteAndRelativeLabels() {
        for s in ["9:18", "20:01", "9/2", "8/28", "昨天", "星期三", "2分钟前", "刚刚", "1小时前", "3天前", "昨天 上午9:05"] {
            #expect(TimeLabel.matches(s), "\(s)")
        }
    }

    @Test func rejectsNamesAndPreviews() {
        for s in ["", "文件传输助手", "张三", "2 张图片", "前面的人", "hello"] {
            #expect(!TimeLabel.matches(s), "\(s)")
        }
    }
}
