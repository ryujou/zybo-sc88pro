"""Compare a whole-song capture, or join fallback captures at fixed boundaries."""
import argparse
import json
from pathlib import Path
import subprocess
import wave
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/effects/recording"
FFMPEG = "ffmpeg"
RATE = 44100


def read(path):
    with wave.open(str(path), "rb") as stream:
        assert (stream.getnchannels(), stream.getsampwidth(), stream.getframerate()) == (2, 2, RATE)
        return np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").reshape(-1, 2).astype(float)


def delay(expected, recorded, position, around=None, fractional=False):
    length = min(2 * RATE, len(expected) - position)
    assert length >= RATE // 2
    template = expected[position:position + length].mean(axis=1)
    signal = recorded.mean(axis=1)
    template -= template.mean()
    signal -= signal.mean()
    size = 1 << (len(signal) + length - 1).bit_length()
    correlation = np.fft.irfft(np.fft.rfft(signal, size) * np.conj(np.fft.rfft(template, size)), size)
    low = position if around is None else position + around - RATE // 10
    high = position + 4 * RATE if around is None else position + around + RATE // 10
    low, high = max(0, low), min(len(signal) - length + 1, high)
    assert high > low
    peak = int(low + np.argmax(correlation[low:high]))
    offset = 0.0
    if fractional and 0 < peak < len(correlation) - 1:
        a, b, c = correlation[peak - 1:peak + 2]
        offset = .5 * (a - c) / (a - 2 * b + c)
    return peak + offset - position


def compare_fixed_clock(expected, actual, aligned, lag, metrics, song):
    from scipy.signal import resample_poly

    positions, delays = [], []
    energy_floor = np.mean(expected ** 2) * .01
    for position in range(2 * RATE, len(expected) - 2 * RATE, 5 * RATE):
        window = expected[position:position + 2 * RATE]
        energy = np.mean(window ** 2, axis=1)
        if energy.mean() < energy_floor:
            continue
        positions.append(position + np.dot(np.arange(len(window)), energy) / energy.sum())
        delays.append(delay(expected, actual, position, lag, fractional=True))
    slope, intercept = np.polyfit(positions, delays, 1)
    residual = np.asarray(delays) - (np.asarray(positions) * slope + intercept)
    # Oversample the reference before evaluating its single affine clock map.
    # The recorded samples are neither resampled nor shifted piece by piece.
    oversampled = resample_poly(expected, 8, 1, axis=0)
    source_positions = (np.arange(len(aligned)) + lag - intercept) / (1 + slope) * 8
    reference = np.column_stack([np.interp(source_positions, np.arange(len(oversampled)),
                                          oversampled[:, ch], left=0, right=0) for ch in range(2)])
    calibration = metrics[0]['alignment_position_samples']
    x, y = reference[calibration:calibration + 2 * RATE], aligned[calibration:calibration + 2 * RATE]
    gains = ((x - x.mean(axis=0)) * (y - y.mean(axis=0))).sum(axis=0) / ((x - x.mean(axis=0)) ** 2).sum(axis=0)
    offsets = y.mean(axis=0) - x.mean(axis=0) * gains
    normalized = (aligned - offsets) / gains
    rms = np.sqrt(np.mean((normalized - reference) ** 2, axis=0) / np.mean(reference ** 2, axis=0))
    correlations = [float(np.corrcoef(reference[:, ch], normalized[:, ch])[0, 1]) for ch in range(2)]
    passed = bool(np.all(rms <= .1) and min(correlations) >= .995 and np.all(gains > 0) and
                  abs(slope * 1e6) <= 100 and np.max(np.abs(residual)) <= 1 and
                  metrics[0]['clipped_samples'] == 0 and min(metrics[0]['signal_to_noise_db']) >= 30)
    with wave.open(str(OUT / 'reference-clock-corrected.wav'), 'wb') as stream:
        stream.setparams((2, 2, RATE, len(reference), 'NONE', 'not compressed'))
        stream.writeframes(np.clip(np.rint(reference), -32768, 32767).astype('<i2').tobytes())
    result = dict(success=passed, song=song, scope='fixed_clock_correction_of_reference_only_original_recording_unchanged',
                  sample_rate=RATE, frames=len(aligned), clock_error_ppm=float(slope * 1e6),
                  recording_start_delay_samples=float(intercept), capture_crop_delay_samples=lag,
                  measurement_positions_samples=positions, measured_delays_samples=delays,
                  clock_fit_residual_samples=residual.tolist(), fixed_channel_gains=gains.tolist(),
                  fixed_channel_dc_offsets=offsets.tolist(), normalized_rms_error=rms.tolist(), correlation=correlations,
                  signal_to_noise_db=metrics[0]['signal_to_noise_db'], clipped_samples=metrics[0]['clipped_samples'])
    (OUT / 'comparison-clock-corrected.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    plot_comparison(reference, normalized, result)
    print(json.dumps(result))
    return passed


def plot_comparison(reference, recording, result):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(2, 2, figsize=(14, 7), layout='constrained')
    fig.suptitle(f'{result["song"]} | Zybo J5 to Line In | uninterrupted {len(recording) / RATE:.3f} s\n'
                 f'Reference clock correction: {result["clock_error_ppm"]:.3f} ppm; recording samples unchanged', fontsize=14)
    block = 1024
    count = len(reference) // block
    times = (np.arange(count) + .5) * block / RATE
    for ch, name in enumerate(['Left', 'Right']):
        ax = axes[0, ch]
        for signal, label, color in [(reference, 'Reference', '#1671b8'), (recording, 'Line In / fixed gain', '#db7925')]:
            values = signal[:count * block, ch].reshape(count, block) / 32768
            ax.fill_between(times, values.min(axis=1), values.max(axis=1), color=color, alpha=.35, label=label)
        ax.set(title=f'{name}: full waveform', xlabel='Time (s)', ylabel='Amplitude', xlim=(0, len(reference) / RATE))
        ax.legend(loc='upper right', fontsize=9)
        ax.grid(alpha=.2)
        ax = axes[1, ch]
        start, end = 30 * RATE, int(30.02 * RATE)
        times_zoom = np.arange(end - start) / RATE * 1000
        ax.plot(times_zoom, reference[start:end, ch] / 32768, color='#1671b8', label='Reference', linewidth=1.5)
        ax.plot(times_zoom, recording[start:end, ch] / 32768, color='#db7925', linestyle='--', label='Line In / fixed gain', linewidth=1)
        ax.set(title=f'{name}: 20 ms at 30 s | correlation {result["correlation"][ch]:.6f} | NRMS {result["normalized_rms_error"][ch] * 100:.2f}%',
               xlabel='Time within window (ms)', ylabel='Amplitude')
        ax.grid(alpha=.2)
    fig.savefig(OUT / 'waveform-comparison.png', dpi=150)
    plt.close(fig)


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--slices", action="store_true")
    parser.add_argument("--correct-reference-clock", action="store_true")
    parser.add_argument("--song", type=int, choices=range(1, 8), default=1)
    parser.add_argument("--output", type=Path, default=OUT)
    args = parser.parse_args()
    OUT = args.output
    song = f'th06_{args.song:02d}'
    if args.slices and args.correct_reference_clock:
        parser.error('Fixed-clock reference correction is verified for whole-song capture only')
    reference = OUT / "reference.wav"
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "s32le",
                    "-ar", "32000", "-ac", "2", "-i",
                    str(ROOT / f"build/verification/offline-player/phase-01/cases/{song}/reference/native.pcm"),
                    "-af", "volume=256", "-ar", str(RATE), "-c:a", "pcm_s16le", str(reference)], check=True)
    expected = read(reference)
    pieces, metrics, gains, offsets = [], [], None, None
    for index, name in enumerate("abc" if args.slices else "p"):
        core_start = index * 30 * RATE
        core_end = min((index + 1) * 30 * RATE, len(expected)) if args.slices else len(expected)
        first = max(0, core_start - RATE // 10)
        end = min(len(expected), core_end + RATE // 10)
        target = expected[first:end]
        actual = read(OUT / f"slice-{name}.wav")
        # The native reference begins with silence; correlate an audible window.
        early_windows = range(0, min(len(target) - 2 * RATE, 6 * RATE) + 1, RATE // 2)
        early_position = max(early_windows, key=lambda pos: np.sum(target[pos:pos + 2 * RATE] ** 2))
        lag = int(delay(target, actual, early_position))
        assert lag >= 0 and lag + len(target) <= len(actual), "Capture does not contain the complete slice"
        aligned = actual[lag:lag + len(target)]
        if gains is None:
            x, y = target[early_position:early_position + 2 * RATE], aligned[early_position:early_position + 2 * RATE]
            gains = ((x - x.mean(axis=0)) * (y - y.mean(axis=0))).sum(axis=0) / ((x - x.mean(axis=0)) ** 2).sum(axis=0)
            offsets = y.mean(axis=0) - x.mean(axis=0) * gains
        # Use a strong late passage instead of the nearly silent reverb tail.
        late_windows = range(max(RATE // 2, len(target) // 2), len(target) - 2 * RATE + 1, RATE // 2)
        late_position = max(late_windows, key=lambda pos: np.sum(target[pos:pos + 2 * RATE] ** 2))
        late_lag = delay(target, actual, late_position, lag)
        ppm = (late_lag - lag) / max(1, late_position - early_position) * 1e6
        noise = actual[:max(1, lag - RATE // 10)]
        noise_rms = np.sqrt(((noise - noise.mean(axis=0)) ** 2).mean(axis=0))
        signal_rms = np.sqrt(((aligned - offsets) ** 2).mean(axis=0))
        metrics.append(dict(slice=name, fixed_delay_samples=lag, clock_error_ppm=ppm,
                            alignment_position_samples=early_position,
                            clock_measurement_position_samples=late_position,
                            noise_rms=noise_rms.tolist(), signal_to_noise_db=(20 * np.log10(signal_rms / np.maximum(noise_rms, 1e-12))).tolist(),
                            clipped_samples=int(np.count_nonzero(np.abs(actual) >= 32767))))
        pieces.append(aligned[core_start - first:core_end - first])
    merged = np.concatenate(pieces)
    assert merged.shape == expected.shape
    with wave.open(str(OUT / f"{song}-linein.wav"), "wb") as stream:
        stream.setparams((2, 2, RATE, len(merged), "NONE", "not compressed"))
        stream.writeframes(merged.astype("<i2").tobytes())
    normalized = (merged - offsets) / gains
    error = normalized - expected
    rms = np.sqrt((error ** 2).mean(axis=0) / (expected ** 2).mean(axis=0))
    correlations = [float(np.corrcoef(expected[:, ch], normalized[:, ch])[0, 1]) for ch in range(2)]
    passed = bool(np.all(rms <= .1) and min(correlations) >= .995 and np.all(gains > 0) and
                  all(m["clipped_samples"] == 0 and abs(m["clock_error_ppm"]) <= 100 and
                      min(m["signal_to_noise_db"]) >= 30 for m in metrics))
    result = dict(success=passed, scope="actual_Line_In_fixed_delay_and_fixed_gain_no_time_warp",
                  sample_rate=RATE, frames=len(merged), fixed_channel_gains=gains.tolist(),
                  fixed_channel_dc_offsets=offsets.tolist(), normalized_rms_error=rms.tolist(),
                  correlation=correlations, slices=metrics,
                  join_sample_indices=[30 * RATE, 60 * RATE] if args.slices else [])
    (OUT / "comparison.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result))
    if args.correct_reference_clock:
        passed = compare_fixed_clock(expected, actual, merged, lag, metrics, song)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
