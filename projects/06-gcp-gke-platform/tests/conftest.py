import sys
from pathlib import Path

# Los paquetes viven en src/ (cada uno se empaqueta en su propia imagen); se añade al
# path para importarlos en los tests sin instalarlos.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
