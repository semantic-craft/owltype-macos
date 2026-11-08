#!/usr/bin/env python3
"""Repository progress snapshots, deterministic HTML and optional publication proof."""
import argparse
import datetime
import hashlib
from html import escape
from html.parser import HTMLParser
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
CONFIG = 'progress/progress.json'
STATUSES = {'done', 'in_progress', 'blocked', 'planned', 'unverified'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n', encoding='utf-8')


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd or ROOT, text=True).strip()


def github(path, paginate=False):
    flags = ('--paginate', '--slurp') if paginate else ()
    return json.loads(run('gh', 'api', *flags, path))


def github_files(path, commit=False):
    pages = github(path + '?per_page=100', paginate=True)
    require(isinstance(pages, list) and pages, 'Incomplete file listing: ' + path)
    batches = [page['files'] if commit else page for page in pages]
    require(all(isinstance(batch, list) for batch in batches), 'Invalid file listing: ' + path)
    files = [f for batch in batches for f in batch]
    # Both endpoints cap listings at 3,000 files. A full final page cannot
    # establish completeness, even if gh has followed every available Link.
    require(len(files) < 3000 and len(batches[-1]) < 100,
            'Incomplete file listing: ' + path)
    return files


def outside_progress(files):
    for f in files:
        paths = [f['filename']]
        if 'previous_filename' in f:
            paths.append(f['previous_filename'])
        for path in paths:
            if not (isinstance(path, str) and path.startswith('progress/')
                    and all(part not in ('', '.', '..') for part in path.split('/'))):
                return str(path)
    return None


def progress_pull(base, number, head):
    path = f'{base}/pulls/{number}'
    try:
        before = github(path)
        files = github_files(path + '/files')
        detail = github(path)
        if (before['head']['sha'] != detail['head']['sha'] or detail['head']['sha'] != head
                or before['base']['sha'] != detail['base']['sha']
                or before['changed_files'] != detail['changed_files']):
            return False
        count = detail['changed_files']
        return (type(count) is int and count == len(files) and bool(files)
                and outside_progress(files) is None)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        return False


def progress_ancestry(base, snapshot, head):
    require(isinstance(snapshot, str) and re.fullmatch(r'[0-9a-f]{40}', snapshot),
            'facts.main must be a full 40-character lowercase hexadecimal commit SHA')
    if snapshot == head:
        return
    comparison = github(f'{base}/compare/{quote(snapshot, safe="")}...{quote(head, safe="")}')
    require(comparison['base_commit']['sha'] == snapshot,
            'Comparison base_commit.sha does not match facts.main')
    require(comparison['status'] != 'identical' or snapshot == head,
            'Comparison is identical but facts.main differs from live head')
    require(comparison['status'] in ('identical', 'ahead'),
            f'facts.main {snapshot} is not an ancestor of {head}: {comparison["status"]}')
    commits = comparison['commits']
    require(type(comparison['total_commits']) is int and comparison['total_commits'] == len(commits),
            'Incomplete comparison commit listing')
    require(bool(commits) or comparison['status'] == 'identical', 'Incomplete comparison commit listing')
    for commit in commits:
        sha = commit['sha']
        files = github_files(f'{base}/commits/{quote(sha, safe="")}', commit=True)
        outside = outside_progress(files)
        require(outside is None, f'Commit {sha} changes outside progress/: {outside}')


def live(c):
    base = 'repos/' + c['repository']
    def gh(path):
        return github(path)
    branch = gh(base)['default_branch']
    head = gh(f'{base}/commits/{quote(branch, safe="")}')['sha']
    pulls, issues = [], []
    for n in sorted(c['tracked']['pulls']):
        p = gh(f'{base}/pulls/{n}')
        pulls.append(dict(number=n, state=p['state'], merged=p['merged'], head=p['head']['sha'], base=p['base']['sha'], merge_commit=p['merge_commit_sha']))
    for n in sorted(c['tracked']['issues']):
        i = gh(f'{base}/issues/{n}')
        issues.append(dict(number=n, state=i['state'], reason=i.get('state_reason'), updated_at=i['updated_at']))
    pages = json.loads(run('gh', 'api', '--paginate', '--slurp', f'{base}/pulls?state=open&per_page=100'))
    return dict(main=head, default_branch=branch, pulls=pulls, issues=issues,
                open_pulls=sorted([dict(number=p['number'], head=p['head']['sha']) for page in pages for p in page
                                   if not progress_pull(base, p['number'], p['head']['sha'])], key=lambda p: p['number']),
                releases=[dict(id=r['id'], tag=r['tag_name'], draft=r['draft'], prerelease=r['prerelease'], published_at=r['published_at']) for r in gh(f'{base}/releases?per_page=10')])


def schema(c, snapshot=True):
    def typed(o, fields):
        require(isinstance(o, dict), 'Expected object')
        for k, t in fields.items():
            require(k in o and type(o[k]) in (t if isinstance(t, tuple) else (t,)), f'Invalid {k}')
    typed(c, dict(schema_version=int, repository=str, title=str, page=str, renderer=(str, type(None)), inputs=list, outputs=list, related_repositories=list, tracked=dict, observed_at=(str, type(None)), facts=dict, sections=list))
    require(c['schema_version'] == 1, 'schema_version must be 1')
    for repo in [c['repository']] + c['related_repositories']:
        require(isinstance(repo, str) and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo), 'Invalid repository')
    for key in ('inputs', 'outputs'):
        require(all(isinstance(p, str) for p in c[key]) and len(set(c[key])) == len(c[key]), f'Invalid {key}')
    require(c['page'] in c['outputs'], 'page must be in outputs')
    typed(c['tracked'], dict(pulls=list, issues=list))
    typed(c['facts'], dict(pulls=list, open_pulls=list, issues=list, releases=list))
    if 'default_branch' in c['facts']:
        typed(c['facts'], dict(default_branch=str))
        require(bool(c['facts']['default_branch']), 'Invalid default_branch')
    if snapshot:
        typed(c['facts'], dict(main=str))
        require(not c['observed_at'] or c['facts']['main'], 'Refresh default branch facts')
    fields = {'pulls': dict(number=int, state=str, merged=bool, head=str, base=str, merge_commit=(str, type(None))),
              'open_pulls': dict(number=int, head=str), 'issues': dict(number=int, state=str, reason=(str, type(None)), updated_at=str),
              'releases': dict(id=int, tag=str, draft=bool, prerelease=bool, published_at=(str, type(None)))}
    for key, spec in fields.items():
        for record in c['facts'][key]:
            typed(record, spec)
    for key in ('pulls', 'issues'):
        ns = c['tracked'][key]
        require(all(type(n) is int and n > 0 for n in ns) and len(set(ns)) == len(ns), 'Invalid tracked numbers')
        require(not snapshot or set(ns) <= {x['number'] for x in c['facts'][key]}, 'Tracked numbers missing facts')
    ids = set()
    def ident(o):
        require(re.fullmatch('[a-z0-9-]+', o['id']) and o['id'] not in ids, 'IDs must be globally unique and nonempty')
        ids.add(o['id'])
    for section in c['sections']:
        typed(section, dict(id=str, title=str, items=list)); ident(section)
        for item in section['items']:
            typed(item, dict(id=str, title=str, status=str, summary=str, evidence=list, next=str)); ident(item)
            require(item['status'] in STATUSES, 'Invalid status')
            for e in item['evidence']:
                typed(e, dict(kind=str, ref=(str, int), note=str))
                require(e['kind'] in {'pull', 'issue', 'release', 'commit', 'file', 'note'}, 'Invalid evidence kind')
                if e['kind'] in ('pull', 'issue'):
                    require(type(e['ref']) is int and e['ref'] in set(c['tracked'][e['kind'] + 's']) | {x['number'] for x in c['facts']['open_pulls']}, 'Evidence number is not tracked')
                elif e['kind'] == 'release':
                    require(e['ref'] in {r['tag'] for r in c['facts']['releases']}, 'Unknown release tag')
                else:
                    require(isinstance(e['ref'], str), 'Evidence ref must be text')


def safe_path(root, value, exists=False):
    require(isinstance(value, str) and value and '\\' not in value, f'Invalid relative path: {value}')
    p = PurePosixPath(value)
    require(not p.is_absolute() and '..' not in p.parts and not re.match(r'^[A-Za-z]:', value), f'Path outside repository: {value}')
    dest = root / value
    require(dest.resolve().is_relative_to(root.resolve()), f'Path outside repository: {value}')
    require(not exists or dest.is_file(), f'Missing input: {value}')
    return dest


def paths(c):
    for p in [c['page']] + c['outputs']:
        safe_path(ROOT, p)
    for p in c['inputs'] + ([c['renderer']] if c['renderer'] else []):
        safe_path(ROOT, p, True)


def normalized_css(text):
    # Comments are not resource references. Decode CSS escapes before URL matching.
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'\\([0-9a-fA-F]{1,6})\s?|\\([^\n\r])',
                  lambda m: chr(int(m[1], 16)) if m[1] else m[2], text)
    return text


def css_urls(text):
    text = normalized_css(text)
    pattern = r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)|@import\s*(?:"([^"]*)"|'([^']*)')"""
    return [next(v for v in m.groups() if v is not None).strip()
            for m in re.finditer(pattern, text, re.I)]


def srcset_urls(value):
    # A URL token may contain commas (notably data URLs); descriptors end at a comma.
    while value:
        value = value.lstrip(' ,\t\r\n\f')
        if not value:
            break
        match = re.match(r'[^\s]+', value)
        url = match[0]; value = value[match.end():]
        yield url.rstrip(',')
        if not url.endswith(','):
            value = value.partition(',')[2]


class HTML(HTMLParser):
    def __init__(self, text):
        super().__init__(); self.links = []; self.external = False; self.requires_inline = False; self.in_style = False; self.in_script = False; self.violations = []; self.inline_lines = []
        self.feed(text)

    def resource(self, value, line=None):
        value = (value or '').strip()
        self.links.append(value)
        if '\\' in value:
            self.violations.append((line or self.getpos()[0], 'Unsupported backslash URL'))
        if value.startswith('//') or urlsplit(value).scheme.lower() in {'http', 'https'}:
            self.external = True
            self.violations.append((line or self.getpos()[0], "External resource: " + value))

    def css(self, text):
        normalized = normalized_css(text)
        string_image_set = any(re.search(r"""(?:^|,)\s*['"]""", match[1])
                               for match in re.finditer(r'image-set\(((?:[^()]|\([^()]*\))*)\)', normalized, re.I))
        if string_image_set or re.search(r'\bsrc\s*\(', normalized, re.I):
            self.violations.append((self.getpos()[0], 'Unsupported CSS string image-set or src()'))
        if re.search(r'@import\b', normalized_css(text), re.I):
            self.requires_inline = True
            self.inline_lines.append(self.getpos()[0])
        for url in css_urls(text):
            self.resource(url, self.getpos()[0] + text.count('\n', 0, max(0, text.find(url))))

    def javascript(self, text):
        # The same dependency policy applies to inline and external scripts.
        # Tokenize strings before comments so https:// inside a specifier survives.
        token_pattern = r"""(?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?P<comment>/\*.*?\*/|//[^\r\n]*)|(?P<word>[$\w]+)|(?P<punct>[^\s])"""
        tokens = [m for m in re.finditer(token_pattern, text, re.S) if m.lastgroup != 'comment']
        for i, token in enumerate(tokens):
            if token.lastgroup != 'word' or token[0] not in {'import', 'export'}:
                continue
            tail = tokens[i + 1:]
            specifier = None
            if token[0] == 'import' and tail and tail[0].lastgroup == 'string':
                specifier = tail[0]
            else:
                for j, candidate in enumerate(tail):
                    if candidate[0] == ';':
                        break
                    if candidate[0] == 'from' and j + 1 < len(tail) and tail[j + 1].lastgroup == 'string':
                        specifier = tail[j + 1]
                        break
            if specifier is not None:
                self.resource(specifier[0][1:-1], self.getpos()[0] + text.count('\n', 0, specifier.start()))
        # Preserve line positions while removing comments and string contents.
        code = re.sub(token_pattern, lambda m: re.sub(r'[^\n]', ' ', m[0])
                      if m.lastgroup in {'string', 'comment'} else m[0], text, flags=re.S)
        pattern = r'fetch\s*\(|XMLHttpRequest|import\s*\(|WebSocket|EventSource|navigator\s*\.\s*sendBeacon|importScripts\s*\(|\b(?:Worker|SharedWorker)\s*\('
        for match in re.finditer(pattern, code, re.I):
            self.violations.append((self.getpos()[0] + code.count('\n', 0, match.start()), 'Runtime access: ' + match[0]))

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if len(a) != len(attrs):
            self.violations.append((self.getpos()[0], 'Unsupported duplicate HTML attribute'))
        for key, value in attrs:
            if key.startswith('on') or key == 'ping':
                self.violations.append((self.getpos()[0], 'Unsupported active attribute: ' + key))
        if tag == 'iframe' and a.get('srcdoc') is not None:
            child = HTML(a['srcdoc'])
            self.links.extend(child.links)
            self.violations.extend((self.getpos()[0] + n - 1, reason) for n, reason in child.violations)
            self.inline_lines.extend([self.getpos()[0]] * len(child.inline_lines))
        if tag == 'meta' and (a.get('http-equiv') or '').lower() == 'refresh':
            match = re.search(r""";\s*url\s*=\s*(.*?)\s*$""", a.get('content') or '', re.I)
            if match:
                self.resource(match[1].strip("\"'"))
            else:
                self.violations.append((self.getpos()[0], 'Unsupported refresh content'))
        if tag == "base" and "href" in a:
            self.violations.append((self.getpos()[0], "base[href] is not allowed"))
        if tag in {"image", "use", "script"}:
            for key in ("href", "xlink:href"):
                if key in a:
                    self.resource(a[key])
        self.links.extend(v.strip() for k, v in attrs if k in ('href', 'src') and v is not None)
        if tag == 'script' and 'src' in a:
            self.requires_inline = True
            self.inline_lines.append(self.getpos()[0])
        embedded = {'script', 'img', 'iframe', 'frame', 'embed', 'video', 'audio', 'source', 'track'}
        if tag in embedded or (tag == 'input' and (a.get('type') or '').lower() == 'image'):
            self.resource(a.get('src'))
        if tag in {'img', 'source'}:
            for url in srcset_urls(a.get('srcset') or ''):
                self.resource(url)
        if tag == 'object':
            self.resource(a.get('data'))
        if tag == 'video':
            self.resource(a.get('poster'))
        if tag == 'link':
            rel = set((a.get('rel') or '').lower().split())
            if not rel or rel - {'canonical', 'alternate', 'author', 'help', 'license', 'next', 'prev', 'search'}:
                if 'href' in a:
                    self.requires_inline = True
                    self.inline_lines.append(self.getpos()[0])
                self.resource(a.get('href'))
        self.css(a.get('style') or '')
        if tag == 'script':
            self.in_script = True
        if tag == 'style':
            self.in_style = True

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag == 'script':
            self.in_script = False
        if tag == 'style':
            self.in_style = False

    def handle_data(self, data):
        if self.in_script:
            self.javascript(data)
        if self.in_style:
            self.css(data)


def html_files(c):
    return sorted(set([c['page']] + [p for p in c['outputs'] if p.lower().endswith(('.html', '.htm'))]))


def relative_target(path, link):
    require('\\' not in unquote(link), f'Unsupported backslash URL: {link}')
    if not link or link.startswith('#') or urlsplit(link).scheme.lower() in {'http', 'https', 'mailto', 'data'} or link.startswith('//'):
        return None
    require(not urlsplit(link).scheme and not link.startswith('/'), f'Nonrelative URL: {link}')
    url_path = unquote(urlsplit(link).path)
    target = (ROOT / path).parent / url_path if url_path else ROOT / path
    # URL identity and relative bases follow the reference, not a symlink target.
    target = Path(os.path.normpath(target))
    require(target.resolve().is_relative_to(ROOT.resolve()), f'Link outside repository: {link}')
    if target.is_dir():
        target = target / 'index.html'
        require(target.resolve().is_relative_to(ROOT.resolve()), f'Link outside repository: {link}')
    require(target.is_file(), f'Missing relative link: {path}: {link}')
    return target.relative_to(ROOT).as_posix()


def resource_document(c, path):
    """Parse scan-capable resources; binary attachments remain graph leaves."""
    suffix = Path(path).suffix.lower()
    if path not in html_files(c) and suffix not in {'.html', '.htm', '.css', '.js', '.mjs', '.svg'}:
        return None, ''
    text = (ROOT / path).read_text(encoding='utf-8')
    if path in html_files(c) or suffix in {'.html', '.htm', '.svg'}:
        return HTML(text), text
    parsed = HTML('')
    if suffix == '.css':
        parsed.css(text)
    else:
        parsed.javascript(text)
    return parsed, text


def resources(c, roots, strict=True):
    todo = list(roots); seen = set()
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.add(path)
        parsed, text = resource_document(c, path)
        yield path, parsed, text
        if parsed is None:
            continue
        for link in parsed.links:
            try:
                target = relative_target(path, link)
            except ValueError:
                if strict:
                    raise
                continue  # relative-links owns missing/invalid local targets.
            if target:
                todo.append(target)


def links(c, recursive=False):
    return {p for p, _, _ in resources(c, [c['page']] if recursive else html_files(c))}


def contained(c):
    pattern = r'fetch\s*\(|XMLHttpRequest|import\s*\(|WebSocket|EventSource|navigator\s*\.\s*sendBeacon|importScripts\s*\(|/Users/|/home/|file://|C:\\\\?'
    inline = set(html_files(c))
    for p, parsed, text in resources(c, html_files(c), strict=False):
        if parsed is None:
            continue
        violations = list(parsed.violations)
        if p in inline:
            violations.extend((line, 'CSS and JavaScript must be inline') for line in parsed.inline_lines)
        match = re.search(pattern, text, re.I)
        if match:
            violations.append((text.count('\n', 0, match.start()) + 1, 'Runtime access: ' + match[0]))
        if violations:
            line, reason = min(violations)
            raise ValueError(f'{p}:{line}: {reason}')


def texts(c):
    for p in sorted(set([CONFIG] + c['inputs'] + c['outputs'] + ([c['renderer']] if c['renderer'] else []))):
        raw = (ROOT / p).read_bytes()
        if b'\0' in raw:
            continue
        try:
            yield p, raw.decode('utf-8')
        except UnicodeDecodeError:
            continue


def forbidden(c):
    pattern = r'chat[g]pt\.site|appgpr[j]_|\.openai/hosting\.json|遗留|已停用|retired|legacy|former URL'
    for p, text in texts(c):
        for n, line in enumerate(text.splitlines(), 1):
            require(not re.search(pattern, line, re.I), f'{p}:{n}: prohibited term')


def repo_links(c):
    allowed = {r.lower() for r in [c['repository']] + c['related_repositories']}
    for p, text in texts(c):
        for owner, name in re.findall(r'github\.com/([\w.-]+)/([\w.-]+)', text, re.I):
            require(f'{owner}/{name.removesuffix(".git")}'.lower() in allowed, f'{p}: unrelated repository {owner}/{name}')


def builtin(c):
    e = lambda x: escape(str(x), quote=True)
    base = 'https://github.com/' + c['repository']
    out = ['<!doctype html>', '<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
           '<title>' + e(c['title']) + '</title>', '<style>body{font:16px system-ui;max-width:960px;margin:3rem auto;padding:0 1rem;color:#202936;background:#f7f8fb}article,section{padding:1rem;margin:1rem 0;background:white;border-radius:12px}a{color:#1555ac}.badge{padding:.25rem .6rem;border-radius:20px;background:#e9edf5}small{color:#566}</style>',
           '<h1>' + e(c['title']) + '</h1>', '<p>Observed: ' + e(c['observed_at'] or 'unverified') + '</p>', '<p>Main: <code>' + e(((c['facts']['default_branch'] + ': ' if 'default_branch' in c['facts'] else '') + c['facts']['main']) if c['facts']['main'] else 'unverified') + '</code></p>']
    for section in c['sections']:
        out.append(f'<section id="{e(section["id"])}"><h2>{e(section["title"])}</h2>')
        for item in section['items']:
            out.append(f'<article id="{e(item["id"])}"><h3>{e(item["title"])}</h3><span class="badge">{e(item["status"])}</span><p>{e(item["summary"])}</p><ul>')
            for evidence in item['evidence']:
                kind, ref = evidence['kind'], evidence['ref']
                route = {'pull': 'pull', 'issue': 'issues', 'release': 'releases/tag', 'commit': 'commit', 'file': 'blob/' + quote(c['facts'].get('default_branch', 'HEAD'), safe='')}.get(kind)
                label = e(f'{kind} {ref}: {evidence["note"]}')
                out.append('<li>' + (f'<a href="{e(base + "/" + route + "/" + quote(str(ref), safe="/" if kind == "file" else ""))}">{label}</a>' if route else label) + '</li>')
            out.append('</ul><p>Next: ' + e(item['next']) + '</p></article>')
        out.append('</section>')
    out.append('<section><h2>Open pull requests</h2><ul>')
    for p in c['facts']['open_pulls']:
        out.append(f'<li><a href="{e(base)}/pull/{p["number"]}">#{p["number"]}</a> <code>{e(p["head"])}</code></li>')
    out.append('</ul><h2>Recent releases</h2><ul>')
    for r in c['facts']['releases']:
        out.append(f'<li><a href="{e(base)}/releases/tag/{e(quote(r["tag"], safe=""))}">{e(r["tag"])}</a> {e(r["published_at"])} (draft: {e(r["draft"])}, prerelease: {e(r["prerelease"])})</li>')
    return '\n'.join(out + ['</ul></section></html>']) + '\n'


def generate(c, dest):
    if c['renderer']:
        subprocess.run([sys.executable, '-B', str(ROOT / c['renderer']), '--out', str(dest)], cwd=ROOT, check=True)
    else:
        require(c['outputs'] == [c['page']], 'Built-in renderer produces page only')
        p = dest / c['page']; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(builtin(c), encoding='utf-8')
    actual = {p.relative_to(dest).as_posix() for p in dest.rglob('*') if p.is_file()}
    require(actual == set(c['outputs']), 'Renderer must produce exactly outputs')
    for p in c['outputs']:
        safe_path(dest, p, True)


def regenerate(c):
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp); generate(c, dest)
        for p in c['outputs']:
            require((ROOT / p).is_file() and (ROOT / p).read_bytes() == (dest / p).read_bytes(), f'Output differs: {p}')


def publication(c, proof):
    require(proof['adapter'] == 'artifact', 'Invalid adapter')
    require(isinstance(proof['source']['commit_sha'], str) and re.fullmatch('[0-9a-f]{40,64}', proof['source']['commit_sha']), 'Invalid source commit')
    pub, back = proof['publish'], proof['readback']
    require(isinstance(pub['url'], str) and pub['url'].startswith('https://') and type(pub['version']) is int and pub['version'] > 0, 'Invalid publication URL/version')
    require(isinstance(pub['version_id'], str) and pub['version_id'] and back['version_id'] == pub['version_id'], 'Version mismatch')
    require(isinstance(back['dir'], str) and Path(back['dir']).is_dir(), 'Missing readback directory')
    require(isinstance(proof['files'], dict) and set(proof['files']) == links(c, True), 'Proof file set differs from reachable files')
    for p, sha in proof['files'].items():
        raw = (ROOT / p).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == sha, f'Digest mismatch: {p}')
        readback = Path(back['dir']) / ('index.html' if p == c['page'] else p)
        require(readback.is_file(), f'Missing readback file: {p}')
        require(raw in readback.read_bytes() if p == c['page'] else raw == readback.read_bytes(), f'Readback differs: {p}')


def live_matches(c):
    current = live(c)
    if 'default_branch' not in c['facts']:
        current.pop('default_branch')
    progress_ancestry('repos/' + c['repository'], c['facts']['main'], current['main'])
    current['main'] = c['facts']['main']
    require(c['facts'] == current, 'GitHub snapshot differs')


def check(c, online=False, proof=None):
    errors = []
    def test(rule, fn):
        try:
            fn()
        except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as exc:
            errors.append(f'Progress check FAILED [{rule}]: {exc}')
    test('schema', lambda: schema(c))
    if not errors:
        test('paths-in-repo', lambda: paths(c))
    if not errors:
        for rule, fn in [('regenerate', regenerate), ('self-contained', contained), ('relative-links', links), ('legacy-terms', forbidden), ('repo-links', repo_links)]:
            test(rule, lambda fn=fn: fn(c))
        if proof is not None:
            test('publication', lambda: publication(c, json.loads(Path(proof).read_text(encoding='utf-8'))))
        if online:
            test('live-facts', lambda: live_matches(c))
            test('repo-visibility', lambda: require(json.loads(run('gh', 'repo', 'view', c['repository'], '--json', 'visibility'))['visibility'] in ('PUBLIC', 'PRIVATE'), 'Repository visibility must be PUBLIC or PRIVATE'))
    for error in errors:
        print(error, file=sys.stderr)
    return not errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['init', 'refresh', 'render', 'check', 'publish'])
    parser.add_argument('--repository'); parser.add_argument('--title')
    parser.add_argument('--live', action='store_true'); parser.add_argument('--publication')
    parser.add_argument('--adapter'); parser.add_argument('--receipt')
    a = parser.parse_args()
    if a.command == 'publish' and a.adapter != 'artifact':
        raise ValueError('Unknown publish adapter')
    if a.command == 'init':
        root = Path.cwd().resolve()
        require(a.repository and a.title, 'init requires --repository and --title')
        require(not (root / 'progress').exists(), 'progress already exists')
        c = dict(schema_version=1, repository=a.repository, title=a.title, page='progress/index.html', renderer=None, inputs=[], outputs=['progress/index.html'], related_repositories=[], tracked=dict(pulls=[], issues=[]), observed_at=None, facts=dict(main='', pulls=[], open_pulls=[], issues=[], releases=[]), sections=[])
        schema(c)
        write_json(root / CONFIG, c)
        shutil.copyfile(__file__, root / 'progress/progress.py')
        (root / c['page']).write_text(builtin(c), encoding='utf-8')
        print('Progress initialized'); return 0
    try:
        c = json.loads((ROOT / CONFIG).read_text(encoding='utf-8'))
    except (ValueError, OSError) as exc:
        print(f'Progress check FAILED [schema]: {exc}', file=sys.stderr); return 1
    if a.command in ('check', 'publish'):
        require(a.command != 'publish' or (a.publication and a.receipt), 'publish requires proof and external receipt')
        if not check(c, a.live or a.command == 'publish', a.publication):
            return 1
        if a.command == 'publish':
            proof = json.loads(Path(a.publication).read_text(encoding='utf-8'))
            require(run('git', 'rev-parse', 'HEAD') == proof['source']['commit_sha'] and not run('git', 'status', '--porcelain', '--untracked-files=all'), 'Source must be clean at proof commit')
            dest = Path(a.receipt).resolve()
            require(not dest.is_relative_to(ROOT), 'Receipt must be outside repository')
            write_json(dest, dict(adapter='artifact', source=proof['source'], publish=proof['publish'], files=proof['files']))
        print('Progress check PASS'); return 0
    schema(c, snapshot=a.command != 'refresh'); paths(c)
    if a.command == 'refresh':
        facts = live(c)
        if facts != c['facts']:
            c['facts'] = facts
            c['observed_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
            write_json(ROOT / CONFIG, c)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp); generate(c, dest)
            for p in c['outputs']:
                (ROOT / p).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(dest / p, ROOT / p)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
