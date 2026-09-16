# CachyOS bootc — developer/agent entry points.
#
# Keep targets thin: they delegate to scripts under hack/ and tests/.
# All targets must be safe to run repeatedly.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

IMAGE ?= localhost:5000/cachyos-bootc:test
REGISTRY ?= localhost:5000
# Image references used by the VM workflow (the guest pulls from the libvirt bridge IP).
VM_IMAGE ?= 192.168.122.1:5000/cachyos-bootc:test
VM_IMAGE_V1 ?= 192.168.122.1:5000/cachyos-bootc:v1
VM_IMAGE_V2 ?= 192.168.122.1:5000/cachyos-bootc:v2
# Extra args forwarded to tests/vm/run.sh (e.g. RUN_ARGS=--keep).
RUN_ARGS ?=

.PHONY: help
help:
	@echo "CachyOS bootc targets:"
	@echo "  make build      Build the CachyOS bootc OCI image ($(IMAGE))"
	@echo "  make lint       Run bootc container lint and static checks"
	@echo "  make test       Full disposable-VM workflow (install, boot, smoke test)"
	@echo "  make vm-install Install into a disposable VM (kept for inspection)"
	@echo "  make vm-update  Install v1, boot, update to v2, verify"
	@echo "  make vm-rollback Install v1, update to v2, roll back to v1, verify"
	@echo "  make image-v1 / image-v2   Build versioned images for update/rollback tests"
	@echo "  make image-test Fast image-level tests (no VM)"
	@echo "  make registry-start/stop/status   Manage the local OCI registry"
	@echo "  make registry-push                Build and push the image to the registry"
	@echo "  make installer                    Build the installer live ISO"
	@echo "  make vm-shell   Open a shell/console on a running test VM"
	@echo "  make clean      Remove local build and test artifacts"
	@echo ""
	@echo "Variables: IMAGE=$(IMAGE) REGISTRY=$(REGISTRY)"

.PHONY: build
build:
	@IMAGE="$(IMAGE)" hack/build.sh

.PHONY: lint
lint: build
	@hack/lint.sh
	@echo "==> bootc container lint"
	@podman run --rm "$(IMAGE)" bootc container lint --fatal-warnings --skip runtime-deps

.PHONY: test
# Full disposable-VM workflow: install -> boot -> smoke test.
test:
	@IMAGE="$(VM_IMAGE)" tests/vm/run.sh $(RUN_ARGS)

.PHONY: vm-install
vm-install:
	@VM_IMAGE_REF="$(VM_IMAGE)" tests/vm/install.sh --keep $(RUN_ARGS)

.PHONY: vm-update
# Install v1, boot, then update to v2 and verify (Tasks 20).
vm-update:
	@IMAGE="$(VM_IMAGE_V1)" tests/vm/run.sh --update --to "$(VM_IMAGE_V2)" $(RUN_ARGS)

.PHONY: vm-rollback
# Install v1, boot, update to v2, then roll back to v1 (Tasks 20+21).
vm-rollback:
	@IMAGE="$(VM_IMAGE_V1)" tests/vm/run.sh --update --to "$(VM_IMAGE_V2)" --rollback $(RUN_ARGS)

.PHONY: image-test
image-test:
	@IMAGE="$(IMAGE)" tests/image/test-image.sh

.PHONY: image-v1 image-v2
# Build distinguishable images for update/rollback testing.
image-v1:
	@podman build --build-arg IMAGE_VERSION=1 --tag localhost:5000/cachyos-bootc:v1 -f Containerfile .
image-v2:
	@podman build --build-arg IMAGE_VERSION=2 --tag localhost:5000/cachyos-bootc:v2 -f Containerfile .

.PHONY: registry-start
registry-start:
	@REGISTRY_PORT=$(REGISTRY_PORT) hack/registry.sh start

.PHONY: registry-stop
registry-stop:
	@hack/registry.sh stop

.PHONY: registry-status
registry-status:
	@hack/registry.sh status

.PHONY: registry-push
registry-push: build registry-start
	@hack/registry.sh push "$(IMAGE)"

.PHONY: installer
installer:
	@INSTALLER_IMAGE=$(INSTALLER_IMAGE) hack/build-installer.sh

.PHONY: vm-shell
# Open an interactive SSH session on a running, installed test VM.
#   make vm-shell VM=cachyos-bootc-test-<id>
# Without VM it picks the single running cachyos-bootc-test-* domain, if there is one.
vm-shell:
	@hack/vm-shell.sh "$(VM)"

.PHONY: clean
clean:
	@hack/clean.sh
