# Fusion OS

Fusion is a hobby operating system for x86-64 implemented in [Nim](https://nim-lang.org). I'm documenting
the process of building it at: [https://0xc0ffee.netlify.app](https://0xc0ffee.netlify.app).

## Screenshots

**UEFI Bootloader**

![UEFI Bootloader](screenshots/bootloader.png)

**GUI** (_Note: This screenshot is from the `graphics` branch, which is still a work-in-progress._)

![Screenshot from the graphics branch](screenshots/graphics.png)

**Booting and Running the Kernel**

![Booting and Running Fusion Kernel](screenshots/kernel-booting.png)

## Features

The following features are currently implemented:

- UEFI Bootloader
- Memory Management
  - Single Address Space (Higher Half Kernel)
  - Physical Memory Manager
  - Virtual Memory Manager
  - Demand Paging
- Task Management
  - Kernel Tasks
  - User Mode Tasks
  - Preemptive Multitasking
  - Priority-based Scheduling
  - ELF Loader (Demand Paged, Relocation)
- System Calls
  - System Call Interface
  - User Mode Library
- IPC
  - Channel-based IPC
  - Message Passing
- Hardware
  - PCI Device Enumeration
  - ACPI Configuration
  - Local APIC Timer
  - I/O APIC Interrupts
  - PS/2 Keyboard Driver
  - PS/2 Mouse Driver
  - Bochs Graphics Adapter Driver
- Window Management
  - FusionWM Window Manager

#### Planned

- Capability-based Security
- Event-based Task State Machines
- Disk I/O
- File System
- Shell
- GUI
- Networking

## Building

To build Fusion, you need to have the following dependencies installed:

- [Nim](https://nim-lang.org) (>= 2.2.0)
- [LLVM](https://llvm.org) (clang and lld)
- [Just](https://github.com/casey/just)

The `clang` and `lld` binaries should be in your `PATH`. You can edit the `.env` file to specify the path to the `clang` and `lld` binaries if they are not in your `PATH`.

Build Fusion with the following command:

```sh
just build
```

## Running

Fusion currently runs on [QEMU](https://www.qemu.org), so you'll need to install it first. The required
OVMF (UEFI firmware) images are included in the `ovmf/` directory. Launch Fusion with the following command:

```sh
just run
```

Additional QEMU arguments can be passed through `just run`, e.g.:

```sh
just run -smp 4
```

## Repository Layout

- `src/boot` — UEFI bootloader (`bootx64.efi`)
- `src/kernel` — the kernel, including drivers, memory management, scheduling, and FusionWM
- `src/user` — user-space programs (e.g. the shell task)
- `src/syslib` — user-mode system library (syscalls, channels, I/O)
- `src/common` — code shared between the bootloader, kernel, and user space
- `justfile` — build and run recipes (`build`, `run`, `clean`, ...)

## License

MIT
