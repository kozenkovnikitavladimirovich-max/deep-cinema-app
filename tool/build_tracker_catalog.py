"""Каталог трекеров для встроенного поиска: описания из открытого каталога Jackett.

Скачивает папку Definitions репозитория Jackett и складывает их в один файл
assets/trackers/catalog.json: {id: {name, description, language, type, yaml}}.
Если что-то пошло не так — пишет пустой каталог, сборка продолжается.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'assets', 'trackers', 'catalog.json')


def field(text, name):
    m = re.search(r'^%s:\s*(.+?)\s*$' % name, text, re.M)
    if not m:
        return ''
    v = m.group(1)
    if len(v) >= 2 and v[0] in '"\'' and v[-1] == v[0]:
        v = v[1:-1]
    return v


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = tempfile.mkdtemp()
    catalog = {}
    try:
        subprocess.run(['git', 'clone', '-q', '--depth', '1', '--filter=blob:none', '--sparse',
                        'https://github.com/Jackett/Jackett.git', tmp + '/jk'], check=True)
        subprocess.run(['git', '-C', tmp + '/jk', 'sparse-checkout', 'set', 'src/Jackett.Common/Definitions'], check=True)
        d = os.path.join(tmp, 'jk', 'src', 'Jackett.Common', 'Definitions')
        for name in sorted(os.listdir(d)):
            if not name.endswith('.yml'):
                continue
            text = open(os.path.join(d, name), encoding='utf-8').read()
            # Ответы в JSON/XML встроенный поиск пока не разбирает.
            if re.search(r'^\s+type:\s*(json|xml)\s*$', text, re.M):
                continue
            tid = field(text, 'id') or name[:-4]
            catalog[tid] = {
                'name': field(text, 'name') or tid,
                'description': field(text, 'description'),
                'language': field(text, 'language'),
                'type': field(text, 'type') or 'public',
                'yaml': text,
            }
    except Exception as e:  # noqa: BLE001
        print('catalog: %s' % e, file=sys.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if not catalog and os.path.exists(OUT):
        print('catalog: не удалось обновить — остаётся прежний')
        return
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, separators=(',', ':'))
    print('catalog: %d трекеров, %d КБ' % (len(catalog), os.path.getsize(OUT) // 1024))


if __name__ == '__main__':
    main()
