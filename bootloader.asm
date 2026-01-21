bits 16
org 0x7C00

start:
    ; --- INITIALIZATION --- 
    cli             ; Disable interrupts while we set up our segments
    xor ax, ax      ; Set AX to 0
    mov ds, ax      ; Data Segment = 0
    mov es, ax      ; Extra Segment = 0
    mov ss, ax      ; Stack Segment = 0
    mov sp, 0x7C00  ; Set the stack pointer
    sti             ; Re-enable interrupts

    ; Set ES to Video Memory ONCE and keep it there
    mov ax, 0xB800
    mov es, ax

    ; Initialize boot drive from BIOS
    mov [boot_drive], dl

    ; Set video mode to 80x50 text mode
    mov ax, 1112h     ; load 8x8 font
    mov bl, 00h
    int 0x10

    ; Hide the blinking cursor
    mov ah, 0x01
    mov ch, 0x26
    int 0x10

    ; Clear screen
    call clear_screen


main_loop:
    ; Wait for 33,333 microseconds (~30 FPS)
    mov ah, 0x86
    xor cx, cx ; cx = 0
    mov dx, FRAME_DELAY_DX ;0x8235
    int 0x15
    
    call decode_note
    call decode_pixels
    jmp main_loop


decode_pixels:
    call read_next_byte    ; Read method header (1 byte)
    xor di, di             ; Reset video pointer to the top-left
    xor dx, dx             ; Reset the count of pixels drawn for this frame
    cmp al, 0x80           ; Check decoding byte method
    je decode_pixel_pos    ; 0x80 -> positional | 0x00 -> RLE
    jmp decode_pixel_rle_loop
decode_pixel_pos:
    mov byte [bits_cnt], 0 ; Reset zero paddings, we dont want to use leftover bits
    mov cl, POS_BITS       ; Set Bits to Read = 12
    call read_bits         ; Read 'Count' of changes -> Returns in AX
    mov dx, ax             ; Move Count to DX (Loop Counter)
    test dx, dx            ; If count is 0, we are done
    jz frame_done
decode_pixel_pos_loop:
    call read_bits         ; Read 'Index' of change -> Returns in AX; CL was not changed
    shl ax, 1              ; Multiply index by 2 (2 bytes per char)
    mov di, ax             ; Move offset to DI
    xor byte [es:di], 0xFB ; Flip the pixel (Space <-> Block)
    dec dx                 ; Decrement loop counter
    jnz decode_pixel_pos_loop ; Loop until all changes are drawn
    jmp frame_done
decode_pixel_rle_loop:
    cmp dx, NUM_OF_CHARS  ; Check if we have drawn all pixels for this frame
    jge frame_done        ; If yes, this frame is finished
    call read_next_byte   ; Load one RLE byte from our data into AL, this also handles end of file
    ; Extract the 7-bit count from the RLE byte
    xor ah, ah            ; Clear the top half of AX
    mov cx, ax            ; Now CX contains the RLE byte
    and cx, 0x7F          ; Keep only the lower 7 bits (the count)
    jcxz frame_error      ; If count is 0, something is wrong, just end frame
    add dx, cx            ; Add the count to our total pixels drawn
    test al, 0x80         ; Check the 1-bit value from the RLE byte
    jnz flip_loop         ; If it's 1, we need to flip pixels
    ; --- CASE 0: NO CHANGE (Value was 0) ---
    ; We just skip ahead in video memory.
    shl cx, 1             ; Multiply count by 2 (because each screen character is 2 bytes)
    add di, cx            ; Move the video pointer forward
    jmp decode_pixel_rle_loop ; Process the next RLE byte
flip_loop:                 ; --- CASE 1: FLIP PIXELS (Value was 1) ---
    xor byte [es:di], 0xFB ; The Magic Flip: XOR the character byte at [ES:DI] with 0xFB.
    inc di                 ; This turns a Space (0x20) into a Block (0xDB), and vice-versa.
    inc di                 ; add di, 2 (3 bytes) with inc di + inc di (2 bytes).
    loop flip_loop
    jmp decode_pixel_rle_loop ; Process the next RLE byte
frame_done:
    ret                       ; The frame is finished, loop back to start the next one
frame_error:
    jmp fail_sequence


decode_note:
    call read_next_byte ; read low byte
    mov bl, al
    call read_next_byte ; read high byte
    mov bh, al
    mov ax, bx          ; BX = PIT reload value
    call play_note
    ret    

; ===================================================================
;                 PROGRAM TERMINATION AND SUBROUTINES
; ===================================================================

; --- Play note using PIT and spekaer
;   AX == 0  -> silence speaker
;   AX != 0  -> play tone using PIT
play_note:
    cmp ax, [last_pit]        ; compare new PIT value with last one
    je .note_end              ; if same note, do nothing
    mov [last_pit], ax        ; store new PIT value
    test ax, ax               ; check if note value is zero
    jne .enable_note          ; if not zero, play the note
    call silence_note         ; otherwise silence the speaker
    ret                       ; skip note enabling
.enable_note:
    in  al, SPEAKER_PORT      ; read speaker control port
    or  al, 3                 ; enable speaker and PIT gate
    out SPEAKER_PORT, al      ; write back to speaker port
    mov al, 0xB6              ; PIT: channel 2, lobyte/hibyte, mode 3
    out PIT_CMD_PORT, al      ; send PIT command
    mov cx, ax                ; copy PIT reload value
    mov al, cl                ; load low byte
    out PIT_DATA_PORT, al     ; send low byte to PIT
    mov al, ch                ; load high byte
    out PIT_DATA_PORT, al     ; send high byte to PIT
.note_end:
    ret                       ; return to caller

; --- Turn off Speakers
silence_note:
    in al, SPEAKER_PORT
    and al, 0FCh
    out SPEAKER_PORT, al
    ret

; --- Read Bits (Max 16) ---
; Input:  CL = Number of bits to read
; Output: AX = Result
read_bits:
    pusha                   ; Save all registers
    xor bx, bx              ; Clear BX (we use BX as accumulator so AX is free for read_next_byte)
.bit_loop:
    cmp byte [bits_cnt], 0  ; Check if we have bits in buffer
    jg .have_bits           ; If yes, skip loading
    call read_next_byte     ; Get next byte into AL (doesn't clobber CX or BX due to its own pusha)
    mov [bits_buf], al      ; Store in bit buffer
    mov byte [bits_cnt], 8  ; Reset bit count to 8
.have_bits:
    shl byte [bits_buf], 1  ; Shift MSB of buffer into Carry Flag
    rcl bx, 1               ; Rotate Carry Flag into LSB of Result (BX)
    dec byte [bits_cnt]     ; Decrement bits remaining in buffer
    dec cl                  ; Decrement bits requested
    jnz .bit_loop           ; Loop if more bits needed
    mov [esp+14], bx        ; Overwrite the saved AX on stack with our result (BX)
    popa                    ; Restore all regs (Original CL restored, AX = Result)
    ret

; --- Read Byte: returns AL ---
read_next_byte:
    pusha                        ; Save all general-purpose registers
    ; --- Check if we've reached end of file (32-bit check) ---
    sub dword [file_size], 1     ; If it goes below 0 (underflow), Carry Flag is set.
    jc  success_sequence
    ; --- Check if need to load next sector
    mov ax, [sector_ptr]         ; Load pointer within current sector
    cmp ax, SECTOR_SIZE          ; Have we reached the end of the sector?
    jb .in_sector                ; If not, continue reading
    ; --- Need to load next sector ---
    mov word [sector_ptr], 0     ; Reset pointer to start of buffer
    inc word [sector_idx]        ; Increment to next sector
    call read_sector             ; Read new sector into buffer
.in_sector:
    ; --- Load next byte from current sector buffer ---
    mov si, READ_BUFFER         ; Base address of the sector buffer
    add si, [sector_ptr]        ; Offset = current position in sector
    mov al, [si]                ; Load byte into AL (return value)
    inc word [sector_ptr]       ; Move pointer to next byte in buffer
    mov [esp+14], al            ; Overwrite the saved AL on stack so 'popa' restores it
    popa                        ; Restore all general-purpose registers
    ret                         ; Return byte in AL

; --- Read Sector: loads sector_idx into READ_BUFFER ---
read_sector:
    mov dl, [boot_drive]  ; Load BIOS boot drive number into DL
    mov si, dap           ; Point SI to the Disk Address Packet
    mov ah, 0x42          ; BIOS extended read function
    int 0x13              ; Call BIOS interrupt (THIS CORRUPTS DS)
    jc fail_sequence      ; Now we can safely check the carry flag
    ret                   ; Return to caller

clear_screen:
    xor di, di           ; Start at the top-left corner (offset 0)
    mov cx, NUM_OF_CHARS ; 80 * 50 = 4000 characters to clear
    mov ax, 0x0F20       ; Attribute (0F) + Character (20)
    rep stosw            ; Repeat "store word" CX times
    ret

; --- Routine for successful completion ---
success_sequence:
    push cs           ; Restore the data segment to our code segment to find messages
    pop ds
    call silence_note
    call clear_screen ; Clear the screen
    mov si, end_msg   ; Setup parameters and call print function for the end message
    mov cx, END_MSG_LEN
    mov bl, 0x0A      ; Attribute: Light Green on Black
    call print_middle
    jmp hang          ; Halt the system


; --- Routine for Disk Read or Other Failures ---
fail_sequence:
    push cs           ; Restore the data segment to our code segment to find messages
    pop ds
    call clear_screen ; Clear the screen
    mov si, fail_msg  ; Setup parameters and call print function for the fail message
    mov cx, FAIL_MSG_LEN
    mov bl, 0x0C      ; Attribute: Light Red on Black
    call print_middle
    jmp hang          ; Halt the system

; --- Reusable function to print a centered string ---
; DS:SI -> Pointer to the string
; CX    -> Length of the string
; BL    -> Color attribute
print_middle:
    mov ax, 2000        ; Calculate the base address for the middle row (25); Offset = 25 * 80 = 2000
    mov dx, 80          ; Calculate the starting column; Column = (80 - string_length) / 2
    sub dl, cl          ; dl = 80 - length
    shr dl, 1           ; dl = (80 - length) / 2
    xor dh, dh          ; Clear dh, so dx = starting column
    add ax, dx          ; ax = 2000 + starting_column
    shl ax, 1           ; Multiply by 2 (for char + attribute)
    mov di, ax          ; Final starting offset in video memory
    mov ah, bl          ; Store attribute in AH. BL was never overwritten.
.print_loop:
    lodsb               ; Load character from DS:SI into AL
    stosw               ; Store AX (character + attribute) to ES:DI
    loop .print_loop
    ret

; --- Halt the system ---
hang:
    cli      ; Disable interrupts
    hlt      ; Halt the CPU
    jmp hang ; Loop just in case hlt doesn't work

; ===================================================================
;                                 DATA
; ===================================================================

boot_drive:   db 0               ; BIOS boot drive (DL)         
sector_ptr:   dw SECTOR_SIZE     ; Pointer inside sector buffer (0..511)
file_size:    dd end_of_file - ($$ + SECTOR_SIZE) ; Total number of bytes in the file
last_pit      dw 0               ; Used to not play same note twice
bits_buf:     db 0               ; Stores the current byte being acted on
bits_cnt:     db 0               ; Stores how many bits are left in bits_buf

POS_BITS        equ 12           ; Amount of bits that takes to encode max value of 4000
FRAME_DELAY_DX  equ 33333        ; ~33ms (~30FPS) / 16666 -> FOR QEMU
PIT_CMD_PORT    equ 0x43
PIT_DATA_PORT   equ 0x42
SPEAKER_PORT    equ 0x61
SECTOR_SIZE     equ 512
NUM_OF_CHARS    equ 80*50        
READ_BUFFER     equ 0x8000       ; Fixed buffer for one sector

dap:
    db 16                        ; Size of DAP
    db 0                         ; Reserved
    dw 1                         ; Number of sectors to read
    dw READ_BUFFER               ; Offset
    dw 0x0000                    ; Segment
sector_idx:                      ; LBA address (filled at runtime)
    dq 0                         ; Current sector index (starts at 0, sector 0 = MBR, sector 1... = Data)

; --- Stored Text and Length Constants ---
end_msg:    db 'THE END'
END_MSG_LEN equ $ - end_msg

fail_msg:   db 'THE ERROR'
FAIL_MSG_LEN equ $ - fail_msg

times (SECTOR_SIZE-2)-($-$$) db 0 ; Pad the MBR to 510 bytes
dw 0xAA55 ; Add the mandatory 0xAA55 signature at the end

; Include audio and video data
incbin "bad_apple_data.bin"
end_of_file:

; Padding to make file exactly 1MB
times 2048*SECTOR_SIZE-($-$$) db 0