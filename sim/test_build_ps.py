"""Check that lowercase source templates remain usable by native build tools."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class NativeSourcePreparationTests(unittest.TestCase):
    def test_prepare_only_restores_cmake_names_without_compiler_or_ncnn(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, '-B', str(ROOT/'build/build_ps.py'),
                 '--prepare-only', '--build-dir', str(Path(directory)/'build')],
                capture_output=True, text=True,
                env={**os.environ, 'PYTHONDONTWRITEBYTECODE':'1'},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            mirror = Path(directory)/'build/source'
            for part in ['app/native', 'conv_accel/native']:
                self.assertIn('CMakeLists.txt', [p.name for p in (mirror/part).iterdir()])
                self.assertEqual((mirror/part/'CMakeLists.txt').read_bytes(),
                                 (ROOT/'src/ps_software'/part/'cmakelists.txt').read_bytes())
            self.assertEqual((mirror/'conv_accel/native/raw_frame.cpp').read_bytes(),
                             (ROOT/'src/ps_software/conv_accel/native/raw_frame.cpp').read_bytes())


if __name__ == '__main__':
    unittest.main()
