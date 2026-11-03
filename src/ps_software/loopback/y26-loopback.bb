SUMMARY = "Y26 DMA loopback verification application"
LICENSE = "CLOSED"

SRC_URI = "file://loopback_test.c file://y26_dma_uapi.h"
S = "${WORKDIR}"
inherit deploy

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -std=c11 -Wall -Wextra -Werror \
        loopback_test.c -o y26-loopback
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 y26-loopback ${D}${bindir}/y26-loopback
}

do_deploy() {
    install -m 0755 ${S}/y26-loopback ${DEPLOYDIR}/y26-loopback
}
addtask deploy after do_compile before do_build
