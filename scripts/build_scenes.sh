#!/bin/zsh
# Builds the pixel-art ambient scenes into the app resources:
#   docs/Ambiente/*.jpeg  →  pixelize (320×180, 48 colours)  →  sprites/light maps
#   → AudiobookForge/AudiobookForge/Resources/Scenes/scene_<name>_*.png
# Re-run after replacing a source image, then `tuist generate`.
set -euo pipefail
ROOT=${0:a:h:h}
SRC=${AMBIENT_SRC_DIR:-$ROOT/../dev-docs/docs/Ambiente}
PIX=$SRC/pixelized
OUT=$ROOT/AudiobookForge/Resources/Scenes
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT

swiftc -O $ROOT/scripts/pixelize_scenes.swift -o $TMP/pixelize
swiftc -O $ROOT/scripts/make_scene_sprites.swift -o $TMP/make_sprites

mkdir -p $PIX $OUT
rm -f $OUT/scene_*
$TMP/pixelize $PIX --size 320x180 --colors 48 $SRC/Barn.jpeg $SRC/Jungle.jpeg $SRC/Kamin.jpeg $SRC/Meer.jpeg $SRC/Parkbank.jpeg $SRC/cyberpunk.jpeg $SRC/train.jpeg
$TMP/pixelize $PIX --size 320x180 --colors 48 --mean $SRC/abend_zug.jpeg
$TMP/pixelize $PIX --size 320x180 --colors 48 --key "$SRC/kamin_chroma key.jpeg" "$SRC/Bahnschiene_grün.jpeg" "$SRC/ebenegrün.jpeg" $SRC/zug_green.jpeg "$SRC/fluss_landschaft_grün.jpeg"

# Bundle names are flat (Tuist copies Resources/** without folders).
cp $PIX/Kamin.png $OUT/scene_fire_room.png
cp "$PIX/kamin_chroma key.png" $OUT/scene_fire_front.png
$TMP/make_sprites $PIX $OUT
ls -la $OUT
