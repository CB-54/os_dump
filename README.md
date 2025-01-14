# os_dump

dump.sh:
- Uploads server files (OS and other files) to the template storage (replace 1.1.1.1 with the IP address of the server storage, the same for the private and public SSH keys)

deploy.sh:
- Applies the OS templates from the storage server to the current server. Performs disc mapping (ext4, RAID, SWAP support), starts the next chroot script

chroot.sh:
- Reinstalls and configures grub for EFI and Legacy boot, executes post-installation scripts (IP replication, GW, etc.)

include.sh:
- Functions for the previous scripts
