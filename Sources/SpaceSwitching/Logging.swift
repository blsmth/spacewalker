import os

/// Shared per-module logger. One category for the whole `SpaceSwitching` target — see issue #25.
let log = Logger(subsystem: "app.spacewalker", category: "SpaceSwitching")
