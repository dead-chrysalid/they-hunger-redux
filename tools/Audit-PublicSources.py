"""Audit the complete reachable publication history without printing secret values.

Usage: python tools/Audit-PublicSources.py PATH [--ref master]
"""
import argparse
import json
import re
import subprocess
from pathlib import Path


def audit(repo, ref):
    objects = subprocess.check_output(
        ['git', '-C', str(repo), 'rev-list', '--objects', ref], text=True
    ).splitlines()
    forbidden = re.compile(r'(^|/)(models|sound|sprites)/|\.(mdl|bsp|wad|spr|wav|mp3|ogg|blend|pdn|kra|aup3)$', re.I)
    secrets = {
        'private-key': re.compile(rb'^-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----', re.M),
        'github-token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{70,255})\b'),
        'aws-access-key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    }
    issues = []
    batch = subprocess.Popen(['git', '-C', str(repo), 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    blobs = 0
    try:
        for item in objects:
            sha, _, name = item.partition(' ')
            batch.stdin.write((sha + '\n').encode())
            batch.stdin.flush()
            header = batch.stdout.readline().decode().split()
            if len(header) != 3:
                raise RuntimeError('Unexpected Git object response')
            size = int(header[2])
            data = batch.stdout.read(size)
            if len(data) != size or batch.stdout.read(1) != b'\n':
                raise RuntimeError('Incomplete Git object response')
            if header[1] != 'blob':
                continue
            blobs += 1
            if forbidden.search(name):
                issues.append({'type': 'game-resource', 'object': sha, 'path': name})
            if size >= 100 * 1024 * 1024:
                issues.append({'type': 'oversize-git-blob', 'object': sha, 'path': name})
            for kind, pattern in secrets.items():
                if pattern.search(data):
                    issues.append({'type': kind, 'object': sha, 'path': name})
    finally:
        batch.stdin.close()
        batch.wait()
        batch.stdout.close()
    return {'repository': repo.name, 'ref': ref, 'objects': len(objects), 'blobs': blobs, 'issues': issues, 'passed': not issues}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path)
    parser.add_argument('--ref', default='master')
    args = parser.parse_args()
    result = audit(args.repository.resolve(), args.ref)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
