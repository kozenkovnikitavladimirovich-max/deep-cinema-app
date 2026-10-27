"""Собрать deno.js из worker.js: тот же мост, но с запуском Deno.serve (для Deno Deploy)."""
import os

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, 'worker.js'), encoding='utf-8').read()
assert 'export default {' in src
out = src.replace('export default {', 'const app = {', 1)
out = ('// Deep Cinema — мост для Deno Deploy. Сгенерирован из worker.js (tool/bridge/make_deno.py),\n'
       '// правьте worker.js и запускайте скрипт заново.\n\n' + out +
       '\nDeno.serve((request, info) => app.fetch(request, info));\n')
open(os.path.join(here, 'deno.js'), 'w', encoding='utf-8').write(out)
print('deno.js готов')
