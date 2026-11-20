"""Release state of one Hex.pm version, read anonymously (no key, no project code).

plan       prints UPLOAD_PACKAGE=true|false and UPLOAD_DOCS=true|false for $GITHUB_ENV:
           a version Hex does not serve uploads both; a served version must not be retired and
           its package bytes must equal the archive just built, or this refuses; served docs are
           kept, missing docs are uploaded.
read-back  the version is served, not retired, with package bytes equal to the archive and
           docs present. Hex.pm's CDN can lag an upload, so absence is re-read for a bounded time.

Docs are never compared byte for byte: a docs build is not byte-stable, and Hex accepts docs
only for a release it serves, so served docs belong to the package compared here
(infra baselabs/docs/ci.md, Releases).
"""
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ATTEMPTS = 10
PAUSE_SECONDS = 15


def fail(message):
    raise SystemExit(f'::error::{message}')


def fetch(url):
    """Body bytes, or None on 404. Any other answer fails closed."""
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        fail(f'Hex.pm read failed for {url} (HTTP {error.code})')
    except (OSError, http.client.HTTPException):
        fail(f'Hex.pm read failed for {url}')


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
            if found['served'] and found['package'] and found['docs']:
                print(f'{package} {version}: package bytes equal the archive; docs present')
                return
            if attempt + 1 < ATTEMPTS:
                time.sleep(PAUSE_SECONDS)
        fail(f'{package} {version}: read-back incomplete after {ATTEMPTS} reads: {found}')
    else:
        fail('usage: hex_release_state.py plan|read-back')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) == 2 else '')
