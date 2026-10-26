#!/usr/bin/env python3
"""Exercise the production test-defaults selector in two real Foundation processes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class DefaultsIsolationTests(unittest.TestCase):
    def test_concurrent_test_hosts_keep_independent_preferences(self):
        source = (ROOT / 'sources/Main.swift').read_text()
        selector = 'enum OwlDefaults {' + source.split('enum OwlDefaults {', 1)[1].split('\n}', 1)[0] + '\n}'
        wrapper = '''
import Foundation
struct OwlApp {
  static let isRunningUnitTests = true
  static let isShowingSettingsForUITests = false
}
SELECTOR
let defaults = OwlDefaults.standard
defaults.set(Int(CommandLine.arguments[1])!, forKey: "pageSize")
defaults.synchronize()
print(OwlDefaults.testSuiteName)
fflush(stdout)
if CommandLine.arguments.count > 2 {
  _ = readLine()
  defaults.synchronize()
  print(defaults.integer(forKey: "pageSize"))
}
'''.replace('SELECTOR', selector)
        with tempfile.TemporaryDirectory(prefix='owl-defaults-isolation-') as temporary:
            root = Path(temporary)
            (root / 'main.swift').write_text(wrapper)
            subprocess.run(['swiftc', str(root / 'main.swift'), '-o', str(root / 'probe')], check=True,
                           capture_output=True, text=True, timeout=60)
            first = subprocess.Popen([str(root / 'probe'), '6', 'wait'], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                first_domain = first.stdout.readline().strip()
                second = subprocess.run([str(root / 'probe'), '8'], check=True, capture_output=True,
                                        text=True, timeout=15)
                second_domain = second.stdout.strip()
                first.stdin.write('read\n')
                first.stdin.flush()
                value = first.stdout.readline().strip()
                first.wait(timeout=15)
                self.assertNotEqual(first_domain, second_domain,
                                    f'Concurrent hosts shared preferences; first page size after peer write: {value}')
                self.assertEqual(value, '6', 'A peer writing page size 8 must not change this host')
                for domain in (first_domain, second_domain):
                    # Reading a nonexistent suite can itself create an empty CFPreferences plist.
                    # Check the file before invoking the observer, then verify no value survives.
                    plist = Path.home() / 'Library/Preferences' / f'{domain}.plist'
                    self.assertFalse(plist.exists(), 'Exited probes must not leave an empty preferences plist')
                    read = subprocess.run(['defaults', 'read', domain, 'pageSize'], capture_output=True)
                    self.assertNotEqual(read.returncode, 0, 'Exited probes must remove temporary preferences')
            finally:
                if first.poll() is None:
                    first.kill()
                first.communicate(timeout=15)
                # Clean both the old failing domain and process-specific successful domains.
                for domain in {first_domain, locals().get('second_domain', '')}:
                    if domain.startswith('im.owltype.inputmethod.Owltype.tests'):
                        subprocess.run(['defaults', 'delete', domain], capture_output=True)


if __name__ == '__main__':
    unittest.main()
