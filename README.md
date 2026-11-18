# Synology NAS drops off the network under load: patched al_eth driver for Annapurna Alpine models (DS1817, DS1517, DS1515, DS2015xs, DS715, RS1219)

If your Synology stops answering on the network after hours of heavy transfers (NFS, rsync, SMB, Hyper Backup) while the box itself is fine, this may be your problem.  The symptoms:

- DSM, SSH, SMB and ping all stop answering on one port, often after hours of sustained writes to the NAS
- the link light stays on and the switch still shows the port up
- the NAS doesn't answer ARP, and the switch sees no frames from it
- the status LED looks normal and a short press of the power button does a clean shutdown, so the OS isn't hung
- nothing at all in `/var/log/messages` or `kern.log`, no `NETDEV WATCHDOG`, no out-of-memory, no I/O errors
- it only comes back after a power cycle

This repo has Synology's own GPL source for the Ethernet driver these models use (`al_eth`, from Annapurna Labs), with fixes, built as a module you can load next to DSM's driver without flashing anything.  A reboot always puts the stock driver back.

Not affiliated with Synology.  Not a confirmed root cause yet, see Status.

## Affected models

Anything on Synology's `alpine` platform, i.e. an Annapurna Labs Alpine SoC (AL-212, AL-314, AL-514).  Per Synology's own board files that's the DS1515, DS1517, DS1817, DS2015xs, DS715 and RS1219, and the DS215+ and DS416 (the latter two may be on the separate `alpine4k` kernel build, which this module is not built for).

Check yours over SSH:

```
uname -a     # ... 3.10.108 #72806 ... armv7l GNU/Linux synology_alpine_ds1817
ethtool -i eth0 | head -2     # driver: al_eth
```

The module here is built for DSM 7.2-72806 (kernel `3.10.108 #72806`, `synology_alpine_*`).  Other DSM builds need a rebuild against their own source.

## What's wrong with the stock driver

Found by reading the source and two independent reviews, with help from FreeBSD's driver for the same hardware and the [awto-unvr](https://github.com/awtoau/awto-unvr) project's audit of it.

1. After each poll the driver re-enables the queue's interrupt with a relaxed register write right after `napi_complete()`, with no barrier between them.  If the hardware sees the re-enable before other CPUs see the poll is finished, the next interrupt is ignored and the queue's interrupt stays masked forever.  DSM runs `irqbalance`, so interrupts do move between CPUs.  Nothing in the driver notices or recovers.
2. The receive DMA waits forever for a free buffer by default, so one stuck queue blocks receive on all of them, ARP included.  That's how a single lost interrupt can take out the whole port.
3. The DMA error interrupt is masked after the first error and never re-enabled, and it only prints `got mgmt interrupt`.  Every later DMA error is silent.
4. The transmit timeout handler does nothing, not even log by default.
5. Unbinding a port from the driver frees its MDIO bus twice (kernel BUG or heap corruption).
6. Smaller ones: dropped packets aren't counted, a short receive refill busy-loops with unlimited warnings, a down/up loses multicast and promiscuous settings, the transmit completion count can be thrown away mid-packet, and every port shutdown fails to stop the receive DMA (`dma state didn't change to Disable ... error -110`).

## What this changes

- A write barrier before the interrupt is re-enabled (fixes 1).
- A 1 second watchdog.  A queue whose interrupt is masked, with no poll scheduled and no interrupt for two seconds, is logged (`rx queue N: interrupt masked with no poll pending; polling to recover`) and polled, which re-enables it.  So a lost interrupt costs a couple of seconds and a log line instead of the port.  It also checks the DMA error registers every second.
- DMA errors are read, cleared and logged with the port name every time, and the error interrupt is re-enabled.
- Optional automatic port reset after a DMA error or transmit timeout (`reset_on_error=1`, off by default, at most once per 10 s, restores link speed and multicast settings).
- `take=<pci address>` moves one running port from DSM's built-in driver to this one, safely (works around 5).
- `/sys/bus/pci/devices/<pci address>/fix_stats` shows per-queue interrupts, polls and stalls, DMA errors, resets and the interrupt mask registers.  `fix_reset` resets the port.  `fix_test_stall` masks a receive queue on purpose, to prove the watchdog recovers it.

Each change is its own commit on top of Synology's unmodified source, so `git log -p` shows exactly what differs.

## Status

Tested on one DS1817, DSM 7.2.2-72806 Update 10, on its LAN 3 port (2026-11-18): the module takes the port with the same MAC, link and address, the watchdog caught a simulated stuck queue within 2.4 s and recovered it, a port reset during a transfer kept the TCP connection going, and it has since been carrying sustained copies (8 million receive interrupts in the first half hour, no DMA errors, no real stalls).  Whether it prevents the original hang isn't proven yet, the hang took hours of load to show up.

If you try it, issues with your `fix_stats` and `dmesg` output are welcome, particularly any `interrupt masked with no poll pending` or `UDMA error` lines.

## Build

Needs Docker and about 1 GB of disk.  The script downloads Synology's kernel source for DSM 7.2-72806 (82 MB) and cross-compiles with Debian's `arm-linux-gnueabi` gcc 12, the same major version Synology uses.

```
git clone https://github.com/JayBeavers/synology-al_eth-network-hang-fix.git
cd synology-al_eth-network-hang-fix
./build.sh
```

The result is `build/al_eth_fix/al_eth_fix.ko`.  It should report `vermagic=3.10.108 SMP mod_unload ARMv7 p2v8`, the same as `/lib/modules/*.ko` on the NAS.

## Deploy

Pick the port you want on the fixed driver.  LAN 1 is `eth0` on most models.  Try it on a port you can afford to lose first, with another port cabled so you can still reach the NAS.

1. Copy the module and start script to the NAS, e.g. into a shared folder:

   ```
   scp build/al_eth_fix/al_eth_fix.ko deploy/al_eth_fix-start.sh admin@nas:/volume1/al_eth_fix/
   ```

2. Try it once by hand, as root (`sudo -i`):

   ```
   sh /volume1/al_eth_fix/al_eth_fix-start.sh eth2 /volume1/al_eth_fix/al_eth_fix.ko
   cat /var/log/al_eth_fix.log
   cat /sys/class/net/eth2/device/fix_stats
   ```

   `dmesg` will show `module verification failed: signature and/or required key missing - tainting kernel` once.  That's normal for any module Synology didn't sign.  DSM checks signatures but doesn't enforce them.

3. To make it stick: DSM, Control Panel, Task Scheduler, Create, Triggered Task, User-defined script.  User `root`, event `Boot-up`, command:

   ```
   sh /volume1/al_eth_fix/al_eth_fix-start.sh eth0 /volume1/al_eth_fix/al_eth_fix.ko
   ```

The start script waits for DSM to bring the port up, records its IPv4 addresses and routes, loads the module with `take=`, and puts the addresses and routes back on the new interface.  Its log is `/var/log/al_eth_fix.log`.  The trial above used the same steps by hand, the script itself is newer and hasn't had a boot test yet.

One port per module load.  To undo: reboot, or `rmmod al_eth_fix` and `echo <pci address> > /sys/bus/pci/drivers/al_eth/bind`.  A DSM update that changes the kernel needs a rebuild against its source.

Module options: `kick_ms` (watchdog interval, default 1000, 0 = off), `reset_on_error` (default 0), `take`.

## Credits

[awto-unvr](https://github.com/awtoau/awto-unvr), a mainline Linux port for the Alpine V2 based Ubiquiti UNVR, whose issue tracker is the best public write-up of this driver and pointed at most of what's here.  FreeBSD's `sys/dev/al_eth` and `sys/contrib/alpine-hal`, an independent driver for the same hardware.  Annapurna Labs and Synology for publishing the source.

## License

GPL-2.0, as published by Synology and Annapurna Labs.  See `COPYING`.
