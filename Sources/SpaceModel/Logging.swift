import os

/// Shared per-module logger. One category for the whole `SpaceModel` target — see PR discussion
/// in issue #25 for why this is per-module rather than per-file. `import os` only; this target
/// must stay unit-testable without a WindowServer, and `Logger` has no such dependency.
let log = Logger(subsystem: "app.spacewalker", category: "SpaceModel")
