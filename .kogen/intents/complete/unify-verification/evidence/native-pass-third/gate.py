from pathlib import Path
import sys
p=Path('gate-count'); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); print('live',n); sys.exit(0 if Path('mode').read_text()=='pass-third' and n==3 else 1)
