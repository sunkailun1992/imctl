import Foundation

/// Fix commands are written with `imctl` as the program (B52); a renderer swaps in the path the reader can run.
public enum ReadinessCommandText {
    public static func substitute(_ command: String, cli: String) -> String {
        guard cli != "imctl" else { return command }
        let program = cli.contains(" ") ? "\"\(cli)\"" : cli
        if command.hasPrefix("imctl ") { return program + String(command.dropFirst("imctl".count)) }
        return command.replacingOccurrences(of: "| imctl ", with: "| \(program) ")
    }
}
