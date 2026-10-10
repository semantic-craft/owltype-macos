// Standalone fresh TIS diagnostics remain available before SwiftUI starts.

import Foundation

if CommandLine.arguments.dropFirst().contains("--tis-probe") {
    print(InstallerTISProbe.output())
    exit(0)
}

OwltypeInstallerApp.main()
