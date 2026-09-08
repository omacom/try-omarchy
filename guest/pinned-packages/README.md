# Reviewed ABI package pins

Recipes here are factory-build inputs for packages Arch Linux ARM no longer
publishes at the SONAME the locked Hyprland stack still requires.

`aquamarine/PKGBUILD` is the Arch `0.14.0-2` packaging (commit pinned in
`guest/spec.json`). The factory rebuilds it from the reviewed upstream tarball,
serves the result only through the disposable `[try-omarchy-abi-pins]` builder
repository, and must not copy that repository into the finished guest. The guest
holds matching runtime packages on `IgnorePkg` instead.
