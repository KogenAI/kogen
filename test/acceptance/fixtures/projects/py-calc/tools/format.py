from pathlib import Path
import sys

target = Path('calc.py')
text = target.read_text()
if '--write' in sys.argv and text.startswith('# unformatted\n'):
    target.write_text(text.removeprefix('# unformatted\n'))
