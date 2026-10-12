"""Exercise assembly with synthetic resources and build artifacts; no game data needed."""
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    source = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='redux-assembly-') as temporary:
        root = Path(temporary)
        shutil.copytree(source / 'tools', root / 'tools', ignore=shutil.ignore_patterns('.venv', '__pycache__', '.blender-support'))
        project = json.loads((source / 'project.json').read_text(encoding='utf-8-sig'))
        manifest = json.loads((source / 'sources.json').read_text(encoding='utf-8-sig'))
        (root / 'project.json').write_text(json.dumps(project))

        def write(relative, data):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            return path

        for component in ('engine', 'sdk', 'rtgl1', 'mainui'):
            repo = root / project['paths']['repositories'][component]
            repo.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            (repo / '.gitignore').write_text('build/\nBuild/\nx64/\n')
            subprocess.run(['git', '-C', str(repo), 'add', '.gitignore'], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Assembly Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Fixture'], check=True)
            manifest['components'][component]['revision'] = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        (root / 'sources.json').write_text(json.dumps(manifest))
        game = project['gameToken']
        payload = {}
        for relative in project['requiredArtifacts']['engine']:
            name = Path(relative).name
            if name == 'SDL2.dll':
                location = f"{project['dependencies']['sdl2']['path']}/lib/x64/{name}"
            elif name == 'RayTracedGL1.dll':
                location = f"{project['paths']['repositories']['rtgl1']}/{project['build']['rtgl1Build']}/{name}"
            else:
                location = f"{project['paths']['repositories']['engine']}/{project['build']['engineOutput']}/{name}"
            payload[relative] = write(location, b'new-' + name.encode())
        for relative in project['requiredArtifacts']['sdk']:
            name = Path(relative).name
            folder = 'cl_dll' if name.startswith('client') else 'dlls'
            payload[relative] = write(f"{project['paths']['repositories']['sdk']}/{project['build']['sdkBuild']}/{folder}/{project['build']['configuration']}/{name}", b'new-' + name.encode())
        payload['rt/shaders/test.spv'] = write(f"{project['paths']['repositories']['rtgl1']}/{project['build']['rtgl1Build']}/shaders/test.spv", b'new-shader')
        receipt = {'sources': manifest['components'], 'files': [{'path': relative, 'sha256': digest(path)} for relative, path in payload.items()]}
        write('.state/publication-build/build.json', json.dumps(receipt).encode())
        for relative in (f'{game}/gameinfo.txt', 'valve/gameinfo.txt', 'rt/data/scenes.json', 'rt/data/textures.json', f'{game}/maps/test.bsp', f'{game}/models/test.mdl', 'rt/shaders/obsolete.spv', '.workspace/private.txt', f'{game}/SAVE/test.sav'):
            write('resources/' + relative, b'resource')
        write('resources/rt_bin/xash.dll', b'old-engine')
        resources = root / 'resources'
        before = {str(p.relative_to(resources)): digest(p) for p in resources.rglob('*') if p.is_file()}

        def command(*args, success=True):
            result = subprocess.run([str(root / 'tools/StillHunger.cmd'), 'assemble', '-Resources', str(resources), *args], cwd=root, text=True, capture_output=True)
            if (result.returncode == 0) != success:
                raise AssertionError(result.stdout + result.stderr)

        command('-Output', 'runtime/forbidden', success=False)
        command('-Output', str(resources / 'child'), success=False)
        command()
        runtime = root / project['paths']['work'] / 'play'
        for relative, path in payload.items():
            assert (runtime / relative).read_bytes() == path.read_bytes(), relative
        assert (runtime / 'StartGame.cmd').is_file()
        assert (runtime / f'{game}/maps/test.bsp').read_bytes() == b'resource'
        assert not (runtime / 'rt/shaders/obsolete.spv').exists()
        assert not (runtime / '.workspace').exists()
        assert not (runtime / f'{game}/SAVE').exists()
        command(success=False)
        assert (runtime / 'rt_bin/xash.dll').read_bytes() == b'new-xash.dll'
        payload['rt/shaders/test.spv'].write_bytes(b'changed-shader')
        command('-Output', 'work/changed', success=False)
        assert not (root / 'work/changed').exists()
        after = {str(p.relative_to(resources)): digest(p) for p in resources.rglob('*') if p.is_file()}
        assert before == after, 'Resource installation changed'
    print('PASS: complete assembly, fresh shaders, source preservation, existing-output and changed-build rejection')


if __name__ == '__main__':
    main()
