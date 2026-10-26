#!/usr/bin/env python3
"""Offline GitHub boundary tests for the shared progress snapshot."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('progress_sync', ROOT / 'progress/sync.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def connection(nodes, more=False, cursor=None):
    return {'nodes': nodes, 'totalCount': len(nodes),
            'pageInfo': {'hasNextPage': more, 'endCursor': cursor}}


def commits(start, count):
    return [{'commit': {'oid': f'{i:040x}', 'committedDate': f'2026-10-26T00:{i//60:02}:{i%60:02}Z'}}
            for i in range(start, start + count)]


class ProgressSyncTests(unittest.TestCase):
    def refresh(self, commit_count=1, file_count=1, bad=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'progress').mkdir()
            config = root / 'progress/progress.json'
            original = json.dumps({'tracked': {}})
            config.write_text(original)
            pr = {'id': 'PR_309', 'number': 309, 'title': 'Wubi', 'body': 'Closes #295',
                  'url': 'https://github.com/semantic-craft/owltype-macos/pull/309',
                  'state': 'OPEN', 'updatedAt': '2026-10-26T00:00:00Z', 'headRefOid': 'a'*40, 'baseRefOid': 'd'*40,
                  'mergedAt': None, 'labels': connection([]), 'comments': connection([])}
            for name, count in [('files', file_count), ('commits', commit_count)]:
                rows = [{'path': f'sources/{i}.swift'} for i in range(min(count, 100))] if name == 'files' else commits(0, min(count, 100))
                pr[name] = connection(rows, count > 100, '100' if count > 100 else str(count))
                pr[name]['totalCount'] = count
                if name == 'commits':
                    pr[name]['pageInfo']['hasPreviousPage'] = count > 100
            remote = {'defaultBranchRef': {'name': 'main', 'target': {'oid': 'b'*40}},
                      'pullRequests': connection([pr]), 'releases': connection([])}
            for n in [280, 294] + sum(sync.GROUPS.values(), []):
                remote['i'+str(n)] = {'number': n, 'title': 'Ticket', 'body': '', 'url': 'https://example.com',
                    'state': 'OPEN', 'stateReason': None, 'updatedAt': '2026-10-26T00:00:00Z',
                    'assignees': connection([]), 'labels': connection([]), 'comments': connection([]),
                    'parent': None, 'blockedBy': connection([]), 'subIssues': connection([])}
            if bad == 'other_connection':
                remote['i294']['comments']['pageInfo']['hasNextPage'] = True
            if bad == 'missing_cursor':
                pr['commits']['pageInfo']['endCursor'] = None
            calls = []
            def github(*args):
                query = args[-1]
                calls.append(query)
                if 'repository(' in query:
                    return json.dumps({'data': {'repository': remote}})
                node = {'id': pr['id'], 'headRefOid': 'c'*40 if bad == 'head_drift' else pr['headRefOid'],
                        'baseRefOid': 'e'*40 if bad == 'base_drift' else pr['baseRefOid']}
                name = 'commits' if 'commits(' in query else 'files' if 'files(' in query else None
                if bad == 'closing_head_drift' and name is None:
                    node['headRefOid'] = 'c'*40
                if bad == 'graphql_error':
                    return json.dumps({'errors': [{'message': 'retry later'}], 'data': None})
                if name:
                    count = commit_count if name == 'commits' else file_count
                    rows = commits(100, count-100) if name == 'commits' else [{'path': f'sources/{i}.swift'} for i in range(100,count)]
                    if bad == 'empty_page': rows = []
                    if bad == 'duplicate_page' and name == 'commits': rows = commits(0, count-100)
                    node[name] = connection(rows, False, '100' if bad == 'cursor_repeat' else str(count))
                    node[name]['totalCount'] = count
                return json.dumps({'data': {'node': node}})
            argv = ['sync.py', '--teslahub', str(root/'hub-source'), '--hub-out', str(root/'hub')]
            with patch.object(sync, 'ROOT', root), patch.object(sync, 'run', side_effect=github), patch.object(sync.subprocess, 'run'), patch.object(sys, 'argv', argv):
                if bad:
                    with self.assertRaises(RuntimeError): sync.main()
                    self.assertEqual(config.read_text(), original, 'rejected snapshots must preserve the page')
                    return
                sync.main()
            snapshot = json.loads((root/'hub/github-snapshot.json').read_text())
            result = snapshot['repositories']['owltype-macos']['open'][0]
            self.assertEqual(len(result['commits']), commit_count)
            self.assertEqual(len(result['files']), file_count)
            self.assertEqual([c['oid'] for c in result['commits']], [f'{i:040x}' for i in range(commit_count)])
            self.assertTrue(all('headRefOid' in q and 'baseRefOid' in q for q in calls[1:]))

    def test_more_than_100_commits_and_files_are_complete(self): self.refresh(141, 151)
    def test_single_page_is_unchanged(self): self.refresh()
    def test_base_drift_is_rejected(self): self.refresh(141, bad='base_drift')
    def test_head_drift_is_rejected(self): self.refresh(141, bad='head_drift')
    def test_empty_following_page_is_rejected(self): self.refresh(141, bad='empty_page')
    def test_repeated_cursor_is_rejected(self): self.refresh(141, bad='cursor_repeat')
    def test_missing_cursor_is_rejected(self): self.refresh(141, bad='missing_cursor')
    def test_duplicate_commits_are_rejected(self): self.refresh(141, bad='duplicate_page')
    def test_graphql_page_error_is_rejected(self): self.refresh(141, bad='graphql_error')
    def test_single_page_head_drift_is_rejected(self): self.refresh(bad='closing_head_drift')
    def test_other_connections_still_fail_closed(self): self.refresh(141, bad='other_connection')


if __name__ == '__main__': unittest.main()
