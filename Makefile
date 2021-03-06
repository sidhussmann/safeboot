VERSION ?= 0.8

BINS += bin/sbsign.safeboot
BINS += bin/sign-efi-sig-list.safeboot
BINS += bin/tpm2-totp
BINS += bin/tpm2

all: $(BINS) update-certs

#
# sbsign needs to be built from a patched version to avoid a
# segfault when using the PKCS11 engine to talk to the Yubikey.
#
SUBMODULES += sbsigntools
bin/sbsign.safeboot: sbsigntools/Makefile
	$(MAKE) -C $(dir $<)
	mkdir -p $(dir $@)
	cp $(dir $<)src/sbsign $@
sbsigntools/Makefile: sbsigntools/autogen.sh
	cd $(dir $@) ; ./autogen.sh && ./configure
sbsigntools/autogen.sh:
	git submodule update --init --recursive --recommend-shallow sbsigntools

#
# sign-efi-sig-list needs to be built from source to have support for
# the PKCS11 engine to talk to the Yubikey.
#
SUBMODULES += efitools
bin/sign-efi-sig-list.safeboot: efitools/Makefile
	$(MAKE) -C $(dir $<) sign-efi-sig-list
	mkdir -p $(dir $@)
	cp $(dir $<)sign-efi-sig-list $@
efitools/Makefile:
	git submodule update --init --recursive --recommend-shallow efitools

#
# tpm2-tss is the library used by tpm2-tools
#
SUBMODULES += tpm2-tss

libtss2-mu = tpm2-tss/src/tss2-mu/.libs/libtss2-mu.a
libtss2-rc = tpm2-tss/src/tss2-rc/.libs/libtss2-rc.a
libtss2-sys = tpm2-tss/src/tss2-sys/.libs/libtss2-sys.a
libtss2-esys = tpm2-tss/src/tss2-esys/.libs/libtss2-esys.a
libtss2-tcti = tpm2-tss/src/tss2-tcti/.libs/libtss2-tctildr.a

$(libtss2-esys): tpm2-tss/Makefile
	$(MAKE) -C $(dir $<)
	mkdir -p $(dir $@)
tpm2-tss/Makefile:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
	cd $(dir $@) ; ./bootstrap && ./configure \
		--disable-doxygen-doc \

#
# tpm2-tools is the head after bundling and ecc support built in
#
SUBMODULES += tpm2-tools

tpm2-tools/tools/tpm2: tpm2-tools/Makefile
	$(MAKE) -C $(dir $<)

bin/tpm2: tpm2-tools/tools/tpm2
	cp $< $@

tpm2-tools/Makefile: $(libtss2-esys)
	git submodule update --init --recursive --recommend-shallow $(dir $@)
	cd $(dir $@) ; ./bootstrap \
	&& ./configure \
		TSS2_RC_CFLAGS=-I../tpm2-tss/include \
		TSS2_RC_LIBS="../$(libtss2-rc)" \
		TSS2_MU_CFLAGS=-I../tpm2-tss/include \
		TSS2_MU_LIBS="../$(libtss2-mu)" \
		TSS2_SYS_CFLAGS=-I../tpm2-tss/include \
		TSS2_SYS_LIBS="../$(libtss2-sys)" \
		TSS2_TCTI_CFLAGS=-I../tpm2-tss/include \
		TSS2_TCTI_LIBS="../$(libtss2-tcti)" \
		TSS2_ESYS_3_0_CFLAGS=-I../tpm2-tss/include \
		TSS2_ESYS_3_0_LIBS="../$(libtss2-esys) -ldl" \




#
# tpm2-totp is build from a branch with hostname support
#
SUBMODULES += tpm2-totp
bin/tpm2-totp: tpm2-totp/Makefile
	$(MAKE) -C $(dir $<)
	mkdir -p $(dir $@)
	cp $(dir $<)/tpm2-totp $@
tpm2-totp/Makefile:
	git submodule update --init --recursive --recommend-shallow tpm2-totp
	cd $(dir $@) ; ./bootstrap && ./configure

#
# swtpm and libtpms are used for simulating the qemu tpm2
#
SUBMODULES += libtpms
libtpms/Makefile:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
	cd $(dir $@) ; ./autogen.sh --with-openssl --with-tpm2
libtpms/src/.libs/libtpm2.a: libtpms/Makefile
	$(MAKE) -C $(dir $<)

SUBMODULES += swtpm
SWTPM=swtpm/src/swtpm/swtpm
swtpm/Makefile: libtpms/src/.libs/libtpm2.a
	git submodule update --init --recursive --recommend-shallow $(dir $@)
	cd $(dir $@) ; \
		LIBTPMS_LIBS="-L`pwd`/../libtpms/src/.libs -ltpms" \
		LIBTPMS_CFLAGS="-I`pwd`/../libtpms/include" \
		./autogen.sh \

$(SWTPM): swtpm/Makefile
	$(MAKE) -C $(dir $<)




#
# Extra package building requirements
#
requirements:
	DEBIAN_FRONTEND=noninteractive \
	apt install -y \
		devscripts \
		debhelper \
		libqrencode-dev \
		libtss2-dev \
		efitools \
		gnu-efi \
		opensc \
		yubico-piv-tool \
		libengine-pkcs11-openssl \
		build-essential \
		binutils-dev \
		git \
		pkg-config \
		automake \
		autoconf \
		autoconf-archive \
		initramfs-tools \
		help2man \
		libssl-dev \
		uuid-dev \
		shellcheck \
		curl \
		libjson-c-dev \
		libcurl4-openssl-dev \
		expect \
		socat \
		libseccomp-dev \
		seccomp \
		gnutls-bin \
		libgnutls28-dev \
		libtasn1-6-dev \


# Remove the temporary files
clean:
	rm -rf bin $(SUBMODULES)
	mkdir $(SUBMODULES)
	#git submodule update --init --recursive --recommend-shallow 

# Regenerate the source file
tar: clean
	tar zcvf ../safeboot_$(VERSION).orig.tar.gz \
		--exclude .git \
		--exclude debian \
		.

package: tar
	debuild -uc -us
	cp ../safeboot_$(VERSION)_amd64.deb safeboot-unstable.deb


# Run shellcheck on the scripts
shellcheck:
	for file in \
		sbin/safeboot* \
		sbin/tpm2-attest \
		initramfs/*/* \
		functions.sh \
	; do \
		shellcheck $$file ; \
	done

# Fetch several of the TPM certs and make them usable
# by the openssl verify tool.
# CAB file from Microsoft has all the TPM certs in DER
# format.  openssl x509 -inform DER -in file.crt -out file.pem
# https://docs.microsoft.com/en-us/windows-server/security/guarded-fabric-shielded-vm/guarded-fabric-install-trusted-tpm-root-certificates
# However, the STM certs in the cab are corrupted? so fetch them
# separately
update-certs:
	#./refresh-certs
	c_rehash certs

# Fake an overlay mount to replace files in /etc/safeboot with these
fake-mount:
	mount --bind `pwd`/safeboot.conf /etc/safeboot/safeboot.conf
	mount --bind `pwd`/functions.sh /etc/safeboot/functions.sh
	mount --bind `pwd`/sbin/safeboot /sbin/safeboot
	mount --bind `pwd`/sbin/safeboot-tpm-unseal /sbin/safeboot-tpm-unseal
	mount --bind `pwd`/sbin/tpm2-attest /sbin/tpm2-attest
	mount --bind `pwd`/initramfs/scripts/safeboot-bootmode /etc/initramfs-tools/scripts/init-top/safeboot-bootmode
fake-unmount:
	mount | awk '/safeboot/ { print $$3 }' | xargs umount


#
# Build a safeboot initrd.cpio
#
build/initrd/gitstatus: initramfs/files.txt
	rm -rf "$(dir $@)"
	mkdir -p "$(dir $@)"
	./sbin/populate "$(dir $@)" "$<"
	git status -s > "$@"

build/initrd.cpio: build/initrd/gitstatus
	( cd $(dir $<) ; \
		find . -print0 \
		| cpio \
			-0 \
			-o \
			-H newc \
	) \
	| ./sbin/cpio-clean \
		initramfs/dev.cpio \
		- \
	> $@
	sha256sum $@

build/initrd.cpio.xz: build/initrd.cpio
	xz \
		--check=crc32 \
		--lzma2=dict=1MiB \
		--threads 0 \
		< "$<" \
	| dd bs=512 conv=sync status=none > "$@.tmp"
	@if ! cmp --quiet "$@.tmp" "$@" ; then \
		mv "$@.tmp" "$@" ; \
	else \
		echo "$@: unchanged" ; \
		rm "$@.tmp" ; \
	fi
	sha256sum $@


BOOTX64=build/boot/EFI/BOOT/BOOTX64.EFI
$(BOOTX64): build/initrd.cpio.xz build/vmlinuz initramfs/cmdline.txt
	mkdir -p "$(dir $@)"
	DIR=. \
	./sbin/safeboot unify-kernel \
		"/tmp/kernel.tmp" \
		linux=build/vmlinuz \
		initrd=build/initrd.cpio.xz \
		cmdline=initramfs/cmdline.txt \

	DIR=. \
	./sbin/safeboot sign-kernel \
		"/tmp/kernel.tmp" \
		"$@"

	sha256sum "$@"

build/boot/PK.auth: signing.crt
	-./sbin/safeboot uefi-sign-keys
	cp signing.crt PK.auth KEK.auth db.auth "$(dir $@)"

build/esp.bin: $(BOOTX64) build/boot/PK.auth
	./sbin/mkfat "$@" build/boot

build/hda.bin: build/esp.bin build/luks.bin
	./sbin/mkgpt "$@" $^

build/key.bin:
	echo -n "abcd1234" > "$@"

build/luks.bin: build/key.bin
	fallocate -l 512M "$@.tmp"
	cryptsetup \
		-y luksFormat \
		--pbkdf pbkdf2 \
		"$@.tmp" \
		"build/key.bin"
	cryptsetup luksOpen \
		--key-file "build/key.bin" \
		"$@.tmp" \
		test-luks
	#mkfs.ext4 /dev/mapper/test-luks
	cat root.squashfs > /dev/mapper/test-luks
	cryptsetup luksClose test-luks
	mv "$@.tmp" "$@"

TPMSTATE=build/vtpm/tpm2-00.permall
$(TPMSTATE): $(SWTPM)
	mkdir -p build/vtpm
	PATH=$(dir $(SWTPM)):$(PATH) \
	echo swtpm/src/swtpm_setup/swtpm_setup \
		--tpm2 \
		--createek \
		--tpmstate "$(dir $@)" \
		--config /dev/null \

# uefi firmware from https://packages.debian.org/buster-backports/all/ovmf/download
qemu: build/hda.bin $(SWTPM) $(TPMSTATE)
	$(SWTPM) socket \
		--tpm2 \
		--tpmstate dir="$(dir $(TPMSTATE))" \
		--ctrl type=unixio,path="$(dir $(TPMSTATE))sock" &

	#cp /usr/share/OVMF/OVMF_VARS.fd build

	-qemu-system-x86_64 \
		-M q35,accel=kvm \
		-m 4G \
		-drive if=pflash,format=raw,readonly,file=/usr/share/OVMF/OVMF_CODE.fd \
		-drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
		-serial stdio \
		-netdev user,id=eth0 \
		-device e1000,netdev=eth0 \
		-chardev socket,id=chrtpm,path="$(dir $(TPMSTATE))sock" \
		-tpmdev emulator,id=tpm0,chardev=chrtpm \
		-device tpm-tis,tpmdev=tpm0 \
		-drive "file=$<,format=raw" \
		-boot c \

	stty sane


