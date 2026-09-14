from pathlib import Path
import sys
p=Path('gate-count'); n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n));sys.exit(0 if True and n==3 else 1)
