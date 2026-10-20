/* Windows instrumented relink only (scripts/pgo-build.sh): on COFF the profile lowering pass
 * references the runtime's registration hook variable; no runtime is linked (profsnap.py reads
 * the counters out of the live process), so this stands in for it. */
int __llvm_profile_runtime = 0;
