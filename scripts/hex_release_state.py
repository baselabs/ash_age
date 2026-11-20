"""Release state of one Hex.pm version, read anonymously (no key, no project code).

plan       prints UPLOAD_PACKAGE=true|false and UPLOAD_DOCS=true|false for $GITHUB_ENV:
           a version Hex does not serve uploads both; a served version must not be retired and
           its package bytes must equal the archive just built, or this refuses; served docs are
           kept, missing docs are uploaded.
read-back  the version is served, not retired, with package bytes equal to the archive, and its
           served docs are a readable archive with index.html and a release.json naming this
           package and version and a commit that is GITHUB_SHA or its ancestor; that commit is
           the published commit. Writes release-assets: the package, the served docs, their
           release.json and SHA256SUMS. Hex.pm's CDN can lag an upload, so absence is re-read
           for a bounded time.

Docs bytes are never compared: a docs build is not byte-stable. Docs render files the package
does not carry, so their release.json, not the package bytes, names the commit that built them
(infra baselabs/docs/ci.md, Releases).
"""
import hashlib
import http.client
import io
import json
import os
import re
import shutil
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

ATTEMPTS = 10
PAUSE_SECONDS = 15


def fail(message):
    raise SystemExit(f'::error::{message}')


def fetch(url, headers=None):
    """Body bytes, or None on 404. Any other answer fails closed."""
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        fail(f'read failed for {url} (HTTP {error.code})')
    except (OSError, http.client.HTTPException):
        fail(f'read failed for {url}')


def state(package, version, archive):
    quoted = urllib.parse.quote(package, safe=''), urllib.parse.quote(version, safe='')
    release = fetch('https://hex.pm/api/packages/{}/releases/{}'.format(*quoted))
    if release is None:
        return {'served': False}
    release = json.loads(release)
    if release.get('retirement'):
        fail(f'{package} {version} is retired on Hex.pm; publication refused')
    served = fetch('https://repo.hex.pm/tarballs/{}-{}.tar'.format(*quoted))
    if served is None:
        return {'served': True, 'package': None, 'docs': bool(release.get('has_docs'))}
    if served != archive:
        fail(f'{package} {version}: served package bytes differ from the archive just built; '
             'publication refused, nothing is replaced')
    return {'served': True, 'package': True, 'docs': bool(release.get('has_docs'))}


def provenance(docs, package, version):
    """The commit named by the served docs' release.json, on the dispatched commit's history."""
    try:
        with tarfile.open(fileobj=io.BytesIO(docs), mode='r:gz') as archive:
            names = {member.name.removeprefix('./'): member for member in archive.getmembers()}
            if 'index.html' not in names or not names['index.html'].isfile():
                fail(f'{package} {version}: served docs have no index.html')
            record = names.get('release.json')
            if record is None or not record.isfile():
                fail(f'{package} {version}: served docs have no release.json; their commit is unknown')
            data = json.loads(archive.extractfile(record).read())
    except (tarfile.TarError, OSError, EOFError, ValueError):
        fail(f'{package} {version}: served docs are not a readable archive with a release.json')
    if not isinstance(data, dict):
        fail(f'{package} {version}: served docs release.json is not an object')
    commit = data.get('commit')
    if data.get('package') != package or data.get('version') != version or not (
            isinstance(commit, str) and re.fullmatch(r'[0-9a-f]{40}', commit)):
        fail(f'{package} {version}: served docs release.json names another release')
    head = os.environ['GITHUB_SHA']
    if commit != head:
        compare = fetch(f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/compare/{commit}...{head}",
                        {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'})
        if compare is None or json.loads(compare).get('status') not in ('ahead', 'identical'):
            fail(f'{package} {version}: served docs were built from {commit}, '
                 'which is not on the default branch history of this run')
    return commit


def assets(package, version, archive, docs, commit):
    """release-assets: the package, the served docs, their release.json and SHA256SUMS."""
    directory = os.path.join(os.environ['RUNNER_TEMP'], 'release-assets')
    shutil.rmtree(directory, ignore_errors=True)
    os.makedirs(directory)
    files = {f'{package}-{version}.tar': archive, f'{package}-{version}-docs.tar.gz': docs}
    for name, data in files.items():
        with open(os.path.join(directory, name), 'wb') as handle:
            handle.write(data)
    with open(os.path.join(directory, 'release.json'), 'w', encoding='utf-8') as handle:
        json.dump({'package': package, 'version': version, 'commit': commit}, handle)
        handle.write('\n')
    with open(os.path.join(directory, 'SHA256SUMS'), 'w', encoding='utf-8') as handle:
        for name, data in files.items():
            handle.write(f'{hashlib.sha256(data).hexdigest()}  {name}\n')


def main(action):
    package, version = os.environ['PACKAGE'], os.environ['VERSION']
    with open(os.environ['PACKAGE_ARCHIVE'], 'rb') as handle:
        archive = handle.read()
    if action == 'plan':
        found = state(package, version, archive)
        if found['served'] and found['package'] is None:
            fail(f'{package} {version}: Hex.pm lists the release but serves no tarball yet; dispatch again shortly')
        upload_package = not found['served']
        upload_docs = not found['served'] or not found['docs']
        print(f'UPLOAD_PACKAGE={str(upload_package).lower()}')
        print(f'UPLOAD_DOCS={str(upload_docs).lower()}')
        print(f'{package} {version}: package {"upload" if upload_package else "served, bytes equal"}; '
              f'docs {"upload" if upload_docs else "served, kept"}', file=sys.stderr)
    elif action == 'read-back':
        for attempt in range(ATTEMPTS):
            found = state(package, version, archive)
            docs = None
            if found['served'] and found['package'] and found['docs']:
                docs = fetch('https://repo.hex.pm/docs/{}-{}.tar.gz'.format(
                    urllib.parse.quote(package, safe=''), urllib.parse.quote(version, safe='')))
            if docs is not None:
                commit = provenance(docs, package, version)
                assets(package, version, archive, docs, commit)
                print(f'{package} {version}: package bytes equal the archive; served docs from {commit}')
                return
            if attempt + 1 < ATTEMPTS:
                time.sleep(PAUSE_SECONDS)
        fail(f'{package} {version}: read-back incomplete after {ATTEMPTS} reads: {found}')
    else:
        fail('usage: hex_release_state.py plan|read-back')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) == 2 else '')
