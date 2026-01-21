@echo off

del /s /q *.img >nul 2>nul
del /s /q *.bin >nul 2>nul
pip install -r requirements.txt
python bad_apple_midi_encoder.py -encode
python bad_apple_encoder.py
nasm -f bin bootloader.asm -o bootloader.img
qemu-system-i386w.exe -audiodev dsound,id=snd0 -machine pcspk-audiodev=snd0 -drive format=raw,file=bootloader.img