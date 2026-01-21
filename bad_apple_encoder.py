from PIL import Image, ImageSequence
import numpy as np
import math

# --- Configuration ---
gif_path = "bad_apple.gif"
midi_bin_path = "bad_apple_midi.bin"
width, height = 80, 50
num_bits_for_index = math.ceil(math.log2(width * height))
threshold = 128
output_file = "bad_apple_data.bin"

class BitWriter:
    def __init__(self):
        self.byte_array = bytearray()
        self.bit_buffer = 0
        self.bit_count = 0
    def write(self, value, num_bits):
        self.bit_buffer = (self.bit_buffer << num_bits) | value
        self.bit_count += num_bits
        while self.bit_count >= 8:
            byte_to_write = (self.bit_buffer >> (self.bit_count - 8)) & 0xFF
            self.byte_array.append(byte_to_write)
            self.bit_count -= 8
            self.bit_buffer &= (1 << self.bit_count) - 1
    def flush(self):
        if self.bit_count > 0:
            padded_byte = self.bit_buffer << (8 - self.bit_count)
            self.byte_array.append(padded_byte)
        self.bit_buffer = 0
        self.bit_count = 0
    def get_bytes(self): return self.byte_array

def rle_pack_bits(bits):
    if len(bits) == 0: return bytearray()
    encoded = bytearray()
    current = bits[0]; run_length = 1
    for b in bits[1:]:
        if b == current and run_length < 127: run_length += 1
        else:
            encoded.append((current << 7) | run_length)
            current = b; run_length = 1
    encoded.append((current << 7) | run_length)
    return encoded

def encode_delta_by_position_bits(delta_bits):
    writer = BitWriter()
    changed_indices = np.where(delta_bits == 1)[0]
    count = len(changed_indices)
    writer.write(count, num_bits_for_index)
    for index in changed_indices: writer.write(index, num_bits_for_index)
    writer.flush()
    return writer.get_bytes()

# --- Load MIDI PIT data ---
with open(midi_bin_path, "rb") as f:
    midi_data = f.read()

# split into 2-byte PIT frames
pit_frames = [
    midi_data[i:i+2]
    for i in range(0, len(midi_data), 2)
]

print(f"Loaded {len(pit_frames)} PIT frames")

# zero-padding function
def get_pit_frame(index):
    if index < len(pit_frames):
        frame = pit_frames[index]
        if len(frame) == 2:
            return frame
        else:
            return frame + b"\x00"  # odd-length safety
    return b"\x00\x00"

# --- Main Processing Logic ---
try:
    gif = Image.open(gif_path)
    total_frames = gif.n_frames
except FileNotFoundError:
    print(f"Error: The file '{gif_path}' was not found.")
    exit()

def frame_to_binary(frame):
    gray = frame.convert("L").resize((width, height))
    return (np.array(gray) > threshold).astype(np.uint8).flatten()

prev_frame = None
total_bytes = 0

print("Starting adaptive per-frame delta encoding...")
with open(output_file, "wb") as f:
    for frame_index, frame in enumerate(ImageSequence.Iterator(gif), start=1):
        bits = frame_to_binary(frame)
        delta_bits = bits if prev_frame is None else (bits ^ prev_frame)

        # === THE ADAPTIVE LOGIC ===
        rle_data = rle_pack_bits(delta_bits)
        pos_data = encode_delta_by_position_bits(delta_bits)
        f.write(get_pit_frame(frame_index-1)) # PIT DATA
        RLE_ONLY = False # Placeholder to make it only encode in RLE

        # We now write the header and payload separately to prevent corruption.
        if RLE_ONLY or len(rle_data) <= len(pos_data):
            # Write a header byte indicating RLE
            f.write(bytes([0b00000000])) # Flag bit 0
            # Write the RLE data payload
            f.write(rle_data)
            payload_size = len(rle_data)
            chosen_method = "RLE"
        else:
            # Write a header byte indicating Positional
            f.write(bytes([0b10000000])) # Flag bit 1
            # Write the Positional data payload
            f.write(pos_data)
            payload_size = len(pos_data)
            chosen_method = "Positional"

        # The total bytes for this frame is 1 (for the header) + payload size
        frame_size = 1 + payload_size
        total_bytes += frame_size + 2
        prev_frame = bits

        if frame_index % 50 == 0 or frame_index == total_frames:
            print(f"Frame {frame_index}/{total_frames} - Chose {chosen_method} ({frame_size} bytes)")

print(f"\nAll {total_frames} frames saved using adaptive encoding to '{output_file}' (BITS: {num_bits_for_index})")
print(f"Done. Final Size: {total_bytes/1024:.2f} KB")