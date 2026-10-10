"""Create source publication copies; never rewrite the development repositories.

Install git-filter-repo==2.47.0 in a separate environment first. Run from the
project root with Python. Exports are placed in the ignored project work path.
"""
import json
import argparse
import subprocess
import sys
from pathlib import Path


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--development-root', type=Path, default=root)
    args = parser.parse_args()
    development_root = args.development_root.resolve()
    project = json.loads((development_root / 'project.json').read_text(encoding='utf-8-sig'))
    manifest = json.loads((root / 'sources.json').read_text(encoding='utf-8-sig'))
    destination = (root / project['paths']['work'] / 'publication-export').resolve()
    if not destination.is_relative_to(root):
        raise RuntimeError('Publication directory must remain inside this project')
    if destination.exists():
        raise RuntimeError('Export directory already exists; preserve it and choose a fresh project checkout')
    # Imports are resolved before clones to avoid leaving half-prepared exports.
    import git_filter_repo
    destination.mkdir(parents=True)
    for component in ('mainui', 'engine', 'sdk', 'rtgl1'):
        source = (development_root / project['paths']['repositories'][component]).resolve()
        target = destination / component
        branch = project['branches'][component]
        if run('git', '-C', str(source), 'status', '--porcelain', '--untracked-files=normal'):
            raise RuntimeError(f'Development {component} checkout must be clean')
        revision = run('git', '-C', str(source), 'rev-parse', branch)
        run('git', 'clone', '--no-local', '--single-branch', '--no-tags', '--branch', branch, str(source), str(target))
        if component == 'sdk':
            if not (target / '.git').is_dir() or (target / '.git').resolve() == (source / '.git').resolve():
                raise RuntimeError('Filtering requires an isolated clone with independent Git metadata')
            options = ['--force', '--invert-paths', '--prune-empty', 'never', '--prune-degenerate', 'never', '--preserve-commit-hashes', '--preserve-commit-encoding']
            for path in ('models/', 'sound/', 'sprites/', 'android/pak/', 'android/res/drawable/'):
                options += ['--path', path]
            run(sys.executable, git_filter_repo.__file__, *options, cwd=target)
        # Only an explicit master push is permitted; never use --mirror.
        remotes = run('git', '-C', str(target), 'remote').splitlines()
        if 'origin' in remotes:
            run('git', '-C', str(target), 'remote', 'remove', 'origin')
        run('git', '-C', str(target), 'remote', 'add', 'origin', manifest['components'][component]['url'])
        if component == 'sdk':
            # Preserve any previous public metadata commits on subsequent exports.
            # The new filtered development tree supplies the current source code.
            remote = run('git', '-C', str(target), 'ls-remote', 'origin', 'refs/heads/master')
            if remote:
                previous = remote.split()[0]
                if previous != manifest['components'][component]['revision']:
                    raise RuntimeError('Public SDK head differs from sources.json; reconcile it before exporting')
                run('git', '-C', str(target), 'fetch', '--no-tags', 'origin', previous)
                ancestor = subprocess.run(['git', '-C', str(target), 'merge-base', '--is-ancestor', previous, branch]).returncode
                if ancestor:
                    differences = run('git', '-C', str(target), 'diff', '--name-only', branch, previous).splitlines()
                    filtered_is_ancestor = subprocess.run(['git', '-C', str(target), 'merge-base', '--is-ancestor', branch, previous]).returncode == 0
                    if filtered_is_ancestor and all(path.startswith('.github/workflows/') for path in differences):
                        # An unchanged development snapshot can reuse its exact
                        # existing public metadata head without another commit.
                        run('git', '-C', str(target), 'checkout', '-B', branch, previous)
                    else:
                        run('git', '-c', 'user.name=dead-chrysalid', '-c', 'user.email=339773814+dead-chrysalid@users.noreply.github.com', '-C', str(target), 'merge', '--no-ff', '-s', 'ours', previous, '-m', 'Retain prior public metadata with the new filtered SDK source')
            workflows = run('git', '-C', str(target), 'ls-files', '.github/workflows').splitlines()
            if workflows:
                run('git', '-C', str(target), 'rm', '--', *workflows)
                run('git', '-c', 'user.name=dead-chrysalid', '-c', 'user.email=339773814+dead-chrysalid@users.noreply.github.com', '-C', str(target), 'commit', '-m', 'Remove inherited upstream CI jobs from the public SDK tree')
        public_revision = run('git', '-C', str(target), 'rev-parse', branch)
        manifest['components'][component]['developmentRevision'] = revision
        manifest['components'][component]['revision'] = public_revision
        run(sys.executable, str(root / 'tools/Audit-PublicSources.py'), str(target), '--ref', branch)
    (root / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Audited source publication copies: {destination}')
