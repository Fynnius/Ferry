import os

/// Unified-log categories (Console.app, subsystem io.github.fynnius.Ferry). Messages carry
/// commands, exit codes and error kinds — never git output, commit messages or keys.
enum Log {
    static let git = Logger(subsystem: "io.github.fynnius.Ferry", category: "git")
    static let discovery = Logger(subsystem: "io.github.fynnius.Ferry", category: "discovery")
    static let app = Logger(subsystem: "io.github.fynnius.Ferry", category: "app")
}
