# CachyOS bootc — build the image, boot it in a bcvk libvirt VM, and ssh in.
#
#   just    podman build -> bcvk libvirt run (install + boot) -> bcvk libvirt ssh
#
# Override via environment: IMAGE, VM, BCVK_CONNECT, DISK_SIZE, FIRMWARE, DISABLE_TPM.
#
# The VM name defaults to a random `rogue-os-test-<uuid>` so a run never replaces a VM it
# did not create. Override VM= to reuse a fixed name (then `--replace` targets that name).
# Remove a finished VM with `bcvk libvirt rm <name>`.
#
# Note: the install (bcvk to-disk) intermittently fails with
# "Finalizing filesystem root: mount point is busy"; just re-run `just`.

image       := env("IMAGE", "localhost/rogue:latest")
vm          := env("VM", "rogue-os-test-" + uuid())
connect     := env("BCVK_CONNECT", "qemu:///session")
disk_size   := env("DISK_SIZE", "24G")
firmware    := env("FIRMWARE", "uefi-insecure")
disable_tpm := env("DISABLE_TPM", "true")

# build the image, install + boot a libvirt VM, then ssh in
default:
    podman build -t {{image}} --build-arg TEST_PKGS=bubblewrap -f Containerfile .
    bcvk libvirt -c {{connect}} run \
        --composefs-backend \
        --firmware {{firmware}} \
        {{ if disable_tpm == "true" { "--disable-tpm" } else { "" } }} \
        --name {{vm}} \
        --disk-size {{disk_size}} \
        --detach --ssh-wait --replace \
        {{image}}
    bcvk libvirt -c {{connect}} ssh {{vm}}
