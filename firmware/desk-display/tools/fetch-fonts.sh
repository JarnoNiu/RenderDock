#!/bin/sh
# Fetches the fonts the desk display is built with into firmware/desk-display/fonts/ (which is not in the
# repository). Each comes from its project's own repository on GitHub, at a fixed revision, with the licence
# file that travels with it. All are under the SIL Open Font License 1.1.
#
#   sh tools/fetch-fonts.sh
set -eu
cd "$(dirname "$0")/.."

ADOBE=https://raw.githubusercontent.com/adobe-fonts/source-han-sans/a4f7cf94edfb9d7ffbdfc4841de276358bd7e0f2
GOOGLE_NUNITO=https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/nunito
GOOGLE_MPLUS=https://raw.githubusercontent.com/google/fonts/bc0a790ea62a542b47a4ba2478249c0625057ae4/ofl/mplusrounded1c

# get DIRECTORY FILE URL BYTES
get() {
  mkdir -p "fonts/$1"
  if [ ! -f "fonts/$1/$2" ]; then
    curl --fail --silent --show-error --location --output "fonts/$1/$2" "$3"
  fi
  size=$(wc -c < "fonts/$1/$2" | tr -d ' ')
  if [ "$4" != "-" ] && [ "$size" != "$4" ]; then
    echo "fonts/$1/$2 is $size bytes, expected $4" >&2
    exit 1
  fi
  echo "fonts/$1/$2  $size bytes"
}

# Chinese text: Source Han Sans, the mainland-China subset.
get source-han-sans SourceHanSansCN-Regular.otf "$ADOBE/SubsetOTF/CN/SourceHanSansCN-Regular.otf" 8429224
get source-han-sans SourceHanSansCN-Medium.otf "$ADOBE/SubsetOTF/CN/SourceHanSansCN-Medium.otf" 8406556
get source-han-sans SourceHanSansCN-Bold.otf "$ADOBE/SubsetOTF/CN/SourceHanSansCN-Bold.otf" 8569308
get source-han-sans LICENSE.txt "$ADOBE/LICENSE.txt" -

# Numerals and Latin, rounded. Two candidates while the choice between them is open.
get nunito Nunito-wght.ttf "$GOOGLE_NUNITO/Nunito%5Bwght%5D.ttf" 276932
get nunito OFL.txt "$GOOGLE_NUNITO/OFL.txt" -
get mplus-rounded-1c MPLUSRounded1c-Medium.ttf "$GOOGLE_MPLUS/MPLUSRounded1c-Medium.ttf" 3432376
get mplus-rounded-1c MPLUSRounded1c-Bold.ttf "$GOOGLE_MPLUS/MPLUSRounded1c-Bold.ttf" 3542384
get mplus-rounded-1c METADATA.pb "$GOOGLE_MPLUS/METADATA.pb" -
