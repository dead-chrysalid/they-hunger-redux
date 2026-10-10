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
            options = ['--force', '--invert-paths', '--prune-empty', 'never', '--prune-degenerate', 'never']
            for path in ('models/', 'sound/', 'sprites/', 'android/pak/', 'android/res/drawable/'):
                options += ['--path', path]
            run(sys.executable, git_filter_repo.__file__, *options, cwd=target)
        public_revision = run('git', '-C', str(target), 'rev-parse', branch)
        manifest['components'][component]['developmentRevision'] = revision
        manifest['components'][component]['revision'] = public_revision
        # Only an explicit master push is permitted; never use --mirror.
        remotes = run('git', '-C', str(target), 'remote').splitlines()
        if 'origin' in remotes:
            run('git', '-C', str(target), 'remote', 'remove', 'origin')
        run('git', '-C', str(target), 'remote', 'add', 'origin', manifest['components'][component]['url'])
        run(sys.executable, str(root / 'tools/Audit-PublicSources.py'), str(target), '--ref', branch)
    (root / 'sources.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Audited source publication copies: {destination}')
