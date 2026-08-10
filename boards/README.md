# Board profiles
#
# Each file under this directory describes one product board. Select it at
# build time with:
#
#   make BOARD=axon-mini rootfs.tar
#   make BOARD=axon-mini disk-ufs.img
#
# With no BOARD= set, recipes use generic Qualcomm Linux defaults (debian
# user, stock linux-image-arm64, no product overlay).
#
# Required keys: name, hostname, username, password
# Optional: root_password, overlays, xfcedesktop, vnc, kernel, image, packages, ci
#
# To add a board:
#   1. Copy axon-mini.yaml → boards/<name>.yaml and edit values
#   2. Add debos-recipes/overlays/vicharak-<name>/ for branding/APT as needed
#   3. Add flash entry in qualcomm-linux-debian-flash.yaml if required
