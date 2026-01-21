import mido
import numpy as np
import sounddevice as sd
import logging
import time
import threading
import sys
import argparse

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------

midi_file = "bad_apple.mid"
frames_file = "bad_apple_midi.bin"

sample_rate = 44100
amplitude = 0.3
PIT_CLOCK = 1193180
MIN_FREQ = 0  # minimum frequency clamp
FPS = 30

# ------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(message)s"
)

# ------------------------------------------------------------
# PIT / FREQUENCY
# ------------------------------------------------------------

def note_to_pit(note):
    if note is None: return 0
    freq = 440.0 * 2 ** ((note - 69) / 12)

    # minimum frequency protection
    if freq < MIN_FREQ:
        freq = MIN_FREQ

    pit = int(PIT_CLOCK / freq)

    # 0 reserved for silence
    pit = min(max(pit, 1), 65535)
    return pit


def pit_to_freq(pit):
    if pit == 0: return 0.0
    return PIT_CLOCK / pit


# ------------------------------------------------------------
# MIDI → MONOPHONIC (HIGHEST NOTE ON OVERLAPS) PIT TIMELINE
# ------------------------------------------------------------

def midi_to_pit_time_highest(filename):
    mid = mido.MidiFile(filename)

    pit_time_list = []
    active_notes = {}
    current_note = None
    note_start = 0.0
    current_time = 0.0

    logging.info(f"Loading MIDI: {filename}")

    for msg in mid:
        current_time += msg.time

        if msg.type == "note_on" and msg.velocity > 0:
            active_notes[msg.note] = current_time

        elif msg.type in ("note_off", "note_on") and msg.velocity == 0:
            active_notes.pop(msg.note, None)

        highest = max(active_notes) if active_notes else None

        if highest != current_note:
            if current_note is not None:
                duration = current_time - note_start
                pit_time_list.append(
                    (note_to_pit(current_note), note_start, duration)
                )

            current_note = highest
            note_start = current_time

    if current_note is not None:
        duration = current_time - note_start
        pit_time_list.append(
            (note_to_pit(current_note), note_start, duration)
        )

    notes_only = sum(d for _, _, d in pit_time_list)

    start = pit_time_list[0][1]
    end = pit_time_list[-1][1] + pit_time_list[-1][2]
    total = end - start

    logging.info(f"Notes only duration : {notes_only:.6f}s")
    logging.info(f"Total incl gaps     : {total:.6f}s")
    logging.info(f"PIT events          : {len(pit_time_list)}")

    return pit_time_list


# ------------------------------------------------------------
# CONTINUOUS WAV
# ------------------------------------------------------------

def generate_wave_from_pit(pit_time_list):
    audio = np.array([], dtype=np.float32)
    prev_end = 0.0

    for pit, start, duration in pit_time_list:
        gap = start - prev_end
        if gap > 0:
            audio = np.concatenate((
                audio,
                np.zeros(int(sample_rate * gap), dtype=np.float32)
            ))

        if pit == 0:
            wave = np.zeros(int(sample_rate * duration), dtype=np.float32)
        else:
            freq = pit_to_freq(pit)
            t = np.linspace(0, duration, int(sample_rate * duration), endpoint=False)
            wave = amplitude * np.sin(2 * np.pi * freq * t)

        audio = np.concatenate((audio, wave))
        prev_end = start + duration

    logging.info(f"Continuous WAV len  : {len(audio)/sample_rate:.6f}s")
    return audio


# ------------------------------------------------------------
# PIT TIMELINE → FPS FRAMES
# ------------------------------------------------------------

def pit_time_to_fps_frames(pit_time_list, fps):
    start = pit_time_list[0][1]
    end = pit_time_list[-1][1] + pit_time_list[-1][2]

    total_duration = end - start
    total_frames = int(round(total_duration * fps))

    frames = []
    idx = 0

    logging.info(f"FPS target          : {fps}")
    logging.info(f"FPS frames          : {total_frames}")

    for i in range(total_frames):
        t = start + (i / total_frames) * total_duration

        while idx < len(pit_time_list):
            pit, s, d = pit_time_list[idx]
            if t < s + d:
                break
            idx += 1

        if idx < len(pit_time_list):
            pit, s, d = pit_time_list[idx]
            frames.append(pit if s <= t < s + d else 0)
        else:
            frames.append(0)

    logging.info(f"FPS duration check  : {len(frames)/fps:.6f}s")
    return frames, total_duration


# ------------------------------------------------------------
# FPS FRAMES → WAV
# ------------------------------------------------------------

def fps_frames_to_wav(frames, total_duration):
    total_samples = int(round(total_duration * sample_rate))
    samples_per_frame = total_duration * sample_rate / len(frames)

    audio = np.zeros(total_samples, dtype=np.float32)

    sample_pos = 0
    phase = 0.0

    for pit in frames:
        next_pos = int(round(sample_pos + samples_per_frame))

        if next_pos > total_samples:
            next_pos = total_samples

        count = next_pos - sample_pos

        if pit == 0:
            audio[sample_pos:next_pos] = 0
        else:
            freq = pit_to_freq(pit)
            phase_inc = 2 * np.pi * freq / sample_rate

            for i in range(count):
                audio[sample_pos + i] = amplitude * np.sin(phase)
                phase += phase_inc
                if phase > 2 * np.pi:
                    phase -= 2 * np.pi

        sample_pos = next_pos

    logging.info(f"FPS WAV duration    : {len(audio)/sample_rate:.6f}s")
    return audio

def play_audio_thread(audio, sample_rate):
    sd.play(audio, sample_rate)
    sd.wait()

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-encode",
        action="store_true",
        help="Only encode MIDI → PIT frames, do not play audio"
    )
    return parser.parse_args()

# ------------------------------------------------------------
# SAVE FRAMES OF PIT
# ------------------------------------------------------------

def save_frames_raw(filename, frames):
    with open(filename, "wb") as f:
        for pit in frames:
            f.write(bytes((pit & 0xFF, (pit >> 8) & 0xFF)))

    logging.info(f"Saved {len(frames)} PIT frames → {filename}")

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

if __name__ == "__main__":
    # MIDI → PIT timeline
    pit_time_list = midi_to_pit_time_highest(midi_file)
    #print(pit_time_list)

    # PIT timeline → FPS frames
    fps_frames, total_duration = pit_time_to_fps_frames(pit_time_list, FPS)

    # FPS frames → Binary File
    save_frames_raw(frames_file, fps_frames)

    # Exit early if -encode passed
    args = parse_args()
    if args.encode:
        logging.info("Encode-only mode enabled. Exiting before playback.")
        exit(0)


    # FPS frames → WAV (verification)
    #audio = generate_wave_from_pit(pit_time_list)
    audio = fps_frames_to_wav(fps_frames, total_duration)

    logging.info("Playing FPS-resampled audio (Ctrl+C to stop)...")

    play_thread = threading.Thread(target=play_audio_thread, args=(audio, sample_rate), daemon=True)
    play_thread.start()

    try:
        while play_thread.is_alive(): time.sleep(0.1)
    except KeyboardInterrupt:
        logging.info("Stopping playback...")
        sd.stop()
        sys.exit(0)

    logging.info("Done.")
