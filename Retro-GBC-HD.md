Retro-HD for Game Boy
---------------------

This spec describes two forms of Game Boy Retro-HD packs:  graphics and sound.
These packs enhance games without altering the code and timing.

# GB-HD Graphics

The GB-HD Graphics pack colorizes DMG games using sprite data and the 4-shade
mono palettes.

Color pack format is as follows:

| Name  | Length | Description |
| ----- | ------ | ----------- |
| Magic | 4      | "GBHD" magic number |
| Seeds | 16     | Four 32-bit numbers used as seeds to SpookyHash |
| Palette flag | 1 | 0x00, indicates next section is the palette section |
| Palettes | n | A set of palettes. |
| Palette set flag | 1| 0xff, Begin palette sets. |
| Sprite flag | 2 | 0xffff, begin sprite sets. |
| End flag | 4 | 0x0000, ends the sprite set. |
| Extended information | ? | extended info. |

Seeds are for SpookyHash.

Palettes are sets of four 16-bit values to indicate a palette, serialized into
packed 64-bit palettes referred to positionally from 0 and up to a maximum of
254\.  Colors only use 15 bits, so 0x7f is the largest byte; 0xff indicates no
more palettes.


Palette sets are as follows:

| Name | Length | Description |
| ----- | ------ | ----------- |
| Mono Palette | 1 | One-byte mono palette |
| Palette index | n | One byte per palette used |

A palette index of 0xff ends the palette set.  An empty palette set 0xffff
ends the palette set sections.  Palette sets only allowed up to 16,384.

Sprite sets are as follows:

| Name | Length | Description |
| ----- | ------ | ----------- |
| Hash | 4 | 32 bit SpookyHash  |
| Seed and Palette | 2 | 2 bits seed index, 14 bits palette set |

The extended information set is a set of one-bit type identifiers and data as
follows:

Type 0x01:  Color naming
| Name | Length | Description |
| ----- | ------ | ----------- |
| Color | 2 | The color |
| Name | ? | Null-terminated string naming the color |


Type 0x02:  Palette naming
| Name | Length | Description |
| ----- | ------ | ----------- |
| Palette | 1 | The palette |
| Name | ? | Null-terminated string |

Type 0x03:  Sprite naming
| Name | Length | Description |
| ----- | ------ | ----------- |
| Sprite | 2 | The sprite |
| Name | ? | Null-terminated string |

Extended information allows annotation for display when editing.  Sprites with
the same name can be grouped by an editing interface.

## GB-HD Super Graphics

An extended HD graphics pack replaces 8x8 sprites with 16x16 sprites.  This
requires a much larger modification to the PPU to double the resolution.

HD Super Graphics adds a type 0x04 extended info entry made up of the 16-bit
sprite ID and the 64-byte 16x16 HD sprite.  These should be separate files
loaded with a graphics pack instead of streamed at the end, but either works.
