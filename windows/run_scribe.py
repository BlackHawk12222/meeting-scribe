"""PyInstaller entry point (and `python run_scribe.py` from source)."""
import multiprocessing
import sys

from scribe.app import main

if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main())
