/* Measured boot inside bootcode.bin: every file bootcode.bin loads (config.txt, start.elf,
   fixup.dat) is hashed by the TPM and extended into a PCR before start.elf runs.

   Hook: 0x80001662 `bl 0x80001720(buf, len)` runs after every "Read File: %s, %d (bytes)";
   the file name is still in the caller's r8. We measure, then call 0x80001720 with the original
   arguments (it is a no-op while signed boot is off). No flags, OTP or boot settings are touched.

   TPM: Infineon SLB9670 on SPI0 CE1, TIS-over-SPI (TCG PC Client PTP), locality 0.
   Per file: SHA-256 and SHA-1 computed here on the VPU, then one TPM2_PCR_Extend(pcr) with both
   digests (the TPM itself hashes at only ~400 KB/s, too slow for a 10 MB kernel).
   config.txt -> PCR 1 (firmware config), everything else -> PCR 0 (firmware code).

   start.elf (stage 2, test): after fixup.dat is measured, the 16 bytes at start.elf link address
   0x0ed7a164 (file offset 0x179b64: `mov r0,r12; bl fclose; ld r0,(gp+..); beq`) are replaced in
   the file buffer, before bootcode.bin relocates and loads it, by `mov r5,se_load_hook; bl r5;
   beq (re-encoded); nop; nop`. No fixup.dat entry touches those bytes. se_load_hook runs inside
   start.elf for every file its load_file() reads, performs the displaced instructions and logs.

   Event log: each measurement is appended to a TCG crypto-agile event log (Spec ID Event03 header,
   TCG_PCR_EVENT2 records with sha1+sha256) built in L2 and copied to SDRAM at LOG_PHYS once the
   file just measured proves SDRAM is up. overlays/tpm-eventlog.dtbo reserves that memory and sets
   linux,sml-base/size on the TPM node, so Linux exposes it as binary_bios_measurements.

   Assembled as one section that starts at HOOK_ADDR rounded down to 4, so branches resolve without a linker. */

        .set HOOK_ADDR,    0x80001662
        .set PAYLOAD_ADDR, 0x80010000
        .set PRINTF,       0x800090d6      /* printf(fmt, r1..r5) -> UART when BOOT_UART=1 */
        .set MEMCPY,       0x80006ae4      /* memcpy(dst, src, n) */
        .set MEMSET,       0x80006b66      /* memset(dst, val, n) */
        .set ORIG_UPDATE,  0x80001720      /* displaced call, made unchanged */

        .set GPFSEL0,      0x7e200000
        .set SPI_CS,       0x7e204000      /* +4 FIFO, +8 CLK */
        .set TIMER_CLO,    0x7e003004      /* free-running 1 MHz */
        .set CDIV,         32
        .set GPCLR0,       0x7e200028      /* write 1 to clear (drive low) */
        .set TPM_RST_GPIO, 4               /* TPM RST# (active low, board pull-up), found by tests/probe-tpm-reset-gpio.sh */

        .set TIS_ACCESS,   0xd40000
        .set TIS_STS,      0xd40018
        .set TIS_FIFO,     0xd40024
        .set TIS_DID_VID,  0xd40f00

        /* scratch in the unused L2 range above the payload */
        .set CMDBUF,       0x80014000      /* 29 + 1024 bytes */
        .set RSPBUF,       0x80014800      /* 512 bytes */
        .set HEXBUF,       0x80014c00
        .set SCRATCH,      0x80014f00
        .set W256,         0x80015000      /* SHA-256 message schedule, 64 words */
        .set W1,           0x80015100      /* SHA-1 message schedule, 80 words */
        .set BLK,          0x80015300      /* current 64-byte block */
        .set H256,         0x80015340      /* SHA-256 state, 8 words */
        .set H1,           0x80015360      /* SHA-1 state, 5 words */
        .set DIG256,       0x80015380      /* SHA-256 digest, big-endian bytes */
        .set DIG1,         0x800153a0      /* SHA-1 digest, big-endian bytes */
        .set SE_DIG256,    0x800153c0      /* start.elf's SHA-256 result (stage 2) */
        .set LOGBUF,       0x80015400      /* event log being built, LOG_MAX bytes */
        .set LOG_MAX,      2048
        .set LOG_PHYS,     0x0f000000      /* ARM physical address handed to Linux */
        .set LOG_SDRAM,    0xcf000000      /* same memory through the VPU's uncached alias */
        .set LOG_SIZE,     0x30000         /* reserved region, must match overlays/tpm-eventlog.dts */
        .set LOG_AREA,     0x8000          /* log at 0x0f000000-0x0f007fff, stage-2 code from 0x0f008000 */
        .set SE_HOOK_BUF,  0xc0100000 + 0x179b64   /* start.elf file buffer + offset of link 0x0ed7a164 */
        .set SE_CODE_SDRAM, 0xcf008000     /* payload copy in the reserved log region (phys 0x0f008000), uncached: for writing it */
        .set SE_CODE_EXEC,  0x0f008000     /* same memory through the cached alias start.elf itself runs from: for executing it */
        .set SE_RET_LINK,  0x0ed7a16c      /* link address after our `bl r5` (lr on entry to se_load_hook) */
        .set SE_BEQ_FALL,  0x0ed7a174      /* displaced `beq r0,0,0x0ed7a1cc`: not taken -> here */
        .set SE_BEQ_TAKEN, 0x0ed7a1cc      /*                                  taken     -> here */
        .set SE_DT_BUF,    0xc0100000 + 0x17988e   /* file buffer + offset of link 0x0ed79e8e */
        .set SE_DT_RET,    0x0ed79e92      /* lr on entry to se_dt_hook */
        .set DTBUF,        0xcf010000      /* scratch copy of the final DT (phys 0x0f010000), uncached */
        .set DTBUF_MAX,    0x10000
        .set SE_FCLOSE,    0x0ece14a0      /* start.elf link addresses (+ runtime delta) */
        .set SE_LOGCAT,    0x0ee25492
        .set SE_LOG,       0x0ee2549a      /* log(cat, level, fmt, ...) -> "MESS:" line */
        .set SE_SHA256_INIT,   0x0edea6e6  /* start.elf's own SHA-256: init(ctx) */
        .set SE_SHA256_UPDATE, 0x0edea8fe  /*   update(ctx, buf, len) */
        .set SE_SHA256_FINAL,  0x0edea4ac  /*   final(ctx, out32) */
        .set SE_SHACTX,    0x80015c00      /* its context (>= 0x6c bytes; 256 reserved) */
        .set EV_POST_CODE,             0x01
        .set EV_PLATFORM_CONFIG_FLAGS, 0x0a
        .set EV_TABLE_OF_DEVICES,      0x0b
        .set EV_IPL,                   0x0d

        .set SECTION_BASE, HOOK_ADDR & ~3   /* section starts 4-aligned so .balign matches real addresses */

        .text
        .skip   HOOK_ADDR - SECTION_BASE
hook:
        bl      measure

        .org    PAYLOAD_ADDR - SECTION_BASE

/* measure(r0=buf, r1=len), caller's r8 = file name -- bootcode.bin hook (stage 1) */
measure:
        stm     r6-r9,lr,(--sp)
        mov     r6,r0
        mov     r7,r1
        mov     r9,r8
        mov     r3,0                       /* PCR 0, firmware code */
        mov     r4,EV_POST_CODE
        ldb     r0,(r9)
        cmp     r0,0x63                    /* 'c' -> config.txt: PCR 1, firmware config */
        bne     1f
        mov     r3,1
        mov     r4,EV_PLATFORM_CONFIG_FLAGS
1:      mov     r0,r6
        mov     r1,r7
        mov     r2,r9
        bl      measure_core
        ldb     r0,(r9)
        cmp     r0,0x66                    /* 'f' -> fixup.dat: start.elf is in its buffer, not yet relocated */
        bne     2f
        bl      se_install
2:      mov     r0,r6
        mov     r1,r7
        mov     r2,ORIG_UPDATE
        bl      r2                         /* displaced call, original arguments */
        ldm     r6-r9,pc,(sp++)

/* measure_core(r0=buf, r1=len, r2=name, r3=pcr, r4=event type): hash, PCR_Extend, event log.
   Shared by stage 1 (bootcode.bin) and stage 2 (start.elf). */
measure_core:
        stm     r6-r15,lr,(--sp)
        mov     r14,r0
        mov     r15,r1
        mov     r9,r2                      /* file name */
        mov     r11,r3                     /* pcr */
        lea     r0,cur_evtype
        st      r4,(r0)
        lea     r0,reset_done              /* once per boot, before the TPM is first used: */
        ld      r1,(r0)
        cmp     r1,0
        bne     1f
        mov     r1,1
        st      r1,(r0)
        bl      tpm_hw_reset               /* PCRs only clear on a hardware reset; SoC reset doesn't reach the TPM */
1:
        bl      spi_init
        lea     r0,diag_done               /* one-time register dump */
        ld      r1,(r0)
        cmp     r1,0
        bne     5f
        mov     r1,1
        st      r1,(r0)
        mov     r0,TIS_DID_VID
        bl      tis_read32
        mov     r12,r0
        lea     r0,last_wait
        ld      r13,(r0)
        mov     r0,TIS_ACCESS
        bl      tis_read32
        mov     r10,r0
        mov     r0,TIS_STS
        bl      tis_read32
        mov     r3,r0
        lea     r0,msg_diag
        mov     r1,r12
        mov     r2,r10
        mov     r4,r13
        bl      say
        mov     r0,TIMER_CLO
        ld      r10,(r0)                   /* restart t0 after the dump */
5:
        bl      tpm_open
        cmp     r0,0
        bne     m_fail

        lea     r0,started
        ld      r1,(r0)
        cmp     r1,0
        bne     2f
        mov     r1,1
        st      r1,(r0)
        bl      log_init
        lea     r0,cmd_startup
        mov     r1,12
        bl      tpm_cmd
        mov     r1,r0
        lea     r0,msg_startup
        bl      say
2:
        lea     r0,busy_us
        mov     r1,0
        st      r1,(r0)
        mov     r0,TIMER_CLO
        ld      r10,(r0)                   /* t0 */

        /* stage 2: SHA-256 by start.elf's own implementation (ours is slow there), SHA-1 by ours */
        lea     r0,in_stage2
        ld      r0,(r0)
        lea     r1,skip256
        st      r0,(r1)
        cmp     r0,0
        beq     1f
        lea     r6,se_delta
        ld      r6,(r6)
        mov     r0,SE_SHACTX
        add     r1,r6,SE_SHA256_INIT
        bl      r1
        mov     r0,SE_SHACTX
        mov     r1,r14
        mov     r2,r15
        add     r3,r6,SE_SHA256_UPDATE
        bl      r3
        mov     r0,SE_SHACTX
        mov     r1,SE_DIG256
        add     r2,r6,SE_SHA256_FINAL
        bl      r2
1:
        /* SHA-1 (and SHA-256 in stage 1) over the file, 64 bytes at a time */
        mov     r6,r14                     /* cursor */
        mov     r7,r15                     /* remaining */
        bl      sha_init
h_loop:
        mov     r0,64
        cmp     r7,r0
        blt     h_tail
        mov     r0,3
        and     r0,r6
        cmp     r0,0
        bne     1f
        mov     r0,r6                      /* aligned: hash in place, no copy */
        bl      sha_block
        b       2f
1:      mov     r0,BLK
        mov     r1,r6
        mov     r2,64
        bl      copy
        mov     r0,BLK
        bl      sha_block
2:      add     r6,64
        sub     r7,64
        b       h_loop
h_tail:                                    /* last partial block + 0x80 + zero pad + bit length */
        mov     r0,BLK
        mov     r1,0
        mov     r2,64
        bl      fill
        cmp     r7,0
        beq     3f
        mov     r0,BLK
        mov     r1,r6
        mov     r2,r7
        bl      copy
3:      mov     r0,BLK
        add     r0,r7
        mov     r1,0x80
        stb     r1,(r0)
        mov     r0,56
        cmp     r7,r0
        blt     4f
        mov     r0,BLK
        bl      sha_block                  /* no room for the length: one more block */
        mov     r0,BLK
        mov     r1,0
        mov     r2,64
        bl      fill
4:      mov     r0,BLK+56
        lsr     r1,r15,29
        bl      put_be32
        mov     r0,BLK+60
        shl     r1,r15,3
        bl      put_be32
        mov     r0,BLK
        bl      sha_block
        bl      sha_final
        lea     r0,skip256
        ld      r0,(r0)
        cmp     r0,0
        beq     1f
        mov     r0,DIG256                  /* stage 2: take start.elf's SHA-256 */
        mov     r1,SE_DIG256
        mov     r2,32
        bl      copy
1:      mov     r0,TIMER_CLO
        ld      r12,(r0)
        sub     r12,r10                    /* hash time, us */

        /* TPM2_PCR_Extend(pcr, {sha1, sha256}) */
        mov     r0,CMDBUF
        lea     r1,tmpl_ext
        mov     r2,87
        bl      copy
        mov     r0,CMDBUF
        stb     r11,(r0+13)
        mov     r0,CMDBUF+33
        mov     r1,DIG1
        mov     r2,20
        bl      copy
        mov     r0,CMDBUF+55
        mov     r1,DIG256
        mov     r2,32
        bl      copy
        mov     r0,CMDBUF
        mov     r1,87
        bl      tpm_cmd
        cmp     r0,0
        bne     m_fail

        lea     r0,msg_done
        mov     r1,r9
        mov     r2,r11
        mov     r3,r15
        bl      say
        mov     r0,TIMER_CLO
        ld      r1,(r0)
        sub     r1,r10                     /* total, us */
        lea     r0,msg_time
        mov     r2,r12
        bl      say
        mov     r0,HEXBUF
        mov     r1,DIG1
        mov     r2,20
        bl      hexdump
        lea     r0,msg_sha1
        mov     r1,r11
        mov     r2,HEXBUF
        bl      say
        mov     r0,HEXBUF
        mov     r1,DIG256
        mov     r2,32
        bl      hexdump
        lea     r0,msg_sha256
        mov     r1,r11
        mov     r2,HEXBUF
        bl      say

        lea     r1,cur_evtype
        ld      r1,(r1)
        mov     r0,r11
        mov     r2,r9
        bl      log_append
        lea     r0,in_stage2               /* stage 2 appends straight into the SDRAM log */
        ld      r0,(r0)
        cmp     r0,0
        bne     7f
        cmp     r11,0                      /* stage 1: PCR0 files (start.elf, fixup.dat) live in SDRAM, so it is up */
        bne     7f
        bl      log_publish
7:
        bl      tpm_close
        b       m_out

m_fail:
        mov     r2,r0
        lea     r0,cmd_stage
        ld      r3,(r0)
        lea     r0,last_sts
        ld      r4,(r0)
        lea     r0,msg_fail
        mov     r1,r9
        bl      say
        bl      tpm_close
m_out:
        ldm     r6-r15,pc,(sp++)

/* tpm_hw_reset: pulse TPM RST# (GPIO TPM_RST_GPIO) low for 2 ms, release to input (board pull-up),
   wait 100 ms. Gives every boot, warm or cold, a TPM reset (_TPM_Init), so PCRs start from zero. */
tpm_hw_reset:
        stm     r6,lr,(--sp)
        mov     r0,GPCLR0
        mov     r1,1
        shl     r1,TPM_RST_GPIO
        st      r1,(r0)                    /* output latch low */
        mov     r0,GPFSEL0
        ld      r1,(r0)
        mov     r2,7
        shl     r2,TPM_RST_GPIO*3
        not     r2,r2
        and     r1,r2
        mov     r2,1
        shl     r2,TPM_RST_GPIO*3
        or      r1,r2
        st      r1,(r0)                    /* FSEL4 = output: RST# low */
        mov     r0,2000
        bl      delay_us
        mov     r0,GPFSEL0
        ld      r1,(r0)
        mov     r2,7
        shl     r2,TPM_RST_GPIO*3
        not     r2,r2
        and     r1,r2
        st      r1,(r0)                    /* FSEL4 = input: released, pull-up brings RST# high */
        mov     r0,100000
        bl      delay_us
        lea     r0,msg_reset
        mov     r1,TPM_RST_GPIO
        bl      say
        ldm     r6,pc,(sp++)

/* delay_us(r0 = microseconds), system timer */
delay_us:
        mov     r1,TIMER_CLO
        ld      r2,(r1)
1:      ld      r3,(r1)
        sub     r3,r2
        cmp     r3,r0
        blt     1b
        rts

/* ---------------- TPM command layer ---------------- */

/* tpm_cmd(r0=cmd, r1=len) -> r0 = response code, or -1 on timeout. Response in RSPBUF. */
tpm_cmd:
        stm     r6-r9,lr,(--sp)
        mov     r6,r0
        mov     r7,r1
        mov     r0,TIS_STS
        mov     r1,0x40                    /* commandReady */
        bl      tis_write8
        lea     r1,cmd_stage
        mov     r2,1
        st      r2,(r1)
        mov     r0,0x40
        bl      poll_sts
        cmp     r0,0
        beq     c_err
        mov     r9,100000                  /* retries while burstCount is 0 */
c_send:
        lea     r1,cmd_stage
        mov     r2,2
        st      r2,(r1)
        mov     r0,0                       /* no mask: stsValid is 0 on an idle TPM, read burstCount */
        bl      poll_sts
        lsr     r0,8
        mov     r1,0xffff
        and     r0,r1
        cmp     r0,0
        bne     1f
        addcmpbgt r9,-1,0,c_send
        b       c_err
1:
        mov     r1,64
        min     r0,r1
        min     r0,r7
        mov     r8,r0
        mov     r0,TIS_FIFO
        mov     r1,r6
        mov     r2,r8
        mov     r3,0
        bl      tis_xfer
        add     r6,r8
        sub     r7,r8
        cmp     r7,0
        bgt     c_send

        mov     r0,TIS_STS
        mov     r1,0x20                    /* tpmGo */
        bl      tis_write8
        mov     r0,TIMER_CLO
        ld      r0,(r0)
        lea     r1,go_t0
        st      r0,(r1)
        mov     r0,0x90
        bl      poll_sts                   /* wait for the TPM to finish the command */
        mov     r0,TIMER_CLO
        ld      r0,(r0)
        lea     r1,go_t0
        ld      r1,(r1)
        sub     r0,r1
        lea     r1,busy_us
        ld      r2,(r1)
        add     r2,r0
        st      r2,(r1)

        mov     r6,RSPBUF
        mov     r7,10                      /* header first */
        mov     r9,0
c_recv:
        lea     r1,cmd_stage
        mov     r2,3
        st      r2,(r1)
        mov     r0,0x90                    /* stsValid | dataAvail */
        bl      poll_sts
        cmp     r0,0
        beq     c_err
        lsr     r0,8
        mov     r1,0xffff
        and     r0,r1
        cmp     r0,0
        beq     c_recv
        mov     r1,64
        min     r0,r1
        min     r0,r7
        mov     r8,r0
        mov     r0,TIS_FIFO
        mov     r1,r6
        mov     r2,r8
        mov     r3,1
        bl      tis_xfer
        add     r6,r8
        sub     r7,r8
        cmp     r7,0
        bgt     c_recv
        cmp     r9,0
        bne     c_done
        mov     r9,1
        mov     r0,RSPBUF+2
        bl      get_be32                   /* responseSize */
        mov     r1,512
        min     r0,r1
        sub     r0,10
        mov     r7,r0
        cmp     r7,0
        bgt     c_recv
c_done:
        mov     r0,TIS_STS
        mov     r1,0x40
        bl      tis_write8
        mov     r0,RSPBUF+6
        bl      get_be32
        b       c_out
c_err:
        mov     r0,TIS_STS
        mov     r1,0x40
        bl      tis_write8
        mov     r0,-1
c_out:
        ldm     r6-r9,pc,(sp++)

/* poll_sts(r0=mask) -> r0 = TPM_STS when (sts & mask) == mask, 0 after 2 s */
poll_sts:
        stm     r6-r8,lr,(--sp)
        mov     r6,r0
        mov     r0,TIMER_CLO
        ld      r7,(r0)
1:      mov     r0,TIS_STS
        bl      tis_read32
        mov     r8,r0
        lea     r1,last_sts
        st      r0,(r1)
        and     r0,r6
        cmp     r0,r6
        beq     2f
        mov     r0,TIMER_CLO
        ld      r0,(r0)
        sub     r0,r7
        mov     r1,2000000
        cmp     r0,r1
        blt     1b
        mov     r8,0
2:      mov     r0,r8
        ldm     r6-r8,pc,(sp++)

/* tpm_open: request locality 0 -> r0 = 0, or -1 */
tpm_open:
        stm     r6,lr,(--sp)
        mov     r0,TIS_ACCESS
        mov     r1,0x02                    /* requestUse */
        bl      tis_write8
        mov     r6,1000
1:      mov     r0,TIS_ACCESS
        bl      tis_read32
        mov     r1,0xa0                    /* tpmRegValidSts | activeLocality */
        and     r0,r1
        cmp     r0,r1
        beq     2f
        addcmpbgt r6,-1,0,1b
        mov     r0,-1
        b       3f
2:      mov     r0,0
3:      ldm     r6,pc,(sp++)

/* tpm_close: relinquish locality 0 */
tpm_close:
        stm     lr,(--sp)
        mov     r0,TIS_ACCESS
        mov     r1,0x20                    /* activeLocality: write 1 to relinquish */
        bl      tis_write8
        ldm     pc,(sp++)

/* ---------------- TIS over SPI ---------------- */

/* tis_read32(r0=addr) -> r0 (little-endian register value) */
tis_read32:
        stm     lr,(--sp)
        mov     r1,SCRATCH
        mov     r2,4
        mov     r3,1
        bl      tis_xfer
        mov     r1,SCRATCH
        ld      r0,(r1)
        ldm     pc,(sp++)

/* tis_write8(r0=addr, r1=value) */
tis_write8:
        stm     lr,(--sp)
        mov     r2,SCRATCH
        stb     r1,(r2)
        mov     r1,r2
        mov     r2,1
        mov     r3,0
        bl      tis_xfer
        ldm     pc,(sp++)

/* tis_xfer(r0=addr, r1=buf, r2=len 1..64, r3=1 read / 0 write) -> r0 = 0, or -1 on wait-state timeout */
tis_xfer:
        stm     r6-r9,lr,(--sp)
        mov     r6,r0
        mov     r7,r1
        mov     r8,r2
        mov     r9,r3
        bl      spi_begin
        mov     r0,r8
        sub     r0,1
        cmp     r9,0
        beq     1f
        bitset  r0,7
1:      bl      spi_byte
        mov     r0,0xd4
        bl      spi_byte
        mov     r0,r6
        lsr     r0,8
        mov     r1,0xff
        and     r0,r1
        bl      spi_byte
        mov     r0,r6
        mov     r1,0xff
        and     r0,r1
        bl      spi_byte
        lea     r1,last_wait               /* keep the flow-control byte for diagnostics */
        st      r0,(r1)
        mov     r5,1000                    /* flow control: wait until MISO bit 0 = 1 */
2:      btest   r0,0
        bne     3f
        mov     r0,0
        bl      spi_byte
        addcmpbgt r5,-1,0,2b
        bl      spi_end
        mov     r0,-1
        b       9f
3:      cmp     r9,0
        beq     5f
4:      mov     r0,0
        bl      spi_byte
        stb     r0,(r7)
        add     r7,1
        addcmpbgt r8,-1,0,4b
        b       6f
5:      ldb     r0,(r7)
        bl      spi_byte
        add     r7,1
        addcmpbgt r8,-1,0,5b
6:      bl      spi_end
        mov     r0,0
9:      ldm     r6-r9,pc,(sp++)

/* ---------------- SPI0 ---------------- */

/* GPIO7 (CE1), 9 (MISO), 10 (MOSI), 11 (SCLK) -> ALT0; mode 0; CS1 */
spi_init:
        mov     r0,GPFSEL0
        ld      r1,(r0)
        mov     r2,0x38e00000              /* FSEL7 | FSEL9 */
        not     r2,r2
        and     r1,r2
        mov     r2,0x20800000              /* ALT0 for 7 and 9 */
        or      r1,r2
        st      r1,(r0)
        ld      r1,(r0+4)
        mov     r2,0x3f                    /* FSEL10 | FSEL11 */
        not     r2,r2
        and     r1,r2
        mov     r2,0x24                    /* ALT0 for 10 and 11 */
        or      r1,r2
        st      r1,(r0+4)
        mov     r0,SPI_CS
        mov     r1,CDIV
        st      r1,(r0+8)
        mov     r1,0x31                    /* CS=1, clear FIFOs */
        st      r1,(r0)
        rts

spi_begin:
        mov     r1,SPI_CS
        mov     r2,0xb1                    /* TA | clear FIFOs | CS=1 */
        st      r2,(r1)
        rts

spi_end:
        mov     r1,SPI_CS
        mov     r3,100000
1:      ld      r2,(r1)
        btest   r2,16                      /* DONE */
        bne     2f
        addcmpbgt r3,-1,0,1b
2:      mov     r2,0x31
        st      r2,(r1)
        rts

/* spi_byte(r0=tx) -> r0=rx; uses r1-r3 only */
spi_byte:
        mov     r1,SPI_CS
        st      r0,(r1+4)
        mov     r3,100000
1:      ld      r2,(r1)
        btest   r2,17                      /* RXD */
        bne     2f
        addcmpbgt r3,-1,0,1b
        mov     r0,0
        rts
2:      ld      r0,(r1+4)
        rts

/* ---------------- helpers ---------------- */

/* get_be32(r0=ptr) -> r0 */
get_be32:
        ldb     r1,(r0)
        shl     r1,8
        ldb     r2,(r0+1)
        or      r1,r2
        shl     r1,8
        ldb     r2,(r0+2)
        or      r1,r2
        shl     r1,8
        ldb     r2,(r0+3)
        or      r1,r2
        mov     r0,r1
        rts

/* put_be32(r0=ptr, r1=value) */
put_be32:
        stb     r1,(r0+3)
        lsr     r1,8
        stb     r1,(r0+2)
        lsr     r1,8
        stb     r1,(r0+1)
        lsr     r1,8
        stb     r1,(r0)
        rts

/* hexdump(r0=dst, r1=src, r2=n): 2n lowercase hex chars + NUL */
hexdump:
        lea     r3,hexchars
1:      ldb     r4,(r1)
        mov     r5,r4
        lsr     r5,4
        add     r5,r3
        ldb     r5,(r5)
        stb     r5,(r0)
        mov     r5,0xf
        and     r4,r5
        add     r4,r3
        ldb     r4,(r4)
        stb     r4,(r0+1)
        add     r0,2
        add     r1,1
        addcmpbgt r2,-1,0,1b
        mov     r4,0
        stb     r4,(r0)
        rts

/* ---------------- SHA-256 / SHA-1 ---------------- */

sha_init:
        stm     lr,(--sp)
        mov     r0,H256
        lea     r1,iv256
        mov     r2,32
        bl      copy
        mov     r0,H1
        lea     r1,iv1
        mov     r2,20
        bl      copy
        ldm     pc,(sp++)

/* sha_block(r0 = 64-byte block, 4-byte aligned) into both states */
sha_block:
        stm     lr,(--sp)
        bl      blk_to_w
        lea     r0,skip256
        ld      r0,(r0)
        cmp     r0,0
        bne     1f
        bl      sha256_compress
1:      bl      sha1_compress
        ldm     pc,(sp++)

/* blk_to_w(r0 = block): bytes -> big-endian words in W256[0..15] and W1[0..15] */
blk_to_w:
        stm     r6-r7,lr,(--sp)
        mov     r6,0xff00ff00
        mov     r7,0x00ff00ff
        mov     r2,r0
        lea     r3,w256_base
        ld      r3,(r3)
        lea     r4,w1_base
        ld      r4,(r4)
        mov     r5,16
1:      ld      r0,(r2++)
        ror     r1,r0,8                    /* b1 b2 b3 b0 */
        ror     r0,r0,24                   /* b3 b0 b1 b2 */
        and     r1,r6
        and     r0,r7
        or      r0,r1                      /* b3 b2 b1 b0 = big-endian value */
        st      r0,(r3++)
        st      r0,(r4++)
        addcmpbgt r5,-1,0,1b
        ldm     r6-r7,pc,(sp++)

sha256_compress:
        stm     r6-r23,lr,(--sp)
        mov     r16,W256                   /* q = &w[t-16] */
        mov     r14,48
1:      ld      r1,(r16+4)                 /* w[t-15] */
        ror     r2,r1,7
        ror     r3,r1,18
        eor     r2,r3
        lsr     r3,r1,3
        eor     r2,r3                      /* s0 */
        ld      r1,(r16+56)                /* w[t-2] */
        ror     r3,r1,17
        ror     r4,r1,19
        eor     r3,r4
        lsr     r4,r1,10
        eor     r3,r4                      /* s1 */
        ld      r0,(r16)
        add     r0,r2
        ld      r1,(r16+36)                /* w[t-7] */
        add     r0,r1
        add     r0,r3
        st      r0,(r16+64)
        add     r16,4
        addcmpbgt r14,-1,0,1b

        mov     r0,H256
        ld      r6,(r0)                    /* a..h = r6..r13 */
        ld      r7,(r0+4)
        ld      r8,(r0+8)
        ld      r9,(r0+12)
        ld      r10,(r0+16)
        ld      r11,(r0+20)
        ld      r12,(r0+24)
        ld      r13,(r0+28)
        lea     r15,w256_base
        ld      r15,(r15)
        lea     r16,k256
        mov     r14,64
2:      ror     r0,r10,6
        ror     r1,r10,11
        eor     r0,r1
        ror     r1,r10,25
        eor     r0,r1                      /* S1(e) */
        eor     r1,r11,r12
        and     r1,r10
        eor     r1,r12                     /* ch(e,f,g) */
        add     r0,r1
        add     r0,r13
        ld      r1,(r16++)
        add     r0,r1
        ld      r1,(r15++)
        add     r0,r1                      /* t1 */
        ror     r2,r6,2
        ror     r3,r6,13
        eor     r2,r3
        ror     r3,r6,22
        eor     r2,r3                      /* S0(a) */
        or      r3,r6,r7
        and     r3,r8
        and     r4,r6,r7
        or      r3,r4                      /* maj(a,b,c) */
        add     r2,r3                      /* t2 */
        mov     r13,r12
        mov     r12,r11
        mov     r11,r10
        add     r10,r9,r0
        mov     r9,r8
        mov     r8,r7
        mov     r7,r6
        add     r6,r0,r2
        addcmpbgt r14,-1,0,2b

        mov     r0,H256
        ld      r1,(r0)
        add     r1,r6
        st      r1,(r0)
        ld      r1,(r0+4)
        add     r1,r7
        st      r1,(r0+4)
        ld      r1,(r0+8)
        add     r1,r8
        st      r1,(r0+8)
        ld      r1,(r0+12)
        add     r1,r9
        st      r1,(r0+12)
        ld      r1,(r0+16)
        add     r1,r10
        st      r1,(r0+16)
        ld      r1,(r0+20)
        add     r1,r11
        st      r1,(r0+20)
        ld      r1,(r0+24)
        add     r1,r12
        st      r1,(r0+24)
        ld      r1,(r0+28)
        add     r1,r13
        st      r1,(r0+28)
        ldm     r6-r23,pc,(sp++)

sha1_compress:
        stm     r6-r23,lr,(--sp)
        mov     r16,W1                     /* q = &w[t-16] */
        mov     r14,64
1:      ld      r0,(r16+52)                /* w[t-3] */
        ld      r1,(r16+32)                /* w[t-8] */
        eor     r0,r1
        ld      r1,(r16+8)                 /* w[t-14] */
        eor     r0,r1
        ld      r1,(r16)                   /* w[t-16] */
        eor     r0,r1
        ror     r0,r0,31                   /* rol 1 */
        st      r0,(r16+64)
        add     r16,4
        addcmpbgt r14,-1,0,1b

        mov     r0,H1
        ld      r6,(r0)                    /* a..e = r6..r10 */
        ld      r7,(r0+4)
        ld      r8,(r0+8)
        ld      r9,(r0+12)
        ld      r10,(r0+16)
        lea     r15,w1_base
        ld      r15,(r15)
        mov     r14,0                      /* t */
        mov     r17,20
        mov     r18,40
        mov     r19,60
2:      cmp     r14,r17
        bge     3f
        eor     r1,r8,r9                   /* 0..19: ch(b,c,d) */
        and     r1,r7
        eor     r1,r9
        mov     r2,0x5a827999
        b       6f
3:      cmp     r14,r18
        bge     4f
        eor     r1,r7,r8                   /* 20..39: parity */
        eor     r1,r9
        mov     r2,0x6ed9eba1
        b       6f
4:      cmp     r14,r19
        bge     5f
        or      r1,r7,r8                   /* 40..59: maj(b,c,d) */
        and     r1,r9
        and     r3,r7,r8
        or      r1,r3
        mov     r2,0x8f1bbcdc
        b       6f
5:      eor     r1,r7,r8                   /* 60..79: parity */
        eor     r1,r9
        mov     r2,0xca62c1d6
6:      ror     r0,r6,27                   /* rol 5 */
        add     r0,r1
        add     r0,r10
        add     r0,r2
        ld      r1,(r15++)
        add     r0,r1
        mov     r10,r9
        mov     r9,r8
        ror     r8,r7,2                    /* rol 30 */
        mov     r7,r6
        mov     r6,r0
        add     r14,1
        mov     r0,80
        cmp     r14,r0
        blt     2b

        mov     r0,H1
        ld      r1,(r0)
        add     r1,r6
        st      r1,(r0)
        ld      r1,(r0+4)
        add     r1,r7
        st      r1,(r0+4)
        ld      r1,(r0+8)
        add     r1,r8
        st      r1,(r0+8)
        ld      r1,(r0+12)
        add     r1,r9
        st      r1,(r0+12)
        ld      r1,(r0+16)
        add     r1,r10
        st      r1,(r0+16)
        ldm     r6-r23,pc,(sp++)

/* states -> big-endian digests at DIG256 / DIG1 */
sha_final:
        stm     r6-r8,lr,(--sp)
        mov     r6,H256
        mov     r7,DIG256
        mov     r8,8
1:      ld      r1,(r6++)
        mov     r0,r7
        bl      put_be32
        add     r7,4
        addcmpbgt r8,-1,0,1b
        mov     r6,H1
        mov     r7,DIG1
        mov     r8,5
2:      ld      r1,(r6++)
        mov     r0,r7
        bl      put_be32
        add     r7,4
        addcmpbgt r8,-1,0,2b
        ldm     r6-r8,pc,(sp++)

/* ---------------- start.elf stage 2 ---------------- */

/* se_install: patch start.elf's load_file in its file buffer (bootcode.bin context) */
se_install:
        stm     r6-r7,lr,(--sp)
        mov     r6,SE_HOOK_BUF
        lea     r7,se_orig
        mov     r2,0
1:      add     r0,r6,r2
        ldb     r0,(r0)
        add     r1,r7,r2
        ldb     r1,(r1)
        cmp     r0,r1
        bne     8f                         /* not the start.elf this was written for: leave it alone */
        add     r2,1
        cmp     r2,16
        blt     1b
        mov     r0,SE_DT_BUF               /* DT site must hold `mov r5,2; st r5,(r15+0x10)` */
        lea     r1,se_dt_orig
        mov     r2,0
2:      add     r3,r0,r2
        ldb     r3,(r3)
        add     r4,r1,r2
        ldb     r4,(r4)
        cmp     r3,r4
        bne     8f
        add     r2,1
        cmp     r2,4
        blt     2b

        /* L2 contents are not guaranteed to reach SDRAM or survive start.elf: copy the whole payload
           into the reserved log region (known to survive) and run stage 2 from there, uncached */
        mov     r0,SE_CODE_SDRAM
        mov     r1,PAYLOAD_ADDR
        lea     r2,payload_end
        sub     r2,r1
        bl      copy
        /* switch only the copy to stage 2 (this stage keeps using bootcode's printf/memcpy) */
        lea     r0,in_stage2
        bl      to_copy
        mov     r1,1
        st      r1,(r0)
        lea     r0,log_buf                 /* the copy appends to the published log in place */
        bl      to_copy
        mov     r1,LOG_SDRAM
        st      r1,(r0)
        lea     r0,w256_base               /* stage 2: SHA working arrays via the L1+L2-cached alias */
        bl      to_copy
        mov     r1,W256 & 0x3fffffff
        st      r1,(r0)
        lea     r0,w1_base
        bl      to_copy
        mov     r1,W1 & 0x3fffffff
        st      r1,(r0)

        /* window at link 0x0ed7a164: mov r5,se_load_hook; bl r5; mov r5,se_dt_hook; b r5 */
        mov     r0,0x05
        stb     r0,(r6)
        stb     r0,(r6+8)
        mov     r0,0xe8
        stb     r0,(r6+1)
        stb     r0,(r6+9)
        lea     r0,se_load_hook
        bl      to_exec
        mov     r1,r0
        add     r0,r6,2
        bl      put_le32
        mov     r0,0x65                    /* bl r5 */
        stb     r0,(r6+6)
        mov     r0,0x00
        stb     r0,(r6+7)
        lea     r0,se_dt_hook
        bl      to_exec
        mov     r1,r0
        add     r0,r6,10
        bl      put_le32
        mov     r0,0x45                    /* b r5 */
        stb     r0,(r6+14)
        mov     r0,0x00
        stb     r0,(r6+15)
        /* DT site at link 0x0ed79e8e: bl 0x0ed7a16c (the second half of the window) */
        mov     r0,SE_DT_BUF
        lea     r1,se_dt_bl
        mov     r2,4
        bl      copy

        lea     r0,se_load_hook
        bl      to_exec
        mov     r1,r0
        lea     r0,msg_se_ok
        bl      say
        b       9f
8:      lea     r0,msg_se_bad
        bl      say
9:      ldm     r6-r7,pc,(sp++)

/* to_exec(r0 = payload address in L2) -> r0 = address to execute the copy at (cached alias) */
to_exec:
        mov     r1,PAYLOAD_ADDR
        sub     r0,r1
        mov     r1,SE_CODE_EXEC
        add     r0,r1
        rts

/* to_copy(r0 = payload address in L2) -> r0 = same location in the SDRAM copy (uncached, for writes) */
to_copy:
        mov     r1,PAYLOAD_ADDR
        sub     r0,r1
        mov     r1,SE_CODE_SDRAM
        add     r0,r1
        rts

/* se_entry_sdram -> r0 = address of se_load_hook in the SDRAM copy */
se_entry_sdram:
        lea     r0,se_entry_off
        ld      r1,(r0)
        add     r0,r1                      /* se_load_hook, L2 address */
        mov     r1,PAYLOAD_ADDR
        sub     r0,r1
        mov     r1,SE_CODE_SDRAM
        add     r0,r1
        rts

/* se_load_hook: called from start.elf load_file after fread (start.elf context).
   r6 = buffer, r7 = bytes read, r10 = name, r12 = FILE; lr = runtime SE_RET_LINK.
   *.dtb -> PCR 5 (EV_TABLE_OF_DEVICES); kernel, initramfs, armstub, u-boot -> PCR 4 (EV_IPL). */
se_load_hook:
        stm     r6-r11,(--sp)              /* no lr: we return to the beq's target, not to lr */
        mov     r9,lr
        mov     r1,SE_RET_LINK
        sub     r9,r1                      /* runtime delta from link addresses */
        lea     r0,se_delta
        st      r9,(r0)
        mov     r0,r12                     /* displaced: mov r0,r12 */
        add     r1,r9,SE_FCLOSE
        bl      r1                         /* displaced: fclose(file) */
        mov     r3,4
        mov     r4,EV_IPL
        mov     r0,r10                     /* name ends in ".dtb"? */
1:      ldb     r1,(r0)
        cmp     r1,0
        beq     2f
        add     r0,1
        b       1b
2:      sub     r0,r10
        cmp     r0,4
        blt     4f
        add     r0,r10                     /* r0 = end of name; (rX-n) would assemble as pc-relative, so step back */
        sub     r0,1
        ldb     r1,(r0)
        cmp     r1,0x62                    /* b */
        bne     4f
        sub     r0,1
        ldb     r1,(r0)
        cmp     r1,0x74                    /* t */
        bne     4f
        sub     r0,1
        ldb     r1,(r0)
        cmp     r1,0x64                    /* d */
        bne     4f
        sub     r0,1
        ldb     r1,(r0)
        cmp     r1,0x2e                    /* . */
        bne     4f
        mov     r3,5
        mov     r4,EV_TABLE_OF_DEVICES
4:      mov     r0,r6
        mov     r1,r7
        mov     r2,r10
        bl      measure_core
        lea     r1,se_delta
        ld      r1,(r1)
        ld      r0,(gp+1543832)            /* displaced: ld r0,(gp+1543832) */
        cmp     r0,0                       /* displaced: beq r0,0,0x0ed7a1cc */
        bne     5f
        add     r1,SE_BEQ_TAKEN
        b       6f
5:      add     r1,SE_BEQ_FALL
6:      ldm     r6-r11,(sp++)
        b       r1

/* se_dt_hook: start.elf has built the final device tree (r7 = address, r10 = size) and is about
   to start the ARM. Measure a copy with /chosen/rng-seed and kaslr-seed (they change every
   boot) NOP'd out, into PCR 5; Linux still gets the real DT. lr = runtime SE_DT_RET.
   Verify from Linux with tools/verify/final-dt-digest.py. */
se_dt_hook:
        stm     r6-r11,lr,(--sp)
        mov     r9,lr
        mov     r1,SE_DT_RET
        sub     r9,r1
        lea     r0,se_delta
        st      r9,(r0)
        add     r0,r7,4
        bl      get_be32                   /* FDT totalsize */
        mov     r6,r0
        mov     r1,DTBUF_MAX
        cmp     r6,r1
        bgt     8f
        mov     r0,DTBUF
        mov     r1,r7
        mov     r2,r6
        bl      copy
        mov     r0,DTBUF
        mov     r1,r6
        bl      fdt_zero_seeds
        mov     r0,DTBUF
        mov     r1,r6
        lea     r2,name_final_dt
        mov     r3,5
        mov     r4,EV_TABLE_OF_DEVICES
        bl      measure_core
        b       9f
8:      lea     r0,msg_dt_big
        mov     r1,r6
        bl      say
9:      mov     r5,2                       /* displaced: mov r5,2; st r5,(r15+0x10) */
        st      r5,(r15+0x10)
        ldm     r6-r11,pc,(sp++)

/* fdt_zero_seeds(r0=fdt, r1=len): replace every rng-seed / kaslr-seed / rsts property with FDT_NOP tokens
   and zero the alignment padding after node names and property values, which start.elf leaves
   uninitialised (it differed between two cold boots). */
fdt_zero_seeds:
        stm     r6-r12,lr,(--sp)
        mov     r6,r0                      /* fdt */
        add     r0,r6,8
        bl      get_be32
        add     r7,r6,r0                   /* p = struct block */
        add     r0,r6,36
        bl      get_be32
        add     r8,r7,r0                   /* end of struct block */
        add     r0,r6,12
        bl      get_be32
        add     r9,r6,r0                   /* strings block */
1:      cmp     r7,r8
        bge     9f
        mov     r0,r7
        bl      get_be32
        add     r7,4
        cmp     r0,1                       /* FDT_BEGIN_NODE: skip name, pad to 4 */
        bne     3f
2:      ldb     r1,(r7)
        add     r7,1
        cmp     r1,0
        bne     2b
        bl      zero_pad                   /* start.elf leaves padding uninitialised */
        b       1b
3:      cmp     r0,3                       /* FDT_PROP: len, nameoff, value */
        bne     6f
        mov     r0,r7
        bl      get_be32
        mov     r10,r0                     /* len */
        add     r0,r7,4
        bl      get_be32
        add     r11,r9,r0                  /* name */
        add     r7,8
        mov     r0,r11
        lea     r1,str_rng_seed
        bl      streq
        mov     r12,r0
        mov     r0,r11
        lea     r1,str_kaslr_seed
        bl      streq
        or      r12,r0
        mov     r0,r11
        lea     r1,str_rsts                /* /chosen/bootloader/rsts: reset reason, 0x1000 cold / 0x1020 warm */
        bl      streq
        or      r0,r12
        cmp     r0,0
        beq     5f
        /* erase the whole property with FDT_NOP tokens, exactly as the kernel does once it has
           consumed rng-seed, so /sys/firmware/fdt with both seeds NOP'd hashes to the same value */
        sub     r0,r7,12                   /* property start (FDT_PROP token) */
        add     r1,r10,3
        mov     r2,3
        not     r2,r2
        and     r1,r2
        add     r1,r7                      /* end of padded value */
        mov     r2,4
4:      cmp     r0,r1
        bge     5f
        mov     r3,0
        stb     r3,(r0)
        stb     r3,(r0+1)
        stb     r3,(r0+2)
        stb     r2,(r0+3)                  /* big-endian FDT_NOP = 0x00000004 */
        add     r0,4
        b       4b
5:      add     r7,r10
        bl      zero_pad
        b       1b
6:      cmp     r0,2                       /* FDT_END_NODE */
        beq     1b
        cmp     r0,4                       /* FDT_NOP */
        beq     1b
9:      ldm     r6-r12,pc,(sp++)           /* FDT_END or anything unexpected */

/* zero_pad: zero bytes from r7 up to the next 4-byte boundary and advance r7 there (uses r1, r2) */
zero_pad:
        mov     r2,0
1:      mov     r1,3
        and     r1,r7
        cmp     r1,0
        beq     2f
        stb     r2,(r7)
        add     r7,1
        b       1b
2:      rts

/* streq(r0, r1) -> r0 = 1 if the NUL-terminated strings are equal */
streq:
1:      ldb     r2,(r0)
        ldb     r3,(r1)
        cmp     r2,r3
        bne     2f
        cmp     r2,0
        beq     3f
        add     r0,1
        add     r1,1
        b       1b
2:      mov     r0,0
        rts
3:      mov     r0,1
        rts

/* say(r0=fmt, r1..r3 [, r4, r5]): bootcode printf in stage 1, start.elf logger in stage 2 (3 values) */
say:
        stm     r6-r10,lr,(--sp)
        lea     r6,in_stage2
        ld      r6,(r6)
        cmp     r6,0
        bne     1f
        mov     r6,PRINTF
        bl      r6
        b       9f
1:      mov     r7,r0
        mov     r8,r1
        mov     r9,r2
        mov     r10,r3
        lea     r6,se_delta
        ld      r6,(r6)
        add     r0,r6,SE_LOGCAT
        bl      r0
        mov     r1,2
        mov     r2,r7
        mov     r3,r8
        mov     r4,r9
        mov     r5,r10
        add     r6,SE_LOG
        bl      r6
9:      ldm     r6-r10,pc,(sp++)

/* copy(r0=dst, r1=src, r2=n): bootcode memcpy in stage 1, byte loop in stage 2 */
copy:
        lea     r3,in_stage2
        ld      r3,(r3)
        cmp     r3,0
        bne     1f
        mov     r3,MEMCPY
        b       r3
1:      cmp     r2,0
        ble     3f
2:      ldb     r3,(r1)
        stb     r3,(r0)
        add     r0,1
        add     r1,1
        addcmpbgt r2,-1,0,2b
3:      rts

/* fill(r0=dst, r1=byte, r2=n) */
fill:
        lea     r3,in_stage2
        ld      r3,(r3)
        cmp     r3,0
        bne     1f
        mov     r3,MEMSET
        b       r3
1:      cmp     r2,0
        ble     3f
2:      stb     r1,(r0)
        add     r0,1
        addcmpbgt r2,-1,0,2b
3:      rts

/* ---------------- TCG event log ---------------- */

/* start a new log: TCG_PCClientPCREvent carrying TCG_EfiSpecIDEvent ("Spec ID Event03") */
log_init:
        stm     lr,(--sp)
        mov     r0,LOGBUF
        lea     r1,log_hdr
        mov     r2,69
        bl      copy
        lea     r0,log_len
        mov     r1,69
        st      r1,(r0)
        lea     r0,log_zeroed
        mov     r1,0
        st      r1,(r0)
        ldm     pc,(sp++)

/* log_append(r0=pcr, r1=event type, r2=name): TCG_PCR_EVENT2 with DIG1/DIG256, event data = name */
log_append:
        stm     r6-r10,lr,(--sp)
        mov     r7,r0
        mov     r8,r1
        mov     r9,r2
        mov     r10,0                      /* strlen(name) */
1:      add     r0,r9,r10
        ldb     r0,(r0)
        cmp     r0,0
        beq     2f
        add     r10,1
        b       1b
2:      lea     r0,log_len
        ld      r6,(r0)
        add     r0,r6,r10
        add     r0,72
        mov     r1,LOG_MAX
        cmp     r0,r1
        bgt     9f                         /* full: drop the event rather than overflow */
        lea     r0,log_buf
        ld      r0,(r0)
        add     r6,r0                      /* cursor */
        mov     r0,r6
        mov     r1,r7
        bl      put_le32                   /* PCRIndex */
        add     r0,r6,4
        mov     r1,r8
        bl      put_le32                   /* EventType */
        add     r0,r6,8
        mov     r1,2
        bl      put_le32                   /* digests.count */
        mov     r1,0x04
        stb     r1,(r6+12)                 /* TPM_ALG_SHA1 */
        mov     r1,0
        stb     r1,(r6+13)
        add     r0,r6,14
        mov     r1,DIG1
        mov     r2,20
        bl      copy
        mov     r1,0x0b
        stb     r1,(r6+34)                 /* TPM_ALG_SHA256 */
        mov     r1,0
        stb     r1,(r6+35)
        add     r0,r6,36
        mov     r1,DIG256
        mov     r2,32
        bl      copy
        add     r0,r6,68
        mov     r1,r10
        bl      put_le32                   /* EventSize */
        add     r0,r6,72
        mov     r1,r9
        mov     r2,r10
        bl      copy                       /* Event = file name */
        lea     r0,log_len
        ld      r1,(r0)
        add     r1,r10
        add     r1,72
        st      r1,(r0)
9:      ldm     r6-r10,pc,(sp++)

/* copy the log to LOG_PHYS (zeroing the whole region once per boot) */
log_publish:
        stm     lr,(--sp)
        lea     r0,log_zeroed
        ld      r1,(r0)
        cmp     r1,0
        bne     1f
        mov     r1,1
        st      r1,(r0)
        mov     r0,LOG_SDRAM
        mov     r1,0
        mov     r2,LOG_AREA                /* log half only; stage-2 code lives in the upper half */
        bl      fill
1:      mov     r0,LOG_SDRAM
        mov     r1,LOGBUF
        lea     r2,log_len
        ld      r2,(r2)
        bl      copy
        lea     r0,log_len
        ld      r1,(r0)
        lea     r0,msg_log
        mov     r2,LOG_PHYS
        bl      say
        ldm     pc,(sp++)

/* put_le32(r0=ptr, r1=value), any alignment */
put_le32:
        stb     r1,(r0)
        lsr     r1,8
        stb     r1,(r0+1)
        lsr     r1,8
        stb     r1,(r0+2)
        lsr     r1,8
        stb     r1,(r0+3)
        rts

/* ---------------- data (in the file, so reset on every boot) ---------------- */
        .balign 4
started:
        .long   0
reset_done:
        .long   0                          /* .word is 16-bit in this assembler */
diag_done:
        .long   0                          /* .word is 16-bit in this assembler */
last_wait:
        .long   0
last_sts:
        .long   0
cmd_stage:
        .long   0
busy_us:
        .long   0
go_t0:
        .long   0
log_len:
        .long   0
log_zeroed:
        .long   0
log_buf:
        .long   LOGBUF
cur_evtype:
        .long   0
in_stage2:                                 /* 1 in the SDRAM copy that runs inside start.elf */
        .long   0
se_delta:                                  /* start.elf runtime - link address */
        .long   0
skip256:                                   /* 1 while start.elf computes SHA-256 */
        .long   0
w256_base:                                 /* SHA working arrays: L2 in stage 1; the copy switches to */
        .long   W256                       /* the L1+L2-cached alias (0x0...) for stage 2 */
w1_base:
        .long   W1                          /* .word is 16-bit in this assembler */
cmd_startup:                               /* TPM2_Startup(TPM_SU_CLEAR) */
        .byte   0x80,0x01, 0,0,0,0x0c, 0,0,0x01,0x44, 0,0
tmpl_ext:                                  /* TPM2_PCR_Extend(pcr, PW session, {sha1, sha256}) */
        .byte   0x80,0x02, 0,0,0,0x57, 0,0,0x01,0x82, 0,0,0,0
        .byte   0,0,0,9, 0x40,0,0,9,0,0,0,0,0
        .byte   0,0,0,2, 0,0x04
        .fill   20,1,0
        .byte   0,0x0b
        .fill   32,1,0
        .balign 4
iv256:
        .long   0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
iv1:
        .long   0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0
k256:
        .long   0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5
        .long   0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174
        .long   0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da
        .long   0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967
        .long   0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85
        .long   0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070
        .long   0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3
        .long   0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
se_entry_off:                              /* se_load_hook relative to this word */
        .long   se_load_hook - se_entry_off
se_orig:                                   /* expected start.elf bytes at link 0x0ed7a164 */
        .byte   0xc0,0x40, 0xfb,0x9f,0x9d,0x39, 0x00,0xe6,0x98,0x8e,0x17,0xc0, 0x00,0x80,0x2e,0xc0
se_dt_orig:                                /* expected start.elf bytes at link 0x0ed79e8e */
        .byte   0x25,0x60, 0xf5,0x34
se_dt_bl:                                  /* bl 0x0ed7a16c, encoded at 0x0ed79e8e */
        .byte   0x80,0x90,0x6f,0x01
log_hdr:                                   /* TCG_PCClientPCREvent + TCG_EfiSpecIDEvent, 69 bytes */
        .byte   0,0,0,0, 3,0,0,0           /* PCR 0, EV_NO_ACTION */
        .fill   20,1,0
        .byte   37,0,0,0                   /* event size */
        .ascii  "Spec ID Event03"
        .byte   0
        .byte   0,0,0,0, 0, 2, 0, 2        /* platformClass, version 2.0, errata 0, uintnSize UINT64 */
        .byte   2,0,0,0                    /* 2 algorithms */
        .byte   0x04,0, 20,0               /* sha1, 20 bytes */
        .byte   0x0b,0, 32,0               /* sha256, 32 bytes */
        .byte   0                          /* vendorInfoSize */
hexchars:
        .ascii  "0123456789abcdef"
msg_diag:
        .asciz  "TPM: DID_VID=%x ACCESS=%x STS=%x wait=%x\n"
msg_se_ok:
        .asciz  "TPM: start.elf hooks installed (load_file, final DT) -> %x\n"
msg_se_bad:
        .asciz  "TPM: start.elf bytes not as expected, hook NOT installed\n"
msg_dt_big:
        .asciz  "TPM: final DT too big (%d bytes), NOT measured"
name_final_dt:
        .asciz  "final-device-tree"
str_rng_seed:
        .asciz  "rng-seed"
str_kaslr_seed:
        .asciz  "kaslr-seed"
str_rsts:
        .asciz  "rsts"
msg_log:
        .asciz  "TPM: event log %d bytes at %x\n"
msg_reset:
        .asciz  "TPM: reset via GPIO%d\n"
msg_startup:
        .asciz  "TPM: Startup rc=%x\n"
msg_done:
        .asciz  "TPM: %s -> PCR%d, %d bytes\n"
msg_time:
        .asciz  "TPM:   %d us (hash %d us)\n"
msg_sha1:
        .asciz  "TPM:   PCR%d sha1   %s\n"
msg_sha256:
        .asciz  "TPM:   PCR%d sha256 %s\n"
msg_fail:
        .asciz  "TPM: %s NOT measured, rc=%x stage=%d sts=%x\n"
        .balign 4
payload_end:
