import time
import os
import math
import numpy as np

# --- Configuration (Must match the encoder) ---
width, height = 80, 50
filename = "bad_apple_data.bin"
total_pixels = width * height

# BitReader is now only needed for the Positional method
class BitReader:
    def __init__(self, data):
        self.data = data
        self.byte_index = 0
        self.bit_index = 0
    def read(self, num_bits):
        result = 0
        for _ in range(num_bits):
            if self.bit_index > 7:
                self.bit_index = 0
                self.byte_index += 1
            if self.byte_index >= len(self.data): return None
            byte = self.data[self.byte_index]
            bit = (byte >> (7 - self.bit_index)) & 1
            result = (result << 1) | bit
            self.bit_index += 1
        return result

# --- Main Decoder Logic ---
def decode_file(filepath):
    try:
        with open(filepath, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        print(f"Error: The file '{filepath}' was not found.")
        return

    current_frame = np.zeros(total_pixels, dtype=np.uint8)
    data_ptr = 0
    frame_count = 0
    
    while data_ptr < len(data):
        frame_count += 1
        data_ptr += 2 # Skip PIT Data
        
        # 1. Read the 1-byte header
        header_byte = data[data_ptr]
        data_ptr += 1
        encoding_flag = (header_byte >> 7) & 1
        delta_frame = np.zeros(total_pixels, dtype=np.uint8)

        if encoding_flag == 0: # RLE Method
            pixels_decoded = 0
            while pixels_decoded < total_pixels and data_ptr < len(data):
                rle_byte = data[data_ptr]
                data_ptr += 1
                val = (rle_byte >> 7) & 1
                count = rle_byte & 0x7F
                if count == 0: continue # Should not happen, but safe
                
                end_pixel = min(pixels_decoded + count, total_pixels)
                delta_frame[pixels_decoded:end_pixel] = val
                pixels_decoded = end_pixel
        
        else: # Positional Method
            # Let's try a linear decode approach
            # We create a BitReader for the rest of the data stream
            reader = BitReader(data[data_ptr:])
            num_bits_for_index = math.ceil(math.log2(width * height))
            count = reader.read(num_bits_for_index)
            
            if count is not None:
                for _ in range(count):
                    index = reader.read(num_bits_for_index)
                    if index is None: break
                    if index < total_pixels:
                        delta_frame[index] = 1
            
            # Advance the main data pointer by how many bytes the BitReader consumed
            bytes_consumed = reader.byte_index
            if reader.bit_index > 0: bytes_consumed += 1
            data_ptr += bytes_consumed

        np.bitwise_xor(current_frame, delta_frame, out=current_frame)
        display_ascii(current_frame, width, frame_count)
        time.sleep(1/30)

def display_ascii(pixels, w, frame_num):
    print("\033[H", end="")
    chars = [" ", "█"]
    output = "".join(chars[p] + ('\n' if (i + 1) % w == 0 else '') for i, p in enumerate(pixels))
    print(output)
    print(f"Frame: {frame_num} | Press Ctrl+C to exit")

if __name__ == "__main__":
    try:
        os.system('cls' if os.name == 'nt' else 'clear')
        decode_file(filename)
    except KeyboardInterrupt:
        print("\nPlayback stopped.")