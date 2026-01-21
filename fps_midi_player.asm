BITS 16
ORG 0x7C00

; -----------------------------
; Start of Bootloader
; -----------------------------

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; Clear screen
    call clear_screen

    ; Print starting message
    mov si, start_msg
    call print_string
    call print_newline

    ; -----------------------------
    ; Load PIT frames from sector 2 into 0x9000:0
    ; -----------------------------
    mov ax, 0x9000
    mov es, ax
    xor bx, bx            ; offset = 0

    mov ah, 0x02          ; INT13h Read Sectors
    mov al, 32            ; 1 sector for demo
    mov ch, 0             ; cylinder
    mov cl, 2             ; sector 2 (sector 1 = MBR)
    mov dh, 0             ; head
    mov dl, 0x80          ; boot drive
    int 0x13
    jc disk_error

    ; DS = code/messages
    ; ES:BX = frames in RAM
    xor bx, bx
    mov si, 0
    mov di, data_end - data_start

; -----------------------------
; Main playback loop
; -----------------------------
play_loop:
    cmp si, di
    jae finished

    mov ax, [es:bx]     ; read 16-bit PIT frame
    add bx, 2
    add si, 2           ; track bytes read

    cmp ax, [last_pit]
    je wait_frame
    mov [last_pit], ax

    cmp ax, 0
    je silence_note

    ; enable speaker
    in al, SPEAKER_PORT
    or al, 3
    out SPEAKER_PORT, al

    ; send PIT value
    mov al, 0xB6
    out PIT_CMD_PORT, al
    mov cx, ax
    mov al, cl
    out PIT_DATA_PORT, al
    mov al, ch
    out PIT_DATA_PORT, al

    jmp wait_frame

silence_note:
    in al, SPEAKER_PORT
    and al, 0FCh
    out SPEAKER_PORT, al

wait_frame:
    mov ah, 0x86
    xor cx, cx
    mov dx, FRAME_DELAY_DX
    int 0x15
    jmp play_loop

finished:
    in al, SPEAKER_PORT
    and al, 0FCh
    out SPEAKER_PORT, al
    mov ax, cs
    mov ds, ax        ; restore DS to code/messages
    mov si, finished_msg
    call print_string
    jmp hang

disk_error:
    mov si, disk_error_msg
    call print_string
    jmp hang

; -----------------------------
; Routines
; -----------------------------
print_string:
.next_char:
    lodsb
    cmp al, 0
    je .done
    mov ah, 0x0E
    int 0x10
    jmp .next_char
.done:
    ret

print_newline:
    mov al, 0x0D
    mov ah, 0x0E
    int 0x10
    mov al, 0x0A
    int 0x10
    ret

clear_screen:
    mov ah, 0x06
    mov al, 0
    mov bh, 0x07
    mov cx, 0
    mov dx, 0x184F
    int 0x10
    mov ah, 0x02
    mov bh, 0
    mov dx, 0
    int 0x10
    ret

hang:
    hlt
    jmp hang

; -----------------------------
; Constants
; -----------------------------

FRAME_DELAY_DX  equ 16666      ; ~33ms (~30FPS)
PIT_CMD_PORT    equ 0x43
PIT_DATA_PORT   equ 0x42
SPEAKER_PORT    equ 0x61
SECTOR_SIZE     equ 512

; -----------------------------
; Messages
; -----------------------------
last_pit dw 0
start_msg:      db "Starting playback...",0
finished_msg:   db "Finished playback!",0
disk_error_msg: db "Disk read error!",0

; -----------------------------
; MBR Padding + Signature
; -----------------------------
times 510-($-$$) db 0
dw 0xAA55

; After the MBR code and messages, just before padding/signature
data_start:
    incbin "bad_apple.fpt"
data_end:

; just a lot of space for disk reading
; we are using standart reading, not extended
; which means we cannot go above 64kb
extra:
times 262144-($-$$) db 0
