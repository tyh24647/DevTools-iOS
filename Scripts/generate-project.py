#!/usr/bin/env python3
"""Maintain the checked-in project; preserve its current sources, targets and signing settings."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).with_name('patch-media-project.py')), run_name='__main__')
