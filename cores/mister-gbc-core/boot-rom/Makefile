
all: retro-gbc-mapper-setup.img retro-gbc-boot-rom.img

retro-gbc-mapper-setup.o: retro-gbc-mapper-setup.asm
	rgbasm retro-gbc-mapper-setup.asm -o retro-gbc-mapper-setup.o -v -Weverything

retro-gbc-mapper-setup.img: retro-gbc-mapper-setup.o
	rgblink retro-gbc-mapper-setup.o -o retro-gbc-mapper-setup.img -v -x


retro-gbc-boot-rom.o: retro-gbc-boot-rom.asm
	rgbasm retro-gbc-boot-rom.asm -o retro-gbc-boot-rom.o -v -Weverything

retro-gbc-boot-rom.img: retro-gbc-boot-rom.o
	rgblink retro-gbc-boot-rom.o -o retro-gbc-boot-rom.img -v -x


clean:
	rm -f retro-gbc-mapper-setup.o retro-gbc-mapper-setup.img \
	 retro-gbc-boot-rom.o retro-gbc-boot-rom.img
