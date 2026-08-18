import os

/// Shared per-module logger. One category for the whole `CGSPrivate` target — see issue #25.
let log = Logger(subsystem: "app.spacewalker", category: "CGSPrivate")
