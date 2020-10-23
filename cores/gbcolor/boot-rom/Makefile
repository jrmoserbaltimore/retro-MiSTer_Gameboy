

rgbchimem_obj := \
	retro-gbc-boot-highmem.o \
	retro-gbc-mapper-setup.o \
	retro-gbc-draw-logo.o

rgbcbootrom_obj := \
	retro-gbc-boot-rom.o

all: retro-gbc-boot-highmem.img retro-gbc-boot-rom.img

%.o : %.asm
	rgbasm $< -o $@ -v -Weverything

retro-gbc-boot-highmem.img: ${rgbchimem_obj}
	rgblink $^ -o $@ -v -x

retro-gbc-boot-rom.img: ${rgbcbootrom_obj}
	rgblink $^ -o $@ -v -x

clean:
	rm -f ${rgbchimem_obj} \
	${rgbcbootrom_obj} \
	retro-gbc-boot-rom.img \
	retro-gbc-boot-highmem.img
