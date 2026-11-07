/// What MacDiskSleuth knows about where disposable bytes live on a Mac.
///
/// Rules are matched against directory paths during a traversal of the scan
/// graph. `~` expands to the user's home *and* to `/Users/*`, so a whole-disk
/// scan covers every account. `**` spans any number of path components; a
/// component with `*`, `?` or `[` is a glob matched case-insensitively.
///
/// A rule can require project markers (`node_modules` only counts next to a
/// `package.json`), treat a folder's children as the interesting units
/// (`~/Library/Caches` → one entry per app), restrict itself to stale items
/// (`~/Downloads` older than 30 days), and join a group so related finds are
/// recommended as one action.
struct CleanupRule: Sendable {
    var category: CleanupCategory
    var title: String
    var safety: CleanupSafety
    var reason: String
    var action: String
    var patterns: [String]
    /// Rules sharing a group key merge into one recommendation.
    var group: String? = nil
    /// Globs; the matched folder's parent must contain one (project markers).
    var requiredSiblings: [String] = []
    /// Globs; the matched folder itself must contain one.
    var requiredChildren: [String] = []
    /// Recommend the folder's children individually rather than the folder.
    var itemsAreChildren = false
    /// With `itemsAreChildren`: keep only children nothing has touched for this long.
    var staleAfterDays: Int? = nil
}

/// Shared title and advice for a group of rules.
struct CleanupGroup: Sendable {
    var title: String
    var reason: String
    var action: String
}

enum CleanupKnowledge {
    // MARK: - Hard exclusions

    /// Never recommended and never descended into for generic finds: the OS,
    /// system databases, mail stores, photo libraries, cloud-synced folders
    /// (deleting there deletes everywhere), version control, backup sets.
    static let excludedPatterns: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/cores", "/dev", "/Network",
        "/private/var/db", "/private/var/vm", "/private/etc", "/private/var/root",
        "/Library/Apple", "/Library/Keychains", "/Library/Updates",
        "~/Library/Mail", "~/Library/Keychains", "~/Library/Photos",
        "~/Library/Messages", "~/Library/Mobile Documents", "~/Library/CloudStorage",
        "~/Library/Accounts", "~/Library/Biome", "~/Library/Daemon Containers",
        "/**/.git", "/**/.svn", "/**/.hg",
        "/**/*.photoslibrary", "/**/*.musiclibrary", "/**/*.tvlibrary", "/**/*.aplibrary",
        "/**/Backups.backupdb", "/**/*.sparsebundle",
        "/**/.Spotlight-V100", "/**/.fseventsd", "/**/.DocumentRevisions-V100",
        "/**/.TemporaryItems", "/**/.PKInstallSandboxManager*",
        "/**/*.app", "/**/*.framework", "/**/*.xcodeproj", "/**/*.xcworkspace",
    ]

    // MARK: - Groups

    static let groups: [String: CleanupGroup] = [
        "app-caches": CleanupGroup(
            title: "Application caches",
            reason: "Apps rebuild caches on demand; the only cost is a slower first launch.",
            action: "Quit the apps, then delete the folders (or use each app's own clear-cache setting)."),
        "developer-caches": CleanupGroup(
            title: "Xcode & developer caches",
            reason: "Build intermediates, previews and simulator caches that Xcode regenerates on the next build.",
            action: "rm -rf ~/Library/Developer/Xcode/DerivedData  (or Xcode → Settings → Locations → Derived Data → ⓧ)"),
        "device-support": CleanupGroup(
            title: "Device symbols & simulators",
            reason: "Debug symbols for every iOS/watchOS version you've plugged in, plus simulator runtimes and devices. Xcode re-downloads what it needs.",
            action: "Delete old versions in iOS DeviceSupport; run `xcrun simctl delete unavailable` and `xcrun simctl runtime delete <id>` for runtimes you no longer target."),
        "build-artifacts": CleanupGroup(
            title: "Build artifacts in your projects",
            reason: "Dependencies and build output that `npm install`, `swift build`, `cargo build`, `pip install` and friends recreate from the lockfile.",
            action: "Delete them in projects you aren't working on today; the next build brings them back."),
        "package-caches": CleanupGroup(
            title: "Package manager caches",
            reason: "Downloaded packages kept so reinstalls are fast. Anything you still use is fetched again on demand.",
            action: "Use each tool's own purge command (listed per item) — they know what is safe to drop."),
        "logs": CleanupGroup(
            title: "Log files",
            reason: "Diagnostic logs; useful only if you are chasing a current problem.",
            action: "Delete the folders' contents. System logs under /Library and /private need sudo."),
        "trash": CleanupGroup(
            title: "Trash",
            reason: "Already deleted — it just hasn't been emptied.",
            action: "Finder → Empty Trash. Trash folders on other volumes empty with it."),
        "containers": CleanupGroup(
            title: "Container disk images",
            reason: "Docker-style tools keep every image, container, volume and build cache inside one disk image. Deleting the file loses everything; pruning inside the tool reclaims what's unused.",
            action: "docker system prune -a --volumes   (then shrink the image: Docker Desktop → Settings → Resources)"),
        "virtual-machines": CleanupGroup(
            title: "Virtual machines",
            reason: "VM disk images are among the largest single items on a Mac. Only you know which machines are still needed.",
            action: "Delete machines you no longer use from the VM app so it also removes snapshots and metadata."),
        "ai-models": CleanupGroup(
            title: "Downloaded AI models",
            reason: "Local model weights are several gigabytes each and are re-downloadable from where they came.",
            action: "Remove models you aren't using (e.g. `ollama rm <model>`)."),
        "toolchains": CleanupGroup(
            title: "Old language toolchains",
            reason: "Version managers keep every runtime you ever installed. Versions no project uses are dead weight.",
            action: "List installed versions with the manager (nvm ls, pyenv versions, rustup toolchain list) and uninstall the old ones."),
        "installers": CleanupGroup(
            title: "Installers you've already used",
            reason: "Update packages and installers are disposable once applied; the originals can be downloaded again.",
            action: "Delete them."),
        "media-caches": CleanupGroup(
            title: "Video render & preview caches",
            reason: "Render files, transcodes and previews that Final Cut Pro, iMovie and Lightroom regenerate when needed.",
            action: "Final Cut Pro: File → Delete Generated Library Files. Lightroom: rebuilds previews on demand."),
        "device-backups": CleanupGroup(
            title: "iPhone & iPad backups",
            reason: "Local device backups. Keep the newest per device unless the device is also backed up to iCloud.",
            action: "Finder → select the device → Manage Backups… → delete old ones."),
        "applications": CleanupGroup(
            title: "Large applications",
            reason: "Apps you no longer use are the easiest gigabytes to give back. Sizes shown are real on-disk bytes after compression.",
            action: "Drag to the Trash, or use the app's own uninstaller when it has one."),
        "ci-workspaces": CleanupGroup(
            title: "CI agent workspaces",
            reason: "Checked-out sources and build output from past pipeline runs; the next run re-fetches what it needs.",
            action: "Delete workspaces of jobs that are not running."),
    ]

    // MARK: - Rules

    static let rules: [CleanupRule] = {
        var rules: [CleanupRule] = []

        // Trash — the surest win there is.
        rules.append(
            CleanupRule(
                category: .trash, title: "Trash", safety: .safe,
                reason: groups["trash"]!.reason, action: groups["trash"]!.action,
                patterns: ["~/.Trash", "/.Trashes", "/Volumes/*/.Trashes"],
                group: "trash"))

        // Application caches — one entry per app so the biggest offenders are named.
        rules.append(
            CleanupRule(
                category: .applicationCaches, title: "User caches", safety: .safe,
                reason: groups["app-caches"]!.reason, action: groups["app-caches"]!.action,
                patterns: ["~/Library/Caches", "~/.cache"],
                group: "app-caches", itemsAreChildren: true))
        rules.append(
            CleanupRule(
                category: .applicationCaches, title: "System-wide caches (sudo)", safety: .safe,
                reason: groups["app-caches"]!.reason, action: groups["app-caches"]!.action,
                patterns: ["/Library/Caches"],
                group: "app-caches", itemsAreChildren: true))
        rules.append(
            CleanupRule(
                category: .applicationCaches, title: "App cache", safety: .safe,
                reason: groups["app-caches"]!.reason, action: groups["app-caches"]!.action,
                patterns: Self.appCacheNames.flatMap { name in
                    [
                        "~/Library/Application Support/**/\(name)",
                        "~/Library/Containers/**/\(name)",
                        "~/Library/Group Containers/**/\(name)",
                    ]
                },
                group: "app-caches"))
        rules.append(
            CleanupRule(
                category: .applicationCaches, title: "Mail attachment downloads", safety: .safe,
                reason: "Attachments you opened from Mail; the originals stay in your mailbox.",
                action: groups["app-caches"]!.action,
                patterns: [
                    "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                    "~/Library/Mail Downloads",
                ],
                group: "app-caches"))
        rules.append(
            CleanupRule(
                category: .applicationCaches, title: "Adobe media cache", safety: .safe,
                reason: "Premiere / After Effects conform and peak files; regenerated when a project opens.",
                action: "Premiere Pro → Settings → Media Cache → Delete Unused",
                patterns: [
                    "~/Library/Application Support/Adobe/Common/Media Cache Files",
                    "~/Library/Application Support/Adobe/Common/Media Cache",
                    "~/Library/Application Support/Adobe/Common/Peak Files",
                ],
                group: "app-caches"))
        rules.append(
            CleanupRule(
                category: .applicationCaches, title: "Cloud sync cache", safety: .safe,
                reason: "Local staging cache of a sync client; the files themselves live in the synced folder and the cloud.",
                action: groups["app-caches"]!.action,
                patterns: [
                    "/**/.dropbox.cache",
                    "~/Library/Application Support/Google/DriveFS/**/content_cache",
                ],
                group: "app-caches"))

        // Xcode & developer caches (regenerated).
        rules.append(
            CleanupRule(
                category: .developerCaches, title: "Xcode DerivedData", safety: .safe,
                reason: groups["developer-caches"]!.reason, action: groups["developer-caches"]!.action,
                patterns: ["~/Library/Developer/Xcode/DerivedData"],
                group: "developer-caches", itemsAreChildren: true))
        rules.append(
            CleanupRule(
                category: .developerCaches, title: "Developer cache", safety: .safe,
                reason: groups["developer-caches"]!.reason, action: groups["developer-caches"]!.action,
                patterns: [
                    "~/Library/Developer/CoreSimulator/Caches",
                    "~/Library/Developer/Xcode/UserData/Previews",
                    "~/Library/Developer/Xcode/UserData/IB Support",
                    "~/Library/Developer/XCTestDevices",
                    "~/Library/Developer/Xcode/Products",
                    "~/Library/Developer/Xcode/iOS Device Logs",
                ],
                group: "developer-caches"))

        // Device support & simulators (re-downloadable).
        rules.append(
            CleanupRule(
                category: .deviceSupport, title: "Device symbols", safety: .likelySafe,
                reason: groups["device-support"]!.reason, action: groups["device-support"]!.action,
                patterns: [
                    "~/Library/Developer/Xcode/iOS DeviceSupport",
                    "~/Library/Developer/Xcode/watchOS DeviceSupport",
                    "~/Library/Developer/Xcode/tvOS DeviceSupport",
                    "~/Library/Developer/Xcode/visionOS DeviceSupport",
                ],
                group: "device-support", itemsAreChildren: true))
        rules.append(
            CleanupRule(
                category: .deviceSupport, title: "Simulators", safety: .likelySafe,
                reason: groups["device-support"]!.reason, action: groups["device-support"]!.action,
                patterns: [
                    "~/Library/Developer/CoreSimulator/Devices",
                    "~/Library/Developer/CoreSimulator/Volumes",
                    "~/Library/Developer/CoreSimulator/Profiles/Runtimes",
                    "~/Library/Developer/XCPGDevices",
                ],
                group: "device-support"))
        rules.append(
            CleanupRule(
                category: .deviceSupport, title: "Android system images & emulators", safety: .review,
                reason: "Emulator system images are 1–8 GB each; keep only the API levels you test.",
                action: "Android Studio → SDK Manager / Device Manager to remove images and virtual devices.",
                patterns: ["~/Library/Android/sdk/system-images", "~/.android/avd"]))

        // Xcode archives: needed to symbolicate shipped builds — review.
        rules.append(
            CleanupRule(
                category: .archives, title: "Xcode archives", safety: .review,
                reason: "Each archive holds a shipped build and its dSYMs. Keep the ones for versions still in users' hands; the rest can go.",
                action: "Xcode → Window → Organizer → Archives → delete old builds.",
                patterns: ["~/Library/Developer/Xcode/Archives"]))

        // Build artifacts inside projects (markers prove it's a project).
        func artifact(_ names: [String], siblings: [String] = [], children: [String] = [], title: String) -> CleanupRule {
            CleanupRule(
                category: .buildArtifacts, title: title, safety: .safe,
                reason: groups["build-artifacts"]!.reason, action: groups["build-artifacts"]!.action,
                patterns: names.map { "/**/\($0)" },
                group: "build-artifacts", requiredSiblings: siblings, requiredChildren: children)
        }
        rules.append(artifact(["node_modules"], siblings: ["package.json"], title: "node_modules"))
        rules.append(artifact([".build"], siblings: ["Package.swift"], title: "SwiftPM build"))
        rules.append(artifact(["target"], siblings: ["Cargo.toml", "pom.xml", "build.sbt"], title: "Rust/Maven/sbt target"))
        rules.append(artifact(["Pods"], siblings: ["Podfile"], title: "CocoaPods"))
        rules.append(artifact(["DerivedData"], siblings: ["*.xcodeproj", "*.xcworkspace"], title: "Project DerivedData"))
        rules.append(artifact([".venv", "venv", "env"], children: ["pyvenv.cfg"], title: "Python virtualenv"))
        rules.append(artifact(["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox"], title: "Python caches"))
        rules.append(artifact(["build"], siblings: ["build.gradle", "build.gradle.kts", "CMakeLists.txt", "pubspec.yaml", "setup.py", "meson.build"], title: "Build output"))
        rules.append(artifact([".gradle"], siblings: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], title: "Gradle project cache"))
        rules.append(artifact([".dart_tool"], siblings: ["pubspec.yaml"], title: "Dart tool cache"))
        rules.append(artifact(["bin", "obj"], siblings: ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"], title: ".NET build output"))
        rules.append(artifact([".terraform"], siblings: ["*.tf"], title: "Terraform providers"))
        rules.append(artifact(["dist", ".next", ".nuxt", ".svelte-kit", ".parcel-cache", ".turbo", ".angular", ".cache", "coverage"], siblings: ["package.json"], title: "JavaScript build output"))
        rules.append(artifact(["_build", "deps"], siblings: ["mix.exs"], title: "Elixir build"))
        rules.append(artifact([".stack-work"], siblings: ["stack.yaml"], title: "Haskell stack build"))
        rules.append(artifact(["dist-newstyle"], siblings: ["*.cabal"], title: "Cabal build"))
        rules.append(artifact(["cmake-build-*"], siblings: ["CMakeLists.txt"], title: "CMake build"))
        rules.append(artifact(["zig-cache", ".zig-cache", "zig-out"], siblings: ["build.zig"], title: "Zig build"))

        // Package manager caches (purge commands per item).
        func cache(_ patterns: [String], title: String, action: String, safety: CleanupSafety = .safe) -> CleanupRule {
            CleanupRule(
                category: .packageCaches, title: title, safety: safety,
                reason: groups["package-caches"]!.reason, action: action,
                patterns: patterns, group: "package-caches")
        }
        rules.append(cache(["~/.npm"], title: "npm cache", action: "npm cache clean --force"))
        rules.append(cache(["~/.yarn/cache", "~/.yarn/berry/cache", "~/Library/Caches/Yarn"], title: "Yarn cache", action: "yarn cache clean"))
        rules.append(cache(["~/.pnpm-store", "~/Library/pnpm"], title: "pnpm store", action: "pnpm store prune"))
        rules.append(cache(["~/.bun/install/cache"], title: "Bun cache", action: "bun pm cache rm"))
        rules.append(cache(["~/.gradle/caches", "~/.gradle/wrapper/dists"], title: "Gradle caches", action: "rm -rf ~/.gradle/caches  (Gradle re-downloads on the next build)"))
        rules.append(cache(["~/.m2/repository"], title: "Maven repository", action: "rm -rf ~/.m2/repository  (Maven re-downloads on the next build)"))
        rules.append(cache(["~/.ivy2/cache", "~/.sbt"], title: "Ivy/sbt caches", action: "Delete; sbt re-resolves dependencies."))
        rules.append(cache(["~/.cargo/registry", "~/.cargo/git"], title: "Cargo registry", action: "cargo cache -a  (cargo-cache) — or delete; re-downloaded on build"))
        rules.append(cache(["~/go/pkg/mod"], title: "Go module cache", action: "go clean -modcache"))
        rules.append(cache(["~/.cocoapods/repos"], title: "CocoaPods specs", action: "pod repo remove master  (CDN is used instead)"))
        rules.append(cache(["~/.nuget/packages"], title: "NuGet packages", action: "dotnet nuget locals all --clear"))
        rules.append(cache(["~/.conda/pkgs", "~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/opt/anaconda3/pkgs", "~/miniforge3/pkgs"], title: "conda package cache", action: "conda clean --all"))
        rules.append(cache(["~/.composer/cache"], title: "Composer cache", action: "composer clear-cache"))
        rules.append(cache(["~/.terraform.d/plugin-cache"], title: "Terraform plugin cache", action: "Delete; `terraform init` re-downloads providers."))
        rules.append(cache(["~/.kube/cache"], title: "kubectl discovery cache", action: "Delete; kubectl rebuilds it on the next call."))
        rules.append(cache(["~/.vagrant.d/boxes"], title: "Vagrant boxes", action: "vagrant box prune", safety: .likelySafe))
        rules.append(cache(["~/.docker/buildx", "~/.docker/desktop/cache"], title: "Docker build cache", action: "docker buildx prune"))

        // Toolchains kept by version managers.
        rules.append(
            CleanupRule(
                category: .toolchains, title: "Installed runtimes", safety: .review,
                reason: groups["toolchains"]!.reason, action: groups["toolchains"]!.action,
                patterns: [
                    "~/.nvm/versions/node", "~/.volta/tools/image/node", "~/.fnm/node-versions",
                    "~/.pyenv/versions", "~/.rbenv/versions", "~/.rustup/toolchains",
                    "~/.sdkman/candidates", "~/.asdf/installs", "~/.local/share/mise/installs",
                    "~/Library/Java/JavaVirtualMachines", "/Library/Java/JavaVirtualMachines",
                    "~/miniconda3/envs", "~/anaconda3/envs",
                ],
                group: "toolchains", itemsAreChildren: true))

        // Containers (prune inside the tool, never delete the image file).
        rules.append(
            CleanupRule(
                category: .containers, title: "Docker Desktop", safety: .review,
                reason: groups["containers"]!.reason, action: groups["containers"]!.action,
                patterns: ["~/Library/Containers/com.docker.docker/Data", "~/.docker/desktop/vms"],
                group: "containers"))
        rules.append(
            CleanupRule(
                category: .containers, title: "Container runtime", safety: .review,
                reason: groups["containers"]!.reason,
                action: "Prune from inside the tool (podman system prune -a, colima delete, minikube delete --all --purge, orb prune …).",
                patterns: [
                    "~/.colima", "~/.lima", "~/.minikube", "~/.rd", "~/.orbstack", "~/OrbStack",
                    "~/Library/Application Support/rancher-desktop",
                    "~/.local/share/containers", "~/.kind",
                ],
                group: "containers"))

        // Virtual machines.
        rules.append(
            CleanupRule(
                category: .virtualMachines, title: "Virtual machine", safety: .review,
                reason: groups["virtual-machines"]!.reason, action: groups["virtual-machines"]!.action,
                patterns: [
                    "~/VirtualBox VMs", "~/Parallels", "~/Virtual Machines.localized",
                    "~/Documents/Virtual Machines.localized", "~/Documents/Parallels",
                    "~/Library/Containers/com.utmapp.UTM/Data/Documents",
                    "/**/*.pvm", "/**/*.vmwarevm", "/**/*.utm", "/**/*.vbox",
                ],
                group: "virtual-machines"))

        // AI models.
        rules.append(
            CleanupRule(
                category: .aiModels, title: "AI models", safety: .review,
                reason: groups["ai-models"]!.reason, action: groups["ai-models"]!.action,
                patterns: ["~/.ollama/models", "~/.lmstudio/models", "~/Library/Application Support/LM Studio/models"],
                group: "ai-models"))

        // Logs.
        rules.append(
            CleanupRule(
                category: .logs, title: "Logs", safety: .likelySafe,
                reason: groups["logs"]!.reason, action: groups["logs"]!.action,
                patterns: ["~/Library/Logs", "/Library/Logs", "/private/var/log"],
                group: "logs", itemsAreChildren: true))
        rules.append(
            CleanupRule(
                category: .logs, title: "App logs", safety: .likelySafe,
                reason: groups["logs"]!.reason, action: groups["logs"]!.action,
                patterns: ["~/Library/Containers/**/Logs", "~/Library/Group Containers/**/Logs"],
                group: "logs"))

        // Installers already applied.
        rules.append(
            CleanupRule(
                category: .installers, title: "iOS update packages", safety: .safe,
                reason: "Firmware images Finder downloaded to update a device; useless once the device is updated.",
                action: groups["installers"]!.action,
                patterns: [
                    "~/Library/iTunes/iPhone Software Updates", "~/Library/iTunes/iPad Software Updates",
                    "~/Library/iTunes/iPod Software Updates", "~/Library/iTunes/Apple Watch Software Updates",
                ],
                group: "installers"))
        rules.append(
            CleanupRule(
                category: .installers, title: "macOS installer", safety: .likelySafe,
                reason: "A full macOS installer is 12+ GB and can be downloaded again from the App Store.",
                action: groups["installers"]!.action,
                patterns: ["/Applications/Install macOS*.app", "~/Applications/Install macOS*.app"],
                group: "installers"))

        // Downloads nobody has touched in a month.
        rules.append(
            CleanupRule(
                category: .downloads, title: "Old downloads", safety: .likelySafe,
                reason: "Items in Downloads untouched for a month are usually installers already run, archives already extracted, or files already filed elsewhere.",
                action: "Review the list, then delete. Installers (.dmg/.pkg/.zip) are the safest.",
                patterns: ["~/Downloads"],
                itemsAreChildren: true, staleAfterDays: 30))

        // Device backups.
        rules.append(
            CleanupRule(
                category: .deviceBackups, title: "Device backups", safety: .review,
                reason: groups["device-backups"]!.reason, action: groups["device-backups"]!.action,
                patterns: ["~/Library/Application Support/MobileSync/Backup"],
                group: "device-backups", itemsAreChildren: true))

        // Applications (review; honest compressed sizes).
        rules.append(
            CleanupRule(
                category: .applications, title: "Application", safety: .review,
                reason: groups["applications"]!.reason, action: groups["applications"]!.action,
                patterns: ["/Applications/*.app", "~/Applications/*.app", "/Applications/*/*.app"],
                group: "applications"))
        rules.append(
            CleanupRule(
                category: .applications, title: "Steam games", safety: .review,
                reason: "Installed games; Steam re-downloads anything you reinstall.",
                action: "Steam → Library → right-click a game → Manage → Uninstall.",
                patterns: ["~/Library/Application Support/Steam/steamapps/common"],
                group: "applications", itemsAreChildren: true))

        // Media that is re-downloadable.
        rules.append(
            CleanupRule(
                category: .media, title: "Downloaded TV & movies", safety: .likelySafe,
                reason: "Purchases and rentals downloaded by the TV app; they stream or re-download from your library.",
                action: "TV app → Library → Downloaded → remove downloads.",
                patterns: ["~/Movies/TV/Media.localized"]))
        rules.append(
            CleanupRule(
                category: .media, title: "Apple Music downloads", safety: .likelySafe,
                reason: "Streaming tracks downloaded for offline listening; they stay in your library and re-download on demand.",
                action: "Music → Library → Downloaded → Remove Download.",
                patterns: ["~/Music/Music/Media.localized/Apple Music"]))

        // Media render caches (regenerated).
        rules.append(
            CleanupRule(
                category: .mediaCaches, title: "Render files", safety: .likelySafe,
                reason: groups["media-caches"]!.reason, action: groups["media-caches"]!.action,
                patterns: [
                    "/**/*.fcpbundle/**/Render Files", "/**/*.fcpbundle/**/Transcoded Media",
                    "/**/*.fcpbundle/**/Analysis Files", "/**/*.fcpbundle/**/Peak Files",
                    "/**/*.imovielibrary/**/Render Files", "/**/*.lrdata",
                ],
                group: "media-caches"))

        // CI agents.
        rules.append(
            CleanupRule(
                category: .ciWorkspaces, title: "CI workspace", safety: .likelySafe,
                reason: groups["ci-workspaces"]!.reason, action: groups["ci-workspaces"]!.action,
                patterns: ["~/.jenkins/workspace", "/**/_work"],
                group: "ci-workspaces", requiredSiblings: [".agent", "jobs", "config.xml"]))

        // System-managed temp: never by hand, but worth knowing about.
        rules.append(
            CleanupRule(
                category: .systemManaged, title: "System temporary files (/private/var/folders)", safety: .review,
                reason: "Per-user caches and temporary files macOS manages itself. Deleting by hand while apps run can corrupt their state.",
                action: "Restart your Mac; macOS clears what is stale. Running out of space here usually points at one app — look inside.",
                patterns: ["/private/var/folders"]))

        return rules
    }()

    /// Cache-like folder names that apps keep under Application Support and
    /// sandbox containers (Electron apps, browsers, editors).
    static let appCacheNames: [String] = [
        "Cache", "Caches", "Code Cache", "GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache",
        "ShaderCache", "GrShaderCache", "CachedData", "CachedExtensionVSIXs", "CachedProfilesData",
        "PersistentCache", "CacheStorage", "Service Worker", "component_crx_cache",
        "optimization_guide_model_store",
    ]

    /// Per-child hints for `itemsAreChildren` folders, matched by lowercase name prefix.
    static let childHints: [(prefix: String, hint: String)] = [
        ("homebrew", "brew cleanup --prune=all"),
        ("pip", "pip cache purge"),
        ("uv", "uv cache clean"),
        ("pypoetry", "poetry cache clear --all ."),
        ("yarn", "yarn cache clean"),
        ("go-build", "go clean -cache"),
        ("cocoapods", "pod cache clean --all"),
        ("com.apple.dt.xcode", "Xcode rebuilds it"),
        ("org.swift.swiftpm", "SwiftPM re-fetches packages"),
        ("org.carthage", "Carthage re-builds"),
        ("google", "Chrome → Clear browsing data → Cached images and files"),
        ("com.apple.safari", "Safari → Settings → Privacy → Manage Website Data"),
        ("firefox", "Firefox → Settings → Privacy → Clear Data"),
        ("com.apple.bird", "iCloud Drive cache — macOS evicts it under pressure"),
        ("cloudkit", "iCloud cache — evicted automatically"),
        ("jetbrains", "IDE indexes; rebuilt when the project reopens"),
        ("ms-playwright", "npx playwright install re-downloads browsers"),
        ("puppeteer", "re-downloaded on next install"),
        ("helm", "helm repo update re-fetches"),
        ("huggingface", "Hugging Face models; re-downloaded on use"),
        ("com.spotify.client", "Spotify re-caches as you listen"),
        ("typescript", "TypeScript server cache"),
        ("node-gyp", "node-gyp headers; re-downloaded"),
        ("electron", "Electron binaries; re-downloaded"),
        ("pre-commit", "pre-commit clean"),
        ("com.microsoft.vscode", "VS Code rebuilds it"),
        ("com.docker.docker", "Docker Desktop cache"),
    ]

    static func hint(forChildNamed name: String) -> String? {
        let lowered = name.lowercased()
        return childHints.first(where: { lowered.hasPrefix($0.prefix) })?.hint
    }

    // MARK: - Generic large files

    enum FileClass {
        case installer, diskImage, video, audio, image, dump, log, other
    }

    static func classify(extension ext: String?) -> FileClass {
        guard let ext else { return .other }
        switch ext {
        case "dmg", "pkg", "iso", "xip", "ipsw", "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar",
            "msi", "exe", "deb", "rpm", "appimage", "mpkg":
            return .installer
        case "vmdk", "vdi", "qcow2", "vhd", "vhdx", "hdd", "img", "raw", "sparseimage", "ova", "qcow":
            return .diskImage
        case "mov", "mp4", "m4v", "mkv", "avi", "mts", "m2ts", "mxf", "braw", "r3d", "webm", "wmv", "flv", "prores":
            return .video
        case "wav", "aif", "aiff", "flac", "alac", "m4a", "mp3", "caf", "ogg":
            return .audio
        case "psd", "psb", "tif", "tiff", "cr2", "cr3", "nef", "arw", "dng", "heic", "raf", "orf", "exr":
            return .image
        case "sql", "dump", "bak", "sqlite", "sqlite3", "db", "bson", "parquet", "csv", "jsonl":
            return .dump
        case "log", "crash", "ips", "diag", "spin":
            return .log
        default:
            return .other
        }
    }
}
