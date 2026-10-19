import Foundation
import Testing
@testable import imctl_console

@Suite("CLIRunner")
struct CLIRunnerTests {
    @Test func capturesOutputAndStatus() throws {
        let echo = CLIRunner(executable: URL(fileURLWithPath: "/bin/echo"))
        #expect(try echo.run(["hi", "there"]) == CLIRunner.Result(status: 0, output: "hi there\n"))
        let cat = CLIRunner(executable: URL(fileURLWithPath: "/bin/cat"))
        #expect(try cat.run([], stdin: "secret\n").output == "secret\n")
        #expect(try CLIRunner(executable: URL(fileURLWithPath: "/usr/bin/false")).run([]).status == 1)
    }

    @Test func siblingHonoursTheEnvironmentOverride() {
        setenv("IMCTL_CLI", "/tmp/fake-imctl", 1)
        defer { unsetenv("IMCTL_CLI") }
        #expect(CLIRunner.sibling().executable.path == "/tmp/fake-imctl")
    }
}
