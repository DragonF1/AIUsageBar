import XCTest
@testable import AIUsageBar

// The three user-facing settings that let someone other than the owner point the app at their own
// setup: the Claude Code folder, the Antigravity OAuth client and token file, and how a closed
// session resumes. Every test uses a suite of its own, wiped when the test ends.

private func scratchSuite(_ testCase: XCTestCase) -> UserDefaults {
    let name = "AIUsageBarTests-\(UUID())"
    let suite = UserDefaults(suiteName: name)!
    testCase.addTeardownBlock { suite.removePersistentDomain(forName: name) }
    return suite
}

private func scratchDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

// MARK: - Claude Code folder

final class ClaudeFolderTests: XCTestCase {
    private func folder(_ typed: String) -> ClaudeFolder {
        ClaudeFolder(configured: typed, home: "/Users/test", supportDirectory: URL(fileURLWithPath: "/support"))
    }

    // Expected hashes: python3 -c "import hashlib;print(hashlib.sha256(b'<dir>').hexdigest()[:8])"

    func testDefaultFolderUsesThePlainKeychainService() {
        XCTAssertEqual(ClaudeFolder.keychainService(forConfigDir: nil), "Claude Code-credentials")
        for typed in ["", "   ", "~/.claude", "~/.claude/", "/Users/test/.claude", "/Users/test/.claude/"] {
            XCTAssertEqual(folder(typed).keychainServices, ["Claude Code-credentials"], "typed \(typed.debugDescription)")
            XCTAssertFalse(folder(typed).isCustom, "typed \(typed.debugDescription)")
        }
    }

    func testCustomFolderKeychainServiceIsSuffixedWithTheHashOfTheConfigDir() {
        XCTAssertEqual(ClaudeFolder.keychainService(forConfigDir: "/Users/test/.claude-work"),
                       "Claude Code-credentials-03abf0ee")
        XCTAssertEqual(folder("/Users/test/.claude-work").keychainServices, ["Claude Code-credentials-03abf0ee"])
    }

    /// The trailing slash is dropped for the first lookup; the path exactly as typed is the second try.
    func testTrailingSlashIsDroppedThenTheTypedPathIsTriedToo() {
        XCTAssertEqual(folder("/Users/test/.claude-work/").keychainServices,
                       ["Claude Code-credentials-03abf0ee", "Claude Code-credentials-8bd6f0f5"])
    }

    func testTildeIsExpandedThenTheTypedPathIsTriedToo() {
        XCTAssertEqual(folder("~/.claude-work").keychainServices,
                       ["Claude Code-credentials-03abf0ee", "Claude Code-credentials-250d1b22"])
        XCTAssertEqual(folder("  ~/.claude-work  ").keychainServices,
                       ["Claude Code-credentials-03abf0ee", "Claude Code-credentials-250d1b22"], "surrounding blanks are not part of the path")
    }

    /// A custom folder must never read the plain item: that one belongs to the default folder's account.
    func testCustomFolderNeverFallsBackToThePlainService() {
        for typed in ["/Users/test/.claude-work", "~/.claude-work", "/somewhere/else/"] {
            XCTAssertFalse(folder(typed).keychainServices.contains("Claude Code-credentials"), typed)
            XCTAssertTrue(folder(typed).isCustom, typed)
        }
    }

    func testTheHashIsOfTheNFCFormOfThePath() {
        // "é" as one scalar and as "e" + combining acute name the same folder.
        XCTAssertEqual(ClaudeFolder.keychainService(forConfigDir: "/Users/test/caf\u{E9}"), "Claude Code-credentials-ec5578f1")
        XCTAssertEqual(ClaudeFolder.keychainService(forConfigDir: "/Users/test/cafe\u{301}"), "Claude Code-credentials-ec5578f1")
    }

    func testDefaultFolderPaths() {
        let f = folder("")
        XCTAssertEqual(f.path, "/Users/test/.claude")
        XCTAssertEqual(f.credentialsFile.path, "/Users/test/.claude/.credentials.json")
        XCTAssertEqual(f.projectsRoot.path, "/Users/test/.claude/projects")
        XCTAssertEqual(f.sessionsRoot.path, "/Users/test/.claude/sessions")
        XCTAssertEqual(f.localBinary, "/Users/test/.claude/local/claude")
        XCTAssertEqual(f.tokenCacheURL.path, "/support/tokens.json")
        XCTAssertEqual(f.environment, [:])
        XCTAssertNil(f.claudeConfigDir)
    }

    func testCustomFolderPathsFeedEveryConsumer() {
        let f = folder("~/work/claude/")
        XCTAssertTrue(f.isCustom)
        XCTAssertEqual(f.path, "/Users/test/work/claude")
        XCTAssertEqual(f.credentialsFile.path, "/Users/test/work/claude/.credentials.json")
        XCTAssertEqual(f.projectsRoot.path, "/Users/test/work/claude/projects")
        XCTAssertEqual(f.sessionsRoot.path, "/Users/test/work/claude/sessions")
        XCTAssertEqual(f.localBinary, "/Users/test/work/claude/local/claude")
        XCTAssertEqual(f.tokenCacheURL.path, "/support/tokens-9ac1b282.json", "a custom folder keeps its own scan cache")
        XCTAssertEqual(f.environment, ["CLAUDE_CONFIG_DIR": "/Users/test/work/claude"])
        XCTAssertEqual(f.claudeConfigDir, "/Users/test/work/claude")
    }

    func testCurrentReadsTheSavedSetting() {
        let suite = scratchSuite(self)
        XCTAssertEqual(ClaudeFolder.current(defaults: suite).configured, "")
        XCTAssertFalse(ClaudeFolder.current(defaults: suite).isCustom)
        suite.set("/opt/claude-b", forKey: Preferences.Key.claudeFolder)
        XCTAssertEqual(ClaudeFolder.current(defaults: suite).path, "/opt/claude-b")
    }

    func testPreferencesStoreABlankFolderAsNoValue() {
        let original = Preferences.defaults
        let suite = scratchSuite(self)
        Preferences.defaults = suite
        defer { Preferences.defaults = original }
        XCTAssertEqual(Preferences.claudeFolder, "")
        Preferences.claudeFolder = "  /opt/claude-b  "
        XCTAssertEqual(Preferences.claudeFolder, "/opt/claude-b")
        Preferences.claudeFolder = "   "
        XCTAssertNil(suite.object(forKey: Preferences.Key.claudeFolder))
    }

    // MARK: consumers

    private func credentialJSON(token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"rt","expiresAt":9999999999999,"scopes":[]}}"#
    }

    /// Reads `<folder>/.credentials.json` for a custom folder, and reports it missing rather than
    /// reaching for the default folder's Keychain item.
    func testCredentialStoreFollowsTheFolder() throws {
        let dir = try scratchDirectory(self)
        try credentialJSON(token: "at-custom").write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        let custom = CredentialStore(folder: { ClaudeFolder(configured: dir.path) })
        let creds = try custom.read()
        XCTAssertEqual(creds.oauth.accessToken, "at-custom")
        XCTAssertEqual(creds.source, .file(dir.appendingPathComponent(".credentials.json")))

        let empty = try scratchDirectory(self)
        XCTAssertThrowsError(try CredentialStore(folder: { ClaudeFolder(configured: empty.path) }).read()) { error in
            guard case .notFound? = error as? CredentialError else { return XCTFail("expected notFound, got \(error)") }
        }
    }

    func testPinnedServiceAndFileStillWin() throws {
        let file = try tempCredentialFile(expiresAt: 9_999_999_999_999)
        let store = CredentialStore(service: "AIUsageBar-test-nonexistent-\(UUID())", fallbackFile: file,
                                    folder: { ClaudeFolder(configured: "/nowhere/else") })
        XCTAssertEqual(try store.read().source, .file(file))
    }

    /// The token store rebuilds its scanner and registry when the setting changes, with no restart.
    @MainActor
    func testTokenStoreFollowsTheFolderSetting() async throws {
        let first = try scratchDirectory(self)
        let second = try scratchDirectory(self)
        for (dir, session, id) in [(first, "one", "m1"), (second, "two", "m2")] {
            try writeTranscript(dir.appendingPathComponent("projects"), "p/\(session).jsonl",
                                assistantLine(id: id, in: 10, out: 10, session: session))
            try registryEntry(pid: getpid(), session: session).write(
                to: { () -> URL in
                    let sessions = dir.appendingPathComponent("sessions")
                    try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
                    return sessions.appendingPathComponent("\(getpid()).json")
                }(), atomically: true, encoding: .utf8)
        }
        let support = try scratchDirectory(self)
        var current = first.path
        let store = TokenStore()
        store.folder = { ClaudeFolder(configured: current, supportDirectory: support) }

        await store.refresh(reason: "test")
        XCTAssertEqual(store.records.map(\.sessionId), ["one"])
        XCTAssertEqual(store.live.map(\.sessionId), ["one"])

        current = second.path
        await store.refresh(reason: "test")
        XCTAssertEqual(store.records.map(\.sessionId), ["two"])
        XCTAssertEqual(store.live.map(\.sessionId), ["two"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder().tokenCacheURL.path),
                      "the second folder scans into a cache of its own")
    }

    func testProbeEnvironmentCarriesTheCustomFolderAndDropsAnInheritedOne() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/test", "CLAUDE_CONFIG_DIR": "/inherited"]
        XCTAssertEqual(ClaudeCLIProbe.environment(base: base, claudeConfigDir: "/Users/test/work")["CLAUDE_CONFIG_DIR"],
                       "/Users/test/work")
        XCTAssertNil(ClaudeCLIProbe.environment(base: base, claudeConfigDir: nil)["CLAUDE_CONFIG_DIR"],
                     "the app reads the default folder, so the probe must not be pointed elsewhere")
    }

    func testProbeCandidatesIncludeTheFoldersLocalInstall() {
        let plain = ClaudeCLIProbe.candidates(folder: folder(""))
        XCTAssertTrue(plain.contains("/Users/test/.claude/local/claude"))
        let custom = ClaudeCLIProbe.candidates(folder: folder("/opt/cc"))
        XCTAssertTrue(custom.contains("/opt/cc/local/claude"))
        XCTAssertTrue(custom.contains("/Users/test/.claude/local/claude"))
    }

    func testProbeRootsFollowTheFolder() {
        var probe = ClaudeCLIProbe(binary: nil)
        probe.folder = { ClaudeFolder(configured: "/opt/cc", home: "/Users/test") }
        XCTAssertEqual(probe.sessionsRoot.path, "/opt/cc/sessions")
        XCTAssertEqual(probe.projectsRoot.path, "/opt/cc/projects")
    }
}

// MARK: - Antigravity client and token file

/// An in-memory stand-in for the Keychain item.
private final class FakeKeychain: @unchecked Sendable {
    var data: Data?
    var failWrites = false
    var writes = 0

    func store(file: AppConfig.OAuthClient? = nil) -> AntigravityClientStore {
        AntigravityClientStore(
            read: { self.data },
            write: { data in
                if self.failWrites { throw AntigravityClientStore.Failure.keychain(-25293) }
                self.writes += 1
                self.data = data
            },
            delete: { self.data = nil },
            file: { file })
    }
}

final class AntigravityClientStoreTests: XCTestCase {
    private let fromFile = AppConfig.OAuthClient(clientId: "file-id", clientSecret: "file-secret")

    func testKeychainBeatsTheFileWhichBeatsNothing() throws {
        let keychain = FakeKeychain()
        var store = keychain.store(file: nil)
        XCTAssertNil(store.resolve())
        XCTAssertEqual(store.source, .none)

        store = keychain.store(file: fromFile)
        XCTAssertEqual(store.resolve()?.client, fromFile)
        XCTAssertEqual(store.source, .file)

        try store.save(clientId: "kc-id", clientSecret: "kc-secret")
        XCTAssertEqual(store.resolve()?.client, AppConfig.OAuthClient(clientId: "kc-id", clientSecret: "kc-secret"))
        XCTAssertEqual(store.source, .keychain)

        try store.clear()
        XCTAssertEqual(store.resolve()?.client, fromFile, "clearing the Keychain item uncovers the file again")
        XCTAssertEqual(store.source, .file)
    }

    func testSavedItemIsTheDocumentedJSON() throws {
        let keychain = FakeKeychain()
        try keychain.store().save(clientId: "id", clientSecret: "secret")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(keychain.data)) as? [String: String]
        XCTAssertEqual(json, ["client_id": "id", "client_secret": "secret"])
        XCTAssertEqual(AntigravityClientStore.service, "io.github.dragonf1.aiusagebar")
        XCTAssertEqual(AntigravityClientStore.account, "antigravity-oauth-client")
    }

    func testSaveTrimsAndRefusesEmptyFields() throws {
        let keychain = FakeKeychain()
        let store = keychain.store()
        XCTAssertThrowsError(try store.save(clientId: "  ", clientSecret: "s")) {
            XCTAssertEqual($0 as? AntigravityClientStore.Failure, .emptyField)
        }
        XCTAssertThrowsError(try store.save(clientId: "id", clientSecret: "\n")) {
            XCTAssertEqual($0 as? AntigravityClientStore.Failure, .emptyField)
        }
        XCTAssertEqual(keychain.writes, 0)
        try store.save(clientId: " id\n", clientSecret: " secret ")
        XCTAssertEqual(store.resolve()?.client, AppConfig.OAuthClient(clientId: "id", clientSecret: "secret"))
    }

    func testAKeychainWriteFailureSurfacesAndKeepsTheOldItem() throws {
        let keychain = FakeKeychain()
        let store = keychain.store()
        try store.save(clientId: "old", clientSecret: "old-secret")
        keychain.failWrites = true
        XCTAssertThrowsError(try store.save(clientId: "new", clientSecret: "new-secret")) {
            XCTAssertEqual($0 as? AntigravityClientStore.Failure, .keychain(-25293))
        }
        XCTAssertEqual(store.resolve()?.client.clientId, "old")
    }

    /// A damaged or half-empty item is skipped, not treated as the active client.
    func testUnusableKeychainItemFallsThroughToTheFile() {
        let keychain = FakeKeychain()
        let store = keychain.store(file: fromFile)
        for bad in ["not json", #"{"client_id":"id"}"#, #"{"client_id":"","client_secret":"s"}"#] {
            keychain.data = Data(bad.utf8)
            XCTAssertEqual(store.source, .file, bad)
        }
    }

    func testStatusWordsNameTheSource() {
        XCTAssertEqual(AntigravityClientStore.Source.keychain.label, "Keychain")
        XCTAssertEqual(AntigravityClientStore.Source.file.label, "antigravity-client.json")
        XCTAssertEqual(AntigravityClientStore.Source.none.label, "none")
    }

    /// The refresh asks the store when it needs the client, so a Save applies to the next refresh.
    func testAuthAsksTheClientProviderAtRefreshTime() async throws {
        let keychain = FakeKeychain()
        let store = keychain.store()
        var auth = AntigravityAuth()
        auth.clientProvider = { store.resolve()?.client }
        XCTAssertNil(auth.clientProvider())
        try store.save(clientId: "id", clientSecret: "secret")
        XCTAssertEqual(auth.clientProvider()?.clientId, "id")
        XCTAssertNil(AntigravityAuth(client: nil).clientProvider())
        XCTAssertEqual(AntigravityAuth(client: fromFile).clientProvider(), fromFile)
    }

    // MARK: token file

    func testTokenFileOverrideWinsAndBlankMeansDefault() {
        let suite = scratchSuite(self)
        XCTAssertEqual(AntigravityToken.effectiveFile(defaults: suite, home: "/Users/test").path,
                       "/Users/test/.gemini/jetski-standalone-oauth-token")
        suite.set("   ", forKey: Preferences.Key.antigravityTokenFile)
        XCTAssertEqual(AntigravityToken.effectiveFile(defaults: suite, home: "/Users/test").path,
                       "/Users/test/.gemini/jetski-standalone-oauth-token")
        suite.set("~/tokens/ag.json", forKey: Preferences.Key.antigravityTokenFile)
        XCTAssertEqual(AntigravityToken.effectiveFile(defaults: suite, home: "/Users/test").path, "/Users/test/tokens/ag.json")
        suite.set("/abs/token", forKey: Preferences.Key.antigravityTokenFile)
        XCTAssertEqual(AntigravityToken.effectiveFile(defaults: suite, home: "/Users/test").path, "/abs/token")
    }
}

// MARK: - Resume

final class ResumeSettingsTests: XCTestCase {
    private let named = AppConfig.Settings.Resume(launcher: "~/.claude-launcher/launch-claude.sh", envFile: "~/.claude-launcher/raycast.env")

    func testNothingSavedAndNoConfigIsTheTerminalWindow() {
        let settings = ResumeSettings.effective(defaults: scratchSuite(self), config: nil)
        XCTAssertEqual(settings, ResumeSettings(mode: .terminal, launcher: "", envFile: "", extraArguments: ""))
    }

    /// The owner's case: config.json names a launcher, Settings has never been touched.
    func testConfigJSONSuppliesTheLauncherAndPicksTheCustomMode() {
        let settings = ResumeSettings.effective(defaults: scratchSuite(self), config: named)
        XCTAssertEqual(settings.mode, .launcher)
        XCTAssertEqual(settings.launcher, "~/.claude-launcher/launch-claude.sh")
        XCTAssertEqual(settings.envFile, "~/.claude-launcher/raycast.env")
    }

    func testAConfigWithoutALauncherStaysOnTerminal() {
        XCTAssertEqual(ResumeSettings.effective(defaults: scratchSuite(self), config: .init(launcher: nil, envFile: "x.env")).mode, .terminal)
        XCTAssertEqual(ResumeSettings.effective(defaults: scratchSuite(self), config: .init(launcher: "", envFile: nil)).mode, .terminal)
    }

    func testSavedValuesWinOverConfigJSON() {
        let suite = scratchSuite(self)
        suite.set("terminal", forKey: Preferences.Key.resumeMode)
        suite.set("/mine/go.sh", forKey: Preferences.Key.resumeLauncher)
        suite.set("/mine/go.env", forKey: Preferences.Key.resumeEnvFile)
        suite.set("--effort xhigh", forKey: Preferences.Key.resumeExtraArguments)
        let settings = ResumeSettings.effective(defaults: suite, config: named)
        XCTAssertEqual(settings, ResumeSettings(mode: .terminal, launcher: "/mine/go.sh", envFile: "/mine/go.env", extraArguments: "--effort xhigh"))
    }

    /// Each value falls back on its own: saving one field does not hide the others in config.json.
    func testEachValueFallsBackIndependently() {
        let suite = scratchSuite(self)
        suite.set("/mine/go.sh", forKey: Preferences.Key.resumeLauncher)
        let settings = ResumeSettings.effective(defaults: suite, config: named)
        XCTAssertEqual(settings.mode, .launcher)
        XCTAssertEqual(settings.launcher, "/mine/go.sh")
        XCTAssertEqual(settings.envFile, "~/.claude-launcher/raycast.env")
    }

    /// A deliberately cleared field is a saved value: it does not resurrect config.json's.
    func testAClearedFieldStaysCleared() {
        let suite = scratchSuite(self)
        suite.set("", forKey: Preferences.Key.resumeEnvFile)
        XCTAssertEqual(ResumeSettings.effective(defaults: suite, config: named).envFile, "")
    }

    func testAnUnknownSavedModeFallsBackToTheDerivedOne() {
        let suite = scratchSuite(self)
        suite.set("tmux", forKey: Preferences.Key.resumeMode)
        XCTAssertEqual(ResumeSettings.effective(defaults: suite, config: named).mode, .launcher)
        XCTAssertEqual(ResumeSettings.effective(defaults: suite, config: nil).mode, .terminal)
    }

    func testModeTitles() {
        XCTAssertEqual(ResumeMode.allCases.map(\.title), ["Terminal window", "Custom launcher script"])
    }

    func testPreferencesSetNilRemovesTheSavedValue() {
        let original = Preferences.defaults
        let suite = scratchSuite(self)
        Preferences.defaults = suite
        defer { Preferences.defaults = original }
        Preferences.resumeMode = .launcher
        Preferences.resumeLauncher = "/x.sh"
        XCTAssertEqual(suite.string(forKey: Preferences.Key.resumeMode), "launcher")
        Preferences.resumeMode = nil
        Preferences.resumeLauncher = nil
        XCTAssertNil(suite.object(forKey: Preferences.Key.resumeMode))
        XCTAssertNil(suite.object(forKey: Preferences.Key.resumeLauncher))
    }
}

final class SessionLauncherSettingsTests: XCTestCase {
    private func launcher(_ resume: ResumeSettings, folder: String = "", existing: Set<String> = ["/work"]) -> SessionLauncher {
        var launcher = SessionLauncher(resume: resume, folder: ClaudeFolder(configured: folder, home: "/Users/test"))
        launcher.fileExists = { existing.contains($0) }
        return launcher
    }

    private func script(_ launcher: SessionLauncher) throws -> String {
        let command = try launcher.resumeCommand(sessionId: "abc-123", cwd: "/work")
        XCTAssertEqual(command.executable, "/usr/bin/osascript")
        return try XCTUnwrap(command.arguments.last)
    }

    private func terminal(_ extra: String = "") -> ResumeSettings {
        ResumeSettings(mode: .terminal, launcher: "", envFile: "", extraArguments: extra)
    }

    func testTerminalAppendsTheExtraArgumentsAfterResume() throws {
        XCTAssertEqual(try script(launcher(terminal("--effort xhigh"))),
                       "tell application \"Terminal\"\ndo script \"cd '/work' && claude --resume 'abc-123' --effort xhigh\"\nactivate\nend tell")
    }

    func testBlankExtraArgumentsAppendNothing() throws {
        let plain = try script(launcher(terminal()))
        XCTAssertEqual(plain, "tell application \"Terminal\"\ndo script \"cd '/work' && claude --resume 'abc-123'\"\nactivate\nend tell")
        XCTAssertEqual(try script(launcher(terminal("  \t "))), plain)
        XCTAssertEqual(try script(launcher(terminal("\n"))), plain)
    }

    func testExtraArgumentsAreTrimmedAndKeptOnOneLine() throws {
        XCTAssertTrue(try script(launcher(terminal("  --effort xhigh \n --verbose "))).contains("'abc-123' --effort xhigh   --verbose\""))
    }

    /// Raw shell text stays raw for the shell, but cannot break out of the AppleScript string.
    func testExtraArgumentsCannotBreakTheAppleScriptString() throws {
        let text = try script(launcher(terminal(#"--append-system-prompt "say \"hi\"" --x 'y'"#)))
        let line = try XCTUnwrap(text.components(separatedBy: "\n").dropFirst().first)
        XCTAssertEqual(line, #"do script "cd '/work' && claude --resume 'abc-123' --append-system-prompt \"say \\\"hi\\\"\" --x 'y'""#)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(try script(launcher(terminal(#"a\b"#))).contains(#"a\\b"#))
    }

    func testCustomFolderPrefixesTheEnvironmentVariableBeforeClaude() throws {
        XCTAssertEqual(try script(launcher(terminal("--effort high"), folder: "~/work/.claude/")),
                       "tell application \"Terminal\"\ndo script \"cd '/work' && CLAUDE_CONFIG_DIR='/Users/test/work/.claude' claude --resume 'abc-123' --effort high\"\nactivate\nend tell")
        XCTAssertFalse(try script(launcher(terminal(), folder: "~/.claude")).contains("CLAUDE_CONFIG_DIR"))
        XCTAssertFalse(try script(launcher(terminal(), folder: "")).contains("CLAUDE_CONFIG_DIR"))
    }

    func testFolderWithAQuoteIsShellQuotedInsideTheAppleScript() throws {
        XCTAssertTrue(try script(launcher(terminal(), folder: "/it's \"x\"")).contains(#"CLAUDE_CONFIG_DIR='/it'\\''s \"x\"' claude"#))
    }

    func testLauncherModeAddsTheFolderToTheEnvironmentOnlyWhenCustom() throws {
        let resume = ResumeSettings(mode: .launcher, launcher: "/l/go.sh", envFile: "/l/go.env", extraArguments: "--ignored")
        let existing: Set<String> = ["/work", "/l/go.sh"]
        let plain = try launcher(resume, existing: existing).resumeCommand(sessionId: "abc", cwd: "/work")
        XCTAssertEqual(plain.executable, "/bin/bash")
        XCTAssertEqual(plain.arguments, ["-c", "set -a; [ -f '/l/go.env' ] && . '/l/go.env'; set +a; exec '/l/go.sh'"])
        XCTAssertEqual(plain.environment, ["CLAUDE_RESUME": "abc", "CLAUDE_LAUNCH_DIR": "/work"])

        let custom = try launcher(resume, folder: "/opt/cc/", existing: existing).resumeCommand(sessionId: "abc", cwd: "/work")
        XCTAssertEqual(custom.arguments, plain.arguments, "extra arguments belong to the Terminal mode only")
        XCTAssertEqual(custom.environment, ["CLAUDE_RESUME": "abc", "CLAUDE_LAUNCH_DIR": "/work", "CLAUDE_CONFIG_DIR": "/opt/cc"])
    }

    func testLauncherModeExpandsTildesAndNeedsAnExistingScript() throws {
        let resume = ResumeSettings(mode: .launcher, launcher: "~/bin/go.sh", envFile: "", extraArguments: "")
        XCTAssertEqual(launcher(resume).launcher?.path, NSHomeDirectory() + "/bin/go.sh")
        XCTAssertThrowsError(try launcher(resume).resumeCommand(sessionId: "abc", cwd: "/work")) {
            XCTAssertEqual($0 as? SessionLauncher.Failure, .noLauncher(NSHomeDirectory() + "/bin/go.sh"))
        }
    }

    func testLauncherModeWithNoScriptSetReportsThatInsteadOfFallingBack() {
        let resume = ResumeSettings(mode: .launcher, launcher: "", envFile: "", extraArguments: "")
        XCTAssertThrowsError(try launcher(resume).resumeCommand(sessionId: "abc", cwd: "/work")) {
            XCTAssertEqual($0 as? SessionLauncher.Failure, .noLauncher(""))
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("Settings") == true)
        }
    }

    /// The public initialiser reads Settings first and config.json second, the way the sessions window does.
    func testInitialiserFollowsSettingsThenConfigJSON() {
        let suite = scratchSuite(self)
        let config = AppConfig.Settings.Resume(launcher: "/l/launch-claude.sh", envFile: "/l/launcher.env")
        var launcher = SessionLauncher(settings: config, defaults: suite)
        XCTAssertEqual(launcher.mode, .launcher)
        XCTAssertEqual(launcher.launcher?.path, "/l/launch-claude.sh")

        suite.set("terminal", forKey: Preferences.Key.resumeMode)
        suite.set("--effort xhigh", forKey: Preferences.Key.resumeExtraArguments)
        suite.set("/opt/cc", forKey: Preferences.Key.claudeFolder)
        launcher = SessionLauncher(settings: config, defaults: suite)
        XCTAssertEqual(launcher.mode, .terminal)
        XCTAssertEqual(launcher.extraArguments, "--effort xhigh")
        XCTAssertEqual(launcher.claudeConfigDir, "/opt/cc")
    }
}
