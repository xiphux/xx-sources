# Copyright 1999-2004 Gentoo Technologies, Inc.
# Distributed under the terms of the GNU General Public License v2
# $Header: $

K_PREPATCHED="yes"

ETYPE="sources"
inherit kernel-2
detect_version

K_NOSETEXTRAVERSION="don't_set_it"
RESTRICT="nomirror"

DESCRIPTION="2.6 Linux kernel patched with Reiser4, CFQ, Nick's Scheduler, Bootsplash and various other bleeding edge goodies"
HOMEPAGE="http://sourceforge.net/projects/xx-sources/"
SRC_URI="${KERNEL_URI} mirror://sourceforge/xx-sources/${PN}-${KV}.patch.bz2"

RDEPEND=">=sys-fs/reiser4progs-1.0.0"
KEYWORDS="-* ~x86 ~amd64 ~ia64 ~alpha"
IUSE=""

src_unpack() {
	cd ${WORKDIR}
	unpack linux-${OKV}.tar.bz2

	mv linux-${OKV} linux-${KV}
	cd ${S}
	bzip2 -dc ${DISTDIR}/${PN}-${KV}.patch.bz2 | patch -p1
	find . -iname "*~" | xargs rm 2> /dev/null

	MY_ARCH=${ARCH}
	unset ARCH
	make mrproper || die "make mrproper died"
	ARCH=${MY_ARCH}
}

K_EXTRAEWARN="IMPORTANT: This is an experimental patch set. Use at your own risk!"