# install-nixos

A Nix flake that provides a one-shot installer for deploying NixOS systems with a flake-based configuration layout.

## What it does

This installer automates the process of:
- Partitioning and formatting a target disk (GPT + UEFI)
- Creating a 500 MiB ESP boot partition and an ext4 root partition
- Generating hardware configuration
- Copying your existing flake-based NixOS configuration to the new system
- Installing NixOS using a flake output (`#hostname`)

## Requirements & Conditions

### ✅ When this installer works

1. **UEFI firmware** – Creates a GPT partition table with an EFI System Partition
2. **x86_64-linux or aarch64-linux** architecture
3. **Flake-based source configuration** in `/etc/nixos/` with:
   - A `flake.nix` at the root
   - A `hosts/` directory structure (recommended)
   - A `hosts/template/` directory with `default.nix` and `users.nix` (optional, will be copied if present)
4. **Running from a NixOS environment** (typically a live ISO) that has:
   - Nix with flakes enabled
   - Root access
   - An existing `/etc/nixos` with your flake configuration

### ❌ Limitations

- **BIOS/legacy boot** – Not supported (UEFI only)
- **Encryption (LUKS)** – Not included in partition layout
- **LVM, RAID, ZFS, btrfs** – Only ext4 root is created
- **Non-flake configurations** – Fallback exists but may fail due to removed `configuration.nix`
- **Dual-boot setups** – Entire disk is wiped; use manual partitioning instead

## Usage

### From your flake-configured NixOS system or live ISO:

```bash
# Run directly via flake
nix run github:yourusername/install-nixos
```

Or clone and run locally:

```bash
git clone https://github.com/yourusername/install-nixos.git
cd install-nixos
nix run
```

### Interactive workflow

The script will:
1. Ask for a new hostname (e.g., `pronix`)
2. List available disks (excluding the current system disk)
3. Show a summary and ask for confirmation before wiping
4. Partition, format, and install NixOS
5. Configure the system using your flake's `#hostname` output

### Example session

```
Choose a name for your new system (example: pronix):
New host name: workstation

Available disks:
  IDX  DEVICE       MODEL                            SIZE(GB)
  [0]  sda          Samsung SSD 860                  500.0
  [1]  nvme0n1      WD Black SN850                   1000.2

Enter the index of the disk to use: 1

Summary before wiping:
  Hostname:           workstation
  Target disk:        /dev/nvme0n1
  Model:              WD Black SN850
  Capacity (GB):      1000.2
  Mounted partitions: none
ALL DATA on /dev/nvme0n1 WILL BE ERASED. Is this correct? [y/N] y

[... installation proceeds ...]
```

## How it works

1. **Flake packaging** – The shell script is wrapped in a `writeShellApplication` with all required tools (parted, rsync, mkfs.*, nixos-install-tools, etc.)
2. **Safety checks** – Validates that `/mnt` is clean, detects the current system disk, requires explicit confirmation
3. **Configuration structure** – Creates `hosts/<hostname>/` and moves `hardware-configuration.nix` there, optionally copying template files
4. **Flake installation** – Runs `nixos-install --flake /mnt/etc/nixos#<hostname>`

## Expected flake structure

Your source `/etc/nixos/flake.nix` should expose NixOS configurations as outputs:

```nix
{
  outputs = { self, nixpkgs }: {
    nixosConfigurations = {
      # The installer will look for an output matching the hostname
      workstation = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/workstation/default.nix
          ./hosts/workstation/hardware-configuration.nix
        ];
      };
    };
  };
}
```

## Logs

All output is logged to `/var/log/nixos-installer.log` (or `/tmp/nixos-installer.log` if `/var/log` is not writable).

## Warnings

- **THIS WILL ERASE THE ENTIRE TARGET DISK** – Review the summary carefully before confirming
- **Not suitable for dual-boot** – The entire disk is reformatted
- **Backup your data** before running on production machines
- **Test in a VM first** if you're uncertain

## License

MIT (or specify your license)

