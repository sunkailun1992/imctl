import Foundation

/// Everything `ReadinessEvaluator` needs, already reduced by the daemon to states and counts (B52).
/// Defaults describe a healthy core with every optional module unconfigured; the daemon sets every field.
public struct ReadinessFacts: Equatable, Sendable {
    public struct Watch: Equatable, Sendable {
        /// nil = the watcher has not finished a poll yet.
        public var lastPollAgeMs: Int64?
        /// The last poll read the conversation list.
        public var lastPollOK: Bool
        /// The watcher's availability verdict; nil before the first one.
        public var clientAvailable: Bool?
        public var conversationCount: Int
        /// The navigation rail was read at least once (B49).
        public var railRead: Bool
        /// Why the 通讯录 badge is not attributed; nil when it is.
        public var railProblem: String?
        /// B53: watcher polls that failed with the client unreachable or degraded in the last hour.
        public var errorsLastHour: Int
        public init(lastPollAgeMs: Int64? = nil, lastPollOK: Bool = false, clientAvailable: Bool? = nil,
                    conversationCount: Int = 0, railRead: Bool = false, railProblem: String? = nil, errorsLastHour: Int = 0) {
            self.lastPollAgeMs = lastPollAgeMs; self.lastPollOK = lastPollOK; self.clientAvailable = clientAvailable
            self.conversationCount = conversationCount; self.railRead = railRead; self.railProblem = railProblem
            self.errorsLastHour = errorsLastHour
        }
    }

    public struct Policy: Equatable, Sendable {
        public var readable: Bool
        public var titleCount: Int
        public var typesEnabled: Bool
        public var chatIdCount: Int
        public var externalUserIdCount: Int
        public var allowAll: Bool
        public var maxAddsPerHour: Int
        public var maxSearchesPerHour: Int
        /// `off` | `all` | `rules` | `remote`
        public var autoAccept: String
        public init(readable: Bool = true, titleCount: Int = 0, typesEnabled: Bool = false, chatIdCount: Int = 0,
                    externalUserIdCount: Int = 0, allowAll: Bool = false, maxAddsPerHour: Int = 20, maxSearchesPerHour: Int = 60,
                    autoAccept: String = "off") {
            self.readable = readable; self.titleCount = titleCount; self.typesEnabled = typesEnabled
            self.chatIdCount = chatIdCount; self.externalUserIdCount = externalUserIdCount; self.allowAll = allowAll
            self.maxAddsPerHour = maxAddsPerHour; self.maxSearchesPerHour = maxSearchesPerHour; self.autoAccept = autoAccept
        }
    }

    /// A local settings file: present on disk, parsed when present, and whether the running daemon loaded it.
    public struct Config: Equatable, Sendable {
        public var present: Bool
        public var valid: Bool
        /// The daemon reads this file only at start: false = absent then or edited since (a restart applies it); nil = not applicable.
        public var loaded: Bool?
        public init(present: Bool = false, valid: Bool = false, loaded: Bool? = nil) {
            self.present = present; self.valid = valid; self.loaded = loaded
        }
    }

    public struct Vision: Equatable, Sendable {
        public var config: Config
        public var cloudEnabled: Bool
        public var keyPresent: Bool
        public var provider: String
        public var model: String
        public var fullWindowEnabled: Bool
        /// Cloud vision was on when the daemon started (the B16 button-crop path is wired only then); nil = unknown.
        public var loadedAtStart: Bool?
        public init(config: Config = Config(), cloudEnabled: Bool = false, keyPresent: Bool = false, provider: String = "qwen",
                    model: String = "", fullWindowEnabled: Bool = false, loadedAtStart: Bool? = nil) {
            self.config = config; self.cloudEnabled = cloudEnabled; self.keyPresent = keyPresent
            self.provider = provider; self.model = model; self.fullWindowEnabled = fullWindowEnabled
            self.loadedAtStart = loadedAtStart
        }
    }

    public struct MQTT: Equatable, Sendable {
        public var config: Config
        /// The daemon was started with `--mqtt`.
        public var daemonMode: Bool
        public var connected: Bool
        /// B53: when a command last arrived over MQTT (since this daemon started); nil = none yet.
        public var lastCommandMs: Int64?
        public init(config: Config = Config(), daemonMode: Bool = false, connected: Bool = false, lastCommandMs: Int64? = nil) {
            self.config = config; self.daemonMode = daemonMode; self.connected = connected; self.lastCommandMs = lastCommandMs
        }
    }

    public enum SkillState: String, Codable, Equatable, Sendable { case missing, current, stale, unknown }

    public struct Agent: Equatable, Sendable {
        public var registered: Bool
        /// The registered command is the bundle's `imctl`.
        public var commandMatches: Bool
        public var skill: SkillState
        public init(registered: Bool = false, commandMatches: Bool = false, skill: SkillState = .missing) {
            self.registered = registered; self.commandMatches = commandMatches; self.skill = skill
        }
    }

    public struct Agents: Equatable, Sendable {
        public var claude: Agent
        public var codex: Agent
        /// The bundle's `imctl` exists, so the handshake can run.
        public var cliPresent: Bool
        public init(claude: Agent = Agent(), codex: Agent = Agent(), cliPresent: Bool = false) {
            self.claude = claude; self.codex = codex; self.cliPresent = cliPresent
        }
    }

    public var version: String
    public var launchedByLaunchd: Bool
    public var pauseReasons: [String]
    public var accessibilityTrusted: Bool
    public var screenRecordingGranted: Bool
    /// As `controller.permissions` reports it: granted | denied | pending | absent | unknown… | error…
    public var wecomData: String
    public var fullDiskAccess: Bool
    public var clientRunning: Bool
    public var clientVersion: String?
    public var watch: Watch
    public var policy: Policy
    public var vision: Vision
    public var mqtt: MQTT
    public var oss: Config
    public var agents: Agents
    public var wecomApi: Config

    /// B53: command outcomes in the last hour.
    public struct Health: Equatable, Sendable {
        public var failedLastHour: Int
        public var unknownLastHour: Int
        public init(failedLastHour: Int = 0, unknownLastHour: Int = 0) {
            self.failedLastHour = failedLastHour; self.unknownLastHour = unknownLastHour
        }
    }

    /// B53: CFBundleVersion the daemon read at its start, and the one on disk now; nil outside an app bundle.
    public var runningBuild: String?
    public var installedBuild: String?
    /// B53: commands accepted or running.
    public var runningCommands: Int
    public var health: Health

    public init(version: String, launchedByLaunchd: Bool = true, pauseReasons: [String] = [], accessibilityTrusted: Bool = true,
                screenRecordingGranted: Bool = true, wecomData: String = "granted", fullDiskAccess: Bool = true,
                clientRunning: Bool = true, clientVersion: String? = "5.0.11", watch: Watch = Watch(), policy: Policy = Policy(),
                vision: Vision = Vision(), mqtt: MQTT = MQTT(), oss: Config = Config(), agents: Agents = Agents(),
                wecomApi: Config = Config(), runningBuild: String? = nil, installedBuild: String? = nil, runningCommands: Int = 0,
                health: Health = Health()) {
        self.version = version; self.launchedByLaunchd = launchedByLaunchd; self.pauseReasons = pauseReasons
        self.accessibilityTrusted = accessibilityTrusted; self.screenRecordingGranted = screenRecordingGranted
        self.wecomData = wecomData; self.fullDiskAccess = fullDiskAccess; self.clientRunning = clientRunning
        self.clientVersion = clientVersion; self.watch = watch; self.policy = policy; self.vision = vision
        self.mqtt = mqtt; self.oss = oss; self.agents = agents; self.wecomApi = wecomApi
        self.runningBuild = runningBuild; self.installedBuild = installedBuild; self.runningCommands = runningCommands
        self.health = health
    }
}
