"""Compile the production manifest model without the UIKit-dependent library."""
from pathlib import Path
import sys

source = (Path(__file__).resolve().parents[1] / 'AIGlass/Album/MediaLibrary.swift').read_text(encoding='utf-8')
start = source.index('struct StoredMediaItem:')
cursor = source.index('{', start) + 1
depth = 1
while depth:
    if source[cursor] == '{': depth += 1
    elif source[cursor] == '}': depth -= 1
    cursor += 1
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:cursor] + '\n', encoding='utf-8')
