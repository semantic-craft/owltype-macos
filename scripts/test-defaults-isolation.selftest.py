#!/usr/bin/env python3
"""Exercise the production test-defaults selector in two real Foundation processes."""
from pathlib import Path
import os
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class DefaultsIsolationTests(unittest.TestCase):
    def test_default_and_explicit_data_roots_never_touch_daily_storage(self):
        source = (ROOT / 'sources/Main.swift').read_text()
        storage = 'enum OwlTestStorage {' + source.split('enum OwlTestStorage {', 1)[1].split('\n}', 1)[0] + '\n}'
        private = 'enum OwlPrivateStorage {' + source.split('enum OwlPrivateStorage {', 1)[1].split('\n}', 1)[0] + '\n}'
        wrapper = r'''
import Foundation
struct OwlApp {
  static let isRunningUnitTests = CommandLine.arguments.contains("unit")
  static let isShowingSettingsForUITests = CommandLine.arguments.contains("ui")
  static let defaultUserDir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("daily")
}
PRIVATE
STORAGE
let data = OwlTestStorage.directory(override: "OWL_TEST_USER_DIR", child: "data", production: OwlApp.defaultUserDir)
let logs = OwlTestStorage.directory(override: "OWL_TEST_LOG_DIR", child: "logs",
  production: OwlApp.defaultUserDir.appendingPathComponent("logs"))
let paths = ["data": data.path, "logs": logs.path]
if OwlTestStorage.isEnabled {
  try OwlPrivateStorage.prepareDirectory(data)
  try Data("synthetic template".utf8).write(to: data.appendingPathComponent("owl_templates.json"))
  let bridge = data.appendingPathComponent("AgentBridge")
  try OwlPrivateStorage.prepareDirectory(bridge)
  try Data("synthetic call".utf8).write(to: bridge.appendingPathComponent("calls.json"))
}
print(String(decoding: try JSONSerialization.data(withJSONObject: paths), as: UTF8.self))
'''.replace('PRIVATE', private).replace('STORAGE', storage)
        with tempfile.TemporaryDirectory(prefix='owl-storage-isolation-') as temporary:
            root = Path(temporary)
            daily = root / 'daily'
            daily.mkdir()
            sentinel = daily / 'owl_templates.json'
            sentinel.write_text('daily template: must not change')
            (root / 'main.swift').write_text(wrapper)
            subprocess.run(['swiftc', str(root / 'main.swift'), '-o', str(root / 'probe')],
                           check=True, capture_output=True, timeout=60)
            env = {k: v for k, v in os.environ.items() if not k.startswith('OWL_TEST_')}
            def run(mode, overrides=None):
                return subprocess.run([str(root / 'probe'), str(root), mode],
                                      env=env | (overrides or {}), capture_output=True, text=True, timeout=15)
            self.assertEqual(json.loads(run('production').stdout)['data'], str(daily))
            roots = []
            for mode in ('unit', 'ui', 'ui'):
                result = run(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                paths = json.loads(result.stdout)
                roots.append(paths['data'])
                self.assertNotEqual(paths['data'], str(daily))
                self.assertEqual(Path(paths['data']).parent, Path(paths['logs']).parent)
                self.assertFalse(Path(paths['data']).parent.exists(), 'Owned root must be removed on exit')
            self.assertEqual(len(set(roots)), len(roots))
            explicit = root / 'fixture'
            result = run('production', {'OWL_TEST_USER_DIR': str(explicit)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['data'], str(explicit))
            self.assertTrue((explicit / 'AgentBridge/calls.json').exists(), 'Caller owns explicit fixtures')
            self.assertFalse(Path(json.loads(result.stdout)['logs']).parent.exists())
            alias = root / 'alias'
            alias.symlink_to(daily, target_is_directory=True)
            for key in ('OWL_TEST_USER_DIR', 'OWL_TEST_LOG_DIR'):
                for path in (daily, daily / 'child', root, alias, 'relative'):
                    result = run('ui', {key: str(path)})
                    self.assertEqual(result.returncode, 78, (key, path, result.stderr))
            self.assertEqual(sentinel.read_text(), 'daily template: must not change')
            self.assertEqual(list(daily.iterdir()), [sentinel])

    def test_concurrent_test_hosts_keep_independent_preferences(self):
        source = (ROOT / 'sources/Main.swift').read_text()
        selector = 'enum OwlDefaults {' + source.split('enum OwlDefaults {', 1)[1].split('\n}', 1)[0] + '\n}'
        wrapper = '''
import Foundation
enum OwlTestStorage { static let isEnabled = true }
enum OwlApp { static let isRunningUnitTests = true }
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
