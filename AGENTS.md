Purpose

This repository is developed by an autonomous coding agent.

These instructions define how the agent must work. They are persistent project instructions and apply to every task in this repository.

The project-specific objective is provided separately in the initial task prompt.

1. Working Environment

The agent runs inside a Distrobox container.

The physical/outer host is a Linux system with:

KVM available;

QEMU available on the host;

libvirt available on the host;

access to the host's virtualization infrastructure from inside the Distrobox.

Do not assume that the Distrobox is itself a normal standalone host.

In particular, verify how the Distrobox accesses:

/dev/kvm;

libvirt;

virsh;

virt-install;

QEMU;

the host/libvirt network;

any required libvirt UNIX sockets.

The Distrobox is the development/agent environment.

The libvirt/QEMU VM is the test environment.

Keep those concepts separate.

Do not attempt to install a second virtualization stack inside the Distrobox unless the project explicitly requires it.

Prefer using the host's KVM/libvirt infrastructure through the existing Distrobox integration.

2. Work Sequentially

Work on one task at a time.

Do not implement multiple unrelated tasks simultaneously.

Before starting work:

Identify the task from the request and the project documentation.

Read the relevant source code and documentation.

Determine what "done" means for that task.

Implement only the work necessary for that task.

After completing the task:

Run the relevant verification/tests.

Fix failures related to the current task.

Record important discoveries.

Select the next task.

Never mark a task complete without verification.

3. Task Tracking

There is no task file. Keep the current task and the remaining work clear in the
conversation, work on one task at a time, and do not silently expand scope. If work reveals
a new task, note it and continue with the current task.

4. Stay Focused

Do not lose focus on the current task.

If you discover an unrelated improvement, note it and continue with the current task.

Examples:

unrelated refactoring;

cosmetic improvements;

additional storage backends;

additional architectures;

unrelated dependency upgrades;

CI/CD improvements;

performance optimizations;

extra documentation.

Do not switch tasks merely because another task looks easier or more interesting.

5. Verify Everything

Prefer evidence over assumptions.

When implementing functionality:

Read current documentation/source where appropriate.

Implement the smallest useful change.

Run it.

Inspect the result.

Fix problems.

Repeat until the current task is genuinely complete.

Do not assume that old blog posts, tutorials, cached knowledge, or remembered CLI syntax are still correct.

For tools such as bootc, CachyOS, libvirt, Podman, systemd, and QEMU, prefer current upstream documentation and source code.

6. Research Efficiently

Research only what is necessary to unblock or correctly implement the current task.

Use this priority:

Current upstream documentation.

Current upstream source code.

Current official project examples.

Relevant reference implementations.

Other sources only when necessary.

Do not spend excessive time researching when a small experiment can answer the question more reliably.

When behavior is uncertain, create a minimal experiment.

Document important architectural discoveries in the project documentation (README.md).

7. Preserve the Intended Architecture

Do not replace an explicit project requirement with an easier alternative without first establishing that the original approach is impossible.

If a requirement appears problematic:

investigate it;

verify the limitation;

record the finding;

determine whether there is a compatible alternative.

Do not silently change the architecture.

The intended architecture for this project is fixed and recorded here. In particular:

- the CachyOS bootc image uses the composefs backend;
- it boots via systemd-boot with a Unified Kernel Image (UKI);
- the image is sealed (fs-verity enforced);
- Secure Boot is always on: the build requires the `db_key` and `pcr_key` BuildKit secrets,
  signs the UKI and `systemd-boot`, and embeds TPM2 PCR policy material; the public db
  certificate and PCR public key live in `build/secureboot/`, and the PK/KEK/db enrollment
  files live in `root/usr/lib/bootc/install/secureboot-keys/auto/` (only public
  certificates);
- bootupd must not be present in the image (its presence would select the GRUB/bootupd path instead of systemd-boot).

Changing any of these requires the same investigate -> verify -> record process, and an explicit documentation update. Do not change them silently.

8. Keep Changes Small

Prefer small, understandable changes over large rewrites.

A task should ideally result in a coherent, reviewable change.

Avoid introducing abstractions before they are necessary.

Do not build elaborate frameworks around simple shell commands unless the complexity is justified.

9. Dependencies

Prefer existing host/system tooling when appropriate.

Do not add a dependency merely because it makes one small operation more convenient.

When adding a dependency:

understand why it is needed;

document it;

verify that it is available in the intended Distrobox environment;

avoid unnecessary coupling.

Remember that installing a package inside the Distrobox does not necessarily install it on the host.

10. Shell Scripts

Shell scripts must:

fail on errors;

avoid silently ignoring failures;

quote variables appropriately;

clean up temporary resources;

provide useful error messages.

For Bash scripts, normally use:

set -euo pipefail


Use cleanup traps where resources such as VMs, disks, temporary directories, mounts, or credentials are created.

11. Disposable Resources

Anything created by automated tests should be disposable.

Examples:

libvirt VMs;

virtual disks;

temporary SSH keys;

temporary registry state;

temporary directories;

mounts.

Tests must clean up after themselves even when they fail.

Use traps or equivalent mechanisms.

Never destroy resources that do not belong to the current test run.

12. Failure Diagnostics

A failure should provide enough information to diagnose it.

When an integration test fails, collect useful information before destroying the environment.

Depending on the failure, this may include:

VM state;

libvirt XML;

networking information;

serial console output;

system journal;

systemctl --failed;

bootc status;

dmesg;

SSH diagnostics;

bootc install logs.

Preserve failure artifacts where useful.

A failed test should not simply end with:

command failed


when substantially better diagnostic information is available.

13. Do Not Hide Failures

Do not use constructs that turn meaningful failures into apparent success.

Avoid:

command || true


unless ignoring the failure is deliberate and documented.

Avoid arbitrary sleeps as a substitute for readiness detection.

Prefer polling with explicit timeouts.

14. VM Ownership and Safety

The test harness must only operate on VMs/resources that it created.

Use unique names, for example:

rogue-os-test-<random-id>


Before destroying a VM, verify that it belongs to the current test run.

Never use broad cleanup commands that could destroy unrelated user VMs.

15. Documentation

Keep documentation synchronized with the implementation.

Use `README.md` and `INSTALL.md` where appropriate.

Do not document functionality that does not exist.

Do not spend significant time writing documentation for an implementation that has not yet been validated.

16. Existing Code

Before modifying an existing file:

read it;

understand its purpose;

understand how it is used;

make the smallest appropriate change.

Do not replace working implementation simply because you would personally structure it differently.

17. External Reference Implementations

Reference repositories may be inspected and used to understand implementation details.

Copying/adapting code is acceptable when the project's requirements permit it.

When copying code:

preserve applicable licensing requirements;

retain attribution where appropriate;

understand the code rather than blindly copying it;

adapt it to the current project rather than introducing unnecessary dependencies.

The primary reference for the image build is the bootcrew/mono repository (arch/Containerfile and shared/), the maintained successor to bootcrew/arch-bootc. Implementation lives in Container.server.

18. Current Task Discipline

At all times, the agent should be able to answer:

What task am I currently working on?

and:

What evidence will allow me to mark this task complete?

If either answer is unclear, stop implementation and clarify the task through the project documentation.

19. Definition of Done

A task is done only when:

the implementation exists;

relevant tests/checks have been run;

failures have been resolved or explicitly documented as blockers;

the result matches the intended architecture;

the documentation is synchronized.

Do not use "probably works" as completion criteria.

20. Final Rule

One task at a time.

Understand it.

Implement it.

Test it.

Fix it.

Record it.

Then move to the next task.
