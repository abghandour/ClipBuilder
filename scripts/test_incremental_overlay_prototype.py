import importlib.util
import json
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prototype', Path(__file__).with_name('incremental_overlay_prototype.py'))
prototype = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prototype)


class OverlayPrototypeTests(unittest.TestCase):
    def test_ranges_never_split_transition_groups(self):
        parts = prototype.plan_ranges([2, 2, 3.7, 2, 2])
        self.assertEqual([(p['first'], p['last']) for p in parts], [(0, 1), (2, 3), (4, 4)])
        self.assertAlmostEqual(parts[-1]['end'], 11.7)
        for previous, current in zip(parts, parts[1:]):
            self.assertEqual(previous['end'], current['start'])

    def test_invalid_durations_rejected(self):
        for values in [[], [0], [-1], [float('nan')], [float('inf')]]:
            with self.assertRaises(ValueError):
                prototype.plan_ranges(values)

    def test_only_dependent_ranges_invalidate(self):
        command = ['-i', 'assembled.mp4', '-filter_complex', 'graph', 'output.mp4']
        parts = prototype.plan_ranges([2]*8)
        before = [prototype.range_key(p, list('abcdefgh'), command, 'ffmpeg-test') for p in parts]
        after = [prototype.range_key(p, list('Xbcdefgh'), command, 'ffmpeg-test') for p in parts]
        self.assertNotEqual(before[0], after[0])
        self.assertEqual(before[1:], after[1:])
        # The adjacent range also invalidates if the edit touches its boundary.
        boundary = [prototype.range_key(p, list('aXcdefgh'), command, 'ffmpeg-test') for p in parts]
        self.assertNotEqual(before[1], boundary[1])

    def test_pixels_and_clock_invalidate_not_scratch_names(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory)/'overlay.png'
            image.write_bytes(b'pixels')
            part = prototype.plan_ranges([2, 2])[0]
            command = ['-i','video.mp4','-loop','1','-t','5','-i',str(image),'-filter_complex','fade=st=1','out.mp4']
            key = prototype.range_key(part, ['a','b'], command, 'ffmpeg-test')
            renamed = Path(directory)/'renamed.png'
            image.rename(renamed)
            command[7] = str(renamed)
            self.assertEqual(key, prototype.range_key(part, ['a','b'], command, 'ffmpeg-test'))
            renamed.write_bytes(b'edited')
            self.assertNotEqual(key, prototype.range_key(part, ['a','b'], command, 'ffmpeg-test'))
            renamed.write_bytes(b'pixels')
            shifted = dict(part, start=1, end=5)
            self.assertNotEqual(key, prototype.range_key(shifted, ['a','b'], command, 'ffmpeg-test'))

    def test_seek_keeps_input_png_duration_and_graph(self):
        command = ['-y','-i','video.mp4','-loop','1','-t','81','-i','overlay.png',
                   '-filter_complex','original-clock','-map','[v]','-map','0:a?',
                   '-c:v','libx264','-c:a','copy','-t','80','out.mp4']
        actual = prototype.chunk_command(command, dict(clockStart=4,clockEnd=8,trimEnd=8-1/60), Path('chunk.mp4'))
        self.assertTrue(actual[actual.index('-filter_complex')+1].startswith('original-clock;'))
        self.assertIn('trim=start=3.983333333:end=7.983333333', actual[actual.index('-filter_complex')+1])
        self.assertNotIn('-ss', actual)
        self.assertIn('81',actual)
        self.assertNotIn('0:a?',actual)
        self.assertNotIn('-c:a',actual)
        self.assertEqual(actual[-6:], ['-an','-fps_mode','vfr','-t','4.000000000','chunk.mp4'])

    def test_clocks_preserve_offset_and_fractional_boundaries(self):
        parts = prototype.plan_ranges([2,2,3.69,2])
        prototype.clock_ranges(parts, {'r_frame_rate':'30/1','start_time':'0.022982'}, 9.72)
        self.assertAlmostEqual(parts[0]['clockStart'], 1/30)
        self.assertAlmostEqual(parts[1]['clockStart'], 4+1/30)
        self.assertAlmostEqual(parts[0]['trimEnd'], 4+1/60)
        with self.assertRaises(ValueError):
            prototype.clock_ranges(parts, {'r_frame_rate':'25/1'}, 9.72)

    def test_cancelled_runner_never_starts_process(self):
        runner = prototype.Runner()
        runner.cancel()
        with self.assertRaises(InterruptedError):
            runner.run(['-version'])
        self.assertFalse(runner.processes)


@unittest.skipUnless(os.environ.get('CLIPBUILDER_OVERLAY_CAPTURE'), 'Opt-in production capture integration')
class OverlayPrototypeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.capture = Path(os.environ['CLIPBUILDER_OVERLAY_CAPTURE'])
        self.cache = self.root/'cache'
        shutil.copytree(Path(os.environ['CLIPBUILDER_OVERLAY_CACHE']), self.cache)
        command = json.loads((self.capture/'command.json').read_text())
        groups = [Path(p) for p in json.loads((self.capture/'groups.json').read_text())]
        parts = prototype.plan_ranges([float(prototype.probe(p)['format']['duration']) for p in groups])
        video = next(s for s in prototype.probe(prototype.source_inputs(command)[0])['streams'] if s['codec_type']=='video')
        limits = [command[i+1] for i,v in enumerate(command) if v=='-t']
        prototype.clock_ranges(parts, video, float(limits[-1]))
        version = subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0]
        key = prototype.range_key(parts[0], [prototype.digest(p) for p in groups], command, version)
        (self.cache/(key+'.mp4')).unlink()

    def test_failed_mux_publishes_no_new_ranges_or_output(self):
        class FailingRunner(prototype.Runner):
            def run(self, arguments):
                if 'concat' in arguments:
                    raise RuntimeError('Injected final mux failure')
                super().run(arguments)
        before = {p.name for p in self.cache.iterdir()}
        output = self.root/'failed.mp4'
        with self.assertRaisesRegex(RuntimeError, 'Injected'):
            prototype.render(self.capture, self.cache, output, FailingRunner())
        self.assertEqual(before, {p.name for p in self.cache.iterdir()})
        self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob('overlay-ranges-*')))

    def test_in_flight_cancellation_drains_children_and_does_not_publish(self):
        progress = self.root/'encoder-progress.txt'
        class CancelRunner(prototype.Runner):
            saw_progress = False
            def run(self, arguments):
                stopped = threading.Event()
                def watch():
                    deadline = time.monotonic()+5
                    while not stopped.wait(0.01) and time.monotonic() < deadline:
                        if progress.exists():
                            text = progress.read_text()
                            if any(line.startswith('frame=') and line[6:].strip().isdigit() and int(line[6:]) > 0 for line in text.splitlines()):
                                self.saw_progress = True
                                self.cancel()
                                return
                watcher = threading.Thread(target=watch, daemon=True)
                watcher.start()
                try:
                    super().run(['-stats_period','0.01','-progress',str(progress)]+arguments)
                finally:
                    stopped.set()
                    watcher.join(timeout=1)
        runner = CancelRunner()
        before = {p.name for p in self.cache.iterdir()}
        output = self.root/'cancelled.mp4'
        start = time.monotonic()
        with self.assertRaises(InterruptedError):
            prototype.render(self.capture, self.cache, output, runner)
        self.assertLess(time.monotonic()-start, 5)
        self.assertTrue(runner.saw_progress)
        self.assertFalse(runner.processes)
        self.assertFalse(output.exists())
        self.assertEqual(before, {p.name for p in self.cache.iterdir()})
        self.assertFalse(list(self.root.glob('overlay-ranges-*')))


if __name__ == '__main__':
    unittest.main()
